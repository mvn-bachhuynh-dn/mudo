import Foundation

/// What the app and the widget extension share through the App Group.
enum SharedConfig {
    static let appGroup = "group.dev.steve.MuDoPhone"
    static var defaults: UserDefaults { UserDefaults(suiteName: appGroup) ?? .standard }
    static let sortKey = "sortUsableFirst"
}
