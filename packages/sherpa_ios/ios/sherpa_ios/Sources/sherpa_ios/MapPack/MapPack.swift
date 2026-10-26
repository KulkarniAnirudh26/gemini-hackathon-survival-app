import Foundation

// Swift port of android-native/mappack (MapPack.kt), checked against the same Python answers
// (parity.json) by packages/sherpa_ios/swift-tests. Reads the map pack written by
// `python -m geopdf_locator.export`.

public struct LatLon: Equatable {
    public let lat: Double
    public let lon: Double
    public init(_ lat: Double, _ lon: Double) { self.lat = lat; self.lon = lon }
}

/// A point on the map page, in PDF points from the top-left corner.
public struct PagePoint: Equatable {
    public let x: Double
    public let y: Double
}

public enum Severity { case warning, info }

public struct Note {
    public let id: Int
    public let text: String
    public let severity: Severity
    public let parkWide: Bool
    /// Road or trail the note is about, e.g. "Tioga Road".
    public let feature: String?
    /// "east" in "closed east of this point".
    public let direction: String?
    /// Where the note points on the map; nil for park-wide notes.
    public let anchor: LatLon?
}

public struct Advisory {
    public let note: Note
    public let reason: String
    public let distanceKm: Double?
}

public struct Place {
    public let text: String
    public let location: LatLon
    /// Where the location was taken from on the page (the map symbol, or the label centre).
    public let page: PagePoint
    public let fontSize: Double
    public let snapped: Bool
    public let viaLeader: Bool
    /// All-caps area name ("TUOLUMNE MEADOWS"): the location is the area's label centre.
    public let area: Bool
    let norm: String
    let guidance: [(note: Int, reason: String, distanceKm: Double?)]
}

public struct PlaceHit {
    public let place: Place
    public let exact: Bool
    public let score: Double
}

public enum MapPackError: Error { case invalid(String) }

/// Offline place search and safety guidance for one map. Same rules as the Python
/// `GeoPdfMap.locate` / `Guidance.for_point` and the Kotlin MapPack.
public final class MapPack {
    public static let supportedVersion = 1

    public let notes: [Note]
    public let places: [Place]
    public var parkWide: [Note] { notes.filter { $0.parkWide } }

    private let pageSize: (w: Double, h: Double)
    private let pageToMercator: [[Double]]
    private let mercatorToPage: [[Double]]
    private let radius: Double
    private let kmPerPt, corridorKm, nearbyKm: Double
    private let noteAnchors: [PagePoint?]
    private let notePaths: [[(path: Int, section: [Double]?)]]
    private let paths: [Polyline]

    public init(json data: Data) throws {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MapPackError.invalid("not a JSON object")
        }
        guard o["format"] as? String == "geopdf-mappack" else { throw MapPackError.invalid("not a map pack") }
        guard o["version"] as? Int == MapPack.supportedVersion else { throw MapPackError.invalid("unsupported version") }
        let geo = o["georef"] as! [String: Any]
        guard geo["projection"] as? String == "EPSG:3857" else { throw MapPackError.invalid("unsupported projection") }
        let page = o["page"] as! [String: Any]
        let gp = o["guidance_params"] as! [String: Any]

        pageSize = (Self.num(page["width"]), Self.num(page["height"]))
        pageToMercator = Self.matrix(geo["page_to_mercator"])
        mercatorToPage = Self.matrix(geo["mercator_to_page"])
        radius = Self.num(geo["earth_radius_m"])
        kmPerPt = Self.num(gp["km_per_pt"])
        corridorKm = Self.num(gp["corridor_km"])
        nearbyKm = Self.num(gp["nearby_km"])

