// DashSplit preferences pane — the 车载分屏 page in Settings.
//
// 0.1.7: rebuilt in Swift on JinxPrefs, mirroring Reverie's pane structure
// exactly (its pane is proven on the target device). The ObjC version built
// its rows through objc_msgSend with a cell CLASS where the constructor takes
// a PSCellType enum value — rows never materialised and the page rendered
// blank. JinxPrefs compiles against the same headers Reverie uses, so the
// enum values are correct by construction here.
//
// The two app pickers use PSListItemsController with dynamic titles/values
// from LSApplicationWorkspace; picking writes the bundle ID straight into
// the plist file the tweak reads. Changes apply the next CarPlay connect.

import Preferences
import UIKit

private let prefsFile = "/var/mobile/Library/Preferences/lilliana.dashsplit.plist"
private let keyEnabled = "Enabled"
private let keyLeft = "HostBundleID"
private let keyRight = "HostBundleID2"
private let defaultLeft = "com.xiaojukeji.didi"
private let defaultRight = "com.autonavi.amap"

private func loadPrefs() -> [String: Any] {
    (NSDictionary(contentsOfFile: prefsFile) as? [String: Any]) ?? [:]
}

private func savePrefs(_ prefs: [String: Any]) {
    NSDictionary(dictionary: prefs).write(toFile: prefsFile, atomically: true)
}

private func stringValue(_ prefs: [String: Any], _ key: String, _ fallback: String) -> String {
    if let value = prefs[key] as? String, !value.isEmpty { return value }
    return fallback
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

@objc(DashSplitPrefListController)
final class DashSplitPrefListController: PSListController {
    override func viewDidLoad() {
        super.viewDidLoad()
        Metadata.package = "lilliana.dashsplit"
        Metadata.tweakName = "车载分屏"
        Metadata.developer = "zpzpzp"
        title = "车载分屏"
    }

    private func appPicker(_ title: String, key: String, defaultID: String) -> PSSpecifier {
        let apps = installedApps()
        let defaultName = apps.first(where: { $0["id"] == defaultID })?["name"] ?? defaultID

        var names = [defaultName]
        var ids = [defaultID]
        for app in apps {
            names.append(app["name"] ?? "")
            ids.append(app["id"] ?? "")
        }

        let picker = PSSpecifier.preferenceSpecifierNamed(
            title,
            target: self,
            set: #selector(setAppValue(_:forSpecifier:)),
            get: #selector(getAppValue(_:)),
            detail: PSListItemsController.self,
            cell: .linkListCell,
            edit: nil
        )
        picker.identifier = key
        picker.setProperty(names, forKey: "titles")
        picker.setProperty(ids, forKey: "values")
        picker.setProperty(key, forKey: "prefsKey")
        picker.setProperty(defaultID, forKey: "prefsDefault")
        return picker
    }

    override var specifiers: NSMutableArray? {
        get {
            if let specifiers = value(forKey: "_specifiers") as? NSMutableArray {
                return specifiers
            }

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
                    footerText: "更改后重新连接 CarPlay 生效;两个半屏选择同一个 App 时,只会投屏左半屏。"
                )
            ], to: &specifiers, in: self)
            specifiers.add(appPicker("左半屏应用", key: keyLeft, defaultID: defaultLeft))
            specifiers.add(appPicker("右半屏应用", key: keyRight, defaultID: defaultRight))

            setValue(specifiers, forKey: "_specifiers")
            return specifiers
        }
        set { super.specifiers = newValue }
    }

    @objc func setAppValue(_ value: Any, forSpecifier specifier: PSSpecifier) {
        guard let key = specifier.property(forKey: "prefsKey") as? String,
              let bundleID = value as? String
        else { return }
        var prefs = loadPrefs()
        prefs[key] = bundleID
        savePrefs(prefs)
        NSLog("[DashSplitPref] set %@ = %@", key, bundleID)
        reloadSpecifier(specifier)
    }

    @objc func getAppValue(_ specifier: PSSpecifier) -> Any {
        let key = (specifier.property(forKey: "prefsKey") as? String) ?? keyLeft
        let fallback = (specifier.property(forKey: "prefsDefault") as? String) ?? defaultLeft
        return stringValue(loadPrefs(), key, fallback)
    }
}
