/// 64-bit FNV-1a, used to compare large intermediate images (masks, HSV planes) with the server's
/// without storing them: scripts/longjump/*.py compute the same hashes.
public enum FNV1a64 {
    static let offset: UInt64 = 0xCBF2_9CE4_8422_2325
    static let prime: UInt64 = 0x0000_0100_0000_01B3

    /// FNV-1a 64 of a byte sequence, as 16 lowercase hex digits.
    public static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        format(hash(bytes))
    }

    public static func hash<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var h = offset
        for byte in bytes {
            h ^= UInt64(byte)
            h = h &* prime
        }
        return h
    }

    /// Image hash: FNV-1a 64 of every row (`rowLength` bytes, all channels), then FNV-1a 64 of
    /// those row hashes as little-endian bytes (`fnv1a64_rows` in the Python scripts).
    public static func rows(_ bytes: [UInt8], rowLength: Int) -> String {
        precondition(rowLength > 0 && bytes.count % rowLength == 0)
        var rowHashes: [UInt8] = []
        rowHashes.reserveCapacity(bytes.count / rowLength * 8)
        bytes.withUnsafeBufferPointer { buffer in
            var start = 0
            while start < buffer.count {
                var h = offset
                for i in start..<(start + rowLength) {
                    h ^= UInt64(buffer[i])
                    h = h &* prime
                }
                for shift in stride(from: 0, to: 64, by: 8) {
                    rowHashes.append(UInt8(truncatingIfNeeded: h >> UInt64(shift)))
                }
                start += rowLength
            }
        }
        return hex(rowHashes)
    }

    static func format(_ value: UInt64) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
