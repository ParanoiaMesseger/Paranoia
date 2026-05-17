import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtMultimedia
import ParanoiaUiClient

// Страница голосового / видео-звонка.
//
// Поддерживает три режима:
// - mode="outgoing" — отправили Offer, ждём Answer (или peer его сразу принял
//   и идёт running). Кнопка «Завершить».
// - mode="incoming" — нам прислали Offer; кнопки «Принять/Отклонить».
// - mode="running"  — звонок установлен; кнопка «Завершить» + камера.
//
// Если в сборке есть video (VideoAvailable): фон страницы — удалённое видео,
// сверху-справа маленькое окошко локального preview, внизу — кнопка камеры.
Rectangle {
    id: root
    objectName: "CallPage"
    color: Theme.bgPrimary

    property string mode: "outgoing"  // outgoing/incoming/running
    property string peerName: CallControl ? CallControl.currentPeer : ""
    property string lastError: ""
    property int elapsedSec: 0

    function refreshModeFromState() {
        if (!CallControl) return
        if (CallControl.callState === "running") mode = "running"
        else if (CallControl.callState === "outgoing") mode = "outgoing"
        else if (CallControl.callState === "incoming") mode = "incoming"
    }

    Component.onCompleted: refreshModeFromState()
    Component.onDestruction: {
        if (Call) {
            Call.setRemoteVideoOutput(null)
            Call.setLocalVideoOutput(null)
        }
    }

    Connections {
        target: VoIPAvailable ? CallControl : null
        function onCallStateChanged() { refreshModeFromState() }
        function onCallConnected() { elapsedSec = 0; mode = "running" }
        function onCallEnded(reason) {
            if (typeof stackView !== "undefined" && stackView) {
                stackView.pop()
            }
        }
        function onControllerError(msg) { lastError = msg }
    }

    // Ошибки самого CallEngine (mic/камера/кодек) тоже должны быть видны
    // пользователю — иначе кнопка «Вкл. камеру» при сбое выглядит как
    // неработающая.
    Connections {
        target: VoIPAvailable ? Call : null
        function onErrorOccurred(msg) {
            // Состояние FFI («ffi-state:…») оставляем только в логе — это
            // диагностика, а не пользовательская ошибка.
            if (typeof msg === "string" && msg.indexOf("ffi-state:") === 0) return
            lastError = msg
        }
    }

    Timer {
        id: tickTimer
        interval: 1000
        repeat: true
        running: mode === "running"
        onTriggered: elapsedSec += 1
    }

    // ── Удалённое видео (фон страницы) ─────────────────────────────────
    VideoOutput {
        id: remoteVideo
        anchors.fill: parent
        visible: VideoAvailable && mode === "running"
                 && (CallControl.remoteHasVideo || (Call && Call.remoteVideoActive))
        fillMode: VideoOutput.PreserveAspectCrop
        Component.onCompleted: {
            if (Call) Call.setRemoteVideoOutput(remoteVideo)
        }
    }

    // ── Локальный preview (overlay в углу) ─────────────────────────────
    Rectangle {
        id: localPreviewFrame
        visible: VideoAvailable && mode === "running" && Call && Call.videoActive
        width: Math.min(parent.width * 0.28, 240)
        height: width * 9 / 16
        color: "#000000"
        radius: 8
        border.color: Theme.border
        border.width: 1
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 16
        z: 10

        VideoOutput {
            id: localPreview
            anchors.fill: parent
            anchors.margins: 2
            fillMode: VideoOutput.PreserveAspectCrop
            Component.onCompleted: {
                if (Call) Call.setLocalVideoOutput(localPreview)
            }
        }
    }

    // ── Текстовый блок (имя, статус, ошибка) ───────────────────────────
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 16

        Label {
            Layout.alignment: Qt.AlignHCenter
            text: peerName.length > 0 ? peerName : qsTr("Звонок")
            font.pixelSize: 28
            color: remoteVideo.visible ? "white" : Theme.textPrimary
            style: remoteVideo.visible ? Text.Outline : Text.Normal
            styleColor: "black"
        }

        Label {
            Layout.alignment: Qt.AlignHCenter
            text: {
                if (!VoIPAvailable) return qsTr("VoIP недоступен")
                if (mode === "outgoing") return qsTr("Вызываем…")
                if (mode === "incoming") {
                    return CallControl.remoteHasVideo
                        ? qsTr("Входящий видеозвонок")
                        : qsTr("Входящий звонок")
                }
                if (mode === "running") {
                    const mm = Math.floor(elapsedSec / 60).toString().padStart(2, "0")
                    const ss = (elapsedSec % 60).toString().padStart(2, "0")
                    return qsTr("В разговоре") + " — " + mm + ":" + ss
                }
                return ""
            }
            color: remoteVideo.visible ? "white" : Theme.textSecondary
            style: remoteVideo.visible ? Text.Outline : Text.Normal
            styleColor: "black"
            font.pixelSize: 18
        }

        Label {
            visible: lastError.length > 0
            Layout.alignment: Qt.AlignHCenter
            wrapMode: Text.Wrap
            color: "#c0392b"
            text: lastError
        }

        Item { Layout.fillHeight: true }

        // ── Опция «с видео» для исходящих ─────────────────────────────
        CheckBox {
            Layout.alignment: Qt.AlignHCenter
            visible: VideoAvailable && mode === "outgoing"
            text: qsTr("С видео")
            checked: CallControl ? CallControl.wantVideo : false
            onToggled: { if (CallControl) CallControl.wantVideo = checked }
        }

        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 16

            ParaButton {
                visible: mode === "incoming"
                implicitWidth: 100
                text: qsTr("Принять")
                onClicked: {
                    lastError = ""
                    // При входящем с видео — авто-включаем камеру у себя.
                    if (CallControl.remoteHasVideo && VideoAvailable) {
                        CallControl.wantVideo = true
                    }
                    if (!CallControl.acceptIncomingCall()) {
                        lastError = qsTr("Не удалось принять звонок")
                    }
                }
            }
            ParaButton {
                implicitWidth: 100
                visible: mode === "incoming"
                text: qsTr("Отклонить")
                onClicked: CallControl.rejectIncomingCall("user_rejected")
            }
            ParaButton {
                implicitWidth: 100
                visible: VideoAvailable && mode === "running"
                text: Call && Call.videoActive ? qsTr("Выкл. камеру") : qsTr("Вкл. камеру")
                onClicked: CallControl.toggleVideo(!(Call && Call.videoActive))
            }
            ParaButton {
                implicitWidth: 100
                visible: mode === "outgoing" || mode === "running"
                text: qsTr("Завершить")
                onClicked: CallControl.hangupCall("user_hangup")
            }
        }
    }
}
