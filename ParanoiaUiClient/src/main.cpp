#include "platform/DesktopTray.hpp"
#include "platform/OrientationLock.hpp"
#include "utils/Logging.hpp"

#include <QByteArray>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlError>
#include <QWindow>
#include <QDebug>
#include <QStandardPaths>
#include <QDir>
#include <QFile>
#include <QStyleHints>
#include <QLocale>
#include <QTranslator>
#if defined(DESKTOP_OS)
#include <QApplication>
#else
#include <QGuiApplication>
#endif
#if defined(OS_ANDROID)
#include <QCoreApplication>
#include <QJniEnvironment>
#include <QJniObject>
#include <ParanoiaFFI>
#endif
#include "utils/adminStorage.hpp"
#include "utils/KeyInjector.hpp"
#include "backend/ChatBackend.hpp"
#include "backend/EncryptedImageProvider.hpp"
#include "backend/MainBackend.hpp"
#include "backend/NotificationCoordinator.hpp"
#include "backend/VersionInfoBackend.hpp"
#include "platform/PlatformNotifications.hpp"
#include "spell/SpellChecker.hpp"
#if defined(DESKTOP_OS)
#include "backend/NativeFileDialog.hpp"
#endif
#if defined(PARANOIA_IOS)
#include "platform/IosFileExport.hpp"
#endif
#if PARANOIA_HAS_QT_MULTIMEDIA
#include <QCameraDevice>
#include <QMediaDevices>
#endif
#include <QPixmapCache>

#if PARANOIA_HAS_VOIP
#include "voip/VoipSystem.hpp"
#endif

#ifdef OS_ANDROID
namespace
{
    bool initAndroidTlsVerifier()
    {
        QJniEnvironment env;
        const auto context = QNativeInterface::QAndroidApplication::context();
        if (paranoia_android_init(env.jniEnv(), context.object<jobject>()) == 0) return true;
        qCritical().noquote() << "Failed to initialize Android TLS verifier:" << ParanoiaFFI::last_error();
        return false;
    }
}
#endif

