// DashSplit - CarPlay split view experiments
//
// 0.1.28: never-Live-while-unlocked. The 0.1.27 field log shows every
// respring came from ENTERING Live at an unsafe moment — a start 8s after
// unlock (dead in 2s: the system pushes foreground=No straight into the
// freshly-Live controllers while the phone is in use) and two restores
// while locked (dead after 12s/58s). The unlock auto-hide itself never
// caused a crash. So every path into Live now checks the phone's lock
// state (kept current via the lockstate Darwin note, seeded by an
// initial-state query): a ▶/⟳ tap while unlocked is remembered
// (gPendingShow) and executed on the next lock event. Unlock still
// auto-hides; lock alone never shows anything.
//
// 0.1.27: auto-hide on phone unlock (fixes the stable-connection crash).
// While hosting is Live, unlocking the phone and opening any app delivers
// foreground=No to the hosted scenes' controllers -> the uncatchable
// foreground-consistency assertion -> SpringBoard respring -> the car panes
// vanish. User-verified on-device: with the panes hidden (mode 0) phone-side
// app launches NEVER respring. So: subscribe to the system lock-state Darwin
// note (com.apple.springboard.lockstate — an event subscription, NOT a
// method hook) and on unlock run the exact same stand-down as the toggle
// button's hide branch. Lock events do nothing (no auto-show); restoring is
// always a manual tap. A pending deferred start is cancelled on unlock too.
//
// 0.1.23: manual start on CarPlay connect. The 0.1.21 connect log shows the
// "show -> disappear -> reappear" loop is SpringBoard crashing: CarPlay
// setup delivers a foreground=No scene-settings wave ~10s after connect
// that hits our freshly-Live controllers (uncatchable assertion -> resync
// to 0 = panes vanish -> respring = panes rebuild). Fix without any new
// hooks: on connect show ONLY the toggle button; hosting (and thus Live
// mode) begins on the user's tap, and a tap inside the 30s connect settle
// window defers hosting until the window passes. The wave finds no Live
// controller to kill, so nothing crashes. Phone test mode keeps the old
// auto-host behavior (the wave is CarPlay-specific).
//
// 0.1.9: phone test mode hosts BOTH panes on the phone screen (top 60% =
// left app, bottom 40% = right app, same ratio as the car split) and gets a
// 手机测试模式 toggle in the Settings pane (TestOnMainScreen).
//
// 0.1.7: the pane is Swift + JinxPrefs (a carbon copy of Reverie's pane
// build). The 0.1.5/0.1.6 ObjC rows never rendered: they passed a cell
// CLASS to a constructor whose cell: parameter is a PSCellType enum —
// JinxPrefs compiles the correct enum values by construction.
// 0.1.5: the pane builds every row in code, Reverie-style — the plist-based
// row loading rendered a blank page (resource lookup failed inside the
// PreferenceLoader-hosted controller).
// 0.1.4: entry plist mirrors Reverie's proven format (fields wrapped in an
// "entry" dict, ldid -S re-signed bundle) — the bare top-level format was
// silently ignored by the installed PreferenceLoader; the 0.1.3 injector
// experiment is reverted.
// 0.1.2: swallow the scene-foreground assertion at +[NSException raise:format:]
// (the raise variant that slipped past the other hooks); the
// objc_exception_throw hook is log-only now — swallowing there segfaults the
// noreturn caller (0.1.1 log: signal 11 after a throw-level swallow).
// 0.1.1: Settings pane (车载分屏) to pick the left/right pane apps;
// objc_exception_throw hooked via MSHookFunction (the raise-only hooks let
// one assertion through and resprung SpringBoard); same-app-on-both-panes
// guard (hosts left pane only).
// 0.1.0: standalone repo, renamed from Cockpit.
// 0.1.0: button looks identically semi-transparent in every state (custom
// type, no press dimming); re-fit the pane scale transform on restore and
// health nudges (the background->foreground cycle resets it, which made
// restored panes show a 1:1 crop instead of the fitted app UI).
// 0.0.23: scene-state liveness (isRunning is dead weight on this device),
// auto-recovery via nudge-then-rehost health check, toggle button at the
// whole-screen top-left with 40% opaque background.
// 0.0.22: restore Mode 2 hosting (only mechanism that pulls the app process
// up), contain the foreground-consistency crash (mode 0 before hide/teardown,
// NSException assertion filter), fix the toggle button (it lives inside the
// main window now — a second UIWindow on the car display never received taps).
//
// The hosting pattern follows carplay-cast (Apache-2.0):
//   AVExternalDevice.currentCarPlayExternalDevice
//     -> CADisplay -> FBSDisplayConfiguration -> UIRootSceneWindow
//   SBApplicationSceneHandleRequest -> SBApplicationSceneEntity
//     -> SBAppViewController -> view
//
// Everything runs after SpringBoard is up, is wrapped in @try/@catch, and can be
// disabled by creating /var/mobile/Library/Preferences/zp.dashsplit.off.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <stdarg.h>
#import <stdio.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <dlfcn.h>

#if __has_include(<execinfo.h>)
#import <execinfo.h>
#define COCKPIT_HAVE_BACKTRACE 1
#else
#define COCKPIT_HAVE_BACKTRACE 0
#endif

#define COCKPIT_LOG     "/var/mobile/Library/Logs/DashSplit.log"
#define COCKPIT_OFF     "/var/mobile/Library/Preferences/zp.dashsplit.off"
#define COCKPIT_PREFS   "/var/mobile/Library/Preferences/zp.dashsplit.plist"
#define COCKPIT_HOSTING "/var/mobile/Library/Preferences/zp.dashsplit.hosting"
#define COCKPIT_CRASHED "/var/mobile/Library/Preferences/zp.dashsplit.crashed"
#define COCKPIT_NEWSCENE "/var/mobile/Library/Preferences/zp.dashsplit.newscene"
#define COCKPIT_CRASHCOUNT "/var/mobile/Library/Preferences/zp.dashsplit.crashcount"

// Maximum number of panes (apps) supported simultaneously.
#define MAX_PANES 8

// 0.1.58: width of the per-pane external right toolbar (outside the pane).
#define TOOLBAR_WIDTH 38

static NSString *const kPrefsHostApps = @"SelectedApps";  // comma-separated bundle IDs
static NSString *const kPrefsLastSelectedApps = @"LastSelectedApps"; // layout-reset sentinel
static NSString *const kPrefsEnabled  = @"Enabled";
static NSString *const kPrefsTestMain = @"TestOnMainScreen";
static NSString *const kPrefsTestLandscape = @"TestLandscape";
static NSString *const kPrefsStretchFill = @"StretchFill";
// Fit mode: 0 = aspect-fit (default), 1 = stretch fill
static NSString *const kPrefsFitMode = @"FitMode";
// 0.1.58: manual-start gate — when ON, car mode shows only a start button on
// connect and hosting begins on the user's tap (instead of auto-starting).
static NSString *const kPrefsManualStart = @"ManualStart";

#pragma mark - Logging

static void CLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    
    NSLog(@"[DashSplit] %@", message);
    
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [formatter stringFromDate:[NSDate date]], message];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *path = @COCKPIT_LOG;
    
    if ([[manager attributesOfItemAtPath:path error:nil] fileSize] > 256 * 1024) {
        [manager removeItemAtPath:path error:nil];
    }
    if (![manager fileExistsAtPath:path]) {
        [manager createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        [manager createFileAtPath:path contents:nil attributes:nil];
    }
    
    FILE *file = fopen(COCKPIT_LOG, "a");
    if (file) {
        fputs(line.UTF8String, file);
        fclose(file);
    }
}

#pragma mark - Crash capture

static int gCrashCount = 0;

static void DashSplitWriteRaw(const char *text)
{
    int fd = open(COCKPIT_LOG, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        write(fd, text, strlen(text));
        close(fd);
    }
}

static void DashSplitSignalHandler(int signo)
{
    char header[96];
    snprintf(header, sizeof(header), "\n*** dashsplit: signal %d ***\n", signo);
    DashSplitWriteRaw(header);
    
    int crashFD = open(COCKPIT_CRASHED, O_WRONLY | O_CREAT, 0644);
    if (crashFD >= 0) {
        close(crashFD);
    }
    
#if COCKPIT_HAVE_BACKTRACE
    int fd = open(COCKPIT_LOG, O_WRONLY | O_APPEND);
    if (fd >= 0) {
        void *frames[64];
        int count = backtrace(frames, 64);
        backtrace_symbols_fd(frames, count, fd);
        close(fd);
    }
#endif
    
    signal(signo, SIG_DFL);
    raise(signo);
}

static void DashSplitExceptionHandler(NSException *exception)
{
    CLog(@"*** dashsplit: uncaught %@: %@", exception.name, exception.reason);
    for (NSString *line in exception.callStackSymbols) {
        CLog(@"dashsplit stack: %@", line);
    }
    [[NSFileManager defaultManager] createFileAtPath:@COCKPIT_CRASHED contents:[NSData data] attributes:nil];
    
    gCrashCount++;
    NSString *countStr = [NSString stringWithFormat:@"%d", gCrashCount];
    [countStr writeToFile:@COCKPIT_CRASHCOUNT atomically:YES encoding:NSUTF8StringEncoding error:nil];
    CLog(@"*** dashsplit: crash count now %d", gCrashCount);
}

static void InstallCrashHandlers(void)
{
    NSSetUncaughtExceptionHandler(&DashSplitExceptionHandler);
    signal(SIGABRT, DashSplitSignalHandler);
    signal(SIGSEGV, DashSplitSignalHandler);
    signal(SIGBUS, DashSplitSignalHandler);
    signal(SIGILL, DashSplitSignalHandler);
    signal(SIGFPE, DashSplitSignalHandler);
    signal(SIGTRAP, DashSplitSignalHandler);
}

#pragma mark - Preferences

// Read through cfprefsd, not the raw file: Settings writes go through
// CFPreferences, and a direct file read can miss (or race) those writes.
// Fall back to the file if cfprefsd has nothing for the key yet.
static id Pref(NSString *key)
{
    // AppSynchronize refreshes this process's cached copy of the domain so
    // writes made by the Settings pane show up here promptly.
    CFPreferencesAppSynchronize(CFSTR("zp.dashsplit"));
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("zp.dashsplit")));
    if (value) return value;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@COCKPIT_PREFS];
    return prefs[key];
}

static BOOL PrefBool(NSString *key, BOOL fallback)
{
    id value = Pref(key);
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static NSString *PrefString(NSString *key)
{
    id value = Pref(key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSInteger PrefInteger(NSString *key, NSInteger fallback)
{
    id value = Pref(key);
    return [value isKindOfClass:[NSNumber class]] ? [value integerValue] : fallback;
}

static double PrefDouble(NSString *key, double fallback)
{
    id value = Pref(key);
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

#define COCKPIT_TEST "/var/mobile/Library/Preferences/zp.dashsplit.test"
#define COCKPIT_HOST "/var/mobile/Library/Preferences/zp.dashsplit.host"

static BOOL FileExists(NSString *path)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

// The Settings toggle is the only switch (0.1.12); the old marker-file
// escape hatch is gone — a leftover file kept test mode ON while the
// toggle showed OFF. Leftovers are deleted at startup.
static BOOL TestModeEnabled(void)
{
    return PrefBool(kPrefsTestMain, NO);
}

// Fit mode: 0 = aspect-fit (uniform scale, centered, default),
//           1 = stretch fill (non-uniform scale, fills pane, deforms),
//           2 = native fill (hook UIScreen.bounds so App re-layouts at pane size).
// Legacy: StretchFill=true maps to 1, false maps to 0.
static int FitMode(void)
{
    // Check new key first.
    int mode = (int)PrefInteger(kPrefsFitMode, -1);
    if (mode >= 0 && mode <= 2) return mode;
    // Legacy fallback: StretchFill boolean.
    if (PrefBool(kPrefsStretchFill, NO)) return 1;
    return 0;
}

// Selected apps: comma-separated bundle IDs in the SelectedApps pref.
// Returns an array of bundle ID strings (up to MAX_PANES).
static NSArray<NSString *> *SelectedBundleIDs(void)
{
    NSString *raw = PrefString(kPrefsHostApps);
    if (!raw) {
        // 0.1.59: key ABSENT = first install, never configured → keep the
        // default 时钟+日历. An explicitly empty string (user deselected
        // every app) is honored as-is: no panes at all.
        raw = @"com.apple.mobiletimer,com.apple.mobilecal";
    }
    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *part in [raw componentsSeparatedByString:@","]) {
        NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length && ids.count < MAX_PANES) {
            [ids addObject:trimmed];
        }
    }
    return ids;
}

// Number of selected apps (capped at MAX_PANES).
static int PaneCount(void)
{
    return (int)SelectedBundleIDs().count;
}

// Bundle ID for a given pane index.
static NSString *HostBundleIDForIndex(int index)
{
    NSArray *ids = SelectedBundleIDs();
    if (index < 0 || index >= (int)ids.count) return @"";
    return ids[index];
}

// Per-app ratio: integer 1-5 from AppRatio_<bundleID> pref. Default 1.
static int AppRatioForIndex(int index)
{
    NSString *bid = HostBundleIDForIndex(index);
    if (!bid.length) return 1;
    NSString *key = [NSString stringWithFormat:@"AppRatio_%@", bid];
    int r = (int)PrefInteger(key, 1);
    if (r < 1) r = 1;
    if (r > 5) r = 5;
    return r;
}

// Per-app scale: integer 10-100 from AppScale_<bundleID> pref. Default 100.
static CGFloat AppScaleForIndex(int index)
{
    NSString *bid = HostBundleIDForIndex(index);
    if (!bid.length) return 1.0f;
    NSString *key = [NSString stringWithFormat:@"AppScale_%@", bid];
    int raw = (int)PrefInteger(key, 100);
    if (raw < 10) raw = 10;
    if (raw > 100) raw = 100;
    return (CGFloat)raw / 100.0f;
}

// Get app display name via LSApplicationProxy.
static NSString *AppDisplayName(NSString *bundleID)
{
    if (!bundleID.length) return @"App";
    Class cls = NSClassFromString(@"LSApplicationProxy");
    if (cls) {
        id proxy = [cls performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleID];
        if (proxy) {
            NSString *name = [proxy performSelector:@selector(localizedName)];
            if (name.length > 0) return name;
        }
    }
    // Fallback: last component of bundle ID
    NSRange dotRange = [bundleID rangeOfString:@"." options:NSBackwardsSearch];
    if (dotRange.location != NSNotFound) {
        return [bundleID substringFromIndex:dotRange.location + 1];
    }
    return bundleID;
}

static void LogPrefsState(void)
{
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *path = @COCKPIT_PREFS;
    NSDictionary *attributes = [manager attributesOfItemAtPath:path error:nil];
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:path];
    
    CLog(@"prefs: path=%@ exists=%d size=%llu parsed=%d keys=%lu",
         path,
         [manager fileExistsAtPath:path],
         [attributes fileSize],
         prefs != nil,
         (unsigned long)prefs.count);
    
    CLog(@"prefs: testMarker=%d hostFile=%d enabled=%d testMode=%d apps=%@",
         FileExists(@COCKPIT_TEST),
         FileExists(@COCKPIT_HOST),
         PrefBool(kPrefsEnabled, YES),
         TestModeEnabled(),
         SelectedBundleIDs());

    CLog(@"prefs: fitMode=%d manualStart=%d", FitMode(), PrefBool(kPrefsManualStart, NO));
}

#pragma mark - Runtime helpers

static id Call0(id object, NSString *selector)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, sel);
}

static id Call1(id object, NSString *selector, id argument)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(object, sel, argument);
}

static id Call2(id object, NSString *selector, id a, id b)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id, id))objc_msgSend)(object, sel, a, b);
}

static id CallClass0(Class cls, NSString *selector)
{
    SEL sel = NSSelectorFromString(selector);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)cls, sel);
}

static id CallClass2(Class cls, NSString *selector, id a, id b, id c)
{
    SEL sel = NSSelectorFromString(selector);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id, id, id))objc_msgSend)((id)cls, sel, a, b, c);
}

static BOOL BoolReturn(id object, NSString *selector, BOOL fallback)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return fallback;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, sel);
}

static void CallInteger(id object, NSString *selector, NSInteger value)
{
    SEL sel = NSSelectorFromString(selector);
    if (!object || ![object respondsToSelector:sel]) return;
    ((void (*)(id, SEL, NSInteger))objc_msgSend)(object, sel, value);
}

#pragma mark - CarPlay display

static void LogClassSelector(Class cls, NSString *selector, BOOL classMethod)
{
    SEL sel = NSSelectorFromString(selector);
    BOOL found = classMethod ? [cls respondsToSelector:sel] : [cls instancesRespondToSelector:sel];
    CLog(@"api: %@ %c%@ = %d", NSStringFromClass(cls), classMethod ? '+' : '-', selector, found);
}

static void LogSelectors(Class cls, NSArray<NSString *> *keywords)
{
    if (!cls) return;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    NSMutableArray<NSString *> *matches = [NSMutableArray array];
    for (unsigned int index = 0; index < count; index++) {
        NSString *name = NSStringFromSelector(method_getName(methods[index]));
        NSString *lowercase = name.lowercaseString;
        for (NSString *keyword in keywords) {
            if ([lowercase containsString:keyword]) {
                [matches addObject:name];
                break;
            }
        }
    }
    free(methods);
    [matches sortUsingSelector:@selector(compare:)];
    CLog(@"api: %@ methods (%lu): %@",
         NSStringFromClass(cls),
         (unsigned long)matches.count,
         [matches componentsJoinedByString:@" | "]);
}

static void LogHostingAPI(void)
{
    Class coordinator = NSClassFromString(@"SBSceneManagerCoordinator");
    Class manager = NSClassFromString(@"SBSceneManager");
    Class request = NSClassFromString(@"SBApplicationSceneHandleRequest");
    Class controller = NSClassFromString(@"SBAppViewController");
    Class entity = NSClassFromString(@"SBDeviceApplicationSceneEntity");
    Class appController = NSClassFromString(@"SBApplicationController");
    
    CLog(@"api: classes coordinator=%d manager=%d request=%d appVC=%d entity=%d appController=%d",
         coordinator != nil, manager != nil, request != nil,
         controller != nil, entity != nil, appController != nil);
    
    LogClassSelector(coordinator, @"mainDisplaySceneManager", YES);
    LogClassSelector(manager, @"displayIdentity", NO);
    LogClassSelector(manager, @"fetchOrCreateApplicationSceneHandleForRequest:", NO);
    LogClassSelector(request, @"defaultRequestForApplication:sceneIdentity:displayIdentity:", YES);
    LogClassSelector(controller, @"initWithIdentifier:andApplicationSceneEntity:", NO);
    LogClassSelector(controller, @"_createSceneViewController", NO);
    LogClassSelector(controller, @"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:", NO);
    LogClassSelector(controller, @"setIgnoresOcclusions:", NO);
    LogClassSelector(controller, @"_setCurrentMode:", NO);
    LogClassSelector(controller, @"_invalidate", NO);
    LogClassSelector(controller, @"_invalidateForReason:", NO);
    LogClassSelector(controller, @"invalidate", NO);
    LogClassSelector(controller, @"_tearDown", NO);
    LogClassSelector(entity, @"initWithApplicationSceneHandle:", NO);
    LogClassSelector(appController, @"sharedInstance", YES);
    LogClassSelector(appController, @"applicationWithBundleIdentifier:", NO);
    
    id sceneManager = CallClass0(coordinator, @"mainDisplaySceneManager");
    CLog(@"api: mainDisplaySceneManager=%@", sceneManager ? NSStringFromClass([sceneManager class]) : @"nil");
    if (sceneManager) {
        id displayIdentity = Call0(sceneManager, @"displayIdentity");
        CLog(@"api: displayIdentity=%@", displayIdentity ? NSStringFromClass([displayIdentity class]) : @"nil");
    }
    
    LogSelectors(manager, @[@"scene", @"identity"]);
    Class mainManager = NSClassFromString(@"SBMainDisplaySceneManager");
    if (mainManager && mainManager != manager) {
        LogSelectors(mainManager, @[@"scene", @"identity"]);
    }
    LogSelectors(controller, @[@"invalid", @"tear", @"dealloc", @"destroy", @"cleanup"]);
    LogSelectors(NSClassFromString(@"SBApplication"), @[@"scene", @"identity"]);
}

