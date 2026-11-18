import EHModels
import EHNetwork
import SwiftUI

extension EnvironmentValues {
    /// The site the lists of this part of the app browse: their items open galleries there. M2 is always on E-Hentai at
    /// the tab roots (site switching is M6); a pushed list sets its route's.
    @Entry var browsingSite: EHSite = .eh
}

/// What a gallery list shows for its model's state.
nonisolated enum GalleryListPhase: Equatable {
    /// Nothing to show yet: the first page (or a reload) is on its way, or was not asked for.
    case loading
    /// The first page failed while nothing was shown.
    case failed(ListFailure)
    /// The items, with the header and footer; also while a jump replaces them (they stay until the page comes).
    case list
    /// The list is shown and has no items: `No Galleries`, under the header (a failed refresh shows there).
    case empty

    static func of(status: ListStatus, itemCount: Int) -> GalleryListPhase {
        if itemCount > 0 { return .list }
        switch status {
        case .idle, .loading: return .loading
        case .loaded: return .empty
        case .failed(let failure): return .failed(failure)
        }
    }
}

extension ListFailure {
    /// The failure as a list shows it while `pause` holds both sites: a ban or a 429 of the site, and an earlier
    /// pause, read as the pause in force (with its end); anything else as itself.
    nonisolated func shown(during pause: SitePause?) -> ListFailure {
        guard let pause else { return self }
        switch self {
        case .paused, .siteIssue(.banned), .siteIssue(.tooManyRequests): return .paused(pause)
        default: return self
        }
    }

    /// The symbol of the failure's view.
    nonisolated var systemImage: String {
        switch self {
        case .loginRequired: "person.crop.circle.badge.exclamationmark"
        case .paused: "pause.circle"
        case .network: "wifi.exclamationmark"
        case .siteIssue, .compactDeclined, .compactUnavailable, .unreadable, .localFavoritesUnavailable:
            "exclamationmark.triangle"
        }
    }
}

