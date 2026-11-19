import Foundation

/// Take-off board detection on the first frame (detection.py red_runway_mask ... fit_takeoff_line,
/// find_board_contact_with_board, takeoff_board.board_row_width_px).
public enum BoardDetector {
    // MARK: masks

    /// detection.red_runway_mask: hue <= 10 or >= 165, saturation > 70, value > 50 (0/1).
    public static func redRunwayMask(_ image: PixelImage) -> BinaryMask {
        var out = [UInt8](repeating: 0, count: image.width * image.height)
        out.withUnsafeMutableBufferPointer { o in
            ImageOps.forEachHSV(image) { i, h, s, v in
                o[i] = (h <= 10 || h >= 165) && s > 70 && v > 50 ? 1 : 0
            }
        }
        return BinaryMask(width: image.width, height: image.height, data: out)
    }

    /// detection.white_mask: saturation < 60 and value > 160, opened with a 3x3 kernel.
    public static func whiteMask(_ image: PixelImage) -> BinaryMask {
        var out = [UInt8](repeating: 0, count: image.width * image.height)
        out.withUnsafeMutableBufferPointer { o in
            ImageOps.forEachHSV(image) { i, _, s, v in
                o[i] = s < 60 && v > 160 ? 1 : 0
            }
        }
        return ImageOps.open(BinaryMask(width: image.width, height: image.height, data: out), kernel: 3)
    }

    // MARK: detect_board

    /// detection.detect_board: the white blob whose ring is the most red runway (none when that
    /// ratio < rule.minRingRed), and every blob of plausible area.
    public static func detectBoard(_ image: PixelImage, rule: BoardRule = BoardRule()) -> BoardDetection {
        let red = redRunwayMask(image)
        let components = ImageOps.connectedComponentsWithStats(whiteMask(image))
        var candidates: [BoardCandidate] = []
        for label in 1..<components.count {
            let stat = components.stats[label]
            if rule.minArea <= stat.area && stat.area <= rule.maxArea {
                candidates.append(scoreCandidate(components, stat: stat, label: label, red: red, rule: rule))
            }
        }
        // sort(key=(ring_red, area, label, bbox), reverse=True)
        candidates.sort { a, b in
            if a.ringRed != b.ringRed { return a.ringRed > b.ringRed }
            if a.area != b.area { return a.area > b.area }
            if a.label != b.label { return a.label > b.label }
            return b.bbox.lexicographicallyPrecedes(a.bbox)
        }
        guard let best = candidates.first, !(best.ringRed < rule.minRingRed) else {
            return BoardDetection(mask: nil, candidates: candidates)
        }
        var mask = [UInt8](repeating: 0, count: components.labels.count)
        let target = Int32(best.label)
        components.labels.withUnsafeBufferPointer { l in
            mask.withUnsafeMutableBufferPointer { m in
                for i in 0..<l.count where l[i] == target { m[i] = 1 }
            }
        }
        return BoardDetection(mask: BinaryMask(width: components.width, height: components.height, data: mask), candidates: candidates)
    }

    /// detection._score_candidate: fraction of red-runway pixels in the ring around one blob.
    static func scoreCandidate(
        _ components: ConnectedComponents, stat: ConnectedComponents.Stat, label: Int, red: BinaryMask, rule: BoardRule
    ) -> BoardCandidate {
        let ring = rule.ringPx
        let width = components.width, height = components.height
        let x0 = max(stat.x - ring, 0), y0 = max(stat.y - ring, 0)
        let x1 = min(stat.x + stat.width + ring, width), y1 = min(stat.y + stat.height + ring, height)
        let ww = x1 - x0, wh = y1 - y0
        var blob = [UInt8](repeating: 0, count: ww * wh)
        let target = Int32(label)
        for y in 0..<wh {
            for x in 0..<ww where components.labels[(y0 + y) * width + x0 + x] == target { blob[y * ww + x] = 1 }
        }
        let blobMask = BinaryMask(width: ww, height: wh, data: blob)
        let dilated = ImageOps.dilate(blobMask, kernel: 2 * ring + 1)
        var sum = 0, n = 0
        for y in 0..<wh {
            for x in 0..<ww where dilated.data[y * ww + x] != 0 && blob[y * ww + x] == 0 {
                n += 1
                sum += Int(red.data[(y0 + y) * width + x0 + x])
            }
        }
        // numpy mean of a uint8 selection: exact integer sum / count (NaN when empty)
        let ringRed = n == 0 ? Double.nan : Double(sum) / Double(n)
        return BoardCandidate(ringRed: ringRed, area: stat.area, label: label, bbox: [stat.x, stat.y, stat.width, stat.height])
    }

    // MARK: take-off line

    /// detection.fit_takeoff_line: Huber line through the pit-side edge pixel of every board row.
    public static func fitTakeoffLine(_ board: BinaryMask, pitSide: Side) -> TakeoffLine {
        var edge: [SIMD2<Float>] = []
        for y in 0..<board.height {
            var lo = -1, hi = -1
            for x in 0..<board.width where board.data[y * board.width + x] != 0 {
                if lo < 0 { lo = x }
                hi = x
            }
            if lo >= 0 { edge.append(SIMD2(Float(pitSide == .left ? lo : hi), Float(y))) }
        }
        precondition(!edge.isEmpty, "empty board mask")
        let fit = ImageOps.fitLineHuber(edge)
        func pointAt(_ y: Float) -> SIMD2<Double> {
            let x: Float = fit.x0 + (y - fit.y0) * fit.vx / fit.vy
            return SIMD2(Double(x), Double(y))
        }
        return TakeoffLine(top: pointAt(edge.map(\.y).min()!), bottom: pointAt(edge.map(\.y).max()!))
    }

    // MARK: board width

    /// takeoff_board.board_row_width_px: median horizontal width over the middle rows of the mask.
    public static func boardRowWidthPx(_ board: BinaryMask) -> Double? {
        var widths: [Double] = []
        for y in 0..<board.height {
            var lo = -1, hi = -1
            for x in 0..<board.width where board.data[y * board.width + x] != 0 {
                if lo < 0 { lo = x }
                hi = x
            }
            if lo >= 0 { widths.append(Double(hi - lo + 1)) }
        }
        if widths.isEmpty { return nil }
        let low = Int(Double(widths.count) * 0.2)
        let high = Int((Double(widths.count) * 0.8).rounded(.up))
        let middle = high > low ? Array(widths[low..<high]) : widths
        return NP.median(middle)
    }
}
