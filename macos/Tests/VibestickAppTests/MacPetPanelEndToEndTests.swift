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
        defer {
            restore(previousWalkingValue, forKey: "VibestickPetWalkingEnabled", in: defaults)
            restore(previousOriginX, forKey: "VibestickPetWindowOriginX", in: defaults)
            restore(previousOriginY, forKey: "VibestickPetWindowOriginY", in: defaults)
        }

        defaults.set(true, forKey: "VibestickPetWalkingEnabled")
        defaults.removeObject(forKey: "VibestickPetWindowOriginX")
        defaults.removeObject(forKey: "VibestickPetWindowOriginY")

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

        let moved = waitUntil(timeout: 1.5) {
            panel.frame.origin.x > startOrigin.x + 8
        }

        XCTAssertTrue(
            moved,
            "Expected walking pet panel to move right from \(startOrigin.x), but it stayed at \(panel.frame.origin.x).")
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
}
