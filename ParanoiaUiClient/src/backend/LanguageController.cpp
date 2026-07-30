#include "LanguageController.hpp"

#include <QCoreApplication>
#include <QLocale>
#include <QQmlApplicationEngine>
#include <QSettings>
#include <QTranslator>
#include <QVariantMap>

namespace {
constexpr auto kSettingsKey = "ui/language";
}

LanguageController::LanguageController(QObject *parent)
    : QObject(parent)
{
    QSettings settings;
    m_language = settings.value(QString::fromLatin1(kSettingsKey),
                                QStringLiteral("system")).toString();
    if (m_language != QStringLiteral("ru") && m_language != QStringLiteral("en"))
        m_language = QStringLiteral("system");
}

QVariantList LanguageController::availableLanguages() const
{
    // name — самоназвание языка (не переводится), чтобы пункт был узнаваем при
    // любом текущем языке интерфейса. «Системный» — через tr, т.к. это не язык.
    QVariantList list;
    auto add = [&list](const QString &code, const QString &name) {
        QVariantMap m;
        m.insert(QStringLiteral("code"), code);
        m.insert(QStringLiteral("name"), name);
        list.append(m);
    };
    add(QStringLiteral("system"), tr("Системный"));
    add(QStringLiteral("ru"), QStringLiteral("Русский"));
    add(QStringLiteral("en"), QStringLiteral("English"));
    return list;
}

void LanguageController::install(const QString &code)
{
    if (m_translator) {
        QCoreApplication::removeTranslator(m_translator);
        delete m_translator;
        m_translator = nullptr;
    }

    // Русский — исходный язык: транслятор не нужен, строки берутся из qsTr-источника.
    if (code == QStringLiteral("ru"))
        return;

    const QLocale locale = (code == QStringLiteral("en"))
                               ? QLocale(QLocale::English)
                               : QLocale(); // system

    auto *t = new QTranslator(this);
    if (t->load(locale, QStringLiteral("Paranoia"), QStringLiteral("_"),
                QStringLiteral(":/i18n"))) {
        QCoreApplication::installTranslator(t);
        m_translator = t;
    } else {
        // .qm нет (напр. русская система) — fallback на исходные строки.
        delete t;
    }
}

void LanguageController::applyInitial()
{
    install(m_language);
}

void LanguageController::setLanguage(const QString &code)
{
    QString c = code;
    if (c != QStringLiteral("ru") && c != QStringLiteral("en"))
        c = QStringLiteral("system");
    if (c == m_language)
        return;

    m_language = c;
    QSettings settings;
    settings.setValue(QString::fromLatin1(kSettingsKey), m_language);

    install(m_language);
    // Горячее обновление: qsTr-биндинги в QML переоценятся.
    if (m_engine)
        m_engine->retranslate();
    emit languageChanged();
}
