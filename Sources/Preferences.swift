import AppKit

enum AppearanceMode: String, CaseIterable {
    case auto, light, dark

    var localizedName: String {
        switch self {
        case .auto:  return "システムに合わせる"
        case .light: return "ライト"
        case .dark:  return "ダーク"
        }
    }

    /// ウインドウ枠やツールバーの外観。auto はシステム設定に任せる。
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto:  return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark:  return NSAppearance(named: .darkAqua)
        }
    }
}

enum Preferences {
    private enum Key {
        static let fontSize = "fontSize"
        static let appearance = "appearance"
    }

    static let fontSizeRange: ClosedRange<CGFloat> = 11...30
    static let defaultFontSize: CGFloat = 16
    static let fontSizeStep: CGFloat = 1

    private static let defaults = UserDefaults.standard

    static var fontSize: CGFloat {
        get {
            guard let stored = defaults.object(forKey: Key.fontSize) as? Double else {
                return defaultFontSize
            }
            return CGFloat(stored).clamped(to: fontSizeRange)
        }
        set { defaults.set(Double(newValue.clamped(to: fontSizeRange)), forKey: Key.fontSize) }
    }

    static var appearance: AppearanceMode {
        get { AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .auto }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appearance)
            NSApp.appearance = newValue.nsAppearance
        }
    }

    /// 起動直後に保存済みの外観をアプリ全体へ反映する。
    static func applyStoredAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