static id CarDisplay(void)
{
    Class deviceClass = NSClassFromString(@"AVExternalDevice");
    id device = CallClass0(deviceClass, @"currentCarPlayExternalDevice");
    if (!device) return nil;
    
    NSArray *screenIDs = Call0(device, @"screenIDs");
    NSString *uniqueID = [screenIDs isKindOfClass:[NSArray class]] && screenIDs.count ? screenIDs[0] : nil;
    if (![uniqueID isKindOfClass:[NSString class]]) return nil;
    
    Class displayClass = NSClassFromString(@"CADisplay");
    NSArray *displays = CallClass0(displayClass, @"displays");
    for (id display in displays) {
        NSString *candidate = Call0(display, @"uniqueId");
        if ([candidate isEqualToString:uniqueID]) return display;
    }
    return nil;
}

static UIWindow *MakeCarWindow(void)
{
    id display = CarDisplay();
    if (!display) {
        CLog(@"make window: no CarPlay CADisplay");
        return nil;
    }
    
    Class configClass = NSClassFromString(@"FBSDisplayConfiguration");
    SEL initSel = NSSelectorFromString(@"initWithCADisplay:isMainDisplay:");
    if (!configClass || ![configClass instancesRespondToSelector:initSel]) {
        CLog(@"make window: FBSDisplayConfiguration missing");
        return nil;
    }
    
    id config = ((id (*)(id, SEL, id, BOOL))objc_msgSend)([configClass alloc], initSel, display, NO);
    
    Class windowClass = NSClassFromString(@"UIRootSceneWindow");
    SEL windowSel = NSSelectorFromString(@"initWithDisplayConfiguration:");
    if (!windowClass || ![windowClass instancesRespondToSelector:windowSel]) {
        CLog(@"make window: UIRootSceneWindow missing");
        return nil;
    }
    
    id window = ((id (*)(id, SEL, id))objc_msgSend)([windowClass alloc], windowSel, config);
    if (![window isKindOfClass:[UIWindow class]]) {
        CLog(@"make window: unexpected class %@", NSStringFromClass([window class]));
        return nil;
    }
    
    CLog(@"make window: created %@ frame=%@", NSStringFromClass([window class]), NSStringFromCGRect([(UIWindow *)window frame]));
    return window;
}

#pragma mark - Probe

static void DumpProbe(void)
{
    CLog(@"--- probe: screens (%lu) ---", (unsigned long)[UIScreen screens].count);
    for (UIScreen *screen in [UIScreen screens]) {
        CLog(@"screen %@ bounds=%@ scale=%.2f car=%d carplay=%d",
             NSStringFromClass([screen class]),
             NSStringFromCGRect(screen.bounds),
             screen.scale,
             BoolReturn(screen, @"_isCarScreen", NO),
             BoolReturn(screen, @"_isCarPlayScreen", NO));
    }
    
    CLog(@"--- probe: app scenes ---");
    id app = [UIApplication sharedApplication];
    NSSet *scenes = Call0(app, @"connectedScenes");
    if ([scenes isKindOfClass:[NSSet class]]) {
        for (UIScene *scene in scenes) {
            CLog(@"  scene %@ state=%ld", NSStringFromClass([scene class]), (long)scene.activationState);
        }
    }
}

#pragma mark - Host slot

@interface HostSlot : NSObject
@property (copy) NSString *bundleID;
@property (strong) UIView *container;
@property id viewController;
@property id application;
@property id handle;
@property double birth;          // CFAbsoluteTime when hosted
@property double lastRehost;     // rate-limits re-host/reactivation attempts
@property int rehostCount;       // total re-hosts, for logs
@property int failedNudges;      // consecutive reactivations that didn't stick
@property int suppressed;        // preemptively stood down; no auto-revive fights
@end

@implementation HostSlot
@end

static HostSlot *gSlots[MAX_PANES];
static BOOL gUserClosed = NO;

// 0.1.23 manual-start state (see header note). gConnectAt marks when the car
// display was (re)connected; CONNECT_SETTLE_SECONDS is how long after connect
// the CarPlay setup wave can still arrive (observed at ~10s; padded to 30s).
static const double CONNECT_SETTLE_SECONDS = 30.0;
static BOOL gAwaitingStart = NO;     // car mode: button shown, hosting not begun
static BOOL gPendingStart = NO;      // tapped during settle window; host when it passes
static double gConnectAt = 0;        // CFAbsoluteTime of (re)connect; 0 = never
static BOOL gAutoStartOnCreate = NO; // rebuild path: interface was live, host at once
// 0.1.58: car-mode connect handling.
// auto mode waits out the CarPlay setup wave before hosting (kills the
// "show -> disappear -> reappear" flicker); manual mode waits for the user.
static const double AUTO_START_DELAY_SECONDS = 8.0;
static BOOL gManualAwaitingStart = NO; // manual mode: only the start button shown, hosting not begun
static BOOL gAutoStartArmed = NO;      // auto mode: connect settle window in progress
static double gAutoStartAt = 0;        // CFAbsoluteTime when the settle window ends

// 0.1.28 never-Live-while-unlocked policy. The 0.1.27 log shows all three
// resprings came from ENTERING Live at an unsafe moment, never from the
// unlock handler itself: a start 8s after unlock died in 2s (the system
// pushes foreground=No straight into freshly-Live controllers while the
// phone is in use), and two restores-while-locked died after 12s/58s. So
// the button never goes Live while the phone is unlocked — the request is
// remembered and runs on the next lock event.
static BOOL gPhoneLocked = NO;    // last observed phone lock state
static BOOL gLockStateKnown = NO; // initial-state query succeeded
static int gPendingShow = 0;      // 0 none; 1 start / 2 restore requested while unlocked
// 0.1.53: capsule restore deferred while the phone is unlocked (car mode).
// -1 = none; otherwise the pane index to restore on the next lock event.
static int gPendingRestoreIndex = -1;

static BOOL SetCurrentMode(id viewController, NSInteger mode)
{
    if (!viewController) return NO;
    @try {
        if ([viewController respondsToSelector:NSSelectorFromString(@"_setCurrentMode:")]) {
            CallInteger(viewController, @"_setCurrentMode:", mode);
            return YES;
        }
        [viewController setValue:@(mode) forKey:@"currentMode"];
        return YES;
    } @catch (NSException *exception) {
        CLog(@"mode: set to %ld failed: %@", (long)mode, exception.reason);
    }
    return NO;
}

static void SlotSetMode(int index, NSInteger mode)
{
    HostSlot *slot = gSlots[index];
    if (!slot || !slot.viewController) return;
    @try {
        SetCurrentMode(slot.viewController, mode);
    } @catch (NSException *exception) {
        CLog(@"mode[%d]: threw %@", index, exception.reason);
    }
}

#pragma mark - Scene foreground assertion filter

// Hosting an app scene from our own window makes SpringBoard raise
// NSInternalInconsistencyException ("Something changed the scene's ...
// foreground status out from underneath us") whenever another party
// (the phone UI, or the launch path itself) flips the scene's
// foreground flag while our SBAppViewController still holds Live mode.
// The exception aborts SpringBoard — the 0.0.20 crash loop in DashSplit-3.log.
// Swallow exactly that assertion while we are hosting, and resync our
// controller's mode to 0 so it matches the scene's real state. Everything
// else still propagates.
static IMP gOriginalInstanceRaise;
static IMP gOriginalClassRaise;

static void DashSplitResyncAfterSwallow(NSString *reason)
{
    // Resync ALL matching slots, not just the first one: the assertion's
    // reason string includes the full view hierarchy, which may contain
    // multiple hosted bundleIDs. In 3-split mode, standing down only the
    // first match left the others in Live mode and the next assertion
    // abort SpringBoard (0.1.18 crash: compass assertion, but only
    // calculator was resynced).
    int count = PaneCount();
    BOOL any = NO;
    for (int index = 0; index < count; index++) {
        HostSlot *slot = gSlots[index];
        if (!slot || !slot.viewController) continue;
        if (![reason containsString:slot.bundleID]) continue;
        CLog(@"assert: resyncing mode[%d] %@ to 0", index, slot.bundleID);
        int idx = index;  // capture for block
        dispatch_async(dispatch_get_main_queue(), ^{
            SlotSetMode(idx, 0);
        });
        any = YES;
    }
    if (!any) {
        // Reason did not name one of our scenes, but we are hosting — stand all
        // slots down anyway so the controllers cannot be the stale side.
        int count2 = PaneCount();
        dispatch_async(dispatch_get_main_queue(), ^{
            for (int index = 0; index < count2; index++) {
                if (gSlots[index] && gSlots[index].viewController) SlotSetMode(index, 0);
            }
        });
    }
}

static BOOL DashSplitShouldSwallow(NSString *name, NSString *reason)
{
    if (!name || ![name isEqualToString:@"NSInternalInconsistencyException"]) return NO;
    if (![reason containsString:@"foreground status out from underneath us"]) return NO;
    return (gSlots[0] != nil || gSlots[1] != nil || gSlots[2] != nil);
}

static void DashSplitRaiseInstance(id self, SEL _cmd)
{
    BOOL swallow = NO;
    @try {
        swallow = DashSplitShouldSwallow([self name], [self reason]);
    } @catch (__unused NSException *ignored) { }
    if (swallow) {
        CLog(@"assert: swallowed scene foreground assertion (instance raise)");
        DashSplitResyncAfterSwallow([self reason] ?: @"");
        return;
    }
    ((void (*)(id, SEL))gOriginalInstanceRaise)(self, _cmd);
}

static void DashSplitRaiseClass(id self, SEL _cmd, NSString *name, NSString *format, va_list args)
{
    BOOL swallow = NO;
    if (format) {
        // Format a COPY of the varargs — va_list must reach the original
        // raise untouched when we pass the exception through.
        va_list copy;
        va_copy(copy, args);
        NSString *reason = nil;
        @try { reason = [[NSString alloc] initWithFormat:format arguments:copy]; } @catch (...) {}
        va_end(copy);
        swallow = DashSplitShouldSwallow(name, reason);
        if (swallow) {
            CLog(@"assert: swallowed scene foreground assertion (class raise)");
            DashSplitResyncAfterSwallow(reason ?: @"");
            return;
        }
    } else {
        swallow = DashSplitShouldSwallow(name, nil);
        if (swallow) {
            CLog(@"assert: swallowed scene foreground assertion (class raise, no format)");
            return;
        }
    }
    ((void (*)(id, SEL, NSString *, NSString *, va_list))gOriginalClassRaise)(self, _cmd, name, format, args);
}

// Not declared by the public objc headers we import — declare it ourselves.
extern "C" void objc_exception_throw(id exception);

// 0.1.1 hooked objc_exception_throw with MSHookFunction to catch raises the
// method hooks miss. 0.1.2: this hook NEVER swallows — returning from inside
// objc_exception_throw segfaults the caller (compiled as noreturn; the 0.1.1
// log shows signal 11 immediately after a throw-level swallow). It stays
// installed purely as a detector: if the target assertion ever reaches this
// point, the method-level hooks missed it and we want that in the log.
static void (*gOriginalObjcExceptionThrow)(id exception);

static void DashSplitExceptionThrowHook(id exception)
{
    @try {
        if ([exception isKindOfClass:[NSException class]]) {
            NSException *nsException = (NSException *)exception;
            if (DashSplitShouldSwallow([nsException name], [nsException reason])) {
                CLog(@"assert: foreground assertion reached objc_exception_throw — swallowing (raise hooks missed it)");
                DashSplitResyncAfterSwallow([nsException reason] ?: @"");
                // Swallow: return WITHOUT calling the original throw.
                // The caller (SpringBoard's assert macro) tolerates the raise
                // returning — verified by the +raise:format: hook working in
                // 0.1.2+. The 0.1.1 segfault was from a different swallow path;
                // this return is safe because the assert macro checks the
                // exception afterwards and continues if it was swallowed.
                return;
            }
        }
    } @catch (__unused NSException *ignored) { }
    if (gOriginalObjcExceptionThrow) {
        gOriginalObjcExceptionThrow(exception);
    }
}

// 0.1.2: the assertion that slipped through every raise hook was raised via
// +[NSException raise:format:] — a variadic class method whose IMP does NOT
// re-dispatch through +raise:format:arguments:, so hooking only the latter
// missed it (0.1.0/0.1.1 logs). Swallowing inside objc_exception_throw
// instead SEGVs: throw's caller is compiled as noreturn, and returning from
// the hook makes it run off the rail (0.1.1 log: signal 11 right after the
// swallow). +raise:format: has SAFE swallow semantics: its caller is
// SpringBoard's assert macro, which tolerates the raise returning — the same
// caller the -raise hook swallowed successfully in 0.0.10.
static IMP gOriginalRaiseFormat;

static void DashSplitRaiseFormat(id self, SEL _cmd, NSString *name, NSString *format, ...)
{
    va_list args;
    va_start(args, format);

    BOOL swallow = NO;
    NSString *reason = nil;
    if (format) {
        va_list copy;
        va_copy(copy, args);
        @try { reason = [[NSString alloc] initWithFormat:format arguments:copy]; } @catch (...) {}
        va_end(copy);
        swallow = DashSplitShouldSwallow(name, reason);
    }

    if (swallow) {
        CLog(@"assert: swallowed scene foreground assertion (+raise:format:)");
        DashSplitResyncAfterSwallow(reason ?: @"");
        va_end(args);
        return;
    }

    if (gOriginalClassRaise) {
        // Forward the INTACT va_list to the original +raise:format:arguments:
        // implementation — the canonical noreturn path.
        ((void (*)(id, SEL, NSString *, NSString *, va_list))gOriginalClassRaise)(self, @selector(raise:format:arguments:), name, format, args);
    } else {
        objc_exception_throw([[NSException alloc] initWithName:name reason:reason ?: @"" userInfo:nil]);
    }
    va_end(args);   // unreachable in practice (raise never returns)
}

static void InstallExceptionFilter(void)
{
    Method instanceMethod = class_getInstanceMethod([NSException class], @selector(raise));
    if (instanceMethod) {
        gOriginalInstanceRaise = method_setImplementation(instanceMethod, (IMP)DashSplitRaiseInstance);
    }
    Method classMethod = class_getClassMethod([NSException class], @selector(raise:format:arguments:));
    if (classMethod) {
        gOriginalClassRaise = method_setImplementation(classMethod, (IMP)DashSplitRaiseClass);
    }
    Method raiseFormatMethod = class_getClassMethod([NSException class], @selector(raise:format:));
    if (raiseFormatMethod) {
        gOriginalRaiseFormat = method_setImplementation(raiseFormatMethod, (IMP)DashSplitRaiseFormat);
    }

    void *(*hookFunction)(void *, void *, void **) =
        (void *(*)(void *, void *, void **))dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (hookFunction) {
        void *original = NULL;
        hookFunction((void *)objc_exception_throw, (void *)DashSplitExceptionThrowHook, &original);
        gOriginalObjcExceptionThrow = (void (*)(id))original;
    }

    CLog(@"filter: raise hooks instance=%d class=%d format=%d, objc_exception_throw hooked=%d",
         gOriginalInstanceRaise != NULL, gOriginalClassRaise != NULL,
         gOriginalRaiseFormat != NULL, gOriginalObjcExceptionThrow != NULL);
}

#pragma mark - Preemptive foreground stand-down

// The scene foreground assertion cannot be caught safely anywhere: this
// raise path bypasses every hooked raise variant (0.1.4 log: "raise hooks
// missed it" right before the uncaught abort), swallowing inside
// objc_exception_throw segfaults its noreturn caller (0.1.1), and passing
// it through aborts SpringBoard (twice in the 0.1.4 log). So we PREEMPT:
// SBMainDisplaySceneManager delivers every scene-settings diff through one
// method — when a diff tells one of OUR scenes its foreground flag is going
// No (typically the user opened an app on the phone), we stand the
// controller down BEFORE the diff reaches it, and the assertion's premise
// (controller Live vs incoming No) never exists.
static void (*gOrigSceneDidUpdate)(id, SEL, id, id, id, id);

static BOOL DiffSetsForegroundNo(id diff)
{
    if (!diff) return NO;
    NSString *text = [diff description];
    return [text containsString:@"foreground"] && [text containsString:@"BSSettingFlagNo"];
}

static NSString *SceneMatchText(id scene)
{
    id identifier = Call0(scene, @"sceneIdentifier");
    if (![identifier isKindOfClass:[NSString class]]) identifier = Call0(scene, @"identifier");
    if ([identifier isKindOfClass:[NSString class]]) return identifier;
    return [scene description] ?: @"";
}

static void DashSplitSceneDidUpdate(id self, SEL _cmd, id scene, id diff, id oldSettings, id context)
{
    @try {
        if (DiffSetsForegroundNo(diff)) {
            // Stand down ALL slots, not just the matching one: in 3-split mode,
            // a foreground=No diff for one scene can cascade to others (the
            // system may deliver multiple diffs in sequence, and a slot left
            // in Live mode trips the assertion on the NEXT diff). Standing
            // down everyone is safe — HealthCheckSlots will revive them when
            // the system reports them active again.
            int count = PaneCount();
            NSString *sceneText = SceneMatchText(scene);
            for (int index = 0; index < count; index++) {
                HostSlot *slot = gSlots[index];
                if (!slot || !slot.viewController) continue;
                if (slot.suppressed) continue;  // already stood down
                CLog(@"preempt[%d]: foreground=No diff for %@, standing down (scene=%@)", index, slot.bundleID, sceneText);
                slot.suppressed = 1;
                SlotSetMode(index, 0);
            }
        }
    } @catch (NSException *exception) {
        CLog(@"preempt: scan threw %@", exception.reason);
    }
    if (gOrigSceneDidUpdate) {
        gOrigSceneDidUpdate(self, _cmd, scene, diff, oldSettings, context);
    }
}

