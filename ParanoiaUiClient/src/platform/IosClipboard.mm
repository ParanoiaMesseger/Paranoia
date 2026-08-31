#include "IosClipboard.hpp"

#if defined(PARANOIA_IOS)

#import <UIKit/UIKit.h>

QString paranoiaIosClipboardText()
{
    NSString *s = UIPasteboard.generalPasteboard.string;
    return s ? QString::fromNSString(s) : QString();
}

#endif
