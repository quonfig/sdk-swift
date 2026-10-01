import Foundation

/// The largest duration Quonfig accepts: `P36500D` (100 years), in milliseconds.
let maxDurationMillis: Int64 = 36_500 * 86_400_000

/// Parse a Quonfig ISO-8601 duration into an integer millisecond count, or `nil`
/// if the string is outside the grammar (qfg-2agi.14).
///
/// The grammar is the shared fixture `integration-test-data/tests/duration/grammar.yaml`
/// (qfg-2agi.29):
///
///     ^P(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$
///
/// plus: at least one component; no dangling `T`; a fraction only on `S`, at most
/// 9 fractional digits; total magnitude <= `P36500D`. Digits are ASCII `0`-`9`
/// only and the match is the whole string (no trailing newline, no non-ASCII
/// digits), which is why this is a hand-written scanner over UTF-8 bytes rather
/// than a regex. Millis use exact integer arithmetic, rounded half up.
func parseISODurationMillis(_ s: String) -> Int64? {
    let bytes = Array(s.utf8)
    var i = 0

    func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

    /// Read one or more ASCII digits as a non-negative integer; `nil` if there
    /// are none or the value overflows Int64 (which is far over the ceiling).
    func readInt() -> Int64? {
        let start = i
        var n: Int64 = 0
        var overflow = false
        while i < bytes.count, isDigit(bytes[i]) {
            if !overflow {
                let (m, o1) = n.multipliedReportingOverflow(by: 10)
                let (a, o2) = m.addingReportingOverflow(Int64(bytes[i] - 0x30))
                overflow = o1 || o2
                n = a
            }
            i += 1
        }
        if i == start || overflow { return nil }
        return n
    }

    /// Add `value * unitMillis` to `total`, failing on overflow.
    func add(_ total: inout Int64, _ value: Int64, _ unitMillis: Int64) -> Bool {
        let (m, o1) = value.multipliedReportingOverflow(by: unitMillis)
        let (a, o2) = total.addingReportingOverflow(m)
        if o1 || o2 { return false }
        total = a
        return true
    }

    guard i < bytes.count, bytes[i] == UInt8(ascii: "P") else { return nil }
    i += 1

    var total: Int64 = 0
    var fractionNanos: Int64 = 0
    var components = 0

    // Optional days: \d+D
    if i < bytes.count, isDigit(bytes[i]) {
        guard let d = readInt(), i < bytes.count, bytes[i] == UInt8(ascii: "D") else { return nil }
        i += 1
        guard add(&total, d, 86_400_000) else { return nil }
        components += 1
    }

    // Optional time part: T(\d+H)?(\d+M)?(\d+(\.\d+)?S)? with at least one.
    if i < bytes.count, bytes[i] == UInt8(ascii: "T") {
        i += 1
        var timeComponents = 0
        // Each designator may appear at most once and only in H, M, S order.
        var nextAllowed = 0  // 0 = H, 1 = M, 2 = S, 3 = none
        while i < bytes.count {
            guard let n = readInt() else { return nil }
            guard i < bytes.count else { return nil }
            var fraction: [UInt8] = []
            if bytes[i] == UInt8(ascii: ".") {
                i += 1
                while i < bytes.count, isDigit(bytes[i]) {
                    fraction.append(bytes[i])
                    i += 1
                }
                guard !fraction.isEmpty, fraction.count <= 9 else { return nil }
                guard i < bytes.count, bytes[i] == UInt8(ascii: "S") else { return nil }
            }
            switch bytes[i] {
            case UInt8(ascii: "H") where nextAllowed <= 0:
                guard add(&total, n, 3_600_000) else { return nil }
                nextAllowed = 1
            case UInt8(ascii: "M") where nextAllowed <= 1:
                guard add(&total, n, 60_000) else { return nil }
                nextAllowed = 2
            case UInt8(ascii: "S") where nextAllowed <= 2:
                guard add(&total, n, 1_000) else { return nil }
                var nanos: Int64 = 0
                for k in 0..<9 {
                    nanos = nanos * 10 + (k < fraction.count ? Int64(fraction[k] - 0x30) : 0)
                }
                fractionNanos = nanos
                nextAllowed = 3
            default:
                return nil
            }
            i += 1
            timeComponents += 1
        }
        guard timeComponents > 0 else { return nil }  // dangling T
        components += timeComponents
    }

    guard i == bytes.count, components > 0 else { return nil }

    // Magnitude ceiling, checked on the exact value before rounding.
    if total > maxDurationMillis || (total == maxDurationMillis && fractionNanos > 0) { return nil }

    // Sub-millisecond fraction, rounded half up.
    let fractionMillis = (fractionNanos + 500_000) / 1_000_000
    return total + fractionMillis
}
