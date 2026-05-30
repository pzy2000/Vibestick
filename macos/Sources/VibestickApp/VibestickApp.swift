import AppKit
import SwiftUI
import UniformTypeIdentifiers
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

private enum PetPresenceMode {
    case normal
    case reduced
}

private enum PetFocusPreference: String {
    case automatic
    case on
    case off

    private static let defaultsKey = "VibestickPetFocusPreference"

    var menuLabel: String {
        switch self {
        case .automatic: "自动"
        case .on: "开启"
        case .off: "关闭"
        }
    }

    var next: PetFocusPreference {
        switch self {
        case .automatic: .on
        case .on: .off
        case .off: .automatic
        }
    }

    static func load() -> PetFocusPreference {
        let value = UserDefaults.standard.string(forKey: defaultsKey)
        return value.flatMap(PetFocusPreference.init(rawValue:)) ?? .automatic
    }

    static func save(_ preference: PetFocusPreference) {
        UserDefaults.standard.set(preference.rawValue, forKey: defaultsKey)
    }
}

struct MacPetActionFrequencySettings: Equatable {
    static let randomActionMinMultiplier: Double = 0.05
    static let randomActionStep: Double = 0.05
    static let minMultiplier: Double = 0.5
    static let maxMultiplier: Double = 2.0
    static let step: Double = 0.1
    static let defaultValue = MacPetActionFrequencySettings(
        randomActionFrequency: 1,
        walkSpeedMultiplier: 1,
        wanderFrequency: 1)

    static let randomActionFrequencyDefaultsKey = "VibestickPetRandomActionFrequency"
    static let walkSpeedMultiplierDefaultsKey = "VibestickPetWalkSpeedMultiplier"
    static let wanderFrequencyDefaultsKey = "VibestickPetWanderFrequency"

    var randomActionFrequency: Double
    var walkSpeedMultiplier: Double
    var wanderFrequency: Double

    var clamped: MacPetActionFrequencySettings {
        MacPetActionFrequencySettings(
            randomActionFrequency: Self.clampRandomActionFrequency(randomActionFrequency),
            walkSpeedMultiplier: Self.clamp(walkSpeedMultiplier),
            wanderFrequency: Self.clamp(wanderFrequency))
    }

    static func load(defaults: UserDefaults = .standard) -> MacPetActionFrequencySettings {
        MacPetActionFrequencySettings(
            randomActionFrequency: loadMultiplier(forKey: randomActionFrequencyDefaultsKey, defaults: defaults),
            walkSpeedMultiplier: loadMultiplier(forKey: walkSpeedMultiplierDefaultsKey, defaults: defaults),
            wanderFrequency: loadMultiplier(forKey: wanderFrequencyDefaultsKey, defaults: defaults)).clamped
    }

    func save(defaults: UserDefaults = .standard) {
        let settings = clamped
        defaults.set(settings.randomActionFrequency, forKey: Self.randomActionFrequencyDefaultsKey)
        defaults.set(settings.walkSpeedMultiplier, forKey: Self.walkSpeedMultiplierDefaultsKey)
        defaults.set(settings.wanderFrequency, forKey: Self.wanderFrequencyDefaultsKey)
    }

    func randomActionDelayRange(active: Bool) -> ClosedRange<TimeInterval> {
        let baseRange: ClosedRange<TimeInterval> = active ? 8...18 : 6...14
        return scaledRandomActionDelay(baseRange.lowerBound)...scaledRandomActionDelay(baseRange.upperBound)
    }

    func scaledRandomActionDelay(_ delay: TimeInterval) -> TimeInterval {
        max(0.1, delay / Self.clampRandomActionFrequency(randomActionFrequency))
    }

    func scaledWalkSpeed(_ speed: CGFloat) -> CGFloat {
        speed * CGFloat(Self.clamp(walkSpeedMultiplier))
    }

    func scaledWanderInterval(_ interval: TimeInterval) -> TimeInterval {
        max(0.1, interval / Self.clamp(wanderFrequency))
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else {
            return 1
        }
        let snapped = (value / step).rounded() * step
        return min(max(snapped, minMultiplier), maxMultiplier)
    }

    static func clampRandomActionFrequency(_ value: Double) -> Double {
        guard value.isFinite else {
            return 1
        }
        let snapped = (value / randomActionStep).rounded() * randomActionStep
        return min(max(snapped, randomActionMinMultiplier), maxMultiplier)
    }

    private static func loadMultiplier(forKey key: String, defaults: UserDefaults) -> Double {
        guard let value = defaults.object(forKey: key) as? NSNumber else {
            return 1
        }
        return value.doubleValue
    }
}

private struct PetFocusContext {
    let petFrame: NSRect?
    let petVisible: Bool
}

@MainActor
private final class PetFocusMonitor {
    private static let sampleInterval: TimeInterval = 1
    private static let enterDelay: TimeInterval = 2
    private static let exitDelay: TimeInterval = 5
    private static let keyboardRecentThreshold: CFTimeInterval = 0.75
    private static let mousePetPadding: CGFloat = 90
    private static let focusBundleIdentifiers = [
        "com.apple.FaceTime",
        "com.apple.iWork.Keynote",
        "com.cisco.webexmeetingsapp",
        "com.microsoft.Powerpoint",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tencent.meeting",
        "us.zoom.xos"
    ]
    private static let focusAppNameFragments = [
        "FaceTime",
        "Keynote",
        "Microsoft PowerPoint",
        "Microsoft Teams",
        "PowerPoint",
        "Tencent Meeting",
        "VooV",
        "Webex",
        "Zoom",
        "腾讯会议"
    ]

    private let contextProvider: () -> PetFocusContext
    private let reductionChanged: (Bool) -> Void
    private var timer: Timer?
    private var activeSince: Date?
    private var lastActiveAt: Date?
    private var isReduced = false
    private var keyboardActivitySamples = 0

    init(
        contextProvider: @escaping () -> PetFocusContext,
        reductionChanged: @escaping (Bool) -> Void
    ) {
        self.contextProvider = contextProvider
        self.reductionChanged = reductionChanged
    }

    func start() {
        stop()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sample()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let now = Date()
        let context = contextProvider()
        let active = isFocusContextActive(context)

        if active {
            if activeSince == nil {
                activeSince = now
            }
            lastActiveAt = now
        } else {
            activeSince = nil
        }

        var nextReduced = isReduced
        if !isReduced,
           let activeSince,
           now.timeIntervalSince(activeSince) >= Self.enterDelay {
            nextReduced = true
        } else if isReduced,
                  let lastActiveAt,
                  now.timeIntervalSince(lastActiveAt) >= Self.exitDelay {
            nextReduced = false
        }

        guard nextReduced != isReduced else {
            return
        }

        isReduced = nextReduced
        reductionChanged(nextReduced)
    }

    private func isFocusContextActive(_ context: PetFocusContext) -> Bool {
        let app = NSWorkspace.shared.frontmostApplication
        return isFocusApp(app)
            || isFrontmostWindowLarge(app)
            || isKeyboardActivityDense()
            || isMouseNearPet(context)
    }

