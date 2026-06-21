import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

// Экран «Настройки профиля»: локальный ник + аватар профиля (хранятся в манифесте,
// не секрет, правятся отсюда) и просмотр параметров подключения (адрес/server_id с
// копированием) + переход к редактору резервных адресов/TURN. Открывается из пикера
// профилей по «шестерёнке». Смена первичного адреса сервера — отдельным заходом
// (требует миграции каталога профиля).
Rectangle {
    id: root
    color: Theme.bgPrimary

    required property string profileId
    // Синхронная инициализация — чтобы встроенный редактор резерва получил server
    // (primaryDomain) уже при создании; refresh() переобновляет на sessionsChanged.
    property var info: Backend.getProfileInfo(root.profileId)
    property string feedbackText: ""
    property bool feedbackError: false

    signal back()

    function refresh() {
        root.info = Backend.getProfileInfo(root.profileId) || ({})
        if (!nickInput.activeFocus)
            nickInput.text = root.info.localName || ""
        if (!serverInput.activeFocus)
            serverInput.text = root.info.server || ""
    }

    function pickAvatar() {
        // Мобилки — системный photo picker (галерея); профиль помечаем префиксом
        // "profile:", чтобы общий обработчик аватара диалога (MainPage) его не
        // перехватил. Десктоп — нативный файловый диалог.
        if (Qt.platform.os === "android" || Qt.platform.os === "ios")
            Chat.pickAvatarFromGallery("profile:" + root.profileId)
        else
            avatarFileDialog.open()
    }

    function saveNick() {
        Backend.setProfileLocalName(root.profileId, nickInput.text)
        root.feedbackError = false
        root.feedbackText = qsTr("Ник сохранён")
    }

    function copyText(t) {
        if (!t || t.length === 0) return
        clip.text = t
        clip.selectAll()
        clip.copy()
        root.feedbackError = false
        root.feedbackText = qsTr("Скопировано")
    }

    Component.onCompleted: root.refresh()

    Connections {
        target: Backend
        function onSessionsChanged() { root.refresh() }
    }
    Connections {
        target: Chat
        function onAvatarPhotoPicked(peer, uri) {
            if (peer !== "profile:" + root.profileId) return
            if (Backend.setProfileAvatar(root.profileId, uri)) {
                root.feedbackError = false; root.feedbackText = qsTr("Аватар обновлён")
            } else {
                root.feedbackError = true;  root.feedbackText = qsTr("Не удалось установить аватар")
            }
        }
    }

    // Скрытый редактор — для копирования в буфер (тот же приём, что в ChatPage).
    TextEdit { id: clip; visible: false }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        ParaHeader {
            Layout.fillWidth: true
            title: qsTr("Настройки профиля")
            onBackClicked: root.back()
        }

        Flickable {
            id: formFlick
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: Math.max(formFlick.height, contentCol.implicitHeight + 48)
            // Только вертикальный скролл — без горизонтального «уезда» контента.
            contentWidth: width
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            ColumnLayout {
                id: contentCol
                width: Math.min(parent.width - 48, 560)
                anchors.horizontalCenter: parent.horizontalCenter
                y: 24
                spacing: 16

                // ── Аватар ──────────────────────────────────────────────
                Item {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.preferredWidth: 96
                    Layout.preferredHeight: 96

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: Theme.bgSecondary
                        border.width: 1
                        border.color: Theme.border
                        visible: !avatarImg.visible
                        Text {
                            anchors.centerIn: parent
                            text: (root.info.displayName || root.info.username || "?").charAt(0).toUpperCase()
                            color: Theme.textPrimary
                            font.pixelSize: 40
                            font.family: Theme.fontFamily
                        }
                    }
                    Image {
                        id: avatarImg
                        anchors.fill: parent
                        // Круг уже запечён в PNG (см. setProfileAvatar) → обычный Image.
                        source: root.info.avatar || ""
                        visible: source.toString().length > 0
                        asynchronous: true
                        cache: false
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pickAvatar()
                    }
                }

                // Кнопки делят ширину (Layout.fillWidth) — иначе их собственная
                // implicitWidth (200px каждая) при появлении «Убрать» суммарно
                // вылезала за экран и ломала ширину всей страницы.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 12
                    ParaButton {
                        Layout.fillWidth: true
                        text: qsTr("Изменить аватар")
                        secondary: true
                        onClicked: root.pickAvatar()
                    }
                    ParaButton {
                        Layout.fillWidth: true
                        text: qsTr("Убрать")
                        destructive: true
                        visible: (root.info.avatar || "").length > 0
                        onClicked: Backend.clearProfileAvatar(root.profileId)
                    }
                }

                // ── Ник ────────────────────────────────────────────────
                ParaInput {
                    id: nickInput
                    Layout.fillWidth: true
                    label: qsTr("Ник профиля")
                    placeholder: qsTr("Отображаемое имя")
                }
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Сохранить ник")
                    onClicked: root.saveNick()
                }

                Text {
                    Layout.fillWidth: true
                    visible: root.feedbackText.length > 0
                    text: root.feedbackText
                    color: root.feedbackError ? Theme.error : Theme.success
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }

                // ── Подключение ─────────────────────────────────────────
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.separator }

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Подключение")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                    font.weight: Font.DemiBold
                }

                // Адрес сервера — редактируемый (переезд на другой домен).
                ParaInput {
                    id: serverInput
                    Layout.fillWidth: true
                    label: qsTr("Адрес сервера")
                    placeholder: qsTr("https://example.com")
                }
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Смена адреса переносит данные профиля (диалоги, ключи) на новый адрес и перелогинивает профиль. Для переезда сервера на другой домен — личность (server_id) не меняется.")
                    color: Theme.textHint
                    font.pixelSize: Theme.fontXs
                    font.family: Theme.fontFamily
                    wrapMode: Text.WordWrap
                }
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Сменить адрес сервера")
                    secondary: true
                    enabled: serverInput.text.trim().length > 0
                             && serverInput.text.trim() !== (root.info.server || "")
                    onClicked: changeServerPopup.open()
                }

                // server_id (read-only + копирование)
                Text {
                    Layout.fillWidth: true
                    text: qsTr("Идентификатор (server_id)")
                    color: Theme.textSecondary
                    font.pixelSize: Theme.fontSm
                    font.family: Theme.fontFamily
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Text {
                        Layout.fillWidth: true
                        text: root.info.serverId || "—"
                        color: Theme.textPrimary
                        font.pixelSize: Theme.fontSm
                        font.family: Theme.fontFamily
                        elide: Text.ElideMiddle
                    }
                    Rectangle {
                        Layout.preferredWidth: 32; Layout.preferredHeight: 32
                        radius: Theme.radiusMd
                        color: copyIdArea.containsMouse ? Theme.bgButton : Theme.bgSecondary
                        border.width: 1; border.color: Theme.border
                        AppIcon { anchors.centerIn: parent; width: 16; height: 16; name: "copy"; iconColor: Theme.textSecondary }
                        MouseArea {
                            id: copyIdArea
                            anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.copyText(root.info.serverId)
                        }
                    }
                }

                // ── Резервные адреса и TURN (встроены, без отдельного окна) ──
                Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Theme.separator }

                Text {
                    Layout.fillWidth: true
                    text: qsTr("Резервные адреса и TURN")
                    color: Theme.textPrimary
                    font.pixelSize: Theme.fontMd
                    font.family: Theme.fontFamily
                    font.weight: Font.DemiBold
                }

                ReserveTurnEditor {
                    Layout.fillWidth: true
                    targetType: "client"
                    targetId: root.profileId
                    primaryDomain: root.info.server || ""
                }

                Item { Layout.preferredHeight: 8 }
            }
        }
    }

    // Подтверждение смены адреса (операция с миграцией каталога + релогин).
    Popup {
        id: changeServerPopup
        anchors.centerIn: Overlay.overlay
        modal: true
        dim: true
        padding: 20
        closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
        background: Rectangle {
            color: Theme.bgCard
            radius: Theme.radiusLg
            border.width: 1
            border.color: Theme.border
        }
        contentItem: ColumnLayout {
            spacing: 14
            Text {
                Layout.preferredWidth: 320
                text: qsTr("Сменить адрес сервера?")
                color: Theme.textPrimary
                font.pixelSize: Theme.fontMd
                font.family: Theme.fontFamily
                font.weight: Font.DemiBold
                wrapMode: Text.WordWrap
            }
            Text {
                Layout.preferredWidth: 320
                text: qsTr("Профиль будет перенесён на «%1» и перелогинен. Диалоги и ключи сохранятся.").arg(serverInput.text.trim())
                color: Theme.textSecondary
                font.pixelSize: Theme.fontSm
                font.family: Theme.fontFamily
                wrapMode: Text.WordWrap
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Отмена")
                    secondary: true
                    onClicked: changeServerPopup.close()
                }
                ParaButton {
                    Layout.fillWidth: true
                    text: qsTr("Сменить")
                    onClicked: {
                        const res = Backend.changeProfileServer(root.profileId, serverInput.text.trim())
                        changeServerPopup.close()
                        if (res && res.ok) {
                            // profileId изменился — возвращаемся к списку профилей.
                            root.back()
                        } else {
                            root.feedbackError = true
                            root.feedbackText = (res && res.error) ? res.error : qsTr("Не удалось сменить адрес")
                        }
                    }
                }
            }
        }
    }

    // Десктоп: нативный выбор файла аватара.
    ParaFileDialog {
        id: avatarFileDialog
        title: qsTr("Выберите аватар")
        mode: "open"
        nameFilters: [qsTr("Изображения (*.png *.jpg *.jpeg *.gif *.webp *.bmp *.tiff *.heic *.heif)"), qsTr("Все файлы (*)")]
        onAccepted: {
            if (Backend.setProfileAvatar(root.profileId, selectedFile.toString())) {
                root.feedbackError = false; root.feedbackText = qsTr("Аватар обновлён")
            } else {
                root.feedbackError = true;  root.feedbackText = qsTr("Не удалось установить аватар")
            }
        }
    }
}
