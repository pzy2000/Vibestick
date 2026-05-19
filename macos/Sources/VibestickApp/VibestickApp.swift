import AppKit
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
                Button("退出 Vibestick") {
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
    private var petToggleMenuItem: NSMenuItem?
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
        let openControlPanel = NSMenuItem(title: "打开控制面板", action: #selector(openControlPanel), keyEquivalent: "")
        openControlPanel.target = self
        menu.addItem(openControlPanel)

        let petToggle = NSMenuItem(title: "显示桌宠", action: #selector(togglePetAction), keyEquivalent: "")
        petToggle.target = self
        menu.addItem(petToggle)
        petToggleMenuItem = petToggle

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        updatePetToggleMenuTitle()
    }

    @objc private func openControlPanel() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first { !($0 is PetPanel) }?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePetAction() {
        togglePet()
    }

    private func showPet() {
        if petWindow == nil {
            petWindow = PetPanel(
                viewModel: viewModel,
                openControlPanel: { [weak self] in self?.openControlPanel() },
                hidePet: { [weak self] in self?.hidePet() },
                quitApplication: { [weak self] in self?.quit() })
        }
        petWindow?.orderFrontRegardless()
        petWindow?.startWalking()
        updatePetToggleMenuTitle()
    }

    private func hidePet() {
        guard let petWindow else {
            updatePetToggleMenuTitle()
            return
        }

        petWindow.close()
        self.petWindow = nil
        updatePetToggleMenuTitle()
    }

    private func togglePet() {
        if petWindow?.isVisible == true {
            hidePet()
            return
        }

        showPet()
    }

    private func updatePetToggleMenuTitle() {
        petToggleMenuItem?.title = petWindow?.isVisible == true ? "隐藏桌宠" : "显示桌宠"
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

@MainActor
final class VibestickViewModel: ObservableObject {
    @Published var statusText = "正在读取状态..."
    @Published var doctorText = "尚未运行诊断。"
    @Published var petMood = "idle"
    @Published var petTitle = "Vibestick"
    @Published var petMessage = "正在读取状态..."
    @Published var petCoders: [CoderAgentStatus] = []
    @Published var helperInstallMessage = ""
    @Published var isInstallingHelper = false

    private let assertionManager: MacSleepAssertionManager
    private let engine: VibestickMacEngine
    private let doctor: MacDoctorService
    private let helperInstaller: HelperInstalling
    private let coderSource: CompositeCoderStatusSource
    private let petResolver = PetStateResolver()
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init() {
        let helper = SubprocessHelperClient()
        let battery = MacBatteryMonitor()
        let processInspector = MacProcessInspector()
        let assertionManager = MacSleepAssertionManager()
        self.assertionManager = assertionManager
        self.helperInstaller = MacHelperInstaller()
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
            CodexSessionStatusSource(),
            ProcessCoderStatusSource(processInspector: processInspector, processNames: VibestickOptions().longTaskProcessNames)
        ])
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard refreshTask == nil else {
            return
        }

        let engine = engine
        let helperInstaller = helperInstaller
        let coderSource = coderSource
        let petResolver = petResolver
        refreshTask = Task.detached(priority: .utility) { [weak self] in
            let status = engine.status()
            let helperPreflight = helperInstaller.preflight()
            let coders = coderSource.getStatuses(now: Date())
            let pet = petResolver.resolve(status: status, coders: coders)

            await MainActor.run {
                self?.finishRefresh(
                    status: status,
                    helperPreflight: helperPreflight,
                    coders: coders,
                    pet: pet)
            }
        }
    }

    private func finishRefresh(
        status: VibestickStatus,
        helperPreflight: HelperInstallPreflight,
        coders: [CoderAgentStatus],
        pet: PetState)
    {
        refreshTask = nil
        statusText = formatStatus(status, helperPreflight: helperPreflight)
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
            let result = try engine.applyMode(mode)
            helperInstallMessage = result.message
            refresh()
        } catch {
            let message = friendlyApplyError(error, mode: mode)
            helperInstallMessage = message
            refresh()
            statusText += "\n操作失败：\(message)"
            doctorText = "详细错误：\(error.localizedDescription)"
        }
    }

    func stopHyperAssertion() {
        assertionManager.endHyperAssertion()
        refresh()
    }

    func requestAccessibility() {
        _ = AccessibilityStatus.isTrusted(prompt: true)
    }

    func installHelper() {
        guard !isInstallingHelper else {
            return
        }

        isInstallingHelper = true
        helperInstallMessage = "正在请求管理员授权安装 Helper..."
        let installer = helperInstaller

        Task.detached {
            let result = Result { try installer.install() }
            await MainActor.run {
                self.isInstallingHelper = false
                switch result {
                case .success(let installResult):
                    self.helperInstallMessage = installResult.message
                    self.refresh()
                    self.runDoctor()
                case .failure(let error):
                    self.helperInstallMessage = error.localizedDescription
                    self.runDoctor()
                }
            }
        }
    }

    private func formatStatus(_ status: VibestickStatus, helperPreflight: HelperInstallPreflight) -> String {
        var lines = [
            "当前模式：\(displayMode(status.activeMode))",
            "恢复状态：\(status.restorePending ? "有待恢复的 pmset 备份" : "无需恢复")",
            "HYPER 守护：\(status.assertionActive ? "正在保持唤醒" : "未运行")",
            "电池/电源：\(formatBattery(status.battery))",
            "睡眠策略：\(formatSleepPolicy(status.pmset, helperPreflight: helperPreflight))",
            "Helper：\(formatHelperStatus(helperPreflight))"
        ]

        if let warning = status.warnings.first {
            lines.append("提示：\(friendlyError(warning))")
        }

        return lines.joined(separator: "\n")
    }

    private func formatBattery(_ battery: BatteryInfo) -> String {
        guard battery.isAvailable else {
            return "无法读取"
        }
        let percent = battery.percentage.map { "\($0)%" } ?? "未知电量"
        return "\(percent)，\(battery.isACConnected ? "已连接外接电源" : "正在使用电池")"
    }

    private func formatSleepPolicy(_ snapshot: PmsetSnapshot?, helperPreflight: HelperInstallPreflight) -> String {
        guard let snapshot else {
            if !helperPreflight.isInstalled {
                return "暂不可读；请先安装 Helper"
            }
            return "暂不可读；请运行诊断查看 Helper 与 pmset 状态"
        }
        let battery = snapshot.value("sleep", source: .battery) ?? "未知"
        let ac = snapshot.value("sleep", source: .ac) ?? "未知"
        return "电池=\(battery)，外接电源=\(ac)"
    }

    private func formatHelperStatus(_ preflight: HelperInstallPreflight) -> String {
        if preflight.isInstalled {
            return "已安装"
        }
        if preflight.isReadyToInstall {
            return "未安装，可点击“安装 Helper”"
        }
        return "安装资源缺失，请先重新构建 macOS app"
    }

    private func displayMode(_ mode: VibestickMode) -> String {
        switch mode {
        case .off:
            return "关闭"
        case .on:
            return "保持唤醒"
        case .hyper:
            return "HYPER"
        }
    }

    private func friendlyApplyError(_ error: Error, mode: VibestickMode) -> String {
        let preflight = helperInstaller.preflight()
        if !preflight.isInstalled {
            switch mode {
            case .off:
                return "需要先安装 Helper 才能恢复 pmset 睡眠策略。"
            case .on, .hyper:
                return "需要先安装 Helper 才能修改 macOS 睡眠策略。"
            }
        }
        return friendlyError(error.localizedDescription)
    }

    private func friendlyError(_ message: String) -> String {
        if message.contains(VibestickPaths.installedHelperPath) || message.localizedCaseInsensitiveContains("failed to start") {
            return "Helper 尚未安装或无法启动，请点击“安装 Helper”。"
        }
        return message
    }
}

