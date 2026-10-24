import Foundation
import Observation

/// The only persisted state (R4): four toggles in UserDefaults.
@MainActor
@Observable
final class Settings {
    static let hideDetailsKey = "hideDetails"
    static let launchAtLoginKey = "launchAtLogin"
    static let autoOpenKey = "autoOpen"
    static let showSubagentsLiveKey = "showSubagentsLive"

    var hideDetails: Bool {
        didSet { UserDefaults.standard.set(hideDetails, forKey: Self.hideDetailsKey) }
    }

    /// Q16: open the live strip on its own when a session starts working or needs you.
    var autoOpen: Bool {
        didSet { UserDefaults.standard.set(autoOpen, forKey: Self.autoOpenKey) }
    }

    /// Q21: list running subagents under their session in the live strip.
    var showSubagentsLive: Bool {
        didSet { UserDefaults.standard.set(showSubagentsLive, forKey: Self.showSubagentsLiveKey) }
    }

    var launchAtLogin: Bool {
        didSet {
            guard !reverting, launchAtLogin != oldValue else { return }
            if let error = LoginItem.set(enabled: launchAtLogin) {
                loginItemError = error
                reverting = true
                launchAtLogin = oldValue          // the toggle must not claim a state the system refused
                reverting = false
            } else {
                loginItemError = nil
                UserDefaults.standard.set(launchAtLogin, forKey: Self.launchAtLoginKey)
            }
        }
    }

    var loginItemError: String?
    @ObservationIgnored private var reverting = false

    init() {
        let defaults = UserDefaults.standard
        hideDetails = defaults.bool(forKey: Self.hideDetailsKey)
        autoOpen = defaults.object(forKey: Self.autoOpenKey) as? Bool ?? true
        showSubagentsLive = defaults.object(forKey: Self.showSubagentsLiveKey) as? Bool ?? true
        launchAtLogin = defaults.object(forKey: Self.launchAtLoginKey) as? Bool ?? LoginItem.isEnabled
    }
}
