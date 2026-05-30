import AppKit
import QuartzCore

enum MacPetCrawlDirection: Equatable {
    case left
    case right

    private static let dragDirectionThreshold: CGFloat = 1

    static func direction(forDragDeltaX deltaX: CGFloat, current: MacPetCrawlDirection) -> MacPetCrawlDirection {
        if deltaX > dragDirectionThreshold {
            return .right
        }
        if deltaX < -dragDirectionThreshold {
            return .left
        }
        return current
    }

    static func direction(
        forAppliedDeltaX deltaX: CGFloat,
        fallback: MacPetCrawlDirection?
    ) -> MacPetCrawlDirection? {
        guard deltaX != 0 else {
            return nil
        }
        if deltaX > dragDirectionThreshold {
            return .right
        }
        if deltaX < -dragDirectionThreshold {
            return .left
        }
        return fallback
    }

    static func activeAnimationDirection(
        manualDragDirection: MacPetCrawlDirection?,
        walkingAnimationDirection: MacPetCrawlDirection?,
        walkingCanAnimate: Bool
    ) -> MacPetCrawlDirection? {
        if let manualDragDirection {
            return manualDragDirection
        }
        return walkingCanAnimate ? walkingAnimationDirection : nil
    }
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

struct MacPetSpritePresentation {
    let frame: MacPetSpriteFrameSnapshot
    let contentsRect: CGRect
    let horizontalScale: CGFloat
    let renderedMotionOffsetX: CGFloat
}

@MainActor
final class MacPetSpriteAnimator {
    private static let frameWidth = 192
    private static let frameHeight = 208
    private static let sheetWidth = 1536
    private static let sheetHeight = 1872
    private static let clips = buildClips()

    private var mood = "idle"
    private var crawlDirection: MacPetCrawlDirection?
    private var isHovering = false
    private var activeClip: PetAnimationClip
    private var randomActionClip: PetAnimationClip?
    private var nextRandomActionAt = Date.distantFuture
    private var actionFrequencySettings: MacPetActionFrequencySettings
    private var frameIndex = 0
    private var lastFrameAdvanceAt = Date()

    init(actionFrequencySettings: MacPetActionFrequencySettings = .load()) {
        self.actionFrequencySettings = actionFrequencySettings.clamped
        activeClip = Self.clips["sleepy_nap"]!
        scheduleRandomAction()
    }

    var frame: MacPetSpriteFrameSnapshot {
        snapshot(for: activeClip.frames[frameIndex % activeClip.frames.count])
    }

    var currentFrameInterval: TimeInterval {
        activeClip.frameInterval
    }

    var presentation: MacPetSpritePresentation {
        let frameRef = activeClip.frames[frameIndex % activeClip.frames.count]
        let frame = snapshot(for: frameRef)
        let horizontalScale: CGFloat = activeClip.flipsWithDirection && crawlDirection == .left ? -1 : 1
        return MacPetSpritePresentation(
            frame: frame,
            contentsRect: contentsRect(for: frameRef),
            horizontalScale: horizontalScale,
            renderedMotionOffsetX: CGFloat(frame.motionOffsetX) * horizontalScale)
    }

    @discardableResult
    func setMood(_ mood: String) -> Bool {
        guard self.mood != mood else {
            return false
        }

        self.mood = mood
        randomActionClip = nil
        scheduleRandomAction()
        return selectClip(forceReset: true)
    }

    @discardableResult
    func setCrawlDirection(_ direction: MacPetCrawlDirection?) -> Bool {
        guard crawlDirection != direction else {
            return false
        }

        crawlDirection = direction
        if direction != nil {
            randomActionClip = nil
        }
        return selectClip(forceReset: true)
    }

    @discardableResult
    func setHovering(_ hovering: Bool) -> Bool {
        guard isHovering != hovering else {
            return false
        }

        isHovering = hovering
        if hovering {
            randomActionClip = nil
        }
        return selectClip(forceReset: true)
    }

