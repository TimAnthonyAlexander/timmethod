import CoreGraphics
import Foundation

/// Direct least-squares ellipse fitting on a cloud of 2-D points (SPEC §8).
///
/// A plate viewed off-axis projects to an ellipse, not a circle, and its
/// **major axis** is the true diameter, rotation-invariant regardless of
/// camera angle — that's the entire reason Track A works from a phone held
/// anywhere in front of a lift instead of demanding a perpendicular tripod
/// shot. Fitting a *circle* instead would throw that away and bias the
/// recovered scale low the moment the lifter isn't framed dead-on.
///
/// ## Method
///
/// This is Halir & Flusser's reformulation ("Numerically Stable Direct
/// Least Squares Fitting of Ellipses", 1998) of Fitzgibbon, Pilu & Fisher's
/// direct ellipse-specific fit ("Direct Least Square Fitting of Ellipses",
/// 1996). Both minimize the algebraic residual of a general conic
/// `A x^2 + Bxy + Cy^2 + Dx + Ey + F = 0` over all input points, subject to
/// the constraint `4AC - B^2 = 1`, which is what forces the result to
/// always *be* an ellipse (never a hyperbola or parabola) rather than
/// fitting a generic conic and hoping. Fitzgibbon's original formulation
/// poses this as a 6x6 generalized eigenvalue problem; Halir & Flusser
/// split the design matrix into its quadratic and linear parts and reduce
/// that down to eigen-decomposing a single 3x3 matrix, which is both
/// cheaper and better conditioned. That reduction — `S1`/`S2`/`S3` below —
/// is exactly their algorithm, not an original derivation.
///
/// ## The eigenproblem
///
/// The reduced 3x3 matrix (`reducedSystemMatrix` below) is in general
/// **not symmetric**, so this can't just reuse a closed-form symmetric
/// 2x2/3x3 eigensolver. It's solved here with a plain cubic characteristic
/// polynomial (closed-form real-root solver, `realCubicRoots`) followed by
/// a null-space extraction per real root (`nullVector`, via the largest
/// cross product of two rows — the standard trick for a rank-2 3x3). No
/// Accelerate/LAPACK: a 3x3 eigenproblem is small enough that a page of
/// closed-form linear algebra is both simpler to audit and to unit-test
/// than marshaling into `dgeev_`, and it keeps this file free of C
/// interop. (Task guidance allows leaning on Accelerate/LAPACK here; this
/// implementation doesn't need to.)
///
/// ## Numerical conditioning
///
/// Points are recentred on their centroid and rescaled to unit average
/// radius before fitting (`fit(points:)`), because plate contours live at
/// pixel coordinates in the hundreds, and an unnormalized design matrix
/// mixes `x^2` terms (~1e5) with the constant `1` column — catastrophically
/// ill-conditioned. The recovered conic is transformed back to the caller's
/// original coordinate frame before any ellipse parameters are extracted,
/// so normalization is entirely invisible to callers.
public enum EllipseFit {
    /// A fitted ellipse, in the same coordinate frame as the input points.
    public struct Ellipse: Sendable, Equatable {
        /// Ellipse centre.
        public let center: CGPoint
        /// Full major axis length (i.e. `2 * semiMajorAxis`), same units
        /// as the input points.
        public let majorAxis: Double
        /// Full minor axis length.
        public let minorAxis: Double
        /// Major axis direction, radians from the positive x-axis toward
        /// positive y, wrapped to `[0, .pi)` — a line has no intrinsic
        /// forward end, so 0 and `.pi` are deliberately identified.
        public let orientation: Double
        /// RMS gradient-weighted algebraic distance from the input points
        /// to the fitted conic, divided by `majorAxis`. Dimensionless,
        /// `>= 0`, smaller is a tighter fit. This is the input
        /// `PlateDetector.confidence` derives from — it is not itself a
        /// 0...1 confidence.
        public let normalizedResidual: Double
    }

    /// Fewer than this many points can't meaningfully over-determine a
    /// 5-degree-of-freedom ellipse (6 conic coefficients minus 1 for the
    /// scale-free homogeneous system); this floor keeps real margin above
    /// the bare minimum of 5 so the fit is a genuine least-squares
    /// solution rather than an exact interpolation of noise.
    private static let minimumPoints = 8

