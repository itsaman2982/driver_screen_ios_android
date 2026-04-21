import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let controller : FlutterViewController = window?.rootViewController as! FlutterViewController
    let webrtcChannel = FlutterMethodChannel(name: "com.driverscreen/webrtc",
                                              binaryMessenger: controller.binaryMessenger)
    DualCameraWebRTCManager.shared.methodChannel = webrtcChannel
    
    webrtcChannel.setMethodCallHandler({
      (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
      
      switch call.method {
      case "startCameras":
        DualCameraWebRTCManager.shared.startCameras()
        result(nil)
        
      case "stopCameras":
        DualCameraWebRTCManager.shared.stopCameras()
        result(nil)
        
      case "createOffer":
        guard let args = call.arguments as? [String: Any],
              let connectionId = args["connectionId"] as? String,
              let type = args["type"] as? String else {
          result(FlutterError(code: "BAD_ARGS", message: "Missing arguments", details: nil))
          return
        }
        
        DualCameraWebRTCManager.shared.createPeerConnection(connectionId: connectionId, type: type) { sdp in
            if let sdp = sdp {
                result(["sdp": sdp.sdp, "type": "offer"])
            } else {
                result(FlutterError(code: "OFFER_FAILED", message: "Failed to create offer", details: nil))
            }
        }
        
      case "setRemoteDescription":
        guard let args = call.arguments as? [String: Any],
              let connectionId = args["connectionId"] as? String,
              let sdp = args["sdp"] as? String,
              let type = args["type"] as? String else {
          result(FlutterError(code: "BAD_ARGS", message: "Missing arguments", details: nil))
          return
        }
        DualCameraWebRTCManager.shared.setRemoteDescription(connectionId: connectionId, sdp: sdp, type: type)
        result(nil)
        
      case "addIceCandidate":
        guard let args = call.arguments as? [String: Any],
              let connectionId = args["connectionId"] as? String,
              let candidate = args["candidate"] as? String,
              let sdpMid = args["sdpMid"] as? String,
              let sdpMLineIndex = args["sdpMLineIndex"] as? Int32 else {
          result(FlutterError(code: "BAD_ARGS", message: "Missing arguments", details: nil))
          return
        }
        DualCameraWebRTCManager.shared.addIceCandidate(connectionId: connectionId, candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex)
        result(nil)
        
      default:
        result(FlutterMethodNotImplemented)
      }
    })

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
