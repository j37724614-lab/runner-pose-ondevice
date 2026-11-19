/// Images the long-jump analysis reads: an 8-bit colour frame, binary masks and float grids.
/// Plain arrays, no CoreGraphics / CoreVideo, so the code builds on Linux; the app wraps its
/// decoded `CVPixelBuffer` (BGRA) in a `PixelImage` without changing the bytes.

/// An 8-bit colour image, row-major, `bytesPerRow` may include padding.
public struct PixelImage: Sendable, Equatable {
    public enum Layout: Sendable, Equatable {
        case bgr, bgra, rgb, rgba

        public var channels: Int {
            switch self {
            case .bgr, .rgb: return 3
            case .bgra, .rgba: return 4
            }
        }
    }

    public let width: Int
    public let height: Int
    public let layout: Layout
    public let bytesPerRow: Int
    public let data: [UInt8]

    public init(width: Int, height: Int, layout: Layout, bytesPerRow: Int? = nil, data: [UInt8]) {
        let rowBytes = bytesPerRow ?? width * layout.channels
        precondition(width > 0 && height > 0 && rowBytes >= width * layout.channels)
        precondition(data.count >= rowBytes * (height - 1) + width * layout.channels)
        self.width = width
        self.height = height
        self.layout = layout
        self.bytesPerRow = rowBytes
        self.data = data
    }

    /// (blue, green, red) of pixel (x, y).
    @inline(__always)
    public func bgr(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        let i = y * bytesPerRow + x * layout.channels
        switch layout {
        case .bgr, .bgra: return (data[i], data[i + 1], data[i + 2])
        case .rgb, .rgba: return (data[i + 2], data[i + 1], data[i])
        }
    }
}

/// A binary image (OpenCV CV_8U 0/1 or numpy bool), row-major, one byte per pixel.
public struct BinaryMask: Sendable, Equatable {
    public let width: Int
    public let height: Int
    /// 0 or 1 per pixel.
    public var data: [UInt8]

    public init(width: Int, height: Int, data: [UInt8]? = nil) {
        precondition(width >= 0 && height >= 0)
        self.width = width
        self.height = height
        self.data = data ?? [UInt8](repeating: 0, count: width * height)
        precondition(self.data.count == width * height)
    }

    /// Mask from runs `[row, start, end)` (the fixtures' encoding).
    public init(width: Int, height: Int, runs: [(row: Int, start: Int, end: Int)]) {
        self.init(width: width, height: height)
        for run in runs {
            for x in run.start..<run.end { data[run.row * width + x] = 1 }
        }
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> Bool {
        get { data[y * width + x] != 0 }
        set { data[y * width + x] = newValue ? 1 : 0 }
    }

    /// Number of set pixels.
    public var count: Int { data.reduce(0) { $0 + Int($1 != 0 ? 1 : 0) } }

    /// Runs `[row, start, end)` of the set pixels, row by row (the fixtures' encoding).
    public var runs: [(row: Int, start: Int, end: Int)] {
        var out: [(row: Int, start: Int, end: Int)] = []
        for y in 0..<height {
            var x = 0
            while x < width {
                if data[y * width + x] != 0 {
                    let start = x
                    while x < width && data[y * width + x] != 0 { x += 1 }
                    out.append((y, start, x))
                } else {
                    x += 1
                }
            }
        }
        return out
    }
}

/// A row-major grid of values (distance transforms, label images, HSV planes).
public struct Grid<Element: Sendable>: Sendable {
    public let width: Int
    public let height: Int
    public var values: [Element]

    public init(width: Int, height: Int, repeating value: Element) {
        self.width = width
        self.height = height
        self.values = [Element](repeating: value, count: width * height)
    }

    public init(width: Int, height: Int, values: [Element]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    @inline(__always)
    public subscript(x: Int, y: Int) -> Element {
        get { values[y * width + x] }
        set { values[y * width + x] = newValue }
    }
}

extension Grid: Equatable where Element: Equatable {}
