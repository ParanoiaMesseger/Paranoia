#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QElapsedTimer>
#include <QFutureWatcher>
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
    Q_PROPERTY(QObject *videoOutput READ videoOutput WRITE setVideoOutput NOTIFY videoOutputChanged)

public:
    explicit QrCameraScanner(QObject *parent = nullptr);
    ~QrCameraScanner() override;

    bool active() const;
    void setActive(bool active);
    bool supported() const;
    QString error() const;
    QObject *videoOutput() const;
    void setVideoOutput(QObject *videoOutput);

    Q_INVOKABLE void start();
    Q_INVOKABLE void stop();

signals:
    void activeChanged();
    void errorChanged();
    void videoOutputChanged();
    void decoded(const QString &text);

private:
    void setError(const QString &error);
    void clearError();

    bool m_active = false;
    QString m_error;
    QObject *m_videoOutput = nullptr;
    QMetaObject::Connection m_videoOutputDestroyedConnection;

#if PARANOIA_HAS_QT_MULTIMEDIA
    void ensureCamera();
    void applyVideoOutput();
    void connectVideoSink(QVideoSink *videoSink);
    void handleFrame(const QVideoFrame &frame);
    void handleDecodeFinished();
    static QString decodeFrame(QVideoFrame frame);
    static QString decodeQr(const QImage &image);

    std::unique_ptr<QMediaCaptureSession> m_captureSession;
    std::unique_ptr<QCamera> m_camera;
    QVideoSink *m_videoSink = nullptr;
    QMetaObject::Connection m_videoFrameConnection;
    QFutureWatcher<QString> m_decodeWatcher;
    QElapsedTimer m_decodeTimer;
    bool m_decodeInFlight = false;
    quint64 m_scanSessionId = 0;
    quint64 m_pendingDecodeSessionId = 0;
#endif
};