    /// Below this normalized spread, points are too close together (or
    /// coincident) to fix a conic's shape rather than just its rough
    /// location — normalizing by a near-zero scale would blow up every
    /// downstream coefficient.
    private static let minimumNormalizationScale = 1e-6

    /// Fits an ellipse to `points` via the constrained direct least-squares
    /// method described in the type documentation.
    ///
    /// Returns `nil` — never a fabricated or wild conic — when: there are
    /// fewer than `minimumPoints` points; the points are degenerate
    /// (coincident or collinear, so no ellipse shape is determined); the
    /// reduced eigenproblem has no real eigenvector satisfying the ellipse
    /// constraint `4AC - B^2 > 0`; or the resulting axes are non-finite or
    /// non-positive. This is "refuse rather than guess" applied to the
    /// maths layer, one level below `PlateDetector`'s own refusal for
    /// implausible geometry.
    public static func fit(points: [CGPoint]) -> Ellipse? {
        guard points.count >= minimumPoints else { return nil }

        // --- Normalize: centre on centroid, scale to unit mean radius. ---
        let n = Double(points.count)
        let meanX = points.reduce(0.0) { $0 + Double($1.x) } / n
        let meanY = points.reduce(0.0) { $0 + Double($1.y) } / n
        let meanRadius =
            points.reduce(0.0) { $0 + hypot(Double($1.x) - meanX, Double($1.y) - meanY) } / n
        guard meanRadius.isFinite, meanRadius >= minimumNormalizationScale else { return nil }

        let normalized = points.map { point in
            (x: (Double(point.x) - meanX) / meanRadius, y: (Double(point.y) - meanY) / meanRadius)
        }

        // --- Design matrix split: D1 = [x^2, xy, y^2], D2 = [x, y, 1]. ---
        var s1 = Matrix3.zero  // D1^T D1
        var s2 = Matrix3.zero  // D1^T D2
        var s3 = Matrix3.zero  // D2^T D2
        for p in normalized {
            let d1: Vector3 = Vector3(p.x * p.x, p.x * p.y, p.y * p.y)
            let d2: Vector3 = Vector3(p.x, p.y, 1)
            s1.addOuterProduct(d1, d1)
            s2.addOuterProduct(d1, d2)
            s3.addOuterProduct(d2, d2)
        }

        guard let s3Inverse = s3.inverse() else { return nil }

        // T maps a1 (quadratic part) to a2 (linear part): a2 = T a1.
        let t = s3Inverse.multiplied(by: -1).multiplying(s2.transposed())
        // Reduced quadratic-part system before applying the ellipse
        // constraint's inverse.
        let m = s1.adding(s2.multiplying(t))
        // C1^{-1} for constraint matrix C1 = [[0,0,2],[0,-1,0],[2,0,0]]:
        // inv(C1) = [[0,0,0.5],[0,-1,0],[0.5,0,0]] (verified by direct
        // multiplication; C1 is its own near-involution up to that halving).
        let c1Inverse = Matrix3(
            row0: Vector3(0, 0, 0.5),
            row1: Vector3(0, -1, 0),
            row2: Vector3(0.5, 0, 0)
        )
        let reducedSystemMatrix = c1Inverse.multiplying(m)

        // --- Solve the 3x3 eigenproblem; pick the ellipse-constrained root. ---
        var quadraticPart: Vector3?
        for (_, vector) in realEigenpairs(of: reducedSystemMatrix) {
            let a = vector.x
            let b = vector.y
            let c = vector.z
            // The ellipse constraint the whole method is built around:
            // 4AC - B^2 = 1 up to the eigenvector's free scale, so > 0 is
            // the sign test that survives the scale ambiguity.
            if 4 * a * c - b * b > 0 {
                quadraticPart = vector
                break
            }
        }
        guard let quadraticPart else { return nil }

        let linearPart = t.applying(to: quadraticPart)

        // Conic coefficients in normalized coordinates.
        let (a, b, c) = (quadraticPart.x, quadraticPart.y, quadraticPart.z)
        let (d, e, f) = (linearPart.x, linearPart.y, linearPart.z)

        // --- Un-normalize back to the caller's coordinate frame. ---
        // u = (x - meanX)/s, v = (y - meanY)/s; substitute and multiply
        // through by s^2 (see type documentation for the full expansion).
        let s = meanRadius
        let bigA = a
        let bigB = b
        let bigC = c
        let bigD = -2 * a * meanX - b * meanY + d * s
        let bigE = -b * meanX - 2 * c * meanY + e * s
        let bigF =
            a * meanX * meanX + b * meanX * meanY + c * meanY * meanY
            - d * s * meanX - e * s * meanY + f * s * s

        guard
            let ellipse = ellipseParameters(a: bigA, b: bigB, c: bigC, d: bigD, e: bigE, f: bigF)
        else { return nil }

        let residual = normalizedResidual(
            points: points, a: bigA, b: bigB, c: bigC, d: bigD, e: bigE, f: bigF,
            majorAxis: ellipse.majorAxis
        )
        guard residual.isFinite else { return nil }

        return Ellipse(
            center: ellipse.center,
            majorAxis: ellipse.majorAxis,
            minorAxis: ellipse.minorAxis,
            orientation: ellipse.orientation,
            normalizedResidual: residual
        )
    }

