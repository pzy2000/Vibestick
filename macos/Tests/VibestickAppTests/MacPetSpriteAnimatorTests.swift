import AppKit
import XCTest
@testable import VibestickApp

@MainActor
final class MacPetSpriteAnimatorTests: XCTestCase {
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
}
