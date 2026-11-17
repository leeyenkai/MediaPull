import Foundation

/// Turns numbers from untrusted sources (engines, servers, page metadata) into integers without trapping.
/// `Int64(Double)` crashes on NaN, infinity and values beyond its range; these return nil instead, and
/// clamp to zero and a generous ceiling so a hostile `Content-Length` or `filesize` cannot overflow later sums.
public enum SafeNumber {
    /// 1 PB: larger than any real media file, small enough that sums of many never overflow Int64.
    public static let maxBytes: Int64 = 1 << 50

    /// A non-negative byte count, or nil when the value is not a finite number.
    public static func bytes(_ value: Double?) -> Int64? {
        guard let value, value.isFinite else { return nil }
        if value <= 0 { return 0 }
        if value >= Double(maxBytes) { return maxBytes }
        return Int64(value)
    }

    /// A finite double in `range`, or nil (durations, bitrates, frame rates).
    public static func finite(_ value: Double?, in range: ClosedRange<Double> = -1e15 ... 1e15) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// An integer in `range`, or nil when the value is not a finite number.
    public static func int(_ value: Double?, in range: ClosedRange<Int> = Int(Int32.min) ... Int(Int32.max)) -> Int? {
        guard let value, value.isFinite else { return nil }
        let clamped = min(max(value.rounded(.towardZero), Double(range.lowerBound)), Double(range.upperBound))
        return Int(clamped)
    }
}
