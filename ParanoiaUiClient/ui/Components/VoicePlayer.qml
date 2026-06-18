import QtQuick
import QtMultimedia

// Невизуальный одиночный аудио-плеер голосовых сообщений. Грузится динамически
// (как VideoViewer/CallPage) — тянет QtMultimedia, которой нет в сборках без
// VoIP. ChatPage держит один экземпляр и переключает воспроизведение по тапу.
Item {
    id: vp

    // id сообщения, которое сейчас играет/на паузе (пусто — ничего).
    property string currentId: ""
    property bool playing: mp.playbackState === MediaPlayer.PlayingState
    property real position: mp.position
    property real duration: mp.duration
    // Бамп для реактивности биндингов в делегатах (position/playing меняются).
    property int tick: 0

    function toggle(id, url) {
        if (vp.currentId === id) {
            if (mp.playbackState === MediaPlayer.PlayingState) mp.pause()
            else mp.play()
        } else {
            vp.currentId = id
            mp.source = url
            mp.play()
        }
    }
    function stop() { mp.stop(); vp.currentId = "" }

    MediaPlayer {
        id: mp
        audioOutput: AudioOutput {}
        onPlaybackStateChanged: vp.tick++
        onPositionChanged: vp.tick++
        onMediaStatusChanged: {
            if (mediaStatus === MediaPlayer.EndOfMedia) {
                var url = mp.source
                mp.stop()
                vp.currentId = ""
                // По завершению — удалить расшифрованный playback-файл голосового.
                Chat.releasePlaybackFile(url)
            }
            vp.tick++
        }
    }
}
