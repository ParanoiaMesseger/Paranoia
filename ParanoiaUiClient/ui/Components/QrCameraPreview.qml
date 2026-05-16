import QtQuick
import QtMultimedia

VideoOutput {
    id: root

    property var scanner: null

    fillMode: VideoOutput.PreserveAspectCrop

    function attachScanner() {
        if (root.scanner)
            root.scanner.videoOutput = root
    }

    onScannerChanged: attachScanner()
    Component.onCompleted: attachScanner()
    Component.onDestruction: {
        if (root.scanner && root.scanner.videoOutput === root)
            root.scanner.videoOutput = null
    }
}
