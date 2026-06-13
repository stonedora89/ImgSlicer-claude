import SwiftUI
import AppKit

@main
struct ImgSlicerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()

    init() {
        if let command = DetectionOverlayCommand.parse(arguments: CommandLine.arguments) {
            command.run()
            Foundation.exit(0)
        }
        if let command = DetectionCountCommand.parse(arguments: CommandLine.arguments) {
            command.run()
            Foundation.exit(0)
        }
        if let command = AlgorithmComparisonCommand.parse(arguments: CommandLine.arguments) {
            command.run()
            Foundation.exit(0)
        }
        AppIcon.install()
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(store)
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入文件...") {
                    store.pickFiles()
                }
                .keyboardShortcut("o")

                Button("开始处理") {
                    store.startProcessing()
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

@MainActor
enum AppIcon {
    static func image() -> NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.main.url(forResource: "icon", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        if let url = Bundle.module.url(forResource: "icon", withExtension: "svg"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApplication.shared.applicationIconImage
    }

    static func install() {
        NSApplication.shared.applicationIconImage = image()
    }
}
