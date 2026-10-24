import Foundation
import ServiceManagement

/// D16 / V6: `SMAppService.mainApp` first, a LaunchAgent plist as the fallback.
@MainActor
enum LoginItem {
    static let label = "com.bagustyo92.agentnotch"

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    static var statusDescription: String {
        let sm: String
        switch SMAppService.mainApp.status {
        case .enabled: sm = "enabled"
        case .notRegistered: sm = "notRegistered"
        case .requiresApproval: sm = "requiresApproval"
        case .notFound: sm = "notFound"
        @unknown default: sm = "unknown"
        }
        return "SMAppService=\(sm) launchAgent=\(FileManager.default.fileExists(atPath: launchAgentURL.path))"
    }

    /// Returns an error message when neither mechanism worked, nil otherwise.
    @discardableResult
    static func set(enabled: Bool) -> String? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            removeLaunchAgent()
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                return "Approve AgentNotch in System Settings › General › Login Items, then switch this on again"
            }
            return nil
        } catch {
            guard enabled else { removeLaunchAgent(); return nil }
            return writeLaunchAgent(after: error)
        }
    }

    private static func removeLaunchAgent() {
        try? FileManager.default.removeItem(at: launchAgentURL)
    }

    private static func writeLaunchAgent(after error: any Error) -> String? {
        guard let exe = Bundle.main.executableURL?.path, exe.hasSuffix(".app/Contents/MacOS/AgentNotch") else {
            return "Launch at login needs the .app bundle (\(error.localizedDescription))"
        }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: launchAgentURL)
            return nil
        } catch {
            return "Launch at login failed: \(error.localizedDescription)"
        }
    }
}
