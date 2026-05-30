import AppKit
import XCTest
@testable import VibestickApp

@MainActor
final class MacPetPanelEndToEndTests: XCTestCase {
    func testWalkingPanelMovesRightFromLeftWalkEdge() throws {
        guard let screen = NSScreen.main else {
            throw XCTSkip("No screen is available for pet panel end-to-end testing.")
        }

        let defaults = UserDefaults.standard
        let previousWalkingValue = defaults.object(forKey: "VibestickPetWalkingEnabled")
        let previousOriginX = defaults.object(forKey: "VibestickPetWindowOriginX")
        let previousOriginY = defaults.object(forKey: "VibestickPetWindowOriginY")
        let previousScale = defaults.object(forKey: "VibestickPetWindowScale")
        defer {
            restore(previousWalkingValue, forKey: "VibestickPetWalkingEnabled", in: defaults)
            restore(previousOriginX, forKey: "VibestickPetWindowOriginX", in: defaults)
            restore(previousOriginY, forKey: "VibestickPetWindowOriginY", in: defaults)
            restore(previousScale, forKey: "VibestickPetWindowScale", in: defaults)
        }

        defaults.set(true, forKey: "VibestickPetWalkingEnabled")
        defaults.removeObject(forKey: "VibestickPetWindowOriginX")
        defaults.removeObject(forKey: "VibestickPetWindowOriginY")
        defaults.removeObject(forKey: "VibestickPetWindowScale")

        let panel = makePanel()
        defer { panel.close() }

        let bounds = MacPetWalkGeometry.walkBounds(
            visibleFrame: screen.visibleFrame,
            panelWidth: panel.frame.width)
        let startOrigin = NSPoint(
            x: bounds.minX,
            y: screen.visibleFrame.minY + 16)
        panel.setFrameOrigin(startOrigin)
        panel.orderFrontRegardless()
        panel.startWalking()
        let start = Date()

        let moved = waitUntil(timeout: 1.5) {
            panel.advanceWalkingForTesting(at: Date())
            return panel.frame.origin.x > startOrigin.x + 8
        }
        panel.advanceWalkingForTesting(at: start.addingTimeInterval(2.0))

        XCTAssertTrue(
            moved || panel.frame.origin.x > startOrigin.x + 8,
            "Expected walking pet panel to move right from \(startOrigin.x), but it stayed at \(panel.frame.origin.x).")
    }

    func testPanelRestoresSavedScale() {
        let defaults = UserDefaults.standard
        let snapshot = saveDefaults(
            "VibestickPetWindowOriginX",
            "VibestickPetWindowOriginY",
            "VibestickPetWindowScale")
        defer { restore(snapshot, in: defaults) }

        defaults.set(140, forKey: "VibestickPetWindowOriginX")
        defaults.set(180, forKey: "VibestickPetWindowOriginY")
        defaults.set(1.25, forKey: "VibestickPetWindowScale")

        let panel = makePanel()
        defer { panel.close() }

        XCTAssertEqual(panel.petScale, 1.25, accuracy: 0.0001)
        XCTAssertEqual(panel.frame.width, 445, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, 595, accuracy: 0.5)
    }

    func testResizingClampsFrameInsideVisibleScreen() throws {
        guard !NSScreen.screens.isEmpty else {
            throw XCTSkip("No screen is available for pet panel end-to-end testing.")
        }

        let defaults = UserDefaults.standard
        let snapshot = saveDefaults(
            "VibestickPetWalkingEnabled",
            "VibestickPetWindowOriginX",
            "VibestickPetWindowOriginY",
            "VibestickPetWindowScale")
        defer { restore(snapshot, in: defaults) }

        defaults.set(false, forKey: "VibestickPetWalkingEnabled")
        defaults.removeObject(forKey: "VibestickPetWindowOriginX")
        defaults.removeObject(forKey: "VibestickPetWindowOriginY")
        defaults.removeObject(forKey: "VibestickPetWindowScale")

        let panel = makePanel()
        defer { panel.close() }
        guard let screen = panel.screen ?? NSScreen.main else {
            throw XCTSkip("No screen is available for pet panel end-to-end testing.")
        }

        panel.setFrameOrigin(NSPoint(
            x: screen.visibleFrame.maxX - panel.frame.width + 20,
            y: screen.visibleFrame.maxY - panel.frame.height + 20))
        panel.beginResizing()
        panel.resize(byDragDelta: NSPoint(x: 55, y: 20))
        panel.finishResizing()

        XCTAssertEqual(panel.petScale, 1.25, accuracy: 0.0001)
        let containingVisibleFrame = NSScreen.screens
            .map(\.visibleFrame)
            .first { $0.insetBy(dx: -0.5, dy: -0.5).contains(panel.frame) }
        XCTAssertNotNil(containingVisibleFrame, "Expected resized frame to fit on a visible screen: \(panel.frame)")
    }

    func testResetPositionKeepsSavedScale() {
        let defaults = UserDefaults.standard
        let snapshot = saveDefaults(
            "VibestickPetWalkingEnabled",
            "VibestickPetWindowOriginX",
            "VibestickPetWindowOriginY",
            "VibestickPetWindowScale")
        defer { restore(snapshot, in: defaults) }

        defaults.set(false, forKey: "VibestickPetWalkingEnabled")
        defaults.set(120, forKey: "VibestickPetWindowOriginX")
        defaults.set(120, forKey: "VibestickPetWindowOriginY")
        defaults.set(0.75, forKey: "VibestickPetWindowScale")

        let panel = makePanel()
        defer { panel.close() }

        panel.resetPetPosition()

        XCTAssertEqual(panel.petScale, 0.75, accuracy: 0.0001)
        XCTAssertEqual(defaults.double(forKey: "VibestickPetWindowScale"), 0.75, accuracy: 0.0001)
    }

