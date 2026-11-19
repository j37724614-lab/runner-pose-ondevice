import Foundation

/// Python's two `round` behaviours, as the server's long-jump code uses them.
///
/// - `round(x, n)` on a Python float is correctly rounded: the exact binary value is rounded to
///   n decimals, ties to even (`round(2.675, 2) == 2.67`).
/// - `round(np.float64(x), n)` uses numpy's algorithm: `rint(x * 10**n) / 10**n`.
/// - `round(x)` without digits returns the nearest integer, ties to even.
///
/// In the result documents the difference is at most one unit in the last kept digit and only
/// for values within ~1e-12 of a tie; the parity tests compare rounded fields with that
/// tolerance.  Fixtures: Tests/LongJumpKitTests/Fixtures/unit/numerics.json ("round").
public enum PyRound {

    /// `round(x, digits)` on a Python float.
    public static func python(_ x: Double, _ digits: Int) -> Double {
        guard x.isFinite else { return x }
        // printf rounds the exact binary value, ties to even, like CPython's float round.
        let text = String(format: "%.\(Swift.max(0, digits))f", x)
        let value = Double(text) ?? x
        return value == 0 ? (x.sign == .minus ? -0.0 : 0.0) : value
    }

    /// `round(np.float64(x), digits)`: numpy's multiply / round-half-even / divide.
    public static func numpy(_ x: Double, _ digits: Int) -> Double {
        guard x.isFinite else { return x }
        if digits >= 0 {
            let scale = pow(10.0, Double(digits))
            return (x * scale).rounded(.toNearestOrEven) / scale
        }
        let scale = pow(10.0, Double(-digits))
        return (x / scale).rounded(.toNearestOrEven) * scale
    }

    /// `round(x)` (no digits): nearest integer, ties to even.
    public static func toInt(_ x: Double) -> Int {
        Int(x.rounded(.toNearestOrEven))
    }
}
