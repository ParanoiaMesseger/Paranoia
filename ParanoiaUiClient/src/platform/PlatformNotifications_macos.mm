#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

@interface ParanoiaMacNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation ParanoiaMacNotificationDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
    (void)center;
    (void)notification;
    if (@available(macOS 11.0, *)) {
        completionHandler(UNNotificationPresentationOptionBanner |
                          UNNotificationPresentationOptionList |
                          UNNotificationPresentationOptionSound);
    } else {
        completionHandler(UNNotificationPresentationOptionAlert |
                          UNNotificationPresentationOptionSound);
    }
}
@end

namespace
{
    ParanoiaMacNotificationDelegate *notificationDelegate()
    {
        static ParanoiaMacNotificationDelegate *delegate = [ParanoiaMacNotificationDelegate new];
        return delegate;
    }
}

extern "C" void paranoia_macos_register_notifications()
{
    UNUserNotificationCenter.currentNotificationCenter.delegate = notificationDelegate();
    UNAuthorizationOptions options = UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge;
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:options
                                                                      completionHandler:^(__unused BOOL granted,
                                                                                          __unused NSError *error) {}];
}

extern "C" void paranoia_macos_show_message_count(unsigned long long count)
{
    if (count == 0) return;

    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = @"Paranoia";
    content.body = [NSString stringWithFormat:@"Новых сообщений: %llu", count];
    content.sound = UNNotificationSound.defaultSound;
    content.badge = @(count > NSIntegerMax ? NSIntegerMax : (NSInteger)count);

    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"paranoia.new_messages"
                                                                          content:content
                                                                          trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

extern "C" void paranoia_macos_clear_delivered_notifications()
{
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center removeAllDeliveredNotifications];
    [center removeAllPendingNotificationRequests];
}
