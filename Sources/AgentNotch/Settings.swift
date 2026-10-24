import Foundation
import Observation

/// The only persisted state (R4): two toggles in UserDefaults.
@MainActor
@Observable
final class Settings {
    static let hideDetailsKey = "hideDetails"
    static let launchAtLoginKey = "launchAtLogin"

    var hideDetails: Bool {
        didSet { UserDefaults.standard.set(hideDetails, forKey: Self.hideDetailsKey) }
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
        launchAtLogin = defaults.object(forKey: Self.launchAtLoginKey) as? Bool ?? LoginItem.isEnabled
    }
}
