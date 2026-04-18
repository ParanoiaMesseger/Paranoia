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

    // Авто-навигация при восстановлении сессии из сохранённых данных
    Connections {
        target: Backend
        function onLoginStateChanged() {
            if (Backend.loggedIn && stackView.depth === 1)
                stackView.replace(mainPage)
        }
    }

    Component.onCompleted: {
        // Если есть только админ-доступ (без клиентского логина) — сразу на главную
        if (Backend.hasAdminAccess && !Backend.loggedIn)
            stackView.replace(mainPage)
    }

    StackView {
        id:           stackView
        anchors.fill: parent

        initialItem: HelloPage {
            onConnectToServer: stackView.push(connectChoicePage)
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
        id: connectChoicePage
        ConnectChoicePage {
            onBack:     stackView.pop()
            onAsAdmin:  stackView.push(connectAdminPage)
            onAsClient: stackView.push(connectClientChoicePage)
        }
    }

    Component {
        id: connectAdminPage
        ConnectAdminPage {
            onBack:      stackView.pop()
            onConnected: stackView.replace(mainPage)
        }
    }

    Component {
        id: connectClientChoicePage
        ConnectClientChoicePage {
            onBack:      stackView.pop()
            onRegister_: stackView.push(clientRegistrationPage)
            onLogin:     stackView.push(clientLoginPage)
        }
    }

    Component {
        id: clientRegistrationPage
        ClientRegistrationPage {
            onBack: stackView.pop()
            onProceedToLogin: function(privKey) {
                stackView.replace(clientLoginPage, { autoFillKey: privKey })
            }
        }
    }

    Component {
        id: clientLoginPage
        ClientLoginPage {
            onBack:     stackView.pop()
            onLoggedIn: stackView.replace(mainPage)
        }
    }

    Component {
        id: mainPage
        MainPage {
            onOpenChat:         function(peer) { stackView.push(chatPage, { peer: peer }) }
            onAddServer:        stackView.push(connectChoicePage)
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