    @discardableResult
    func setActionFrequencySettings(_ settings: MacPetActionFrequencySettings) -> Bool {
        let next = settings.clamped
        guard actionFrequencySettings != next else {
            return false
        }

        actionFrequencySettings = next
        scheduleRandomAction()
        return true
    }

    @discardableResult
    func advanceFrameIfDue(at date: Date) -> Bool {
        guard date.timeIntervalSince(lastFrameAdvanceAt) >= currentFrameInterval else {
            return false
        }

        lastFrameAdvanceAt = date
        return advanceFrame()
    }

    private func advanceFrame() -> Bool {
        let changed = selectClip(forceReset: false)
        if !changed, !activeClip.loops, frameIndex >= activeClip.frames.count - 1 {
            randomActionClip = nil
            scheduleRandomAction()
            return selectClip(forceReset: true)
        } else if !changed {
            frameIndex = (frameIndex + 1) % activeClip.frames.count
            return true
        }

        return changed
    }

    private func selectClip(forceReset: Bool) -> Bool {
        let selected = resolveClip()
        if forceReset || selected.id != activeClip.id {
            activeClip = selected
            frameIndex = 0
            lastFrameAdvanceAt = Date()
            return true
        }
        return false
    }

    private func resolveClip() -> PetAnimationClip {
        if let crawlDirection {
            return Self.clips[crawlDirection == .left ? "patrol_crawl_left" : "patrol_crawl_right"]!
        }
        if isHovering {
            randomActionClip = nil
            return Self.clips["attention_paw"]!
        }
        if let fixedClip = fixedStateClip(for: mood) {
            randomActionClip = nil
            return fixedClip
        }
        if let randomActionClip {
            return randomActionClip
        }
        if canUseRandomActions(mood), Date() >= nextRandomActionAt {
            randomActionClip = chooseRandomAction(for: mood)
            return randomActionClip!
        }
        return baseClip(for: mood)
    }

    private func snapshot(for frameRef: PetSpriteFrameRef) -> MacPetSpriteFrameSnapshot {
        MacPetSpriteFrameSnapshot(
            pose: activeClip.pose,
            column: frameRef.column,
            row: frameRef.row,
            frameIndex: frameIndex,
            clipName: activeClip.name,
            motionOffsetX: frameRef.motionOffsetX,
            motionOffsetY: frameRef.motionOffsetY,
            flipsWithDirection: activeClip.flipsWithDirection)
    }

    private func contentsRect(for frame: PetSpriteFrameRef) -> CGRect {
        CGRect(
            x: CGFloat(frame.column * Self.frameWidth) / CGFloat(Self.sheetWidth),
            y: CGFloat(Self.sheetHeight - ((frame.row + 1) * Self.frameHeight)) / CGFloat(Self.sheetHeight),
            width: CGFloat(Self.frameWidth) / CGFloat(Self.sheetWidth),
            height: CGFloat(Self.frameHeight) / CGFloat(Self.sheetHeight))
    }

    private func chooseRandomAction(for mood: String) -> PetAnimationClip {
        let pool = mood == "tool_calling"
            ? ["tool_typing", "curious_look", "attention_paw", "playful_stretch", "groom_think"]
            : ["curious_look", "attention_paw", "playful_stretch", "groom_think"]
        return Self.clips[pool.randomElement()!]!
    }

    private func scheduleRandomAction() {
        guard canUseRandomActions(mood) else {
            nextRandomActionAt = .distantFuture
            return
        }
        let active = isActiveCoderMood(mood)
        nextRandomActionAt = Date().addingTimeInterval(Double.random(in: actionFrequencySettings.randomActionDelayRange(active: active)))
    }

    private func canUseRandomActions(_ mood: String) -> Bool {
        isActiveCoderMood(mood)
    }

