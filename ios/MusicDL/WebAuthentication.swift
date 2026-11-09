import AuthenticationServices
import UIKit

@MainActor
final class WebAuthentication: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var deadline: Task<Void, Never>?
    private var operation: UUID?

    func open(_ url: URL) async throws -> URL {
        guard session == nil else { throw MusicAccountError.service }
        let id = UUID(); operation = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: URL(string: SpotifyConfiguration.redirect)!.scheme) { [weak self] callback, error in
                    Task { @MainActor [weak self] in
                        guard let self, self.operation == id else { return }
                        if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                            self.finish(.failure(MusicAccountError.cancelled), id: id)
                        } else if error != nil || callback == nil { self.finish(.failure(MusicAccountError.service), id: id) }
                        else { self.finish(.success(callback!), id: id) }
                    }
                }
                self.session = session
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = false
                if !session.start() { finish(.failure(MusicAccountError.service), id: id); return }
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
                    self?.cancel(reason: .timeout)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.operation == id else { return }
                self?.cancel(reason: .cancelled)
            }
        }
    }
    func cancel(reason: MusicAccountError = .cancelled) {
        guard let id = operation else { return }
        session?.cancel()
        finish(.failure(reason), id: id)
    }
    private func finish(_ result: Result<URL, Error>, id: UUID) {
        guard operation == id else { return }
        let pending = continuation
        operation = nil; continuation = nil; session = nil
        deadline?.cancel(); deadline = nil
        pending?.resume(with: result)
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