struct ControlPanelView: View {
    @ObservedObject var viewModel: VibestickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("关闭") { viewModel.apply(.off) }
                Button("保持唤醒") { viewModel.apply(.on) }
                Button("HYPER") { viewModel.apply(.hyper) }
                Button("停止 HYPER") { viewModel.stopHyperAssertion() }
            }
            .buttonStyle(.borderedProminent)

            Text(viewModel.statusText)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("刷新") { viewModel.refresh() }
                Button("诊断") { viewModel.runDoctor() }
                Button(viewModel.isInstallingHelper ? "安装中..." : "安装 Helper") { viewModel.installHelper() }
                    .disabled(viewModel.isInstallingHelper)
                Button("辅助功能授权") { viewModel.requestAccessibility() }
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
final class PetPanel: NSPanel, NSMenuDelegate {
    private static let walkingEnabledDefaultsKey = "VibestickPetWalkingEnabled"

    private let viewModel: VibestickViewModel
    private let openControlPanel: () -> Void
    private let hidePet: () -> Void
    private let quitApplication: () -> Void
    private let walkingToggleMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let spriteAnimator = MacPetSpriteAnimator()
    private let spriteLayerView = MacPetSpriteLayerView()
    private var displayLink: MacPetDisplayLink?
    private var pauseUntil: Date?
    private var lastTick: Date?
    private var direction: MacPetCrawlDirection = .left
    private var walkingEnabled = PetPanel.loadWalkingEnabled()
    private var spriteHovering = false
    private let walkSpeed: CGFloat = 56
    private let bottomMargin: CGFloat = 16