    private func isFocusApp(_ app: NSRunningApplication?) -> Bool {
        guard let app, app.bundleIdentifier != VibestickPaths.bundleIdentifier else {
            return false
        }

        if let bundleIdentifier = app.bundleIdentifier,
           Self.focusBundleIdentifiers.contains(where: { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }) {
            return true
        }

        guard let name = app.localizedName else {
            return false
        }

        return Self.focusAppNameFragments.contains { fragment in
            name.range(of: fragment, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func isKeyboardActivityDense() -> Bool {
        let secondsSinceKey = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if secondsSinceKey <= Self.keyboardRecentThreshold {
            keyboardActivitySamples = min(keyboardActivitySamples + 1, 4)
        } else {
            keyboardActivitySamples = max(keyboardActivitySamples - 1, 0)
        }
        return keyboardActivitySamples >= 3
    }

    private func isMouseNearPet(_ context: PetFocusContext) -> Bool {
        guard context.petVisible, let petFrame = context.petFrame else {
            return false
        }
        return petFrame.insetBy(dx: -Self.mousePetPadding, dy: -Self.mousePetPadding).contains(NSEvent.mouseLocation)
    }

    private func isFrontmostWindowLarge(_ app: NSRunningApplication?) -> Bool {
        guard let app,
              app.bundleIdentifier != VibestickPaths.bundleIdentifier,
              let windowList = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID) as? [[String: Any]]
        else {
            return false
        }

        for window in windowList {
            guard
                (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                windowLooksLarge(bounds)
            else {
                continue
            }
            return true
        }

        return false
    }

    private func windowLooksLarge(_ bounds: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let frame = screen.frame
            let visibleFrame = screen.visibleFrame
            let fillsScreen = bounds.width >= frame.width * 0.94 && bounds.height >= frame.height * 0.90
            let fillsVisibleArea = bounds.width >= visibleFrame.width * 0.96 && bounds.height >= visibleFrame.height * 0.94
            return fillsScreen || fillsVisibleArea
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewModel = VibestickViewModel()
    private var statusItem: NSStatusItem?
    private var modeSummaryMenuItem: NSMenuItem?
    private var taskSummaryMenuItem: NSMenuItem?
    private var petSummaryMenuItem: NSMenuItem?
    private var walkingSummaryMenuItem: NSMenuItem?
    private var focusSummaryMenuItem: NSMenuItem?
    private var petToggleMenuItem: NSMenuItem?
    private var petWalkingMenuItem: NSMenuItem?
    private var petCardModeMenuItem: NSMenuItem?
    private var petFocusModeMenuItem: NSMenuItem?
    private var petResetPositionMenuItem: NSMenuItem?
    private var petLibrarySummaryMenuItem: NSMenuItem?
    private var petWindow: PetPanel?
    private var screenParametersObserver: NSObjectProtocol?
    private var focusMonitor: PetFocusMonitor?
    private var focusPreference = PetFocusPreference.load()
    private var autoFocusReduced = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel.menuStateDidChange = { [weak self] in
            self?.updateStatusItemState()
        }
        viewModel.petLibraryChanged = { [weak self] in
            self?.petWindow?.reloadPetSprite()
            self?.updateStatusItemState()
        }
        viewModel.petActionFrequencyChanged = { [weak self] settings in
            self?.petWindow?.applyActionFrequencySettings(settings)
        }
        setupStatusItem()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main)
        { [weak self] _ in
            Task { @MainActor in
                self?.petWindow?.screenParametersDidChange()
                self?.updateStatusItemState()
            }
        }
        startFocusMonitor()
        showPet()
        viewModel.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        screenParametersObserver = nil
        focusMonitor?.stop()
        focusMonitor = nil
        viewModel.shutdown()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()

        let modeSummary = disabledMenuItem("")
        menu.addItem(modeSummary)
        modeSummaryMenuItem = modeSummary

        let taskSummary = disabledMenuItem("")
        menu.addItem(taskSummary)
        taskSummaryMenuItem = taskSummary

        let petSummary = disabledMenuItem("")
        menu.addItem(petSummary)
        petSummaryMenuItem = petSummary

        let walkingSummary = disabledMenuItem("")
        menu.addItem(walkingSummary)
        walkingSummaryMenuItem = walkingSummary

        let focusSummary = disabledMenuItem("")
        menu.addItem(focusSummary)
        focusSummaryMenuItem = focusSummary

        let petLibrarySummary = disabledMenuItem("")
        menu.addItem(petLibrarySummary)
        petLibrarySummaryMenuItem = petLibrarySummary

        menu.addItem(.separator())

        let openControlPanel = NSMenuItem(title: "打开控制面板", action: #selector(openControlPanel), keyEquivalent: "")
        openControlPanel.target = self
        menu.addItem(openControlPanel)

        let refresh = NSMenuItem(title: "刷新状态", action: #selector(refreshStatus), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)

        let petToggle = NSMenuItem(title: "显示桌宠", action: #selector(togglePetAction), keyEquivalent: "")
        petToggle.target = self
        menu.addItem(petToggle)
        petToggleMenuItem = petToggle

        let petWalking = NSMenuItem(title: "", action: #selector(togglePetWalkingAction), keyEquivalent: "")
        petWalking.target = self
        menu.addItem(petWalking)
        petWalkingMenuItem = petWalking

        let petCardMode = NSMenuItem(title: "", action: #selector(cyclePetCardModeAction), keyEquivalent: "")
        petCardMode.target = self
        menu.addItem(petCardMode)
        petCardModeMenuItem = petCardMode

        let petFocusMode = NSMenuItem(title: "", action: #selector(cyclePetFocusPreferenceAction), keyEquivalent: "")
        petFocusMode.target = self
        menu.addItem(petFocusMode)
        petFocusModeMenuItem = petFocusMode

        let resetPosition = NSMenuItem(title: "重置桌宠位置", action: #selector(resetPetPositionAction), keyEquivalent: "")
        resetPosition.target = self
        menu.addItem(resetPosition)
        petResetPositionMenuItem = resetPosition

        let importPet = NSMenuItem(title: "导入宠物...", action: #selector(importPetAction), keyEquivalent: "")
        importPet.target = self
        menu.addItem(importPet)

        let exportPet = NSMenuItem(title: "导出当前宠物...", action: #selector(exportPetAction), keyEquivalent: "")
        exportPet.target = self
        menu.addItem(exportPet)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
        updateStatusItemState()
    }

    private func disabledMenuItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func openControlPanel() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first { !($0 is PetPanel) }?.makeKeyAndOrderFront(nil)
    }

    @objc private func refreshStatus() {
        viewModel.refresh()
    }

    @objc private func togglePetAction() {
        togglePet()
    }

    @objc private func togglePetWalkingAction() {
        petWindow?.toggleWalking()
        updateStatusItemState()
    }

    @objc private func cyclePetCardModeAction() {
        petWindow?.cycleCardDisplayMode()
        updateStatusItemState()
    }

    @objc private func resetPetPositionAction() {
        petWindow?.resetPetPosition()
        updateStatusItemState()
    }

    @objc private func cyclePetFocusPreferenceAction() {
        cycleFocusPreference()
    }

    @objc private func importPetAction() {
        viewModel.importPetFromDialog()
    }

    @objc private func exportPetAction() {
        viewModel.exportCurrentPetFromDialog()
    }

    private func showPet() {
        if petWindow == nil {
            petWindow = PetPanel(
                viewModel: viewModel,
                openControlPanel: { [weak self] in self?.openControlPanel() },
                hidePet: { [weak self] in self?.hidePet() },
                importPet: { [weak self] in self?.viewModel.importPetFromDialog() },
                exportPet: { [weak self] in self?.viewModel.exportCurrentPetFromDialog() },
                quitApplication: { [weak self] in self?.quit() },
                cycleFocusPreference: { [weak self] in self?.cycleFocusPreference() },
                focusActionTitle: { [weak self] in self?.focusActionTitle ?? "勿扰模式：自动" },
                menuStateDidChange: { [weak self] in self?.updateStatusItemState() })
        }
        petWindow?.orderFrontRegardless()
        petWindow?.startWalking()
        applyFocusPresence()
        updateStatusItemState()
    }

    private func hidePet() {
        guard let petWindow else {
            updateStatusItemState()
            return
        }

        petWindow.close()
        self.petWindow = nil
        updateStatusItemState()
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

    private func updateStatusItemState() {
        updateStatusIcon()
        updateSummaryMenuItems()
        updatePetToggleMenuTitle()

        let petVisible = petWindow?.isVisible == true
        petWalkingMenuItem?.title = petWindow?.walkingActionTitle ?? (PetPanel.savedWalkingEnabled ? "暂停行走" : "恢复行走")
        petWalkingMenuItem?.isEnabled = petVisible
        petCardModeMenuItem?.title = petWindow?.cardDisplayModeActionTitle ?? "切换任务卡"
        petCardModeMenuItem?.isEnabled = petVisible
        petFocusModeMenuItem?.title = focusActionTitle
        petFocusModeMenuItem?.isEnabled = petVisible
        petResetPositionMenuItem?.isEnabled = petVisible
        petWindow?.refreshFocusPreferenceMenuText()
    }

    private func updateSummaryMenuItems() {
        let activeTaskCount = viewModel.activeTaskCount
        modeSummaryMenuItem?.title = "模式：\(viewModel.menuModeText)"
        taskSummaryMenuItem?.title = activeTaskCount == 0 ? "任务：无活跃任务" : "任务：\(activeTaskCount) 个活跃任务"
        petSummaryMenuItem?.title = "桌宠：\(petWindow?.isVisible == true ? "显示" : "隐藏")"
        walkingSummaryMenuItem?.title = "行走：\((petWindow?.isWalkingEnabled ?? PetPanel.savedWalkingEnabled) ? "行走中" : "暂停")"
        focusSummaryMenuItem?.title = "勿扰：\(focusSummaryText)"
        petLibrarySummaryMenuItem?.title = "宠物：\(viewModel.currentPet.displayName)"
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else {
            return
        }

        if let image = statusImage(named: statusSymbolName()) ?? statusImage(named: "circle.fill") {
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.imagePosition = .noImage
            button.title = "V"
        }
        button.toolTip = "Vibestick - \(viewModel.menuModeText)"
    }

    private func statusImage(named symbolName: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Vibestick") else {
            return nil
        }
        image.isTemplate = true
        return image
    }

    private func statusSymbolName() -> String {
        if viewModel.hasErrorCoder {
            return "exclamationmark.triangle.fill"
        }
        if viewModel.hasWaitingCoder {
            return "hand.raised.fill"
        }
        if viewModel.hasActiveCoderWork {
            return "terminal.fill"
        }
        switch viewModel.menuActiveMode {
        case .hyper:
            return "bolt.fill"
        case .on:
            return "powerplug.fill"
        case .off:
            return "circle.fill"
        }
    }

    private var focusActionTitle: String {
        "勿扰模式：\(focusPreference.menuLabel)"
    }

    private var focusSummaryText: String {
        switch focusPreference {
        case .automatic:
            return autoFocusReduced ? "已降低" : "自动"
        case .on:
            return "开启"
        case .off:
            return "关闭"
        }
    }

    private func startFocusMonitor() {
        focusMonitor = PetFocusMonitor(
            contextProvider: { [weak self] in
                guard let self else {
                    return PetFocusContext(petFrame: nil, petVisible: false)
                }
                return PetFocusContext(
                    petFrame: self.petWindow?.isVisible == true ? self.petWindow?.frame : nil,
                    petVisible: self.petWindow?.isVisible == true)
            },
            reductionChanged: { [weak self] reduced in
                self?.autoFocusReduced = reduced
                self?.applyFocusPresence()
                self?.updateStatusItemState()
            })
        focusMonitor?.start()
    }

    private func cycleFocusPreference() {
        focusPreference = focusPreference.next
        PetFocusPreference.save(focusPreference)
        applyFocusPresence()
        updateStatusItemState()
    }

    private func applyFocusPresence() {
        let shouldReduce: Bool
        switch focusPreference {
        case .automatic:
            shouldReduce = autoFocusReduced
        case .on:
            shouldReduce = true
        case .off:
            shouldReduce = false
        }
        petWindow?.setPresenceMode(shouldReduce ? .reduced : .normal)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

struct VibestickAppConfiguration {
    let coderStatusDirectory: URL
    let codexSessionsRoot: URL
    let enableCodexMonitor: Bool

    static func fromProcess(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VibestickAppConfiguration {
        let statusPath = option("--status-dir", in: arguments) ?? environment["VIBESTICK_CODER_STATUS_DIR"]
        let sessionsPath = option("--codex-sessions-dir", in: arguments) ?? environment["VIBESTICK_CODEX_SESSIONS_DIR"]
        return VibestickAppConfiguration(
            coderStatusDirectory: statusPath.map { URL(fileURLWithPath: $0) } ?? VibestickPaths.coderStatusDirectory,
            codexSessionsRoot: sessionsPath.map { URL(fileURLWithPath: $0) } ?? CodexSessionPaths.defaultSessionsRoot,
            enableCodexMonitor: !hasFlag("--no-codex-monitor", in: arguments))
    }

    private static func option(_ name: String, in arguments: [String]) -> String? {
        for index in arguments.indices {
            let value = arguments[index]
            if value == name,
               arguments.indices.contains(arguments.index(after: index)) {
                return arguments[arguments.index(after: index)]
            }

            let prefix = "\(name)="
            if value.hasPrefix(prefix) {
                return String(value.dropFirst(prefix.count))
            }
        }

        return nil
    }

    private static func hasFlag(_ name: String, in arguments: [String]) -> Bool {
        arguments.contains(name)
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
    @Published var pets: [PetDefinition] = []
    @Published var currentPet: PetDefinition
    @Published var petLibraryMessage = ""
    @Published var petPreviewImage: NSImage?
    @Published var helperInstallMessage = ""
    @Published var isInstallingHelper = false
    @Published var firstLaunchInstallText = ""
    @Published var shouldShowFirstLaunchInstall = false
    @Published var canCompleteFirstLaunchInstall = false
    @Published var isCompletingFirstLaunchInstall = false
    @Published var deviceWatcherStatusText = "正在读取插盘自启状态..."
    @Published var deviceWatcherMessage = ""
    @Published var isInstallingDeviceWatcher = false
    @Published var petActionFrequencySettings = MacPetActionFrequencySettings.load()
    var menuStateDidChange: (() -> Void)?
    var petLibraryChanged: (() -> Void)?
    var petActionFrequencyChanged: ((MacPetActionFrequencySettings) -> Void)?
    private(set) var activeTaskCount = 0

    private let assertionManager: MacSleepAssertionManager
    private let engine: VibestickMacEngine
    private let doctor: MacDoctorService
    private let firstLaunchInstaller: FirstLaunchInstaller
    private let helperInstaller: HelperInstalling
    private let deviceWatcherInstaller: DeviceWatcherInstalling
    let petLibrary: PetLibrary
    private let coderSource: CompositeCoderStatusSource
    private let codexStatusBridge: CodexSessionStatusBridge?
    private let petResolver = PetStateResolver()
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var coderRefreshTask: Task<Void, Never>?
    private var latestStatus: VibestickStatus?

    var menuActiveMode: VibestickMode {
        latestStatus?.activeMode ?? .off
    }

    var menuModeText: String {
        displayMode(menuActiveMode)
    }

    var hasErrorCoder: Bool {
        petMood == "error" || petCoders.contains { $0.phase == .error }
    }

    var hasWaitingCoder: Bool {
        petMood == "waiting" || petCoders.contains { $0.phase == .waitingAuthorization }
    }

    var hasActiveCoderWork: Bool {
        activeTaskCount > 0
    }

    init(configuration: VibestickAppConfiguration = .fromProcess()) {
        let helper = SubprocessHelperClient(statusRunner: ProcessCommandRunner(timeoutSeconds: 3))
        let battery = MacBatteryMonitor()
        let processInspector = MacProcessInspector()
        let assertionManager = MacSleepAssertionManager()
        let helperInstaller = MacHelperInstaller()
        let deviceWatcherInstaller = MacDeviceWatcherInstaller()
        let petLibrary = PetLibrary()
        self.assertionManager = assertionManager
        self.helperInstaller = helperInstaller
        self.deviceWatcherInstaller = deviceWatcherInstaller
        self.petLibrary = petLibrary
        self.currentPet = petLibrary.currentPet()
        self.firstLaunchInstaller = FirstLaunchInstaller(
            appPath: Bundle.main.bundleURL.path,
            helperInstaller: helperInstaller,
            deviceWatcherInstaller: deviceWatcherInstaller)
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
        self.codexStatusBridge = configuration.enableCodexMonitor
            ? CodexSessionStatusBridge(
                statusDirectory: configuration.coderStatusDirectory,
                sessionsRoot: configuration.codexSessionsRoot)
            : nil
        self.coderSource = CompositeCoderStatusSource([
            JsonFileCoderStatusSource(directory: configuration.coderStatusDirectory),
            ProcessCoderStatusSource(processInspector: processInspector, processNames: VibestickOptions().longTaskProcessNames)
        ])
        self.codexStatusBridge?.start()
        self.refreshPetLibrary()
        self.refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func refresh() {
        refreshCoderPet()
        refreshSystemStatus()
        refreshPetLibrary()
    }

    func refreshPetLibrary() {
        pets = petLibrary.pets()
        currentPet = petLibrary.currentPet()
        petPreviewImage = petLibrary.previewImage(for: currentPet)
        menuStateDidChange?()
    }

    func selectPet(id: String) {
        do {
            try petLibrary.selectPet(id: id)
            petLibraryMessage = "已切换到 \(petLibrary.currentPet().displayName)。"
            refreshPetLibrary()
            petLibraryChanged?()
        } catch {
            petLibraryMessage = friendlyError(error.localizedDescription)
            refreshPetLibrary()
        }
    }

    func setRandomActionFrequency(_ value: Double) {
        updatePetActionFrequencySettings {
            $0.randomActionFrequency = value
        }
    }

    func setWalkSpeedMultiplier(_ value: Double) {
        updatePetActionFrequencySettings {
            $0.walkSpeedMultiplier = value
        }
    }

    func setWanderFrequency(_ value: Double) {
        updatePetActionFrequencySettings {
            $0.wanderFrequency = value
        }
    }

    private func updatePetActionFrequencySettings(_ update: (inout MacPetActionFrequencySettings) -> Void) {
        var settings = petActionFrequencySettings
        update(&settings)
        settings = settings.clamped
        guard settings != petActionFrequencySettings else {
            return
        }

        petActionFrequencySettings = settings
        settings.save()
        petActionFrequencyChanged?(settings)
        menuStateDidChange?()
    }

    func importPetFromDialog() {
        let panel = NSOpenPanel()
        panel.title = "导入 Vibestick 宠物"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .png, .webP]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        importPet(from: url, replace: false, metadata: nil)
    }

    func exportCurrentPetFromDialog() {
        let pet = currentPet
        let panel = NSSavePanel()
        panel.title = "导出 Vibestick 宠物"
        panel.nameFieldStringValue = "\(pet.id).vibestick-pet.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try petLibrary.exportPet(id: pet.id, to: url)
            petLibraryMessage = "已导出 \(pet.displayName)。"
        } catch {
            petLibraryMessage = friendlyError(error.localizedDescription)
        }
    }

    func deleteCurrentCustomPet() {
        guard !currentPet.isBuiltIn else {
            petLibraryMessage = "内置宠物不能删除。"
            return
        }

        let alert = NSAlert()
        alert.messageText = "删除 \(currentPet.displayName)？"
        alert.informativeText = "此操作不能撤销。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            try petLibrary.deleteCustomPet(id: currentPet.id)
            petLibraryMessage = "已删除自定义宠物，已切回内置宠物。"
            refreshPetLibrary()
            petLibraryChanged?()
        } catch {
            petLibraryMessage = friendlyError(error.localizedDescription)
        }
    }

    private func importPet(from url: URL, replace: Bool, metadata: PetImportMetadata?) {
        do {
            let imported: PetDefinition
            if ["png", "webp"].contains(url.pathExtension.lowercased()) {
                guard let metadata = metadata ?? promptPetMetadata(suggestedName: url.deletingPathExtension().lastPathComponent) else {
                    return
                }
                imported = try petLibrary.importRawAtlas(url, metadata: metadata, replace: replace)
            } else {
                imported = try petLibrary.importPackage(url, replace: replace)
            }

            petLibraryMessage = "已导入并切换到 \(imported.displayName)。"
            refreshPetLibrary()
            petLibraryChanged?()
        } catch PetLibraryError.duplicate(let id) {
            let alert = NSAlert()
            alert.messageText = "宠物“\(id)”已存在。"
            alert.informativeText = "是否替换已有宠物？"
            alert.addButton(withTitle: "替换")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                importPet(from: url, replace: true, metadata: metadata)
            }
        } catch {
            petLibraryMessage = friendlyError(error.localizedDescription)
        }
    }

    private func promptPetMetadata(suggestedName: String) -> PetImportMetadata? {
        let nameField = NSTextField(string: suggestedName.isEmpty ? "Imported Pet" : suggestedName)
        let descriptionField = NSTextField(string: "Imported Vibestick pet.")
        nameField.frame = NSRect(x: 0, y: 34, width: 280, height: 24)
        descriptionField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 62))
        container.addSubview(nameField)
        container.addSubview(descriptionField)

        let alert = NSAlert()
        alert.messageText = "导入宠物 Atlas"
        alert.informativeText = "填写宠物名称和描述。"
        alert.accessoryView = container
        alert.addButton(withTitle: "导入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return nil
        }

        return PetImportMetadata(
            displayName: nameField.stringValue,
            description: descriptionField.stringValue)
    }

    private func refreshCoderPet() {
        guard coderRefreshTask == nil else {
            return
        }

        let coderSource = coderSource
        let petResolver = petResolver
        let status = latestStatus ?? Self.defaultPetStatus()
        coderRefreshTask = Task(priority: .utility) { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let coders = coderSource.getStatuses(now: Date())
                let pet = petResolver.resolve(status: status, coders: coders)
                return (coders, pet)
            }.value

            guard !Task.isCancelled else {
                return
            }
            self?.finishCoderRefresh(coders: result.0, pet: result.1)
        }
    }

    private func refreshSystemStatus() {
        guard refreshTask == nil else {
            return
        }

        let engine = engine
        let helperInstaller = helperInstaller
        let deviceWatcherInstaller = deviceWatcherInstaller
        let firstLaunchInstaller = firstLaunchInstaller
        refreshTask = Task(priority: .utility) { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let status = engine.status()
                let helperPreflight = helperInstaller.preflight()
                let deviceWatcherStatus = deviceWatcherInstaller.status()
                let firstLaunchStatus = firstLaunchInstaller.status()
                return (status, helperPreflight, deviceWatcherStatus, firstLaunchStatus)
            }.value

            guard !Task.isCancelled else {
                return
            }
            self?.finishSystemRefresh(
                status: result.0,
                helperPreflight: result.1,
                deviceWatcherStatus: result.2,
                firstLaunchStatus: result.3)
        }
    }

    private func finishSystemRefresh(
        status: VibestickStatus,
        helperPreflight: HelperInstallPreflight,
        deviceWatcherStatus: DeviceWatcherInstallStatus,
        firstLaunchStatus: FirstLaunchInstallStatus)
    {
        refreshTask = nil
        latestStatus = status
        statusText = formatStatus(status, helperPreflight: helperPreflight)
        deviceWatcherStatusText = formatDeviceWatcherStatus(deviceWatcherStatus)
        firstLaunchInstallText = formatFirstLaunchStatus(firstLaunchStatus)
        shouldShowFirstLaunchInstall = firstLaunchStatus.location.kind == .mountedVolume || firstLaunchStatus.needsInstall
        canCompleteFirstLaunchInstall = firstLaunchStatus.needsInstall && firstLaunchStatus.canCompleteInstall
        menuStateDidChange?()
        refreshCoderPet()
    }

    private func finishCoderRefresh(coders: [CoderAgentStatus], pet: PetState) {
        coderRefreshTask = nil
        activeTaskCount = coders.filter { Self.isMenuActivePhase($0.phase) }.count
        petMood = pet.mood
        petTitle = pet.title
        petMessage = pet.message
        petCoders = Array(coders.prefix(3))
        menuStateDidChange?()
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

    func shutdown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        refreshTask?.cancel()
        refreshTask = nil
        coderRefreshTask?.cancel()
        coderRefreshTask = nil
        codexStatusBridge?.stop()
        assertionManager.endHyperAssertion()
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

    func completeFirstLaunchInstall() {
        guard !isCompletingFirstLaunchInstall else {
            return
        }

        isCompletingFirstLaunchInstall = true
        firstLaunchInstallText = "正在完成 Helper 和插盘自启安装..."
        let installer = firstLaunchInstaller

        Task.detached {
            let result = Result { try installer.completeInstall() }
            await MainActor.run {
                self.isCompletingFirstLaunchInstall = false
                switch result {
                case .success(let installResult):
                    self.firstLaunchInstallText = installResult.message
                    self.helperInstallMessage = installResult.message
                    self.deviceWatcherMessage = installResult.message
                    self.refresh()
                    self.runDoctor()
                case .failure(let error):
                    self.firstLaunchInstallText = error.localizedDescription
                    self.runDoctor()
                    self.refresh()
                }
            }
        }
    }

    func installDeviceWatcher() {
        guard !isInstallingDeviceWatcher else {
            return
        }

        isInstallingDeviceWatcher = true
        deviceWatcherMessage = "正在安装插盘自启 LaunchAgent..."
        let installer = deviceWatcherInstaller

        Task.detached {
            let result = Result { try installer.install() }
            await MainActor.run {
                self.isInstallingDeviceWatcher = false
                switch result {
                case .success(let installResult):
                    self.deviceWatcherMessage = installResult.message
                case .failure(let error):
                    self.deviceWatcherMessage = error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    func uninstallDeviceWatcher() {
        guard !isInstallingDeviceWatcher else {
            return
        }

        isInstallingDeviceWatcher = true
        deviceWatcherMessage = "正在卸载插盘自启 LaunchAgent..."
        let installer = deviceWatcherInstaller

        Task.detached {
            let result = Result { try installer.uninstall() }
            await MainActor.run {
                self.isInstallingDeviceWatcher = false
                switch result {
                case .success(let uninstallResult):
                    self.deviceWatcherMessage = uninstallResult.message
                case .failure(let error):
                    self.deviceWatcherMessage = error.localizedDescription
                }
                self.refresh()
            }
        }
    }

    private static func defaultPetStatus() -> VibestickStatus {
        VibestickStatus(
            activeMode: .off,
            restorePending: false,
            pmset: nil,
            battery: BatteryInfo(percentage: nil, isACConnected: false, isAvailable: false),
            longTasks: [],
            assertionActive: false,
            warnings: [])
    }

    private static func isMenuActivePhase(_ phase: CoderAgentPhase) -> Bool {
        PetStateResolver.isActiveTaskPhase(phase)
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

    private func formatDeviceWatcherStatus(_ status: DeviceWatcherInstallStatus) -> String {
        if status.isInstalled {
            return "已启用：插入 Vibestick RP2040 会启动或聚焦 app。"
        }
        if status.isReadyToInstall {
            return "未启用：可安装当前 app 的用户级 LaunchAgent。"
        }
        if !status.watcherExecutableExists {
            return "不可安装：找不到 VibestickDeviceWatcher，请先重新构建 app。"
        }
        if !status.appExists {
            return "不可安装：找不到 Vibestick.app，请先构建或安装 app。"
        }
        return "未启用。"
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

    private func formatFirstLaunchStatus(_ status: FirstLaunchInstallStatus) -> String {
        switch status.location.kind {
        case .mountedVolume:
            return "请先把 Vibestick 拖到 Applications 后再打开，才能完成 Helper 和插盘自启安装。"
        case .other:
            return "请把 Vibestick.app 移到 Applications 后再完成安装。"
        case .systemApplications, .userApplications:
            break
        }

        if !status.needsInstall {
            return "Vibestick 安装已完成。"
        }

        if !status.canCompleteInstall {
            return "安装资源缺失，请重新构建或重新下载 Vibestick。"
        }

        return "还需完成：\(status.missingComponentNames.joined(separator: "、"))。点击“完成安装”后会先请求管理员授权安装 Helper，再启用插盘自启。"
    }
}

struct ControlPanelView: View {
    @ObservedObject var viewModel: VibestickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if viewModel.shouldShowFirstLaunchInstall {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.firstLaunchInstallText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(viewModel.isCompletingFirstLaunchInstall ? "安装中..." : "完成安装") {
                        viewModel.completeFirstLaunchInstall()
                    }
                    .disabled(!viewModel.canCompleteFirstLaunchInstall || viewModel.isCompletingFirstLaunchInstall)
                }
                .padding(.bottom, 4)

                Divider()
            }

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

            VStack(alignment: .leading, spacing: 8) {
                Text("插盘自启：\(viewModel.deviceWatcherStatusText)")
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button(viewModel.isInstallingDeviceWatcher ? "处理中..." : "启用插盘自启") {
                        viewModel.installDeviceWatcher()
                    }
                    .disabled(viewModel.isInstallingDeviceWatcher)
                    Button("关闭插盘自启") {
                        viewModel.uninstallDeviceWatcher()
                    }
                    .disabled(viewModel.isInstallingDeviceWatcher)
                }
                if !viewModel.deviceWatcherMessage.isEmpty {
                    Text(viewModel.deviceWatcherMessage)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("宠物库")
                    .font(.headline)
                HStack(alignment: .center, spacing: 12) {
                    if let image = viewModel.petPreviewImage {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 54, height: 58)
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.secondary.opacity(0.16))
                            .frame(width: 54, height: 58)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(viewModel.currentPet.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        Text(viewModel.currentPet.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Picker("当前宠物", selection: Binding(
                    get: { viewModel.currentPet.id },
                    set: { viewModel.selectPet(id: $0) }))
                {
                    ForEach(viewModel.pets) { pet in
                        Text(pet.isBuiltIn ? "\(pet.displayName)（内置）" : pet.displayName)
                            .tag(pet.id)
                    }
                }
                .pickerStyle(.menu)
                HStack {
                    Button("导入宠物") { viewModel.importPetFromDialog() }
                    Button("导出当前") { viewModel.exportCurrentPetFromDialog() }
                    Button("删除自定义") { viewModel.deleteCurrentCustomPet() }
                        .disabled(viewModel.currentPet.isBuiltIn)
                }
                if !viewModel.petLibraryMessage.isEmpty {
                    Text(viewModel.petLibraryMessage)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("宠物动作频率")
                    .font(.headline)
                PetFrequencySlider(
                    title: "随机动作频率",
                    range: MacPetActionFrequencySettings.randomActionMinMultiplier...MacPetActionFrequencySettings.maxMultiplier,
                    step: MacPetActionFrequencySettings.randomActionStep,
                    value: Binding(
                        get: { viewModel.petActionFrequencySettings.randomActionFrequency },
                        set: { viewModel.setRandomActionFrequency($0) }))
                PetFrequencySlider(
                    title: "行走速度",
                    value: Binding(
                        get: { viewModel.petActionFrequencySettings.walkSpeedMultiplier },
                        set: { viewModel.setWalkSpeedMultiplier($0) }))
                PetFrequencySlider(
                    title: "游荡/停顿频率",
                    value: Binding(
                        get: { viewModel.petActionFrequencySettings.wanderFrequency },
                        set: { viewModel.setWanderFrequency($0) }))
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

private struct PetFrequencySlider: View {
    let title: String
    var range: ClosedRange<Double> = MacPetActionFrequencySettings.minMultiplier...MacPetActionFrequencySettings.maxMultiplier
    var step: Double = MacPetActionFrequencySettings.step
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formattedMultiplier(value))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $value,
                in: range,
                step: step)
        }
    }

    private func formattedMultiplier(_ value: Double) -> String {
        if value < 0.1 {
            return String(format: "%.2fx", value)
        }
        return String(format: "%.1fx", value)
    }
}

@MainActor
private enum PetCardDisplayMode: String {
    case hidden
    case compact
    case full

    var menuLabel: String {
        switch self {
        case .hidden: "隐藏"
        case .compact: "紧凑"
        case .full: "完整"
        }
    }

    var next: PetCardDisplayMode {
        switch self {
        case .hidden: .compact
        case .compact: .full
        case .full: .hidden
        }
    }

    var expanded: PetCardDisplayMode {
        switch self {
        case .hidden: .compact
        case .compact, .full: .full
        }
    }

    var collapsed: PetCardDisplayMode {
        switch self {
        case .hidden, .compact: .hidden
        case .full: .compact
        }
    }
}

@MainActor
private final class PetPanelState: ObservableObject {
    @Published var cardDisplayMode: PetCardDisplayMode
    @Published var isPresenceReduced: Bool
    @Published var scale: CGFloat
    @Published var resizeHandleVisible: Bool

    init(
        cardDisplayMode: PetCardDisplayMode,
        isPresenceReduced: Bool = false,
        scale: CGFloat = MacPetResizeGeometry.defaultScale,
        resizeHandleVisible: Bool = false)
    {
        self.cardDisplayMode = cardDisplayMode
        self.isPresenceReduced = isPresenceReduced
        self.scale = MacPetResizeGeometry.clampedScale(scale)
        self.resizeHandleVisible = resizeHandleVisible
    }
}

private struct PetPresenceSnapshot {
    let frame: NSRect
    let retainedScreenIdentifier: String?
}

enum MacPetWalkGeometry {
    static let spriteLaneWidth: CGFloat = 220

    static func walkBounds(
        visibleFrame: NSRect,
        panelWidth: CGFloat,
        spriteLaneWidth: CGFloat = spriteLaneWidth
    ) -> (minX: CGFloat, maxX: CGFloat) {
        let sideOverhang = max((panelWidth - spriteLaneWidth) / 2, 0)
        let minX = visibleFrame.minX - sideOverhang
        let maxX = max(minX, visibleFrame.maxX - panelWidth + sideOverhang)
        return (minX, maxX)
    }
}

enum MacPetResizeGeometry {
    static let defaultScale: CGFloat = 1.0
    static let minScale: CGFloat = 0.35
    static let maxScale: CGFloat = 1.5
    static let dragDivisor: CGFloat = 220
    static let hitPadding: CGFloat = 16
    static let handleSize: CGFloat = 34
    static let handleHitPadding: CGFloat = 6
    static let handleTrailingOffset: CGFloat = 12
    static let handleBottomOffset: CGFloat = -4
    static let basePanelSize = CGSize(width: 356, height: 476)
    static let baseSpriteLaneSize = CGSize(width: MacPetWalkGeometry.spriteLaneWidth, height: 210)

    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else {
            return defaultScale
        }
        return min(max(scale, minScale), maxScale)
    }

    static func scale(startScale: CGFloat, dragDelta: NSPoint) -> CGFloat {
        let dominantDelta = abs(dragDelta.x) >= abs(dragDelta.y) ? dragDelta.x : dragDelta.y
        return clampedScale(startScale + dominantDelta / dragDivisor)
    }

    static func scaledSize(baseSize: CGSize, scale: CGFloat) -> CGSize {
        let clamped = clampedScale(scale)
        return CGSize(width: baseSize.width * clamped, height: baseSize.height * clamped)
    }

    static func spriteFrame(hostBounds: NSRect, scale: CGFloat) -> NSRect {
        let size = scaledSize(baseSize: baseSpriteLaneSize, scale: scale)
        return NSRect(
            x: hostBounds.midX - size.width / 2,
            y: hitPadding * clampedScale(scale),
            width: size.width,
            height: size.height)
    }

    static func handleFrame(spriteFrame: NSRect, scale: CGFloat) -> NSRect {
        let clamped = clampedScale(scale)
        let side = handleSize * clamped
        return NSRect(
            x: spriteFrame.maxX + handleTrailingOffset * clamped - side,
            y: spriteFrame.minY + handleBottomOffset * clamped,
            width: side,
            height: side)
    }

    static func hitFrame(handleFrame: NSRect, scale: CGFloat) -> NSRect {
        handleFrame.insetBy(dx: -handleHitPadding * clampedScale(scale), dy: -handleHitPadding * clampedScale(scale))
    }

    static func isResizeHit(point: NSPoint, handleFrame: NSRect, scale: CGFloat = defaultScale) -> Bool {
        hitFrame(handleFrame: handleFrame, scale: scale).contains(point)
    }
}

@MainActor
final class PetPanel: NSPanel, NSMenuDelegate {
    private static let walkingEnabledDefaultsKey = "VibestickPetWalkingEnabled"
    private static let originXDefaultsKey = "VibestickPetWindowOriginX"
    private static let originYDefaultsKey = "VibestickPetWindowOriginY"
    private static let screenIdentifierDefaultsKey = "VibestickPetScreenIdentifier"
    private static let cardDisplayModeDefaultsKey = "VibestickPetCardDisplayMode"
    private static let scaleDefaultsKey = "VibestickPetWindowScale"
    private static let defaultFrame = NSRect(
        x: 120,
        y: 120,
        width: MacPetResizeGeometry.basePanelSize.width,
        height: MacPetResizeGeometry.basePanelSize.height)

    private let viewModel: VibestickViewModel
    private let openControlPanel: () -> Void
    private let hidePet: () -> Void
    private let importPet: () -> Void
    private let exportPet: () -> Void
    private let quitApplication: () -> Void
    private let cycleFocusPreference: () -> Void
    private let focusActionTitle: () -> String
    private let menuStateDidChange: () -> Void
    private let walkingToggleMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let cardDisplayModeMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let focusModeMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let panelState = PetPanelState(
        cardDisplayMode: PetPanel.loadCardDisplayMode(),
        scale: PetPanel.loadSavedScale())
    private let spriteAnimator = MacPetSpriteAnimator()
    private let spriteLayerView = MacPetSpriteLayerView()
    private var displayLink: MacPetDisplayLink?
    private var pauseUntil: Date?
    private var lastTick: Date?
    private var nextWanderAt: Date?
    private var direction: MacPetCrawlDirection = .left
    private var manualDragDirection: MacPetCrawlDirection?
    private var walkingAnimationDirection: MacPetCrawlDirection?
    private var actionFrequencySettings = MacPetActionFrequencySettings.load()
    private var currentWalkSpeed: CGFloat = 0
    private var crawlAnimationSuppressed = false
    private var walkingEnabled = PetPanel.loadWalkingEnabled()
    private var spriteHovering = false
    private var retainedScreenIdentifier = PetPanel.loadSavedScreenIdentifier()
    private var presenceMode: PetPresenceMode = .normal
    private var presenceSnapshot: PetPresenceSnapshot?
    private var manualInteractionDuringReduced = false
    private var resizing = false
    private var resizeStartScale = MacPetResizeGeometry.defaultScale
    private static let minimumWalkableWidth: CGFloat = 8
    private static let edgeTolerance: CGFloat = 2
    private static let reducedAlpha: CGFloat = 0.42
    private static let reducedCornerMargin: CGFloat = 12
    private static let spriteWalkLaneWidth = MacPetWalkGeometry.spriteLaneWidth
    private let bottomMargin: CGFloat = 16

    init(
        viewModel: VibestickViewModel,
        openControlPanel: @escaping () -> Void,
        hidePet: @escaping () -> Void,
        importPet: @escaping () -> Void,
        exportPet: @escaping () -> Void,
        quitApplication: @escaping () -> Void,
        cycleFocusPreference: @escaping () -> Void,
        focusActionTitle: @escaping () -> String,
        menuStateDidChange: @escaping () -> Void = {})
    {
        self.viewModel = viewModel
        self.openControlPanel = openControlPanel
        self.hidePet = hidePet
        self.importPet = importPet
        self.exportPet = exportPet
        self.quitApplication = quitApplication
        self.cycleFocusPreference = cycleFocusPreference
        self.focusActionTitle = focusActionTitle
        self.menuStateDidChange = menuStateDidChange
        self.actionFrequencySettings = viewModel.petActionFrequencySettings.clamped
        super.init(
            contentRect: Self.initialFrame(),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        currentWalkSpeed = randomWalkSpeed()
        let hosting = PetHostingView(rootView: PetView(
            viewModel: viewModel,
            panelState: panelState,
            spriteLayerView: spriteLayerView,
            onHoverChanged: { [weak self] hovering in
                self?.setSpriteHovering(hovering)
            }))
        hosting.onPrimaryClick = { [weak self] in
            self?.cycleCardDisplayMode()
        }
        hosting.onDoubleClick = { [weak self] in
            self?.openControlPanel()
        }
        hosting.onCommandClick = { [weak self] in
            self?.hidePet()
        }
        hosting.onScroll = { [weak self] deltaY in
            self?.adjustCardDisplayMode(scrollDeltaY: deltaY)
        }
        hosting.onDragStart = { [weak self] in
            self?.beginManualDrag()
        }
        hosting.onDragTo = { [weak self] origin, deltaX in
            self?.moveManually(to: origin, dragDeltaX: deltaX)
        }
        hosting.onDragEnd = { [weak self] in
            self?.finishManualDrag()
        }
        hosting.isResizeHit = { [weak self, weak hosting] point in
            guard let self, let hosting else {
                return false
            }
            let spriteFrame = MacPetResizeGeometry.spriteFrame(
                hostBounds: hosting.bounds,
                scale: self.petScale)
            let handleFrame = MacPetResizeGeometry.handleFrame(
                spriteFrame: spriteFrame,
                scale: self.petScale)
            return MacPetResizeGeometry.isResizeHit(
                point: point,
                handleFrame: handleFrame,
                scale: self.petScale)
        }
        hosting.onResizeHoverChanged = { [weak self] hovering in
            self?.setResizeHandleHovering(hovering)
        }
        hosting.onResizeStart = { [weak self] in
            self?.beginResizing()
        }
        hosting.onResizeTo = { [weak self] delta in
            self?.resize(byDragDelta: delta)
        }
        hosting.onResizeEnd = { [weak self] in
            self?.finishResizing()
        }
        contentView = hosting
        hosting.petContextMenu = buildContextMenu()
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        spriteAnimator.setActionFrequencySettings(actionFrequencySettings)
    }

    static var savedWalkingEnabled: Bool {
        loadWalkingEnabled()
    }

    var isWalkingEnabled: Bool {
        walkingEnabled
    }

    var walkingActionTitle: String {
        walkingEnabled ? "暂停行走" : "恢复行走"
    }

    var cardDisplayModeActionTitle: String {
        "任务卡：\(panelState.cardDisplayMode.menuLabel)"
    }

    var petScale: CGFloat {
        panelState.scale
    }

    var isResizeHandleVisible: Bool {
        panelState.resizeHandleVisible
    }

    var petActionFrequencySettings: MacPetActionFrequencySettings {
        actionFrequencySettings
    }

    var isPresenceReduced: Bool {
        presenceMode == .reduced
    }

    func startWalking() {
        if walkingEnabled {
            resumeWalkingFromCurrentPosition()
        } else {
            clampCurrentPosition()
        }
        displayLink?.invalidate()
        let displayLink = MacPetDisplayLink { [weak self] date in
            self?.displayTick(at: date)
        }
        self.displayLink = displayLink
        displayLink.start()
        updateSpritePresentation(at: Date(), force: true)
    }

    func screenParametersDidChange() {
        pauseUntil = nil
        lastTick = nil
        if presenceMode == .reduced {
            moveToReducedCorner()
            updateSpritePresentation(at: Date(), force: true)
            return
        }

        if walkingEnabled {
            resumeWalkingFromCurrentPosition()
        } else {
            clampCurrentPosition()
            saveCurrentPosition()
        }
        updateSpritePresentation(at: Date(), force: true)
    }

    func toggleWalking() {
        walkingEnabled.toggle()
        UserDefaults.standard.set(walkingEnabled, forKey: Self.walkingEnabledDefaultsKey)
        pauseUntil = nil
        lastTick = nil

        if walkingEnabled, presenceMode == .normal {
            resumeWalkingFromCurrentPosition()
        } else if presenceMode == .reduced {
            moveToReducedCorner()
        }

        updateWalkingMenuText()
        menuStateDidChange()
        updateSpritePresentation(at: Date(), force: true)
    }

    func cycleCardDisplayMode() {
        setCardDisplayMode(panelState.cardDisplayMode.next)
    }

    func setResizeHandleHovering(_ hovering: Bool) {
        guard panelState.resizeHandleVisible != hovering else {
            return
        }
        panelState.resizeHandleVisible = hovering
    }

    fileprivate func setPresenceMode(_ mode: PetPresenceMode) {
        guard presenceMode != mode else {
            return
        }

        switch mode {
        case .normal:
            exitReducedPresence()
        case .reduced:
            enterReducedPresence()
        }

        menuStateDidChange()
        updateSpritePresentation(at: Date(), force: true)
    }

    func refreshFocusPreferenceMenuText() {
        updateFocusModeMenuText()
    }

    func advanceWalkingForTesting(at now: Date) {
        updateWalkPosition(at: now)
        let frameChanged = spriteAnimator.advanceFrameIfDue(at: now)
        updateSpritePresentation(at: now, force: frameChanged)
    }

    func reloadPetSprite() {
        spriteLayerView.setSpritesheetURL(viewModel.currentPet.spritesheetURL)
        updateSpritePresentation(at: Date(), force: true)
    }

    func applyActionFrequencySettings(_ settings: MacPetActionFrequencySettings) {
        let next = settings.clamped
        guard actionFrequencySettings != next else {
            return
        }

        actionFrequencySettings = next
        spriteAnimator.setActionFrequencySettings(next)
        startNewWalkSegment(at: Date())
        updateSpritePresentation(at: Date(), force: true)
    }

    func resetPetPosition() {
        clearSavedPosition()
        pauseUntil = nil
        lastTick = nil
        var next = Self.defaultFrame
        next.size = MacPetResizeGeometry.scaledSize(
            baseSize: MacPetResizeGeometry.basePanelSize,
            scale: petScale)
        setFrameOrigin(Self.clampedFrame(next, preferredScreenIdentifier: nil).origin)

        if presenceMode == .reduced {
            moveToReducedCorner()
        } else if walkingEnabled {
            resumeWalkingFromCurrentPosition()
        } else {
            saveCurrentPosition()
        }
        menuStateDidChange()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateWalkingMenuText()
        updateCardDisplayModeMenuText()
        updateFocusModeMenuText()
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
        guard walkingEnabled, presenceMode == .normal, !resizing else {
            pauseUntil = nil
            nextWanderAt = nil
            walkingAnimationDirection = nil
            crawlAnimationSuppressed = presenceMode == .reduced
            lastTick = now
            return
        }

        if let pauseUntil, now < pauseUntil {
            walkingAnimationDirection = nil
            lastTick = now
            return
        }
        pauseUntil = nil

        let elapsed = min(now.timeIntervalSince(lastTick ?? now), 0.25)
        lastTick = now
        guard let screen = targetScreen(for: frame, preferRetainedScreen: true) else {
            return
        }

        var next = frame
        next.origin.y = screen.visibleFrame.minY + bottomMargin

        let bounds = walkBounds(for: screen, frameWidth: next.width)
        let walkableWidth = bounds.maxX - bounds.minX
        guard walkableWidth >= Self.minimumWalkableWidth else {
            next.origin.x = min(max(next.origin.x, bounds.minX), bounds.maxX)
            setFrameOrigin(next.origin)
            crawlAnimationSuppressed = true
            walkingAnimationDirection = nil
            nextWanderAt = nil
            return
        }

        crawlAnimationSuppressed = false
        let stepDirection = direction
        let previousX = next.origin.x
        let delta = currentWalkSpeed * elapsed * (stepDirection == .right ? 1 : -1)
        next.origin.x += delta

        if next.origin.x <= bounds.minX {
            next.origin.x = bounds.minX
            direction = .right
            startNewWalkSegment(at: now)
            pauseUntil = now.addingTimeInterval(Self.randomEdgePause())
        } else if next.origin.x >= bounds.maxX {
            next.origin.x = bounds.maxX
            direction = .left
            startNewWalkSegment(at: now)
            pauseUntil = now.addingTimeInterval(Self.randomEdgePause())
        } else if shouldApplyWander(at: now, originX: next.origin.x, bounds: bounds) {
            applyWander(at: now)
        }

        walkingAnimationDirection = MacPetCrawlDirection.direction(
            forAppliedDeltaX: next.origin.x - previousX,
            fallback: stepDirection)
        setFrameOrigin(next.origin)
    }

    private func resumeWalkingFromCurrentPosition() {
        pauseUntil = nil
        lastTick = nil
        walkingAnimationDirection = nil
        alignToWalkLane(resetDirection: true)
        startNewWalkSegment(at: Date())
    }

    private func beginManualDrag() {
        if presenceMode == .reduced {
            manualInteractionDuringReduced = true
        }
        manualDragDirection = direction
        walkingAnimationDirection = nil
        if walkingEnabled {
            walkingEnabled = false
            UserDefaults.standard.set(walkingEnabled, forKey: Self.walkingEnabledDefaultsKey)
            menuStateDidChange()
        }
        pauseUntil = nil
        lastTick = nil
        updateWalkingMenuText()
        updateSpritePresentation(at: Date(), force: true)
    }

    private func moveManually(to origin: NSPoint, dragDeltaX: CGFloat) {
        let nextDirection = MacPetCrawlDirection.direction(
            forDragDeltaX: dragDeltaX,
            current: manualDragDirection ?? direction)
        manualDragDirection = nextDirection
        direction = nextDirection
        setFrameOrigin(clampedOrigin(origin, preferRetainedScreen: false))
        updateSpritePresentation(at: Date())
    }

    private func finishManualDrag() {
        manualDragDirection = nil
        walkingAnimationDirection = nil
        saveCurrentPosition()
        updateSpritePresentation(at: Date(), force: true)
    }

    func beginResizing() {
        if presenceMode == .reduced {
            manualInteractionDuringReduced = true
        }
        resizing = true
        resizeStartScale = petScale
        walkingAnimationDirection = nil
        crawlAnimationSuppressed = true
        pauseUntil = nil
        lastTick = nil
        updateSpritePresentation(at: Date(), force: true)
    }

    func resize(byDragDelta delta: NSPoint) {
        let nextScale = MacPetResizeGeometry.scale(startScale: resizeStartScale, dragDelta: delta)
        applyScale(nextScale)
        clampCurrentPosition()
        updateSpritePresentation(at: Date(), force: true)
    }

    func finishResizing() {
        resizing = false
        crawlAnimationSuppressed = presenceMode == .reduced
        saveCurrentPosition()
        updateSpritePresentation(at: Date(), force: true)
    }

    private func enterReducedPresence() {
        presenceSnapshot = PetPresenceSnapshot(frame: frame, retainedScreenIdentifier: retainedScreenIdentifier)
        manualInteractionDuringReduced = false
        presenceMode = .reduced
        alphaValue = Self.reducedAlpha
        panelState.isPresenceReduced = true
        pauseUntil = nil
        lastTick = nil
        nextWanderAt = nil
        walkingAnimationDirection = nil
        crawlAnimationSuppressed = true
        moveToReducedCorner()
    }

    private func exitReducedPresence() {
        let snapshot = presenceSnapshot
        presenceMode = .normal
        alphaValue = 1
        panelState.isPresenceReduced = false
        pauseUntil = nil
        lastTick = nil
        nextWanderAt = nil
        walkingAnimationDirection = nil
        crawlAnimationSuppressed = false

        if let snapshot, !manualInteractionDuringReduced {
            retainedScreenIdentifier = snapshot.retainedScreenIdentifier
            setFrameOrigin(clampedOrigin(snapshot.frame.origin))
        } else {
            clampCurrentPosition()
        }

        presenceSnapshot = nil
        manualInteractionDuringReduced = false

        if walkingEnabled {
            resumeWalkingFromCurrentPosition()
        }
    }

    private func moveToReducedCorner() {
        guard let screen = targetScreen(for: frame, preferRetainedScreen: true) else {
            return
        }

        let visibleFrame = screen.visibleFrame
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - frame.width - Self.reducedCornerMargin)
        let leftX = min(visibleFrame.minX + Self.reducedCornerMargin, maxX)
        let rightX = maxX
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - frame.height)
        let bottomY = min(max(visibleFrame.minY + bottomMargin, visibleFrame.minY), maxY)
        let targetX = frame.midX < visibleFrame.midX ? leftX : rightX
        setFrameOrigin(NSPoint(x: targetX, y: bottomY))
        retainedScreenIdentifier = Self.screenIdentifier(for: screen)
    }

    private func alignToWalkLane(resetDirection: Bool = false) {
        guard let screen = targetScreen(for: frame, preferRetainedScreen: true) else {
            return
        }
        var next = frame
        next.origin.y = screen.visibleFrame.minY + bottomMargin
        let bounds = walkBounds(for: screen, frameWidth: next.width)
        next.origin.x = min(max(next.origin.x, bounds.minX), bounds.maxX)
        setFrameOrigin(next.origin)
        retainedScreenIdentifier = Self.screenIdentifier(for: screen)
        crawlAnimationSuppressed = bounds.maxX - bounds.minX < Self.minimumWalkableWidth
        walkingAnimationDirection = nil
        if resetDirection {
            direction = crawlDirection(for: next.origin.x, on: screen)
        }
    }

    private func crawlDirection(for originX: CGFloat, on screen: NSScreen) -> MacPetCrawlDirection {
        let bounds = walkBounds(for: screen, frameWidth: frame.width)
        if originX <= bounds.minX + Self.edgeTolerance {
            return .right
        }
        if originX >= bounds.maxX - Self.edgeTolerance {
            return .left
        }
        return Bool.random() ? .right : .left
    }

    private func walkBounds(for screen: NSScreen, frameWidth: CGFloat) -> (minX: CGFloat, maxX: CGFloat) {
        MacPetWalkGeometry.walkBounds(
            visibleFrame: screen.visibleFrame,
            panelWidth: frameWidth,
            spriteLaneWidth: Self.spriteWalkLaneWidth)
    }

    private func startNewWalkSegment(at now: Date) {
        currentWalkSpeed = randomWalkSpeed()
        nextWanderAt = now.addingTimeInterval(randomWanderInterval())
    }

    private func shouldApplyWander(
        at now: Date,
        originX: CGFloat,
        bounds: (minX: CGFloat, maxX: CGFloat)
    ) -> Bool {
        guard let nextWanderAt, now >= nextWanderAt else {
            return false
        }

        let width = bounds.maxX - bounds.minX
        guard width >= 160 else {
            self.nextWanderAt = now.addingTimeInterval(randomWanderInterval())
            return false
        }

        let margin = min(max(width * 0.15, 48), width / 2)
        guard originX > bounds.minX + margin, originX < bounds.maxX - margin else {
            self.nextWanderAt = now.addingTimeInterval(randomWanderInterval())
            return false
        }

        return true
    }

    private func applyWander(at now: Date) {
        if Double.random(in: 0..<1) < 0.65 {
            direction = reversed(direction)
        }
        startNewWalkSegment(at: now)
        if Double.random(in: 0..<1) < 0.25 {
            pauseUntil = now.addingTimeInterval(Self.randomWanderPause())
        }
    }

    private func reversed(_ direction: MacPetCrawlDirection) -> MacPetCrawlDirection {
        switch direction {
        case .left:
            return .right
        case .right:
            return .left
        }
    }

    private func randomWalkSpeed() -> CGFloat {
        actionFrequencySettings.scaledWalkSpeed(CGFloat(Double.random(in: 42...72)))
    }

    private static func randomEdgePause() -> TimeInterval {
        Double.random(in: 0.15...0.45)
    }

    private func randomWanderInterval() -> TimeInterval {
        actionFrequencySettings.scaledWanderInterval(Double.random(in: 2.5...6.5))
    }

    private static func randomWanderPause() -> TimeInterval {
        Double.random(in: 0.12...0.45)
    }

    private func clampCurrentPosition() {
        setFrameOrigin(clampedOrigin(frame.origin))
    }

    private func applyScale(_ scale: CGFloat) {
        let nextScale = MacPetResizeGeometry.clampedScale(scale)
        panelState.scale = nextScale
        var nextFrame = frame
        nextFrame.size = MacPetResizeGeometry.scaledSize(
            baseSize: MacPetResizeGeometry.basePanelSize,
            scale: nextScale)
        setFrame(Self.clampedFrame(nextFrame, preferredScreenIdentifier: retainedScreenIdentifier), display: true)
    }

    private func clampedOrigin(_ origin: NSPoint, preferRetainedScreen: Bool = true) -> NSPoint {
        var nextFrame = frame
        nextFrame.origin = origin
        guard let targetScreen = targetScreen(for: nextFrame, preferRetainedScreen: preferRetainedScreen) else {
            return origin
        }

        let visibleFrame = targetScreen.visibleFrame
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - nextFrame.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - nextFrame.height)
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY))
    }

    private func targetScreen(for rect: NSRect, preferRetainedScreen: Bool) -> NSScreen? {
        if preferRetainedScreen,
           let retainedScreenIdentifier,
           let screen = Self.screen(identifier: retainedScreenIdentifier) {
            return screen
        }

        return Self.screen(containing: rect) ?? screen ?? NSScreen.main
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

        cardDisplayModeMenuItem.target = self
        cardDisplayModeMenuItem.action = #selector(cycleCardDisplayModeFromMenu)
        updateCardDisplayModeMenuText()
        menu.addItem(cardDisplayModeMenuItem)

        focusModeMenuItem.target = self
        focusModeMenuItem.action = #selector(cycleFocusModeFromMenu)
        updateFocusModeMenuText()
        menu.addItem(focusModeMenuItem)

        let resetPosition = NSMenuItem(title: "重置桌宠位置", action: #selector(resetPetPositionFromMenu), keyEquivalent: "")
        resetPosition.target = self
        menu.addItem(resetPosition)

        let hide = NSMenuItem(title: "隐藏桌宠", action: #selector(hidePetFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let importPet = NSMenuItem(title: "导入宠物...", action: #selector(importPetFromMenu), keyEquivalent: "")
        importPet.target = self
        menu.addItem(importPet)

        let exportPet = NSMenuItem(title: "导出当前宠物...", action: #selector(exportPetFromMenu), keyEquivalent: "")
        exportPet.target = self
        menu.addItem(exportPet)

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
        toggleWalking()
    }

    @objc private func cycleCardDisplayModeFromMenu() {
        cycleCardDisplayMode()
    }

    @objc private func cycleFocusModeFromMenu() {
        cycleFocusPreference()
        updateFocusModeMenuText()
    }

    @objc private func quitFromMenu() {
        quitApplication()
    }

    @objc private func hidePetFromMenu() {
        hidePet()
    }

    @objc private func importPetFromMenu() {
        importPet()
    }

    @objc private func exportPetFromMenu() {
        exportPet()
    }

    private func updateWalkingMenuText() {
        walkingToggleMenuItem.title = walkingActionTitle
    }

    private func adjustCardDisplayMode(scrollDeltaY: CGFloat) {
        guard scrollDeltaY != 0 else {
            return
        }

        let nextMode = scrollDeltaY > 0
            ? panelState.cardDisplayMode.expanded
            : panelState.cardDisplayMode.collapsed
        setCardDisplayMode(nextMode)
    }

    private func setCardDisplayMode(_ mode: PetCardDisplayMode) {
        guard panelState.cardDisplayMode != mode else {
            return
        }

        panelState.cardDisplayMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.cardDisplayModeDefaultsKey)
        updateCardDisplayModeMenuText()
        menuStateDidChange()
    }

    private func updateCardDisplayModeMenuText() {
        cardDisplayModeMenuItem.title = "任务卡：\(panelState.cardDisplayMode.menuLabel)"
    }

    private func updateFocusModeMenuText() {
        focusModeMenuItem.title = focusActionTitle()
    }

    @objc private func resetPetPositionFromMenu() {
        resetPetPosition()
    }

    private static func loadWalkingEnabled() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: walkingEnabledDefaultsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: walkingEnabledDefaultsKey)
    }

    private static func loadCardDisplayMode() -> PetCardDisplayMode {
        let value = UserDefaults.standard.string(forKey: cardDisplayModeDefaultsKey)
        return value.flatMap(PetCardDisplayMode.init(rawValue:)) ?? .full
    }

    private static func loadSavedScale() -> CGFloat {
        guard let value = UserDefaults.standard.object(forKey: scaleDefaultsKey) as? NSNumber else {
            return MacPetResizeGeometry.defaultScale
        }
        return MacPetResizeGeometry.clampedScale(CGFloat(truncating: value))
    }

    private static func initialFrame() -> NSRect {
        var frame = defaultFrame
        frame.size = MacPetResizeGeometry.scaledSize(
            baseSize: MacPetResizeGeometry.basePanelSize,
            scale: loadSavedScale())
        let screenIdentifier = loadSavedScreenIdentifier()
        if let savedOrigin = loadSavedOrigin() {
            frame.origin = savedOrigin
        }
        return clampedFrame(frame, preferredScreenIdentifier: screenIdentifier)
    }

    private static func loadSavedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: originXDefaultsKey) != nil,
              defaults.object(forKey: originYDefaultsKey) != nil
        else {
            return nil
        }

        return NSPoint(
            x: defaults.double(forKey: originXDefaultsKey),
            y: defaults.double(forKey: originYDefaultsKey))
    }

    private static func loadSavedScreenIdentifier() -> String? {
        UserDefaults.standard.string(forKey: screenIdentifierDefaultsKey)
    }

    private static func clampedFrame(_ frame: NSRect, preferredScreenIdentifier: String?) -> NSRect {
        var next = frame
        guard let targetScreen = screen(identifier: preferredScreenIdentifier) ?? screen(containing: frame) ?? NSScreen.main else {
            return next
        }

        let visibleFrame = targetScreen.visibleFrame
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - next.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - next.height)
        next.origin = NSPoint(
            x: min(max(next.origin.x, visibleFrame.minX), maxX),
            y: min(max(next.origin.y, visibleFrame.minY), maxY))
        return next
    }

    private static func screen(identifier: String?) -> NSScreen? {
        guard let identifier else {
            return nil
        }
        return NSScreen.screens.first { screenIdentifier(for: $0) == identifier }
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens
            .map { screen in (screen, intersectionArea(screen.visibleFrame, rect)) }
            .filter { $0.1 > 0 }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }

    private static func screenIdentifier(for screen: NSScreen?) -> String? {
        guard let value = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return value.stringValue
    }

    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        return intersection.width * intersection.height
    }

    private func saveCurrentPosition() {
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.origin.x), forKey: Self.originXDefaultsKey)
        defaults.set(Double(frame.origin.y), forKey: Self.originYDefaultsKey)
        defaults.set(Double(petScale), forKey: Self.scaleDefaultsKey)
        retainedScreenIdentifier = Self.screenIdentifier(for: Self.screen(containing: frame) ?? screen)
        if let retainedScreenIdentifier {
            defaults.set(retainedScreenIdentifier, forKey: Self.screenIdentifierDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.screenIdentifierDefaultsKey)
        }
    }

    private func clearSavedPosition() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.originXDefaultsKey)
        defaults.removeObject(forKey: Self.originYDefaultsKey)
        defaults.removeObject(forKey: Self.screenIdentifierDefaultsKey)
        retainedScreenIdentifier = nil
    }

    private func setSpriteHovering(_ hovering: Bool) {
        spriteHovering = hovering
        updateSpritePresentation(at: Date())
    }

    private func updateSpritePresentation(at now: Date, force: Bool = false) {
        spriteLayerView.setSpritesheetURL(viewModel.currentPet.spritesheetURL)
        let moodChanged = spriteAnimator.setMood(viewModel.petMood)
        let hoverChanged = spriteAnimator.setHovering(spriteHovering)
        let directionChanged = spriteAnimator.setCrawlDirection(activeCrawlDirection(at: now))
        guard force || moodChanged || hoverChanged || directionChanged else {
            return
        }

        spriteLayerView.apply(spriteAnimator.presentation)
    }

    private func activeCrawlDirection(at now: Date) -> MacPetCrawlDirection? {
        let isPaused = pauseUntil.map { $0 > now } ?? false
        let walkingCanAnimate = walkingEnabled
            && presenceMode == .normal
            && !crawlAnimationSuppressed
            && (walkingAnimationDirection != nil || !isPaused)
        return MacPetCrawlDirection.activeAnimationDirection(
            manualDragDirection: manualDragDirection,
            walkingAnimationDirection: walkingAnimationDirection,
            walkingCanAnimate: walkingCanAnimate)
    }

}

@MainActor
private final class PetHostingView: NSHostingView<PetView> {
    var onPrimaryClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onCommandClick: (() -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragTo: ((NSPoint, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var isResizeHit: ((NSPoint) -> Bool)?
    var onResizeHoverChanged: ((Bool) -> Void)?
    var onResizeStart: (() -> Void)?
    var onResizeTo: ((NSPoint) -> Void)?
    var onResizeEnd: (() -> Void)?

    var petContextMenu: NSMenu? {
        didSet {
            menu = petContextMenu
        }
    }

    private let dragThreshold: CGFloat = 4
    private var pendingPrimaryClick: DispatchWorkItem?
    private var resizeHovering = false
    private var resizeTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let resizeTrackingArea, trackingAreas.contains(where: { $0 === resizeTrackingArea }) {
            removeTrackingArea(resizeTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil)
        resizeTrackingArea = trackingArea
        addTrackingArea(trackingArea)
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeHover(at: convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        setResizeHovering(false)
        super.mouseExited(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelPendingPrimaryClick()
        showPetContextMenu(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            cancelPendingPrimaryClick()
            showPetContextMenu(with: event)
            return
        }

        if event.modifierFlags.contains(.command) {
            cancelPendingPrimaryClick()
            onCommandClick?()
            return
        }

        if event.clickCount >= 2 {
            cancelPendingPrimaryClick()
            onDoubleClick?()
            return
        }

        trackPrimaryMouse(from: event)
    }

    override func scrollWheel(with event: NSEvent) {
        cancelPendingPrimaryClick()
        onScroll?(event.scrollingDeltaY)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        petContextMenu
    }

    private func updateResizeHover(at point: NSPoint) {
        setResizeHovering(isResizeHit?(point) == true)
    }

    private func setResizeHovering(_ hovering: Bool) {
        guard resizeHovering != hovering else {
            return
        }
        resizeHovering = hovering
        onResizeHoverChanged?(hovering)
    }

    private func showPetContextMenu(with event: NSEvent) {
        guard let petContextMenu else {
            super.rightMouseDown(with: event)
            return
        }

        NSMenu.popUpContextMenu(petContextMenu, with: event, for: self)
    }

    private func trackPrimaryMouse(from event: NSEvent) {
        guard let window else {
            schedulePrimaryClick()
            return
        }

        let startMouseLocation = NSEvent.mouseLocation
        let startWindowOrigin = window.frame.origin
        let startViewLocation = convert(event.locationInWindow, from: nil)
        let interaction: PetHostingPointerInteraction = isResizeHit?(startViewLocation) == true ? .resize : .move
        setResizeHovering(interaction == .resize)
        var lastMouseLocation = startMouseLocation
        var isDragging = false

        while true {
            guard let nextEvent = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true)
            else {
                break
            }

            let currentMouseLocation = NSEvent.mouseLocation
            let delta = NSPoint(
                x: currentMouseLocation.x - startMouseLocation.x,
                y: currentMouseLocation.y - startMouseLocation.y)
            let dragDeltaX = currentMouseLocation.x - lastMouseLocation.x
            let distance = hypot(delta.x, delta.y)

            if nextEvent.type == .leftMouseDragged {
                if !isDragging, distance >= dragThreshold {
                    isDragging = true
                    cancelPendingPrimaryClick()
                    switch interaction {
                    case .move:
                        onDragStart?()
                    case .resize:
                        onResizeStart?()
                    }
                }

                if isDragging {
                    switch interaction {
                    case .move:
                        onDragTo?(NSPoint(
                            x: startWindowOrigin.x + delta.x,
                            y: startWindowOrigin.y + delta.y),
                            dragDeltaX)
                    case .resize:
                        onResizeTo?(delta)
                    }
                }
                lastMouseLocation = currentMouseLocation
                continue
            }

            if isDragging {
                switch interaction {
                case .move:
                    onDragEnd?()
                case .resize:
                    onResizeEnd?()
                }
            } else {
                schedulePrimaryClick()
            }
            break
        }
    }

    private func schedulePrimaryClick() {
        cancelPendingPrimaryClick()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pendingPrimaryClick = nil
            self?.onPrimaryClick?()
        }
        pendingPrimaryClick = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: workItem)
    }

    private func cancelPendingPrimaryClick() {
        pendingPrimaryClick?.cancel()
        pendingPrimaryClick = nil
    }
}

private enum PetHostingPointerInteraction {
    case move
    case resize
}

private struct PetView: View {
    @ObservedObject var viewModel: VibestickViewModel
    @ObservedObject var panelState: PetPanelState
    let spriteLayerView: MacPetSpriteLayerView
    let onHoverChanged: (Bool) -> Void
    @State private var isHovering = false

    init(
        viewModel: VibestickViewModel,
        panelState: PetPanelState,
        spriteLayerView: MacPetSpriteLayerView,
        onHoverChanged: @escaping (Bool) -> Void)
    {
        self.viewModel = viewModel
        self.panelState = panelState
        self.spriteLayerView = spriteLayerView
        self.onHoverChanged = onHoverChanged
    }

    var body: some View {
        let scaledSize = MacPetResizeGeometry.scaledSize(
            baseSize: MacPetResizeGeometry.basePanelSize,
            scale: panelState.scale)
        content
            .frame(
                width: MacPetResizeGeometry.basePanelSize.width,
                height: MacPetResizeGeometry.basePanelSize.height,
                alignment: .center)
            .scaleEffect(panelState.scale, anchor: .center)
            .frame(width: scaledSize.width, height: scaledSize.height, alignment: .center)
    }

    private var content: some View {
        VStack(spacing: 8) {
            cardArea
            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(.black.opacity(0.18))
                    .frame(width: 150, height: 18)
                    .blur(radius: 4)
                    .offset(y: 7)
                sprite
                resizeHandle
            }
            .frame(width: MacPetWalkGeometry.spriteLaneWidth, height: 210)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                onHoverChanged(hovering)
            }
        }
        .padding(10)
    }

