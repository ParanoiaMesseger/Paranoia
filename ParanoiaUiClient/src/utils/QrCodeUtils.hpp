#pragma once

#include <QQmlEngine>

class QrCodeUtils : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
public:
    Q_INVOKABLE QString pngDataUrl(const QString &payload, int size = 512);
    Q_INVOKABLE QVariantMap decodeFromImage(const QString &filePath);
    Q_INVOKABLE QVariantMap registrationPublicKeyFromQr(const QString &payload);
};