import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Custom native plugins live alongside the Flutter ones. They register
    // their own MethodChannel + EventChannel + platform views.
    if let registrar = self.registrar(forPlugin: "LivePhotoPlugin") {
      LivePhotoPlugin.register(with: registrar)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
