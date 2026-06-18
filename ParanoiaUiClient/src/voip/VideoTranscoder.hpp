#pragma once

#include <QImage>
#include <QString>
#include <functional>

namespace paranoia::media
{

    /// Транскодер видео-вложений на libav* (libavformat/avcodec/swscale/swresample).
    ///
    /// Назначение: перед отправкой сжать произвольный выбранный пользователем
    /// видеофайл (mp4/mov/mkv/webm, камеры телефонов H.264/HEVC) в компактный
    /// H.264/AAC mp4 — как делают мессенджеры: даунскейл до разумного разрешения,
    /// умеренный битрейт, faststart (moov в начало для прогрессивного
    /// проигрывания). Аудио перекодируется в AAC.
    ///
    /// 🔐 Транскодер работает ТОЛЬКО с локально выбранным отправителем файлом.
    /// Входящее (полученное) видео проигрывается нативным медиаплеером ОС
    /// (Qt Multimedia), а НЕ парсится нашим ffmpeg — недоверенный сетевой ввод в
    /// демуксеры libavformat не попадает.
    class VideoTranscoder
    {
    public:
        struct Options {
            /// Самая длинная сторона кадра ограничивается этим значением (с
            /// сохранением пропорций, чётные размеры). 0 — не масштабировать.
            int maxDimension = 1280;
            /// Целевой битрейт видео, бит/с. 0 — авто по разрешению результата.
            int videoBitrateBps = 0;
            /// Целевой битрейт аудио, бит/с.
            int audioBitrateBps = 128'000;
        };

        /// Перекодировать `inputPath` → `outputPath` (mp4). `progress` вызывается
        /// со значением 0.0..1.0 (по позиции относительно длительности; может не
        /// дойти строго до 1.0 — финал гарантируется возвратом true). При ошибке
        /// возвращает false и пишет причину в `*error` (если не null).
        ///
        /// Метод СИНХРОННЫЙ и тяжёлый — вызывать на рабочем потоке.
        static bool transcode(const QString &inputPath, const QString &outputPath,
                              const std::function<void(double)> &progress, QString *error, Options opt);

        /// Удобный overload с настройками по умолчанию.
        static bool transcode(const QString &inputPath, const QString &outputPath,
                              const std::function<void(double)> &progress, QString *error)
        {
            return transcode(inputPath, outputPath, progress, error, Options{});
        }

        /// Извлечь репрезентативный кадр для превью (первый декодируемый кадр).
        /// Возвращает RGB-изображение или null QImage при ошибке. Используется и
        /// на отправителе (исходный файл), и на получателе (скачанный mp4).
        static QImage extractPosterFrame(const QString &path, QString *error = nullptr);
    };

} // namespace paranoia::media