    init(
        viewModel: VibestickViewModel,
        openControlPanel: @escaping () -> Void,
        hidePet: @escaping () -> Void,
        quitApplication: @escaping () -> Void)
    {
        self.viewModel = viewModel
        self.openControlPanel = openControlPanel
        self.hidePet = hidePet
        self.quitApplication = quitApplication
        super.init(
            contentRect: NSRect(x: 120, y: 120, width: 356, height: 476),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        let hosting = PetHostingView(rootView: PetView(
            viewModel: viewModel,
            spriteLayerView: spriteLayerView,
            onHoverChanged: { [weak self] hovering in
                self?.setSpriteHovering(hovering)
            }))
        contentView = hosting
        hosting.petContextMenu = buildContextMenu()
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
    }

    func startWalking() {
        alignToWalkLane()
        displayLink?.invalidate()
        let displayLink = MacPetDisplayLink { [weak self] date in
            self?.displayTick(at: date)
        }
        self.displayLink = displayLink
        displayLink.start()
        updateSpritePresentation(at: Date(), force: true)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateWalkingMenuText()
    }

    override func close() {
        displayLink?.invalidate()
        displayLink = nil
        super.close()
    }

    private func displayTick(at now: Date) {
        guard isVisible else {
            return
        }

        updateWalkPosition(at: now)
        let frameChanged = spriteAnimator.advanceFrameIfDue(at: now)
        updateSpritePresentation(at: now, force: frameChanged)
    }

    private func updateWalkPosition(at now: Date) {
        guard walkingEnabled else {
            pauseUntil = nil
            lastTick = now
            return
        }

        if let pauseUntil, now < pauseUntil {
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

        setFrameOrigin(next.origin)
    }

    private func alignToWalkLane() {
        guard let screen = screen ?? NSScreen.main else {
            return
        }
        var next = frame
        next.origin.y = screen.visibleFrame.minY + bottomMargin
        next.origin.x = min(max(next.origin.x, screen.visibleFrame.minX), screen.visibleFrame.maxX - next.width)
        setFrameOrigin(next.origin)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let open = NSMenuItem(title: "打开控制面板", action: #selector(openControlPanelFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let refresh = NSMenuItem(title: "刷新桌宠", action: #selector(refreshPetFromMenu), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        walkingToggleMenuItem.target = self
        walkingToggleMenuItem.action = #selector(toggleWalkingFromMenu)
        updateWalkingMenuText()
        menu.addItem(walkingToggleMenuItem)

        let hide = NSMenuItem(title: "隐藏桌宠", action: #selector(hidePetFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        menu.addItem(.separator())

        let exit = NSMenuItem(title: "退出 Vibestick", action: #selector(quitFromMenu), keyEquivalent: "")
        exit.target = self
        menu.addItem(exit)

        return menu
    }

    @objc private func openControlPanelFromMenu() {
        openControlPanel()
    }

    @objc private func refreshPetFromMenu() {
        viewModel.refresh()
    }

    @objc private func toggleWalkingFromMenu() {
        walkingEnabled.toggle()
        UserDefaults.standard.set(walkingEnabled, forKey: Self.walkingEnabledDefaultsKey)
        pauseUntil = nil
        lastTick = nil

        if walkingEnabled {
            alignToWalkLane()
        }

        updateWalkingMenuText()
        updateSpritePresentation(at: Date(), force: true)
    }

    @objc private func quitFromMenu() {
        quitApplication()
    }

    @objc private func hidePetFromMenu() {
        hidePet()
    }

    private func updateWalkingMenuText() {
        walkingToggleMenuItem.title = walkingEnabled ? "暂停行走" : "恢复行走"
    }

    private static func loadWalkingEnabled() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: walkingEnabledDefaultsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: walkingEnabledDefaultsKey)
    }

    private func setSpriteHovering(_ hovering: Bool) {
        spriteHovering = hovering
        updateSpritePresentation(at: Date())
    }

    private func updateSpritePresentation(at now: Date, force: Bool = false) {
        let moodChanged = spriteAnimator.setMood(viewModel.petMood)
        let hoverChanged = spriteAnimator.setHovering(spriteHovering)
        let directionChanged = spriteAnimator.setCrawlDirection(activeCrawlDirection(at: now))
        guard force || moodChanged || hoverChanged || directionChanged else {
            return
        }

        spriteLayerView.apply(
            spriteAnimator.presentation,
            glowColor: glowColor(for: viewModel.petMood),
            hovering: spriteHovering)
    }

    private func activeCrawlDirection(at now: Date) -> MacPetCrawlDirection? {
        guard walkingEnabled, !spriteHovering else {
            return nil
        }
        if let pauseUntil, pauseUntil > now {
            return nil
        }
        return direction
    }

    private func glowColor(for mood: String) -> NSColor {
        switch mood {
        case "power": .systemOrange
        case "running": .systemGreen
        case "reasoning": .systemBlue
        case "waiting": .systemYellow
        case "error": .systemRed
        case "success": .systemMint
        case "offline": .systemGray
        default: .systemPurple
        }
    }
}

@MainActor
private final class PetHostingView: NSHostingView<PetView> {
    var petContextMenu: NSMenu? {
        didSet {
            menu = petContextMenu
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showPetContextMenu(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showPetContextMenu(with: event)
            return
        }

        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        petContextMenu
    }

    private func showPetContextMenu(with event: NSEvent) {
        guard let petContextMenu else {
            super.rightMouseDown(with: event)
            return
        }

        NSMenu.popUpContextMenu(petContextMenu, with: event, for: self)
    }
}

struct PetView: View {
    @ObservedObject var viewModel: VibestickViewModel
    let spriteLayerView: MacPetSpriteLayerView
    let onHoverChanged: (Bool) -> Void
    @State private var isHovering = false

    init(
        viewModel: VibestickViewModel,
        spriteLayerView: MacPetSpriteLayerView,
        onHoverChanged: @escaping (Bool) -> Void)
    {
        self.viewModel = viewModel
        self.spriteLayerView = spriteLayerView
        self.onHoverChanged = onHoverChanged
    }

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
                onHoverChanged(hovering)
            }
            if viewModel.petCoders.isEmpty {
                statusBubble
            }
        }
        .padding(10)
    }

    private var sprite: some View {
        MacPetSpriteRepresentable(spriteLayerView: spriteLayerView)
            .frame(width: 194, height: 210)
    }

    private var taskCards: some View {
        VStack(spacing: 6) {
            ForEach(viewModel.petCoders, id: \.identity) { coder in
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

}

private struct MacPetSpriteRepresentable: NSViewRepresentable {
    let spriteLayerView: MacPetSpriteLayerView

    func makeNSView(context: Context) -> MacPetSpriteLayerView {
        spriteLayerView
    }

    func updateNSView(_ nsView: MacPetSpriteLayerView, context: Context) {
    }
}
