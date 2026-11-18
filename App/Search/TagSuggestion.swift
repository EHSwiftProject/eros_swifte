import EHModels

/// A tag offered while a search is typed, with its translated name when the local tag table gave it
/// (`TagTranslation.plainName`); nil when the site's `tagsuggest` gave it.
nonisolated struct TagSuggestion: Sendable, Hashable {
    let tag: TagRef
    let translation: String?
}

nonisolated extension TagSuggestion {
    /// "<short>:<key>", the namespace abbreviated where `TagNamespace` has an abbreviation (else written in full);
    /// the key alone without a namespace.
    var displayName: String {
        guard let namespace = tag.namespace else { return tag.name }
        return "\(Self.shortName(of: namespace)):\(tag.name)"
    }

    /// "<namespace>:<translation>", the namespace's Chinese name where `TagNamespaceNames` has one, else its full name;
    /// the translation alone without a namespace; nil without a translation.
    var translatedName: String? {
        guard let translation else { return nil }
        guard let namespace = tag.namespace else { return translation }
        let fullName = TagNamespace.fullName(for: namespace) ?? namespace
        return "\(TagNamespaceNames.chinese(fullName) ?? fullName):\(translation)"
    }

    /// What a search writes for this exact tag (Flutter `search_page_controller.dart` and `extension.dart`):
    /// "<short>:<key>$", or `<short>:"<key>$"` when the key has a space; without a namespace "<key>$" or `"<key>$"`.
    var searchTerm: String {
        let exact = tag.name + "$"
        let value = tag.name.contains(" ") ? "\"\(exact)\"" : exact
        guard let namespace = tag.namespace else { return value }
        return "\(Self.shortName(of: namespace)):\(value)"
    }

    private static func shortName(of namespace: String) -> String {
        TagNamespace.abbreviation(for: namespace) ?? namespace
    }
}

/// The Chinese display names of the tag namespaces, by full name (Flutter `EHConst.translateTagType`). For display
/// only: abbreviations and full names come from `TagNamespace`.
nonisolated enum TagNamespaceNames {
    private static let names: [String: String] = [
        "artist": "作者", "character": "角色", "female": "女性", "group": "团队", "language": "语言",
        "male": "男性", "parody": "原作", "reclass": "归类", "other": "其他", "mixed": "混合",
        "cosplayer": "扮演者", "misc": "杂项", "uploader": "上传者", "temp": "临时",
    ]

    /// The Chinese name of the namespace `fullName` ("female" → "女性"); nil for any other name.
    static func chinese(_ fullName: String) -> String? {
        names[fullName]
    }
}
