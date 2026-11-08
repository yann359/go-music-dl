import SwiftUI

@main
struct MusicDLApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            NativeRoot()
                .environmentObject(model).environmentObject(model.client).environmentObject(model.audio)
                .tint(MusicDesign.coral)
                .task { await model.start() }
        }
    }
}

struct NativeRoot: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.colorScheme) private var scheme
    @AppStorage("music.appearance") private var appearance = "system"
    @Namespace private var playerTransition
    var body: some View {
        Group {
            if model.isReady {
                if #available(iOS 26.0, *) {
                    tabs.tabViewBottomAccessory {
                        if audio.currentSong != nil {
                            MiniPlayer().matchedTransitionSource(id: "player", in: playerTransition)
                        }
                    }.tabBarMinimizeBehavior(.onScrollDown)
                } else {
                    tabs.safeAreaInset(edge: .bottom, spacing: 0) {
                        if audio.currentSong != nil { MiniPlayer().background(.regularMaterial) }
                    }
                }
            } else if let error = model.error {
                VStack(spacing: 20) {
                    NativeEmptyState(symbol: "wifi.exclamationmark", title: "暂时没能启动", detail: error)
                    Button("重新连接") { Task { await model.start() } }.buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "waveform.path").font(.system(size: 52, weight: .ultraLight)).foregroundStyle(MusicDesign.coral)
                    Text("澄音").font(.system(.largeTitle, design: .rounded).weight(.medium)).tracking(6)
                    ProgressView().padding(.top, 12)
                }
            }
        }
        .background(MusicDesign.canvas(scheme))
        .preferredColorScheme(appearance == "system" ? nil : appearance == "dark" ? .dark : .light)
        .sheet(isPresented: $model.showPlayer) {
            if #available(iOS 18.0, *) {
                FullPlayer().navigationTransition(.zoom(sourceID: "player", in: playerTransition))
                    .presentationDragIndicator(.visible).presentationCornerRadius(36)
            } else { FullPlayer().presentationDragIndicator(.visible) }
        }
        .overlay(alignment: .top) {
            if let message = model.toast {
                Text(message).font(.subheadline).padding(16).frame(maxWidth: 360)
                    .musicGlass().padding(.horizontal).padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity)).zIndex(10)
            }
        }
    }
    private var tabs: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack { DiscoverScreen() }.tabItem { Label("发现", systemImage: "sparkles") }.tag(0)
            NavigationStack { SearchScreen() }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(1)
            NavigationStack { LibraryScreen() }.tabItem { Label("音乐库", systemImage: "square.stack") }.tag(2)
            NavigationStack { ProfileScreen() }.tabItem { Label("我的", systemImage: "person.crop.circle") }.tag(3)
        }
    }
}
