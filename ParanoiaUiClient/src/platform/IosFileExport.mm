#include "IosFileExport.hpp"

#if defined(PARANOIA_IOS)

#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Сохранить медиа-файл (фото/видео) в системную галерею (Photos) через
// PHPhotoLibrary с add-only авторизацией (NSPhotoLibraryAddUsageDescription).
// Результат — в callback (cb), который ChatBackend маршалит обратно в Qt-поток.
// Временный исходник удаляется после записи.
extern "C" void paranoia_ios_save_media_to_photos(const char *cpath, bool isVideo, const char *cfilename,
                                                   void (*cb)(void *ctx, bool ok, const char *err),
                                                   void *ctx)
{
    NSString *path     = [NSString stringWithUTF8String:(cpath ? cpath : "")];
    NSString *filename = [NSString stringWithUTF8String:(cfilename ? cfilename : "")];
    NSURL *url         = [NSURL fileURLWithPath:path];
    void (^report)(bool, NSString *) = ^(bool ok, NSString *err) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (cb)
            cb(ctx, ok, ok ? "" : (err ? err.UTF8String : "save_failed"));
    };
    void (^doSave)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
            // originalFilename несёт расширение (mp4/jpg) — иначе Photos не
            // определяет тип ресурса (временный файл на диске — .bin) и падает
            // PHPhotosErrorInvalidResource.
            PHAssetResourceCreationOptions *opt = [[PHAssetResourceCreationOptions alloc] init];
            if (filename.length > 0)
                opt.originalFilename = filename;
            [req addResourceWithType:(isVideo ? PHAssetResourceTypeVideo : PHAssetResourceTypePhoto)
                             fileURL:url
                             options:opt];
        }
            completionHandler:^(BOOL success, NSError *error) {
                NSString *msg = error ? [NSString stringWithFormat:@"%@ (%ld)",
                                                                   error.localizedDescription, (long)error.code]
                                      : nil;
                report(success, msg);
            }];
    };
    if (@available(iOS 14.0, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                                   handler:^(PHAuthorizationStatus status) {
                                                       if (status == PHAuthorizationStatusAuthorized
                                                           || status == PHAuthorizationStatusLimited)
                                                           doSave();
                                                       else
                                                           report(false, @"no_photo_permission");
                                                   }];
    } else {
        doSave();
    }
}

#include <QDir>
#include <QFileInfo>
#include <QStandardPaths>

// Делегат живёт вместе с пикером (через associated object) и при уничтожении
// чистит временный файл. asCopy:YES → система копирует файл в выбранное место,
// оригинал во временном каталоге нам больше не нужен.
@interface ParanoiaExportPickerDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic, copy) NSString *tempPath;
@end

@implementation ParanoiaExportPickerDelegate
- (void)dealloc
{
    if (_tempPath)
        [[NSFileManager defaultManager] removeItemAtPath:_tempPath error:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    Q_UNUSED(controller); Q_UNUSED(urls);
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    Q_UNUSED(controller);
}
@end

namespace {
UIViewController *topViewController()
{
    UIWindow *keyWindow = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]])
            continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { keyWindow = w; break; }
        }
        if (keyWindow) break;
    }
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController)
        vc = vc.presentedViewController;
    return vc;
}
} // namespace

QString IosFileExport::prepareExportPath(const QString &filename)
{
    QString name = QFileInfo(filename.trimmed()).fileName();
    if (name.isEmpty())
        name = QStringLiteral("paranoia-export.json");
    const QString dir = QDir(QStandardPaths::writableLocation(QStandardPaths::TempLocation))
                            .filePath(QStringLiteral("paranoia-export"));
    QDir().mkpath(dir);
    return QDir(dir).filePath(name);
}

static void presentExportPicker(NSString *path)
{
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // Файл не записан (ошибка экспорта уже показана вызывающим) — ничего не делаем.
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];

    UIDocumentPickerViewController *picker = nil;
    if (@available(iOS 14.0, *)) {
        picker = [[UIDocumentPickerViewController alloc] initForExportingURLs:@[ url ] asCopy:YES];
    } else {
        picker = [[UIDocumentPickerViewController alloc] initWithURL:url
                                                             inMode:UIDocumentPickerModeExportToService];
    }

    ParanoiaExportPickerDelegate *delegate = [[ParanoiaExportPickerDelegate alloc] init];
    delegate.tempPath = path;
    picker.delegate = delegate;
    // Удерживаем делегат на время жизни пикера (ARC: associated object с RETAIN).
    objc_setAssociatedObject(picker, "paranoiaExportDelegate", delegate,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIViewController *root = topViewController();
    if (!root) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return;
    }
    [root presentViewController:picker animated:YES completion:nil];
}

void IosFileExport::exportFile(const QString &localPath)
{
    presentExportPicker(localPath.toNSString());
}

// C-обёртка для сохранения НЕ-медиа вложения в «Файлы» (document picker).
extern "C" void paranoia_ios_export_file(const char *cpath)
{
    presentExportPicker([NSString stringWithUTF8String:(cpath ? cpath : "")]);
}

#endif // PARANOIA_IOS
