#include "KeyInjector.hpp"

#include <QCoreApplication>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QWindow>

void KeyInjector::sendKey(int key, int modifiers, const QString &text)
{
    // focusObject — это внутренний QQuickTextInput/QQuickTextEdit активного поля.
    // Он сам обрабатывает навигацию, выделение и стандартные комбинации
    // (Copy/Paste/SelectAll) в keyPressEvent через QKeySequence::matches().
    QObject *receiver = QGuiApplication::focusObject();
    if (!receiver) receiver = QGuiApplication::focusWindow();
    if (!receiver) return;

    const auto mods = static_cast<Qt::KeyboardModifiers>(modifiers);

    QKeyEvent press(QEvent::KeyPress, key, mods, text);
    QCoreApplication::sendEvent(receiver, &press);
    QKeyEvent release(QEvent::KeyRelease, key, mods, text);
    QCoreApplication::sendEvent(receiver, &release);
}
