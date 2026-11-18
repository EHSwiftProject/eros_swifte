import EHModels
import EHNetwork
import Foundation
import Testing

@testable import Eros

/// A `ListFeed` that answers from a script: each position has a queue of answers (a page, or an error), taken in turn,
/// each held by its `Gate` until the test opens it. Records every call; a call for a position with nothing left queued
/// records an issue and throws `Unscripted`.
@MainActor final class ScriptedFeed: ListFeed {
    /// One call: the position and whether it asked the site (`refresh`).
    struct Call: Equatable, CustomStringConvertible {
        let position: ListPosition
        let refresh: Bool

        init(_ position: ListPosition, _ refresh: Bool) {
            self.position = position
            self.refresh = refresh
        }

        var description: String { "(\(position), \(refresh))" }
    }

    /// Thrown for a call nothing was queued for.
    struct Unscripted: Error {}

    private enum Reply {
        case page(ListPageResult)
        case failure(any Error)
    }

    private struct Step {
        let reply: Reply
        let gate: Gate?
    }

    private var script: [ListPosition: [Step]] = [:]
    /// Every call, oldest first.
    private(set) var calls: [Call] = []

    /// Queues `page` as the next answer at `position`; `cached`: the answer came from the response cache.
    func answer(_ position: ListPosition, _ page: GalleryListPage, cached: Bool = false, gate: Gate? = nil) {
        script[position, default: []].append(
            Step(reply: .page(ListPageResult(page: page, isFromCache: cached)), gate: gate)
        )
    }

    /// Queues `error` as the next answer at `position`.
    func fail(_ position: ListPosition, _ error: any Error, gate: Gate? = nil) {
        script[position, default: []].append(Step(reply: .failure(error), gate: gate))
    }

    func page(at position: ListPosition, refresh: Bool) async throws -> ListPageResult {
        calls.append(Call(position, refresh))
        guard var steps = script[position], !steps.isEmpty else {
            Issue.record("nothing scripted for \(position)")
            throw Unscripted()
        }
        let step = steps.removeFirst()
        script[position] = steps
        if let gate = step.gate { await gate.wait() }
        switch step.reply {
        case .page(let result): return result
        case .failure(let error): throw error
        }
    }
}

/// A list row with made-up values: gallery `gid` (from 900001 on in these tests), a token from its gid.
func makeItem(_ gid: Int) -> GallerySummary {
    GallerySummary(
        id: GalleryID(gid: gid, token: String(format: "%010x", gid)), title: "fake gallery \(gid)",
        category: .misc, coverURL: URL(string: "https://ehgt.org/t/00/00/fake-cover-\(gid).jpg"), coverSize: nil,
        tags: [], postedAt: nil, rating: 0, isRatedByUser: false, favoriteSlot: nil, favoriteName: nil,
        favoriteNote: nil, uploader: "fake uploader", isUploaderDimmed: false, pageCount: 10, isExpunged: false
    )
}

/// A Compact list page of the rows `gids`, with the given cursors, page numbers and the text above the results.
func makePage(
    _ gids: [Int], next: String? = nil, previous: String? = nil, index: Int? = nil, count: Int? = nil,
    summary: String? = nil, filtered: Int? = nil
) -> GalleryListPage {
    GalleryListPage(
        items: gids.map(makeItem), skippedRowCount: 0, displayMode: .compact, previousCursor: previous,
        nextCursor: next, pageIndex: index, pageCount: count, resultSummary: summary, filteredCount: filtered,
        similarityScanDisabled: false, favoriteFolders: [], favoritesOrder: nil
    )
}
