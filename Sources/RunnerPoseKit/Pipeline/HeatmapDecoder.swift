import CoreML
import Foundation
import simd

/// S5 — DarkPose heatmap decoding + inverse affine back to original frame pixels.
///
/// Faithful port of (keep in sync — parity gate, 規劃書 §05 P1 / §12):
///   MotionAGFormer/demo/lib/hrnet/lib/utils/inference.py
///     get_max_preds, _dark_gaussian_blur, _dark_taylor, get_final_preds_dark
///   MotionAGFormer/demo/lib/hrnet/lib/utils/transforms.py  transform_preds
///
/// This is the **naive baseline** (plain Swift loops) — correctness first. The vDSP /
/// Metal rewrite is a P2 optimisation (規劃書 §04 後處理), gated on this matching
/// PyTorch to sub-pixel first.
struct HeatmapDecoder {
    let config: Config

    /// heatmap: raw model output, shape [1, 23, H=96, W=72], row-major.
    /// center / scale: from `Geometry.boxToCenterScale` for this frame.
    /// Returns 23 `Joint`s in original-frame pixel coordinates.
    func decode(
        heatmap: MLMultiArray,
        center: SIMD2<Double>,
        scale: SIMD2<Double>
    ) -> [Joint] {
        let J = JointName.count
        let H = config.heatmapHeight
        let W = config.heatmapWidth

        let planes = Self.toPlanes(heatmap, joints: J, height: H, width: W)

        // ---- get_max_preds: argmax per joint over flattened HxW ----
        var coords = [SIMD2<Double>](repeating: .zero, count: J)
        var maxVals = [Double](repeating: 0, count: J)
        for j in 0..<J {
            var bestIdx = 0
            var best = -Double.greatestFiniteMagnitude
            let base = j * H * W
            for i in 0..<(H * W) where planes[base + i] > best {
                best = planes[base + i]
                bestIdx = i
            }
            maxVals[j] = max(best, 0)
            // preds[:,0] = idx % W ; preds[:,1] = floor(idx / W)
            coords[j] = SIMD2(Double(bestIdx % W), Double(bestIdx / W))
            if best <= 0 { coords[j] = .zero } // pred_mask in get_max_preds
        }

        if config.fastHeatmapDecode {
            let inv = Geometry.affineTransform(
                center: center,
                scale: scale,
                outputSize: SIMD2(Double(W), Double(H)),
                inverse: true
            )

            return (0..<J).map { j in
                let p = inv.apply(Self.refineQuarterPixel(planes, joint: j, coord: coords[j], height: H, width: W))
                return Joint(name: JointName(rawValue: j)!, x: p.x, y: p.y, score: maxVals[j])
            }
        }

        // ---- DarkPose: blur (preserve peak) -> clip -> log -> Taylor refine ----
        var refined = coords
        for j in 0..<J {
            let base = j * H * W
            var plane = Array(planes[base ..< base + H * W])
            Self.darkGaussianBlurInPlace(&plane, height: H, width: W, kernel: config.darkPoseKernel)
            for i in 0..<plane.count {
                plane[i] = Foundation.log(min(max(plane[i], 1e-10), 50))
            }
            refined[j] = Self.darkTaylor(plane, height: H, width: W, coord: coords[j])
        }

        // ---- transform_preds: inverse affine at heatmap resolution ----
        let inv = Geometry.affineTransform(
            center: center,
            scale: scale,
            outputSize: SIMD2(Double(W), Double(H)),
            inverse: true
        )

        return (0..<J).map { j in
            let p = inv.apply(refined[j])
            return Joint(name: JointName(rawValue: j)!, x: p.x, y: p.y, score: maxVals[j])
        }
    }

    private static func refineQuarterPixel(
        _ planes: [Double],
        joint: Int,
        coord: SIMD2<Double>,
        height H: Int,
        width W: Int
    ) -> SIMD2<Double> {
        let px = Int(coord.x)
        let py = Int(coord.y)
        guard px > 0, px < W - 1, py > 0, py < H - 1 else { return coord }

        let base = joint * H * W
        func v(_ x: Int, _ y: Int) -> Double { planes[base + y * W + x] }
        let dx = v(px + 1, py) - v(px - 1, py)
        let dy = v(px, py + 1) - v(px, py - 1)

        return SIMD2(
            coord.x + (dx == 0 ? 0 : (dx > 0 ? 0.25 : -0.25)),
            coord.y + (dy == 0 ? 0 : (dy > 0 ? 0.25 : -0.25))
        )
    }