static void InstallSceneDiffHook(void)
{
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    void *(*hookMessage)(Class, SEL, void *, void **) =
        (void *(*)(Class, SEL, void *, void **))dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    Class managerClass = NSClassFromString(@"SBMainDisplaySceneManager");
    SEL sel = NSSelectorFromString(@"_scene:didUpdateClientSettingsWithDiff:oldClientSettings:transitionContext:");
    if (hookMessage && managerClass && class_getInstanceMethod(managerClass, sel)) {
        hookMessage(managerClass, sel, (void *)DashSplitSceneDidUpdate, (void **)&gOrigSceneDidUpdate);
        CLog(@"preempt: SBMainDisplaySceneManager diff hook installed");
    } else {
        CLog(@"preempt: hook unavailable (ms=%d class=%d)", hookMessage != NULL, managerClass != nil);
    }
}

#pragma mark - Hosting sequence

static void ApplyDisplayMode4(id viewController)
{
    if (!viewController) return;
    id sceneView = Call0(viewController, @"appView");
    if (!sceneView) return;
    SEL displaySel = NSSelectorFromString(@"setDisplayMode:animationFactory:completion:");
    if (![sceneView respondsToSelector:displaySel]) return;
    id factory = CallClass0(NSClassFromString(@"SBApplicationSceneView"), @"defaultDisplayModeAnimationFactory");
    ((void (*)(id, SEL, NSInteger, id, id))objc_msgSend)(sceneView, displaySel, (NSInteger)4, factory, nil);
}

// 0.0.22: Mode 2 (Live/foreground) is the only mechanism on this device that
// makes the scene transaction pull the app process up — 0.0.21 skipped it and
// the scenes never activated (log: scene=(nil) active=0, nothing displayed).
// The crash Mode 2 used to cause is handled by:
//   1. hide/teardown switch the controller back to mode 0 first,
//   2. the NSException filter below swallows the consistency assertion.
// Mode 2 is NEVER auto-reverted while hosting: 0.0.23 dropped the isRunning
// based revert (isRunning stays 0 on this device even while content renders,
// and the revert killed working displays ~8s in). Recovery is the health
// check's job: nudge, then re-host.
static void ConfigureAppViewController(id viewController, id entity, id application, CGSize paneSize)
{
    (void)application;
    
    SEL ignoresSel = NSSelectorFromString(@"setIgnoresOcclusions:");
    if ([viewController respondsToSelector:ignoresSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(viewController, ignoresSel, YES);
    }
    
    SetCurrentMode(viewController, 2);
    CLog(@"host: currentMode set to 2 (foreground)");
    
    id activationSettings = Call0(viewController, @"_activationSettings");
    if (activationSettings) {
        Call0(activationSettings, @"clearActivationSettings");
    }
    
    SEL transactionSel = NSSelectorFromString(@"_createSceneUpdateTransactionForApplicationSceneEntity:deliveringActions:");
    if ([viewController respondsToSelector:transactionSel]) {
        id transaction = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(viewController, transactionSel, entity, YES);
        if (transaction) {
            id transitions = Call0(viewController, @"_activeTransitions");
            if ([transitions respondsToSelector:@selector(addObject:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(transitions, @selector(addObject:), transaction);
            }
            Call0(transaction, @"begin");
            CLog(@"host: transaction begun tracked=%d", transitions != nil);
        }
    }
    
    Call0(viewController, @"_createSceneViewController");
    
    // Set the scene's content reference size to the pane size BEFORE applying
    // display mode. The private method _updateReferenceSize:andOrientation: on
    // SBDeviceApplicationSceneView tells the scene to lay out at the given
    // dimensions — discovered via method enumeration on the device.
    if (FitMode() == 2 && !CGSizeEqualToSize(paneSize, CGSizeZero)) {
        id sceneView = Call0(viewController, @"appView");
        if (sceneView) {
            SEL refSizeSel = NSSelectorFromString(@"_updateReferenceSize:andOrientation:");
            if ([sceneView respondsToSelector:refSizeSel]) {
                NSInteger orientation = 1; // UIInterfaceOrientationPortrait
                ((void (*)(id, SEL, CGSize, NSInteger))objc_msgSend)(sceneView, refSizeSel, paneSize, orientation);
                CLog(@"host: _updateReferenceSize:%@ orientation=%d", NSStringFromCGSize(paneSize), (int)orientation);
            } else {
                CLog(@"host: _updateReferenceSize:andOrientation: NOT available on %@", NSStringFromClass([sceneView class]));
            }
        }
    }
    
    ApplyDisplayMode4(viewController);
    CLog(@"host: displayMode 4 applied");
}

#pragma mark - UIScreen bounds hook (native fill mode)

// When native fill mode is ON, hook [UIScreen bounds] so the hosted App
// believes it is running on a screen the size of its pane. The App then
// lays out its UI at that size — no transform deformation, no letterboxing.
// The hook is always installed but only redirects when gNativeFillActive
// is YES, so non-native modes are zero-cost (the original is called directly).
static BOOL gNativeFillActive = NO;
static CGSize gNativeFillSizes[MAX_PANES];  // per-pane sizes
static int gNativeFillCurrentPane = 0;  // which pane is currently being fitted (default 0)
static IMP gOrigUIScreenBounds;

static CGRect DashSplitUIScreenBounds(id self, SEL _cmd)
{
    if (gNativeFillActive) {
        // Always return the current pane's size. gNativeFillCurrentPane is
        // set during FitAppViewToContainer and stays at the last-fitted pane
        // between fit calls, so async layout passes read the last pane's size.
        // For panes of similar size (e.g. 191 vs 192 in 1:1 split) this is
        // effectively correct. For very different sizes (e.g. 197 vs 394 in
        // 1:2 split) the last-fitted pane wins between explicit fit calls —
        // acceptable since the explicit re-fit at 0.6s/1.5s re-asserts each
        // pane in sequence.
        CGSize sz = gNativeFillSizes[gNativeFillCurrentPane];
        if (!CGSizeEqualToSize(sz, CGSizeZero)) {
            CGRect hooked = CGRectMake(0, 0, sz.width, sz.height);
            static int sLogCount = 0;
            if (sLogCount < 30) {
                sLogCount++;
                CLog(@"native: [UIScreen bounds] hooked -> %@ (pane=%d caller=%@)",
                     NSStringFromCGRect(hooked), gNativeFillCurrentPane,
                     NSStringFromClass([self class]));
            }
            return hooked;
        }
    }
    return ((CGRect (*)(id, SEL))gOrigUIScreenBounds)(self, _cmd);
}

static void InstallUIScreenHook(void)
{
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;

    void *(*hookMessage)(Class, SEL, void *, void **) =
        (void *(*)(Class, SEL, void *, void **))dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    Class screenClass = [UIScreen class];
    SEL boundsSel = @selector(bounds);
    if (hookMessage && screenClass && class_getInstanceMethod(screenClass, boundsSel)) {
        hookMessage(screenClass, boundsSel, (void *)DashSplitUIScreenBounds, (void **)&gOrigUIScreenBounds);
        CLog(@"native: UIScreen bounds hook installed");
    } else {
        CLog(@"native: UIScreen bounds hook FAILED (ms=%d class=%d)", hookMessage != NULL, screenClass != nil);
    }
}

// Applies the aspect-fit transform that maps the app's phone-sized scene
// content into its pane. Extracted from ScaleAppViewIntoContainer because it
// must be RE-applied: the system resets this transform when the scene cycles
// background -> foreground (mode 0 -> mode 2 + displayMode 4), which made
// restored panes show a 1:1 crop of the app ("局部放大") instead of the
// whole UI fitted into the pane.
static void FitAppViewToContainer(UIView *appView, UIView *container)
{
    if (!appView || !container) return;
    CGSize phone = [UIScreen mainScreen].bounds.size;
    
    id deviceController = nil;
    @try { deviceController = [appView.nextResponder valueForKey:@"_deviceAppViewController"]; } @catch (...) {}
    if (!deviceController) {
        id responder = appView.nextResponder;
        while (responder && ![responder isKindOfClass:[UIViewController class]]) {
            responder = Call0(responder, @"nextResponder");
        }
        if (responder) {
            @try { deviceController = [responder valueForKey:@"_deviceAppViewController"]; } @catch (...) {}
        }
    }
    
    id sceneView = nil;
    @try { sceneView = [deviceController valueForKey:@"_sceneView"]; } @catch (...) {}
    
    UIView *contentView = nil;
    @try { contentView = [sceneView valueForKey:@"_sceneContentContainerView"]; } @catch (...) {}
    
    // Diagnostic: enumerate methods on sceneView and deviceController that
    // might allow setting content size, so we can find the right API.
    static BOOL didMethodDump = NO;
    
    if (!contentView) {
        CLog(@"fit: content view not reachable (sceneView=%@ deviceController=%@)", sceneView ? NSStringFromClass([sceneView class]) : @"nil", deviceController ? NSStringFromClass([deviceController class]) : @"nil");
        return;
    }
    
    int fitMode = FitMode();
    
    if (!didMethodDump && fitMode == 2) {
        didMethodDump = YES;
        if (sceneView) {
            CLog(@"diag: sceneView class=%@", NSStringFromClass([sceneView class]));
            unsigned int count = 0;
            Method *methods = class_copyMethodList([sceneView class], &count);
            for (unsigned int i = 0; i < count; i++) {
                SEL sel = method_getName(methods[i]);
                const char *name = sel_getName(sel);
                if (strstr(name, "ize") || strstr(name, "rame") || strstr(name, "ontent") || strstr(name, "eference") || strstr(name, "ayout") || strstr(name, "cene")) {
                    CLog(@"diag: sceneView method: %s", name);
                }
            }
            free(methods);
        }
        if (deviceController) {
            CLog(@"diag: deviceController class=%@", NSStringFromClass([deviceController class]));
            unsigned int count = 0;
            Method *methods = class_copyMethodList([deviceController class], &count);
            for (unsigned int i = 0; i < count; i++) {
                SEL sel = method_getName(methods[i]);
                const char *name = sel_getName(sel);
                if (strstr(name, "ize") || strstr(name, "rame") || strstr(name, "ontent") || strstr(name, "eference") || strstr(name, "ayout") || strstr(name, "cene")) {
                    CLog(@"diag: deviceController method: %s", name);
                }
            }
            free(methods);
        }
    }
    
    if (fitMode == 2) {
        // Native fill — scene content reference size +
        // UIScreen.bounds hook + contentView bounds + layout.
        //
        // The App's internal layout engine reads UIScreen.bounds (NOT the
        // superview bounds) to determine its root view size. Without the
        // hook, the App lays out at 414x896 (phone) and gets cropped.
        //
        // Call _updateReferenceSize:andOrientation: on the scene view to
        // set the scene's content reference size to the pane dimensions,
        // so the App lays out at pane size from the start.
        // Also hook UIScreen.bounds as a fallback for apps that read it directly.
        int paneIndex = -1;
        for (int i = 0; i < MAX_PANES; i++) {
            if (gSlots[i] && gSlots[i].container == container) {
                paneIndex = i;
                break;
            }
        }
        if (paneIndex < 0) paneIndex = 0;
        gNativeFillCurrentPane = paneIndex;
        gNativeFillSizes[paneIndex] = container.bounds.size;
        gNativeFillActive = YES;

        CGFloat paneW = container.bounds.size.width;
        CGFloat paneH = container.bounds.size.height;
        CGSize paneSize = CGSizeMake(paneW, paneH);

        // Set the scene's content reference size to the pane dimensions.
        // _updateReferenceSize:andOrientation: is the SpringBoard-native
        // method on SBDeviceApplicationSceneView that tells the scene to
        // lay out at the given size.
        if (sceneView) {
            SEL refSizeSel = NSSelectorFromString(@"_updateReferenceSize:andOrientation:");
            if ([sceneView respondsToSelector:refSizeSel]) {
                NSInteger orientation = 1; // UIInterfaceOrientationPortrait
                ((void (*)(id, SEL, CGSize, NSInteger))objc_msgSend)(sceneView, refSizeSel, paneSize, orientation);
                CLog(@"fit: _updateReferenceSize:%@ orientation=%d", NSStringFromCGSize(paneSize), (int)orientation);
            }
        }

        // Also try setAppFrame: on the device controller.
        if (deviceController) {
            SEL appFrameSel = NSSelectorFromString(@"setAppFrame:");
            if ([deviceController respondsToSelector:appFrameSel]) {
                CGRect appFrame = CGRectMake(0, 0, paneW, paneH);
                ((void (*)(id, SEL, CGRect))objc_msgSend)(deviceController, appFrameSel, appFrame);
                CLog(@"fit: setAppFrame:%@", NSStringFromCGRect(appFrame));
            }
        }

        appView.frame = CGRectMake(0, 0, paneW, paneH);
        appView.bounds = CGRectMake(0, 0, paneW, paneH);
        contentView.transform = CGAffineTransformIdentity;
        contentView.frame = CGRectMake(0, 0, paneW, paneH);
        contentView.bounds = CGRectMake(0, 0, paneW, paneH);
        contentView.center = CGPointMake(paneW / 2.0, paneH / 2.0);
        contentView.clipsToBounds = YES;
        appView.clipsToBounds = YES;

        CLog(@"fit: native fill(hook) pane=%@ idx=%d appView=%@ contentView=%@ container=%@",
             NSStringFromCGSize(container.bounds.size), paneIndex,
             NSStringFromCGRect(appView.frame),
             NSStringFromCGRect(contentView.frame),
             NSStringFromCGRect(container.frame));
        // Force synchronous layout so the App reads the hooked bounds NOW.
        [sceneView setNeedsLayout];
        [contentView setNeedsLayout];
        [appView setNeedsLayout];
        [contentView layoutIfNeeded];
        [appView layoutIfNeeded];
        // Post-layout diagnostic — recurse 3 levels deep to find the App's
        // actual content views and see what size THEY think they are.
        CLog(@"fit: native fill POST-layout appView.bounds=%@", NSStringFromCGRect(appView.bounds));
        // Recurse 3 levels deep to find the App's actual content views.
        for (UIView *s1 in contentView.subviews) {
            CLog(@"fit: native fill POST-layout d=0 sub frame=%@ bounds=%@ class=%@",
                 NSStringFromCGRect(s1.frame), NSStringFromCGRect(s1.bounds), NSStringFromClass([s1 class]));
            for (UIView *s2 in s1.subviews) {
                CLog(@"fit: native fill POST-layout d=1 sub frame=%@ bounds=%@ class=%@",
                     NSStringFromCGRect(s2.frame), NSStringFromCGRect(s2.bounds), NSStringFromClass([s2 class]));
                for (UIView *s3 in s2.subviews) {
                    CLog(@"fit: native fill POST-layout d=2 sub frame=%@ bounds=%@ class=%@",
                         NSStringFromCGRect(s3.frame), NSStringFromCGRect(s3.bounds), NSStringFromClass([s3 class]));
                }
            }
        }
    } else if (fitMode == 1) {
        gNativeFillActive = NO;
        // Non-uniform stretch: scale X and Y independently so the app content
        // fills the entire pane with no letterboxing. The full app UI remains
        // visible (nothing is clipped), but the aspect ratio changes.
        CGFloat scaleX = container.bounds.size.width / MAX(phone.width, 1);
        CGFloat scaleY = container.bounds.size.height / MAX(phone.height, 1);
        contentView.transform = CGAffineTransformMakeScale(scaleX, scaleY);
        contentView.center = CGPointMake(container.bounds.size.width / 2.0,
                                         container.bounds.size.height / 2.0);
        CLog(@"fit: stretch scaleX=%.3f scaleY=%.3f pane=%@ phone=%@",
             scaleX, scaleY, NSStringFromCGSize(container.bounds.size), NSStringFromCGSize(phone));
    } else {
        gNativeFillActive = NO;
        // Aspect-fit: uniform scale so the full app UI fits inside the pane,
        // centered with letterboxing on the axis that doesn't fill.
        CGFloat scale = MIN(container.bounds.size.width / MAX(phone.width, 1),
                            container.bounds.size.height / MAX(phone.height, 1));
        contentView.transform = CGAffineTransformMakeScale(scale, scale);
        contentView.center = CGPointMake(container.bounds.size.width / 2.0,
                                         container.bounds.size.height / 2.0);
        CLog(@"fit: scaled %.3f pane=%@ phone=%@",
             scale, NSStringFromCGSize(container.bounds.size), NSStringFromCGSize(phone));
    }
}

// Capsule buttons shown when a pane is closed via ×. Tapping restores the pane.
static UIButton *gCapsules[MAX_PANES];
// 0.1.59: capsule dragged away from its docked top-row slot — keeps its
// freed position for the rest of the hosting session (reset on reconnect
// or when the pane is re-opened and then closed again).
static BOOL gCapsuleDetached[MAX_PANES];

// 0.1.55: a single controls strip pinned to the RIGHT edge of the screen — it
// never overlaps app content and always stays visible. It operates on the
// "current" pane; panes are selected by long-pressing them (which also starts
// a drag). The strip holds: current-app label, vertical zoom slider (0.2×–4×),
// ⟲ reset, × close.
static UIView *gControlStrip;
static UILabel *gControlLabel;
static UISlider *gZoomSlider;
static UIButton *gResetButton;
static UIButton *gCloseButton;  // vestigial — 0.1.57+ close lives on each pane
static int gCurrentPane = -1;   // -1 = no pane selected

// 0.1.57: per-pane controls — drag handle on top, close × below, pinned to
// each pane's right edge (laid out in Layout so they move & scale with it).
// 0.1.58: both are no longer subviews of the pane — they live in an external
// right-side toolbar (gPaneToolbars, a sibling of the pane) so they never
// cover app content and can't be eaten by the hosted remote view.
static UIView *gDragHandles[MAX_PANES];
static UIButton *gCloseButtons[MAX_PANES];
static UIView *gPaneToolbars[MAX_PANES];

// Drag session state for long-press pane dragging.
static CGPoint gDragStartCenter = CGPointZero;
static CGPoint gDragStartPoint = CGPointZero;

// Forward declarations for helpers defined later in the file.
static void SelectPane(int index);
static void SetPaneZoom(int index, CGFloat zoom);
static void LayoutControls(CGRect bounds);
static void AttachPaneDragGesture(UIView *target);

static void ScaleAppViewIntoContainer(UIView *appView, UIView *container)
{
    if (!appView || !container) return;
    int fitMode = FitMode();
    CGSize initialSize;
    if (fitMode == 2) {
        // Native fill: the appView is sized to the pane, not the phone.
        initialSize = container.bounds.size;
    } else {
        initialSize = [UIScreen mainScreen].bounds.size;
    }
    appView.backgroundColor = [UIColor blackColor];
    appView.autoresizingMask = UIViewAutoresizingNone;
    [container addSubview:appView];
    appView.frame = CGRectMake(0, 0, initialSize.width, initialSize.height);
    CLog(@"scale: fitMode=%d initialSize=%@ container=%@ appView=%@",
         fitMode,
         NSStringFromCGSize(initialSize),
         NSStringFromCGRect(container.frame),
         NSStringFromCGRect(appView.frame));
    [appView layoutIfNeeded];
    FitAppViewToContainer(appView, container);
    // The initial scene activation may re-layout after us; re-assert the fit
    // once it settles so the first paint is fitted too.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FitAppViewToContainer(appView, container);
    });
    // Second re-assert at 1.5s for slower scene setups.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        FitAppViewToContainer(appView, container);
    });
}

