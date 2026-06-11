#pragma once

#include <QQuickImageProvider>

// Рендерит эмодзи-символ в QImage через QPainter (id = сам эмодзи). Нужен, чтобы
// большая эмодзи-сетка (#42) НЕ упиралась в цветной glyph-кэш scene-graph (на
// Android он переполнялся → часть эмодзи/целые вкладки не рисовались). Картинки
// идут через обычный QML image-cache (LRU, перерисовка при промахе) — пустот нет.
class EmojiImageProvider : public QQuickImageProvider
{
public:
    EmojiImageProvider();
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;
};
