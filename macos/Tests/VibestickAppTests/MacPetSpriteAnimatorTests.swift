import AppKit
import XCTest
@testable import VibestickApp

@MainActor
final class MacPetSpriteAnimatorTests: XCTestCase {
    func testActionFrequencySettingsClampToSupportedRange() {
        let settings = MacPetActionFrequencySettings(
            randomActionFrequency: 0.01,
            walkSpeedMultiplier: 1.04,
            wanderFrequency: 2.8).clamped

        XCTAssertEqual(settings.randomActionFrequency, 0.05)
        XCTAssertEqual(settings.walkSpeedMultiplier, 1.0)
        XCTAssertEqual(settings.wanderFrequency, 2.0)
    }

    func testRandomActionFrequencyKeepsLowValuesBelowWalkingMinimum() {
        let settings = MacPetActionFrequencySettings(
            randomActionFrequency: 0.05,
            walkSpeedMultiplier: 0.05,
            wanderFrequency: 0.05).clamped

        XCTAssertEqual(settings.randomActionFrequency, 0.05)
        XCTAssertEqual(settings.walkSpeedMultiplier, 0.5)
        XCTAssertEqual(settings.wanderFrequency, 0.5)
    }

    func testActionFrequencySettingsScaleBehaviorIntervals() {
        let settings = MacPetActionFrequencySettings(
            randomActionFrequency: 2.0,
            walkSpeedMultiplier: 1.5,
            wanderFrequency: 0.5)

        XCTAssertEqual(settings.scaledRandomActionDelay(8), 4)
        XCTAssertEqual(settings.scaledWalkSpeed(60), 90)
        XCTAssertEqual(settings.scaledWanderInterval(4), 8)
        XCTAssertEqual(settings.randomActionDelayRange(active: true).lowerBound, 4)
        XCTAssertEqual(settings.randomActionDelayRange(active: true).upperBound, 9)
    }

    func testActionFrequencySettingsPersistToDefaults() throws {
        let suiteName = "MacPetActionFrequencySettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = MacPetActionFrequencySettings(
            randomActionFrequency: 1.6,
            walkSpeedMultiplier: 0.7,
            wanderFrequency: 1.3)
        settings.save(defaults: defaults)

