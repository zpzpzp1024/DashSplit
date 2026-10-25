// DashSplit preferences pane — the 车载分屏 page in Settings.
//
// 0.1.5: every row is built in code, Reverie-style (its pane is proven on
// this device). The previous version loaded rows from specs.plist via
// loadSpecifiersFromPlistName:, which resolved nothing inside the
// PreferenceLoader-hosted controller and rendered a blank page.
//
// Selections are written straight to the plist file the tweak reads (it
// parses the file directly, so CFPreferences/cfprefsd is bypassed).
// Changes take effect the next time CarPlay connects.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <objc/message.h>

static NSString *const kPrefsFile    = @"/var/mobile/Library/Preferences/lilliana.dashsplit.plist";
static NSString *const kKeyLeft      = @"HostBundleID";
static NSString *const kKeyRight     = @"HostBundleID2";
static NSString *const kKeyEnabled   = @"Enabled";
static NSString *const kDefaultLeft  = @"com.xiaojukeji.didi";
static NSString *const kDefaultRight = @"com.autonavi.amap";

static NSMutableDictionary *LoadPrefs(void)
{
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:kPrefsFile];
    return prefs ? [prefs mutableCopy] : [NSMutableDictionary dictionary];
}

static NSString *StringValue(NSDictionary *prefs, NSString *key, NSString *fallback)
{
    NSString *value = prefs[key];
    return [value isKindOfClass:[NSString class]] && value.length ? value : fallback;
}

// Every installed app the user could reasonably pick: user apps plus system
// apps (时钟/计算器/…), internals filtered out. LSApplicationWorkspace lives
// in the private MobileCoreServices framework, loaded on demand.
static NSArray *InstalledApps(void)
{
    NSBundle *framework = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MobileCoreServices.framework"];
    if (framework && !framework.loaded) [framework load];

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = nil;
    if (workspaceClass) {
        SEL workspaceSel = NSSelectorFromString(@"defaultWorkspace");
        if ([workspaceClass respondsToSelector:workspaceSel]) {
            workspace = ((id (*)(id, SEL))objc_msgSend)((id)workspaceClass, workspaceSel);
        }
    }

    NSArray *proxies = nil;
    if (workspace) {
        SEL allSel = NSSelectorFromString(@"allInstalledApplications");
        if ([workspace respondsToSelector:allSel]) {
            proxies = ((id (*)(id, SEL))objc_msgSend)(workspace, allSel);
        }
    }
    if (![proxies isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *apps = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (id proxy in proxies) {
        NSString *name = nil;
        NSString *bundleID = nil;
        @try { name = [proxy valueForKey:@"localizedName"]; } @catch (__unused NSException *ignored) { }
        @try { bundleID = [proxy valueForKey:@"bundleIdentifier"]; } @catch (__unused NSException *ignored) { }
        if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;
        if (![bundleID isKindOfClass:[NSString class]] || bundleID.length == 0) continue;
        if ([seen containsObject:bundleID]) continue;
        [seen addObject:bundleID];

        // applicationType: NSString ("System"/"User"/…) on old iOS,
        // NSNumber enum (0=User, 1=System, 2=Internal…) on new.
        id type = nil;
        @try { type = [proxy valueForKey:@"applicationType"]; } @catch (__unused NSException *ignored) { }
        if ([type isKindOfClass:[NSString class]]) {
            if (![type isEqualToString:@"System"] && ![type isEqualToString:@"User"]) continue;
        } else if ([type isKindOfClass:[NSNumber class]]) {
            NSInteger raw = [(NSNumber *)type integerValue];
            if (raw != 0 && raw != 1) continue;
        }

        [apps addObject:@{ @"name": name, @"id": bundleID }];
    }

    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"] options:NSNumericSearch];
    }];
    return apps;
}

// The public SDK types the cell: argument of the PSSpecifier constructor as
// an undocumented PSCellType enum, so build specifiers through objc_msgSend.
static PSSpecifier *MakeSpecifier(NSString *name, id target, SEL set, SEL get, Class detail, Class cell)
{
    SEL ctor = NSSelectorFromString(@"preferenceSpecifierNamed:target:action:set:get:detail:cell:edit:");
    if (![PSSpecifier respondsToSelector:ctor]) return nil;
    return ((PSSpecifier *(*)(id, SEL, id, id, SEL, SEL, SEL, Class, Class, Class))objc_msgSend)
        ([PSSpecifier class], ctor, name ?: @"", target, NULL, set, get, detail, cell, nil);
}

