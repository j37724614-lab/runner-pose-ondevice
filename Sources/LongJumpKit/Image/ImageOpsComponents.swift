import Foundation

/// cv2.connectedComponentsWithStats result: label 0 is the background.
public struct ConnectedComponents: Sendable {
    public struct Stat: Sendable, Equatable {
        public var x: Int, y: Int, width: Int, height: Int, area: Int
    }

    public let width: Int
    public let height: Int
    /// Number of labels including the background (cv2's first return value).
    public let count: Int
    public var labels: [Int32]
    /// One per label, index = label.
    public var stats: [Stat]
}

extension ImageOps {
    /// 8-connected components of the non-zero pixels.  OpenCV's default (Spaghetti, a 2x2 block
    /// scan) numbers the components by the first 2x2 block, in block raster order, that touches
    /// them; this reproduces that numbering with a plain two-pass union-find.
    public static func connectedComponentsWithStats(_ mask: BinaryMask) -> ConnectedComponents {
        let w = mask.width, h = mask.height
        var labels = [Int32](repeating: 0, count: w * h)
        guard w > 0, h > 0 else {
            return ConnectedComponents(width: w, height: h, count: 1, labels: labels, stats: [.init(x: 0, y: 0, width: 0, height: 0, area: 0)])
        }
        let capacity = ((w + 1) / 2) * ((h + 1) / 2) + 2
        let parentPtr = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
        defer { parentPtr.deallocate() }
        parentPtr[0] = 0
        var next: Int32 = 1
        @inline(__always) func find(_ a: Int32) -> Int32 {
            var r = a
            while parentPtr[Int(r)] != r { r = parentPtr[Int(r)] }
            var c = a
            while parentPtr[Int(c)] != r { let n = parentPtr[Int(c)]; parentPtr[Int(c)] = r; c = n }
            return r
        }
        @inline(__always) func union(_ a: Int32, _ b: Int32) -> Int32 {
            let ra = find(a), rb = find(b)
            if ra == rb { return ra }
            if ra < rb { parentPtr[Int(rb)] = ra; return ra }
            parentPtr[Int(ra)] = rb
            return rb
        }
        mask.data.withUnsafeBufferPointer { src in
            labels.withUnsafeMutableBufferPointer { lab in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w where src[row + x] != 0 {
                        let left: Int32 = x > 0 ? lab[row + x - 1] : 0
                        var ul: Int32 = 0, up: Int32 = 0, ur: Int32 = 0
                        if y > 0 {
                            let u = row - w + x
                            up = lab[u]
                            if x > 0 { ul = lab[u - 1] }
                            if x + 1 < w { ur = lab[u + 1] }
                        }
                        var l: Int32 = 0
                        if left != 0 { l = left }
                        if ul != 0 { l = l == 0 ? ul : union(l, ul) }
                        if up != 0 { l = l == 0 ? up : union(l, up) }
                        if ur != 0 { l = l == 0 ? ur : union(l, ur) }
                        if l == 0 {
                            parentPtr[Int(next)] = next
                            l = next
                            next += 1
                        }
                        lab[row + x] = l
                    }
                }
            }
        }
        let provisional = Int(next)
        // Resolve roots, find each component's first block key.
        var rootOf = [Int32](repeating: 0, count: provisional)
        for i in 1..<max(provisional, 1) { rootOf[i] = find(Int32(i)) }
        let blocksPerRow = (w + 1) / 2
        let none = Int.max
        var key = [Int](repeating: none, count: provisional)
        var minX = [Int](repeating: Int.max, count: provisional)
        var minY = [Int](repeating: Int.max, count: provisional)
        var maxX = [Int](repeating: -1, count: provisional)
        var maxY = [Int](repeating: -1, count: provisional)
        var area = [Int](repeating: 0, count: provisional)
        labels.withUnsafeBufferPointer { lab in
            for y in 0..<h {
                for x in 0..<w {
                    let l = lab[y * w + x]
                    if l == 0 { continue }
                    let r = Int(rootOf[Int(l)])
                    let k = (y >> 1) * blocksPerRow + (x >> 1)
                    if k < key[r] { key[r] = k }
                    if x < minX[r] { minX[r] = x }
                    if x > maxX[r] { maxX[r] = x }
                    if y < minY[r] { minY[r] = y }
                    if y > maxY[r] { maxY[r] = y }
                    area[r] += 1
                }
            }
        }
        let roots = (1..<max(provisional, 1)).filter { rootOf[$0] == Int32($0) }.sorted { key[$0] < key[$1] }
        var finalLabel = [Int32](repeating: 0, count: provisional)
        var stats = [ConnectedComponents.Stat(x: 0, y: 0, width: w, height: h, area: 0)]
        var foreground = 0
        for (i, r) in roots.enumerated() {
            finalLabel[r] = Int32(i + 1)
            stats.append(.init(x: minX[r], y: minY[r], width: maxX[r] - minX[r] + 1, height: maxY[r] - minY[r] + 1, area: area[r]))
            foreground += area[r]
        }
        // OpenCV's background stat: bbox of the background pixels, area = pixel count minus foreground.
        var bx0 = Int.max, by0 = Int.max, bx1 = -1, by1 = -1
        mask.data.withUnsafeBufferPointer { src in
            for y in 0..<h {
                for x in 0..<w where src[y * w + x] == 0 {
                    if x < bx0 { bx0 = x }
                    if x > bx1 { bx1 = x }
                    if y < by0 { by0 = y }
                    if y > by1 { by1 = y }
                }
            }
        }
        if bx1 >= 0 {
            stats[0] = .init(x: bx0, y: by0, width: bx1 - bx0 + 1, height: by1 - by0 + 1, area: w * h - foreground)
        } else {
            stats[0] = .init(x: 0, y: 0, width: 0, height: 0, area: 0)
        }
        labels.withUnsafeMutableBufferPointer { lab in
            for i in 0..<lab.count where lab[i] != 0 { lab[i] = finalLabel[Int(rootOf[Int(lab[i])])] }
        }
        return ConnectedComponents(width: w, height: h, count: roots.count + 1, labels: labels, stats: stats)
    }
}
