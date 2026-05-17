#include "SpellHighlighter.hpp"

#include "SpellChecker.hpp"

#include <QColor>
#include <QQuickTextDocument>
#include <QRegularExpression>
#include <QSyntaxHighlighter>
#include <QTextCharFormat>
#include <QTextDocument>

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

protected:
    void highlightBlock(const QString &text) override
    {
        if (!m_enabled || !m_checker.available()) return;

        static const QRegularExpression wordPattern(QStringLiteral("[\\p{L}][\\p{L}\\p{Mn}'’\\-]*"),
                                                    QRegularExpression::UseUnicodePropertiesOption);
        QTextCharFormat errorFormat;
        errorFormat.setUnderlineStyle(QTextCharFormat::SpellCheckUnderline);
        errorFormat.setUnderlineColor(QColor(QStringLiteral("#FF2738")));

        auto match = wordPattern.globalMatch(text);
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
