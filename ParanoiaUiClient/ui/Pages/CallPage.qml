import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Effects
import QtMultimedia
import ParanoiaUiClient

// Страница голосового / видео-звонка.
//
// Поддерживает три режима:
// - mode="outgoing" — отправили Offer, ждём Answer. Кнопка «Завершить».
// - mode="incoming" — нам прислали Offer; кнопки «Принять/Отклонить».
// - mode="running"  — звонок установлен; mic mute / camera toggle / camera switch / hangup.
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

    Component.onCompleted: {
        refreshModeFromState()
        if (typeof OrientationLock !== "undefined" && OrientationLock) {
            OrientationLock.lockPortrait()
        }
    }
    Component.onDestruction: {
        if (Call) {
            Call.setRemoteVideoOutput(null)
            Call.setLocalVideoOutput(null)
        }
        if (typeof OrientationLock !== "undefined" && OrientationLock) {
            OrientationLock.unlock()
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

    Connections {
        target: VoIPAvailable ? Call : null
        function onErrorOccurred(msg) {
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
        // Видимость теперь зависит от РЕАЛЬНОЙ активности видео-кадров
        // (Call.remoteVideoActive сбрасывается в C++ по таймауту 1.5s без
        // фреймов), а не только от заявленного remoteHasVideo. Иначе после
        // выключения камеры peer'ом тут остаётся замёрзший последний кадр.
        visible: VideoAvailable && mode === "running" && Call && Call.remoteVideoActive
        fillMode: VideoOutput.PreserveAspectCrop
        Component.onCompleted: {
            if (Call) Call.setRemoteVideoOutput(remoteVideo)
        }
    }

    // Аватар-заглушка: круг с первой буквой имени собеседника. Показывается
    // когда удалённого видео нет (камера выключена / не была включена) во
    // время активного звонка. Цвет — акцент темы (одиночные звонки, групповых
    // не планируем); позже сюда поедет реальная аватарка.
    Item {
        id: remoteAvatarPlaceholder
        anchors.fill: parent
        visible: mode === "running" && !(Call && Call.remoteVideoActive)

        readonly property string _displayName: peerName.length > 0 ? peerName : "?"
        readonly property string _initial: _displayName.length > 0
                                           ? _displayName.charAt(0).toUpperCase()
                                           : "?"

        Rectangle {
            id: avatarCircle
            anchors.centerIn: parent
            width: Math.min(parent.width, parent.height) * 0.32
            height: width
            radius: width / 2
            color: Theme.bgButton
            border.color: Theme.accent
            border.width: 2

            Label {
                anchors.centerIn: parent
                text: remoteAvatarPlaceholder._initial
                color: Theme.textPrimary
                font.pixelSize: avatarCircle.width * 0.45
                font.weight: Font.DemiBold
            }
        }
    }

    // Полупрозрачная подложка под текстом/контролами поверх видео — чтобы
    // имя/таймер читались на произвольной картинке. Не нужна когда показан
    // placeholder: там и так контрастный фон.
    Rectangle {
        id: scrim
        anchors.fill: parent
        visible: remoteVideo.visible
        gradient: Gradient {
            GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.55) }
            GradientStop { position: 0.35; color: Qt.rgba(0, 0, 0, 0.0) }
            GradientStop { position: 0.65; color: Qt.rgba(0, 0, 0, 0.0) }
            GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.65) }
        }
    }

    // ── Локальный preview (overlay в углу) ─────────────────────────────
    Item {
        id: localPreviewFrame
        visible: VideoAvailable && mode === "running" && Call && Call.videoActive
        // Рамка повторяет aspect фактического кадра: при portrait-камере
        // (телефон вертикально) — 9:16, при landscape — 16:9. Aspect берётся
        // из Call.localVideoPortrait.
        readonly property bool _portrait: Call && Call.localVideoPortrait
        width: _portrait ? Math.min(parent.width * 0.22, 180)
                         : Math.min(parent.width * 0.32, 280)
        height: _portrait ? width * 16 / 9 : width * 9 / 16
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 16
        z: 10

        // VideoOutput сам по себе игнорирует rounded-clip родителя (Qt SG
        // умеет только прямоугольный hardware-clip). Чтобы скруглить
        // углы — рендерим в offscreen texture через layer.enabled и потом
        // накладываем маску (MultiEffect.maskSource) — белый прямоугольник
        // с тем же radius. Содержимое за пределами маски становится прозрачным.
        VideoOutput {
            id: localPreview
            anchors.fill: parent
            fillMode: VideoOutput.PreserveAspectFit
            layer.enabled: true
            layer.smooth: true
            layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: localPreviewMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 1.0
            }
            Component.onCompleted: {
                if (Call) Call.setLocalVideoOutput(localPreview)
            }
        }

        // Источник маски — невидимый Rectangle с radius'ом. layer.enabled
        // превращает его в текстуру, которую MultiEffect.maskSource читает.
        Item {
            id: localPreviewMask
            anchors.fill: parent
            visible: false
            layer.enabled: true
            Rectangle {
                anchors.fill: parent
                radius: 12
                color: "white"
            }
        }

        // Бордюр поверх скруглённого видео — отдельным Rectangle, не выкусывая
        // его маской (бордюру Rectangle.border сам красит rounded корректно).
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            radius: 12
            border.color: Theme.border
            border.width: 1
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

        // Мнемосхема пути звонка под именем абонента. Скрываем когда
        // активно удалённое видео — там нужна максимальная площадь под кадр.
        CallPathIndicator {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 280
            Layout.preferredHeight: 90
            visible: VoIPAvailable && !remoteVideo.visible &&
                     (mode === "outgoing" || mode === "running")
            txPath:     VoIPAvailable && CallControl ? CallControl.currentPath : 0
            rxPath:     VoIPAvailable && CallControl ? CallControl.rxPath : 0
            pathLabel:  VoIPAvailable && CallControl ? CallControl.currentPathLabel : ""
            turnServer: VoIPAvailable && CallControl ? CallControl.activeTurnServer : ""
            active:     VoIPAvailable && Call ? Call.mediaReceived : false
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
        // Самописный toggle вместо QtQuick.Controls CheckBox: дефолтный
        // CheckBox берёт системные цвета и почти не виден на тёмном фоне
        // (особенно поверх удалённого видео). Здесь — контрастная подложка.
        Rectangle {
            id: wantVideoToggle
            Layout.alignment: Qt.AlignHCenter
            visible: VideoAvailable && mode === "outgoing"
            implicitWidth: wantVideoRow.implicitWidth + 24
            implicitHeight: 40
            radius: Theme.radiusMd
            color: Qt.rgba(0, 0, 0, 0.55)
            border.width: 1
            border.color: Theme.border

            RowLayout {
                id: wantVideoRow
                anchors.centerIn: parent
                spacing: 10

                Rectangle {
                    id: checkBox
                    implicitWidth: 22
                    implicitHeight: 22
                    radius: 4
                    color: CallControl && CallControl.wantVideo ? Theme.accent : "transparent"
                    border.color: CallControl && CallControl.wantVideo ? Theme.accentHover : Theme.textPrimary
                    border.width: 2

                    AppIcon {
                        anchors.centerIn: parent
                        width: 16; height: 16
                        name: "check"
                        iconColor: "white"
                        strokeWidth: 2.5
                        visible: CallControl && CallControl.wantVideo
                    }
                }

                Label {
                    text: qsTr("С видео")
                    color: "white"
                    font.pixelSize: Theme.fontMd
                }
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: if (CallControl) CallControl.wantVideo = !CallControl.wantVideo
            }
        }

        // ── Кнопки управления ─────────────────────────────────────────
        RowLayout {
            Layout.alignment: Qt.AlignHCenter
            spacing: 18

            // running: микрофон mute
            CallControlButton {
                visible: mode === "running" && Call !== null
                // Конвенция как в Telegram/WhatsApp: иконка показывает ДЕЙСТВИЕ
                // (что произойдёт при нажатии), а не текущее состояние. То есть
                // микрофон работает → видим перечёркнутую иконку («нажми чтобы
                // замьютить»); микрофон замьючен → видим обычную («нажми чтобы
                // включить»). Это интуитивнее: иконка отвечает на вопрос «что
                // станет», а не «что сейчас».
                iconName: Call && Call.micMuted ? "mic" : "micOff"
                tone: Call && Call.micMuted ? "warning" : "neutral"
                tooltip: Call && Call.micMuted ? qsTr("Включить микрофон") : qsTr("Выключить микрофон")
                onClicked: if (Call) Call.setMicMuted(!Call.micMuted)
            }

            // running: камера on/off — та же конвенция (см. комментарий выше).
            CallControlButton {
                visible: VideoAvailable && mode === "running"
                iconName: Call && Call.videoActive ? "videoOff" : "video"
                tone: Call && Call.videoActive ? "neutral" : "warning"
                tooltip: Call && Call.videoActive ? qsTr("Выключить камеру") : qsTr("Включить камеру")
                onClicked: CallControl.toggleVideo(!(Call && Call.videoActive))
            }

            // running: переключение камер
            CallControlButton {
                visible: VideoAvailable && mode === "running" && Call && Call.videoActive
                         && Call.hasMultipleCameras()
                iconName: "cameraSwitch"
                tone: "neutral"
                tooltip: qsTr("Сменить камеру")
                onClicked: if (Call) Call.switchCamera()
            }

            // incoming: принять
            CallControlButton {
                visible: mode === "incoming"
                iconName: "phone"
                tone: "accept"
                tooltip: qsTr("Принять")
                onClicked: {
                    lastError = ""
                    if (CallControl.remoteHasVideo && VideoAvailable) {
                        CallControl.wantVideo = true
                    }
                    if (!CallControl.acceptIncomingCall()) {
                        lastError = qsTr("Не удалось принять звонок")
                    }
                }
            }

            // incoming: отклонить, outgoing/running: завершить
            CallControlButton {
                visible: mode === "incoming" || mode === "outgoing" || mode === "running"
                iconName: "phoneHangup"
                tone: "hangup"
                tooltip: mode === "incoming" ? qsTr("Отклонить") : qsTr("Завершить")
                onClicked: {
                    if (mode === "incoming") {
                        CallControl.rejectIncomingCall("user_rejected")
                    } else {
                        CallControl.hangupCall("user_hangup")
                    }
                }
            }
        }
    }

    // Компактная кнопка управления звонком: круг с иконкой.
    component CallControlButton: Rectangle {
        id: btn
        property string iconName: ""
        property string tone: "neutral"  // neutral / accept / hangup / warning
        property string tooltip: ""

        signal clicked()

        implicitWidth: 64
        implicitHeight: 64
        radius: width / 2

        property bool _isHovered: btnArea.containsMouse
        property bool _isPressed: btnArea.pressed

        color: {
            const baseAlpha = _isPressed ? 0.85 : 0.7
            if (tone === "accept")  return Qt.rgba(0.10, 0.65, 0.30, baseAlpha)
            if (tone === "hangup")  return Qt.rgba(0.80, 0.10, 0.13, baseAlpha)
            if (tone === "warning") return Qt.rgba(0.95, 0.55, 0.10, baseAlpha)
            return _isHovered ? Qt.rgba(1, 1, 1, 0.28) : Qt.rgba(0, 0, 0, 0.45)
        }
        border.width: 1
        border.color: tone === "neutral" ? Theme.border : "transparent"
        scale: _isPressed ? 0.94 : 1.0

        Behavior on color { ColorAnimation { duration: 110 } }
        Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

        AppIcon {
            anchors.centerIn: parent
            width: 28
            height: 28
            name: iconName
            iconColor: "white"
            fillColor: btn.color
            strokeWidth: 2
        }

        MouseArea {
            id: btnArea
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
            ToolTip.visible: btn._isHovered && btn.tooltip.length > 0
            ToolTip.text: btn.tooltip
            ToolTip.delay: 600
        }
    }
}
