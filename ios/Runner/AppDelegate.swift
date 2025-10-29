import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  var audioPlayer: AVAudioPlayer? = nil
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    let EVENT_CHANNEL = "audio_usb/events"
    let METHOD_CHANNEL = "audio_usb/methods"

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // EventChannel: envia eventos de conexão/desconexão
    var eventSink: FlutterEventSink? = nil
    var routeObserver: NSObjectProtocol? = nil

    let eventChannel = FlutterEventChannel(name: EVENT_CHANNEL, binaryMessenger: controller.binaryMessenger)
    eventChannel.setStreamHandler({ () -> FlutterStreamHandler in
      class Handler: NSObject, FlutterStreamHandler {
        var eventSink: FlutterEventSink?
        var routeObserver: NSObjectProtocol?

        func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
          self.eventSink = events
          let session = AVAudioSession.sharedInstance()
          try? session.setCategory(.playback, mode: .default, options: [])
          try? session.setActive(true)

          // Estado inicial
          let hasUsb = Self.isUsbConnected(session: session)
          events(hasUsb ? "connected" : "disconnected")

          self.routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let sink = self?.eventSink else { return }
            let connected = Self.isUsbConnected(session: session)
            sink(connected ? "connected" : "disconnected")
          }
          return nil
        }

        func onCancel(withArguments arguments: Any?) -> FlutterError? {
          if let observer = routeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeObserver = nil
          }
          eventSink = nil
          return nil
        }

        static func isUsbConnected(session: AVAudioSession) -> Bool {
          return session.currentRoute.outputs.contains { $0.portType == .usbAudio }
        }
      }
      return Handler()
    }())

    // MethodChannel: retorna detalhes dos canais
    let methodChannel = FlutterMethodChannel(name: METHOD_CHANNEL, binaryMessenger: controller.binaryMessenger)
    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "getOutputChannelDetails":
        let session = AVAudioSession.sharedInstance()
        if let usbPort = session.currentRoute.outputs.first(where: { $0.portType == .usbAudio }) {
          let name = usbPort.portName
          let count = usbPort.channels?.count ?? 0
          let channels = (count > 0) ? (1...count).map { "Canal de Saída \($0)" } : []
          result([
            "deviceName": name,
            "outputChannelCount": count,
            "outputChannels": channels
          ])
        } else {
          result([
            "deviceName": "",
            "outputChannelCount": 0,
            "outputChannels": []
          ])
        }
      case "getInputChannelDetails":
        let session = AVAudioSession.sharedInstance()
        if let usbInput = session.currentRoute.inputs.first(where: { $0.portType == .usbAudio }) {
          let name = usbInput.portName
          let count = usbInput.channels?.count ?? 0
          let channels = (count > 0) ? (1...count).map { "Canal de Entrada \($0)" } : []
          result([
            "deviceName": name,
            "inputChannelCount": count,
            "inputChannels": channels
          ])
        } else {
          result([
            "deviceName": "",
            "inputChannelCount": 0,
            "inputChannels": []
          ])
        }
      case "playPreview":
        guard let args = call.arguments as? [String: Any],
              let filePath = args["filePath"] as? String else {
          result(FlutterError(code: "bad_args", message: "filePath ausente", details: nil))
          return
        }
        let outputChannel = (args["outputChannel"] as? Int) ?? 0
        do {
          let session = AVAudioSession.sharedInstance()
          try? session.setCategory(.playback, mode: .default, options: [])
          try? session.setActive(true)

          // Preferência de saída: o iOS automaticamente roteia para USB quando conectado.
          // Seleção de canal específica não é suportada diretamente com AVAudioPlayer.

          let url = URL(fileURLWithPath: filePath)
          self.audioPlayer?.stop()
          self.audioPlayer = try AVAudioPlayer(contentsOf: url)
          // Roteamento simples: estéreo L/R via pan
          if outputChannel == 0 {
            self.audioPlayer?.pan = -1.0 // Left
          } else if outputChannel == 1 {
            self.audioPlayer?.pan = 1.0 // Right
          } else {
            self.audioPlayer?.pan = 0.0 // Center
          }
          self.audioPlayer?.prepareToPlay()
          self.audioPlayer?.play()
          result(nil)
        } catch {
          result(FlutterError(code: "play_error", message: error.localizedDescription, details: nil))
        }
      case "stopPreview":
        self.audioPlayer?.stop()
        self.audioPlayer = nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
