import Foundation
import XCTest
@testable import LongJumpKit

/// Fixture access for the LongJumpKit parity tests.
///
/// - Unit fixtures (committed, small): `Fixtures/unit/*.json`, from
///   scripts/longjump/make_unit_fixtures.py.
/// - Real cases (gitignored, ~0.6 GB): `testdata/longjump/<case>/`, from
///   scripts/longjump/dump_longjump_fixtures.py.  `$LONGJUMP_FIXTURES` overrides the folder.
///   Tests that need them call `try LongJumpCase.all()`, which skips the test when the folder
///   is missing.
enum Fixtures {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // LongJumpKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()

    static var casesRoot: URL {
        if let override = ProcessInfo.processInfo.environment["LONGJUMP_FIXTURES"] {
            return URL(fileURLWithPath: override)
        }
        return repoRoot.appendingPathComponent("testdata/longjump")
    }

    static func unit(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "Fixtures", withExtension: nil)?
                .appendingPathComponent("unit/\(name).json"),
            "missing unit fixture \(name): run scripts/longjump/make_unit_fixtures.py"
        )
        return try readJSON(url)
    }

    static func readJSON(_ url: URL) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }
}

/// One recorded call: `fn` is the Python qualified name ("core.longjump.detection.find_flight").
struct RecordedCall {
    var fn: String
    var args: JSONObject
    var result: JSONValue
    /// Arguments the function changed in place, after the call.
    var after: JSONObject?
    /// sand_mark._nearest_contact_in_batch only: the runner masks the segmenter returned.
    var masks: [JSONValue]?

    /// Short function name ("find_flight").
    var name: String { String(fn.split(separator: ".").last ?? "") }

    func arg(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws -> JSONValue {
        try XCTUnwrap(args[key], "\(fn): no argument \(key)", file: file, line: line)
    }
}

/// One real attempt recorded from the server (testdata/longjump/<name>/).
final class LongJumpCase {
    let name: String
    let folder: URL
    let document: JSONValue

    private var cachedCalls: [RecordedCall]?
    private var cachedTrack: PoseTrack?
    private var cachedFrame: PixelImage??

    init(folder: URL) throws {
        self.folder = folder
        self.name = folder.lastPathComponent
        self.document = try Fixtures.readJSON(folder.appendingPathComponent("case.json"))
    }

    /// Every case listed in index.json; skips the calling test when the fixtures are missing.
    static func all(file: StaticString = #filePath, line: UInt = #line) throws -> [LongJumpCase] {
        let index = Fixtures.casesRoot.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: index.path) else {
            throw XCTSkip("no \(index.path): run scripts/longjump/dump_longjump_fixtures.py", file: file, line: line)
        }
        let cases = try XCTUnwrap(Fixtures.readJSON(index)["cases"]?.arrayValue)
        return try cases.compactMap { $0["name"]?.stringValue }.map {
            try LongJumpCase(folder: Fixtures.casesRoot.appendingPathComponent($0))
        }
    }

    var cameraIndex: Int? { document["camera_index"]?.intValue }

    /// The pit calibration the server used (nil for the GT jumps).
    var pit: PitCalibration? {
        guard let pit = document["pit"], !pit.isNull else { return nil }
        return PitCalibration(
            imagePoints: pit["image_points"]!.arrayValue!.map { $0.point2 },
            worldPoints: pit["world_points"]!.arrayValue!.map { $0.point2 },
            boardOffsetM: pit["board_offset_m"]!.doubleValue!
        )
    }

    /// The case's full pose track (pose/keypoints_2d.json, the server's camera).
    func fullTrack() throws -> PoseTrack {
        if let cachedTrack { return cachedTrack }
        let data = try Data(contentsOf: folder.appendingPathComponent("pose/keypoints_2d.json"))
        let track = try PoseTrack.load(keypointsJSON: data, cameraIndex: cameraIndex)
        cachedTrack = track
        return track
    }

    /// `{"$track": n}` -> the first n frames of the full track.
    func track(_ value: JSONValue) throws -> PoseTrack {
        let n = try XCTUnwrap(value["$track"]?.intValue, "not a track reference: \(value)")
        return try fullTrack().until(n)
    }

