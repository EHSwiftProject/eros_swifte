import EHModels
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Eros

/// `ListTagView`: the text it shows and what a window of its own renders.
@MainActor @Suite struct ListTagViewTests {
    private static let translated = TagRef(raw: "female:fake tag")
    private static let untranslated = TagRef(raw: "female:other fake")

    /// An environment (own settings suite, in-memory tag database) holding the made-up translation, prefetched.
    private static func makeEnvironment(showsTranslations: Bool) async throws -> AppEnvironment {
        let environment = AppEnvironment(uiTesting: true)
        let store = try #require(environment.tagTranslations)
        _ = try await store.replaceAll(with: TagNameCacheTests.smallDatabase, version: "v0 test")
        await environment.tagNames.prefetch([translated, untranslated])
        environment.settings.settings.showsTagTranslations = showsTranslations
        return environment
    }

    @Test func translatedTagShowsThePlainName() async throws {
        let environment = try await Self.makeEnvironment(showsTranslations: true)
        #expect(
            ListTagView.text(for: Self.translated, showsTranslations: true, names: environment.tagNames) == "示例标签"
        )
        let host = try HostedViews.show(
            ListTagView(tag: ListTag(tag: Self.translated, colors: nil)), environment: environment
        )
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.labels(in: host.view).contains("示例标签") })
        #expect(!Self.labels(in: host.view).contains("fake tag"))
    }

    @Test func translationsOffShowTheOriginal() async throws {
        let environment = try await Self.makeEnvironment(showsTranslations: false)
        #expect(
            ListTagView.text(for: Self.translated, showsTranslations: false, names: environment.tagNames)
                == "fake tag"
        )
        let host = try HostedViews.show(
            ListTagView(tag: ListTag(tag: Self.translated, colors: nil)), environment: environment
        )
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.labels(in: host.view).contains("fake tag") })
        #expect(!Self.labels(in: host.view).contains("示例标签"))
    }

    @Test func untranslatedTagShowsTheOriginal() async throws {
        let environment = try await Self.makeEnvironment(showsTranslations: true)
        #expect(
            ListTagView.text(for: Self.untranslated, showsTranslations: true, names: environment.tagNames)
                == "other fake"
        )
    }

    @Test func tagIsNotAButtonWithoutAnAction() async throws {
        let environment = try await Self.makeEnvironment(showsTranslations: true)
        let host = try HostedViews.show(
            ListTagView(tag: ListTag(tag: Self.translated, colors: nil)), environment: environment
        )
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.labels(in: host.view).contains("示例标签") })
        #expect(!HostedViews.identifiers(in: host.view).contains("list.tag"))
    }

    @Test func tagIsAButtonWhenAnActionIsSet() async throws {
        let environment = try await Self.makeEnvironment(showsTranslations: true)
        let owner = NSObject()
        let view = ListTagView(tag: ListTag(tag: Self.translated, colors: nil))
            .environment(\.listTagAction, ListTagAction(owner) { _, _ in })
        let host = try HostedViews.show(view, environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually { HostedViews.identifiers(in: host.view).contains("list.tag") })
        #expect(HostedViews.elements(in: host.view).contains { $0.accessibilityValue == "female:fake tag" })
    }

    /// The action is compared by its owner (L071e): the search page passes a new closure on every redraw, which would
    /// redraw every tag of its results; the same owner's actions are equal, another owner's are not. Performing it
    /// hands the closure the owner and the tag.
    @Test func actionsAreComparedByTheirOwner() {
        let owner = TapLog()
        let other = TapLog()
        let first = ListTagAction(owner) { $0.tags.append($1) }
        let second = ListTagAction(owner) { _, _ in }
        let another = ListTagAction(other) { _, _ in }
        #expect(first == second)
        #expect(first != another)
        first(Self.translated)
        #expect(owner.tags == [Self.translated])
        #expect(other.tags.isEmpty)
    }

    /// The action holds its owner weakly (M2 re-review F3 M-6): it does not keep a page's model alive, and once the
    /// owner is gone, performing it does nothing.
    @Test func anActionDoesNotKeepItsOwner() {
        var owner: TapLog? = TapLog()
        weak let held = owner
        let performed = TapLog()
        let action = ListTagAction(owner!) { _, tag in performed.tags.append(tag) }
        owner = nil
        #expect(held == nil)
        action(Self.translated)
        #expect(performed.tags.isEmpty)
    }

    // MARK: - Helpers

    /// The tags an action was performed with.
    @MainActor private final class TapLog {
        var tags: [TagRef] = []
    }

    /// The accessibility labels under `root`, on a window of `HostedViews`.
    private static func labels(in root: NSObject) -> [String] {
        HostedViews.elements(in: root).compactMap(\.accessibilityLabel)
    }
}