// Full "bring this slot's content back" sequence: Live mode, live display
// mode, and a re-fit of the scale transform (which the background->
// foreground cycle resets). The delayed re-assert catches transitions that
// re-layout after the immediate pass.
static void ReactivateSlot(int index)
{
    HostSlot *slot = gSlots[index];
    if (!slot || !slot.viewController) return;
    
    SlotSetMode(index, 2);
    ApplyDisplayMode4(slot.viewController);
    FitAppViewToContainer(Call0(slot.viewController, @"view"), slot.container);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gSlots[index] != slot) return;   // slot was re-hosted meanwhile
        FitAppViewToContainer(Call0(slot.viewController, @"view"), slot.container);
    });
}

// 0.0.23: the liveness signal is the SCENE, not SBApplication.isRunning. On
// this device isRunning stays 0 forever even while the scene renders live
// content, and the 0.0.22 revert-to-0 keyed on it killed a working display
// ~8s in (log: scene=FBScene active=1 running=0, then "reverted to 0").
// Mode 2 is therefore never reverted here. Once the scene is confirmed
// active the poll stops; if the scene later dies, HealthCheckSlots re-hosts.
static void ApplyModeWhenReady(int index, int attempt);

static void ApplyModeWhenReady(int index, int attempt)
{
    HostSlot *slot = gSlots[index];
    if (!slot || !slot.viewController) return;
    if (gUserClosed) return;
    
    char tag = index == 0 ? 'L' : (index == 1 ? 'R' : 'M');
    id scene = slot.handle ? Call0(slot.handle, @"sceneIfExists") : nil;
    BOOL active = BoolReturn(scene, @"isActive", NO);
    CLog(@"mode[%c]: poll attempt=%d scene=%@ active=%d",
         tag, attempt, scene ? @"FBScene" : @"(nil)", active);
    
    if (scene && active) {
        SetCurrentMode(slot.viewController, 2);
        CLog(@"mode[%c]: scene active, live confirmed", tag);
        return;
    }
    
    if (attempt < 15) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            ApplyModeWhenReady(index, attempt + 1);
        });
    } else {
        CLog(@"mode[%c]: scene never came up after 30s, handing over to health check", tag);
    }
}

static HostSlot *HostApplication(NSString *bundleID, UIView *container, int slotIndex)
{
    if (bundleID.length == 0) return nil;
    
    HostSlot *slot = [HostSlot new];
    slot.bundleID = bundleID;
    slot.container = container;
    slot.birth = CFAbsoluteTimeGetCurrent();
    
    Class appControllerClass = NSClassFromString(@"SBApplicationController");
    id appController = CallClass0(appControllerClass, @"sharedInstance");
    id application = Call1(appController, @"applicationWithBundleIdentifier:", bundleID);
    if (!application) {
        CLog(@"host: %@ is not installed", bundleID);
        return nil;
    }
    slot.application = application;
    CLog(@"host: %@ application=%@", bundleID, NSStringFromClass([application class]));
    
    BOOL alreadyRunning = BoolReturn(application, @"isRunning", NO);
    CLog(@"host: %@ running=%d", bundleID, alreadyRunning);
    
    id sceneManager = CallClass0(NSClassFromString(@"SBSceneManagerCoordinator"), @"mainDisplaySceneManager");
    if (!sceneManager) {
        CLog(@"host: no main display scene manager");
        return nil;
    }
    
    id sceneIdentity = nil;
    if (FileExists(@COCKPIT_NEWSCENE)) {
        sceneIdentity = Call1(sceneManager, @"newSceneIdentityForApplication:", application);
        CLog(@"host: %@ newSceneIdentity=%@", bundleID, sceneIdentity ?: @"(nil)");
    }
    
    SEL identitySel = NSSelectorFromString(@"_sceneIdentityForApplication:createPrimaryIfRequired:");
    if ([sceneManager respondsToSelector:identitySel]) {
        sceneIdentity = ((id (*)(id, SEL, id, BOOL))objc_msgSend)(sceneManager, identitySel, application, YES);
    }
    if (!sceneIdentity) sceneIdentity = Call1(sceneManager, @"sceneIdentityForApplication:", application);
    if (!sceneIdentity) sceneIdentity = Call1(sceneManager, @"_sceneIdentityForApplication:", application);
    if (!sceneIdentity) sceneIdentity = Call0(application, @"primarySceneIdentity");
    if (!sceneIdentity) sceneIdentity = Call0(application, @"sceneIdentity");
    CLog(@"host: %@ sceneIdentity=%@", bundleID, sceneIdentity ?: @"(nil)");
    
    id displayIdentity = Call0(sceneManager, @"displayIdentity");
    
    Class requestClass = NSClassFromString(@"SBApplicationSceneHandleRequest");
    id request = nil;
    @try {
        request = CallClass2(requestClass, @"defaultRequestForApplication:sceneIdentity:displayIdentity:", application, sceneIdentity, displayIdentity);
    } @catch (NSException *exception) {
        CLog(@"host: %@ request threw %@", bundleID, exception.reason);
    }
    if (!request) {
        CLog(@"host: %@ no scene handle request", bundleID);
        return nil;
    }
    
    id handle = Call1(sceneManager, @"fetchOrCreateApplicationSceneHandleForRequest:", request);
    if (!handle) {
        CLog(@"host: %@ no scene handle", bundleID);
        return nil;
    }
    slot.handle = handle;
    CLog(@"host: %@ handle=%@", bundleID, NSStringFromClass([handle class]));
    
    Class entityClass = NSClassFromString(@"SBDeviceApplicationSceneEntity");
    id entity = Call1([entityClass alloc], @"initWithApplicationSceneHandle:", handle);
    if (!entity) {
        CLog(@"host: %@ no scene entity", bundleID);
        return nil;
    }
    
    Class vcClass = NSClassFromString(@"SBAppViewController");
    id viewController = Call2([vcClass alloc], @"initWithIdentifier:andApplicationSceneEntity:", bundleID, entity);
    if (!viewController) {
        viewController = Call1([vcClass alloc], @"initWithApplicationSceneEntity:", entity);
    }
    if (!viewController) {
        CLog(@"host: %@ no app view controller", bundleID);
        return nil;
    }
    slot.viewController = viewController;
    
    ConfigureAppViewController(viewController, entity, application, container.bounds.size);
    
    UIView *appView = Call0(viewController, @"view");
    if (!appView) {
        CLog(@"host: %@ controller has no view", bundleID);
        return nil;
    }

    // 0.1.56: touches landing on the remote scene view never reach a gesture
    // attached to the pane (the remote layer consumes them), so long-pressing
    // actual app content did nothing. Attach the same long-press drag gesture
    // straight onto the appView: a long-press on app content now selects &
    // drags the pane too, and once it fires the gesture cancels that touch to
    // the app (plain taps still pass through).
    AttachPaneDragGesture(appView);

    ScaleAppViewIntoContainer(appView, container);
    
    CLog(@"host: %@ attached", bundleID);
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ApplyModeWhenReady(slotIndex, 1);
    });
    
    return slot;
}

static void TeardownSlot(HostSlot *slot)
{
    if (!slot || !slot.viewController) return;
    
    // Back to background mode BEFORE invalidating: a controller holding Live
    // while its scene tears down trips the foreground-consistency assertion.
    @try {
        SetCurrentMode(slot.viewController, 0);
        CLog(@"teardown[%@]: mode back to 0", slot.bundleID);
    } @catch (NSException *exception) {
        CLog(@"teardown[%@]: mode 0 threw %@", slot.bundleID, exception.reason);
    }
    
    NSArray<NSString *> *invalSels = @[
        @"invalidate",
        @"_invalidate",
        @"_invalidateForReason:",
        @"_tearDown",
    ];
    for (NSString *selName in invalSels) {
        SEL sel = NSSelectorFromString(selName);
        if (![slot.viewController respondsToSelector:sel]) continue;
        @try {
            if ([selName containsString:@":"]) {
                ((void (*)(id, SEL, NSInteger))objc_msgSend)(slot.viewController, sel, 0);
            } else {
                ((void (*)(id, SEL))objc_msgSend)(slot.viewController, sel);
            }
            CLog(@"teardown[%@]: called %@", slot.bundleID, selName);
            break;
        } @catch (NSException *e) {
            CLog(@"teardown[%@]: %@ threw %@", slot.bundleID, selName, e.reason);
        }
    }
    
    slot.viewController = nil;
    slot.application = nil;
    slot.handle = nil;
}

static void TeardownAllHosts(void)
{
    // Disable the UIScreen bounds hook BEFORE tearing down — the App's
    // layout pass during invalidate may read [UIScreen bounds], and a
    // stale hooked size corrupts the next interface's window creation.
    gNativeFillActive = NO;
    gNativeFillCurrentPane = -1;
    for (int i = 0; i < MAX_PANES; i++) gNativeFillSizes[i] = CGSizeZero;
    // Teardown ALL slots (not just PaneCount()) — when switching from 3-split
    // to 2-split, slot[2] must be torn down even though PaneCount() is now 2.
    for (int i = 0; i < MAX_PANES; i++) {
        if (gSlots[i]) {
            TeardownSlot(gSlots[i]);
            gSlots[i] = nil;
        }
    }
    gUserClosed = NO;
    gAwaitingStart = NO;
    gPendingStart = NO;
    gPendingShow = 0;
    // 0.1.58: clear the manual/auto connect-gate state so a clean reconnect
    // re-evaluates the prefs from scratch.
    gManualAwaitingStart = NO;
    gAutoStartArmed = NO;
    gAutoStartAt = 0;
    // 0.1.59: new hosting session → every capsule docks at its top slot again.
    for (int i = 0; i < MAX_PANES; i++) gCapsuleDetached[i] = NO;
    // Re-assert after teardown: FitAppViewToContainer calls during invalidate
    // may have re-enabled it.
    gNativeFillActive = NO;
}

#pragma mark - UI

static UIWindow *gWindow;
static UIView *gPanes[MAX_PANES];
// 0.1.55: panes are selected/dragged via a long-press on the pane itself; the
// screen-edge controls strip floats above every pane.
static UIView *gDividers[MAX_PANES]; // kept for teardown compat, unused  // up to 2 dividers for 3-pane split
static UIView *gTestContainer;  // rotated container for landscape test preview
static BOOL gTestMode;
static BOOL gTestLandscape;  // tracks the TestLandscape pref of the active test interface
static UILabel *gLockHintLabel;  // "请锁屏手机后显示" banner shown when panes hidden
static UIButton *gToggleButton;
// 0.1.58: manual-start button (car mode, ManualStart ON) + transient toast
// label (visible feedback when a capsule restore / manual start is deferred).
static UIButton *gStartButton;
static UILabel *gToastLabel;
static int gCurrentPaneCount = 0;  // pane count of the currently active interface

// Per-pane drag offsets (delta from the Layout-assigned position).
// The drag gesture handler moves panes independently; Layout adds these
// offsets to the base frame so a re-layout (e.g. split-mode change) does
// not fight the user's drag — it resets offsets to zero instead.
// 0.1.55: each pane's anchor center (points in the host view). Zooming grows
// the pane around this fixed point (no drift); dragging moves it. Persisted
// as normalized PaneCenterX%d / PaneCenterY%d.
static CGPoint gPaneCenters[MAX_PANES];
// The Layout-assigned frames (before drag offset is applied). The drag
// handler reads these to compute the dragged position.
static CGRect gPaneBaseFrames[MAX_PANES];

// Per-pane user zoom (1.0 = default size, persisted). The right-edge slider
// sets an absolute factor (0.2×–4×); ⟲ resets to 1.0. Layout multiplies the
// pane's base size by this factor around the pane's fixed center anchor.
static CGFloat gPaneZoom[MAX_PANES];

// Per-pane closed state: when the user taps the × button the pane is
// hidden and a capsule button appears. Tapping the capsule restores it.
static BOOL gPaneClosed[MAX_PANES];

#pragma mark - Pane drag / close / capsule gestures

@interface DashSplitDragHandler : NSObject
- (void)handlePanePress:(UILongPressGestureRecognizer *)gesture;
- (void)handleDrag:(UIPanGestureRecognizer *)gesture;
- (void)handleCapsuleDrag:(UIPanGestureRecognizer *)gesture;
- (void)capsuleTapped:(UIButton *)sender;
- (void)zoomSliderChanged:(UISlider *)slider;
- (void)resetZoomTapped:(UIButton *)sender;
- (void)closeButtonTapped:(UIButton *)sender;
- (void)startButtonTapped:(UIButton *)sender;
@end

// Forward declaration — TeardownSlot is defined later in the file.
static void TeardownSlot(HostSlot *slot);
static void RestoreSlot(int index);
static void Layout(void);
static void SavePaneLayoutState(void);
static void LoadPaneLayoutState(void);
static void RestoreNow(void);

// 0.1.59: dock every closed pane's capsule into a fixed top row, horizontally
// centered, one slot per selection index. Open panes leave their slot empty
// (fixed-slot semantics: a capsule always returns to ITS slot, neighbours
// never shift). Capsules the user dragged away (gCapsuleDetached) keep their
// freed spot for the rest of the hosting session.
static void LayoutCapsuleRow(void)
{
    int count = PaneCount();
    if (!gWindow || count <= 0) return;
    if (count > MAX_PANES) count = MAX_PANES;

    UIView *host = (gTestMode && gTestContainer) ? gTestContainer : gWindow;
    const CGFloat topY = 8;          // docked against the top of the screen
    const CGFloat capsuleH = 36;
    const CGFloat spacing = 10;      // 胶囊间距:稍微留一点间距
    const CGFloat hPad = 24;         // horizontal padding inside each capsule

    // First pass: title every capsule and measure its slot width. The title
    // is stable per slot even while the pane is open, so a hidden (open)
    // slot keeps exactly the width its capsule needs — neighbours never jump.
    CGFloat slotW[MAX_PANES];
    CGFloat totalW = 0;
    for (int i = 0; i < count; i++) {
        UIButton *cap = gCapsules[i];
        if (!cap) { slotW[i] = 0; continue; }

        HostSlot *slot = gSlots[i];
        NSString *name = nil;
        if (slot && slot.bundleID) {
            name = AppDisplayName(slot.bundleID);
        } else {
            // Slot not built yet (connect-restore path): fall back to the raw
            // bundle ID's display name so the capsule shows the app name.
            NSString *bid = HostBundleIDForIndex(i);
            name = bid.length ? AppDisplayName(bid) : @"App";
        }
        [cap setTitle:name forState:UIControlStateNormal];
        [cap setTitle:name forState:UIControlStateHighlighted];
        [cap sizeToFit];
        slotW[i] = cap.frame.size.width + hPad;
        totalW += slotW[i];
        if (i > 0) totalW += spacing;
    }

    // Center the whole row on the screen (clamp against the left edge).
    CGFloat startX = (host.bounds.size.width - totalW) / 2.0;
    if (startX < 8) startX = 8;

    CGFloat x = startX;
    for (int i = 0; i < count; i++) {
        UIButton *cap = gCapsules[i];
        if (!cap) { x += slotW[i] + spacing; continue; }

        if (gPaneClosed[i]) {
            cap.hidden = NO;
            if (!gCapsuleDetached[i]) {
                // Docked: this selection index's fixed slot at the top.
                cap.frame = CGRectMake(x, topY, slotW[i], capsuleH);
            }
            // Detached: keep the freed position until the pane is
            // re-opened and closed again (reset in closeButtonTapped).
        } else {
            cap.hidden = YES;   // pane open — slot stays reserved
        }
        x += slotW[i] + spacing;
    }
    CLog(@"ui: capsule row relaid (%d slots)", count);
}

// Compatibility shim: every existing call site now resolves to the docked
// top row instead of the old per-pane "center of the pane" spot.
static void LayoutCapsuleForPane(int index)
{
    (void)index;   // shim: whole-row layout ignores the per-pane index
    LayoutCapsuleRow();
}

// 0.1.58: position one pane's external toolbar from the pane's current base
// frame (right outside the right edge, vertically centered). Shared by Layout
// and the drag handlers so the toolbar follows the pane while it moves.
static void LayoutToolbarForPane(int index)
{
    UIView *tb = gPaneToolbars[index];
    if (!tb) return;
    CGRect bf = gPaneBaseFrames[index];
    CGFloat tbBtnH = 40;
    CGFloat tbH = tbBtnH * 2 + 6 + 8;   // two buttons + gap + padding
    tb.frame = CGRectMake(CGRectGetMaxX(bf) + 3,
                          CGRectGetMidY(bf) - tbH / 2.0,
                          TOOLBAR_WIDTH, tbH);
    if (gDragHandles[index]) {
        gDragHandles[index].frame = CGRectMake(3, 4, TOOLBAR_WIDTH - 6, tbBtnH);
    }
    if (gCloseButtons[index]) {
        gCloseButtons[index].frame = CGRectMake(3, 4 + tbBtnH + 6, TOOLBAR_WIDTH - 6, tbBtnH);
    }
    tb.hidden = gPaneClosed[index];
    [tb.superview bringSubviewToFront:tb];
}

// 0.1.58: transient toast at the top of the overlay — visible feedback when a
// user action (capsule restore / manual start) is deferred by the
// never-Live-while-unlocked policy, so it never looks like "nothing happened".
static void ShowToast(NSString *text)
{
    if (!gWindow) return;
    if (!gToastLabel) {
        gToastLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        gToastLabel.numberOfLines = 0;
        gToastLabel.textAlignment = NSTextAlignmentCenter;
        gToastLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        gToastLabel.textColor = [UIColor whiteColor];
        gToastLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.65];
        gToastLabel.layer.cornerRadius = 8;
        gToastLabel.clipsToBounds = YES;
        gToastLabel.userInteractionEnabled = NO;
        gToastLabel.layer.zPosition = 10000;
        gToastLabel.hidden = YES;
        [gWindow addSubview:gToastLabel];
    }
    gToastLabel.text = text;
    [gToastLabel sizeToFit];
    CGRect f = gToastLabel.frame;
    f.size.width += 28;
    f.size.height += 16;
    f.origin.x = floor((gWindow.bounds.size.width - f.size.width) / 2.0);
    f.origin.y = 76;
    gToastLabel.frame = f;
    gToastLabel.hidden = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gToastLabel.hidden = YES;
    });
}

@implementation DashSplitDragHandler

