import MonitorUI
import ServiceManagement

/// The real login-item state from macOS, so a change made in System Settings shows here too. Only works from the
/// .app bundle, not from `swift run`.
extension LoginItem {
    static let mainApp = LoginItem(
        isEnabled: { SMAppService.mainApp.status == .enabled },
        needsApproval: { SMAppService.mainApp.status == .requiresApproval },
        set: { enabled in
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        },
        openSystemSettings: { SMAppService.openSystemSettingsLoginItems() })
}
