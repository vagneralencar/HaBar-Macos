import Foundation
import Network

public struct DiscoveredServer: Identifiable, Hashable, Sendable {
    public var id: String { urlString }
    public let name: String
    public let urlString: String

    public init(name: String, urlString: String) {
        self.name = name
        self.urlString = urlString
    }
}

@MainActor
public final class BonjourDiscovery: ObservableObject {
    public static let shared = BonjourDiscovery()

    @Published public private(set) var discoveredServers: [DiscoveredServer] = []
    @Published public private(set) var isSearching: Bool = false

    private var browser: NWBrowser?

    public init() {}

    public func startBrowsing() {
        guard browser == nil else { return }
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_home-assistant._tcp", domain: "local.")
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let b = NWBrowser(for: descriptor, using: parameters)
        self.browser = b
        self.isSearching = true

        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var servers: [DiscoveredServer] = []
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint {
                        let cleanName = name.replacingOccurrences(of: "\\", with: "")
                        // Common fallback host resolution: homeassistant.local or name.local
                        let url = "http://homeassistant.local:8123"
                        servers.append(DiscoveredServer(name: cleanName, urlString: url))
                    }
                }
                self.discoveredServers = servers
            }
        }

        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed = state {
                    self?.isSearching = false
                }
            }
        }

        b.start(queue: DispatchQueue(label: "habar.bonjour.discovery"))
    }

    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isSearching = false
    }
}
