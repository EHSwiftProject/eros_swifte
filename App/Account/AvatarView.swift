import Foundation
import Nuke
import SwiftUI
import UIKit

/// The account's avatar, or the system default avatar when there is none or it cannot be loaded.
///
/// Not `AsyncImage`: that would skip the throttle, send another user agent than the WebKit one and leave cookies in
/// `Library/Cookies` (preflight M9). The image comes from `AvatarLoader` instead.
struct AvatarView: View {
    let url: URL?

    @Environment(AppEnvironment.self) private var environment
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(Circle())
        .accessibilityIdentifier("account.avatar")
        .task(id: url) {
            image = nil
            guard let url else { return }
            // Leaving does not cancel the load: it goes on and fills the loader's memory (see AvatarLoader).
            image = await environment.avatars.image(for: url)
        }
    }
}

/// Loads avatar images through the avatar pipeline (`ImagePipelines.avatars`): its data loader sends them the way the
/// app sends every image request (`EHImageDataLoader`: throttled, with the WebKit user agent and the Cookie header of
/// the image's own host only, redirects followed by hand, each hop throttled and rescoped, on sessions without cookie
/// storage or URL cache).
///
/// Each URL is asked for at most once until `removeAll()` (logging out, or the start of a login: the account may
/// change), whatever happens to the views (user decision 2026-11-05: what cannot be read is not retried; a 429 must
/// not be asked again each time the settings page shows):
/// - a loaded image is kept in memory, here (the pipeline's memory cache may evict it; this keeps it);
/// - a failed URL (any status but 200, not an image, a transport or throttle error) is remembered and answered nil;
/// - one load per URL is in flight at a time, and every caller waits for it. The load runs in a task of its own that
///   a caller's cancellation does not reach: when a view leaves mid-load (its `.task` is cancelled), the load is not
///   cancelled; it goes on and its result fills the memory, so the view finds it when it comes back instead of asking
///   again. Only `removeAll()` cancels loads, and a cancelled load records nothing.
@MainActor final class AvatarLoader {
    /// The avatar pipeline: memory cache only.
    let pipeline: ImagePipeline
    private var images: [URL: UIImage] = [:]
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    /// One more on every `removeAll()`: a load started before it records nothing.
    private var generation = 0

    init(pipeline: ImagePipeline) {
        self.pipeline = pipeline
    }

    /// The image at `url` (https only); nil when it cannot be loaded or is not an image. Asks the site at most once per
    /// URL until `removeAll()` (see the type's documentation). A cancelled caller still gets the load's result when
    /// it ends; its cancellation never cancels the load.
    func image(for url: URL) async -> UIImage? {
        if let image = images[url] { return image }
        if failed.contains(url) { return nil }
        let load: Task<UIImage?, Never>
        if let running = inFlight[url] {
            load = running
        } else {
            let started = generation
            let pipeline = pipeline
            load = Task {
                let image = try? await pipeline.image(for: url)
                self.finish(url, with: image, generation: started)
                return image
            }
            inFlight[url] = load
        }
        return await load.value
    }

    /// Whether `url`'s image is kept in memory.
    func hasImage(for url: URL) -> Bool { images[url] != nil }

    /// Whether `url` failed and will not be asked for again before `removeAll()`.
    func hasFailed(_ url: URL) -> Bool { failed.contains(url) }

    /// Whether a load of `url` is in flight.
    func isLoading(_ url: URL) -> Bool { inFlight[url] != nil }

    /// Forgets every image and every failure, the pipeline's memory cache included, and cancels the loads in flight
    /// (logging out, a new login).
    func removeAll() {
        generation += 1
        for load in inFlight.values { load.cancel() }
        inFlight = [:]
        images = [:]
        failed = []
        pipeline.cache.removeAll(caches: .memory)
    }

    /// Records a load's result, unless `removeAll()` came in meanwhile.
    private func finish(_ url: URL, with image: UIImage?, generation: Int) {
        guard generation == self.generation else { return }
        inFlight[url] = nil
        if let image {
            images[url] = image
        } else {
            failed.insert(url)
        }
    }
}
