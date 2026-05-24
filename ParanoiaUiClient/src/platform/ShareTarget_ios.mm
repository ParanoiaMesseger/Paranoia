// iOS реализация чтения share-target'а, который положил
// ParanoiaShareViewController в App Group контейнер (см.
// ios/ShareExtension/ShareViewController.mm). После чтения данные
// очищаются — повторный вызов вернёт пустой результат, пока пользователь
// не отправит новый share.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdlib.h>
#import <string.h>

#include <vector>

static NSString *const kAppGroupId    = @"group.app.paranoia.client";
static NSString *const kShareTextKey  = @"paranoia.share.text";
static NSString *const kShareFilesKey = @"paranoia.share.files";

namespace
{
    char *duplicateUtf8(NSString *value)
    {
        if (value == nil) return nullptr;
        const char *utf8 = value.UTF8String;
        if (utf8 == nullptr) return nullptr;
        return strdup(utf8);
    }
}

extern "C" bool paranoia_ios_take_share_target(char **out_text, char ***out_files, int *out_file_count)
{
    if (out_text) *out_text = nullptr;
    if (out_files) *out_files = nullptr;
    if (out_file_count) *out_file_count = 0;

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kAppGroupId];
    if (!defaults) return false;

    NSString *text   = [defaults stringForKey:kShareTextKey];
    NSArray *rawList = [defaults arrayForKey:kShareFilesKey];

    if ((text.length == 0) && (rawList.count == 0)) return false;

    [defaults removeObjectForKey:kShareTextKey];
    [defaults removeObjectForKey:kShareFilesKey];
    [defaults synchronize];

    if (out_text) *out_text = duplicateUtf8(text ?: @"");

    std::vector<char *> files;
    for (id entry in rawList) {
        if (![entry isKindOfClass:NSString.class]) continue;
        char *dup = duplicateUtf8((NSString *)entry);
        if (dup) files.push_back(dup);
    }
    if (!files.empty() && out_files && out_file_count) {
        char **buf = (char **)malloc(sizeof(char *) * files.size());
        for (size_t i = 0; i < files.size(); ++i) buf[i] = files[i];
        *out_files = buf;
        *out_file_count = static_cast<int>(files.size());
    } else {
        for (auto *p : files) free(p);
    }
    return true;
}

extern "C" void paranoia_ios_free_share_target(char *text, char **files, int file_count)
{
    if (text) free(text);
    if (files) {
        for (int i = 0; i < file_count; ++i)
            if (files[i]) free(files[i]);
        free(files);
    }
}
