// DashSplit preferences pane — the 车载分屏 page in Settings.
//
// 0.1.49: complete architecture change — multi-select app list replaces
// fixed 3-slot pickers. Selected apps get dynamic per-app ratio and scale
// sliders. Split mode selector removed. Capsule-based UI on the car display.

import Preferences
import UIKit

private let prefsFile = "/var/mobile/Library/Preferences/zp.dashsplit.plist"
private let keyEnabled = "Enabled"
private let keySelectedApps = "SelectedApps"
private let keyFitMode = "FitMode"
private let keyTestLandscape = "TestLandscape"

// Tweak version shown in the settings pane.
private let tweakVersion = "0.1.51"

private let prefsDomain = "zp.dashsplit" as CFString

private func loadPrefs() -> [String: Any] {
    (NSDictionary(contentsOfFile: prefsFile) as? [String: Any]) ?? [:]
}

private func setPref(_ value: Any, forKey key: String) {
    CFPreferencesSetValue(key as CFString, value as CFTypeRef, prefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(prefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

private func boolPref(_ key: String, defaultValue: Bool) -> Bool {
    if let value = CFPreferencesCopyAppValue(key as CFString, prefsDomain) as? Bool {
        return value
    }
    if let value = loadPrefs()[key] as? Bool {
        return value
    }
    return defaultValue
}

// MARK: - Selected apps (comma-separated bundle IDs)

private func selectedAppIDs() -> [String] {
    if let value = CFPreferencesCopyAppValue(keySelectedApps as CFString, prefsDomain) as? String, !value.isEmpty {
        return value.components(separatedBy: ",").filter { !$0.isEmpty }
    }
    if let value = loadPrefs()[keySelectedApps] as? String, !value.isEmpty {
        return value.components(separatedBy: ",").filter { !$0.isEmpty }
    }
    // Defaults: 时钟 + 日历
    return ["com.apple.mobiletimer", "com.apple.mobilecal"]
}

private func setSelectedAppIDs(_ ids: [String]) {
    setPref(ids.joined(separator: ","), forKey: keySelectedApps)
}

private func toggleAppSelected(_ bundleID: String) {
    var ids = selectedAppIDs()
    if let idx = ids.firstIndex(of: bundleID) {
        ids.remove(at: idx)
    } else {
        ids.append(bundleID)
    }
    setSelectedAppIDs(ids)
}

// MARK: - Per-app ratio and scale keys

private func ratioKey(_ bundleID: String) -> String { "AppRatio_\(bundleID)" }
private func scaleKey(_ bundleID: String) -> String { "AppScale_\(bundleID)" }

private func appRatio(_ bundleID: String) -> Int {
    if let value = CFPreferencesCopyAppValue(ratioKey(bundleID) as CFString, prefsDomain) as? Int, value > 0 {
        return value
    }
    return 1
}

private func appScale(_ bundleID: String) -> Int {
    if let value = CFPreferencesCopyAppValue(scaleKey(bundleID) as CFString, prefsDomain) as? Int, value >= 10 {
        return value
    }
    return 100
}

// MARK: - Fit mode

private func currentFitMode() -> Int {
    if let value = CFPreferencesCopyAppValue(keyFitMode as CFString, prefsDomain) as? Int, value >= 0 && value <= 1 {
        return value
    }
    if let value = loadPrefs()[keyFitMode] as? Int, value >= 0 && value <= 1 {
        return value
    }
    return 0
}

private func fitModeName() -> String {
    switch currentFitMode() {
    case 1: return "拉伸填满"
    default: return "等比缩放"
    }
}

// MARK: - App list (filtered)

// System apps that are useful for CarPlay projection (have meaningful content).
private let allowedSystemBundlePrefixes: [String] = [
    "com.apple.mobiletimer",    // 时钟
    "com.apple.mobilecal",      // 日历
    "com.apple.calculator",     // 计算器
    "com.apple.weather",        // 天气
    "com.apple.MobileAddressBook", // 通讯录
    "com.apple.AppleStore",     // App Store
    "com.apple.stocks",         // 股市
    "com.apple.mobilemail",     // 邮件
    "com.apple.MobileSMS",      // 信息
    "com.apple.Maps",           // 地图
    "com.apple.Music",          // 音乐
    "com.apple.Preferences",    // 设置
    "com.apple.facetime",       // FaceTime
    "com.apple.shortcuts",      // 快捷指令
    "com.apple.Health",         // 健康
    "com.apple.Home",           // 家庭
    "com.apple.podcasts",       // 播客
    "com.apple.VoiceMemos",     // 语音备忘录
    "com.apple.iBooks",         // 图书
    "com.apple.Translate",      // 翻译
]

private func isAllowedApp(_ bundleID: String, isSystem: Bool) -> Bool {
    if !isSystem { return true }  // All user apps are allowed
    // For system apps, only allow known useful ones
    for prefix in allowedSystemBundlePrefixes {
        if bundleID == prefix || bundleID.hasPrefix(prefix + ".") {
            return true
        }
    }
    return false
}

private func installedApps() -> [[String: String]] {
    if let bundle = Bundle(path: "/System/Library/PrivateFrameworks/MobileCoreServices.framework"), !bundle.isLoaded {
        bundle.load()
    }
    guard
        let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
        workspaceClass.responds(to: NSSelectorFromString("defaultWorkspace"))
    else { return [] }
    guard let workspace = workspaceClass.perform(NSSelectorFromString("defaultWorkspace"))?.takeUnretainedValue() as? NSObject
    else { return [] }
    guard workspace.responds(to: NSSelectorFromString("allInstalledApplications")),
          let proxies = workspace.perform(NSSelectorFromString("allInstalledApplications"))?.takeUnretainedValue() as? [NSObject]
    else { return [] }

    var apps: [[String: String]] = []
    var seen = Set<String>()
    for proxy in proxies {
        guard let name = proxy.value(forKey: "localizedName") as? String, !name.isEmpty,
              let bundleID = proxy.value(forKey: "bundleIdentifier") as? String, !bundleID.isEmpty
        else { continue }
        if seen.contains(bundleID) { continue }

        let rawType = proxy.value(forKey: "applicationType")
        var isSystem = false
        if let type = rawType as? String {
            if type == "System" { isSystem = true }
            else if type == "User" { isSystem = false }
            else { continue }
        } else if let type = rawType as? NSNumber {
            let raw = type.intValue
            if raw == 1 { isSystem = true }
            else if raw == 0 { isSystem = false }
            else { continue }
        } else { continue }

        // Filter out uncommon system apps
        if !isAllowedApp(bundleID, isSystem: isSystem) { continue }

        seen.insert(bundleID)
        apps.append(["name": name, "id": bundleID])
    }
    apps.sort { ($0["name"] ?? "") < ($1["name"] ?? "") }
    return apps
}

private func appName(for bundleID: String, apps: [[String: String]]) -> String {
    apps.first(where: { $0["id"] == bundleID })?["name"] ?? bundleID
}

// MARK: - Multi-select app picker

private final class MultiAppRowTarget: NSObject {
    let bundleID: String
    weak var picker: MultiAppPickerController?

    init(bundleID: String, picker: MultiAppPickerController?) {
        self.bundleID = bundleID
        self.picker = picker
    }

    @objc func toggleApp() {
        toggleAppSelected(bundleID)
        NSLog("[DashSplitPref] toggle app: %@ ", bundleID)
        // Reload the picker to show updated selection state.
        picker?.reloadPicker()
        // Also refresh the parent pane so dynamic sliders update.
        if let nav = picker?.navigationController, nav.viewControllers.count >= 2,
           let parent = nav.viewControllers[nav.viewControllers.count - 2] as? DashSplitPrefListController {
            parent.refreshPane()
        }
    }
}

class MultiAppPickerController: PSListController {
    private var rowTargets: [MultiAppRowTarget] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "选择应用"
    }

    @objc func reloadPicker() {
        setValue(nil, forKey: "_specifiers")
        perform(NSSelectorFromString("reloadSpecifiers"))
    }

    override var specifiers: NSMutableArray? {
        get {
            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }

            let selected = Set(selectedAppIDs())
            let apps = installedApps()
            rowTargets = []

            var specifiers = NSMutableArray()
            specifiers.add(PSSpecifier.emptyGroup())

            for app in apps {
                let bid = app["id"] ?? ""
                let name = app["name"] ?? ""
                let isSelected = selected.contains(bid)
                let title = isSelected ? "✓ \(name)" : name

                let target = MultiAppRowTarget(bundleID: bid, picker: self)
                rowTargets.append(target)

                let row = PSSpecifier.preferenceSpecifierNamed(
                    title,
                    target: target,
                    set: nil,
                    get: nil,
                    detail: nil,
                    cell: .buttonCell,
                    edit: nil
                )
                row?.buttonAction = #selector(MultiAppRowTarget.toggleApp)
                if let row = row { specifiers.add(row) }
            }

            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        set { super.specifiers = newValue }
    }
}

@objc(DashSplitMultiAppPicker)
final class DashSplitMultiAppPicker: MultiAppPickerController {}

// MARK: - Fit mode picker (等比缩放 / 拉伸填满)

private final class FitModeRowTarget: NSObject {
    let mode: Int
    weak var picker: FitModePickerController?

    init(mode: Int, picker: FitModePickerController?) {
        self.mode = mode
        self.picker = picker
    }

    @objc func selectMode() {
        setPref(mode, forKey: keyFitMode)
        NSLog("[DashSplitPref] set FitMode = %d", mode)
        if let nav = picker?.navigationController, nav.viewControllers.count >= 2,
           let parent = nav.viewControllers[nav.viewControllers.count - 2] as? DashSplitPrefListController {
            parent.refreshPane()
        }
        picker?.navigationController?.popViewController(animated: true)
    }
}

class FitModePickerController: PSListController {
    private var rowTargets: [FitModeRowTarget] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "显示模式"
    }

    override var specifiers: NSMutableArray? {
        get {
            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }

            let current = currentFitMode()
            rowTargets = []

            var specifiers = NSMutableArray()
            specifiers.add(PSSpecifier.emptyGroup())

            let modes: [(Int, String)] = [
                (0, "等比缩放"),
                (1, "拉伸填满")
            ]
            for (mode, name) in modes {
                let title = mode == current ? "✓ \(name)" : name
                let target = FitModeRowTarget(mode: mode, picker: self)
                rowTargets.append(target)
                let row = PSSpecifier.preferenceSpecifierNamed(
                    title,
                    target: target,
                    set: nil,
                    get: nil,
                    detail: nil,
                    cell: .buttonCell,
                    edit: nil
                )
                row?.buttonAction = #selector(FitModeRowTarget.selectMode)
                if let row = row { specifiers.add(row) }
            }

            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        set { super.specifiers = newValue }
    }
}

@objc(DashSplitFitModePicker)
final class DashSplitFitModePicker: FitModePickerController {}

// MARK: - Test orientation (横屏/竖屏预览)

func currentTestLandscape() -> Bool {
    return boolPref(keyTestLandscape, defaultValue: true)
}

private final class TestOrientRowTarget: NSObject {
    let landscape: Bool
    weak var picker: TestOrientPickerController?

    init(landscape: Bool, picker: TestOrientPickerController?) {
        self.landscape = landscape
        self.picker = picker
    }

    @objc func selectOrient() {
        setPref(landscape, forKey: keyTestLandscape)
        NSLog("[DashSplitPref] set TestLandscape = %d", landscape ? 1 : 0)
        if let nav = picker?.navigationController, nav.viewControllers.count >= 2,
           let parent = nav.viewControllers[nav.viewControllers.count - 2] as? DashSplitPrefListController {
            parent.refreshPane()
        }
        picker?.navigationController?.popViewController(animated: true)
    }
}

class TestOrientPickerController: PSListController {
    private var rowTargets: [TestOrientRowTarget] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "预览方向"
    }

    override var specifiers: NSMutableArray? {
        get {
            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }

            let current = currentTestLandscape()
            rowTargets = []

            var specifiers = NSMutableArray()
            specifiers.add(PSSpecifier.emptyGroup())

            let options: [(Bool, String)] = [
                (true, "横屏预览"),
                (false, "竖屏预览")
            ]
            for (land, name) in options {
                let title = land == current ? "✓ \(name)" : name
                let target = TestOrientRowTarget(landscape: land, picker: self)
                rowTargets.append(target)
                let row = PSSpecifier.preferenceSpecifierNamed(
                    title,
                    target: target,
                    set: nil,
                    get: nil,
                    detail: nil,
                    cell: .buttonCell,
                    edit: nil
                )
                row?.buttonAction = #selector(TestOrientRowTarget.selectOrient)
                if let row = row { specifiers.add(row) }
            }

            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        set { super.specifiers = newValue }
    }
}

