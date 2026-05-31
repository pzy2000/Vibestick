using System.Globalization;
using Vibestick.Core;

namespace Vibestick.Gui;

public enum GuiLanguage
{
    Zh,
    En
}

public enum GuiLanguagePreference
{
    System,
    Zh,
    En
}

public static class GuiLanguagePreferenceExtensions
{
    public static GuiLanguagePreference ParseLanguagePreference(string? value)
    {
        return value?.Trim().ToLowerInvariant() switch
        {
            "system" => GuiLanguagePreference.System,
            "zh" or "zh-cn" or "zh-hans" => GuiLanguagePreference.Zh,
            "en" or "en-us" => GuiLanguagePreference.En,
            _ => GuiLanguagePreference.System
        };
    }

    public static string ToStorageValue(this GuiLanguagePreference preference)
    {
        return preference switch
        {
            GuiLanguagePreference.Zh => "zh",
            GuiLanguagePreference.En => "en",
            _ => "system"
        };
    }

    public static GuiLanguage Resolve(this GuiLanguagePreference preference, CultureInfo? culture = null)
    {
        return preference switch
        {
            GuiLanguagePreference.Zh => GuiLanguage.Zh,
            GuiLanguagePreference.En => GuiLanguage.En,
            _ => ((culture ?? CultureInfo.CurrentUICulture).Name.StartsWith("zh", StringComparison.OrdinalIgnoreCase)
                ? GuiLanguage.Zh
                : GuiLanguage.En)
        };
    }
}

public sealed class GuiText
{
    private GuiText(GuiLanguage language)
    {
        Language = language;
    }

    public GuiLanguage Language { get; }

    public static GuiText For(GuiLanguage language) => new(language);

    public string LanguageLabel => Language == GuiLanguage.Zh ? "语言" : "Language";
    public string LanguageSystem => Language == GuiLanguage.Zh ? "跟随系统" : "System";
    public string LanguageChinese => "中文";
    public string LanguageEnglish => "English";
    public string OpenControlPanel => Language == GuiLanguage.Zh ? "打开控制面板" : "Open Control Panel";
    public string HidePet => Language == GuiLanguage.Zh ? "隐藏桌宠" : "Hide Pet";
    public string ShowPet => Language == GuiLanguage.Zh ? "显示桌宠" : "Show Pet";
    public string ImportPetMenu => Language == GuiLanguage.Zh ? "导入宠物..." : "Import Pet...";
    public string ExportPetMenu => Language == GuiLanguage.Zh ? "导出当前宠物..." : "Export Current Pet...";
    public string ExitVibestick => Language == GuiLanguage.Zh ? "退出 Vibestick" : "Exit Vibestick";
    public string Title => "Vibestick";
    public string Subtitle => Language == GuiLanguage.Zh ? "Windows 睡眠策略控制面板" : "Windows sleep-policy control panel";
    public string Mode => Language == GuiLanguage.Zh ? "模式" : "Mode";
    public string LidClose => Language == GuiLanguage.Zh ? "合盖动作" : "Lid Close";
    public string Battery => Language == GuiLanguage.Zh ? "电池" : "Battery";
    public string PowerScheme => Language == GuiLanguage.Zh ? "电源计划" : "Power Scheme";
    public string RestorePending => Language == GuiLanguage.Zh ? "待恢复" : "Restore Pending";
    public string HyperGuard => Language == GuiLanguage.Zh ? "HYPER 守护" : "HYPER Guard";
    public string RunningTasks => Language == GuiLanguage.Zh ? "运行任务" : "Running Tasks";
    public string RefreshStatus => Language == GuiLanguage.Zh ? "刷新状态" : "Refresh Status";
    public string RunDoctor => Language == GuiLanguage.Zh ? "运行诊断" : "Run Doctor";
    public string ModeOn => Language == GuiLanguage.Zh ? "模式 ON" : "Mode ON";
    public string ModeHyper => "Mode HYPER";
    public string StopHyperGuard => Language == GuiLanguage.Zh ? "停止 HYPER 守护" : "Stop HYPER Guard";
    public string OffRevert => Language == GuiLanguage.Zh ? "关闭 / 恢复" : "OFF / Revert";
    public string PetLibrary => Language == GuiLanguage.Zh ? "宠物库" : "Pet Library";
    public string ImportPet => Language == GuiLanguage.Zh ? "导入宠物" : "Import Pet";
    public string ExportCurrent => Language == GuiLanguage.Zh ? "导出当前" : "Export Current";
    public string DeleteCustomPet => Language == GuiLanguage.Zh ? "删除自定义宠物" : "Delete Custom Pet";
    public string BuiltIn => Language == GuiLanguage.Zh ? "内置" : "Built-in";
    public string RandomActions => Language == GuiLanguage.Zh ? "随机动作" : "Random actions";
    public string WalkingSpeed => Language == GuiLanguage.Zh ? "行走速度" : "Walking speed";
    public string WanderPause => Language == GuiLanguage.Zh ? "游荡 / 停顿" : "Wander / pause";
    public string HyperWatch => "HYPER Watch";
    public string Protection => Language == GuiLanguage.Zh ? "保护状态" : "Protection";
    public string BatterySafety => Language == GuiLanguage.Zh ? "电池安全" : "Battery Safety";
    public string Timing => Language == GuiLanguage.Zh ? "时间" : "Timing";
    public string DoctorSnapshot => Language == GuiLanguage.Zh ? "诊断快照" : "Doctor Snapshot";
    public string Ready => Language == GuiLanguage.Zh ? "就绪。" : "Ready.";
    public string StatusRefreshed => Language == GuiLanguage.Zh ? "状态已刷新。" : "Status refreshed.";
    public string DoctorPassed => Language == GuiLanguage.Zh ? "诊断通过。" : "Doctor passed.";
    public string DoctorFoundIssues => Language == GuiLanguage.Zh ? "诊断发现问题。" : "Doctor found issues.";
    public string HyperGuardStarted => Language == GuiLanguage.Zh ? "HYPER 守护已启动。此窗口保持打开时会阻止系统空闲睡眠。" : "HYPER guard started. Idle system sleep is blocked while this window stays open.";
    public string HyperGuardStopped => Language == GuiLanguage.Zh ? "HYPER 守护已停止。模式状态降级为 ON。" : "HYPER guard stopped. Mode state downgraded to ON.";
    public string CriticalBatteryActionApplied => Language == GuiLanguage.Zh ? "已应用临界电量动作。" : "Critical battery action applied.";
    public string BatterySafetyDowngraded => Language == GuiLanguage.Zh ? "电池安全策略已将 HYPER 降级为 ON。" : "Battery safety downgraded HYPER to ON.";
    public string Yes => Language == GuiLanguage.Zh ? "是" : "Yes";
    public string No => Language == GuiLanguage.Zh ? "否" : "No";
    public string NoTasks => Language == GuiLanguage.Zh ? "未检测到白名单中的长时间运行任务。" : "No whitelisted long-running tasks detected.";
    public string Running => Language == GuiLanguage.Zh ? "运行中" : "Running";
    public string Stopped => Language == GuiLanguage.Zh ? "已停止" : "Stopped";
    public string RefreshProtection => Language == GuiLanguage.Zh ? "刷新状态以读取保护状态。" : "Refresh status to load protection state.";
    public string BatteryPending => Language == GuiLanguage.Zh ? "电池安全检查待运行。" : "Battery safety check pending.";
    public string GuardStoppedTiming => Language == GuiLanguage.Zh ? "守护已停止\n安全检查已暂停\n上次刷新：-" : "Guard stopped\nSafety check paused\nLast refresh: -";
    public string DoctorNotRun => Language == GuiLanguage.Zh ? "尚未运行诊断。" : "Doctor not run yet.";
    public string PauseWalking => Language == GuiLanguage.Zh ? "暂停行走" : "Pause Walking";
    public string ResumeWalking => Language == GuiLanguage.Zh ? "恢复行走" : "Resume Walking";
    public string RefreshPet => Language == GuiLanguage.Zh ? "刷新桌宠" : "Refresh Pet";

