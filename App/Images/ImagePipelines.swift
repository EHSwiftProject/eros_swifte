import Foundation
import Nuke

/// The app's two Nuke pipelines. Both load through an `EHImageDataLoader` (the throttle, the site's identity, the
/// breaker) and have a memory cache of their own (never `ImageCache.shared`, so clearing one leaves the other, and two
/// environments share nothing). Neither reads local resources (`file:` and `data:` URLs go to the loader, which
/// refuses them) or resumes partial downloads (the loader only hands over whole 200 answers).
nonisolated enum ImagePipelines {
    /// The thumbnails' disk cache limit.
    static let thumbnailDiskCacheLimit = 300 * 1024 * 1024

    /// Thumbnails: memory cache plus, when diskCacheName is non-nil, a DataCache in the system Caches directory (300 MB).
    /// A disk cache that cannot be created leaves the pipeline with the memory cache only.
    static func thumbnails(dataLoader: EHImageDataLoader, diskCacheName: String?) -> ImagePipeline {
        var configuration = baseConfiguration(dataLoader: dataLoader)
        if let diskCacheName, let cache = try? DataCache(name: diskCacheName) {
            cache.sizeLimit = thumbnailDiskCacheLimit
            configuration.dataCache = cache
        }
        return ImagePipeline(configuration: configuration)
    }

    /// Avatars: memory cache only.
    static func avatars(dataLoader: EHImageDataLoader) -> ImagePipeline {
        ImagePipeline(configuration: baseConfiguration(dataLoader: dataLoader))
    }

    private static func baseConfiguration(dataLoader: EHImageDataLoader) -> ImagePipeline.Configuration {
        var configuration = ImagePipeline.Configuration(dataLoader: dataLoader)
        configuration.imageCache = ImageCache()
        configuration.dataCache = nil
        configuration.isLocalResourcesSupportEnabled = false
        configuration.isResumableDataEnabled = false
        return configuration
    }
}
