import EHNetwork
import EHParsing
import Foundation
import Nuke
import SwiftUI
import UIKit

/// What a `RemoteImage` shows: nothing yet (no URL, or still loading), the image with its size in pixels, or a failure.
nonisolated enum RemoteImagePhase {
    case empty
    case success(Image, size: CGSize)
    case failure
}

/// A site image (a cover, a thumbnail) from the thumbnail pipeline, `AppEnvironment.images`, which every request of
/// goes through the throttle with the site's identity (`EHImageDataLoader`). Not `AsyncImage`: that would skip both.
///
/// The image loads in a task keyed by the URL and whether both sites are paused (`AppEnvironment.sitePause`), so it is
/// cancelled when the view goes (a load cancelled while it waits for the throttle never goes out) and loads again when
/// it comes back; one the memory cache holds shows at once. A failure shows `.failure` and is not retried while the
/// view stays; nothing is prefetched. A load refused because both sites are paused (`EHNetworkError.paused`: a 429
/// pauses them for a minute, a ban until it ends) is no failure but a wait (A-M2): nothing is recorded, and when the
/// pause ends the key changes and the image loads. So is a load whose own answer began the pause (a 429 or a ban
/// notice from a guarded host, `pausesBothSites(_:)`): the thumbnails on screen when it began (M2 re-review F3 M-1).
struct RemoteImage<Content: View>: View {
    /// A load's outcome, with the URL it was for.
    private struct Loaded {
        let url: URL
        let phase: RemoteImagePhase
    }

    private let url: URL?
    private let content: (RemoteImagePhase) -> Content

    @Environment(AppEnvironment.self) private var environment
    @State private var loaded: Loaded?

    init(url: URL?, @ViewBuilder content: @escaping (RemoteImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: LoadKey(url: url, isPaused: environment.sitePause != nil)) { await load() }
    }

    /// What a load depends on: the URL, and whether both sites are paused.
    private struct LoadKey: Equatable {
        let url: URL?
        let isPaused: Bool
    }

    /// The outcome for the current URL, else the memory cache's image, else `.empty`.
    private var phase: RemoteImagePhase {
        guard let url else { return .empty }
        if let loaded, loaded.url == url { return loaded.phase }
        if let image = environment.images.cache[url]?.image { return Self.success(image) }
        return .empty
    }

    private func load() async {
        guard let url else { return }
        // An outcome for this URL stays: an image is shown, a failure is not retried.
        if let loaded, loaded.url == url { return }
        do {
            let image = try await environment.images.image(for: url)
            loaded = Loaded(url: url, phase: Self.success(image))
        } catch {
            // The view went (or the URL changed), or the load is a wait (`waits(after:loading:)`): nothing is
            // recorded, so it loads again when it comes back, the session settles or the pause ends.
            guard !Task.isCancelled, !Self.waits(after: error.dataLoadingError, loading: url) else { return }
            loaded = Loaded(url: url, phase: .failure)
        }
    }

    /// Whether a load of `url` that failed for `reason` (the data loader's error) is a wait rather than a failure:
    /// - it straddled a logout or the start of a login (`ImageLoadError.superseded`);
    /// - both sites are paused (`EHNetworkError.paused`);
    /// - its own answer began the pause (a 429 or a ban notice from a guarded host, `pausesBothSites(_:)`): both sites
    ///   are paused by then, so the key turns paused, then not, and the image loads (M2 re-review F3 M-1). A host the
    ///   breaker does not guard (H@H) pauses nothing, and its 429 stays a failure.
    static func waits(after reason: (any Error)?, loading url: URL) -> Bool {
        if reason as? ImageLoadError == .superseded { return true }
        switch reason as? EHNetworkError {
        case .paused?:
            return true
        case .issue(let issue)?:
            return pausesBothSites(issue) && SiteBreaker.isGuarded(host: url.host() ?? "")
        default:
            return false
        }
    }

    /// Whether `SiteBreaker.record(_:at:)` pauses both sites for `issue` met at a guarded host: a ban and a 429.
    static func pausesBothSites(_ issue: ResponseIssue) -> Bool {
        switch issue {
        case .banned, .tooManyRequests: true
        case .bandwidthExceeded, .exAccessDenied, .keyMismatch: false
        }
    }

    private static func success(_ image: UIImage) -> RemoteImagePhase {
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return .success(Image(uiImage: image), size: size)
    }
}
