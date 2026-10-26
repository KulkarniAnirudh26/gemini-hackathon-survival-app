import Flutter
import UIKit

/// Registers Sherpa's native channels on iOS. On Android the host app (MainActivity.kt)
/// implements the same channels.
@MainActor
public class SherpaIosPlugin: NSObject, FlutterPlugin {
  private let registrar: FlutterPluginRegistrar
  private let ai: AiCore
  private var map3dResult: FlutterResult?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    self.ai = AiCore()
  }

  // Flutter registers plugins and delivers channel calls on the main thread.
  public nonisolated static func register(with registrar: FlutterPluginRegistrar) {
    MainActor.assumeIsolated { setUp(registrar) }
  }

  private static func setUp(_ registrar: FlutterPluginRegistrar) {
    let plugin = SherpaIosPlugin(registrar: registrar)
    let messenger = registrar.messenger()

    let ai = FlutterMethodChannel(name: "survival/ai", binaryMessenger: messenger)
    ai.setMethodCallHandler { call, result in MainActor.assumeIsolated { plugin.ai.handle(call, result: result) } }
    FlutterEventChannel(name: "survival/ai/events", binaryMessenger: messenger).setStreamHandler(plugin.ai)

    let map3d = FlutterMethodChannel(name: "survival/map3d", binaryMessenger: messenger)
    map3d.setMethodCallHandler { call, result in MainActor.assumeIsolated { plugin.handleMap3d(call, result: result) } }
  }

  private func assetPath(_ asset: String) -> String? {
    Bundle.main.path(forResource: registrar.lookupKey(forAsset: asset), ofType: nil)
  }

  private func handleMap3d(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      let ok = Map3dViewController.available(assetPath: assetPath)
      NSLog("Map3D: available=%@", ok ? "yes" : "no")
      result(ok)
    case "open":
      let args = call.arguments as? [String: Any]
      let lat = args?["lat"] as? Double, lon = args?["lon"] as? Double
      guard let top = topViewController() else {
        NSLog("Map3D: no view controller to present from")
        return result(false)
      }
      map3dResult?(false)
      map3dResult = result
      let vc = Map3dViewController(assetPath: assetPath, me: (lat != nil && lon != nil) ? LatLon(lat!, lon!) : nil)
      vc.onClose = { [weak self] home in
        self?.map3dResult?(home)
        self?.map3dResult = nil
      }
      vc.modalPresentationStyle = .fullScreen
      NSLog("Map3D: presenting from %@", String(describing: type(of: top)))
      top.present(vc, animated: true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// The Flutter view's controller (set once the scene is up), else the key window's root;
  /// then whatever it is already presenting.
  private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }
    var vc = registrar.viewController
      ?? (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }
}
