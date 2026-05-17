#include "SpellChecker.hpp"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QSet>
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

struct SpellChecker::Impl {
    QString locale = QStringLiteral("ru_RU");
    bool available = false;

#if PARANOIA_HAS_HUNSPELL
    struct HunspellDeleter {
        void operator()(Hunhandle *handle) const
        {
            if (handle) Hunspell_destroy(handle);
        }
    };

    std::vector<std::unique_ptr<Hunhandle, HunspellDeleter>> dictionaries;

    bool loadOne(const QString &localeName)
    {
        const QString aff = ensureBundledDictionaryFile(localeName, QStringLiteral("aff"));
        const QString dic = ensureBundledDictionaryFile(localeName, QStringLiteral("dic"));
        if (aff.isEmpty() || dic.isEmpty()) return false;
        std::unique_ptr<Hunhandle, HunspellDeleter> dictionary(
            Hunspell_create(aff.toUtf8().constData(), dic.toUtf8().constData()));
        if (!dictionary) return false;
        dictionaries.push_back(std::move(dictionary));
        return true;
    }
#endif

    void load()
    {
        available = false;
#if PARANOIA_HAS_HUNSPELL
        dictionaries.clear();
        const QString primary = locale.trimmed().isEmpty() ? QStringLiteral("ru_RU") : locale.trimmed();
        loadOne(primary);
        if (primary != QStringLiteral("en_US")) loadOne(QStringLiteral("en_US"));
        available = !dictionaries.empty();
#endif
    }
};

QString SpellChecker::prepareBundledDictionaries()
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

SpellChecker::SpellChecker(QObject *parent) : QObject(parent), m_impl(std::make_unique<Impl>()) { m_impl->load(); }

SpellChecker::~SpellChecker() = default;

bool SpellChecker::available() const { return m_impl->available; }

QString SpellChecker::locale() const { return m_impl->locale; }

void SpellChecker::setLocale(const QString &locale)
{
    const QString value = locale.trimmed().isEmpty() ? QStringLiteral("ru_RU") : locale.trimmed();
    if (m_impl->locale == value) return;
    const bool wasAvailable = m_impl->available;
    m_impl->locale          = value;
    m_impl->load();
    emit localeChanged();
    if (wasAvailable != m_impl->available) emit availableChanged();
}

bool SpellChecker::checkWord(const QString &word) const
{
    QString normalized = word.trimmed();
    if (normalized.size() < 2 || !m_impl->available) return true;
    static const QRegularExpression letters(QStringLiteral("\\p{L}"), QRegularExpression::UseUnicodePropertiesOption);
    if (!normalized.contains(letters)) return true;
    if (normalized.toUpper() == normalized && normalized.size() > 1) return true;

#if PARANOIA_HAS_HUNSPELL
    const QByteArray normalizedUtf8 = normalized.toUtf8();
    const QString lower             = normalized.toLower();
    const QByteArray lowerUtf8      = lower.toUtf8();
    for (const auto &dictionary : m_impl->dictionaries) {
        if (Hunspell_spell(dictionary.get(), normalizedUtf8.constData()) ||
            Hunspell_spell(dictionary.get(), lowerUtf8.constData()))
            return true;
    }
    return false;
#else
    return true;
#endif
}

QStringList SpellChecker::suggestWords(const QString &word, int maxCount) const
{
    QString normalized = word.trimmed();
    if (normalized.size() < 2 || !m_impl->available || maxCount <= 0) return {};

    QStringList result;
#if PARANOIA_HAS_HUNSPELL
    QSet<QString> seen;
    const QByteArray wordUtf8 = normalized.toUtf8();
    for (const auto &dictionary : m_impl->dictionaries) {
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
#endif
    return result;
}
