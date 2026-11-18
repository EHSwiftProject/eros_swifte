import EHFixtures
import EHModels
import EHParsing
import Foundation
import Testing

// The captured settings and home pages hold the account's own choices and figures: its profile names, the value of
// every setting, its favorites folder names, its image limit. They are checked by structure only (field names, kinds,
// counts, order relations); every such value is bound to a Boolean or a count before `#expect`, so that a failure
// prints no value. The account's private mytags pages under local/ are never read here: the mytags tests use the
// constructed page and hand-written fragments, whose values are all made up ("Fake …", ids from 9000001, the masked
// apiuid 1111111), and so are compared exactly.

// MARK: Helpers for captured fixtures

private func uconfig(_ site: EHSite) throws -> UConfigPage {
    try UConfigParser.parse(Fixtures.string("\(site.rawValue)/account/uconfig.html"))
}

/// A field kind's case, without its value.
private func kindName(_ kind: FormField.Kind) -> String {
    switch kind {
    case .radio: "radio"
    case .checkbox: "checkbox"
    case .text: "text"
    case .textarea: "textarea"
    case .hidden: "hidden"
    case .select: "select"
    }
}

/// The kind of the first field of each name.
private func kindNames(in form: SettingsForm) -> [String: String] {
    form.fields.reduce(into: [:]) { names, field in
        if names[field.name] == nil { names[field.name] = kindName(field.kind) }
    }
}

/// The settings the plan names, by the kind uconfig.php gives them.
private let radioFieldNames = [
    "uh", "xr", "tl", "ar", "dm", "fs", "rc", "lt", "ts", "tr", "cs", "sc", "tb", "pn", "oi", "qb", "ms", "mt",
]
private let textFieldNames = (0...9).map { "favorite_\($0)" } + ["ft", "wt", "ru", "rx", "ry", "tp", "vp"]

/// The private forum profile page the tooling plan's T8 imports (git-ignored, so it is read from the source tree;
/// `local/` is not in the resource bundle), as `FixtureFiles.sourceRoot` finds the fixture root.
private let localForumProfile = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/local/eh/forum/profile.html")

private var hasLocalForumProfile: Bool {
    FileManager.default.fileExists(atPath: localForumProfile.path(percentEncoded: false))
}

// MARK: Hand-written settings pages, after the captured pages' markup

/// The profile selector of uconfig.php, with the given options.
private func fakeProfileForm(_ options: String) -> String {
    #"<form id="profile_form" action="" method="post"><input type="hidden" id="profile_action" name="profile_action" value="" />"#
        + #"<input type="hidden" id="profile_name" name="profile_name" value="" />"#
        + #"<select name="profile_set" onchange="do_profile_post()">\#(options)</select></form>"#
}

/// A settings form with one control of each kind, made-up names and values, and the Apply button.
private let fakeSettingsForm = """
<form action="" method="post">
<div><input type="radio" name="fake_radio" value="0" id="fake_radio_0" /><label for="fake_radio_0">Fake 0</label></div>
<div><input type="radio" name="fake_radio" value="1" id="fake_radio_1" checked="checked" /><label for="fake_radio_1">Fake 1</label></div>
<div><input type="checkbox" name="fake_check" id="fake_check" checked /></div>
<div><input type="checkbox" name="fake_valued_check" value="11" /></div>
<div><input type="checkbox" onchange="fake_toggle(this)" /></div>
<div><input type="text" name="fake_text" value="11" size="4" /></div>
<div><input name="fake_untyped" value="Fake Text" /></div>
<input type="hidden" name="fake_hidden" value="a" />
<div><textarea name="fake_area" rows="4" cols="40">
Fake line 1
Fake line 2</textarea></div>
<div><select name="fake_select"><option value="a">Fake A</option><option value="b" selected="selected">Fake B</option></select></div>
<div><select name="fake_unselected"><option value="c">Fake C</option><option>Fake D</option></select></div>
<div><input type="radio" name="fake_unchecked" value="0" /><input type="radio" name="fake_unchecked" value="1" /></div>
<div><input type="radio" name="fake_radio" value="2" id="fake_radio_2" /><label for="fake_radio_2">Fake 2</label></div>
<div><input type="submit" name="apply" value="Apply" /></div>
</form>
"""

