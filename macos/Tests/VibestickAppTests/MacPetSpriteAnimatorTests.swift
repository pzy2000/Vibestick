import XCTest
@testable import VibestickApp

@MainActor
final class MacPetSpriteAnimatorTests: XCTestCase {
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
}
