#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <dispatch/dispatch.h>
#import <objc/message.h>
#import <stdlib.h>
#import <string.h>

extern "C" void paranoia_platform_trigger_background_poll();

@interface ParanoiaIosNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

namespace
{
    NSString *const kPollingTaskIdentifier  = @"com.paranoia.polling";
    NSString *const kWarningShownKey        = @"paranoia.ios.background_warning_shown";
    NSString *const kOpenProfileIdKey       = @"paranoia.ios.open_profile_id";
    NSString *const kOpenPeerKey            = @"paranoia.ios.open_peer";
    NSString *const kUserInfoProfileIdKey   = @"profileId";
    NSString *const kUserInfoPeerKey        = @"peer";

    // Сохраняет target открытия чата в NSUserDefaults. Используется и при
    // тёплом тапе (didReceiveNotificationResponse:), и переживает cold start —
    // QML при запуске зовёт takeOpenTargetFromNotification и забирает.
    void persistOpenTarget(NSString *profileId, NSString *peer)
    {
        if (peer.length == 0) return;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setObject:(profileId ?: @"") forKey:kOpenProfileIdKey];
        [defaults setObject:peer forKey:kOpenPeerKey];
    }
}

@implementation ParanoiaIosNotificationDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
    (void)center;
    (void)notification;
    if (@available(iOS 14.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner |
                          UNNotificationPresentationOptionList |
                          UNNotificationPresentationOptionSound);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert |
                          UNNotificationPresentationOptionSound);
    }
}

// Срабатывает при тапе по уведомлению (и при тёплом старте, и при cold start
// после запуска приложения). userInfo приходит из content.userInfo, которую
// мы кладём в paranoia_ios_show_message_count.
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
didReceiveNotificationResponse:(UNNotificationResponse *)response
         withCompletionHandler:(void (^)(void))completionHandler
{
    (void)center;
    NSDictionary *userInfo = response.notification.request.content.userInfo;
    NSString *profileId    = userInfo[kUserInfoProfileIdKey];
    NSString *peer         = userInfo[kUserInfoPeerKey];
    if ([profileId isKindOfClass:NSString.class] == NO) profileId = @"";
    if ([peer isKindOfClass:NSString.class]) {
        persistOpenTarget(profileId, peer);
    }
    completionHandler();
}
@end

namespace
{
    ParanoiaIosNotificationDelegate *notificationDelegate()
    {
        static ParanoiaIosNotificationDelegate *delegate = [ParanoiaIosNotificationDelegate new];
        return delegate;
    }

    bool supportsContinuedProcessing()
    {
        if (@available(iOS 26.0, *)) {
            return NSClassFromString(@"BGContinuedProcessingTaskRequest") != Nil &&
                   NSClassFromString(@"BGTaskScheduler") != Nil;
        }
        return false;
    }

