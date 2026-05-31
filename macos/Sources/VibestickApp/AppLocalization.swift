import Foundation
import VibestickMacCore

enum AppLanguage: String, Equatable {
    case zh
    case en
}

enum AppLanguagePreference: String, CaseIterable, Identifiable, Equatable {
    case system
    case zh
    case en

    static let defaultsKey = "VibestickLanguagePreference"

    var id: String { rawValue }

    static func parse(_ value: String?) -> AppLanguagePreference {
        value.flatMap(AppLanguagePreference.init(rawValue:)) ?? .system
    }

    static func load(defaults: UserDefaults = .standard) -> AppLanguagePreference {
        parse(defaults.string(forKey: defaultsKey))
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    func resolvedLanguage(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .zh:
            return .zh
        case .en:
            return .en
        case .system:
            return Self.systemLanguage(preferredLanguages: preferredLanguages)
        }
    }

    static func systemLanguage(preferredLanguages: [String]) -> AppLanguage {
        let preferred = preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("zh") ? .zh : .en
    }
}

struct LocalizedText: Equatable {
    let language: AppLanguage

    static var current: LocalizedText {
        LocalizedText(language: AppLanguagePreference.load().resolvedLanguage())
    }

    func languagePreferenceLabel(_ preference: AppLanguagePreference) -> String {
        switch (language, preference) {
        case (.zh, .system): return "跟随系统"
        case (.zh, .zh): return "中文"
        case (.zh, .en): return "English"
        case (.en, .system): return "System"
        case (.en, .zh): return "中文"
        case (.en, .en): return "English"
        }
    }

    func focusPreferenceLabel(_ preference: PetFocusPreference) -> String {
        switch (language, preference) {
        case (.zh, .automatic): return "自动"
        case (.zh, .on): return "开启"
        case (.zh, .off): return "关闭"
        case (.en, .automatic): return "Auto"
        case (.en, .on): return "On"
        case (.en, .off): return "Off"
        }
    }

    func cardModeLabel(_ mode: PetCardDisplayMode) -> String {
        switch (language, mode) {
        case (.zh, .hidden): return "隐藏"
        case (.zh, .compact): return "紧凑"
        case (.zh, .full): return "完整"
        case (.en, .hidden): return "Hidden"
        case (.en, .compact): return "Compact"
        case (.en, .full): return "Full"
        }
    }

    func modeLabel(_ mode: VibestickMode) -> String {
        switch (language, mode) {
        case (.zh, .off): return "关闭"
        case (.zh, .on): return "保持唤醒"
        case (.zh, .hyper): return "HYPER"
        case (.en, .off): return "Off"
        case (.en, .on): return "Keep Awake"
        case (.en, .hyper): return "HYPER"
        }
    }

    func activityCategoryLabel(_ category: AppActivityCategory) -> String {
        switch (language, category) {
        case (.zh, .study): return "学习"
        case (.zh, .distraction): return "摆烂"
        case (.zh, .neutral): return "中性"
        case (.en, .study): return "Study"
        case (.en, .distraction): return "Distraction"
        case (.en, .neutral): return "Neutral"
        }
    }

