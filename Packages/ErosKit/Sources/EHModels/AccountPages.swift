import Foundation

// MARK: Settings (`uconfig.php`)

/// One of the account's settings profiles, as the profile selector of `uconfig.php` lists it.
public struct SiteProfile: Sendable, Hashable, Codable {
    /// The profile's number: the selector option's value, sent back as `profile_set` and kept in the `sp` cookie.
    public let number: Int
    /// The profile's name, without the "(Default)" suffix and trimmed.
    public let name: String
    /// The profile the page shows (the one the request's `sp` cookie chose).
    public let isSelected: Bool
    /// The account's default profile: its option's text ends in "(Default)" (the Flutter app's rule).
    public let isDefault: Bool

    public init(number: Int, name: String, isSelected: Bool, isDefault: Bool) {
        self.number = number
        self.name = name
        self.isSelected = isSelected
        self.isDefault = isDefault
    }
}

/// One option of a `select`.
public struct FormOption: Sendable, Hashable, Codable {
    /// What the form sends when the option is selected: its `value`, or its text without one.
    public let value: String
    /// The option's text, trimmed.
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// One named control of a form, with what the page set it to.
public struct FormField: Sendable, Hashable, Codable {
    public enum Kind: Sendable, Hashable, Codable {
        /// Every radio button of one name: their values in page order, and the checked one's.
        case radio(options: [String], selected: String?)
        /// A checkbox: its value ("on" without one) and whether it is checked.
        case checkbox(value: String, isChecked: Bool)
        /// A one-line input (`type` text, missing, or any other the form sends as text).
        case text(String)
        /// A `textarea`'s text, its line breaks kept.
        case textarea(String)
        case hidden(String)
        /// A `select`: its options, and the selected one's value (the first option's when none is marked, as a
        /// browser sends it).
        case select(options: [FormOption], selected: String?)
    }

    /// The control's `name`.
    public let name: String
    public let kind: Kind

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }

    /// What the form sends for this field: the selected radio or option value, the text, the checked checkbox's
    /// value; nil when it sends nothing.
    var sentValue: String? {
        switch kind {
        case .radio(_, let selected), .select(_, let selected): selected
        case .checkbox(let value, let isChecked): isChecked ? value : nil
        case .text(let value), .textarea(let value), .hidden(let value): value
        }
    }
}

/// A settings form as the page fills it in, for editing and sending back.
public struct SettingsForm: Sendable, Equatable, Codable {
    /// The named controls in page order; the radio buttons of one name are one field, where the first of them is.
    /// Buttons (submit, reset, image, `button`), file inputs and unnamed controls are left out.
    public var fields: [FormField]

    public init(fields: [FormField]) {
        self.fields = fields
    }

    /// What the form sends for `name`: the selected radio or `select` value, the text of a text, textarea or hidden
    /// field, the value of a checked checkbox ("on" without one); nil when no field of that name sends anything.
    public func value(of name: String) -> String? {
        fields.lazy.filter { $0.name == name }.compactMap(\.sentValue).first
    }
}

/// The settings page (`uconfig.php`).
public struct UConfigPage: Sendable, Equatable, Codable {
    /// The account's profiles, in page order; empty when the page has no profile selector.
    public var profiles: [SiteProfile]
    /// The profile the page shows.
    public var selectedProfile: SiteProfile? { profiles.first(where: \.isSelected) }
    /// The settings form (the one with the Apply button); no fields when the page has none.
    public var form: SettingsForm

    public init(profiles: [SiteProfile], form: SettingsForm) {
        self.profiles = profiles
        self.form = form
    }
}

// MARK: My Tags (`mytags`)

/// One of the account's tag sets, as the mytags page's tag set chooser lists it.
public struct TagSet: Sendable, Hashable, Codable {
    /// The tag set's number (the chooser option's value; the `tagset` query of the page).
    public let id: Int
    /// The tag set's name, without its tag count.
    public let name: String
    /// How many tags it holds, from the " (<n>)" after its name; nil without one.
    public let tagCount: Int?
    /// The tag set the page shows.
    public let isSelected: Bool

    public init(id: Int, name: String, tagCount: Int?, isSelected: Bool) {
        self.id = id
        self.name = name
        self.tagCount = tagCount
        self.isSelected = isSelected
    }
}

/// One tag of the shown tag set.
public struct UserTag: Sendable, Hashable, Codable {
    /// The tag's number on the site (`usertag_<id>`; the `tagid` of the `setusertag` API).
    public let id: Int
    public let tag: TagRef
    /// Galleries with the tag are listed on the watched page.
    public let isWatched: Bool
    /// Galleries with the tag are hidden from lists.
    public let isHidden: Bool
    /// The color the account set for the tag, "#RRGGBB" (case as the page writes it); nil when it has none and
    /// takes the tag set's color.
    public let colorHex: String?
    /// The tag's weight; nil when it cannot be read (it must be given one before the tag is saved).
    public let weight: Int?

    public init(id: Int, tag: TagRef, isWatched: Bool, isHidden: Bool, colorHex: String?, weight: Int?) {
        self.id = id
        self.tag = tag
        self.isWatched = isWatched
        self.isHidden = isHidden
        self.colorHex = colorHex
        self.weight = weight
    }
}

/// The mytags page: the account's tag sets and the tags of the one it shows.
public struct MyTagsPage: Sendable, Equatable, Codable {
    /// The tag sets, in page order; empty when the page has no tag set chooser.
    public var tagSets: [TagSet]
    /// The shown tag set's tags, in page order. A row whose tag, watch or hide checkbox or color cannot be read is
    /// left out: saving a tag sends its watch, hide and color back together, so an unknown one must never be taken for
    /// unchecked or for the tag set's color.
    public var userTags: [UserTag]
    /// The account's API user id (`var apiuid`), for the JSON API.
    public var apiUID: Int?
    /// The account's API key (`var apikey`), for the JSON API.
    public var apiKey: String?
    /// The page offers to delete the shown tag set.
    public var canDeleteTagSet: Bool

    public init(tagSets: [TagSet], userTags: [UserTag], apiUID: Int?, apiKey: String?, canDeleteTagSet: Bool) {
        self.tagSets = tagSets
        self.userTags = userTags
        self.apiUID = apiUID
        self.apiKey = apiKey
        self.canDeleteTagSet = canDeleteTagSet
    }
}

// MARK: Overview (`home.php`)

/// The account's image limits, from the Image Limits section of `home.php`.
public struct ImageLimits: Sendable, Equatable, Codable {
    /// Images viewed toward the limit; 0 when the section only offers to unlock the limits.
    public let current: Int
    /// The limit; 0 when the section only offers to unlock the limits.
    public let limit: Int
    /// The GP the reset (or the unlock) costs; nil when it cannot be read.
    public let resetCost: Int?
    /// The section says high-resolution images can be limited.
    public let highResolutionLimited: Bool

    public init(current: Int, limit: Int, resetCost: Int?, highResolutionLimited: Bool) {
        self.current = current
        self.limit = limit
        self.resetCost = resetCost
        self.highResolutionLimited = highResolutionLimited
    }
}

// MARK: Forum profile (`forums.e-hentai.org/index.php?showuser=<id>`)

/// What the account's forum profile page shows of it.
public struct ForumProfile: Sendable, Equatable, Codable {
    /// The name the forum shows.
    public let displayName: String
    /// The avatar image; nil without one.
    public let avatarURL: URL?

    public init(displayName: String, avatarURL: URL?) {
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}