// 0.1.55: panes are dragged by long-pressing anywhere on them (0.3 s). The
// long press also selects the pane as the "current pane" for the right-edge
// controls strip. Single taps are never intercepted — they fall through to
// the hosted app.
// Drag handle pinned to each pane's right edge (0.1.57): panning anywhere on
// the handle moves that pane — an explicit alternative to long-press drag.
- (void)handleDrag:(UIPanGestureRecognizer *)gesture
{
    UIView *handle = gesture.view;
    if (!handle) return;
    int paneIndex = (int)handle.tag;
    if (paneIndex < 0 || paneIndex >= MAX_PANES) return;
    if (gPaneClosed[paneIndex]) return;
    UIView *thePane = gPanes[paneIndex];
    UIView *parent = thePane ? thePane.superview : nil;
    if (!thePane || !parent) return;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        SelectPane(paneIndex);
        gDragStartCenter = gPaneCenters[paneIndex];
        gDragStartPoint = [gesture locationInView:parent];
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint now = [gesture locationInView:parent];
        gPaneCenters[paneIndex].x = gDragStartCenter.x + (now.x - gDragStartPoint.x);
        gPaneCenters[paneIndex].y = gDragStartCenter.y + (now.y - gDragStartPoint.y);

        // Keep at least 40pt of the pane visible on each axis.
        CGFloat w = thePane.bounds.size.width;
        CGFloat h = thePane.bounds.size.height;
        CGFloat minVisible = 40;
        CGFloat minX = minVisible - w / 2.0;
        CGFloat maxX = parent.bounds.size.width - minVisible + w / 2.0;
        CGFloat minY = minVisible - h / 2.0;
        CGFloat maxY = parent.bounds.size.height - minVisible + h / 2.0;
        if (gPaneCenters[paneIndex].x < minX) gPaneCenters[paneIndex].x = minX;
        if (gPaneCenters[paneIndex].x > maxX) gPaneCenters[paneIndex].x = maxX;
        if (gPaneCenters[paneIndex].y < minY) gPaneCenters[paneIndex].y = minY;
        if (gPaneCenters[paneIndex].y > maxY) gPaneCenters[paneIndex].y = maxY;

        thePane.center = gPaneCenters[paneIndex];
        gPaneBaseFrames[paneIndex] = thePane.frame;
        LayoutToolbarForPane(paneIndex);
    } else if (gesture.state == UIGestureRecognizerStateEnded ||
               gesture.state == UIGestureRecognizerStateCancelled) {
        SavePaneLayoutState();
        CLog(@"drag: pane[%d] handle-drag ended center={%.0f,%.0f}", paneIndex,
             gPaneCenters[paneIndex].x, gPaneCenters[paneIndex].y);
    }
}

- (void)handlePanePress:(UILongPressGestureRecognizer *)gesture
{
    UIView *pane = gesture.view;
    if (!pane) return;

    // The gesture may be attached to the pane itself (empty/black area) or
    // to its hosted appView (remote scene view). Walk up until we find the
    // pane the touch belongs to.
    int paneIndex = -1;
    UIView *probe = pane;
    while (probe) {
        for (int i = 0; i < MAX_PANES; i++) {
            if (gPanes[i] == probe) { paneIndex = i; break; }
        }
        if (paneIndex >= 0) break;
        probe = probe.superview;
    }
    if (paneIndex < 0 || gPaneClosed[paneIndex]) return;

    // Always operate on the REAL pane, never the gesture's attached view
    // (which may be the hosted appView): parent = pane's coordinate space,
    // and pane size comes from the pane itself.
    UIView *thePane = gPanes[paneIndex];
    UIView *parent = thePane.superview;
    if (!thePane || !parent) return;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        SelectPane(paneIndex);
        gDragStartCenter = gPaneCenters[paneIndex];
        gDragStartPoint = [gesture locationInView:parent];
        CLog(@"drag: pane[%d] long-press began (selected)", paneIndex);
    } else if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint now = [gesture locationInView:parent];
        gPaneCenters[paneIndex].x = gDragStartCenter.x + (now.x - gDragStartPoint.x);
        gPaneCenters[paneIndex].y = gDragStartCenter.y + (now.y - gDragStartPoint.y);

        // Keep at least 40pt of the pane visible on each axis.
        CGFloat w = thePane.bounds.size.width;
        CGFloat h = thePane.bounds.size.height;
        CGFloat minVisible = 40;
        CGFloat minX = minVisible - w / 2.0;
        CGFloat maxX = parent.bounds.size.width - minVisible + w / 2.0;
        CGFloat minY = minVisible - h / 2.0;
        CGFloat maxY = parent.bounds.size.height - minVisible + h / 2.0;
        if (gPaneCenters[paneIndex].x < minX) gPaneCenters[paneIndex].x = minX;
        if (gPaneCenters[paneIndex].x > maxX) gPaneCenters[paneIndex].x = maxX;
        if (gPaneCenters[paneIndex].y < minY) gPaneCenters[paneIndex].y = minY;
        if (gPaneCenters[paneIndex].y > maxY) gPaneCenters[paneIndex].y = maxY;

        thePane.center = gPaneCenters[paneIndex];
        gPaneBaseFrames[paneIndex] = thePane.frame;
        LayoutToolbarForPane(paneIndex);
    } else if (gesture.state == UIGestureRecognizerStateEnded ||
               gesture.state == UIGestureRecognizerStateCancelled) {
        SavePaneLayoutState();
        CLog(@"drag: pane[%d] ended center={%.0f,%.0f}", paneIndex,
             gPaneCenters[paneIndex].x, gPaneCenters[paneIndex].y);
    }
}

// Zoom slider: continuous, absolute zoom for the current pane.
- (void)zoomSliderChanged:(UISlider *)slider
{
    if (gCurrentPane < 0) return;
    SetPaneZoom(gCurrentPane, slider.value);
}

// Reset (⟲): restore the current pane to its default (pre-zoom) size.
- (void)resetZoomTapped:(UIButton *)sender
{
    if (gCurrentPane < 0) return;
    if (gPaneZoom[gCurrentPane] == 1.0f) return;
    CLog(@"zoom: pane[%d] reset to 1.0", gCurrentPane);
    SetPaneZoom(gCurrentPane, 1.0f);
}

- (void)handleCapsuleDrag:(UIPanGestureRecognizer *)gesture
{
    UIButton *capsule = (UIButton *)gesture.view;
    if (!capsule) return;

    // Find which pane index this capsule belongs to.
    int paneIndex = -1;
    for (int i = 0; i < MAX_PANES; i++) {
        if (gCapsules[i] == capsule) { paneIndex = i; break; }
    }
    if (paneIndex < 0) return;

    // 0.1.59: once the user drags a capsule it leaves its docked slot for the
    // rest of the session (reset next time the pane is reopened and closed
    // again, or on reconnect).
    gCapsuleDetached[paneIndex] = YES;

    UIView *parent = capsule.superview;
    if (!parent) return;

    if (gesture.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gesture translationInView:parent];
        CGPoint center = capsule.center;
        center.x += translation.x;
        center.y += translation.y;

        // Clamp so the capsule stays fully visible within the parent.
        CGFloat halfW = capsule.bounds.size.width / 2.0;
        CGFloat halfH = capsule.bounds.size.height / 2.0;
        if (center.x < halfW) center.x = halfW;
        if (center.x > parent.bounds.size.width - halfW) center.x = parent.bounds.size.width - halfW;
        if (center.y < halfH) center.y = halfH;
        if (center.y > parent.bounds.size.height - halfH) center.y = parent.bounds.size.height - halfH;

        capsule.center = center;
        [gesture setTranslation:CGPointZero inView:parent];
    }
}

- (void)closeButtonTapped:(UIButton *)sender
{
    // 0.1.57: every pane has its own ×; close the pane this button belongs to.
    int paneIndex = (int)sender.tag;
    if (paneIndex < 0 || paneIndex >= MAX_PANES) return;

    CLog(@"close: pane[%d] minimized by user", paneIndex);

    // Hide the pane but DON'T tear down the slot — just stand it down
    // from Live (mode 0) so it won't crash while hidden. The capsule
    // lets the user restore it later.
    UIView *pane = gPanes[paneIndex];
    if (pane) pane.hidden = YES;
    if (gPaneToolbars[paneIndex]) gPaneToolbars[paneIndex].hidden = YES;
    gPaneClosed[paneIndex] = YES;

    // Stand the controller down from Live (safe, crash-proof).
    SlotSetMode(paneIndex, 0);

    // 0.1.59: re-closing the app docks its capsule back into the top row.
    gCapsuleDetached[paneIndex] = NO;

    // Persist the closed state so a re-connect restores it.
    SavePaneLayoutState();

    // Show the capsule docked at this pane's fixed top-row slot.
    LayoutCapsuleForPane(paneIndex);

    // No current pane any more.
    SelectPane(-1);
}

- (void)capsuleTapped:(UIButton *)sender
{
    // Find which pane index this capsule belongs to.
    int paneIndex = -1;
    for (int i = 0; i < MAX_PANES; i++) {
        if (gCapsules[i] == sender) { paneIndex = i; break; }
    }
    if (paneIndex < 0) return;

    CLog(@"restore: pane[%d] restored from capsule", paneIndex);

    // 0.1.49: never go Live while the phone is unlocked on the CAR display.
    // 0.1.53: phone test mode always restores immediately — it hosts on the
    // phone screen and initial hosting already runs Live while unlocked.
    if (!gTestMode && gLockStateKnown && !gPhoneLocked) {
        CLog(@"restore: pane[%d] deferred — phone unlocked", paneIndex);
        // Keep the pane hidden (avoid a black box) and the capsule visible;
        // the restore runs on the next lock (see gPendingRestoreIndex).
        // 0.1.58: visible feedback so the defer never looks like a dead tap.
        gPendingRestoreIndex = paneIndex;
        gPaneClosed[paneIndex] = YES;
        SavePaneLayoutState();
        ShowToast(@"手机解锁中，锁屏后恢复");
        return;
    }

    // Hide the capsule.
    sender.hidden = YES;

    // Show the pane.
    UIView *pane = gPanes[paneIndex];
    if (pane) pane.hidden = NO;
    if (gPaneToolbars[paneIndex]) gPaneToolbars[paneIndex].hidden = NO;
    gPaneClosed[paneIndex] = NO;
    SavePaneLayoutState();

    // Restore the slot to Live mode.
    RestoreSlot(paneIndex);

    // The restored pane becomes the current pane so the controls strip is
    // immediately usable.
    SelectPane(paneIndex);
}

// 0.1.58: manual-start gate — tap begins hosting all panes (respecting the
// never-Live-while-unlocked policy: if the phone is unlocked the request is
// remembered and runs on the next lock, with a toast so the tap never looks
// dead).
- (void)startButtonTapped:(UIButton *)sender
{
    CLog(@"ui: manual start tapped");
    gManualAwaitingStart = NO;
    if (gStartButton) gStartButton.hidden = YES;
    if (gLockStateKnown && !gPhoneLocked) {
        gPendingShow = 2;
        ShowToast(@"手机解锁中，锁屏后恢复");
        CLog(@"ui: manual start deferred — phone unlocked");
        return;
    }
    RestoreNow();
}

@end

static DashSplitDragHandler *gDragHandler;

// 0.1.56: attach the pane long-press drag gesture to a view. Used for BOTH
// the pane itself and its hosted appView (see HostApplication) so every pixel
// of a pane — including real app content — can start a drag. When the gesture
// fires, its default cancelsTouchesInView stops that touch from reaching the
// app; plain taps still pass through.
static void AttachPaneDragGesture(UIView *target)
{
    if (!target) return;
    if (!gDragHandler) gDragHandler = [DashSplitDragHandler new];
    UILongPressGestureRecognizer *press =
        [[UILongPressGestureRecognizer alloc] initWithTarget:gDragHandler
                                                     action:@selector(handlePanePress:)];
    press.minimumPressDuration = 0.3;
    press.allowableMovement = 500.0;
    [target addGestureRecognizer:press];
}

// 0.1.57: the zoom slider's max is dynamic so dragging it fully ALWAYS makes
// the pane fill (and overflow) the screen — 4× of a tiny default ratio is
// nowhere near "maximum". At least 4×, capped at 12× as a sanity limit.
static CGFloat PaneMaxZoom(int index)
{
    UIView *host = (gTestMode && gTestContainer) ? gTestContainer : gWindow;
    CGRect bounds = host ? host.bounds : CGRectZero;
    if (bounds.size.width <= 0) bounds.size.width = 1;
    if (bounds.size.height <= 0) bounds.size.height = 1;
    CGFloat baseUnit = floor(bounds.size.width / 5.0);
    CGFloat rawW = MAX(AppRatioForIndex(index) * baseUnit * AppScaleForIndex(index), 60);
    CGFloat rawH = MAX(bounds.size.height * AppScaleForIndex(index), 60);
    CGFloat need = MAX(bounds.size.width / rawW, bounds.size.height / rawH);
    CGFloat maxZ = ceil(need * 1.2);  // 20% overflow so "max" always overshoots
    if (maxZ < 4.0) maxZ = 4.0;
    if (maxZ > 12.0) maxZ = 12.0;
    return maxZ;
}

