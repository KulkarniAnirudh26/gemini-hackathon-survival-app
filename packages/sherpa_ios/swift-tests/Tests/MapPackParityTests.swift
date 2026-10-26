import Foundation
import XCTest
@testable import MapPack

/// The Swift port must give the same answers as the Python pipeline, like the Kotlin port.
/// Regenerate the fixtures with `python scripts/build_android_assets.py data/yosemite.pdf`.
final class MapPackParityTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()  // repo root
    static let pack = try! MapPack(json: Data(contentsOf: root.appendingPathComponent("assets/maps/yosemite/mappack.json")))
    static let parity = try! JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("android-native/mappack/src/test/resources/parity.json"))
    ) as! [String: Any]

    func testSearchMatchesPythonForEveryPlace() {
        let cases = Self.parity["searches"] as! [[String: Any]]
        var failures: [String] = []
        for c in cases {
            let query = c["query"] as! String
            let lat = c["lat"] as! Double, lon = c["lon"] as! Double
            let hit = Self.pack.search(query).first
            if hit == nil || abs(hit!.place.location.lat - lat) > 1e-5 || abs(hit!.place.location.lon - lon) > 1e-5 {
                failures.append("\(query): python \(c["label"]!) (\(lat), \(lon)), swift \(hit?.place.text ?? "none")")
            }
        }
        XCTAssert(failures.isEmpty, "\(failures.count)/\(cases.count) differ:\n" + failures.joined(separator: "\n"))
        XCTAssertGreaterThan(cases.count, 300)
    }

    func testGpsGuidanceMatchesPython() {
        let cases = Self.parity["positions"] as! [[String: Any]]
        var failures: [String] = []
        for c in cases {
            let at = LatLon(c["lat"] as! Double, c["lon"] as! Double)
            let expected = (c["guidance"] as! [[String: Any]]).map { "\($0["text"]!) | \($0["reason"]!)" }
            let actual = Self.pack.guidanceAt(at).map { "\($0.note.text) | \($0.reason)" }
            if expected != actual { failures.append("\(at)\n  python \(expected)\n  swift  \(actual)") }
        }
        XCTAssert(failures.isEmpty, "\(failures.count)/\(cases.count) differ:\n" + failures.joined(separator: "\n"))
        XCTAssertGreaterThan(cases.count, 400)
    }

    func testPageAndLatLonRoundTrip() {
        for x in [0.0, 300, 1165] {
            for y in [0.0, 600, 1233] {
                let back = Self.pack.latLonToPage(Self.pack.pageToLatLon(PagePoint(x: x, y: y)))
                XCTAssertEqual(back.x, x, accuracy: 1e-6)
                XCTAssertEqual(back.y, y, accuracy: 1e-6)
            }
        }
    }

    func testTiogaClosuresApplyBetweenTheGatesOnly() {
        let olmsted = Self.pack.guidanceFor(Self.pack.search("Olmsted Point")[0].place).map { $0.note.text }
        XCTAssert(olmsted.contains { $0.hasPrefix("Tioga Road closed") })
        let leeVining = Self.pack.guidanceFor(Self.pack.search("Lee Vining")[0].place).map { $0.note.text }
        XCTAssertFalse(leeVining.contains { $0.hasPrefix("Tioga Road closed") })
    }

    func testNormalizeSplitsLigatures() {
        XCTAssertEqual(MapPack.normalize("Paciﬁc Crest Trail"), "pacificcresttrail")
    }
}
