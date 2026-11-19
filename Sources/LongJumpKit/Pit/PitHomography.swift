import Foundation

public enum PitHomographyError: Error, Equatable, CustomStringConvertible {
    case tooFewPoints
    case degenerate

    public var description: String {
        switch self {
        case .tooFewPoints: return "pit calibration needs at least 4 points"
        case .degenerate: return "degenerate pit calibration (points collinear?)"
        }
    }
}

/// pit_homography.PitHomography: image points <-> pit world coordinates (metres, X along the pit,
/// Y across it).  The matrix reproduces `cv2.findHomography(src, dst, 0)` of OpenCV 4.13: float32
/// points, the normalised DLT of HomographyEstimatorCallback (Jacobi eigen solver) and, for more
/// than 4 points, 10 Levenberg-Marquardt iterations of HomographyRefineCallback.
public struct PitHomography: Sendable, Equatable {
    public let calibration: PitCalibration
    /// Row-major 3x3.
    public let matrix: [[Double]]
    public let rmsM: Double
    public let xRange: (Double, Double)

    private let flat: [Double]
    private let inverseFlat: [Double]

    public static func == (a: PitHomography, b: PitHomography) -> Bool {
        a.calibration == b.calibration && a.matrix == b.matrix && a.rmsM == b.rmsM
            && a.xRange.0 == b.xRange.0 && a.xRange.1 == b.xRange.1
    }

    public init(_ calibration: PitCalibration) throws {
        guard calibration.imagePoints.count >= 4, calibration.imagePoints.count == calibration.worldPoints.count else {
            throw PitHomographyError.tooFewPoints
        }
        self.calibration = calibration
        let src = calibration.imagePoints.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let dst = calibration.worldPoints.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        guard var h = OpenCVHomography.dlt(src, dst) else { throw PitHomographyError.degenerate }
        if src.count > 4 {
            OpenCVHomography.refine(&h, src, dst)
            let scale = OpenCVHomography.scaleFor(h[8])
            h = h.map { $0 * scale }
        }
        flat = h
        matrix = (0..<3).map { Array(h[($0 * 3)..<($0 * 3 + 3)]) }
        // np.linalg.inv(matrix) (LAPACK getrf/getrs with partial pivoting)
        guard let inverse = Self.invert3(h) else { throw PitHomographyError.degenerate }
        inverseFlat = inverse
        let world = calibration.worldPoints
        // Initialised below once self is usable.
        var rms = 0.0
        let projected = calibration.imagePoints.map { Self.transform($0, h) }
        let squares = zip(projected, world).map { p, w -> Double in
            let dx = p.x - w.x
            let dy = p.y - w.y
            return dx * dx + dy * dy
        }
        rms = NP.mean(squares).squareRoot()
        rmsM = rms
        xRange = (world.map(\.x).min()!, world.map(\.x).max()!)
    }

    /// cv2.perspectiveTransform (w = 1/w when |w| > FLT_EPSILON, else 0).
    static func transform(_ p: SIMD2<Double>, _ m: [Double]) -> SIMD2<Double> {
        let x = p.x * m[0] + p.y * m[1] + m[2]
        let y = p.x * m[3] + p.y * m[4] + m[5]
        var w = p.x * m[6] + p.y * m[7] + m[8]
        if Swift.abs(w) > Double(Float.ulpOfOne) {
            w = 1.0 / w
            return SIMD2(x * w, y * w)
        }
        return SIMD2(0, 0)
    }

    public func toWorld(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        points.map { Self.transform($0, flat) }
    }

    public func toWorld(_ point: SIMD2<Double>) -> SIMD2<Double> { Self.transform(point, flat) }

    public func toImage(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        points.map { Self.transform($0, inverseFlat) }
    }

    public func toImage(_ point: SIMD2<Double>) -> SIMD2<Double> { Self.transform(point, inverseFlat) }

