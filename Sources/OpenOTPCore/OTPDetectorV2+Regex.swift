import Foundation

// Regex + scan helpers for the v2 detector (NSRegularExpression, ICU-based).

extension OTPv2 {

    // Compiled-regex cache. Guarded by a lock: multiple AccountWatcher actors
    // (one per account) call regex() concurrently — an unsynchronized static
    // dictionary races and crashes.
    nonisolated(unsafe) private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexCacheLock = NSLock()

    static func regex(_ pattern: String, caseInsensitive: Bool = false,
                      dotAll: Bool = false) -> NSRegularExpression {
        let key = "\(caseInsensitive ? "i" : "")\(dotAll ? "s" : ""):\(pattern)"
        regexCacheLock.lock()
        if let r = regexCache[key] { regexCacheLock.unlock(); return r }
        regexCacheLock.unlock()
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        if dotAll { opts.insert(.dotMatchesLineSeparators) }
        let r = try! NSRegularExpression(pattern: pattern, options: opts)
        regexCacheLock.lock()
        regexCache[key] = r
        regexCacheLock.unlock()
        return r
    }

    static func regexMatches(_ s: String, _ pattern: String) -> Bool {
        let ns = s as NSString
        return regex(pattern).firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) != nil
    }

    static func regexFullMatch(_ s: String, _ pattern: String) -> Bool {
        let ns = s as NSString
        guard let m = regex(pattern).firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        else { return false }
        return m.range.location == 0 && m.range.length == ns.length
    }

    static func firstGroup(_ s: String, _ pattern: String) -> String? {
        let ns = s as NSString
        guard let m = regex(pattern).firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    static func regexReplace(_ s: String, _ pattern: String, _ repl: String,
                             dotAll: Bool = false) -> String {
        let ns = s as NSString
        return regex(pattern, dotAll: dotAll).stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: repl)
    }

    // Replace each match of group(1) using a closure (nil → drop match text kept).
    static func regexReplaceFn(_ s: String, _ pattern: String,
                               _ fn: (String) -> String?) -> String {
        let ns = s as NSString
        let re = regex(pattern)
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var result = ""
        var last = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let token = m.numberOfRanges > 1 ? ns.substring(with: m.range(at: 1)) : ns.substring(with: m.range)
            if let rep = fn(token) { result += rep }
            else { result += ns.substring(with: m.range) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    // Find the '>' that ends a start tag, ignoring '>' inside quoted attributes.
    static func findTagEnd(_ chars: [Character], from: Int) -> Int? {
        var i = from
        let n = chars.count
        var quote: Character? = nil
        while i < n {
            let c = chars[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            }
            i += 1
        }
        return nil
    }

    // Find the index where `seq` begins at/after `from`; returns the start index.
    static func findSeq(_ chars: [Character], from: Int, seq: [Character]) -> Int? {
        let n = chars.count
        let m = seq.count
        if m == 0 || from >= n { return nil }
        var i = from
        while i <= n - m {
            var ok = true
            for k in 0..<m where chars[i + k] != seq[k] { ok = false; break }
            if ok { return i }
            i += 1
        }
        return nil
    }
}
