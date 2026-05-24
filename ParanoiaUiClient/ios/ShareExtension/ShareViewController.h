// iOS Share Extension entry point. Реализован отдельным bundle (см.
// CMakeLists.txt → ParanoiaShareExtension). Получает NSExtensionItem'ы
// через стандартное iOS Share Sheet API, копирует файлы в общий App Group
// контейнер (group.app.paranoia.client) и кладёт текст/URI в shared
// NSUserDefaults того же App Group'а. Главное приложение читает их
// при следующем запуске или onURL:options: (paranoia://share).

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ParanoiaShareViewController : UIViewController
@end

NS_ASSUME_NONNULL_END
