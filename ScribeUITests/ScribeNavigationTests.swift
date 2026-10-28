import XCTest

@MainActor
final class ScribeNavigationTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        try super.setUpWithError()
        if name.contains("testCaptureAppStoreScreenshots") {
            try XCTSkipUnless(ProcessInfo.processInfo.environment["SCRIBE_CAPTURE_STORE_SCREENSHOTS"] == "1",
                              "Enable the explicit App Store screenshot capture run")
        }
        continueAfterFailure = false
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "ui-test-fixture")
            .firstMatch.waitForExistence(timeout: 15), "UI tests require the isolated DEBUG fixture")
    }

    private func openTab(_ name: String) {
        let nativeTab = app.tabBars.buttons[name]
        let tab = nativeTab.exists ? nativeTab : app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", name)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "Missing \(name) tab\n\(app.debugDescription)")
        tab.tap()
    }

    func testTabsAndItemForm() {
        openTab("Items")
        let add = app.buttons["items.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("QA")
        XCTAssertEqual(name.value as? String, "QA")
        preserveOrientation()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(name.value as? String, "QA")
        attachScreenshot("Item form in portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(name.value as? String, "QA")
        attachScreenshot("Item form in landscape")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        openTab("Settings")
        XCTAssertTrue(app.staticTexts["Default Period Range"].waitForExistence(timeout: 10))
        openTab("Dashboard")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "This week")).firstMatch
            .waitForExistence(timeout: 10))
        attachScreenshot("Dashboard navigation")
    }

    func testPaymentUpdatesInsights() {
        openTab("Dashboard")
        let reviewed = app.staticTexts["dashboard.reviewed-count"]
        XCTAssertTrue(reviewed.waitForExistence(timeout: 10), "Weekly check-in must remain available in every layout")
        let remaining = app.staticTexts["dashboard.remaining"]
        let initialReviewed = reviewed.label
        let initialAmount = remaining.label
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND value == %@", "Mark as paid", "pending")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        let paymentID = confirm.identifier
        confirm.tap()
        let undo = app.buttons[paymentID]
        XCTAssertTrue(undo.waitForExistence(timeout: 10))
        XCTAssertEqual(undo.label, "Undo paid")
        let reviewedChanged = NSPredicate(format: "label != %@", initialReviewed)
        expectation(for: reviewedChanged, evaluatedWith: reviewed)
        waitForExpectations(timeout: 10)
        XCTAssertNotEqual(remaining.label, initialAmount)
        attachScreenshot("Insights after confirming a payment")
        undo.tap()
        expectation(for: NSPredicate(format: "label == %@", initialReviewed), evaluatedWith: reviewed)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(remaining.label, initialAmount)
    }

    func testExpandedWeekSurvivesRotation() {
        openTab("Dashboard")
        let previous = app.buttons["week.past"].firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 10))
        XCTAssertEqual(previous.value as? String, "Collapsed")
        previous.tap()
        expectation(for: NSPredicate(format: "value == %@", "Expanded"), evaluatedWith: previous)
        waitForExpectations(timeout: 10)
        preserveOrientation()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(previous.value as? String, "Expanded")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(previous.value as? String, "Expanded")
    }

    private func preserveOrientation() {
        let original = XCUIDevice.shared.orientation
        let restore = [.portrait, .portraitUpsideDown, .landscapeLeft, .landscapeRight]
            .contains(original) ? original : .portrait
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.orientation = restore }
        }
    }

    func testCaptureAppStoreScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SCRIBE_CAPTURE_STORE_SCREENSHOTS"] == "1",
                          "Enable the explicit App Store screenshot capture run")
        openTab("Dashboard")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "This week"))
            .firstMatch.waitForExistence(timeout: 10))
        try requestStoreCapture("01-dashboard")
        openTab("Items")
        XCTAssertTrue(app.buttons["items.add"].waitForExistence(timeout: 10))
        try requestStoreCapture("02-items")
        let item = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "budget-item.")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()
        XCTAssertTrue(app.buttons["Edit"].waitForExistence(timeout: 10))
        try requestStoreCapture("03-detail")
    }

    private func requestStoreCapture(_ stage: String) throws {
        let session = try XCTUnwrap(ProcessInfo.processInfo.environment["SCRIBE_CAPTURE_SESSION"],
                                   "Use capture_store_screenshots.py for full-frame App Store captures")
        _ = try XCTUnwrap(UUID(uuidString: session), "Invalid screenshot session")
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let folder = documents.appendingPathComponent("AppStoreCapture", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = folder.appendingPathComponent("\(session).request")
        let acknowledgement = folder.appendingPathComponent("\(session).\(stage).ack")
        _ = app.screenshot()
        try stage.write(to: request, atomically: true, encoding: .utf8)
        let deadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: acknowledgement.path) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: acknowledgement.path),
                      "Screenshot host did not capture \(stage)")
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
