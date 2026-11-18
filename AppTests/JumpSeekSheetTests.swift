import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Eros

/// `JumpSeekSheet` on a window of its own: what its date picker writes into the text field.
@MainActor @Suite struct JumpSeekSheetTests {
    /// The calendar the sheet reads and writes days in.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// Every pick writes its day into the text field: the day the picker already shows (today, when the sheet opens)
    /// as well as another one.
    @Test func pickingADayFillsTheTextField() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let model = GalleryListModel(feed: ScriptedFeed())
        let host = try HostedViews.show(JumpSeekSheet(model: model), environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.subviews(of: UIDatePicker.self, in: host.view).count == 1 })
        let picker = try #require(Self.subviews(of: UIDatePicker.self, in: host.view).first)
        let field = try #require(
            Self.subviews(of: UITextField.self, in: host.view).first { $0.placeholder == "Date or Offset" }
        )
        #expect((field.text ?? "").isEmpty)

        // The day shown, picked again: the value does not change, yet it is a pick.
        picker.sendActions(for: .valueChanged)
        let shown = JumpSeekInput.seekText(for: picker.date, calendar: Self.calendar)
        #expect(await eventually { field.text == shown })

        let other = try #require(Self.calendar.date(from: DateComponents(year: 2024, month: 1, day: 5, hour: 12)))
        picker.date = other
        picker.sendActions(for: .valueChanged)
        #expect(await eventually { field.text == "2024-01-05" })
    }

    /// Today, beside the date picker, writes today into the text field (U10: picking the day the picker already shows
    /// sends nothing in the system's calendar).
    @Test func todayFillsTheTextField() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let model = GalleryListModel(feed: ScriptedFeed())
        let host = try HostedViews.show(JumpSeekSheet(model: model), environment: environment)
        defer { HostedViews.hide(host) }
        #expect(await eventually { Self.subviews(of: UIDatePicker.self, in: host.view).count == 1 })
        let field = try #require(
            Self.subviews(of: UITextField.self, in: host.view).first { $0.placeholder == "Date or Offset" }
        )
        #expect((field.text ?? "").isEmpty)
        var today: NSObject?
        #expect(await eventually {
            today = HostedViews.elements(in: host.view).first { HostedViews.identifier(of: $0) == "jumpSeek.today" }
            return today != nil
        })
        #expect(today?.accessibilityActivate() == true)
        let expected = JumpSeekInput.seekText(for: .now, calendar: Self.calendar)
        #expect(await eventually { field.text == expected })
    }

    /// At the largest accessibility text size (AX5), with 375 pt of content width, Today is whole (as wide as its title
    /// needs), inside the visible part of its row and clear of the date picker (M2 re-review F3 M-8). Beside the
    /// picker, as at the other sizes, the picker took the whole row and left Today no width at all (iPad, 2026-11-17):
    /// it goes below the picker at the accessibility sizes.
    ///
    /// 375 pt is the narrowest iPhone screen held upright (the iPhone SE's and the mini's; M2 review F6). The window
    /// is that wide plus the window's horizontal safe area, measured on a first showing: on the iPhone Duo's outer
    /// screen the scene keeps a rail 84 pt wide on the right (`HostedViews`), and a window of a fixed 390 left the
    /// sheet 306 pt, narrower than on any device. This makes up for the rail in the test only; the app's layout does
    /// not look at widths.
    ///
    /// The picker shows a fixed day in a fixed format: Nov 18, 2026 in en_US, the day and the format those widths were
    /// measured with (M2 review F6). At AX5 the compact picker is as wide as its date's text, so the room Today keeps
    /// follows the day shown and the region's format: on the Duo it kept 4 pt inside its cell on that day, a few wider
    /// days of the year (May 26, 2027) would push it out there, and a longer format (zh_Hans) on every device. That is
    /// the compact picker's known limit at AX5, left to M8 (M2 final re-review I-1). This test pins the layout below
    /// the picker: its result is to follow the code alone, not the day it runs on or the simulator's region.
    @Test func todayStaysWholeAtTheLargestTextSize() async throws {
        let environment = AppEnvironment(uiTesting: true)
        let model = GalleryListModel(feed: ScriptedFeed())
        let first = try await Self.showAtTheLargestTextSize(model: model, environment: environment)
        let inset = first.view.safeAreaInsets.left + first.view.safeAreaInsets.right
        HostedViews.hide(first)
        let host = try await Self.showAtTheLargestTextSize(
            model: model, environment: environment, width: Self.contentWidth + inset
        )
        defer { HostedViews.hide(host) }
        // The day the widths were measured on, picked; the frames below are taken once the sheet has shown it.
        let picker = try #require(Self.subviews(of: UIDatePicker.self, in: host.view).first)
        picker.date = try #require(Self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12)))
        picker.sendActions(for: .valueChanged)
        let field = try #require(
            Self.subviews(of: UITextField.self, in: host.view).first { $0.placeholder == "Date or Offset" }
        )
        #expect(await eventually { field.text == "2026-11-18" })
        host.view.layoutIfNeeded()
        let content = HostedViews.contentRegion(of: host)
        #expect(
            abs(content.width - Self.contentWidth) < 1, "The sheet has \(content.width) pt, not \(Self.contentWidth)"
        )
        var today: NSObject?
        #expect(await eventually {
            today = HostedViews.elements(in: host.view).first { HostedViews.identifier(of: $0) == "jumpSeek.today" }
            return today != nil
        })
        let window = try #require(host.view.window)
        let pickerFrame = picker.convert(picker.bounds, to: nil)
        let todayFrame = HostedViews.frame(of: try #require(today), in: window)
        let row = try #require(Self.visibleRow(of: picker), "The date picker is in no list row")
        let largest = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let title = UIFont.preferredFont(forTextStyle: .body, compatibleWith: largest)
        let needed = ("Today" as NSString).size(withAttributes: [.font: title]).width
        #expect(todayFrame.width >= needed - 1, "Today is \(todayFrame.width) wide, its title needs \(needed)")
        #expect(row.contains(todayFrame), "Today at \(todayFrame), the visible part of its row at \(row)")
        #expect(!pickerFrame.intersects(todayFrame), "Today at \(todayFrame), the picker at \(pickerFrame)")
    }

    /// The content width the AX5 test lays the sheet out in: the narrowest iPhone screen held upright.
    private static let contentWidth: CGFloat = 375

    /// The sheet on a window `width` wide (390 by default) at AX5, in the en_US format whatever the simulator's region,
    /// once its date picker is there.
    private static func showAtTheLargestTextSize(
        model: GalleryListModel, environment: AppEnvironment, width: CGFloat = 390
    ) async throws -> UIHostingController<AnyView> {
        let host = try HostedViews.show(
            JumpSeekSheet(model: model).environment(\.locale, Locale(identifier: "en_US")),
            environment: environment, size: CGSize(width: width, height: 700)
        )
        host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        #expect(await eventually { Self.subviews(of: UIDatePicker.self, in: host.view).count == 1 })
        return host
    }

    /// The part of the list row `view` is in that is not under the window's bars or rail, in the window's
    /// coordinates: the row's cell within the list's safe area.
    private static func visibleRow(of view: UIView) -> CGRect? {
        var ancestor = view.superview
        while let candidate = ancestor, !(candidate is UICollectionViewCell) { ancestor = candidate.superview }
        guard let cell = ancestor else { return nil }
        while let candidate = ancestor, !(candidate is UICollectionView) { ancestor = candidate.superview }
        guard let list = ancestor else { return nil }
        let visible = list.convert(list.bounds.inset(by: list.safeAreaInsets), to: nil)
        return cell.convert(cell.bounds, to: nil).intersection(visible)
    }

    /// The views of type `T` under `root`, depth first.
    private static func subviews<T: UIView>(of type: T.Type, in root: UIView) -> [T] {
        var found: [T] = []
        var pending = [root]
        while let view = pending.popLast() {
            if let match = view as? T { found.append(match) }
            pending += view.subviews.reversed()
        }
        return found
    }
}
