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
                Button(appDelegate.viewModel.text.quitVibestick) {
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

enum PetFocusPreference: String {
    case automatic
    case on
    case off

    private static let defaultsKey = "VibestickPetFocusPreference"

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
    private var openControlPanelMenuItem: NSMenuItem?
    private var refreshMenuItem: NSMenuItem?
    private var importPetMenuItem: NSMenuItem?
    private var exportPetMenuItem: NSMenuItem?
    private var quitMenuItem: NSMenuItem?
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

        let openControlPanel = NSMenuItem(title: viewModel.text.openControlPanel, action: #selector(openControlPanel), keyEquivalent: "")
        openControlPanel.target = self
        menu.addItem(openControlPanel)
        openControlPanelMenuItem = openControlPanel

        let refresh = NSMenuItem(title: viewModel.text.refreshStatus, action: #selector(refreshStatus), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        refreshMenuItem = refresh

        let petToggle = NSMenuItem(title: viewModel.text.showPet, action: #selector(togglePetAction), keyEquivalent: "")
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

        let resetPosition = NSMenuItem(title: viewModel.text.resetPetPosition, action: #selector(resetPetPositionAction), keyEquivalent: "")
        resetPosition.target = self
        menu.addItem(resetPosition)
        petResetPositionMenuItem = resetPosition

        let importPet = NSMenuItem(title: viewModel.text.importPetMenu, action: #selector(importPetAction), keyEquivalent: "")
        importPet.target = self
        menu.addItem(importPet)
        importPetMenuItem = importPet

        let exportPet = NSMenuItem(title: viewModel.text.exportPetMenu, action: #selector(exportPetAction), keyEquivalent: "")
        exportPet.target = self
        menu.addItem(exportPet)
        exportPetMenuItem = exportPet

        menu.addItem(.separator())
        let quit = NSMenuItem(title: viewModel.text.quit, action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        quitMenuItem = quit
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
                focusActionTitle: { [weak self] in self?.focusActionTitle ?? LocalizedText.current.focusModePrefix },
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
        petToggleMenuItem?.title = petWindow?.isVisible == true ? viewModel.text.hidePet : viewModel.text.showPet
    }

    private func updateStatusItemState() {
        updateStatusIcon()
        updateStaticMenuItems()
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
        petWindow?.refreshLanguageText()
        petWindow?.refreshFocusPreferenceMenuText()
    }

    private func updateStaticMenuItems() {
        openControlPanelMenuItem?.title = viewModel.text.openControlPanel
        refreshMenuItem?.title = viewModel.text.refreshStatus
        petResetPositionMenuItem?.title = viewModel.text.resetPetPosition
        importPetMenuItem?.title = viewModel.text.importPetMenu
        exportPetMenuItem?.title = viewModel.text.exportPetMenu
        quitMenuItem?.title = viewModel.text.quit
    }

    private func updateSummaryMenuItems() {
        let activeTaskCount = viewModel.activeTaskCount
        modeSummaryMenuItem?.title = "\(viewModel.text.modePrefix): \(viewModel.menuModeText)"
        taskSummaryMenuItem?.title = activeTaskCount == 0
            ? "\(viewModel.text.taskPrefix): \(viewModel.text.noActiveTasks)"
            : "\(viewModel.text.taskPrefix): \(activeTaskCount) \(viewModel.text.activeTaskUnit)"
        petSummaryMenuItem?.title = "\(viewModel.text.petPrefix): \(petWindow?.isVisible == true ? viewModel.text.petVisible : viewModel.text.petHidden)"
        walkingSummaryMenuItem?.title = "\(viewModel.text.walkingPrefix): \((petWindow?.isWalkingEnabled ?? PetPanel.savedWalkingEnabled) ? viewModel.text.walking : viewModel.text.paused)"
        focusSummaryMenuItem?.title = "\(viewModel.text.focusSummaryPrefix): \(focusSummaryText)"
        petLibrarySummaryMenuItem?.title = "\(viewModel.text.petLibraryPrefix): \(viewModel.currentPet.displayName)"
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
        "\(viewModel.text.focusModePrefix): \(viewModel.text.focusPreferenceLabel(focusPreference))"
    }

    private var focusSummaryText: String {
        switch focusPreference {
        case .automatic:
            return autoFocusReduced ? viewModel.text.autoReduced : viewModel.text.auto
        case .on:
            return viewModel.text.on
        case .off:
            return viewModel.text.off
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
    @Published var languagePreference = AppLanguagePreference.load()
    @Published var petMood = "idle"
    @Published var petTitle = "Vibestick"
    @Published var petMessage = "正在读取状态..."
    @Published var petCoders: [CoderAgentStatus] = []
    @Published var activityObservation: AppActivityObservation?
    @Published var activityRuleSummaryText = "正在读取活动规则..."
    @Published var activityRuleOverrideText = ""
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
    private let activityRuleStore: AppActivityRuleStore
    private let activityInspector: AppActivityInspector
    private let codexStatusBridge: CodexSessionStatusBridge?
    private let petResolver = PetStateResolver()
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var coderRefreshTask: Task<Void, Never>?
    private var latestStatus: VibestickStatus?

    var text: LocalizedText {
        LocalizedText(language: languagePreference.resolvedLanguage())
    }

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
        let activityRuleStore = AppActivityRuleStore()
        self.assertionManager = assertionManager
        self.helperInstaller = helperInstaller
        self.deviceWatcherInstaller = deviceWatcherInstaller
        self.petLibrary = petLibrary
        self.currentPet = petLibrary.currentPet()
        self.activityRuleStore = activityRuleStore
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
        self.activityInspector = AppActivityInspector(ruleStore: activityRuleStore)
        self.codexStatusBridge?.start()
        applyInitialLocalizedText()
        self.refreshPetLibrary()
        self.refreshActivityRuleSummary()
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
        refreshActivityRuleSummary()
    }

    func setLanguagePreference(_ preference: AppLanguagePreference) {
        guard languagePreference != preference else {
            return
        }
        languagePreference = preference
        preference.save()
        applyInitialLocalizedText()
        refreshActivityRuleSummary()
        if let latestStatus {
            statusText = formatStatus(latestStatus, helperPreflight: helperInstaller.preflight())
        }
        menuStateDidChange?()
    }

    private func applyInitialLocalizedText() {
        if latestStatus == nil {
            statusText = text.loadingStatus
        }
        if doctorText == "尚未运行诊断。" || doctorText == "Doctor has not run yet." {
            doctorText = text.doctorNotRun
        }
        if deviceWatcherStatusText == "正在读取插盘自启状态..." || deviceWatcherStatusText == "Loading device auto-start status..." {
            deviceWatcherStatusText = text.language == .zh
                ? "正在读取插盘自启状态..."
                : "Loading device auto-start status..."
        }
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
            petLibraryMessage = text.language == .zh
                ? "已切换到 \(petLibrary.currentPet().displayName)。"
                : "Switched to \(petLibrary.currentPet().displayName)."
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

    func refreshActivityRuleSummary() {
        let inventory = activityRuleStore.loadInventory()
        let disabledBuiltInCount = inventory.bundledRules.filter { bundledRule in
            inventory.userRules.contains { $0.id == bundledRule.id && !$0.isEnabled }
        }.count
        let customCount = inventory.userRules.filter { userRule in
            !inventory.bundledRules.contains { $0.id == userRule.id }
        }.count

        activityRuleSummaryText = text.language == .zh
            ? "生效 \(inventory.effectiveRules.count) 条 · 内置 \(inventory.bundledRules.count) 条 · 覆盖 \(inventory.userRules.count) 条 · 自定义 \(customCount) 条"
            : "Effective \(inventory.effectiveRules.count) · Built-in \(inventory.bundledRules.count) · Overrides \(inventory.userRules.count) · Custom \(customCount)"
        activityRuleOverrideText = inventory.userRules.isEmpty
            ? (text.language == .zh ? "覆盖文件：未创建" : "Override file: not created")
            : (text.language == .zh ? "覆盖文件：\(inventory.userRulesURL.path)" : "Override file: \(inventory.userRulesURL.path)")

        if disabledBuiltInCount > 0 {
            activityRuleOverrideText += text.language == .zh
                ? " · 已禁用内置 \(disabledBuiltInCount) 条"
                : " · Disabled built-in \(disabledBuiltInCount)"
        }
        if !inventory.diagnostics.isEmpty {
            activityRuleOverrideText += " · \(inventory.diagnostics.joined(separator: "；"))"
        }
    }

    func openActivityRuleManager() {
        ActivityRuleManagerWindowController.shared.show(store: activityRuleStore) { [weak self] in
            self?.refreshActivityRuleSummary()
            self?.refreshCoderPet()
        }
    }

    func importPetFromDialog() {
        let panel = NSOpenPanel()
        panel.title = text.language == .zh ? "导入 Vibestick 宠物" : "Import Vibestick Pet"
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
        panel.title = text.language == .zh ? "导出 Vibestick 宠物" : "Export Vibestick Pet"
        panel.nameFieldStringValue = "\(pet.id).vibestick-pet.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try petLibrary.exportPet(id: pet.id, to: url)
            petLibraryMessage = text.language == .zh ? "已导出 \(pet.displayName)。" : "Exported \(pet.displayName)."
        } catch {
            petLibraryMessage = friendlyError(error.localizedDescription)
        }
    }

    func deleteCurrentCustomPet() {
        guard !currentPet.isBuiltIn else {
            petLibraryMessage = text.language == .zh ? "内置宠物不能删除。" : "The built-in pet cannot be deleted."
            return
        }

        let alert = NSAlert()
        alert.messageText = text.language == .zh ? "删除 \(currentPet.displayName)？" : "Delete \(currentPet.displayName)?"
        alert.informativeText = text.language == .zh ? "此操作不能撤销。" : "This cannot be undone."
        alert.addButton(withTitle: text.language == .zh ? "删除" : "Delete")
        alert.addButton(withTitle: text.language == .zh ? "取消" : "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }

        do {
            try petLibrary.deleteCustomPet(id: currentPet.id)
            petLibraryMessage = text.language == .zh
                ? "已删除自定义宠物，已切回内置宠物。"
                : "Deleted the custom pet and switched back to the built-in pet."
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

            petLibraryMessage = text.language == .zh
                ? "已导入并切换到 \(imported.displayName)。"
                : "Imported and switched to \(imported.displayName)."
            refreshPetLibrary()
            petLibraryChanged?()
        } catch PetLibraryError.duplicate(let id) {
            let alert = NSAlert()
            alert.messageText = text.language == .zh ? "宠物“\(id)”已存在。" : "Pet \"\(id)\" already exists."
            alert.informativeText = text.language == .zh ? "是否替换已有宠物？" : "Replace the existing pet?"
            alert.addButton(withTitle: text.language == .zh ? "替换" : "Replace")
            alert.addButton(withTitle: text.language == .zh ? "取消" : "Cancel")
            alert.alertStyle = .warning
            if alert.runModal() == .alertFirstButtonReturn {
                importPet(from: url, replace: true, metadata: metadata)
            }
        } catch {
            petLibraryMessage = friendlyError(error.localizedDescription)
        }
    }

    private func promptPetMetadata(suggestedName: String) -> PetImportMetadata? {
        let nameField = NSTextField(string: suggestedName.isEmpty ? (text.language == .zh ? "导入的宠物" : "Imported Pet") : suggestedName)
        let descriptionField = NSTextField(string: text.language == .zh ? "导入的 Vibestick 宠物。" : "Imported Vibestick pet.")
        nameField.frame = NSRect(x: 0, y: 34, width: 280, height: 24)
        descriptionField.frame = NSRect(x: 0, y: 0, width: 280, height: 24)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 62))
        container.addSubview(nameField)
        container.addSubview(descriptionField)

        let alert = NSAlert()
        alert.messageText = text.language == .zh ? "导入宠物 Atlas" : "Import Pet Atlas"
        alert.informativeText = text.language == .zh ? "填写宠物名称和描述。" : "Enter the pet name and description."
        alert.accessoryView = container
        alert.addButton(withTitle: text.language == .zh ? "导入" : "Import")
        alert.addButton(withTitle: text.language == .zh ? "取消" : "Cancel")
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
        let activityInspector = activityInspector
        let status = latestStatus ?? Self.defaultPetStatus()
        coderRefreshTask = Task(priority: .utility) { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let now = Date()
                let coders = coderSource.getStatuses(now: now)
                let pet = petResolver.resolve(status: status, coders: coders)
                let activity = activityInspector.observe(now: now)
                return (coders, pet, activity)
            }.value

            guard !Task.isCancelled else {
                return
            }
            self?.finishCoderRefresh(coders: result.0, pet: result.1, activity: result.2)
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

    private func finishCoderRefresh(coders: [CoderAgentStatus], pet: PetState, activity: AppActivityObservation) {
        coderRefreshTask = nil
        activeTaskCount = coders.filter { Self.isMenuActivePhase($0.phase) }.count
        activityObservation = activity
        let display = Self.petDisplayState(pet: pet, coders: coders, activity: activity, text: text)
        petMood = display.mood
        petTitle = display.title
        petMessage = display.message
        petCoders = Array(coders.prefix(3))
        menuStateDidChange?()
    }

    static func petDisplayState(
        pet: PetState,
        coders: [CoderAgentStatus],
        activity: AppActivityObservation,
        text: LocalizedText = .current
    ) -> (mood: String, title: String, message: String) {
        guard canApplyActivityOverlay(pet: pet, coders: coders) else {
            return (pet.mood, pet.title, pet.message)
        }

        let appLabel = activity.browserTitle ?? activity.appName ?? (text.language == .zh ? "当前 App" : "Current App")
        switch activity.category {
        case .study:
            return text.language == .zh
                ? ("happy", "学习中", "\(appLabel) 让猫咪很开心。")
                : ("happy", "Studying", "\(appLabel) makes the cat happy.")
        case .distraction:
            return text.language == .zh
                ? ("sad", "摆烂预警", "\(appLabel) 让猫咪有点难过。")
                : ("sad", "Distraction Alert", "\(appLabel) makes the cat a little sad.")
        case .neutral:
            return (pet.mood, pet.title, pet.message)
        }
    }

    static func canApplyActivityOverlay(pet: PetState, coders: [CoderAgentStatus]) -> Bool {
        if ["error", "waiting", "success", "low_battery", "power"].contains(pet.mood) {
            return false
        }

        if coders.contains(where: { status in
            switch status.phase {
            case .waitingAuthorization, .error, .success:
                true
            case .idle, .sleeping, .running, .reasoning, .toolCalling, .offline, .unknown:
                false
            }
        }) {
            return false
        }

        return ["idle", "sleeping", "running", "reasoning", "tool_calling"].contains(pet.mood)
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
            statusText += text.language == .zh ? "\n操作失败：\(message)" : "\nOperation failed: \(message)"
            doctorText = text.language == .zh ? "详细错误：\(error.localizedDescription)" : "Error detail: \(error.localizedDescription)"
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
        helperInstallMessage = text.language == .zh ? "正在请求管理员授权安装 Helper..." : "Requesting administrator authorization to install Helper..."
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
        firstLaunchInstallText = text.language == .zh ? "正在完成 Helper 和插盘自启安装..." : "Finishing Helper and device auto-start setup..."
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
        deviceWatcherMessage = text.language == .zh ? "正在安装插盘自启 LaunchAgent..." : "Installing device auto-start LaunchAgent..."
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
        deviceWatcherMessage = text.language == .zh ? "正在卸载插盘自启 LaunchAgent..." : "Uninstalling device auto-start LaunchAgent..."
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
            text.language == .zh ? "当前模式：\(displayMode(status.activeMode))" : "Current mode: \(displayMode(status.activeMode))",
            text.language == .zh ? "恢复状态：\(status.restorePending ? text.restorePending : text.noRestoreNeeded)" : "Restore state: \(status.restorePending ? text.restorePending : text.noRestoreNeeded)",
            text.language == .zh ? "HYPER 守护：\(status.assertionActive ? text.hyperGuardRunning : text.hyperGuardStopped)" : "HYPER guard: \(status.assertionActive ? text.hyperGuardRunning : text.hyperGuardStopped)",
            text.language == .zh ? "电池/电源：\(formatBattery(status.battery))" : "Battery/power: \(formatBattery(status.battery))",
            text.language == .zh ? "睡眠策略：\(formatSleepPolicy(status.pmset, helperPreflight: helperPreflight))" : "Sleep policy: \(formatSleepPolicy(status.pmset, helperPreflight: helperPreflight))",
            "Helper: \(formatHelperStatus(helperPreflight))"
        ]

        if let warning = status.warnings.first {
            lines.append(text.language == .zh ? "提示：\(friendlyError(warning))" : "Tip: \(friendlyError(warning))")
        }

        return lines.joined(separator: "\n")
    }

    private func formatBattery(_ battery: BatteryInfo) -> String {
        guard battery.isAvailable else {
            return text.powerUnavailable
        }
        let percent = battery.percentage.map { "\($0)%" } ?? text.unknownBattery
        return "\(percent), \(battery.isACConnected ? text.acConnected : text.onBattery)"
    }

    private func formatSleepPolicy(_ snapshot: PmsetSnapshot?, helperPreflight: HelperInstallPreflight) -> String {
        guard let snapshot else {
            if !helperPreflight.isInstalled {
                return text.temporarilyUnreadableInstallHelper
            }
            return text.temporarilyUnreadableRunDoctor
        }
        let battery = snapshot.value("sleep", source: .battery) ?? (text.language == .zh ? "未知" : "unknown")
        let ac = snapshot.value("sleep", source: .ac) ?? (text.language == .zh ? "未知" : "unknown")
        return text.language == .zh ? "电池=\(battery)，外接电源=\(ac)" : "battery=\(battery), AC=\(ac)"
    }

    private func formatHelperStatus(_ preflight: HelperInstallPreflight) -> String {
        if preflight.isInstalled {
            return text.helperInstalled
        }
        if preflight.isReadyToInstall {
            return text.helperReady
        }
        return text.helperResourcesMissing
    }

    private func formatDeviceWatcherStatus(_ status: DeviceWatcherInstallStatus) -> String {
        if status.isInstalled {
            return text.deviceWatcherInstalled
        }
        if status.isReadyToInstall {
            return text.deviceWatcherReady
        }
        if !status.watcherExecutableExists {
            return text.watcherMissing
        }
        if !status.appExists {
            return text.appMissing
        }
        return text.deviceWatcherDisabled
    }

    private func displayMode(_ mode: VibestickMode) -> String {
        switch mode {
        case .off:
            return text.modeLabel(.off)
        case .on:
            return text.modeLabel(.on)
        case .hyper:
            return text.modeLabel(.hyper)
        }
    }

    private func friendlyApplyError(_ error: Error, mode: VibestickMode) -> String {
        let preflight = helperInstaller.preflight()
        if !preflight.isInstalled {
            switch mode {
            case .off:
                return text.helperRequiredRestore
            case .on, .hyper:
                return text.helperRequiredModify
            }
        }
        return friendlyError(error.localizedDescription)
    }

    private func friendlyError(_ message: String) -> String {
        if message.contains(VibestickPaths.installedHelperPath) || message.localizedCaseInsensitiveContains("failed to start") {
            return text.helperNotInstalled
        }
        return message
    }

    private func formatFirstLaunchStatus(_ status: FirstLaunchInstallStatus) -> String {
        switch status.location.kind {
        case .mountedVolume:
            return text.firstLaunchMoveFromDmg
        case .other:
            return text.firstLaunchMoveToApplications
        case .systemApplications, .userApplications:
            break
        }

        if !status.needsInstall {
            return text.installComplete
        }

        if !status.canCompleteInstall {
            return text.installResourcesMissing
        }

        return text.language == .zh
            ? "还需完成：\(status.missingComponentNames.joined(separator: "、"))。点击“完成安装”后会先请求管理员授权安装 Helper，再启用插盘自启。"
            : "Still needed: \(status.missingComponentNames.joined(separator: ", ")). Complete Install will request administrator authorization for Helper, then enable device auto-start."
    }
}

struct ControlPanelView: View {
    @ObservedObject var viewModel: VibestickViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker(viewModel.text.languageLabel, selection: Binding(
                    get: { viewModel.languagePreference },
                    set: { viewModel.setLanguagePreference($0) }))
                {
                    ForEach(AppLanguagePreference.allCases) { preference in
                        Text(viewModel.text.languagePreferenceLabel(preference)).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Spacer()
            }

            if viewModel.shouldShowFirstLaunchInstall {
                VStack(alignment: .leading, spacing: 8) {
                    Text(viewModel.firstLaunchInstallText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(viewModel.isCompletingFirstLaunchInstall ? viewModel.text.installing : viewModel.text.completeInstall) {
                        viewModel.completeFirstLaunchInstall()
                    }
                    .disabled(!viewModel.canCompleteFirstLaunchInstall || viewModel.isCompletingFirstLaunchInstall)
                }
                .padding(.bottom, 4)

                Divider()
            }

            HStack {
                Button(viewModel.text.modeOffButton) { viewModel.apply(.off) }
                Button(viewModel.text.keepAwakeButton) { viewModel.apply(.on) }
                Button("HYPER") { viewModel.apply(.hyper) }
                Button(viewModel.text.stopHyper) { viewModel.stopHyperAssertion() }
            }
            .buttonStyle(.borderedProminent)

            Text(viewModel.statusText)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button(viewModel.text.refresh) { viewModel.refresh() }
                Button(viewModel.text.doctor) { viewModel.runDoctor() }
                Button(viewModel.isInstallingHelper ? viewModel.text.installing : viewModel.text.installHelper) { viewModel.installHelper() }
                    .disabled(viewModel.isInstallingHelper)
                Button(viewModel.text.accessibility) { viewModel.requestAccessibility() }
            }

            if !viewModel.helperInstallMessage.isEmpty {
                Text(viewModel.helperInstallMessage)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("\(viewModel.text.deviceWatcherPrefix): \(viewModel.deviceWatcherStatusText)")
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button(viewModel.isInstallingDeviceWatcher ? viewModel.text.processing : viewModel.text.enableDeviceWatcher) {
                        viewModel.installDeviceWatcher()
                    }
                    .disabled(viewModel.isInstallingDeviceWatcher)
                    Button(viewModel.text.disableDeviceWatcher) {
                        viewModel.uninstallDeviceWatcher()
                    }
                    .disabled(viewModel.isInstallingDeviceWatcher)
                }
                if !viewModel.deviceWatcherMessage.isEmpty {
                    Text(viewModel.deviceWatcherMessage)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(viewModel.text.activityRuleLibrary)
                    .font(.headline)
                Text(viewModel.activityObservation.map {
                    "\(viewModel.text.currentActivityPrefix): \(viewModel.text.activityCategoryLabel($0.category)) · \($0.appName ?? "-") · \($0.matchedRuleId ?? viewModel.text.noMatchedRule)"
                } ?? "\(viewModel.text.currentActivityPrefix): \(viewModel.text.noCurrentActivity)")
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(viewModel.activityRuleSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.activityRuleOverrideText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button(viewModel.text.manageActivityRules) {
                    viewModel.openActivityRuleManager()
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.text.petLibrary)
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
                Picker(viewModel.text.currentPet, selection: Binding(
                    get: { viewModel.currentPet.id },
                    set: { viewModel.selectPet(id: $0) }))
                {
                    ForEach(viewModel.pets) { pet in
                        Text(pet.isBuiltIn ? "\(pet.displayName) (\(viewModel.text.builtIn))" : pet.displayName)
                            .tag(pet.id)
                    }
                }
                .pickerStyle(.menu)
                HStack {
                    Button(viewModel.text.importPet) { viewModel.importPetFromDialog() }
                    Button(viewModel.text.exportCurrent) { viewModel.exportCurrentPetFromDialog() }
                    Button(viewModel.text.deleteCustom) { viewModel.deleteCurrentCustomPet() }
                        .disabled(viewModel.currentPet.isBuiltIn)
                }
                if !viewModel.petLibraryMessage.isEmpty {
                    Text(viewModel.petLibraryMessage)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.text.petActionFrequency)
                    .font(.headline)
                PetFrequencySlider(
                    title: viewModel.text.randomActionFrequency,
                    range: MacPetActionFrequencySettings.randomActionMinMultiplier...MacPetActionFrequencySettings.maxMultiplier,
                    step: MacPetActionFrequencySettings.randomActionStep,
                    value: Binding(
                        get: { viewModel.petActionFrequencySettings.randomActionFrequency },
                        set: { viewModel.setRandomActionFrequency($0) }))
                PetFrequencySlider(
                    title: viewModel.text.walkingSpeed,
                    value: Binding(
                        get: { viewModel.petActionFrequencySettings.walkSpeedMultiplier },
                        set: { viewModel.setWalkSpeedMultiplier($0) }))
                PetFrequencySlider(
                    title: viewModel.text.wanderPauseFrequency,
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

enum ActivityRuleFilter: String, CaseIterable, Identifiable {
    case all
    case study
    case distraction
    case neutral
    case disabled
    case custom
    case builtIn

    var id: String { rawValue }

    func label(text: LocalizedText = .current) -> String {
        switch (text.language, self) {
        case (.zh, .all): "全部"
        case (.zh, .study): "学习"
        case (.zh, .distraction): "摆烂"
        case (.zh, .neutral): "中性"
        case (.zh, .disabled): "已禁用"
        case (.zh, .custom): "自定义"
        case (.zh, .builtIn): "内置"
        case (.en, .all): "All"
        case (.en, .study): "Study"
        case (.en, .distraction): "Distraction"
        case (.en, .neutral): "Neutral"
        case (.en, .disabled): "Disabled"
        case (.en, .custom): "Custom"
        case (.en, .builtIn): "Built-in"
        }
    }
}

struct ActivityRuleRow: Identifiable, Equatable {
    let id: String
    let rule: AppActivityRule
    let isBuiltIn: Bool
    let hasUserOverride: Bool

    func sourceLabel(text: LocalizedText = .current) -> String {
        if isBuiltIn && hasUserOverride && !rule.isEnabled {
            return text.language == .zh ? "内置已禁用" : "Built-in disabled"
        }
        if isBuiltIn && hasUserOverride {
            return text.language == .zh ? "覆盖内置" : "Built-in override"
        }
        if isBuiltIn {
            return text.builtIn
        }
        return rule.isEnabled
            ? (text.language == .zh ? "自定义" : "Custom")
            : (text.language == .zh ? "自定义已禁用" : "Custom disabled")
    }

    func categoryLabel(text: LocalizedText = .current) -> String {
        Self.categoryLabel(rule.category, text: text)
    }

    static func categoryLabel(_ category: AppActivityCategory, text: LocalizedText = .current) -> String {
        text.activityCategoryLabel(category)
    }
}

struct ActivityRuleDraft: Equatable {
    var originalId: String?
    var isBuiltIn: Bool
    var hasUserOverride: Bool
    var id: String
    var category: AppActivityCategory
    var isEnabled: Bool
    var bundleIdentifiersText: String
    var appNameFragmentsText: String
    var urlHostSuffixesText: String
    var urlContainsText: String
    var titleFragmentsText: String

    init(row: ActivityRuleRow) {
        originalId = row.id
        isBuiltIn = row.isBuiltIn
        hasUserOverride = row.hasUserOverride
        id = row.rule.id
        category = row.rule.category
        isEnabled = row.rule.isEnabled
        bundleIdentifiersText = Self.join(row.rule.bundleIdentifiers)
        appNameFragmentsText = Self.join(row.rule.appNameFragments)
        urlHostSuffixesText = Self.join(row.rule.urlHostSuffixes)
        urlContainsText = Self.join(row.rule.urlContains)
        titleFragmentsText = Self.join(row.rule.titleFragments)
    }

    init(customId: String) {
        originalId = nil
        isBuiltIn = false
        hasUserOverride = false
        id = customId
        category = .study
        isEnabled = true
        bundleIdentifiersText = ""
        appNameFragmentsText = ""
        urlHostSuffixesText = ""
        urlContainsText = ""
        titleFragmentsText = ""
    }

    var hasMatchers: Bool {
        !bundleIdentifiers.isEmpty
            || !appNameFragments.isEmpty
            || !urlHostSuffixes.isEmpty
            || !urlContains.isEmpty
            || !titleFragments.isEmpty
    }

    var bundleIdentifiers: [String] { Self.split(bundleIdentifiersText) }
    var appNameFragments: [String] { Self.split(appNameFragmentsText) }
    var urlHostSuffixes: [String] { Self.split(urlHostSuffixesText) }
    var urlContains: [String] { Self.split(urlContainsText) }
    var titleFragments: [String] { Self.split(titleFragmentsText) }

    func makeRule() throws -> AppActivityRule {
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedId.isEmpty else {
            throw ActivityRuleEditorError.emptyRuleId
        }
        guard hasMatchers || (isBuiltIn && !isEnabled) else {
            throw ActivityRuleEditorError.missingMatchers(normalizedId)
        }
        return AppActivityRule(
            id: normalizedId,
            category: category,
            isEnabled: isEnabled,
            bundleIdentifiers: bundleIdentifiers,
            appNameFragments: appNameFragments,
            urlHostSuffixes: urlHostSuffixes,
            urlContains: urlContains,
            titleFragments: titleFragments).normalizedForStorage
    }

    private static func split(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func join(_ values: [String]) -> String {
        values.joined(separator: "\n")
    }
}

enum ActivityRuleEditorError: Error, LocalizedError, Equatable {
    case emptyRuleId
    case duplicateRuleId(String)
    case missingMatchers(String)
    case noSelection

    var errorDescription: String? {
        switch self {
        case .emptyRuleId:
            return "规则 ID 不能为空。"
        case .duplicateRuleId(let id):
            return "规则 ID 已存在：\(id)。"
        case .missingMatchers(let id):
            return "规则 \(id) 至少需要一个匹配项。"
        case .noSelection:
            return "请先选择一条规则。"
        }
    }
}

@MainActor
final class ActivityRuleManagerViewModel: ObservableObject {
    @Published private(set) var rows: [ActivityRuleRow] = []
    @Published var filter: ActivityRuleFilter = .all {
        didSet { selectFirstVisibleRuleIfNeeded() }
    }
    @Published var selectedRuleID: String?
    @Published var draft: ActivityRuleDraft?
    @Published private(set) var statusMessage = ""
    @Published private(set) var diagnostics: [String] = []
    @Published private(set) var overrideFilePath = ""
    @Published private(set) var effectiveRuleCount = 0

    var rulesDidChange: (() -> Void)?

    private let store: AppActivityRuleStore

    init(store: AppActivityRuleStore = AppActivityRuleStore()) {
        self.store = store
        reload()
    }

    var filteredRows: [ActivityRuleRow] {
        rows.filter { row in
            switch filter {
            case .all:
                return true
            case .study:
                return row.rule.category == .study
            case .distraction:
                return row.rule.category == .distraction
            case .neutral:
                return row.rule.category == .neutral
            case .disabled:
                return !row.rule.isEnabled
            case .custom:
                return !row.isBuiltIn
            case .builtIn:
                return row.isBuiltIn
            }
        }
    }

    var selectedRow: ActivityRuleRow? {
        guard let selectedRuleID else {
            return nil
        }
        return rows.first { $0.id == selectedRuleID }
    }

    var canRestoreSelectedRule: Bool {
        selectedRow?.hasUserOverride == true
    }

    var canDeleteSelectedRule: Bool {
        guard let row = selectedRow else {
            return false
        }
        return !row.isBuiltIn || row.hasUserOverride
    }

    func reload(selecting preferredRuleID: String? = nil) {
        let inventory = store.loadInventory()
        rows = Self.makeRows(from: inventory)
        diagnostics = inventory.diagnostics
        overrideFilePath = inventory.userRulesURL.path
        effectiveRuleCount = inventory.effectiveRules.count

        let nextSelection = preferredRuleID ?? selectedRuleID
        if let nextSelection, rows.contains(where: { $0.id == nextSelection }) {
            selectRule(id: nextSelection)
        } else {
            selectRule(id: filteredRows.first?.id ?? rows.first?.id)
        }
    }

    func selectRule(id: String?) {
        selectedRuleID = id
        if let id, let row = rows.first(where: { $0.id == id }) {
            draft = ActivityRuleDraft(row: row)
        } else {
            draft = nil
        }
    }

    func updateDraft(_ update: (inout ActivityRuleDraft) -> Void) {
        guard var draft else {
            return
        }
        update(&draft)
        if draft.isBuiltIn {
            draft.id = draft.originalId ?? draft.id
        }
        self.draft = draft
    }

    func newCustomRule() {
        let id = nextCustomRuleId()
        selectedRuleID = nil
        draft = ActivityRuleDraft(customId: id)
        statusMessage = "正在新增自定义规则。"
    }

    func saveDraft() {
        do {
            guard let draft else {
                throw ActivityRuleEditorError.noSelection
            }
            let rule = try draft.makeRule()
            try validateUniqueRuleId(rule.id, originalId: draft.originalId)

            if let originalId = draft.originalId {
                _ = try store.replaceUserRule(id: originalId, with: rule)
            } else {
                _ = try store.upsertUserRule(rule)
            }

            statusMessage = "已保存 \(rule.id)。"
            rulesDidChange?()
            reload(selecting: rule.id)
        } catch {
            statusMessage = friendlyRuleError(error)
        }
    }

    func disableSelectedRule() {
        do {
            guard let row = selectedRow else {
                throw ActivityRuleEditorError.noSelection
            }
            if row.isBuiltIn {
                _ = try store.disableBundledRule(id: row.id)
            } else {
                let disabledRule = AppActivityRule(
                    id: row.rule.id,
                    category: row.rule.category,
                    isEnabled: false,
                    bundleIdentifiers: row.rule.bundleIdentifiers,
                    appNameFragments: row.rule.appNameFragments,
                    urlHostSuffixes: row.rule.urlHostSuffixes,
                    urlContains: row.rule.urlContains,
                    titleFragments: row.rule.titleFragments)
                _ = try store.upsertUserRule(disabledRule)
            }
            statusMessage = "已禁用 \(row.id)。"
            rulesDidChange?()
            reload(selecting: row.id)
        } catch {
            statusMessage = friendlyRuleError(error)
        }
    }

    func restoreSelectedRule() {
        do {
            guard let row = selectedRow else {
                throw ActivityRuleEditorError.noSelection
            }
            _ = try store.removeUserRule(id: row.id)
            statusMessage = "已恢复 \(row.id)。"
            rulesDidChange?()
            reload(selecting: row.id)
        } catch {
            statusMessage = friendlyRuleError(error)
        }
    }

    func deleteSelectedRule() {
        do {
            guard let row = selectedRow else {
                throw ActivityRuleEditorError.noSelection
            }
            guard !row.isBuiltIn || row.hasUserOverride else {
                statusMessage = "内置规则不能删除，可以禁用。"
                return
            }
            _ = try store.removeUserRule(id: row.id)
            statusMessage = row.isBuiltIn ? "已移除 \(row.id) 的覆盖。" : "已删除 \(row.id)。"
            rulesDidChange?()
            reload()
        } catch {
            statusMessage = friendlyRuleError(error)
        }
    }

    func resetAllOverrides() {
        do {
            try store.resetUserRules()
            statusMessage = "已恢复全部默认规则。"
            rulesDidChange?()
            reload()
        } catch {
            statusMessage = friendlyRuleError(error)
        }
    }

    func openOverrideLocation() {
        do {
            try FileManager.default.createDirectory(
                at: store.userRulesURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: store.userRulesURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([store.userRulesURL])
            } else {
                NSWorkspace.shared.open(store.userRulesURL.deletingLastPathComponent())
            }
        } catch {
            statusMessage = friendlyRuleError(error)
        }
    }

    private func selectFirstVisibleRuleIfNeeded() {
        guard let selectedRuleID,
              filteredRows.contains(where: { $0.id == selectedRuleID })
        else {
            selectRule(id: filteredRows.first?.id)
            return
        }
    }

    private func nextCustomRuleId() -> String {
        let existingIds = Set(rows.map(\.id))
        var index = 1
        while existingIds.contains("custom-rule-\(index)") {
            index += 1
        }
        return "custom-rule-\(index)"
    }

    private func validateUniqueRuleId(_ id: String, originalId: String?) throws {
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if rows.contains(where: { $0.id == normalizedId && $0.id != originalId }) {
            throw ActivityRuleEditorError.duplicateRuleId(normalizedId)
        }
    }

    private func friendlyRuleError(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }

    private static func makeRows(from inventory: AppActivityRuleInventory) -> [ActivityRuleRow] {
        let userRulesById = Dictionary(uniqueKeysWithValues: inventory.userRules.map { ($0.id, $0) })
        let bundledIds = Set(inventory.bundledRules.map(\.id))
        var rows: [ActivityRuleRow] = inventory.bundledRules.map { bundledRule in
            if let userRule = userRulesById[bundledRule.id] {
                return ActivityRuleRow(
                    id: bundledRule.id,
                    rule: displayRule(bundledRule: bundledRule, userRule: userRule),
                    isBuiltIn: true,
                    hasUserOverride: true)
            }
            return ActivityRuleRow(
                id: bundledRule.id,
                rule: bundledRule,
                isBuiltIn: true,
                hasUserOverride: false)
        }

        rows.append(contentsOf: inventory.userRules
            .filter { !bundledIds.contains($0.id) }
            .map { ActivityRuleRow(id: $0.id, rule: $0, isBuiltIn: false, hasUserOverride: true) })
        return rows
    }

    private static func displayRule(bundledRule: AppActivityRule, userRule: AppActivityRule) -> AppActivityRule {
        guard !userRule.isEnabled && !userRule.hasMatchers else {
            return userRule
        }
        return AppActivityRule(
            id: bundledRule.id,
            category: userRule.category,
            isEnabled: false,
            bundleIdentifiers: bundledRule.bundleIdentifiers,
            appNameFragments: bundledRule.appNameFragments,
            urlHostSuffixes: bundledRule.urlHostSuffixes,
            urlContains: bundledRule.urlContains,
            titleFragments: bundledRule.titleFragments)
    }
}

struct ActivityRuleManagerView: View {
    @ObservedObject var viewModel: ActivityRuleManagerViewModel
    private var text: LocalizedText { .current }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(text.activityRuleLibrary)
                        .font(.headline)
                    Spacer()
                    Button {
                        viewModel.newCustomRule()
                    } label: {
                        Label(text.language == .zh ? "新增" : "New", systemImage: "plus")
                    }
                }

                Picker(text.language == .zh ? "过滤" : "Filter", selection: $viewModel.filter) {
                    ForEach(ActivityRuleFilter.allCases) { filter in
                        Text(filter.label(text: text)).tag(filter)
                    }
                }
                .pickerStyle(.menu)

                List {
                    ForEach(viewModel.filteredRows) { row in
                        ActivityRuleRowButton(
                            row: row,
                            isSelected: row.id == viewModel.selectedRuleID,
                            text: text)
                        {
                            viewModel.selectRule(id: row.id)
                        }
                    }
                }
                .listStyle(.sidebar)

                Text(text.language == .zh
                    ? "生效 \(viewModel.effectiveRuleCount) 条 · \(viewModel.overrideFilePath)"
                    : "Effective \(viewModel.effectiveRuleCount) · \(viewModel.overrideFilePath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(width: 300)
            .padding(16)

            Divider()

            ScrollView {
                ActivityRuleEditorView(viewModel: viewModel, text: text)
                    .frame(minWidth: 520, maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 600)
        .onAppear { viewModel.reload() }
    }
}

private struct ActivityRuleRowButton: View {
    let row: ActivityRuleRow
    let isSelected: Bool
    var text: LocalizedText = .current
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.id)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                    Text(row.sourceLabel(text: text))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.categoryLabel(text: text))
                    .font(.caption)
                    .foregroundStyle(row.rule.isEnabled ? .primary : .secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct ActivityRuleEditorView: View {
    @ObservedObject var viewModel: ActivityRuleManagerViewModel
    let text: LocalizedText

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.draft == nil {
                Text(text.language == .zh ? "请选择规则" : "Select a rule")
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(viewModel.draft?.isBuiltIn == true
                        ? (text.language == .zh ? "编辑内置覆盖" : "Edit Built-in Override")
                        : (text.language == .zh ? "编辑自定义规则" : "Edit Custom Rule"))
                        .font(.headline)
                    Spacer()
                    if viewModel.canRestoreSelectedRule {
                        Button {
                            viewModel.restoreSelectedRule()
                        } label: {
                            Label(text.language == .zh ? "恢复单条" : "Restore Rule", systemImage: "arrow.counterclockwise")
                        }
                    }
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text(text.language == .zh ? "规则 ID" : "Rule ID")
                        TextField(text.language == .zh ? "规则 ID" : "Rule ID", text: draftBinding(\.id, fallback: ""))
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.draft?.isBuiltIn == true)
                    }
                    GridRow {
                        Text(text.language == .zh ? "分类" : "Category")
                        Picker(text.language == .zh ? "分类" : "Category", selection: draftBinding(\.category, fallback: .study)) {
                            ForEach(AppActivityCategory.allCases, id: \.rawValue) { category in
                                Text(ActivityRuleRow.categoryLabel(category, text: text)).tag(category)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    GridRow {
                        Text(text.language == .zh ? "启用" : "Enabled")
                        Toggle("", isOn: draftBinding(\.isEnabled, fallback: true))
                            .labelsHidden()
                    }
                }

                RuleTextEditor(
                    title: "Bundle ID",
                    text: draftBinding(\.bundleIdentifiersText, fallback: ""))
                RuleTextEditor(
                    title: "App 名称片段",
                    text: draftBinding(\.appNameFragmentsText, fallback: ""))
                RuleTextEditor(
                    title: "URL host",
                    text: draftBinding(\.urlHostSuffixesText, fallback: ""))
                RuleTextEditor(
                    title: "URL contains",
                    text: draftBinding(\.urlContainsText, fallback: ""))
                RuleTextEditor(
                    title: "标题片段",
                    text: draftBinding(\.titleFragmentsText, fallback: ""))

                HStack {
                    Button {
                        viewModel.saveDraft()
                    } label: {
                        Label(text.language == .zh ? "保存" : "Save", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        viewModel.disableSelectedRule()
                    } label: {
                        Label(text.language == .zh ? "禁用" : "Disable", systemImage: "pause")
                    }

                    Button(role: .destructive) {
                        viewModel.deleteSelectedRule()
                    } label: {
                        Label(text.language == .zh ? "删除覆盖" : "Delete Override", systemImage: "trash")
                    }
                    .disabled(!viewModel.canDeleteSelectedRule)

                    Spacer()

                    Button {
                        viewModel.openOverrideLocation()
                    } label: {
                        Label(text.language == .zh ? "打开覆盖文件位置" : "Open Override Location", systemImage: "folder")
                    }
                }

                HStack {
                    Button(role: .destructive) {
                        viewModel.resetAllOverrides()
                    } label: {
                        Label(text.language == .zh ? "恢复全部默认规则" : "Restore All Defaults", systemImage: "gobackward")
                    }
                    Spacer()
                }
            }

            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.diagnostics, id: \.self) { diagnostic in
                Text(diagnostic)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
    }

    private func draftBinding<T>(
        _ keyPath: WritableKeyPath<ActivityRuleDraft, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: { viewModel.draft?[keyPath: keyPath] ?? fallback },
            set: { value in
                viewModel.updateDraft { draft in
                    draft[keyPath: keyPath] = value
                }
            })
    }
}

private struct RuleTextEditor: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 48, idealHeight: 58, maxHeight: 74)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        }
    }
}

@MainActor
final class ActivityRuleManagerWindowController: NSObject, NSWindowDelegate {
    static let shared = ActivityRuleManagerWindowController()

    private var window: NSWindow?
    private var viewModel: ActivityRuleManagerViewModel?

    func show(store: AppActivityRuleStore, onRulesChanged: @escaping () -> Void) {
        let viewModel = ActivityRuleManagerViewModel(store: store)
        viewModel.rulesDidChange = onRulesChanged
        self.viewModel = viewModel

        let rootView = ActivityRuleManagerView(viewModel: viewModel)
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "活动规则库"
            window.center()
            window.delegate = self
            window.isReleasedWhenClosed = false
            self.window = window
        }

        window?.contentView = NSHostingView(rootView: rootView)
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        viewModel = nil
    }
}

enum PetCardDisplayMode: String {
    case hidden
    case compact
    case full

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
    static let handleSize: CGFloat = 34
    static let handleHitPadding: CGFloat = 6
    static let handleTrailingOffset: CGFloat = 12
    static let handleBottomOffset: CGFloat = -4
    static let basePanelSize = CGSize(width: 356, height: 476)
    static let baseSpriteSize = CGSize(width: 194, height: 210)

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

    static func handleFrame(
        anchorFrame: NSRect,
        scale: CGFloat,
        isFlipped: Bool = false
    ) -> NSRect {
        let clamped = clampedScale(scale)
        let side = handleSize * clamped
        let y = isFlipped
            ? anchorFrame.maxY - side - handleBottomOffset * clamped
            : anchorFrame.minY + handleBottomOffset * clamped
        return NSRect(
            x: anchorFrame.maxX + handleTrailingOffset * clamped - side,
            y: y,
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
            return self.isResizeHandleHit(point, in: hosting)
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
        walkingEnabled ? viewModel.text.pauseWalking : viewModel.text.resumeWalking
    }

    var cardDisplayModeActionTitle: String {
        "\(viewModel.text.taskCardPrefix): \(viewModel.text.cardModeLabel(panelState.cardDisplayMode))"
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

    func resizeHandleFrameForTesting() -> NSRect {
        if let contentView {
            contentView.layoutSubtreeIfNeeded()
            return resizeHandleFrame(in: contentView)
        }
        return resizeHandleFrame(hostBounds: NSRect(origin: .zero, size: frame.size))
    }

    func isResizeHandleHitForTesting(at point: NSPoint) -> Bool {
        if let contentView {
            contentView.layoutSubtreeIfNeeded()
            return isResizeHandleHit(point, in: contentView)
        }
        return isResizeHandleHit(point, hostBounds: NSRect(origin: .zero, size: frame.size))
    }

    private func resizeHandleFrame(in hostView: NSView) -> NSRect {
        resizeHandleFrame(
            anchorFrame: renderedPetFrame(in: hostView) ?? fallbackPetFrame(in: hostView.bounds),
            isFlipped: hostView.isFlipped)
    }

    private func resizeHandleFrame(hostBounds: NSRect) -> NSRect {
        resizeHandleFrame(anchorFrame: fallbackPetFrame(in: hostBounds), isFlipped: false)
    }

    private func resizeHandleFrame(anchorFrame: NSRect, isFlipped: Bool) -> NSRect {
        MacPetResizeGeometry.handleFrame(
            anchorFrame: anchorFrame,
            scale: petScale,
            isFlipped: isFlipped)
    }

    private func renderedPetFrame(in hostView: NSView) -> NSRect? {
        guard spriteLayerView.window != nil,
              spriteLayerView.bounds.width > 1,
              spriteLayerView.bounds.height > 1
        else {
            return nil
        }
        let frame = spriteLayerView.convert(spriteLayerView.bounds, to: hostView)
        guard frame.width > 1, frame.height > 1 else {
            return nil
        }
        return frame
    }

    private func fallbackPetFrame(in hostBounds: NSRect) -> NSRect {
        let size = MacPetResizeGeometry.scaledSize(
            baseSize: MacPetResizeGeometry.baseSpriteSize,
            scale: petScale)
        return NSRect(
            x: hostBounds.midX - size.width / 2,
            y: hostBounds.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }

    private func isResizeHandleHit(_ point: NSPoint, in hostView: NSView) -> Bool {
        MacPetResizeGeometry.isResizeHit(
            point: point,
            handleFrame: resizeHandleFrame(in: hostView),
            scale: petScale)
    }

    private func isResizeHandleHit(_ point: NSPoint, hostBounds: NSRect) -> Bool {
        MacPetResizeGeometry.isResizeHit(
            point: point,
            handleFrame: resizeHandleFrame(hostBounds: hostBounds),
            scale: petScale)
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

    func refreshLanguageText() {
        if let hosting = contentView as? PetHostingView {
            hosting.petContextMenu = buildContextMenu()
        }
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
        applyScale(nextScale, preferRetainedScreen: false)
        clampCurrentPosition(preferRetainedScreen: false)
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

    private func clampCurrentPosition(preferRetainedScreen: Bool = true) {
        setFrameOrigin(clampedOrigin(frame.origin, preferRetainedScreen: preferRetainedScreen))
    }

    private func applyScale(_ scale: CGFloat, preferRetainedScreen: Bool = true) {
        let nextScale = MacPetResizeGeometry.clampedScale(scale)
        panelState.scale = nextScale
        var nextFrame = frame
        nextFrame.size = MacPetResizeGeometry.scaledSize(
            baseSize: MacPetResizeGeometry.basePanelSize,
            scale: nextScale)
        let nextClampedFrame = preferRetainedScreen
            ? Self.clampedFrame(nextFrame, preferredScreenIdentifier: retainedScreenIdentifier)
            : Self.clampedFrame(nextFrame, on: screen ?? NSScreen.main)
        setFrame(nextClampedFrame, display: true)
    }

    private func clampedOrigin(_ origin: NSPoint, preferRetainedScreen: Bool = true) -> NSPoint {
        var nextFrame = frame
        nextFrame.origin = origin
        let targetScreen = preferRetainedScreen
            ? targetScreen(for: nextFrame, preferRetainedScreen: true)
            : (screen ?? NSScreen.main ?? Self.screen(containing: nextFrame))
        guard let targetScreen else {
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

        let open = NSMenuItem(title: viewModel.text.openControlPanel, action: #selector(openControlPanelFromMenu), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let refresh = NSMenuItem(title: viewModel.text.refreshPet, action: #selector(refreshPetFromMenu), keyEquivalent: "")
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

        let resetPosition = NSMenuItem(title: viewModel.text.resetPetPosition, action: #selector(resetPetPositionFromMenu), keyEquivalent: "")
        resetPosition.target = self
        menu.addItem(resetPosition)

        let hide = NSMenuItem(title: viewModel.text.hidePet, action: #selector(hidePetFromMenu), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let importPet = NSMenuItem(title: viewModel.text.importPetMenu, action: #selector(importPetFromMenu), keyEquivalent: "")
        importPet.target = self
        menu.addItem(importPet)

        let exportPet = NSMenuItem(title: viewModel.text.exportPetMenu, action: #selector(exportPetFromMenu), keyEquivalent: "")
        exportPet.target = self
        menu.addItem(exportPet)

        menu.addItem(.separator())

        let exit = NSMenuItem(title: viewModel.text.quitVibestick, action: #selector(quitFromMenu), keyEquivalent: "")
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
        cardDisplayModeMenuItem.title = cardDisplayModeActionTitle
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
        guard let targetScreen = screen(identifier: preferredScreenIdentifier) ?? screen(containing: frame) ?? NSScreen.main else {
            return frame
        }

        return clampedFrame(frame, on: targetScreen)
    }

    private static func clampedFrame(_ frame: NSRect, on targetScreen: NSScreen?) -> NSRect {
        var next = frame
        guard let targetScreen else {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

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

    override func mouseEntered(with event: NSEvent) {
        updateResizeHover(at: convert(event.locationInWindow, from: nil))
        super.mouseEntered(with: event)
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
                    .overlay(alignment: .bottomTrailing) {
                        ZStack {
                            resizeHoverTarget
                            resizeHandle
                        }
                        .frame(
                            width: MacPetResizeGeometry.handleSize + MacPetResizeGeometry.handleHitPadding * 2,
                            height: MacPetResizeGeometry.handleSize + MacPetResizeGeometry.handleHitPadding * 2)
                        .offset(
                            x: MacPetResizeGeometry.handleTrailingOffset + MacPetResizeGeometry.handleHitPadding,
                            y: -MacPetResizeGeometry.handleBottomOffset + MacPetResizeGeometry.handleHitPadding)
                    }
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

    private var resizeHoverTarget: some View {
        Color.clear
            .contentShape(Rectangle())
            .onHover { hovering in
                panelState.resizeHandleVisible = hovering
            }
            .accessibilityHidden(true)
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
