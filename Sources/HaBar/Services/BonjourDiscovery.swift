import Foundation

public struct DiscoveredServer: Identifiable, Hashable, Sendable {
    public var id: String { urlString }
    public let name: String
    public let urlString: String
    public init(name: String, urlString: String) { self.name = name; self.urlString = urlString }
}

@MainActor public final class BonjourDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    public static let shared = BonjourDiscovery()
    @Published public private(set) var discoveredServers: [DiscoveredServer] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var errorMessage: String?
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []
    private var resolved: [ObjectIdentifier: DiscoveredServer] = [:]

    public func startBrowsing() {
        guard browser == nil else { return }
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        isSearching = true; errorMessage = nil
        browser.searchForServices(ofType: "_home-assistant._tcp.", inDomain: "local.")
    }
    public func stopBrowsing() {
        browser?.stop(); browser = nil
        services.forEach { $0.stop(); $0.delegate = nil }
        services = []; resolved = [:]; discoveredServers = []; isSearching = false
    }
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            services.append(service); service.delegate = self; service.resolve(withTimeout: 8)
        }
    }
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            resolved.removeValue(forKey: ObjectIdentifier(service))
            services.removeAll { $0 == service }; publish()
        }
    }
    nonisolated public func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated {
            guard services.contains(sender), let host = sender.hostName, sender.port > 0 else { return }
            var components = URLComponents()
            components.scheme = "http"; components.host = host; components.port = sender.port
            if let data = sender.txtRecordData(), let scheme = NetService.dictionary(fromTXTRecord: data)["base_url"].flatMap({ String(data: $0, encoding: .utf8) }).flatMap({ URL(string: $0)?.scheme }), scheme == "https" { components.scheme = scheme }
            guard let url = components.url else { return }
            resolved[ObjectIdentifier(sender)] = DiscoveredServer(name: sender.name, urlString: url.absoluteString)
            publish()
        }
    }
    nonisolated public func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        MainActor.assumeIsolated {
            isSearching = false
            errorMessage = L10n.t("Não foi possível buscar na rede local. Informe a URL manualmente.", "Couldn't search the local network. Enter the URL manually.")
        }
    }
    private func publish() {
        discoveredServers = Array(Set(resolved.values)).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