    func testResizeHandleVisibilityCanBeDrivenByHoverState() {
        let panel = makePanel()
        defer { panel.close() }

        XCTAssertFalse(panel.isResizeHandleVisible)

        panel.setResizeHandleHovering(true)
        XCTAssertTrue(panel.isResizeHandleVisible)

        panel.setResizeHandleHovering(false)
        XCTAssertFalse(panel.isResizeHandleVisible)
    }

    func testResizeHandleHitTestUsesRenderedPetSpriteBottomRight() {
        let defaults = UserDefaults.standard
        let snapshot = saveDefaults(
            "VibestickPetCardDisplayMode",
            "VibestickPetWindowScale")
        defer { restore(snapshot, in: defaults) }

        defaults.set("compact", forKey: "VibestickPetCardDisplayMode")
        defaults.set(1.0, forKey: "VibestickPetWindowScale")

        let panel = makePanel()
        defer { panel.close() }
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))

        let handleFrame = panel.resizeHandleFrameForTesting()
        let contentBounds = panel.contentView?.bounds ?? NSRect(origin: .zero, size: panel.frame.size)

        XCTAssertLessThan(
            handleFrame.maxX,
            contentBounds.maxX - 40,
            "Expected the resize handle to anchor to the rendered pet, not the transparent panel edge.")
        XCTAssertGreaterThan(
            handleFrame.minY,
            contentBounds.minY + 70,
            "Expected the resize handle to anchor to the rendered pet, not the transparent panel bottom.")
        XCTAssertTrue(
            panel.isResizeHandleHitForTesting(at: NSPoint(x: handleFrame.midX, y: handleFrame.midY)),
            "Expected the rendered pet lower-right handle to enter resize mode.")
        XCTAssertTrue(
            panel.isResizeHandleHitForTesting(at: NSPoint(x: handleFrame.maxX + 2, y: handleFrame.minY - 2)),
            "Expected handle padding to remain resizeable.")
        XCTAssertFalse(
            panel.isResizeHandleHitForTesting(at: NSPoint(x: handleFrame.minX - 44, y: handleFrame.midY)),
            "Expected lower middle/left pet area to keep the existing move behavior.")
        XCTAssertFalse(
            panel.isResizeHandleHitForTesting(at: NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)),
            "Expected the panel body to keep the existing move behavior.")
    }

    func testPanelLoadsAndAppliesActionFrequencySettings() {
        let defaults = UserDefaults.standard
        let snapshot = saveDefaults(
            "VibestickPetRandomActionFrequency",
            "VibestickPetWalkSpeedMultiplier",
            "VibestickPetWanderFrequency")
        defer { restore(snapshot, in: defaults) }

        defaults.set(0.05, forKey: "VibestickPetRandomActionFrequency")
        defaults.set(0.7, forKey: "VibestickPetWalkSpeedMultiplier")
        defaults.set(1.3, forKey: "VibestickPetWanderFrequency")

        let panel = makePanel()
        defer { panel.close() }

        XCTAssertEqual(panel.petActionFrequencySettings.randomActionFrequency, 0.05, accuracy: 0.0001)
        XCTAssertEqual(panel.petActionFrequencySettings.walkSpeedMultiplier, 0.7, accuracy: 0.0001)
        XCTAssertEqual(panel.petActionFrequencySettings.wanderFrequency, 1.3, accuracy: 0.0001)

        panel.applyActionFrequencySettings(MacPetActionFrequencySettings(
            randomActionFrequency: 2.0,
            walkSpeedMultiplier: 1.5,
            wanderFrequency: 0.5))

        XCTAssertEqual(panel.petActionFrequencySettings.randomActionFrequency, 2.0, accuracy: 0.0001)
        XCTAssertEqual(panel.petActionFrequencySettings.walkSpeedMultiplier, 1.5, accuracy: 0.0001)
        XCTAssertEqual(panel.petActionFrequencySettings.wanderFrequency, 0.5, accuracy: 0.0001)
    }

    private func makePanel() -> PetPanel {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibestick-pet-e2e-\(UUID().uuidString)")
        let configuration = VibestickAppConfiguration(
            coderStatusDirectory: tempRoot.appendingPathComponent("status"),
            codexSessionsRoot: tempRoot.appendingPathComponent("sessions"),
            enableCodexMonitor: false)
        let viewModel = VibestickViewModel(configuration: configuration)

        return PetPanel(
            viewModel: viewModel,
            openControlPanel: {},
            hidePet: {},
            importPet: {},
            exportPet: {},
            quitApplication: {},
            cycleFocusPreference: {},
            focusActionTitle: { "专注模式" })
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        return condition()
    }

    private func restore(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func saveDefaults(_ keys: String...) -> [String: Any?] {
        let defaults = UserDefaults.standard
        return Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, defaults.object(forKey: key))
        })
    }

    private func restore(_ snapshot: [String: Any?], in defaults: UserDefaults) {
        for (key, value) in snapshot {
            restore(value, forKey: key, in: defaults)
        }
    }
}
