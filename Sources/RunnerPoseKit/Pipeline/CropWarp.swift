import Accelerate
import CoreGraphics
import CoreImage
import CoreVideo
import simd

/// S3 — turn a full frame + bbox into the 288×384 RGB `person_crop` the HRNet Core ML
/// model expects (values 0…255, normalisation baked into the model).
///
/// Geometry: `Geometry.boxToCenterScale` + `Geometry.affineTransform(...inverse:false)`,
/// then a bilinear affine warp (== `cv2.warpAffine(..., INTER_LINEAR)` in the pipeline's
/// `PreProcess`).
struct CropWarp {
    let config: Config

    /// Pool of 288×384 BGRA buffers, reused frame-to-frame (規劃書 §04 影格路徑).
    private let pool: CVPixelBufferPool

    /// Kept per-frame so S5 can run the inverse transform.
    struct WarpInfo {
        var center: SIMD2<Double>
        var scale: SIMD2<Double>
        var forward: Geometry.Affine
    }

    init(config: Config) throws {
        self.config = config
        var pool: CVPixelBufferPool?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.hrnetInputWidth,
            kCVPixelBufferHeightKey as String: config.hrnetInputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 4] as CFDictionary,
                                             attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw RunnerPoseError.cropWarpSetup(status)
        }
        self.pool = pool
    }

    /// - Parameters:
    ///   - frame: source frame, BGRA, IOSurface-backed.
    ///   - box: qualifying runner box in source pixels.
    ///   - frameSize: source frame width/height.
    /// - Returns: a pooled 288×384 BGRA crop + the transform used.
    func makeCrop(
        from frame: CVPixelBuffer,
        box: BBox,
        frameSize: CGSize
    ) throws -> (crop: CVPixelBuffer, info: WarpInfo) {
        let (center, scale) = Geometry.boxToCenterScale(
            box: box,
            frameWidth: Int(frameSize.width),
            frameHeight: Int(frameSize.height)
        )
        let forward = Geometry.affineTransform(
            center: center,
            scale: scale,
            outputSize: SIMD2(Double(config.hrnetInputWidth), Double(config.hrnetInputHeight)),
            inverse: false
        )

        var out: CVPixelBuffer?
        let s = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard s == kCVReturnSuccess, let out else { throw RunnerPoseError.cropWarpSetup(s) }

        try Self.warpBGRA(src: frame, dst: out, forward: forward)
        return (out, WarpInfo(center: center, scale: scale, forward: forward))
    }

    /// Bilinear affine warp, BGRA8888.
    ///
    /// TODO(mac): verify the transform *direction*. `cv2.warpAffine` takes the src→dst
    /// matrix and samples the inverse; `vImageAffineWarp_ARGB8888` takes a
    /// `vImage_AffineTransform` that also maps src→dst (it inverts internally). So
    /// `forward.cg` should be correct as-is, but confirm on a checkerboard fixture in
    /// `DarkPoseParityTests`. `kvImageBackgroundColorFill` = black, matching cv2's
    /// default 0 border.
    static func warpBGRA(src: CVPixelBuffer, dst: CVPixelBuffer, forward: Geometry.Affine) throws {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }

        var srcBuf = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(src),
            height: vImagePixelCount(CVPixelBufferGetHeight(src)),
            width: vImagePixelCount(CVPixelBufferGetWidth(src)),
            rowBytes: CVPixelBufferGetBytesPerRow(src)
        )
        var dstBuf = vImage_Buffer(
            data: CVPixelBufferGetBaseAddress(dst),
            height: vImagePixelCount(CVPixelBufferGetHeight(dst)),
            width: vImagePixelCount(CVPixelBufferGetWidth(dst)),
            rowBytes: CVPixelBufferGetBytesPerRow(dst)
        )

        let sourceHeight = Double(CVPixelBufferGetHeight(src))
        let destinationHeight = Double(CVPixelBufferGetHeight(dst))
        var xform = forward.vImageTransform(
            sourceHeight: sourceHeight,
            destinationHeight: destinationHeight
        )
        var bg: Pixel_8888 = (0, 0, 0, 255)
        let err = withUnsafePointer(to: &bg) { bgPtr in
            vImageAffineWarp_ARGB8888(
                &srcBuf, &dstBuf, nil, &xform, bgPtr,
                vImage_Flags(kvImageBackgroundColorFill | kvImageHighQualityResampling)
            )
        }
        guard err == kvImageNoError else { throw RunnerPoseError.warpFailed(err) }
    }
}

private extension Geometry.Affine {
    /// `Geometry.Affine` is in OpenCV/top-left coordinates. vImage affine warps use
    /// bottom-left coordinates, so convert the same source -> destination mapping
    /// before passing it to `vImageAffineWarp_ARGB8888`.
    func vImageTransform(sourceHeight: Double, destinationHeight: Double) -> vImage_AffineTransform {
        let topLeftA = a
        let topLeftB = b
        let topLeftC = c
        let topLeftD = d

        let bottomLeftA = topLeftA
        let bottomLeftB = -topLeftB
        let bottomLeftTX = tx + topLeftB * sourceHeight

        let bottomLeftC = -topLeftC
        let bottomLeftD = topLeftD
        let bottomLeftTY = destinationHeight - topLeftD * sourceHeight - ty

        return vImage_AffineTransform(
            a: Float(bottomLeftA),
            b: Float(bottomLeftC),
            c: Float(bottomLeftB),
            d: Float(bottomLeftD),
            tx: Float(bottomLeftTX),
            ty: Float(bottomLeftTY)
        )
    }
}
