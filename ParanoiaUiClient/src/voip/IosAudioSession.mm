#include "IosAudioSession.hpp"

#if defined(Q_OS_IOS) || defined(OS_IOS) || (defined(__APPLE__) && TARGET_OS_IOS)
#define PARANOIA_VOIP_IOS 1
#else
#define PARANOIA_VOIP_IOS 0
#endif

#if PARANOIA_VOIP_IOS
#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>
#endif

namespace paranoia::voip
{
    void iosAudioSessionConfigureForVoiceCall()
    {
#if PARANOIA_VOIP_IOS
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *error          = nil;

        AVAudioSessionCategoryOptions options =
            AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth;
        if (@available(iOS 10.0, *)) {
            options |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
        }

        if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                              mode:AVAudioSessionModeVoiceChat
                           options:options
                             error:&error]) {
            NSLog(@"Paranoia: AVAudioSession setCategory failed: %@", error);
            error = nil;
        }

        // Явный override на speaker — на устройствах с приёмником
        // (iPhone) DefaultToSpeaker в категории работает, но при смене
        // route может слететь. Доп. вызов гарантирует, что после старта
        // звонка вывод идёт через громкий динамик.
        if (![session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error]) {
            NSLog(@"Paranoia: AVAudioSession overrideOutputAudioPort failed: %@", error);
            error = nil;
        }

        if (![session setActive:YES error:&error]) {
            NSLog(@"Paranoia: AVAudioSession setActive YES failed: %@", error);
        }
#endif
    }

    void iosAudioSessionDeactivate()
    {
#if PARANOIA_VOIP_IOS
        AVAudioSession *session = [AVAudioSession sharedInstance];
        NSError *error          = nil;
        if (![session setActive:NO
                    withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                          error:&error]) {
            NSLog(@"Paranoia: AVAudioSession setActive NO failed: %@", error);
        }
#endif
    }
}
