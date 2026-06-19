#pragma once

#include <QObject>
#include <QString>

// Помощник для работы с системным буфером обмена на десктопе.
//
// Текст из буфера штатно вставляется самим TextArea (Ctrl+V), а вот картинку
// (например, скриншот в буфере) Qt Quick TextArea вставить не умеет. Этот
// хелпер сохраняет изображение из QClipboard во временный PNG и возвращает путь,
// чтобы QML мог отправить его как вложение через Chat.sendFile.
class ClipboardUtils : public QObject
{
    Q_OBJECT
public:
    explicit ClipboardUtils(QObject *parent = nullptr) : QObject(parent) {}

    // Есть ли в буфере именно изображение (не пустое).
    Q_INVOKABLE bool hasImage() const;

    // Сохранить картинку из буфера во временный PNG. Возвращает абсолютный путь
    // или пустую строку (картинки нет / не удалось сохранить).
    Q_INVOKABLE QString saveImageToTemp() const;

    // Текст из буфера (на случай унификации логики вставки в QML).
    Q_INVOKABLE QString text() const;
};
