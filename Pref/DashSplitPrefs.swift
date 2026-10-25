// DashSplit preferences pane — the 车载分屏 page in Settings.
//
// 0.1.8: the app pickers are our own controller pages (one PSButtonCell row
// per app) instead of PSListItemsController detail rows, which crashed
// Settings on open on the target device. Everything here uses the row types
// Reverie's proven pane uses (GroupCell/ToggleCell/ButtonCell machinery via
// JinxPrefs). Selecting an app writes the bundle ID straight into the plist
// file the tweak reads; changes apply the next CarPlay connect.

import Preferences
import UIKit

private let prefsFile = "/var/mobile/Library/Preferences/lilliana.dashsplit.plist"
private let keyEnabled = "Enabled"
private let keyLeft = "HostBundleID"
private let keyRight = "HostBundleID2"
private let defaultLeft = "com.xiaojukeji.didi"
private let defaultRight = "com.autonavi.amap"

private let prefsDomain = "lilliana.dashsplit" as CFString

private func loadPrefs() -> [String: Any] {
    (NSDictionary(contentsOfFile: prefsFile) as? [String: Any]) ?? [:]
}

// Write through cfprefsd so Settings' own preference writes and ours can
// never clobber each other; Synchronize forces the plist file to update.
private func setPref(_ value: Any, forKey key: String) {
    CFPreferencesSetValue(key as CFString, value as CFTypeRef, prefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSynchronize(prefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
}

private func stringValue(_ prefs: [String: Any], _ key: String, _ fallback: String) -> String {
    if let value = prefs[key] as? String, !value.isEmpty { return value }
    return fallback
}

private func appName(for bundleID: String, apps: [[String: String]]) -> String {
    apps.first(where: { $0["id"] == bundleID })?["name"] ?? bundleID
}

// Every installed app the user could reasonably pick: user apps plus system
// apps (时钟/计算器/…), internals filtered out. LSApplicationWorkspace lives
// in the private MobileCoreServices framework, loaded on demand.
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

        // applicationType: NSString ("System"/"User"/…) on old iOS,
        // NSNumber enum (0=User, 1=System, 2=Internal…) on new.
        let rawType = proxy.value(forKey: "applicationType")
        if let type = rawType as? String {
            if type != "System" && type != "User" { continue }
        } else if let type = rawType as? NSNumber {
            let raw = type.intValue
            if raw != 0 && raw != 1 { continue }
        }

        seen.insert(bundleID)
        apps.append(["name": name, "id": bundleID])
    }
    apps.sort { ($0["name"] ?? "") < ($1["name"] ?? "") }
    return apps
}

// Per-row tap target for the picker list. PSButtonCell invokes the action
// on the specifier's target; a dedicated object per row carries the bundle
// ID without touching selector arity (Reverie's 0-arg button pattern).
private final class AppRowTarget: NSObject {
    let bundleID: String
    let paneKey: String
    weak var picker: AppPickerController?

    init(bundleID: String, paneKey: String, picker: AppPickerController?) {
        self.bundleID = bundleID
        self.paneKey = paneKey
        self.picker = picker
    }

    @objc func selectApp() {
        setPref(bundleID, forKey: paneKey)
        NSLog("[DashSplitPref] set %@ = %@", paneKey, bundleID)
        picker?.navigationController?.popViewController(animated: true)
    }
}

class AppPickerController: PSListController {
    var paneKey: String { "" }
    var paneTitle: String { "" }
    var fallbackID: String { "" }