int main(int argc, char *argv[])
{
    QCoreApplication::setOrganizationName("Paranoia");
    QCoreApplication::setApplicationName("ParanoiaUiClient");
    QCoreApplication::setApplicationVersion(APP_VERSION);
#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS)
    qputenv("QT_IM_MODULE", QByteArrayLiteral("qtvirtualkeyboard"));
    qputenv("QT_VIRTUALKEYBOARD_STYLE", QByteArrayLiteral("Paranoia"));
    // Кастомные раскладки (см. CMakeLists "keyboard_layouts"): гарантируют
    // alternativeKeys (е→ё, ь→ъ, .→!?) в APK и убирают кнопку скрытия клавиатуры.
    if (qEnvironmentVariableIsEmpty("QT_VIRTUALKEYBOARD_LAYOUT_PATH"))
        qputenv("QT_VIRTUALKEYBOARD_LAYOUT_PATH", QByteArrayLiteral("qrc:/paranoia/keyboard_layouts"));
    QGuiApplication::styleHints()->setMousePressAndHoldInterval(300);
#endif
#if defined(Q_OS_UNIX) && !defined(Q_OS_DARWIN) && !defined(Q_OS_ANDROID)
    QGuiApplication::setDesktopFileName(QStringLiteral("app.paranoia.client"));
    // Файловый диалог на GNOME: по умолчанию Qt идёт через xdg-desktop-portal
    // (D-Bus → отдельный процесс GTK-chooser с миниатюрами/GVfs/recent) — открытие
    // ощутимо тормозит, особенно первое. Прямая тема gtk3 даёт нативный GTK-диалог
    // в самом процессе, без портала → открывается мгновенно. Ставим, только если
    // пользователь не задал тему сам (иначе уважаем его выбор).
    if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORMTHEME"))
        qputenv("QT_QPA_PLATFORMTHEME", QByteArrayLiteral("gtk3"));
#endif

#if PARANOIA_DESKTOP_TRAY
    QApplication app(argc, argv);
    app.setQuitOnLastWindowClosed(false);
#else
    QGuiApplication app(argc, argv);
#endif
    app.setWindowIcon(QIcon(QStringLiteral(":/logo_symbol.svg")));

    // ── Локализация ────────────────────────────────────────────────────────
    // Исходные строки русские (sourcelanguage=ru). Для не-русской системной
    // локали грузим встроенный перевод :/i18n/Paranoia_<locale>.qm (load()
    // сам перебирает en_US → en). Если .qm нет или строка не переведена —
    // fallback на исходную русскую строку, т.е. текущее поведение без регрессии.
    // translator живёт до конца main(), что переживает app.exec().
    static QTranslator appTranslator;
    if (appTranslator.load(QLocale(), QStringLiteral("Paranoia"),
                           QStringLiteral("_"), QStringLiteral(":/i18n")))
        app.installTranslator(&appTranslator);

#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS)
    const QString dataDir = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
    if (!dataDir.isEmpty() && QDir().mkpath(dataDir) && QDir::setCurrent(dataDir))
        qInfo().noquote() << "Using app data directory:" << dataDir;
    else
        qWarning().noquote() << "Failed to switch to app data directory:" << dataDir;
#endif

#if defined(Q_OS_ANDROID)
    if (!initAndroidTlsVerifier()) return -1;
#endif

#if PARANOIA_HAS_QT_VIRTUAL_KEYBOARD
    const QString hunspellDataPath = SpellChecker::prepareBundledDictionaries();
    if (!hunspellDataPath.isEmpty()) {
        QByteArray envValue       = QFile::encodeName(hunspellDataPath);
        const QByteArray existing = qgetenv("QT_VIRTUALKEYBOARD_HUNSPELL_DATA_PATH");
        if (!existing.isEmpty() && existing != envValue) {
#if defined(OS_WIN)
            envValue = envValue + ";" + existing;
#else
            envValue = envValue + ":" + existing;
#endif
        }
        qputenv("QT_VIRTUALKEYBOARD_HUNSPELL_DATA_PATH", envValue);
    }
#endif

    Logging logging;
    // admin::Admin::initAdmins() перенесён в MainBackend::onVaultUnlocked():
    // admins.crypt теперь под vault-шифрованием, требует master_key в RAM.
    PlatformNotifications::registerBackgroundTasks();
    NotificationCoordinator notifications;
    MainBackend backend(notifications);
    ChatBackend chatBackend;
    VersionInfoBackend versionInfoBackend;
    // Cross-backend wiring
    QObject::connect(&chatBackend, &ChatBackend::activePeerChanged, &notifications,
                     &NotificationCoordinator::onActivePeerChanged);
    QObject::connect(&chatBackend, &ChatBackend::peerMessagesRead, &notifications,
                     &NotificationCoordinator::onPeerMessagesRead);
    QObject::connect(&chatBackend, &ChatBackend::backgroundMessagesReceived, &notifications,
                     &NotificationCoordinator::onBackgroundMessagesReceived);
    QObject::connect(&chatBackend, &ChatBackend::pulledNewMessages, &backend,
                     &MainBackend::publishServiceSnapshot);
    // На unlock'е разогреваем все диалоги: пользователь видит свежие сообщения
    // в UI сразу, без ожидания alarm-цикла notifications-сервиса.
    QObject::connect(&backend, &MainBackend::vaultUnlocked, &chatBackend,
                     &ChatBackend::prefetchAllDialogs);
    QObject::connect(&notifications, &NotificationCoordinator::networkRestored, &chatBackend,
                     &ChatBackend::onNetworkRestored);
    QObject::connect(&notifications, &NotificationCoordinator::sessionReset, &chatBackend,
                     &ChatBackend::onSessionReset);
    QObject::connect(&backend, &MainBackend::dialogRemoved, &chatBackend, &ChatBackend::onDialogRemoved);
    QObject::connect(&backend, &MainBackend::sessionReset, &chatBackend, &ChatBackend::onSessionReset);

    // Глобально отключаем дисковый QPixmapCache: расшифрованные превью идут
    // через EncryptedImageProvider и не должны попадать в системный кеш.
    QPixmapCache::setCacheLimit(0);

    QQmlApplicationEngine engine;
    auto *imageProvider = new EncryptedImageProvider();
    engine.addImageProvider(QStringLiteral("secure"), imageProvider);
    chatBackend.setImageProvider(imageProvider);
    // Зануляем кеш плейн-байтов при vault_lock и при выходе приложения.
    // aboutToQuit срабатывает ДО деструкции engine — imageProvider ещё жив.
    QObject::connect(&backend, &MainBackend::vaultLocked, &chatBackend,
                     [imageProvider]() { imageProvider->clear(); });
    QObject::connect(&app, &QCoreApplication::aboutToQuit,
                     [imageProvider]() { imageProvider->clear(); });

    KeyInjector keyInjector;
    engine.rootContext()->setContextProperty("KeyInjector", &keyInjector);
    engine.rootContext()->setContextProperty("Backend", &backend);
    engine.rootContext()->setContextProperty("Chat", &chatBackend);
    engine.rootContext()->setContextProperty("Notifications", &notifications);
    engine.rootContext()->setContextProperty("VersionInfo", &versionInfoBackend);
#if defined(DESKTOP_OS)
    // Нативный системный файловый диалог (QtWidgets QFileDialog) — QML-обёртки Qt
    // на macOS 26 не выводят панель на экран. См. NativeFileDialog.hpp / ParaFileDialog.qml.
    NativeFileDialog nativeFileDialog;
    engine.rootContext()->setContextProperty("FileDialogs", &nativeFileDialog);
#endif
#if defined(PARANOIA_IOS)
    // Нативный экспорт файла (UIDocumentPickerViewController forExporting) — на iOS
    // QtQuick.Dialogs save рисует десктопный QML-fallback. См. IosFileExport.hpp /
    // ParaFileDialog.qml (ветка save на iOS).
    IosFileExport iosFileExport;
    engine.rootContext()->setContextProperty("IosFileExport", &iosFileExport);
#endif
    engine.rootContext()->setContextProperty("VirtualKeyboardAvailable", PARANOIA_HAS_QT_VIRTUAL_KEYBOARD != 0);
    engine.rootContext()->setContextProperty("MultimediaAvailable", PARANOIA_HAS_QT_MULTIMEDIA != 0);
    // Реально ли есть камера в системе (для выбора «сканировать QR камерой» vs
    // «считать QR из файла»). На macOS без камеры (напр. Mac mini) сканер падал
    // с «нет камеры» без фоллбэка на файл — см. cameraQrScan в QR-страницах.
#if PARANOIA_HAS_QT_MULTIMEDIA
    const bool cameraAvailable = !QMediaDevices::videoInputs().isEmpty();
#else
    const bool cameraAvailable = false;
#endif
    engine.rootContext()->setContextProperty("CameraAvailable", cameraAvailable);
    engine.rootContext()->setContextProperty("VoIPAvailable", PARANOIA_HAS_VOIP != 0);
    engine.rootContext()->setContextProperty("VideoAvailable", PARANOIA_HAS_VIDEO != 0);
    engine.rootContext()->setContextProperty("DesktopTrayEnabled", DesktopTray::desktopTrayEnabled());
    paranoia::platform::OrientationLock orientationLock;
    engine.rootContext()->setContextProperty("OrientationLock", &orientationLock);
#if PARANOIA_HAS_VOIP
    paranoia::voip::VoipSystem voipSystem(engine, backend);
#endif
    logging.connectEngine(&engine);
    engine.loadFromModule("ParanoiaUiClient", "Main");
    if (engine.rootObjects().isEmpty())
        qCritical().noquote() << "QML root object is empty after loadFromModule. Import paths:"
                              << engine.importPathList().join(", ");
    DesktopTray desktopTray(engine);
    QObject::connect(&notifications, &NotificationCoordinator::notificationAvailable, &desktopTray,
                     &DesktopTray::notificationAvailable);
    QObject::connect(&notifications, &NotificationCoordinator::notificationsCleared, &desktopTray,
                     &DesktopTray::clearAccumulatedNotifications);
    return app.exec();
}
