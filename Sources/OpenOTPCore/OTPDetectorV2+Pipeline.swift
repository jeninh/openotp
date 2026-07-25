import Foundation

// Detection pipeline: tokenize → claim → extract → score.

extension OTPv2 {

    struct Token { var text: String; var start: Int; var end: Int }

    static let glue: Set<UInt16> = Set(":./-_@".utf16)

    static func isAlnum(_ ns: NSString, _ i: Int) -> Bool {
        let u = ns.character(at: i)
        guard let sc = Unicode.Scalar(u) else { return false }   // surrogate → not alnum
        return CharacterSet.alphanumerics.contains(sc)
    }

    static func tokenize(_ ns: NSString) -> [Token] {
        var tokens: [Token] = []
        let n = ns.length
        var i = 0
        while i < n {
            if isAlnum(ns, i) {
                var j = i
                while j < n {
                    if isAlnum(ns, j) { j += 1 }
                    else if glue.contains(ns.character(at: j)) && j + 1 < n
                                && isAlnum(ns, j + 1) && j > i && isAlnum(ns, j - 1) { j += 1 }
                    else { break }
                }
                tokens.append(Token(text: ns.substring(with: NSRange(location: i, length: j - i)),
                                    start: i, end: j))
                i = j
            } else { i += 1 }
        }
        return tokens
    }

    static let coalesceBlockBase = -100

    static func coalesceCells(_ rm: inout RenderMap, _ tokens: [Token]) -> [Token] {
        let schar = rm.runs.filter { $0.soleChar }.sorted { $0.start < $1.start }
        if schar.count < 2 { return tokens }

        var groups: [[Run]] = []
        var cur: [Run] = []
        for r in schar {
            if cur.isEmpty { cur = [r]; continue }
            let gap = rm.ns.substring(with: NSRange(location: cur.last!.end,
                                                    length: r.start - cur.last!.end))
            if gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { cur.append(r) }
            else { if cur.count >= 2 { groups.append(cur) }; cur = [r] }
        }
        if cur.count >= 2 { groups.append(cur) }
        if groups.isEmpty { return tokens }

        var out = tokens
        var nextBlock = coalesceBlockBase
        for g in groups {
            let start = g.first!.start, end = g.last!.end
            let inside = out.filter { start <= $0.start && $0.end <= end }
            if inside.count <= 1 { continue }
            let mergedText = g.map {
                rm.ns.substring(with: NSRange(location: $0.start, length: $0.end - $0.start))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }.joined()
            out.removeAll { start <= $0.start && $0.end <= end }
            out.append(Token(text: mergedText, start: start, end: end))
            var mr = Run(start: start, end: end, blockId: nextBlock)
            mr.fontRatio = g.map { $0.fontRatio }.max() ?? 1.0
            mr.letterSpacing = g.contains { $0.letterSpacing }
            mr.bold = g.contains { $0.bold }
            mr.centered = g.contains { $0.centered }
            mr.mono = g.contains { $0.mono }
            mr.inLink = g.contains { $0.inLink }
            rm.blockText[nextBlock] = mergedText
            rm.runs.insert(mr, at: 0)
            nextBlock -= 1
        }
        out.sort { $0.start < $1.start }
        return out
    }

    struct Claim { var start: Int; var end: Int; var kind: String }

