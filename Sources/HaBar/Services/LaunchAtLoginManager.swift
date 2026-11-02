import Foundation
import ServiceManagement

@MainActor
public final class LaunchAtLoginManager: ObservableObject {
    public static let shared = LaunchAtLoginManager()

    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var needsApproval = false

    public init() {
        refreshStatus()
    }

    public func refreshStatus() {
        if #available(macOS 13.0, *) {
            isEnabled = (SMAppService.mainApp.status == .enabled)
            needsApproval = SMAppService.mainApp.status == .requiresApproval
        }
    }

    public func setEnabled(_ enable: Bool) {
        guard #available(macOS 13.0, *) else { return }
        errorMessage = nil
        do {
            if enable {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshStatus()
    }
}
