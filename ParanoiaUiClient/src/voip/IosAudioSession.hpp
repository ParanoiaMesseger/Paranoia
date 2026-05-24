#pragma once

namespace paranoia::voip
{
    // Конфигурирует AVAudioSession для голосового/видео звонка:
    // category=PlayAndRecord, mode=VoiceChat, options=DefaultToSpeaker|AllowBluetooth,
    // setActive:YES. Без этого QAudioSource/QAudioSink на iOS работают в
    // дефолтной категории — звук уходит в earpiece, а одновременный recording
    // ведёт к приглушению воспроизведения. Прямой аналог
    // ParanoiaAndroidUtils.setVoiceCallMode(true, speakerphone=true).
    //
    // Безопасно вызывать с любой платформы — на не-iOS no-op.
    void iosAudioSessionConfigureForVoiceCall();

    // Снимает категорию VoIP-звонка и деактивирует session с
    // NotifyOthersOnDeactivation, чтобы фоновые приложения (музыка и т. п.)
    // снова могли вернуть звук.
    void iosAudioSessionDeactivate();
}
