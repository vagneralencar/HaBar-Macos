import SwiftUI
import AppKit
import Combine
import Network
import Carbon

@main
@MainActor
public enum HaBarApp {
    private static var appDelegate: AppDelegate?

    public static func main() {
        let args = CommandLine.arguments
        if args.contains("--verify-update") {
            // Read-only release smoke test: no HA credentials, no replacement or relaunch.
            AppInfo.versionOverride = "dev"
            Task { @MainActor in
                do {
                    guard let release = await UpdateChecker.fetchLatestRelease() else { throw AppUpdaterError.noDownloadURL }
                    let staged = try await AppUpdater.shared.downloadAndStageUpdate(release: release)
                    try FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent())
                    print("Verified release \(release.version): publisher signature, archive, bundle and architecture")
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Update verification failed: \(error.localizedDescription)\n".utf8))
                    exit(1)
                }
            }
            RunLoop.main.run()
            return
        }
        if let idx = args.firstIndex(of: "--export-screenshots"), idx + 1 < args.count {
            let outDir = args[idx + 1]
            NSApplication.shared.setActivationPolicy(.prohibited)
            do {
                try ScreenshotExporter.exportAll(to: outDir)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Screenshot export failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
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
public final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let store = HomeAssistantStore()
    private var cancellables = Set<AnyCancellable>()
    private var eventMonitor: Any?
    private var registeredHotkey: EventHotKeyRef?
    private var hotkeyHandler: EventHandlerRef?
    private var settingsWindow: NSWindow?
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
        if let registeredHotkey { UnregisterEventHotKey(registeredHotkey) }
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler) }
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
        store.$isShowingSettings.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] visible in
            guard let self else { return }
            if visible { self.showSettingsWindow() } else { self.settingsWindow?.close() }
        }.store(in: &cancellables)
        store.$hotKeyEnabled.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.registerHotkey() }.store(in: &cancellables)
        store.$language.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.updateStatusButton(status: self.store.connectionStatus, mode: self.store.menuBarDisplayMode)
            self.settingsWindow?.title = L10n.t("Ajustes — HaBar", "Settings — HaBar")
        }.store(in: &cancellables)
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
            tooltip = L10n.t("HaBar — Conectado a \(host)", "HaBar — Connected to \(host)")
        case .demoMode(let host):
            symbolName = "house.fill"
            tooltip = L10n.t("HaBar — Modo Demo (\(host))", "HaBar — Demo mode (\(host))")
        case .connecting:
            symbolName = "house"
            tooltip = L10n.t("HaBar — Conectando ao Home Assistant…", "HaBar — Connecting to Home Assistant…")
        case .reconnecting:
            symbolName = "house.slash.fill"
            tooltip = L10n.t("HaBar — Sem conexão • Reconectando…", "HaBar — Offline • Reconnecting…")
        case .unauthorized, .forbidden:
            symbolName = "exclamationmark.shield.fill"
            tooltip = L10n.t("HaBar — Token inválido ou expirado", "HaBar — Invalid or expired token")
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
            title = store.powerReadingWatts.map { " \(Int($0))W" } ?? " —W"
        case .primaryTemperature:
            if let temp = store.primaryTemperatureCelsius {
                title = String(format: " %.1f°C", temp)
            } else {
                title = " —°C"
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

        let turnOffItem = NSMenuItem(title: L10n.t("Apagar todas as luzes", "Turn off all lights"), action: #selector(contextTurnOffAll), keyEquivalent: "")
        turnOffItem.target = self
        turnOffItem.isEnabled = store.activeLightsCount > 0
        menu.addItem(turnOffItem)

        let syncItem = NSMenuItem(title: L10n.t("Sincronizar Agora", "Sync now"), action: #selector(contextSyncNow), keyEquivalent: "")
        syncItem.target = self
        menu.addItem(syncItem)

        let settingsItem = NSMenuItem(title: L10n.t("Ajustes...", "Settings…"), action: #selector(contextOpenSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let browserItem = NSMenuItem(title: L10n.t("Abrir no Navegador", "Open in browser"), action: #selector(contextOpenBrowser), keyEquivalent: "")
        browserItem.target = self
        menu.addItem(browserItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: L10n.t("Encerrar HaBar", "Quit HaBar"), action: #selector(contextQuit), keyEquivalent: "q")
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
        showSettingsWindow()
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
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in owner.togglePopover(nil) }
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &hotkeyHandler)
        registerHotkey()
    }

    private func registerHotkey() {
        if let registeredHotkey { UnregisterEventHotKey(registeredHotkey); self.registeredHotkey = nil }
        guard store.hotKeyEnabled, hotkeyHandler != nil else { return }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_H), UInt32(cmdKey | optionKey), EventHotKeyID(signature: 0x48414252, id: 1), GetApplicationEventTarget(), 0, &registeredHotkey)
        if result != noErr { store.showToast(L10n.t("Atalho indisponível. Verifique se outro aplicativo usa ⌥⌘H.", "Shortcut unavailable. Check whether another app uses ⌥⌘H."), isError: true) }
    }

    private func showSettingsWindow() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(store: store))
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 560, height: 700))
            window.minSize = NSSize(width: 500, height: 450)
            window.title = L10n.t("Ajustes — HaBar", "Settings — HaBar")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        BonjourDiscovery.shared.startBrowsing()
    }

    public func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow {
            store.isShowingSettings = false
            BonjourDiscovery.shared.stopBrowsing()
        }
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
    static func exportAll(to directoryPath: String) throws {
        KeychainHelper.isIsolatedForTesting = true
        L10n.forcedLanguage = "pt"
        let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets/AppIcon.icns")
        if let icon = NSImage(contentsOf: iconURL) { NSApplication.shared.applicationIconImage = icon }
        let dirURL = URL(fileURLWithPath: directoryPath)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let demoStore = HomeAssistantStore.makeScreenshotDemoStore()

        let dashboardFrame = PopoverScreenshotFrame {
            MainPopoverView(store: demoStore)
        }
        try renderView(dashboardFrame, to: dirURL.appendingPathComponent("habar-dashboard.png"))

        if let firstLight = demoStore.devices.first {
            demoStore.selectedDeviceForDetail = firstLight
        }
        let detailFrame = PopoverScreenshotFrame {
            MainPopoverView(store: demoStore)
        }
        try renderView(detailFrame, to: dirURL.appendingPathComponent("habar-light-detail.png"))
        demoStore.selectedDeviceForDetail = nil
        demoStore.themeMode = .light
        demoStore.language = .en
        try renderView(MainPopoverView(store: demoStore), to: dirURL.appendingPathComponent("habar-dashboard-light-en.png"), scheme: .light)
        try renderView(SettingsView(store: demoStore).frame(width: 560, height: 700), to: dirURL.appendingPathComponent("habar-settings-light-en.png"), scheme: .light)

    }

    private static func renderView<V: View>(_ view: V, to fileURL: URL, scheme: ColorScheme = .dark) throws {
        // AppKit hosting is required for native scroll views, menus and form controls.
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "HaBar.Screenshot", code: 1)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "HaBar.Screenshot", code: 2)
        }
        try png.write(to: fileURL, options: .atomic)
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
