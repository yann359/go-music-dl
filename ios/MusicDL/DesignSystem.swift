import SwiftUI

enum MusicDesign {
    static let coral = Color(red: 0.88, green: 0.33, blue: 0.28)
    static let ink = Color(red: 0.13, green: 0.16, blue: 0.18)
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.065, green: 0.075, blue: 0.085) : Color(red: 0.98, green: 0.97, blue: 0.95)
    }
    static func panel(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(white: 0.12) : .white
    }
}

extension Song: Identifiable { var idForUI: String { key }; var identity: String { key } }
// Song's platform id is already an Identifiable witness. Composite keys are
// supplied explicitly to lists so cross-platform results never collide.

struct CoverArt: View {
    let url: String
    let title: String
    var radius: CGFloat = 14
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                let palette = Self.palette(title)
                LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(.white.opacity(0.12)).frame(width: geometry.size.width * 0.85)
                    .offset(x: geometry.size.width * 0.35, y: -geometry.size.height * 0.3)
                Image(systemName: "waveform").font(.system(size: geometry.size.width * 0.25, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.8))
                if let link = Self.imageURL(url) {
                    AsyncImage(url: link) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .accessibilityHidden(true)
    }
    static func palette(_ seed: String) -> [Color] {
        let index = seed.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 4 }
        return [
            [Color(red: 0.79, green: 0.42, blue: 0.32), Color(red: 0.30, green: 0.16, blue: 0.23)],
            [Color(red: 0.38, green: 0.53, blue: 0.50), Color(red: 0.10, green: 0.24, blue: 0.29)],
            [Color(red: 0.48, green: 0.49, blue: 0.68), Color(red: 0.21, green: 0.22, blue: 0.40)],
            [Color(red: 0.74, green: 0.61, blue: 0.37), Color(red: 0.32, green: 0.27, blue: 0.24)]
        ][index]
    }
    static func imageURL(_ raw: String) -> URL? {
        guard !raw.isEmpty, let value = URL(string: raw, relativeTo: URL(string: "http://127.0.0.1:37777"))?.absoluteURL,
              ["http", "https"].contains(value.scheme ?? "") else { return nil }
        return value
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.bold()).tracking(-0.5)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 38, weight: .ultraLight)).foregroundStyle(MusicDesign.coral)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 290)
        }.frame(maxWidth: .infinity).padding(.vertical, 54).padding(.horizontal, 24)
    }
}

struct GlassControls<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 18) { content() }
        } else { content() }
    }
}

extension View {
    @ViewBuilder func musicGlass() -> some View {
        if #available(iOS 26.0, *) { self.glassEffect(.regular, in: .capsule) }
        else { self.background(.regularMaterial, in: Capsule()) }
    }
}

struct SourcePill: View {
    let title: String
    var selected = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 15).padding(.vertical, 10)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? MusicDesign.coral : Color.secondary.opacity(0.09), in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
