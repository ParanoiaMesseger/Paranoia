#pragma once

#include <QObject>
#include <QString>
#include <QVariantList>

class QTranslator;
class QQmlApplicationEngine;

// Выбор языка интерфейса. Исходные строки русские (sourcelanguage=ru), английский
// перевод встроен в :/i18n/Paranoia_en.qm. По умолчанию язык берётся из системной
// локали; пользователь может переопределить его в настройках. Выбор сохраняется в
// QSettings и применяется без перезапуска через QQmlApplicationEngine::retranslate().
class LanguageController : public QObject
{
    Q_OBJECT

    // "system" | "ru" | "en"
    Q_PROPERTY(QString language READ language NOTIFY languageChanged)
    Q_PROPERTY(QVariantList availableLanguages READ availableLanguages CONSTANT)

public:
    explicit LanguageController(QObject *parent = nullptr);

    QString language() const { return m_language; }
    QVariantList availableLanguages() const;

    // Движок нужен для горячего retranslate() при смене языка в рантайме.
    void setEngine(QQmlApplicationEngine *engine) { m_engine = engine; }

    // Поставить транслятор по сохранённому языку. Вызывать на старте ДО engine.load().
    void applyInitial();

    Q_INVOKABLE void setLanguage(const QString &code);

signals:
    void languageChanged();

private:
    // Снять прошлый транслятор и поставить новый для языка code (ru = без транслятора,
    // т.к. русский — исходный язык). Возвращает true, если транслятор установлен.
    void install(const QString &code);

    QString m_language; // выбранный код языка
    QTranslator *m_translator = nullptr;
    QQmlApplicationEngine *m_engine = nullptr;
};
