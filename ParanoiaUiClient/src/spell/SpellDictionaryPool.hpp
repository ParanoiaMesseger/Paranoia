#pragma once

#include <QByteArray>
#include <QHash>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <memory>

// Иммутабельный набор загруженных словарей Hunspell (первичная локаль + en_US
// фолбэк). Хэндлы Hunspell НЕ потокобезопасны для конкурентного spell/suggest,
// поэтому эти методы вызываются ТОЛЬКО на GUI-потоке. Фоновый воркер набор лишь
// СОЗДАЁТ (Hunspell_create) и передаёт готовым — далее только чтение.
class LoadedDictionaries
{
public:
    LoadedDictionaries();
    ~LoadedDictionaries();
    LoadedDictionaries(const LoadedDictionaries &)            = delete;
    LoadedDictionaries &operator=(const LoadedDictionaries &) = delete;

    bool empty() const;
    // true, если слово известно хотя бы одному словарю (проверяются оба варианта:
    // как есть и в нижнем регистре — вызывающий передаёт уже нормализованные utf8).
    bool spell(const QByteArray &wordUtf8, const QByteArray &lowerUtf8) const;
    QStringList suggest(const QByteArray &wordUtf8, int maxCount) const;

private:
    friend class SpellDictionaryPool;
    bool addLocale(const QString &localeName); // строит Hunspell_create; зовёт пул на воркере

    struct Impl;
    std::unique_ptr<Impl> d;
};

// Шаренный кэш словарей Hunspell по локали с ленивой ФОНОВОЙ загрузкой.
//
// 01#20: раньше каждый SpellSyntaxHighlighter владел SpellChecker'ом по значению, и
// его конструктор грузил ru_RU (.dic 3.48 МБ) + en_US синхронно на GUI-потоке — на
// КАЖДОЕ открытие чата (ChatPage пересоздаётся). Здесь словари грузятся ОДИН раз на
// локаль, на QThreadPool-воркере, и шарятся всеми чекерами; готовый набор
// иммутабелен. Пул — «утекающий» синглтон (живёт до конца процесса), поэтому набор,
// раз загруженный, не освобождается — это и есть кэш.
class SpellDictionaryPool : public QObject
{
    Q_OBJECT
public:
    using Handle = std::shared_ptr<const LoadedDictionaries>;

    static SpellDictionaryPool *instance();

    // Готовый набор для локали, если он уже в кэше; иначе — null БЕЗ запуска загрузки.
    Handle peek(const QString &locale) const;
    // Готовый набор, если загружен; иначе — null и (при первом запросе) старт фоновой
    // загрузки. По готовности — сигнал localeReady(нормализованная-локаль).
    Handle acquire(const QString &locale);

    // Разово копирует связанные словари из qrc на диск (вызывается на старте).
    static QString prepareBundledDictionaries();

signals:
    void localeReady(const QString &locale);

private:
    explicit SpellDictionaryPool(QObject *parent = nullptr);

    QHash<QString, Handle> m_ready;   // только GUI-поток
    QSet<QString>          m_loading; // только GUI-поток
};
