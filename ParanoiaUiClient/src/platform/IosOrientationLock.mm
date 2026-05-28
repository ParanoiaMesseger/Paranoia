#if defined(Q_OS_IOS) || defined(OS_IOS) || (defined(__APPLE__) && TARGET_OS_IOS)
#define PARANOIA_IOS 1
#else
#define PARANOIA_IOS 0
#endif

#if PARANOIA_IOS
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Категория к AppDelegate, чтобы UIKit мог опросить разрешённые ориентации.
// AppDelegate генерируется Qt, поэтому добавляем поведение через associated
// object: при наличии lock — возвращаем только portrait, иначе — All.

static UIInterfaceOrientationMask g_lockedMask = UIInterfaceOrientationMaskAll;

extern "C" void paranoia_ios_lock_orientation_portrait()
{
    g_lockedMask = UIInterfaceOrientationMaskPortrait;
    if (@available(iOS 16.0, *)) {
        // На iOS 16+ требуется явно попросить геометрию обновиться.
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    scene = (UIWindowScene *)s;
                    break;
                }
            }
            if (scene) {
                UIWindowSceneGeometryPreferencesIOS *prefs =
                    [[UIWindowSceneGeometryPreferencesIOS alloc]
                        initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait];
                [scene requestGeometryUpdateWithPreferences:prefs
                                               errorHandler:^(NSError * _Nonnull error) {
                    NSLog(@"Paranoia: orientation lock geometry update failed: %@", error);
                }];
            }
            [UIViewController attemptRotationToDeviceOrientation];
        });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIViewController attemptRotationToDeviceOrientation];
        });
    }
}

extern "C" void paranoia_ios_unlock_orientation()
{
    g_lockedMask = UIInterfaceOrientationMaskAll;
    if (@available(iOS 16.0, *)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    scene = (UIWindowScene *)s;
                    break;
                }
            }
            if (scene) {
                UIWindowSceneGeometryPreferencesIOS *prefs =
                    [[UIWindowSceneGeometryPreferencesIOS alloc]
                        initWithInterfaceOrientations:UIInterfaceOrientationMaskAll];
                [scene requestGeometryUpdateWithPreferences:prefs errorHandler:nil];
            }
        });
    }
}

// Перехватываем supportedInterfaceOrientations на AppDelegate Qt'шного приложения
// через swizzle. Делаем это +load — выполнится один раз при загрузке бандла.
@interface NSObject (ParanoiaOrientationLock)
@end

@implementation NSObject (ParanoiaOrientationLock)

+ (void)load
{
    // Делается один раз для класса QIOSApplicationDelegate / QtAppDelegate /
    // ApplicationDelegate (Qt именует его по-разному в разных версиях).
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class delegateClass = nil;
        for (NSString *name in @[ @"QIOSApplicationDelegate", @"QApplicationDelegate", @"ApplicationDelegate" ]) {
            Class c = NSClassFromString(name);
            if (c) { delegateClass = c; break; }
        }
        if (!delegateClass) return;
        SEL sel = @selector(application:supportedInterfaceOrientationsForWindow:);
        IMP impl = imp_implementationWithBlock(^UIInterfaceOrientationMask(id self, UIApplication *app, UIWindow *win) {
            return g_lockedMask;
        });
        class_addMethod(delegateClass, sel, impl, "I@:@@");
    });
}

@end

#else
extern "C" void paranoia_ios_lock_orientation_portrait() {}
extern "C" void paranoia_ios_unlock_orientation() {}
#endif
