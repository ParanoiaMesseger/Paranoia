#include "QrCameraScanner.hpp"

#include <QDebug>
#include <QImage>
#include <QPointer>
#include <QtConcurrent>
#include <QVariant>

#if PARANOIA_HAS_QT_MULTIMEDIA
#include <QCameraDevice>
#include <QCoreApplication>
#include <QMediaDevices>
#include <QPermissions>
#include <QVideoFrame>
#include <ReadBarcode.h>
#endif

namespace
{
    constexpr qint64 DecodeIntervalMs = 250;
}

QrCameraScanner::QrCameraScanner(QObject *parent) : QObject(parent)
{
#if PARANOIA_HAS_QT_MULTIMEDIA
    connect(&m_decodeWatcher, &QFutureWatcher<QString>::finished, this, &QrCameraScanner::handleDecodeFinished);
#endif
}

QrCameraScanner::~QrCameraScanner()
{
    stop();
#if PARANOIA_HAS_QT_MULTIMEDIA
    m_decodeWatcher.waitForFinished();
#endif
}

bool QrCameraScanner::active() const { return m_active; }

void QrCameraScanner::setActive(bool active)
{
    if (active)
        start();
    else
        stop();
}

bool QrCameraScanner::supported() const
{
#if PARANOIA_HAS_QT_MULTIMEDIA
#if QT_CONFIG(permissions)
    QCameraPermission permission;
    const auto status = qApp->checkPermission(permission);
    if (status == Qt::PermissionStatus::Denied) return false;
#if defined(Q_OS_ANDROID) || defined(Q_OS_IOS) || defined(Q_OS_MACOS)
    if (status == Qt::PermissionStatus::Undetermined) return true;
#endif
#endif
    return !QMediaDevices::videoInputs().isEmpty();
#else
    return false;
#endif
}

QString QrCameraScanner::error() const { return m_error; }

QObject *QrCameraScanner::videoOutput() const { return m_videoOutput; }

void QrCameraScanner::setVideoOutput(QObject *videoOutput)
{
    if (m_videoOutput == videoOutput) return;

    if (m_videoOutputDestroyedConnection) disconnect(m_videoOutputDestroyedConnection);
    m_videoOutput = videoOutput;

#if PARANOIA_HAS_QT_MULTIMEDIA
    if (m_videoOutput) {
        m_videoOutputDestroyedConnection = connect(m_videoOutput, &QObject::destroyed, this, [this]() {
            m_videoOutput = nullptr;
            connectVideoSink(nullptr);
            if (m_captureSession) m_captureSession->setVideoOutput(nullptr);
            emit videoOutputChanged();
        });
    }
    applyVideoOutput();
#endif

    emit videoOutputChanged();
}

void QrCameraScanner::start()
{
#if PARANOIA_HAS_QT_MULTIMEDIA
#if QT_CONFIG(permissions)
    QCameraPermission permission;
    const auto status = qApp->checkPermission(permission);
    if (status == Qt::PermissionStatus::Undetermined) {
        const QPointer<QrCameraScanner> self(this);
        qApp->requestPermission(permission, this, [self](const QPermission &permission) {
            if (!self) return;
            emit self->supportedChanged();
            if (permission.status() == Qt::PermissionStatus::Granted) {
                self->start();
            } else {
                self->setError(QrCameraScanner::tr("Нет доступа к камере."));
            }
        });
        return;
    }
    if (status == Qt::PermissionStatus::Denied) {
        emit supportedChanged();
        setError(QrCameraScanner::tr("Нет доступа к камере."));
        return;
    }
#endif

    if (!supported()) {
        setError(QrCameraScanner::tr("Камера не найдена или недоступна."));
        return;
    }

    ensureCamera();
    if (!m_camera) {
        setError(QrCameraScanner::tr("Камера не найдена или недоступна."));
        return;
    }
    clearError();
    if (!m_active) {
        ++m_scanSessionId;
        m_decodeTimer.invalidate();
        m_active = true;
        emit activeChanged();
    }
    m_camera->start();
#else
    setError(QrCameraScanner::tr("Сканирование камерой не включено в этой сборке."));
#endif
}

