import SQLite3
import UIKit
import WebKit

private let scheme = "sherpa-map"
private let mapDir = "assets/maps/yosemite"
private let required = ["pdf": "yosemite.mbtiles", "terrain": "yosemite-terrain.mbtiles"]
private let optional = ["imagery": "yosemite-imagery.mbtiles"]

// Sherpa palette (lib/ui/theme.dart)
private let ink = UIColor(red: 0x14 / 255, green: 0x20 / 255, blue: 0x19 / 255, alpha: 1)
private let inkMuted = UIColor(red: 0x48 / 255, green: 0x5B / 255, blue: 0x4F / 255, alpha: 1)
private let paper = UIColor(red: 0xF4 / 255, green: 0xF7 / 255, blue: 0xF4 / 255, alpha: 1)
private let clay = UIColor(red: 0xD9 / 255, green: 0x48 / 255, blue: 0x19 / 255, alpha: 1)
private let water = UIColor(red: 0x1F / 255, green: 0x6F / 255, blue: 0xA8 / 255, alpha: 1)
private let line = UIColor(red: 0xD9 / 255, green: 0xE0 / 255, blue: 0xD9 / 255, alpha: 1)

/// Offline 3D map of Yosemite on iOS: aerial imagery (or the printed NPS park map) draped over
/// real terrain, in MapLibre GL inside a WKWebView. The page and every tile are served from the
/// app's Flutter assets by a custom URL scheme (tiles read straight from the MBTiles with SQLite),
/// so it needs no network. Under the map a search box finds a place on the park map, flies there
/// and lists the map's guidance for that spot, or for the GPS position. Same behaviour as
/// android/.../map3d/Map3dActivity.kt.
final class Map3dViewController: UIViewController, WKScriptMessageHandler, UITextFieldDelegate {
  var onClose: ((Bool) -> Void)?  // true: the user tapped "Home"

  private let assetPath: (String) -> String?
  private let me: LatLon?
  private let tiles: TileStore?
  private let pack: MapPack?
  private var webView: WKWebView!
  private var pageLoaded = false
  private var pending: [String] = []

  private let search = UITextField()
  private let results = UIStackView()
  private let titleLabel = UILabel()
  private let subtitle = UILabel()
  private let guidance = UIStackView()

  static func available(assetPath: (String) -> String?) -> Bool {
    required.values.allSatisfy { assetPath("\(mapDir)/\($0)") != nil }
  }