        let rawNotes = o["notes"] as! [[String: Any]]
        notes = rawNotes.enumerated().map { i, n in
            let lat = n["lat"] as? Double, lon = n["lon"] as? Double
            return Note(
                id: i,
                text: n["text"] as! String,
                severity: n["severity"] as? String == "warning" ? .warning : .info,
                parkWide: n["scope"] as? String == "park",
                feature: n["feature"] as? String,
                direction: n["direction"] as? String,
                anchor: (lat != nil && lon != nil) ? LatLon(lat!, lon!) : nil
            )
        }
        noteAnchors = rawNotes.map { n in
            guard let x = n["x"] as? Double, let y = n["y"] as? Double else { return nil }
            return PagePoint(x: x, y: y)
        }
        notePaths = rawNotes.map { n in
            ((n["paths"] as? [[String: Any]]) ?? []).map { p in
                (path: p["path"] as! Int, section: (p["section"] as? [Any])?.map { Self.num($0) })
            }
        }
        paths = (o["paths"] as! [[Any]]).map { pts in
            Polyline(pts.map { p -> PagePoint in
                let xy = p as! [Any]
                return PagePoint(x: Self.num(xy[0]), y: Self.num(xy[1]))
            })
        }
        places = (o["labels"] as! [[String: Any]]).map { lb in
            Place(
                text: lb["text"] as! String,
                location: LatLon(Self.num(lb["lat"]), Self.num(lb["lon"])),
                page: PagePoint(x: Self.num(lb["x"]), y: Self.num(lb["y"])),
                fontSize: Self.num(lb["size"]),
                snapped: lb["snapped"] as! Bool,
                viaLeader: lb["via_leader"] as! Bool,
                area: lb["area"] as! Bool,
                norm: lb["norm"] as! String,
                guidance: (lb["guidance"] as! [[String: Any]]).map { a in
                    (note: a["note"] as! Int, reason: a["reason"] as! String, distanceKm: a["distance_km"] as? Double)
                }
            )
        }
    }

    // -- coordinates ----------------------------------------------------------------------------

    public func pageToLatLon(_ p: PagePoint) -> LatLon {
        let (mx, my) = Self.affine(pageToMercator, p.x, p.y)
        return LatLon((2 * atan(exp(my / radius)) - .pi / 2) * 180 / .pi, mx / radius * 180 / .pi)
    }

    public func latLonToPage(_ ll: LatLon) -> PagePoint {
        let mx = radius * ll.lon * .pi / 180
        let my = radius * log(tan(.pi / 4 + ll.lat * .pi / 180 / 2))
        let (x, y) = Self.affine(mercatorToPage, mx, my)
        return PagePoint(x: x, y: y)
    }

    public func isOnMap(_ ll: LatLon) -> Bool {
        let p = latLonToPage(ll)
        return p.x >= 0 && p.x <= pageSize.w && p.y >= 0 && p.y <= pageSize.h
    }

    // -- search ---------------------------------------------------------------------------------

    /// Places whose label contains [query], best first: exact labels, labels anchored to a map
    /// symbol (especially via a leader line) and larger type rank higher; ties go top to bottom,
    /// then left to right on the page.
    public func search(_ query: String, limit: Int = 20) -> [PlaceHit] {
        let q = Self.normalize(query)
        if q.isEmpty { return [] }
        let hits = places.enumerated().compactMap { i, p -> (Int, PlaceHit)? in
            guard p.norm.contains(q) else { return nil }
            let exact = p.norm == q
            let score = 4.0 * (exact ? 1 : 0) + 2.0 * (p.snapped ? 1 : 0) + 0.5 * (p.viaLeader ? 1 : 0) + 0.25 * p.fontSize
            return (i, PlaceHit(place: p, exact: exact, score: score))
        }
        return hits.sorted { a, b in
            if a.1.score != b.1.score { return a.1.score > b.1.score }
            if a.1.place.page.y != b.1.place.page.y { return a.1.place.page.y < b.1.place.page.y }
            if a.1.place.page.x != b.1.place.page.x { return a.1.place.page.x < b.1.place.page.x }
            return a.0 < b.0
        }.prefix(limit).map { $0.1 }
    }

    // -- guidance -------------------------------------------------------------------------------

    /// Local guidance at a place (precomputed when the pack was built).
    public func guidanceFor(_ place: Place) -> [Advisory] {
        place.guidance.map { Advisory(note: notes[$0.note], reason: $0.reason, distanceKm: $0.distanceKm) }
    }

    /// Local guidance at a GPS position, most relevant first: closures on the road the position
    /// is on (inside the closed stretch only), notes along that road, then notes printed nearby.
    public func guidanceAt(_ position: LatLon) -> [Advisory] {
        let xy = latLonToPage(position)
        let corridorPt = corridorKm / kmPerPt
        var out: [Advisory] = []
        for (i, note) in notes.enumerated() where !note.parkWide {
            var matched = false
            for ref in notePaths[i] {
                let (dist, s) = paths[ref.path].project(xy)
                if dist > corridorPt { continue }
                if let direction = note.direction {
                    if let section = ref.section, s >= section[0], s <= section[1] {
                        out.append(Advisory(note: note, reason: "on \(note.feature ?? ""), \(direction) of the marked point",
                                            distanceKm: dist * kmPerPt))
                        matched = true
                    }
                } else {
                    out.append(Advisory(note: note, reason: "along \(note.feature ?? "")", distanceKm: dist * kmPerPt))
                    matched = true
                }
                break
            }
            if !matched, !(!notePaths[i].isEmpty && note.direction != nil), let anchor = noteAnchors[i] {
                let km = hypot(xy.x - anchor.x, xy.y - anchor.y) * kmPerPt
                if km <= nearbyKm {
                    out.append(Advisory(note: note, reason: "nearby (\(String(format: "%.1f", km)) km)", distanceKm: km))
                }
            }
        }
        func rank(_ a: Advisory) -> Int { a.reason.hasPrefix("on ") || a.reason.hasPrefix("along ") ? 1 : 2 }
        let ranked = out.enumerated().sorted { a, b in
            let (x, y) = (a.element, b.element)
            if rank(x) != rank(y) { return rank(x) < rank(y) }
            let (wx, wy) = (x.note.severity == .warning, y.note.severity == .warning)
            if wx != wy { return wx }
            let (dx, dy) = (x.distanceKm ?? 0, y.distanceKm ?? 0)
            if dx != dy { return dx < dy }
            return a.offset < b.offset  // stable, as in Kotlin and Python
        }.map { $0.element }
        // the same note is often printed more than once along a road; keep the most relevant copy
        var seen = Set<String>()
        return ranked.filter { seen.insert($0.note.text).inserted }
    }

    // -- helpers --------------------------------------------------------------------------------

    /// Same normalisation as the Python and Kotlin sides: compatibility-decompose (accents and
    /// ligatures split), lowercase, then keep [a-z0-9] only.
    public static func normalize(_ text: String) -> String {
        let decomposed = text.decomposedStringWithCompatibilityMapping.lowercased()
        return String(decomposed.unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) })
    }

    private static func affine(_ m: [[Double]], _ x: Double, _ y: Double) -> (Double, Double) {
        (x * m[0][0] + y * m[1][0] + m[2][0], x * m[0][1] + y * m[1][1] + m[2][1])
    }

    private static func num(_ v: Any?) -> Double {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        return .nan
    }

    private static func matrix(_ v: Any?) -> [[Double]] { (v as! [[Any]]).map { $0.map { num($0) } } }
}

/// A road or trail line in page coordinates, with arc-length positions.
struct Polyline {
    let points: [PagePoint]
    let cumulative: [Double]

    init(_ points: [PagePoint]) {
        self.points = points
        var c = [Double](repeating: 0, count: points.count)
        for i in 1..<max(points.count, 1) {
            c[i] = c[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        cumulative = c
    }

    /// (distance from p to the line, arc-length position of the closest point).
    func project(_ p: PagePoint) -> (Double, Double) {
        var bestD = Double.infinity, bestS = 0.0
        for i in 0..<(points.count - 1) {
            let a = points[i], b = points[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let seg2 = dx * dx + dy * dy
            let t = seg2 == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / seg2))
            let d = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            if d < bestD {
                bestD = d
                bestS = cumulative[i] + t * seg2.squareRoot()
            }
        }
        return (bestD, bestS)
    }
}
