// Controller-script — позволяет переустанавливать Paranoia поверх существующей
// копии без ручного запуска MaintenanceTool. По умолчанию Qt IFW на странице
// выбора папки выдаёт «TargetDirectoryInUse: Выбранный каталог существует и
// содержит установленное приложение» и заблокирует пользователя. Этот hard-
// блок нельзя обойти автоответом на диалог (IFW принимает только Ok/NoButton
// для этого ID и всё равно не пропускает дальше).
//
// Поэтому до того, как IFW дойдёт до своих проверок, мы вручную сносим
// предыдущую установку:
//   1) taskkill старого ParanoiaMaintenance.exe (вдруг висит)
//   2) rmdir /S /Q всей папки TargetDir
//   3) reg delete реестровых записей, по которым IFW определяет
//      «приложение установлено»
//
// MaintenanceTool с `purge` мы НЕ дожидаемся — на практике он делает
// self-update spawn, primary процесс выходит сразу, а копия может висеть
// десятки секунд и иногда вообще не доделать uninstall (см. лог пользователя:
// после 30s poll'а MaintenanceTool.exe всё ещё на месте). Так что force-
// cleanup намного надёжнее.
//
// Безопасность: пользовательские профили и диалоги хранятся в
// QStandardPaths::AppDataLocation (%APPDATA%\<org>\<app> на Windows,
// ~/.local/share/<org>/<app> на Linux) — это другое дерево, не пересекается
// с TargetDir. rmdir сносит только бинари установки.

function Controller() {
    Controller.prototype._cleanupAttempted = false;

    Controller.prototype._toNativePath = function(path) {
        if (systemInfo.productType === "windows") {
            return path.replace(/\//g, "\\");
        }
        return path;
    };

    Controller.prototype._safeExecute = function(program, args, tag) {
        try {
            var result = installer.execute(program, args);
            console.log("controlscript[" + tag + "]: " + program + " "
                        + args.join(" ") + " — ok");
            return result;
        } catch (e) {
            console.log("controlscript[" + tag + "]: " + program + " "
                        + args.join(" ") + " — failed: " + e);
            return null;
        }
    };

    Controller.prototype._cleanupOldInstall = function(targetDir, source) {
        if (Controller.prototype._cleanupAttempted) {
            return;
        }
        if (!targetDir) {
            return;
        }

        // IFW используется только для Windows (Linux → .deb, macOS → .dmg).
        var mt = targetDir + "/ParanoiaMaintenance.exe";

        if (!installer.fileExists(mt)) {
            console.log("controlscript[" + source + "]: no existing install at " + mt);
            return;
        }

        Controller.prototype._cleanupAttempted = true;
        console.log("controlscript[" + source + "]: removing existing install at " + targetDir);

        {
            var winPath = Controller.prototype._toNativePath(targetDir);

            // Kill anything still holding files in TargetDir.
            Controller.prototype._safeExecute("taskkill.exe",
                ["/F", "/IM", "ParanoiaMaintenance.exe", "/T"], source);
            // На случай висящей self-update копии MaintenanceTool: у IFW
            // обычно она называется <Name>Maintenance.dat или с цифровым
            // суффиксом. Шаблон с * через taskkill /IM поддерживается.
            Controller.prototype._safeExecute("taskkill.exe",
                ["/F", "/IM", "Paranoia.exe", "/T"], source);

            // Force-remove TargetDir.
            Controller.prototype._safeExecute("cmd.exe",
                ["/c", "rmdir", "/S", "/Q", winPath], source);

            // IFW writes a registry stub used to detect "already installed".
            // Конкретный путь зависит от <Name>/<Publisher>/<MaintenanceToolName>
            // в config.xml; чистим все правдоподобные варианты — reg delete
            // молча вернёт error для отсутствующих ключей, и это нормально.
            var regCandidates = [
                "HKCU\\Software\\Paranoia",
                "HKCU\\Software\\Paranoia\\Paranoia",
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Paranoia",
                "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\ParanoiaMaintenance"
            ];
            for (var i = 0; i < regCandidates.length; i++) {
                Controller.prototype._safeExecute("reg.exe",
                    ["delete", regCandidates[i], "/f"], source);
            }
        }

        if (installer.fileExists(mt)) {
            console.log("controlscript[" + source + "]: WARNING — "
                        + mt + " still present after cleanup; IFW may block "
                        + "with TargetDirectoryInUse");
        } else {
            console.log("controlscript[" + source + "]: cleanup ok");
        }
    };

    if (typeof installer === "undefined" || !installer.isInstaller()) {
        return;
    }

    var targetDir = installer.value("TargetDir");
    console.log("controlscript[ctor]: installer.value('TargetDir') = " + targetDir);
    if (!targetDir || targetDir.indexOf("@") !== -1) {
        var homeDir = installer.value("HomeDir");
        console.log("controlscript[ctor]: HomeDir = " + homeDir);
        if (homeDir) {
            targetDir = homeDir + "/AppData/Local/Programs/Paranoia";
        }
    }
    Controller.prototype._cleanupOldInstall(targetDir, "ctor");
}

// Если пользователь сам сменит TargetDir на путь с другой старой установкой,
// здесь чистим её тоже.
Controller.prototype.TargetDirectoryPageCallback = function() {
    var targetDir = installer.value("TargetDir");
    console.log("controlscript[targetDirPage]: TargetDir = " + targetDir);
    Controller.prototype._cleanupOldInstall(targetDir, "targetDirPage");
};
