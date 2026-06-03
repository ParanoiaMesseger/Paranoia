function Component() {}

Component.prototype.createOperations = function() {
    component.createOperations();

    // IFW используется только для Windows (Linux → .deb, macOS → .dmg).
    if (systemInfo.productType === "windows") {
        // Install MSVC runtime silently.
        // Accepted exit codes: 0 (success), 1638 (newer or equal version already
        // installed), 1641 (success, reboot initiated), 3010 (success, reboot
        // required). Without this list IFW treats 1638 as failure and shows
        // an error dialog when VC++ runtime is already present on the system.
        component.addElevatedOperation(
            "Execute",
            "{0,1638,1641,3010}",
            "@TargetDir@/bin/vc_redist.x64.exe", "/install", "/quiet", "/norestart",
            "UNDOEXECUTE", ""
        );

        component.addOperation(
            "CreateShortcut",
            "@TargetDir@/bin/Paranoia.exe",
            "@DesktopDir@/Paranoia.lnk",
            "workingDirectory=@TargetDir@/bin",
            "description=Paranoia messaging client"
        );

        component.addOperation(
            "CreateShortcut",
            "@TargetDir@/bin/Paranoia.exe",
            "@StartMenuDir@/Paranoia.lnk",
            "workingDirectory=@TargetDir@/bin",
            "description=Paranoia messaging client"
        );

        component.addOperation(
            "CreateShortcut",
            "@TargetDir@/ParanoiaMaintenance.exe",
            "@StartMenuDir@/Uninstall Paranoia.lnk",
            "description=Uninstall Paranoia"
        );
    }
};