    /// np.linalg.inv of a 3x3: LU with partial pivoting, solved against the identity.
    static func invert3(_ a: [Double]) -> [Double]? {
        let n = 3
        var lu = a
        var piv = [Int](repeating: 0, count: n)
        for k in 0..<n {
            var p = k
            var best = Swift.abs(lu[k * n + k])
            for i in (k + 1)..<n where Swift.abs(lu[i * n + k]) > best {
                best = Swift.abs(lu[i * n + k])
                p = i
            }
            piv[k] = p
            if lu[p * n + k] == 0 { return nil }
            if p != k { for j in 0..<n { lu.swapAt(k * n + j, p * n + j) } }
            for i in (k + 1)..<n {
                lu[i * n + k] /= lu[k * n + k]
                for j in (k + 1)..<n { lu[i * n + j] -= lu[i * n + k] * lu[k * n + j] }
            }
        }
        var inv = [Double](repeating: 0, count: n * n)
        for i in 0..<n { inv[i * n + i] = 1 }
        for k in 0..<n where piv[k] != k {
            for j in 0..<n { inv.swapAt(k * n + j, piv[k] * n + j) }
        }
        for c in 0..<n {
            for i in 0..<n {
                var s = inv[i * n + c]
                for k in 0..<i { s -= lu[i * n + k] * inv[k * n + c] }
                inv[i * n + c] = s
            }
            for i in stride(from: n - 1, through: 0, by: -1) {
                var s = inv[i * n + c]
                for k in (i + 1)..<n { s -= lu[i * n + k] * inv[k * n + c] }
                inv[i * n + c] = s / lu[i * n + i]
            }
        }
        return inv
    }
}

/// pit_homography.near_end_from_direction: world X of the pit end the athlete runs in from.
public func nearEndFromDirection(_ homography: PitHomography, runSide: Side) -> Double {
    PitHomography.nearEndFromDirection(homography, runSide: runSide)
}

extension PitHomography {
    public static func nearEndFromDirection(_ homography: PitHomography, runSide: Side) -> Double {
        let midY = NP.mean(homography.calibration.worldPoints.map(\.y))
        let ends = homography.toImage([
            SIMD2(homography.xRange.0, midY), SIMD2(homography.xRange.1, midY),
        ])
        let cameFromRight = runSide == .left
        let xs = [ends[0].x, ends[1].x]
        let index = cameFromRight ? NP.argmax(xs) : NP.argmin(xs)
        return index == 0 ? homography.xRange.0 : homography.xRange.1
    }
}

// MARK: - OpenCV port

enum OpenCVHomography {
    static func scaleFor(_ x: Double) -> Double {
        Swift.abs(x) > Double(Float.ulpOfOne) ? 1.0 / x : 1.0
    }

    /// HomographyEstimatorCallback::runKernel (method 0); nil when OpenCV returns 0.
    static func dlt(_ m1: [SIMD2<Float>], _ m2: [SIMD2<Float>]) -> [Double]? {
        let count = m1.count
        let M = m1
        let m = m2
        var cm = SIMD2<Double>(0, 0), cM = SIMD2<Double>(0, 0)
        var sm = SIMD2<Double>(0, 0), sM = SIMD2<Double>(0, 0)
        for i in 0..<count {
            cm.x += Double(m[i].x); cm.y += Double(m[i].y)
            cM.x += Double(M[i].x); cM.y += Double(M[i].y)
        }
        cm.x /= Double(count); cm.y /= Double(count)
        cM.x /= Double(count); cM.y /= Double(count)
        for i in 0..<count {
            sm.x += Swift.abs(Double(m[i].x) - cm.x)
            sm.y += Swift.abs(Double(m[i].y) - cm.y)
            sM.x += Swift.abs(Double(M[i].x) - cM.x)
            sM.y += Swift.abs(Double(M[i].y) - cM.y)
        }
        let eps = Double.ulpOfOne
        if Swift.abs(sm.x) < eps || Swift.abs(sm.y) < eps || Swift.abs(sM.x) < eps || Swift.abs(sM.y) < eps {
            return nil
        }
        let n = Double(count)
        sm.x = n / sm.x; sm.y = n / sm.y
        sM.x = n / sM.x; sM.y = n / sM.y

        let invHnorm: [Double] = [1.0 / sm.x, 0, cm.x, 0, 1.0 / sm.y, cm.y, 0, 0, 1]
        let Hnorm2: [Double] = [sM.x, 0, -cM.x * sM.x, 0, sM.y, -cM.y * sM.y, 0, 0, 1]

        var LtL = [Double](repeating: 0, count: 81)
        for i in 0..<count {
            let x = (Double(m[i].x) - cm.x) * sm.x
            let y = (Double(m[i].y) - cm.y) * sm.y
            let X = (Double(M[i].x) - cM.x) * sM.x
            let Y = (Double(M[i].y) - cM.y) * sM.y
            let Lx: [Double] = [X, Y, 1, 0, 0, 0, -x * X, -x * Y, -x]
            let Ly: [Double] = [0, 0, 0, X, Y, 1, -y * X, -y * Y, -y]
            for j in 0..<9 {
                for k in j..<9 { LtL[j * 9 + k] += Lx[j] * Lx[k] + Ly[j] * Ly[k] }
            }
        }
        for j in 0..<9 { for k in 0..<j { LtL[j * 9 + k] = LtL[k * 9 + j] } }  // completeSymm

        var w = [Double](repeating: 0, count: 9)
        var v = [Double](repeating: 0, count: 81)
        jacobi(&LtL, &w, &v, 9)
        let h0 = Array(v[72..<81])
        let htemp = matmul3(invHnorm, h0)
        let h = matmul3(htemp, Hnorm2)
        let scale = scaleFor(h[8])
        return h.map { $0 * scale }
    }

