import Flutter
import UIKit
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    engineBridge.pluginRegistry.registrar(forPlugin: "TicketDiaryMediaVolume")?
      .register(MediaVolumeViewFactory(), withId: "ticketdiary/media_volume")
  }
}

private final class MediaVolumeViewFactory: NSObject, FlutterPlatformViewFactory {
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
              arguments args: Any?) -> FlutterPlatformView {
    MediaVolumePlatformView(frame: frame)
  }
}

private final class MediaVolumePlatformView: NSObject, FlutterPlatformView {
  private let volumeView: MPVolumeView

  init(frame: CGRect) {
    volumeView = MPVolumeView(frame: frame)
    super.init()
    volumeView.showsRouteButton = false
    volumeView.tintColor = UIColor(red: 139 / 255, green: 94 / 255, blue: 60 / 255, alpha: 1)
    volumeView.accessibilityLabel = "미디어 볼륨"
  }

  func view() -> UIView { volumeView }
}
