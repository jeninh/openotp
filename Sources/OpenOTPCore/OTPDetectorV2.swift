import Foundation

// OTP Detection v2 — the OTP detector. Precision-first: it annotates the HTML
// into a render map (rather than flattening it), tokenizes with strict
// boundaries, removes non-code spans with evidence-gated claimers (URLs, IPs,
// dates, money, phones, identifiers, hashes), then scores what's left by
// structural salience × lexical binding × shape and decides conservatively.
// Offsets are UTF-16 (NSString-native for the regex passes).

public enum OTPv2 {

    static let maxAge: TimeInterval = 2 * 3600
    static let keywordRange = 60
    static let negativeRange = 20
    static let sFloor = 0.30
    static let lBoundGate = 0.50
    public static let sStructuralGate = 0.75
    public static let cThreshold = 0.60
    public static let cAmbiguous = 0.75
    public static let ambiguityMargin = 0.10

    // plain-text isolation-richness weights
    static let ptShortLineMax = 12
    static let ptBlankFlanked = 0.20
    static let ptShortLine = 0.10
    static let ptIndented = 0.10
    static let ptIsolationCap = 0.35

    public struct Lexicon {
        public var positive: [String]
        public var negative: [String]
        public var connectives: Set<String>
        public var absorbers: Set<String>
        public var idWords: Set<String>
    }

    public static let lexiconEN = Lexicon(
        positive: [
            "verification code", "security code", "one-time", "one time",
            "passcode", "password", "verification", "authentication", "verify",
            "code", "otp", "pin", "expires in", "valid for", "2fa",
        ],
        negative: ["order", "invoice", "total", "amount", "tracking", "receipt"],
        connectives: ["is", "was", "below", "following", "your", "the", "a",
                      "use", "enter", "here", "it", "this"],
        absorbers: ["ip", "address", "account", "phone", "number", "order",
                    "browser", "device", "location", "email", "username",
                    "attempt", "login"],
        idWords: ["order", "invoice", "ref", "reference", "ticket", "case",
                  "account", "user", "customer", "tracking", "id", "no",
                  "number", "item", "confirmation"]
    )

    static let months = ("january february march april may june july august "
        + "september october november december jan feb mar apr jun jul aug sep "
        + "sept oct nov dec").split(separator: " ").map(String.init)
}