    private func isActiveCoderMood(_ mood: String) -> Bool {
        ["running", "reasoning", "tool_calling"].contains(mood)
    }

    private func fixedStateClip(for mood: String) -> PetAnimationClip? {
        switch mood {
        case "idle", "sleeping":
            Self.clips["sleepy_nap"]!
        case "waiting":
            Self.clips["waiting_peek"]!
        case "happy":
            Self.clips["happy_beg"]!
        case "sad":
            Self.clips["low_battery_curl"]!
        case "success":
            Self.clips["success_jump"]!
        case "error":
            Self.clips["error_shake"]!
        case "low_battery":
            Self.clips["low_battery_curl"]!
        case "power":
            Self.clips["power_guard"]!
        default:
            nil
        }
    }

    private func baseClip(for mood: String) -> PetAnimationClip {
        switch mood {
        case "idle", "sleeping":
            Self.clips["sleepy_nap"]!
        case "happy":
            Self.clips["happy_beg"]!
        case "sad":
            Self.clips["low_battery_curl"]!
        default:
            Self.clips["seated_blink"]!
        }
    }

    private static func buildClips() -> [String: PetAnimationClip] {
        let clips = [
            PetAnimationClip("seated_blink", "seated", row(0, 0, 5), 0.360, true, false),
            PetAnimationClip("patrol_crawl_right", "crawling", patrolFrames(row: 1), 0.115, true, false, clipName: "patrol_crawl"),
            PetAnimationClip("patrol_crawl_left", "crawling", patrolFrames(row: 2), 0.115, true, false, clipName: "patrol_crawl"),
            PetAnimationClip("attention_paw", "attention", row(3, 0, 3), 0.210, false, false),
            PetAnimationClip("playful_stretch", "stretch", row(4, 0, 4), 0.240, false, false),
            PetAnimationClip("sleepy_nap", "sleepy", row(5, 0, 7), 0.300, false, false),
            PetAnimationClip("curious_look", "curious", row(6, 0, 5), 0.260, false, false),
            PetAnimationClip("happy_beg", "happy", row(7, 0, 5), 0.250, false, false),
            PetAnimationClip("groom_think", "grooming", row(8, 0, 5), 0.260, false, false),
            PetAnimationClip("waiting_peek", "peek", peekFrames(), 0.180, true, false),
            PetAnimationClip("tool_typing", "typing", typingFrames(), 0.120, false, false),
            PetAnimationClip("success_jump", "jump", successJumpFrames(), 0.115, false, false),
            PetAnimationClip("error_shake", "shake", errorShakeFrames(), 0.085, true, false),
            PetAnimationClip("low_battery_curl", "curled", row(5, 2, 7), 0.420, true, false),
            PetAnimationClip("power_guard", "guard", row(3, 0, 3), 0.160, true, false)
        ]
        return Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
    }

    private static func row(_ row: Int, _ firstColumn: Int, _ lastColumn: Int) -> [PetSpriteFrameRef] {
        (firstColumn...lastColumn).map { PetSpriteFrameRef(column: $0, row: row) }
    }

    private static func patrolFrames(row: Int) -> [PetSpriteFrameRef] {
        Self.row(row, 0, 7).enumerated().map { index, frame in
            let offset = patrolMotion(index)
            return PetSpriteFrameRef(
                column: frame.column,
                row: frame.row,
                motionOffsetX: offset.x,
                motionOffsetY: offset.y)
        }
    }

    private static func peekFrames() -> [PetSpriteFrameRef] {
        [0, 1, 2, 3, 4, 3, 2, 1].map { column in
            PetSpriteFrameRef(column: column, row: 6)
        }
    }

    private static func typingFrames() -> [PetSpriteFrameRef] {
        [0, 1, 2, 3, 4, 5, 4, 3, 2, 1].enumerated().map { index, column in
            PetSpriteFrameRef(
                column: column,
                row: 8,
                motionOffsetX: index.isMultiple(of: 2) ? -1 : 1,
                motionOffsetY: 0)
        }
    }

