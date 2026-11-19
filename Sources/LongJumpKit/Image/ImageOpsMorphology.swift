import Foundation

extension ImageOps {
    /// Window-any over a rectangular kernel (anchor k/2), outside = 0.  `flip` 1 inverts input and
    /// output, which turns it into an erosion with outside = set.
    static func windowAny(_ mask: BinaryMask, kw: Int, kh: Int, flip: UInt8) -> BinaryMask {
        let w = mask.width, h = mask.height
        if w == 0 || h == 0 { return mask }
        let ax = kw / 2, ay = kh / 2
        var horizontal = [UInt8](repeating: 0, count: w * h)
        var out = [UInt8](repeating: 0, count: w * h)
        mask.data.withUnsafeBufferPointer { src in
            horizontal.withUnsafeMutableBufferPointer { hz in
                // horizontal: any set in [x-ax, x-ax+kw-1], by a sliding count
                for y in 0..<h {
                    let row = y * w
                    var count = 0
                    // initial window for x = 0: columns [-ax, kw-1-ax]
                    var hi = -1
                    let first = kw - 1 - ax
                    while hi < min(first, w - 1) { hi += 1; count += Int(src[row + hi] ^ flip) }
                    for x in 0..<w {
                        hz[row + x] = count > 0 ? 1 : 0
                        let add = x + 1 + kw - 1 - ax
                        if add < w { count += Int(src[row + add] ^ flip) }
                        let drop = x - ax
                        if drop >= 0 { count -= Int(src[row + drop] ^ flip) }
                    }
                }
            }
        }
        // vertical on the (already flipped-domain) horizontal result
        horizontal.withUnsafeBufferPointer { hz in
            out.withUnsafeMutableBufferPointer { o in
                var counts = [Int32](repeating: 0, count: w)
                var hi = -1
                let first = kh - 1 - ay
                while hi < min(first, h - 1) {
                    hi += 1
                    for x in 0..<w { counts[x] += Int32(hz[hi * w + x]) }
                }
                for y in 0..<h {
                    for x in 0..<w { o[y * w + x] = (counts[x] > 0 ? 1 : 0) ^ flip }
                    let add = y + 1 + kh - 1 - ay
                    if add < h { for x in 0..<w { counts[x] += Int32(hz[add * w + x]) } }
                    let drop = y - ay
                    if drop >= 0 { for x in 0..<w { counts[x] -= Int32(hz[drop * w + x]) } }
                }
            }
        }
        return BinaryMask(width: w, height: h, data: out)
    }

    /// cv2.dilate with np.ones((kh, kw)) and the default border (outside unset).
    public static func dilate(_ mask: BinaryMask, kernelWidth kw: Int, kernelHeight kh: Int) -> BinaryMask {
        windowAny(mask, kw: kw, kh: kh, flip: 0)
    }

    /// cv2.erode with np.ones((kh, kw)) and the default border (outside set).
    public static func erode(_ mask: BinaryMask, kernelWidth kw: Int, kernelHeight kh: Int) -> BinaryMask {
        // erode(m) = not dilate(not m): the horizontal pass sees the inverted input
        windowAny(mask, kw: kw, kh: kh, flip: 1)
    }

    public static func dilate(_ mask: BinaryMask, kernel k: Int) -> BinaryMask { dilate(mask, kernelWidth: k, kernelHeight: k) }
    public static func erode(_ mask: BinaryMask, kernel k: Int) -> BinaryMask { erode(mask, kernelWidth: k, kernelHeight: k) }

    /// cv2.morphologyEx(MORPH_OPEN): erode then dilate.
    public static func open(_ mask: BinaryMask, kernel k: Int) -> BinaryMask { dilate(erode(mask, kernel: k), kernel: k) }

    /// cv2.morphologyEx(MORPH_CLOSE): dilate then erode.
    public static func close(_ mask: BinaryMask, kernel k: Int) -> BinaryMask { erode(dilate(mask, kernel: k), kernel: k) }
}
