import AppKit
import SwiftUI

enum MacPetCrawlDirection {
    case left
    case right
}

struct MacPetSpriteFrameSnapshot: Equatable {
    let pose: String
    let column: Int
    let row: Int
    let frameIndex: Int
    let clipName: String
    let motionOffsetX: Double
    let motionOffsetY: Double
    let flipsWithDirection: Bool
}

@MainActor
final class MacPetSpriteAnimator: ObservableObject {
    private static let frameWidth = 192
    private static let frameHeight = 208
    private static let sheetWidth = 1536
    private static let sheetHeight = 1872
    private static let clips = buildClips()

    @Published private(set) var image: NSImage?
    @Published private(set) var frame = MacPetSpriteFrameSnapshot(
        pose: "seated",
        column: 0,
        row: 0,
        frameIndex: 0,
        clipName: "seated_blink",
        motionOffsetX: 0,
        motionOffsetY: 0,
        flipsWithDirection: false)

    private let sheet: NSImage?
    private var mood = "idle"
    private var crawlDirection: MacPetCrawlDirection?
    private var isHovering = false
    private var activeClip: PetAnimationClip
    private var randomActionClip: PetAnimationClip?
    private var nextRandomActionAt = Date().addingTimeInterval(6)
    private var frameIndex = 0

    init() {
        activeClip = Self.clips["seated_blink"]!
        if let url = Self.spriteURL() {
            sheet = NSImage(contentsOf: url)
        } else {
            sheet = nil
        }
        render()
    }

    var currentFrameInterval: TimeInterval {
        activeClip.frameInterval
    }

    var horizontalScale: CGFloat {
        frame.flipsWithDirection && crawlDirection == .left ? -1 : 1
    }

    func setMood(_ mood: String) {
        guard self.mood != mood else {
            return
        }
        self.mood = mood
        randomActionClip = nil
        scheduleRandomAction()
        _ = selectClip(forceReset: true)
        render()
    }

    func setCrawlDirection(_ direction: MacPetCrawlDirection?) {
        guard crawlDirection != direction else {
            return
        }
        crawlDirection = direction
        if direction != nil {
            randomActionClip = nil
        }
        _ = selectClip(forceReset: true)
        render()
    }