    // The 3x3 products and the gemm calls of LMSolver (J^T r, A d) run in OpenBLAS in the pip
    // wheels, whose kernels use fused multiply-add: with plain mul+add the LM lands on a different
    // point of its flat valley (8.6e-8 off in H[2][0]); with fma it matches to ~4e-13.
    static func matmul3(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s = fma(a[i * 3 + k], b[k * 3 + j], s) }
                out[i * 3 + j] = s
            }
        }
        return out
    }

    private static func hypotCV(_ a0: Double, _ b0: Double) -> Double {
        var a = Swift.abs(a0)
        var b = Swift.abs(b0)
        if a > b {
            b /= a
            return a * (1 + b * b).squareRoot()
        }
        if b > 0 {
            a /= b
            return b * (1 + a * a).squareRoot()
        }
        return 0
    }

    /// cv::JacobiImpl_ for symmetric A (n x n row-major, destroyed); eigenvectors are the rows of
    /// V, eigenvalues W sorted descending.
    static func jacobi(_ A: inout [Double], _ W: inout [Double], _ V: inout [Double], _ n: Int) {
        let eps = Double.ulpOfOne
        let astep = n
        for i in 0..<n {
            for j in 0..<n { V[i * n + j] = 0 }
            V[i * n + i] = 1
        }
        let maxIters = n * n * 30
        var indR = [Int](repeating: 0, count: n)
        var indC = [Int](repeating: 0, count: n)
        var mv = 0.0
        for k in 0..<n {
            W[k] = A[(astep + 1) * k]
            if k < n - 1 {
                var m = k + 1
                mv = Swift.abs(A[astep * k + m])
                var i = k + 2
                while i < n {
                    let val = Swift.abs(A[astep * k + i])
                    if mv < val { mv = val; m = i }
                    i += 1
                }
                indR[k] = m
            }
            if k > 0 {
                var m = 0
                mv = Swift.abs(A[k])
                var i = 1
                while i < k {
                    let val = Swift.abs(A[astep * i + k])
                    if mv < val { mv = val; m = i }
                    i += 1
                }
                indC[k] = m
            }
        }
        if n > 1 {
            for _ in 0..<maxIters {
                var k = 0
                mv = Swift.abs(A[indR[0]])
                var i = 1
                while i < n - 1 {
                    let val = Swift.abs(A[astep * i + indR[i]])
                    if mv < val { mv = val; k = i }
                    i += 1
                }
                var l = indR[k]
                i = 1
                while i < n {
                    let val = Swift.abs(A[astep * indC[i] + i])
                    if mv < val { mv = val; k = indC[i]; l = i }
                    i += 1
                }
                let p = A[astep * k + l]
                if Swift.abs(p) <= eps { break }
                let y = (W[l] - W[k]) * 0.5
                var t = Swift.abs(y) + hypotCV(p, y)
                var s = hypotCV(p, t)
                let c = t / s
                s = p / s
                t = (p / t) * p
                if y < 0 { s = -s; t = -t }
                A[astep * k + l] = 0
                W[k] -= t
                W[l] += t

                @inline(__always) func rotate(_ i0: Int, _ i1: Int, _ arr: inout [Double]) {
                    let a0 = arr[i0], b0 = arr[i1]
                    arr[i0] = a0 * c - b0 * s
                    arr[i1] = a0 * s + b0 * c
                }
                for i in 0..<k { rotate(astep * i + k, astep * i + l, &A) }
                if k + 1 < l { for i in (k + 1)..<l { rotate(astep * k + i, astep * i + l, &A) } }
                if l + 1 < n { for i in (l + 1)..<n { rotate(astep * k + i, astep * l + i, &A) } }
                for i in 0..<n { rotate(n * k + i, n * l + i, &V) }

                for j in 0..<2 {
                    let idx = j == 0 ? k : l
                    if idx < n - 1 {
                        var m = idx + 1
                        mv = Swift.abs(A[astep * idx + m])
                        var i = idx + 2
                        while i < n {
                            let val = Swift.abs(A[astep * idx + i])
                            if mv < val { mv = val; m = i }
                            i += 1
                        }
                        indR[idx] = m
                    }
                    if idx > 0 {
                        var m = 0
                        mv = Swift.abs(A[idx])
                        var i = 1
                        while i < idx {
                            let val = Swift.abs(A[astep * i + idx])
                            if mv < val { mv = val; m = i }
                            i += 1
                        }
                        indC[idx] = m
                    }
                }
            }
        }
        for k in 0..<(n - 1) {
            var m = k
            for i in (k + 1)..<n where W[m] < W[i] { m = i }
            if k != m {
                W.swapAt(m, k)
                for i in 0..<n { V.swapAt(n * m + i, n * k + i) }
            }
        }
    }

    /// solve(A, b, x, DECOMP_EIG) for a symmetric n x n A (Jacobi + SVBkSb).
    static func solveEig(_ A: [Double], _ b: [Double], _ n: Int) -> [Double] {
        var a = A
        var w = [Double](repeating: 0, count: n)
        var v = [Double](repeating: 0, count: n * n)
        jacobi(&a, &w, &v, n)
        var threshold = 0.0
        for i in 0..<n { threshold += w[i] }
        threshold *= Double.ulpOfOne * 2
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var wi = w[i]
            if Swift.abs(wi) <= threshold { continue }
            wi = 1 / wi
            var s = 0.0
            for j in 0..<n { s += v[i * n + j] * b[j] }
            s *= wi
            for j in 0..<n { x[j] = x[j] + s * v[i * n + j] }
        }
        return x
    }

    /// invert(A, DECOMP_EIG): pseudo-inverse via the Jacobi eigen decomposition.
    static func invertEig(_ A: [Double], _ n: Int) -> [Double] {
        var a = A
        var w = [Double](repeating: 0, count: n)
        var v = [Double](repeating: 0, count: n * n)
        jacobi(&a, &w, &v, n)
        var threshold = 0.0
        for i in 0..<n { threshold += w[i] }
        threshold *= Double.ulpOfOne * 2
        var x = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            var wi = w[i]
            if Swift.abs(wi) <= threshold { continue }
            wi = 1 / wi
            var buffer = [Double](repeating: 0, count: n)
            for j in 0..<n { buffer[j] = v[i * n + j] * wi }
            for k in 0..<n {
                let s = v[i * n + k]
                for j in 0..<n { x[k * n + j] = x[k * n + j] + s * buffer[j] }
            }
        }
        return x
    }

    /// HomographyRefineCallback::compute.
    static func residual(_ h: [Double], _ src: [SIMD2<Float>], _ dst: [SIMD2<Float>], jacobian: Bool)
        -> (r: [Double], J: [Double])
    {
        let count = src.count
        var err = [Double](repeating: 0, count: count * 2)
        var J = [Double](repeating: 0, count: jacobian ? count * 18 : 0)
        for i in 0..<count {
            let Mx = Double(src[i].x), My = Double(src[i].y)
            var ww = h[6] * Mx + h[7] * My + h[8]
            ww = Swift.abs(ww) > Double.ulpOfOne ? 1.0 / ww : 0
            let xi = (h[0] * Mx + h[1] * My + h[2]) * ww
            let yi = (h[3] * Mx + h[4] * My + h[5]) * ww
            err[i * 2] = xi - Double(dst[i].x)
            err[i * 2 + 1] = yi - Double(dst[i].y)
            if jacobian {
                let o = i * 18
                J[o + 0] = Mx * ww; J[o + 1] = My * ww; J[o + 2] = ww
                J[o + 6] = -Mx * ww * xi; J[o + 7] = -My * ww * xi; J[o + 8] = -ww * xi
                J[o + 12] = Mx * ww; J[o + 13] = My * ww; J[o + 14] = ww
                J[o + 15] = -Mx * ww * yi; J[o + 16] = -My * ww * yi; J[o + 17] = -ww * yi
            }
        }
        return (err, J)
    }

    private static func normalMatrix(_ J: [Double], rows: Int) -> (A: [Double], v: (([Double]) -> [Double])) {
        var A = [Double](repeating: 0, count: 81)
        for i in 0..<9 {
            for j in i..<9 {
                var s = 0.0
                for k in 0..<rows { s += J[k * 9 + i] * J[k * 9 + j] }
                A[i * 9 + j] = s
                A[j * 9 + i] = s
            }
        }
        return (A, { r in
            (0..<9).map { i in
                var s = 0.0
                for k in 0..<rows { s = fma(J[k * 9 + i], r[k], s) }
                return s
            }
        })
    }

    /// LMSolver::create(HomographyRefineCallback, 10)->run(h) (LMSolverImpl::run).
    static func refine(_ h: inout [Double], _ src: [SIMD2<Float>], _ dst: [SIMD2<Float>]) {
        let epsx = Double(Float.ulpOfOne), epsf = Double(Float.ulpOfOne)
        let maxIters = 10
        let lx = 9
        var x = h
        var (r, J) = residual(x, src, dst, jacobian: true)
        var S = r.reduce(0) { $0 + $1 * $1 }
        let rows = r.count
        var (A, vOf) = normalMatrix(J, rows: rows)
        var v = vOf(r)
        let D = (0..<lx).map { A[$0 * lx + $0] }
        let Rlo = 0.25, Rhi = 0.75
        var lambda = 1.0, lc = 0.75
        var iter = 0
        while true {
            var Ap = A
            for i in 0..<lx { Ap[i * lx + i] += lambda * D[i] }
            let d = solveEig(Ap, v, lx)
            let xd = (0..<lx).map { x[$0] - d[$0] }
            let rd = residual(xd, src, dst, jacobian: false).r
            let Sd = rd.reduce(0) { $0 + $1 * $1 }
            // temp_d = -A d + 2 v
            var tempD = [Double](repeating: 0, count: lx)
            for i in 0..<lx {
                var s = 0.0
                for j in 0..<lx { s = fma(A[i * lx + j], d[j], s) }
                tempD[i] = -s + 2 * v[i]
            }
            var dS = 0.0
            for i in 0..<lx { dS += d[i] * tempD[i] }
            let R = (S - Sd) / (Swift.abs(dS) > Double.ulpOfOne ? dS : 1)
            if R > Rhi {
                lambda *= 0.5
                if lambda < lc { lambda = 0 }
            } else if R < Rlo {
                var t = 0.0
                for i in 0..<lx { t += d[i] * v[i] }
                var nu = (Sd - S) / (Swift.abs(t) > Double.ulpOfOne ? t : 1) + 2
                nu = Swift.min(Swift.max(nu, 2), 10)
                if lambda == 0 {
                    let inverse = invertEig(A, lx)
                    var maxval = Double.ulpOfOne
                    for i in 0..<lx { maxval = Swift.max(maxval, Swift.abs(inverse[i * lx + i])) }
                    lambda = 1 / maxval
                    lc = lambda
                    nu *= 0.5
                }
                lambda *= nu
            }
            if Sd < S {
                S = Sd
                x = xd
                (r, J) = residual(x, src, dst, jacobian: true)
                (A, vOf) = normalMatrix(J, rows: rows)
                v = vOf(r)
            }
            iter += 1
            let dInf = d.reduce(0) { Swift.max($0, Swift.abs($1)) }
            let rInf = r.reduce(0) { Swift.max($0, Swift.abs($1)) }
            if !(iter < maxIters && dInf >= epsx && rInf >= epsf) { break }
        }
        h = x
    }
}