    static func collectClaims(_ rm: RenderMap, _ tokens: [Token], _ lex: Lexicon) -> [Claim] {
        let text = rm.text
        let ns = rm.ns
        var claims: [Claim] = []

        let monthAlt = months.joined(separator: "|")
        let buffer: [(String, String)] = [
            (#"(https?://\S+|www\.\S+|\b[\w.-]+\.(?:com|net|org|io|co|dev|app)/\S*)"#, "url"),
            (#"[$€£]\s?\d[\d,]*(?:\.\d{2})?|\b\d{1,3}(?:,\d{3})+(?:\.\d{2})?\b"#, "money"),
            (#"\+\d[\d\s().-]{6,}\d|\(\d{3}\)\s?\d{3}[- .]\d{4}|\b\d{3}[-.]\d{3}[-.]\d{4}\b"#, "phone"),
            (#"\b\d{1,2}:\d{2}(?::\d{2})?\s?(?:am|pm)?\b"#, "time"),
            (#"\b(?:\#(monthAlt))[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?\b|\b\d{1,2}\s+(?:\#(monthAlt))[a-z]*\.?(?:\s+\d{4})?\b"#, "date"),
        ]
        for (pat, kind) in buffer {
            let re = regex(pat, caseInsensitive: true)
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                claims.append(Claim(start: m.range.location,
                                    end: m.range.location + m.range.length, kind: kind))
            }
        }
        let yearRe = regex(#"(?:©|\(c\)|copyright|since|in|est\.?)\s*(\d{4})\b"#, caseInsensitive: true)
        for m in yearRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let g = m.range(at: 1)
            claims.append(Claim(start: g.location, end: g.location + g.length, kind: "date"))
        }

        for (idx, tok) in tokens.enumerated() {
            let t = tok.text
            if regexFullMatch(t, #"([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}"#) {
                claims.append(Claim(start: tok.start, end: tok.end, kind: "mac"))
            } else if regexFullMatch(t, #"[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){2,7}"#) && t.contains(":") {
                claims.append(Claim(start: tok.start, end: tok.end, kind: "ipv6"))
            } else if let g = ipv4Groups(t) {
                if g.allSatisfy({ (0...255).contains($0) }) {
                    claims.append(Claim(start: tok.start, end: tok.end, kind: "ipv4"))
                }
            } else if regexFullMatch(t, #"\d{4}-\d{2}-\d{2}(T[\d:.]+Z?)?"#) {
                claims.append(Claim(start: tok.start, end: tok.end, kind: "date"))
            } else if regexFullMatch(t.lowercased(), #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#) {
                claims.append(Claim(start: tok.start, end: tok.end, kind: "uuid"))
            } else if regexFullMatch(t, #"v?\d+(\.\d+){1,3}"#) && t.contains(".") {
                claims.append(Claim(start: tok.start, end: tok.end, kind: "version"))
            } else if regexFullMatch(t, #"1Z[0-9A-Z]{16}"#) {
                claims.append(Claim(start: tok.start, end: tok.end, kind: "tracking"))
            } else if t.count >= 12 && isAsciiAlnum(t)
                        && t.contains(where: { $0.isLowercase })
                        && t.contains(where: { $0.isNumber })
                        && t.contains(where: { $0.isLetter }) {
                claims.append(Claim(start: tok.start, end: tok.end, kind: "hash"))
            }

            if isAllASCIIDigits(t) {
                // Phrase-level claim evidence is SAME-BLOCK by definition —
                // it must not leak across render-map structure.
                let numBlock = blockAt(rm, tok.start)
                let backStart = max(0, tok.start - 3)
                let back = ns.substring(with: NSRange(location: backStart, length: tok.start - backStart))
                if let hashRange = back.range(of: "#", options: .backwards) {
                    let hashPos = backStart + back.distance(from: back.startIndex, to: hashRange.lowerBound)
                    if numBlock != nil && blockAt(rm, hashPos) == numBlock {
                        claims.append(Claim(start: tok.start, end: tok.end, kind: "identifier"))
                        continue
                    }
                }
                var j = max(0, idx - 2)
                while j < idx {
                    let w = tokens[j].text.lowercased().trimmingTrailingDots()
                    if lex.idWords.contains(w) && tok.start - tokens[j].end <= 24
                        && numBlock != nil && blockAt(rm, tokens[j].start) == numBlock {
                        claims.append(Claim(start: tok.start, end: tok.end, kind: "identifier"))
                        break
                    }
                    j += 1
                }
            }
        }

        // merge overlapping claims (longest span wins via interval union)
        claims.sort { $0.start != $1.start ? $0.start < $1.start : ($0.end - $0.start) > ($1.end - $1.start) }
        var merged: [Claim] = []
        for c in claims {
            if let last = merged.last, c.start < last.end {
                if c.end > last.end {
                    merged[merged.count - 1] = Claim(start: last.start, end: c.end,
                                                     kind: last.kind + "+" + c.kind)
                }
            } else { merged.append(c) }
        }
        return merged
    }

    static func claimed(_ claims: [Claim], _ start: Int, _ end: Int) -> String? {
        for c in claims where start < c.end && c.start < end { return c.kind }
        return nil
    }

    // render-map block id containing `pos`, or nil.
    static func blockAt(_ rm: RenderMap, _ pos: Int) -> Int? {
        rm.runAt(pos)?.blockId
    }

    struct Candidate {
        var value: String; var raw: String; var start: Int; var end: Int; var kind: String
        var trace: [String] = []
        var S = 0.0; var L = 0.0; var P = 0.0; var C = 0.0
    }

    static func extractCandidates(_ rm: RenderMap, _ tokens: [Token], _ claims: [Claim]) -> [Candidate] {
        var cands: [Candidate] = []
        var covered: [(Int, Int)] = []
        let text = rm.text
        let ns = rm.ns

        let groupedRe = regex(#"(?<![\w.:/@-])(\d{2,4}(?:([- ])\d{2,4})(?:\2\d{2,4}){0,2})(?![\w.:/@-])"#)
        for m in groupedRe.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let g1 = m.range(at: 1), g2 = m.range(at: 2)
            let raw = ns.substring(with: g1)
            guard g2.location != NSNotFound else { continue }
            let sep = ns.substring(with: g2)
            let parts = raw.components(separatedBy: sep)
            if Set(parts.map { $0.count }).count != 1 { continue }
            let digits = parts.joined()
            if !(4...8).contains(digits.count) { continue }
            if claimed(claims, g1.location, g1.location + g1.length) != nil { continue }
            cands.append(Candidate(value: digits, raw: raw, start: g1.location,
                                   end: g1.location + g1.length, kind: "grouped"))
            covered.append((g1.location, g1.location + g1.length))
        }

        for tok in tokens {
            if covered.contains(where: { $0.0 <= tok.start && tok.end <= $0.1 }) { continue }
            if claimed(claims, tok.start, tok.end) != nil { continue }
            let t = tok.text
            if !t.isASCIIString { continue }
            if isAllASCIIDigits(t) && (4...8).contains(t.count) {
                cands.append(Candidate(value: t, raw: t, start: tok.start, end: tok.end, kind: "numeric"))
            } else if isAsciiAlnum(t) && (6...10).contains(t.count)
                        && t.contains(where: { $0.isLetter }) {
                // A code looks like one of three shapes (examples are synthetic):
                //   • MIXED letters+digits, any case — "K7m2Qz", "A1B2C3"
                //   • an ALL-UPPERCASE letter block — "QWERTZUIOP"
                //   • IRREGULARLY-capitalized letters — "aBxKpZ", as some
                //     providers' mixed-case login codes: a capital appears
                //     somewhere past the first character.
                // Excluded as ordinary words: all-lowercase ("password") and
                // plain Capitalized words ("Notion", "Welcome") whose only
                // capital is the leading one. Longer lowercase+digit hashes are
                // already claimed at ≥12.
                let hasDigit = t.contains(where: { $0.isNumber })
                let allUpper = (t == t.uppercased())
                let hasLower = t.contains(where: { $0.isLowercase })
                let internalUpper = t.dropFirst().contains(where: { $0.isUppercase })
                if hasDigit || allUpper || (hasLower && internalUpper) {
                    cands.append(Candidate(value: t, raw: t, start: tok.start, end: tok.end, kind: "alphanumeric"))
                }
            }
        }
        return cands
    }

    static func scoreStructural(_ cand: inout Candidate, _ rm: RenderMap) {
        guard let run = rm.runAt(cand.start) else { cand.S = 0; return }
        var s = 0.0
        if run.isSubject {
            s += 0.35; cand.trace.append("subjectProminence+0.35")
        } else {
            let block = rm.blockText[run.blockId] ?? ""
            let sub = rm.ns.substring(with: NSRange(location: cand.start, length: cand.end - cand.start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if (!block.isEmpty && block == sub) || block == cand.raw {
                s += 0.45; cand.trace.append("soleBlockContent+0.45")
            } else if let r = block.range(of: cand.raw) {
                let before = countWords(String(block[..<r.lowerBound]))
                let after = countWords(String(block[r.upperBound...]))
                if before >= 3 && after >= 3 { s -= 0.50; cand.trace.append("proseEmbedded-0.50") }
            }
            var style = 0.0
            if run.fontRatio >= 1.3 { style += 0.20; cand.trace.append("fontSize+0.20") }
            if run.letterSpacing { style += 0.15; cand.trace.append("letterSpacing+0.15") }
            if run.bold { style += 0.10; cand.trace.append("bold+0.10") }
            if run.centered { style += 0.10; cand.trace.append("centered+0.10") }
            if run.mono { style += 0.10; cand.trace.append("monospace+0.10") }
            s += min(style, 0.35)

            if run.isPlaintext {
                var iso = 0.0
                if run.ptBlankFlanked { iso += ptBlankFlanked; cand.trace.append("blankLineFlanked+\(String(format: "%.2f", ptBlankFlanked))") }
                if run.ptShort { iso += ptShortLine; cand.trace.append("shortLine+\(String(format: "%.2f", ptShortLine))") }
                if run.ptIndented { iso += ptIndented; cand.trace.append("indentedCentered+\(String(format: "%.2f", ptIndented))") }
                s += min(iso, ptIsolationCap)
            }

            if run.inLink { s -= 0.40; cand.trace.append("insideLink-0.40") }
            if let rid = run.rowId {
                let numeric = rm.rowNumericCells[rid] ?? 0
                let money = rm.tableHasMoney[run.tableId ?? -1] ?? false
                if numeric >= 3 || money { s -= 0.60; cand.trace.append("receiptTable-0.60") }
            }
        }
        cand.S = max(0.0, min(1.0, s))
    }

    static func findKeywords(_ low: String, _ words: [String]) -> [(Int, Int, String)] {
        var out: [(Int, Int, String)] = []
        let ns = low as NSString
        for w in words {
            let pat = "(?<![a-z0-9])" + NSRegularExpression.escapedPattern(for: w) + "(?![a-z0-9])"
            for m in regex(pat).matches(in: low, range: NSRange(location: 0, length: ns.length)) {
                out.append((m.range.location, m.range.location + m.range.length, w))
            }
        }
        return out
    }

    static func scoreLexical(_ cand: inout Candidate, _ rm: RenderMap, _ lex: Lexicon) {
        let low = rm.text.lowercased()
        let ns = low as NSString
        var l = 0.0
        var best: (Int, Int, Int, String)? = nil  // d, ks, ke, kw
        for (ks, ke, kw) in findKeywords(low, lex.positive) {
            let d = ke <= cand.start ? cand.start - ke : ks - cand.end
            if d >= 0 && d <= keywordRange && (best == nil || d < best!.0) { best = (d, ks, ke, kw) }
        }
        if let (d, ks, ke, kw) = best {
            let gapRange = ke <= cand.start
                ? NSRange(location: ke, length: cand.start - ke)
                : NSRange(location: cand.end, length: ks - cand.end)
            let gap = gapRange.length > 0 ? ns.substring(with: gapRange) : ""
            let between = matchesOf(#"[a-z]+"#, in: gap)
            // Compound-absorber fix — drop the run of absorber tokens DIRECTLY
            // abutting the keyword span (a compound modifier naming the code, e.g.
            // "email verification code"), not an absorbed governed noun. A
            // connective between an absorber and the keyword breaks adjacency, so
            // "verify your email address" still absorbs.
            let kwBefore = ke <= cand.start   // keyword before candidate → adjacent tokens at front
            let order = kwBefore ? between : between.reversed().map { $0 }
            var nCompound = 0
            for w in order {
                if lex.absorbers.contains(w) { nCompound += 1 } else { break }
            }
            for w in order.prefix(nCompound) { cand.trace.append("absorberCompound(\(w))") }
            let effective = kwBefore ? Array(between[nCompound...])
                                     : Array(between[..<(between.count - nCompound)])
            if effective.contains(where: { lex.absorbers.contains($0) }) {
                cand.trace.append("keywordAbsorbed(\(kw))")
            } else if effective.allSatisfy({ lex.connectives.contains($0) }) {
                l = 0.6 + 0.4 * max(0.0, 1 - Double(d) / Double(keywordRange))
                cand.trace.append("boundKeyword(\(kw),d=\(d))+\(String(format: "%.2f", l))")
            } else {
                l = 0.2 * max(0.0, 1 - Double(d) / Double(keywordRange))
                cand.trace.append("unboundProximity(\(kw),d=\(d))+\(String(format: "%.2f", l))")
            }
        }
        for (ks, ke, kw) in findKeywords(low, lex.negative) {
            let d = ke <= cand.start ? cand.start - ke : ks - cand.end
            if d >= 0 && d <= negativeRange {
                l -= 0.45; cand.trace.append("negativeKeyword(\(kw))-0.45"); break
            }
        }
        cand.L = max(0.0, min(1.0, l))
    }

    static func scoreShape(_ cand: inout Candidate) {
        var p = cand.value.count == 6 ? 0.12 : 0.05
        if cand.kind == "grouped" || cand.kind == "alphanumeric" { p += 0.03 }
        cand.P = p
        cand.trace.append("shapePrior+\(String(format: "%.2f", p))")
    }

    static let mergeOpen = ["{{", "*|", "%"], mergeClose = ["}}", "|*", "%"]
    static func mergeTagWrapped(_ ns: NSString, _ start: Int, _ end: Int) -> Bool {
        let bStart = max(0, start - 3)
        let before = ns.substring(with: NSRange(location: bStart, length: start - bStart))
        let after = ns.substring(with: NSRange(location: end, length: min(3, ns.length - end)))
        return mergeOpen.contains { before.contains($0) } && mergeClose.contains { after.contains($0) }
    }

    static func pipeline(subject: String, body: String, isHTML: Bool, lex: Lexicon)
        -> (RenderMap, [Candidate]) {
        var rm = buildRenderMap(subject: subject, body: body, isHTML: isHTML)
        var tokens = tokenize(rm.ns)
        tokens = coalesceCells(&rm, tokens)
        let claims = collectClaims(rm, tokens, lex)
        let cands = extractCandidates(rm, tokens, claims)
        return (rm, cands)
    }
}