    func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else {
            return
        }
        isHovering = hovering
        if hovering {
            randomActionClip = nil
        }
        _ = selectClip(forceReset: true)
        render()
    }

    func advanceFrame() {
        let changed = selectClip(forceReset: false)
        if !changed, !activeClip.loops, frameIndex >= activeClip.frames.count - 1 {
            randomActionClip = nil
            scheduleRandomAction()
            _ = selectClip(forceReset: true)
        } else if !changed {
            frameIndex = (frameIndex + 1) % activeClip.frames.count
        }
        render()
    }

    private func selectClip(forceReset: Bool) -> Bool {
        let selected = resolveClip()
        if forceReset || selected.name != activeClip.name {
            activeClip = selected
            frameIndex = 0
            return true
        }
        return false
    }

    private func resolveClip() -> PetAnimationClip {
        if crawlDirection != nil {
            return Self.clips["patrol_crawl"]!
        }
        if isHovering || ["error", "waiting", "power"].contains(mood) {
            randomActionClip = nil
            return Self.clips["attention_paw"]!
        }
        if mood == "sleeping" {
            randomActionClip = nil
            return Self.clips["sleepy_nap"]!
        }
        if let randomActionClip {
            return randomActionClip
        }
        if canUseRandomActions(mood), Date() >= nextRandomActionAt {
            randomActionClip = chooseRandomAction()
            return randomActionClip!
        }
        return baseClip(for: mood)
    }

    private func render() {
        let frameRef = activeClip.frames[frameIndex % activeClip.frames.count]
        frame = MacPetSpriteFrameSnapshot(
            pose: activeClip.pose,
            column: frameRef.column,
            row: frameRef.row,
            frameIndex: frameIndex,
            clipName: activeClip.name,
            motionOffsetX: frameRef.motionOffsetX,
            motionOffsetY: frameRef.motionOffsetY,
            flipsWithDirection: activeClip.flipsWithDirection)
        image = crop(frameRef)
    }

    private func crop(_ frame: PetSpriteFrameRef) -> NSImage? {
        guard let sheet, let cgImage = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let rect = CGRect(
            x: frame.column * Self.frameWidth,
            y: Self.sheetHeight - ((frame.row + 1) * Self.frameHeight),
            width: Self.frameWidth,
            height: Self.frameHeight)
        guard let cropped = cgImage.cropping(to: rect) else {
            return nil
        }

        return NSImage(cgImage: cropped, size: NSSize(width: Self.frameWidth, height: Self.frameHeight))
    }

    private func chooseRandomAction() -> PetAnimationClip {
        let activePool = ["curious_look", "attention_paw", "playful_stretch", "groom_think"]
        let idlePool = ["curious_look", "attention_paw", "playful_stretch", "sleepy_nap", "happy_beg", "groom_think"]
        let pool = ["running", "reasoning"].contains(mood) ? activePool : idlePool
        return Self.clips[pool.randomElement()!]!
    }

    private func scheduleRandomAction() {
        guard canUseRandomActions(mood) else {
            nextRandomActionAt = .distantFuture
            return
        }
        let active = ["running", "reasoning"].contains(mood)
        nextRandomActionAt = Date().addingTimeInterval(Double.random(in: active ? 8...18 : 6...14))
    }

    private func canUseRandomActions(_ mood: String) -> Bool {
        ["idle", "success", "offline", "running", "reasoning"].contains(mood)
    }

    private func baseClip(for mood: String) -> PetAnimationClip {
        switch mood {
        case "running", "reasoning":
            Self.clips["curious_look"]!
        case "sleeping":
            Self.clips["sleepy_nap"]!
        case "error", "waiting", "power":
            Self.clips["attention_paw"]!
        default:
            Self.clips["seated_blink"]!
        }
    }

    private static func buildClips() -> [String: PetAnimationClip] {
        let clips = [
            PetAnimationClip("seated_blink", "seated", row(0, 0, 5), 0.360, true, false),
            PetAnimationClip("patrol_crawl", "crawling", patrolFrames(), 0.115, true, true),
            PetAnimationClip("attention_paw", "attention", row(3, 0, 3), 0.210, false, false),
            PetAnimationClip("playful_stretch", "stretch", row(4, 0, 4), 0.240, false, false),
            PetAnimationClip("sleepy_nap", "sleepy", row(5, 0, 7), 0.300, false, false),
            PetAnimationClip("curious_look", "curious", row(6, 0, 5), 0.260, true, false),
            PetAnimationClip("happy_beg", "happy", row(7, 0, 5), 0.250, false, false),
            PetAnimationClip("groom_think", "grooming", row(8, 0, 5), 0.260, false, false)
        ]
        return Dictionary(uniqueKeysWithValues: clips.map { ($0.name, $0) })
    }

    private static func spriteURL() -> URL? {
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("VibestickMac_VibestickApp.bundle", isDirectory: true),
           let bundle = Bundle(url: resourceURL),
           let url = spriteURL(in: bundle)
        {
            return url
        }

        return spriteURL(in: Bundle.module)
    }

    private static func spriteURL(in bundle: Bundle) -> URL? {
        bundle.url(
            forResource: "golden-shaded-cat-spritesheet.cleaned",
            withExtension: "png",
            subdirectory: "PetSprites")
            ?? bundle.url(
                forResource: "golden-shaded-cat-spritesheet.cleaned",
                withExtension: "png")
    }

    private static func row(_ row: Int, _ firstColumn: Int, _ lastColumn: Int) -> [PetSpriteFrameRef] {
        (firstColumn...lastColumn).map { PetSpriteFrameRef(column: $0, row: row) }
    }

    private static func patrolFrames() -> [PetSpriteFrameRef] {
        (row(1, 0, 7) + row(2, 0, 7)).enumerated().map { index, frame in
            let offset = patrolMotion(index)
            return PetSpriteFrameRef(
                column: frame.column,
                row: frame.row,
                motionOffsetX: offset.x,
                motionOffsetY: offset.y)
        }
    }

    private static func patrolMotion(_ index: Int) -> (x: Double, y: Double) {
        switch index % 8 {
        case 0: (-3, 1)
        case 1: (-1, -4)
        case 2: (2, -7)
        case 3: (4, -4)
        case 4: (5, 1)
        case 5: (3, -3)
        case 6: (0, -6)
        default: (-2, -2)
        }
    }
}

private struct PetSpriteFrameRef {
    let column: Int
    let row: Int
    var motionOffsetX: Double = 0
    var motionOffsetY: Double = 0
}

private struct PetAnimationClip {
    let name: String
    let pose: String
    let frames: [PetSpriteFrameRef]
    let frameInterval: TimeInterval
    let loops: Bool
    let flipsWithDirection: Bool

    init(
        _ name: String,
        _ pose: String,
        _ frames: [PetSpriteFrameRef],
        _ frameInterval: TimeInterval,
        _ loops: Bool,
        _ flipsWithDirection: Bool
    ) {
        self.name = name
        self.pose = pose
        self.frames = frames
        self.frameInterval = frameInterval
        self.loops = loops
        self.flipsWithDirection = flipsWithDirection
    }
}
