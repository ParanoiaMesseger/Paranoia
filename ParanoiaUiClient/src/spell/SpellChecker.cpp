#include "SpellChecker.hpp"

#include <QRegularExpression>

namespace
{
    QString normalizeLocale(const QString &locale)
    {
        const QString trimmed = locale.trimmed();
        return trimmed.isEmpty() ? QStringLiteral("ru_RU") : trimmed;
    }
}

SpellChecker::SpellChecker(QObject *parent) : QObject(parent)
{
    // Тёплый кэш: если словари этой локали уже загружены другим чекером — берём
    // сразу (available без ожидания). НЕ триггерим загрузку здесь — это ensureLoaded.
    m_dicts = SpellDictionaryPool::instance()->peek(m_locale);
    // По готовности фоновой загрузки подхватываем набор и сообщаем наверх.
    connect(SpellDictionaryPool::instance(), &SpellDictionaryPool::localeReady, this,
            [this](const QString &loc) {
                if (loc != m_locale) return;
                SpellDictionaryPool::Handle ready = SpellDictionaryPool::instance()->peek(m_locale);
                if (!ready || ready == m_dicts) return;
                const bool wasAvailable = available();
                m_dicts                 = ready;
                if (wasAvailable != available()) emit availableChanged();
            });
}

SpellChecker::~SpellChecker() = default;

bool SpellChecker::available() const { return m_dicts && !m_dicts->empty(); }

QString SpellChecker::locale() const { return m_locale; }

void SpellChecker::ensureLoaded()
{
    m_requested = true;
    if (available()) return;
    const bool wasAvailable = available();
    // acquire вернёт готовый набор (тёплый кэш) сразу или null + старт фоновой
    // загрузки; во втором случае набор придёт сигналом localeReady.
    m_dicts = SpellDictionaryPool::instance()->acquire(m_locale);
    if (wasAvailable != available()) emit availableChanged();
}

void SpellChecker::setLocale(const QString &locale)
{
    const QString value = normalizeLocale(locale);
    if (m_locale == value) return;
    const bool wasAvailable = available();
    m_locale                = value;
    // Подхватить готовый набор новой локали из кэша; если проверка уже запрашивалась —
    // при промахе кэша запустить фоновую загрузку под новую локаль.
    m_dicts = SpellDictionaryPool::instance()->peek(m_locale);
    if (m_requested && !available()) m_dicts = SpellDictionaryPool::instance()->acquire(m_locale);
    emit localeChanged();
    if (wasAvailable != available()) emit availableChanged();
}

bool SpellChecker::checkWord(const QString &word) const
{
    QString normalized = word.trimmed();
    if (normalized.size() < 2 || !available()) return true;
    static const QRegularExpression letters(QStringLiteral("\\p{L}"), QRegularExpression::UseUnicodePropertiesOption);
    if (!normalized.contains(letters)) return true;
    if (normalized.toUpper() == normalized && normalized.size() > 1) return true;

    const QByteArray normalizedUtf8 = normalized.toUtf8();
    const QByteArray lowerUtf8      = normalized.toLower().toUtf8();
    return m_dicts->spell(normalizedUtf8, lowerUtf8);
}

QStringList SpellChecker::suggestWords(const QString &word, int maxCount) const
{
    QString normalized = word.trimmed();
    if (normalized.size() < 2 || !available() || maxCount <= 0) return {};
    return m_dicts->suggest(normalized.toUtf8(), maxCount);
}

QString SpellChecker::prepareBundledDictionaries()
{
    return SpellDictionaryPool::prepareBundledDictionaries();
}