        XCTAssertEqual(MacPetActionFrequencySettings.load(defaults: defaults), settings.clamped)
    }

    func testInitialIdleUsesSleepyNapClip() {
        let animator = MacPetSpriteAnimator()

        let frame = animator.frame
        XCTAssertEqual(frame.clipName, "sleepy_nap")
        XCTAssertEqual(frame.pose, "sleepy")
        XCTAssertEqual(frame.row, 5)
    }

    func testIdleHoveringUsesAttentionClip() {
        let animator = MacPetSpriteAnimator()

        animator.setHovering(true)

        let frame = animator.frame
        XCTAssertEqual(frame.clipName, "attention_paw")
        XCTAssertEqual(frame.pose, "attention")
    }

    func testSleepingMoodUsesSleepyNapClip() {
        let animator = MacPetSpriteAnimator()

        animator.setMood("sleeping")

        let frame = animator.frame
        XCTAssertEqual(frame.clipName, "sleepy_nap")
        XCTAssertEqual(frame.pose, "sleepy")
    }

    func testCrawlDirectionOverridesHoveringAttentionClip() {
        let animator = MacPetSpriteAnimator()

        animator.setCrawlDirection(.right)
        animator.setHovering(true)

        let frame = animator.frame
        XCTAssertEqual(frame.clipName, "patrol_crawl")
        XCTAssertEqual(frame.pose, "crawling")
        XCTAssertEqual(frame.row, 1)
        XCTAssertFalse(frame.flipsWithDirection)
    }

    func testRightCrawlUsesRunningRightRowWithoutMirroring() {
        let animator = MacPetSpriteAnimator()

        animator.setCrawlDirection(.right)

        let presentation = animator.presentation
        XCTAssertEqual(presentation.frame.row, 1)
        XCTAssertEqual(presentation.horizontalScale, 1)
        XCTAssertEqual(presentation.renderedMotionOffsetX, CGFloat(presentation.frame.motionOffsetX))
    }

    func testLeftCrawlUsesRunningLeftRowWithoutMirroring() {
        let animator = MacPetSpriteAnimator()

        animator.setCrawlDirection(.left)

        let presentation = animator.presentation
        XCTAssertEqual(presentation.frame.row, 2)
        XCTAssertEqual(presentation.horizontalScale, 1)
        XCTAssertEqual(presentation.renderedMotionOffsetX, CGFloat(presentation.frame.motionOffsetX))
    }

    func testLeftAndRightCrawlUseMatchingRowsForSameFrame() {
        let rightAnimator = MacPetSpriteAnimator()
        let leftAnimator = MacPetSpriteAnimator()

        rightAnimator.setCrawlDirection(.right)
        leftAnimator.setCrawlDirection(.left)

        XCTAssertEqual(rightAnimator.frame.frameIndex, leftAnimator.frame.frameIndex)
        XCTAssertEqual(rightAnimator.frame.row, 1)
        XCTAssertEqual(leftAnimator.frame.row, 2)
        XCTAssertEqual(leftAnimator.presentation.renderedMotionOffsetX, rightAnimator.presentation.renderedMotionOffsetX)
    }

    func testRightCrawlFramesStayOnRunningRightRow() {
        let rows = crawlRows(for: .right)

        XCTAssertEqual(rows, Array(repeating: 1, count: 8))
    }

    func testLeftCrawlFramesStayOnRunningLeftRow() {
        let rows = crawlRows(for: .left)

        XCTAssertEqual(rows, Array(repeating: 2, count: 8))
    }

    func testCrawlDirectionStartsCrawlingWhenAlreadyHovering() {
        let animator = MacPetSpriteAnimator()

        animator.setHovering(true)
        animator.setCrawlDirection(.right)

        let frame = animator.frame
        XCTAssertEqual(frame.clipName, "patrol_crawl")
        XCTAssertEqual(frame.pose, "crawling")
        XCTAssertEqual(frame.row, 1)
    }

    func testCrawlDirectionOverridesFixedMoodClip() {
        let animator = MacPetSpriteAnimator()

        animator.setMood("tool_calling")
        animator.setCrawlDirection(.left)

        let frame = animator.frame
        XCTAssertEqual(frame.clipName, "patrol_crawl")
        XCTAssertEqual(frame.pose, "crawling")
        XCTAssertEqual(frame.row, 2)
        XCTAssertFalse(frame.flipsWithDirection)
    }

    func testHoveringOverridesFixedMoodAndClearingHoverRestoresMoodClip() {
        let animator = MacPetSpriteAnimator()

        animator.setMood("tool_calling")
        animator.setHovering(true)

        XCTAssertEqual(animator.frame.clipName, "attention_paw")
        XCTAssertEqual(animator.frame.pose, "attention")

        animator.setHovering(false)

        XCTAssertEqual(animator.frame.clipName, "tool_typing")
        XCTAssertEqual(animator.frame.pose, "typing")
    }

    func testDragDirectionHelperUsesHorizontalDelta() {
        XCTAssertEqual(MacPetCrawlDirection.direction(forDragDeltaX: 12, current: .left), .right)
        XCTAssertEqual(MacPetCrawlDirection.direction(forDragDeltaX: -12, current: .right), .left)
    }

    func testDragDirectionHelperKeepsCurrentDirectionForSmallJitter() {
        XCTAssertEqual(MacPetCrawlDirection.direction(forDragDeltaX: 0.5, current: .left), .left)
        XCTAssertEqual(MacPetCrawlDirection.direction(forDragDeltaX: -0.5, current: .right), .right)
    }

    func testAppliedDeltaDirectionKeepsCurrentFrameLeftWhenNextDirectionTurnsRight() {
        let animationDirection = MacPetCrawlDirection.direction(
            forAppliedDeltaX: -8,
            fallback: .right)

        XCTAssertEqual(animationDirection, .left)
    }

    func testAppliedDeltaDirectionKeepsCurrentFrameRightWhenNextDirectionTurnsLeft() {
        let animationDirection = MacPetCrawlDirection.direction(
            forAppliedDeltaX: 8,
            fallback: .left)

        XCTAssertEqual(animationDirection, .right)
    }

    func testAppliedDeltaDirectionKeepsFallbackForTinyMovement() {
        XCTAssertEqual(
            MacPetCrawlDirection.direction(forAppliedDeltaX: 0.5, fallback: .left),
            .left)
        XCTAssertEqual(
            MacPetCrawlDirection.direction(forAppliedDeltaX: -0.5, fallback: .right),
            .right)
    }

    func testAppliedDeltaDirectionClearsWhenWindowDidNotMove() {
        XCTAssertNil(MacPetCrawlDirection.direction(forAppliedDeltaX: 0, fallback: .right))
        XCTAssertNil(MacPetCrawlDirection.direction(forAppliedDeltaX: 0, fallback: .left))
    }

    func testManualDragDirectionOverridesWalkingAnimationDirection() {
        let direction = MacPetCrawlDirection.activeAnimationDirection(
            manualDragDirection: .left,
            walkingAnimationDirection: .right,
            walkingCanAnimate: true)

        XCTAssertEqual(direction, .left)
    }

    func testWalkingAnimationDirectionRequiresWalkingAnimationAllowed() {
        XCTAssertEqual(
            MacPetCrawlDirection.activeAnimationDirection(
                manualDragDirection: nil,
                walkingAnimationDirection: .right,
                walkingCanAnimate: true),
            .right)
        XCTAssertNil(
            MacPetCrawlDirection.activeAnimationDirection(
                manualDragDirection: nil,
                walkingAnimationDirection: .right,
                walkingCanAnimate: false))
    }

    private func crawlRows(for direction: MacPetCrawlDirection) -> [Int] {
        let animator = MacPetSpriteAnimator()
        let start = Date()
        animator.setCrawlDirection(direction)

        var rows = [animator.frame.row]
        for step in 1..<8 {
            _ = animator.advanceFrameIfDue(at: start.addingTimeInterval(Double(step)))
            rows.append(animator.frame.row)
        }
        return rows
    }

}

