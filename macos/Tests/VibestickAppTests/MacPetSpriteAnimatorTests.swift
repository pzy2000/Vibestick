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
        XCTAssertTrue([1, 2].contains(frame.row))
        XCTAssertTrue(frame.flipsWithDirection)
    }

    func testCrawlDirectionStartsCrawlingWhenAlreadyHovering() {
        let animator = MacPetSpriteAnimator()

        animator.setHovering(true)
        animator.setCrawlDirection(.right)

        let frame = animator.frame
        XCTAssertEqual(frame.clipName, "patrol_crawl")
        XCTAssertEqual(frame.pose, "crawling")
        XCTAssertTrue([1, 2].contains(frame.row))
    }

    func testCrawlDirectionOverridesFixedMoodClip() {
        let animator = MacPetSpriteAnimator()

        animator.setMood("tool_calling")
        animator.setCrawlDirection(.left)

        let frame = animator.frame
        XCTAssertEqual(frame.clipName, "patrol_crawl")
        XCTAssertEqual(frame.pose, "crawling")
        XCTAssertTrue([1, 2].contains(frame.row))
        XCTAssertTrue(frame.flipsWithDirection)
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
}