/// A gallery list over a `GalleryListModel` (M2 index §3.4), in one of the five `ListStyle`s, for any source: the tab
/// roots, the routed lists, search.
///
/// - Loads its first page when it appears; pull to refresh; scrolls to the top when `scrollToTopSignal` changes.
/// - The items sit in lanes (`LanePlan`, one `LazyVStack` each) in a `ScrollView`. The content's width and where it
///   begins come from a full-width, zero-high view at its top; the active division (the Duo's fold, iOS 27.1) from the
///   scroll view's own geometry, as a view is told only of the divisions over it and none crosses a zero-high one.
///   The fold goes into the content's coordinates through a coordinate space named on the scroll view. The lanes are
///   laid out again whenever the width or the fold changes (`LaneAssignment.sync`). The next page is asked for when
///   one of the last items (as many as there are lanes) appears.
/// - Header: the summary, a failed refresh (or jump) with its action, a jump in flight. Footer: the next page loading,
///   its failure (tap to retry), the Load More button; nothing at the end.
/// - Nothing shown yet: a spinner, or the failure (`ContentUnavailableView`, Log In or Try Again). Shown but empty:
///   `No Galleries` with the summary, in the middle of the height the scroll view shows.
/// - The spinner, the failure, `No Galleries`, the header, the footer and the pause banner's text keep clear of the
///   Duo's fold (`keepsClearOfFold(alignment:)`, D2): on its wider side. The lanes split at it instead (above).
/// - While both sites are paused (`AppEnvironment.sitePause`) a banner above the list says until when.
/// - The session's identity (logged in, the E-Hentai member id) changing reloads the list (the
///   one place that does it for every list).
/// - The tags of the items are prefetched (`TagNameCache.prefetch`) when they change, when the tag names were cleared
///   (`generation`) and when translations are turned on; once per change, never per redraw.
struct GalleryListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.browsingSite) private var site
    @Environment(\.horizontalSizeClass) private var sizeClass
    private let model: GalleryListModel
    private let style: ListStyle

    /// The content's width and where it begins in the scroll view, from the geometry of the width probe.
    @State private var space = LaneSpace()
    /// The x range of the fold (the Duo's, iOS 27.1) in the scroll view's coordinate space (`LanePlan.fold(in:)`); nil
    /// without one that splits the lanes.
    @State private var fold: ClosedRange<CGFloat>?
    /// The lanes the items are in; kept between redraws so that a page coming in places only its own items.
    @State private var lanes = LaneCache()
    @State private var position = ScrollPosition(edge: .top)
    @State private var isShowingLogin = false

    init(model: GalleryListModel, style: ListStyle) {
        self.model = model
        self.style = style
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                pauseBanner
            }
            .task {
                await model.loadFirst()
            }
            .onChange(of: identity) {
                Task { await model.reload() }
            }
            .task(id: tagPrefetch) {
                let prefetch = tagPrefetch
                guard prefetch.isOn, !prefetch.tags.isEmpty else { return }
                await environment.tagNames.prefetch(prefetch.tags)
            }
            .sheet(isPresented: $isShowingLogin) {
                LoginView()
            }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch GalleryListPhase.of(status: model.status, itemCount: model.items.count) {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("gallery.loading")
                .keepsClearOfFold()
        case .failed(let failure):
            failureView(failure.shown(during: environment.sitePause))
        case .list, .empty:
            list
        }
    }

    private var list: some View {
        let metrics = LaneMetrics.of(style, regularWidth: sizeClass == .regular)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                widthProbe
                header
                if model.items.isEmpty {
                    // As tall as the scroll view shows, so it stands in the middle (U9), yet still in the scroll view:
                    // pulling down refreshes an empty list too.
                    ContentUnavailableView(
                        "No Galleries", systemImage: "photo.on.rectangle", description: model.summary.map { Text($0) }
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("gallery.empty")
                    .containerRelativeFrame(.vertical)
                    .keepsClearOfFold()
                } else {
                    lanesView(metrics: metrics)
                }
                footer
            }
        }
        .contentMargins(.horizontal, metrics.margin, for: .scrollContent)
        // The fold is read here, on the list's whole extent: the width probe, zero high, is never crossed by it. Only
        // its x range is kept, which neither scrolling (the scroll view's frame stays where it is) nor the scroll view
        // moving up or down (the pause banner) changes: only the posture, or the scroll view's place or extent across
        // the screen.
        .coordinateSpace(.named(LaneSpace.scrollView))
        .onGeometryChange(for: ClosedRange<CGFloat>?.self) { proxy in
            LanePlan.fold(in: DivisionRegion.all(of: proxy))
        } action: { fold in
            self.fold = fold
        }
        .scrollPosition($position)
        .refreshable {
            await model.refresh()
        }
        .onChange(of: model.scrollToTopSignal) {
            withAnimation { position.scrollTo(edge: .top) }
        }
    }

    /// A full-width, zero-high view whose geometry gives the content's width and its leading edge's x in the scroll
    /// view: the origin the fold is moved by (`LanePlan.division(from:contentOrigin:)`). The fold itself is not seen
    /// here: a view is told only of the divisions over it.
    private var widthProbe: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 0)
            .onGeometryChange(for: LaneSpace.self) { proxy in
                LaneSpace(proxy)
            } action: { space in
                self.space = space
            }
    }

    private func lanesView(metrics: LaneMetrics) -> some View {
        let division = fold.map { LanePlan.division(from: $0, contentOrigin: space.origin) }
        let plan = LanePlan.make(
            width: space.width, style: style, regularWidth: sizeClass == .regular, division: division
        )
        let assignment = lanes.assignment(for: model.items, style: style, plan: plan)
        let byID = Dictionary(model.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lookahead = plan.lanes.count
        return HStack(alignment: .top, spacing: 0) {
            if space.width > 0 {
                ForEach(Array(plan.lanes.enumerated()), id: \.offset) { index, lane in
                    let start = index == 0 ? 0 : plan.lanes[index - 1].upperBound
                    let laneWidth = lane.upperBound - lane.lowerBound
                    Color.clear.frame(width: max(lane.lowerBound - start, 0), height: 0)
                    LazyVStack(alignment: .leading, spacing: metrics.itemSpacing) {
                        ForEach(index < assignment.lanes.count ? assignment.lanes[index] : [], id: \.self) { id in
                            if let summary = byID[id] {
                                item(summary, laneWidth: laneWidth, lookahead: lookahead)
                            }
                        }
                    }
                    .frame(width: laneWidth, alignment: .top)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("gallery.list.\(style.rawValue)")
    }

    private func item(_ summary: GallerySummary, laneWidth: CGFloat, lookahead: Int) -> some View {
        NavigationLink(value: AppRoute.gallery(summary.id, site)) {
            GalleryItemView(summary: summary, style: style, laneWidth: laneWidth)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            ItemContextMenu(id: summary.id, site: site)
        }
        .accessibilityIdentifier("gallery.item.\(summary.id.gid)")
        .onAppear {
            Task { await model.itemAppeared(summary.id, lookahead: lookahead) }
        }
    }

    // MARK: - Header and footer

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let failure = model.refreshFailure {
                refreshFailureRow(failure.shown(during: environment.sitePause))
            }
            if model.status == .loading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("gallery.header.loading")
            }
            if let summary = model.summary, !model.items.isEmpty {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("gallery.summary")
            }
        }
        .keepsClearOfFold(alignment: .leading)
        .padding(.top, 8)
    }

    /// A failed refresh or jump while the list is shown: its message and what it offers, on one baseline.
    private func refreshFailureRow(_ failure: ListFailure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(failure.message)
                .accessibilityIdentifier("gallery.refreshFailure")
            Spacer(minLength: 0)
            switch failure.action {
            case .logIn:
                Button("Log In") { isShowingLogin = true }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("gallery.refreshFailure.logIn")
            case .tryAgain:
                Button("Try Again") { Task { await model.refresh() } }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("gallery.refreshFailure.tryAgain")
            case nil:
                EmptyView()
            }
        }
        .font(.footnote)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
    }

    @ViewBuilder private var footer: some View {
        Group {
            switch model.footer {
            case .loading:
                ProgressView()
                    .accessibilityIdentifier("gallery.footer.loading")
            case .failed:
                Button {
                    Task { await model.retryMore() }
                } label: {
                    Label("Load failed. Tap to retry.", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("gallery.footer.failed")
            case .loadMore:
                Button("Load More") {
                    Task { await model.loadMore() }
                }
                .accessibilityIdentifier("gallery.footer.loadMore")
            case .none, .end:
                EmptyView()
            }
        }
        .keepsClearOfFold()
        .padding(.vertical, 16)
    }

    // MARK: - Failure and pause

    private func failureView(_ failure: ListFailure) -> some View {
        ContentUnavailableView {
            // The identifier goes on the title, not the view: inside a page that is one accessibility container
            // (`GalleryRootView`, `RouteListView`) a container of the same extent merges into it and loses its own.
            Label(failure.title, systemImage: failure.systemImage)
                .accessibilityIdentifier("gallery.failure")
        } description: {
            Text(failure.message)
        } actions: {
            switch failure.action {
            case .logIn:
                Button("Log In") { isShowingLogin = true }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("gallery.failure.logIn")
            case .tryAgain:
                Button("Try Again") { Task { await model.reload() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("gallery.failure.tryAgain")
            case nil:
                EmptyView()
            }
        }
        .keepsClearOfFold()
    }

    @ViewBuilder private var pauseBanner: some View {
        if let pause = environment.sitePause {
            Label(ListFailure.paused(pause).message, systemImage: "pause.circle")
                .font(.footnote)
                .keepsClearOfFold(alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar, ignoresSafeAreaEdges: .top)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("gallery.pauseBanner")
        }
    }

    // MARK: - Observed values

    /// Who the session is: the E-Hentai member id while logged in, nil otherwise.
    private var identity: SessionIdentity {
        environment.sessionIdentity
    }

    /// What the tag prefetch depends on: the names' generation, whether translations are shown, and the items' tags.
    private var tagPrefetch: TagPrefetch {
        var seen: Set<TagRef> = []
        var tags: [TagRef] = []
        for summary in model.items {
            for tag in summary.tags where seen.insert(tag.tag).inserted {
                tags.append(tag.tag)
            }
        }
        return TagPrefetch(
            generation: environment.tagNames.generation,
            isOn: environment.settings.settings.showsTagTranslations,
            tags: tags
        )
    }
}

/// One item in the list's style.
private struct GalleryItemView: View {
    let summary: GallerySummary
    let style: ListStyle
    let laneWidth: CGFloat

    var body: some View {
        switch style {
        case .list: GalleryListRow(summary: summary, laneWidth: laneWidth)
        case .simpleList: GallerySimpleRow(summary: summary)
        case .waterfall: GalleryWaterfallCell(summary: summary, laneWidth: laneWidth)
        case .waterfallLarge: GalleryWaterfallLargeCell(summary: summary, laneWidth: laneWidth)
        case .grid: GalleryGridCell(summary: summary, laneWidth: laneWidth)
        }
    }
}

/// The content's width and the x of its leading edge in the scroll view's coordinate space (`scrollView`), the space
/// the fold is read in: the difference puts the fold in the content's coordinates, whatever the margins and the safe
/// area. From the left edge, as the fold's x (left-to-right only; right-to-left is not in M2).
private nonisolated struct LaneSpace: Equatable, Sendable {
    /// The name of the list's scroll view's coordinate space.
    static let scrollView = "GalleryListView.scrollView"

    var width: CGFloat = 0
    var origin: CGFloat = 0

    init() {}

    /// Of the width probe: only its x in the scroll view, which scrolling does not change, not its y, which it does.
    init(_ proxy: GeometryProxy) {
        width = proxy.size.width
        origin = proxy.frame(in: .named(Self.scrollView)).minX
    }
}

/// The input of the tag prefetch (`.task(id:)`).
private nonisolated struct TagPrefetch: Equatable {
    let generation: Int
    let isOn: Bool
    let tags: [TagRef]
}

/// The list's lanes between redraws: the assignment is brought up to the items and lanes of each redraw
/// (`LaneAssignment.sync`), so a page coming in places only its own items and the lanes are laid out again only when
/// their number changed. A plain object, not observed: updating it during a redraw invalidates nothing.
private final class LaneCache {
    private var assignment = LaneAssignment(laneCount: 1)
    /// The style the assignment was made for: another style reckons other heights, so it starts again.
    private var style: ListStyle?

    func assignment(for items: [GallerySummary], style: ListStyle, plan: LanePlan) -> LaneAssignment {
        if self.style != style {
            self.style = style
            assignment = LaneAssignment(laneCount: plan.lanes.count)
        }
        let laneWidth = plan.laneWidth
        assignment.sync(
            items.map { ($0.id, LaneAssignment.estimatedHeight(cover: $0.coverSize, style: style, laneWidth: laneWidth)) },
            laneCount: plan.lanes.count
        )
        return assignment
    }
}
