import EHModels
import Foundation
import Testing

@testable import Eros

/// `GroupDraft`: what the group editor shows and saves (Flutter `custom_profile_setting_page.dart`).
@MainActor @Suite struct GroupDraftTests {
    /// The default groups, in English, with made-up ids.
    private static let defaults: [CustomGroup] = {
        var next = 0
        return CustomGroup.defaults(languageCode: "en") {
            next += 1
            return "fake-group-\(next)"
        }
    }()

    @Test func newDraftsAreGalleryGroups() {
        let draft = GroupDraft(group: nil)
        #expect(draft.name.isEmpty)
        #expect(draft.type == .gallery)
        #expect(draft.style == nil)
        #expect(draft.categories == nil)
        #expect(draft.searchTexts.isEmpty)
        #expect(!draft.enablesAdvanced)
        #expect(draft.advanced == AdvancedSearch())
        #expect(draft.showsSearchOptions)
        // Every new draft is a group of its own.
        #expect(GroupDraft(group: nil).makeGroup().uuid != draft.makeGroup().uuid)
    }

    @Test func popularHidesSearchOptions() {
        var draft = GroupDraft(group: nil)
        #expect(draft.showsSearchOptions)
        draft.type = .popular
        #expect(!draft.showsSearchOptions)
        draft.type = .watched
        #expect(draft.showsSearchOptions)
        #expect(!GroupDraft(group: Self.defaults[0]).showsSearchOptions)
    }

    @Test func blankNamesCannotBeSaved() {
        var draft = GroupDraft(group: nil)
        #expect(!draft.canSave)
        draft.name = "  "
        #expect(!draft.canSave)
        draft.name = " Name Test "
        #expect(draft.canSave)
        #expect(draft.makeGroup().name == "Name Test")
    }

    @Test func sameNameIsReported() {
        var draft = GroupDraft(group: nil)
        draft.name = " Gallery "
        #expect(draft.replacedGroupName(in: Self.defaults) == "Gallery")
        draft.name = "Other Test"
        #expect(draft.replacedGroupName(in: Self.defaults) == nil)
        draft.name = "   "
        #expect(draft.replacedGroupName(in: Self.defaults) == nil)

        // A group keeps its own name.
        var own = GroupDraft(group: Self.defaults[1])
        #expect(own.replacedGroupName(in: Self.defaults) == nil)
        // A group that is saved again replaces itself (the store matches its uuid first), never another one that
        // has the name it now takes.
        own.name = "Watched"
        #expect(own.replacedGroupName(in: Self.defaults) == nil)
    }

    /// Each search text keeps its id, the same text twice included, so a list row stays with its text when one before
    /// it goes.
    @Test func searchTextsKeepTheirIdentity() {
        var draft = GroupDraft(group: CustomGroup(
            uuid: "fake-group-texts", name: "Texts Test", searchText: ["female:fake tag", "artist:fake artist"]
        ))
        draft.addSearchText("female:fake tag")
        #expect(draft.searchTexts.map(\.text) == ["female:fake tag", "artist:fake artist", "female:fake tag"])
        #expect(Set(draft.searchTexts.map(\.id)).count == 3)
        let ids = draft.searchTexts.map(\.id)

        draft.removeSearchTexts(atOffsets: [0])
        #expect(draft.searchTexts.map(\.id) == Array(ids[1...]))
        #expect(draft.searchTexts.map(\.text) == ["artist:fake artist", "female:fake tag"])
        #expect(draft.makeGroup().searchText == ["artist:fake artist", "female:fake tag"])
    }

    /// An existing group the editor left as it was has no changes (Save then writes nothing); any edit, or a name that
    /// only gained spaces around it, is told apart. A new group always has changes.
    @Test func changesAreToldApart() {
        let gallery = Self.defaults[1]
        var draft = GroupDraft(group: gallery)
        #expect(!draft.hasChanges)
        draft.name = " \(gallery.name) "
        #expect(!draft.hasChanges)
        draft.style = .grid
        #expect(draft.hasChanges)
        draft.style = nil
        #expect(!draft.hasChanges)

        draft.addSearchText("female:fake tag")
        #expect(draft.hasChanges)
        draft.removeSearchTexts(atOffsets: [0])
        #expect(!draft.hasChanges)
        draft.categories = []
        #expect(draft.hasChanges)

        #expect(GroupDraft(group: nil).hasChanges)
    }

