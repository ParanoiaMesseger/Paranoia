// Нативный выбор фото из галереи на iOS через PHPickerViewController (iOS 14+).
//
// Зачем: на iOS у приложения не было нативного фото-пикера — выбор аватара падал
// в ParaFileDialog (приложение «Файлы»), а не в галерею. PHPicker запускается
// ВНЕ процесса приложения, поэтому НЕ требует доступа к Photo Library и записи
// NSPhotoLibraryUsageDescription в Info.plist — пользователь сам выбирает фото.
//
// API: paranoia_ios_pick_avatar(cb, ctx) — показывает пикер; по результату зовёт
// cb(ctx, path) с путём к временному JPEG (или nullptr при отмене/ошибке). cb
// вызывается в главном потоке (UIKit-делегат).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>

typedef void (*ParanoiaImagePickedCb)(void *ctx, const char *path);

@interface ParanoiaImagePickerDelegate : NSObject <PHPickerViewControllerDelegate>
@property(nonatomic, assign) ParanoiaImagePickedCb callback;
@property(nonatomic, assign) void *context;
@end

// Удерживаем делегат живым на время показа пикера (PHPickerViewController держит
// делегат слабо). Один выбор за раз — статической ссылки достаточно.
static ParanoiaImagePickerDelegate *g_activePickerDelegate = nil;

namespace
{
    UIViewController *topViewController()
    {
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
            if (window != nil) break;
        }
        if (window == nil) window = UIApplication.sharedApplication.keyWindow;
        UIViewController *controller = window.rootViewController;
        while (controller.presentedViewController != nil) controller = controller.presentedViewController;
        return controller;
    }

    // UIImage → временный JPEG, путь возвращается caller'у (он его прочитает и
    // удалит). Имя без коллизий: pid+addr достаточно (один пик за раз).
    NSString *writeTempJpeg(UIImage *image)
    {
        if (image == nil) return nil;
        NSData *data = UIImageJPEGRepresentation(image, 0.9);
        if (data.length == 0) return nil;
        NSString *name = [NSString stringWithFormat:@"paranoia_avatar_%@.jpg", NSUUID.UUID.UUIDString];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
        if (![data writeToFile:path atomically:YES]) return nil;
        return path;
    }

    void finish(ParanoiaImagePickerDelegate *delegate, NSString *path)
    {
        if (delegate.callback != nullptr) {
            delegate.callback(delegate.context, path.length > 0 ? path.UTF8String : nullptr);
        }
        if (g_activePickerDelegate == delegate) g_activePickerDelegate = nil;
    }
}

@implementation ParanoiaImagePickerDelegate
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results
{
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (results.count == 0) { finish(self, nil); return; } // отмена

    NSItemProvider *provider = results.firstObject.itemProvider;
    if (![provider canLoadObjectOfClass:UIImage.class]) { finish(self, nil); return; }

    ParanoiaImagePickerDelegate *strongSelf = self; // удержать до конца async-загрузки
    [provider loadObjectOfClass:UIImage.class
              completionHandler:^(__kindof id<NSItemProviderReading> object, NSError *error) {
                  UIImage *image = [object isKindOfClass:UIImage.class] ? (UIImage *)object : nil;
                  // loadObject завершается в фоне → возвращаемся в главный поток.
                  dispatch_async(dispatch_get_main_queue(), ^{
                      NSString *path = (image != nil && error == nil) ? writeTempJpeg(image) : nil;
                      finish(strongSelf, path);
                  });
              }];
}
@end

extern "C" void paranoia_ios_pick_avatar(ParanoiaImagePickedCb cb, void *ctx)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = topViewController();
        if (host == nil) { if (cb) cb(ctx, nullptr); return; }

        PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
        config.selectionLimit = 1;
        config.filter = [PHPickerFilter imagesFilter];

        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
        ParanoiaImagePickerDelegate *delegate = [ParanoiaImagePickerDelegate new];
        delegate.callback = cb;
        delegate.context = ctx;
        picker.delegate = delegate;
        g_activePickerDelegate = delegate; // strong ref на время показа

        [host presentViewController:picker animated:YES completion:nil];
    });
}
