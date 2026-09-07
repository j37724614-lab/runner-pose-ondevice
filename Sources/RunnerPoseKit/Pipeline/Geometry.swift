import CoreGraphics
import simd

/// Faithful port of the runner-analysis-pipeline HRNet pre/post geometry.
///
/// Python sources (keep these in sync — `DarkPoseParityTests` / a Mac parity run
/// against them is the acceptance gate, 規劃書 §05 P1):
///   MotionAGFormer/demo/lib/hrnet/lib/utils/utilitys.py   box_to_center_scale, PreProcess
///   MotionAGFormer/demo/lib/hrnet/lib/utils/transforms.py get_affine_transform, transform_preds
///
/// Coordinate conventions match OpenCV: origin top-left, x right, y down.
enum Geometry {

    /// `center, scale` for the affine warp.
    ///
    /// ```python
    /// def box_to_center_scale(box, model_image_width, model_image_height):
    ///     center = np.zeros((2), dtype=np.float32)
    ///     x1, y1, x2, y2 = box[:4]
    ///     box_width, box_height = x2 - x1, y2 - y1
    ///     center[0] = x1 + box_width * 0.5
    ///     center[1] = y1 + box_height * 0.5
    ///     aspect_ratio = model_image_width * 1.0 / model_image_height
    ///     pixel_std = 200
    ///     if box_width > aspect_ratio * box_height:
    ///         box_height = box_width * 1.0 / aspect_ratio
    ///     elif box_width < aspect_ratio * box_height:
    ///         box_width = box_height * aspect_ratio
    ///     scale = np.array([box_width / pixel_std, box_height / pixel_std], dtype=np.float32)
    ///     if center[0] != -1:
    ///         scale = scale * 1.25
    ///     return center, scale
    /// ```
    ///
    /// ⚠️ QUIRK carried over verbatim from the pipeline: `PreProcess` calls this as
    /// `box_to_center_scale(bbox, data_numpy.shape[0], data_numpy.shape[1])`, i.e. it
    /// passes the **source frame height** as `model_image_width` and the **source frame
    /// width** as `model_image_height`. So `aspectRatio == frameHeight / frameWidth`,
    /// NOT `288/384`. This is almost certainly a latent bug in the original, but the
    /// trained model has only ever seen crops made this way, so we reproduce it exactly.
    /// If a parity run shows it matters, fix it in BOTH places together, not here alone.
    static func boxToCenterScale(
        box: BBox,
        frameWidth: Int,
        frameHeight: Int
    ) -> (center: SIMD2<Double>, scale: SIMD2<Double>) {
        var boxWidth = box.width
        var boxHeight = box.height
        let center = SIMD2<Double>(box.x1 + boxWidth * 0.5, box.y1 + boxHeight * 0.5)

        // verbatim: model_image_width <- frameHeight, model_image_height <- frameWidth
        let aspectRatio = Double(frameHeight) / Double(frameWidth)
        let pixelStd = 200.0

        if boxWidth > aspectRatio * boxHeight {
            boxHeight = boxWidth / aspectRatio
        } else if boxWidth < aspectRatio * boxHeight {
            boxWidth = boxHeight * aspectRatio
        }
        var scale = SIMD2<Double>(boxWidth / pixelStd, boxHeight / pixelStd)
        if center.x != -1 { scale *= 1.25 }
        return (center, scale)
    }

    /// 2×3 affine, row-major: `[a b tx; c d ty]`. Maps (x,y,1) -> (x',y').
    struct Affine {
        var a, b, tx: Double
        var c, d, ty: Double

        func apply(_ p: SIMD2<Double>) -> SIMD2<Double> {
            SIMD2(a * p.x + b * p.y + tx, c * p.x + d * p.y + ty)
        }

        /// `CGAffineTransform` for feeding Core Image (note CG's field order: a,b,c,d,tx,ty
        /// with b/c swapped relative to our row-major `[a b tx; c d ty]`).
        var cg: CGAffineTransform {
            CGAffineTransform(a: CGFloat(a), b: CGFloat(c), c: CGFloat(b), d: CGFloat(d),
                              tx: CGFloat(tx), ty: CGFloat(ty))
        }
    }

    /// Solve the unique affine mapping three source points to three destination points.
    /// Equivalent to `cv2.getAffineTransform(src, dst)`.
    static func affineFrom(
        _ src: (SIMD2<Double>, SIMD2<Double>, SIMD2<Double>),
        to dst: (SIMD2<Double>, SIMD2<Double>, SIMD2<Double>)
    ) -> Affine {
        // Solve M * [x y 1]^T = [x' y']^T for each axis independently.
        //   | x0 y0 1 | |a|   |x0'|
        //   | x1 y1 1 | |b| = |x1'|
        //   | x2 y2 1 | |tx|  |x2'|
        let m = simd_double3x3(rows: [
            SIMD3(src.0.x, src.0.y, 1),
            SIMD3(src.1.x, src.1.y, 1),
            SIMD3(src.2.x, src.2.y, 1),
        ])
        let inv = m.inverse
        let rowX = inv * SIMD3(dst.0.x, dst.1.x, dst.2.x)
        let rowY = inv * SIMD3(dst.0.y, dst.1.y, dst.2.y)
        return Affine(a: rowX.x, b: rowX.y, tx: rowX.z,
                      c: rowY.x, d: rowY.y, ty: rowY.z)
    }

    /// Port of `get_affine_transform(center, scale, rot=0, output_size, inv)`.
    /// `rot` is always 0 in the pipeline, so it is dropped.
    ///
    /// ```python
    /// scale_tmp = scale * 200.0
    /// src_w = scale_tmp[0]
    /// dst_w, dst_h = output_size[0], output_size[1]
    /// src_dir = [0, src_w * -0.5]                 # rot = 0
    /// dst_dir = [0, dst_w * -0.5]
    /// src[0] = center
    /// src[1] = center + src_dir
    /// dst[0] = [dst_w*0.5, dst_h*0.5]
    /// dst[1] = dst[0] + dst_dir
    /// src[2] = get_3rd_point(src[0], src[1])      # b + [-(a-b).y, (a-b).x]
    /// dst[2] = get_3rd_point(dst[0], dst[1])
    /// trans = getAffineTransform(dst, src) if inv else getAffineTransform(src, dst)
    /// ```
    static func affineTransform(
        center: SIMD2<Double>,
        scale: SIMD2<Double>,
        outputSize: SIMD2<Double>,
        inverse: Bool
    ) -> Affine {
        let scaleTmp = scale * 200.0
        let srcW = scaleTmp.x
        let dstW = outputSize.x
        let dstH = outputSize.y

        let srcDir = SIMD2<Double>(0, srcW * -0.5)
        let dstDir = SIMD2<Double>(0, dstW * -0.5)

        let src0 = center
        let src1 = center + srcDir
        let dst0 = SIMD2<Double>(dstW * 0.5, dstH * 0.5)
        let dst1 = dst0 + dstDir

        let src2 = thirdPoint(src0, src1)
        let dst2 = thirdPoint(dst0, dst1)

        return inverse
            ? affineFrom((dst0, dst1, dst2), to: (src0, src1, src2))
            : affineFrom((src0, src1, src2), to: (dst0, dst1, dst2))
    }

    /// `get_3rd_point(a, b)` -> `b + [-(a-b).y, (a-b).x]`
    private static func thirdPoint(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
        let d = a - b
        return b + SIMD2<Double>(-d.y, d.x)
    }
}
