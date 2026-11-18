import EHModels
import EHNetwork
import Foundation
import ImageIO
import Observation
import UIKit

/// The image search page (search Q5; Flutter `search_image_controller.dart`, request.dart:1087-1147): the image picked,
/// made ready for the upload (`ImageLookupUpload.prepare(_:limit:)`), the search's switches, and the search.
///
/// - Picking an image (from Photos, Files, or as bytes) prepares it off the main actor (`isPreparing` meanwhile). When
///   picks overlap, the later one is kept: a preparation that started earlier and ends later changes nothing. A failed
///   pick keeps the image picked before and says why in `failureMessage`.
/// - A file over `ImageLookupUpload.maximumInputBytes` is refused by its size, never read; whatever its size, no more
///   than one byte past that is ever read from it.
/// - `search()` sends the image with `options` through `lookup`, one search at a time, never while an image is being
///   prepared; a search that finds the results puts them in `result`, which the page pushes once and clears.
/// - Failures are worded for the user in `failureMessage` (the page shows them in an alert and clears it); a cancelled
///   search, or one whose session ended, says nothing (`ListFailure(_:)`).
///
/// Nothing about the image, its file name or path is logged.
@MainActor @Observable final class ImageSearchModel {
    /// Sends an image search: the bytes, their format, the switches.
    typealias Lookup = @MainActor (Data, ImageFormat, ImageLookupOptions) async throws -> ImageLookupResult
    /// Makes picked bytes ready for the upload, off the main actor.
    typealias Prepare = @Sendable (Data) async throws -> PreparedImage

    nonisolated static let notAnImageMessage = "This file is not an image Eros-SE can read."
    nonisolated static let tooLargeMessage = "The image is too large to upload, even after making it smaller."
    nonisolated static let noResultsMessage = "The site did not return search results."
    /// The longer side, in pixels, of `preview`: 240 pt at 3x.
    nonisolated static let previewPixels = 720

    /// The site searched.
    let site: EHSite
    /// The search's switches: Similarity Scan on, covers only and expunged off.
    var options = ImageLookupOptions()
    /// The image the search sends; nil until one is picked.
    private(set) var image: PreparedImage?
    /// `image`, made small enough to show (at most `previewPixels` on its longer side, turned upright).
    private(set) var preview: UIImage?
    /// A picked image is being made ready.
    private(set) var isPreparing = false
    /// A search is out.
    private(set) var isSearching = false
    /// The results of the last search, until the page has pushed them.
    var result: ImageLookupResult?
    /// What went wrong, worded for the user, until the page has shown it.
    var failureMessage: String?

    @ObservationIgnored private let lookup: Lookup
    @ObservationIgnored private let prepare: Prepare
    /// One more with every pick: a preparation whose number is no longer the latest changes nothing.
    @ObservationIgnored private var picks = 0

    /// - Parameter prepare: Makes picked bytes ready; `ImageLookupUpload.prepare(_:limit:)` off the main actor when
    ///   nil. The tests pass their own, to hold one preparation while another ends.
    init(site: EHSite, lookup: @escaping Lookup, prepare: Prepare? = nil) {
        self.site = site
        self.lookup = lookup
        self.prepare = prepare ?? { data in try await ImageSearchModel.prepared(data) }
    }

    /// Whether `search()` would send: an image is there, and neither a preparation nor a search is out.
    var canSearch: Bool {
        image != nil && !isPreparing && !isSearching
    }

    // MARK: - Picking

    /// Picks `data` (see the type).
    func choose(_ data: Data) async {
        await choose { data }
    }

    /// Picks the bytes `load` gives (Photos' `loadTransferable`). No bytes, or a load that fails, is not an image; a
    /// cancelled load says nothing.
    func choose(loading load: @escaping @Sendable () async throws -> Data?) async {
        let pick = beginPicking()
        let outcome: Result<PreparedImage, any Error>
        do {
            let data: Data?
            do {
                data = try await load()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ImageLookupUploadError.notAnImage
            }
            guard let data else { throw ImageLookupUploadError.notAnImage }
            outcome = .success(try await prepare(data))
        } catch {
            outcome = .failure(error)
        }
        await finishPicking(pick, with: outcome)
    }

