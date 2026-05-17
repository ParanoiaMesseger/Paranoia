function Component() {}

Component.prototype.createOperations = function() {
    component.createOperations();

    if (systemInfo.kernelType === "linux") {
        component.addOperation("Mkdir", "@HomeDir@/.local/bin");
        component.addOperation(
            "CreateLink",
            "@HomeDir@/.local/bin/Paranoia",
            "@TargetDir@/bin/Paranoia"
        );
        component.addOperation("Mkdir", "@HomeDir@/.local/share/applications");
        component.addOperation(
            "CreateLink",
            "@HomeDir@/.local/share/applications/app.paranoia.client.desktop",
            "@TargetDir@/share/applications/app.paranoia.client.desktop"
        );
    }

    if (systemInfo.productType === "windows") {
        // Install MSVC runtime silently; noop if already installed
        component.addElevatedOperation(
            "Execute",
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
