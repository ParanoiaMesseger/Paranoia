import QtQuick
import QtQuick.Controls
import QtQuick.Window
import ParanoiaUiClient

ApplicationWindow {
    id: appWindow
    visible: true
    width: 420
    height: 780
    title: "Paranoia"
    color: Theme.bgPrimary
    property bool importNavigationPending: false
    property string notificationProfileHint: ""
    property string notificationPeerHint: ""
    readonly property bool virtualKeyboardEnabled: VirtualKeyboardAvailable && (Qt.platform.os === "android" || Qt.platform.os === "ios")

    onActiveChanged: {
        if (active)
            appWindow.refreshNotificationPeerHint()
    }

    function refreshNotificationPeerHint() {
        const peer = Backend.takeNotificationPeer();
        if (peer && peer.length > 0) {
            appWindow.notificationProfileHint = Backend.notificationHintProfileId || "";
            appWindow.notificationPeerHint = peer;
        }
    }

    function openMainPageIfReady() {
        if ((Backend.loggedIn || Backend.hasAdminAccess) && (stackView.depth === 1 || appWindow.importNavigationPending)) {
            appWindow.importNavigationPending = false;
            stackView.replace(mainPage);
        }
    }

    onClosing: function (close) {
        close.accepted = false;
        if (stackView.depth >= 1) {
            var current = stackView.currentItem;
            if (current && typeof current.handleBackButton === "function") {
                if (current.handleBackButton()) {
                    return;
                }
            }
        }

        if (stackView.depth > 1) {
            stackView.pop();
            return;
        }
        if (DesktopTrayEnabled) {
            appWindow.hide();
            return;
        }
        close.accepted = true;
    }

    // Авто-навигация при восстановлении сессии из сохранённых данных
    Connections {
        target: Backend
        function onLoginStateChanged() {
            appWindow.refreshNotificationPeerHint();
            appWindow.openMainPageIfReady();
        }
        function onAdminStateChanged() {
            appWindow.openMainPageIfReady();
        }
        function onNotificationAvailable(count, profileId, peer) {
            appWindow.notificationProfileHint = profileId || "";
            appWindow.notificationPeerHint = peer || "";
        }
        function onSessionSwitched() {
            while (stackView.depth > 1) stackView.pop(StackView.Immediate);
        }
    }

    Component.onCompleted: {
        appWindow.refreshNotificationPeerHint();
        if (Backend.loggedIn || Backend.hasAdminAccess)
            stackView.replace(mainPage);
    }

    StackView {
        id: stackView
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.bottomMargin: keyboardHeight

        Behavior on anchors.bottomMargin {
            NumberAnimation {
                duration: 140
                easing.type: Easing.OutCubic
            }
        }

        property real keyboardHeight: {
            if (!appWindow.virtualKeyboardEnabled)
                return 0;
            if (Qt.inputMethod.visible)
                return Qt.inputMethod.keyboardRectangle.height;
            return 0;
        }

        initialItem: HelloPage {
            onImportProfile: stackView.push(importProfilePage)
            onRegisterClient: stackView.push(clientRegistrationPage)
            onInstallServer: stackView.push(installServerPage)
        }
    }

    Loader {
        id: virtualKeyboardLoader
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        z: 9999
        active: appWindow.virtualKeyboardEnabled
        source: active ? "Components/VirtualKeyboardPanel.qml" : ""
    }

    Component {
        id: installServerPage
        InstallServerPage {
            onBack: stackView.pop()
            onServerInstalled: function (profileId) {
                Backend.activateProfile(profileId)
                stackView.replace(mainPage)
            }
        }
    }

    Component {
        id: clientRegistrationPage
        ClientRegistrationPage {
            onBack: stackView.pop()
            onLoggedIn: stackView.replace(mainPage)
        }
    }

    Component {
        id: importProfilePage
        ImportProfilePage {
            onBack: {
                appWindow.importNavigationPending = false;
                stackView.pop();
            }
            onProfileImported: {
                appWindow.importNavigationPending = true;
                appWindow.openMainPageIfReady();
            }
        }
    }

    Component {
        id: mainPage
        MainPage {
            highlightProfileId: appWindow.notificationProfileHint
            highlightPeer: appWindow.notificationPeerHint
            onOpenChat: function (profileId, peer) {
                if (appWindow.notificationPeerHint === peer &&
                        (appWindow.notificationProfileHint.length === 0 || appWindow.notificationProfileHint === profileId)) {
                    appWindow.notificationProfileHint = "";
                    appWindow.notificationPeerHint = "";
                }
                stackView.push(chatPage, { peer: peer });
            }
            onRegisterClient:   stackView.push(clientRegistrationPage)
            onInstallNewServer: stackView.push(installServerPage)
            onOpenExportImport: stackView.push(exportImportPage, { initialTabIndex: 0 })
            onOpenImport:       stackView.push(exportImportPage, { initialTabIndex: 1 })
            onOpenAddDialog:    stackView.push(addDialogPage)
            onOpenUpdateKey:    function (peer) { stackView.push(updateKeyPage, { peer: peer }) }
            onOpenClearHistory: function (peer) { stackView.push(clearHistoryPage, { peer: peer }) }
            onOpenRegisterUser: function (domain) { stackView.push(registerUserPage, { targetDomain: domain }) }
            onOpenAddReserveDomain: function (targetType, targetId, primaryDomain) {
                stackView.push(addReserveDomainPage, {
                    targetType: targetType,
                    targetId: targetId,
                    primaryDomain: primaryDomain
                })
            }
        }
    }

    Component {
        id: chatPage
        ChatPage {
            onBack: stackView.pop()
        }
    }

    Component {
        id: exportImportPage
        ExportImportPage {
            onBack: stackView.pop()
        }
    }

    Component {
        id: addDialogPage
        AddDialogPage {
            onBack: stackView.pop()
            onOpenQrExchange: function (peer, updateExisting) {
                stackView.push(qrExchangePage, { peer: peer, updateExisting: updateExisting })
            }
        }
    }

    Component {
        id: updateKeyPage
        UpdateKeyPage {
            onBack: stackView.pop()
            onOpenQrExchange: function (peer, updateExisting) {
                stackView.push(qrExchangePage, { peer: peer, updateExisting: updateExisting })
            }
        }
    }

    Component {
        id: clearHistoryPage
        ClearHistoryPage {
            onBack: stackView.pop()
        }
    }

    Component {
        id: registerUserPage
        RegisterUserPage {
            onBack: stackView.pop()
        }
    }

    Component {
        id: addReserveDomainPage
        AddReserveDomainPage {
            onBack: stackView.pop()
        }
    }

    Component {
        id: qrExchangePage
        QrExchangePage {
            onBack: stackView.pop()
            onExchangeConfirmed: {
                stackView.pop()  // убираем QrExchangePage
                stackView.pop()  // убираем AddDialogPage или UpdateKeyPage
            }
        }
    }
}
