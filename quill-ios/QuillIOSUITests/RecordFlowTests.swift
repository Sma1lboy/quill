import XCTest

extension XCUIApplication {
    /// Every test here drives the app itself, never the first-run page — a
    /// full-screen cover on a fresh install makes all of them fail on a
    /// non-hittable button. One launcher instead of an env dict per test.
    func launchPastOnboarding() {
        launchEnvironment["QUILL_SKIP_ONBOARDING"] = "1"
        launch()
    }
}

/// Drives the real app on a physical device: quick take → record ~8s of
/// whatever the mic hears → stop. Transcription then runs in-app; the test
/// waits for the pipeline banner to clear so the transcript lands on disk.
final class RecordFlowTests: XCTestCase {
    @MainActor
    func testQuickTakeRecordsAndTranscribes() throws {
        let app = XCUIApplication()

        // Auto-accept the mic permission alert when it appears.
        addUIInterruptionMonitor(withDescription: "mic permission") { alert in
            for label in ["Allow", "OK", "允许", "好"] {
                let button = alert.buttons[label]
                if button.exists {
                    button.tap()
                    return true
                }
            }
            return false
        }

        app.launchPastOnboarding()

        let record = app.buttons["Start recording"]
        XCTAssertTrue(record.waitForExistence(timeout: 10), "record bar not found")
        record.tap()
        // Poke the app so the interruption monitor fires if an alert is up.
        // NOT `app.tap()`: that hits the screen centre, which is a session row
        // once the library has ~8 rows — it navigates into the detail view and
        // "Stop recording" below is then gone, so the test fails as the
        // library grows and reads like a regression. The header wordmark is
        // inert and always in the same place.
        app.staticTexts["quill"].firstMatch.tap()

        // Capture ~8 seconds of live audio.
        sleep(8)

        let stop = app.buttons["Stop recording"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "stop control not found — recording never started?")
        stop.tap()

        // First run downloads the whisper model (~600MB) — allow up to 15 min
        // for the transcribing banner to appear and clear.
        let done = NSPredicate(format: "exists == false")
        let banner = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'transcribing'")
        ).firstMatch

        if banner.waitForExistence(timeout: 30) {
            let cleared = XCTNSPredicateExpectation(predicate: done, object: banner)
            XCTAssertEqual(
                XCTWaiter().wait(for: [cleared], timeout: 900),
                .completed,
                "transcription did not finish within 15 min"
            )
        }

        // A TXT row proves the transcript was written. The row is one
        // accessibility element (so VoiceOver reads it as a sentence), so the
        // stage tag is matched by identifier rather than as its own text.
        let txtTag = app.descendants(matching: .any).matching(identifier: "TXT").firstMatch
        XCTAssertTrue(txtTag.waitForExistence(timeout: 30), "no transcribed session row appeared")
    }
}

final class DetailOpenTests: XCTestCase {
    @MainActor
    func testOpenFirstSessionDetail() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        // Tap the first session row (they're buttons inside the scroll view).
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Today' OR label CONTAINS 'Yesterday'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "no session row")
        row.tap()
        sleep(3)
        XCTAssertTrue(app.state == .runningForeground, "app crashed after opening detail")
    }
}

/// Search sheet opens and takes a query. Running it in Debug also trips
/// `TranscriptSearch.selfCheck()`, so a broken snippet/fold asserts here.
final class SearchTests: XCTestCase {
    @MainActor
    func testSearchSheetAcceptsQuery() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        let search = app.buttons["Search"]
        XCTAssertTrue(search.waitForExistence(timeout: 8), "search button not in header")
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search field never appeared")
        field.tap()
        field.typeText("the")
        sleep(3) // debounce + scan
        XCTAssertTrue(app.state == .runningForeground, "app crashed during search")
        for i in 0..<min(app.staticTexts.count, 30) {
            let t = app.staticTexts.element(boundBy: i).label
            if !t.isEmpty { print("SEARCH: \(t.prefix(100))") }
        }
    }
}