    UIViewController *topViewController()
    {
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *candidate in windowScene.windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
            }
            if (window != nil) break;
        }
        if (window == nil) window = UIApplication.sharedApplication.keyWindow;

        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController != nil) controller = controller.presentedViewController;
        return controller;
    }

    void showLegacyIosWarningOnce()
    {
        if (supportsContinuedProcessing()) return;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults boolForKey:kWarningShownKey]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *controller = topViewController();
            if (controller == nil) return;

            [defaults setBool:YES forKey:kWarningShownKey];

            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"Фоновые уведомления недоступны"
                                 message:@"На iOS 25 и ниже Paranoia не может проверять новые сообщения в фоне. Уведомления работают только пока приложение открыто. Для фоновых уведомлений требуется iOS 26+."
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Понятно" style:UIAlertActionStyleDefault handler:nil]];
            [controller presentViewController:alert animated:YES completion:nil];
        });
    }

    id sharedTaskScheduler()
    {
        Class schedulerClass = NSClassFromString(@"BGTaskScheduler");
        if (schedulerClass == Nil) return nil;
        return ((id (*)(id, SEL))objc_msgSend)(schedulerClass, NSSelectorFromString(@"sharedScheduler"));
    }

    void completeTask(id task, BOOL success)
    {
        SEL completeSelector = NSSelectorFromString(@"setTaskCompletedWithSuccess:");
        if (task != nil && [task respondsToSelector:completeSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(task, completeSelector, success);
        }
    }

    void schedulePollingTask();

    void handlePollingTask(id task)
    {
        schedulePollingTask();

        SEL expirationSelector = NSSelectorFromString(@"setExpirationHandler:");
        if (task != nil && [task respondsToSelector:expirationSelector]) {
            void (^expirationHandler)(void) = ^{
                completeTask(task, NO);
            };
            ((void (*)(id, SEL, id))objc_msgSend)(task, expirationSelector, expirationHandler);
        }

        paranoia_platform_trigger_background_poll();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            completeTask(task, YES);
        });
    }

    void registerPollingTask()
    {
        if (!supportsContinuedProcessing()) return;
        id scheduler = sharedTaskScheduler();
        SEL registerSelector = NSSelectorFromString(@"registerForTaskWithIdentifier:usingQueue:launchHandler:");
        if (scheduler == nil || ![scheduler respondsToSelector:registerSelector]) return;

        id launchHandler = ^(id task) {
            handlePollingTask(task);
        };
        BOOL registered = ((BOOL (*)(id, SEL, NSString *, dispatch_queue_t, id))objc_msgSend)(
            scheduler, registerSelector, kPollingTaskIdentifier, dispatch_get_main_queue(), launchHandler);
        if (!registered) NSLog(@"Paranoia: failed to register BGContinuedProcessingTask");
    }

    void schedulePollingTask()
    {
        if (!supportsContinuedProcessing()) return;
        id scheduler = sharedTaskScheduler();
        if (scheduler == nil) return;

        Class requestClass = NSClassFromString(@"BGContinuedProcessingTaskRequest");
        if (requestClass == Nil) return;

        id allocatedRequest = [requestClass alloc];
        id request = nil;
        SEL visibleInitSelector = NSSelectorFromString(@"initWithIdentifier:title:subtitle:");
        if ([allocatedRequest respondsToSelector:visibleInitSelector]) {
            request = ((id (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(
                allocatedRequest,
                visibleInitSelector,
                kPollingTaskIdentifier,
                @"Paranoia",
                @"Проверка новых сообщений");
        } else {
            SEL legacyInitSelector = NSSelectorFromString(@"initWithIdentifier:");
            if (![allocatedRequest respondsToSelector:legacyInitSelector]) {
                NSLog(@"Paranoia: BGContinuedProcessingTaskRequest has no supported initializer");
                return;
            }
            request = ((id (*)(id, SEL, NSString *))objc_msgSend)(allocatedRequest,
                                                                   legacyInitSelector,
                                                                   kPollingTaskIdentifier);
        }
        if (request == nil) return;

        NSDate *earliest = [NSDate dateWithTimeIntervalSinceNow:10 + arc4random_uniform(231)];
        SEL earliestSelector = NSSelectorFromString(@"setEarliestBeginDate:");
        if ([request respondsToSelector:earliestSelector]) {
            ((void (*)(id, SEL, NSDate *))objc_msgSend)(request, earliestSelector, earliest);
        }
        SEL networkSelector = NSSelectorFromString(@"setRequiresNetworkConnectivity:");
        if ([request respondsToSelector:networkSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(request, networkSelector, YES);
        }

        NSError *error = nil;
        SEL submitSelector = NSSelectorFromString(@"submitTaskRequest:error:");
        if ([scheduler respondsToSelector:submitSelector]) {
            BOOL submitted = ((BOOL (*)(id, SEL, id, NSError **))objc_msgSend)(scheduler, submitSelector, request, &error);
            if (!submitted && error != nil) NSLog(@"Paranoia: failed to schedule background polling: %@", error);
        }
    }

    void cancelPollingTask()
    {
        id scheduler = sharedTaskScheduler();
        SEL cancelSelector = NSSelectorFromString(@"cancelTaskRequestWithIdentifier:");
        if (scheduler != nil && [scheduler respondsToSelector:cancelSelector]) {
            ((void (*)(id, SEL, NSString *))objc_msgSend)(scheduler, cancelSelector, kPollingTaskIdentifier);
        }
    }

    void requestLocalNotificationPermission()
    {
        UNUserNotificationCenter.currentNotificationCenter.delegate = notificationDelegate();
        UNAuthorizationOptions options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
        [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:options
                                                                           completionHandler:^(__unused BOOL granted,
                                                                                               __unused NSError *error) {}];
    }

    // Дублирующая C-строка для возврата через extern "C" интерфейс — caller
    // (PlatformNotifications.cpp) обязан освободить через paranoia_ios_free_string.
    char *duplicateUtf8(NSString *value)
    {
        if (value == nil || value.length == 0) return nullptr;
        const char *utf8 = value.UTF8String;
        if (utf8 == nullptr) return nullptr;
        return strdup(utf8);
    }
}

extern "C" void paranoia_ios_register_background_tasks()
{
    requestLocalNotificationPermission();
    registerPollingTask();
    showLegacyIosWarningOnce();
}

extern "C" void paranoia_ios_schedule_background_polling()
{
    schedulePollingTask();
}

extern "C" void paranoia_ios_cancel_background_polling()
{
    cancelPollingTask();
}

extern "C" void paranoia_ios_show_message_count(unsigned long long count, const char *profileId, const char *peer)
{
    if (count == 0) return;
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"Paranoia";
    content.body = [NSString stringWithFormat:@"Новых сообщений: %llu", count];
    content.sound = UNNotificationSound.defaultSound;
    content.badge = @(count > NSIntegerMax ? NSIntegerMax : (NSInteger)count);

    // Кладём target в userInfo — забираем обратно в didReceiveNotificationResponse:
    // при тапе. Пустой peer оставляем (значит «общий» баннер без целевого чата).
    NSString *profileIdStr = (profileId != nullptr) ? @(profileId) : @"";
    NSString *peerStr      = (peer != nullptr) ? @(peer) : @"";
    content.userInfo = @{
        kUserInfoProfileIdKey: profileIdStr ?: @"",
        kUserInfoPeerKey:      peerStr      ?: @"",
    };

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"paranoia.new_messages"
                                                                           content:content
                                                                           trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

extern "C" bool paranoia_ios_take_open_target(char **out_profile_id, char **out_peer)
{
    if (out_profile_id == nullptr || out_peer == nullptr) return false;
    *out_profile_id = nullptr;
    *out_peer       = nullptr;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *peer           = [defaults stringForKey:kOpenPeerKey];
    if (peer.length == 0) return false;

    NSString *profileId = [defaults stringForKey:kOpenProfileIdKey];
    [defaults removeObjectForKey:kOpenProfileIdKey];
    [defaults removeObjectForKey:kOpenPeerKey];

    *out_profile_id = duplicateUtf8(profileId);
    *out_peer       = duplicateUtf8(peer);
    return true;
}

extern "C" void paranoia_ios_free_string(char *value)
{
    if (value != nullptr) free(value);
}
