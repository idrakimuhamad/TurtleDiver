import XCTest

/// The update check's wiring: the four places a release can surface, the one
/// place its request is allowed to run, and the promise the pane does not make.
///
/// These read the source rather than the built app because the interesting
/// properties are *absences* — that the launch check does not block the launch,
/// that the request is not on the main actor, that the pane has no download
/// button — and an absence cannot be observed from a running process.
final class UpdateWiringTests: XCTestCase {

    private let appDelegate = "VPNConnect/AppDelegate.swift"
    private let mainView = "VPNConnect/MainView.swift"
    private let settingsManager = "VPNConnect/SettingsManager.swift"
    private let settingsCatalog = "VPNConnect/Views/SettingsCatalog.swift"
    private let settingsView = "VPNConnect/SettingsView.swift"
    private let model = "VPNConnect/Views/UpdateModel.swift"
    private let pane = "VPNConnect/Views/UpdatesView.swift"

    // MARK: - Launch

    /// The check runs at launch only if the user has left it on, only after the
    /// window exists, and never on the thread that has to paint it.
    func testTheLaunchCheckIsGatedAndRunsLastAndOffTheMainActor() throws {
        let code = try strippedCode(at: appDelegate)
        let launch = try body(of: "func applicationDidFinishLaunching", in: code)
        XCTAssertLessThan(launch.count, 8_000, "the slice must be the method, not the rest of the file")

        let gate = try XCTUnwrap(launch.range(of: "SettingsManager.shared.updatesCheckEnabled"),
                                 "the launch check must read the setting the user owns")
        let call = try XCTUnwrap(launch.range(of: "checkIfEnabled("),
                                 "the toggle has to reach the check")
        let task = try XCTUnwrap(launch.range(of: "Task {"),
                                 "an async check must not be awaited inline at launch")
        let window = try XCTUnwrap(launch.range(of: "resizeWindowForContent()"),
                                   "the window is still sized before the check")

        XCTAssertLessThan(task.lowerBound, call.lowerBound)
        // Last: a launch must never wait on the network, however briefly.
        XCTAssertLessThan(window.lowerBound, gate.lowerBound)
        XCTAssertLessThan(window.lowerBound, task.lowerBound)
    }

    /// One request, in a detached task. The transport waits on a semaphore
    /// around a socket; on the main actor that is a frozen window.
    func testTheRequestIsHandedToADetachedTask() throws {
        let code = try strippedCode(at: model)
        let check = try body(of: "public func check() async", in: code)
        XCTAssertLessThan(check.count, 4_000)

        let detached = try XCTUnwrap(check.range(of: "Task.detached"),
                                     "the request must not run on the main actor")
        let request = try XCTUnwrap(check.range(of: "checker.check(running: running)"),
                                    "the checker still makes the request")
        XCTAssertLessThan(detached.lowerBound, request.lowerBound,
                          "the request must be inside the detached task, not before it")
    }

    // MARK: - Where a release shows up

    func testTheMainWindowShowsABannerOnlyWhileThereIsAnOffer() throws {
        let code = try strippedCode(at: mainView)
        let view = try body(of: "var body: some View", in: code)
        XCTAssertLessThan(view.count, 4_000)

        XCTAssertNotNil(view.range(of: "if let offer = updates.offer"),
                        "the banner must be conditional — an update is not wallpaper")
        XCTAssertNotNil(code.range(of: "(NSApp.delegate as? AppDelegate)?.openSettingsRoute(.updates)"),
                        "the banner opens the pane that can explain itself")

        let banner = try body(of: "private func updateBanner", in: code)
        XCTAssertLessThan(banner.count, 3_000)
        // Nothing in this window installs anything.
        XCTAssertFalse(banner.contains("URLSession"), "the window must not download")
        XCTAssertFalse(banner.contains("installer"), "the window must not touch the release's files")
    }

    func testTheStatusItemGainsARowOnlyWhileThereIsAnOffer() throws {
        let code = try strippedCode(at: appDelegate)
        let menu = try body(of: "private func updateMenu", in: code)
        XCTAssertLessThan(menu.count, 8_000)

        let offer = try XCTUnwrap(menu.range(of: "if let offer = UpdateModel.shared.offer"),
                                  "the update row must be added only when there is an offer")
        let row = try XCTUnwrap(menu.range(of: "#selector(openUpdates)"),
                                "the row has to lead somewhere")
        XCTAssertLessThan(offer.lowerBound, row.lowerBound)

        // The row appears when the answer arrives and goes when it stops being
        // true, which means the menu is rebuilt on every change of phase.
        let bindings = try body(of: "private func setupBindings", in: code)
        XCTAssertNotNil(bindings.range(of: "UpdateModel.shared.$phase"),
                        "the menu must be rebuilt when the phase changes")
    }