@objc(DashSplitTestOrientPicker)
final class DashSplitTestOrientPicker: TestOrientPickerController {}

// MARK: - Respring

private final class RespringTarget: NSObject {
    weak var controller: PSListController?

    init(controller: PSListController?) {
        self.controller = controller
    }

    @objc func respringTapped() {
        guard let vc = controller else { return }
        let alert = UIAlertController(
            title: "应用设置",
            message: "确定要重启 SpringBoard 吗?\n重启后所有更改将立即生效。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "重启", style: .destructive, handler: { _ in
            NSLog("[DashSplitPref] respring triggered by user")
            var argv: [UnsafeMutablePointer<CChar>?] = [
                strdup("killall"),
                strdup("-9"),
                strdup("SpringBoard"),
                nil
            ]
            defer { argv.forEach { free($0) } }
            var pid: pid_t = 0
            let paths = ["/var/jb/usr/bin/killall", "/usr/bin/killall"]
            for path in paths {
                if posix_spawn(&pid, path, nil, nil, argv, nil) == 0 {
                    NSLog("[DashSplitPref] respring spawned pid %d via %s", pid, path)
                    break
                }
            }
        }))
        vc.present(alert, animated: true)
    }
}

// MARK: - Main settings controller

@objc(DashSplitPrefListController)
final class DashSplitPrefListController: PSListController {
    private var respringTarget: RespringTarget?

