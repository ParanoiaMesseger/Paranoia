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
    NSString *const kPendingCallOfferKey    = @"paranoia.ios.pending_call_offer";
    NSString *const kPendingCallAnswerKey   = @"paranoia.ios.pending_call_answer";

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
    // «Ответить» в баннере вызова → авто-приём после загрузки сессии (без второго
    // тапа на экране). Тап по телу баннера флаг не ставит — там кнопки выбора.
    if ([response.actionIdentifier isEqualToString:@"PARANOIA_CALL_ANSWER"]) {
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:kPendingCallAnswerKey];
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

    // Фоновый опрос — через BGProcessingTask (iOS 13+): это API, ПАРНОЕ к уже
    // объявленному в Info.plist режиму UIBackgroundModes=processing (поэтому НЕ
    // нужна правка plist). ВАЖНО: BGAppRefreshTask потребовал бы режим 'fetch',
    // которого в plist НЕТ → submitTaskRequest падал бы BGTaskSchedulerErrorCodeNotPermitted
    // и задача НЕ запускалась (это и был регресс — фон-уведомления пропали).
    // BGContinuedProcessingTask (iOS26) — для user-initiated work, для периодич.
    // опроса не годится. Система всё равно сама решает частоту (без push реал-тайма
    // не будет), но задача снова FIRING'ит в окнах системы.
    bool supportsBackgroundTasks()
    {
        if (@available(iOS 13.0, *)) {
            return NSClassFromString(@"BGTaskScheduler") != Nil &&
                   NSClassFromString(@"BGProcessingTaskRequest") != Nil;
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
        if (supportsBackgroundTasks()) return;
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        if ([defaults boolForKey:kWarningShownKey]) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *controller = topViewController();
            if (controller == nil) return;

            [defaults setBool:YES forKey:kWarningShownKey];

            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:NSLocalizedString(@"Фоновые уведомления недоступны", @"background notifications alert title")
                                 message:NSLocalizedString(@"На iOS 25 и ниже Paranoia не может проверять новые сообщения в фоне. Уведомления работают только пока приложение открыто. Для фоновых уведомлений требуется iOS 26+.", @"background notifications alert body")
                          preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"Понятно", @"alert dismiss button") style:UIAlertActionStyleDefault handler:nil]];
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
        if (!supportsBackgroundTasks()) return;
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
        if (!supportsBackgroundTasks()) return;
        id scheduler = sharedTaskScheduler();
        if (scheduler == nil) return;

        // BGProcessingTaskRequest — парный к UIBackgroundModes=processing (без правки
        // plist). initWithIdentifier:, setRequiresNetworkConnectivity:YES (нужна сеть
        // для опроса), setRequiresExternalPower:NO (не только на зарядке).
        Class requestClass = NSClassFromString(@"BGProcessingTaskRequest");
        if (requestClass == Nil) return;

        id allocatedRequest = [requestClass alloc];
        SEL initSelector = NSSelectorFromString(@"initWithIdentifier:");
        if (![allocatedRequest respondsToSelector:initSelector]) {
            NSLog(@"Paranoia: BGProcessingTaskRequest has no initWithIdentifier:");
            return;
        }
        id request = ((id (*)(id, SEL, NSString *))objc_msgSend)(allocatedRequest, initSelector,
                                                                 kPollingTaskIdentifier);
        if (request == nil) return;

        // Просим как можно скорее (система всё равно решает сама).
        NSDate *earliest = [NSDate dateWithTimeIntervalSinceNow:60];
        SEL earliestSelector = NSSelectorFromString(@"setEarliestBeginDate:");
        if ([request respondsToSelector:earliestSelector]) {
            ((void (*)(id, SEL, NSDate *))objc_msgSend)(request, earliestSelector, earliest);
        }
        SEL netSelector = NSSelectorFromString(@"setRequiresNetworkConnectivity:");
        if ([request respondsToSelector:netSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(request, netSelector, YES);
        }
        SEL powerSelector = NSSelectorFromString(@"setRequiresExternalPower:");
        if ([request respondsToSelector:powerSelector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(request, powerSelector, NO);
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

    // Категория входящего вызова с кнопками Ответить/Сбросить (#6). «Ответить» —
    // foreground (открывает приложение → штатный экран звонка подхватит оффер);
    // «Сбросить» — просто гасит уведомление (звонок без push живёт коротко).
    void ensureCallCategory()
    {
        UNNotificationAction *answer = [UNNotificationAction
            actionWithIdentifier:@"PARANOIA_CALL_ANSWER"
                           title:NSLocalizedString(@"Ответить", @"answer incoming call")
                         options:UNNotificationActionOptionForeground];
        UNNotificationAction *dismiss = [UNNotificationAction
            actionWithIdentifier:@"PARANOIA_CALL_DISMISS"
                           title:NSLocalizedString(@"Сбросить", @"reject incoming call")
                         options:UNNotificationActionOptionDestructive];
        UNNotificationCategory *cat = [UNNotificationCategory
            categoryWithIdentifier:@"PARANOIA_CALL"
                           actions:@[answer, dismiss]
                 intentIdentifiers:@[]
                           options:UNNotificationCategoryOptionNone];
        [UNUserNotificationCenter.currentNotificationCenter setNotificationCategories:[NSSet setWithObject:cat]];
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
    ensureCallCategory();
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
    content.body = [NSString stringWithFormat:NSLocalizedString(@"Новых сообщений: %llu", @"new messages notification body"), count];
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

// Локальный баннер входящего вызова (#6). Кнопки — из категории PARANOIA_CALL.
// callId нужен лишь для уникального идентификатора запроса (один звонок — один баннер).
extern "C" void paranoia_ios_show_incoming_call(const char *callId)
{
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = NSLocalizedString(@"Входящий вызов", @"incoming call title");
    content.body  = NSLocalizedString(@"Нажмите «Ответить», чтобы принять", @"incoming call body");
    content.sound = UNNotificationSound.defaultSound;
    content.categoryIdentifier = @"PARANOIA_CALL";
    content.userInfo = @{ @"incomingCall": @YES };

    NSString *cid = (callId != nullptr && callId[0] != '\0') ? @(callId) : @"x";
    NSString *reqId = [@"paranoia.incoming_call." stringByAppendingString:cid];
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:reqId
                                                                           content:content
                                                                           trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

// Handoff входящего звонка (#6): фоновый call-poll (в Qt-процессе) сохраняет
// расшифрованный конверт; при открытии приложение забирает и скармливает в
// CallSignaling.injectEnvelope (сервер `drain`-ит оффер, повторный poll пуст).
extern "C" void paranoia_ios_store_pending_call_offer(const char *json)
{
    if (json == nullptr || json[0] == '\0') return;
    [NSUserDefaults.standardUserDefaults setObject:@(json) forKey:kPendingCallOfferKey];
}

extern "C" bool paranoia_ios_take_pending_call_offer(char **out_json)
{
    if (out_json == nullptr) return false;
    *out_json = nullptr;
    NSString *offer = [NSUserDefaults.standardUserDefaults stringForKey:kPendingCallOfferKey];
    if (offer.length == 0) return false;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kPendingCallOfferKey];
    *out_json = duplicateUtf8(offer);
    return true;
}

extern "C" bool paranoia_ios_take_pending_call_answer()
{
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (![defaults boolForKey:kPendingCallAnswerKey]) return false;
    [defaults removeObjectForKey:kPendingCallAnswerKey];
    return true;
}

extern "C" void paranoia_ios_clear_delivered_notifications()
{
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center removeAllDeliveredNotifications];
    [center removeAllPendingNotificationRequests];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication.sharedApplication.applicationIconBadgeNumber = 0;
    });
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
