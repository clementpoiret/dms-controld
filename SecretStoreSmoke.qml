import QtQuick
import Quickshell

ShellRoot {
    SecretStore {
        id: secretStore

        onAvailabilityFinished: function(available) {
            if (secretStore.busy) {
                console.error("SecretStore availability callback ran while the helper was still busy")
                Qt.exit(1)
                return
            }
            console.info("SecretStore availability callback ran after the helper became idle:", available)
            Qt.exit(0)
        }
    }

    Timer {
        interval: 3000
        running: true
        onTriggered: {
            console.error("SecretStore availability check timed out")
            Qt.exit(1)
        }
    }

    Component.onCompleted: {
        if (!secretStore.checkAvailability()) {
            console.error("SecretStore availability check did not start")
            Qt.exit(1)
        }
    }
}