    // MARK: - Conic → ellipse parameters

    /// Extracts centre, full axis lengths and orientation from a general
    /// conic `A x^2 + Bxy + Cy^2 + Dx + Ey + F = 0`. Returns `nil` if the
    /// conic isn't a real, non-degenerate ellipse (axes non-finite,
    /// non-positive, or the conic is a degenerate point/line).
    ///
    /// Derivation: translate to the conic's centre (found by solving the
    /// gradient-zero equations), which reduces the equation to
    /// `A u^2 + Buv + Cv^2 + F0 = 0` in centred coordinates `(u,v)`, where
    /// `F0` is the conic evaluated at the centre. Diagonalizing the
    /// symmetric quadratic-form matrix `[[A, B/2], [B/2, C]]` (closed-form
    /// 2x2 eigen-decomposition, always real since the matrix is symmetric)
    /// gives principal-axis eigenvalues `λ1, λ2` and their directions;
    /// each semi-axis length is `sqrt(-F0 / λi)`.
    private static func ellipseParameters(
        a: Double, b: Double, c: Double, d: Double, e: Double, f: Double
    ) -> (center: CGPoint, majorAxis: Double, minorAxis: Double, orientation: Double)? {
        let determinant = 4 * a * c - b * b
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }

        let centerX = (b * e - 2 * c * d) / determinant
        let centerY = (b * d - 2 * a * e) / determinant
        guard centerX.isFinite, centerY.isFinite else { return nil }

        let f0 = a * centerX * centerX + b * centerX * centerY + c * centerY * centerY + d * centerX + e * centerY + f
        guard f0.isFinite, f0 != 0 else { return nil }

        let mean = (a + c) / 2
        let diff = (a - c) / 2
        let radius = (diff * diff + (b / 2) * (b / 2)).squareRoot()
        let lambda1 = mean + radius  // eigenvalue whose eigenvector direction is `theta` below
        let lambda2 = mean - radius

        guard lambda1.isFinite, lambda2.isFinite else { return nil }

        let theta = 0.5 * atan2(b, a - c)

        let axis1Squared = -f0 / lambda1
        let axis2Squared = -f0 / lambda2
        guard
            axis1Squared.isFinite, axis1Squared > 0,
            axis2Squared.isFinite, axis2Squared > 0
        else { return nil }

        let axis1 = 2 * axis1Squared.squareRoot()
        let axis2 = 2 * axis2Squared.squareRoot()

        let majorAxis: Double
        let minorAxis: Double
        var orientation: Double
        if axis1 >= axis2 {
            majorAxis = axis1
            minorAxis = axis2
            orientation = theta
        } else {
            majorAxis = axis2
            minorAxis = axis1
            orientation = theta + .pi / 2
        }

        // Wrap to [0, .pi): a line direction, not a vector.
        orientation = orientation.truncatingRemainder(dividingBy: .pi)
        if orientation < 0 { orientation += .pi }

        guard majorAxis.isFinite, minorAxis.isFinite, majorAxis > 0, minorAxis > 0 else { return nil }

