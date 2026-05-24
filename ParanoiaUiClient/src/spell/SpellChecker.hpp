#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QString>
#include <QStringList>
#include <memory>

class SpellChecker : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(bool available READ available NOTIFY availableChanged)
    Q_PROPERTY(QString locale READ locale WRITE setLocale NOTIFY localeChanged)

public:
    explicit SpellChecker(QObject *parent = nullptr);
    ~SpellChecker() override;

    bool available() const;
    QString locale() const;
    void setLocale(const QString &locale);

    Q_INVOKABLE bool checkWord(const QString &word) const;
    Q_INVOKABLE QStringList suggestWords(const QString &word, int maxCount = 5) const;

    static QString prepareBundledDictionaries();

signals:
    void availableChanged();
    void localeChanged();

private:
    struct Impl;
    std::unique_ptr<Impl> m_impl;
};
