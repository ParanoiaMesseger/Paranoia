#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QPointer>
#include <QQuickTextDocument>

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
