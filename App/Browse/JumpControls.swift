import EHNetwork
import SwiftUI

// MARK: - Input rules

/// Which of the list's cursors a Jump/Seek goes from: its next one or its previous one.
nonisolated enum ListJumpDirection: Sendable, Hashable {
    case next, previous
}

/// Why the Jump/Seek input sends nothing.
nonisolated enum JumpSeekError: Error, Equatable {
    case empty, malformed, beforeEarliest, afterToday, malformedGalleryID

    /// What the sheet's footer says.
    var message: String {
        switch self {
        case .empty: "Enter an offset or a date."
        case .malformed: "Use 3d, 2w, 6m, 1y or a date such as 2024-01-31."
        case .beforeEarliest: "Enter a date on or after 2007-03-20."
        case .afterToday: "Enter a date no later than today."
        case .malformedGalleryID: "A gallery ID has digits only."
        }
    }
}

/// The Jump/Seek sheet's input as a list position (Flutter tabview_controller.dart:748-802, without its slips: it sent
/// empty and malformed values, and any date).
///
/// - The text is trimmed and lowercased. A date (`yyyy`, `yyyy-MM`, `yyyy-MM-dd`, `yy-MM` or `yy-MM-dd`; a two-digit
///   year is 20YY) is a seek: it has to be a day of the calendar, on or after `earliest` and on or before today, a
///   year or a month counting from its first day. Otherwise digits with an optional `d`, `w`, `m` or `y` are a jump.
///   Four digits alone are a year.
/// - The cursor: the gallery ID when one is given (digits only), else the list's own cursor for the direction.
nonisolated enum JumpSeekInput {
    /// The site's earliest day (its `mindate`).
    static let earliest = DateComponents(year: 2007, month: 3, day: 20)

    /// `.offset(jump:seek:from:)`; from = .next/.previous(galleryID) when galleryID is non-empty, else the list's own
    /// cursor for that direction (nil when it has none).
    static func position(
        text: String, galleryID: String, direction: ListJumpDirection, navigation: ListNavigation, today: Date,
        calendar: Calendar
    ) -> Result<ListPosition, JumpSeekError> {
        read(
            text: text, galleryID: galleryID, direction: direction, navigation: navigation, today: today,
            calendar: calendar
        ).position
    }

    /// The text and the gallery ID read once, each with its own error (`position(text:galleryID:...)` is its
    /// `position`).
    static func read(
        text: String, galleryID: String, direction: ListJumpDirection, navigation: ListNavigation, today: Date,
        calendar: Calendar
    ) -> JumpSeekReading {
        JumpSeekReading(
            offset: offset(text: text, today: today, calendar: calendar),
            cursor: cursor(galleryID: galleryID, direction: direction, navigation: navigation)
        )
    }

    /// The cursor a Jump/Seek goes from: `galleryID` (trimmed; digits only) in `direction` when it is non-empty, else
    /// the list's own cursor for `direction`, nil when it has none.
    static func cursor(
        galleryID: String, direction: ListJumpDirection, navigation: ListNavigation
    ) -> Result<ListCursor?, JumpSeekError> {
        let gid = galleryID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !gid.isEmpty {
            guard gid.wholeMatch(of: /[0-9]+/) != nil else { return .failure(.malformedGalleryID) }
            return .success(direction == .next ? .next(gid) : .previous(gid))
        }
        guard case .cursor(let next, let previous) = navigation else { return .success(nil) }
        return .success(direction == .next ? next.map(ListCursor.next) : previous.map(ListCursor.previous))
    }

    /// `date` as the date picker writes it into the text field: `yyyy-MM-dd` in `calendar`.
    static func seekText(for date: Date, calendar: Calendar) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// The jump or the seek `text` asks for (see the type's rules).
    private static func offset(
        text: String, today: Date, calendar: Calendar
    ) -> Result<JumpSeekReading.Offset, JumpSeekError> {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return .failure(.empty) }
        let isLongDate = value.wholeMatch(of: /[0-9]{4}(-[0-9]{2}){0,2}/) != nil
        let isShortDate = value.wholeMatch(of: /[0-9]{2}(-[0-9]{2}){1,2}/) != nil
        if isLongDate || isShortDate {
            if let failure = check(date: value, isShort: isShortDate, today: today, calendar: calendar) {
                return .failure(failure)
            }
            return .success(JumpSeekReading.Offset(jump: nil, seek: value))
        }
        guard value.wholeMatch(of: /[0-9]+[dwmy]?/) != nil else { return .failure(.malformed) }
        return .success(JumpSeekReading.Offset(jump: value, seek: nil))
    }

    /// Why the date `value` (one of the date shapes) is refused, or nil when it is a day from `earliest` to today.
    private static func check(date value: String, isShort: Bool, today: Date, calendar: Calendar) -> JumpSeekError? {
        let numbers = value.split(separator: "-").compactMap { Int($0) }
        guard let first = numbers.first else { return .malformed }
        let year = isShort ? 2000 + first : first
        let month = numbers.count > 1 ? numbers[1] : 1
        let day = numbers.count > 2 ? numbers[2] : 1
        guard DateComponents(year: year, month: month, day: day).isValidDate(in: calendar) else { return .malformed }
        let earliestDay = (earliest.year ?? 0, earliest.month ?? 0, earliest.day ?? 0)
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        if (year, month, day) < earliestDay { return .beforeEarliest }
        if (year, month, day) > (now.year ?? 0, now.month ?? 0, now.day ?? 0) { return .afterToday }
        return nil
    }
}