    // MARK: - ports

    /// ```python
    /// def _dark_gaussian_blur(heatmaps, kernel=11):
    ///     border = (kernel - 1) // 2
    ///     origin_max = np.max(hm)
    ///     if origin_max <= 0: continue
    ///     dr = zeros(H + 2*border, W + 2*border); dr[border:-border, border:-border] = hm
    ///     dr = cv2.GaussianBlur(dr, (kernel, kernel), 0)      # sigma auto from ksize
    ///     hm = dr[border:-border, border:-border]
    ///     hm *= origin_max / np.max(hm)
    /// ```
    /// OpenCV auto sigma for ksize k: `0.3*((k-1)*0.5 - 1) + 0.8`. k=11 -> sigma = 2.0.
    static func darkGaussianBlurInPlace(
        _ hm: inout [Double], height H: Int, width W: Int, kernel: Int
    ) {
        let originMax = hm.max() ?? 0
        guard originMax > 0 else { return }
        let border = (kernel - 1) / 2
        let sigma = 0.3 * (Double(kernel - 1) * 0.5 - 1) + 0.8
        let g = gaussianKernel1D(radius: border, sigma: sigma)

        let ph = H + 2 * border, pw = W + 2 * border
        var pad = [Double](repeating: 0, count: ph * pw)
        for y in 0..<H {
            for x in 0..<W { pad[(y + border) * pw + (x + border)] = hm[y * W + x] }
        }
        // separable convolution with zero padding (cv2.BORDER_DEFAULT is reflect,
        // but the pipeline pads with an explicit zero border first, and the peak is
        // far from the edge, so a zero-border separable pass matches in practice —
        // TODO(mac): confirm against cv2 on a real heatmap in DarkPoseParityTests).
        var tmp = [Double](repeating: 0, count: ph * pw)
        for y in 0..<ph {
            for x in 0..<pw {
                var acc = 0.0
                for k in -border...border {
                    let xx = x + k
                    if xx >= 0 && xx < pw { acc += pad[y * pw + xx] * g[k + border] }
                }
                tmp[y * pw + x] = acc
            }
        }
        for y in 0..<ph {
            for x in 0..<pw {
                var acc = 0.0
                for k in -border...border {
                    let yy = y + k
                    if yy >= 0 && yy < ph { acc += tmp[yy * pw + x] * g[k + border] }
                }
                pad[y * pw + x] = acc
            }
        }

        var blurredMax = 0.0
        for y in 0..<H {
            for x in 0..<W {
                let v = pad[(y + border) * pw + (x + border)]
                hm[y * W + x] = v
                if v > blurredMax { blurredMax = v }
            }
        }
        guard blurredMax > 0 else { return }
        let s = originMax / blurredMax
        for i in 0..<hm.count { hm[i] *= s }
    }

    private static func gaussianKernel1D(radius: Int, sigma: Double) -> [Double] {
        var k = [Double](repeating: 0, count: 2 * radius + 1)
        var sum = 0.0
        for i in -radius...radius {
            let v = exp(-Double(i * i) / (2 * sigma * sigma))
            k[i + radius] = v
            sum += v
        }
        for i in 0..<k.count { k[i] /= sum }
        return k
    }

