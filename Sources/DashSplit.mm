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
// disabled by creating /var/mobile/Library/Preferences/lilliana.dashsplit.off.

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
#define COCKPIT_OFF     "/var/mobile/Library/Preferences/lilliana.dashsplit.off"
#define COCKPIT_PREFS   "/var/mobile/Library/Preferences/lilliana.dashsplit.plist"
#define COCKPIT_HOSTING "/var/mobile/Library/Preferences/lilliana.dashsplit.hosting"
#define COCKPIT_CRASHED "/var/mobile/Library/Preferences/lilliana.dashsplit.crashed"
#define COCKPIT_NEWSCENE "/var/mobile/Library/Preferences/lilliana.dashsplit.newscene"
#define COCKPIT_CRASHCOUNT "/var/mobile/Library/Preferences/lilliana.dashsplit.crashcount"

static NSString *const kPrefsHostApp  = @"HostBundleID";
static NSString *const kPrefsHostApp2 = @"HostBundleID2";
static NSString *const kPrefsHostApp3 = @"HostBundleID3";
static NSString *const kPrefsEnabled  = @"Enabled";
static NSString *const kPrefsTestMain = @"TestOnMainScreen";
static NSString *const kPrefsTestLandscape = @"TestLandscape";
static NSString *const kPrefsStretchFill = @"StretchFill";
// Fit mode: 0 = aspect-fit (default), 1 = stretch fill, 2 = native fill (hook UIScreen.bounds)
static NSString *const kPrefsFitMode = @"FitMode";
static NSString *const kPrefsSplitMode = @"SplitMode";
// Split ratio: integer (1-5) for each pane's relative weight. 0 means
// "default" — auto 1:2 in 2-split, 1:1:1 in 3-split, ignored in 1-split.
static NSString *const kPrefsSplitRatio = @"SplitRatio";
static NSString *const kPrefsSplitRatio2 = @"SplitRatio2"; // 3-split: pane2 share
static NSString *const kPrefsSplitRatio3 = @"SplitRatio3"; // 3-split: pane3 share

// Uninstallable system apps: the defaults must exist on every device.
static NSString *const kDefaultHost1 = @"com.apple.mobiletimer";   // 时钟
static NSString *const kDefaultHost2 = @"com.apple.mobilecal";     // 日历
static NSString *const kDefaultHost3 = @"com.apple.calculator";    // 计算器

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
    CFPreferencesAppSynchronize(CFSTR("lilliana.dashsplit"));
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("lilliana.dashsplit")));
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

#define COCKPIT_TEST "/var/mobile/Library/Preferences/lilliana.dashsplit.test"
#define COCKPIT_HOST "/var/mobile/Library/Preferences/lilliana.dashsplit.host"

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

// Split mode: 1 = single app (no split), 2 = two-way split (default), 3 = three-way split.
static int SplitMode(void)
{
    int mode = (int)PrefInteger(kPrefsSplitMode, 2);
    if (mode < 1) return 2;
    if (mode > 3) return 3;
    return mode;
}

// Split ratios: each pane's relative weight. Defaults are 0 (meaning
// "use built-in defaults": 1:2 in 2-split, 1:1:1 in 3-split). The values
// are integers 1-5 representing relative proportions; the Layout function
// normalises them to actual pixel widths. 1-split ignores ratios entirely.
static void SplitRatios(int count, int ratios[3])
{
    int r1 = (int)PrefInteger(kPrefsSplitRatio, 0);
    int r2 = (int)PrefInteger(kPrefsSplitRatio2, 0);
    int r3 = (int)PrefInteger(kPrefsSplitRatio3, 0);

    if (count <= 1) {
        // 1-split: single pane takes everything.
        ratios[0] = 1;
    } else if (count == 2) {
        // 2-split: use r1 for pane1, r2 (if set) for pane2. If r2 is 0 but
        // r1 is set, pane2 gets the complement (6-r1) to keep total 6. If
        // both 0, default 1:2.
        if (r1 > 0) {
            ratios[0] = r1;
            ratios[1] = (r2 > 0) ? r2 : (6 - r1);
            if (ratios[1] < 1) ratios[1] = 1;
        } else {
            ratios[0] = 1;  // default 1:2
            ratios[1] = 2;
        }
    } else {
        // 3-split: if any set use them; if none set, equal (1:1:1).
        if (r1 > 0 || r2 > 0 || r3 > 0) {
            ratios[0] = r1 > 0 ? r1 : 1;
            ratios[1] = r2 > 0 ? r2 : 1;
            ratios[2] = r3 > 0 ? r3 : 1;
        } else {
            ratios[0] = 1;
            ratios[1] = 1;
            ratios[2] = 1;
        }
    }
}