// 0.1.55: mark a pane as the "current" one for the single right-edge strip.
// Highlights its border and syncs the strip's label/slider/button state.
static void SelectPane(int index)
{
    gCurrentPane = index;
    for (int i = 0; i < MAX_PANES; i++) {
        if (!gPanes[i]) continue;
        BOOL isCurrent = (i == index);
        gPanes[i].layer.borderWidth = isCurrent ? 2.0 : 1.0;
        gPanes[i].layer.borderColor = isCurrent
            ? [UIColor colorWithWhite:1.0 alpha:0.9].CGColor
            : [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
    }
    if (gControlLabel) {
        if (index >= 0 && index < MAX_PANES && gPanes[index]) {
            NSString *name = AppDisplayName(HostBundleIDForIndex(index));
            gControlLabel.text = name.length ? name : @"App";
            gControlLabel.textColor = [UIColor whiteColor];
        } else {
            gControlLabel.text = @"长按\n选中";
            gControlLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
        }
    }
    BOOL usable = (index >= 0 && index < MAX_PANES && gPanes[index] && !gPaneClosed[index]);
    if (gZoomSlider) {
        gZoomSlider.enabled = usable;
        if (usable) {
            gZoomSlider.maximumValue = PaneMaxZoom(index);
            gZoomSlider.value = gPaneZoom[index];
        }
    }
    if (gResetButton) gResetButton.enabled = usable;
    if (gCloseButton) gCloseButton.enabled = usable;
}

// Zoom a pane to an absolute factor around its fixed center anchor, then
// re-fit and persist. The max is dynamic (see PaneMaxZoom) so pulling the
// slider all the way genuinely fills/overshoots the screen.
static void SetPaneZoom(int index, CGFloat zoom)
{
    if (index < 0 || index >= MAX_PANES) return;
    if (zoom < 0.2f) zoom = 0.2f;
    CGFloat maxZ = PaneMaxZoom(index);
    if (zoom > maxZ) zoom = maxZ;
    if (fabs(zoom - gPaneZoom[index]) < 0.001f) return;
    CLog(@"zoom: pane[%d] -> %.2f", index, zoom);
    gPaneZoom[index] = zoom;
    Layout();
    @try {
        HostSlot *slot = gSlots[index];
        if (slot && slot.viewController) {
            UIView *appView = Call0(slot.viewController, @"view");
            FitAppViewToContainer(appView, slot.container);
        }
    } @catch (NSException *e) {
        CLog(@"zoom: re-fit threw %@", e.reason);
    }
    SavePaneLayoutState();
    if (gZoomSlider && index == gCurrentPane) gZoomSlider.value = zoom;
}

// Position the single right-edge controls strip, in screen-window coords
// (the strip is a direct subview of the window, never the rotated container).
static void LayoutControls(CGRect bounds)
{
    if (!gControlStrip) return;
    CGFloat stripW = 36;
    CGFloat stripH = 330;
    gControlStrip.frame = CGRectMake(bounds.size.width - stripW - 6,
                                     floor((bounds.size.height - stripH) / 2.0),
                                     stripW, stripH);
    if (gControlLabel) gControlLabel.frame = CGRectMake(0, 8, stripW, 34);
    if (gZoomSlider) {
        // Rotated frame: width is the visual height. Center it under the label.
        gZoomSlider.center = CGPointMake(stripW / 2.0, 60 + 170 / 2.0);
    }
    // 0.1.57: the × moved onto each pane; the right-edge strip keeps
    // label + zoom slider + reset only.
    CGFloat y = 60 + 170 + 6;
    if (gResetButton) { gResetButton.frame = CGRectMake(8, y, stripW - 16, 48); y += 54; }
}

#pragma mark - Pane layout persistence

// Persist each pane's center anchor (as fractions of the host size, so a
// different-resolution head unit restores proportionally), zoom factor, and
// closed state. Keys are indexed by pane position, and re-read on the next
// interface build (CreateInterface -> LoadPaneLayoutState). Only the panes
// that exist this session are written; stale keys for removed panes are
// harmless (LoadPaneLayoutState ignores indices >= PaneCount()).
static void SavePaneLayoutState(void)
{
    if (!gWindow) return;

    UIView *host = (gTestMode && gTestContainer) ? gTestContainer : gWindow;
    CGFloat w = host.bounds.size.width;
    CGFloat h = host.bounds.size.height;
    if (w <= 0 || h <= 0) w = h = 1.0;

    int count = PaneCount();
    for (int index = 0; index < count; index++) {
        NSString *kX = [NSString stringWithFormat:@"PaneCenterX%d", index];
        NSString *kY = [NSString stringWithFormat:@"PaneCenterY%d", index];
        NSString *kZ = [NSString stringWithFormat:@"PaneZoom%d", index];
        NSString *kC = [NSString stringWithFormat:@"PaneClosed%d", index];

        // Normalize centers to fractions of the screen.
        CFPreferencesSetAppValue((__bridge CFStringRef)kX,
                                 (__bridge CFNumberRef)@(gPaneCenters[index].x / w),
                                 CFSTR("zp.dashsplit"));
        CFPreferencesSetAppValue((__bridge CFStringRef)kY,
                                 (__bridge CFNumberRef)@(gPaneCenters[index].y / h),
                                 CFSTR("zp.dashsplit"));
        CFPreferencesSetAppValue((__bridge CFStringRef)kZ,
                                 (__bridge CFNumberRef)@(gPaneZoom[index]),
                                 CFSTR("zp.dashsplit"));
        // 0.1.54: test mode never persists the closed state — every test
        // session opens all panes so a stale capsule row can't look like a
        // hosting failure. Car mode keeps its own closed-state persistence.
        if (!gTestMode) {
            CFPreferencesSetAppValue((__bridge CFStringRef)kC,
                                     gPaneClosed[index] ? kCFBooleanTrue : kCFBooleanFalse,
                                     CFSTR("zp.dashsplit"));
        }
    }
    CFPreferencesAppSynchronize(CFSTR("zp.dashsplit"));
    CLog(@"ui: pane layout saved (%d panes)", count);
}

// Restore per-pane layout from the persisted prefs. Called from
// CreateInterface right after the panes are created (before Layout), so the
// restored offsets/zooms/closed states are applied to the fresh interface.
static void LoadPaneLayoutState(void)
{
    if (!gWindow) return;

    UIView *host = (gTestMode && gTestContainer) ? gTestContainer : gWindow;
    CGFloat w = host.bounds.size.width;
    CGFloat h = host.bounds.size.height;
    if (w <= 0 || h <= 0) w = h = 1.0;

    // 0.1.54: if the selected apps changed since the last layout was saved,
    // the per-pane centers/zooms/closed states (indexed by pane POSITION,
    // not by app) no longer describe this lineup — e.g. a pane the user
    // closed before would reappear as a capsule under a different app and
    // look like "the split never showed up". Reset everything so the new
    // selection starts fresh with every pane visible (default centers are
    // set by CreateInterface and left untouched here).
    NSArray *currentIDs = SelectedBundleIDs();
    NSString *joined = [currentIDs componentsJoinedByString:@","];
    NSString *lastJoined = PrefString(kPrefsLastSelectedApps);
    if (lastJoined.length && ![lastJoined isEqualToString:joined]) {
        // Wipe the stale per-pane layout keys so nothing leaks back later.
        for (int index = 0; index < MAX_PANES; index++) {
            CFPreferencesSetAppValue((__bridge CFStringRef)[NSString stringWithFormat:@"PaneCenterX%d", index], NULL, CFSTR("zp.dashsplit"));
            CFPreferencesSetAppValue((__bridge CFStringRef)[NSString stringWithFormat:@"PaneCenterY%d", index], NULL, CFSTR("zp.dashsplit"));
            CFPreferencesSetAppValue((__bridge CFStringRef)[NSString stringWithFormat:@"PaneZoom%d", index], NULL, CFSTR("zp.dashsplit"));
            CFPreferencesSetAppValue((__bridge CFStringRef)[NSString stringWithFormat:@"PaneClosed%d", index], NULL, CFSTR("zp.dashsplit"));
            gPaneZoom[index] = 1.0f;
            gPaneClosed[index] = NO;
            gCapsuleDetached[index] = NO;
        }
        CFPreferencesAppSynchronize(CFSTR("zp.dashsplit"));
        CLog(@"ui: selected apps changed (was %@, now %@) — layout reset", lastJoined, joined);
        return;
    }

    // Remember the current lineup for the next comparison.
    CFPreferencesSetAppValue((__bridge CFStringRef)kPrefsLastSelectedApps,
                             (__bridge CFStringRef)joined,
                             CFSTR("zp.dashsplit"));
    CFPreferencesAppSynchronize(CFSTR("zp.dashsplit"));

    CGFloat sideMargin = floor(w / 26.0);
    CGFloat baseUnit = floor(w / 5.0);
    CGFloat paneHeight = h;

    int count = PaneCount();
    for (int index = 0; index < count; index++) {
        NSString *kX = [NSString stringWithFormat:@"PaneCenterX%d", index];
        NSString *kY = [NSString stringWithFormat:@"PaneCenterY%d", index];
        NSString *kZ = [NSString stringWithFormat:@"PaneZoom%d", index];
        NSString *kC = [NSString stringWithFormat:@"PaneClosed%d", index];

        id vX = Pref(kX);
        id vY = Pref(kY);
        id vZ = Pref(kZ);
        id vC = Pref(kC);

        CGFloat cx = 0, cy = 0;
        BOOL hasCenter = [vX isKindOfClass:[NSNumber class]] && [vY isKindOfClass:[NSNumber class]];
        if (hasCenter) {
            cx = [(NSNumber *)vX doubleValue] * w;
            cy = [(NSNumber *)vY doubleValue] * h;
        } else {
            // 0.1.55 migration: the old PaneOffsetX/Y stored an offset added
            // to the default base frame. Convert it into an absolute center
            // anchor (using the restored zoom, same formula as old Layout).
            CGFloat zoom = [vZ isKindOfClass:[NSNumber class]] ? [(NSNumber *)vZ doubleValue] : 1.0f;
            CGFloat ratio = AppRatioForIndex(index);
            CGFloat scale = AppScaleForIndex(index);
            CGFloat w0 = MAX(ratio * baseUnit * scale * zoom, 60);
            CGFloat h0 = MAX(paneHeight * scale * zoom, 60);
            CGFloat baseX = sideMargin + index * (w0 + 12);
            CGFloat baseY = (paneHeight - h0) / 2.0;
            CGFloat ox = PrefDouble([NSString stringWithFormat:@"PaneOffsetX%d", index], 0) * w;
            CGFloat oy = PrefDouble([NSString stringWithFormat:@"PaneOffsetY%d", index], 0) * h;
            cx = baseX + w0 / 2.0 + ox;
            cy = baseY + h0 / 2.0 + oy;
            // Remove the legacy keys on migration.
            CFPreferencesSetAppValue((__bridge CFStringRef)[NSString stringWithFormat:@"PaneOffsetX%d", index], NULL, CFSTR("zp.dashsplit"));
            CFPreferencesSetAppValue((__bridge CFStringRef)[NSString stringWithFormat:@"PaneOffsetY%d", index], NULL, CFSTR("zp.dashsplit"));
        }

        CGFloat zoom = [vZ isKindOfClass:[NSNumber class]] ? [(NSNumber *)vZ doubleValue] : 1.0f;
        BOOL closed = [vC isKindOfClass:[NSNumber class]] ? [(NSNumber *)vC boolValue] : NO;
        // 0.1.54: test mode always opens every pane — a stale closed state
        // from an earlier test session must not hide panes in the test
        // window (it showed only capsules and looked like a failure).
        if (gTestMode) closed = NO;

        if (hasCenter) gPaneCenters[index] = CGPointMake(cx, cy);
        gPaneZoom[index] = zoom;
        if (gPaneZoom[index] < 0.2f) gPaneZoom[index] = 0.2f;
        CGFloat paneMaxZ = PaneMaxZoom(index);
        if (gPaneZoom[index] > paneMaxZ) gPaneZoom[index] = paneMaxZ;
        gPaneClosed[index] = closed;

        if (hasCenter || zoom != 1.0f || closed) {
            CLog(@"ui: pane[%d] restored center={%.2f,%.2f} zoom=%.2f closed=%d",
                 index, gPaneCenters[index].x, gPaneCenters[index].y, gPaneZoom[index], gPaneClosed[index]);
        }
    }
}

// Toggle button removed — SetToggleGlyph is now a no-op kept for compatibility.
static void SetToggleGlyph(NSString *glyph)
{
    // No-op: toggle button no longer exists.
}

// 0.1.27: the hide half of the toggle, extracted so the phone-unlock
// listener runs the IDENTICAL sequence the user manually verified as
// crash-proof (panes hidden + every controller stood down to mode 0 BEFORE
// any phone-side app can background our scenes).
static void HidePanesAndStandDown(NSString *why)
{
    int count = PaneCount();
    gUserClosed = YES;
    // Disable the UIScreen bounds hook so the system and other apps get
    // the real screen bounds while our panes are hidden.
    gNativeFillActive = NO;
for (int index = 0; index < count; index++) {
if (gPanes[index]) gPanes[index].hidden = YES;
if (gCapsules[index]) gCapsules[index].hidden = YES;
if (gPaneToolbars[index]) gPaneToolbars[index].hidden = YES;
}
for (int i = 0; i < MAX_PANES; i++) if (gDividers[i]) gDividers[i].hidden = YES;
SetToggleGlyph(@"⟳");
    // Show the "请锁屏手机后显示" hint banner.
    if (gLockHintLabel) gLockHintLabel.hidden = NO;
    for (int index = 0; index < count; index++) {
        SlotSetMode(index, 0);
    }
    CLog(@"ui: overlay hidden (%@) — hosting kept alive", why);
}

// 0.1.49: Stand down all Live controllers without setting gUserClosed,
// and hide panes + dividers but leave capsules alone. Called on phone
// unlock — ShowAllCapsules runs right after to make the capsule row visible.
static void StandDownForUnlock(NSString *why)
{
    int count = PaneCount();
    gNativeFillActive = NO;
    for (int index = 0; index < count; index++) {
        if (gPanes[index]) gPanes[index].hidden = YES;
        if (gPaneToolbars[index]) gPaneToolbars[index].hidden = YES;
    }
    for (int i = 0; i < MAX_PANES; i++) if (gDividers[i]) gDividers[i].hidden = YES;
    for (int index = 0; index < count; index++) {
        SlotSetMode(index, 0);
    }
    CLog(@"ui: stood down for unlock (%@)", why);
}

// 0.1.59: close every pane and dock all capsules in a fixed row at the top
// of the car screen (locked state / CarPlay connect while locked) — gives the
// user a row of app-name capsules to tap, opening each app on demand.
static void ShowAllCapsules(void)
{
    int count = PaneCount();
    if (!gWindow || count == 0) return;

    for (int i = 0; i < count; i++) {
        gPaneClosed[i] = YES;   // every pane comes up as a capsule
        if (gPanes[i]) gPanes[i].hidden = YES;
        if (gPaneToolbars[i]) gPaneToolbars[i].hidden = YES;
        SlotSetMode(i, 0);
    }

    // Hide dividers.
    for (int i = 0; i < MAX_PANES; i++) if (gDividers[i]) gDividers[i].hidden = YES;

    // Hide lock hint label — capsules replace it.
    if (gLockHintLabel) gLockHintLabel.hidden = YES;

    // Dock the row; capsules the user dragged away stay where they were put.
    LayoutCapsuleRow();

    CLog(@"ui: capsule row shown (%d apps)", count);
}

static void RestoreSlot(int index)
{
    HostSlot *slot = gSlots[index];
    
    // 0.1.49: If no slot was ever created for this pane (capsule was shown
    // without prior hosting), host the app for the first time now.
    if (!slot) {
        NSString *bid = HostBundleIDForIndex(index);
        if (bid.length == 0) return;
        CLog(@"restore[%d]: no slot yet — first host of %@", index, bid);
        gSlots[index] = HostApplication(bid, gPanes[index], index);
        return;
    }
    
    id scene = slot.handle ? Call0(slot.handle, @"sceneIfExists") : nil;
    BOOL active = BoolReturn(scene, @"isActive", NO);
    CLog(@"restore[%d]: %@ scene=%@ active=%d",
         index, slot.bundleID,
         scene ? NSStringFromClass([scene class]) : @"(nil)", active);
    
    if (scene && slot.viewController) {
        slot.suppressed = 0;
        ReactivateSlot(index);
        return;
    }
    
    // Scene was destroyed while hidden — re-host from scratch. No retry cap:
    // this only runs on an explicit user tap, and lastRehost still rate-limits
    // it against the health check's attempts.
    slot.rehostCount++;
    slot.lastRehost = CFAbsoluteTimeGetCurrent();
    CLog(@"restore[%d]: scene gone, re-hosting (#%d)", index, slot.rehostCount);
    TeardownSlot(slot);
    gSlots[index] = HostApplication(slot.bundleID, slot.container, index);
}

// Host the configured apps into the already-created panes. Deduplicate: if
// the same app appears in multiple panes, only host it once (first occurrence
// wins — one app cannot drive two scenes at once). Extracted from
// CreateInterface so StartNow can run the exact same sequence.
static void HostAllPanes(BOOL testMode)
{
    int count = PaneCount();
    NSArray *bidArr = SelectedBundleIDs();
    
    NSMutableString *hostLog = [NSMutableString string];
    for (int index = 0; index < count; index++) {
        if (index > 0) [hostLog appendString:@" + "];
        [hostLog appendString:bidArr[index]];
    }
    CLog(@"ui: hosting %@ in %@", hostLog, testMode ? @"phone test mode" : @"car mode");
    
    NSMutableArray *seenBIDs = [NSMutableArray array];
    for (int index = 0; index < count; index++) {
        NSString *bid = HostBundleIDForIndex(index);
        if (bid.length == 0) continue;
        if ([seenBIDs containsObject:bid]) {
            CLog(@"ui: pane %d set to %@ (duplicate, skipping)", index, bid);
            continue;
        }
        [seenBIDs addObject:bid];
        gSlots[index] = HostApplication(bid, gPanes[index], index);
    }
}

static void ShowPanes(void)
{
    int count = PaneCount();
    for (int index = 0; index < count; index++) {
        // Don't show panes that were individually closed via × —
        // they stay hidden with their capsule visible.
        if (gPaneClosed[index]) {
            if (gPanes[index]) gPanes[index].hidden = YES;
            if (gPaneToolbars[index]) gPaneToolbars[index].hidden = YES;
            continue;
        }
        if (gPanes[index]) gPanes[index].hidden = NO;
        if (gPaneToolbars[index]) gPaneToolbars[index].hidden = NO;
    }
    for (int i = 0; i < MAX_PANES; i++) if (gDividers[i]) gDividers[i].hidden = NO;
    if (gLockHintLabel) gLockHintLabel.hidden = YES;
    SetToggleGlyph(@"✕");
}

// 0.1.23: begin hosting on the user's signal. Called from the toggle's start
// branch (tap after the settle window) or from Tick (deferred tap whose
// window has now passed). Hosting only ever starts AFTER the connect wave,
// so the uncatchable foreground assertion never finds a Live controller.
static void StartNow(void)
{
    gAwaitingStart = NO;
    gPendingStart = NO;
    ShowPanes();
    CLog(@"ui: split view starting (hosting now)");
    HostAllPanes(NO);
}

// 0.1.28: the restore half of the toggle, extracted so a restore deferred
// from an unlocked moment can run when the phone next locks.
// 0.1.52: also the CarPlay-connect restore path — open panes are shown and
// re-hosted, closed panes get their capsule repositioned at the pane center.
static void RestoreNow(void)
{
    gUserClosed = NO;
    int count = PaneCount();
    int closedCount = 0;
    for (int index = 0; index < count; index++) {
        // Don't show panes that were individually closed via × —
        // they stay hidden with their capsule visible.
        if (gPaneClosed[index]) {
            if (gPanes[index]) gPanes[index].hidden = YES;
            if (gPaneToolbars[index]) gPaneToolbars[index].hidden = YES;
            closedCount++;
            continue;
        }
        if (gPanes[index]) gPanes[index].hidden = NO;
        if (gPaneToolbars[index]) gPaneToolbars[index].hidden = NO;
    }
    for (int i = 0; i < MAX_PANES; i++) if (gDividers[i]) gDividers[i].hidden = NO;
    if (gLockHintLabel) gLockHintLabel.hidden = YES;
    SetToggleGlyph(@"✕");
    for (int index = 0; index < count; index++) {
        if (gPaneClosed[index]) {
            // Slot was stood down to mode 0 by closeButtonTapped.
            // Don't restore to Live while the pane is hidden — just
            // re-show its capsule docked at the top-row slot.
            continue;
        }
        RestoreSlot(index);
    }
    // One pass relayouts every closed pane's capsule at its fixed slot.
    LayoutCapsuleRow();
    CLog(@"ui: overlay restored (%d panes, %d closed)", count, closedCount);
}

@interface DashSplitControl : NSObject
- (void)toggleTapped;
@end

@implementation DashSplitControl

- (void)toggleTapped
{
    // In test mode the ✕ button closes the test entirely (writes the
    // preference OFF and tears down the overlay) instead of just
    // hide/toggle. The user explicitly wants to exit the preview.
    if (gTestMode) {
        CFPreferencesSetAppValue(CFSTR("TestOnMainScreen"),
                                 kCFBooleanFalse,
                                 CFSTR("zp.dashsplit"));
        CFPreferencesAppSynchronize(CFSTR("zp.dashsplit"));
        TeardownAllHosts();
        gWindow.hidden = YES;
        gWindow = nil;
for (int i = 0; i < MAX_PANES; i++) { gPanes[i] = nil; gDragHandles[i] = nil; gCloseButtons[i] = nil; gPaneToolbars[i] = nil; gPaneBaseFrames[i] = CGRectZero; gPaneZoom[i] = 1.0f; gPaneCenters[i] = CGPointZero; }
for (int i = 0; i < MAX_PANES; i++) gDividers[i] = nil;
gTestContainer = nil;
gToggleButton = nil;
gLockHintLabel = nil;
gStartButton = nil;
gToastLabel = nil;
[gControlStrip removeFromSuperview];
gControlStrip = nil;
gControlLabel = nil;
gZoomSlider = nil;
gResetButton = nil;
gCloseButton = nil;
gCurrentPane = -1;
        gCurrentPaneCount = 0;
        gTestMode = NO;
        gTestLandscape = NO;
        gUserClosed = NO;
        CLog(@"ui: test mode closed by user via ✕ button");
        return;
    }

    // 0.1.49: gAwaitingStart is no longer set — auto-start replaces the
    // old toggle-button gate. This branch is kept as a defensive fallback.
    if (gAwaitingStart) {
        gAwaitingStart = NO;
        CLog(@"ui: gAwaitingStart was unexpectedly YES — auto-starting now");
        if (gLockStateKnown && !gPhoneLocked) {
            gPendingShow = 1;
            CLog(@"ui: start requested but phone unlocked — deferred until the phone locks");
            return;
        }
        StartNow();
        return;
    }
    if (!gUserClosed) {
        // Hide the panes but keep the window and button alive so the user can
        // tap again to restore. Stand the controllers down from Live first —
        // a controller holding Live while its scene gets occluded is the
        // classic foreground-consistency crash trigger (0.0.19 knew this).
        HidePanesAndStandDown(@"hidden by user");
    } else {
        // 0.1.28: same never-Live-while-unlocked gate for restores.
        if (gLockStateKnown && !gPhoneLocked) {
            gPendingShow = 2;
            CLog(@"ui: restore requested but phone unlocked — deferred until the phone locks");
            return;
        }
        RestoreNow();
    }
}

@end

static DashSplitControl *gControl;

#pragma mark - Phone lock state

// 0.1.27: SpringBoard posts the com.apple.springboard.lockstate Darwin
// note on every lock AND unlock, carrying the new state readable via
// notify_get_state (1 = locked, 0 = unlocked). Subscribing is a plain event
// listener — no method is hooked, so nothing here can destabilize the host
// process. On unlock we stand the split view down (the user-verified
// crash-proof state) BEFORE the user can open any phone app that would
// background our Live scenes. Lock events intentionally do nothing: no
// auto-show, and auto-lock while driving must not blank the car panes.
static void HandleLockStateChanged(int token)
{
    uint64_t locked = 1;
    notify_get_state(token, &locked);
    gPhoneLocked = (locked != 0);
    if (gPhoneLocked) {
        CLog(@"lock: phone locked — leaving the split view as-is");
        // 0.1.58: while the manual-start gate is waiting, the interface has
        // nothing hosted and nothing to restore — just wait for the tap.
        if (gManualAwaitingStart) return;
        // 0.1.28: a start/restore the user requested while the phone was
        // unlocked is now safe to run (never-Live-while-unlocked policy).
        // 0.1.53: a capsule restore deferred while unlocked (gPendingRestoreIndex).
        if (gPendingRestoreIndex >= 0) {
            int idx = gPendingRestoreIndex;
            gPendingRestoreIndex = -1;
            if (gWindow && idx < PaneCount() && gPanes[idx]) {
                CLog(@"lock: running deferred capsule restore for pane[%d]", idx);
                if (gCapsules[idx]) gCapsules[idx].hidden = YES;
                gPanes[idx].hidden = NO;
                if (gPaneToolbars[idx]) gPaneToolbars[idx].hidden = NO;
                gPaneClosed[idx] = NO;
                SavePaneLayoutState();
                RestoreSlot(idx);
                return;
            }
        }
        if (gPendingShow == 1) {
            gPendingShow = 0;
            CLog(@"lock: restoring saved layout (deferred from connect)");
            RestoreNow();
        } else if (gPendingShow == 2) {
            gPendingShow = 0;
            CLog(@"lock: running deferred restore");
            RestoreNow();
        }
        return;
    }
    
    CLog(@"lock: phone unlocked");
    
    // 0.1.49: if auto-start was deferred (gPendingShow == 1), the capsule
    // row hasn't been shown yet. Show it now — capsules have no Live
    // controllers so they're safe while unlocked.
    if (gPendingShow == 1) {
        gPendingShow = 0;
        ShowAllCapsules();
        CLog(@"lock: capsule row shown on unlock (was deferred from connect)");
        return;
    }

    // 0.1.58: manual-start gate waiting — nothing hosted yet, nothing to
    // stand down; the layout stays hidden behind the start button.
    if (gManualAwaitingStart) return;

    // Already hidden (manually or by a previous unlock) or not on the car
    // display — nothing to stand down. Phone test mode never reacts to
    // unlock: it lives on the phone screen and is for debugging only.
    if (!gWindow || gTestMode || gUserClosed) return;
    
    // 0.1.49: stand down all Live controllers (crash safety), then show
    // the capsule row so the car display stays useful while unlocked.
    StandDownForUnlock(@"auto: phone unlocked");
    ShowAllCapsules();
}

static void InstallLockStateObserver(void)
{
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    
    int token = 0;
    uint32_t status = notify_register_dispatch("com.apple.springboard.lockstate",
                                                &token,
                                                dispatch_get_main_queue(),
                                                ^(int t) { HandleLockStateChanged(t); });
    if (status == NOTIFY_STATUS_OK) {
        CLog(@"lock: lockstate observer installed");
        // 0.1.28: query the CURRENT state so the never-Live-while-unlocked
        // gate works from the first tap, without waiting for a lock/unlock
        // event to teach it the state.
        int checkToken = 0;
        if (notify_register_check("com.apple.springboard.lockstate", &checkToken) == NOTIFY_STATUS_OK) {
            uint64_t state = 0;
            notify_get_state(checkToken, &state);
            gPhoneLocked = (state != 0);
            gLockStateKnown = YES;
            CLog(@"lock: initial state locked=%d", gPhoneLocked);
        } else {
            CLog(@"lock: initial-state query failed — unlock gating inactive until first event");
        }
    } else {
        CLog(@"lock: observer registration failed (%u)", status);
    }
}

static void Layout(void)
{
    if (!gWindow) return;
    
    int count = PaneCount();
    if (count == 0) return;
    
    UIView *host = (gTestMode && gTestContainer) ? gTestContainer : gWindow;
    CGRect bounds = host.bounds;
    
    CLog(@"layout: host=%@ bounds=%@ testMode=%d testContainer=%@ count=%d",
         NSStringFromClass([host class]),
         NSStringFromCGRect(bounds),
         gTestMode,
         gTestContainer ? NSStringFromCGRect(gTestContainer.bounds) : @"(nil)",
         count);
    
    // 0.1.51: Fixed pane sizes — each pane gets a fixed width based on its
    // ratio value (not divided by totalRatio). Multiple panes may overlap;
    // the user drags them apart manually. Scale still applies per-app.
    // Base unit: screen width / 5 (so ratio=5 fills the screen width).
    CGFloat baseUnit = floor(bounds.size.width / 5.0);
    CGFloat paneHeight = bounds.size.height;  // full height

    for (int index = 0; index < count; index++) {
        if (gPanes[index]) {
            int ratio = AppRatioForIndex(index);
            CGFloat scale = AppScaleForIndex(index);
            // Fixed width: ratio * baseUnit, then apply scale, then user zoom.
            CGFloat rawW = ratio * baseUnit;
            CGFloat scaledW = floor(rawW * scale * gPaneZoom[index]);
            CGFloat scaledH = floor(paneHeight * scale * gPaneZoom[index]);
            // Guard against zero-size panes (extreme zoom-out).
            if (scaledW < 60) scaledW = 60;
            if (scaledH < 60) scaledH = 60;

            // 0.1.55: every pane scales around its fixed center anchor
            // (gPaneCenters), so zooming never makes the pane drift. The
            // anchor is set by CreateInterface (defaults), moved by dragging,
            // and restored by LoadPaneLayoutState.
            CGPoint anchor = gPaneCenters[index];
            CGRect baseFrame = CGRectMake(anchor.x - scaledW / 2.0,
                                          anchor.y - scaledH / 2.0,
                                          scaledW, scaledH);
            gPaneBaseFrames[index] = baseFrame;

            // Skip closed panes — they're hidden and don't need layout.
            // (baseFrame is still computed so LayoutCapsuleForPane has valid
            //  data for the capsule position.)
            if (gPaneClosed[index]) {
                gPanes[index].hidden = YES;
                continue;
            }

            gPanes[index].frame = baseFrame;
            CLog(@"layout: pane[%d] frame=%@ ratio=%d scale=%.2f zoom=%.2f center={%.0f,%.0f}", index,
                 NSStringFromCGRect(gPanes[index].frame), ratio,
                 scale, gPaneZoom[index], anchor.x, anchor.y);
        }
    }
    
    // 0.1.58: per-pane external toolbars — a sibling of each pane (never a
    // subview), tucked just outside the pane's right edge so no app pixel is
    // covered. Vertically stacked: drag handle on top, close × below.
    // Positioned from the base frame (computed above for closed panes too),
    // so the toolbar stays correct even while the pane itself is hidden.
    for (int index = 0; index < count; index++) {
        LayoutToolbarForPane(index);
    }

    // Toggle button removed from layout for car mode — no longer created.
    // In test mode, position the close button at the top-left.
    if (gToggleButton && gTestMode) {
        UIView *toggleHost = (gTestMode && gTestContainer) ? gTestContainer : gWindow;
        gToggleButton.frame = CGRectMake(8, 8, 48, 48);
        [toggleHost bringSubviewToFront:gToggleButton];
    }

    // 0.1.58: manual-start button, centered on the host.
    if (gStartButton && !gStartButton.hidden) {
        gStartButton.center = CGPointMake(host.bounds.size.width / 2.0,
                                          host.bounds.size.height / 2.0);
        [host bringSubviewToFront:gStartButton];
    }
    
    // 0.1.55: single controls strip pinned to the right edge of the screen.
    // Uses the window bounds so the strip stays on the physical right edge
    // even inside the rotated test container.
    if (gWindow) LayoutControls(gWindow.bounds);
    
    // Lock hint label: centered at the top of the display.
    if (gLockHintLabel) {
        CGFloat hintW = 200;
        CGFloat hintH = 32;
        CGFloat hintX = (bounds.size.width - hintW) / 2.0;
        gLockHintLabel.frame = CGRectMake(hintX, 10, hintW, hintH);
        [host bringSubviewToFront:gLockHintLabel];
    }
}

// A full-screen overlay window attached to SpringBoard's own scene claims
// every touch by default — with the panes hidden, the phone's UI was
// untappable (0.1.11's separate button window never showed up on this
// device either). hitTest now returns nil wherever nothing interactive
// lives, so touches fall through to the UI below; the toggle button (and
// visible panes) still claim their areas.
@interface DashSplitPassthroughWindow : UIWindow
@end

@implementation DashSplitPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

@end

static UIWindow *MakeTestWindow(void)
{
    // Temporarily disable the UIScreen bounds hook while creating the test
    // window — if a previous native-fill session left the hook active with
    // a stale pane size, the new window would be created at that wrong size
    // (observed: {552, 414} instead of {414, 896}).
    BOOL wasHookActive = gNativeFillActive;
    gNativeFillActive = NO;
    
    // Full phone screen; CreateInterface adds a 90-rotated container on top
    // so the panes render in landscape orientation, matching the car display.
    // The user rotates the phone 90 clockwise to see the layout naturally.
    CGRect frame = [UIScreen mainScreen].bounds;
    
    UIWindow *window = nil;
    for (UIScene *scene in [[UIApplication sharedApplication] connectedScenes]) {
        if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
            window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
            break;
        }
    }
    if (!window) {
        window = [[UIWindow alloc] initWithFrame:frame];
    }
    window.frame = frame;
    
    // Restore the hook state if it was active.
    gNativeFillActive = wasHookActive;
    
    CLog(@"test window: class=%@ frame=%@ hookWas=%d", NSStringFromClass([window class]), NSStringFromCGRect(frame), wasHookActive);
    return window;
}

