import QtQuick
import QtQuick.Controls
import QtQuick.Window
import ParanoiaUiClient

ApplicationWindow {
    id:      appWindow
    visible: true
    width:   420
    height:  780
    title:   "Paranoia"
    color:   Theme.bgPrimary
    property bool importNavigationPending: false

    function openMainPageIfReady() {
        if ((Backend.loggedIn || Backend.hasAdminAccess) && (stackView.depth === 1 || appWindow.importNavigationPending)) {
            appWindow.importNavigationPending = false
            stackView.replace(mainPage)
        }
    }

    onClosing: function(close) {
        close.accepted = false
        if (stackView.depth >= 1) {
            var current = stackView.currentItem
            if (current && typeof current.handleBackButton === "function") {
                if (current.handleBackButton()) {
                    return
                }
            }
        }

        if (stackView.depth > 1) {
            stackView.pop()          // вызываем свою логику "назад"
            return
        }
        close.accepted = true
        // если depth == 1, close.accepted = true по умолчанию → выход
    }

    // Авто-навигация при восстановлении сессии из сохранённых данных
    Connections {
        target: Backend
        function onLoginStateChanged() {
            appWindow.openMainPageIfReady()
        }
        function onAdminStateChanged() {
            appWindow.openMainPageIfReady()
        }
    }

    Component.onCompleted: {
        if (Backend.loggedIn || Backend.hasAdminAccess)
            stackView.replace(mainPage)
    }

    StackView {
        id:           stackView
        anchors.fill: parent

        initialItem: HelloPage {
            onImportProfile:  stackView.push(importProfilePage)
            onRegisterClient: stackView.push(clientRegistrationPage)
            onInstallServer:   stackView.push(installServerPage)
        }
    }

    Component {
        id: installServerPage
        InstallServerPage {
            onBack:            stackView.pop()
            onServerInstalled: function(domain) { stackView.replace(mainPage) }
        }
    }

    Component {
        id: clientRegistrationPage
        ClientRegistrationPage {
            onBack:     stackView.pop()
            onLoggedIn: stackView.replace(mainPage)
        }
    }

    Component {
        id: importProfilePage
        ImportProfilePage {
            onBack: {
                appWindow.importNavigationPending = false
                stackView.pop()
            }
            onProfileImported: {
                appWindow.importNavigationPending = true
                appWindow.openMainPageIfReady()
            }
        }
    }

    Component {
        id: mainPage
        MainPage {
            onOpenChat:         function(peer) { stackView.push(chatPage, { peer: peer }) }
            onRegisterClient:   stackView.push(clientRegistrationPage)
            onInstallNewServer: stackView.push(installServerPage)
        }
    }

    Component {
        id: chatPage
        ChatPage {
            onBack: stackView.pop()
        }
    }
}
