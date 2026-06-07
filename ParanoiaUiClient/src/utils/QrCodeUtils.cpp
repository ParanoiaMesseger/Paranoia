#include "QrCodeUtils.hpp"

#include "Utils.hpp"

#include <QBuffer>
#include <ReadBarcode.h>
#include <qrcodegen.hpp>
#include <QPainter>
#include <ParanoiaFFI>

QString QrCodeUtils::pngDataUrl(const QString &payload, int size)
{
    const QByteArray data = payload.toUtf8();
    if (data.isEmpty()) return {};
    const int requestedSize = std::clamp(size, 128, 2048);
    try {
        const std::vector<std::uint8_t> bytes(data.cbegin(), data.cend());
        const qrcodegen::QrCode qr = qrcodegen::QrCode::encodeBinary(bytes, qrcodegen::QrCode::Ecc::LOW);
        constexpr int border       = 4;
        const int modules          = qr.getSize() + border * 2;
        const int scale            = std::max(1, requestedSize / modules);
        const int imageSize        = modules * scale;

        QImage image(imageSize, imageSize, QImage::Format_RGB32);
        image.fill(Qt::white);

        QPainter painter(&image);
        painter.setPen(Qt::NoPen);
        painter.setBrush(Qt::black);
        for (int y = 0; y < qr.getSize(); ++y)
            for (int x = 0; x < qr.getSize(); ++x)
                if (qr.getModule(x, y)) { painter.drawRect((x + border) * scale, (y + border) * scale, scale, scale); }
        painter.end();
        QByteArray png;
        QBuffer buffer(&png);
        buffer.open(QIODevice::WriteOnly);
        if (!image.save(&buffer, "PNG")) return {};
        return QStringLiteral("data:image/png;base64,") + QString::fromLatin1(png.toBase64());
    } catch (const std::exception &e) {
        qWarning() << "QR generation failed:" << e.what();
        return {};
    }
}

QVariantMap QrCodeUtils::decodeFromImage(const QString &filePath)
{
    const QString path = Utils::normalizeLocalFilePath(filePath);
    if (path.isEmpty()) return ParanoiaFFI::errorResult(QrCodeUtils::tr("Не указан файл изображения с QR-кодом."));

    const QImage image(path);
    if (image.isNull()) return ParanoiaFFI::errorResult(QrCodeUtils::tr("Не удалось открыть изображение с QR-кодом."));

    const QImage gray = image.convertToFormat(QImage::Format_Grayscale8);
    try {
        const ZXing::ImageView view(gray.constBits(), gray.width(), gray.height(), ZXing::ImageFormat::Lum,
                                    gray.bytesPerLine());
        ZXing::ReaderOptions options;
        options.setFormats(ZXing::BarcodeFormat::QRCode).setTryHarder(true).setTryRotate(true).setTryInvert(true);
        const auto barcodes = ZXing::ReadBarcodes(view, options);
        for (const auto &barcode : barcodes) {
            if (barcode.isValid()) {
                return QVariantMap{{"ok", true}, {"text", QString::fromStdString(barcode.text())}};
            }
        }
        return ParanoiaFFI::errorResult(QrCodeUtils::tr("QR-код на изображении не найден."));
    } catch (const std::exception &e) {
        return ParanoiaFFI::errorResult(QrCodeUtils::tr("Ошибка чтения QR-кода: ") + QString::fromUtf8(e.what()));
    }
}

QVariantMap QrCodeUtils::registrationPublicKeyFromQr(const QString &payload)
{
    QString text = payload.trimmed();
    if (text.isEmpty()) return ParanoiaFFI::errorResult(QrCodeUtils::tr("QR-код не содержит данные регистрации."));
    QJsonParseError parseError;
    const QJsonDocument doc = QJsonDocument::fromJson(text.toUtf8(), &parseError);
    if (parseError.error == QJsonParseError::NoError && doc.isObject()) {
        const QJsonObject obj = doc.object();
        text                  = obj.value(QStringLiteral("pubkey")).toString().trimmed();
    }
    if (!Utils::decodeFixedBase64(text, 32))
        return ParanoiaFFI::errorResult(QrCodeUtils::tr("QR-код не содержит корректный публичный ключ base64."));
    return QVariantMap{{"ok", true}, {"pubkey", text}};
}