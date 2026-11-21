import Foundation

/// What the app and the widget extension share: one Keychain access group, no App Group.
enum SharedConfig {
    /// The expanded `$(AppIdentifierPrefix)dev.steve.MuDoPhone.shared` (Team ID + ".dev..."), written into
    /// Info.plist by the build. nil when it is empty, still unexpanded, or has no team prefix (unsigned
    /// Simulator builds): then only the default keychain group is used.
    static var keychainGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MuDoSharedKeychainGroup") as? String,
              !value.isEmpty, !value.hasPrefix("$("), !value.hasPrefix(".") else { return nil }
        return value
    }
    static let sortKey = "sortUsableFirst"
}