    public string ModeLabel(VibestickMode mode)
    {
        return mode switch
        {
            VibestickMode.Off => Language == GuiLanguage.Zh ? "关闭" : "Off",
            VibestickMode.On => Language == GuiLanguage.Zh ? "保持唤醒" : "On",
            VibestickMode.Hyper => "HYPER",
            _ => mode.ToString()
        };
    }

    public string ImportPetDialogTitle => Language == GuiLanguage.Zh ? "导入 Vibestick 宠物" : "Import Vibestick Pet";
    public string ImportPetFilter => Language == GuiLanguage.Zh
        ? "Vibestick 宠物和图集|*.vibestick-pet.zip;*.zip;*.png;*.webp|所有文件|*.*"
        : "Vibestick pets and atlases|*.vibestick-pet.zip;*.zip;*.png;*.webp|All files|*.*";
    public string ExportPetDialogTitle => Language == GuiLanguage.Zh ? "导出 Vibestick 宠物" : "Export Vibestick Pet";
    public string ExportPetFilter => Language == GuiLanguage.Zh
        ? "Vibestick 宠物包|*.vibestick-pet.zip|Zip 归档|*.zip"
        : "Vibestick pet package|*.vibestick-pet.zip|Zip archive|*.zip";
    public string ImportedAndSwitched(string name) => Language == GuiLanguage.Zh ? $"已导入并切换到 {name}。" : $"Imported and switched to {name}.";
    public string Exported(string name) => Language == GuiLanguage.Zh ? $"已导出 {name}。" : $"Exported {name}.";
    public string PetExistsReplace(string id) => Language == GuiLanguage.Zh ? $"宠物“{id}”已存在。是否替换？" : $"Pet '{id}' already exists. Replace it?";
    public string BuiltInPetCannotDelete => Language == GuiLanguage.Zh ? "内置宠物不能删除。" : "The built-in pet cannot be deleted.";
    public string DeletePetConfirm(string name) => Language == GuiLanguage.Zh ? $"删除 {name}？此操作不能撤销。" : $"Delete {name}? This cannot be undone.";
    public string ImportPetAtlas => Language == GuiLanguage.Zh ? "导入宠物 Atlas" : "Import Pet Atlas";
    public string PetName => Language == GuiLanguage.Zh ? "宠物名称" : "Pet name";
    public string Description => Language == GuiLanguage.Zh ? "描述" : "Description";
    public string Cancel => Language == GuiLanguage.Zh ? "取消" : "Cancel";
    public string Import => Language == GuiLanguage.Zh ? "导入" : "Import";
    public string ImportedPetName => Language == GuiLanguage.Zh ? "导入的宠物" : "Imported Pet";
    public string ImportedPetDescription => Language == GuiLanguage.Zh ? "导入的 Vibestick 宠物。" : "Imported Vibestick pet.";
    public string PetNameRequired => Language == GuiLanguage.Zh ? "宠物名称不能为空。" : "Pet name is required.";
}