    private static func successJumpFrames() -> [PetSpriteFrameRef] {
        zip(row(7, 0, 5), [0, -10, -22, -14, -6, 0]).map { frame, offsetY in
            PetSpriteFrameRef(
                column: frame.column,
                row: frame.row,
                motionOffsetX: 0,
                motionOffsetY: Double(offsetY))
        }
    }

    private static func errorShakeFrames() -> [PetSpriteFrameRef] {
        zip([0, 1, 2, 3, 2, 1], [-5, 5, -4, 4, -2, 2]).map { column, offsetX in
            PetSpriteFrameRef(
                column: column,
                row: 3,
                motionOffsetX: Double(offsetX),
                motionOffsetY: 0)
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

@MainActor
final class MacPetSpriteLayerView: NSView {
    private static let spriteSize = CGSize(width: 194, height: 210)

    private let spriteLayer = CALayer()
    private let fallbackLayer = CATextLayer()
    private var currentPresentation: MacPetSpritePresentation?
    private var currentSpritesheetURL: URL?

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.spriteSize))
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        spriteLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        spriteLayer.bounds = CGRect(origin: .zero, size: Self.spriteSize)
        spriteLayer.contentsGravity = .resize
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        layer?.addSublayer(spriteLayer)

        fallbackLayer.string = "missing pet sprite"
        fallbackLayer.alignmentMode = .center
        fallbackLayer.foregroundColor = NSColor.labelColor.cgColor
        fallbackLayer.fontSize = 12
        fallbackLayer.isHidden = true
        layer?.addSublayer(fallbackLayer)

        setSpritesheetURL(PetLibrary.defaultBuiltInSpritesheetURL())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        applyCurrentPresentation()
    }

    func apply(_ presentation: MacPetSpritePresentation) {
        currentPresentation = presentation
        applyCurrentPresentation()
    }

    func setSpritesheetURL(_ url: URL?) {
        guard currentSpritesheetURL != url else {
            return
        }
        currentSpritesheetURL = url
        loadSpritesheet(url)
        applyCurrentPresentation()
    }

    private func loadSpritesheet(_ url: URL?) {
        guard let url,
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            spriteLayer.isHidden = true
            fallbackLayer.isHidden = false
            return
        }

        spriteLayer.contents = cgImage
        spriteLayer.isHidden = false
        fallbackLayer.isHidden = true
    }

    private func applyCurrentPresentation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        fallbackLayer.frame = bounds
        guard let presentation = currentPresentation, spriteLayer.contents != nil else {
            return
        }

        spriteLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        spriteLayer.position = CGPoint(
            x: bounds.midX + presentation.renderedMotionOffsetX,
            y: bounds.midY - CGFloat(presentation.frame.motionOffsetY))
        spriteLayer.contentsRect = presentation.contentsRect
        spriteLayer.transform = CATransform3DMakeScale(presentation.horizontalScale, 1, 1)
    }

}

private struct PetSpriteFrameRef {
    let column: Int
    let row: Int
    var motionOffsetX: Double = 0
    var motionOffsetY: Double = 0
}

private struct PetAnimationClip {
    let id: String
    let name: String
    let pose: String
    let frames: [PetSpriteFrameRef]
    let frameInterval: TimeInterval
    let loops: Bool
    let flipsWithDirection: Bool

    init(
        _ id: String,
        _ pose: String,
        _ frames: [PetSpriteFrameRef],
        _ frameInterval: TimeInterval,
        _ loops: Bool,
        _ flipsWithDirection: Bool,
        clipName: String? = nil
    ) {
        self.id = id
        self.name = clipName ?? id
        self.pose = pose
        self.frames = frames
        self.frameInterval = frameInterval
        self.loops = loops
        self.flipsWithDirection = flipsWithDirection
    }
}
