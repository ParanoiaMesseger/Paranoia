#include "QrCameraScanner.hpp"

#include <QBuffer>
#include <QDebug>
#include <QImage>

#if PARANOIA_HAS_QT_MULTIMEDIA
#include <QCameraDevice>
#include <QCoreApplication>
#include <QMediaDevices>
#include <QPermissions>
#include <QVideoFrame>
#include <ReadBarcode.h>
#endif

QrCameraScanner::QrCameraScanner(QObject *parent) : QObject(parent) {}

QrCameraScanner::~QrCameraScanner() { stop(); }

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
    return !QMediaDevices::videoInputs().isEmpty();
#else
    return false;
#endif
}

QString QrCameraScanner::error() const { return m_error; }

QString QrCameraScanner::previewFrame() const { return m_previewFrame; }

void QrCameraScanner::start()
{
#if PARANOIA_HAS_QT_MULTIMEDIA
    if (!supported()) {
        setError("Камера не найдена или недоступна.");
        return;
    }

#if QT_CONFIG(permissions)
    QCameraPermission permission;
    const auto status = qApp->checkPermission(permission);
    if (status == Qt::PermissionStatus::Undetermined) {
        qApp->requestPermission(permission, this, [this](const QPermission &permission) {
            if (permission.status() == Qt::PermissionStatus::Granted)
                start();
            else
                setError("Нет доступа к камере.");
        });
        return;
    }
    if (status == Qt::PermissionStatus::Denied) {
        setError("Нет доступа к камере.");
        return;
    }
#endif

    ensureCamera();
    if (!m_camera) {
        setError("Не удалось инициализировать камеру.");
        return;
    }
    clearError();
    if (!m_active) {
        m_active = true;
        emit activeChanged();
    }
    m_camera->start();
#else
    setError("Сканирование камерой не включено в этой сборке.");
#endif
}

void QrCameraScanner::stop()
{
#if PARANOIA_HAS_QT_MULTIMEDIA
    if (m_camera) m_camera->stop();
#endif
    if (!m_active) return;
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
    m_videoSink      = std::make_unique<QVideoSink>();
    m_captureSession = std::make_unique<QMediaCaptureSession>();
    m_captureSession->setCamera(m_camera.get());
    m_captureSession->setVideoSink(m_videoSink.get());

    connect(m_videoSink.get(), &QVideoSink::videoFrameChanged, this, &QrCameraScanner::handleFrame);
    connect(m_camera.get(), &QCamera::errorOccurred, this,
            [this](QCamera::Error error, const QString &errorString) {
                if (error != QCamera::NoError) setError(errorString.isEmpty() ? "Ошибка камеры." : errorString);
            });
}

void QrCameraScanner::handleFrame(const QVideoFrame &frame)
{
    if (!m_active) return;

    QImage image = frame.toImage();
    if (image.isNull()) return;

    if (!m_previewTimer.isValid() || m_previewTimer.elapsed() > 160) {
        m_previewTimer.restart();
        updatePreview(image);
    }

    if (m_decodeTimer.isValid() && m_decodeTimer.elapsed() < 240) return;
    m_decodeTimer.restart();

    if (image.width() > 1280) image = image.scaledToWidth(1280, Qt::FastTransformation);
    const QString text = decodeQr(image);
    if (text.isEmpty()) return;

    stop();
    emit decoded(text);
}

void QrCameraScanner::updatePreview(const QImage &image)
{
    QImage preview = image;
    if (preview.width() > 720) preview = preview.scaledToWidth(720, Qt::FastTransformation);

    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    if (!preview.save(&buffer, "JPG", 70)) {
        bytes.clear();
        buffer.close();
        buffer.open(QIODevice::WriteOnly);
        if (!preview.save(&buffer, "PNG")) return;
        m_previewFrame = QStringLiteral("data:image/png;base64,") + QString::fromLatin1(bytes.toBase64());
    } else {
        m_previewFrame = QStringLiteral("data:image/jpeg;base64,") + QString::fromLatin1(bytes.toBase64());
    }
    emit previewFrameChanged();
}

QString QrCameraScanner::decodeQr(const QImage &image) const
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
