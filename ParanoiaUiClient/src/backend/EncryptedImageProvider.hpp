#pragma once
#include <QByteArray>
#include <QCache>
#include <QImage>
#include <QMutex>
#include <QQuickImageProvider>
#include <QSize>

/// In-memory ImageProvider для расшифрованных вложений. Plaintext-байты
/// никогда не пишутся на диск: ChatBackend кладёт сюда QByteArray, QML
/// читает через "image://secure/<msg_id>".
///
/// Кеш ограничен по числу элементов (LRU). При vault_lock владелец обязан
/// вызвать clear() — иначе расшифрованные байты останутся в heap.
class EncryptedImageProvider : public QQuickImageProvider
{
public:
    // Лимит RAM на расшифрованные превью. Превью даунскейлятся до ~2048px
    // (~150-400 КБ JPEG, см. makePreviewBytes в ChatBackend), поэтому 128 МБ —
    // это сотни фото без вытеснения. Храним ЭНКОДНЫЕ байты (не декод), декод
    // живёт в scene-graph отдельно, так что для RAM это умеренно. Достигнут —
    // QCache вытесняет LRU.
    static constexpr int kMaxBytesBudget = 128 * 1024 * 1024;

    EncryptedImageProvider()
        : QQuickImageProvider(QQuickImageProvider::Image), m_cache(kMaxBytesBudget) {}

    /// Положить байты для id. Тип содержимого определяется QImage::loadFromData
    /// (PNG/JPEG/WebP). Перезаписывает существующее. cost = размер в байтах,
    /// чтобы лимит QCache считал реальную RAM, а не «64 элемента любого размера».
    void setBytes(const QString &id, const QByteArray &bytes)
    {
        QMutexLocker lock(&m_mutex);
        const int cost = qBound(1, static_cast<int>(bytes.size()), kMaxBytesBudget);
        m_cache.insert(id, new QByteArray(bytes), cost);
    }

    void remove(const QString &id)
    {
        QMutexLocker lock(&m_mutex);
        m_cache.remove(id);
    }

    void clear()
    {
        QMutexLocker lock(&m_mutex);
        m_cache.clear();
    }

    bool contains(const QString &id) const
    {
        QMutexLocker lock(&m_mutex);
        return m_cache.contains(id);
    }

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override
    {
        QByteArray bytes;
        {
            QMutexLocker lock(&m_mutex);
            QByteArray *cached = m_cache.object(id);
            if (cached) bytes = *cached;
        }
        if (bytes.isEmpty()) return {};
        QImage img;
        if (!img.loadFromData(bytes)) return {};
        if (size) *size = img.size();
        if (!requestedSize.isEmpty() && requestedSize.width() > 0 && requestedSize.height() > 0)
            return img.scaled(requestedSize, Qt::KeepAspectRatio, Qt::SmoothTransformation);
        return img;
    }

private:
    mutable QMutex m_mutex;
    QCache<QString, QByteArray> m_cache;
};
