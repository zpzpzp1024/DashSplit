// DashSplit settings injector — puts the 车载分屏 row into Settings WITHOUT
// PreferenceLoader. 0.1.3 dropped the PreferenceLoader dependency after it
// silently failed to surface the entry on the target device: its dylib and
// filter plist install correctly, the entry plist and pref bundle are all in
// place, yet the row never appears. This dylib uses the same injection
// mechanism as the main SpringBoard tweak (plain MobileSubstrate filter on
// com.apple.Preferences), which is proven working on that device.
//
// It swizzles -[PSListController specifiers] — the same hook point classic
// PreferenceLoader uses — and appends one PSLinkCell row on the ROOT
// settings list. Tapping it pushes DashSplitPrefListController from
// DashSplitPref.bundle (the pane itself is unchanged).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Preferences/Preferences.h>
#import <objc/runtime.h>
#import <objc/message.h>

static Class DashSplitPaneController(void)
{
    static Class controller;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSBundle *bundle = [NSBundle bundleWithPath:@"/var/jb/Library/PreferenceBundles/DashSplitPref.bundle"];
        if (bundle && ![bundle isLoaded]) [bundle load];
        controller = NSClassFromString(@"DashSplitPrefListController");
        if (!controller) {
            NSLog(@"[DashSplitSettings] pane controller class not found");
        }
    });
    return controller;
}

// The root list is the first view controller of the window's root navigation
// stack. Comparing identity (not class chains) keeps this true for whatever
// private navigation subclass Settings uses.
static BOOL IsRootSettingsList(id controller)
{
    UIWindow *window = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window) break;
    }
    UINavigationController *navigation = [window.rootViewController isKindOfClass:[UINavigationController class]]
        ? (UINavigationController *)window.rootViewController
        : nil;
    if (!navigation || navigation.viewControllers.count == 0) return NO;
    return navigation.viewControllers.firstObject == (UIViewController *)controller;
}

static IMP gOriginalSpecifiers;
static void *const kDashSplitRowAdded = (void *)&kDashSplitRowAdded;

static NSArray *DashSplitSpecifiers(id self, SEL _cmd)
{
    NSArray *specifiers = ((NSArray *(*)(id, SEL))gOriginalSpecifiers)(self, _cmd);

    Class pane = DashSplitPaneController();
    if (!pane) return specifiers;
    if (![self isKindOfClass:[PSListController class]]) return specifiers;
    if (!IsRootSettingsList(self)) return specifiers;
    if (objc_getAssociatedObject(self, kDashSplitRowAdded)) return specifiers;
    if (![specifiers isKindOfClass:[NSArray class]]) return specifiers;

    // The public SDK types the cell: argument as an undocumented PSCellType
    // enum, so build the specifier through objc_msgSend instead.
    SEL ctor = NSSelectorFromString(@"preferenceSpecifierNamed:target:action:set:get:detail:cell:edit:");
    if (![PSSpecifier respondsToSelector:ctor]) return specifiers;
    PSSpecifier *row = ((PSSpecifier *(*)(id, SEL, id, id, SEL, SEL, SEL, Class, Class, Class))objc_msgSend)
        ([PSSpecifier class], ctor,
         @"车载分屏", nil, NULL, NULL, NULL,
         pane, NSClassFromString(@"PSLinkCell"), nil);
    if (!row) return specifiers;

    [row setProperty:@"车载分屏" forKey:@"label"];

    NSMutableArray *updated = [specifiers mutableCopy];
    [updated addObject:row];
    objc_setAssociatedObject(self, kDashSplitRowAdded, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[DashSplitSettings] row added to root settings list");
    return updated;
}

__attribute__((constructor))
static void DashSplitSettingsInit(void)
{
    @autoreleasepool {
        Method method = class_getInstanceMethod([PSListController class], @selector(specifiers));
        if (method) {
            gOriginalSpecifiers = method_setImplementation(method, (IMP)DashSplitSpecifiers);
        }
        NSLog(@"[DashSplitSettings] injector loaded, specifiers hook=%d", gOriginalSpecifiers != NULL);
    }
}