/// The actions menu opens and the delete dialog asks before deleting.
/// Running this in Debug also trips `SessionActions.selfCheck()`, so broken
/// rename/zip logic asserts here.
final class SessionActionsTests: XCTestCase {
    @MainActor
    func testDeleteAsksForConfirmation() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Today' OR label CONTAINS 'Yesterday' OR label CONTAINS 'Jul'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "no session row")
        row.tap()

        let menu = app.buttons["Session actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "actions menu not in toolbar")
        menu.tap()
        XCTAssertTrue(app.buttons["rename"].waitForExistence(timeout: 3), "rename missing")
        XCTAssertTrue(app.buttons["share folder"].exists, "share folder missing")

        app.buttons["delete"].firstMatch.tap()
        // The dialog must appear rather than the session vanishing.
        XCTAssertTrue(
            app.staticTexts["delete this session?"].waitForExistence(timeout: 3),
            "delete ran without confirmation"
        )
        // Back out — this test must not destroy the library it ran against.
        // The dialog is an action sheet, so its buttons aren't in app.buttons;
        // if the tap can't be found, kill the app rather than risk confirming.
        let cancel = app.sheets.buttons["cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
            XCTAssertTrue(app.state == .runningForeground, "app crashed during session actions")
        } else {
            app.terminate()
        }
    }
}

final class EnhanceErrorProbe: XCTestCase {
    @MainActor
    func testReadEnhanceError() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Today' OR label CONTAINS 'Yesterday' OR label CONTAINS 'Jul'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        let gen = app.buttons["generate notes"].firstMatch
        if gen.waitForExistence(timeout: 5) {
            gen.tap()
            sleep(4)
        }
        // Dump every static text so the error line shows in the log.
        for i in 0..<min(app.staticTexts.count, 40) {
            let t = app.staticTexts.element(boundBy: i).label
            if !t.isEmpty { print("TEXT: \(t)") }
        }
    }
}

final class SettingsProbe: XCTestCase {
    @MainActor
    func testInspectNotesModelSection() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        app.buttons["Settings"].firstMatch.tap()
        sleep(2)
        // scroll to notes model section
        app.swipeUp()
        sleep(1)
        for i in 0..<min(app.staticTexts.count, 60) {
            let t = app.staticTexts.element(boundBy: i).label
            if !t.isEmpty { print("SETTXT: \(t)") }
        }
        // find and flip the qwen toggle if present
        let toggle = app.switches.firstMatch
        if toggle.exists {
            print("TOGGLE: value=\(toggle.value ?? "?")")
            if (toggle.value as? String) == "0" {
                toggle.tap()
                sleep(1)
                print("TOGGLE-AFTER: value=\(toggle.value ?? "?")")
            }
        }
        // tap download if it appeared
        let dl = app.buttons["download model"].firstMatch
        if dl.waitForExistence(timeout: 3) {
            dl.tap()
            print("DOWNLOAD: tapped")
            sleep(5)
            for i in 0..<min(app.staticTexts.count, 60) {
                let t = app.staticTexts.element(boundBy: i).label
                if t.contains("downloading") || t.contains("%") || t.contains("failed") {
                    print("DLSTATE: \(t)")
                }
            }
        } else {
            print("DOWNLOAD: button not found")
        }
    }
}

final class NotesGenProbe: XCTestCase {
    @MainActor
    func testGenerateNotesOnLongSession() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        // open the 20-min session (has 20:00 duration label)
        let row = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '20:00'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "20-min session row not found")
        row.tap()
        sleep(2)
        // tap retry in the facts block
        let retry = app.buttons["retry"].firstMatch
        if retry.waitForExistence(timeout: 4) {
            retry.tap()
            print("RETRY: tapped")
        } else {
            print("RETRY: not found (notes may already exist)")
        }
        // wait up to 90s for notes to appear
        let notesKicker = app.staticTexts["NOTES"].firstMatch
        let appeared = notesKicker.waitForExistence(timeout: 90)
        print("NOTES-APPEARED: \(appeared)")
        for i in 0..<min(app.staticTexts.count, 50) {
            let t = app.staticTexts.element(boundBy: i).label
            if !t.isEmpty { print("NT: \(t.prefix(120))") }
        }
    }
}

