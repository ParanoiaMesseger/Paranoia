import QtQuick
import QtQuick.Controls
import QtMultimedia
import ParanoiaUiClient

// Полноэкранный проигрыватель видео-вложений. Пушится на stackView из ChatPage
// (openVideo) после материализации расшифрованного mp4 во временный файл.
// Тянет QtMultimedia → грузится динамически только в VoIP/Video-сборках.
Item {
    id: viewer

    // file://-URL локального расшифрованного mp4.
    property url source
    property string title: ""

    // Жест «назад» (свайп/Esc) закрывает плеер, а не диалог.
    signal back()

    function close() {
        player.stop()
        // Удаляем расшифрованный playback-файл — plaintext не должен залёживаться.
        Chat.releasePlaybackFile(viewer.source)
        if (StackView.view) StackView.view.pop()
        else viewer.back()
    }

    Rectangle { anchors.fill: parent; color: "#000000" }

    MediaPlayer {
        id: player
        source: viewer.source
        videoOutput: videoOut
        audioOutput: AudioOutput {}
        onErrorOccurred: function(err, str) { console.warn("VideoViewer playback error:", str) }
        Component.onCompleted: play()
    }

    VideoOutput {
        id: videoOut
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectFit
    }

    // Тап по видео — показать/скрыть контролы и play/pause.
    property bool controlsVisible: true
    Timer {
        id: hideTimer
        interval: 3000
        onTriggered: if (player.playbackState === MediaPlayer.PlayingState) viewer.controlsVisible = false
    }
    MouseArea {
        anchors.fill: parent
        onClicked: {
            viewer.controlsVisible = !viewer.controlsVisible
            if (viewer.controlsVisible) hideTimer.restart()
        }
    }

    // Спиннер пока буферизуется/грузится.
    BusyIndicator {
        anchors.centerIn: parent
        running: player.mediaStatus === MediaPlayer.LoadingMedia
                 || player.mediaStatus === MediaPlayer.StalledMedia
        visible: running
    }

    // Центральная кнопка play/pause.
    Rectangle {
        anchors.centerIn: parent
        width: 76; height: 76; radius: 38
        color: "#80000000"
        border.width: 1; border.color: "#55FFFFFF"
        visible: viewer.controlsVisible
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }
        AppIcon {
            anchors.centerIn: parent
            anchors.horizontalCenterOffset: player.playbackState === MediaPlayer.PlayingState ? 0 : 3
            width: 34; height: 34
            name: player.playbackState === MediaPlayer.PlayingState ? "pause" : "play"
            iconColor: "#FFFFFF"
            fillColor: "#FFFFFF"
            strokeWidth: 2
        }
        MouseArea {
            anchors.fill: parent
            onClicked: {
                if (player.playbackState === MediaPlayer.PlayingState) player.pause()
                else player.play()
                viewer.controlsVisible = true
                hideTimer.restart()
            }
        }
    }

    // Верхняя панель: назад + название.
    Rectangle {
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 56
        color: "#99000000"
        visible: viewer.controlsVisible
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Rectangle {
            id: backBtn
            anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 8 }
            width: 40; height: 40; radius: Theme.radiusSm
            color: backArea.containsMouse ? "#33FFFFFF" : "transparent"
            AppIcon {
                anchors.centerIn: parent
                width: 22; height: 22
                name: "chevronLeft"
                iconColor: "#FFFFFF"
                strokeWidth: 2
            }
            MouseArea {
                id: backArea
                anchors.fill: parent
                hoverEnabled: true
                onClicked: viewer.close()
            }
        }
        Text {
            anchors { left: backBtn.right; right: parent.right; verticalCenter: parent.verticalCenter
                      leftMargin: 6; rightMargin: 12 }
            text: viewer.title
            color: "#FFFFFF"
            font.pixelSize: Theme.fontMd
            font.family: Theme.fontFamily
            elide: Text.ElideRight
        }
    }

    // Нижняя панель: позиция + слайдер + длительность.
    function fmt(ms) {
        if (ms <= 0 || isNaN(ms)) return "0:00"
        var s = Math.floor(ms / 1000)
        var m = Math.floor(s / 60)
        s = s % 60
        return m + ":" + (s < 10 ? "0" + s : s)
    }
    Rectangle {
        anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
        height: 56
        color: "#99000000"
        visible: viewer.controlsVisible
        opacity: visible ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 150 } }

        Row {
            anchors.fill: parent
            anchors.leftMargin: 14
            anchors.rightMargin: 14
            spacing: 10

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 44
                horizontalAlignment: Text.AlignHCenter
                text: viewer.fmt(player.position)
                color: "#FFFFFF"
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
            }
            Slider {
                id: seek
                width: parent.width - 44 * 2 - 10 * 2
                anchors.verticalCenter: parent.verticalCenter
                from: 0
                to: Math.max(1, player.duration)
                value: player.position
                // Перематываем только по действию пользователя, чтобы биндинг
                // value=position не дёргал seek во время обычного проигрывания.
                onMoved: player.position = value
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: 44
                horizontalAlignment: Text.AlignHCenter
                text: viewer.fmt(player.duration)
                color: "#FFFFFF"
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
            }
        }
    }

    // Esc / Back закрывают плеер.
    focus: true
    Keys.onEscapePressed: viewer.close()
    Keys.onBackPressed: viewer.close()
    StackView.onActivated: { viewer.forceActiveFocus(); hideTimer.restart() }
}
