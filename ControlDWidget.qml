pragma ComponentBehavior: Bound

import QtQuick
import qs.Common
import qs.Modals.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    popoutWidth: 420
    popoutHeight: 620

    property int commandSequence: 0
    property double uiNow: Date.now()
    property bool showCommandResult: false
    readonly property var snapshot: snapshotVar.value || ({})
    readonly property var commandResult: resultVar.value || null

    onCommandResultChanged: {
        var age = commandResult ? Date.now() - Number(commandResult.completedAt || 0) : 12000
        showCommandResult = commandResult !== null && commandResult !== undefined && age >= 0 && age < 12000
        if (showCommandResult) {
            commandResultTimer.interval = Math.max(1, 12000 - age)
            commandResultTimer.restart()
        }
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.uiNow = Date.now()
    }

    Timer {
        id: commandResultTimer
        interval: 12000
        onTriggered: root.showCommandResult = false
    }

    PluginGlobalVar {
        id: snapshotVar
        varName: "snapshot"
        defaultValue: ({
            phase: "loading",
            revision: 0,
            overallState: "loading",
            api: { state: "unknown", lastSuccessAt: 0 },
            auth: { state: "loading", writeState: "unverified" },
            dns: { state: "unknown", lastCheckedAt: 0, detail: "Not checked" },
            endpoints: [],
            profiles: [],
            capabilities: { pause: false, pauseMode: "unavailable" },
            remainingPauseSeconds: 0
        })
    }

    PluginGlobalVar {
        id: commandVar
        varName: "command"
        defaultValue: null
    }

    PluginGlobalVar {
        id: resultVar
        varName: "commandResult"
        defaultValue: null
    }

    ConfirmModal {
        id: sharedPauseConfirm
    }

    function setting(key, fallback) {
        return pluginData && pluginData[key] !== undefined ? pluginData[key] : fallback
    }

    function sendCommand(type, payload) {
        showCommandResult = false
        commandSequence += 1
        var now = Date.now()
        commandVar.set({
            id: pluginId + "-widget-" + now + "-" + commandSequence,
            type: type,
            payload: payload || {},
            issuedAt: now
        })
    }

    function stateIcon(state) {
        switch (state) {
        case "healthy": return "shield"
        case "paused": return "pause_circle"
        case "hardDisabled": return "block"
        case "misconfigured": return "warning"
        case "offline": return "cloud_off"
        case "authError": return "key_off"
        case "setupRequired": return "settings"
        case "loading": return "progress_activity"
        default: return "help"
        }
    }

    function stateColor(state) {
        switch (state) {
        case "healthy": return Theme.success
        case "paused": return Theme.warning
        case "hardDisabled":
        case "misconfigured":
        case "authError": return Theme.error
        case "setupRequired": return Theme.primary
        default: return Theme.surfaceVariantText
        }
    }

    function stateLabel(state) {
        switch (state) {
        case "healthy": return "Protected"
        case "paused": return "Protection paused"
        case "hardDisabled": return "Hard disabled"
        case "misconfigured": return "DNS misconfigured"
        case "offline": return "Offline"
        case "authError": return "Authentication failed"
        case "setupRequired": return "Setup required"
        case "loading": return "Loading"
        default: return "Unknown"
        }
    }

    function configLabel(state) {
        switch (state) {
        case "active": return "Active"
        case "softDisabled": return "Soft disabled"
        case "hardDisabled": return "Hard disabled"
        case "pending": return "Pending"
        default: return "Unknown"
        }
    }

    function dnsLabel() {
        switch (snapshot.dns ? snapshot.dns.state : "unknown") {
        case "healthy": return "Healthy"
        case "misconfigured": return "Misconfigured"
        case "offline": return "Offline"
        case "checking": return "Checking"
        case "toolError": return "Tool unavailable"
        default: return "Unknown"
        }
    }

    function dnsIcon() {
        switch (snapshot.dns ? snapshot.dns.state : "unknown") {
        case "healthy": return "check_circle"
        case "misconfigured": return "warning"
        case "offline": return "cloud_off"
        case "checking": return "progress_activity"
        case "toolError": return "error"
        default: return "help"
        }
    }

    function dnsColor() {
        switch (snapshot.dns ? snapshot.dns.state : "unknown") {
        case "healthy": return Theme.success
        case "misconfigured":
        case "offline":
        case "toolError": return Theme.error
        case "checking": return Theme.primary
        default: return Theme.surfaceVariantText
        }
    }

    function dnsDescription() {
        var detail = snapshot.dns ? snapshot.dns.detail : "DNS has not been checked"
        if (snapshot.overallState === "paused" && snapshot.dns && snapshot.dns.state === "healthy")
            return "DNS is still routed through Control D; policy enforcement is paused."
        return detail
    }

    function protectionDescription() {
        switch (snapshot.configState) {
        case "active": return "Filtering is enabled for this endpoint."
        case "softDisabled": return "Filtering is off; DNS remains configured."
        case "hardDisabled": return "Hard disabled outside this widget; only reactivation is allowed."
        case "pending": return "This endpoint is not ready for changes yet."
        default: return "Protection state is unavailable."
        }
    }

    function stateDescription() {
        switch (snapshot.overallState) {
        case "healthy":
            return "Protection is active and local DNS is using Control D."
        case "paused":
            if (snapshot.pauseSource === "both")
                return "Protection is off and the profile pause timer is also active."
            if (snapshot.pauseSource === "profile")
                return (snapshot.capabilities && snapshot.capabilities.pauseMode === "unconfirmed"
                        ? "Locally tracked profile pause" : "Profile pause active")
                        + " · " + formatDuration(snapshot.remainingPauseSeconds) + " remaining"
            return "Protection is off for this endpoint; DNS remains configured."
        case "hardDisabled": return "This endpoint was hard disabled outside the widget."
        case "misconfigured": return snapshot.dns ? snapshot.dns.detail : "This machine is not using Control D DNS."
        case "offline":
            return snapshot.stale ? "Control D is unreachable; showing the last confirmed state."
                                  : "Control D or the local DNS route is unavailable."
        case "authError": return "The configured token was rejected. Update it in settings."
        case "setupRequired": return "Add a credential and associate this machine with an endpoint."
        case "loading": return "Refreshing account and DNS state…"
        default: return "Protection state cannot be confirmed yet."
        }
    }

    function busyLabel() {
        switch (snapshot.busyAction || "") {
        case "setProtection": return "Updating protection…"
        case "switchProfile": return "Switching profile…"
        case "pauseProfile": return "Pausing profile…"
        case "resumeProfile": return "Reactivating profile…"
        default: return ""
        }
    }

    function commandResultMatches(types) {
        return showCommandResult && commandResult && types.indexOf(commandResult.type) !== -1
    }

    function apiLabel() {
        switch (snapshot.api ? snapshot.api.state : "unknown") {
        case "online": return "Online"
        case "offline": return "Offline"
        case "loading": return "Refreshing"
        case "error": return "Error"
        default: return "Unknown"
        }
    }

    function shortId(value) {
        var text = String(value || "")
        return text.length > 6 ? text.slice(-6) : text
    }

    function formatCompactDuration(seconds) {
        var value = Math.max(0, Number(seconds) || 0)
        if (value >= 3600)
            return Math.ceil(value / 3600) + "h"
        if (value >= 60)
            return Math.ceil(value / 60) + "m"
        return Math.ceil(value) + "s"
    }

    function formatDuration(seconds) {
        var value = Math.max(0, Math.floor(Number(seconds) || 0))
        var hours = Math.floor(value / 3600)
        var minutes = Math.floor((value % 3600) / 60)
        var remaining = value % 60
        if (hours > 0)
            return hours + "h " + minutes + "m " + remaining + "s"
        if (minutes > 0)
            return minutes + "m " + remaining + "s"
        return remaining + "s"
    }

    function relativeTime(timestamp) {
        var elapsed = Math.max(0, uiNow - (Number(timestamp) || 0))
        if (!timestamp)
            return "never"
        if (elapsed < 60000)
            return "just now"
        if (elapsed < 3600000)
            return Math.floor(elapsed / 60000) + "m ago"
        if (elapsed < 86400000)
            return Math.floor(elapsed / 3600000) + "h ago"
        return Math.floor(elapsed / 86400000) + "d ago"
    }

    function profileLabel(profile) {
        return profile ? profile.name + " · " + shortId(profile.pk) : ""
    }

    function profileOptions() {
        return (snapshot.profiles || []).map(function(profile) { return root.profileLabel(profile) })
    }

    function profileIdForLabel(label) {
        var profile = (snapshot.profiles || []).find(function(item) {
            return root.profileLabel(item) === label
        })
        return profile ? profile.pk : ""
    }

    function barText() {
        var mode = setting("barLabelMode", "profile")
        if (mode === "icon-only")
            return ""
        if (mode === "compact")
            return "CD"
        var state = snapshot.overallState || "unknown"
        if (state === "hardDisabled") return "CD · Disabled"
        if (state === "misconfigured") return "CD · DNS"
        if (state === "offline") return "CD · Offline"
        if (state === "authError") return "CD · Auth"
        if (state === "setupRequired") return "CD · Setup"
        if (state === "loading") return "CD · …"
        if (!snapshot.profile) return "CD · Unknown"
        var text = "CD · " + snapshot.profile.name
        if (state === "paused")
            text += snapshot.remainingPauseSeconds > 0
                ? " · " + (snapshot.capabilities && snapshot.capabilities.pauseMode === "unconfirmed" ? "~" : "")
                  + formatCompactDuration(snapshot.remainingPauseSeconds) : " · Off"
        return text
    }

    function tooltipText() {
        var endpoint = snapshot.endpoint ? snapshot.endpoint.name : "Not selected"
        var profile = snapshot.profile ? snapshot.profile.name : "Not selected"
        var text = "Control D — Endpoint: " + endpoint + " — Profile: " + profile
                + " — Status: " + configLabel(snapshot.configState)
                + " — DNS: " + dnsLabel()
                + " — API: " + (snapshot.api ? snapshot.api.state : "unknown")
        if (snapshot.stale)
            text += " — stale, last confirmed " + relativeTime(snapshot.api ? snapshot.api.lastSuccessAt : 0)
        return text
    }

    function requestPause(seconds) {
        var profile = snapshot.profile
        if (!profile)
            return
        var shared = Number(profile.sharedEndpointCount) > 1
        if (shared && setting("confirmSharedPause", true)) {
            sharedPauseConfirm.showWithOptions({
                title: "Pause shared profile?",
                message: "Pausing “" + profile.name + "” affects " + profile.sharedEndpointCount
                         + " endpoints. DNS policy enforcement will be paused for all of them.",
                confirmText: "Pause profile",
                confirmColor: Theme.warning,
                onConfirm: function() {
                    root.sendCommand("pauseProfile", { seconds: seconds, confirmedShared: true })
                }
            })
            return
        }
        sendCommand("pauseProfile", { seconds: seconds, confirmedShared: true })
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            Accessible.name: root.tooltipText()
            Accessible.role: Accessible.Button

            DankIcon {
                name: root.stateIcon(root.snapshot.overallState)
                size: root.iconSize
                color: root.stateColor(root.snapshot.overallState)
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.barText().length > 0
                text: root.barText()
                font.pixelSize: Theme.barTextSize(root.barThickness, root.barConfig?.fontScale)
                color: Theme.widgetTextColor
                elide: Text.ElideRight
                wrapMode: Text.NoWrap
                width: Math.min(implicitWidth, 140)
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: root.iconSize
            implicitHeight: root.iconSize

            Accessible.name: root.tooltipText()
            Accessible.role: Accessible.Button

            DankIcon {
                anchors.centerIn: parent
                name: root.stateIcon(root.snapshot.overallState)
                size: root.iconSize
                color: root.stateColor(root.snapshot.overallState)
            }
        }
    }

    popoutContent: Component {
        PopoutComponent {
            id: popout
            headerText: "Control D"
            detailsText: root.snapshot.endpoint
                         ? root.snapshot.endpoint.name + " · " + (root.snapshot.profile ? root.snapshot.profile.name : "No profile")
                         : "Select an endpoint in settings"
            showCloseButton: true

            headerActions: Component {
                DankActionButton {
                    iconName: root.snapshot.api && root.snapshot.api.state === "loading"
                              ? "progress_activity" : "refresh"
                    iconColor: Theme.surfaceVariantText
                    buttonSize: 28
                    tooltipText: "Refresh Control D"
                    tooltipSide: "bottom"
                    enabled: root.snapshot.phase !== "loading" && !root.snapshot.busyAction
                    Accessible.name: "Refresh Control D"
                    Accessible.role: Accessible.Button
                    onClicked: root.sendCommand("refreshAll", {})
                }
            }

            Component.onCompleted: {
                var lastSuccess = root.snapshot.api ? Number(root.snapshot.api.lastSuccessAt) || 0 : 0
                if (root.snapshot.auth && root.snapshot.auth.secretPresent
                        && root.snapshot.auth.state !== "rejected"
                        && Date.now() - lastSuccess > 30000)
                    root.sendCommand("refreshAll", {})
            }

            DankFlickable {
                width: parent.width
                height: Math.max(0, root.popoutHeight - popout.headerHeight - popout.detailsHeight)
                contentWidth: width
                contentHeight: popoutColumn.implicitHeight + Theme.spacingM * 2
                clip: true

                Column {
                    id: popoutColumn
                    width: parent.width - Theme.spacingM * 2
                    x: Theme.spacingM
                    y: Theme.spacingM
                    spacing: Theme.spacingM

                    StyledRect {
                        width: parent.width
                        height: statusColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.withAlpha(root.stateColor(root.snapshot.overallState), 0.10)
                        border.color: Theme.withAlpha(root.stateColor(root.snapshot.overallState), 0.35)
                        border.width: 1

                        Column {
                            id: statusColumn
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingM

                                DankIcon {
                                    name: root.stateIcon(root.snapshot.overallState)
                                    size: 38
                                    color: root.stateColor(root.snapshot.overallState)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    width: parent.width - 38 - Theme.spacingM
                                    spacing: Theme.spacingXS

                                    StyledText {
                                        width: parent.width
                                        text: root.stateLabel(root.snapshot.overallState)
                                        color: Theme.surfaceText
                                        font.pixelSize: Theme.fontSizeLarge
                                        font.weight: Font.Medium
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: root.stateDescription()
                                        color: Theme.surfaceVariantText
                                        wrapMode: Text.WordWrap
                                    }

                                    StyledText {
                                        width: parent.width
                                        visible: root.snapshot.stale
                                        text: "Last confirmed " + root.relativeTime(root.snapshot.api ? root.snapshot.api.lastSuccessAt : 0)
                                        color: Theme.warning
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }
                            }

                            StyledText {
                                width: parent.width
                                visible: root.commandResultMatches(["refreshAll"])
                                text: root.commandResult ? root.commandResult.message : ""
                                color: root.commandResult && root.commandResult.ok ? Theme.success : Theme.error
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                width: parent.width
                                visible: root.snapshot.lastError
                                         && (root.snapshot.lastError.subsystem === "api"
                                             || root.snapshot.lastError.subsystem === "credentials"
                                             || root.snapshot.lastError.subsystem === "account")
                                text: root.snapshot.lastError ? root.snapshot.lastError.message : ""
                                color: Theme.error
                                wrapMode: Text.WordWrap
                            }

                            DankButton {
                                visible: root.snapshot.phase === "setupRequired"
                                         || root.snapshot.overallState === "authError"
                                width: parent.width
                                text: "Open Control D settings"
                                iconName: "settings"
                                Accessible.name: text
                                Accessible.role: Accessible.Button
                                onClicked: {
                                    if (popout.closePopout)
                                        popout.closePopout()
                                    PopoutService.openSettingsWithTab("plugins")
                                }
                            }
                        }
                    }

                    StyledRect {
                        visible: root.snapshot.endpoint !== null && root.snapshot.endpoint !== undefined
                        width: parent.width
                        height: protectionColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            id: protectionColumn
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            DankToggle {
                                width: parent.width
                                text: "Protection"
                                description: root.protectionDescription()
                                descriptionColor: root.snapshot.configState === "hardDisabled"
                                                  ? Theme.error : Theme.surfaceVariantText
                                checked: root.snapshot.configState === "active"
                                toggling: root.snapshot.busyAction === "setProtection"
                                enabled: !root.snapshot.busyAction
                                         && root.snapshot.api && root.snapshot.api.state === "online"
                                         && root.snapshot.auth && root.snapshot.auth.writeState !== "denied"
                                         && root.snapshot.configState !== "pending"
                                         && root.snapshot.configState !== "unknown"
                                onToggled: function(checked) {
                                    root.sendCommand("setProtection", { enabled: checked })
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: 1
                                color: Theme.outline
                                opacity: 0.3
                            }

                            DankDropdown {
                                width: parent.width
                                text: "Profile"
                                description: "Assigned to this endpoint"
                                options: root.profileOptions()
                                currentValue: root.profileLabel(root.snapshot.profile)
                                enabled: !root.snapshot.busyAction
                                         && root.snapshot.api && root.snapshot.api.state === "online"
                                         && root.snapshot.auth && root.snapshot.auth.writeState !== "denied"
                                onValueChanged: function(value) {
                                    var profileId = root.profileIdForLabel(value)
                                    if (profileId && (!root.snapshot.profile || profileId !== root.snapshot.profile.pk))
                                        root.sendCommand("switchProfile", { profileId: profileId })
                                }
                            }

                            StyledText {
                                width: parent.width
                                visible: root.busyLabel().length > 0
                                text: root.busyLabel()
                                color: Theme.primary
                                font.weight: Font.Medium
                            }

                            StyledText {
                                width: parent.width
                                text: "Profile pause"
                                color: Theme.surfaceText
                                font.weight: Font.Medium
                                font.pixelSize: Theme.fontSizeMedium
                            }

                            StyledRect {
                                visible: root.snapshot.profile && Number(root.snapshot.profile.sharedEndpointCount) > 1
                                width: parent.width
                                height: sharedWarningRow.implicitHeight + Theme.spacingS * 2
                                radius: Theme.cornerRadius
                                color: Theme.withAlpha(Theme.warning, 0.10)
                                border.color: Theme.withAlpha(Theme.warning, 0.35)
                                border.width: 1

                                Row {
                                    id: sharedWarningRow
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingS
                                    spacing: Theme.spacingS

                                    DankIcon {
                                        name: "warning"
                                        size: 18
                                        color: Theme.warning
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    StyledText {
                                        width: parent.width - 18 - Theme.spacingS
                                        text: root.snapshot.profile
                                              ? "“" + root.snapshot.profile.name + "” is used by "
                                                + root.snapshot.profile.sharedEndpointCount
                                                + " endpoints. Pausing it affects all of them."
                                              : ""
                                        color: Theme.surfaceText
                                        wrapMode: Text.WordWrap
                                    }
                                }
                            }

                            Flow {
                                width: parent.width
                                spacing: Theme.spacingS
                                visible: root.snapshot.capabilities && root.snapshot.capabilities.pause
                                         && Number(root.snapshot.remainingPauseSeconds) <= 0

                                Repeater {
                                    model: [
                                        { label: "5 min", seconds: 300 },
                                        { label: "15 min", seconds: 900 },
                                        { label: "1 hour", seconds: 3600 },
                                        { label: "1 day", seconds: 86400 }
                                    ]

                                    DankButton {
                                        required property var modelData
                                        property var pausePreset: modelData
                                        text: pausePreset.label
                                        buttonHeight: 32
                                        horizontalPadding: Theme.spacingM
                                        backgroundColor: Theme.surfaceContainerHighest
                                        textColor: Theme.surfaceText
                                        enabled: !root.snapshot.busyAction
                                                 && root.snapshot.api && root.snapshot.api.state === "online"
                                                 && root.snapshot.auth && root.snapshot.auth.writeState !== "denied"
                                        Accessible.name: "Pause profile for " + pausePreset.label
                                        Accessible.role: Accessible.Button
                                        onClicked: root.requestPause(pausePreset.seconds)
                                    }
                                }
                            }

                            Column {
                                width: parent.width
                                spacing: Theme.spacingS
                                visible: Number(root.snapshot.remainingPauseSeconds) > 0
                                         || (root.snapshot.capabilities
                                             && root.snapshot.capabilities.pauseMode === "unconfirmed")

                                StyledText {
                                    width: parent.width
                                    text: Number(root.snapshot.remainingPauseSeconds) > 0
                                          ? (root.snapshot.capabilities.pauseMode === "unconfirmed"
                                             ? "Locally tracked pause · " : "Paused · ")
                                            + root.formatDuration(root.snapshot.remainingPauseSeconds) + " remaining"
                                          : "Control D does not report the remote pause state."
                                    color: Theme.warning
                                    wrapMode: Text.WordWrap
                                }

                                DankButton {
                                    width: parent.width
                                    text: root.snapshot.capabilities
                                          && root.snapshot.capabilities.pauseMode === "unconfirmed"
                                          ? "Reactivate profile" : "Resume profile"
                                    iconName: "play_arrow"
                                    buttonHeight: 36
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                    enabled: !root.snapshot.busyAction
                                             && root.snapshot.api && root.snapshot.api.state === "online"
                                             && root.snapshot.auth && root.snapshot.auth.writeState !== "denied"
                                    Accessible.name: text
                                    Accessible.role: Accessible.Button
                                    onClicked: root.sendCommand("resumeProfile", {})
                                }
                            }

                            StyledText {
                                width: parent.width
                                visible: root.snapshot.capabilities
                                         && root.snapshot.capabilities.pauseMode === "unconfirmed"
                                text: "Pause countdowns are local estimates and can be lost after a restart."
                                color: Theme.warning
                                font.pixelSize: Theme.fontSizeSmall
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                width: parent.width
                                visible: root.snapshot.capabilities
                                         && root.snapshot.capabilities.pauseMode === "unavailable"
                                text: "Pause state is unavailable. The advanced unconfirmed-pause option can enable writes without read-back."
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                width: parent.width
                                visible: root.commandResultMatches(["setProtection", "switchProfile", "pauseProfile", "resumeProfile"])
                                text: root.commandResult ? root.commandResult.message : ""
                                color: root.commandResult && root.commandResult.ok ? Theme.success : Theme.error
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                width: parent.width
                                visible: root.snapshot.lastError && root.snapshot.lastError.subsystem === "mutation"
                                text: root.snapshot.lastError ? root.snapshot.lastError.message : ""
                                color: Theme.error
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    StyledRect {
                        width: parent.width
                        height: dnsColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHigh

                        Column {
                            id: dnsColumn
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                DankIcon {
                                    name: root.dnsIcon()
                                    size: 22
                                    color: root.dnsColor()
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Column {
                                    width: parent.width - 22 - dnsButton.width - Theme.spacingS * 2
                                    spacing: 1
                                    anchors.verticalCenter: parent.verticalCenter

                                    StyledText {
                                        width: parent.width
                                        text: "DNS routing"
                                        color: Theme.surfaceText
                                        font.weight: Font.Medium
                                    }

                                    StyledText {
                                        width: parent.width
                                        text: root.dnsLabel()
                                        color: root.dnsColor()
                                        font.pixelSize: Theme.fontSizeSmall
                                    }
                                }

                                DankButton {
                                    id: dnsButton
                                    text: root.snapshot.dns && root.snapshot.dns.state === "checking" ? "Checking…" : "Check now"
                                    buttonHeight: 32
                                    horizontalPadding: Theme.spacingM
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                    enabled: !root.snapshot.dns || root.snapshot.dns.state !== "checking"
                                    Accessible.name: "Check DNS now"
                                    Accessible.role: Accessible.Button
                                    onClicked: root.sendCommand("runDnsProbe", {})
                                }
                            }

                            StyledText {
                                width: parent.width
                                text: root.dnsDescription()
                                color: Theme.surfaceVariantText
                                wrapMode: Text.WordWrap
                            }

                            StyledText {
                                width: parent.width
                                text: "Last checked " + root.relativeTime(root.snapshot.dns ? root.snapshot.dns.lastCheckedAt : 0)
                                color: Theme.surfaceVariantText
                                font.pixelSize: Theme.fontSizeSmall
                            }

                            StyledText {
                                width: parent.width
                                visible: root.commandResultMatches(["runDnsProbe"])
                                text: root.commandResult ? root.commandResult.message : ""
                                color: root.commandResult && root.commandResult.ok ? Theme.success : Theme.error
                                wrapMode: Text.WordWrap
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingS

                        StyledText {
                            width: parent.width - settingsButton.width - Theme.spacingS
                            text: "API " + root.apiLabel() + " · Updated " + root.relativeTime(root.snapshot.updatedAt)
                            color: Theme.surfaceVariantText
                            font.pixelSize: Theme.fontSizeSmall
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                        }

                        DankActionButton {
                            id: settingsButton
                            iconName: "settings"
                            tooltipText: "Open Control D settings"
                            Accessible.name: tooltipText
                            Accessible.role: Accessible.Button
                            onClicked: {
                                if (popout.closePopout)
                                    popout.closePopout()
                                PopoutService.openSettingsWithTab("plugins")
                            }
                        }
                    }

                    Item {
                        width: 1
                        height: Theme.spacingS
                    }
                }
            }
        }
    }
}