    private var rowTargets: [AppRowTarget] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = paneTitle
    }

    override var specifiers: NSMutableArray? {
        get {
            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }

            let apps = installedApps()
            let current = stringValue(loadPrefs(), paneKey, fallbackID)
            rowTargets = []

            var specifiers = NSMutableArray()
            // Current selection first, then everything else.
            specifiers.add(PSSpecifier.emptyGroup())
            if let currentRow = buttonRow(name: "当前:" + appName(for: current, apps: apps), bundleID: current) {
                specifiers.add(currentRow)
            }
            for app in apps where app["id"] != current {
                if let row = buttonRow(name: app["name"] ?? "", bundleID: app["id"] ?? "") {
                    specifiers.add(row)
                }
            }

            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        set { super.specifiers = newValue }
    }

    private func buttonRow(name: String, bundleID: String) -> PSSpecifier? {
        let target = AppRowTarget(bundleID: bundleID, paneKey: paneKey, picker: self)
        rowTargets.append(target)

        let row = PSSpecifier.preferenceSpecifierNamed(
            name,
            target: target,
            set: nil,
            get: nil,
            detail: nil,
            cell: .buttonCell,
            edit: nil
        )
        row?.buttonAction = #selector(AppRowTarget.selectApp)
        return row
    }
}

@objc(DashSplitLeftAppPicker)
final class DashSplitLeftAppPicker: AppPickerController {
    override var paneKey: String { keyLeft }
    override var paneTitle: String { "左半屏应用" }
    override var fallbackID: String { defaultLeft }
}

@objc(DashSplitRightAppPicker)
final class DashSplitRightAppPicker: AppPickerController {
    override var paneKey: String { keyRight }
    override var paneTitle: String { "右半屏应用" }
    override var fallbackID: String { defaultRight }
}

@objc(DashSplitPrefListController)
final class DashSplitPrefListController: PSListController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Metadata.package = "lilliana.dashsplit"
        Metadata.tweakName = "车载分屏"
        Metadata.developer = "zpzpzp"
        title = "车载分屏"
    }

    // A link row per pane that shows the current pick in its title.
    private func paneRow(_ title: String, current: String, detail: AnyClass) -> PSSpecifier? {
        let apps = installedApps()
        let row = PSSpecifier.preferenceSpecifierNamed(
            "\(title):\(appName(for: current, apps: apps))",
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
            // Cells bake Metadata.package into their "defaults" domain —
            // set it before any cell is built, not only in viewDidLoad
            // (specifiers can be requested before viewDidLoad runs; an
            // empty package here made the toggle write to a broken domain).
            Metadata.package = "lilliana.dashsplit"
            Metadata.tweakName = "车载分屏"
            Metadata.developer = "zpzpzp"

            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }

            let prefs = loadPrefs()
            var specifiers = NSMutableArray()
            SpecifierFactory.add([
                GroupCell(
                    name: "通用",
                    footerText: "启用后,连接 CarPlay 时会在车机屏幕上左右分屏显示下面选择的两个 App。"
                ),
                ToggleCell(name: "启用分屏", key: keyEnabled, defaultValue: true)
            ], to: &specifiers, in: self)

            SpecifierFactory.add([
                GroupCell(
                    name: "分屏应用",
                    footerText: "点进去选择 App;更改后重新连接 CarPlay 生效;两个半屏选同一个 App 时只投左半屏。"
                )
            ], to: &specifiers, in: self)
            if let left = paneRow("左半屏应用", current: stringValue(prefs, keyLeft, defaultLeft), detail: DashSplitLeftAppPicker.self) {
                specifiers.add(left)
            }
            if let right = paneRow("右半屏应用", current: stringValue(prefs, keyRight, defaultRight), detail: DashSplitRightAppPicker.self) {
                specifiers.add(right)
            }

            SpecifierFactory.add([
                GroupCell(
                    name: "测试",
                    footerText: "不连 CarPlay,直接在手机屏幕上分屏预览:上 60% 为左屏应用,下 40% 为右屏应用。开启后几秒内出现,关闭后几秒内消失。"
                ),
                ToggleCell(name: "手机测试模式", key: "TestOnMainScreen", defaultValue: false)
            ], to: &specifiers, in: self)

            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        set { super.specifiers = newValue }
    }

    // Refresh the pane rows (they show the current pick in their titles)
    // when coming back from a picker page.
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setValue(nil, forKey: "_specifiers")
        perform(NSSelectorFromString("reloadSpecifiers"))
    }
}