  init(assetPath: @escaping (String) -> String?, me: LatLon?) {
    self.assetPath = assetPath
    self.me = me
    self.tiles = TileStore(assetPath: assetPath)
    self.pack = assetPath("\(mapDir)/mappack.json")
      .flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
      .flatMap { try? MapPack(json: $0) }
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("not used") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = paper

    let config = WKWebViewConfiguration()
    config.setURLSchemeHandler(SchemeHandler(assetPath: assetPath, tiles: tiles), forURLScheme: scheme)
    config.userContentController.add(WeakMessageHandler(self), name: "Host")
    webView = WKWebView(frame: .zero, configuration: config)
    webView.isOpaque = false
    webView.backgroundColor = .black
    webView.scrollView.isScrollEnabled = false
    #if DEBUG
    if #available(iOS 16.4, *) { webView.isInspectable = true }
    #endif

    let home = pill(title: "‹  Home", fill: ink, text: .white, bold: true)
    home.accessibilityLabel = "Back to the home screen"
    home.addAction(UIAction { [weak self] _ in self?.close(home: true) }, for: .touchUpInside)

    let mapArea = UIView()
    mapArea.backgroundColor = .black
    for v in [webView!, home] { v.translatesAutoresizingMaskIntoConstraints = false; mapArea.addSubview(v) }
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: mapArea.topAnchor),
      webView.bottomAnchor.constraint(equalTo: mapArea.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: mapArea.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: mapArea.trailingAnchor),
      home.topAnchor.constraint(equalTo: mapArea.topAnchor, constant: 12),
      home.leadingAnchor.constraint(equalTo: mapArea.leadingAnchor, constant: 12),
    ])

    let panel = buildPanel()
    for v in [mapArea, panel] { v.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(v) }
    NSLayoutConstraint.activate([
      mapArea.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      mapArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      mapArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      mapArea.bottomAnchor.constraint(equalTo: panel.topAnchor),
      panel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      panel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
      // the panel rides above the keyboard while typing
      panel.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
    ])

    var query = "tiles=/tiles"
    query += "&pdfMax=\(tiles?.metadata("pdf", "maxzoom") ?? "13")"
    query += "&demMax=\(tiles?.metadata("terrain", "maxzoom") ?? "11")"
    query += "&imgMax=\(tiles?.has("imagery") == true ? (tiles?.metadata("imagery", "maxzoom") ?? "13") : "0")"
    query += "&bounds=\(tiles?.metadata("pdf", "bounds") ?? "")"
    webView.load(URLRequest(url: URL(string: "\(scheme)://app/map3d/index.html?\(query)")!))

    if let me { showMe(me) } else { showIntro() }
  }

  // -- panel under the map --------------------------------------------------------------------

  private func buildPanel() -> UIView {
    search.placeholder = "Search a place, e.g. Half Dome"
    search.font = .systemFont(ofSize: 16)
    search.textColor = ink
    search.backgroundColor = .white
    search.layer.cornerRadius = 10
    search.layer.borderWidth = 1
    search.layer.borderColor = line.cgColor
    search.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
    search.leftViewMode = .always
    search.returnKeyType = .search
    search.autocorrectionType = .no
    search.clearButtonMode = .whileEditing
    search.isEnabled = pack != nil
    search.delegate = self
    search.accessibilityLabel = "Search a place"
    search.addAction(UIAction { [weak self] _ in self?.updateResults() }, for: .editingChanged)
    search.heightAnchor.constraint(equalToConstant: 44).isActive = true

    let myLocation = pill(title: "◎  My location", fill: .white, text: ink, bold: false, border: ink)
    myLocation.accessibilityLabel = "Guidance for my location"
    myLocation.isEnabled = me != nil && pack != nil
    myLocation.alpha = myLocation.isEnabled ? 1 : 0.4
    myLocation.addAction(UIAction { [weak self] _ in
      guard let self, let me = self.me else { return }
      self.search.resignFirstResponder()
      self.showMe(me)
    }, for: .touchUpInside)

    let searchRow = UIStackView(arrangedSubviews: [search, myLocation])
    searchRow.spacing = 8
    searchRow.alignment = .center
    myLocation.setContentHuggingPriority(.required, for: .horizontal)

    results.axis = .vertical
    results.isHidden = true
    results.backgroundColor = .white
    results.layer.cornerRadius = 10
    results.layer.borderWidth = 1
    results.layer.borderColor = line.cgColor
    results.isLayoutMarginsRelativeArrangement = true
    results.layoutMargins = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)

    titleLabel.font = .boldSystemFont(ofSize: 18)
    titleLabel.textColor = ink
    subtitle.font = .systemFont(ofSize: 13)
    subtitle.textColor = inkMuted
    guidance.axis = .vertical
    guidance.spacing = 10

    let details = UIStackView(arrangedSubviews: [titleLabel, subtitle, guidance])
    details.axis = .vertical
    details.spacing = 4
    details.setCustomSpacing(10, after: subtitle)
    let scroll = UIScrollView()
    scroll.keyboardDismissMode = .onDrag
    details.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(details)
    NSLayoutConstraint.activate([
      details.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
      details.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
      details.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      details.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      details.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
    ])
    let scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 220)
    scrollHeight.priority = .defaultHigh  // gives way to the keyboard
    scrollHeight.isActive = true

    let panel = UIStackView(arrangedSubviews: [searchRow, results, scroll])
    panel.axis = .vertical
    panel.spacing = 8
    panel.backgroundColor = paper
    panel.isLayoutMarginsRelativeArrangement = true
    panel.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
    return panel
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if let best = pack?.search(textField.text ?? "", limit: 1).first { choose(best.place) }
    return true
  }

  private func updateResults() {
    results.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let q = (search.text ?? "").trimmingCharacters(in: .whitespaces)
    let hits = q.count >= 2 ? (pack?.search(q, limit: 5) ?? []) : []
    results.isHidden = hits.isEmpty
    for hit in hits {
      var conf = UIButton.Configuration.plain()
      conf.title = hit.place.text
      conf.subtitle = formatLatLon(hit.place.location)
      conf.baseForegroundColor = ink
      conf.titleAlignment = .leading
      conf.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
      conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
        var a = a
        a.font = hit.exact ? .boldSystemFont(ofSize: 15) : .systemFont(ofSize: 15)
        return a
      }
      let b = UIButton(configuration: conf)
      b.contentHorizontalAlignment = .leading
      b.accessibilityLabel = "Result: \(hit.place.text)"
      b.addAction(UIAction { [weak self] _ in self?.choose(hit.place) }, for: .touchUpInside)
      results.addArrangedSubview(b)
    }
  }

  private func choose(_ place: Place) {
    guard let pack else { return }
    search.text = place.text
    results.isHidden = true
    search.resignFirstResponder()
    js("showPlace(\(place.location.lat), \(place.location.lon), \(jsString(place.text)))")
    show(place.text, formatLatLon(place.location), pack.guidanceFor(place))
  }

  private func showMe(_ me: LatLon) {
    js("showMe(\(me.lat), \(me.lon))")
    guard let pack else { return show("Your location", formatLatLon(me), []) }
    let where_ = formatLatLon(me) + (pack.isOnMap(me) ? "" : " · outside the park map")
    show("Your location", where_, pack.guidanceAt(me))
  }

  private func showIntro() {
    show("Yosemite National Park",
         pack != nil ? "Search a place to see it in 3D with the park map's guidance" : "Place search isn't available",
         [], intro: true)
  }

  /// Title, coordinates and the guidance list, park-wide notes last.
  private func show(_ heading: String, _ where_: String, _ local: [Advisory], intro: Bool = false) {
    titleLabel.text = heading
    subtitle.text = where_
    guidance.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if pack != nil, !intro, local.isEmpty {
      let none = UILabel()
      none.text = "No map notes for this spot."
      none.font = .systemFont(ofSize: 14)
      none.textColor = inkMuted
      guidance.addArrangedSubview(none)
    }
    local.forEach { guidance.addArrangedSubview(advisoryRow($0.note, $0.reason)) }
    pack?.parkWide.forEach { guidance.addArrangedSubview(advisoryRow($0, "park-wide")) }
  }

  private func advisoryRow(_ note: Note, _ reason: String) -> UIView {
    let warning = note.severity == .warning
    let badge = PaddedLabel()
    badge.text = warning ? "WARNING" : "INFO"
    badge.font = .boldSystemFont(ofSize: 11)
    badge.textColor = .white
    badge.backgroundColor = warning ? clay : water
    badge.layer.cornerRadius = 4
    badge.clipsToBounds = true
    badge.setContentHuggingPriority(.required, for: .horizontal)
    badge.setContentCompressionResistancePriority(.required, for: .horizontal)

    let text = UILabel()
    text.text = note.text
    text.font = .systemFont(ofSize: 14)
    text.textColor = ink
    text.numberOfLines = 0
    let why = UILabel()
    why.text = reason
    why.font = .systemFont(ofSize: 12)
    why.textColor = inkMuted
    why.numberOfLines = 0
    let body = UIStackView(arrangedSubviews: [text, why])
    body.axis = .vertical
    body.spacing = 2

    let row = UIStackView(arrangedSubviews: [badge, body])
    row.spacing = 10
    row.alignment = .top
    return row
  }

  // -- web page -------------------------------------------------------------------------------

  func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let msg = message.body as? String else { return }
    NSLog("Map3D: %@", msg)
    if msg == "loaded" {
      pageLoaded = true
      pending.forEach { webView.evaluateJavaScript($0) }
      pending.removeAll()
    }
  }

  private func js(_ code: String) {
    if pageLoaded { webView.evaluateJavaScript(code) } else { pending.append(code) }
  }

  private func close(home: Bool) {
    dismiss(animated: true) { [onClose] in onClose?(home) }
  }

  // -- helpers --------------------------------------------------------------------------------

  private func pill(title: String, fill: UIColor, text: UIColor, bold: Bool, border: UIColor? = nil) -> UIButton {
    var conf = UIButton.Configuration.filled()
    conf.title = title
    conf.baseBackgroundColor = fill
    conf.baseForegroundColor = text
    conf.cornerStyle = .capsule
    conf.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
    conf.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { a in
      var a = a
      a.font = bold ? .boldSystemFont(ofSize: 15) : .systemFont(ofSize: 14)
      return a
    }
    if let border { conf.background.strokeColor = border; conf.background.strokeWidth = 1 }
    return UIButton(configuration: conf)
  }

  private func formatLatLon(_ ll: LatLon) -> String { String(format: "%.5f, %.5f", ll.lat, ll.lon) }

  private func jsString(_ s: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [s])
    let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(arr.dropFirst().dropLast())  // the JSON string literal inside ["..."]
  }
}