    /// Picks the file at `url` (`fileImporter`), read while its security-scoped resource is accessed (and all the same
    /// when that is refused, as for the app's own and temporary files). A file over
    /// `ImageLookupUpload.maximumInputBytes` is refused by its size and never read; one whose size cannot be read is
    /// read up to one byte past it, and refused the same way when it has more (`contents(of:)`). One that cannot be
    /// read is not an image.
    func chooseFile(at url: URL) async {
        let pick = beginPicking()
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing { url.stopAccessingSecurityScopedResource() }
        }
        let outcome: Result<PreparedImage, any Error>
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > ImageLookupUpload.maximumInputBytes {
            outcome = .failure(ImageLookupUploadError.tooLarge)
        } else {
            do {
                let data = try await Self.contents(of: url)
                outcome = .success(try await prepare(data))
            } catch {
                outcome = .failure(error)
            }
        }
        await finishPicking(pick, with: outcome)
    }

    private func beginPicking() -> Int {
        picks += 1
        isPreparing = true
        failureMessage = nil
        return picks
    }

    /// Takes the outcome of pick `pick` unless a later pick began meanwhile.
    private func finishPicking(_ pick: Int, with outcome: Result<PreparedImage, any Error>) async {
        switch outcome {
        case .success(let prepared):
            let preview = await Self.preview(of: prepared.data)
            guard pick == picks else { return }
            image = prepared
            self.preview = preview
        case .failure(let error):
            guard pick == picks else { return }
            failureMessage = Self.message(for: error)
        }
        isPreparing = false
    }

    // MARK: - Searching

    /// Sends `image` with `options` (see the type); does nothing without an image, while one is being prepared, or
    /// while a search is out.
    func search() async {
        guard canSearch, let image else { return }
        isSearching = true
        failureMessage = nil
        defer { isSearching = false }
        do {
            result = try await lookup(image.data, image.format, options)
        } catch {
            failureMessage = Self.message(for: error)
        }
    }

    /// The words for `error`: an image that cannot be read or made small enough, a search that found no results page
    /// (`ImageLookupError`), else as a list says it (`ListFailure`); nil for a cancellation or an ended session.
    nonisolated static func message(for error: any Error) -> String? {
        switch error {
        case let error as ImageLookupUploadError:
            switch error {
            case .notAnImage: notAnImageMessage
            case .tooLarge: tooLargeMessage
            }
        case is ImageLookupError:
            noResultsMessage
        default:
            ListFailure(error)?.message
        }
    }

    // MARK: - Off the main actor

    /// `ImageLookupUpload.prepare(_:limit:)` of `data`, off the main actor.
    @concurrent private nonisolated static func prepared(_ data: Data) async throws -> PreparedImage {
        try ImageLookupUpload.prepare(data)
    }

    /// The bytes of the file at `url`, off the main actor, read through a `FileHandle` up to one byte past
    /// `ImageLookupUpload.maximumInputBytes`: a file whose size could not be read beforehand, or that grew since, is
    /// never read whole. More than the maximum is `ImageLookupUploadError.tooLarge`; a
    /// failure to read is `.notAnImage`. Neither carries the path.
    @concurrent private nonisolated static func contents(of url: URL) async throws -> Data {
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: ImageLookupUpload.maximumInputBytes + 1) ?? Data()
        } catch {
            throw ImageLookupUploadError.notAnImage
        }
        guard data.count <= ImageLookupUpload.maximumInputBytes else { throw ImageLookupUploadError.tooLarge }
        return data
    }

    /// The first frame of `data`, at most `previewPixels` on its longer side and turned upright, off the main actor;
    /// nil when ImageIO reads no image from it.
    @concurrent private nonisolated static func preview(of data: Data) async -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
