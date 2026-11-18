import EHFixtures
import EHModels
import EHParsing
import Foundation
import Testing

// The captured popups hold the account's own data: its funds, its favorites folder names and note, the uploader,
// file name and hash of a torrent and its tracker link. They are checked by structure only (counts, formats,
// presence); every such value is compared as a Boolean bound before `#expect`, so that a failure prints no value.
// Hand-written pages carry made-up values (gid 900001, token 0f0f0f0f0f, "Fake …") and are compared exactly.

// MARK: Helpers for captured fixtures

private func torrents(_ site: EHSite) throws -> [TorrentInfo] {
    try TorrentListParser.parse(Fixtures.string("\(site.rawValue)/popup/torrents.html"))
}

private func favorites(_ site: EHSite) throws -> FavoritesPopup {
    try FavoritesPopupParser.parse(Fixtures.string("\(site.rawValue)/popup/favorites.html"))
}

private func isNonEmpty(_ text: String) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func isInfoHash(_ text: String) -> Bool {
    text.count == 40 && text.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
}

/// The arguments of every `do_hathdl('…')` in `html`, read straight from the page text.
private func hathArguments(in html: String) -> Set<String> {
    Set(html.matches(of: /do_hathdl\('([^']*)'\)/).map { String($0.1) })
}

// MARK: Hand-written archiver popup, after the captured pages' markup

private let fakeDownloadForms = """
<div style="width:100%"><div style="float:left">\
<div style="text-align:center">Download Cost: &nbsp; <strong>Free!</strong></div>\
<form action="https://e-hentai.org/archiver.php?gid=900001&amp;token=0f0f0f0f0f" method="post">\
<input type="hidden" name="dltype" value="org" />\
<div><input type="submit" name="dlcheck" value="Download Original Archive" /></div></form>\
<p>Estimated Size: &nbsp; <strong>11.1 MiB</strong></p></div>\
<div style="float:right">\
<div style="text-align:center">Download Cost: &nbsp; <strong>1,111 GP</strong></div>\
<form action="https://e-hentai.org/archiver.php?gid=900001&amp;token=0f0f0f0f0f" method="post">\
<input type="hidden" name="dltype" value="res" />\
<div><input type="submit" name="dlcheck" value="Download Resample Archive" /></div></form>\
<p>Estimated Size: &nbsp; <strong>1.1 MiB</strong></p></div>\
<div style="clear:both"></div></div>
"""

/// The H@H part: an original, a size the site cannot make ("N/A", still linked), one shown without a link, and a
/// resample with a cost.
private let fakeHathTable = """
<div style="width:100%"><p>H@H Downloader</p>\
<form id="hathdl_form" action="https://e-hentai.org/archiver.php?gid=900001&amp;token=0f0f0f0f0f" method="post">\
<input type="hidden" id="hathdl_xres" name="hathdl_xres" value="" /></form><table><tr>\
<td><p><a href="#" onclick="return do_hathdl('org')">Original</a></p><p>11.1 MiB</p><p>Free</p></td>\
<td><p><a href="#" onclick="return do_hathdl('1280')">1280x</a></p><p>N/A</p><p>N/A</p></td>\
<td><p>2400x</p><p>N/A</p><p>N/A</p></td>\
<td><p><a href="#" onclick="return do_hathdl('780')">780x</a></p><p>1.1 MiB</p><p>11 GP</p></td>\
</tr></table></div>
"""

/// A made-up archiver popup; `funds` is the markup after the title.
private func fakeArchiverPage(funds: String = "<p>Current Funds: 1,234 GP and 5,678 Credits</p>") -> String {
    """
    <html><head><title>Fake Gallery 1</title></head><body><div id="db"><h1>Fake Gallery 1</h1>\
    \(funds)\(fakeDownloadForms)\(fakeHathTable)</div></body></html>
    """
}

// MARK: Hand-written torrent popup, after the captured pages' markup

private let fakeHashA = String(repeating: "0f", count: 20)
private let fakeHashB = String(repeating: "0e", count: 20)

/// One torrent's form; `rows` replaces the two rows of figures and the uploader.
private func fakeTorrentForm(link: String, rows: String? = nil) -> String {
    let figures = rows ?? """
    <tr><td><span>Posted:</span> <span>2001-01-01 01:01</span></td><td><span>Size:</span> 11.1 MiB</td><td></td>\
    <td><span>Seeds:</span> 1</td><td><span>Peers:</span> 2</td><td><span>Downloads:</span> 1,234</td></tr>\
    <tr><td colspan="5"><span>Uploader:</span> Fake Uploader</td>\
    <td rowspan="2"><input type="submit" name="torrent_update" value="Fake" /></td></tr>
    """
    return """
    <form method="post" action="https://e-hentai.org/gallerytorrents.php?gid=900001&amp;t=0f0f0f0f0f">\
    <div><input type="hidden" name="torrent_info" value="1" /><table>\(figures)\
    <tr><td colspan="5">\(link)</td></tr></table></div></form>
    """
}

private func fakeTorrentLink(hash: String, name: String = "Fake Gallery 1.zip") -> String {
    """
    <a href="https://ehtracker.org/get/900001/\(hash).torrent" \
    onclick="document.location='https://ehtracker.org/get/900001/1-fakepasskey/\(hash).torrent'; return false">\(name)</a>
    """
}

/// A made-up torrent popup: `forms` in the list part, then the upload part (a form without a torrent link).
private func fakeTorrentPage(_ forms: [String]) -> String {
    """
    <html><head><title>Fake Gallery 1</title></head><body><div class="stuffbox"><div id="torrentinfo">\
    <div><h1>Fake Gallery 1</h1><p>Fake text.</p>\(forms.joined())</div>\
    <div><div><span>Fake:</span> Fake text.</div>\
    <form method="post" action="https://upload.e-hentai.org/torrent_upload.php?gid=900001&amp;t=0f0f0f0f0f" \
    enctype="multipart/form-data"><div><input type="hidden" name="MAX_FILE_SIZE" value="1" />\
    <input type="file" name="torrentfile" accept="application/x-bittorrent" />\
    <input type="submit" name="upload" value="Fake" /></div></form></div>\
    </div></div></body></html>
    """
}

// MARK: Hand-written favorites popup, after the captured pages' markup

/// One row of the folder list: the radio, the icon, the name and the clearing div the site ends a row with.
private func fakeFolderRow(value: String, name: String, checked: Bool = false) -> String {
    """
    <div style="height:25px; cursor:pointer"><div style="float:left">\
    <input type="radio" name="favcat" value="\(value)" id="fav\(value)"\(checked ? #" checked="checked""# : "") /></div>\
    <div style="float:left; background-image:url(https://ehgt.org/g/fav.png)" \
    onclick="document.getElementById('fav\(value)').click()"></div>\
    <div style="float:left" onclick="document.getElementById('fav\(value)').click()">\(name)</div>\
    <div class="c"></div></div>
    """
}

/// A made-up favorites popup: folders "Fake Folder 0" … "Fake Folder 9" (the one at `checked` selected), the remove
/// choice when `favorited`, then the note and its slot line.
private func fakeFavoritesPage(
    checked: Int? = 3,
    favorited: Bool = true,
    note: String? = "Fake note &amp; more",
    slots: String = "3 / 1,000 favorite note slots used."
) -> String {
    let folders = (0...9).map { (index: Int) in
        fakeFolderRow(value: "\(index)", name: "Fake Folder \(index)", checked: index == checked)
    }
    let remove = favorited ? fakeFolderRow(value: "favdel", name: "Remove from Favorites") : ""
    let noteField = note.map { #"<textarea name="favnote" cols="40" rows="3">\#($0)</textarea>"# } ?? ""
    return """
    <html><head><title>Fake Gallery 1</title></head><body><div class="stuffbox">\
    <div>Fake Gallery 1</div><form id="galpop" action="" method="post"><p>Fake text.</p>\
    <div><div class="nosel">\(folders.joined())\(remove)</div>\
    <div><p>Favorite Note (Fake)</p>\(noteField)<br />\
    <div>\(slots) [<a href="https://ehwiki.org/wiki/Favorites">?</a>]<br />\
    <input type="submit" name="apply" value="Apply Changes" />\
    <input type="hidden" name="update" value="1" /></div></div></div></form></div></body></html>
    """
}

@Suite struct PopupParserTests {
    // MARK: Captured fixtures, one test per row of the plan's table

    @Test(arguments: EHSite.allCases)
    func archiverPopupsParse(site: EHSite) throws {
        let html = try Fixtures.string("\(site.rawValue)/popup/archiver.html")
        let options = try ArchiverParser.parse(html)
        #expect(options.downloads.map(\.type) == ["org", "res"])
        let downloadsHaveText = options.downloads.allSatisfy { isNonEmpty($0.costText) && isNonEmpty($0.sizeText) }
        #expect(downloadsHaveText)
        #expect(options.hathOptions.count >= 1)
        let arguments = hathArguments(in: html)
        let everyXresIsAnArgument = options.hathOptions.allSatisfy { arguments.contains($0.xres) }
        #expect(everyXresIsAnArgument)
        let hasFunds = options.funds != nil
        #expect(hasFunds == (site == .eh))
    }

    @Test(arguments: EHSite.allCases)
    func torrentPopupsParse(site: EHSite) throws {
        let list = try torrents(site)
        #expect(list.count >= 1)
        let trackerHost = site == .eh ? "ehtracker.org" : "exhentai.org"
        for torrent in list {
            let hashIsHex = isInfoHash(torrent.infoHash)
            #expect(hashIsHex)
            let hostMatches = torrent.downloadURL.host() == trackerHost
            #expect(hostMatches)
            let hasName = isNonEmpty(torrent.name)
            #expect(hasName)
            let hasFigures = torrent.seeds != nil && torrent.peers != nil && torrent.downloads != nil
            #expect(hasFigures)
            let magnetMatches = torrent.magnetURL.absoluteString == "magnet:?xt=urn:btih:" + torrent.infoHash
            #expect(magnetMatches)
        }
    }

    @Test(arguments: EHSite.allCases)
    func favoritesPopupsParse(site: EHSite) throws {
        let popup = try favorites(site)
        #expect(popup.folders.count == 10)
        #expect(popup.folders.map(\.index) == Array(0...9))
        let foldersHaveNames = popup.folders.allSatisfy { isNonEmpty($0.name) }
        #expect(foldersHaveNames)
        let hasSelection = popup.selectedIndex != nil
        #expect(hasSelection)
        let isFavorited = popup.isFavorited
        #expect(!isFavorited)
        let noteIsEmpty = popup.note.isEmpty
        #expect(noteIsEmpty)
        let hasSlots = popup.noteSlotsUsed != nil && popup.noteSlotsTotal != nil
        #expect(hasSlots)
    }

    // MARK: Archiver

    @Test func fundsIgnoreThousandsSeparators() throws {
        let options = try ArchiverParser.parse(fakeArchiverPage())
        #expect(options.funds == ArchiveFunds(gp: 1234, credits: 5678))
    }

    @Test func unavailableHathOptionsAreSkipped() throws {
        let options = try ArchiverParser.parse(fakeArchiverPage())
        #expect(options.hathOptions.map(\.xres) == ["org", "780"])
        #expect(!options.hathOptions.contains { $0.sizeText == "N/A" })
    }

    @Test func handWrittenArchiverParses() throws {
        let options = try ArchiverParser.parse(fakeArchiverPage())
        #expect(options == ArchiveOptions(
            funds: ArchiveFunds(gp: 1234, credits: 5678),
            downloads: [
                ArchiveDownload(type: "org", costText: "Free!", sizeText: "11.1 MiB"),
                ArchiveDownload(type: "res", costText: "1,111 GP", sizeText: "1.1 MiB"),
            ],
            hathOptions: [
                HathDownloadOption(resolution: "Original", xres: "org", sizeText: "11.1 MiB", costText: "Free"),
                HathDownloadOption(resolution: "780x", xres: "780", sizeText: "1.1 MiB", costText: "11 GP"),
            ]
        ))
    }

    /// The captured EH page writes the label and the amounts in two paragraphs, with links between the amounts.
    @Test func fundsInTheParagraphAfterTheLabelParse() throws {
        let funds = """
        <p>Current Funds:</p><p>12,345 GP [<a href="https://ehwiki.org/wiki/GP">?</a>] &nbsp; \
        22 Credits [<a href="https://ehwiki.org/wiki/Credits">?</a>]</p>
        """
        let options = try ArchiverParser.parse(fakeArchiverPage(funds: funds))
        #expect(options.funds == ArchiveFunds(gp: 12345, credits: 22))
    }

    /// A gallery title is the uploader's text; one that starts like the label must not be read as the funds.
    @Test func fundsLabelInTheTitleIsPassedOver() throws {
        let page = fakeArchiverPage()
            .replacingOccurrences(of: "<h1>Fake Gallery 1</h1>", with: "<h1>Current Funds: Fake</h1>")
        #expect(try ArchiverParser.parse(page).funds == ArchiveFunds(gp: 1234, credits: 5678))
        let withoutFunds = fakeArchiverPage(funds: "")
            .replacingOccurrences(of: "<h1>Fake Gallery 1</h1>", with: "<h1>Current Funds: 1 GP 1 Credits</h1>")
        #expect(try ArchiverParser.parse(withoutFunds).funds == nil)
    }

    @Test func pageWithoutFundsHasNone() throws {
        #expect(try ArchiverParser.parse(fakeArchiverPage(funds: "")).funds == nil)
    }

    /// The funds are only shown: when the label is there but its amounts cannot be read, they are nil and the
    /// downloads and H@H options are still read.
    @Test func unreadableFundsLeaveTheRestReadable() throws {
        let options = try ArchiverParser.parse(fakeArchiverPage(funds: "<p>Current Funds: Fake</p>"))
        #expect(options.funds == nil)
        #expect(options.downloads.map(\.type) == ["org", "res"])
        #expect(options.hathOptions.map(\.xres) == ["org", "780"])
    }

    /// The label in its own `strong`: the amounts are in the paragraph around it, which is not searched, so the
    /// funds are nil (pinned behavior) and the rest is read.
    @Test func fundsLabelInItsOwnStrongGivesNoFunds() throws {
        let funds = "<p><strong>Current Funds:</strong> 1,234 GP and 5,678 Credits</p>"
        let options = try ArchiverParser.parse(fakeArchiverPage(funds: funds))
        #expect(options.funds == nil)
        #expect(options.downloads.map(\.type) == ["org", "res"])
        #expect(options.hathOptions.map(\.xres) == ["org", "780"])
    }

    /// An element between the label and the amounts: only the label's next sibling is searched, so the funds are
    /// nil (pinned behavior) and the rest is read.
    @Test func elementBetweenFundsLabelAndAmountsGivesNoFunds() throws {
        let funds = #"<p>Current Funds:</p><div class="fake"></div><p>1,234 GP and 5,678 Credits</p>"#
        let options = try ArchiverParser.parse(fakeArchiverPage(funds: funds))
        #expect(options.funds == nil)
        #expect(options.downloads.map(\.type) == ["org", "res"])
        #expect(options.hathOptions.map(\.xres) == ["org", "780"])
    }

    @Test func pageWithoutDownloadFormsThrows() {
        #expect(throws: ParseError.missing("downloads")) {
            try ArchiverParser.parse("<html><body><p>Fake text.</p></body></html>")
        }
    }

    @Test func downloadWithoutCostOrSizeThrows() {
        let noCostLabel = fakeArchiverPage().replacingOccurrences(of: "Download Cost:", with: "Fake:")
        #expect(throws: ParseError.missing("costText")) { try ArchiverParser.parse(noCostLabel) }
        let emptySize = fakeArchiverPage()
            .replacingOccurrences(of: "<strong>11.1 MiB</strong>", with: "<strong> </strong>")
        #expect(throws: ParseError.malformed("sizeText")) { try ArchiverParser.parse(emptySize) }
        let emptyType = fakeArchiverPage().replacingOccurrences(of: #"value="res""#, with: #"value="""#)
        #expect(throws: ParseError.malformed("dltype")) { try ArchiverParser.parse(emptyType) }
    }

    // MARK: Torrents

    @Test func handWrittenTorrentsParse() throws {
        let second = fakeTorrentForm(
            link: fakeTorrentLink(hash: fakeHashB, name: "Fake Gallery 1 (Fake).zip"),
            rows: "<tr><td><span>Posted:</span> <span>2002-02-02 02:02</span></td></tr>"
        )
        let first = fakeTorrentForm(link: fakeTorrentLink(hash: fakeHashA))
        let list = try TorrentListParser.parse(fakeTorrentPage([first, second]))
        #expect(list == [
            TorrentInfo(
                name: "Fake Gallery 1.zip",
                infoHash: fakeHashA,
                downloadURL: URL(string: "https://ehtracker.org/get/900001/\(fakeHashA).torrent")!,
                postedText: "2001-01-01 01:01",
                sizeText: "11.1 MiB",
                seeds: 1,
                peers: 2,
                downloads: 1234,
                uploader: "Fake Uploader"
            ),
            TorrentInfo(
                name: "Fake Gallery 1 (Fake).zip",
                infoHash: fakeHashB,
                downloadURL: URL(string: "https://ehtracker.org/get/900001/\(fakeHashB).torrent")!,
                postedText: "2002-02-02 02:02",
                sizeText: nil,
                seeds: nil,
                peers: nil,
                downloads: nil,
                uploader: nil
            ),
        ])
    }

    @Test func magnetLinkCarriesTheHash() throws {
        let page = fakeTorrentPage([fakeTorrentForm(link: fakeTorrentLink(hash: fakeHashA))])
        let torrent = try #require(TorrentListParser.parse(page).first)
        #expect(torrent.magnetURL == URL(string: "magnet:?xt=urn:btih:\(fakeHashA)")!)
    }

    @Test func galleryWithoutTorrentsHasNone() throws {
        #expect(try TorrentListParser.parse(fakeTorrentPage([])) == [])
    }

    @Test func pageWithoutTorrentInfoThrows() {
        #expect(throws: ParseError.missing("torrentinfo")) {
            try TorrentListParser.parse("<html><body><p>Fake text.</p></body></html>")
        }
    }

    @Test func torrentLinkWithoutHashIsMalformed() {
        let shortHash = String(fakeHashA.dropLast())
        #expect(throws: ParseError.malformed("infoHash")) {
            try TorrentListParser.parse(fakeTorrentPage([fakeTorrentForm(link: fakeTorrentLink(hash: shortHash))]))
        }
    }

    @Test func torrentLinkWithoutNameIsMissing() {
        let page = fakeTorrentPage([fakeTorrentForm(link: fakeTorrentLink(hash: fakeHashA, name: " "))])
        #expect(throws: ParseError.missing("name")) { try TorrentListParser.parse(page) }
    }

    @Test func relativeTorrentLinkIsMalformed() {
        let link = #"<a href="/get/900001/\#(fakeHashA).torrent">Fake Gallery 1.zip</a>"#
        #expect(throws: ParseError.malformed("downloadURL")) {
            try TorrentListParser.parse(fakeTorrentPage([fakeTorrentForm(link: link)]))
        }
    }

    // MARK: Favorites

    @Test func handWrittenFavoritesParse() throws {
        let popup = try FavoritesPopupParser.parse(fakeFavoritesPage())
        #expect(popup == FavoritesPopup(
            folders: (0...9).map { FavoriteFolder(index: $0, name: "Fake Folder \($0)") },
            selectedIndex: 3,
            note: "Fake note & more",
            noteSlotsUsed: 3,
            noteSlotsTotal: 1000,
            isFavorited: true
        ))
    }

    @Test func notFavoritedPopupHasNoRemoveChoice() throws {
        let page = fakeFavoritesPage(checked: nil, favorited: false, note: "", slots: "")
        let popup = try FavoritesPopupParser.parse(page)
        #expect(popup.folders.count == 10)
        #expect(popup.selectedIndex == nil)
        #expect(!popup.isFavorited)
        #expect(popup.note == "")
        #expect(popup.noteSlotsUsed == nil)
        #expect(popup.noteSlotsTotal == nil)
    }

    @Test func noteKeepsItsLineBreaks() throws {
        let popup = try FavoritesPopupParser.parse(fakeFavoritesPage(note: "\nFake line 1\nFake line 2\n"))
        #expect(popup.note == "Fake line 1\nFake line 2")
    }

    /// The folder names and the note are the account's words; only the line after the note field gives the slots.
    @Test func slotsComeFromTheLineAfterTheNote() throws {
        let page = fakeFavoritesPage(note: "9 / 9 favorite note slots")
            .replacingOccurrences(of: ">Fake Folder 0<", with: ">8 / 8 favorite note slots<")
        let popup = try FavoritesPopupParser.parse(page)
        #expect(popup.noteSlotsUsed == 3)
        #expect(popup.noteSlotsTotal == 1000)
        #expect(popup.folders.first?.name == "8 / 8 favorite note slots")
        #expect(popup.note == "9 / 9 favorite note slots")
    }

    @Test func pageWithoutFoldersThrows() {
        #expect(throws: ParseError.missing("favcat")) {
            try FavoritesPopupParser.parse("<html><body><p>Fake text.</p></body></html>")
        }
    }

    /// Saving the popup sends the note back; without the field the note is unknown, and "" would erase it.
    @Test func pageWithoutNoteFieldThrows() {
        #expect(throws: ParseError.missing("favnote")) {
            try FavoritesPopupParser.parse(fakeFavoritesPage(note: nil))
        }
    }

    @Test func folderWithoutNameThrows() {
        let page = fakeFavoritesPage().replacingOccurrences(of: ">Fake Folder 7<", with: "><")
        #expect(throws: ParseError.missing("folderName")) { try FavoritesPopupParser.parse(page) }
    }
}
