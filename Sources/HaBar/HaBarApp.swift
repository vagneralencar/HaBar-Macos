import SwiftUI
import AppKit
import Combine

@main
public struct HaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    public init() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outDir = args[idx + 1]
            MainActor.assumeIsolated {
                ScreenshotExporter.exportAll(to: outDir)
            }
            exit(0)
        }
    }

    public var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = HomeAssistantStore()
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupPopover()
        setupStatusItem()
        observeStoreChanges()
        setupOutsideClickMonitor()
    }

    private func setupPopover() {
        let rootView = MainPopoverView(store: store)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]

        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover(_:))
        updateStatusButtonLabel(activeCount: store.activeLightsCount)
    }

    private func observeStoreChanges() {
        store.$devices
            .map { devices in
                devices.reduce(0) { $0 + ($1.isOn ? 1 : 0) }
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] activeCount in
                self?.updateStatusButtonLabel(activeCount: activeCount)
            }
            .store(in: &cancellables)
    }

    private func updateStatusButtonLabel(activeCount: Int) {
        guard let button = statusItem?.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let icon = NSImage(systemSymbolName: "house.fill", accessibilityDescription: "HaBar")?.withSymbolConfiguration(config)
        icon?.isTemplate = true
        button.image = icon

        if activeCount > 0 {
            button.title = " \(activeCount)"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        } else {
            button.title = ""
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func setupOutsideClickMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }
}

@MainActor
enum ScreenshotExporter {
    static func exportAll(to directoryPath: String) {
        let dirURL = URL(fileURLWithPath: directoryPath)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let demoStore = HomeAssistantStore.makeScreenshotDemoStore()

        let dashboardFrame = PopoverScreenshotFrame {
            MainPopoverView(store: demoStore)
        }
        renderView(dashboardFrame, to: dirURL.appendingPathComponent("habar-dashboard.png"))

        if let firstLight = demoStore.devices.first {
            demoStore.selectedDeviceForDetail = firstLight
        }
        let detailFrame = PopoverScreenshotFrame {
            MainPopoverView(store: demoStore)
        }
        renderView(detailFrame, to: dirURL.appendingPathComponent("habar-light-detail.png"))
    }

    private static func renderView<V: View>(_ view: V, to fileURL: URL) {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.scale = 2.0
        guard let cgImage = renderer.cgImage else { return }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return }
        try? pngData.write(to: fileURL, options: .atomic)
    }
}

private struct PopoverScreenshotFrame<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.09, blue: 0.14),
                    Color(red: 0.14, green: 0.10, blue: 0.20),
                    Color(red: 0.06, green: 0.07, blue: 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            content
                .background(Color(red: 0.11, green: 0.11, blue: 0.13))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.65), radius: 28, x: 0, y: 16)
                .padding(28)
        }
        .fixedSize()
    }
}