void QrCameraScanner::stop()
{
#if PARANOIA_HAS_QT_MULTIMEDIA
    if (m_camera) m_camera->stop();
#endif
    if (!m_active) return;
#if PARANOIA_HAS_QT_MULTIMEDIA
    ++m_scanSessionId;
#endif
    m_active = false;
    emit activeChanged();
}

void QrCameraScanner::setError(const QString &error)
{
    if (m_error == error) return;
    m_error = error;
    emit errorChanged();
}

void QrCameraScanner::clearError() { setError({}); }

#if PARANOIA_HAS_QT_MULTIMEDIA
void QrCameraScanner::ensureCamera()
{
    if (m_camera) return;

    const auto cameras = QMediaDevices::videoInputs();
    if (cameras.isEmpty()) return;

    QCameraDevice selected = cameras.first();
    for (const auto &camera : cameras) {
        if (camera.position() == QCameraDevice::BackFace) {
            selected = camera;
            break;
        }
    }

    m_camera         = std::make_unique<QCamera>(selected);
    m_captureSession = std::make_unique<QMediaCaptureSession>();
    m_captureSession->setCamera(m_camera.get());
    applyVideoOutput();

    connect(m_camera.get(), &QCamera::errorOccurred, this, [this](QCamera::Error error, const QString &errorString) {
        if (error != QCamera::NoError) setError(errorString.isEmpty() ? QrCameraScanner::tr("Ошибка камеры.") : errorString);
    });
}

void QrCameraScanner::applyVideoOutput()
{
    if (!m_captureSession) return;

    m_captureSession->setVideoOutput(m_videoOutput);

    QVideoSink *videoSink = nullptr;
    if (m_videoOutput) videoSink = m_videoOutput->property("videoSink").value<QVideoSink *>();
    connectVideoSink(videoSink);
}

void QrCameraScanner::connectVideoSink(QVideoSink *videoSink)
{
    if (m_videoSink == videoSink) return;

    if (m_videoFrameConnection) disconnect(m_videoFrameConnection);
    m_videoSink = videoSink;
    if (m_videoSink)
        m_videoFrameConnection =
            connect(m_videoSink, &QVideoSink::videoFrameChanged, this, &QrCameraScanner::handleFrame);
}

void QrCameraScanner::handleFrame(const QVideoFrame &frame)
{
    if (!m_active || !frame.isValid() || m_decodeInFlight) return;
    if (m_decodeTimer.isValid() && m_decodeTimer.elapsed() < DecodeIntervalMs) return;
    m_decodeTimer.restart();

    m_pendingDecodeSessionId = m_scanSessionId;
    m_decodeInFlight         = true;
    m_decodeWatcher.setFuture(QtConcurrent::run(&QrCameraScanner::decodeFrame, frame));
}

void QrCameraScanner::handleDecodeFinished()
{
    const QString text = m_decodeWatcher.result();
    m_decodeInFlight   = false;
    if (!m_active || m_pendingDecodeSessionId != m_scanSessionId || text.isEmpty()) return;

    stop();
    emit decoded(text);
}

QString QrCameraScanner::decodeFrame(QVideoFrame frame)
{
    QImage image = frame.toImage();
    if (image.isNull()) return {};

    if (image.width() > 1280) image = image.scaledToWidth(1280, Qt::FastTransformation);
    return decodeQr(image);
}

QString QrCameraScanner::decodeQr(const QImage &image)
{
    const QImage gray = image.convertToFormat(QImage::Format_Grayscale8);
    try {
        const ZXing::ImageView view(gray.constBits(), gray.width(), gray.height(), ZXing::ImageFormat::Lum,
                                    gray.bytesPerLine());
        ZXing::ReaderOptions options;
        options.setFormats(ZXing::BarcodeFormat::QRCode).setTryHarder(true).setTryRotate(true).setTryInvert(true);
        const auto barcodes = ZXing::ReadBarcodes(view, options);
        for (const auto &barcode : barcodes) {
            if (barcode.isValid()) return QString::fromStdString(barcode.text());
        }
    } catch (const std::exception &e) {
        qWarning() << "QR camera decode failed:" << e.what();
    }
    return {};
}
#endif
