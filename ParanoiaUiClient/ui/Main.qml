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

    StackView {
        id:           stackView
        anchors.fill: parent

        initialItem: HelloPage {
            onConnectToServer: stackView.push(connectChoicePage)
            onInstallServer:   stackView.push(installServerPage)
        }
    }

    // ── Компоненты страниц ────────────────────────────────
    Component {
        id: installServerPage
        InstallServerPage {
            onBack:            stackView.pop()
            onServerInstalled: stackView.replace(mainPage)
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
            onBack:       stackView.pop()
            onRegister_:  stackView.push(clientRegistrationPage)
            onLogin:      stackView.push(clientLoginPage)
        }
    }

    Component {
        id: clientRegistrationPage
        ClientRegistrationPage {
            onBack: stackView.pop()
            onProceedToLogin: function(privKey) {
                stackView.replace(clientLoginPage,
                                  { "autoFillKey": privKey })
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
            hasAdminAccess: false   // устанавливается при подключении
            hasUserAccess:  true
        }
    }
}