/// The Jump/Seek sheet's input read once (`JumpSeekInput.read`): what the text asks for and the cursor, each with its
/// own error.
nonisolated struct JumpSeekReading {
    /// A relative jump or a date to seek to.
    nonisolated struct Offset {
        let jump: String?
        let seek: String?
    }

    let offset: Result<Offset, JumpSeekError>
    /// The cursor the jump goes from (`JumpSeekInput.cursor`).
    let cursor: Result<ListCursor?, JumpSeekError>

    /// `.offset(jump:seek:from:)`, or the first error: the text's, else the gallery ID's.
    var position: Result<ListPosition, JumpSeekError> {
        offset.flatMap { offset in cursor.map { .offset(jump: offset.jump, seek: offset.seek, from: $0) } }
    }

    /// Every error, the text's first: the footer shows them all.
    var errors: [JumpSeekError] {
        [offset.error, cursor.error].compactMap(\.self)
    }
}

/// The Jump to Page sheet's input.
nonisolated enum PageJumpInput {
    /// "n" (digits, surrounding spaces ignored) in 1...pageCount → .page(n - 1); anything else nil.
    static func position(for text: String, pageCount: Int) -> ListPosition? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.wholeMatch(of: /[0-9]+/) != nil, let number = Int(value), number >= 1, number <= pageCount else {
            return nil
        }
        return .page(number - 1)
    }
}

/// Which jumps a list offers: Jump to Page on a numbered list of more than one page, Jump/Seek on a cursor list, and
/// Back to First Page after a jump.
nonisolated struct ListJumpOptions: Equatable {
    let offersPageJump: Bool
    let offersJumpSeek: Bool
    let offersBackToFirst: Bool

    init(navigation: ListNavigation, isAfterJump: Bool) {
        switch navigation {
        case .numbered(_, let count):
            offersPageJump = count > 1
            offersJumpSeek = false
        case .cursor(let next, let previous):
            offersPageJump = false
            offersJumpSeek = next != nil || previous != nil
        case .none:
            offersPageJump = false
            offersJumpSeek = false
        }
        offersBackToFirst = isAfterJump
    }
}

// MARK: - Toolbar

extension View {
    /// The jumps of `model`'s list (`ListJumpOptions`) as toolbar items (`.primaryAction`, low visibility priority, so
    /// they may go to the overflow menu): Jump/Seek (`jump.open`) or Jump to Page (`jump.page`), each opening its
    /// sheet, and Back to First Page (`jump.backToFirst`, a reload) after a jump.
    func listJumpControls(_ model: GalleryListModel) -> some View {
        modifier(ListJumpControls(model: model))
    }
}

