import XCTest
@testable import LongJumpKit

/// NP / PyRound / FNV1a64 against numpy, scipy and Python (Fixtures/unit/numerics.json).
final class NumericsTests: XCTestCase {
    private var fixture: JSONValue!

    override func setUpWithError() throws {
        fixture = try Fixtures.unit("numerics")
    }

    func testFillNaN() throws {
        for c in fixture["fill_nan"]!.arrayValue! {
            assertDoublesEqual(NP.fillNaN(c["input"]!.doubles), c["output"]!.doubles, "fill_nan \(c["input"]!)")
        }
    }

    func testGradient() throws {
        for c in fixture["gradient"]!.arrayValue! {
            assertDoublesEqual(NP.gradient(c["input"]!.doubles), c["output"]!.doubles, "gradient \(c["input"]!)")
        }
    }

    func testMedianFilter() throws {
        for c in fixture["median_filter"]!.arrayValue! {
            let size = c["size"]!.intValue!
            assertDoublesEqual(
                NP.medianFilterNearest(c["input"]!.doubles, size: size), c["output"]!.doubles, "median_filter size \(size)"
            )
        }
    }

    func testPercentileAndMedian() throws {
        for c in fixture["percentile"]!.arrayValue! {
            let q = c["q"]!.fixtureDouble!
            XCTAssertTrue(
                sameDouble(NP.percentile(c["input"]!.doubles, q), c["output"]!.fixtureDouble!),
                "percentile \(q) of \(c["input"]!): \(NP.percentile(c["input"]!.doubles, q)) != \(c["output"]!)"
            )
        }
        for c in fixture["median"]!.arrayValue! {
            XCTAssertTrue(sameDouble(NP.median(c["input"]!.doubles), c["output"]!.fixtureDouble!), "median \(c["input"]!)")
        }
    }

    func testNaNStatistics() throws {
        for c in fixture["nan_stats"]!.arrayValue! {
            let v = c["input"]!.doubles
            let label = "\(c["input"]!)"
            XCTAssertTrue(sameDouble(NP.nanMedian(v), c["nanmedian"]!.fixtureDouble!), "nanmedian \(label)")
            XCTAssertTrue(sameDouble(NP.nanMean(v), c["nanmean"]!.fixtureDouble!), "nanmean \(label)")
            XCTAssertTrue(sameDouble(NP.nanMax(v), c["nanmax"]!.fixtureDouble!), "nanmax \(label)")
            XCTAssertTrue(sameDouble(NP.nanMin(v), c["nanmin"]!.fixtureDouble!), "nanmin \(label)")
            XCTAssertEqual(NP.nanArgmin(v), c["nanargmin"]!.intValue, "nanargmin \(label)")
            XCTAssertEqual(NP.nanArgmax(v), c["nanargmax"]!.intValue, "nanargmax \(label)")
            XCTAssertEqual(NP.argmin(v), c["argmin"]!.intValue, "argmin \(label)")
            XCTAssertEqual(NP.argmax(v), c["argmax"]!.intValue, "argmax \(label)")
        }
    }

    func testSumMatchesNumpyPairwiseSummation() throws {
        // nanmean of 25 values goes through numpy's 8-way blocked sum; checked above.  Here the
        // block structure itself on exactly representable values.
        XCTAssertEqual(NP.sum((1...200).map(Double.init)), 20100)
        XCTAssertEqual(NP.sum([]), 0)
    }

    func testPythonAndNumpyRounding() throws {
        for c in fixture["round"]!.arrayValue! {
            let x = c["x"]!.fixtureDouble!
            let digits = c["digits"]!.intValue!
            XCTAssertEqual(PyRound.python(x, digits), c["python"]!.fixtureDouble!, "round(\(x), \(digits))")
            XCTAssertEqual(PyRound.numpy(x, digits), c["numpy"]!.fixtureDouble!, "np round(\(x), \(digits))")
        }
        for c in fixture["round_int"]!.arrayValue! {
            XCTAssertEqual(PyRound.toInt(c["x"]!.fixtureDouble!), c["output"]!.intValue!, "round(\(c["x"]!))")
        }
    }

    func testFNV1a() {
        XCTAssertEqual(FNV1a64.hex(Array("long jump".utf8)), "a43a669b87bd7341")
    }

    func testJSONSerialisationFollowsPython() {
        let value: JSONValue = ["status": "jump", "fps": 59.937, "official_m": 2.0, "frame": 87, "distance": nil, "warnings": []]
        XCTAssertEqual(
            value.serialized(indent: nil),
            #"{"status": "jump", "fps": 59.937, "official_m": 2.0, "frame": 87, "distance": null, "warnings": []}"#
        )
        XCTAssertEqual(JSONValue.pythonFloat(1e-05), "1e-05")
        XCTAssertEqual(JSONValue.pythonFloat(-0.0), "-0.0")
    }
}
