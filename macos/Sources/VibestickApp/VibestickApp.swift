import AppKit
import ServiceManagement
import SwiftUI
import VibestickMacCore

@main
struct VibestickMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Vibestick") {
            ControlPanelView(viewModel: appDelegate.viewModel)
                .frame(minWidth: 520, minHeight: 420)
        }
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Vibestick") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = VibestickViewModel()
    private var statusItem: NSStatusItem?
    private var petWindow: PetPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        showPet()
        viewModel.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        viewModel.stopHyperAssertion()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Vibestick"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Control Panel", action: #selector(openControlPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show Pet", action: #selector(showPetAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openControlPanel() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    @objc private func showPetAction() {
        showPet()
    }

    private func showPet() {
        if petWindow == nil {
            petWindow = PetPanel(viewModel: viewModel)
        }
        petWindow?.orderFrontRegardless()
        petWindow?.startWalking()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class VibestickViewModel: ObservableObject {
    @Published var statusText = "Loading..."
    @Published var doctorText = "Doctor not run yet."
    @Published var petMood = "idle"
    @Published var petTitle = "Vibestick"
    @Published var petMessage = "Loading..."
    @Published var petCoders: [CoderAgentStatus] = []
    @Published var helperInstallMessage = ""

    private let runner = ProcessCommandRunner()
    private let assertionManager: MacSleepAssertionManager
    private let engine: VibestickMacEngine
    private let doctor: MacDoctorService
    private let coderSource: CompositeCoderStatusSource
    private let petResolver = PetStateResolver()
    private var refreshTimer: Timer?

    init() {
        let helper = SubprocessHelperClient()
        let battery = MacBatteryMonitor()
        let processInspector = MacProcessInspector()
        let assertionManager = MacSleepAssertionManager()
        self.assertionManager = assertionManager
        self.engine = VibestickMacEngine(
            helper: helper,
            battery: battery,
            processInspector: processInspector,
            assertionManager: assertionManager)
        self.doctor = MacDoctorService(
            helper: helper,
            battery: battery,
            processInspector: processInspector,
            assertionManager: assertionManager)
        self.coderSource = CompositeCoderStatusSource([
            JsonFileCoderStatusSource(),
            ProcessCoderStatusSource(processInspector: processInspector, processNames: VibestickOptions().longTaskProcessNames)
        ])
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        let status = engine.status()
        statusText = """
        Mode: \(status.activeMode.rawValue)
        Restore pending: \(status.restorePending ? "yes" : "no")
        HYPER assertion: \(status.assertionActive ? "active" : "inactive")
        Battery: \(status.battery.percentage.map { "\($0)%" } ?? "unknown"), AC connected=\(status.battery.isACConnected)
        pmset sleep: battery=\(status.pmset?.value("sleep", source: .battery) ?? "-"), ac=\(status.pmset?.value("sleep", source: .ac) ?? "-")
        """

        let coders = coderSource.getStatuses(now: Date())
        let pet = petResolver.resolve(status: status, coders: coders)
        petMood = pet.mood
        petTitle = pet.title
        petMessage = pet.message
        petCoders = Array(coders.prefix(3))
    }

    func runDoctor() {
        let report = doctor.run()
        doctorText = report.checks
            .map { "\($0.passed ? "OK " : "ERR") \($0.name): \($0.message)" }
            .joined(separator: "\n")
    }

    func apply(_ mode: VibestickMode) {
        do {
            _ = try engine.applyMode(mode)
            refresh()
        } catch {
            statusText = "Error: \(error.localizedDescription)"
        }
    }

    func stopHyperAssertion() {
        assertionManager.endHyperAssertion()
        refresh()
    }

    func requestAccessibility() {
        _ = AccessibilityStatus.isTrusted(prompt: true)
    }

    func registerHelper() {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.daemon(plistName: "com.pzy.vibestick.helper.plist").register()
                helperInstallMessage = "Helper registration requested."
            } catch {
                helperInstallMessage = "Helper registration failed: \(error.localizedDescription)"
            }
        } else {
            helperInstallMessage = "Helper registration requires macOS 13 or newer."
        }
    }
}

struct ControlPanelView: View {
    @ObservedObject var viewModel: VibestickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("OFF") { viewModel.apply(.off) }
                Button("ON") { viewModel.apply(.on) }
                Button("HYPER") { viewModel.apply(.hyper) }
                Button("Stop HYPER Guard") { viewModel.stopHyperAssertion() }
            }
            .buttonStyle(.borderedProminent)

            Text(viewModel.statusText)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Refresh") { viewModel.refresh() }
                Button("Doctor") { viewModel.runDoctor() }
                Button("Install Helper") { viewModel.registerHelper() }
                Button("Accessibility") { viewModel.requestAccessibility() }
            }

            if !viewModel.helperInstallMessage.isEmpty {
                Text(viewModel.helperInstallMessage)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(viewModel.doctorText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .onAppear { viewModel.refresh() }
    }
}

