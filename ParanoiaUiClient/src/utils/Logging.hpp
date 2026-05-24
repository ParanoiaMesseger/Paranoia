#pragma once
#include <QObject>

class QQmlApplicationEngine;
class QQmlError;

class Logging : public QObject
{
    Q_OBJECT
    QQmlApplicationEngine* engine_ = nullptr;
public:
    Logging();
    void connectEngine(QQmlApplicationEngine* engine);
public slots:
    void qmlWarnings(const QList<QQmlError> &warnings);
    void objectCreationFailed();
};
