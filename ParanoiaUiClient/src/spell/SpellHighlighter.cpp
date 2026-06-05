#include "SpellHighlighter.hpp"

#include "SpellChecker.hpp"

#include <QColor>
#include <QDebug>
#include <QQuickTextDocument>
#include <QRegularExpression>
#include <QSyntaxHighlighter>
#include <QTextCharFormat>
#include <QTextDocument>
#include <QVariantMap>

namespace
{
    // Word boundary regex — same as in SpellSyntaxHighlighter, kept here so we can
    // locate the word the user clicked on without re-scanning the whole text.
    const QRegularExpression &wordPattern()
    {
        static const QRegularExpression pattern(QStringLiteral("[\\p{L}][\\p{L}\\p{Mn}'’\\-]*"),
                                                QRegularExpression::UseUnicodePropertiesOption);
        return pattern;
    }
}

class SpellSyntaxHighlighter final : public QSyntaxHighlighter
{
public:
    explicit SpellSyntaxHighlighter(QTextDocument *document) : QSyntaxHighlighter(document) {}

    void setEnabled(bool enabled)
    {
        if (m_enabled == enabled) return;
        m_enabled = enabled;
        rehighlight();
    }

    void setLocale(const QString &locale)
    {
        m_checker.setLocale(locale);
        rehighlight();
    }

    bool available() const { return m_checker.available(); }

    QStringList suggest(const QString &word, int maxCount) const { return m_checker.suggestWords(word, maxCount); }

    bool isMisspelled(const QString &word) const { return !m_checker.checkWord(word); }

protected:
    void highlightBlock(const QString &text) override
    {
        // QQuickTextEdit НЕ рендерит underline-decoration из QSyntaxHighlighter,
        // поэтому видимое подчёркивание рисует QML-оверлей (см. misspelledRanges +
        // Canvas в ChatPage). Здесь формат всё же ставим — на случай платформ, где
        // он рендерится, и чтобы документ нёс корректную разметку; вреда нет.
        if (!m_enabled || !m_checker.available()) return;

        QTextCharFormat errorFormat;
        errorFormat.setUnderlineStyle(QTextCharFormat::WaveUnderline);
        errorFormat.setUnderlineColor(QColor(QStringLiteral("#FF2738")));

        auto match = wordPattern().globalMatch(text);
        while (match.hasNext()) {
            const auto wordMatch = match.next();
            const int start      = wordMatch.capturedStart();
            const QString word   = wordMatch.captured();
            if (start > 0 && (text[start - 1] == QLatin1Char('@') || text[start - 1] == QLatin1Char('#'))) continue;
            if (word == QStringLiteral("http") || word == QStringLiteral("https")) continue;
            if (!m_checker.checkWord(word)) setFormat(start, word.size(), errorFormat);
        }
    }

private:
    SpellChecker m_checker;
    bool m_enabled = true;
};

SpellHighlighter::SpellHighlighter(QObject *parent) : QObject(parent) {}

SpellHighlighter::~SpellHighlighter() { delete m_highlighter; }

QQuickTextDocument *SpellHighlighter::textDocument() const { return m_textDocument; }

void SpellHighlighter::setTextDocument(QQuickTextDocument *document)
{
    if (m_textDocument == document) return;
    m_textDocument = document;
    rebuildHighlighter();
    emit textDocumentChanged();
}

bool SpellHighlighter::enabled() const { return m_enabled; }

void SpellHighlighter::setEnabled(bool enabled)
{
    if (m_enabled == enabled) return;
    m_enabled = enabled;
    if (m_highlighter) m_highlighter->setEnabled(enabled);
    emit enabledChanged();
}

QString SpellHighlighter::locale() const { return m_locale; }

void SpellHighlighter::setLocale(const QString &locale)
{
    const QString value = locale.trimmed().isEmpty() ? QStringLiteral("ru_RU") : locale.trimmed();
    if (m_locale == value) return;
    const bool wasAvailable = available();
    m_locale                = value;
    if (m_highlighter) m_highlighter->setLocale(m_locale);
    emit localeChanged();
    if (wasAvailable != available()) emit availableChanged();
}

bool SpellHighlighter::available() const { return m_highlighter && m_highlighter->available(); }

QVariantMap SpellHighlighter::misspelledAt(int position, int maxSuggestions) const
{
    if (!m_enabled || !m_highlighter || !m_textDocument) return {};
    QTextDocument *doc = m_textDocument->textDocument();
    if (!doc || position < 0 || position > doc->characterCount()) return {};

    const QString text = doc->toPlainText();
    if (position > text.size()) return {};

    auto match = wordPattern().globalMatch(text);
    while (match.hasNext()) {
        const auto wordMatch = match.next();
        const int start      = wordMatch.capturedStart();
        const int end        = wordMatch.capturedEnd();
        if (position < start) return {};
        if (position > end) continue;
        const QString word = wordMatch.captured();
        if (start > 0 && (text[start - 1] == QLatin1Char('@') || text[start - 1] == QLatin1Char('#'))) return {};
        if (word == QStringLiteral("http") || word == QStringLiteral("https")) return {};
        if (!m_highlighter->isMisspelled(word)) return {};
        QVariantMap result;
        result[QStringLiteral("start")]       = start;
        result[QStringLiteral("length")]      = word.size();
        result[QStringLiteral("word")]        = word;
        result[QStringLiteral("suggestions")] = m_highlighter->suggest(word, maxSuggestions);
        return result;
    }
    return {};
}

QVariantList SpellHighlighter::misspelledRanges() const
{
    QVariantList ranges;
    if (!m_enabled || !m_highlighter || !m_textDocument) return ranges;
    QTextDocument *doc = m_textDocument->textDocument();
    if (!doc) return ranges;

    const QString text = doc->toPlainText();
    auto match = wordPattern().globalMatch(text);
    while (match.hasNext()) {
        const auto wordMatch = match.next();
        const int start      = wordMatch.capturedStart();
        const QString word   = wordMatch.captured();
        if (start > 0 && (text[start - 1] == QLatin1Char('@') || text[start - 1] == QLatin1Char('#'))) continue;
        if (word == QStringLiteral("http") || word == QStringLiteral("https")) continue;
        if (!m_highlighter->isMisspelled(word)) continue;
        QVariantMap r;
        r[QStringLiteral("start")]  = start;
        r[QStringLiteral("length")] = word.size();
        ranges.append(r);
    }
    return ranges;
}

void SpellHighlighter::rebuildHighlighter()
{
    const bool wasAvailable = available();
    delete m_highlighter;
    m_highlighter = nullptr;
    if (m_textDocument && m_textDocument->textDocument()) {
        m_highlighter = new SpellSyntaxHighlighter(m_textDocument->textDocument());
        connect(m_highlighter, &QObject::destroyed, this, [this]() { m_highlighter = nullptr; });
        m_highlighter->setEnabled(m_enabled);
        m_highlighter->setLocale(m_locale);
    }
    if (wasAvailable != available()) emit availableChanged();
}
