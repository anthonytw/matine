import XCTest

/// Drives the app in the simulator, signed in as the dev account
/// (scripts/mobile.sh uitest passes it as TEST_RUNNER_MATINE_DEV_*).
@MainActor
final class MatineMobileUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        for key in ["MATINE_DEV_SERVER", "MATINE_DEV_USER", "MATINE_DEV_PASSWORD"] {
            app.launchEnvironment[key] = env[key]
        }
        app.launchArguments = ["-MatineDevScreen", screen, "-MatineDevLanguage", "es-ES"]
        // MATINE_UITEST_SIZE=UICTContentSizeCategoryXXXL: a Dynamic Type size, for layout checks.
        if let size = env["MATINE_UITEST_SIZE"], !size.isEmpty {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", size]
        }
        app.launch()
        return app
    }

    /// A landscape store and website shot (scripts/screenshots.sh ipad): `simctl` cannot rotate a
    /// simulator, XCUIDevice can. MATINE_SHOTS is the folder, MATINE_SHOTS_FILE the name,
    /// MATINE_SHOTS_SCREEN the DebugLaunch screen, MATINE_SHOTS_LANG/ITEMS as on the TV.
    func testLandscapeShot() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["MATINE_SHOTS"] else { throw XCTSkip("MATINE_SHOTS is not set (scripts/screenshots.sh sets it)") }
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { XCUIDevice.shared.orientation = .portrait }   // also after a failure
        let app = XCUIApplication()
        for key in ["MATINE_DEV_SERVER", "MATINE_DEV_USER", "MATINE_DEV_PASSWORD"] {
            app.launchEnvironment[key] = env[key]
        }
        app.launchArguments = [
            "-MatineDevScreen", env["MATINE_SHOTS_SCREEN"] ?? "home", "-MatineDevLanguage", env["MATINE_SHOTS_LANG"] ?? "en-US",
            "-MatineDevName", "Ana", "-MatineDevOnlyItems", env["MATINE_SHOTS_ITEMS"] ?? "",
        ]
        app.launch()
        Thread.sleep(forTimeInterval: Double(env["MATINE_SHOTS_WAIT"] ?? "") ?? 14)   // sign-in, rows, posters
        let file = URL(fileURLWithPath: dir).appendingPathComponent((env["MATINE_SHOTS_FILE"] ?? "landscape") + ".png")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
    }

    /// Starts playing `item` and shows the system player's controls.
    private func playAndShowControls(_ item: String) -> XCUIApplication {
        let app = launch("play:\(item)")
        // Wait for the picture, then let it play a moment so there is a position to report.
        _ = app.otherElements["AVPlayerView"].waitForExistence(timeout: 60)
        Thread.sleep(forTimeInterval: 6)
        app.tap()
        return app
    }

    /// Home is on screen and reachable (it is covered while the player is up).
    private func homeVisible(_ app: XCUIApplication) -> Bool {
        let home = app.navigationBars["Inicio"]
        return home.exists && home.isHittable
    }

    private func waitForHome(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if homeVisible(app) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    private func requireItem() throws -> String {
        guard let item = ProcessInfo.processInfo.environment["MATINE_UITEST_ITEM"], !item.isEmpty else {
            throw XCTSkip("MATINE_UITEST_ITEM (an item id the dev account can play) is not set")
        }
        return item
    }

    /// The player has a way out: the system player's own close button (its
    /// identifier is "Close Button", labelled "Cerrar") shows with the
    /// controls and closes the player in one tap, returning to where it was
    /// opened from; the app is not left on a black screen. The Stopped report
    /// that goes with it is covered by PlaybackControllerTests in MatineKit.
    func testPlayThenClose() throws {
        let app = playAndShowControls(try requireItem())
        let close = app.buttons["Close Button"]
        XCTAssertTrue(close.waitForHittable(timeout: 10), "the system player shows its close button")
        XCTAssertEqual(close.label, "Cerrar")
        XCTAssertFalse(app.buttons["player.close"].exists, "no second close button of ours")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        close.tap()
        XCTAssertTrue(close.waitForDisappearance(timeout: 15), "one tap closes the player")
        XCTAssertTrue(app.navigationBars["Inicio"].waitForExistence(timeout: 15), "closing returns to Home")
    }

    /// A short drag down that is let go before the threshold cancels the
    /// system player's swipe-to-dismiss; the player must stay open. (If the
    /// player has no interactive dismissal this holds trivially.)
    func testCancelledSwipeDownKeepsPlaying() throws {
        let app = playAndShowControls(try requireItem())
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        from.press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        Thread.sleep(forTimeInterval: 2)
        app.tap()
        XCTAssertTrue(app.buttons["Close Button"].waitForExistence(timeout: 5), "the player is still open")
        XCTAssertFalse(homeVisible(app), "Home is still covered")
        app.buttons["Close Button"].tap()
        XCTAssertTrue(app.navigationBars["Inicio"].waitForExistence(timeout: 15))
    }

    /// Picture in Picture: starting it must not close the player (and so not
    /// send Stopped); "back to app" in the PiP window shows the player
    /// again; closing the PiP window closes it. Needs a simulator with a PiP
    /// button (iPad): MATINE_SIM="iPad Pro 11-inch (M5)" scripts/mobile.sh uitest testPictureInPicture ITEM.
    func testPictureInPicture() throws {
        let app = playAndShowControls(try requireItem())
        let pipButton = app.buttons["PIP Button"]
        guard pipButton.waitForHittable(timeout: 10) else { throw XCTSkip("this device has no Picture in Picture button (use an iPad simulator)") }
        XCTAssertFalse(homeVisible(app), "Home is covered while the player is up")
        pipButton.tap()
        let window = app.otherElements["PIPUIView"]
        XCTAssertTrue(window.waitForExistence(timeout: 15), "the PiP window opens")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(window.exists)
        XCTAssertFalse(homeVisible(app), "starting PiP did not close the player")
        // Back to the app: the player is shown again.
        window.tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.12)).tap()
        let close = app.buttons["Close Button"]
        if !close.waitForExistence(timeout: 10) { app.tap() }
        XCTAssertTrue(close.waitForHittable(timeout: 10), "the player is back after restoring")
        // And again into PiP, then close the PiP window: that closes the player.
        pipButton.tap()
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3)
        window.tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.12)).tap()
        XCTAssertTrue(window.waitForDisappearance(timeout: 15), "the PiP window closes")
        XCTAssertTrue(waitForHome(app, timeout: 10), "closing PiP closes the player")
    }

    /// "Reproducir en la tele" on a detail page sends the video to the Apple
    /// TV that has Matiné open (the tvOS simulator, signed in as the same
    /// account) and shows the "En la tele" bar. With no TV open it says so.
    func testPlayOnTV() throws {
        let item = try requireItem()
        let app = launch("item:\(item)")
        let button = app.buttons["detail.playOnTV"]
        XCTAssertTrue(button.waitForExistence(timeout: 60), "the page offers Play on TV")
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "detail"
        before.lifetime = .keepAlways
        add(before)
        button.tap()
        let bar = app.otherElements["detail.tvBar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 15), "the TV bar shows after sending")
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "sent"
        after.lifetime = .keepAlways
        add(after)
        // Let the TV start before the test goes on (the shell takes its screenshot).
        Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["MATINE_UITEST_HOLD"] ?? "") ?? 0)
        if ProcessInfo.processInfo.environment["MATINE_UITEST_EXPECT_DROP"] != nil {
            // The TV is stopped from outside: the bar goes away by itself (it asks every 15 seconds).
            XCTAssertTrue(bar.waitForDisappearance(timeout: 60), "the bar goes when the TV stops playing")
        } else {
            app.buttons["Detener en la tele"].tap()
            XCTAssertTrue(bar.waitForDisappearance(timeout: 15), "Stop on the TV removes the bar")
        }
    }

    /// "Entrar con un código" on a fresh install: the code is announced on the
    /// network, an Apple TV approves it (see testApproveNearby in the tvOS UI
    /// tests), and the phone signs in. Start the tvOS test first; this waits.
    func testNearbyCodeSignIn() throws {
        guard ProcessInfo.processInfo.environment["MATINE_UITEST_NEARBY"] != nil else {
            throw XCTSkip("MATINE_UITEST_NEARBY is not set (needs an Apple TV simulator approving)")
        }
        // A fresh install (the debug hook would sign the dev account in first,
        // making it a profile the phone already has) opens on sign-in; with
        // profiles it opens on the picker.
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(es-ES)", "-AppleLocale", "es_ES"]
        app.launch()
        let add = app.buttons["Añadir perfil"]
        if add.waitForExistence(timeout: 10) { add.tap() }
        // The server field starts empty: type the dev server (TEST_RUNNER_MATINE_DEV_SERVER).
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["MATINE_DEV_SERVER"].flatMap { $0.isEmpty ? nil : $0 },
                                   "set TEST_RUNNER_MATINE_DEV_SERVER to the dev server's address")
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 30))
        field.tap()
        field.typeText(server)
        let code = app.buttons.matching(NSPredicate(format: "label CONTAINS 'código'")).firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 30))
        code.tap()
        XCTAssertTrue(app.staticTexts["Tu código"].waitForExistence(timeout: 30))
        // A profile new to this phone says who it signed in as before landing
        // (with "No soy yo"); one already here lands straight on Home.
        let notMe = app.buttons["No soy yo"]
        let home = app.navigationBars["Inicio"]
        let deadline = Date().addingTimeInterval(180)
        while !notMe.exists && !home.exists && Date() < deadline { Thread.sleep(forTimeInterval: 1) }
        if notMe.exists {
            app.buttons["Continuar"].tap()
        }
        XCTAssertTrue(home.waitForExistence(timeout: 30), "the TV approved and the phone signed in")
    }

    func testHomeAndTabs() throws {
        let app = launch("home")
        XCTAssertTrue(app.navigationBars["Inicio"].waitForExistence(timeout: 30))
    }
}

private extension XCUIElement {
    func waitForDisappearance(timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    func waitForHittable(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "isHittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
