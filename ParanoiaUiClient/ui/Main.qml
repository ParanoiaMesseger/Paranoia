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

    function openMainPageIfReady() {
        if ((Backend.loggedIn || Backend.hasAdminAccess) && stackView.depth === 1) {
            if (startupImportPopup.opened)
                startupImportPopup.close()
            stackView.replace(mainPage)
        }
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
            onImportProfile:  startupImportPopup.openImport()
            onRegisterClient: stackView.push(clientRegistrationPage)
            onInstallServer:   stackView.push(installServerPage)
        }
    }

    ExportImportPage {
        id: startupImportPopup
        importOnly: true
        onProfileImported: appWindow.openMainPageIfReady()
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
