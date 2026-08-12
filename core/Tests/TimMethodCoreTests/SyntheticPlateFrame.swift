import CoreGraphics
import CoreVideo

/// Renders a synthetic frame — a filled ellipse ("plate") on a plain
/// background — into a `CVPixelBuffer`, 32BGRA, matching the live capture
/// pipeline's pixel format (SPEC §4.2). Used to exercise `PlateDetector`'s
/// real edge → contour → fit pipeline end to end, not just `EllipseFit`'s
/// maths in isolation.
///
/// A filled *light* ellipse on a *dark* ground is the documented
/// convention every test in `PlateDetectorTests` relies on — it's also
/// what `PlateDetector` itself is configured for (`detectsDarkOnLight =
/// false`, see that file).
enum SyntheticPlateFrame {
    /// One ellipse to draw: a fully-specified plate placement.
    struct Ellipse {
        /// Centre, pixel space (top-left origin, y down).
        var center: CGPoint
        /// Full major axis length, pixels.
        var majorAxis: Double
        /// Full minor axis length, pixels.
        var minorAxis: Double
        /// In-plane rotation, radians, of the major axis from the positive
        /// x-axis.
        var rotation: Double

        init(center: CGPoint, majorAxis: Double, minorAxis: Double, rotation: Double = 0) {
            self.center = center
            self.majorAxis = majorAxis
            self.minorAxis = minorAxis
            self.rotation = rotation
        }
    }

    /// Renders `ellipses` as light-grey filled shapes on a near-black
    /// background into a new `width` x `height` 32BGRA `CVPixelBuffer`.
    static func render(width: Int, height: Int, ellipses: [Ellipse]) -> CVPixelBuffer {
        var pixelBufferOut: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBufferOut
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            fatalError("SyntheticPlateFrame: CVPixelBufferCreate failed with status \(status)")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            fatalError("SyntheticPlateFrame: no base address")
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else {
            fatalError("SyntheticPlateFrame: CGContext creation failed")
        }

        // Dark ground.
        context.setFillColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Light plate(s). CGContext's coordinate origin is bottom-left with
        // y up; the pixel buffer itself (and everything this test suite and
        // `PlateDetector` treat as "pixel space") is top-left with y down.
        // Flip once, up front, so an `Ellipse.center` given in top-left/y-down
        // coordinates lands at the same pixel it would in the final buffer.
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1)
        for ellipse in ellipses {
            context.saveGState()
            context.translateBy(x: ellipse.center.x, y: ellipse.center.y)
            context.rotate(by: ellipse.rotation)
            let rect = CGRect(
                x: -ellipse.majorAxis / 2, y: -ellipse.minorAxis / 2,
                width: ellipse.majorAxis, height: ellipse.minorAxis
            )
            context.fillEllipse(in: rect)
            context.restoreGState()
        }
        context.restoreGState()

        return pixelBuffer
    }
}
