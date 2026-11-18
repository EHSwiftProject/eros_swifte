import EHModels
import EHNetwork
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The image search page (search Q5; Flutter `search_image_page.dart`), identified `imageSearch.root`, titled
/// `Image Search` (inline), pushed by value from the search page's Image Search (`ImageSearchRoute.search`).
///
/// - Image: the image picked (`imageSearch.preview`, whole: `scaledToFit`, at most 240 pt high), a spinner while it is
///   being made ready or searched with, then Choose from Photos (`imageSearch.photos`, the original bytes) and Choose
///   from Files (`imageSearch.files`, any image file). A footnote says when the image was converted to a JPEG, which
///   only finds similar images.
/// - Options: Use Similarity Scan (`imageSearch.similar`, on), Only Search Covers (`imageSearch.covers`) and Show
///   Expunged (`imageSearch.expunged`), both off.
/// - The toolbar's Search (`imageSearch.submit`, primary) is disabled without an image, while one is being made ready
///   and while a search is out; meanwhile the two ways to pick and the three switches are disabled too. A search that
///   finds the results pushes them by value (`ImageSearchRoute.results`) once, onto the tab selected when Search was
///   tapped, even if another is selected by then; coming back, the image and the switches
///   are as they were. A failure is told in the app's alerts (`Image Search Failed`).
///
/// DEBUG: a UI test launch with `-EROS_UI_TEST_IMAGE 1` (`TestSwitches.uiTestImage`) picks an 8×8 PNG drawn here when
/// the page first appears.
struct ImageSearchView: View {
    @Environment(AppEnvironment.self) private var environment
    private let site: EHSite

    init(site: EHSite) {
        self.site = site
    }

    var body: some View {
        ImageSearchPage(environment: environment, site: site)
    }
}

/// The footnote under the image when it was converted to a JPEG (`imageSearch.converted`), clear of the Duo's fold
/// (`keepsClearOfFold(alignment:)`, D2) and leading as a footnote is.
struct ImageSearchConvertedNote: View {
    var body: some View {
        Text("Converted to JPEG for upload, so only similar images can match, not this exact file.")
            .accessibilityIdentifier("imageSearch.converted")
            .keepsClearOfFold(alignment: .leading)
    }
}

/// The page over its model, made once with the page: the stack's destination runs again
/// with every update, so a model made there would be made again and the image picked lost. It takes the environment
/// from its parent for `State(initialValue:)`.
private struct ImageSearchPage: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: ImageSearchModel
    /// The photo just picked in Photos, until its bytes are asked for.
    @State private var photo: PhotosPickerItem?
    @State private var isPickingFile = false
    /// The tab selected when Search was last tapped: the search's results go onto its stack.
    @State private var searchTab: AppTab?
    #if DEBUG
    /// The test image was picked once (`TestSwitches.uiTestImage`); coming back to the page does not pick it again.
    @State private var hasPickedTestImage = false
    #endif

    init(environment: AppEnvironment, site: EHSite) {
        let service = environment.service
        _model = State(initialValue: ImageSearchModel(site: site) { data, format, options in
            try await service.imageLookup(image: data, format: format, options: options, site: site)
        })
    }

    var body: some View {
        @Bindable var model = model
        Form {
            imageSection
            Section("Options") {
                Toggle("Use Similarity Scan", isOn: $model.options.similar)
                    .accessibilityIdentifier("imageSearch.similar")
                Toggle("Only Search Covers", isOn: $model.options.coversOnly)
                    .accessibilityIdentifier("imageSearch.covers")
                Toggle("Show Expunged", isOn: $model.options.includeExpunged)
                    .accessibilityIdentifier("imageSearch.expunged")
            }
            // A search that is out was sent with the image and the switches shown, so they stay as they are until it
            // ends.
            .disabled(model.isSearching)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("imageSearch.root")
        .navigationTitle("Image Search")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                searchButton
            }
        }
        .fileImporter(isPresented: $isPickingFile, allowedContentTypes: [.image]) { result in
            pickFile(result)
        }
        .onChange(of: photo) { _, item in
            pickPhoto(item)
        }
        .onChange(of: model.result) { _, result in
            pushResults(result)
        }
        .onChange(of: model.failureMessage) { _, message in
            showFailure(message)
        }
        .task {
            await pickTestImage()
        }
    }

    private var imageSection: some View {
        Section {
            if model.isPreparing {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("imageSearch.preparing")
            } else if let preview = model.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 240)
                    .accessibilityLabel("Chosen Image")
                    .accessibilityIdentifier("imageSearch.preview")
            }
            if model.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("imageSearch.searching")
            }
            PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle")
            }
            .disabled(model.isSearching)
            .accessibilityIdentifier("imageSearch.photos")
            Button("Choose from Files", systemImage: "folder") {
                isPickingFile = true
            }
            .disabled(model.isSearching)
            .accessibilityIdentifier("imageSearch.files")
        } header: {
            Text("Image")
        } footer: {
            if model.image?.wasReencoded == true {
                ImageSearchConvertedNote()
            }
        }
    }

    /// Search: the image with the switches. The tab selected at the tap is kept for the results.
    private var searchButton: some View {
        Button("Search", systemImage: "magnifyingglass") {
            searchTab = environment.router.selectedTab
            let model = model
            Task { await model.search() }
        }
        .disabled(!model.canSearch)
        .accessibilityIdentifier("imageSearch.submit")
    }

    /// The photo picked: its original bytes (`preferredItemEncoding: .current`), asked for by the model, so a later
    /// pick wins over a photo still loading. The selection is cleared, so the same photo can be picked again.
    private func pickPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        photo = nil
        let model = model
        Task {
            await model.choose { try await item.loadTransferable(type: Data.self) }
        }
    }

    /// The file picked; a picker that failed (not cancelled) is told as a file that is not an image.
    private func pickFile(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let model = model
            Task { await model.chooseFile(at: url) }
        case .failure(let error):
            if (error as? CocoaError)?.code != .userCancelled {
                model.failureMessage = ImageSearchModel.notAnImageMessage
            }
        }
    }

    /// Pushes the results of a search by value, once, onto the stack of the tab Search was tapped on (`searchTab`),
    /// and clears them from the model.
    private func pushResults(_ result: ImageLookupResult?) {
        guard let result else { return }
        model.result = nil
        let router = environment.router
        let results = ImageSearchResults(result: result, site: model.site)
        // Search sets `searchTab` before the results can come; the fallback only keeps a Release build going.
        assert(searchTab != nil, "image search results came without the tab Search was tapped on")
        router.push(.results(results), onto: searchTab ?? router.selectedTab)
    }

    /// Tells `message` in the app's alerts (`AlertCenter`); its OK clears it from the model.
    private func showFailure(_ message: String?) {
        guard let message else { return }
        let model = model
        environment.alerts.present(HostedAlert(
            title: "Image Search Failed", message: message,
            actions: [HostedAlert.Action("OK") { model.failureMessage = nil }]
        ))
    }

    /// DEBUG, a UI test launch with `-EROS_UI_TEST_IMAGE 1` only: picks `testImage()`, once.
    private func pickTestImage() async {
        #if DEBUG
        guard !hasPickedTestImage, AppEnvironment.isUITestingLaunch,
              UserDefaults.standard.bool(forKey: TestSwitches.uiTestImage.description) else { return }
        hasPickedTestImage = true
        await model.choose(Self.testImage())
        #endif
    }

    #if DEBUG
    /// An 8×8 PNG of one colour, drawn here: no Photos library, no file.
    private static func testImage() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 8, height: 8)
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
    #endif
}
