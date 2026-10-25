// DashSplit preferences bundle — the "车载分屏" pane in the Settings app.
//
// Two app pickers (left/right pane) plus a master toggle. The pickers list
// every installed app, system apps included, by localized name. Selections
// are written straight to the plist file the tweak reads (the tweak parses
// the file directly, so we bypass CFPreferences to avoid cfprefsd caching).
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
    NSMutableArray *names = [NSMutableArray arrayWithObject:defaultID];
    NSMutableArray *ids = [NSMutableArray arrayWithObject:defaultID];
    for (NSDictionary *app in apps) {
        [names addObject:app[@"name"]];
        [ids addObject:app[@"id"]];
    }
    // Show the default by its own name when it is among the installed apps.
    for (NSDictionary *app in apps) {
        if ([app[@"id"] isEqualToString:defaultID]) {
            names[0] = app[@"name"];
            break;
        }
    }

    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:title
                                                            target:self
                                                               set:@selector(setAppValue:forSpecifier:)
                                                               get:@selector(getAppValue:)
                                                            detail:[PSListItemsController class]
                                                              cell:NSClassFromString(@"PSLinkListCell")
                                                              edit:NULL];
    [specifier setProperty:names forKey:@"titles"];
    [specifier setProperty:ids forKey:@"values"];
    [specifier setProperty:key forKey:@"prefsKey"];
    [specifier setProperty:defaultID forKey:@"prefsDefault"];
    return specifier;
}

- (NSArray *)specifiers
{
    if (_specifiers == nil) {
        NSMutableArray *specs = [NSMutableArray array];

        PSSpecifier *toggle = [PSSpecifier preferenceSpecifierNamed:@"启用分屏"
                                                              target:self
                                                                 set:@selector(setEnabledValue:forSpecifier:)
                                                                 get:@selector(getEnabledValue:)
                                                              detail:nil
                                                                cell:NSClassFromString(@"PSSwitchCell")
                                                                edit:NULL];
        [specs addObject:toggle];

        [specs addObject:[self appPickerNamed:@"左半屏应用" key:kKeyLeft defaultID:kDefaultLeft]];
        [specs addObject:[self appPickerNamed:@"右半屏应用" key:kKeyRight defaultID:kDefaultRight]];

        PSSpecifier *note = [PSSpecifier preferenceSpecifierNamed:@"更改后重新连接 CarPlay 生效；左右选同一应用时只投左屏"
                                                            target:self
                                                               set:NULL
                                                               get:NULL
                                                            detail:nil
                                                              cell:NSClassFromString(@"PSTitleValueCell")
                                                              edit:NULL];
        [specs addObject:note];

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
