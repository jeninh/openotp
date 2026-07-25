import Foundation

extension OTPv2 {

    public struct V2Result {
        public let value: String
        public let confidence: Double
        public let trace: [String]
    }

    static func round3(_ x: Double) -> Double {
        (x * 1000).rounded(.toNearestOrEven) / 1000
    }

    public static func detect(subject: String, body: String, isHTML: Bool,
                              lex: Lexicon = lexiconEN) -> V2Result? {
        let (rm, cands0) = pipeline(subject: subject, body: body, isHTML: isHTML, lex: lex)
        var eligible: [Candidate] = []
        for var c in cands0 {
            if mergeTagWrapped(rm.ns, c.start, c.end) { continue }
            scoreStructural(&c, rm)
            scoreLexical(&c, rm, lex)
            scoreShape(&c)
            c.C = min(1.0, max(0.5 * c.S + 0.4 * c.L, 0.8 * c.S) + c.P)
            if c.S < sFloor { continue }
            if !(c.L >= lBoundGate || c.S >= sStructuralGate) { continue }
            eligible.append(c)
        }
        if eligible.isEmpty { return nil }
        let ordered = stableSortByCDesc(eligible)
        var winner = ordered[0]
        var threshold = cThreshold
        if ordered.count > 1 && ordered[1].value != winner.value
            && winner.C - ordered[1].C < ambiguityMargin {
            threshold = cAmbiguous
            winner.trace.append("ambiguity(runnerUp=\(ordered[1].value))->bar=\(threshold)")
        }
        if winner.C < threshold { return nil }
        winner.trace.append("S=\(String(format: "%.2f", winner.S)) L=\(String(format: "%.2f", winner.L)) P=\(String(format: "%.2f", winner.P)) C=\(String(format: "%.2f", winner.C))")
        return V2Result(value: winner.value, confidence: round3(winner.C), trace: winner.trace)
    }

    /// App bridge: run the v2 detector on an `EmailMessage`, applying the age
    /// gate, and return a `DetectedCode` carrying the evidence trace.
    /// This is what the watcher calls.
    public static func extract(from message: EmailMessage, now: Date = Date(),
                               lex: Lexicon = lexiconEN) -> DetectedCode? {
        if now.timeIntervalSince(message.receivedAt) > maxAge { return nil }
        guard let r = detect(subject: message.subject, body: message.body,
                             isHTML: message.isHTML, lex: lex) else { return nil }
        return DetectedCode(
            code: r.value, confidence: r.confidence, account: message.account,
            sender: message.sender, subject: message.subject,
            messageID: message.id, receivedAt: message.receivedAt,
            evidenceTrace: r.trace
        )
    }


    static func stableSortByCDesc(_ xs: [Candidate]) -> [Candidate] {
        xs.enumerated().sorted {
            $0.element.C != $1.element.C ? $0.element.C > $1.element.C : $0.offset < $1.offset
        }.map { $0.element }
    }

    static func ipv4Groups(_ t: String) -> [Int]? {
        let ns = t as NSString
        guard let m = regex(#"(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})"#)
            .firstMatch(in: t, range: NSRange(location: 0, length: ns.length)),
              m.range.location == 0, m.range.length == ns.length else { return nil }
        var g: [Int] = []
        for i in 1...4 { g.append(Int(ns.substring(with: m.range(at: i))) ?? -1) }
        return g
    }

    static func countWords(_ s: String) -> Int {
        matchesOf(#"\w+"#, in: s).count
    }

    static func matchesOf(_ pattern: String, in s: String) -> [String] {
        let ns = s as NSString
        return regex(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }
}

extension String {
    var isASCIIString: Bool { allSatisfy { $0.isASCII } }
    func trimmingTrailingDots() -> String {
        var s = self
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

extension OTPv2 {
    static func isAsciiAlnum(_ t: String) -> Bool {
        !t.isEmpty && t.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    static func isAllASCIIDigits(_ t: String) -> Bool {
        !t.isEmpty && t.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
