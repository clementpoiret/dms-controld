import QtQuick
import Quickshell.Io
import "ControlDModels.js" as Models

QtObject {
    id: root

    readonly property bool running: primaryProcess.running || neutralProcess.running || timeoutTimer.running
    property string phase: "idle"
    property bool timedOut: false

    signal finished(var result)

    function run() {
        if (running)
            return false
        timedOut = false
        phase = "primary"
        primaryProcess.running = true
        timeoutTimer.restart()
        return true
    }

    function finish(state, detail) {
        timeoutTimer.stop()
        phase = "idle"
        finished({
            state: state,
            detail: detail,
            lastCheckedAt: Date.now()
        })
    }

    function runNeutral() {
        timedOut = false
        phase = "neutral"
        neutralProcess.running = true
        timeoutTimer.restart()
    }

    property Timer timeoutTimer: Timer {
        interval: 5000
        repeat: false
        onTriggered: {
            root.timedOut = true
            if (root.phase === "primary" && primaryProcess.running)
                primaryProcess.running = false
            else if (root.phase === "neutral" && neutralProcess.running)
                neutralProcess.running = false
        }
    }

    property Process primaryProcess: Process {
        command: ["nslookup", "verify.controld.com"]
        environment: ({ "LC_ALL": "C" })
        running: false
        stdout: StdioCollector { id: primaryOutput }
        stderr: StdioCollector {}

        onExited: function(exitCode) {
            if (root.phase !== "primary")
                return
            timeoutTimer.stop()
            var parsed = Models.parseNslookupAnswer(primaryOutput.text || "")
            if (!root.timedOut && exitCode === 0 && parsed.ok) {
                root.finish("healthy", "Control D verification returned an address")
                return
            }
            root.runNeutral()
        }
    }

    property Process neutralProcess: Process {
        command: ["nslookup", "example.com"]
        environment: ({ "LC_ALL": "C" })
        running: false
        stdout: StdioCollector { id: neutralOutput }
        stderr: StdioCollector {}

        onExited: function(exitCode) {
            if (root.phase !== "neutral")
                return
            timeoutTimer.stop()
            var parsed = Models.parseNslookupAnswer(neutralOutput.text || "")
            if (!root.timedOut && exitCode === 0 && parsed.ok) {
                root.finish("misconfigured", "Local DNS works, but Control D verification failed")
                return
            }
            root.finish("offline", "The Control D and neutral DNS lookups both failed")
        }
    }

    Component.onDestruction: {
        timeoutTimer.stop()
        primaryProcess.running = false
        neutralProcess.running = false
    }
}
