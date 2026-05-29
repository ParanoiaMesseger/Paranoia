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
    // Share-target: данные из системного share-sheet'а. Подхватываются на
    // активации окна и держатся до выбора чата (см. MainPage shareBanner).
    property string sharePendingText: ""
    property var sharePendingFiles: []
    readonly property bool hasShareTarget: sharePendingText.length > 0 || (sharePendingFiles && sharePendingFiles.length > 0)
    readonly property bool startOnMainPage: Backend.hasStoredClientProfiles || Backend.loggedIn || Backend.hasAdminAccess
    readonly property bool virtualKeyboardEnabled: VirtualKeyboardAvailable && (Qt.platform.os === "android" || Qt.platform.os === "ios")

    onActiveChanged: {
        if (active) {
            appWindow.refreshNotificationPeerHint()
            appWindow.refreshShareTarget()
        }
    }

    // Android: onNewIntent (входящий share-intent при уже запущенном приложении)
    // не всегда меняет Window.active → onActiveChanged может не сработать.
    // Слушаем applicationState (Background→Active при показе activity'ы).
    Connections {
        target: Qt.application
        function onStateChanged() {
            if (Qt.application.state === Qt.ApplicationActive) {
                appWindow.refreshNotificationPeerHint()
                appWindow.refreshShareTarget()
            }
        }
    }

    function refreshNotificationPeerHint() {
        const peer = Notifications.takeNotificationPeer();
        if (peer && peer.length > 0) {
            appWindow.notificationProfileHint = Notifications.notificationHintProfileId || "";
            appWindow.notificationPeerHint = peer;
        }
    }

    function refreshShareTarget() {
        if (typeof Backend.takeShareTarget !== "function") return
        const target = Backend.takeShareTarget()
        if (!target) return
        const text = String(target.text || "")
        const rawFiles = target.files || []
        // QStringList из C++ может прийти как sequence-wrapper, у которого
        // .length и индексация работают, но дальнейшая передача через property
        // var / JSON.stringify иногда даёт сюрпризы. Копируем в plain JS Array
        // явным циклом — после этого с массивом ведём себя как с обычным.
        var files = []
        for (var i = 0; i < rawFiles.length; ++i) {
            var entry = String(rawFiles[i] || "").trim()
            if (entry.length > 0) files.push(entry)
        }
        if (text.length === 0 && files.length === 0) return
        appWindow.sharePendingText = text
        appWindow.sharePendingFiles = files
    }

    function clearShareTarget() {
        appWindow.sharePendingText = ""
        appWindow.sharePendingFiles = []
    }

    function openMainPageIfReady() {
        if (!(Backend.loggedIn || Backend.hasAdminAccess))
            return;
        if (stackView.depth !== 1 && !appWindow.importNavigationPending)
            return;

        appWindow.importNavigationPending = false;
        if (stackView.currentItem && stackView.currentItem.objectName === "MainPage")
            return;
        stackView.replace(mainPage);
    }

    onClosing: function (close) {
        close.accepted = false;
        if (appWindow.handleNavigationBack()) return;
        if (DesktopTrayEnabled) {
            appWindow.hide();
            return;
        }
        close.accepted = true;
    }

    // Унифицированная навигация «назад». Возвращает true если что-то закрыли
    // (overlay/поиск/selection или поп stack'а). Используется и системным
    // back-button'ом (onClosing), и Esc на десктопе (см. Shortcut ниже).
    function handleNavigationBack(): bool {
        if (stackView.depth >= 1) {
            var current = stackView.currentItem;
            if (current && typeof current.handleBackButton === "function") {
                if (current.handleBackButton()) return true;
            }
        }
        // Открытая виртуальная клавиатура скрывается жестом «назад» — без
        // выхода со страницы. Кнопки скрытия на самой клавиатуре больше нет.
        if (appWindow.virtualKeyboardEnabled && Qt.inputMethod.visible) {
            Qt.inputMethod.hide();
            return true;
        }
        if (stackView.depth > 1) {
            stackView.pop();
            return true;
        }
        return false;
    }

    // Desktop: Esc работает как back-кнопка. Закрывает фотовьюер/поиск/selection
    // (через handleBackButton текущей страницы), либо popает стек на одну позицию.
    // На последней странице ничего не делаем — закрывать всё окно по Esc
    // неожиданно (для этого есть штатный close).
    Shortcut {
        sequence: "Esc"
        context: Qt.WindowShortcut
        enabled: !appWindow.virtualKeyboardEnabled
        onActivated: appWindow.handleNavigationBack()
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
        function onSessionSwitched() {
            while (stackView.depth > 1) stackView.pop(StackView.Immediate);
        }
        function onShareTargetReady() {
            appWindow.refreshShareTarget();
        }
    }

    Connections {
        target: Notifications
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
        appWindow.refreshShareTarget();
        appWindow.openMainPageIfReady();
        if (VoIPAvailable) {
            appWindow.callPageComponent = Qt.createComponent(
                Qt.resolvedUrl("Pages/CallPage.qml"), Component.PreferSynchronous);
            if (appWindow.callPageComponent.status === Component.Error)
                console.warn("CallPage load error:", appWindow.callPageComponent.errorString());
        }
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

        initialItem: appWindow.vaultGatePage()
    }

    function vaultGatePage() {
        switch (Backend.vaultStatus) {
            case 0: return setPinPage     // не инициализирован — set PIN
            case 1: return unlockPinPage  // заблокирован — unlock
            case 2: return appWindow.startOnMainPage ? mainPage : helloPage
            default: return helloPage
        }
    }

    Connections {
        target: Backend
        // Qt.callLater отодвигает stackView.replace на следующий event-tick:
        // иначе мы синхронно уничтожаем UnlockPin/SetPin прямо во время
        // JS-handler'а Connections.onVaultUnlockResult, что приводит к
        // обращениям к destroyed-объекту в Qt 6.
        function onVaultStatusChanged() {
            Qt.callLater(function() {
                const next = appWindow.vaultGatePage()
                if (next) stackView.replace(null, next)
            })
        }
        function onVaultLocked() {
            Qt.callLater(function() { stackView.replace(null, unlockPinPage) })
        }
    }

    Component {
        id: setPinPage
        SetPin {
            objectName: "SetPin"
            showBack: false
            onAccepted: function (pin) { Backend.vaultSetPin(pin) }
        }
    }

    Component {
        id: unlockPinPage
        UnlockPin {
            objectName: "UnlockPin"
            onAccepted: function (pin) { Backend.vaultUnlock(pin) }
        }
    }

    Component {
        id: helloPage
        HelloPage {
            objectName: "HelloPage"
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
            objectName: "MainPage"
            highlightProfileId: appWindow.notificationProfileHint
            highlightPeer: appWindow.notificationPeerHint
            shareTargetText: appWindow.sharePendingText
            shareTargetFiles: appWindow.sharePendingFiles
            onCancelShareTarget: appWindow.clearShareTarget()
            onOpenChat: function (profileId, peer) {
                if (appWindow.notificationPeerHint === peer &&
                        (appWindow.notificationProfileHint.length === 0 || appWindow.notificationProfileHint === profileId)) {
                    appWindow.notificationProfileHint = "";
                    appWindow.notificationPeerHint = "";
                }
                var props = { peer: peer }
                if (appWindow.hasShareTarget) {
                    props.shareTextInitial = appWindow.sharePendingText
                    props.shareFilesInitial = appWindow.sharePendingFiles
                    appWindow.clearShareTarget()
                }
                stackView.push(chatPage, props);
            }
            onRegisterClient:   stackView.push(clientRegistrationPage)
            onInstallNewServer: stackView.push(installServerPage)
            onOpenExportImport: stackView.push(exportImportPage, { initialTabIndex: 0 })
            onOpenImport:       stackView.push(exportImportPage, { initialTabIndex: 1 })
            onOpenAddDialog:    stackView.push(addDialogPage)
            onOpenUpdateKey:    function (peer) { stackView.push(updateKeyPage, { peer: peer }) }
            onOpenRegisterUser: function (domain) { stackView.push(registerUserPage, { targetDomain: domain }) }
            onOpenAddReserveDomain: function (targetType, targetId, primaryDomain) {
                stackView.push(addReserveDomainPage, {
                    targetType: targetType,
                    targetId: targetId,
                    primaryDomain: primaryDomain
                })
            }
            onOpenVersionInfo: stackView.push(versionInfoPage)
            onOpenChangePin: stackView.push(changePinPage)
        }
    }

    Component {
        id: changePinPage
        ChangePin {
            onBack: stackView.pop()
            onChanged: stackView.pop()
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
        id: versionInfoPage
        VersionInfoPage {
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

    // CallPage.qml тянет QtMultimedia — её нет в сборках без VoIP, поэтому
    // загружаем компонент динамически только когда VoIPAvailable=true.
    property var callPageComponent: null

    Connections {
        target: VoIPAvailable ? CallControl : null
        function onIncomingCall(peer, callId) {
            if (!appWindow.callPageComponent || appWindow.callPageComponent.status !== Component.Ready) return
            const props = { mode: "incoming", peerName: peer }
            if (stackView.currentItem && stackView.currentItem.objectName === "CallPage") {
                stackView.replace(appWindow.callPageComponent, props)
                return
            }
            stackView.push(appWindow.callPageComponent, props)
        }
    }
}
