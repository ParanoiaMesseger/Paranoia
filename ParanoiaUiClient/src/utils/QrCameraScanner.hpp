#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QElapsedTimer>
#include <QString>

class QImage;

#ifndef PARANOIA_HAS_QT_MULTIMEDIA
#define PARANOIA_HAS_QT_MULTIMEDIA 0
#endif

#if PARANOIA_HAS_QT_MULTIMEDIA
#include <QCamera>
#include <QMediaCaptureSession>
#include <QVideoSink>
#include <memory>
#endif

class QrCameraScanner : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool active READ active WRITE setActive NOTIFY activeChanged)
    Q_PROPERTY(bool supported READ supported CONSTANT)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)
    Q_PROPERTY(QString previewFrame READ previewFrame NOTIFY previewFrameChanged)

public:
    explicit QrCameraScanner(QObject *parent = nullptr);
    ~QrCameraScanner() override;

    bool active() const;
    void setActive(bool active);
    bool supported() const;
    QString error() const;
    QString previewFrame() const;

    Q_INVOKABLE void start();
    Q_INVOKABLE void stop();

signals:
    void activeChanged();
    void errorChanged();
    void previewFrameChanged();
    void decoded(const QString &text);

private:
    void setError(const QString &error);
    void clearError();

    bool m_active = false;
    QString m_error;
    QString m_previewFrame;

#if PARANOIA_HAS_QT_MULTIMEDIA
    void ensureCamera();
    void handleFrame(const QVideoFrame &frame);
    void updatePreview(const QImage &image);
    QString decodeQr(const QImage &image) const;

    std::unique_ptr<QMediaCaptureSession> m_captureSession;
    std::unique_ptr<QCamera> m_camera;
    std::unique_ptr<QVideoSink> m_videoSink;
    QElapsedTimer m_decodeTimer;
    QElapsedTimer m_previewTimer;
#endif
};
