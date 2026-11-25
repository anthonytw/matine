import XCTest

/// Drives the app in the simulator with the Siri Remote, signed in as the dev
/// account (scripts/app.sh passes it as TEST_RUNNER_MATINE_DEV_*). Two jobs:
/// Apple's accessibility audit on each main screen, and a tour that saves a
/// screenshot per step for review (to MATINE_SHOTS, when set).
@MainActor
final class MatineUITests: XCTestCase {
    private var remote: XCUIRemote { .shared }

    override func setUp() async throws {
        continueAfterFailure = true
    }

    /// A library item id from the environment (`TEST_RUNNER_NAME=ID` on the
    /// xcodebuild command line): the tests that open one skip without it.
    private func libraryItem(_ name: String) throws -> String {
        guard let id = ProcessInfo.processInfo.environment[name], !id.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_\(name) to an item id from your dev server")
        }
        return id
    }

    private func launch(_ screen: String, language: String = "es-ES", role: String = "adult", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        let env = ProcessInfo.processInfo.environment
        for key in ["MATINE_DEV_SERVER", "MATINE_DEV_USER", "MATINE_DEV_PASSWORD"] {
            app.launchEnvironment[key] = env[key]
        }
        app.launchArguments = ["-MatineDevScreen", screen, "-MatineDevLanguage", language, "-MatineDevRole", role] + extra
        app.launch()
        return app
    }

    /// Under XCUITest the app opens with focus in the sidebar, even drawn
    /// collapsed (a normal launch opens on the content): Right moves in.
    private func enterContent() { press(.right) }

    private func settle(_ seconds: Double = 2.5) { Thread.sleep(forTimeInterval: seconds) }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["MATINE_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times {
            remote.press(button)
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    // MARK: Nearby sign-in

    /// A phone in "Entrar con un código" announces its code; the banner offers
    /// the open profile, and choosing it approves. Start the phone's
    /// testNearbyCodeSignIn first (or `matine quickconnect start --announce`);
    /// this waits up to two minutes for the announcement.
    func testApproveNearby() throws {
        guard ProcessInfo.processInfo.environment["MATINE_UITEST_NEARBY"] != nil else {
            throw XCTSkip("MATINE_UITEST_NEARBY is not set (needs a phone showing a code)")
        }
        let app = launch("home")
        let decline = app.buttons["Ahora no"]
        XCTAssertTrue(decline.waitForExistence(timeout: 120), "the sheet appears over browsing")
        settle(1.5)
        XCTAssertTrue(decline.hasFocus, "focus starts on Ahora no, so a stray press declines")
        shot("nearby-banner")
        // Deliberate: up to the profile, select; then a confirm step whose
        // focus starts on Cancelar; up to Aprobar, select.
        press(.up)
        press(.select)
        let approve = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Aprobar'")).firstMatch
        XCTAssertTrue(approve.waitForExistence(timeout: 10), "a confirm step follows the choice")
        settle(1.5)
        XCTAssertTrue(app.buttons["Cancelar"].hasFocus)
        shot("nearby-confirm")
        press(.up)
        press(.select)
        XCTAssertTrue(app.staticTexts["Aprobado. El otro dispositivo entrará en unos segundos."].waitForExistence(timeout: 20))
        shot("nearby-approved")
    }

    // MARK: Accessibility

    func testAccessibilityAudit() throws {
        for (screen, role) in [("picker", "adult"), ("home", "adult"), ("settings", "adult"), ("settings", "kid"), ("search", "adult")] {
            let app = launch(screen, role: role)
            settle(5)
            try audit(app, "\(screen) (\(role))")
            switch screen {
            case "home":
                // The first tile's page.
                enterContent()
                press(.select)
                settle(4)
                try audit(app, "detail")
            case "settings" where role == "adult":
                enterContent()
                press(.select)
                settle(2)
                try audit(app, "avatar editor")
            default:
                break
            }
        }
    }

    private func audit(_ app: XCUIApplication, _ screen: String) throws {
        try app.performAccessibilityAudit { issue in
            // tvOS's own search field (from `.searchable`) reports its
            // prompt as clipped; it isn't ours to change.
            if screen.hasPrefix("search"), issue.auditType == .textClipped { return true }
            let element = issue.element.map { "\($0.elementType.rawValue) “\($0.label)” \($0.frame)" } ?? "no element"
            XCTFail("\(screen): \(issue.compactDescription) · \(element)")
            return true
        }
    }

    // MARK: Tour

    func testTour() {
        let app = launch("home")
        settle(6)
        enterContent()
        shot("01-home")
        press(.down)
        settle(1.5)
        shot("02-home-down")
        press(.right)
        settle(1.5)
        shot("03-home-right")
        press(.menu)
        settle(1.5)
        shot("04-sidebar")
        press(.down, times: 2)
        shot("05-sidebar-down")
        press(.select)
        settle(3)
        shot("06-tab")
        _ = app
    }

    func testSettingsTour() {
        _ = launch("settings")
        settle(5)
        enterContent()
        shot("10-settings")
        press(.select)
        settle(2)
        shot("11-avatar-editor")
        press(.down)
        press(.select)
        settle(1)
        shot("12-new-robot")
        press(.down)
        press(.right, times: 2)
        press(.select)
        settle(1)
        shot("13-animal")
    }

    /// Every main screen once, for a design review.
    func testGallery() {
        let app = launch("home")
        settle(6)
        enterContent()
        settle(1.5)
        shot("g01-home")
        press(.right)
        settle(1.5)
        shot("g02-home-next-tile")
        press(.down)
        settle(1.5)
        shot("g03-home-row-2")
        press(.up)
        press(.select)
        settle(4)
        shot("g04-detail")
        press(.down)
        settle(1)
        shot("g05-detail-episodes")
        press(.menu)
        settle(1.5)
        // Sidebar as drawn: Inicio, Buscar, the profile, then the libraries.
        press(.menu)
        settle(1)
        shot("g06-sidebar")
        press(.down, times: 3)
        press(.select)
        settle(4)
        shot("g07-library")
        // Below the titles: Seguir viendo and Al azar.
        press(.down, times: 3)
        settle(2)
        shot("g07b-library-below")
        press(.up, times: 3)
        press(.menu)
        press(.up, times: 2)
        press(.select)
        settle(2)
        shot("g08-search")
        _ = app
    }

    /// Search typed into from the remote: grouped results, a typo, and
    /// (where the on-device model is there) the related row; audited too.
    func testSearch() throws {
        let app = launch("search")
        settle(6)
        let field = app.searchFields.firstMatch
        for (step, query) in ["dentista", "denitsta", "navidad"].enumerated() {
            enterContent()
            if step > 0 { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12)) }
            field.typeText(query)
            settle(3)
            press(.down)
            settle(1.5)
            shot("s\(step + 1)-\(query)")
            if step == 0 { try audit(app, "search results") }
            press(.menu)
            settle(1)
        }
    }

    /// A series page: the first screen, the surprise tile ahead of the row,
    /// then the list of every episode below it.
    func testSeriesPage() throws {
        let app = launch("search")
        settle(6)
        enterContent()
        app.searchFields.firstMatch.typeText("cuentos")
        settle(3)
        press(.down)
        press(.select)
        settle(5)
        shot("p1-series")
        // The backdrop takes the next picture in turn.
        settle(10)
        shot("p1b-series-later")
        press(.down)
        settle(1)
        let surprise = app.buttons["Un episodio al azar"].firstMatch
        for _ in 0..<12 where !surprise.hasFocus { press(.left) }
        settle(1)
        shot("p2-surprise")
        XCTAssertTrue(surprise.hasFocus)
        press(.down)
        settle(1.5)
        shot("p3-list")
        try audit(app, "series list")
        press(.down, times: 3)
        settle(1.5)
        shot("p4-list-down")
    }

    /// Cambiar nombre opens the keyboard at once, no moving to the field first.
    func testRenameOpensTheKeyboard() {
        let app = launch("manage")
        settle(5)
        enterContent()
        let rename = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Cambiar nombre'")).firstMatch
        for _ in 0..<12 where !rename.hasFocus { press(.down) }
        XCTAssertTrue(rename.hasFocus)
        press(.select)
        settle(2)
        shot("r1-rename")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
    }

    /// A film with a cast: the facts, the cast row below the first screen,
    /// and a person's page with what the library holds of theirs.
    func testCastAndPerson() throws {
        let app = launch("item:" + (try libraryItem("MATINE_TEST_FILM")))
        settle(6)
        enterContent()
        settle(1)
        shot("c1-film")
        press(.down)
        settle(2)
        shot("c2-cast-focused")
        let tile = app.buttons.matching(NSPredicate(format: "label CONTAINS ', como '")).firstMatch
        XCTAssertTrue(tile.exists, "a cast tile with its character in its label")
        press(.right, times: 2)
        settle(1)
        shot("c3-cast-scrolled")
        press(.left, times: 2)
        press(.select)
        settle(5)
        shot("c4-person")
        try audit(app, "person page")
        press(.down)
        settle(1.5)
        shot("c5-person-focus")
    }

    /// A series page: its cast sits below the episode list.
    func testSeriesCast() throws {
        let app = launch("item:" + (try libraryItem("MATINE_TEST_SERIES")))
        settle(7)
        enterContent()
        settle(1)
        shot("d1-series")
        // Down through the season row and the episode row to the list: a
        // wide button (one episode per line) takes focus.
        func listIsFocused() -> Bool {
            app.buttons.allElementsBoundByIndex.contains { $0.hasFocus && $0.frame.width > 900 }
        }
        for _ in 0..<8 where !listIsFocused() { press(.down) }
        settle(1.5)
        XCTAssertTrue(listIsFocused(), "focus reaches the episode list")
        shot("d2-list")
        // On down through the list to the cast row.
        func castIsFocused() -> Bool {
            app.buttons.matching(NSPredicate(format: "label CONTAINS ', como '")).allElementsBoundByIndex.contains { $0.hasFocus }
        }
        for _ in 0..<30 where !castIsFocused() { press(.down) }
        settle(1.5)
        XCTAssertTrue(castIsFocused(), "focus reaches the cast row below the episodes")
        shot("d3-after-list")
        XCTAssertTrue(app.staticTexts["Reparto"].exists)
    }

    /// A title with no metadata looks as it always did.
    func testNoMetadataTitle() throws {
        _ = launch("item:" + (try libraryItem("MATINE_TEST_BARE")))
        settle(6)
        enterContent()
        settle(1)
        shot("n1-plain")
        press(.down)
        settle(1)
        shot("n2-plain-down")
    }


    // MARK: Store screenshots

    /// The App Store and website shots (scripts/screenshots.sh tv): the local demo server
    /// (scripts/demo-server/), a made-up profile name, MATINE_SHOTS_LANG (en-US or es-ES), written to MATINE_SHOTS.
    func testStoreShots() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MATINE_SHOTS"] != nil else { throw XCTSkip("MATINE_SHOTS is not set (scripts/screenshots.sh sets it)") }
        let language = env["MATINE_SHOTS_LANG"] ?? "en-US"
        let who = ["-MatineDevName", "Ana", "-MatineDevOnlyItems", env["MATINE_SHOTS_ITEMS"] ?? ""]
        func start(_ screen: String, extra: [String] = []) -> XCUIApplication {
            launch(screen, language: language, extra: who + extra)
        }
        // 01-home
        var app = start("home")
        settle(14)
        enterContent()
        settle(2)
        shot("01-home")
        // 02-detail: a film (MATINE_SHOTS_DETAIL)
        app = start("item:" + (env["MATINE_SHOTS_DETAIL"] ?? ""))
        settle(12)
        enterContent()
        settle(2)
        shot("02-detail")
        // 03-series: a series (MATINE_SHOTS_SERIES), focus on its episode row
        app = start("item:" + (env["MATINE_SHOTS_SERIES"] ?? ""))
        settle(12)
        enterContent()
        press(.down)   // from Play onto the episode row: the header and the first episodes stay in view
        settle(2.5)
        shot("03-series")
        // 04-profiles: the picker with made-up housemates
        app = start("picker", extra: ["-MatineDevDemoProfiles", "YES"])
        settle(8)
        shot("04-profiles")
        // 05-search: MATINE_SHOTS_SEARCH ("animation" finds the animated open movies)
        app = start("search")
        settle(10)
        enterContent()
        app.searchFields.firstMatch.typeText(env["MATINE_SHOTS_SEARCH"] ?? "animation")
        settle(5)
        press(.down)
        settle(3)
        shot("05-search")
    }

    func testPicker() {
        _ = launch("picker")
        settle(4)
        shot("20-picker")
    }
}