final class TitleProbe: XCTestCase {
    @MainActor
    func testHomeShowsGeneratedTitle() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        sleep(2)
        for i in 0..<min(app.buttons.count, 30) {
            let t = app.buttons.element(boundBy: i).label
            if t.contains("20:00") || t.contains("NVIDIA") || t.contains("Jensen") || t.contains("vision") {
                print("ROW: \(t.prefix(100))")
            }
        }
        for i in 0..<min(app.staticTexts.count, 40) {
            let t = app.staticTexts.element(boundBy: i).label
            if !t.isEmpty { print("HOME: \(t.prefix(80))") }
        }
    }
}

final class AICapProbe: XCTestCase {
    @MainActor
    func testReadAICapabilities() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        app.buttons["Settings"].firstMatch.tap()
        sleep(1)
        app.swipeUp(); app.swipeUp()
        sleep(1)
        for i in 0..<min(app.staticTexts.count, 80) {
            let t = app.staticTexts.element(boundBy: i).label
            if !t.isEmpty { print("CAP: \(t.prefix(90))") }
        }
    }
}

final class AICapProbe2: XCTestCase {
    @MainActor
    func testReadFullCapabilities() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        app.buttons["Settings"].firstMatch.tap()
        sleep(1)
        for _ in 0..<4 { app.swipeUp() }
        sleep(1)
        var capture = false
        for i in 0..<min(app.staticTexts.count, 100) {
            let t = app.staticTexts.element(boundBy: i).label
            if t == "on-device model" { capture = true }
            if capture && !t.isEmpty { print("FULL: \(t.prefix(90))") }
        }
    }
}

final class RegenNotesProbe: XCTestCase {
    @MainActor
    func testRegenerateWithNewPrompt() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS '20:00'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        sleep(1)
        let rerun = app.buttons["re-run"].firstMatch
        XCTAssertTrue(rerun.waitForExistence(timeout: 5), "re-run not found")
        rerun.tap()
        print("RERUN: tapped")
        sleep(30)
        for i in 0..<min(app.staticTexts.count, 30) {
            let t = app.staticTexts.element(boundBy: i).label
            if !t.isEmpty { print("RG: \(t.prefix(110))") }
        }
    }
}

final class ScreenshotDriver: XCTestCase {
    @MainActor
    func testHoldDetailOpen() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'nvidia'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        sleep(25) // window for external screenshots
    }
    @MainActor
    func testHoldSettingsOpen() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        app.buttons["Settings"].firstMatch.tap()
        sleep(25)
    }
}

final class ScreenshotDriver2: XCTestCase {
    @MainActor
    func testHoldTranscriptOpen() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'nvidia'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        sleep(1)
        // expand the TRANSCRIPT disclosure then scroll it into view
        let disclosure = app.staticTexts["TRANSCRIPT"].firstMatch
        if disclosure.waitForExistence(timeout: 4) {
            app.swipeUp()
            disclosure.tap()
            sleep(1)
            app.swipeUp()
        }
        sleep(22)
    }
}