    @Test func untouchedCategoriesStayNil() {
        var gallery = Self.defaults[1]
        #expect(gallery.cats == nil)
        var draft = GroupDraft(group: gallery)
        #expect(draft.categories == nil)
        draft.name = "Renamed Test"
        #expect(draft.makeGroup().cats == nil)

        draft.categories = CategoryMask(rawValue: 4)
        #expect(draft.makeGroup().cats == 4)
        draft.categories = []
        #expect(draft.makeGroup().cats == 0)

        gallery.cats = 9
        #expect(GroupDraft(group: gallery).categories == CategoryMask(rawValue: 9))
    }

    /// The Categories row's summary: how many of the ten categories the draft hides (high bits do not count).
    @Test func hiddenCategoriesAreCounted() {
        var draft = GroupDraft(group: Self.defaults[1])
        #expect(draft.hiddenCategoryCount == 0)
        draft.categories = []
        #expect(draft.hiddenCategoryCount == 0)
        draft.categories = .only(.manga)
        #expect(draft.hiddenCategoryCount == 9)
        draft.categories = .allBut(.manga)
        #expect(draft.hiddenCategoryCount == 1)
        draft.categories = CategoryMask(rawValue: 1 << 12 | GalleryCategory.misc.filterBit)
        #expect(draft.hiddenCategoryCount == 1)
    }

    @Test func uneditedFieldsSurvive() throws {
        let group = CustomGroup(
            uuid: "fake-group-kept", name: "Kept Test", searchText: nil, listTypeValue: nil,
            catsTypeValue: "fake cats type", cats: nil, enableAdvance: nil, advSearchTypeValue: "fake advanced type",
            advSearch: nil, listModeValue: nil, hideTab: true, aggregateGroups: ["fake-group-1", "fake-group-2"],
            lastEditTime: 1_700_000_000_000
        )
        // Nothing edited: the group as it was.
        #expect(GroupDraft(group: group).makeGroup() == group)

        var draft = GroupDraft(group: group)
        draft.name = "Edited Test"
        draft.addSearchText("female:fake tag")
        draft.style = .grid
        let edited = draft.makeGroup()
        #expect(edited.uuid == "fake-group-kept")
        #expect(edited.name == "Edited Test")
        #expect(edited.searchText == ["female:fake tag"])
        #expect(edited.listStyle == .grid)
        #expect(edited.hideTab == true)
        #expect(edited.aggregateGroups == ["fake-group-1", "fake-group-2"])
        #expect(edited.catsTypeValue == "fake cats type")
        #expect(edited.advSearchTypeValue == "fake advanced type")
        #expect(edited.lastEditTime == 1_700_000_000_000)
        // Not touched: still unset, not their defaults written out.
        #expect(edited.listTypeValue == nil)
        #expect(edited.cats == nil)
        #expect(edited.enableAdvance == nil)
        #expect(edited.advSearch == nil)
    }

    @Test func turningAdvancedOffKeepsTheSearch() {
        var group = CustomGroup(uuid: "fake-group-advanced", name: "Advanced Test", searchText: ["artist:fake artist"])
        var search = AdvancedSearch()
        search.requireTorrent = true
        search.minimumRating = 4
        search.pageRange = PageRange(from: 20, to: 200)
        group.advancedSearch = search
        group.enableAdvance = true
        let stored = group.advSearch

        var draft = GroupDraft(group: group)
        #expect(draft.enablesAdvanced)
        #expect(draft.advanced == search)
        draft.enablesAdvanced = false
        let saved = draft.makeGroup()
        #expect(saved.enableAdvance == false)
        #expect(saved.advSearch == stored)
        #expect(saved.advancedSearch == search)
        #expect(saved.listQuery().advanced == nil)

        // Turned on again: the same options are sent.
        draft.enablesAdvanced = true
        #expect(draft.makeGroup().listQuery().advanced == search)
    }

    @Test func editedTypeAndStyleAreWritten() {
        var draft = GroupDraft(group: Self.defaults[1])
        draft.type = .watched
        draft.style = .waterfallLarge
        var group = draft.makeGroup()
        #expect(group.listTypeValue == "watched")
        #expect(group.listModeValue == "waterfallLarge")

        // Back to the global setting.
        draft = GroupDraft(group: group)
        draft.style = nil
        group = draft.makeGroup()
        #expect(group.listStyle == nil)
        #expect(group.listModeValue == "global")
    }
}
