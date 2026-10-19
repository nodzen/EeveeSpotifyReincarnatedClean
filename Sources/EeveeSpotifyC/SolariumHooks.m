#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <strings.h>
#include <os/log.h>
#include <dlfcn.h>
#pragma clang diagnostic ignored "-Warc-retain-cycles"

static BOOL solariumToggleEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"disableLiquidGlass"];
}

static Class glassEffectClass = nil;
static IMP orig_initWithEffect = NULL;
static IMP orig_setEffect = NULL;

static BOOL surfaceUsesLiquidGlass(id view) {
    NSString *name = view ? NSStringFromClass([view class]) : @"";
    return [name rangeOfString:@"LiquidGlass" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static UIVisualEffect *deGlass(id view, UIVisualEffect *effect) {
    if (!effect || !glassEffectClass) return effect;
    if (![effect isKindOfClass:glassEffectClass]) return effect;
    if (!solariumToggleEnabled()) return effect;
    if (!surfaceUsesLiquidGlass(view)) return effect;

    os_log(OS_LOG_DEFAULT, "[EeveeSpotify] Glass: replaced UIGlassEffect on %{public}@",
           view ? NSStringFromClass([view class]) : @"<nil>");
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
}

static id new_initWithEffect(id self, SEL _cmd, UIVisualEffect *effect) {
    UIVisualEffect *replacement = deGlass(self, effect);
    if (orig_initWithEffect) {
        return ((id (*)(id, SEL, UIVisualEffect *))orig_initWithEffect)(self, _cmd, replacement);
    }
    return self;
}

static void new_setEffect(id self, SEL _cmd, UIVisualEffect *effect) {
    UIVisualEffect *replacement = deGlass(self, effect);
    if (orig_setEffect) {
        ((void (*)(id, SEL, UIVisualEffect *))orig_setEffect)(self, _cmd, replacement);
    }
}

static void installGlassEffectHooks(void) {
    if (orig_initWithEffect || orig_setEffect) return;

    Class hostClass = [UIVisualEffectView class];
    glassEffectClass = NSClassFromString(@"UIGlassEffect");
    if (!hostClass || !glassEffectClass) {
        os_log(OS_LOG_DEFAULT, "[EeveeSpotify] GlassHook: missing classes host=%p glass=%p",
               (void *)(__bridge const void *)hostClass, (void *)(__bridge const void *)glassEffectClass);
        return;
    }

    Method initMethod = class_getInstanceMethod(hostClass, @selector(initWithEffect:));
    if (initMethod) {
        orig_initWithEffect = method_setImplementation(initMethod, (IMP)new_initWithEffect);
    }

    Method setMethod = class_getInstanceMethod(hostClass, @selector(setEffect:));
    if (setMethod) {
        orig_setEffect = method_setImplementation(setMethod, (IMP)new_setEffect);
    }

    os_log(OS_LOG_DEFAULT, "[EeveeSpotify] GlassHook: installed init=%p set=%p glass=%@",
           (void *)orig_initWithEffect, (void *)orig_setEffect,
           glassEffectClass);
}


static const unsigned kSkipMask = 0x1;
static IMP o_addInteraction = NULL;
static BOOL gSkipDisabled = NO;

static unsigned skipBit(NSString *n) {
    if ([n hasPrefix:@"_UIScrollPocket"] || [n hasPrefix:@"_UIScrollEdgeEffect"]) return 0x1;
    return 0;
}

static void new_addInteraction(UIView *self, SEL c, id i) {
    NSString *n = NSStringFromClass([i class]);
    unsigned b = skipBit(n);
    if (b && (kSkipMask & b) && solariumToggleEnabled() && !gSkipDisabled) {
        static int k; if (k++ < 40)
            os_log(OS_LOG_DEFAULT, "[EeveeSpotify] InteractionSkipped: %{public}@ on %{public}@", n, NSStringFromClass(self.class));
        return;
    }
    if (o_addInteraction) {
        ((void(*)(id,SEL,id))o_addInteraction)(self, c, i);
    }
}

static NSMutableDictionary *gCapsuleLayoutOrig = nil;

static void newCapsuleLayout(UIVisualEffectView *self, SEL _cmd) {
    IMP original = NULL;
    for (Class k = object_getClass(self); k && !original; k = class_getSuperclass(k)) {
        NSValue *value = gCapsuleLayoutOrig[NSStringFromClass(k)];
        original = value ? value.pointerValue : NULL;
    }
    if (original) {
        ((void (*)(UIVisualEffectView *, SEL))original)(self, _cmd);
    }

    if (!solariumToggleEnabled()) return;
    NSString *effectName = self.effect ? NSStringFromClass([self.effect class]) : nil;
    if (effectName && [effectName containsString:@"Glass"]) return;

    CGFloat width = self.bounds.size.width;
    CGFloat height = self.bounds.size.height;
    if (MIN(width, height) <= 0) return;

    self.clipsToBounds = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.cornerRadius = MIN(width, height) / 2.0;

    static NSMutableSet *loggedCapsules = nil;
    static dispatch_once_t loggedOnce;
    dispatch_once(&loggedOnce, ^{ loggedCapsules = [NSMutableSet set]; });

    NSString *className = NSStringFromClass([self class]) ?: @"<nil>";
    if (![loggedCapsules containsObject:className]) {
        [loggedCapsules addObject:className];
        os_log(OS_LOG_DEFAULT, "[EeveeSpotify] GlassCapsule: %{public}@ w=%.0f h=%.0f r=%.1f",
               className, width, height, MIN(width, height) / 2.0);
    }
}

static void installCapsuleLayout(NSString *className) {
    Class c = NSClassFromString(className);
    if (!c) return;
    if (!gCapsuleLayoutOrig) {
        gCapsuleLayoutOrig = [NSMutableDictionary dictionary];
    }
    IMP inherited = class_getMethodImplementation(class_getSuperclass(c), @selector(layoutSubviews));
    if (class_addMethod(c, @selector(layoutSubviews), (IMP)newCapsuleLayout, "v@:")) {
        gCapsuleLayoutOrig[className] = [NSValue valueWithPointer:inherited];
    } else {
        Method method = class_getInstanceMethod(c, @selector(layoutSubviews));
        gCapsuleLayoutOrig[className] = [NSValue valueWithPointer:method_setImplementation(method, (IMP)newCapsuleLayout)];
    }
}


__attribute__((constructor)) static void solarium_hooks_constructor(void) {
    // Crash guard for interaction-skip experiment.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSInteger crashes = [d integerForKey:@"eevee.skipLaunches"] + 1;
    [d setInteger:crashes forKey:@"eevee.skipLaunches"];
    gSkipDisabled = crashes >= 3;
    os_log(OS_LOG_DEFAULT, "[EeveeSpotify] SkipGuard: launches=%ld disabled=%d", (long)crashes, gSkipDisabled);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"eevee.skipLaunches"];
    });


    installGlassEffectHooks();
    Method ai = class_getInstanceMethod([UIView class], @selector(addInteraction:));
    if (ai) {
        o_addInteraction = method_setImplementation(ai, (IMP)new_addInteraction);
    }
    installCapsuleLayout(@"_TtCO22Reprise_LiquidGlassKit11LiquidGlass13ChipGlassView");
    installCapsuleLayout(@"_TtCO22Reprise_LiquidGlassKit11LiquidGlass13SearchBarView");
}
