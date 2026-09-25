import Foundation

/// 设置的持久化。
///
/// Server and relay settings are stored in UserDefaults. The native token is
/// discovered per connection from the console's `browser_url`, so it is not
/// persisted; the old token key is retained only for migration safety.
public final class AppSettingsStore {

    public static let settingsKey = "com.eva.vrpico.settings"
    public static let webXRTokenKey = "com.eva.vrpico.webxr-token"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 普通设置

    /// 读取失败或没有存量时返回 `.default`。
    public func loadSettings() -> AppSettings {
        guard let data = defaults.data(forKey: Self.settingsKey) else {
            return .default
        }
        do {
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            // EVA-VR has one fixed native endpoint. Older builds exposed this
            // field and may have persisted the fake robot ZMQ port (5555).
            // Migrate it here so hidden legacy state can never redirect PICO.
            if settings.webxrPort != AppSettings.defaultWebXRPort
                || settings.webxrMode != AppSettings.defaultWebXRMode {
                settings.webxrPort = AppSettings.defaultWebXRPort
                settings.webxrMode = AppSettings.defaultWebXRMode
                saveSettings(settings)
            }
            return settings
        } catch {
            // 结构变更导致旧数据解不开时不能让 App 起不来，退回默认值。
            return .default
        }
    }

    public func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.settingsKey)
    }

    // MARK: - token

    /// 拿不到时返回空串，让界面显示为空而不是报错。
    public func loadToken() -> String {
        defaults.string(forKey: Self.webXRTokenKey) ?? ""
    }

    /// 首次运行时使用出厂默认 token；保存过的空串也应原样返回。
    public func loadTokenOrDefault() -> String {
        guard defaults.object(forKey: Self.webXRTokenKey) != nil else {
            return AppSettings.defaultWebXRToken
        }
        return loadToken()
    }

    public func saveToken(_ token: String) {
        defaults.set(token, forKey: Self.webXRTokenKey)
    }

    // MARK: - 重置

    /// 设置界面「恢复默认值」用。清掉全部持久化内容。
    public func reset() {
        defaults.removeObject(forKey: Self.settingsKey)
        defaults.removeObject(forKey: Self.webXRTokenKey)
    }
}