private struct ListJumpControls: ViewModifier {
    let model: GalleryListModel
    @State private var sheet: ListJumpSheet?

    func body(content: Content) -> some View {
        let options = ListJumpOptions(navigation: model.navigation, isAfterJump: model.isAfterJump)
        content
            .toolbar {
                if options.offersJumpSeek {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            sheet = .jumpSeek
                        } label: {
                            Label("Jump/Seek", systemImage: "arrow.uturn.down.circle")
                        }
                        .accessibilityIdentifier("jump.open")
                    }
                    .visibilityPriority(.low)
                }
                if options.offersPageJump {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            sheet = .page
                        } label: {
                            Label("Jump to Page", systemImage: "arrow.uturn.down.circle")
                        }
                        .accessibilityIdentifier("jump.page")
                    }
                    .visibilityPriority(.low)
                }
                if options.offersBackToFirst {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await model.reload() }
                        } label: {
                            Label("Back to First Page", systemImage: "arrow.up.circle")
                        }
                        .accessibilityIdentifier("jump.backToFirst")
                    }
                    .visibilityPriority(.low)
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .jumpSeek: JumpSeekSheet(model: model)
                case .page: PageJumpSheet(model: model)
                }
            }
    }
}

private enum ListJumpSheet: Identifiable {
    case jumpSeek, page

    var id: Self { self }
}

// MARK: - Sheets

/// The Jump/Seek sheet: an offset or a date (typed, or picked: every pick writes `yyyy-MM-dd` into the field, and
/// Today beside the picker writes today's, the day the picker shows while nothing is picked), the
/// direction (Next when the list has a next cursor, else Previous) and an optional gallery ID to go from. The footer
/// says which cursor the jump goes from and everything wrong with the input; Go jumps (`GalleryListModel.jump(to:)`)
/// and closes the sheet, and is disabled while the input is refused.
struct JumpSeekSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let model: GalleryListModel

    @State private var text = ""
    /// The day last picked; nil until one is (the picker shows today meanwhile).
    @State private var pickedDate: Date?
    @State private var direction: ListJumpDirection
    @State private var galleryID = ""

    init(model: GalleryListModel) {
        self.model = model
        let hasNext = if case .cursor(next: _?, previous: _) = model.navigation { true } else { false }
        _direction = State(initialValue: hasNext ? .next : .previous)
    }

    var body: some View {
        let calendar = Self.calendar
        // Now, once per redraw: the picker's range, its selection while nothing is picked and the reading all use the
        // same moment, so the selection never lies past the range's end (L076a).
        let now = Date.now
        let reading = JumpSeekInput.read(
            text: text, galleryID: galleryID, direction: direction, navigation: model.navigation, today: now,
            calendar: calendar
        )
        NavigationStack {
            Form {
                Section {
                    TextField("Date or Offset", text: $text)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("jump.text")
                    // Today beside the picker; below it at the accessibility text sizes, where the picker took the
                    // whole row and left Today no width at all (M2 re-review F3 M-8, measured at AX5).
                    let dateRow = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout())
                    dateRow {
                        DatePicker(
                            "Date", selection: pick(calendar, fallback: now), in: Self.dateRange(calendar, now: now),
                            displayedComponents: .date
                        )
                        .accessibilityIdentifier("jump.date")
                        // The picker shows today while nothing is picked, and picking the day it already shows sends
                        // nothing on iOS 27.2 (M2 review U10): this writes today in one tap. Today as of the tap, not
                        // of the last redraw (a sheet left open past midnight); the redraw that follows reads a `now`
                        // no earlier than it, so the pick stays inside the picker's range.
                        Button("Today") {
                            let today = Date.now
                            pickedDate = today
                            text = JumpSeekInput.seekText(for: today, calendar: calendar)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("jumpSeek.today")
                    }
                    Picker("Direction", selection: $direction) {
                        Text("Next").tag(ListJumpDirection.next)
                        Text("Previous").tag(ListJumpDirection.previous)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("jump.direction")
                    TextField("Gallery ID (Optional)", text: $galleryID)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("jump.gid")
                } footer: {
                    footer(reading)
                }
            }
            .navigationTitle("Jump or Seek")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                JumpSheetToolbar(position: reading.position.value, model: model, dismiss: dismiss)
            }
        }
        .alertHost()
    }

    /// The date picker's selection: the day picked, else `fallback` (now). Every pick writes its day into the text
    /// field, the day already shown included (a value that does not change would not reach `onChange`).
    private func pick(_ calendar: Calendar, fallback: Date) -> Binding<Date> {
        let text = $text
        let pickedDate = $pickedDate
        return Binding {
            pickedDate.wrappedValue ?? fallback
        } set: { date in
            pickedDate.wrappedValue = date
            text.wrappedValue = JumpSeekInput.seekText(for: date, calendar: calendar)
        }
    }

    /// The cursor the jump goes from (while the gallery ID is good), and every error, the text's first.
    private func footer(_ reading: JumpSeekReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .success(let from) = reading.cursor {
                Group {
                    if let from {
                        Text("From gallery \(from.galleryID).")
                    } else {
                        Text("From the start of the list.")
                    }
                }
                .accessibilityIdentifier("jump.from")
            }
            if let first = reading.errors.first {
                reading.errors.dropFirst().reduce(Self.line(first)) { shown, error in
                    Text("\(shown)\n\(Self.line(error))")
                }
                .accessibilityIdentifier("jump.error")
            }
        }
    }

    /// An error's line; an empty field is a prompt rather than a mistake.
    private static func line(_ error: JumpSeekError) -> Text {
        Text(error.message).foregroundStyle(error == .empty ? Color.secondary : Color.red)
    }

    /// The Gregorian calendar in the device's time zone: the days typed or picked are the user's.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// From the site's earliest day to `now`.
    private static func dateRange(_ calendar: Calendar, now: Date) -> ClosedRange<Date> {
        let earliest = calendar.date(from: JumpSeekInput.earliest) ?? .distantPast
        return earliest...max(earliest, now)
    }
}

