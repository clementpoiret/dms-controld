import QtQuick
import Quickshell
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "ControlDApi.js" as Api
import "ControlDModels.js" as Models

PluginComponent {
    id: root

    property bool initialized: false
    property bool shuttingDown: false
    property bool acceptCommands: false
    property string apiToken: ""
    property string pendingCredentialCommandId: ""
    property string pendingCredentialCommandType: "credentialsChanged"
    property bool hasResolvedOrganization: false
    property string resolvedOrganizationId: ""

    property int readGeneration: 0
    property var readPending: null
    property var readHandles: []
    property string pendingAccountCommandId: ""
    property string pendingAccountCommandType: "refreshAll"
    property int retryReadAttempt: 0
    property string retryReadCommandId: ""
    property string retryReadCommandType: "refreshAll"

    property var accountDevices: []
    property var accountProfiles: []
    property var recentCommandIds: []
    property var activeMutation: null
    property var mutationHandle: null
    property string pendingDnsCommandId: ""
    property var unconfirmedProfilePauses: ({})

    property var snapshot: emptySnapshot()

    PluginGlobalVar {
        id: commandVar
        varName: "command"
        defaultValue: null
        onValueChanged: {
            if (root.acceptCommands)
                root.handleCommand(value)
        }
    }

    function emptySnapshot() {
        return {
            schemaVersion: 2,
            revision: 0,
            phase: "loading",
            configured: false,
            stale: false,
            hasConfirmedData: false,
            auth: {
                provider: "secret-service",
                secretPresent: false,
                readVerified: false,
                writeState: "unverified",
                state: "notConfigured"
            },
            api: { state: "unknown", lastSuccessAt: 0, lastAttemptAt: 0 },
            endpoint: null,
            endpoints: [],
            profile: null,
            profiles: [],
            dns: { state: "unknown", lastCheckedAt: 0, detail: "Not checked" },
            capabilities: { pause: false, pauseMode: "unavailable" },
            configState: "unknown",
            pauseSource: "none",
            overallState: "loading",
            remainingPauseSeconds: 0,
            busyAction: "",
            lastError: null,
            cache: { cachedAt: 0 },
            updatedAt: Date.now()
        }
    }

    function setting(key, fallback) {
        if (pluginData && pluginData[key] !== undefined)
            return pluginData[key]
        return fallback
    }

    function boundedInterval(key, fallback) {
        return Math.max(120, Math.min(1800, Number(setting(key, fallback)) || fallback)) * 1000
    }

    function pauseCapabilities(profile) {
        var mode = Models.profilePauseMode(profile, setting("allowUnconfirmedProfilePause", false))
        return { pause: mode !== "unavailable", pauseMode: mode }
    }

    function setLocalPauseExpiry(profileId, disableTtl) {
        if (!profileId)
            return
        var next = Object.assign({}, unconfirmedProfilePauses)
        if (Number(disableTtl) > Date.now() / 1000)
            next[profileId] = Number(disableTtl)
        else
            delete next[profileId]
        unconfirmedProfilePauses = next
    }

    function localPauseExpiry(profileId, nowMs) {
        if (!profileId || unconfirmedProfilePauses[profileId] === undefined)
            return null
        var expiry = Number(unconfirmedProfilePauses[profileId])
        if (Number.isFinite(expiry) && expiry > Number(nowMs) / 1000)
            return expiry
        setLocalPauseExpiry(profileId, 0)
        return null
    }

    function clearReadablePauseEstimates(profiles) {
        var next = Object.assign({}, unconfirmedProfilePauses)
        var changed = false
        var items = profiles || []
        items.forEach(function(profile) {
            if (profile.pauseReadable === true && next[profile.pk] !== undefined) {
                delete next[profile.pk]
                changed = true
            }
        })
        if (changed)
            unconfirmedProfilePauses = next
    }

    function publish(persistCache) {
        var now = Date.now()
        var capabilities = pauseCapabilities(snapshot.profile)
        var localExpiry = capabilities.pauseMode === "unconfirmed" && snapshot.profile
            ? localPauseExpiry(snapshot.profile.pk, now) : null
        var derived = Models.deriveSnapshot(Object.assign({}, snapshot, {
            capabilities: capabilities
        }), now, localExpiry)
        snapshot = Object.assign({}, derived, {
            revision: (snapshot.revision || 0) + 1,
            updatedAt: now
        })
        if (pluginService)
            pluginService.setGlobalVar(pluginId, "snapshot", snapshot)
        if (persistCache && snapshot.hasConfirmedData)
            cacheWriteTimer.restart()
    }

    function sanitizedError(error, subsystem) {
        if (!error)
            return null
        var message = Models.sanitizeText(error.message || "Operation failed", 240)
        if (apiToken && message.indexOf(apiToken) !== -1)
            message = message.split(apiToken).join("[redacted]")
        return {
            subsystem: subsystem || "unknown",
            kind: error.kind || "unknown",
            httpStatus: Number(error.httpStatus) || 0,
            apiCode: error.apiCode === undefined ? null : error.apiCode,
            message: message,
            retryable: error.retryable === true,
            at: error.at || Date.now()
        }
    }

    function finishCommand(id, type, ok, message, error, notifyUser) {
        if (!id || !pluginService)
            return
        var safeMessage = Models.sanitizeText(message || (ok ? "Completed" : "Operation failed"), 240)
        if (apiToken && safeMessage.indexOf(apiToken) !== -1)
            safeMessage = safeMessage.split(apiToken).join("[redacted]")
        pluginService.setGlobalVar(pluginId, "commandResult", {
            id: id,
            type: type || "",
            ok: ok === true,
            message: safeMessage,
            error: error ? sanitizedError(error, error.subsystem || "command") : null,
            completedAt: Date.now()
        })
        if (notifyUser && setting("showNotifications", true)) {
            if (ok)
                ToastService.showInfo("Control D", safeMessage)
            else
                ToastService.showError("Control D", safeMessage)
        }
    }

    function loadCache() {
        if (!pluginService)
            return
        var cached = pluginService.loadPluginState(pluginId, "snapshotCache", null)
        var currentOrganization = String(setting("organizationId", "") || "").trim()
        resolvedOrganizationId = currentOrganization
        hasResolvedOrganization = true
        if (cached && String(cached.organizationId || "") !== currentOrganization)
            return
        var restored = Models.restoreSanitizedCache(cached)
        if (!restored)
            return
        snapshot = Object.assign({}, emptySnapshot(), restored, {
            phase: "ready",
            stale: true,
            configured: true,
            hasConfirmedData: true,
            auth: emptySnapshot().auth,
            endpoints: [],
            busyAction: "",
            cache: { cachedAt: Number(restored.cachedAt) || 0 }
        })
        publish(false)
    }

    function initialize(commandId) {
        if (!initialized) {
            initialized = true
            loadCache()
            runDnsProbe("")
            resolveCredentials(commandId || "", commandId ? "initialize" : "credentialsChanged")
            return
        }
        refreshAll(commandId || "")
    }

    function resolveCredentials(commandId, commandType) {
        pendingCredentialCommandId = commandId || ""
        pendingCredentialCommandType = commandType || "credentialsChanged"
        var nextOrganization = String(setting("organizationId", "") || "").trim()
        if (hasResolvedOrganization && nextOrganization !== resolvedOrganizationId) {
            if (pluginService)
                pluginService.clearPluginState(pluginId)
            unconfirmedProfilePauses = ({})
            snapshot = emptySnapshot()
        }
        resolvedOrganizationId = nextOrganization
        hasResolvedOrganization = true
        apiToken = ""
        abortAccountReads()
        readRetryTimer.stop()

        var provider = setting("credentialProvider", "secret-service")
        snapshot = Object.assign({}, snapshot, {
            phase: snapshot.hasConfirmedData ? "ready" : "loading",
            stale: snapshot.hasConfirmedData,
            auth: {
                provider: provider,
                secretPresent: false,
                readVerified: false,
                writeState: "unverified",
                state: "loading"
            },
            lastError: null
        })
        publish(false)

        if (provider === "environment") {
            var environmentToken = Quickshell.env("CONTROL_D_API_TOKEN") || ""
            if (!environmentToken) {
                snapshot = Object.assign({}, snapshot, {
                    phase: "setupRequired",
                    auth: {
                        provider: provider,
                        secretPresent: false,
                        readVerified: false,
                        writeState: "unverified",
                        state: "notConfigured"
                    },
                    lastError: {
                        subsystem: "credentials",
                        kind: "auth",
                        message: "CONTROL_D_API_TOKEN is not set",
                        at: Date.now()
                    }
                })
                publish(false)
                finishCommand(commandId, pendingCredentialCommandType, false, "Environment token is not configured",
                              snapshot.lastError, true)
                pendingCredentialCommandId = ""
                return
            }
            apiToken = environmentToken
            environmentToken = ""
            snapshot = Object.assign({}, snapshot, {
                auth: {
                    provider: provider,
                    secretPresent: true,
                    readVerified: false,
                    writeState: "unverified",
                    state: "stored"
                }
            })
            refreshAccount(commandId || "", 0, pendingCredentialCommandType)
            pendingCredentialCommandId = ""
            return
        }

        if (!secretStore.checkAvailability()) {
            var busyError = {
                subsystem: "credentials",
                kind: "unknown",
                message: "Credential helper is busy",
                at: Date.now()
            }
            snapshot = Object.assign({}, snapshot, { lastError: busyError })
            publish(false)
            finishCommand(commandId, pendingCredentialCommandType, false, busyError.message, busyError, true)
            pendingCredentialCommandId = ""
        }
    }

    function handleSecretAvailability(available) {
        if (shuttingDown)
            return
        if (setting("credentialProvider", "secret-service") !== "secret-service")
            return
        if (!available) {
            snapshot = Object.assign({}, snapshot, {
                phase: "setupRequired",
                auth: {
                    provider: "secret-service",
                    secretPresent: false,
                    readVerified: false,
                    writeState: "unverified",
                    state: "unavailable"
                },
                lastError: {
                    subsystem: "credentials",
                    kind: "tool",
                    message: "Secret Service tooling is unavailable",
                    at: Date.now()
                }
            })
            publish(false)
            finishCommand(pendingCredentialCommandId, pendingCredentialCommandType, false,
                          "Secret Service tooling is unavailable", snapshot.lastError, true)
            pendingCredentialCommandId = ""
            return
        }
        if (!secretStore.lookup()) {
            var lookupStartError = {
                subsystem: "credentials",
                kind: "tool",
                message: "Credential lookup could not start",
                at: Date.now()
            }
            snapshot = Object.assign({}, snapshot, {
                phase: "setupRequired",
                auth: {
                    provider: "secret-service",
                    secretPresent: false,
                    readVerified: false,
                    writeState: "unverified",
                    state: "unavailable"
                },
                lastError: lookupStartError
            })
            publish(false)
            finishCommand(pendingCredentialCommandId, pendingCredentialCommandType, false,
                          lookupStartError.message, lookupStartError, true)
            pendingCredentialCommandId = ""
        }
    }

    function handleSecretLookup(success, secret, message) {
        if (shuttingDown)
            return
        if (setting("credentialProvider", "secret-service") !== "secret-service") {
            secret = ""
            return
        }
        if (!success || !secret) {
            apiToken = ""
            snapshot = Object.assign({}, snapshot, {
                phase: "setupRequired",
                auth: {
                    provider: "secret-service",
                    secretPresent: false,
                    readVerified: false,
                    writeState: "unverified",
                    state: "notConfigured"
                },
                lastError: null
            })
            publish(false)
            finishCommand(pendingCredentialCommandId, pendingCredentialCommandType, false,
                          message || "No stored Control D token was found", {
                              subsystem: "credentials",
                              kind: "auth",
                              message: message || "No stored Control D token was found",
                              at: Date.now()
                          }, false)
            pendingCredentialCommandId = ""
            return
        }
        apiToken = secret
        secret = ""
        snapshot = Object.assign({}, snapshot, {
            auth: {
                provider: "secret-service",
                secretPresent: true,
                readVerified: false,
                writeState: "unverified",
                state: "stored"
            }
        })
        var commandId = pendingCredentialCommandId
        var commandType = pendingCredentialCommandType
        pendingCredentialCommandId = ""
        refreshAccount(commandId, 0, commandType)
    }

    function requestContext() {
        var timeout = requestTimeoutComponent.createObject(root, {
            interval: 10000,
            repeat: false
        })
        return {
            token: apiToken,
            organizationId: String(setting("organizationId", "") || "").trim(),
            startTimeout: function(callback) {
                timeout.triggered.connect(callback)
                timeout.start()
            },
            cancelTimeout: function() {
                if (!timeout)
                    return
                timeout.stop()
                timeout.destroy()
                timeout = null
            }
        }
    }

    function abortAccountReads() {
        readHandles.forEach(function(handle) {
            if (handle && handle.abort)
                handle.abort()
        })
        readHandles = []
        readPending = null
    }

    function refreshAll(commandId) {
        if (!apiToken) {
            finishCommand(commandId, "refreshAll", false, "Configure a Control D token first", {
                              subsystem: "credentials", kind: "auth",
                              message: "Configure a Control D token first", at: Date.now()
                          }, true)
            return
        }
        refreshAccount(commandId || "", 0, "refreshAll")
        runDnsProbe("")
    }

    function refreshAccount(commandId, attempt, commandType) {
        if (!apiToken)
            return
        abortAccountReads()
        readRetryTimer.stop()
        readGeneration += 1
        var generation = readGeneration
        pendingAccountCommandId = commandId || ""
        pendingAccountCommandType = commandType || "refreshAll"
        readPending = {
            generation: generation,
            attempt: attempt || 0,
            devicesDone: false,
            profilesDone: false,
            devices: null,
            profiles: null
        }
        snapshot = Object.assign({}, snapshot, {
            phase: snapshot.hasConfirmedData ? "ready" : "loading",
            api: Object.assign({}, snapshot.api, {
                state: snapshot.hasConfirmedData ? snapshot.api.state : "loading",
                lastAttemptAt: Date.now()
            })
        })
        publish(false)

        var devicesHandle = Api.request("GET", "/devices", null, requestContext(), function(result) {
            root.accountReadPart(generation, "devices", result)
        })
        var profilesHandle = Api.request("GET", "/profiles", null, requestContext(), function(result) {
            root.accountReadPart(generation, "profiles", result)
        })
        readHandles = [devicesHandle, profilesHandle]
    }

    function accountReadPart(generation, part, result) {
        if (shuttingDown || generation !== readGeneration || !readPending)
            return
        readPending[part] = result
        readPending[part + "Done"] = true
        if (readPending.devicesDone && readPending.profilesDone)
            completeAccountRead()
    }

    function firstReadError() {
        if (readPending.devices && !readPending.devices.ok)
            return readPending.devices.error
        if (readPending.profiles && !readPending.profiles.ok)
            return readPending.profiles.error
        return null
    }

    function completeAccountRead() {
        var pending = readPending
        readHandles = []
        if (!pending)
            return
        var transportError = firstReadError()
        if (transportError) {
            if (transportError.retryable && pending.attempt < 3) {
                retryReadAttempt = pending.attempt + 1
                retryReadCommandId = pendingAccountCommandId
                retryReadCommandType = pendingAccountCommandType
                readPending = null
                readRetryTimer.interval = retryDelay(retryReadAttempt)
                readRetryTimer.restart()
                return
            }
            readPending = null
            handleAccountFailure(transportError)
            return
        }

        var devicesResult = Models.normalizeDevices(pending.devices.value)
        var profilesResult = Models.normalizeProfiles(pending.profiles.value)
        if (!devicesResult.ok || !profilesResult.ok) {
            readPending = null
            handleAccountFailure(!devicesResult.ok ? devicesResult.error : profilesResult.error)
            return
        }

        accountDevices = devicesResult.value
        accountProfiles = profilesResult.value
        clearReadablePauseEstimates(accountProfiles)
        var storedEndpointId = String(setting("endpointId", "") || "")
        var endpoint = accountDevices.find(function(item) { return item.pk === storedEndpointId }) || null
        var selectionError = null
        if (storedEndpointId && !endpoint) {
            if (pluginService) {
                pluginService.savePluginData(pluginId, "endpointId", "")
                pluginService.clearPluginState(pluginId)
            }
            selectionError = {
                subsystem: "account",
                kind: "not-found",
                message: "Selected endpoint no longer exists",
                at: Date.now()
            }
        }
        var profile = endpoint
            ? accountProfiles.find(function(item) { return item.pk === endpoint.profileId }) || null
            : null
        if (endpoint && !profile) {
            selectionError = {
                subsystem: "account",
                kind: "contract",
                message: "The selected endpoint references an unavailable profile",
                at: Date.now()
            }
        }
        if (profile) {
            profile = Object.assign({}, profile, {
                sharedEndpointCount: Models.countProfileAssignments(accountDevices, profile.pk)
            })
        }

        var previousWriteState = snapshot.auth && snapshot.auth.writeState
            ? snapshot.auth.writeState : "unverified"
        snapshot = Object.assign({}, snapshot, {
            phase: endpoint && profile ? "ready" : "setupRequired",
            configured: endpoint !== null && profile !== null,
            stale: false,
            hasConfirmedData: endpoint !== null && profile !== null,
            endpoints: accountDevices,
            endpoint: endpoint,
            profiles: accountProfiles,
            profile: profile,
            auth: {
                provider: setting("credentialProvider", "secret-service"),
                secretPresent: true,
                readVerified: true,
                writeState: previousWriteState,
                state: previousWriteState === "denied" ? "readOnly" : "verified"
            },
            api: {
                state: "online",
                lastSuccessAt: Date.now(),
                lastAttemptAt: snapshot.api.lastAttemptAt
            },
            lastError: selectionError
        })
        readPending = null
        publish(true)

        var accountCommand = pendingAccountCommandId
        var accountCommandType = pendingAccountCommandType
        pendingAccountCommandId = ""
        if (accountCommand)
            finishCommand(accountCommand, accountCommandType, true, "Control D state refreshed", null, true)

        if (activeMutation && (activeMutation.stage === "readback" || activeMutation.stage === "uncertainReadback"))
            finishMutationReadback(true, null)

    }

    function handleAccountFailure(error) {
        var safeError = sanitizedError(error, "api")
        if (safeError.kind === "auth" || safeError.kind === "permission") {
            apiToken = ""
            snapshot.auth = Object.assign({}, snapshot.auth, {
                secretPresent: true,
                readVerified: false,
                writeState: "unverified",
                state: "rejected"
            })
        }
        snapshot = Object.assign({}, snapshot, {
            phase: snapshot.hasConfirmedData ? "ready" : "error",
            stale: snapshot.hasConfirmedData,
            api: Object.assign({}, snapshot.api, {
                state: safeError.kind === "network" || safeError.kind === "timeout" || safeError.kind === "server"
                    ? "offline" : "error"
            }),
            lastError: safeError
        })
        publish(false)

        var accountCommand = pendingAccountCommandId
        var accountCommandType = pendingAccountCommandType
        pendingAccountCommandId = ""
        if (accountCommand)
            finishCommand(accountCommand, accountCommandType, false, safeError.message, safeError, true)
        if (activeMutation && (activeMutation.stage === "readback" || activeMutation.stage === "uncertainReadback"))
            finishMutationReadback(false, safeError)
    }

    function retryDelay(attempt) {
        var base = attempt === 1 ? 2000 : (attempt === 2 ? 5000 : 15000)
        return Math.round(base * (0.9 + Math.random() * 0.2))
    }

    function selectEndpoint(commandId, endpointId) {
        if (activeMutation || snapshot.busyAction) {
            finishCommand(commandId, "setEndpoint", false, "Wait for the current Control D change to finish", {
                              subsystem: "account", kind: "busy",
                              message: "Wait for the current Control D change to finish", at: Date.now()
                          }, false)
            return
        }
        var endpoint = accountDevices.find(function(item) { return item.pk === endpointId }) || null
        if (!endpoint) {
            finishCommand(commandId, "setEndpoint", false, "Select an endpoint from the current account list", {
                              subsystem: "account", kind: "not-found",
                              message: "Endpoint is not in the current account list", at: Date.now()
                          }, true)
            return
        }
        var profile = accountProfiles.find(function(item) { return item.pk === endpoint.profileId }) || null
        if (!profile) {
            finishCommand(commandId, "setEndpoint", false, "The endpoint profile is unavailable", {
                              subsystem: "account", kind: "contract",
                              message: "The endpoint profile is unavailable", at: Date.now()
                          }, true)
            return
        }
        if (pluginService)
            pluginService.savePluginData(pluginId, "endpointId", endpoint.pk)
        profile = Object.assign({}, profile, {
            sharedEndpointCount: Models.countProfileAssignments(accountDevices, profile.pk)
        })
        snapshot = Object.assign({}, snapshot, {
            phase: "ready",
            configured: true,
            stale: false,
            hasConfirmedData: true,
            endpoint: endpoint,
            profile: profile,
            lastError: null
        })
        publish(true)
        finishCommand(commandId, "setEndpoint", true, "Endpoint association saved", null, true)
        delayedDnsTimer.restart()
    }

    function runDnsProbe(commandId) {
        if (dnsProbe.running) {
            if (commandId)
                finishCommand(commandId, "runDnsProbe", false, "DNS check is already running", {
                                  subsystem: "dns", kind: "busy",
                                  message: "DNS check is already running", at: Date.now()
                              }, false)
            return
        }
        pendingDnsCommandId = commandId || ""
        snapshot = Object.assign({}, snapshot, {
            dns: Object.assign({}, snapshot.dns, { state: "checking" })
        })
        publish(false)
        if (!dnsProbe.run()) {
            pendingDnsCommandId = ""
            snapshot = Object.assign({}, snapshot, {
                dns: {
                    state: "toolError",
                    lastCheckedAt: Date.now(),
                    detail: "DNS tool could not be started"
                }
            })
            publish(false)
        }
    }

    function handleDnsResult(result) {
        snapshot = Object.assign({}, snapshot, {
            dns: {
                state: result.state || "unknown",
                lastCheckedAt: result.lastCheckedAt || Date.now(),
                detail: Models.sanitizeText(result.detail || "DNS state is unknown", 240)
            }
        })
        publish(true)
        if (pendingDnsCommandId) {
            var ok = result.state === "healthy"
            finishCommand(pendingDnsCommandId, "runDnsProbe", ok,
                          ok ? "Local DNS is using Control D" : snapshot.dns.detail,
                          ok ? null : {
                              subsystem: "dns", kind: result.state,
                              message: snapshot.dns.detail, at: Date.now()
                          }, true)
            pendingDnsCommandId = ""
        }
    }

    function beginMutation(commandId, type, expected, confirmationMode) {
        if (activeMutation || snapshot.busyAction) {
            finishCommand(commandId, type, false, "Another Control D change is in progress", {
                              subsystem: "mutation", kind: "busy",
                              message: "Another Control D change is in progress", at: Date.now()
                          }, false)
            return false
        }
        if (!apiToken || !snapshot.endpoint || !snapshot.profile || snapshot.api.state !== "online") {
            finishCommand(commandId, type, false, "Control D state is not ready for changes", {
                              subsystem: "mutation", kind: "setup",
                              message: "Control D state is not ready for changes", at: Date.now()
                          }, true)
            return false
        }
        if (snapshot.auth.writeState === "denied") {
            finishCommand(commandId, type, false, "A Control D Write token is required", {
                              subsystem: "mutation", kind: "permission",
                              message: "A Control D Write token is required", at: Date.now()
                          }, true)
            return false
        }
        activeMutation = {
            id: commandId,
            type: type,
            stage: "writing",
            uncertain: false,
            confirmationMode: confirmationMode || "readback",
            expected: expected || {}
        }
        snapshot = Object.assign({}, snapshot, { busyAction: type, lastError: null })
        publish(false)
        return true
    }

    function sendMutation(path, fields) {
        var mutation = activeMutation
        mutationHandle = Api.request("PUT", path, fields, requestContext(), function(result) {
            if (!root.activeMutation || root.activeMutation !== mutation || root.shuttingDown)
                return
            root.mutationHandle = null
            if (!result.ok) {
                root.handleMutationFailure(result.error)
                return
            }
            root.snapshot.auth = Object.assign({}, root.snapshot.auth, {
                writeState: "verified",
                state: "verified"
            })
            if (mutation.confirmationMode === "accepted") {
                root.finishAcceptedProfileMutation(mutation)
                return
            }
            mutation.stage = "readback"
            root.refreshAccount("", 0, "refreshAll")
        })
    }

    function finishAcceptedProfileMutation(mutation) {
        setLocalPauseExpiry(mutation.expected.profileId, mutation.expected.disableTtl)
        activeMutation = null
        snapshot = Object.assign({}, snapshot, { busyAction: "", lastError: null })
        publish(false)
        var message = mutation.type === "pauseProfile"
            ? "Profile pause accepted; countdown is a local estimate"
            : "Profile reactivation accepted; remote state cannot be read back"
        finishCommand(mutation.id, mutation.type, true, message, null, true)
        refreshAccount("", 0, "refreshAll")
        delayedDnsTimer.restart()
    }

    function handleMutationFailure(error) {
        var mutation = activeMutation
        var safeError = sanitizedError(error, "mutation")
        if (safeError.kind === "permission") {
            snapshot.auth = Object.assign({}, snapshot.auth, {
                writeState: "denied",
                state: "readOnly"
            })
        }
        if (safeError.kind === "timeout") {
            if (mutation.confirmationMode === "accepted") {
                activeMutation = null
                snapshot = Object.assign({}, snapshot, {
                    busyAction: "",
                    lastError: safeError
                })
                publish(false)
                finishCommand(mutation.id, mutation.type, false,
                              "Write timed out; remote profile state is unknown. Use Reactivate profile to retry.",
                              safeError, true)
                return
            }
            mutation.uncertain = true
            mutation.stage = "uncertainReadback"
            refreshAccount("", 0, "refreshAll")
            return
        }
        activeMutation = null
        snapshot = Object.assign({}, snapshot, {
            busyAction: "",
            lastError: safeError
        })
        publish(false)
        finishCommand(mutation.id, mutation.type, false, safeError.message, safeError, true)
        if (safeError.kind === "not-found")
            refreshAccount("", 0, "refreshAll")
    }

    function finishMutationReadback(success, error) {
        var mutation = activeMutation
        if (!mutation)
            return
        if (success && !Models.mutationReadbackMatches(mutation, snapshot)) {
            success = false
            error = {
                subsystem: "mutation",
                kind: "contract",
                message: "Read-back did not confirm the requested Control D change",
                at: Date.now()
            }
        }
        activeMutation = null
        snapshot = Object.assign({}, snapshot, {
            busyAction: "",
            lastError: success ? null : sanitizedError(error, "mutation")
        })
        publish(success)
        if (!success) {
            var readbackMessage = error && error.kind === "contract"
                ? error.message
                : (mutation.uncertain ? "Write timed out and state could not be refreshed"
                                      : "Change succeeded but read-back failed")
            finishCommand(mutation.id, mutation.type, false,
                          readbackMessage, error, true)
            return
        }
        if (mutation.uncertain) {
            finishCommand(mutation.id, mutation.type, false,
                          "State refreshed after an uncertain write", {
                              subsystem: "mutation", kind: "timeout",
                              message: "The write timed out; confirmed state was refreshed", at: Date.now()
                          }, true)
        } else {
            finishCommand(mutation.id, mutation.type, true, mutationSuccessMessage(mutation.type), null, true)
        }
        delayedDnsTimer.restart()
    }

    function mutationSuccessMessage(type) {
        switch (type) {
        case "setProtection": return "Protection state updated"
        case "switchProfile": return "Endpoint profile updated"
        case "pauseProfile": return "Profile pause updated"
        case "resumeProfile": return "Profile resumed"
        default: return "Control D state updated"
        }
    }

    function setProtection(commandId, enabled) {
        if (!snapshot.endpoint || snapshot.configState === "pending" || snapshot.configState === "unknown") {
            finishCommand(commandId, "setProtection", false, "Endpoint status cannot be changed yet", {
                              subsystem: "mutation", kind: "state",
                              message: "Endpoint status cannot be changed yet", at: Date.now()
                          }, false)
            return
        }
        if (snapshot.configState === "hardDisabled" && enabled !== true) {
            finishCommand(commandId, "setProtection", false, "A hard-disabled endpoint can only be reactivated", {
                              subsystem: "mutation", kind: "state",
                              message: "A hard-disabled endpoint can only be reactivated", at: Date.now()
                          }, false)
            return
        }
        var status = Models.protectionStatus(enabled === true)
        if (!beginMutation(commandId, "setProtection", {
                               endpointId: snapshot.endpoint.pk,
                               status: status
                           }))
            return
        sendMutation("/devices/" + Api.encodePathSegment(snapshot.endpoint.pk), {
            status: status
        })
    }

    function switchProfile(commandId, profileId) {
        var profile = accountProfiles.find(function(item) { return item.pk === profileId }) || null
        if (!profile) {
            finishCommand(commandId, "switchProfile", false, "Select a profile from the current account list", {
                              subsystem: "mutation", kind: "not-found",
                              message: "Profile is not in the current account list", at: Date.now()
                          }, false)
            return
        }
        if (!beginMutation(commandId, "switchProfile", {
                               endpointId: snapshot.endpoint.pk,
                               profileId: profile.pk
                           }))
            return
        sendMutation("/devices/" + Api.encodePathSegment(snapshot.endpoint.pk), {
            profile_id: profile.pk
        })
    }

    function pauseProfile(commandId, seconds, confirmedShared) {
        if (!Models.allowedPauseSeconds(seconds) || !snapshot.capabilities.pause) {
            finishCommand(commandId, "pauseProfile", false, "Profile pause is unavailable for this API response", {
                              subsystem: "mutation", kind: "contract",
                              message: "Profile pause is unavailable for this API response", at: Date.now()
                          }, false)
            return
        }
        if (snapshot.profile.sharedEndpointCount > 1 && setting("confirmSharedPause", true)
                && confirmedShared !== true) {
            finishCommand(commandId, "pauseProfile", false, "Confirm the shared-profile pause first", {
                              subsystem: "mutation", kind: "confirmation",
                              message: "Confirm the shared-profile pause first", at: Date.now()
                          }, false)
            return
        }
        var disableTtl = Math.floor(Date.now() / 1000) + Number(seconds)
        var confirmationMode = snapshot.capabilities.pauseMode === "unconfirmed" ? "accepted" : "readback"
        if (!beginMutation(commandId, "pauseProfile", {
                               profileId: snapshot.profile.pk,
                               disableTtl: disableTtl
                           }, confirmationMode))
            return
        sendMutation("/profiles/" + Api.encodePathSegment(snapshot.profile.pk), {
            disable_ttl: disableTtl
        })
    }

    function resumeProfile(commandId) {
        if (!snapshot.capabilities.pause) {
            finishCommand(commandId, "resumeProfile", false, "Profile pause is unavailable for this API response", {
                              subsystem: "mutation", kind: "contract",
                              message: "Profile pause is unavailable for this API response", at: Date.now()
                          }, false)
            return
        }
        var confirmationMode = snapshot.capabilities.pauseMode === "unconfirmed" ? "accepted" : "readback"
        if (!beginMutation(commandId, "resumeProfile", {
                               profileId: snapshot.profile.pk,
                               disableTtl: 0
                           }, confirmationMode))
            return
        sendMutation("/profiles/" + Api.encodePathSegment(snapshot.profile.pk), {
            disable_ttl: 0
        })
    }

    function clearCache(commandId) {
        cacheWriteTimer.stop()
        if (pluginService) {
            pluginService.clearPluginState(pluginId)
            snapshot = Object.assign({}, snapshot, { cache: { cachedAt: 0 } })
            publish(false)
        }
        finishCommand(commandId, "clearCache", true, "Cached Control D state cleared", null, true)
    }

    function handleCommand(command) {
        if (!command || Models.commandIsDuplicate(recentCommandIds, command.id))
            return
        recentCommandIds = Models.rememberCommandId(recentCommandIds, command.id, 64)
        var payload = command.payload || {}
        switch (command.type) {
        case "initialize": initialize(command.id); break
        case "refreshAll": refreshAll(command.id); break
        case "runDnsProbe": runDnsProbe(command.id); break
        case "credentialsChanged":
        case "testCredentials":
            if (activeMutation || snapshot.busyAction) {
                finishCommand(command.id, command.type, false,
                              "Wait for the current Control D change before replacing credentials", {
                                  subsystem: "credentials", kind: "busy",
                                  message: "Wait for the current Control D change before replacing credentials",
                                  at: Date.now()
                              }, false)
            } else {
                resolveCredentials(command.id, command.type)
            }
            break
        case "setEndpoint": selectEndpoint(command.id, String(payload.endpointId || "")); break
        case "setProtection": setProtection(command.id, payload.enabled === true); break
        case "switchProfile": switchProfile(command.id, String(payload.profileId || "")); break
        case "pauseProfile": pauseProfile(command.id, payload.seconds, payload.confirmedShared === true); break
        case "resumeProfile": resumeProfile(command.id); break
        case "clearCache": clearCache(command.id); break
        default:
            finishCommand(command.id, command.type, false, "Unsupported command", {
                              subsystem: "command", kind: "validation",
                              message: "Unsupported command", at: Date.now()
                          }, false)
            break
        }
    }

    Component {
        id: requestTimeoutComponent
        Timer {}
    }

    property SecretStore secretStore: SecretStore {
        onAvailabilityFinished: function(available) { root.handleSecretAvailability(available) }
        onLookupFinished: function(success, secret, message) {
            root.handleSecretLookup(success, secret, message)
        }
    }

    property DnsProbe dnsProbe: DnsProbe {
        onFinished: function(result) { root.handleDnsResult(result) }
    }

    Timer {
        id: apiPollTimer
        interval: root.boundedInterval("apiPollSeconds", 300)
        repeat: true
        running: root.initialized
        onTriggered: {
            if (root.apiToken && !root.activeMutation)
                root.refreshAccount("", 0)
        }
    }

    onPluginDataChanged: {
        if (!setting("allowUnconfirmedProfilePause", false))
            unconfirmedProfilePauses = ({})
        if (initialized)
            publish(false)
    }

    Timer {
        id: dnsPollTimer
        interval: root.boundedInterval("dnsPollSeconds", 300)
        repeat: true
        running: root.initialized
        onTriggered: root.runDnsProbe("")
    }

    Timer {
        id: countdownTimer
        interval: 1000
        repeat: true
        running: root.snapshot.remainingPauseSeconds > 0
        onTriggered: {
            var before = root.snapshot.remainingPauseSeconds
            root.publish(false)
            if (before > 0 && root.snapshot.remainingPauseSeconds === 0 && root.apiToken)
                root.refreshAccount("", 0)
        }
    }

    Timer {
        id: delayedDnsTimer
        interval: 2000
        repeat: false
        onTriggered: root.runDnsProbe("")
    }

    Timer {
        id: readRetryTimer
        repeat: false
        onTriggered: root.refreshAccount(root.retryReadCommandId, root.retryReadAttempt,
                                         root.retryReadCommandType)
    }

    Timer {
        id: cacheWriteTimer
        interval: 750
        repeat: false
        onTriggered: {
            if (!root.pluginService || !root.snapshot.hasConfirmedData)
                return
            var cached = Models.sanitizedCache(root.snapshot)
            cached.organizationId = String(root.setting("organizationId", "") || "").trim()
            root.pluginService.savePluginState(root.pluginId, "snapshotCache", cached)
            root.snapshot = Object.assign({}, root.snapshot, { cache: { cachedAt: cached.cachedAt } })
            root.publish(false)
        }
    }

    Component.onCompleted: Qt.callLater(function() {
        var existingCommand = commandVar.value
        if (existingCommand && existingCommand.id)
            recentCommandIds = Models.rememberCommandId([], existingCommand.id, 64)
        acceptCommands = true
        root.initialize("")
    })

    Component.onDestruction: {
        shuttingDown = true
        apiToken = ""
        if (mutationHandle && mutationHandle.abort)
            mutationHandle.abort()
        mutationHandle = null
        abortAccountReads()
        apiPollTimer.stop()
        dnsPollTimer.stop()
        countdownTimer.stop()
        delayedDnsTimer.stop()
        readRetryTimer.stop()
        cacheWriteTimer.stop()
    }
}