/// A badge label with a little padding.
private final class PaddedLabel: UILabel {
  override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))) }
  override var intrinsicContentSize: CGSize {
    let s = super.intrinsicContentSize
    return CGSize(width: s.width + 12, height: s.height + 4)
  }
}

/// Breaks the WKUserContentController -> handler retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?
  init(_ target: WKScriptMessageHandler) { self.target = target }
  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    target?.userContentController(c, didReceive: m)
  }
}

/// Serves sherpa-map://app/map3d/<file> from the Flutter assets and
/// sherpa-map://app/tiles/<name>/<z>/<x>/<y>.<ext> from the MBTiles.
private final class SchemeHandler: NSObject, WKURLSchemeHandler {
  private let assetPath: (String) -> String?
  private let tiles: TileStore?

  init(assetPath: @escaping (String) -> String?, tiles: TileStore?) {
    self.assetPath = assetPath
    self.tiles = tiles
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url else { return }
    let parts = url.path.split(separator: "/").map(String.init)
    var body: Data?
    var mime = "application/octet-stream"
    if parts.first == "map3d", parts.count == 2, let path = assetPath("assets/map3d/\(parts[1])") {
      body = try? Data(contentsOf: URL(fileURLWithPath: path))
      mime = parts[1].hasSuffix(".html") ? "text/html" : parts[1].hasSuffix(".css") ? "text/css"
        : parts[1].hasSuffix(".js") ? "text/javascript" : mime
    } else if parts.first == "tiles", parts.count == 5, let z = Int(parts[2]), let x = Int(parts[3]),
              let dot = parts[4].firstIndex(of: "."), let y = Int(parts[4][..<dot]) {
      body = tiles?.tile(parts[1], z: z, x: x, y: y)
      mime = parts[4].hasSuffix(".png") ? "image/png" : "image/jpeg"
    }
    let status = body == nil ? 404 : 200
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Access-Control-Allow-Origin": "*"])!
    task.didReceive(response)
    task.didReceive(body ?? Data())
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// The 3D tilesets: park map ("pdf") and elevation ("terrain") required, imagery optional.
/// MBTiles are SQLite files and the app bundle is readable, so they are opened in place.
private final class TileStore {
  private var dbs: [String: OpaquePointer] = [:]

  init?(assetPath: (String) -> String?) {
    for (name, file) in required.merging(optional, uniquingKeysWith: { a, _ in a }) {
      var db: OpaquePointer?
      if let path = assetPath("\(mapDir)/\(file)"),
         sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db {
        dbs[name] = db
      } else if required[name] != nil {
        return nil
      }
    }
  }

  deinit { dbs.values.forEach { sqlite3_close($0) } }

  func has(_ name: String) -> Bool { dbs[name] != nil }

  func tile(_ name: String, z: Int, x: Int, y: Int) -> Data? {
    guard let db = dbs[name] else { return nil }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    let sql = "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    sqlite3_bind_int(stmt, 1, Int32(z))
    sqlite3_bind_int(stmt, 2, Int32(x))
    sqlite3_bind_int(stmt, 3, Int32((1 << z) - 1 - y))  // MBTiles rows are TMS
    guard sqlite3_step(stmt) == SQLITE_ROW, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
    return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
  }

  func metadata(_ name: String, _ key: String) -> String? {
    guard let db = dbs[name] else { return nil }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT value FROM metadata WHERE name=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
    sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return nil }
    return String(cString: text)
  }
}