private func fakeSettingsPage(profiles: String?, form: String?) -> String {
    let body = [profiles.map(fakeProfileForm), form].compactMap { $0 }.joined(separator: "\n")
    return #"<html><body><div class="stuffbox" id="outer"><h1>Fake Settings</h1>\#n\#(body)</div></body></html>"#
}

// MARK: Hand-written mytags pages, after the constructed page (itself after the structure of the private pages)

/// A tag row; `omitting` names an input to leave out ("tagwatch", "taghide" or "tagcolor"), its div left empty.
private func fakeUserTagRow(
    id: Int, title: String?, watched: Bool = false, hidden: Bool = false, color: String = "", weight: String = "10",
    omitting omitted: String? = nil
) -> String {
    let titleAttribute = title.map { #" title="\#($0)""# } ?? ""
    let watch = watched ? #" checked="checked""# : ""
    let hide = hidden ? #" checked="checked""# : ""
    let input = { (name: String, html: String) in omitted == name ? "<div></div>" : html }
    return #"<div id="usertag_\#(id)"><div><a href="https://e-hentai.org/tag/fake"><div id="tagpreview_\#(id)" class="gt"\#(titleAttribute)>fake</div></a></div>"#
        + input("tagwatch", #"<div><label class="lc"><input type="checkbox" id="tagwatch_\#(id)"\#(watch) /><span></span> Fake</label></div>"#)
        + input("taghide", #"<div><label class="lc"><input type="checkbox" id="taghide_\#(id)"\#(hide) /><span></span> Fake</label></div>"#)
        + #"<div><button id="colorsetter_\#(id)" class="jscolor" tabindex="-1"></button></div>"#
        + input("tagcolor", #"<div><input type="text" id="tagcolor_\#(id)" class="tagcolor" value="\#(color)" /></div>"#)
        + #"<div><input type="text" id="tagweight_\#(id)" value="\#(weight)" /></div>"#
        + #"<div id="selector_\#(id)"><label class="lc"><input type="checkbox" name="fake_usertags[]" value="\#(id)" /><span></span></label></div></div>"#
}

/// The new-tag row the site puts first; it is not a tag.
private let fakeNewTagRow = #"<div id="usertag_0"><div><div class="tagcomplete"><input type="text" id="tagname_new" name="tagname_new" value="" /></div></div>"#
    + #"<div><label class="lc"><input type="checkbox" id="tagwatch_0" name="tagwatch_new" /><span></span></label></div>"#
    + #"<div><label class="lc"><input type="checkbox" id="taghide_0" name="taghide_new" /><span></span></label></div>"#
    + #"<div><button id="colorsetter_0" class="jscolor" tabindex="-1"></button></div>"#
    + #"<div><input type="text" id="tagcolor_0" name="tagcolor_new" class="tagcolor" value="" /></div>"#
    + #"<div><input type="text" id="tagweight_0" name="tagweight_new" value="10" /></div>"#
    + #"<div><input type="submit" id="tagsave_0" value="Fake" disabled="disabled" /></div></div>"#

private let fakeTagSetChooser = #"<select onchange="change_tagset(this.value)"><option value="9100001" selected="selected">Fake Set 1 (1)</option></select>"#

private func fakeMyTagsPage(
    chooser: String? = fakeTagSetChooser, rows: [String], deletable: Bool = false,
    script: String = #"var apiuid = 1111111;\#nvar apikey = "a1a1a1a1a1a1a1a1a1a1";"#
) -> String {
    let delete = deletable ? #" <input type="button" onclick="do_tagset_delete()" value="Fake" />"# : ""
    let tagSets = chooser.map {
        #"<form id="tagset_form" action="" method="post"><div id="tagset_outer">"#
            + #"<div><input type="button" onclick="do_tagset_rename()" value="Fake" />\#(delete)</div>"#
            + #"<div>\#($0)</div></div></form>"#
    } ?? ""
    return #"<html><body><div class="stuffbox" id="outer"><script type="text/javascript">\#(script)</script>"#
        + tagSets
        + #"<form id="usertag_form" action="" method="post"><div id="usertags_outer">\#(rows.joined(separator: "\n"))</div></form>"#
        + "</div></body></html>"
}

// MARK: Hand-written home pages, after the captured page's markup

private func fakeHomePage(limits: String, after: String = "") -> String {
    #"<html><body><div class="stuffbox"><h2>Image Limits</h2><div class="homebox">\#(limits)</div>"#
        + #"<h2>Fake Section</h2><div class="homebox"><p>Fake <strong>11</strong> and <strong>111</strong>.</p>\#(after)</div>"#
        + "</div></body></html>"
}

private let fakeLimits = """
<p>Fake text, high-resolution images can be limited.</p>\
<p>Fake current <strong>12</strong> fake limit <strong>5,000</strong>.</p>\
<p>Fake reset <strong>34</strong> GP.</p>\
<form action="" method="post"><p><input type="submit" name="reset_imagelimit" value="Fake" /></p></form>
"""

// MARK: Hand-written forum profiles, after the constructed page

private func fakeForumProfile(_ avatarCell: String, name: String = "Fake Nickname") -> String {
    #"<html><body><div id="ipbwrapper"><table class="ipbtable"><tr><td class="row1">"#
        + #"<div id="profilename">\#(name)</div>\#n<br />\#n\#(avatarCell)\#n<div class="postdetails">Fake Group</div>"#
        + "</td></tr></table></div></body></html>"
}

@Suite struct AccountPageParserTests {
    // MARK: uconfig.php: captured fixtures

    @Test(arguments: EHSite.allCases)
    func settingsPagesParse(site: EHSite) throws {
        let page = try uconfig(site)
        let profileCount = page.profiles.count
        #expect(profileCount >= 1)
        let selectedCount = page.profiles.filter(\.isSelected).count
        #expect(selectedCount == 1)
        let numbers = page.profiles.map(\.number)
        let numbersAreDistinct = Set(numbers).count == numbers.count
        #expect(numbersAreDistinct)
        let numbersArePositive = numbers.allSatisfy { $0 > 0 }
        #expect(numbersArePositive)

        // Field names only: they are the site's, the same for every account.
        let kinds = kindNames(in: page.form)
        #expect(radioFieldNames.filter { kinds[$0] != "radio" } == [])
        #expect(textFieldNames.filter { kinds[$0] != "text" } == [])
        #expect(kinds["xu"] == "textarea")

        // uconfig's dm is a number ("0"…"4"), not the list page's m/p/l/e/t.
        guard case .radio(let options, let selected)? = page.form.fields.first(where: { $0.name == "dm" })?.kind else {
            Issue.record("dm is not a radio field")
            return
        }
        let optionCount = options.count
        #expect(optionCount == 5)
        let selectionIsAnOption = selected.map(options.contains) == true
        #expect(selectionIsAnOption)
        let selectionIsTheValue = selected != nil && page.form.value(of: "dm") == selected
        #expect(selectionIsTheValue)
    }

    @Test(arguments: EHSite.allCases)
    func everyRadioGroupIsOneField(site: EHSite) throws {
        let fields = try uconfig(site).form.fields
        let names = fields.map(\.name)
        let namesAreDistinct = Set(names).count == names.count
        #expect(namesAreDistinct)
    }

    // MARK: uconfig.php: constructed fixtures

    @Test func erosProfileThatIsNotSelected() throws {
        let page = try UConfigParser.parse(Fixtures.string("constructed/eh/uconfig-eros-unselected.html"))
        #expect(page.profiles == [
            SiteProfile(number: 1, name: "Fake Default", isSelected: true, isDefault: false),
            SiteProfile(number: 5, name: "Eros-FE", isSelected: false, isDefault: false),
            SiteProfile(number: 6, name: "Fake Other", isSelected: false, isDefault: false),
        ])
        #expect(page.selectedProfile?.number == 1)
        let eros = page.profiles.first { $0.name == "Eros-FE" }
        #expect(eros?.number == 5)
        #expect(eros?.isSelected == false)
        // Only the profile options were changed: the settings form is the captured page's.
        let formIsTheCaptured = try page.form == uconfig(.eh).form
        #expect(formIsTheCaptured)
    }

    @Test func pageWithoutErosProfile() throws {
        let page = try UConfigParser.parse(Fixtures.string("constructed/eh/uconfig-without-eros.html"))
        #expect(page.profiles == [
            SiteProfile(number: 1, name: "Fake Default", isSelected: true, isDefault: false),
            SiteProfile(number: 6, name: "Fake Other", isSelected: false, isDefault: false),
        ])
        #expect(!page.profiles.contains { $0.name == "Eros-FE" })
        #expect(page.selectedProfile?.number == 1)
    }

    // MARK: uconfig.php: hand-written pages

    /// The "(Default)" suffix is the Flutter app's rule (`profile_parser.dart:32`); neither captured page has it.
    @Test func defaultSuffixMarksTheDefaultProfile() throws {
        let page = try UConfigParser.parse(fakeSettingsPage(
            profiles: #"<option value="1" selected="selected">Fake One</option><option value="2">Fake (Default)</option>"#,
            form: nil
        ))
        #expect(page.profiles == [
            SiteProfile(number: 1, name: "Fake One", isSelected: true, isDefault: false),
            SiteProfile(number: 2, name: "Fake", isSelected: false, isDefault: true),
        ])
    }

    @Test func pageWithoutTheApplyFormHasAnEmptyForm() throws {
        let page = try UConfigParser.parse(fakeSettingsPage(
            profiles: #"<option value="3">Fake Three</option><option value="4" selected="selected">Fake Four</option>"#,
            form: nil
        ))
        #expect(page.profiles.map(\.number) == [3, 4])
        #expect(page.selectedProfile == SiteProfile(number: 4, name: "Fake Four", isSelected: true, isDefault: false))
        #expect(page.form.fields == [])
    }

    @Test func settingsFormReadsEveryKindOfControl() throws {
        let page = try UConfigParser.parse(fakeSettingsPage(
            profiles: #"<option value="1" selected="selected">Fake One</option>"#, form: fakeSettingsForm
        ))
        #expect(page.form.fields == [
            FormField(name: "fake_radio", kind: .radio(options: ["0", "1", "2"], selected: "1")),
            FormField(name: "fake_check", kind: .checkbox(value: "on", isChecked: true)),
            FormField(name: "fake_valued_check", kind: .checkbox(value: "11", isChecked: false)),
            FormField(name: "fake_text", kind: .text("11")),
            FormField(name: "fake_untyped", kind: .text("Fake Text")),
            FormField(name: "fake_hidden", kind: .hidden("a")),
            FormField(name: "fake_area", kind: .textarea("Fake line 1\nFake line 2")),
            FormField(name: "fake_select", kind: .select(
                options: [FormOption(value: "a", label: "Fake A"), FormOption(value: "b", label: "Fake B")], selected: "b"
            )),
            FormField(name: "fake_unselected", kind: .select(
                options: [FormOption(value: "c", label: "Fake C"), FormOption(value: "Fake D", label: "Fake D")],
                selected: "c"
            )),
            FormField(name: "fake_unchecked", kind: .radio(options: ["0", "1"], selected: nil)),
        ])
    }

    @Test func formValuesAreWhatTheFormSends() throws {
        let form = try UConfigParser.parse(fakeSettingsPage(
            profiles: #"<option value="1" selected="selected">Fake One</option>"#, form: fakeSettingsForm
        )).form
        #expect(form.value(of: "fake_radio") == "1")
        #expect(form.value(of: "fake_check") == "on")
        #expect(form.value(of: "fake_valued_check") == nil)
        #expect(form.value(of: "fake_text") == "11")
        #expect(form.value(of: "fake_hidden") == "a")
        #expect(form.value(of: "fake_area") == "Fake line 1\nFake line 2")
        #expect(form.value(of: "fake_select") == "b")
        #expect(form.value(of: "fake_unselected") == "c")
        #expect(form.value(of: "fake_unchecked") == nil)
        #expect(form.value(of: "apply") == nil)
        #expect(form.value(of: "no_such_field") == nil)
    }

    /// A browser drops only the line break right after `<textarea>`.
    @Test func textareaKeepsAllButTheFirstLineBreak() throws {
        let form = #"<form action="" method="post"><textarea name="fake_area">"# + "\n\nFake line\n"
            + #"</textarea><input type="submit" name="apply" value="Apply" /></form>"#
        let page = try UConfigParser.parse(fakeSettingsPage(profiles: nil, form: form))
        #expect(page.form.fields == [FormField(name: "fake_area", kind: .textarea("\nFake line\n"))])
    }

    @Test func settingsFormWithoutProfileSelectorHasNoProfiles() throws {
        let page = try UConfigParser.parse(fakeSettingsPage(profiles: nil, form: fakeSettingsForm))
        #expect(page.profiles == [])
        #expect(page.selectedProfile == nil)
        #expect(page.form.fields.count == 10)
    }

    @Test func profileWithoutANumberIsMalformed() {
        let options = #"<option value="1">Fake One</option><option value="x1">Fake</option>"#
        let html = fakeSettingsPage(profiles: options, form: nil)
        #expect(throws: ParseError.malformed("profile_set")) { try UConfigParser.parse(html) }
    }

    @Test func optionWithoutValueIsNotAProfile() throws {
        let page = try UConfigParser.parse(fakeSettingsPage(
            profiles: #"<option>Fake Heading</option><option value="2" selected="selected">Fake Two</option>"#, form: nil
        ))
        #expect(page.profiles == [SiteProfile(number: 2, name: "Fake Two", isSelected: true, isDefault: false)])
    }

    @Test func pageWithNeitherProfilesNorSettingsThrows() {
        let html = #"<html><body><div class="stuffbox"><p>Fake page</p></div></body></html>"#
        #expect(throws: ParseError.missing("profile_set")) { try UConfigParser.parse(html) }
    }

    // MARK: mytags

    @Test func constructedMyTagsParse() throws {
        let page = try MyTagsParser.parse(Fixtures.string("constructed/eh/account-mytags.html"))
        #expect(page == MyTagsPage(
            tagSets: [
                TagSet(id: 9100001, name: "Fake Set 1", tagCount: 2, isSelected: false),
                TagSet(id: 9100002, name: "Fake Set 2", tagCount: 3, isSelected: true),
            ],
            userTags: [
                UserTag(
                    id: 9000001, tag: TagRef(namespace: "artist", name: "fake artist"),
                    isWatched: true, isHidden: false, colorHex: nil, weight: 10
                ),
                UserTag(
                    id: 9000002, tag: TagRef(namespace: "female", name: "fake tag"),
                    isWatched: false, isHidden: true, colorHex: "#3377CC", weight: -5
                ),
                UserTag(
                    id: 9000003, tag: TagRef(namespace: "other", name: "fake tag 3"),
                    isWatched: false, isHidden: false, colorHex: "#AA11FF", weight: 25
                ),
            ],
            apiUID: 1111111,
            apiKey: "a1a1a1a1a1a1a1a1a1a1",
            canDeleteTagSet: true
        ))
    }

    @Test func tagSetWithoutDeleteButtonCannotBeDeleted() throws {
        let rows = [fakeNewTagRow, fakeUserTagRow(id: 9000001, title: "other:fake")]
        let page = try MyTagsParser.parse(fakeMyTagsPage(rows: rows))
        #expect(!page.canDeleteTagSet)
        #expect(page.tagSets == [TagSet(id: 9100001, name: "Fake Set 1", tagCount: 1, isSelected: true)])
        #expect(page.userTags.map(\.id) == [9000001])
    }

    @Test func deleteFunctionOutsideAButtonDoesNotCount() throws {
        let page = try MyTagsParser.parse(fakeMyTagsPage(
            rows: [fakeUserTagRow(id: 9000001, title: "other:fake")],
            script: "function fake() { do_tagset_delete(); }\nvar apiuid = 1111111;"
        ))
        #expect(!page.canDeleteTagSet)
    }

    @Test func pageWithoutTagSetChooserHasNoTagSets() throws {
        let rows = [fakeUserTagRow(id: 9000001, title: "other:fake")]
        let page = try MyTagsParser.parse(fakeMyTagsPage(chooser: nil, rows: rows))
        #expect(page.tagSets == [])
        #expect(page.userTags.map(\.id) == [9000001])
    }

    @Test func tagSetWithoutCountHasNoCount() throws {
        let chooser = #"<select onchange="change_tagset(this.value)"><option value="9100003">Fake Set</option>"#
            + #"<option value="9100004" selected="selected">Fake (Set) 4 (11)</option></select>"#
        let page = try MyTagsParser.parse(fakeMyTagsPage(chooser: chooser, rows: [fakeNewTagRow]))
        #expect(page.tagSets == [
            TagSet(id: 9100003, name: "Fake Set", tagCount: nil, isSelected: false),
            TagSet(id: 9100004, name: "Fake (Set) 4", tagCount: 11, isSelected: true),
        ])
        #expect(page.userTags == [])
    }

    @Test func tagSetWithoutANumberIsMalformed() {
        let chooser = #"<select onchange="change_tagset(this.value)"><option value="x">Fake Set</option></select>"#
        #expect(throws: ParseError.malformed("tagset")) {
            try MyTagsParser.parse(fakeMyTagsPage(chooser: chooser, rows: [fakeNewTagRow]))
        }
    }

    @Test func unreadableWeightIsNil() throws {
        let page = try MyTagsParser.parse(fakeMyTagsPage(rows: [
            fakeUserTagRow(id: 9000001, title: "other:fake", weight: "x1"),
            fakeUserTagRow(id: 9000002, title: "other:fake 2", color: "#a1b2c3", weight: ""),
            fakeUserTagRow(id: 9000003, title: "fake", color: "a1b2c3", weight: "-11"),
        ]))
        #expect(page.userTags.map(\.weight) == [nil, nil, -11])
        #expect(page.userTags.map(\.colorHex) == [nil, "#a1b2c3", "#a1b2c3"])
        #expect(page.userTags.map(\.tag) == [
            TagRef(namespace: "other", name: "fake"), TagRef(namespace: "other", name: "fake 2"),
            TagRef(namespace: nil, name: "fake"),
        ])
    }

    /// Saving a tag sends its color back: one that cannot be read must not pass for the tag set's.
    @Test func rowWithUnreadableColorIsSkipped() throws {
        let page = try MyTagsParser.parse(fakeMyTagsPage(rows: [
            fakeUserTagRow(id: 9000001, title: "other:fake", color: "fake"),
            fakeUserTagRow(id: 9000002, title: "other:fake 2", color: "#12345"),
            fakeUserTagRow(id: 9000003, title: "other:fake 3", watched: true, color: "#1A2B3C", weight: "11"),
        ]))
        #expect(page.userTags == [UserTag(
            id: 9000003, tag: TagRef(namespace: "other", name: "fake 3"),
            isWatched: true, isHidden: false, colorHex: "#1A2B3C", weight: 11
        )])
    }

    /// Saving a tag sends its watch, hide and color back: a missing input must not pass for unchecked or uncolored.
    @Test(arguments: ["tagwatch", "taghide", "tagcolor"])
    func rowWithoutAnInputIsSkipped(input: String) throws {
        let page = try MyTagsParser.parse(fakeMyTagsPage(rows: [
            fakeNewTagRow,
            fakeUserTagRow(id: 9000001, title: "other:fake", watched: true, hidden: true, color: "#1A2B3C", omitting: input),
            fakeUserTagRow(id: 9000002, title: "other:fake 2", hidden: true, color: "#3C2B1A", weight: "-11"),
        ]))
        #expect(page.userTags == [UserTag(
            id: 9000002, tag: TagRef(namespace: "other", name: "fake 2"),
            isWatched: false, isHidden: true, colorHex: "#3C2B1A", weight: -11
        )])
    }

    @Test func rowWithoutWeightInputHasNoWeight() throws {
        let row = fakeUserTagRow(id: 9000001, title: "other:fake")
            .replacingOccurrences(of: #"<div><input type="text" id="tagweight_9000001" value="10" /></div>"#, with: "<div></div>")
        let page = try MyTagsParser.parse(fakeMyTagsPage(rows: [row]))
        #expect(page.userTags.map(\.weight) == [nil])
    }

    @Test func rowWithoutTagIsSkipped() throws {
        let page = try MyTagsParser.parse(fakeMyTagsPage(rows: [
            fakeUserTagRow(id: 9000001, title: nil), fakeUserTagRow(id: 9000002, title: "other:fake"),
        ]))
        #expect(page.userTags.map(\.id) == [9000002])
    }

    @Test func rowsWithoutAnyTagThrow() {
        let rows = [fakeNewTagRow, fakeUserTagRow(id: 9000001, title: nil), fakeUserTagRow(id: 9000002, title: " ")]
        let html = fakeMyTagsPage(rows: rows)
        #expect(throws: ParseError.missing("usertag")) { try MyTagsParser.parse(html) }
    }

    @Test func pageWithoutUserTagsThrows() {
        let html = #"<html><body><div class="stuffbox" id="outer"><p>Fake page</p></div></body></html>"#
        #expect(throws: ParseError.missing("usertags_outer")) { try MyTagsParser.parse(html) }
    }

    @Test func pageWithoutAPIKeysHasNone() throws {
        let page = try MyTagsParser.parse(fakeMyTagsPage(rows: [fakeNewTagRow], script: "var fake = 1;"))
        #expect(page.apiUID == nil)
        #expect(page.apiKey == nil)
    }

    /// The same rule as the gallery page's (`GalleryDetailParserTests.apiKeyOfLettersAndDigitsIsRead`).
    @Test func apiKeyOfLettersAndDigitsIsRead() throws {
        let script = #"var apiuid = 1111111;\#nvar apikey = "AAAAaaaa1111AAAAzzzz";"#
        let page = try MyTagsParser.parse(fakeMyTagsPage(rows: [fakeNewTagRow], script: script))
        #expect(page.apiKey == "AAAAaaaa1111AAAAzzzz")
        #expect(page.apiUID == 1111111)
        let other = #"var apiuid = 1111111;\#nvar apikey = "aaaa-aaaa";"#
        #expect(try MyTagsParser.parse(fakeMyTagsPage(rows: [fakeNewTagRow], script: other)).apiKey == nil)
    }

    // MARK: home.php

    @Test func homePageImageLimits() throws {
        let limits = try HomePageParser.imageLimits(in: Fixtures.string("eh/account/home.html"))
        let currentIsWithinTheLimit = 0 <= limits.current && limits.current <= limits.limit
        #expect(currentIsWithinTheLimit)
        let limitIsPositive = limits.limit > 0
        #expect(limitIsPositive)
        let hasResetCost = limits.resetCost != nil
        #expect(hasResetCost)
    }

    @Test func handWrittenImageLimitsParse() throws {
        let limits = try HomePageParser.imageLimits(in: fakeHomePage(limits: fakeLimits))
        #expect(limits == ImageLimits(current: 12, limit: 5000, resetCost: 34, highResolutionLimited: true))
    }

    @Test func singleNumberIsTheUnlockCost() throws {
        let limits = try HomePageParser.imageLimits(in: fakeHomePage(
            limits: "<p>Fake text.</p><p>Fake unlock <strong>20,000</strong> GP.</p>"
        ))
        #expect(limits == ImageLimits(current: 0, limit: 0, resetCost: 20000, highResolutionLimited: false))
    }

    @Test func highResolutionSentenceInAnotherSectionDoesNotCount() throws {
        let limits = try HomePageParser.imageLimits(in: fakeHomePage(
            limits: "<p>Fake <strong>1</strong> of <strong>11</strong>, <strong>111</strong>.</p>",
            after: "<p>Fake: high-resolution images can be limited.</p>"
        ))
        #expect(limits == ImageLimits(current: 1, limit: 11, resetCost: 111, highResolutionLimited: false))
    }

    @Test func unreadableResetCostIsNil() throws {
        let limits = try HomePageParser.imageLimits(in: fakeHomePage(
            limits: "<p>Fake <strong>1</strong> of <strong>11</strong>, <strong>Fake</strong>.</p>"
        ))
        #expect(limits == ImageLimits(current: 1, limit: 11, resetCost: nil, highResolutionLimited: false))
    }

    @Test func unreadableLimitIsMalformed() {
        let html = fakeHomePage(limits: "<p>Fake <strong>1</strong> of <strong>Fake</strong>, <strong>111</strong>.</p>")
        #expect(throws: ParseError.malformed("limit")) { try HomePageParser.imageLimits(in: html) }
    }

    @Test func pageWithoutImageLimitsThrows() {
        let html = #"<html><body><div class="stuffbox"><h2>Fake Section</h2><div class="homebox"><p><strong>11</strong></p></div></div></body></html>"#
        #expect(throws: ParseError.missing("Image Limits")) { try HomePageParser.imageLimits(in: html) }
    }

    @Test func imageLimitsWithoutTheirBoxThrow() {
        // The next section's box is not read in its place.
        let html = #"<html><body><div class="stuffbox"><h2>Image Limits</h2><p>Fake</p><h2>Fake Section</h2>"#
            + #"<div class="homebox"><p><strong>1</strong> <strong>11</strong> <strong>111</strong></p></div></div></body></html>"#
        #expect(throws: ParseError.missing("div.homebox")) { try HomePageParser.imageLimits(in: html) }
    }

    @Test func imageLimitsWithoutNumbersThrow() {
        let html = fakeHomePage(limits: "<p>Fake text.</p>")
        #expect(throws: ParseError.missing("p > strong")) { try HomePageParser.imageLimits(in: html) }
    }

    // MARK: Forum profile

    @Test func constructedForumProfileParses() throws {
        let profile = try ForumProfileParser.parse(Fixtures.string("constructed/eh/forum-profile.html"))
        #expect(profile == ForumProfile(
            displayName: "Fake Nickname", avatarURL: URL(string: "https://forums.e-hentai.org/uploads/av-1111111.jpg")
        ))
    }

    @Test func profileWithoutAvatarHasNilURL() throws {
        let profile = try ForumProfileParser.parse(fakeForumProfile("<div>Fake text</div>"))
        #expect(profile == ForumProfile(displayName: "Fake Nickname", avatarURL: nil))
    }

    @Test func absoluteAvatarIsKept() throws {
        let cell = #"<div><img src="https://ehgt.org/fake/av-1.jpg" alt="" /></div>"#
        let profile = try ForumProfileParser.parse(fakeForumProfile(cell))
        #expect(profile.avatarURL == URL(string: "https://ehgt.org/fake/av-1.jpg"))
    }

    @Test func avatarOnlyComesFromTheSecondElementAfterTheName() throws {
        // The element right after the name holds an image; the one after that holds none.
        let html = #"<html><body><div id="profilename">Fake Nickname</div><div><img src="uploads/fake.gif" /></div>"#
            + "<div>Fake text</div></body></html>"
        #expect(try ForumProfileParser.parse(html).avatarURL == nil)
    }

    @Test func forumPageWithoutProfileNameThrows() {
        let html = #"<html><body><div class="maintitle">Fake Title</div></body></html>"#
        #expect(throws: ParseError.missing("#profilename")) { try ForumProfileParser.parse(html) }
    }

    @Test func emptyProfileNameIsMalformed() {
        let html = fakeForumProfile(#"<div><img src="uploads/av-1111111.jpg" alt="" /></div>"#, name: " ")
        #expect(throws: ParseError.malformed("#profilename")) { try ForumProfileParser.parse(html) }
    }

    /// Runs only where the tooling plan's T8 has imported the real page into local/ (it is never checked in).
    @Test(.enabled(if: hasLocalForumProfile))
    func localForumProfileParses() throws {
        let html = String(decoding: try Data(contentsOf: localForumProfile), as: UTF8.self)
        let profile = try ForumProfileParser.parse(html)
        let hasName = !profile.displayName.isEmpty
        #expect(hasName)
        let avatarIsNilOrHTTPS = profile.avatarURL.map { $0.scheme == "https" } ?? true
        #expect(avatarIsNilOrHTTPS)
    }
}
