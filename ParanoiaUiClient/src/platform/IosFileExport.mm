#include "IosFileExport.hpp"

#if defined(PARANOIA_IOS)

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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

void IosFileExport::exportFile(const QString &localPath)
{
    NSString *path = localPath.toNSString();
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

#endif // PARANOIA_IOS
