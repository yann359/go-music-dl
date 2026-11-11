import XCTest
import UIKit
@testable import MusicDL

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "MusicDL-appearance-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testExistingAppearanceSurvivesMigrationAndThemesPersistIndependently() throws {
        let store = try defaults()
        store.set("dark", forKey: "music.appearance")
        let settings = AppearanceSettings(defaults: store)
        XCTAssertEqual(settings.appearance, .dark)
        XCTAssertEqual(settings.theme, .appleRed)
        for mode in MusicAppearance.allCases {
            settings.appearance = mode
            for theme in MusicTheme.allCases {
                settings.theme = theme
                let restored = AppearanceSettings(defaults: store)
                XCTAssertEqual(restored.appearance, mode)
                XCTAssertEqual(restored.theme, theme)
                XCTAssertEqual(settings.appearance, mode)
            }
        }
    }

    func testRestoreDefaultsOnlyTouchesTwoAppearanceKeys() throws {
        let store = try defaults()
        store.set("existing-user-library", forKey: "music.library")
        store.set("downloads-and-cache", forKey: "music.downloads")
        store.set(true, forKey: "other.setting")
        let settings = AppearanceSettings(defaults: store)
        settings.appearance = .light; settings.theme = .auroraCyan
        settings.restoreDefaults()
        let restored = AppearanceSettings(defaults: store)
        XCTAssertEqual(restored.appearance, .system)
        XCTAssertEqual(restored.theme, .appleRed)
        XCTAssertEqual(store.string(forKey: "music.library"), "existing-user-library")
        XCTAssertEqual(store.string(forKey: "music.downloads"), "downloads-and-cache")
        XCTAssertTrue(store.bool(forKey: "other.setting"))
    }

    func testUnknownSavedValuesFallBackSafely() throws {
        let store = try defaults()
        store.set("removed-mode", forKey: AppearanceSettings.appearanceKey)
        store.set("removed-theme", forKey: AppearanceSettings.themeKey)
        let settings = AppearanceSettings(defaults: store)
        XCTAssertEqual(settings.appearance, .system)
        XCTAssertEqual(settings.theme, .appleRed)
    }

    func testAllThemeTextAndFilledForegroundsHaveReadableContrast() {
        func luminance(_ components: [Double]) -> Double {
            let linear = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        func contrast(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }
        XCTAssertEqual(MusicTheme.allCases.count, 8)
        for theme in MusicTheme.allCases {
            for dark in [false, true] {
                let hex = theme.hex(dark: dark)
                let color = luminance([Double((hex >> 16) & 255) / 255, Double((hex >> 8) & 255) / 255, Double(hex & 255) / 255])
                let canvas = luminance(dark ? [0.065, 0.075, 0.085] : [0.98, 0.97, 0.95])
                XCTAssertGreaterThanOrEqual(contrast(color, canvas), 4.5, "\(theme) on canvas dark=\(dark)")
                XCTAssertGreaterThanOrEqual(contrast(color, dark ? 0 : 1), 4.5, "\(theme) filled foreground dark=\(dark)")
                let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
                let resolved = UIColor(theme.color).resolvedColor(with: traits)
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                XCTAssertTrue(resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
                XCTAssertEqual(Double(red), Double((hex >> 16) & 255) / 255, accuracy: 0.002)
            }
        }
    }
}
