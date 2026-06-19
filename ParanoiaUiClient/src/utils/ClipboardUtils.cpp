#include "ClipboardUtils.hpp"

#include <QClipboard>
#include <QDateTime>
#include <QDir>
#include <QGuiApplication>
#include <QImage>
#include <QMimeData>
#include <QStandardPaths>

bool ClipboardUtils::hasImage() const
{
    const QClipboard *cb = QGuiApplication::clipboard();
    if (!cb) return false;
    const QMimeData *md = cb->mimeData();
    if (!md || !md->hasImage()) return false;
    return !cb->image().isNull();
}

QString ClipboardUtils::saveImageToTemp() const
{
    const QClipboard *cb = QGuiApplication::clipboard();
    if (!cb) return {};
    const QImage img = cb->image();
    if (img.isNull()) return {};

    QString dir = QStandardPaths::writableLocation(QStandardPaths::TempLocation);
    if (dir.isEmpty()) dir = QDir::tempPath();
    const QString name =
        QStringLiteral("paranoia-paste-%1.png").arg(QDateTime::currentMSecsSinceEpoch());
    const QString path = QDir(dir).filePath(name);
    if (!img.save(path, "PNG")) return {};
    return path;
}

QString ClipboardUtils::text() const
{
    const QClipboard *cb = QGuiApplication::clipboard();
    return cb ? cb->text() : QString();
}
