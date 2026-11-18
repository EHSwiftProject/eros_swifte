import XCTest

/// UI tests for the "Tag Translations" section of the Settings page (browse B4a).
final class TagDatabaseSettingsTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Settings → "Tag Translations": nothing is downloaded and no result shows; Update Now asks GitHub, which the
    /// replay does not know (a 404, a known request outside the replay table), and the footer says it failed.
    @MainActor
    func testTagDatabaseSectionShowsTheUpdateResult() {
        let app = launchApp(replayingFixtures: true)
        selectTab("settings", in: app)
        let version = element("settings.tagDatabase.version", in: app)
        scrollUntilVisible(version, in: app)
        XCTAssertTrue(version.exists, "No Version row in Settings")
        XCTAssertTrue(
            version.label.contains("Not Downloaded") || (version.value as? String) == "Not Downloaded",
            "Version row reads \(version.label) / \(String(describing: version.value))"
        )
        XCTAssertFalse(element("settings.tagDatabase.result", in: app).exists)

        let update = element("settings.tagDatabase.update", in: app)
        scrollUntilVisible(update, in: app)
        update.tap()
        // The footer sits below the section: the lazy form builds it only once it is scrolled near.
        let result = element("settings.tagDatabase.result", in: app)
        scrollUntilVisible(result, in: app, attempts: 12)
        if !result.exists {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "element tree"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("No update result appeared")
            return
        }
        XCTAssertEqual(result.label, "Update failed. Check your connection.")

        let screenshot = XCTAttachment(screenshot: screenshotOfDisplayShowing(app))
        screenshot.name = "b4-settings"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
