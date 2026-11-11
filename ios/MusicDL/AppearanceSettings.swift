import SwiftUI
import UIKit

enum MusicAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色模式"; case .dark: return "深色模式" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

enum MusicTheme: String, CaseIterable, Identifiable {
    case appleRed, oceanBlue, mintGreen, dreamPurple, sunsetOrange, cherryPink, auroraCyan, graphiteGray
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appleRed: return "Apple 红"
        case .oceanBlue: return "海洋蓝"
        case .mintGreen: return "薄荷绿"
        case .dreamPurple: return "梦幻紫"
        case .sunsetOrange: return "落日橙"
        case .cherryPink: return "樱花粉"
        case .auroraCyan: return "极光青"
        case .graphiteGray: return "石墨灰"
        }
    }
    // Light colors support small text on the existing warm canvas. Dark
    // variants are brighter; filled controls use a matching dark foreground.
    func hex(dark: Bool) -> UInt32 {
        switch self {
        case .appleRed: return dark ? 0xFF7285 : 0xC52A3D
        case .oceanBlue: return dark ? 0x6DB8FF : 0x0967B2
        case .mintGreen: return dark ? 0x64D8B0 : 0x087655
        case .dreamPurple: return dark ? 0xC4A3FF : 0x7750B8
        case .sunsetOrange: return dark ? 0xFFB36C : 0xA64908
        case .cherryPink: return dark ? 0xFF95C9 : 0xB83275
        case .auroraCyan: return dark ? 0x5AD9E4 : 0x007780
        case .graphiteGray: return dark ? 0xBEC6CF : 0x515960
        }
    }
    var color: Color {
        Color(uiColor: UIColor { traits in Self.uiColor(self.hex(dark: traits.userInterfaceStyle == .dark)) })
    }
    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

@MainActor
final class AppearanceSettings: ObservableObject {
    static let appearanceKey = "music.appearance" // Preserve existing choices.
    static let themeKey = "music.themeColor"
    private let defaults: UserDefaults
    @Published var appearance: MusicAppearance { didSet { defaults.set(appearance.rawValue, forKey: Self.appearanceKey) } }
    @Published var theme: MusicTheme { didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) } }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = MusicAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        theme = MusicTheme(rawValue: defaults.string(forKey: Self.themeKey) ?? "") ?? .appleRed
    }
    func restoreDefaults() {
        // Only these two keys; never reset the UserDefaults domain or library.
        appearance = .system
        theme = .appleRed
    }
}

private struct MusicAccentKey: EnvironmentKey { static let defaultValue = MusicTheme.appleRed.color }
extension EnvironmentValues {
    var musicAccent: Color {
        get { self[MusicAccentKey.self] }
        set { self[MusicAccentKey.self] = newValue }
    }
}

struct AppearanceScreen: View {
    @EnvironmentObject private var settings: AppearanceSettings
    @Environment(\.musicAccent) private var accent
    @State private var confirmingReset = false
    var body: some View {
        Form {
            Section("外观模式") {
                ForEach(MusicAppearance.allCases) { mode in
                    Button { settings.appearance = mode } label: {
                        HStack {
                            Text(mode.title).foregroundStyle(.primary)
                            Spacer()
                            if settings.appearance == mode { Image(systemName: "checkmark").foregroundStyle(accent) }
                        }.contentShape(Rectangle())
                    }.accessibilityLabel(mode.title)
                        .accessibilityValue(settings.appearance == mode ? "已选中" : "未选中")
                        .accessibilityAddTraits(settings.appearance == mode ? .isSelected : [])
                        .accessibilityIdentifier("appearance-" + mode.rawValue)
                }
            }
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 12)], spacing: 18) {
                    ForEach(MusicTheme.allCases) { theme in
                        Button { settings.theme = theme } label: {
                            VStack(spacing: 8) {
                                Circle().fill(theme.color).frame(width: 44, height: 44)
                                    .overlay { if settings.theme == theme {
                                        Image(systemName: "checkmark").font(.body.bold()).foregroundStyle(MusicDesign.onAccent)
                                    } }
                                Text(theme.title).font(.caption).foregroundStyle(.primary)
                                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            }.frame(maxWidth: .infinity, minHeight: 78)
                        }.buttonStyle(.plain).accessibilityLabel(theme.title)
                            .accessibilityValue(settings.theme == theme ? "已选中" : "未选中")
                            .accessibilityAddTraits(settings.theme == theme ? .isSelected : [])
                            .accessibilityIdentifier("theme-" + theme.rawValue)
                    }
                }.padding(.vertical, 8)
            } header: { Text("主题颜色") } footer: { Text("立即应用到按钮、选中状态与播放进度；可与任意外观模式组合。") }
            Section("效果预览") {
                Label(settings.theme.title, systemImage: "waveform").foregroundStyle(accent)
                ProgressView(value: 0.58).accessibilityLabel("主题色进度预览")
                Toggle("开关预览", isOn: .constant(true)).accessibilityIdentifier("theme-toggle-preview")
            }
            Section {
                Button("恢复默认主题") { confirmingReset = true }.accessibilityIdentifier("theme-restore")
            } footer: { Text("恢复为跟随系统与 Apple 红，仅重置外观选项。") }
        }.navigationTitle("外观").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("恢复默认主题？", isPresented: $confirmingReset, titleVisibility: .visible) {
                Button("恢复外观默认值", role: .destructive) { settings.restoreDefaults() }
            } message: { Text("歌曲、缓存、下载内容与其他设置都会保留。") }
    }
}