        return (CGPoint(x: centerX, y: centerY), majorAxis, minorAxis, orientation)
    }

    /// RMS of the gradient-weighted algebraic distance
    /// (`|G(x,y)| / |∇G(x,y)|`, Taubin's approximation to true geometric
    /// point-to-conic distance) across `points`, normalized by
    /// `majorAxis` so the result is a dimensionless "fraction of the plate's
    /// diameter" figure, comparable across differently-scaled detections.
    private static func normalizedResidual(
        points: [CGPoint], a: Double, b: Double, c: Double, d: Double, e: Double, f: Double,
        majorAxis: Double
    ) -> Double {
        guard majorAxis.isFinite, majorAxis > 0 else { return .infinity }
        var sumSquared = 0.0
        var counted = 0
        for point in points {
            let x = Double(point.x)
            let y = Double(point.y)
            let g = a * x * x + b * x * y + c * y * y + d * x + e * y + f
            let gx = 2 * a * x + b * y + d
            let gy = b * x + 2 * c * y + e
            let gradientMagnitude = (gx * gx + gy * gy).squareRoot()
            guard gradientMagnitude > 1e-9 else { continue }
            let distance = abs(g) / gradientMagnitude
            sumSquared += distance * distance
            counted += 1
        }
        guard counted > 0 else { return .infinity }
        let rms = (sumSquared / Double(counted)).squareRoot()
        return rms / majorAxis
    }

    // MARK: - 3x3 linear algebra

    /// A plain 3-vector. Not `SIMD3<Double>` on purpose: this file's
    /// arithmetic is a handful of scalar ops per fit, not a hot loop, and a
    /// bespoke type keeps every operation's meaning explicit at the call
    /// site instead of reaching for generic vector algebra.
    private struct Vector3 {
        var x: Double
        var y: Double
        var z: Double

        init(_ x: Double, _ y: Double, _ z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    /// A 3x3 matrix stored row-major. Only the operations this fit actually
    /// needs: zero, outer product accumulation, transpose, multiply
    /// (by scalar, by matrix, by vector), add, and inverse.
    private struct Matrix3 {
        var rows: [Vector3]  // rows[i] = (m_i0, m_i1, m_i2)

        static let zero = Matrix3(
            row0: Vector3(0, 0, 0), row1: Vector3(0, 0, 0), row2: Vector3(0, 0, 0)
        )

        init(row0: Vector3, row1: Vector3, row2: Vector3) {
            rows = [row0, row1, row2]
        }

        subscript(_ r: Int, _ col: Int) -> Double {
            get {
                switch col {
                case 0: rows[r].x
                case 1: rows[r].y
                default: rows[r].z
                }
            }
            set {
                switch col {
                case 0: rows[r].x = newValue
                case 1: rows[r].y = newValue
                default: rows[r].z = newValue
                }
            }
        }

        /// Adds `u v^T` (outer product) into `self` in place — the
        /// accumulation pattern `S1`/`S2`/`S3` are built with, one point's
        /// contribution at a time.
        mutating func addOuterProduct(_ u: Vector3, _ v: Vector3) {
            self[0, 0] += u.x * v.x
            self[0, 1] += u.x * v.y
            self[0, 2] += u.x * v.z
            self[1, 0] += u.y * v.x
            self[1, 1] += u.y * v.y
            self[1, 2] += u.y * v.z
            self[2, 0] += u.z * v.x
            self[2, 1] += u.z * v.y
            self[2, 2] += u.z * v.z
        }

        func transposed() -> Matrix3 {
            Matrix3(
                row0: Vector3(self[0, 0], self[1, 0], self[2, 0]),
                row1: Vector3(self[0, 1], self[1, 1], self[2, 1]),
                row2: Vector3(self[0, 2], self[1, 2], self[2, 2])
            )
        }

        func multiplied(by scalar: Double) -> Matrix3 {
            Matrix3(
                row0: Vector3(rows[0].x * scalar, rows[0].y * scalar, rows[0].z * scalar),
                row1: Vector3(rows[1].x * scalar, rows[1].y * scalar, rows[1].z * scalar),
                row2: Vector3(rows[2].x * scalar, rows[2].y * scalar, rows[2].z * scalar)
            )
        }

        func adding(_ other: Matrix3) -> Matrix3 {
            Matrix3(
                row0: Vector3(rows[0].x + other.rows[0].x, rows[0].y + other.rows[0].y, rows[0].z + other.rows[0].z),
                row1: Vector3(rows[1].x + other.rows[1].x, rows[1].y + other.rows[1].y, rows[1].z + other.rows[1].z),
                row2: Vector3(rows[2].x + other.rows[2].x, rows[2].y + other.rows[2].y, rows[2].z + other.rows[2].z)
            )
        }

        /// `self * other` (matrix product).
        func multiplying(_ other: Matrix3) -> Matrix3 {
            let ot = other.transposed()  // so each entry is a dot of two rows
            var result = Matrix3.zero
            for r in 0..<3 {
                for col in 0..<3 {
                    let rowVec = rows[r]
                    let colVec = ot.rows[col]  // = column `col` of `other`
                    result[r, col] = rowVec.x * colVec.x + rowVec.y * colVec.y + rowVec.z * colVec.z
                }
            }
            return result
        }

        /// `self * v`.
        func applying(to v: Vector3) -> Vector3 {
            Vector3(
                rows[0].x * v.x + rows[0].y * v.y + rows[0].z * v.z,
                rows[1].x * v.x + rows[1].y * v.y + rows[1].z * v.z,
                rows[2].x * v.x + rows[2].y * v.y + rows[2].z * v.z
            )
        }

        var trace: Double { self[0, 0] + self[1, 1] + self[2, 2] }

        var determinant: Double {
            self[0, 0] * (self[1, 1] * self[2, 2] - self[1, 2] * self[2, 1])
                - self[0, 1] * (self[1, 0] * self[2, 2] - self[1, 2] * self[2, 0])
                + self[0, 2] * (self[1, 0] * self[2, 1] - self[1, 1] * self[2, 0])
        }

        /// Sum of the three principal (diagonal-anchored) 2x2 minors — the
        /// coefficient of λ in the characteristic polynomial.
        var sumOfPrincipalMinors: Double {
            (self[0, 0] * self[1, 1] - self[0, 1] * self[1, 0])
                + (self[0, 0] * self[2, 2] - self[0, 2] * self[2, 0])
                + (self[1, 1] * self[2, 2] - self[1, 2] * self[2, 1])
        }

        /// Closed-form 3x3 inverse via the adjugate, `nil` if singular.
        func inverse() -> Matrix3? {
            let det = determinant
            guard det.isFinite, abs(det) > 1e-12 else { return nil }
            let invDet = 1 / det

            let cofactor00 = self[1, 1] * self[2, 2] - self[1, 2] * self[2, 1]
            let cofactor01 = -(self[1, 0] * self[2, 2] - self[1, 2] * self[2, 0])
            let cofactor02 = self[1, 0] * self[2, 1] - self[1, 1] * self[2, 0]
            let cofactor10 = -(self[0, 1] * self[2, 2] - self[0, 2] * self[2, 1])
            let cofactor11 = self[0, 0] * self[2, 2] - self[0, 2] * self[2, 0]
            let cofactor12 = -(self[0, 0] * self[2, 1] - self[0, 1] * self[2, 0])
            let cofactor20 = self[0, 1] * self[1, 2] - self[0, 2] * self[1, 1]
            let cofactor21 = -(self[0, 0] * self[1, 2] - self[0, 2] * self[1, 0])
            let cofactor22 = self[0, 0] * self[1, 1] - self[0, 1] * self[1, 0]

            // Inverse = (1/det) * adjugate = (1/det) * cofactor^T.
            return Matrix3(
                row0: Vector3(cofactor00 * invDet, cofactor10 * invDet, cofactor20 * invDet),
                row1: Vector3(cofactor01 * invDet, cofactor11 * invDet, cofactor21 * invDet),
                row2: Vector3(cofactor02 * invDet, cofactor12 * invDet, cofactor22 * invDet)
            )
        }

        /// `self - λI`.
        func subtractingFromDiagonal(_ lambda: Double) -> Matrix3 {
            var result = self
            result[0, 0] -= lambda
            result[1, 1] -= lambda
            result[2, 2] -= lambda
            return result
        }
    }

    /// Real eigenpairs of a general (not-necessarily-symmetric) 3x3 matrix:
    /// the real roots of its cubic characteristic polynomial, each paired
    /// with a null-space vector of `m - λI`.
    ///
    /// This is deliberately narrow to what `fit(points:)` needs: it does
    /// not attempt to find complex eigenpairs (irrelevant here — only a
    /// real eigenvector can satisfy the real-valued ellipse constraint
    /// `4AC - B^2 > 0`), and returns 1–3 pairs, oldest-eigenvalue-first by
    /// construction of `realCubicRoots`.
    private static func realEigenpairs(of m: Matrix3) -> [(value: Double, vector: Vector3)] {
        let trace = m.trace
        let a2 = -trace
        let a1 = m.sumOfPrincipalMinors
        let a0 = -m.determinant
        return realCubicRoots(a2: a2, a1: a1, a0: a0).compactMap { lambda in
            guard let vector = nullVector(of: m.subtractingFromDiagonal(lambda)) else { return nil }
            return (lambda, vector)
        }
    }

    /// Real roots of `λ^3 + a2 λ^2 + a1 λ + a0 = 0`, via the standard
    /// depressed-cubic substitution `λ = t - a2/3` and either the
    /// trigonometric formula (three real roots, the expected case for this
    /// fit's well-posed reduced system) or Cardano's formula for the single
    /// real root otherwise.
    ///
    /// The branch is chosen by the sign of `p`, not by an epsilon-gated
    /// discriminant test: three real roots requires `p < 0` (the
    /// discriminant `-4p^3 - 27q^2 > 0` forces `p^3 < 0`), and the
    /// trigonometric formula stays numerically valid across the *entire*
    /// `p < 0` range, including right at the repeated-root boundary
    /// (`arg` is clamped to `[-1, 1]` to absorb the floating-point noise
    /// there). Cardano's formula, by contrast, computes
    /// `sqrt(q^2/4 + p^3/27)` — two same-order-of-magnitude terms of
    /// opposite sign whose true sum is ~0 exactly at that same boundary —
    /// and loses enough precision there to occasionally hand back a
    /// small negative radicand (`NaN`) for a case that is genuinely,
    /// if barely, three real roots. Restricting Cardano to `p >= 0`, where
    /// both terms are non-negative and there is no cancellation, avoids
    /// that failure mode entirely rather than papering over it with a
    /// wider epsilon.
    private static func realCubicRoots(a2: Double, a1: Double, a0: Double) -> [Double] {
        let shift = a2 / 3
        let p = a1 - a2 * a2 / 3
        let q = (2 * a2 * a2 * a2) / 27 - (a2 * a1) / 3 + a0

        guard p.isFinite, q.isFinite else { return [] }

        if abs(p) < 1e-14 && abs(q) < 1e-14 {
            return [-shift]
        }

        if p < 0 {
            // Three real roots (generic case), or a repeated real root
            // right at the boundary — both handled by the same formula.
            let r = 2 * (-p / 3).squareRoot()
            var arg = (3 * q) / (p * r)  // = (3q)/(2p) * sqrt(-3/p), rearranged to avoid an extra sqrt
            arg = min(1, max(-1, arg))
            let phi = acos(arg) / 3
            return (0..<3).map { k in
                r * cos(phi - 2 * .pi * Double(k) / 3) - shift
            }
        } else {
            // p >= 0: exactly one real root, and no cancellation risk —
            // p^3/27 and q^2/4 are both non-negative here.
            let term = (q * q / 4 + p * p * p / 27).squareRoot()
            let u = cubeRoot(-q / 2 + term)
            let v = cubeRoot(-q / 2 - term)
            return [u + v - shift]
        }
    }

    private static func cubeRoot(_ x: Double) -> Double {
        x < 0 ? -pow(-x, 1.0 / 3.0) : pow(x, 1.0 / 3.0)
    }

    /// An approximate null-space vector of a near-singular 3x3 matrix: the
    /// cross product of two of its rows is orthogonal to both, hence in the
    /// null space of a rank-2 matrix. Tries all three row pairs and keeps
    /// the largest-magnitude cross product for numerical stability — the
    /// standard fix for "the two rows I happened to pick are nearly
    /// parallel". Returns `nil` if every pair is degenerate (the matrix is
    /// not actually rank-2, so `λ` was not really an eigenvalue).
    private static func nullVector(of m: Matrix3) -> Vector3? {
        let pairs = [(m.rows[0], m.rows[1]), (m.rows[0], m.rows[2]), (m.rows[1], m.rows[2])]
        var best: Vector3?
        var bestMagnitude = 0.0
        for (u, v) in pairs {
            let cross = Vector3(
                u.y * v.z - u.z * v.y,
                u.z * v.x - u.x * v.z,
                u.x * v.y - u.y * v.x
            )
            let magnitude = (cross.x * cross.x + cross.y * cross.y + cross.z * cross.z).squareRoot()
            guard magnitude.isFinite, magnitude > bestMagnitude else { continue }
            bestMagnitude = magnitude
            best = Vector3(cross.x / magnitude, cross.y / magnitude, cross.z / magnitude)
        }
        guard bestMagnitude > 1e-9 else { return nil }
        return best
    }
}