@MainActor
final class PetPanel: NSPanel {
    private let viewModel: VibestickViewModel
    private var walkTimer: Timer?
    private var pauseUntil: Date?
    private var lastTick: Date?
    private var direction: MacPetCrawlDirection = .left
    private let walkSpeed: CGFloat = 56
    private let bottomMargin: CGFloat = 16

    init(viewModel: VibestickViewModel) {
        self.viewModel = viewModel
        let hosting = NSHostingView(rootView: PetView(viewModel: viewModel))
        super.init(
            contentRect: NSRect(x: 120, y: 120, width: 356, height: 560),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        contentView = hosting
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
    }

    func startWalking() {
        alignToWalkLane()
        walkTimer?.invalidate()
        walkTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.walkTick()
            }
        }
    }

    private func walkTick() {
        guard isVisible else {
            return
        }

        let now = Date()
        if let pauseUntil, now < pauseUntil {
            viewModel.petMood = viewModel.petMood
            lastTick = now
            return
        }
        pauseUntil = nil

        let elapsed = min(now.timeIntervalSince(lastTick ?? now), 0.25)
        lastTick = now
        guard let screen = screen ?? NSScreen.main else {
            return
        }

        var next = frame
        next.origin.y = screen.visibleFrame.minY + bottomMargin
        let delta = walkSpeed * elapsed * (direction == .right ? 1 : -1)
        next.origin.x += delta

        let minX = screen.visibleFrame.minX
        let maxX = screen.visibleFrame.maxX - frame.width
        if next.origin.x <= minX {
            next.origin.x = minX
            direction = .right
            pauseUntil = now.addingTimeInterval(1)
        } else if next.origin.x >= maxX {
            next.origin.x = maxX
            direction = .left
            pauseUntil = now.addingTimeInterval(1)
        }

        setFrame(next, display: true, animate: false)
        NotificationCenter.default.post(
            name: .vibestickPetWalkDirectionChanged,
            object: direction)
    }

    private func alignToWalkLane() {
        guard let screen = screen ?? NSScreen.main else {
            return
        }
        var next = frame
        next.origin.y = screen.visibleFrame.minY + bottomMargin
        next.origin.x = min(max(next.origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - next.width)
        setFrame(next, display: true, animate: false)
    }
}

struct PetView: View {
    @ObservedObject var viewModel: VibestickViewModel
    @StateObject private var animator = MacPetSpriteAnimator()
    @State private var walkDirection: MacPetCrawlDirection? = .left
    @State private var isHovering = false
    @State private var frameTimer = Timer.publish(every: 0.36, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            taskCards
            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(.black.opacity(0.18))
                    .frame(width: 150, height: 18)
                    .blur(radius: 4)
                    .offset(y: 7)
                sprite
            }
            .frame(width: 220, height: 210)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                animator.setHovering(hovering)
                if hovering {
                    animator.setCrawlDirection(nil)
                } else {
                    animator.setCrawlDirection(walkDirection)
                }
            }
            statusBubble
        }
        .padding(10)
        .onAppear {
            animator.setMood(viewModel.petMood)
            animator.setCrawlDirection(walkDirection)
        }
        .onChange(of: viewModel.petMood) { _, mood in
            animator.setMood(mood)
        }
        .onReceive(frameTimer) { _ in
            animator.advanceFrame()
            frameTimer = Timer.publish(every: animator.currentFrameInterval, on: .main, in: .common).autoconnect()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vibestickPetWalkDirectionChanged)) { notification in
            guard let direction = notification.object as? MacPetCrawlDirection else {
                return
            }
            walkDirection = direction
            if !isHovering {
                animator.setCrawlDirection(direction)
            }
        }
    }

    private var sprite: some View {
        Group {
            if let image = animator.image {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: animator.horizontalScale, y: 1)
                    .offset(
                        x: animator.frame.motionOffsetX,
                        y: -animator.frame.motionOffsetY)
                    .shadow(color: glowColor.opacity(isHovering ? 0.72 : 0.32), radius: isHovering ? 18 : 9)
                    .shadow(color: .black.opacity(0.24), radius: 9, x: 0, y: 7)
            } else {
                Text("missing cat sprite")
                    .font(.caption)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .frame(width: 194, height: 210)
        .animation(.easeOut(duration: 0.12), value: animator.frame)
    }

    private var taskCards: some View {
        VStack(spacing: 6) {
            ForEach(viewModel.petCoders, id: \.agent) { coder in
                VStack(alignment: .leading, spacing: 3) {
                    Text(coder.taskSummary ?? coder.agent)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(coder.taskDetail ?? coder.message ?? coder.phase.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
            }
        }
        .frame(width: 332)
    }

    private var statusBubble: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(viewModel.petTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(viewModel.petMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(width: 308, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.20), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 4)
    }

    private var glowColor: Color {
        switch viewModel.petMood {
        case "power": .orange
        case "running": .green
        case "reasoning": .blue
        case "waiting": .yellow
        case "error": .red
        case "success": .mint
        case "offline": .gray
        default: .purple
        }
    }
}

extension Notification.Name {
    static let vibestickPetWalkDirectionChanged = Notification.Name("vibestickPetWalkDirectionChanged")
}
