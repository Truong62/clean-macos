import Foundation
import Combine

struct EditorSharedLink: Equatable, Sendable {
    let url: URL
    let expiresAt: Date
    let deletionToken: String
    func usable(at date: Date) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && expiresAt > date && !deletionToken.isEmpty
    }
}

protocol EditorLinkService: Sendable {
    func upload(_ data: Data, format: EditorFormat, lifetime: TimeInterval) async throws -> EditorSharedLink
    func delete(_ link: EditorSharedLink) async throws
}

enum EditorLinkState: Equatable {
    case idle, uploading, ready(EditorSharedLink), deleting(EditorSharedLink), failed(String)
    var isBusy: Bool {
        switch self {
        case .uploading, .deleting: true
        default: false
        }
    }
    var link: EditorSharedLink? {
        switch self {
        case .ready(let link), .deleting(let link): link
        default: nil
        }
    }
}

@MainActor
final class EditorLinkController: ObservableObject {
    @Published private(set) var state = EditorLinkState.idle
    @Published private(set) var error: String?
    private var generation = UUID()
    func upload(_ data: Data, format: EditorFormat, service: any EditorLinkService, now: Date = Date()) async {
        guard !state.isBusy else { return }
        let token = UUID()
        generation = token
        state = .uploading
        error = nil
        do {
            let link = try await service.upload(data, format: format, lifetime: 3600)
            guard generation == token else { return }
            guard link.usable(at: now) else { state = .failed("The service returned an invalid or expired link."); return }
            state = .ready(link)
        } catch { if generation == token { state = .failed(error.localizedDescription) } }
    }
    func delete(service: any EditorLinkService) async {
        guard case .ready(let link) = state else { return }
        state = .deleting(link)
        error = nil
        do {
            try await service.delete(link)
            state = .idle
        } catch { state = .ready(link); self.error = error.localizedDescription }
    }
}
