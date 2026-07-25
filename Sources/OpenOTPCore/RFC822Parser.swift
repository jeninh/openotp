import Foundation

public enum RFC822Parser {

    public struct Parsed: Sendable {
        public let subject: String
        public let from: String
        public let body: String
        public let isHTML: Bool
    }

    /// Parses a raw RFC 822 message (as fetched over IMAP) into subject, sender, and
    /// body text, handling MIME multipart, base64/quoted-printable, and encoded-word headers.
    public static func parse(_ data: Data) -> Parsed {
        let raw = String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
        let (headerStr, bodyStr) = splitHeadersBody(raw)
        let headers = parseHeaders(headerStr)
        let subject = decodeEncodedWords(headers["subject"] ?? "")
        let from = decodeEncodedWords(headers["from"] ?? "")
        let (body, isHTML) = extractBody(headers: headers, body: bodyStr)
        return Parsed(subject: subject, from: from, body: body, isHTML: isHTML)
    }

    static func splitHeadersBody(_ raw: String) -> (String, String) {
        if let r = raw.range(of: "\r\n\r\n") {
            return (String(raw[..<r.lowerBound]), String(raw[r.upperBound...]))
        }
        if let r = raw.range(of: "\n\n") {
            return (String(raw[..<r.lowerBound]), String(raw[r.upperBound...]))
        }
        return (raw, "")
    }

    static func parseHeaders(_ headerStr: String) -> [String: String] {
        var headers: [String: String] = [:]
        var currentKey: String?
        var currentVal = ""
        func commit() {
            if let k = currentKey { headers[k.lowercased()] = currentVal.trimmingCharacters(in: .whitespaces) }
        }
        for line in headerStr.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.first == " " || line.first == "\t" {
                currentVal += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                commit()
                currentKey = String(line[..<colon])
                currentVal = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        commit()
        return headers
    }

    static func extractBody(headers: [String: String], body: String) -> (String, Bool) {
        let contentType = (headers["content-type"] ?? "text/plain").lowercased()

        if contentType.contains("multipart"), let boundary = boundary(from: headers["content-type"] ?? "") {
            var plain: String?
            var html: String?
            for part in splitParts(body, boundary: boundary) {
                let (ph, pb) = splitHeadersBody(part)
                let pheaders = parseHeaders(ph)
                let pct = (pheaders["content-type"] ?? "text/plain").lowercased()
                if pct.contains("multipart") {
                    let (t, isHTML) = extractBody(headers: pheaders, body: pb)
                    if isHTML { if html == nil { html = t } } else if plain == nil { plain = t }
                } else if pct.contains("text/plain") {
                    if plain == nil { plain = decodeContent(pb, headers: pheaders) }
                } else if pct.contains("text/html") {
                    if html == nil { html = decodeContent(pb, headers: pheaders) }
                }
            }
            // Prefer text/html. Senders style the OTP in
            // the HTML part; the plain-text alternative often lacks the code (→
            // false negatives) or flattens tables into bare number lines (→ false
            // positives). The whole render map depends on seeing the HTML.
            if let html, !html.isEmpty { return (html, true) }
            if let plain { return (plain, false) }
            return ("", false)
        }

        let text = decodeContent(body, headers: headers)
        return (text, contentType.contains("text/html"))
    }

    static func decodeContent(_ body: String, headers: [String: String]) -> String {
        let cte = (headers["content-transfer-encoding"] ?? "7bit").lowercased()
        let charset = charset(from: headers["content-type"] ?? "") ?? "utf-8"
        let bytes: Data
        switch cte {
        case "base64": bytes = decodeBase64(body)
        case "quoted-printable": bytes = decodeQuotedPrintable(body)
        default: bytes = body.data(using: .isoLatin1) ?? Data(body.utf8)
        }
        return decodeString(bytes, charset: charset)
    }

    // MARK: - MIME helpers

    static func boundary(from contentType: String) -> String? {
        guard let r = contentType.range(of: "boundary=", options: .caseInsensitive) else { return nil }
        var b = String(contentType[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if b.first == "\"" {
            b.removeFirst()
            if let end = b.firstIndex(of: "\"") { b = String(b[..<end]) }
        } else if let end = b.firstIndex(where: { $0 == ";" || $0 == " " }) {
            b = String(b[..<end])
        }
        return b.isEmpty ? nil : b
    }

    static func charset(from contentType: String) -> String? {
        guard let r = contentType.range(of: "charset=", options: .caseInsensitive) else { return nil }
        var c = String(contentType[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if c.first == "\"" {
            c.removeFirst()
            if let end = c.firstIndex(of: "\"") { c = String(c[..<end]) }
        } else if let end = c.firstIndex(where: { $0 == ";" || $0 == " " }) {
            c = String(c[..<end])
        }
        return c
    }

    static func splitParts(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        var parts: [String] = []
        for chunk in body.components(separatedBy: delimiter) {
            var c = chunk
            if c.hasPrefix("--") { continue }
            while c.first == "\r" || c.first == "\n" { c.removeFirst() }
            if !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(c) }
        }
        return parts
    }

    static func decodeBase64(_ s: String) -> Data {
        let cleaned = s.components(separatedBy: .whitespacesAndNewlines).joined()
        return Data(base64Encoded: cleaned) ?? Data()
    }

    static func decodeQuotedPrintable(_ s: String) -> Data {
        let bytes = Array(s.data(using: .isoLatin1) ?? Data(s.utf8))
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        var out = [UInt8]()
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == 0x3D {
                if i + 2 < bytes.count, let hi = hex(bytes[i+1]), let lo = hex(bytes[i+2]) {
                    out.append((hi << 4) | lo); i += 3; continue
                }
                if i + 2 < bytes.count && bytes[i+1] == 0x0D && bytes[i+2] == 0x0A { i += 3; continue }
                if i + 1 < bytes.count && bytes[i+1] == 0x0A { i += 2; continue }
                i += 1; continue
            }
            out.append(b); i += 1
        }
        return Data(out)
    }

    static func decodeString(_ data: Data, charset: String) -> String {
        let enc: String.Encoding
        switch charset.lowercased() {
        case "utf-8", "utf8": enc = .utf8
        case "iso-8859-1", "latin1": enc = .isoLatin1
        case "us-ascii", "ascii": enc = .ascii
        case "windows-1252", "cp1252": enc = .windowsCP1252
        default: enc = .utf8
        }
        return String(data: data, encoding: enc) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Encoded-word (=?charset?B?...?=)

    static func decodeEncodedWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let pattern = "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?="
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if !between.trimmingCharacters(in: .whitespaces).isEmpty { result += between }
            let cs = ns.substring(with: m.range(at: 1))
            let enc = ns.substring(with: m.range(at: 2)).uppercased()
            let text = ns.substring(with: m.range(at: 3))
            let data: Data = enc == "B" ? decodeBase64(text)
                : decodeQuotedPrintable(text.replacingOccurrences(of: "_", with: " "))
            result += decodeString(data, charset: cs)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result.isEmpty ? s : result
    }
}