final class MacPetWalkGeometryTests: XCTestCase {
    func testWalkBoundsUseSpriteLaneWhenStatusCardIsWiderThanPet() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let bounds = MacPetWalkGeometry.walkBounds(
            visibleFrame: visibleFrame,
            panelWidth: 352,
            spriteLaneWidth: 220)

        XCTAssertEqual(bounds.minX, -66)
        XCTAssertEqual(bounds.maxX, 714)
    }

    func testWalkBoundsKeepPanelInsideScreenWhenPanelIsNotWiderThanPet() {
        let visibleFrame = NSRect(x: 100, y: 0, width: 900, height: 700)
        let bounds = MacPetWalkGeometry.walkBounds(
            visibleFrame: visibleFrame,
            panelWidth: 200,
            spriteLaneWidth: 220)

        XCTAssertEqual(bounds.minX, 100)
        XCTAssertEqual(bounds.maxX, 800)
    }

    func testWalkBoundsUseScaledPanelWidth() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let scaledWidth = MacPetResizeGeometry.scaledSize(
            baseSize: CGSize(width: 356, height: 476),
            scale: 1.25).width
        let bounds = MacPetWalkGeometry.walkBounds(
            visibleFrame: visibleFrame,
            panelWidth: scaledWidth,
            spriteLaneWidth: 220)

        XCTAssertEqual(bounds.minX, -112.5)
        XCTAssertEqual(bounds.maxX, 667.5)
    }
}

final class MacPetResizeGeometryTests: XCTestCase {
    func testClampedScaleUsesWindowsRange() {
        XCTAssertEqual(MacPetResizeGeometry.clampedScale(0.1), 0.35)
        XCTAssertEqual(MacPetResizeGeometry.clampedScale(1.0), 1.0)
        XCTAssertEqual(MacPetResizeGeometry.clampedScale(2.0), 1.5)
    }

    func testScaleFromDragUsesDominantAxisAndWindowsDivisor() {
        XCTAssertEqual(
            MacPetResizeGeometry.scale(startScale: 1.0, dragDelta: NSPoint(x: 22, y: 10)),
            1.1,
            accuracy: 0.0001)
        XCTAssertEqual(
            MacPetResizeGeometry.scale(startScale: 1.0, dragDelta: NSPoint(x: 20, y: -44)),
            0.8,
            accuracy: 0.0001)
    }

    func testScaledSizeUsesClampedScale() {
        let size = MacPetResizeGeometry.scaledSize(
            baseSize: CGSize(width: 356, height: 476),
            scale: 2.0)

        XCTAssertEqual(size.width, 534)
        XCTAssertEqual(size.height, 714)
    }

    func testResizeHitAcceptsSpriteBottomRightHandleOnly() {
        let spriteFrame = NSRect(x: 68, y: 10, width: 220, height: 210)
        let handleFrame = MacPetResizeGeometry.handleFrame(spriteFrame: spriteFrame, scale: 1.0)

        XCTAssertTrue(MacPetResizeGeometry.isResizeHit(
            point: NSPoint(x: 270, y: 34),
            handleFrame: handleFrame))
        XCTAssertTrue(MacPetResizeGeometry.isResizeHit(
            point: NSPoint(x: 292, y: 12),
            handleFrame: handleFrame))
        XCTAssertFalse(MacPetResizeGeometry.isResizeHit(
            point: NSPoint(x: 76, y: 190),
            handleFrame: handleFrame))
        XCTAssertFalse(MacPetResizeGeometry.isResizeHit(
            point: NSPoint(x: 178, y: 120),
            handleFrame: handleFrame))
    }

    func testResizeHandleFramesScaleFromSpriteBottomRight() {
        let spriteFrame = NSRect(x: 68, y: 10, width: 220, height: 210)

        let defaultFrame = MacPetResizeGeometry.handleFrame(spriteFrame: spriteFrame, scale: 1.0)
        XCTAssertEqual(defaultFrame.width, 34)
        XCTAssertEqual(defaultFrame.height, 34)
        XCTAssertEqual(defaultFrame.maxX, spriteFrame.maxX + 12)
        XCTAssertEqual(defaultFrame.minY, spriteFrame.minY - 4)

        let scaledFrame = MacPetResizeGeometry.handleFrame(spriteFrame: spriteFrame, scale: 1.5)
        XCTAssertEqual(scaledFrame.width, 51)
        XCTAssertEqual(scaledFrame.height, 51)
        XCTAssertEqual(scaledFrame.maxX, spriteFrame.maxX + 18)
        XCTAssertEqual(scaledFrame.minY, spriteFrame.minY - 6)
    }
}