    private var sprite: some View {
        MacPetSpriteRepresentable(spriteLayerView: spriteLayerView)
            .frame(width: 194, height: 210)
    }

    @ViewBuilder
    private var resizeHandle: some View {
        if panelState.resizeHandleVisible {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .frame(
                    width: MacPetResizeGeometry.handleSize,
                    height: MacPetResizeGeometry.handleSize)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 3)
                .frame(
                    width: MacPetWalkGeometry.spriteLaneWidth,
                    height: 210,
                    alignment: .bottomTrailing)
                .offset(
                    x: MacPetResizeGeometry.handleTrailingOffset,
                    y: -MacPetResizeGeometry.handleBottomOffset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var cardArea: some View {
        if panelState.isPresenceReduced {
            EmptyView()
        } else {
            switch panelState.cardDisplayMode {
            case .hidden:
                EmptyView()
            case .compact:
                compactCard
            case .full:
                fullCards
            }
        }
    }

    @ViewBuilder
    private var compactCard: some View {
        if let coder = viewModel.petCoders.first {
            taskCard(for: coder, detailLineLimit: 1)
                .frame(width: 292)
        } else {
            statusCard(detailLineLimit: 1)
                .frame(width: 292)
        }
    }

    @ViewBuilder
    private var fullCards: some View {
        if viewModel.petCoders.isEmpty {
            statusCard(detailLineLimit: 2)
                .frame(width: 308)
        } else {
            taskCards
        }
    }

    private var taskCards: some View {
        VStack(spacing: 6) {
            ForEach(viewModel.petCoders, id: \.identity) { coder in
                taskCard(for: coder, detailLineLimit: 2)
            }
        }
        .frame(width: 332)
    }

    private func taskCard(for coder: CoderAgentStatus, detailLineLimit: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(coder.taskSummary ?? coder.agent)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(coder.taskDetail ?? coder.message ?? coder.phase.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(detailLineLimit)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            taskStatusAccessory(for: coder.phase)
                .frame(width: 22, height: 22)
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

    @ViewBuilder
    private func taskStatusAccessory(for phase: CoderAgentPhase) -> some View {
        switch phase {
        case .running, .reasoning, .toolCalling:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .accessibilityLabel("任务进行中")
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityLabel("完成 ✅")
        case .idle, .sleeping, .waitingAuthorization, .error, .offline, .unknown:
            Color.clear
                .accessibilityHidden(true)
        }
    }

    private func statusCard(detailLineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(viewModel.petTitle)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(viewModel.petMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(detailLineLimit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
