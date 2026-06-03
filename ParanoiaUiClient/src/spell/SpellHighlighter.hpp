#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QPointer>
#include <QQuickTextDocument>
#include <QStringList>
#include <QVariantList>

class SpellSyntaxHighlighter;

class SpellHighlighter : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QQuickTextDocument *textDocument READ textDocument WRITE setTextDocument NOTIFY textDocumentChanged)
    Q_PROPERTY(bool enabled READ enabled WRITE setEnabled NOTIFY enabledChanged)
    Q_PROPERTY(QString locale READ locale WRITE setLocale NOTIFY localeChanged)
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)

public:
    explicit SpellHighlighter(QObject *parent = nullptr);
    ~SpellHighlighter() override;

    QQuickTextDocument *textDocument() const;
    void setTextDocument(QQuickTextDocument *document);

    bool enabled() const;
    void setEnabled(bool enabled);

    QString locale() const;
    void setLocale(const QString &locale);

    bool available() const;

    // Returns {start, length, word, suggestions} for the misspelled word at `position`,
    // or an empty map when the position is not over a misspelled word.
    Q_INVOKABLE QVariantMap misspelledAt(int position, int maxSuggestions = 5) const;

    // Все диапазоны опечаток в документе: список {start, length}. QQuickTextEdit
    // не рендерит underline из QSyntaxHighlighter, поэтому QML рисует подчёркивание
    // сам (Canvas-оверлей), беря эти диапазоны + positionToRectangle.
    Q_INVOKABLE QVariantList misspelledRanges() const;

signals:
    void textDocumentChanged();
    void enabledChanged();
    void localeChanged();
    void availableChanged();

private:
    void rebuildHighlighter();

    QPointer<QQuickTextDocument> m_textDocument;
    SpellSyntaxHighlighter *m_highlighter = nullptr;
    QString m_locale                      = QStringLiteral("ru_RU");
    bool m_enabled                        = true;
};
