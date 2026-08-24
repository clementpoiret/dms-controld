pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.Common
import qs.Modals.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "controlD"

    property int commandSequence: 0
    property string transientToken: ""
    property string credentialProvider: "secret-service"
    property string organizationDraft: ""
    property bool organizationDirty: false
    property string endpointCandidate: ""
    property string pendingAccountRefreshId: ""
    property string pendingSettingsCommandId: ""
    property string pendingResultSection: ""
    property string commandResultSection: ""
    property bool availabilityKnown: false
    property bool secretToolAvailable: false
    property string localMessage: ""
    property string localMessageSection: ""
    property bool localMessageOk: false
    property bool showLocalMessage: false
    property bool showCommandResult: false
    property double uiNow: Date.now()
    property int apiPollSeconds: 300
    property int dnsPollSeconds: 300
    property bool allowUnconfirmedPause: false

    property var snapshot: defaultSnapshot()
    property var commandResult: null

    function defaultSnapshot() {
        return {
            phase: "loading",
            auth: { provider: "secret-service", state: "loading", secretPresent: false, writeState: "unverified" },
            api: { state: "unknown", lastSuccessAt: 0 },
            dns: { state: "unknown", lastCheckedAt: 0 },
            endpoints: [],
            profiles: [],
            cache: { cachedAt: 0 }
        }
    }

    property SecretStore secretStore: SecretStore {
        onAvailabilityFinished: function(available) {
            root.availabilityKnown = true
            root.secretToolAvailable = available
            if (!available && root.credentialProvider === "secret-service")
                root.reportLocal(false, "Secret Service tooling is unavailable. Select Environment variable or install secret-tool.", "credentials")
        }
        onStoreFinished: function(success, message) {
            root.clearTransientToken()
            root.reportLocal(success, success ? "Token stored; verifying read access…" : message, "credentials")
            if (success)
                root.sendCommand("credentialsChanged", {}, "credentials")
        }
        onClearFinished: function(success, message) {
            root.clearTransientToken()
            root.reportLocal(success, success ? "Stored token forgotten" : message, "credentials")
            if (success)
                root.sendCommand("credentialsChanged", {}, "credentials")
        }
    }

    property ConfirmModal forgetConfirm: ConfirmModal {}

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.uiNow = Date.now()
    }

    Timer {
        id: localMessageTimer
        interval: 12000
        onTriggered: root.showLocalMessage = false
    }

    Timer {
        id: commandResultTimer
        interval: 12000
        onTriggered: root.showCommandResult = false
    }

    function reportLocal(ok, message, section) {
        localMessageOk = ok === true
        localMessage = message || ""
        localMessageSection = section || ""
        showLocalMessage = localMessage.length > 0
        if (showLocalMessage)
            localMessageTimer.restart()
    }

    function sendCommand(type, payload, section) {
        if (!pluginService) {
            reportLocal(false, "Plugin service is unavailable", section || "")
            return ""
        }
        commandSequence += 1
        showCommandResult = false
        commandResultSection = ""
        var now = Date.now()
        var commandId = pluginId + "-settings-" + now + "-" + commandSequence
        pendingSettingsCommandId = commandId
        pendingResultSection = section || ""
        if (type === "refreshAll" && section === "account")
            pendingAccountRefreshId = commandId
        pluginService.setGlobalVar(pluginId, "command", {
            id: commandId,
            type: type,
            payload: payload || {},
            issuedAt: now
        })
        return commandId
    }

    function syncGlobalState(varName) {
        if (!pluginService)
            return
        if (!varName || varName === "snapshot") {
            snapshot = pluginService.getGlobalVar(pluginId, "snapshot", null) || defaultSnapshot()
            syncEndpointCandidate()
        }
        if (!varName || varName === "commandResult") {
            commandResult = pluginService.getGlobalVar(pluginId, "commandResult", null)
            if (commandResult && commandResult.id === pendingSettingsCommandId) {
                commandResultSection = pendingResultSection
                showCommandResult = commandResultSection.length > 0
                if (showCommandResult)
                    commandResultTimer.restart()
                pendingSettingsCommandId = ""
                pendingResultSection = ""
            }
            if (commandResult && commandResult.id === pendingAccountRefreshId)
                pendingAccountRefreshId = ""
        }
    }

    function refreshAccountLists() {
        sendCommand("refreshAll", {}, "account")
    }

    function loadCustomSettings() {
        credentialProvider = String(loadValue("credentialProvider", "secret-service") || "secret-service")
        if (credentialProvider !== "secret-service" && credentialProvider !== "environment")
            credentialProvider = "secret-service"
        if (!organizationDirty)
            organizationDraft = String(loadValue("organizationId", "") || "")
        apiPollSeconds = Math.max(120, Math.min(1800, Number(loadValue("apiPollSeconds", 300)) || 300))
        dnsPollSeconds = Math.max(120, Math.min(1800, Number(loadValue("dnsPollSeconds", 300)) || 300))
        allowUnconfirmedPause = loadValue("allowUnconfirmedProfilePause", false) === true
        syncEndpointCandidate()
    }

    function clearTransientToken() {
        transientToken = ""
        tokenField.clear()
    }

    function providerLabel() {
        return credentialProvider === "environment" ? "Environment variable" : "Secret Service"
    }

    function authStatus() {
        if (credentialProvider === "environment" && snapshot.auth && snapshot.auth.secretPresent)
            return "Environment token in use"
        var state = snapshot.auth ? snapshot.auth.state : "notConfigured"
        switch (state) {
        case "stored": return "Stored · Write access not yet verified"
        case "verified":
            return snapshot.auth.writeState === "verified"
                ? "Read and Write access verified" : "Read access verified · Write access not yet verified"
        case "readOnly": return "Read-only"
        case "rejected": return "Authentication failed"
        case "unavailable": return "Secret Service unavailable"
        case "loading": return "Checking credentials…"
        default: return "Not configured"
        }
    }

    function shortId(value) {
        var text = String(value || "")
        return text.length > 6 ? text.slice(-6) : text
    }

    function endpointLabel(endpoint) {
        return endpoint ? endpoint.name + " · " + shortId(endpoint.pk) : ""
    }

    function endpointOptions() {
        return (snapshot.endpoints || []).map(function(endpoint) { return root.endpointLabel(endpoint) })
    }

    function endpointForLabel(label) {
        return (snapshot.endpoints || []).find(function(endpoint) {
            return root.endpointLabel(endpoint) === label
        }) || null
    }

    function syncEndpointCandidate() {
        var options = endpointOptions()
        var confirmed = snapshot.endpoint ? endpointLabel(snapshot.endpoint) : ""
        if (confirmed && options.indexOf(confirmed) !== -1) {
            endpointCandidate = confirmed
            return
        }
        if (options.indexOf(endpointCandidate) === -1)
            endpointCandidate = options.length === 1 ? options[0] : ""
    }

    function saveProvider(label) {
        var provider = label === "Environment variable" ? "environment" : "secret-service"
        if (provider === "secret-service" && availabilityKnown && !secretToolAvailable)
            return
        credentialProvider = provider
        saveValue("credentialProvider", provider)
        clearTransientToken()
        reportLocal(true, "Credential provider changed; checking configuration…", "credentials")
        Qt.callLater(function() { root.sendCommand("credentialsChanged", {}, "credentials") })
    }

    function saveToken() {
        var submitted = transientToken
        clearTransientToken()
        if (!submitted) {
            reportLocal(false, "Enter a Control D token first", "credentials")
            return
        }
        if (!secretToolAvailable || !secretStore.store(submitted)) {
            submitted = ""
            reportLocal(false, "Secret Service is unavailable or busy", "credentials")
            return
        }
        submitted = ""
        reportLocal(true, "Saving token to Secret Service…", "credentials")
    }

    function applyOrganization() {
        var organizationId = organizationDraft.trim()
        organizationDirty = false
        saveValue("organizationId", organizationId)
        saveValue("endpointId", "")
        endpointCandidate = ""
        reportLocal(true, "Organization changed; endpoint association and cached account data were cleared.", "account")
        Qt.callLater(function() { root.sendCommand("credentialsChanged", {}, "account") })
    }

    function useEndpoint() {
        var endpoint = endpointForLabel(endpointCandidate)
        if (!endpoint)
            return
        sendCommand("setEndpoint", { endpointId: endpoint.pk }, "account")
    }

    function relativeTime(timestamp) {
        var elapsed = Math.max(0, uiNow - (Number(timestamp) || 0))
        if (!timestamp) return "never"
        if (elapsed < 60000) return "just now"
        if (elapsed < 3600000) return Math.floor(elapsed / 60000) + "m ago"
        if (elapsed < 86400000) return Math.floor(elapsed / 3600000) + "h ago"
        return Math.floor(elapsed / 86400000) + "d ago"
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

    function connectionLabel() {
        var auth = snapshot.auth || {}
        if (auth.state === "rejected" || auth.state === "unavailable")
            return "Connection needs attention"
        if (!auth.secretPresent)
            return "Setup required"
        if (!snapshot.endpoint)
            return "Select an endpoint"
        if (snapshot.api && snapshot.api.state === "offline")
            return snapshot.stale ? "Connected state is stale" : "Control D is offline"
        if (snapshot.stale)
            return "Connected state is stale"
        if (auth.writeState === "denied")
            return "Connected with read-only access"
        if (auth.writeState !== "verified")
            return "Connected · Write access unverified"
        return "Connected"
    }

    function connectionDescription() {
        var parts = [providerLabel()]
        if (snapshot.endpoint)
            parts.push(snapshot.endpoint.name)
        if (snapshot.profile)
            parts.push(snapshot.profile.name)
        else if (snapshot.auth && snapshot.auth.secretPresent)
            parts.push("Endpoint not selected")
        return parts.join(" · ")
    }

    function connectionColor() {
        var auth = snapshot.auth || {}
        if (auth.state === "rejected" || auth.state === "unavailable")
            return Theme.error
        if (!auth.secretPresent || !snapshot.endpoint)
            return Theme.primary
        if (snapshot.stale || (snapshot.api && snapshot.api.state === "offline")
                || auth.writeState !== "verified")
            return Theme.warning
        return Theme.success
    }

    function connectionIcon() {
        var auth = snapshot.auth || {}
        if (auth.state === "rejected") return "key_off"
        if (auth.state === "unavailable") return "error"
        if (!auth.secretPresent || !snapshot.endpoint) return "settings"
        if (snapshot.stale || (snapshot.api && snapshot.api.state === "offline")) return "cloud_off"
        if (auth.writeState === "denied") return "lock"
        if (auth.writeState !== "verified") return "key"
        return "verified_user"
    }

    function authStatusColor() {
        var auth = snapshot.auth || {}
        if (auth.state === "rejected" || auth.state === "unavailable" || auth.state === "readOnly")
            return auth.state === "readOnly" ? Theme.warning : Theme.error
        if (auth.state === "verified")
            return auth.writeState === "verified" ? Theme.success : Theme.primary
        return Theme.surfaceText
    }

    function authHelpText() {
        var auth = snapshot.auth || {}
        if (auth.state === "readOnly" || auth.writeState === "denied")
            return "This token can read account state but cannot change protection, profiles, or pauses."
        if (auth.state === "verified" && auth.writeState === "verified")
            return "Read and write access is ready for widget controls."
        if (auth.state === "verified")
            return "Read access is ready. Write access will be confirmed by the first protection, profile, or pause change; no test write is performed."
        return "Use a dedicated Control D Write token to enable protection, profile, and pause controls."
    }

    function pollIntervalOptions() {
        return ["2 minutes", "5 minutes", "10 minutes", "15 minutes", "30 minutes"]
    }

    function intervalLabel(seconds) {
        var value = Math.max(120, Math.min(1800, Number(seconds) || 300))
        var known = ({ 120: "2 minutes", 300: "5 minutes", 600: "10 minutes", 900: "15 minutes", 1800: "30 minutes" })
        if (known[value])
            return known[value]
        if (value % 60 === 0)
            return (value / 60) + " minutes"
        return value + " seconds"
    }

    function intervalSeconds(label) {
        switch (label) {
        case "2 minutes": return 120
        case "5 minutes": return 300
        case "10 minutes": return 600
        case "15 minutes": return 900
        case "30 minutes": return 1800
        default: return 300
        }
    }

    function savePollInterval(key, label) {
        var seconds = intervalSeconds(label)
        if (key === "apiPollSeconds")
            apiPollSeconds = seconds
        else
            dnsPollSeconds = seconds
        saveValue(key, seconds)
    }

    function commandResultMatches(section, types) {
        return showCommandResult && commandResultSection === section && commandResult
                && types.indexOf(commandResult.type) !== -1
    }

    function diagnosticRows() {
        return [
            { label: "API", value: (snapshot.api ? snapshot.api.state : "unknown")
              + " · " + relativeTime(snapshot.api ? snapshot.api.lastSuccessAt : 0) },
            { label: "DNS", value: (snapshot.dns ? snapshot.dns.state : "unknown")
              + " · " + relativeTime(snapshot.dns ? snapshot.dns.lastCheckedAt : 0) },
            { label: "Endpoint", value: snapshot.endpoint ? snapshot.endpoint.pk : "Not selected" },
            { label: "Profile", value: snapshot.profile ? snapshot.profile.pk : "Not selected" },
            { label: "Cache", value: (snapshot.stale ? "Stale" : "Current")
              + " · " + relativeTime(snapshot.cache ? snapshot.cache.cachedAt : 0) },
            { label: "Credentials", value: providerLabel() }
        ]
    }

    function diagnosticSummary() {
        var error = snapshot.lastError || null
        return [
            "Control D diagnostics",
            "API: " + (snapshot.api ? snapshot.api.state : "unknown")
                + ", last success " + relativeTime(snapshot.api ? snapshot.api.lastSuccessAt : 0),
            "DNS: " + (snapshot.dns ? snapshot.dns.state : "unknown")
                + ", last check " + relativeTime(snapshot.dns ? snapshot.dns.lastCheckedAt : 0),
            "Endpoint ID: " + (snapshot.endpoint ? snapshot.endpoint.pk : "none"),
            "Profile ID: " + (snapshot.profile ? snapshot.profile.pk : "none"),
            "Cache: " + (snapshot.stale ? "stale" : "current")
                + ", saved " + relativeTime(snapshot.cache ? snapshot.cache.cachedAt : 0),
            "Credential provider: " + credentialProvider,
            "Last error: " + (error ? error.kind + " — " + error.message : "none")
        ].join("\n")
    }

    Component.onCompleted: {
        Qt.callLater(function() {
            root.loadCustomSettings()
            root.syncGlobalState("")
            root.secretStore.checkAvailability()
        })
    }

    Component.onDestruction: clearTransientToken()

    Connections {
        target: root.pluginService
        enabled: root.pluginService !== null
        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId)
                root.loadCustomSettings()
        }
        function onGlobalVarChanged(changedPluginId, varName) {
            if (changedPluginId === root.pluginId)
                root.syncGlobalState(varName)
        }
    }

    StyledRect {
        width: parent.width
        height: connectionSummaryRow.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.withAlpha(root.connectionColor(), 0.10)
        border.color: Theme.withAlpha(root.connectionColor(), 0.35)
        border.width: 1

        Row {
            id: connectionSummaryRow
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingM

            DankIcon {
                name: root.connectionIcon()
                size: 32
                color: root.connectionColor()
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                width: parent.width - 32 - Theme.spacingM
                spacing: Theme.spacingXS

                StyledText {
                    width: parent.width
                    text: root.connectionLabel()
                    color: Theme.surfaceText
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent.width
                    text: root.connectionDescription()
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
            }
        }
    }

    StyledText {
        width: parent.width
        text: "Credentials"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
    }

    DankDropdown {
        width: parent.width
        text: "Credential provider"
        description: root.availabilityKnown && !root.secretToolAvailable
                     ? "Secret Service is unavailable; the environment provider remains usable."
                     : "Tokens are never saved in DMS settings."
        options: root.availabilityKnown && !root.secretToolAvailable
                 ? ["Environment variable"] : ["Secret Service", "Environment variable"]
        currentValue: root.providerLabel()
        enabled: !root.snapshot.busyAction
        onValueChanged: function(value) { root.saveProvider(value) }
    }

    StyledText {
        width: parent.width
        text: root.authStatus()
        color: root.authStatusColor()
        font.weight: Font.Medium
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        text: root.authHelpText()
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    DankTextField {
        id: tokenField
        visible: root.credentialProvider === "secret-service"
        width: parent.width
        labelText: "Control D API token"
        placeholderText: root.snapshot.auth && root.snapshot.auth.secretPresent
                         ? "Paste a replacement token" : "Paste token"
        echoMode: TextInput.Password
        showPasswordToggle: true
        maximumLength: 512
        onTextEdited: root.transientToken = text
        onAccepted: root.saveToken()
    }

    Flow {
        visible: root.credentialProvider === "secret-service"
        width: parent.width
        spacing: Theme.spacingS

        DankButton {
            text: root.snapshot.auth && root.snapshot.auth.secretPresent ? "Replace and test" : "Save and test"
            iconName: "key"
            enabled: root.secretToolAvailable && root.transientToken.length > 0 && !root.secretStore.busy
            Accessible.name: text
            Accessible.role: Accessible.Button
            onClicked: root.saveToken()
        }

        DankButton {
            text: "Forget token"
            iconName: "delete"
            enabled: root.secretToolAvailable && root.snapshot.auth
                     && root.snapshot.auth.secretPresent && !root.secretStore.busy
            backgroundColor: Theme.errorContainer
            textColor: Theme.error
            Accessible.name: text
            Accessible.role: Accessible.Button
            onClicked: root.forgetConfirm.showWithOptions({
                title: "Forget Control D token?",
                message: "This removes the token from Secret Service and disables authenticated controls until another credential is configured.",
                confirmText: "Forget token",
                confirmColor: Theme.error,
                onConfirm: function() {
                    if (!root.secretStore.clear())
                        root.reportLocal(false, "Secret Service is busy", "credentials")
                }
            })
        }
    }

    DankButton {
        visible: root.credentialProvider === "environment"
        width: parent.width
        text: "Test environment token"
        iconName: "key"
        Accessible.name: text
        Accessible.role: Accessible.Button
        onClicked: root.sendCommand("testCredentials", {}, "credentials")
    }

    StyledText {
        width: parent.width
        visible: root.showLocalMessage && root.localMessageSection === "credentials"
        text: root.localMessage
        color: root.localMessageOk ? Theme.success : Theme.error
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        visible: root.commandResultMatches("credentials", ["credentialsChanged", "testCredentials"])
        text: root.commandResult ? root.commandResult.message : ""
        color: root.commandResult && root.commandResult.ok ? Theme.success : Theme.error
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Account and endpoint"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
    }

    StyledText {
        width: parent.width
        text: "Choose the Control D endpoint that represents this machine."
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    DankTextField {
        id: organizationField
        width: parent.width
        labelText: "Organization ID"
        placeholderText: "Optional for personal accounts"
        maximumLength: 160
        text: root.organizationDraft
        onTextEdited: {
            root.organizationDraft = text
            root.organizationDirty = true
        }
    }

    StyledText {
        width: parent.width
        text: "Changing organization clears the selected endpoint and cached account state."
        color: root.organizationDraft.trim() !== String(root.loadValue("organizationId", "") || "").trim()
               ? Theme.warning : Theme.surfaceVariantText
        font.pixelSize: Theme.fontSizeSmall
        wrapMode: Text.WordWrap
    }

    Flow {
        width: parent.width
        spacing: Theme.spacingS

        DankButton {
            text: "Apply organization"
            enabled: root.organizationDraft.trim() !== String(root.loadValue("organizationId", "") || "").trim()
                     && !root.snapshot.busyAction
            Accessible.name: text
            Accessible.role: Accessible.Button
            onClicked: root.applyOrganization()
        }

        DankButton {
            text: root.pendingAccountRefreshId ? "Refreshing account…" : "Refresh account"
            iconName: "refresh"
            backgroundColor: Theme.surfaceContainerHighest
            textColor: Theme.surfaceText
            enabled: !root.pendingAccountRefreshId
            Accessible.name: text
            Accessible.role: Accessible.Button
            onClicked: root.refreshAccountLists()
        }
    }

    StyledText {
        width: parent.width
        visible: root.pendingAccountRefreshId.length > 0
                 || root.commandResultMatches("account", ["refreshAll", "setEndpoint", "credentialsChanged"])
        text: root.pendingAccountRefreshId ? "Contacting Control D…"
                                           : (root.commandResult ? root.commandResult.message : "")
        color: root.pendingAccountRefreshId ? Theme.primary
                                            : (root.commandResult && root.commandResult.ok
                                               ? Theme.success : Theme.error)
        wrapMode: Text.WordWrap
    }

    StyledText {
        width: parent.width
        visible: root.showLocalMessage && root.localMessageSection === "account"
        text: root.localMessage
        color: root.localMessageOk ? Theme.success : Theme.error
        wrapMode: Text.WordWrap
    }

    DankDropdown {
        width: parent.width
        text: "Endpoint"
        description: "Select the endpoint assigned to this machine."
        options: root.endpointOptions()
        currentValue: root.endpointCandidate
        emptyText: "No endpoints loaded"
        onValueChanged: function(value) { root.endpointCandidate = value }
    }

    StyledText {
        width: parent.width
        visible: !root.snapshot.endpoint && root.endpointOptions().length === 1
        text: "One endpoint was found and preselected. Confirm it below to finish setup."
        color: Theme.primary
        wrapMode: Text.WordWrap
    }

    DankButton {
        width: parent.width
        text: "Use this endpoint"
        iconName: "devices"
        enabled: root.endpointForLabel(root.endpointCandidate) !== null
                 && (!root.snapshot.endpoint
                     || root.endpointForLabel(root.endpointCandidate).pk !== root.snapshot.endpoint.pk)
                 && !root.snapshot.busyAction
        Accessible.name: text
        Accessible.role: Accessible.Button
        onClicked: root.useEndpoint()
    }

    StyledRect {
        width: parent.width
        height: selectedEndpointColumn.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: selectedEndpointColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingXS

            StyledText {
                width: parent.width
                text: root.snapshot.endpoint ? root.snapshot.endpoint.name : "No endpoint selected"
                color: Theme.surfaceText
                font.weight: Font.Medium
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                text: root.snapshot.endpoint
                      ? "Resolver " + root.snapshot.endpoint.resolverId
                        + " · " + root.configLabel(root.snapshot.configState)
                        + " · " + (root.snapshot.profile ? root.snapshot.profile.name : "Profile unavailable")
                      : "Refresh the account, choose an endpoint, then confirm the association."
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Widget behavior"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
    }

    SelectionSetting {
        settingKey: "barLabelMode"
        label: "Bar label"
        description: "Show the profile name, a compact CD label, or only the status icon."
        options: [
            { label: "Profile", value: "profile" },
            { label: "Compact", value: "compact" },
            { label: "Icon only", value: "icon-only" }
        ]
        defaultValue: "profile"
    }

    DankDropdown {
        width: parent.width
        text: "Account refresh"
        description: "How often to read endpoint and profile state."
        options: root.pollIntervalOptions()
        currentValue: root.intervalLabel(root.apiPollSeconds)
        onValueChanged: function(value) { root.savePollInterval("apiPollSeconds", value) }
    }

    DankDropdown {
        width: parent.width
        text: "DNS check"
        description: "How often to verify local Control D DNS routing."
        options: root.pollIntervalOptions()
        currentValue: root.intervalLabel(root.dnsPollSeconds)
        onValueChanged: function(value) { root.savePollInterval("dnsPollSeconds", value) }
    }

    ToggleSetting {
        settingKey: "showNotifications"
        label: "Show notifications"
        description: "Notify when a user-initiated Control D action succeeds or fails."
        defaultValue: true
    }

    ToggleSetting {
        settingKey: "confirmSharedPause"
        label: "Confirm shared-profile pauses"
        description: "Ask before pausing a profile used by multiple endpoints. Impact is always shown in the widget."
        defaultValue: true
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Advanced"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
    }

    StyledRect {
        width: parent.width
        height: advancedColumn.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.warning, 0.10)
        border.color: Theme.withAlpha(Theme.warning, 0.35)
        border.width: 1

        Column {
            id: advancedColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankIcon {
                    name: "warning"
                    size: 20
                    color: Theme.warning
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    width: parent.width - 20 - Theme.spacingS
                    text: "Unconfirmed profile pauses"
                    color: Theme.surfaceText
                    font.weight: Font.Medium
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            StyledText {
                width: parent.width
                text: "Allow pause writes when Control D accepts disable_ttl but does not return pause state. Countdowns become local estimates and can be lost after restart."
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            DankToggle {
                width: parent.width
                text: "Allow unconfirmed pauses"
                description: root.allowUnconfirmedPause ? "Enabled · remote state cannot be read back" : "Off by default"
                descriptionColor: root.allowUnconfirmedPause ? Theme.warning : Theme.surfaceVariantText
                checked: root.allowUnconfirmedPause
                onToggled: function(checked) {
                    root.allowUnconfirmedPause = checked
                    root.saveValue("allowUnconfirmedProfilePause", checked)
                }
            }
        }
    }

    Rectangle {
        width: parent.width
        height: 1
        color: Theme.outline
        opacity: 0.3
    }

    StyledText {
        width: parent.width
        text: "Diagnostics"
        color: Theme.surfaceText
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
    }

    StyledRect {
        width: parent.width
        height: diagnosticsColumn.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: diagnosticsColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingM
            spacing: Theme.spacingS

            Repeater {
                model: root.diagnosticRows()

                Row {
                    required property var modelData
                    width: parent.width
                    spacing: Theme.spacingS

                    StyledText {
                        width: 84
                        text: parent.modelData.label
                        color: Theme.surfaceVariantText
                        font.pixelSize: Theme.fontSizeSmall
                    }

                    StyledText {
                        width: parent.width - 84 - Theme.spacingS
                        text: parent.modelData.value
                        color: Theme.surfaceText
                        font.pixelSize: Theme.fontSizeSmall
                        horizontalAlignment: Text.AlignRight
                        wrapMode: Text.WrapAnywhere
                    }
                }
            }

            StyledText {
                width: parent.width
                visible: root.snapshot.lastError !== null && root.snapshot.lastError !== undefined
                text: root.snapshot.lastError
                      ? "Last error: " + root.snapshot.lastError.kind + " — " + root.snapshot.lastError.message : ""
                color: Theme.error
                wrapMode: Text.WordWrap
            }

            Flow {
                width: parent.width
                spacing: Theme.spacingS

                Repeater {
                    model: [
                        { text: "Refresh all", icon: "refresh", command: "refreshAll" },
                        { text: "Check DNS", icon: "dns", command: "runDnsProbe" },
                        { text: "Clear cache", icon: "delete_sweep", command: "clearCache" }
                    ]

                    DankButton {
                        required property var modelData
                        text: modelData.text
                        iconName: modelData.icon
                        backgroundColor: Theme.surfaceContainerHighest
                        textColor: Theme.surfaceText
                        Accessible.name: text
                        Accessible.role: Accessible.Button
                        onClicked: root.sendCommand(modelData.command, {}, "diagnostics")
                    }
                }

                DankButton {
                    text: "Copy summary"
                    iconName: "content_copy"
                    backgroundColor: Theme.surfaceContainerHighest
                    textColor: Theme.surfaceText
                    Accessible.name: "Copy diagnostic summary"
                    Accessible.role: Accessible.Button
                    onClicked: Quickshell.execDetached(["dms", "cl", "copy", root.diagnosticSummary()])
                }
            }

            StyledText {
                width: parent.width
                visible: root.commandResultMatches("diagnostics", ["refreshAll", "runDnsProbe", "clearCache"])
                text: root.commandResult ? root.commandResult.message : ""
                color: root.commandResult && root.commandResult.ok ? Theme.success : Theme.error
                wrapMode: Text.WordWrap
            }
        }
    }
}
