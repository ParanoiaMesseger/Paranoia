#pragma once

#include "SpellDictionaryPool.hpp"

#include <QObject>
#include <QString>
#include <QStringList>

// Проверка орфографии поверх шаренного пула словарей (SpellDictionaryPool).
// Конструктор ДЁШЕВЫЙ (не грузит словари) — тяжёлая загрузка ленивая и фоновая,
// запускается ensureLoaded() только когда проверка реально нужна (см. 01#20).
class SpellChecker : public QObject
{
    Q_OBJECT

public:
    explicit SpellChecker(QObject *parent = nullptr);
    ~SpellChecker() override;

    bool available() const;
    QString locale() const;
    void setLocale(const QString &locale);

    // Запускает ленивую фоновую загрузку словарей текущей локали, если ещё не
    // загружены (иначе — подхватывает готовые из пула). Звать только когда проверка
    // включена: на мобилках (enabled=false) словари не грузятся вовсе.
    void ensureLoaded();

    // checkWord/suggestWords зовёт только SpellHighlighter (C++); SpellChecker не
    // QML-тип (QML_ELEMENT снят в 01#20), поэтому Q_INVOKABLE-маркеры лишние (03#35).
    bool checkWord(const QString &word) const;
    QStringList suggestWords(const QString &word, int maxCount = 5) const;

    static QString prepareBundledDictionaries();

signals:
    void availableChanged();
    void localeChanged();

private:
    QString                     m_locale = QStringLiteral("ru_RU");
    SpellDictionaryPool::Handle m_dicts;             // готовый набор из пула или null
    bool                        m_requested = false; // ensureLoaded для текущей локали вызывали
};
