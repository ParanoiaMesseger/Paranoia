#pragma once

#include <QObject>
#include <QString>

// Доставляет синтетические нажатия клавиш текущему фокусному элементу.
// Используется панелью навигации над виртуальной клавиатурой (EditKeyToolbar.qml):
// кнопки «в начало / выделить всё / стрелки / копировать / вставить / в конец»
// шлют QKeyEvent прямо в focusObject, как это делает сама виртуальная клавиатура
// для навигационных клавиш. Работает с QtQuick TextInput/TextEdit на всех платформах.
class KeyInjector : public QObject
{
    Q_OBJECT
public:
    explicit KeyInjector(QObject *parent = nullptr) : QObject(parent) {}

    // key       — значение Qt::Key (например Qt::Key_Left).
    // modifiers — битовая маска Qt::KeyboardModifiers (например Qt::ControlModifier).
    // text      — опциональный вставляемый текст (для навигации не нужен).
    Q_INVOKABLE void sendKey(int key, int modifiers = 0, const QString &text = QString());
};
