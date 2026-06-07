import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()
    signal serverInstalled(string profileId)

    InstallServerBackend {
        id: backend

        onStepStatusChanged: function(step, status) {
            root.setStepStatus(step, status)
        }

        onInstallFinished: function(domain, profileId) {
            root.isInstalling = false
            root.serverInstalled(profileId)
        }

        onInstallError: function(step, message) {
            root.setStepStatus(step, InstallServerBackend.Error)
            root.isInstalling = false
            root.errorText = message
        }
    }

    // Список шагов установки
    readonly property var steps: [
        qsTr("Генерация ключей администратора"),
        qsTr("Подключение по SSH"),
        qsTr("Создание /opt/Paranoia и конфигурации"),
        qsTr("Установка nginx"),
        qsTr("Получение TLS-сертификата"),
        qsTr("Настройка nginx → Paranoia"),
        qsTr("Загрузка paranoia-server"),
        qsTr("Регистрация systemd-сервиса"),
        qsTr("Запуск сервера"),
        qsTr("Проверка соединения"),
        qsTr("Добавление сервера в список")
    ]

    property var stepStatuses: Array(steps.length).fill(0)
    property bool isInstalling: false
    property string errorText: ""
    ColumnLayout {
        anchors.fill:        parent
        spacing:             0

        ParaHeader {
            Layout.fillWidth: true
            title:            qsTr("Установить свой сервер")
            onBackClicked:    root.back()
        }

        Flickable {
            id: formFlick
            Layout.fillWidth:  true
            Layout.fillHeight: true
            contentHeight:     Math.max(formFlick.height, innerCol.implicitHeight + 48)
            clip:              true

            ColumnLayout {
                id:           innerCol
                width:        Math.min(parent.width - 48, 560)
                anchors.horizontalCenter: parent.horizontalCenter
                y:            Math.max(24, (formFlick.height - implicitHeight) / 2)
                spacing:      16

                Item { Layout.preferredHeight: 8 }

                // ── Поля ввода ───────────────────────────────
                ParaInput {
                    id:          domainInput
                    Layout.fillWidth: true
                    label:       qsTr("Домен (для TLS)")
                    placeholder: "example.com"
                }

                ParaInput {
                    id:          ipInput
                    Layout.fillWidth: true
                    label:       qsTr("IP-адрес")
                    placeholder: "192.168.1.1"
                }

                ParaInput {
                    id:          usernameInput
                    Layout.fillWidth: true
                    label:       qsTr("SSH-пользователь")
                    placeholder: "root"
                    text:        "root"
                }

                ParaInput {
                    id:          passwordInput
                    Layout.fillWidth: true
                    label:       qsTr("SSH-пароль")
                    placeholder: "••••••••"
                    echoMode:    TextInput.Password
                }

                ParaInput {
                    id:          portInput
                    Layout.fillWidth: true
                    label:       qsTr("Порт сервера Paranoia")
                    placeholder: "1455"
                    text:        "1455"
                }

                Item { Layout.preferredHeight: 4 }

                // ── Прогресс-бар ─────────────────────────────
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing:          8
                    visible:          root.isInstalling

                    ProgressBar {
                        id:               mainProgress
                        Layout.fillWidth: true
                        from:  0
                        to:    root.steps.length
                        value: root.stepStatuses.filter(s => s === 2).length

                        background: Rectangle {
                            radius: 4
                            color:  Theme.bgInput
                        }
                        contentItem: Item {
                            Rectangle {
                                width:  mainProgress.visualPosition * parent.width
                                height: parent.height
                                radius: 4
                                color:  Theme.accent
                                Behavior on width { NumberAnimation { duration: 200 } }
                            }
                        }
                    }

                    // Шаги
                    Repeater {
                        model: root.steps
                        ProgressStep {
                            stepText: modelData
                            status:   root.stepStatuses[index] ?? 0
                        }
                    }
                }

                // ── Ошибка ───────────────────────────────────
                Text {
                    Layout.fillWidth: true
                    visible:          root.errorText.length > 0
                    text:             root.errorText
                    color:            Theme.error
                    font.pixelSize:   13
                    wrapMode:         Text.WordWrap
                }

                // ── Кнопка ───────────────────────────────────
                ParaButton {
                    Layout.fillWidth: true
                    text:             root.isInstalling ? qsTr("Установка…") : qsTr("Установить")
                    enabled:          !root.isInstalling
                    onClicked: {
                        root.isInstalling = true
                        root.errorText = ""
                        // Сигнал для C++/Python backend:
                        backend.install(domainInput.text, ipInput.text,
                             usernameInput.text, passwordInput.text,
                             parseInt(portInput.text))
                    }
                }

                Item { Layout.preferredHeight: 16 }
            }
        }
    }

    // Вызывается из backend при завершении шага:
    // root.stepStatuses[stepIndex] = status (1/2/3)
    // root.stepStatusesChanged()
    function setStepStatus(index, status) {
        let arr = root.stepStatuses.slice()
        arr[index] = status
        root.stepStatuses = arr
    }
}
