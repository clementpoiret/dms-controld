import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("controlD.startupCheck", [
            "sh", "-c", "command -v nslookup >/dev/null 2>&1"
        ], function(stdout, exitCode) {
            if (exitCode === 0) {
                done(null)
                return
            }
            done({
                title: "nslookup is required",
                details: "Install the DNS lookup utility provided by your distribution's BIND or DNS utilities package, ensure 'nslookup' is on DankMaterialShell's PATH, then enable Control D again."
            })
        }, 0)
    }
}
