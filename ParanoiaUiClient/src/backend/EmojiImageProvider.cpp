#include "EmojiImageProvider.hpp"

#include <QFont>
#include <QPainter>

EmojiImageProvider::EmojiImageProvider()
    : QQuickImageProvider(QQuickImageProvider::Image)
{
}

QImage EmojiImageProvider::requestImage(const QString &id, QSize *size, const QSize &requestedSize)
{
    // id — сам эмодзи (URL-декодирован движком). Рендерим в квадрат requestedSize
    // (или 48px по умолчанию), прозрачный фон, цветной глиф через системный
    // fallback-шрифт (QFont без family → fallback на цветной emoji-шрифт).
    int dim = requestedSize.width() > 0 ? requestedSize.width()
            : requestedSize.height() > 0 ? requestedSize.height()
            : 48;
    if (dim < 8) dim = 8;
    if (dim > 256) dim = 256;

    QImage img(dim, dim, QImage::Format_ARGB32_Premultiplied);
    img.fill(Qt::transparent);

    QPainter p(&img);
    p.setRenderHint(QPainter::Antialiasing, true);
    p.setRenderHint(QPainter::TextAntialiasing, true);
    QFont f;
    f.setPixelSize(int(dim * 0.82));
    p.setFont(f);
    p.drawText(QRect(0, 0, dim, dim), Qt::AlignCenter, id);
    p.end();

    if (size) *size = QSize(dim, dim);
    return img;
}
