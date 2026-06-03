#pragma once
#if defined(DESKTOP_OS)

#include <QList>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QUrl>

// Нативный системный файловый диалог через QtWidgets QFileDialog.
//
// Зачем отдельный C++-бэкенд, а не QML FileDialog: на macOS 26 QML-обёртки
// (QtQuick.Dialogs и Qt.labs.platform) НЕ выводят системную NSOpenPanel на
// экран — панель рисуется отдельным remote-view XPC-процессом, и QML-слой Qt
// 6.10 её не презентует (AppKit при этом репортит visible=true, но окна нет).
// QtWidgets QFileDialog показывает нативную панель корректно. Подпись (ad-hoc /
// Developer ID) на это не влияет, App Sandbox у нас выключен.
//
// Возвращает file:// URL'ы — ровно то, что раньше отдавал QtQuick.Dialogs
// (selectedFile/selectedFiles/selectedFolder), чтобы обработчики в QML не
// менялись. Только desktop (на мобиле QtWidgets не линкуется — см. ParaFileDialog.qml).
class NativeFileDialog : public QObject
{
    Q_OBJECT

public:
    explicit NativeFileDialog(QObject *parent = nullptr) : QObject(parent) {}

    // Пустой результат (null QUrl / пустой список) = пользователь отменил.
    Q_INVOKABLE QUrl openFile(const QString &title, const QStringList &nameFilters) const;
    Q_INVOKABLE QList<QUrl> openFiles(const QString &title, const QStringList &nameFilters) const;
    Q_INVOKABLE QUrl saveFile(const QString &title, const QStringList &nameFilters,
                              const QString &suggestedName) const;
    Q_INVOKABLE QUrl openFolder(const QString &title) const;
};

#endif // DESKTOP_OS
