#import "ShareViewController.h"

#import <Foundation/Foundation.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <objc/message.h>

// App Group identifier должен совпадать с одноимённой entitlement-записью у
// главного приложения и у этого extension'а. Файлы из NSExtensionItem копируем
// внутрь group container'а, потому что NSItemProvider возвращает URL во
// временной директории extension'а — после возврата из extension'а main app
// доступа к ним уже не имеет.
static NSString *const kAppGroupId      = @"group.app.paranoia.client";
static NSString *const kShareTextKey    = @"paranoia.share.text";
static NSString *const kShareFilesKey   = @"paranoia.share.files";
static NSString *const kShareDirName    = @"share";
static NSString *const kAppUrlScheme    = @"paranoia://share";

@interface ParanoiaShareViewController ()
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation ParanoiaShareViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UILabel *label = [UILabel new];
    label.text = @"Передаём в Paranoia…";
    label.textColor = UIColor.labelColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:label];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.spinner startAnimating];
    [self.view addSubview:self.spinner];

    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.topAnchor constraintEqualToAnchor:self.spinner.bottomAnchor constant:16],
    ]];

    [self collectSharedItems];
}

- (void)collectSharedItems
{
    NSExtensionContext *context = self.extensionContext;
    NSMutableString *text = [NSMutableString new];
    NSMutableArray<NSString *> *files = [NSMutableArray new];
    dispatch_group_t group = dispatch_group_create();

    for (NSExtensionItem *item in context.inputItems) {
        if (item.attributedContentText.string.length > 0) {
            if (text.length > 0) [text appendString:@"\n"];
            [text appendString:item.attributedContentText.string];
        }
        for (NSItemProvider *provider in item.attachments) {
            [self handleProvider:provider text:text files:files group:group];
        }
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [self persistShareText:text files:files];
        [self openMainAppAndFinish];
    });
}

- (void)handleProvider:(NSItemProvider *)provider
                  text:(NSMutableString *)text
                 files:(NSMutableArray<NSString *> *)files
                 group:(dispatch_group_t)group
{
    NSArray<NSString *> *typeOrder = @[
        (NSString *)kUTTypeMovie,
        (NSString *)kUTTypeImage,
        (NSString *)kUTTypeAudio,
        (NSString *)kUTTypeFileURL,
        (NSString *)kUTTypeData,
        (NSString *)kUTTypeURL,
        (NSString *)kUTTypePlainText,
        (NSString *)kUTTypeText,
    ];

    for (NSString *uti in typeOrder) {
        if (![provider hasItemConformingToTypeIdentifier:uti]) continue;
        dispatch_group_enter(group);
        [provider loadItemForTypeIdentifier:uti options:nil completionHandler:^(id<NSSecureCoding> item, NSError *error) {
            if (error) {
                dispatch_group_leave(group);
                return;
            }
            if ([uti isEqualToString:(NSString *)kUTTypePlainText] || [uti isEqualToString:(NSString *)kUTTypeText]) {
                NSString *value = nil;
                if ([(id)item isKindOfClass:NSString.class]) value = (NSString *)item;
                else if ([(id)item isKindOfClass:NSURL.class]) value = ((NSURL *)item).absoluteString;
                if (value.length > 0) {
                    @synchronized (text) {
                        if (text.length > 0) [text appendString:@"\n"];
                        [text appendString:value];
                    }
                }
            } else if ([uti isEqualToString:(NSString *)kUTTypeURL]) {
                NSURL *url = nil;
                if ([(id)item isKindOfClass:NSURL.class]) url = (NSURL *)item;
                if (url.isFileURL) {
                    NSURL *copied = [self copyToGroupContainer:url];
                    if (copied) {
                        @synchronized (files) { [files addObject:copied.absoluteString]; }
                    }
                } else if (url.absoluteString.length > 0) {
                    @synchronized (text) {
                        if (text.length > 0) [text appendString:@"\n"];
                        [text appendString:url.absoluteString];
                    }
                }
            } else {
                NSURL *src = nil;
                if ([(id)item isKindOfClass:NSURL.class]) src = (NSURL *)item;
                if (src) {
                    NSURL *copied = [self copyToGroupContainer:src];
                    if (copied) {
                        @synchronized (files) { [files addObject:copied.absoluteString]; }
                    }
                }
            }
            dispatch_group_leave(group);
        }];
        return;  // одного типа на attachment достаточно
    }
}

- (NSURL * _Nullable)copyToGroupContainer:(NSURL *)src
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *container = [fm containerURLForSecurityApplicationGroupIdentifier:kAppGroupId];
    if (!container) return nil;
    NSURL *dir = [container URLByAppendingPathComponent:kShareDirName isDirectory:YES];
    [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *suggested = src.lastPathComponent;
    if (suggested.length == 0) suggested = @"shared.bin";
    NSString *uuid = [NSUUID UUID].UUIDString;
    NSURL *dest = [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", uuid, suggested]];

    NSError *err = nil;
    if (![fm copyItemAtURL:src toURL:dest error:&err]) {
        NSLog(@"Paranoia share: copy failed %@ -> %@: %@", src, dest, err);
        return nil;
    }
    return dest;
}

- (void)persistShareText:(NSString *)text files:(NSArray<NSString *> *)files
{
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kAppGroupId];
    if (!defaults) return;
    [defaults setObject:(text ?: @"") forKey:kShareTextKey];
    [defaults setObject:(files ?: @[]) forKey:kShareFilesKey];
    [defaults synchronize];
}

- (void)openMainAppAndFinish
{
    NSURL *url = [NSURL URLWithString:kAppUrlScheme];
    // Из app extension вызов UIApplication.sharedApplication запрещён. Чтобы
    // открыть основное приложение, поднимаемся по responder chain до объекта,
    // отвечающего на selector openURL:options:completionHandler: — это даёт
    // нам live UIApplication-инстанс.
    UIResponder *responder = self;
    SEL sel = NSSelectorFromString(@"openURL:options:completionHandler:");
    while (responder) {
        if ([responder respondsToSelector:sel]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(responder, sel, url, @{}, nil);
            break;
        }
        responder = [responder nextResponder];
    }
    [self.extensionContext completeRequestReturningItems:@[] completionHandler:nil];
}

@end