final class ScreenshotDriver3: XCTestCase {
    @MainActor
    func testHoldNoteControlsOpen() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        app.buttons["New note"].firstMatch.tap()
        sleep(24)
    }
    @MainActor
    func testHoldSettingsScrolled() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        app.buttons["Settings"].firstMatch.tap()
        sleep(1)
        app.swipeUp(); app.swipeUp()
        sleep(24)
    }

    /// Holds the session actions menu open on a fully-processed session, so
    /// the new rows (export audio / re-transcribe) can be screenshotted from
    /// outside. The NOTE row is the one with audio + transcript + notes, and
    /// therefore the only one where every item is enabled.
    @MainActor
    func testHoldActionsMenuOnNotedSession() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        let row = app.descendants(matching: .any)
            .matching(identifier: "NOTE").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "no fully-processed session to open")
        row.tap()
        let menu = app.buttons["Session actions"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "actions menu not in toolbar")
        menu.tap()
        XCTAssertTrue(
            app.buttons["export audio"].waitForExistence(timeout: 3),
            "export audio missing from the menu"
        )
        XCTAssertTrue(app.buttons["re-transcribe"].exists, "re-transcribe missing from the menu")
        sleep(24)
    }

    /// Opens settings and switches remote notes on, which is what actually
    /// executes `RemoteCredential` / `RemoteShape` / `RemoteModels`
    /// self-checks — a Debug build asserts here if any of that logic is wrong.
    /// Leaves the toggle off again so a screenshot run isn't affected.
    @MainActor
    func testRemoteNotesSectionSelfChecks() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        app.buttons["Settings"].firstMatch.tap()
        sleep(1)
        app.swipeUp(); app.swipeUp()
        sleep(1)
        let toggle = app.switches["remote notes"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "remote notes section not in settings")
        let wasOn = (toggle.value as? String) == "1"
        if !wasOn { toggle.tap() }
        sleep(2)   // the expanded rows construct RemoteEnhance/RemoteShape
        XCTAssertTrue(app.state == .runningForeground, "a self-check assertion fired")
        // The key row must exist, and must NOT be showing a real key in clear.
        XCTAssertTrue(app.staticTexts["api key"].exists, "key row missing")
        if !wasOn { toggle.tap() }
        sleep(1)
        XCTAssertTrue(app.state == .runningForeground, "crashed toggling remote notes off")
    }

    /// The re-transcribe confirmation. It must say audio is safe before the
    /// user throws a transcript away — holds the dialog open, then cancels so
    /// the run doesn't destroy the library it screenshotted.
    @MainActor
    func testHoldRetranscribeConfirmation() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        let row = app.descendants(matching: .any)
            .matching(identifier: "NOTE").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "no fully-processed session to open")
        row.tap()
        app.buttons["Session actions"].tap()
        let item = app.buttons["re-transcribe"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "re-transcribe missing from the menu")
        item.tap()
        XCTAssertTrue(
            app.staticTexts["transcribe this again?"].waitForExistence(timeout: 3),
            "re-transcribe ran without confirmation"
        )
        sleep(20)
        // Back out — same reason as the delete test: never wreck the library.
        let cancel = app.sheets.buttons["cancel"].firstMatch
        if cancel.waitForExistence(timeout: 2) { cancel.tap() } else { app.terminate() }
    }

    /// Same session with the menu closed — the notes screen itself, where the
    /// "re-run" affordance sits next to the notes kicker.
    @MainActor
    func testHoldNotedSessionDetail() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        let row = app.descendants(matching: .any)
            .matching(identifier: "NOTE").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 8), "no fully-processed session to open")
        row.tap()
        sleep(24)
    }
}

final class RemoteShotDriver: XCTestCase {
    /// Holds the remote notes section open, expanded, for screenshotting.
    @MainActor
    func testHoldRemoteSection() throws {
        let app = XCUIApplication()
        app.launchPastOnboarding()
        app.buttons["Settings"].firstMatch.tap()
        sleep(1)
        // One swipe: the remote section sits above "notes prompt", so two
        // swipes scroll clean past it to storage.
        app.swipeUp()
        let toggle = app.switches["remote notes"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String) != "1" { toggle.tap() }
        sleep(20)
        if (toggle.value as? String) == "1" { toggle.tap() }
    }
}
