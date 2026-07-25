import Foundation

// Dual representation (render map): annotate the HTML into a linear
// text buffer where each run carries structural metadata (block, font, styling,
// link/table context). Offsets are UTF-16 (NSString-native).

extension OTPv2 {

    struct Run {
        var start: Int
        var end: Int
        var blockId: Int
        var isSubject = false
        var fontRatio = 1.0
        var letterSpacing = false
        var bold = false
        var centered = false
        var mono = false
        var inLink = false
        var tableId: Int? = nil
        var rowId: Int? = nil
        var elemId = 0
        var soleChar = false
        var isPlaintext = false
        var ptBlankFlanked = false
        var ptShort = false
        var ptIndented = false
    }

    struct RenderMap {
        var text: String
        var ns: NSString
        var runs: [Run]
        var blockText: [Int: String]
        var rowNumericCells: [Int: Int]
        var tableHasMoney: [Int: Bool]

        func runAt(_ pos: Int) -> Run? {
            for r in runs where r.start <= pos && pos < r.end { return r }
            return nil
        }
    }

    static let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4",
        "h5", "h6", "td", "th", "li", "blockquote", "pre", "center", "section",
        "article", "header", "footer", "tr", "table", "ul", "ol", "body"]
    static let skipTags: Set<String> = ["script", "style", "head", "title"]
    static let bigTags: [String: Double] = ["h1": 2.0, "h2": 1.6, "h3": 1.4]
    static let monoTags: Set<String> = ["pre", "code", "tt", "kbd"]
    // Void/unclosed tags — INTENTIONAL, do not "fix" by balancing the stack:
    // a start tag WITHOUT an explicit "/" (e.g. <br>) pushes a style/elem frame
    // that is never popped; only an explicit self-close (<br/>) pushes+pops.
    // This matters on real mail — an ancestor's font-size then stays in force for
    // footer text after <br> runs, which is what lets those codes score correctly.

    static let zeroWidth: Set<Character> = ["\u{200b}", "\u{200c}", "\u{200d}",
                                            "\u{2060}", "\u{feff}"]

    static func stripZeroWidth(_ s: String) -> String {
        String(s.filter { !zeroWidth.contains($0) })
    }

    struct StyleState {
        var font = 1.0
        var ls = false
        var bold = false
        var center = false
        var mono = false
    }

    static func applyDecls(_ s: inout StyleState, _ decl: String) {
        if decl.isEmpty { return }
        if let m = firstGroup(decl, #"font-size\s*:\s*(\d+(?:\.\d+)?)px"#),
           let px = Double(m) { s.font = max(s.font, px / 16.0) }
        if let m = firstGroup(decl, #"letter-spacing\s*:\s*(\d+(?:\.\d+)?)"#),
           let v = Double(m), v > 0 { s.ls = true }
        if regexMatches(decl, #"text-align\s*:\s*center"#) { s.center = true }
        if regexMatches(decl, #"font-weight\s*:\s*(bold|[6-9]00)"#) { s.bold = true }
        if regexMatches(decl, #"font-family\s*:[^;]*(mono|courier)"#) { s.mono = true }
    }

    static func parseStyleBlocks(_ html: String) -> (tag: [String: String], cls: [String: String]) {
        var tagRules: [String: String] = [:]
        var classRules: [String: String] = [:]
        let ns = html as NSString
        let blockRe = try! NSRegularExpression(pattern: "<style[^>]*>(.*?)</style>",
                                               options: [.caseInsensitive, .dotMatchesLineSeparators])
        for m in blockRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            var block = ns.substring(with: m.range(at: 1))
            block = regexReplace(block, #"/\*.*?\*/"#, "", dotAll: true)
            for (selGroup, decl) in iterCSSRules(block) {
                let declLow = decl.lowercased()
                for rawSel in selGroup.split(separator: ",") {
                    let sel = rawSel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if regexFullMatch(sel, #"\.[A-Za-z_][\w-]*"#) {
                        let name = String(sel.dropFirst())
                        classRules[name, default: ""] += ";" + declLow
                    } else if regexFullMatch(sel, #"[A-Za-z][\w-]*"#) {
                        let name = sel.lowercased()
                        tagRules[name, default: ""] += ";" + declLow
                    } // else: compound/descendant/id/attr/pseudo → ignored
                }
            }
        }
        return (tagRules, classRules)
    }

    // Yield (selector, decl) for TOP-LEVEL rules; skip @-rules via brace depth.
    static func iterCSSRules(_ css: String) -> [(String, String)] {
        var out: [(String, String)] = []
        let chars = Array(css)
        let n = chars.count
        var i = 0
        while i < n {
            guard let brace = chars[i...].firstIndex(of: "{") else { break }
            let selector = String(chars[i..<brace]).trimmingCharacters(in: .whitespacesAndNewlines)
            var depth = 1
            var j = brace + 1
            while j < n && depth > 0 {
                if chars[j] == "{" { depth += 1 }
                else if chars[j] == "}" { depth -= 1 }
                j += 1
            }
            let block = String(chars[(brace + 1)..<max(brace + 1, j - 1)])
            if !selector.hasPrefix("@") { out.append((selector, block)) }
            i = j
        }
        return out
    }

    final class MapBuilder {
        let tagRules: [String: String]
        let classRules: [String: String]
        var buf = ""
        var pos = 0
        var runs: [Run] = []
        var blockStack = [0]
        var blockCounter = 0
        var styleStack = [StyleState()]
        var skipDepth = 0
        var linkDepth = 0
        var tableStack: [Int] = []
        var rowStack: [Int] = []
        var tableCounter = 0
        var rowCounter = 0
        var cellTexts: [Int: [String]] = [:]
        var cellBuf: [String]? = nil
        var tableMoney: [Int: Bool] = [:]
        var elemCounter = 0
        var elemStack = [0]
        var elemText: [Int: String] = [0: ""]

        init(tagRules: [String: String], classRules: [String: String]) {
            self.tagRules = tagRules
            self.classRules = classRules
        }

        func emit(_ s: String) { buf += s; pos += s.utf16.count }

        func pushStyle(_ tag: String, _ attrs: [String: String]) {
            var s = styleStack.last!
            if let f = OTPv2.bigTags[tag] { s.font = max(s.font, f) }
            if tag == "b" || tag == "strong" { s.bold = true }
            if tag == "center" { s.center = true }
            if OTPv2.monoTags.contains(tag) { s.mono = true }
            OTPv2.applyDecls(&s, tagRules[tag] ?? "")
            if let cls = attrs["class"] {
                for c in cls.split(separator: " ") {
                    OTPv2.applyDecls(&s, classRules[String(c)] ?? "")
                }
            }
            OTPv2.applyDecls(&s, (attrs["style"] ?? "").lowercased())
            styleStack.append(s)
            elemCounter += 1
            elemStack.append(elemCounter)
            elemText[elemCounter] = ""
        }

        func popStyle() {
            if styleStack.count > 1 {
                styleStack.removeLast()
                if elemStack.count > 1 { elemStack.removeLast() }
            }
        }

        func startTag(_ tag: String, _ attrs: [String: String]) {
            if OTPv2.skipTags.contains(tag) { skipDepth += 1; return }
            if tag == "a" { linkDepth += 1 }
            if tag == "table" {
                tableCounter += 1; tableStack.append(tableCounter)
                tableMoney[tableCounter] = false
            }
            if tag == "tr" {
                rowCounter += 1; rowStack.append(rowCounter)
                cellTexts[rowCounter] = []
            }
            if tag == "td" || tag == "th" { cellBuf = [] }
            if OTPv2.blockTags.contains(tag) {
                blockCounter += 1; blockStack.append(blockCounter); emit("\n")
            }
            pushStyle(tag, attrs)
        }

        func endTag(_ tag: String) {
            if OTPv2.skipTags.contains(tag) { skipDepth = max(0, skipDepth - 1); return }
            if tag == "a" { linkDepth = max(0, linkDepth - 1) }
            if (tag == "td" || tag == "th"), let cb = cellBuf {
                if let r = rowStack.last {
                    cellTexts[r, default: []].append(cb.joined().trimmingCharacters(in: .whitespaces))
                }
                cellBuf = nil
            }
            if tag == "tr", !rowStack.isEmpty { rowStack.removeLast() }
            if tag == "table", !tableStack.isEmpty { tableStack.removeLast() }
            if OTPv2.blockTags.contains(tag), blockStack.count > 1 {
                blockStack.removeLast(); emit("\n")
            }
            popStyle()
        }

        func handleData(_ raw: String) {
            if skipDepth > 0 || raw.isEmpty { return }
            let data = OTPv2.stripZeroWidth(raw)
            if data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                emit(" "); return
            }
            let s = styleStack.last!
            let start = pos
            emit(data)
            if cellBuf != nil { cellBuf!.append(data) }
            if data.contains("$") || data.contains("€") || data.contains("£") {
                for t in tableStack { tableMoney[t] = true }
            }
            let eid = elemStack.last!
            elemText[eid, default: ""] += data
            runs.append(Run(start: start, end: pos, blockId: blockStack.last!,
                            fontRatio: s.font, letterSpacing: s.ls, bold: s.bold,
                            centered: s.center, mono: s.mono, inLink: linkDepth > 0,
                            tableId: tableStack.last, rowId: rowStack.last, elemId: eid))
        }

        // Minimal HTML tokenizer mirroring html.parser's event stream for the
        // constructs OTP emails use. Stray '<' not starting a tag is data.
        func feed(_ html: String) {
            let chars = Array(html)
            let n = chars.count
            var i = 0
            var dataBuf = ""
            func flushData() {
                if !dataBuf.isEmpty { handleData(OTPv2.decodeEntities(dataBuf)); dataBuf = "" }
            }
            while i < n {
                let c = chars[i]
                if c == "<" {
                    let nxt = i + 1 < n ? chars[i + 1] : " "
                    if nxt == "!" {                              // comment / doctype
                        flushData()
                        if i + 3 < n && chars[i + 1] == "!" && chars[i + 2] == "-" && chars[i + 3] == "-" {
                            if let close = findSeq(chars, from: i + 4, seq: ["-", "-", ">"]) {
                                i = close + 3; continue
                            } else { break }
                        }
                        if let gt = chars[i...].firstIndex(of: ">") { i = gt + 1; continue }
                        break
                    } else if nxt == "/" {                        // end tag
                        flushData()
                        guard let gt = chars[(i + 2)...].firstIndex(of: ">") else { break }
                        let name = String(chars[(i + 2)..<gt]).trimmingCharacters(in: .whitespaces).lowercased()
                        endTag(tagName(name))
                        i = gt + 1; continue
                    } else if nxt.isLetter {                      // start tag
                        flushData()
                        guard let gt = findTagEnd(chars, from: i + 1) else { break }
                        let inner = String(chars[(i + 1)..<gt])
                        let selfClose = inner.hasSuffix("/")
                        let (name, attrs) = parseTag(inner)
                        startTag(name, attrs)
                        // Only an explicit self-close pops; a bare <br>/<img>/etc.
                        // leaks its frame (bare void tag; see the void-tag note above).
                        if selfClose { endTag(name) }
                        i = gt + 1; continue
                    } else {                                      // stray '<' → data
                        dataBuf.append(c); i += 1; continue
                    }
                } else {
                    dataBuf.append(c); i += 1
                }
            }
            flushData()
        }

        private func tagName(_ n: String) -> String { n }

        private func parseTag(_ inner: String) -> (String, [String: String]) {
            var s = inner
            if s.hasSuffix("/") { s.removeLast() }
            let chars = Array(s)
            var i = 0
            let n = chars.count
            var name = ""
            while i < n && !chars[i].isWhitespace { name.append(chars[i]); i += 1 }
            var attrs: [String: String] = [:]
            while i < n {
                while i < n && chars[i].isWhitespace { i += 1 }
                if i >= n { break }
                var key = ""
                while i < n && chars[i] != "=" && !chars[i].isWhitespace { key.append(chars[i]); i += 1 }
                while i < n && chars[i].isWhitespace { i += 1 }
                var value = ""
                if i < n && chars[i] == "=" {
                    i += 1
                    while i < n && chars[i].isWhitespace { i += 1 }
                    if i < n && (chars[i] == "\"" || chars[i] == "'") {
                        let q = chars[i]; i += 1
                        while i < n && chars[i] != q { value.append(chars[i]); i += 1 }
                        if i < n { i += 1 }
                    } else {
                        while i < n && !chars[i].isWhitespace { value.append(chars[i]); i += 1 }
                    }
                }
                if !key.isEmpty { attrs[key.lowercased()] = value }
            }
            return (name.lowercased(), attrs)
        }
    }

    // Decode the handful of HTML entities OTP emails can contain (html.parser
    // with convert_charrefs=True decodes all; we cover common + numeric).
    static func decodeEntities(_ s: String) -> String {
        if !s.contains("&") { return s }
        var out = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                     "&apos;": "'", "&#39;": "'", "&nbsp;": "\u{a0}",
                     "&copy;": "©", "&mdash;": "—", "&ndash;": "–"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        // numeric &#dd; / &#xhh;
        out = regexReplaceFn(out, #"&#(x?[0-9A-Fa-f]+);"#) { token in
            var t = token
            let hex = t.hasPrefix("x") || t.hasPrefix("X")
            if hex { t.removeFirst() }
            guard let v = UInt32(t, radix: hex ? 16 : 10), let sc = Unicode.Scalar(v)
            else { return nil }
            return String(Character(sc))
        }
        return out
    }

    static func buildRenderMap(subject: String, body: String, isHTML: Bool) -> RenderMap {
        let subj = stripZeroWidth(subject)
        var runs: [Run] = []
        var parts: [String] = []
        var pos = 0
        if !subj.isEmpty {
            runs.append(Run(start: 0, end: subj.utf16.count, blockId: -1, isSubject: true))
            parts.append(subj)
            pos = subj.utf16.count
        }
        parts.append("\n"); pos += 1

        var rowNumeric: [Int: Int] = [:]
        var tableMoney: [Int: Bool] = [:]
        var elemText: [Int: String] = [:]

        if isHTML {
            let (tagRules, classRules) = parseStyleBlocks(body)
            let mb = MapBuilder(tagRules: tagRules, classRules: classRules)
            mb.feed(body)
            let offset = pos
            parts.append(mb.buf)
            for var r in mb.runs { r.start += offset; r.end += offset; runs.append(r) }
            for (rid, cells) in mb.cellTexts {
                rowNumeric[rid] = cells.reduce(0) { $0 + (numericCell($1) ? 1 : 0) }
            }
            tableMoney = mb.tableMoney
            elemText = mb.elemText
        } else {
            let b = stripZeroWidth(body)
            let offset = pos
            parts.append(b)
            let lines = b.components(separatedBy: "\n")
            var lineStart = offset
            var bid = 0
            for (idx, line) in lines.enumerated() {
                bid += 1
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let prevBlank = idx == 0 || lines[idx - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let nextBlank = idx == lines.count - 1 || lines[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    let stripped = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    let indented = line.first.map { $0 == " " || $0 == "\t" } ?? false
                    runs.append(Run(start: lineStart, end: lineStart + line.utf16.count,
                                    blockId: bid, isPlaintext: true,
                                    ptBlankFlanked: prevBlank && nextBlank,
                                    ptShort: stripped.count <= ptShortLineMax,
                                    ptIndented: indented))
                }
                lineStart += line.utf16.count + 1
            }
        }

        let text = parts.joined()
        let ns = text as NSString
        var blockText: [Int: String] = [:]
        for r in runs {
            blockText[r.blockId, default: ""] += ns.substring(with: NSRange(location: r.start, length: r.end - r.start))
        }
        for k in blockText.keys { blockText[k] = blockText[k]!.trimmingCharacters(in: .whitespacesAndNewlines) }

        // mark sole-single-alnum-char runs
        for idx in runs.indices where runs[idx].elemId != 0 {
            let et = (elemText[runs[idx].elemId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rt = ns.substring(with: NSRange(location: runs[idx].start,
                                                length: runs[idx].end - runs[idx].start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            runs[idx].soleChar = rt.count == 1 && isAsciiOrLetterDigit(rt) && et == rt
        }

        return RenderMap(text: text, ns: ns, runs: runs, blockText: blockText,
                         rowNumericCells: rowNumeric, tableHasMoney: tableMoney)
    }

    static func numericCell(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for ch in [",", "$", "€", "£"] { t = t.replacingOccurrences(of: ch, with: "") }
        if t.isEmpty { return false }
        return regexFullMatch(t, #"\d+(\.\d+)?"#)
    }

    static func isAsciiOrLetterDigit(_ s: String) -> Bool {
        guard let c = s.unicodeScalars.first, s.unicodeScalars.count == 1 else { return false }
        return CharacterSet.alphanumerics.contains(c)
    }
}
