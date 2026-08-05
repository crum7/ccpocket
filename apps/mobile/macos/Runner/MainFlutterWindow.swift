import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSToolbarDelegate {
  private let windowToolbar = NSToolbar(identifier: "ccpocket.mainToolbar")
  private var windowChromeChannel: FlutterMethodChannel?
  private var filePickerChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    styleMask.insert(.fullSizeContentView)
    toolbarStyle = .unified
    isMovableByWindowBackground = false

    windowToolbar.delegate = self
    windowToolbar.displayMode = .iconOnly
    windowToolbar.sizeMode = .regular
    windowToolbar.allowsUserCustomization = false
    windowToolbar.showsBaselineSeparator = false
    toolbar = windowToolbar

    // Hide the (empty) unified toolbar while fullscreen — otherwise macOS
    // composites a translucent toolbar strip over the top of the Flutter
    // content and our custom tab bar disappears underneath it.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillEnterFullScreen),
      name: NSWindow.willEnterFullScreenNotification,
      object: self)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleWillExitFullScreen),
      name: NSWindow.willExitFullScreenNotification,
      object: self)

    let flutterViewController = FlutterViewController()
    let chromeChannel = FlutterMethodChannel(
      name: "ccpocket/window_chrome",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    chromeChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "beginWindowDrag" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self else {
        result(nil)
        return
      }
      guard let event = NSApp.currentEvent else {
        result(nil)
        return
      }
      self.performDrag(with: event)
      result(nil)
    }
    windowChromeChannel = chromeChannel

    let pickerChannel = FlutterMethodChannel(
      name: "ccpocket/file_picker",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    pickerChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "pickFiles" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self else {
        result([])
        return
      }
      let arguments = call.arguments as? [String: Any]
      let maxFiles = max(1, arguments?["maxFiles"] as? Int ?? 5)
      self.pickFiles(maxFiles: maxFiles, result: result)
    }
    filePickerChannel = pickerChannel

    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    []
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    []
  }

  @objc private func handleWillEnterFullScreen(_ notification: Notification) {
    toolbar?.isVisible = false
  }

  @objc private func handleWillExitFullScreen(_ notification: Notification) {
    toolbar?.isVisible = true
  }

  private func pickFiles(maxFiles: Int, result: @escaping FlutterResult) {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = maxFiles > 1
    panel.resolvesAliases = true
    panel.beginSheetModal(for: self) { response in
      guard response == .OK else {
        result([])
        return
      }
      result(Array(panel.urls.prefix(maxFiles)).map(\.path))
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }
}