static PSSpecifier *MakeGroup(NSString *title, NSString *footer)
{
    PSSpecifier *group = MakeSpecifier(title ?: @"", nil, NULL, NULL, nil, NSClassFromString(@"PSGroupCell"));
    if (group && footer.length > 0) {
        [group setProperty:footer forKey:@"footerText"];
    }
    return group;
}

@interface DashSplitPrefListController : PSListController
@end

@implementation DashSplitPrefListController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"车载分屏";
}

- (PSSpecifier *)appPickerNamed:(NSString *)title key:(NSString *)key defaultID:(NSString *)defaultID
{
    NSArray *apps = InstalledApps();
    NSString *defaultName = defaultID;
    for (NSDictionary *app in apps) {
        if ([app[@"id"] isEqualToString:defaultID]) {
            defaultName = app[@"name"];
            break;
        }
    }

    NSMutableArray *names = [NSMutableArray arrayWithObject:defaultName];
    NSMutableArray *ids = [NSMutableArray arrayWithObject:defaultID];
    for (NSDictionary *app in apps) {
        [names addObject:app[@"name"]];
        [ids addObject:app[@"id"]];
    }

    PSSpecifier *picker = MakeSpecifier(title, self,
                                        @selector(setAppValue:forSpecifier:),
                                        @selector(getAppValue:),
                                        [PSListItemsController class],
                                        NSClassFromString(@"PSLinkListCell"));
    [picker setProperty:names forKey:@"titles"];
    [picker setProperty:ids forKey:@"values"];
    [picker setProperty:key forKey:@"prefsKey"];
    [picker setProperty:defaultID forKey:@"prefsDefault"];
    return picker;
}

- (NSArray *)specifiers
{
    if (_specifiers == nil) {
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *general = MakeGroup(@"通用",
            @"启用后,连接 CarPlay 时会在车机屏幕上左右分屏显示下面选择的两个 App。");
        if (general) [specs addObject:general];

        PSSpecifier *toggle = MakeSpecifier(@"启用分屏", self,
                                            @selector(setEnabledValue:forSpecifier:),
                                            @selector(getEnabledValue:),
                                            nil,
                                            NSClassFromString(@"PSSwitchCell"));
        if (toggle) [specs addObject:toggle];

        PSSpecifier *panes = MakeGroup(@"分屏应用",
            @"更改后重新连接 CarPlay 生效;两个半屏选择同一个 App 时,只会投屏左半屏。");
        if (panes) [specs addObject:panes];

        PSSpecifier *left = [self appPickerNamed:@"左半屏应用" key:kKeyLeft defaultID:kDefaultLeft];
        if (left) [specs addObject:left];

        PSSpecifier *right = [self appPickerNamed:@"右半屏应用" key:kKeyRight defaultID:kDefaultRight];
        if (right) [specs addObject:right];

        _specifiers = specs;
    }
    return _specifiers;
}

- (void)setAppValue:(id)value forSpecifier:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:@"prefsKey"];
    if (![value isKindOfClass:[NSString class]] || !key) return;
    NSMutableDictionary *prefs = LoadPrefs();
    prefs[key] = value;
    [prefs writeToFile:kPrefsFile atomically:YES];
    NSLog(@"[DashSplitPref] set %@ = %@", key, value);
    [self reloadSpecifier:specifier];
}

- (id)getAppValue:(PSSpecifier *)specifier
{
    return StringValue(LoadPrefs(),
                       [specifier propertyForKey:@"prefsKey"],
                       [specifier propertyForKey:@"prefsDefault"]);
}

- (void)setEnabledValue:(id)value forSpecifier:(PSSpecifier *)specifier
{
    NSMutableDictionary *prefs = LoadPrefs();
    prefs[kKeyEnabled] = @([value boolValue]);
    [prefs writeToFile:kPrefsFile atomically:YES];
    [self reloadSpecifier:specifier];
}

- (id)getEnabledValue:(PSSpecifier *)specifier
{
    id value = LoadPrefs()[kKeyEnabled];
    return @([value isKindOfClass:[NSNumber class]] ? [(NSNumber *)value boolValue] : YES);
}

@end