    override func viewDidLoad() {
        super.viewDidLoad()
        Metadata.package = "zp.dashsplit"
        Metadata.tweakName = "车载分屏"
        Metadata.developer = "zpzpzp"
        title = "车载分屏"
    }

    private func linkRow(_ title: String, detail: AnyClass) -> PSSpecifier? {
        let row = PSSpecifier.preferenceSpecifierNamed(
            title,
            target: self,
            set: nil,
            get: nil,
            detail: detail,
            cell: .linkCell,
            edit: nil
        )
        return row
    }

    override var specifiers: NSMutableArray? {
        get {
            Metadata.package = "zp.dashsplit"
            Metadata.tweakName = "车载分屏"
            Metadata.developer = "zpzpzp"

            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }

            var specifiers = NSMutableArray()

            // 通用
            SpecifierFactory.add([
                GroupCell(
                    name: "通用",
                    footerText: "启用后,连接CarPlay并锁屏时\n自动显示胶囊排,点击胶囊打开App。"
                ),
                ToggleCell(name: "启用分屏", key: keyEnabled, defaultValue: true)
            ], to: &specifiers, in: self)

            // 应用选择
            let apps = installedApps()
            let selected = selectedAppIDs()
            let selectedCount = selected.count
            SpecifierFactory.add([
                GroupCell(
                    name: "应用选择",
                    footerText: "点击选择要投屏的App,可多选。\n已选\(selectedCount)个App。\n再次点击可取消选择。"
                )
            ], to: &specifiers, in: self)
            if let appRow = linkRow("选择应用 (\(selectedCount)个)", detail: DashSplitMultiAppPicker.self) {
                specifiers.add(appRow)
            }

            // Dynamic per-app sliders for selected apps
            if !selected.isEmpty {
                SpecifierFactory.add([
                    GroupCell(
                        name: "应用占比与缩放",
                        footerText: "每个App独立设置。\n占比:1-5,控制窗口固定宽度(1=1/5屏宽,5=满屏宽)。\n缩放:10-100,等比缩小窗口。\n多App会叠放,可拖拽调整位置。"
                    )
                ], to: &specifiers, in: self)

                for bid in selected {
                    let name = appName(for: bid, apps: apps)
                    // Each app gets its own group header for clarity.
                    SpecifierFactory.add([
                        GroupCell(name: name, footerText: "")
                    ], to: &specifiers, in: self)
                    // Ratio slider
                    SpecifierFactory.add([
                        SliderCell(name: "占比", key: ratioKey(bid), defaultValue: 1, range: 1..<6)
                    ], to: &specifiers, in: self)
                    // Scale slider
                    SpecifierFactory.add([
                        SliderCell(name: "缩放", key: scaleKey(bid), defaultValue: 100, range: 10..<101)
                    ], to: &specifiers, in: self)
                }
            }

            // 显示与测试
            SpecifierFactory.add([
                GroupCell(
                    name: "显示与测试",
                    footerText: "等比缩放:保持宽高比,两侧可能留白。\n拉伸填满:强行拉伸,文字会变形。\n测试模式不连CarPlay直接预览。"
                )
            ], to: &specifiers, in: self)
            if let fitRow = linkRow("显示模式:\(fitModeName())", detail: DashSplitFitModePicker.self) {
                specifiers.add(fitRow)
            }
            let testOrient = currentTestLandscape() ? "横屏预览" : "竖屏预览"
            if let orientRow = linkRow("预览方向:\(testOrient)", detail: DashSplitTestOrientPicker.self) {
                specifiers.add(orientRow)
            }
            SpecifierFactory.add([
                ToggleCell(name: "手机测试模式", key: "TestOnMainScreen", defaultValue: false)
            ], to: &specifiers, in: self)

            // Respring button
            respringTarget = RespringTarget(controller: self)
            if let btn = PSSpecifier.preferenceSpecifierNamed(
                "应用设置",
                target: respringTarget!,
                set: nil,
                get: nil,
                detail: nil,
                cell: .buttonCell,
                edit: nil
            ) {
                btn.buttonAction = #selector(RespringTarget.respringTapped)
                specifiers.add(btn)
            }

            // About
            SpecifierFactory.add([
                GroupCell(
                    name: "关于",
                    footerText: "DashSplit \(tweakVersion)"
                )
            ], to: &specifiers, in: self)
            if let versionRow = PSSpecifier.preferenceSpecifierNamed(
                "版本:\(tweakVersion)",
                target: self,
                set: nil,
                get: nil,
                detail: nil,
                cell: .linkCell,
                edit: nil
            ) {
                specifiers.add(versionRow)
            }

            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        set { super.specifiers = newValue }
    }

    @objc func refreshPane() {
        setValue(nil, forKey: "_specifiers")
        perform(NSSelectorFromString("reloadSpecifiers"))
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshPane()
    }
}