    var quitVibestick: String { language == .zh ? "退出 Vibestick" : "Quit Vibestick" }
    var loadingStatus: String { language == .zh ? "正在读取状态..." : "Loading status..." }
    var doctorNotRun: String { language == .zh ? "尚未运行诊断。" : "Doctor has not run yet." }
    var activityRulesLoading: String { language == .zh ? "正在读取活动规则..." : "Loading activity rules..." }
    var languageLabel: String { language == .zh ? "语言" : "Language" }
    var openControlPanel: String { language == .zh ? "打开控制面板" : "Open Control Panel" }
    var refreshStatus: String { language == .zh ? "刷新状态" : "Refresh Status" }
    var showPet: String { language == .zh ? "显示桌宠" : "Show Pet" }
    var hidePet: String { language == .zh ? "隐藏桌宠" : "Hide Pet" }
    var pauseWalking: String { language == .zh ? "暂停行走" : "Pause Walking" }
    var resumeWalking: String { language == .zh ? "恢复行走" : "Resume Walking" }
    var taskCardPrefix: String { language == .zh ? "任务卡" : "Task Card" }
    var focusModePrefix: String { language == .zh ? "勿扰模式" : "Focus Mode" }
    var focusSummaryPrefix: String { language == .zh ? "勿扰" : "Focus" }
    var resetPetPosition: String { language == .zh ? "重置桌宠位置" : "Reset Pet Position" }
    var importPetMenu: String { language == .zh ? "导入宠物..." : "Import Pet..." }
    var exportPetMenu: String { language == .zh ? "导出当前宠物..." : "Export Current Pet..." }
    var refreshPet: String { language == .zh ? "刷新桌宠" : "Refresh Pet" }
    var quit: String { language == .zh ? "退出" : "Quit" }
    var noActiveTasks: String { language == .zh ? "无活跃任务" : "No active tasks" }
    var activeTaskUnit: String { language == .zh ? "个活跃任务" : "active task(s)" }
    var petVisible: String { language == .zh ? "显示" : "Visible" }
    var petHidden: String { language == .zh ? "隐藏" : "Hidden" }
    var walking: String { language == .zh ? "行走中" : "Walking" }
    var paused: String { language == .zh ? "暂停" : "Paused" }
    var autoReduced: String { language == .zh ? "已降低" : "Reduced" }
    var auto: String { language == .zh ? "自动" : "Auto" }
    var on: String { language == .zh ? "开启" : "On" }
    var off: String { language == .zh ? "关闭" : "Off" }
    var modePrefix: String { language == .zh ? "模式" : "Mode" }
    var taskPrefix: String { language == .zh ? "任务" : "Tasks" }
    var petPrefix: String { language == .zh ? "桌宠" : "Pet" }
    var walkingPrefix: String { language == .zh ? "行走" : "Walking" }
    var petLibraryPrefix: String { language == .zh ? "宠物" : "Pet" }
    var completeInstall: String { language == .zh ? "完成安装" : "Complete Install" }
    var installing: String { language == .zh ? "安装中..." : "Installing..." }
    var modeOffButton: String { language == .zh ? "关闭" : "Off" }
    var keepAwakeButton: String { language == .zh ? "保持唤醒" : "Keep Awake" }
    var stopHyper: String { language == .zh ? "停止 HYPER" : "Stop HYPER" }
    var refresh: String { language == .zh ? "刷新" : "Refresh" }
    var doctor: String { language == .zh ? "诊断" : "Doctor" }
    var installHelper: String { language == .zh ? "安装 Helper" : "Install Helper" }
    var accessibility: String { language == .zh ? "辅助功能授权" : "Accessibility" }
    var deviceWatcherPrefix: String { language == .zh ? "插盘自启" : "Device Auto-Start" }
    var processing: String { language == .zh ? "处理中..." : "Processing..." }
    var enableDeviceWatcher: String { language == .zh ? "启用插盘自启" : "Enable Auto-Start" }
    var disableDeviceWatcher: String { language == .zh ? "关闭插盘自启" : "Disable Auto-Start" }
    var activityRuleLibrary: String { language == .zh ? "活动规则库" : "Activity Rules" }
    var currentActivityPrefix: String { language == .zh ? "当前" : "Current" }
    var noCurrentActivity: String { language == .zh ? "尚未检测" : "Not detected" }
    var noMatchedRule: String { language == .zh ? "未命中" : "No match" }
    var manageActivityRules: String { language == .zh ? "管理活动规则库" : "Manage Activity Rules" }
    var petLibrary: String { language == .zh ? "宠物库" : "Pet Library" }
    var builtIn: String { language == .zh ? "内置" : "Built-in" }
    var currentPet: String { language == .zh ? "当前宠物" : "Current Pet" }
    var importPet: String { language == .zh ? "导入宠物" : "Import Pet" }
    var exportCurrent: String { language == .zh ? "导出当前" : "Export Current" }
    var deleteCustom: String { language == .zh ? "删除自定义" : "Delete Custom" }
    var petActionFrequency: String { language == .zh ? "宠物动作频率" : "Pet Action Frequency" }
    var randomActionFrequency: String { language == .zh ? "随机动作频率" : "Random Actions" }
    var walkingSpeed: String { language == .zh ? "行走速度" : "Walking Speed" }
    var wanderPauseFrequency: String { language == .zh ? "游荡/停顿频率" : "Wander / Pause" }
    var restorePending: String { language == .zh ? "有待恢复的 pmset 备份" : "pmset backup pending" }
    var noRestoreNeeded: String { language == .zh ? "无需恢复" : "No restore needed" }
    var hyperGuardRunning: String { language == .zh ? "正在保持唤醒" : "Keeping awake" }
    var hyperGuardStopped: String { language == .zh ? "未运行" : "Stopped" }
    var powerUnavailable: String { language == .zh ? "无法读取" : "Unavailable" }
    var unknownBattery: String { language == .zh ? "未知电量" : "Unknown battery" }
    var acConnected: String { language == .zh ? "已连接外接电源" : "AC connected" }
    var onBattery: String { language == .zh ? "正在使用电池" : "On battery" }
    var temporarilyUnreadableInstallHelper: String { language == .zh ? "暂不可读；请先安装 Helper" : "Unavailable; install Helper first" }
    var temporarilyUnreadableRunDoctor: String { language == .zh ? "暂不可读；请运行诊断查看 Helper 与 pmset 状态" : "Unavailable; run Doctor to inspect Helper and pmset" }
    var helperInstalled: String { language == .zh ? "已安装" : "Installed" }
    var helperReady: String { language == .zh ? "未安装，可点击“安装 Helper”" : "Not installed; click Install Helper" }
    var helperResourcesMissing: String { language == .zh ? "安装资源缺失，请先重新构建 macOS app" : "Install resources missing; rebuild the macOS app" }
    var deviceWatcherInstalled: String { language == .zh ? "已启用：插入 Vibestick RP2040 会启动或聚焦 app。" : "Enabled: inserting Vibestick RP2040 launches or focuses the app." }
    var deviceWatcherReady: String { language == .zh ? "未启用：可安装当前 app 的用户级 LaunchAgent。" : "Disabled: can install the current app's user LaunchAgent." }
    var watcherMissing: String { language == .zh ? "不可安装：找不到 VibestickDeviceWatcher，请先重新构建 app。" : "Cannot install: VibestickDeviceWatcher is missing. Rebuild the app first." }
    var appMissing: String { language == .zh ? "不可安装：找不到 Vibestick.app，请先构建或安装 app。" : "Cannot install: Vibestick.app is missing. Build or install the app first." }
    var deviceWatcherDisabled: String { language == .zh ? "未启用。" : "Disabled." }
    var helperRequiredRestore: String { language == .zh ? "需要先安装 Helper 才能恢复 pmset 睡眠策略。" : "Install Helper before restoring the pmset sleep policy." }
    var helperRequiredModify: String { language == .zh ? "需要先安装 Helper 才能修改 macOS 睡眠策略。" : "Install Helper before changing the macOS sleep policy." }
    var helperNotInstalled: String { language == .zh ? "Helper 尚未安装或无法启动，请点击“安装 Helper”。" : "Helper is not installed or cannot start; click Install Helper." }
    var firstLaunchMoveFromDmg: String { language == .zh ? "请先把 Vibestick 拖到 Applications 后再打开，才能完成 Helper 和插盘自启安装。" : "Move Vibestick to Applications and reopen it to finish Helper and auto-start setup." }
    var firstLaunchMoveToApplications: String { language == .zh ? "请把 Vibestick.app 移到 Applications 后再完成安装。" : "Move Vibestick.app to Applications before finishing setup." }
    var installComplete: String { language == .zh ? "Vibestick 安装已完成。" : "Vibestick setup is complete." }
    var installResourcesMissing: String { language == .zh ? "安装资源缺失，请重新构建或重新下载 Vibestick。" : "Install resources are missing; rebuild or download Vibestick again." }
}
