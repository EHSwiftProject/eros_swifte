import EHModels
import Foundation
import SwiftSoup

/// Reads the settings page (`uconfig.php`).
///
/// The settings form is read whole and by control, not by the fields the Flutter app knew: since that app was written
/// the page lost `hh` and all but one `xn_<n>`, and gained `tf`, `pp`, `co` and the `ct_<category>` fields.
public enum UConfigParser {
    /// Parses a settings page.
    ///
    /// - Profiles: each option with a `value` of `select[name=profile_set]`, in page order; the one with `selected` is
    ///   selected; a text ending in "(Default)" marks the default profile, and the name is the text without it,
    ///   trimmed (the Flutter app's rule). No selector gives no profiles.
    /// - Form: every named control of the first `form` holding `input[name=apply]`, in page order (see
    ///   `SettingsForm.fields`); no fields without such a form.
    /// - Throws: `ParseError.malformed("profile_set")` when a profile's value is not a number;
    ///   `.missing("profile_set")` when the page has neither the profile selector nor the settings form (it is no
    ///   settings page); whatever SwiftSoup throws, unchanged.
    public static func parse(_ html: String) throws -> UConfigPage {
        let document = try SwiftSoup.parse(html)
        let selector = try document.select("select[name=profile_set]").first()
        let form = try document.select("form:has(input[name=apply])").first()
        if selector == nil && form == nil { throw ParseError.missing("profile_set") }
        return UConfigPage(
            profiles: try selector.map(profiles(in:)) ?? [],
            form: SettingsForm(fields: try form.map(fields(of:)) ?? [])
        )
    }

    // MARK: Profiles

    private static let defaultSuffix = "(Default)"

    private static func profiles(in selector: Element) throws -> [SiteProfile] {
        try selector.select("option[value]").map { option in
            guard let number = ImagePageParser.number(try option.attr("value")) else {
                throw ParseError.malformed("profile_set")
            }
            var name = try option.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let isDefault = name.hasSuffix(defaultSuffix)
            if isDefault {
                name = name.dropLast(defaultSuffix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return SiteProfile(number: number, name: name, isSelected: option.hasAttr("selected"), isDefault: isDefault)
        }
    }

    // MARK: Settings form

    /// Input types the form leaves out: the buttons (clicked, never filled in) and file inputs.
    private static let unsentInputTypes: Set<String> = ["submit", "reset", "button", "image", "file"]

    /// The named controls of `form`, radio buttons of one name merged into the field of the first.
    private static func fields(of form: Element) throws -> [FormField] {
        var fields: [FormField] = []
        var radioIndex: [String: Int] = [:]
        for control in try form.select("input, textarea, select") {
            guard let field = try field(of: control) else { continue }
            if case .radio(let options, let selected) = field.kind {
                if let index = radioIndex[field.name], case .radio(let known, let knownSelected) = fields[index].kind {
                    let kind = FormField.Kind.radio(options: known + options, selected: knownSelected ?? selected)
                    fields[index] = FormField(name: field.name, kind: kind)
                    continue
                }
                radioIndex[field.name] = fields.count
            }
            fields.append(field)
        }
        return fields
    }

    /// The field of one control (a radio button as a group of one); nil for an unnamed control and for the input
    /// types the form leaves out.
    private static func field(of control: Element) throws -> FormField? {
        let name = try control.attr("name")
        if name.isEmpty { return nil }
        switch control.tagName() {
        case "textarea": return FormField(name: name, kind: .textarea(textareaValue(of: control)))
        case "select": return FormField(name: name, kind: try select(control))
        default: break
        }
        let type = try control.attr("type").trimmingCharacters(in: .whitespaces).lowercased()
        let value = control.hasAttr("value") ? try control.attr("value") : nil
        let isChecked = control.hasAttr("checked")
        switch type {
        case "radio":
            let value = value ?? "on"
            return FormField(name: name, kind: .radio(options: [value], selected: isChecked ? value : nil))
        case "checkbox":
            return FormField(name: name, kind: .checkbox(value: value ?? "on", isChecked: isChecked))
        case "hidden":
            return FormField(name: name, kind: .hidden(value ?? ""))
        case _ where unsentInputTypes.contains(type):
            return nil
        default:
            return FormField(name: name, kind: .text(value ?? ""))
        }
    }

    /// The text of a textarea as a browser fills it in: line breaks kept, one line break right after the start tag
    /// dropped (the HTML parser drops it; SwiftSoup keeps it).
    private static func textareaValue(of control: Element) -> String {
        let text = control.textNodes().map { $0.getWholeText() }.joined()
        if text.hasPrefix("\r\n") { return String(text.dropFirst(2)) }
        if text.hasPrefix("\n") { return String(text.dropFirst()) }
        return text
    }

    private static func select(_ control: Element) throws -> FormField.Kind {
        var options: [FormOption] = []
        var selected: String?
        for option in try control.select("option") {
            let label = try option.text().trimmingCharacters(in: .whitespacesAndNewlines)
            let value = option.hasAttr("value") ? try option.attr("value") : label
            options.append(FormOption(value: value, label: label))
            if selected == nil, option.hasAttr("selected") { selected = value }
        }
        return .select(options: options, selected: selected ?? options.first?.value)
    }
}
