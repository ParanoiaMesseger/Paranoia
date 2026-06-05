#include "backend/NativeFileDialog.hpp"

#if defined(DESKTOP_OS)

#include <QFileDialog>

// ВАЖНО — почему DontUseNativeDialog на desktop:
// Приложение целиком на QtQuick (главное окно — QQuickWindow), QWidget-окон нет.
// Системная NSOpenPanel на macOS — модальная панель, которой нужен родительский
// NSWindow от QtWidgets; при parent=nullptr и отсутствии QWidget-окон нативная
// панель НЕ показывается и getOpenFileName возвращается мгновенно пустой
// (проверено логами). Non-native QFileDialog рисует собственное QWidget-окно и
// показывается всегда, без родителя. (QML-обёртки QtQuick.Dialogs/Qt.labs.platform
// на macOS 26 тоже не выводят нативную панель — out-of-process remote view.)
namespace
{
    constexpr QFileDialog::Options kOpts = QFileDialog::DontUseNativeDialog;

    QString joinFilters(const QStringList &nameFilters)
    {
        // Qt-формат: "Описание (*.ext);;Другое (*.x)". На пустом списке — все файлы.
        return nameFilters.join(QStringLiteral(";;"));
    }
}

QUrl NativeFileDialog::openFile(const QString &title, const QStringList &nameFilters) const
{
    const QString path =
        QFileDialog::getOpenFileName(nullptr, title, QString(), joinFilters(nameFilters), nullptr, kOpts);
    return path.isEmpty() ? QUrl() : QUrl::fromLocalFile(path);
}

QList<QUrl> NativeFileDialog::openFiles(const QString &title, const QStringList &nameFilters) const
{
    const QStringList paths =
        QFileDialog::getOpenFileNames(nullptr, title, QString(), joinFilters(nameFilters), nullptr, kOpts);
    QList<QUrl> urls;
    urls.reserve(paths.size());
    for (const QString &p : paths)
        urls.append(QUrl::fromLocalFile(p));
    return urls;
}

QUrl NativeFileDialog::saveFile(const QString &title, const QStringList &nameFilters,
                                const QString &suggestedName) const
{
    const QString path =
        QFileDialog::getSaveFileName(nullptr, title, suggestedName, joinFilters(nameFilters), nullptr, kOpts);
    return path.isEmpty() ? QUrl() : QUrl::fromLocalFile(path);
}

QUrl NativeFileDialog::openFolder(const QString &title) const
{
    const QString dir = QFileDialog::getExistingDirectory(
        nullptr, title, QString(), kOpts | QFileDialog::ShowDirsOnly | QFileDialog::DontResolveSymlinks);
    return dir.isEmpty() ? QUrl() : QUrl::fromLocalFile(dir);
}

#endif // DESKTOP_OS