    /// ```python
    /// def _dark_taylor(heatmap, coord):        # heatmap already log-space
    ///     px, py = int(coord[0]), int(coord[1])
    ///     if 1 < px < W-2 and 1 < py < H-2:
    ///         dx  = 0.5*(hm[py,px+1] - hm[py,px-1])
    ///         dy  = 0.5*(hm[py+1,px] - hm[py-1,px])
    ///         dxx = 0.25*(hm[py,px+2] - 2*hm[py,px] + hm[py,px-2])
    ///         dxy = 0.25*(hm[py+1,px+1] - hm[py-1,px+1] - hm[py+1,px-1] + hm[py-1,px-1])
    ///         dyy = 0.25*(hm[py+2,px] - 2*hm[py,px] + hm[py-2,px])
    ///         det = dxx*dyy - dxy*dxy
    ///         if det != 0:
    ///             offset = -inv([[dxx,dxy],[dxy,dyy]]) @ [dx,dy]
    ///             coord = coord + offset
    /// ```
    static func darkTaylor(
        _ hm: [Double], height H: Int, width W: Int, coord: SIMD2<Double>
    ) -> SIMD2<Double> {
        let px = Int(coord.x), py = Int(coord.y)
        guard px > 1, px < W - 2, py > 1, py < H - 2 else { return coord }
        func v(_ x: Int, _ y: Int) -> Double { hm[y * W + x] }

        let dx = 0.5 * (v(px + 1, py) - v(px - 1, py))
        let dy = 0.5 * (v(px, py + 1) - v(px, py - 1))
        let dxx = 0.25 * (v(px + 2, py) - 2 * v(px, py) + v(px - 2, py))
        let dxy = 0.25 * (v(px + 1, py + 1) - v(px + 1, py - 1) - v(px - 1, py + 1) + v(px - 1, py - 1))
        let dyy = 0.25 * (v(px, py + 2) - 2 * v(px, py) + v(px, py - 2))

        let det = dxx * dyy - dxy * dxy
        guard det != 0 else { return coord }
        // offset = -H^{-1} g
        let ox = -( dyy * dx - dxy * dy) / det
        let oy = -(-dxy * dx + dxx * dy) / det
        return coord + SIMD2(ox, oy)
    }

    /// MLMultiArray [1,J,H,W] float16/float32 -> flat `[Double]` of length J*H*W.
    static func toPlanes(_ a: MLMultiArray, joints J: Int, height H: Int, width W: Int) -> [Double] {
        var out = [Double](repeating: 0, count: J * H * W)
        let strides = a.strides.map(\.intValue)
        guard strides.count >= 4 else {
            return toPlanesBySubscript(a, joints: J, height: H, width: W)
        }

        switch a.dataType {
        case .float16:
            let ptr = a.dataPointer.bindMemory(to: Float16.self, capacity: a.count)
            fillPlanes(from: ptr, strides: strides, output: &out, joints: J, height: H, width: W) { Double(Float($0)) }
        case .float32:
            let ptr = a.dataPointer.bindMemory(to: Float.self, capacity: a.count)
            fillPlanes(from: ptr, strides: strides, output: &out, joints: J, height: H, width: W) { Double($0) }
        case .double:
            let ptr = a.dataPointer.bindMemory(to: Double.self, capacity: a.count)
            fillPlanes(from: ptr, strides: strides, output: &out, joints: J, height: H, width: W) { $0 }
        default:
            return toPlanesBySubscript(a, joints: J, height: H, width: W)
        }

        return out
    }

    private static func fillPlanes<T>(
        from ptr: UnsafePointer<T>,
        strides: [Int],
        output: inout [Double],
        joints J: Int,
        height H: Int,
        width W: Int,
        convert: (T) -> Double
    ) {
        let jointStride = strides[1]
        let yStride = strides[2]
        let xStride = strides[3]

        for j in 0..<J {
            let jointOffset = j * jointStride
            for y in 0..<H {
                let rowOffset = jointOffset + y * yStride
                let outOffset = j * H * W + y * W
                for x in 0..<W {
                    output[outOffset + x] = convert(ptr[rowOffset + x * xStride])
                }
            }
        }
    }

    private static func toPlanesBySubscript(_ a: MLMultiArray, joints J: Int, height H: Int, width W: Int) -> [Double] {
        var out = [Double](repeating: 0, count: J * H * W)
        for j in 0..<J {
            for y in 0..<H {
                for x in 0..<W {
                    let key = [NSNumber(value: 0), NSNumber(value: j), NSNumber(value: y), NSNumber(value: x)]
                    out[j * H * W + y * W + x] = a[key].doubleValue
                }
            }
        }
        return out
    }
}
