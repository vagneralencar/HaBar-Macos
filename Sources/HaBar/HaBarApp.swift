import SwiftUI
import AppKit
import Combine
import Network

@main
@MainActor
public enum HaBarApp {
    private static var appDelegate: AppDelegate?

    public static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outDir = args[idx + 1]
            ScreenshotExporter.exportAll(to: outDir)
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.appDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = HomeAssistantStore()
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private let networkMonitor = NWPathMonitor()
    private let networkQueue = DispatchQueue(label: "habar.network.monitor")

    public func applicationDidFinishLaunching(_ notification: Notification) {
        setupPopover()
        setupStatusItem()
        observeStoreChanges()
        setupOutsideClickMonitor()
        setupGlobalHotkey()
        setupSleepWakeObserver()
        setupNetworkMonitoring()

        if store.autoCheckUpdates {
            Task {
                await store.checkForUpdates(userInitiated: false)
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        networkMonitor.cancel()
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    private func setupPopover() {
        let rootView = MainPopoverView(store: store)
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]

        popover.contentViewController = hostingController
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusButton(status: store.connectionStatus, mode: store.menuBarDisplayMode)
    }

    private func observeStoreChanges() {
        Publishers.CombineLatest3(
            store.$devices,
            store.$connectionStatus.removeDuplicates(),
            store.$menuBarDisplayMode.removeDuplicates()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _, status, mode in
            self?.updateStatusButton(status: status, mode: mode)
        }
        .store(in: &cancellables)
    }

    private func updateStatusButton(status: HAConnectionStatus, mode: MenuBarDisplayMode) {
        guard let button = statusItem?.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

        let symbolName: String
        let tooltip: String

        switch status {
        case .connected(let host):
            symbolName = "house.fill"
            tooltip = "HaBar — Conectado a \(host)"
        case .demoMode(let host):
            symbolName = "house.fill"
            tooltip = "HaBar — Modo Demo (\(host))"
        case .connecting:
            symbolName = "house"
            tooltip = "HaBar — Conectando ao Home Assistant…"
        case .reconnecting:
            symbolName = "house.slash.fill"
            tooltip = "HaBar — Sem conexão • Reconectando…"
        case .unauthorized:
            symbolName = "exclamationmark.shield.fill"
            tooltip = "HaBar — Token inválido ou expirado"
        }

        let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: "HaBar")?.withSymbolConfiguration(config)
        icon?.isTemplate = true
        button.image = icon
        button.toolTip = tooltip

        let title: String
        let activeCount = store.activeLightsCount
        let power = store.totalPowerWatts

        switch mode {
        case .activeLights:
            title = activeCount > 0 ? " \(activeCount)" : ""
        case .totalPower:
            title = power > 0 ? " \(Int(power))W" : ""
        case .primaryTemperature:
            if let temp = store.primaryTemperatureCelsius {
                title = String(format: " %.1f°C", temp)
            } else {
                title = activeCount > 0 ? " \(activeCount)" : ""
            }
        case .lightsAndPower:
            if activeCount > 0 && power > 0 {
                title = " \(activeCount) • \(Int(power))W"
            } else if activeCount > 0 {
                title = " \(activeCount)"
            } else if power > 0 {
                title = " \(Int(power))W"
            } else {
                title = ""
            }
        case .iconOnly:
            title = ""
        }

        button.title = title
        if !title.isEmpty {
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        store.setPopoverPresented(false)
    }

    public func popoverWillShow(_ notification: Notification) {
        store.setPopoverPresented(true)
    }

    @objc private func handleStatusItemClick(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent

        if event?.type == .rightMouseUp {
            showContextMenu(for: button)
            return
        }

        togglePopover(sender)
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard statusItem.button != nil else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        store.applyOpeningRoomPreference()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu(for view: NSView) {
        let menu = NSMenu()

        let headerItem = NSMenuItem(title: "HaBar v\(AppInfo.version)", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        let turnOffItem = NSMenuItem(title: "Apagar Tudo", action: #selector(contextTurnOffAll), keyEquivalent: "")
        turnOffItem.target = self
        turnOffItem.isEnabled = store.activeLightsCount > 0
        menu.addItem(turnOffItem)

        let syncItem = NSMenuItem(title: "Sincronizar Agora", action: #selector(contextSyncNow), keyEquivalent: "")
        syncItem.target = self
        menu.addItem(syncItem)

        let settingsItem = NSMenuItem(title: "Ajustes...", action: #selector(contextOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let browserItem = NSMenuItem(title: "Abrir no Navegador", action: #selector(contextOpenBrowser), keyEquivalent: "")
        browserItem.target = self
        menu.addItem(browserItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Encerrar HaBar", action: #selector(contextQuit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height), in: view)
    }

    @objc private func contextTurnOffAll() {
        if store.confirmTurnOffAll {
            showPopover()
        }
        store.requestTurnOffAllLights()
    }

    @objc private func contextSyncNow() {
        store.connectToHomeAssistant()
    }

    @objc private func contextOpenSettings() {
        store.isShowingSettings = true
        showPopover()
    }

    @objc private func contextOpenBrowser() {
        store.openHomeAssistantInBrowser()
    }

    @objc private func contextQuit() {
        NSApplication.shared.terminate(nil)
    }

    private func setupOutsideClickMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
    }

    private func setupGlobalHotkey() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.handleHotkeyEvent(event) == true {
                return nil
            }
            return event
        }
    }

    @discardableResult
    private func handleHotkeyEvent(_ event: NSEvent) -> Bool {
        guard store.hotKeyEnabled else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command, .option] && event.charactersIgnoringModifiers?.lowercased() == "h" {
            togglePopover(nil)
            return true
        }
        return false
    }

    private func setupSleepWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWakeNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleWakeNotification(_ notification: Notification) {
        store.resyncAfterWake()
    }

    private func setupNetworkMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                self?.store.networkDidBecomeAvailable()
            }
        }
        networkMonitor.start(queue: networkQueue)
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
