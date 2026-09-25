import Foundation

/// Metadata for the native PICO client distributed with VrPico.
public enum NativePicoApp {

    public static let packageName = "org.eva.pico.input"
    public static let displayName = "EVA-VR"
    public static let bundledAPKName = "EVA-PICO.apk"
    public static let bundledVersionName = "0.2.5"

    /// The build script copies the APK to this fixed location inside the app.
    /// The URL argument keeps this helper testable without requiring a bundle.
    public static func bundledAPKURL(
        bundleURL: URL = Bundle.main.bundleURL
    ) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(bundledAPKName, isDirectory: false)
    }
}
