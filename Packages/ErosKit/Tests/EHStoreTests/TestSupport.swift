import EHModels
import Foundation

/// Runs `body` with a fresh directory under the temporary directory and removes it afterwards.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let manager = FileManager.default
    let directory = manager.temporaryDirectory
        .appending(path: "eros-store-\(UUID().uuidString)", directoryHint: .isDirectory)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: directory) }
    return try await body(directory)
}

/// A made-up gallery summary with all 16 fields set (the date has whole seconds, so JSON keeps it exactly).
func fakeSummary(gid: Int, title: String = "Fake title") -> GallerySummary {
    GallerySummary(
        id: GalleryID(gid: gid, token: "0123456789"),
        title: title,
        category: .doujinshi,
        coverURL: URL(string: "https://example.invalid/c/\(gid).jpg"),
        coverSize: ImageSize(width: 250, height: 353),
        tags: [
            ListTag(
                tag: TagRef(namespace: "female", name: "fake tag"),
                colors: TagColors(text: "#112233", border: "#445566", background: "#778899")
            )
        ],
        postedAt: Date(timeIntervalSince1970: 1_700_000_000),
        rating: 4.5,
        isRatedByUser: true,
        favoriteSlot: 3,
        favoriteName: "示例收藏夹",
        favoriteNote: "示例备注",
        uploader: "fake uploader",
        isUploaderDimmed: true,
        pageCount: 42,
        isExpunged: true
    )
}

/// Polls `condition` every 10 ms for at most `limit`; true once it holds.
func waitUntil(within limit: Duration = .seconds(5), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