static int PaneCount(void)
{
    return SplitMode();
}

static NSString *HostBundleID1(void)
{
    NSString *bundleID = PrefString(kPrefsHostApp);
    if (bundleID.length) return bundleID;
    
    NSString *text = [NSString stringWithContentsOfFile:@COCKPIT_HOST encoding:NSUTF8StringEncoding error:nil];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length) return text;
    
    return kDefaultHost1;
}

static NSString *HostBundleID2(void)
{
    NSString *bundleID = PrefString(kPrefsHostApp2);
    if (bundleID.length) return bundleID;
    return kDefaultHost2;
}

static NSString *HostBundleID3(void)
{
    NSString *bundleID = PrefString(kPrefsHostApp3);
    if (bundleID.length) return bundleID;
    return kDefaultHost3;
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
    
    CLog(@"prefs: testMarker=%d hostFile=%d enabled=%d testMode=%d splitMode=%d host1=%@ host2=%@ host3=%@",
         FileExists(@COCKPIT_TEST),
         FileExists(@COCKPIT_HOST),
         PrefBool(kPrefsEnabled, YES),
         TestModeEnabled(),
         SplitMode(),
         HostBundleID1(),
         HostBundleID2(),
         HostBundleID3());
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

static HostSlot *gSlots[3];
static BOOL gUserClosed = NO;

// 0.1.23 manual-start state (see header note). gConnectAt marks when the car
// display was (re)connected; CONNECT_SETTLE_SECONDS is how long after connect
// the CarPlay setup wave can still arrive (observed at ~10s; padded to 30s).
static const double CONNECT_SETTLE_SECONDS = 30.0;
static BOOL gAwaitingStart = NO;     // car mode: button shown, hosting not begun
static BOOL gPendingStart = NO;      // tapped during settle window; host when it passes
static double gConnectAt = 0;        // CFAbsoluteTime of (re)connect; 0 = never
static BOOL gAutoStartOnCreate = NO; // rebuild path: interface was live, host at once

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
// (CarBridge, the phone UI, or the launch path itself) flips the scene's
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
    
    // CarBridge-style: set the scene's content reference size to the pane
    // size BEFORE applying display mode. This makes the App's scene lay out
    // at the pane dimensions from the very start — like CarBridge does in
    // fullscreen mode. The method setContentReferenceSize:withInterfaceOrientation:
    // is on SBApplicationSceneView (the appView), discovered via CarBridge
    // reverse engineering.
    if (FitMode() == 2 && !CGSizeEqualToSize(paneSize, CGSizeZero)) {
        id sceneView = Call0(viewController, @"appView");
        if (sceneView) {
            SEL refSizeSel = NSSelectorFromString(@"setContentReferenceSize:withInterfaceOrientation:");
            if ([sceneView respondsToSelector:refSizeSel]) {
                NSInteger orientation = 1; // UIInterfaceOrientationPortrait
                ((void (*)(id, SEL, CGSize, NSInteger))objc_msgSend)(sceneView, refSizeSel, paneSize, orientation);
                CLog(@"host: setContentReferenceSize:%@ orientation=%d", NSStringFromCGSize(paneSize), (int)orientation);
            } else {
                CLog(@"host: setContentReferenceSize:withInterfaceOrientation: NOT available on %@", NSStringFromClass([sceneView class]));
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
static CGSize gNativeFillSizes[3] = {CGSizeZero, CGSizeZero, CGSizeZero};  // per-pane sizes
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
        // Native fill — CarBridge-style scene content reference size +
        // UIScreen.bounds hook + contentView bounds + layout.
        //
        // The App's internal layout engine reads UIScreen.bounds (NOT the
        // superview bounds) to determine its root view size. Without the
        // hook, the App lays out at 414x896 (phone) and gets cropped.
        //
        // CarBridge approach: call setContentReferenceSize:withInterfaceOrientation:
        // on the SBApplicationSceneView to set the scene's content reference
        // size to the pane dimensions, so the App lays out at pane size from
        // the start. Also hook UIScreen.bounds as a fallback for apps that
        // read it directly.
        int paneIndex = -1;
        for (int i = 0; i < 3; i++) {
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

        // CarBridge-style: set content reference size on the scene view.
        if (sceneView) {
            SEL refSizeSel = NSSelectorFromString(@"setContentReferenceSize:withInterfaceOrientation:");
            if ([sceneView respondsToSelector:refSizeSel]) {
                NSInteger orientation = 1; // UIInterfaceOrientationPortrait
                ((void (*)(id, SEL, CGSize, NSInteger))objc_msgSend)(sceneView, refSizeSel, paneSize, orientation);
                CLog(@"fit: setContentReferenceSize:%@ orientation=%d", NSStringFromCGSize(paneSize), (int)orientation);
            }
        }

        // Also try setAppFrame: on the device controller (CarBridge uses this).
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
        [contentView layoutIfNeeded];
        [appView layoutIfNeeded];
        // Post-layout diagnostic.
        CLog(@"fit: native fill POST-layout appView.bounds=%@", NSStringFromCGRect(appView.bounds));
        for (UIView *sub in contentView.subviews) {
            CLog(@"fit: native fill POST-layout sub frame=%@ bounds=%@ class=%@",
                 NSStringFromCGRect(sub.frame),
                 NSStringFromCGRect(sub.bounds),
                 NSStringFromClass([sub class]));
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
    appView.backgroundColor = [UIColor clearColor];
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
    for (int i = 0; i < 3; i++) gNativeFillSizes[i] = CGSizeZero;
    // Teardown ALL slots (not just PaneCount()) — when switching from 3-split
    // to 2-split, slot[2] must be torn down even though PaneCount() is now 2.
    for (int i = 0; i < 3; i++) {
        if (gSlots[i]) {
            TeardownSlot(gSlots[i]);
            gSlots[i] = nil;
        }
    }
    gUserClosed = NO;
    gAwaitingStart = NO;
    gPendingStart = NO;
    gPendingShow = 0;
    // Re-assert after teardown: FitAppViewToContainer calls during invalidate
    // may have re-enabled it.
    gNativeFillActive = NO;
}

#pragma mark - UI

static UIWindow *gWindow;
static UIView *gPanes[3];
static UIView *gDividers[2];  // up to 2 dividers for 3-pane split
static UIView *gTestContainer;  // rotated container for landscape test preview
static BOOL gTestMode;
static BOOL gTestLandscape;  // tracks the TestLandscape pref of the active test interface
static UILabel *gLockHintLabel;  // "请锁屏手机后显示" banner shown when panes hidden
static UIButton *gToggleButton;
static int gCurrentPaneCount = 0;  // pane count of the currently active interface

// The toggle glyph must be set on BOTH normal and highlighted states —
// otherwise the press shows the stale title from the other state.
static void SetToggleGlyph(NSString *glyph)
{
    if (!gToggleButton) return;
    [gToggleButton setTitle:glyph forState:UIControlStateNormal];
    [gToggleButton setTitle:glyph forState:UIControlStateHighlighted];
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
    }
    for (int i = 0; i < 2; i++) if (gDividers[i]) gDividers[i].hidden = YES;
    SetToggleGlyph(@"⟳");
    // Show the "请锁屏手机后显示" hint banner.
    if (gLockHintLabel) gLockHintLabel.hidden = NO;
    for (int index = 0; index < count; index++) {
        SlotSetMode(index, 0);
    }
    CLog(@"ui: overlay hidden (%@) — hosting kept alive", why);
}

static void RestoreSlot(int index)
{
    HostSlot *slot = gSlots[index];
    if (!slot) return;
    
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
    NSString *bid1 = HostBundleID1();
    NSString *bid2 = HostBundleID2();
    NSString *bid3 = HostBundleID3();
    NSArray *bidArr = [NSArray arrayWithObjects:bid1, bid2, bid3, nil];
    
    NSMutableString *hostLog = [NSMutableString string];
    for (int index = 0; index < count; index++) {
        if (index > 0) [hostLog appendString:@" + "];
        [hostLog appendString:bidArr[index]];
    }
    CLog(@"ui: hosting %@ in %@", hostLog, testMode ? @"phone test mode" : @"car mode");
    
    NSMutableArray *seenBIDs = [NSMutableArray array];
    for (int index = 0; index < count; index++) {
        NSString *bid = bidArr[index];
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
        if (gPanes[index]) gPanes[index].hidden = NO;
    }
    for (int i = 0; i < 2; i++) if (gDividers[i]) gDividers[i].hidden = NO;
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
static void RestoreNow(void)
{
    gUserClosed = NO;
    int count = PaneCount();
    for (int index = 0; index < count; index++) {
        if (gPanes[index]) gPanes[index].hidden = NO;
    }
    for (int i = 0; i < 2; i++) if (gDividers[i]) gDividers[i].hidden = NO;
    if (gLockHintLabel) gLockHintLabel.hidden = YES;
    SetToggleGlyph(@"✕");
    for (int index = 0; index < count; index++) {
        RestoreSlot(index);
    }
    CLog(@"ui: overlay restored");
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
                                 CFSTR("lilliana.dashsplit"));
        CFPreferencesAppSynchronize(CFSTR("lilliana.dashsplit"));
        TeardownAllHosts();
        gWindow.hidden = YES;
        gWindow = nil;
        int count = PaneCount();
        for (int i = 0; i < count; i++) gPanes[i] = nil;
        for (int i = 0; i < 2; i++) gDividers[i] = nil;
        gTestContainer = nil;
        gToggleButton = nil;
        gLockHintLabel = nil;
        gCurrentPaneCount = 0;
        gTestMode = NO;
        gTestLandscape = NO;
        gUserClosed = NO;
        CLog(@"ui: test mode closed by user via ✕ button");
        return;
    }

    if (gAwaitingStart) {
        // 0.1.28: never enter Live while the phone is unlocked. The 19:10
        // session started hosting 8s after unlock and died 2s later — with
        // the phone in use the system pushes foreground=No straight into
        // freshly-Live controllers. Remember the request; run it on the
        // next lock event.
        if (gLockStateKnown && !gPhoneLocked) {
            gPendingShow = 1;
            ShowPanes();
            CLog(@"ui: start requested but phone unlocked — deferred until the phone locks");
            return;
        }
        // 0.1.23 start button. A tap inside the settle window shows the
        // (still empty) panes for feedback but defers hosting — the CarPlay
        // setup wave is still due and must not find a Live controller.
        double age = gConnectAt > 0 ? CFAbsoluteTimeGetCurrent() - gConnectAt : CONNECT_SETTLE_SECONDS;
        if (age < CONNECT_SETTLE_SECONDS) {
            gPendingStart = YES;
            ShowPanes();
            CLog(@"ui: start tapped %.0fs after connect — panes shown, hosting deferred to the %.0fs mark", age, CONNECT_SETTLE_SECONDS);
        } else {
            StartNow();
        }
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
        // 0.1.28: a start/restore the user requested while the phone was
        // unlocked is now safe to run (never-Live-while-unlocked policy).
        if (gPendingShow == 1) {
            gPendingShow = 0;
            CLog(@"lock: running deferred start");
            StartNow();
        } else if (gPendingShow == 2) {
            gPendingShow = 0;
            CLog(@"lock: running deferred restore");
            RestoreNow();
        }
        return;
    }
    
    CLog(@"lock: phone unlocked");
    
    // Nothing hosted yet on the car display — a deferred early tap must not
    // turn into a Live host while the user is about to use the phone.
    if (gAwaitingStart) {
        if (gPendingStart) {
            gPendingStart = NO;
            int count = PaneCount();
            for (int index = 0; index < count; index++) {
                if (gPanes[index]) gPanes[index].hidden = YES;
            }
            for (int i = 0; i < 2; i++) if (gDividers[i]) gDividers[i].hidden = YES;
            SetToggleGlyph(@"▶");
            CLog(@"lock: pending start cancelled on unlock — tap ▶ again later");
        }
        return;
    }
    
    // Already hidden (manually or by a previous unlock) or not on the car
    // display — nothing to stand down. Phone test mode never reacts to
    // unlock: it lives on the phone screen and is for debugging only.
    if (!gWindow || gTestMode || gUserClosed) return;
    
    HidePanesAndStandDown(@"auto: phone unlocked");
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
    
    // In test mode the panes live inside gTestContainer which is rotated 90°
    // clockwise to simulate a landscape car display on the portrait phone.
    // The container's bounds are swapped (width=screen height, height=screen
    // width), so Layout uses those as the effective landscape dimensions.
    // In portrait test mode gTestContainer is nil — panes are added directly
    // to the window, so we use the window bounds instead.
    UIView *host = (gTestMode && gTestContainer) ? gTestContainer : gWindow;
    CGRect bounds = host.bounds;
    
    CLog(@"layout: host=%@ bounds=%@ testMode=%d testContainer=%@",
         NSStringFromClass([host class]),
         NSStringFromCGRect(bounds),
         gTestMode,
         gTestContainer ? NSStringFromCGRect(gTestContainer.bounds) : @"(nil)");
    
    // Both test mode and car mode use the same horizontal split logic:
    // leave the leftmost strip for a system sidebar, then split the remaining
    // width into N columns based on user-configurable ratios.
    //
    // Test mode simulates a landscape car display by computing a sideMargin
    // proportional to the screen, giving the same visual layout as the car.
    CGFloat sideMargin = floor(bounds.size.width / 13.0);
    CGFloat usable = bounds.size.width - sideMargin;

    // Get user-configured split ratios (falls back to defaults when unset).
    int ratios[3] = {0};
    SplitRatios(count, ratios);

    // Normalise ratios to pixel widths. The last pane absorbs any rounding
    // remainder so the panes fill the full usable width without gaps.
    CGFloat origins[3];
    CGFloat widths[3];
    int totalRatio = 0;
    for (int i = 0; i < count; i++) totalRatio += ratios[i];

    CGFloat accumulated = 0;
    for (int i = 0; i < count; i++) {
        origins[i] = accumulated;
        if (i < count - 1) {
            CGFloat w = floor(usable * ratios[i] / totalRatio);
            widths[i] = w;
            accumulated += w;
        } else {
            // Last pane: take everything that's left.
            widths[i] = usable - accumulated;
        }
    }

    for (int index = 0; index < count; index++) {
        if (gPanes[index]) {
            gPanes[index].frame = CGRectMake(sideMargin + origins[index], 0,
                                              widths[index], bounds.size.height);
            CLog(@"layout: pane[%d] frame=%@ ratio=%d", index,
                 NSStringFromCGRect(gPanes[index].frame), ratios[index]);
        }
    }
    for (int i = 0; i < count - 1 && i < 2; i++) {
        if (gDividers[i]) {
            gDividers[i].frame = CGRectMake(sideMargin + origins[i] + widths[i], 0, 2, bounds.size.height);
        }
    }
    
    // Toggle button sits at the very top-left corner of the WHOLE display
    // (window coordinates), not the left pane, so it never covers hosted
    // content. In test mode it lives inside the rotated container too.
    UIView *toggleHost = (gTestMode && gTestContainer) ? gTestContainer : gWindow;
    if (gToggleButton) {
        gToggleButton.frame = CGRectMake(8, 8, 48, 48);
        [toggleHost bringSubviewToFront:gToggleButton];
    }
    // Lock hint label: centered at the top of the display.
    if (gLockHintLabel) {
        CGFloat hintW = 200;
        CGFloat hintH = 32;
        CGFloat hintX = (bounds.size.width - hintW) / 2.0;
        gLockHintLabel.frame = CGRectMake(hintX, 10, hintW, hintH);
        [toggleHost bringSubviewToFront:gLockHintLabel];
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
    
    // Create panes with blue translucent background.
    UIColor *paneColor = [UIColor colorWithRed:0.05 green:0.20 blue:0.55 alpha:0.55];
    NSArray *paneTitles = @[@"加载App……", @"加载App……", @"加载App……"];
    for (int index = 0; index < count; index++) {
        NSString *title = index < paneTitles.count ? paneTitles[index] : @"加载App……";
        gPanes[index] = MakePane(title, paneColor);
        [addTarget addSubview:gPanes[index]];
    }
    
    // Create divider lines (one per gap between adjacent panes).
    for (int i = 0; i < count - 1 && i < 2; i++) {
        gDividers[i] = [[UIView alloc] initWithFrame:CGRectZero];
        gDividers[i].backgroundColor = [UIColor whiteColor];
        gDividers[i].userInteractionEnabled = NO;
        [addTarget addSubview:gDividers[i]];
    }
    
    // Toggle button — always visible, lets user hide/show the panes.
    // Custom type with identical colors for every state: the button must look
    // the same (semi-transparent) whether idle or pressed. The old system-type
    // button dimmed only while touched, which read as "transparent when
    // pressed, opaque otherwise". (Custom buttons have no automatic press
    // dimming; the highlighted-state title is set explicitly so a press can
    // never fall back to a stale glyph either.)
    if (!gControl) gControl = [DashSplitControl new];
    UIButton *toggle = [UIButton buttonWithType:UIButtonTypeCustom];
    UIColor *glyphColor = [UIColor colorWithWhite:1.0 alpha:0.6];
    [toggle setTitle:@"✕" forState:UIControlStateNormal];
    [toggle setTitle:@"✕" forState:UIControlStateHighlighted];
    [toggle setTitleColor:glyphColor forState:UIControlStateNormal];
    [toggle setTitleColor:glyphColor forState:UIControlStateHighlighted];
    toggle.titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    toggle.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
    toggle.layer.cornerRadius = 24;
    toggle.layer.zPosition = 9999;
    [toggle addTarget:gControl action:@selector(toggleTapped) forControlEvents:UIControlEventTouchUpInside];

    [addTarget addSubview:toggle];
    gWindow = window;
    gToggleButton = toggle;
    
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
    } else {
        // 0.1.23: fresh CarPlay connect — show ONLY the start button. Panes
        // and dividers stay hidden and nothing is hosted until the user
        // taps (see toggleTapped / StartNow).
        gAwaitingStart = YES;
        for (int index = 0; index < count; index++) {
            if (gPanes[index]) gPanes[index].hidden = YES;
        }
        for (int i = 0; i < 2; i++) if (gDividers[i]) gDividers[i].hidden = YES;
        SetToggleGlyph(@"▶");
        CLog(@"ui: car mode — split view awaits a tap on the start button");
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
                for (int i = 0; i < 3; i++) gPanes[i] = nil;
                for (int i = 0; i < 2; i++) gDividers[i] = nil;
                gTestContainer = nil;
                gToggleButton = nil;
                gLockHintLabel = nil;
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
                int count = PaneCount();
                for (int i = 0; i < count; i++) gPanes[i] = nil;
                for (int i = 0; i < 2; i++) gDividers[i] = nil;
                gTestContainer = nil;
                gToggleButton = nil;
                gLockHintLabel = nil;
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
                for (int i = 0; i < 3; i++) gPanes[i] = nil;
                for (int i = 0; i < 2; i++) gDividers[i] = nil;
                gTestContainer = nil;
                gToggleButton = nil;
                gLockHintLabel = nil;
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
                for (int i = 0; i < 3; i++) gPanes[i] = nil;
                for (int i = 0; i < 2; i++) gDividers[i] = nil;
                gTestContainer = nil;
                gToggleButton = nil;
                gLockHintLabel = nil;
                gCurrentPaneCount = 0;
                // Fall through to CreateInterface below.
            } else {
                if (gWindow.hidden && !gUserClosed) {
                    gWindow.hidden = NO;
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
                if (!gUserClosed && !gAwaitingStart) {
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
        
        CLog(@"--- DashSplit 0.1.39 loaded ---");
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
                CFPreferencesSetAppValue(CFSTR("TestOnMainScreen"), kCFBooleanFalse, CFSTR("lilliana.dashsplit"));
                // Stored picks from experimentation also reset to the new
                // Clock/Calendar defaults so the device shows them cleanly.
                CFPreferencesSetAppValue(CFSTR("HostBundleID"), (__bridge CFTypeRef)kDefaultHost1, CFSTR("lilliana.dashsplit"));
                CFPreferencesSetAppValue(CFSTR("HostBundleID2"), (__bridge CFTypeRef)kDefaultHost2, CFSTR("lilliana.dashsplit"));
                CFPreferencesSetAppValue((__bridge CFStringRef)resetKey, kCFBooleanTrue, CFSTR("lilliana.dashsplit"));
                CFPreferencesAppSynchronize(CFSTR("lilliana.dashsplit"));
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
