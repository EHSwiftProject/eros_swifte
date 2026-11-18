import EHModels
import Foundation
import Testing
import UIKit

@testable import Eros

/// The long-press menu of a list item. No test reads or writes the general pasteboard: Copy Link writes where it is
/// told, here a `FakePasteboard` or a named pasteboard of the test's own.
@MainActor @Suite struct ItemMenuActionTests {
    private static let link = "https://e-hentai.org/g/900123/0123456789/"
    private static let id = GalleryID(gid: 900_123, token: "0123456789")

    @Test func copyLinkWritesTheGalleryURL() {
        let pasteboard = FakePasteboard()
        ItemMenuAction.copyLink(Self.id, site: .eh, to: pasteboard)
        #expect(pasteboard.written == [URL(string: Self.link)])
        #expect(pasteboard.reads == 0)
    }

    /// What the app's pasteboard holds after Copy Link (`UIPasteboard.writeURL(_:)`): the URL and its text, read back
    /// through `PasteboardSource` as the clipboard monitor reads it.
    @Test func aSystemPasteboardHoldsTheURLAndItsText() async throws {
        let name = UIPasteboard.Name("proj.eros.swifte.tests.\(UUID().uuidString)")
        let pasteboard = try #require(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let source: any PasteboardSource = pasteboard
        let before = source.changeCount
        #expect(await !source.mayHoldWebURL())

        ItemMenuAction.copyLink(Self.id, site: .eh, to: pasteboard)
        #expect(source.changeCount != before)
        #expect(await source.mayHoldWebURL())
        #expect(pasteboard.url == URL(string: Self.link))
        #expect(source.hasStrings)
        #expect(source.string == Self.link)
    }

    /// A URL item without text (`UIPasteboard.url` set alone) reads as text too: `hasStrings` holds and `string` gives
    /// the URL's text, so the clipboard monitor, which reads the text only, still finds a link another app put on
    /// the clipboard as a URL. On a pasteboard of the test's own, never the general one.
    @Test func aURLOnlyItemReadsAsText() async throws {
        let name = UIPasteboard.Name("proj.eros.swifte.tests.\(UUID().uuidString)")
        let pasteboard = try #require(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        pasteboard.url = URL(string: Self.link)
        #expect(pasteboard.hasStrings)
        #expect(pasteboard.string == Self.link)
        #expect(await (pasteboard as any PasteboardSource).mayHoldWebURL())
    }

    /// The system's pattern detection (`mayHoldWebURL()`, which never makes the system ask) finds a web link in plain
    /// text, alone or inside a sentence, and nothing in text without one: what the clipboard monitor relies on (user
    /// decision 2026-11-17). On a pasteboard of the test's own, never the general one.
    @Test func aSystemPasteboardFindsLinksInPlainText() async throws {
        let name = UIPasteboard.Name("proj.eros.swifte.tests.\(UUID().uuidString)")
        let pasteboard = try #require(UIPasteboard(name: name, create: true))
        defer { UIPasteboard.remove(withName: name) }
        let source: any PasteboardSource = pasteboard
        for (text, holds) in [
            (Self.link, true), ("Look at this one: \(Self.link) (fake)", true), ("fake words, no link", false),
        ] {
            pasteboard.string = text
            #expect(await source.mayHoldWebURL() == holds, Comment(rawValue: text))
        }
    }
}
