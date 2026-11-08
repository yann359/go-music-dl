import SwiftUI
import WebKit
import UniformTypeIdentifiers

@main
struct MusicDLApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            Group {
                if let url = model.url {
                    LegacyWebView(url: url, engine: model.audio)
                } else if let error = model.error {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text("启动失败").font(.title2)
                        Text(error).font(.body).textSelection(.enabled)
                        Button("重试") { Task { await model.start() } }
                    }.padding()
                } else { ProgressView("正在启动音乐服务…") }
            }
            .task { await model.start() }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var url: URL?
    @Published var error: String?
    let audio = AudioEngine()
    private var starting = false
    func start() async {
        guard url == nil && !starting else { return }
        // Hosted tests should not contact any music providers or start the server.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        starting = true; error = nil
        defer { starting = false }
        do {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            url = try await GoBridge.start(root: root.path)
        } catch { self.error = error.localizedDescription }
    }
}

struct LegacyWebView: UIViewRepresentable {
    let url: URL
    let engine: AudioEngine
    func makeCoordinator() -> Coordinator { Coordinator(engine: engine, origin: url) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let controller = configuration.userContentController
        if let path = Bundle.main.url(forResource: "native-audio", withExtension: "js"),
           let script = try? String(contentsOf: path, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        controller.add(context.coordinator, name: "musicDL")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        context.coordinator.webView = view
        engine.stateDidChange = { [weak coordinator = context.coordinator] state in coordinator?.receive(state) }
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "musicDL")
        coordinator.engine.stateDidChange = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        let engine: AudioEngine
        let origin: URL
        weak var webView: WKWebView?
        private var destinations: [ObjectIdentifier: URL] = [:]
        init(engine: AudioEngine, origin: URL) { self.engine = engine; self.origin = origin }

        private func trusted(_ url: URL?) -> Bool {
            guard let url else { return false }
            return url.scheme == origin.scheme && url.host == origin.host && url.port == origin.port
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, trusted(message.frameInfo.request.url),
                  JSONSerialization.isValidJSONObject(message.body),
                  let data = try? JSONSerialization.data(withJSONObject: message.body), data.count <= 8 * 1024 * 1024,
                  let request = try? JSONDecoder().decode(PlaybackRequest.self, from: data) else { return }
            engine.handle(request)
        }

        func receive(_ state: [String: Any]) {
            guard let view = webView, trusted(view.url), UIApplication.shared.applicationState == .active,
                  let data = try? JSONSerialization.data(withJSONObject: state),
                  let text = String(data: data, encoding: .utf8) else { return }
            view.evaluateJavaScript("window.musicDLNative?.receive(\(text));", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { engine.publish() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Recover browsing only. Native audio and queue are deliberately untouched.
            webView.reload()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let target = action.request.url else { decisionHandler(.cancel); return }
            if trusted(target) {
                let isDownload = target.path.hasSuffix("/download") || target.path.hasSuffix("/download_lrc")
                    || target.path.hasSuffix("/download_cover")
                decisionHandler(isDownload || action.shouldPerformDownload ? .download : .allow)
            } else {
                decisionHandler(.cancel)
                if ["https", "http"].contains(target.scheme ?? "") { UIApplication.shared.open(target) }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(response.canShowMIMEType ? .allow : .download)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                      completionHandler: @escaping (URL?) -> Void) {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Exports", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = URL(fileURLWithPath: suggestedFilename).lastPathComponent
                let target = directory.appendingPathComponent(UUID().uuidString + "-" + name)
                destinations[ObjectIdentifier(download)] = target
                completionHandler(target)
            } catch { completionHandler(nil) }
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let target = destinations.removeValue(forKey: ObjectIdentifier(download)),
                  let presenter = webView?.window?.rootViewController else { return }
            let sheet = UIActivityViewController(activityItems: [target], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = webView
            presenter.present(sheet, animated: true)
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let target = destinations.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: target) }
            showAlert("下载失败", message: error.localizedDescription)
        }

        private func showAlert(_ title: String, message: String) {
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default))
            webView?.window?.rootViewController?.present(alert, animated: true)
        }

        // Web features use these dialogs for delete/login/collection actions.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            let alert = UIAlertController(title: "MusicDL", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
            webView.window?.rootViewController?.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            let alert = UIAlertController(title: "MusicDL", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
            webView.window?.rootViewController?.present(alert, animated: true)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            let alert = UIAlertController(title: "MusicDL", message: prompt, preferredStyle: .alert)
            alert.addTextField { $0.text = defaultText }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
            webView.window?.rootViewController?.present(alert, animated: true)
        }
    }
}