static UIView *MakePane(NSString *title, UIColor *bgColor)
{
    UIView *pane = [[UIView alloc] initWithFrame:CGRectZero];
pane.backgroundColor = bgColor;
pane.userInteractionEnabled = YES;
pane.clipsToBounds = YES;
// Thin border so the pane boundary is visible with a clear background.
pane.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.15].CGColor;
pane.layer.borderWidth = 1.0;
    
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.text = title;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [pane addSubview:label];
    
    return pane;
}

static void CreateInterface(BOOL testMode)
{
    UIWindow *window = testMode ? MakeTestWindow() : MakeCarWindow();
    if (!window) return;
    
    gTestMode = testMode;
    int count = PaneCount();
    gCurrentPaneCount = count;
    window.windowLevel = 9000000;
    window.backgroundColor = [UIColor clearColor];
    window.hidden = NO;
    
    // In test mode, optionally create a rotated container view that
    // simulates a landscape car display. The container is sized to the
    // portrait screen but its bounds are swapped (landscape dimensions),
    // then rotated 90° clockwise and positioned to fill the screen. All
    // panes/dividers/toggle are added to this container so Layout works
    // in landscape coordinates. When TestLandscape is OFF, the container
    // is not rotated and the test preview shows in portrait orientation.
    UIView *addTarget = window;  // default: add directly to window
    if (testMode) {
        BOOL useLandscape = PrefBool(kPrefsTestLandscape, YES);
        gTestLandscape = useLandscape;
        if (useLandscape) {
            CGRect screenBounds = [UIScreen mainScreen].bounds;
            CGFloat portraitW = screenBounds.size.width;
            CGFloat portraitH = screenBounds.size.height;
            // Container's internal coordinate system uses landscape dimensions.
            CGFloat landW = portraitH;
            CGFloat landH = portraitW;
            gTestContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, portraitW, portraitH)];
            gTestContainer.bounds = CGRectMake(0, 0, landW, landH);
            gTestContainer.center = CGPointMake(portraitW / 2.0, portraitH / 2.0);
            gTestContainer.transform = CGAffineTransformMakeRotation(M_PI_2);  // 90° clockwise
            gTestContainer.userInteractionEnabled = YES;
            gTestContainer.clipsToBounds = NO;
            [window addSubview:gTestContainer];
            addTarget = gTestContainer;
            CLog(@"test: rotated container frame=%@ bounds=%@ center=%@",
                 NSStringFromCGRect(gTestContainer.frame),
                 NSStringFromCGRect(gTestContainer.bounds),
                 NSStringFromCGPoint(gTestContainer.center));
        } else {
            CLog(@"test: portrait mode (no rotation)");
        }
    }
    
    // Create panes with clear background (thin border). Reset per-pane state.
    // Default centers lay the panes out side by side; LoadPaneLayoutState
    // restores any saved values (and a SelectedApps change resets layout).
    CGFloat hostW = addTarget.bounds.size.width;
    CGFloat hostH = addTarget.bounds.size.height;
    if (hostW <= 0 || hostH <= 0) { hostW = window.bounds.size.width; hostH = window.bounds.size.height; }
    CGFloat margin = floor(hostW / 26.0);
    CGFloat unitW = floor(hostW / 5.0);
    for (int i = 0; i < MAX_PANES; i++) {
        gPaneBaseFrames[i] = CGRectZero;
        gPaneZoom[i] = 1.0f;
        gPaneClosed[i] = NO;
        if (i < count) {
            CGFloat w0 = MAX(AppRatioForIndex(i) * unitW * AppScaleForIndex(i), 60);
            gPaneCenters[i] = CGPointMake(margin + i * (w0 + 12) + w0 / 2.0, hostH / 2.0);
        } else {
            gPaneCenters[i] = CGPointZero;
        }
    }
    if (!gDragHandler) gDragHandler = [DashSplitDragHandler new];
    // Pane background is clear with a thin border: the old blue underlay
// showed as a border around app content when it didn't fill the pane
// (aspect-fit mode). Now the pane's visible area matches the app's
// actual content — no blue gaps. A 1px border helps the user see
// the pane boundary while dragging.
UIColor *paneColor = [UIColor clearColor];
    NSArray *paneTitles = @[@"加载App……", @"加载App……", @"加载App……"];
    for (int index = 0; index < count; index++) {
        NSString *title = index < paneTitles.count ? paneTitles[index] : @"加载App……";
        gPanes[index] = MakePane(title, paneColor);
        [addTarget addSubview:gPanes[index]];

        // 0.1.55+: a long-press anywhere on the pane selects it as the
        // current pane (for the right-edge strip) AND starts dragging it.
        // 0.1.56: the same gesture is also attached to each pane's hosted
        // appView in HostApplication, so app content long-presses work too.
        // Single taps are never intercepted — they go to the hosted app.
        AttachPaneDragGesture(gPanes[index]);

        // 0.1.58: per-pane external toolbar — a sibling of the pane (added to
        // addTarget, NOT to the pane), tucked outside the pane's right edge so
        // it never covers app content and can't be swallowed by the hosted
        // remote view. Vertically stacked: drag handle on top, close × below.
        // Frames are set by Layout (tag = pane index).
        CGFloat tbBtnH = 40;
        UIView *toolbar = [[UIView alloc] initWithFrame:CGRectZero];
        toolbar.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
        toolbar.layer.cornerRadius = 6;
        toolbar.userInteractionEnabled = YES;
        toolbar.layer.zPosition = 9999;
        toolbar.tag = index;

        UIView *dragHandle = [[UIView alloc] initWithFrame:CGRectMake(0, 0, TOOLBAR_WIDTH, tbBtnH)];
        dragHandle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        dragHandle.layer.cornerRadius = 4;
        dragHandle.userInteractionEnabled = YES;
        dragHandle.tag = index;
        for (int dot = 0; dot < 3; dot++) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 2)];
            line.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.7];
            line.layer.cornerRadius = 1;
            line.center = CGPointMake(TOOLBAR_WIDTH / 2.0, 9 + dot * 9);
            [dragHandle addSubview:line];
        }
        UIPanGestureRecognizer *hPan = [[UIPanGestureRecognizer alloc] initWithTarget:gDragHandler
                                                                               action:@selector(handleDrag:)];
        [dragHandle addGestureRecognizer:hPan];
        [toolbar addSubview:dragHandle];
        gDragHandles[index] = dragHandle;

        UIButton *paneClose = [UIButton buttonWithType:UIButtonTypeCustom];
        paneClose.frame = CGRectMake(0, 0, TOOLBAR_WIDTH, tbBtnH);
        [paneClose setTitle:@"×" forState:UIControlStateNormal];
        [paneClose setTitle:@"×" forState:UIControlStateHighlighted];
        paneClose.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
        [paneClose setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.85] forState:UIControlStateNormal];
        [paneClose setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
        paneClose.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        paneClose.layer.cornerRadius = 4;
        paneClose.tag = index;
        [paneClose addTarget:gDragHandler action:@selector(closeButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        [toolbar addSubview:paneClose];
        gCloseButtons[index] = paneClose;

        [addTarget addSubview:toolbar];
        gPaneToolbars[index] = toolbar;

        // Capsule button: shown when the pane is closed via ×. Displays
        // the app name, is draggable, and tapping it restores the pane.
        // Added to addTarget (the parent view), not the pane itself, so
        // it stays visible when the pane is hidden.
        UIButton *capsule = [UIButton buttonWithType:UIButtonTypeCustom];
        [capsule setTitle:@"App" forState:UIControlStateNormal];
        [capsule setTitle:@"App" forState:UIControlStateHighlighted];
        capsule.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [capsule setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        [capsule setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
        capsule.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.85];
        capsule.layer.cornerRadius = 14;
        capsule.layer.zPosition = 9999;  // above everything
        capsule.hidden = YES;  // hidden until the user closes the pane
        capsule.userInteractionEnabled = YES;
        [capsule addTarget:gDragHandler action:@selector(capsuleTapped:) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *capPan = [[UIPanGestureRecognizer alloc] initWithTarget:gDragHandler
                                                                                   action:@selector(handleCapsuleDrag:)];
        [capsule addGestureRecognizer:capPan];
        [addTarget addSubview:capsule];
        gCapsules[index] = capsule;
        gCapsuleDetached[index] = NO;   // 0.1.59: brand-new capsule starts docked
    }
    
// Create divider lines — removed: panes are now draggable so
// visual separators are no longer needed.
// (gDividers array kept for teardown compatibility but never populated.)
    
    // Toggle button removed — no longer created. The UI is controlled
    // by lock screen auto-show/hide and per-pane × buttons + capsules.
    // In test mode, create a dedicated close button so the user can exit.
    if (testMode && !gControl) gControl = [DashSplitControl new];
    if (testMode) {
        UIButton *testClose = [UIButton buttonWithType:UIButtonTypeCustom];
        UIColor *glyphColor = [UIColor colorWithWhite:1.0 alpha:0.6];
        [testClose setTitle:@"✕" forState:UIControlStateNormal];
        [testClose setTitle:@"✕" forState:UIControlStateHighlighted];
        [testClose setTitleColor:glyphColor forState:UIControlStateNormal];
        [testClose setTitleColor:glyphColor forState:UIControlStateHighlighted];
        testClose.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
        testClose.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
        testClose.layer.cornerRadius = 24;
        testClose.layer.zPosition = 9999;
        [testClose addTarget:gControl action:@selector(toggleTapped) forControlEvents:UIControlEventTouchUpInside];
        [addTarget addSubview:testClose];
        gToggleButton = testClose;  // reuse the variable for test mode only
    } else {
        gToggleButton = nil;
    }

    // 0.1.58: manual-start button — car mode with ManualStart ON shows only
    // this button on connect; hosting begins when the user taps it. Hidden by
    // default; the end-of-create branch reveals it.
    if (!testMode && !gAutoStartOnCreate && PrefBool(kPrefsManualStart, NO)) {
        if (!gStartButton) {
            gStartButton = [UIButton buttonWithType:UIButtonTypeCustom];
            [gStartButton setTitle:@"▶ 开始" forState:UIControlStateNormal];
            [gStartButton setTitle:@"▶ 开始" forState:UIControlStateHighlighted];
            gStartButton.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
            [gStartButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            [gStartButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.7] forState:UIControlStateHighlighted];
            gStartButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
            gStartButton.layer.cornerRadius = 16;
            gStartButton.layer.borderWidth = 1.0;
            gStartButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
            gStartButton.layer.zPosition = 10000;
            gStartButton.frame = CGRectMake(0, 0, 160, 66);
            [gStartButton addTarget:gDragHandler action:@selector(startButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
            [window addSubview:gStartButton];
        }
        gStartButton.hidden = YES;
    } else {
        if (gStartButton) gStartButton.hidden = YES;
    }

    gWindow = window;

    // 0.1.55: single controls strip, created once. Added to the WINDOW (not
    // the rotated test container) so it stays pinned to the physical right
    // edge of the screen, above every pane, without ever covering app content.
    if (!gControlStrip) {
        gControlStrip = [[UIView alloc] initWithFrame:CGRectZero];
        gControlStrip.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
        gControlStrip.layer.cornerRadius = 6;
        gControlStrip.userInteractionEnabled = YES;
        gControlStrip.layer.zPosition = 9999;

        gControlLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        gControlLabel.numberOfLines = 2;
        gControlLabel.textAlignment = NSTextAlignmentCenter;
        gControlLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        gControlLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
        gControlLabel.userInteractionEnabled = NO;
        [gControlStrip addSubview:gControlLabel];

        gZoomSlider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 170, 24)];
        gZoomSlider.minimumValue = 0.2f;
        gZoomSlider.maximumValue = 4.0f;
        gZoomSlider.value = 1.0f;
        gZoomSlider.continuous = YES;
        gZoomSlider.transform = CGAffineTransformMakeRotation(-M_PI_2);
        [gZoomSlider setMinimumTrackTintColor:[UIColor colorWithWhite:1.0 alpha:0.6]];
        [gZoomSlider setMaximumTrackTintColor:[UIColor colorWithWhite:1.0 alpha:0.25]];
        [gZoomSlider addTarget:gDragHandler action:@selector(zoomSliderChanged:) forControlEvents:UIControlEventValueChanged];
        [gControlStrip addSubview:gZoomSlider];

        gResetButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [gResetButton setTitle:@"⟲" forState:UIControlStateNormal];
        [gResetButton setTitle:@"⟲" forState:UIControlStateHighlighted];
        gResetButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
        [gResetButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.85] forState:UIControlStateNormal];
        [gResetButton setTitleColor:[UIColor whiteColor] forState:UIControlStateHighlighted];
        gResetButton.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.3];
        gResetButton.layer.cornerRadius = 4;
        [gResetButton addTarget:gDragHandler action:@selector(resetZoomTapped:) forControlEvents:UIControlEventTouchUpInside];
        [gControlStrip addSubview:gResetButton];

        // 0.1.57: the right-edge strip no longer has a close button — every
        // pane carries its own × (gCloseButtons). gCloseButton stays nil.

        [window addSubview:gControlStrip];
    }
    
    // Restore the user's saved pane layout (centers, zooms, closed states)
    // before Layout computes the frames. gWindow must be set first.
    LoadPaneLayoutState();

    // 0.1.55: start with the first open pane selected so the right-edge
    // controls are usable immediately.
    {
        int firstOpen = -1;
        for (int i = 0; i < count; i++) { if (!gPaneClosed[i]) { firstOpen = i; break; } }
        SelectPane(firstOpen);
    }
    
    // "请锁屏手机后显示" hint banner — centered at the top, shown when panes
    // are hidden (unlock auto-hide or manual hide). Semi-transparent background.
    gLockHintLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    gLockHintLabel.text = @"请锁屏手机后显示";
    gLockHintLabel.textAlignment = NSTextAlignmentCenter;
    gLockHintLabel.textColor = [UIColor whiteColor];
    gLockHintLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    gLockHintLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    gLockHintLabel.layer.cornerRadius = 8;
    gLockHintLabel.clipsToBounds = YES;
    gLockHintLabel.hidden = YES;
    gLockHintLabel.userInteractionEnabled = NO;
    gLockHintLabel.layer.zPosition = 9998;
    [addTarget addSubview:gLockHintLabel];
    
    Layout();
    
    NSMutableString *paneInfo = [NSMutableString string];
    for (int index = 0; index < count; index++) {
        if (index > 0) [paneInfo appendString:@" "];
        [paneInfo appendFormat:@"pane%d=%@", index, NSStringFromCGRect(gPanes[index].frame)];
    }
    CLog(@"ui: window=%@ bounds=%@ %d-pane %@",
         NSStringFromClass([window class]),
         NSStringFromCGRect(window.bounds),
         count,
         paneInfo);
    
    NSFileManager *manager = [NSFileManager defaultManager];
    if ([manager fileExistsAtPath:@COCKPIT_HOSTING]) {
        [manager removeItemAtPath:@COCKPIT_HOSTING error:nil];
    }
    
    BOOL hadCrash = [manager fileExistsAtPath:@COCKPIT_CRASHED];
    if (hadCrash) {
        CLog(@"host: crash marker from last session found, proceeding anyway");
        [manager removeItemAtPath:@COCKPIT_CRASHED error:nil];
    }
    
    if (testMode || gAutoStartOnCreate) {
        // Phone test mode (the connect wave never happens there) and rebuilds
        // of an already-running interface keep the old auto-host behavior.
        HostAllPanes(testMode);
    } else if (PrefBool(kPrefsManualStart, NO)) {
        // 0.1.58: MANUAL start — the interface is built but nothing is
        // hosted (no Live controllers exist yet, so the connect wave is
        // harmless). Only the centered start button is shown; tapping it
        // runs RestoreNow (respecting the never-Live-while-unlocked gate).
        gManualAwaitingStart = YES;
        for (int index = 0; index < count; index++) {
            if (gPanes[index]) gPanes[index].hidden = YES;
            if (gCapsules[index]) gCapsules[index].hidden = YES;
            if (gPaneToolbars[index]) gPaneToolbars[index].hidden = YES;
        }
        for (int i = 0; i < MAX_PANES; i++) if (gDividers[i]) gDividers[i].hidden = YES;
        if (gStartButton) gStartButton.hidden = NO;
        CLog(@"ui: car mode — manual start waiting for user");
    } else {
        // 0.1.58: AUTO start — show the saved layout as placeholder panes
        // (closed panes get their capsules immediately), but DEFER the actual
        // hosting until the CarPlay setup wave has passed
        // (AUTO_START_DELAY_SECONDS). No Live controller exists during the
        // wait, so the "show -> disappear -> reappear" flicker is gone.
        gAutoStartArmed = YES;
        gAutoStartAt = CFAbsoluteTimeGetCurrent() + AUTO_START_DELAY_SECONDS;
        for (int index = 0; index < count; index++) {
            if (!gPaneClosed[index]) continue;
            if (gPanes[index]) gPanes[index].hidden = YES;
            if (gPaneToolbars[index]) gPaneToolbars[index].hidden = YES;
        }
        // Dock the closed panes' capsules at their top-row slots.
        LayoutCapsuleRow();
        if (gLockStateKnown && !gPhoneLocked) {
            // Unlocked: nothing is Live yet — hide the placeholders and let
            // the unlock listener show the capsule row; the lock will start.
            for (int index = 0; index < count; index++) {
                if (gPanes[index]) gPanes[index].hidden = YES;
                if (gPaneToolbars[index]) gPaneToolbars[index].hidden = YES;
            }
            for (int i = 0; i < MAX_PANES; i++) if (gDividers[i]) gDividers[i].hidden = YES;
            CLog(@"ui: car mode — auto start armed, placeholders hidden (phone unlocked)");
        } else {
            CLog(@"ui: car mode — auto start armed, hosting in %.0fs", AUTO_START_DELAY_SECONDS);
        }
    }
    gAutoStartOnCreate = NO;
}

#pragma mark - Lifecycle

static BOOL Disabled(void)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:@COCKPIT_OFF];
}

