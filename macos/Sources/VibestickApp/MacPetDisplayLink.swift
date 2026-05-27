import CoreVideo
import Foundation

@MainActor
final class MacPetDisplayLink {
    private let tick: @MainActor (Date) -> Void
    private var displayLink: CVDisplayLink?
    private var fallbackTimer: Timer?

    init(tick: @escaping @MainActor (Date) -> Void) {
        self.tick = tick
    }

    func start() {
        invalidate()

        var createdDisplayLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&createdDisplayLink) == kCVReturnSuccess,
              let createdDisplayLink
        else {
            startFallbackTimer()
            return
        }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            guard let context else {
                return kCVReturnSuccess
            }

            let displayLink = Unmanaged<MacPetDisplayLink>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async {
                Task { @MainActor in
                    displayLink.fire()
                }
            }
            return kCVReturnSuccess
        }

        let result = CVDisplayLinkSetOutputCallback(
            createdDisplayLink,
            callback,
            Unmanaged.passUnretained(self).toOpaque())
        guard result == kCVReturnSuccess,
              CVDisplayLinkStart(createdDisplayLink) == kCVReturnSuccess
        else {
            startFallbackTimer()
            return
        }

        displayLink = createdDisplayLink
    }

    func invalidate() {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func fire() {
        tick(Date())
    }

    private func startFallbackTimer() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fire()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }
}
