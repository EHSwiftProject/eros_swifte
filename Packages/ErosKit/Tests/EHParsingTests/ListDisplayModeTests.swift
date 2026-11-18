import Testing
import EHModels
import EHParsing

private func searchnavHTML(selected: String) -> String {
    func option(_ value: String, _ title: String) -> String {
        let attribute = value == selected ? " selected=\"selected\"" : ""
        return "<option value=\"\(value)\"\(attribute)>\(title)</option>"
    }
    return """
    <div class="searchnav"><div><a id="ufirst" href="#">First</a></div>\
    <div><a id="ulast" href="#">Last</a></div>\
    <div><select>\(option("m", "Minimal"))\(option("l", "Compact"))\(option("t", "Thumbnail"))\
    \(option("x", "Unknown"))</select></div></div>
    """
}

@Suite struct ListDisplayModeTests {
    @Test func detectsCompactFromSearchnav() throws {
        let mode = try ListDisplayMode.detect(in: searchnavHTML(selected: "l"))
        #expect(mode == .compact)
        #expect(mode?.isCompact == true)
    }

    @Test func detectsThumbnailFromSearchnav() throws {
        let mode = try ListDisplayMode.detect(in: searchnavHTML(selected: "t"))
        #expect(mode == .thumbnail)
        #expect(mode?.isCompact == false)
    }

    @Test func fallsBackToDmsSelect() throws {
        let html = "<div id=\"dms\"><div><select><option value=\"e\" selected>Extended</option></select></div></div>"
        #expect(try ListDisplayMode.detect(in: html) == .extended)
    }

    @Test func returnsNilWithoutSelectedOption() throws {
        #expect(try ListDisplayMode.detect(in: searchnavHTML(selected: "")) == nil)
    }

    @Test func unknownCodeIsUnrecognized() throws {
        let mode = try ListDisplayMode.detect(in: searchnavHTML(selected: "x"))
        #expect(mode == .unrecognized("x"))
        #expect(mode?.isCompact == false)
    }

    /// A selected option without a `value` reads as the empty code, not as nil (left over from M0).
    @Test func selectedOptionWithoutValueIsUnrecognizedEmpty() throws {
        let html = """
        <div class="searchnav"><div><a id="ulast" href="#">Last</a></div>\
        <div><select><option>Minimal</option><option selected>Compact</option></select></div></div>
        """
        #expect(try ListDisplayMode.detect(in: html) == .unrecognized(""))
    }

    /// With a `.searchnav` but no `#ulast`, there is no selector to read, and `#dms` is not tried (left over from M0).
    @Test func searchnavWithoutUlastIsNil() throws {
        let html = """
        <div class="searchnav"><div><a id="ufirst" href="#">First</a></div>\
        <div><select><option value="l" selected="selected">Compact</option></select></div></div>\
        <div id="dms"><div><select><option value="e" selected>Extended</option></select></div></div>
        """
        #expect(try ListDisplayMode.detect(in: html) == nil)
    }
}
