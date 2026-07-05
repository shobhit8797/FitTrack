import XCTest

// Scripted walkthrough for the marketing screen recording. Launches the app in
// demo mode (seeded, no-backend data — see DemoData.swift) and drives an
// unhurried tour through Today → Workout → Diet → Progress → the Log hub, with
// deliberate pauses so a simultaneous `simctl io recordVideo` capture reads as a
// smooth product demo. This is a capture harness, not a correctness test.
final class DemoWalkthrough: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        app.launchEnvironment["FITTRACK_DEMO"] = "1"
        app.launch()
    }

    func testDemoWalkthrough() {
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 40), "Demo main tabs should appear")
        hold(3.0) // let the Today hero + rings animate in

        // ── Today: hero, macros, activity, meal timeline ──
        app.swipeUp();   hold(1.7)
        app.swipeUp();   hold(1.7)
        app.swipeDown(); hold(0.7)
        app.swipeDown(); hold(1.6)

        // ── Workout: AI plan, day selector, exercises ──
        tap(tabBar.buttons["Workout"]); hold(2.6)
        tapIfExists(app.buttons["Lower A"]); hold(1.9)
        tapIfExists(app.buttons["Upper B"]); hold(1.9)
        app.swipeUp();   hold(1.7)
        app.swipeUp();   hold(1.7)
        app.swipeDown(); hold(1.0)

        // ── Diet: 7-day AI meal plan, day picker ──
        tap(tabBar.buttons["Diet"]); hold(2.6)
        tapIfExists(app.buttons["Wednesday"]); hold(1.9)
        tapIfExists(app.buttons["Saturday"]);  hold(1.9)
        app.swipeUp();   hold(1.7)
        app.swipeUp();   hold(1.7)
        app.swipeDown(); hold(1.0)

        // ── Progress: weight trend, calories, adherence, lifts ──
        tap(tabBar.buttons["Progress"]); hold(2.6)
        hold(1.4)
        app.swipeUp(); hold(1.8)
        tapIfExists(app.buttons["3M"]); hold(1.6)
        app.swipeUp(); hold(1.8)
        app.swipeUp(); hold(1.8)
        app.swipeUp(); hold(1.6)
        app.swipeDown(); hold(0.8)

        // ── The ➕ Log hub launcher ──
        tap(tabBar.buttons["Log"]); hold(2.8)
        tapIfExists(app.buttons["Close"]); hold(1.2)

        // ── Land back on Today ──
        tap(tabBar.buttons["Today"]); hold(3.0)
    }

    // MARK: Helpers

    private func hold(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    private func tap(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 5) { element.tap() }
    }

    /// Tap only if present — day bubbles / range segments vary by the current
    /// date, so a missing one should never abort the tour.
    private func tapIfExists(_ element: XCUIElement) {
        if element.waitForExistence(timeout: 3), element.isHittable { element.tap() }
    }
}
