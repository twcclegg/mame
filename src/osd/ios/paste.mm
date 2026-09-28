
//============================================================
//
//  clipboard.mm - iOS clipboard handler
//
//============================================================

// MAME headers
#include "emu.h"

// IOS headers
#include "iososd.h"

#import <UIKit/UIPasteboard.h>
#include <AvailabilityMacros.h>

//============================================================
//  osd_get_clipboard_text
//============================================================

std::string osd_get_clipboard_text(void)
{
#if TARGET_OS_IOS || (defined(TARGET_OS_VISION) && TARGET_OS_VISION)   // no clipboard on tvOS
    @autoreleasepool {
        if (UIPasteboard.generalPasteboard.hasStrings)
            return std::string(UIPasteboard.generalPasteboard.string.UTF8String);
        else
            return std::string();
    }
#else
    return std::string();
#endif
}

std::error_condition osd_set_clipboard_text(std::string_view text) noexcept
{
    return std::error_condition();
}
