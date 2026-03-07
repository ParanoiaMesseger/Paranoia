import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import ParanoiaUiClient

Rectangle {
    id: root
    color: Theme.bgPrimary

    signal back()
    signal serverInstalled(string domain)

    InstallServerBackend {
        id: backend

        onStepStatusChanged: function(step, status) {
            root.setStepStatus(step, status)
        }

        onInstallFinished: function(domain) {
            root.isInstalling = false
            root.serverInstalled(domain)
        }

        onInstallError: function(step, message) {
            root.setStepStatus(step, InstallServerBackend.Error)
            root.isInstalling = false
            // можно завести errorText и показывать его
        }
    }

    // Список шагов установки
    readonly property var steps: [
        "Генерация ключей администратора",
        "Подключение по SSH",
        "Создание /opt/Paranoia и конфигурации",
        "Установка nginx",
        "Получение TLS-сертификата",
        "Настройка nginx → Paranoia",
        "Загрузка paranoia-server",
        "Регистрация systemd-сервиса",
        "Запуск сервера",
        "Проверка соединения",
        "Добавление сервера в список"
    ]

    property var stepStatuses: Array(steps.length).fill(0)
    property bool isInstalling: false

    ColumnLayout {
        anchors.fill:        parent
        spacing:             0

        ParaHeader {
            Layout.fillWidth: true
            title:            "Установить свой сервер"
            onBackClicked:    root.back()
        }

        Flickable {
            Layout.fillWidth:  true
            Layout.fillHeight: true
            contentHeight:     innerCol.implicitHeight + 32
            clip:              true

            ColumnLayout {
                id:           innerCol
                width:        parent.width
                anchors.left: parent.left
                anchors.right:parent.right
                anchors.margins: 24
                spacing:      16

                Item { Layout.preferredHeight: 8 }

                // ── Поля ввода ───────────────────────────────
                ParaInput {
                    id:          domainInput
                    Layout.fillWidth: true
                    label:       "Домен (для TLS)"
                    placeholder: "example.com"
                }

                ParaInput {
                    id:          ipInput
                    Layout.fillWidth: true
                    label:       "IP-адрес"
                    placeholder: "192.168.1.1"
                }

                ParaInput {
                    id:          usernameInput
                    Layout.fillWidth: true
                    label:       "SSH-пользователь"
                    placeholder: "root"
                }

                ParaInput {
                    id:          passwordInput
                    Layout.fillWidth: true
                    label:       "SSH-пароль"
                    placeholder: "••••••••"
                    echoMode:    TextInput.Password
                }

                ParaInput {
                    id:          portInput
                    Layout.fillWidth: true
                    label:       "Порт сервера Paranoia"
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

                // ── Кнопка ───────────────────────────────────
                ParaButton {
                    Layout.fillWidth: true
                    text:             root.isInstalling ? "Установка…" : "Установить"
                    enabled:          !root.isInstalling
                    onClicked: {
                        root.isInstalling = true
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
