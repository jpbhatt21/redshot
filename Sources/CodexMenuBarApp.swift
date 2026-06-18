import SwiftUI

@main
struct RedshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(service: appDelegate.screenshotService)
        } label: {
            Label("Redshot", systemImage: "camera.viewfinder")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let screenshotService = ScreenshotService()
    private var hotKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyMonitor {
            NSEvent.removeMonitor(hotKeyMonitor)
        }
    }

    private func installHotKey() {
        hotKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.shift),
                  flags.contains(.option),
                  !flags.contains(.command),
                  !flags.contains(.control) else {
                return
            }

            let key = event.charactersIgnoringModifiers?.lowercased()
            Task { @MainActor in
                switch key {
                case "s":
                    NSApp.activate(ignoringOtherApps: true)
                    self?.screenshotService.startCapture()
                case "a":
                    self?.screenshotService.captureFocusedWindow()
                case "d":
                    self?.screenshotService.captureLastRegion()
                case "f":
                    self?.screenshotService.captureFullScreen()
                default:
                    break
                }
            }
        }
    }
}
