//
//  SettingsSection.swift
//  Pulse Cue
//

/// Which group of settings a screen shows.
///
/// One screen, four entrances. `MeView` used to offer a single 「設定」 that
/// opened everything at once — body measurements, HealthKit, the account and
/// notification toggles in one scroll — which put "how tall am I" and "should
/// the app buzz" at the same level. The distinction that matters is between
/// *your data* and *the app's configuration*, and it is not visible when they
/// share a list.
///
/// The cases are the four responsibilities, and each has a view of its own:
/// `BodyGoalsSettingsSection`, `HealthSettingsSection`,
/// `AccountSettingsSection`, `AppPreferencesSection`. `SettingsView` is only
/// the shell that chooses between them.
enum SettingsSection: Equatable, CaseIterable {
    /// Height, age, sex, activity, BMR/TDEE and the weight goal.
    case bodyAndGoals
    /// HealthKit, and what the app is allowed to send.
    case health
    /// Sign-in, the linked provider, the server account and its deletion.
    case account
    /// Notifications, help, version — the app itself.
    case app

    var title: String {
        switch self {
        case .bodyAndGoals: return "体と目標"
        case .health: return "ヘルスケア"
        case .account: return "アカウント"
        case .app: return "アプリ設定"
        }
    }
}
