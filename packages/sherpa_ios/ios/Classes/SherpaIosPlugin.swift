import Flutter
import UIKit

/// Registers Sherpa's native channels on iOS. On Android the host app (MainActivity.kt)
/// implements the same channels.
public class SherpaIosPlugin: NSObject, FlutterPlugin {
  private let registrar: FlutterPluginRegistrar
  private let ai: AiFallback
  private var map3dResult: FlutterResult?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    self.ai = AiFallback()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = SherpaIosPlugin(registrar: registrar)
    let messenger = registrar.messenger()

    let ai = FlutterMethodChannel(name: "survival/ai", binaryMessenger: messenger)
    ai.setMethodCallHandler { call, result in plugin.ai.handle(call, result: result) }
    FlutterEventChannel(name: "survival/ai/events", binaryMessenger: messenger).setStreamHandler(plugin.ai)

    let map3d = FlutterMethodChannel(name: "survival/map3d", binaryMessenger: messenger)
    map3d.setMethodCallHandler { call, result in plugin.handleMap3d(call, result: result) }
  }

  private func assetPath(_ asset: String) -> String? {
    Bundle.main.path(forResource: registrar.lookupKey(forAsset: asset), ofType: nil)
  }

  private func handleMap3d(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "available":
      result(Map3dViewController.available(assetPath: assetPath))
    case "open":
      let args = call.arguments as? [String: Any]
      let lat = args?["lat"] as? Double, lon = args?["lon"] as? Double
      guard let top = Self.topViewController() else { return result(false) }
      map3dResult?(false)
      map3dResult = result
      let vc = Map3dViewController(assetPath: assetPath, me: (lat != nil && lon != nil) ? LatLon(lat!, lon!) : nil)
      vc.onClose = { [weak self] home in
        self?.map3dResult?(home)
        self?.map3dResult = nil
      }
      vc.modalPresentationStyle = .fullScreen
      top.present(vc, animated: true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    var vc = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }
}
