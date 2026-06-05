import QtQuick
import QtQuick.Dialogs as QQD

// Универсальный файловый диалог приложения.
//
//   • Desktop (macOS/Windows/Linux) → нативный системный QFileDialog через C++
//     `FileDialogs` (NativeFileDialog). QML-обёртки Qt на macOS 26 не выводят
//     нативную панель на экран — см. NativeFileDialog.hpp.
//   • Mobile (Android/iOS) → QtQuick.Dialogs (QtWidgets там не линкуется).
//
// API повторяет QtQuick.Dialogs.FileDialog, чтобы обработчики на местах не
// менялись: selectedFile / selectedFiles / selectedFolder (file:// URL) +
// signal accepted(). Режим задаётся `mode`.
QtObject {
    id: ctl

    // Конфигурация
    property string title: ""
    property var    nameFilters: []
    property string mode: "open"        // "open" | "openMultiple" | "save" | "folder"
    property string defaultSuffix: ""
    property url    currentFile          // для "save": предложенное имя/путь

    // Результаты (как у QtQuick.Dialogs.FileDialog/FolderDialog)
    property url selectedFile
    property var selectedFiles: []
    property url selectedFolder

    signal accepted()

    readonly property bool _desktop: !(Qt.platform.os === "android" || Qt.platform.os === "ios")

    function open() {
        if (ctl._desktop) {
            if (ctl.mode === "openMultiple") {
                var urls = FileDialogs.openFiles(ctl.title, ctl.nameFilters)
                if (urls && urls.length > 0) { ctl.selectedFiles = urls; ctl.accepted() }
            } else if (ctl.mode === "save") {
                var nm = ctl.currentFile.toString()
                if (nm.indexOf("/") >= 0) nm = nm.substring(nm.lastIndexOf("/") + 1)
                var su = FileDialogs.saveFile(ctl.title, ctl.nameFilters, nm)
                if (su.toString().length > 0) { ctl.selectedFile = su; ctl.accepted() }
            } else if (ctl.mode === "folder") {
                var fu = FileDialogs.openFolder(ctl.title)
                if (fu.toString().length > 0) { ctl.selectedFolder = fu; ctl.accepted() }
            } else {
                var ou = FileDialogs.openFile(ctl.title, ctl.nameFilters)
                if (ou.toString().length > 0) { ctl.selectedFile = ou; ctl.accepted() }
            }
        } else if (ctl.mode === "folder") {
            _folderDlg.open()
        } else {
            if (ctl.mode === "save" && ctl.currentFile.toString().length > 0)
                _fileDlg.currentFile = ctl.currentFile
            _fileDlg.open()
        }
    }

    // Мобильные нативные диалоги (на десктопе создаются, но не открываются).
    property QtObject _fileDlg: QQD.FileDialog {
        title: ctl.title
        nameFilters: ctl.nameFilters
        defaultSuffix: ctl.defaultSuffix
        fileMode: ctl.mode === "openMultiple" ? QQD.FileDialog.OpenFiles
                : ctl.mode === "save"          ? QQD.FileDialog.SaveFile
                                               : QQD.FileDialog.OpenFile
        onAccepted: {
            if (ctl.mode === "openMultiple") { ctl.selectedFiles = selectedFiles; ctl.accepted() }
            else                             { ctl.selectedFile  = selectedFile;  ctl.accepted() }
        }
    }

    property QtObject _folderDlg: QQD.FolderDialog {
        title: ctl.title
        onAccepted: { ctl.selectedFolder = selectedFolder; ctl.accepted() }
    }
}
