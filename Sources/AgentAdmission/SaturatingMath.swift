/// Non-trapping arithmetic for every number that can be reached through the public API.
///
/// Time is carried as `Int64` milliseconds everywhere (not `Int`, which is 32-bit on watchOS),
/// so all the helpers below operate on `Int64` and clamp instead of trapping.
public enum Saturating {
    @inlinable
    public static func add(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.addingReportingOverflow(b)
        guard o else { return r }
        return b > 0 ? .max : .min
    }

    @inlinable
    public static func subtract(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.subtractingReportingOverflow(b)
        guard o else { return r }
        return b > 0 ? .min : .max
    }

    @inlinable
    public static func multiply(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, o) = a.multipliedReportingOverflow(by: b)
        guard o else { return r }
        return (a < 0) == (b < 0) ? .max : .min
    }

    /// Division that never traps: `x / 0` returns `nil`, and `Int64.min / -1` saturates to `.max`.
    @inlinable
    public static func divide(_ a: Int64, _ b: Int64) -> Int64? {
        guard b != 0 else { return nil }
        let (r, o) = a.dividedReportingOverflow(by: b)
        return o ? .max : r
    }

    /// Ceiling division for non-negative operands; `nil` when `b <= 0`.
    @inlinable
    public static func ceilDivide(_ a: Int64, _ b: Int64) -> Int64? {
        guard b > 0 else { return nil }
        guard a > 0 else { return 0 }
        // a > 0 and b > 0, so neither the subtraction nor the division can overflow.
        return (a - 1) / b + 1
    }

    /// `Int64(Double)` traps on NaN, ±infinity and out-of-range values. This clamps instead;
    /// NaN maps to `fallback`.
    @inlinable
    public static func int64(_ value: Double, fallback: Int64 = 0) -> Int64 {
        guard !value.isNaN else { return fallback }
        // 2^63 is exactly representable as a Double; anything >= it is out of range.
        if value >= 9_223_372_036_854_775_808.0 { return .max }
        if value < -9_223_372_036_854_775_808.0 { return .min }
        return Int64(value)
    }

    /// `Int(Int64)` traps when `Int` is 32-bit. Clamps to the platform `Int` range instead.
    @inlinable
    public static func int(_ value: Int64) -> Int {
        if value > Int64(Int.max) { return .max }
        if value < Int64(Int.min) { return .min }
        return Int(value)
    }

    @inlinable
    public static func clamp(_ value: Int64, _ lower: Int64, _ upper: Int64) -> Int64 {
        guard lower <= upper else { return lower }
        return min(max(value, lower), upper)
    }
}