    func testTheUpdatesPaneIsReachableFromTheSidebar() throws {
        let catalog = try strippedCode(at: settingsCatalog)
        XCTAssertNotNil(catalog.range(of: "route: .updates,"),
                        "the pane needs a catalog entry to appear in the sidebar")
        XCTAssertNotNil(catalog.range(of: "group: .application,"))

        let code = try strippedCode(at: settingsView)
        XCTAssertNotNil(code.range(of: "case .updates:\n            UpdatesView()"),
                        "the sidebar must dispatch to the pane")
    }

    // MARK: - The setting

    /// On by default, and remembered. `bool(forKey:)` cannot tell "off" from
    /// "never answered", and reading an unset key as off would ship the check
    /// disabled for every install that predates it.
    func testTheSettingIsOnByDefaultAndPersists() throws {
        let code = try strippedCode(at: settingsManager)

        XCTAssertNotNil(code.range(of: "static let updatesCheckEnabled = \"updatesCheckEnabled\""),
                        "the preference needs a key")
        XCTAssertNotNil(code.range(of: "updatesCheckEnabled = defaults.object(forKey: Keys.updatesCheckEnabled) as? Bool ?? true"),
                        "an absent key must read as on")
        XCTAssertNotNil(code.range(of: "@Published var updatesCheckEnabled: Bool = true"),
                        "the default is on")
        XCTAssertNotNil(code.range(of: "defaults.set(updatesCheckEnabled, forKey: Keys.updatesCheckEnabled)"),
                        "the choice must survive a relaunch")
    }

    // MARK: - What the pane promises

    /// This pane checks. It cannot download and it cannot install, so it must not
    /// offer to — the row that acts opens the release page, which is a thing that
    /// works today.
    func testThePaneChecksAndDoesNotPretendToInstall() throws {
        let code = try strippedCode(at: pane)

        XCTAssertNotNil(code.range(of: "Button(\"Open Release Page\")"),
                        "the acting row must be the one that works")
        XCTAssertFalse(code.contains("Button(\"Download"),
                       "there is no download path yet, so there must be no download button")
        XCTAssertFalse(code.contains("Button(\"Install"),
                       "there is no install path yet, so there must be no install button")
        XCTAssertFalse(code.contains("installer.url"),
                       "the pane must not fetch the release's files")
        XCTAssertFalse(code.contains("URLSession"), "the pane itself must not make requests")
    }

    /// The age line is redrawn on a clock, and it is drawn from *that* clock's
    /// date. A `TimelineView` whose closure ignored `context.date` would tick
    /// happily and re-draw the same frozen wording, which is the bug this pins:
    /// the pane said "Checked just now" while the check was eight minutes old.
    func testTheAgeLineIsRedrawnOnAClockRatherThanFrozenWhenDrawn() throws {
        let code = try strippedCode(at: pane)

        let clock = try XCTUnwrap(code.range(of: "TimelineView(.periodic(from: .now, by: 30))"),
                                  "the age line has to be redrawn on a clock")
        let drawn = try XCTUnwrap(code.range(of: "caption: model.checkedText(at: context.date)"),
                                  "the redraw must speak about the new date, not the one it was created with")
        XCTAssertLessThan(clock.lowerBound, drawn.lowerBound,
                          "the date must come from the clock that redraws the row")
        XCTAssertFalse(code.contains("caption: model.checkedText,"),
                       "no row may read the age from the frozen clock while the pane is open")
    }

    /// Both the check and its failures are the connection log's business, and
    /// the connection log carries request lines — so neither file may write to
    /// it, or a version number ends up beside a tunnel's diagnostics.
    func testTheUpdatePathNeverWritesToTheConnectionLog() throws {
        for path in [model, pane] {
            let code = try strippedCode(at: path)
            for forbidden in ["vpn.log", "debugOutput", "StartupLog", "VpnConnectionLogger", "logSend"] {
                XCTAssertFalse(code.contains(forbidden),
                               "\(path) must not write to \(forbidden)")
            }
        }
    }

    // MARK: Helpers

    /// The text of one declaration, from its declaration to the next one at the
    /// same indentation — the nearest, not the first pattern that matches.
    private func body(of declaration: String, in code: String) throws -> Substring {
        let start = try XCTUnwrap(code.range(of: declaration), "\(declaration) not found")
        let rest = code[start.upperBound...]
        let anchors = ["\n    func ", "\n    private func ", "\n    static func ",
                       "\n    public func ", "\n    var ", "\n    private var ",
                       "\n    @objc func ", "\n    @ViewBuilder"]
        let ends = anchors.compactMap { rest.range(of: $0)?.lowerBound }
        guard let end = ends.min() else { return rest }
        return rest[..<end]
    }

    private func strippedCode(at path: String) throws -> String {
        let text = try String(contentsOf: repoRoot.appendingPathComponent(path), encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
