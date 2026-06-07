#pragma once
#if defined(PARANOIA_IOS)

#include <QObject>
#include <QString>

// Нативный экспорт файла на iOS через UIDocumentPickerViewController(forExporting:).
//
// Зачем: QtQuick.Dialogs.FileDialog на iOS поддерживает ТОЛЬКО открытие —
// QIOSFileDialog::show() возвращает false для AcceptSave, и QtQuick.Dialogs
// падает в QML-fallback (десктопный файловый браузер: широкое окно с дефолтными
// кнопками, не помещается на экран телефона). Поэтому сохранение/экспорт делаем
// сами: пишем во временный файл в песочнице и даём системный document picker
// выбрать назначение («Файлы»/iCloud/AirDrop на другое устройство).
//
// Открытие/импорт/выбор фото на iOS у Qt нативные — их трогать не нужно.
class IosFileExport : public QObject
{
    Q_OBJECT

public:
    explicit IosFileExport(QObject *parent = nullptr) : QObject(parent) {}

    // Путь во временном каталоге песочницы для файла filename (только базовое имя).
    Q_INVOKABLE QString prepareExportPath(const QString &filename);

    // Презентует системный экспорт-пикер для уже записанного файла localPath.
    // Если файла нет — no-op (вызывающий уже показал ошибку записи).
    Q_INVOKABLE void exportFile(const QString &localPath);
};

#endif // PARANOIA_IOS