    /// The first video frame (BGR), or nil when the case has none.
    func firstFrame() throws -> PixelImage? {
        if let cachedFrame { return cachedFrame }
        var image: PixelImage?
        if let info = document["first_frame"], !info.isNull {
            let data = try Data(contentsOf: folder.appendingPathComponent(info["file"]!.stringValue!))
            image = PixelImage(
                width: info["width"]!.intValue!,
                height: info["height"]!.intValue!,
                layout: .bgr,
                data: [UInt8](data)
            )
        }
        cachedFrame = .some(image)
        return image
    }

    /// Every recorded call, in the order the calls returned.
    func calls() throws -> [RecordedCall] {
        if let cachedCalls { return cachedCalls }
        let document = try Fixtures.readJSON(folder.appendingPathComponent("calls.json"))
        let calls = try XCTUnwrap(document["calls"]?.arrayValue).map { call in
            RecordedCall(
                fn: call["fn"]!.stringValue!,
                args: call["args"]?.objectValue ?? JSONObject(),
                result: call["result"] ?? .null,
                after: call["after"]?.objectValue,
                masks: call["masks"]?.arrayValue
            )
        }
        cachedCalls = calls
        return calls
    }

    /// Recorded calls of one function, by short name ("find_flight").
    func calls(_ name: String) throws -> [RecordedCall] {
        try calls().filter { $0.name == name }
    }

    /// analyse_long_jump's return value (internal "_" keys included).
    func result() throws -> JSONValue {
        try Fixtures.readJSON(folder.appendingPathComponent("result.json"))
    }
}

// MARK: - Decoding fixture values

extension JSONValue {
    /// A number, with the fixtures' "nan" / "inf" / "-inf" strings; nil for null.
    var fixtureDouble: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string("nan"): return .nan
        case .string("inf"): return .infinity
        case .string("-inf"): return -.infinity
        default: return nil
        }
    }

    /// A list of numbers (null -> NaN).
    var doubles: [Double] { (arrayValue ?? []).map { $0.fixtureDouble ?? .nan } }

    var ints: [Int] { (arrayValue ?? []).compactMap(\.intValue) }

    /// [x, y] -> SIMD2.
    var point2: SIMD2<Double> {
        let v = doubles
        return SIMD2(v[0], v[1])
    }

    /// [start, end) tuple -> Range (nil for null).
    var range: Range<Int>? {
        guard let v = arrayValue, v.count == 2, let a = v[0].intValue, let b = v[1].intValue else { return nil }
        return a..<b
    }

    /// `{"$mask": {width, height, runs}}` -> BinaryMask (nil for null).
    var mask: BinaryMask? {
        guard let m = self["$mask"] else { return nil }
        let runs = (m["runs"]?.arrayValue ?? []).map { run -> (row: Int, start: Int, end: Int) in
            let r = run.ints
            return (r[0], r[1], r[2])
        }
        return BinaryMask(width: m["width"]!.intValue!, height: m["height"]!.intValue!, runs: runs)
    }

    var side: Side? { stringValue.flatMap(Side.init(rawValue:)) }
}

extension TakeoffLine {
    /// From a recorded `{"$type": "TakeoffLine", top, bottom}` (nil for null).
    init?(fixture: JSONValue) {
        guard let top = fixture["top"], let bottom = fixture["bottom"] else { return nil }
        self.init(top: top.point2, bottom: bottom.point2)
    }
}

extension BoardContactAssessment {
    init?(fixture value: JSONValue) {
        guard value["$type"]?.stringValue == "BoardContactAssessment" else { return nil }
        self.init(
            footSide: value["foot_side"]?.side,
            boardContactIndex: value["board_contact_index"]?.intValue,
            toeOffIndex: value["toe_off_index"]?.intValue,
            minToeClearancePx: value["min_toe_clearance_px"]?.fixtureDouble,
            clearanceFrameIndex: value["clearance_frame_index"]?.intValue,
            toeOverLine: value["toe_over_line"]?.boolValue,
            takeoffPosition: value["takeoff_position"]?.stringValue.flatMap(TakeoffPosition.init(rawValue:)),
            minBoardDistancePx: value["min_board_distance_px"]?.fixtureDouble
        )
    }
}

