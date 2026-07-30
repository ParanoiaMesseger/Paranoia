#include "SpellDictionaryPool.hpp"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QMetaObject>
#include <QStandardPaths>
#include <QThreadPool>
#include <vector>

#ifndef PARANOIA_HAS_HUNSPELL
#define PARANOIA_HAS_HUNSPELL 0
#endif

#if PARANOIA_HAS_HUNSPELL
#include <hunspell/hunspell.h>
#endif

namespace
{
    const QStringList kBundledLocales = {QStringLiteral("ru_RU"), QStringLiteral("en_US")};

    QString normalizeLocale(const QString &locale)
    {
        const QString trimmed = locale.trimmed();
        return trimmed.isEmpty() ? QStringLiteral("ru_RU") : trimmed;
    }

    QString dictionaryDataPath()
    {
        QString root = QStandardPaths::writableLocation(QStandardPaths::AppDataLocation);
        if (root.isEmpty()) root = QDir::tempPath();
        QDir dir(root);
        if (!dir.mkpath(QStringLiteral("dictionaries"))) return {};
        return dir.filePath(QStringLiteral("dictionaries"));
    }

    QString ensureBundledDictionaryFile(const QString &localeName, const QString &suffix)
    {
        const QString root = dictionaryDataPath();
        if (root.isEmpty()) return {};

        const QString resourcePath = QStringLiteral(":/dictionaries/%1.%2").arg(localeName, suffix);
        if (!QFile::exists(resourcePath)) return {};

        const QString targetPath = QDir(root).filePath(QStringLiteral("%1.%2").arg(localeName, suffix));
        QFileInfo targetInfo(targetPath);
        QFile resource(resourcePath);
        if (targetInfo.exists() && resource.open(QIODevice::ReadOnly) && targetInfo.size() == resource.size())
            return targetPath;

        QFile::remove(targetPath);
        return QFile::copy(resourcePath, targetPath) ? targetPath : QString();
    }
}

struct LoadedDictionaries::Impl {
#if PARANOIA_HAS_HUNSPELL
    struct HunspellDeleter {
        void operator()(Hunhandle *handle) const
        {
            if (handle) Hunspell_destroy(handle);
        }
    };
    std::vector<std::unique_ptr<Hunhandle, HunspellDeleter>> dictionaries;
#endif
};

LoadedDictionaries::LoadedDictionaries() : d(std::make_unique<Impl>()) {}
LoadedDictionaries::~LoadedDictionaries() = default;

bool LoadedDictionaries::empty() const
{
#if PARANOIA_HAS_HUNSPELL
    return d->dictionaries.empty();
#else
    return true;
#endif
}

bool LoadedDictionaries::addLocale(const QString &localeName)
{
#if PARANOIA_HAS_HUNSPELL
    const QString aff = ensureBundledDictionaryFile(localeName, QStringLiteral("aff"));
    const QString dic = ensureBundledDictionaryFile(localeName, QStringLiteral("dic"));
    if (aff.isEmpty() || dic.isEmpty()) return false;
    std::unique_ptr<Hunhandle, Impl::HunspellDeleter> dictionary(
        Hunspell_create(aff.toUtf8().constData(), dic.toUtf8().constData()));
    if (!dictionary) return false;
    d->dictionaries.push_back(std::move(dictionary));
    return true;
#else
    Q_UNUSED(localeName);
    return false;
#endif
}

bool LoadedDictionaries::spell(const QByteArray &wordUtf8, const QByteArray &lowerUtf8) const
{
#if PARANOIA_HAS_HUNSPELL
    for (const auto &dictionary : d->dictionaries) {
        if (Hunspell_spell(dictionary.get(), wordUtf8.constData()) ||
            Hunspell_spell(dictionary.get(), lowerUtf8.constData()))
            return true;
    }
    return false;
#else
    Q_UNUSED(wordUtf8);
    Q_UNUSED(lowerUtf8);
    return true;
#endif
}

QStringList LoadedDictionaries::suggest(const QByteArray &wordUtf8, int maxCount) const
{
    QStringList result;
#if PARANOIA_HAS_HUNSPELL
    QSet<QString> seen;
    for (const auto &dictionary : d->dictionaries) {
        char **suggestions = nullptr;
        const int count    = Hunspell_suggest(dictionary.get(), &suggestions, wordUtf8.constData());
        for (int i = 0; i < count && result.size() < maxCount; ++i) {
            const QString suggestion = QString::fromUtf8(suggestions[i]).trimmed();
            if (suggestion.isEmpty() || seen.contains(suggestion)) continue;
            seen.insert(suggestion);
            result.push_back(suggestion);
        }
        Hunspell_free_list(dictionary.get(), &suggestions, count);
        if (result.size() >= maxCount) break;
    }
#else
    Q_UNUSED(wordUtf8);
    Q_UNUSED(maxCount);
#endif
    return result;
}

SpellDictionaryPool *SpellDictionaryPool::instance()
{
    // «Утекающий» синглтон: словари-кэш живёт до конца процесса (ОС вернёт память).
    static SpellDictionaryPool *inst = new SpellDictionaryPool();
    return inst;
}

SpellDictionaryPool::SpellDictionaryPool(QObject *parent) : QObject(parent) {}

SpellDictionaryPool::Handle SpellDictionaryPool::peek(const QString &locale) const
{
    const auto it = m_ready.constFind(normalizeLocale(locale));
    return it != m_ready.constEnd() ? it.value() : Handle{};
}

SpellDictionaryPool::Handle SpellDictionaryPool::acquire(const QString &locale)
{
    const QString key = normalizeLocale(locale);
    if (const auto it = m_ready.constFind(key); it != m_ready.constEnd()) return it.value();
    if (m_loading.contains(key)) return {}; // загрузка уже идёт — придёт localeReady
    m_loading.insert(key);

    // Синглтон бессмертен → сырой указатель стабилен, захватывать безопасно.
    SpellDictionaryPool *self = this;
    QThreadPool::globalInstance()->start([self, key]() {
        auto dicts = std::make_shared<LoadedDictionaries>();
        dicts->addLocale(key); // тяжёлый Hunspell_create — на воркере, не на GUI
        if (key != QStringLiteral("en_US")) dicts->addLocale(QStringLiteral("en_US"));
        Handle ready = std::move(dicts); // shared_ptr<LoadedDictionaries> → <const ...>
        // Готовый (иммутабельный) набор передаём на GUI-поток через очередь.
        QMetaObject::invokeMethod(self, [self, key, ready]() {
            self->m_loading.remove(key);
            self->m_ready.insert(key, ready);
            emit self->localeReady(key);
        });
    });
    return {};
}

QString SpellDictionaryPool::prepareBundledDictionaries()
{
    const QString root = dictionaryDataPath();
    if (root.isEmpty()) return {};

    bool copiedAny = false;
    for (const QString &localeName : kBundledLocales) {
        const bool hasAff = !ensureBundledDictionaryFile(localeName, QStringLiteral("aff")).isEmpty();
        const bool hasDic = !ensureBundledDictionaryFile(localeName, QStringLiteral("dic")).isEmpty();
        copiedAny         = copiedAny || (hasAff && hasDic);
    }
    return copiedAny ? root : QString();
}