/// The Jump to Page sheet of a numbered list: a page number from 1 to the list's page count; Go jumps to it and closes
/// the sheet, and is disabled while the number is out of range.
struct PageJumpSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let model: GalleryListModel

    @State private var text = ""

    init(model: GalleryListModel) {
        self.model = model
    }

    var body: some View {
        let count = pageCount
        NavigationStack {
            Form {
                Section {
                    TextField("Page", text: $text)
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("jump.pageText")
                } footer: {
                    Text("Page range 1 - \(count)")
                }
            }
            .navigationTitle("Jump to Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                JumpSheetToolbar(
                    position: PageJumpInput.position(for: text, pageCount: count), model: model, dismiss: dismiss
                )
            }
        }
        .alertHost()
    }

    /// The numbered list's page count; 0 for any other list.
    private var pageCount: Int {
        if case .numbered(_, let count) = model.navigation { count } else { 0 }
    }
}

/// A jump sheet's toolbar: Close (`.cancellationAction`) and Go (`.topBarPinnedTrailing`), disabled without a
/// position; Go closes the sheet, then jumps.
private struct JumpSheetToolbar: ToolbarContent {
    let position: ListPosition?
    let model: GalleryListModel
    let dismiss: DismissAction

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { dismiss() }
                .accessibilityIdentifier("jump.close")
        }
        ToolbarItem(placement: .topBarPinnedTrailing) {
            Button {
                guard let position else { return }
                dismiss()
                Task { await model.jump(to: position) }
            } label: {
                Label("Go", systemImage: "arrow.forward")
            }
            .disabled(position == nil)
            .accessibilityIdentifier("jump.go")
        }
    }
}

private extension ListCursor {
    /// The gallery the cursor pages from.
    var galleryID: String {
        switch self {
        case .next(let gid), .previous(let gid): gid
        }
    }
}

private nonisolated extension Result {
    /// The value of a success.
    var value: Success? {
        if case .success(let value) = self { value } else { nil }
    }

    /// The error of a failure.
    var error: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
