import XCTest
@testable import LongJumpKit

/// ImageOps against OpenCV 4.13 (Fixtures/unit/opencv.json).
final class ImageOpsTests: XCTestCase {
    private var fixture: JSONValue!

    override func setUpWithError() throws {
        fixture = try Fixtures.unit("opencv")
    }

    private func mask(_ c: JSONValue, _ key: String) -> BinaryMask {
        let runs = c[key]!.arrayValue!.map { run -> (row: Int, start: Int, end: Int) in
            let r = run.ints
            return (r[0], r[1], r[2])
        }
        return BinaryMask(width: c["width"]!.intValue!, height: c["height"]!.intValue!, runs: runs)
    }

    func testHSVSamples() throws {
        let hsv = fixture["hsv"]!
        let bgr = hsv["samples_bgr"]!.arrayValue!.flatMap { $0.ints.map { UInt8($0) } }
        let expected = hsv["samples_hsv"]!.arrayValue!.flatMap { $0.ints.map { UInt8($0) } }
        let image = PixelImage(width: bgr.count / 3, height: 1, layout: .bgr, data: bgr)
        XCTAssertEqual(ImageOps.bgrToHSV(image).data, expected)
    }

    func testHSVEveryColor() throws {
        var data = [UInt8](repeating: 0, count: 4096 * 4096 * 3)
        for i in 0..<(1 << 24) {
            data[i * 3] = UInt8(i >> 16)
            data[i * 3 + 1] = UInt8((i >> 8) & 255)
            data[i * 3 + 2] = UInt8(i & 255)
        }
        let hsv = ImageOps.bgrToHSV(PixelImage(width: 4096, height: 4096, layout: .bgr, data: data))
        XCTAssertEqual(FNV1a64.rows(hsv.data, rowLength: 4096 * 3), fixture["hsv"]!["every_color_hsv_fnv1a64_rows"]!.stringValue)
    }

    func testMorphology() throws {
        for (n, c) in fixture["morphology"]!.arrayValue!.enumerated() {
            let input = mask(c, "input")
            XCTAssertEqual(ImageOps.open(input, kernel: 3), mask(c, "open3"), "open3 case \(n)")
            XCTAssertEqual(ImageOps.close(input, kernel: 5), mask(c, "close5"), "close5 case \(n)")
            XCTAssertEqual(ImageOps.dilate(input, kernel: 13), mask(c, "dilate13"), "dilate13 case \(n)")
            XCTAssertEqual(ImageOps.erode(input, kernel: 3), mask(c, "erode3"), "erode3 case \(n)")
        }
    }

    func testConnectedComponents() throws {
        for (n, c) in fixture["connected_components"]!.arrayValue!.enumerated() {
            let result = ImageOps.connectedComponentsWithStats(mask(c, "input"))
            XCTAssertEqual(result.count, c["count"]!.intValue, "count case \(n)")
            let labels = c["labels"]!.arrayValue!.flatMap { $0.ints.map { Int32($0) } }
            XCTAssertEqual(result.labels, labels, "labels case \(n)")
            let stats = c["stats"]!.arrayValue!.map { $0.ints }
            XCTAssertEqual(result.stats.count, stats.count)
            for (i, s) in result.stats.enumerated() {
                XCTAssertEqual([s.x, s.y, s.width, s.height, s.area], stats[i], "stats case \(n) label \(i)")
            }
        }
    }

    func testDistanceTransform() throws {
        for (n, c) in fixture["distance_transform_l2_5"]!.arrayValue!.enumerated() {
            let result = ImageOps.distanceTransformL2x5(mask(c, "input"))
            let expected = c["output"]!.arrayValue!.flatMap { $0.doubles.map { Float($0) } }
            let bad = zip(result.values, expected).enumerated().filter { $0.element.0.bitPattern != $0.element.1.bitPattern }
            XCTAssertTrue(bad.isEmpty, "case \(n) \(c["width"]!.intValue!)x\(c["height"]!.intValue!): \(bad.count) differ, first \(bad.prefix(4).map { "\($0.offset): \($0.element.0) vs \($0.element.1)" })")
        }
    }

    func testFitLineHuber() throws {
        for (n, c) in fixture["fit_line_huber"]!.arrayValue!.enumerated() {
            let points = c["points"]!.arrayValue!.map { p -> SIMD2<Float> in
                let v = p.doubles
                return SIMD2(Float(v[0]), Float(v[1]))
            }
            let fit = ImageOps.fitLineHuber(points)
            let expected = c["output"]!.doubles.map { Float($0) }
            XCTAssertEqual([fit.vx, fit.vy, fit.x0, fit.y0].map(\.bitPattern), expected.map(\.bitPattern), "case \(n): \(fit) vs \(expected)")
        }
    }
}