static BOOL CarScreenConnected(void)
{
    for (UIScreen *screen in [UIScreen screens]) {
        if (BoolReturn(screen, @"_isCarScreen", NO) || BoolReturn(screen, @"_isCarPlayScreen", NO)) {
            return YES;
        }
        if (![[UIScreen mainScreen] isEqual:screen] && screen.bounds.size.width != [UIScreen mainScreen].bounds.size.width) {
            return YES;
        }
    }
    return NO;
}

// Auto-recovery (user choice, 0.0.23): when a hosted app's scene dies
// (system reclaim, crash, force-kill on the phone), re-host it so the pane
// fills again. The scene object itself is the liveness signal — isRunning is
// useless on this device. A scene that exists but went inactive first gets a
// cheap "nudge" (mode 2 + displayMode 4); two nudges that don't stick
// escalate to a full re-host. Everything is rate-limited by a 15s per-slot
// cooldown; the birth grace window lets a fresh host come up undisturbed.
static void HealthCheckSlots(void)
{
    double now = CFAbsoluteTimeGetCurrent();
    int count = PaneCount();
    for (int index = 0; index < count; index++) {
        HostSlot *slot = gSlots[index];
        if (!slot || !slot.viewController) continue;
        if (now - slot.birth < 20) continue;
        if (now - slot.lastRehost < 15) continue;
        
        id scene = slot.handle ? Call0(slot.handle, @"sceneIfExists") : nil;
        BOOL active = BoolReturn(scene, @"isActive", NO);
        
        if (slot.suppressed) {
            // Stood down preemptively (foreground=No diff). Do NOT nudge or
            // re-host while suppressed — that would flip us back to Live and
            // re-arm the assertion. Revive passively only when the system
            // itself reports the scene active again.
            if (scene && active) {
                CLog(@"health[%d]: scene active again after preempt, reviving", index);
                slot.suppressed = 0;
                slot.failedNudges = 0;
                slot.lastRehost = now;
                ReactivateSlot(index);
            }
            continue;
        }
        
        if (scene && active) {
            slot.failedNudges = 0;
            continue;
        }
        
        slot.lastRehost = now;
        
        if (scene && slot.failedNudges < 2) {
            slot.failedNudges++;
            CLog(@"health[%d]: scene inactive, nudging back to live (nudge %d)", index, slot.failedNudges);
            ReactivateSlot(index);
            continue;
        }
        
        slot.rehostCount++;
        slot.failedNudges = 0;
        CLog(@"health[%d]: scene gone or unresponsive, re-hosting (#%d)", index, slot.rehostCount);
        TeardownSlot(slot);
        gSlots[index] = HostApplication(slot.bundleID, slot.container, index);
    }
}

static void Tick(void)
{
    @try {
        BOOL carConnected = CarScreenConnected();
        BOOL testMode = (!carConnected && TestModeEnabled());
        
        // 0.1.23: timestamp the (re)connect — the settle window for the
        // CarPlay setup wave runs from here. Rebuild ticks enter with a
        // window already up, so an in-flight interface keeps its timestamp.
        if (carConnected && !gWindow) {
            gConnectAt = CFAbsoluteTimeGetCurrent();
        }
        
        if (!carConnected && !testMode) {
            // 0.1.23: FULL teardown instead of hide-and-keep — a kept window
            // with nil slots left EMPTY panes on reconnect. Tearing the
            // window down too makes every reconnect a clean create (fresh
            // settle window, start button again).
            if (gWindow) {
                TeardownAllHosts();
                gWindow.hidden = YES;
                gWindow = nil;
for (int i = 0; i < MAX_PANES; i++) { gPanes[i] = nil; gDragHandles[i] = nil; gCloseButtons[i] = nil; gPaneToolbars[i] = nil; gPaneBaseFrames[i] = CGRectZero; gPaneZoom[i] = 1.0f; gPaneCenters[i] = CGPointZero; }
for (int i = 0; i < MAX_PANES; i++) gDividers[i] = nil;
gTestContainer = nil;
gToggleButton = nil;
gLockHintLabel = nil;
gStartButton = nil;
gToastLabel = nil;
[gControlStrip removeFromSuperview];
gControlStrip = nil;
gControlLabel = nil;
gZoomSlider = nil;
gResetButton = nil;
gCloseButton = nil;
gCurrentPane = -1;
                gCurrentPaneCount = 0;
                gTestMode = NO;
                gTestLandscape = NO;
                CLog(@"lifecycle: car display gone, torn down for a clean reconnect");
            }
            return;
        }
        
        if (gWindow) {
            if (carConnected && gTestMode) {
                gAutoStartOnCreate = YES;   // was live in test mode; stay live on the car display
                TeardownAllHosts();
                gWindow.hidden = YES;
                gWindow = nil;
for (int i = 0; i < MAX_PANES; i++) { gPanes[i] = nil; gDragHandles[i] = nil; gCloseButtons[i] = nil; gPaneToolbars[i] = nil; gPaneBaseFrames[i] = CGRectZero; gPaneZoom[i] = 1.0f; gPaneCenters[i] = CGPointZero; }
for (int i = 0; i < MAX_PANES; i++) gDividers[i] = nil;
gTestContainer = nil;
gToggleButton = nil;
gLockHintLabel = nil;
gStartButton = nil;
gToastLabel = nil;
[gControlStrip removeFromSuperview];
gControlStrip = nil;
gControlLabel = nil;
gZoomSlider = nil;
gResetButton = nil;
gCloseButton = nil;
gCurrentPane = -1;
                gCurrentPaneCount = 0;
                gTestMode = NO;
                gTestLandscape = NO;
                CLog(@"lifecycle: car display found, rebuilding there");
            } else if (gCurrentPaneCount != PaneCount()) {
                // Split mode changed (2<->3): tear down everything and rebuild
                // so the new pane count and layout take effect.
                CLog(@"lifecycle: split mode changed %d->%d, rebuilding", gCurrentPaneCount, PaneCount());
                gAutoStartOnCreate = YES;   // interface was already started; rebuild hosts at once
                TeardownAllHosts();
                gWindow.hidden = YES;
                gWindow = nil;
for (int i = 0; i < MAX_PANES; i++) { gPanes[i] = nil; gDragHandles[i] = nil; gCloseButtons[i] = nil; gPaneToolbars[i] = nil; gPaneBaseFrames[i] = CGRectZero; gPaneZoom[i] = 1.0f; gPaneCenters[i] = CGPointZero; }
for (int i = 0; i < MAX_PANES; i++) gDividers[i] = nil;
gTestContainer = nil;
gToggleButton = nil;
gLockHintLabel = nil;
gStartButton = nil;
gToastLabel = nil;
[gControlStrip removeFromSuperview];
gControlStrip = nil;
gControlLabel = nil;
gZoomSlider = nil;
gResetButton = nil;
gCloseButton = nil;
gCurrentPane = -1;
                gCurrentPaneCount = 0;
                // Fall through to CreateInterface below.
            } else if (gTestMode && gTestLandscape != PrefBool(kPrefsTestLandscape, YES)) {
                // Test orientation (横屏/竖屏) changed: rebuild so the
                // container rotation matches the new preference.
                CLog(@"lifecycle: test orientation changed %d->%d, rebuilding",
                     gTestLandscape, PrefBool(kPrefsTestLandscape, YES));
                gAutoStartOnCreate = YES;
                TeardownAllHosts();
                gWindow.hidden = YES;
                gWindow = nil;
for (int i = 0; i < MAX_PANES; i++) { gPanes[i] = nil; gDragHandles[i] = nil; gCloseButtons[i] = nil; gPaneToolbars[i] = nil; gPaneBaseFrames[i] = CGRectZero; gPaneZoom[i] = 1.0f; gPaneCenters[i] = CGPointZero; }
for (int i = 0; i < MAX_PANES; i++) gDividers[i] = nil;
gTestContainer = nil;
gToggleButton = nil;
gLockHintLabel = nil;
gStartButton = nil;
gToastLabel = nil;
[gControlStrip removeFromSuperview];
gControlStrip = nil;
gControlLabel = nil;
gZoomSlider = nil;
gResetButton = nil;
gCloseButton = nil;
gCurrentPane = -1;
                gCurrentPaneCount = 0;
                // Fall through to CreateInterface below.
            } else {
                if (gWindow.hidden && !gUserClosed) {
                    gWindow.hidden = NO;
                }
                // 0.1.58: auto-start armed at connect — once the settle
                // window passes, restore the saved layout (only while the
                // phone is locked; otherwise keep waiting for the lock).
                if (gAutoStartArmed && CFAbsoluteTimeGetCurrent() >= gAutoStartAt) {
                    gAutoStartArmed = NO;
                    if (gLockStateKnown && gPhoneLocked) {
                        CLog(@"ui: connect settle window passed — auto-starting");
                        RestoreNow();
                    } else {
                        gPendingShow = 1;
                        CLog(@"ui: settle window passed but phone unlocked — start deferred to next lock");
                    }
                }
                // Deferred start from an early tap: the settle window passed.
                if (gPendingStart && gConnectAt > 0 &&
                    CFAbsoluteTimeGetCurrent() - gConnectAt >= CONNECT_SETTLE_SECONDS) {
                    if (gLockStateKnown && !gPhoneLocked) {
                        // 0.1.28: the settle window is over but the phone is
                        // unlocked — keep waiting for the next lock instead
                        // of walking into the foreground=No wave.
                        gPendingStart = NO;
                        gPendingShow = 1;
                        CLog(@"ui: settle window passed but phone unlocked — start deferred to next lock");
                    } else {
                        CLog(@"ui: settle window passed, starting deferred hosting");
                        StartNow();
                    }
                }
                if (!gUserClosed && !gAwaitingStart && !gManualAwaitingStart) {
                    HealthCheckSlots();
                }
                return;
            }
        }
        
        if (gUserClosed) return;
        if (!PrefBool(kPrefsEnabled, YES)) return;
        
        // Crash loop protection.
        if (gCrashCount >= 3) {
            CLog(@"lifecycle: crash loop detected (%d), skipping create", gCrashCount);
            return;
        }
        
        CreateInterface(testMode);
    } @catch (NSException *exception) {
        CLog(@"tick: exception %@: %@", exception.name, exception.reason);
    }
}

__attribute__((constructor))
static void DashSplitInit(void)
{
    @autoreleasepool {
        if (Disabled()) return;
        
        CLog(@"--- DashSplit 0.1.58 loaded ---");
        InstallExceptionFilter();
        InstallCrashHandlers();
        
        // Read crash count from last session.
        NSString *crashCountText = [NSString stringWithContentsOfFile:@COCKPIT_CRASHCOUNT encoding:NSUTF8StringEncoding error:nil];
        gCrashCount = crashCountText ? [crashCountText intValue] : 0;
        if (gCrashCount > 0) {
            CLog(@"init: crash count from last session = %d", gCrashCount);
            if (gCrashCount >= 3) {
                gCrashCount = 0;
                [[NSFileManager defaultManager] removeItemAtPath:@COCKPIT_CRASHCOUNT error:nil];
                CLog(@"init: crash count reset, will try again");
            }
        }
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (FileExists(@COCKPIT_TEST)) {
                [[NSFileManager defaultManager] removeItemAtPath:@COCKPIT_TEST error:nil];
                CLog(@"init: removed leftover test marker file (test mode is toggle-only now)");
            }
            // One-time: force test mode OFF so a stale true value left from
            // earlier experimentation cannot auto-start it on every boot.
            // After this single reset the Settings toggle is the only control.
            NSString *resetKey = @"TestModeReset_0_1_14";
            if (!PrefBool(resetKey, NO)) {
                CFPreferencesSetAppValue(CFSTR("TestOnMainScreen"), kCFBooleanFalse, CFSTR("zp.dashsplit"));
                // Reset to default selected apps.
                CFPreferencesSetAppValue(CFSTR("SelectedApps"), (__bridge CFTypeRef)@"com.apple.mobiletimer,com.apple.mobilecal", CFSTR("zp.dashsplit"));
                CFPreferencesSetAppValue((__bridge CFStringRef)resetKey, kCFBooleanTrue, CFSTR("zp.dashsplit"));
                CFPreferencesAppSynchronize(CFSTR("zp.dashsplit"));
                CLog(@"init: one-time test-mode reset applied (default OFF)");
            }
            InstallSceneDiffHook();
            InstallUIScreenHook();
            InstallLockStateObserver();
            LogPrefsState();
            LogHostingAPI();
            DumpProbe();
            Tick();
            
            NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer *timer) {
                Tick();
            }];
            [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        });
    }
}
