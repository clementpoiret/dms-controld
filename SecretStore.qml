import QtQuick
import Quickshell.Io

QtObject {
    id: root

    readonly property bool busy: availabilityProcess.running || storeProcess.running
                                 || lookupProcess.running || clearProcess.running
    property string pendingSecret: ""

    signal availabilityFinished(bool available)
    signal storeFinished(bool success, string message)
    signal lookupFinished(bool success, string secret, string message)
    signal clearFinished(bool success, string message)

    function checkAvailability() {
        if (busy)
            return false
        availabilityProcess.running = true
        return true
    }

    function store(secret) {
        if (busy || !secret || secret.length === 0)
            return false
        pendingSecret = secret
        storeProcess.stdinEnabled = true
        storeProcess.running = true
        return true
    }

    function lookup() {
        if (busy)
            return false
        lookupProcess.running = true
        return true
    }

    function clear() {
        if (busy)
            return false
        clearProcess.running = true
        return true
    }

    property Process availabilityProcess: Process {
        command: ["sh", "-c", "command -v secret-tool >/dev/null 2>&1"]
        running: false
        onExited: function(exitCode) {
            // Quickshell updates Process.running after emitting exited. Defer the
            // callback so a listener can immediately start the lookup process.
            Qt.callLater(function() {
                root.availabilityFinished(exitCode === 0)
            })
        }
    }

    property Process storeProcess: Process {
        command: [
            "secret-tool", "store",
            "--label=Control D API token — DMS",
            "application", "dms-control-d",
            "account", "default"
        ]
        stdinEnabled: true
        running: false
        stderr: StdioCollector {}

        onStarted: {
            storeProcess.write(root.pendingSecret)
            root.pendingSecret = ""
            storeProcess.stdinEnabled = false
        }

        onExited: function(exitCode) {
            root.pendingSecret = ""
            storeProcess.stdinEnabled = true
            root.storeFinished(exitCode === 0,
                               exitCode === 0 ? "" : "Secret Service rejected the token")
        }
    }

    property Process lookupProcess: Process {
        command: [
            "secret-tool", "lookup",
            "application", "dms-control-d",
            "account", "default"
        ]
        running: false
        stdout: StdioCollector { id: lookupOutput }
        stderr: StdioCollector {}

        onExited: function(exitCode) {
            if (exitCode !== 0) {
                root.lookupFinished(false, "", "No stored Control D token was found")
                return
            }
            var secret = lookupOutput.text || ""
            secret = secret.replace(/\r?\n$/, "")
            if (!secret) {
                root.lookupFinished(false, "", "No stored Control D token was found")
                return
            }
            root.lookupFinished(true, secret, "")
            secret = ""
        }
    }

    property Process clearProcess: Process {
        command: [
            "secret-tool", "clear",
            "application", "dms-control-d",
            "account", "default"
        ]
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}

        onExited: function(exitCode) {
            root.clearFinished(exitCode === 0,
                               exitCode === 0 ? "" : "Secret Service could not forget the token")
        }
    }

    Component.onDestruction: {
        pendingSecret = ""
        availabilityProcess.running = false
        storeProcess.running = false
        lookupProcess.running = false
        clearProcess.running = false
    }
}