extension JumpEvents {
    init?(fixture value: JSONValue) {
        guard value["$type"]?.stringValue == "JumpEvents" else { return nil }
        self.init(
            flightStart: value["flight_start"]!.intValue!,
            flightEnd: value["flight_end"]!.intValue!,
            apex: value["apex"]!.intValue!,
            boardContact: value["board_contact"]?.intValue,
            toeOff: value["toe_off"]?.intValue,
            sandLanding: value["sand_landing"]?.intValue,
            takeoffAssessment: value["takeoff_assessment"].flatMap(BoardContactAssessment.init(fixture:)),
            sandLandingReview: (value["sand_landing_review"]?.arrayValue ?? []).compactMap(\.stringValue)
        )
    }
}

extension BoardView {
    init?(fixture value: JSONValue) {
        guard value["$type"]?.stringValue == "BoardView", let mask = value["mask"]?.mask else { return nil }
        self.init(mask: mask, line: value["line"].flatMap(TakeoffLine.init(fixture:)))
    }
}

extension SandMark {
    init?(fixture value: JSONValue) {
        guard value["$type"]?.stringValue == "SandMark" else { return nil }
        let px = value["image_px"]!.ints
        self.init(
            frame: value["frame"]!.intValue!,
            imagePx: SIMD2(px[0], px[1]),
            joint: value["joint"]?.stringValue,
            bodyPart: value["body_part"]?.stringValue,
            framesSearched: value["frames_searched"]!.intValue!
        )
    }
}

// MARK: - Comparing

/// Element-wise comparison with NaN == NaN; `tolerance` absolute.
func assertDoublesEqual(
    _ actual: [Double], _ expected: [Double], tolerance: Double = 0, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) {
    guard actual.count == expected.count else {
        return XCTFail("\(message()): count \(actual.count) != \(expected.count)", file: file, line: line)
    }
    for i in actual.indices where !sameDouble(actual[i], expected[i], tolerance) {
        return XCTFail("\(message()): [\(i)] \(actual[i]) != \(expected[i])", file: file, line: line)
    }
}

func sameDouble(_ a: Double, _ b: Double, _ tolerance: Double = 0) -> Bool {
    if a.isNaN || b.isNaN { return a.isNaN && b.isNaN }
    if a.isInfinite || b.isInfinite { return a == b }
    return Swift.abs(a - b) <= tolerance
}

/// Recursive comparison of a Swift-built JSON value with a recorded one.  Numbers compare with
/// `tolerance` (absolute), ints and doubles interchangeably; "nan" strings match NaN.  Returns the
/// differences as "path: actual != expected" lines (empty when equal).
func jsonDifferences(_ actual: JSONValue, _ expected: JSONValue, tolerance: Double = 1e-9, path: String = "$") -> [String] {
    if let a = actual.fixtureDouble, let e = expected.fixtureDouble,
       actual.stringValue == nil || expected.stringValue == nil || a.isNaN {
        return sameDouble(a, e, tolerance) ? [] : ["\(path): \(a) != \(e)"]
    }
    switch (actual, expected) {
    case (.object(let a), .object(let e)):
        var out: [String] = []
        for key in Set(a.keys).union(e.keys).sorted() {
            switch (a[key], e[key]) {
            case (nil, _): out.append("\(path).\(key): missing")
            case (_, nil): out.append("\(path).\(key): unexpected")
            case (let x?, let y?): out += jsonDifferences(x, y, tolerance: tolerance, path: "\(path).\(key)")
            }
        }
        return out
    case (.array(let a), .array(let e)):
        guard a.count == e.count else { return ["\(path): \(a.count) items != \(e.count)"] }
        return zip(a, e).enumerated().flatMap { i, pair in
            jsonDifferences(pair.0, pair.1, tolerance: tolerance, path: "\(path)[\(i)]")
        }
    default:
        return actual == expected ? [] : ["\(path): \(actual.serialized(indent: nil)) != \(expected.serialized(indent: nil))"]
    }
}
