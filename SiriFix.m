// SiriFix.dylib — LiveContainer tweak to stop VK (and similar apps) from
// crashing on launch inside LiveContainer.
//
// The crash:
//   "Use of the class <INPreferences: 0x...> from an app requires the
//    entitlement com.apple.developer.siri. Did you enable the Siri
//    capability in your Xcode project?"
//   Call stack: CoreFoundation -> objc_exception_throw -> Intents ->
//   VKClient (VK_SHADOW_sdallocx) on a background dispatch queue.
//
// Root cause: LiveContainer runs the guest app inside LiveContainer's own
// process, so iOS checks LiveContainer's entitlements, not VK's. The
// guest's com.apple.developer.siri entitlement is not copied to the host,
// and LiveContainer upstream will not fix this (FAQ 8.2; issue #1492).
//
// Fix strategy: never let the real Intents code run. VK's launch path is
// the Apple-documented SiriKit authorization pattern —
// +[INPreferences siriAuthorizationStatus] and
// +[INPreferences requestSiriAuthorization:] — so we swizzle those class
// methods to report Denied (2) and never call the original implementation
// (which is what throws). We also replace -[INPreferences init] with a
// plain NSObject init, because the entitlement check also fires while an
// INPreferences instance is being created; the replacement never runs the
// original init body, so the check inside it never runs.
//
// Pure Objective-C runtime swizzling, no CydiaSubstrate dependency.
// Loaded by LiveContainer's TweakLoader before UIApplicationMain, so the
// patches are in place before VK's launch code runs.
//
// EXPERIMENTAL: this only covers the INPreferences path. If VK (or iOS)
// reaches the entitlement check through a different selector, the app can
// still crash — in that case the new crash log is the next diagnostic.
// Siri features inside VK will simply report "not authorized", which is
// the intended behaviour here.

#import <Foundation/Foundation.h>
#import <Intents/Intents.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// INSiriAuthorizationStatus: NotDetermined=0, Restricted=1, Denied=2,
// Authorized=3. Denied makes the app skip Siri and continue normally.
#define SIRIFIX_DENIED ((INSiriAuthorizationStatus)2)

#pragma mark - Replacement implementations (never call the original)

// +[INPreferences siriAuthorizationStatus]
static INSiriAuthorizationStatus SiriFix_siriAuthorizationStatus(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return SIRIFIX_DENIED;
}

// +[INPreferences requestSiriAuthorization:]
// Call the completion block synchronously with Denied. Synchronous is
// deliberate: the caller may be on a background queue waiting for the
// result, and dispatching async to the main queue could deadlock if the
// caller ever blocks the main thread. The block itself only records the
// status, so a synchronous call is safe.
static void SiriFix_requestSiriAuthorization(id self, SEL _cmd, void (^handler)(INSiriAuthorizationStatus)) {
    (void)self; (void)_cmd;
    if (handler) {
        handler(SIRIFIX_DENIED);
    }
}

// -[INPreferences init]
// Bypass INPreferences's own init (which performs the entitlement check)
// by running NSObject's init instead. INPreferences's superclass is
// NSObject, so objc_msgSendSuper with that superclass gives a plain
// initialized object. The object is never used for real Siri work — the
// class methods above already short-circuit the authorization flow —
// so a half-featured instance is harmless here.
static id SiriFix_INPreferences_init(id self, SEL _cmd) {
    struct objc_super superInfo = { self, class_getSuperclass(object_getClass(self)) };
    return ((id (*)(struct objc_super *, SEL))objc_msgSendSuper)(&superInfo, _cmd);
}

#pragma mark - Installation

static void SiriFix_install(void) {
    // Force-load the Intents framework so the INPreferences class exists
    // even if nothing has touched SiriKit yet in this process.
    dlopen("/System/Library/Frameworks/Intents.framework/Intents", RTLD_NOW | RTLD_GLOBAL);

    Class cls = NSClassFromString(@"INPreferences");
    if (cls == Nil) {
        NSLog(@"[SiriFix] INPreferences class not found, nothing to patch");
        return;
    }

    // Class methods live on the metaclass; class_getClassMethod finds them.
    // method_setImplementation replaces the IMP without ever calling the
    // original — the original is what throws the entitlement exception.
    Method m1 = class_getClassMethod(cls, @selector(siriAuthorizationStatus));
    if (m1) {
        method_setImplementation(m1, (IMP)SiriFix_siriAuthorizationStatus);
    } else {
        NSLog(@"[SiriFix] WARNING: +siriAuthorizationStatus not found");
    }

    Method m2 = class_getClassMethod(cls, @selector(requestSiriAuthorization:));
    if (m2) {
        method_setImplementation(m2, (IMP)SiriFix_requestSiriAuthorization);
    } else {
        NSLog(@"[SiriFix] WARNING: +requestSiriAuthorization: not found");
    }

    Method m3 = class_getInstanceMethod(cls, @selector(init));
    if (m3) {
        method_setImplementation(m3, (IMP)SiriFix_INPreferences_init);
    } else {
        NSLog(@"[SiriFix] WARNING: -init not found");
    }

    NSLog(@"[SiriFix] installed — INPreferences patched, Siri reported as Denied");
}

__attribute__((constructor))
static void SiriFix_constructor(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SiriFix_install();
    });
}
