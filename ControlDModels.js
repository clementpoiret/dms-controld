.pragma library

function contractError(message) {
    return {
        ok: false,
        error: {
            kind: "contract",
            httpStatus: 0,
            apiCode: null,
            message: sanitizeText(message || "Control D returned an unsupported response", 240),
            retryable: false,
            at: Date.now()
        }
    }
}

function sanitizeText(value, maximumLength) {
    var text = value === undefined || value === null ? "" : String(value)
    text = text.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim()
    return text.slice(0, maximumLength || 240)
}

function controllerArray(response, key) {
    if (!response || response.success !== true || !response.body || !Array.isArray(response.body[key]))
        return null
    return response.body[key]
}

function validId(value) {
    return typeof value === "string" && value.length > 0 && value.length <= 160
}

function optionalProfileId(value) {
    if (value === undefined || value === null || value === "" || value === -1 || value === "-1")
        return null
    return validId(String(value)) ? String(value) : null
}

function integerOrNull(value) {
    var number = Number(value)
    return Number.isFinite(number) && Math.floor(number) === number ? number : null
}

function normalizeDevices(response) {
    var items = controllerArray(response, "devices")
    if (items === null)
        return contractError("Control D devices response is missing body.devices")

    var devices = []
    for (var index = 0; index < items.length; index += 1) {
        var raw = items[index] || {}
        var pk = validId(raw.PK) ? raw.PK : (validId(raw.device_id) ? raw.device_id : "")
        var profileId = optionalProfileId(raw.profile_id)
        if (!profileId && raw.profile && validId(raw.profile.PK))
            profileId = raw.profile.PK
        var profileId2 = optionalProfileId(raw.profile_id2)
        if (!profileId2 && raw.profile2 && validId(raw.profile2.PK))
            profileId2 = raw.profile2.PK
        var status = integerOrNull(raw.status)
        if (!pk || !profileId || status === null || typeof raw.name !== "string")
            return contractError("A Control D device is missing PK, name, status, or profile")

        devices.push({
            pk: pk,
            resolverId: validId(raw.device_id) ? raw.device_id : (raw.resolvers && validId(raw.resolvers.uid) ? raw.resolvers.uid : pk),
            name: sanitizeText(raw.name, 160),
            status: status,
            profileId: profileId,
            profileId2: profileId2
        })
    }
    return { ok: true, value: devices }
}

function normalizeProfiles(response) {
    var items = controllerArray(response, "profiles")
    if (items === null)
        return contractError("Control D profiles response is missing body.profiles")

    var profiles = []
    for (var index = 0; index < items.length; index += 1) {
        var raw = items[index] || {}
        if (!validId(raw.PK) || typeof raw.name !== "string")
            return contractError("A Control D profile is missing PK or name")
        var disableTtl = raw.disable_ttl === undefined || raw.disable_ttl === null
            ? null
            : integerOrNull(raw.disable_ttl)
        if (raw.disable_ttl !== undefined && raw.disable_ttl !== null && disableTtl === null)
            return contractError("A Control D profile has an invalid disable_ttl")
        profiles.push({
            pk: raw.PK,
            name: sanitizeText(raw.name, 160),
            disableTtl: disableTtl,
            pauseReadable: disableTtl !== null
        })
    }
    profiles.sort(function(left, right) {
        var nameOrder = left.name.toLocaleLowerCase().localeCompare(right.name.toLocaleLowerCase())
        return nameOrder !== 0 ? nameOrder : left.pk.localeCompare(right.pk)
    })
    return { ok: true, value: profiles }
}

function endpointConfigState(status) {
    switch (Number(status)) {
    case 0: return "pending"
    case 1: return "active"
    case 2: return "softDisabled"
    case 3: return "hardDisabled"
    default: return "unknown"
    }
}

function remainingPauseSeconds(disableTtl, nowMs) {
    if (disableTtl === null || disableTtl === undefined)
        return 0
    return Math.max(0, Math.ceil(Number(disableTtl) - Number(nowMs || Date.now()) / 1000))
}

function profilePauseMode(profile, allowUnconfirmed) {
    if (!profile)
        return "unavailable"
    if (profile.pauseReadable === true)
        return "confirmed"
    return allowUnconfirmed === true ? "unconfirmed" : "unavailable"
}

function countProfileAssignments(devices, profilePk) {
    if (!validId(profilePk))
        return 0
    return (devices || []).reduce(function(count, device) {
        return count + (device.profileId === profilePk || device.profileId2 === profilePk ? 1 : 0)
    }, 0)
}

function pauseSource(status, disableTtl, nowMs) {
    if (Number(status) === 3)
        return "hard"
    var endpointPaused = Number(status) === 2
    var profilePaused = remainingPauseSeconds(disableTtl, nowMs) > 0
    if (endpointPaused && profilePaused)
        return "both"
    if (endpointPaused)
        return "endpoint"
    if (profilePaused)
        return "profile"
    return "none"
}

function deriveOverallState(snapshot) {
    var auth = snapshot.auth || {}
    var api = snapshot.api || {}
    var endpoint = snapshot.endpoint || null
    var dns = snapshot.dns || {}
    if (!auth.secretPresent)
        return "setupRequired"
    if (snapshot.phase === "loading" && !snapshot.hasConfirmedData)
        return "loading"
    if (auth.state === "rejected")
        return "authError"
    if (!endpoint)
        return "setupRequired"
    if (api.state === "offline" && !snapshot.hasConfirmedData)
        return "offline"
    if (Number(endpoint.status) === 3)
        return "hardDisabled"
    if (Number(endpoint.status) === 2 || Number(snapshot.remainingPauseSeconds) > 0)
        return "paused"
    if (Number(endpoint.status) === 1 && dns.state === "misconfigured")
        return "misconfigured"
    if (Number(endpoint.status) === 1 && (dns.state === "offline" || dns.state === "toolError"))
        return "offline"
    if (Number(endpoint.status) === 1 && dns.state === "healthy")
        return "healthy"
    return "unknown"
}

function deriveSnapshot(snapshot, nowMs, localDisableTtl) {
    var endpoint = snapshot.endpoint || null
    var profile = snapshot.profile || null
    var effectiveDisableTtl = profile && profile.pauseReadable === true
        ? profile.disableTtl : localDisableTtl
    var remaining = profile ? remainingPauseSeconds(effectiveDisableTtl, nowMs) : 0
    var derived = Object.assign({}, snapshot, {
        configState: endpoint ? endpointConfigState(endpoint.status) : "unknown",
        remainingPauseSeconds: remaining,
        pauseSource: endpoint ? pauseSource(endpoint.status, effectiveDisableTtl, nowMs) : "none"
    })
    derived.overallState = deriveOverallState(derived)
    return derived
}

function protectionStatus(enabled) {
    return enabled === true ? 1 : 2
}

function allowedPauseSeconds(value) {
    var seconds = Number(value)
    return seconds === 300 || seconds === 900 || seconds === 3600 || seconds === 86400
}

function mutationReadbackMatches(mutation, snapshot) {
    if (!mutation || !snapshot)
        return false
    var expected = mutation.expected || {}
    var endpoint = snapshot.endpoint || null
    var profile = snapshot.profile || null
    switch (mutation.type) {
    case "setProtection":
        return endpoint && endpoint.pk === expected.endpointId
                && Number(endpoint.status) === Number(expected.status)
    case "switchProfile":
        return endpoint && endpoint.pk === expected.endpointId
                && endpoint.profileId === expected.profileId
    case "pauseProfile":
    case "resumeProfile":
        return profile && profile.pk === expected.profileId
                && Number(profile.disableTtl) === Number(expected.disableTtl)
    default:
        return false
    }
}

function commandIsDuplicate(recentIds, id) {
    return !validId(id) || (recentIds || []).indexOf(id) !== -1
}

function rememberCommandId(recentIds, id, maximum) {
    var next = (recentIds || []).slice()
    if (!commandIsDuplicate(next, id))
        next.push(id)
    var limit = maximum || 64
    return next.length > limit ? next.slice(next.length - limit) : next
}

function parseNslookupAnswer(output) {
    var lines = String(output || "").split(/\r?\n/)
    var answerStarted = false
    var addresses = []
    for (var index = 0; index < lines.length; index += 1) {
        var line = lines[index].trim()
        var lower = line.toLocaleLowerCase()
        if (lower.indexOf("non-authoritative answer") !== -1 || lower.indexOf("authoritative answers can be found") !== -1)
            answerStarted = true
        if (/^name\s*:/i.test(line))
            answerStarted = true
        if (!answerStarted)
            continue
        var match = line.match(/^address(?:es)?\s*:\s*(.+)$/i)
        if (!match)
            continue
        match[1].split(/\s+/).forEach(function(candidate) {
            var cleaned = candidate.replace(/^\[|\]$/g, "").replace(/#\d+$/, "")
            if ((/^\d{1,3}(\.\d{1,3}){3}$/.test(cleaned) || /^[0-9a-f:]+(%[A-Za-z0-9_.-]+)?$/i.test(cleaned))
                    && addresses.indexOf(cleaned) === -1) {
                addresses.push(cleaned)
            }
        })
    }
    return { ok: addresses.length > 0, addresses: addresses }
}

function sanitizedCache(snapshot) {
    return {
        schemaVersion: 2,
        endpoint: snapshot.endpoint || null,
        profile: snapshot.profile || null,
        profiles: Array.isArray(snapshot.profiles) ? snapshot.profiles : [],
        dns: snapshot.dns || { state: "unknown", lastCheckedAt: 0, detail: "Not checked" },
        api: snapshot.api || { state: "unknown", lastSuccessAt: 0, lastAttemptAt: 0 },
        lastError: snapshot.lastError || null,
        cachedAt: Date.now()
    }
}

function restoreSanitizedCache(cache) {
    if (!cache || cache.schemaVersion !== 2 || !cache.endpoint || !cache.profile)
        return null
    var endpoint = cache.endpoint
    var profile = cache.profile
    var status = integerOrNull(endpoint.status)
    var disableTtl = profile.disableTtl === null || profile.disableTtl === undefined
        ? null : integerOrNull(profile.disableTtl)
    if (!validId(endpoint.pk) || typeof endpoint.name !== "string" || status === null
            || !validId(endpoint.profileId) || !validId(profile.pk)
            || typeof profile.name !== "string" || (profile.disableTtl !== undefined
            && profile.disableTtl !== null && disableTtl === null)) {
        return null
    }
    var dns = cache.dns && typeof cache.dns === "object" ? cache.dns : {}
    var api = cache.api && typeof cache.api === "object" ? cache.api : {}
    var error = cache.lastError && typeof cache.lastError === "object" ? cache.lastError : null
    var cachedProfiles = []
    if (Array.isArray(cache.profiles)) {
        for (var profileIndex = 0; profileIndex < cache.profiles.length; profileIndex += 1) {
            var cachedProfile = cache.profiles[profileIndex] || {}
            if (!validId(cachedProfile.pk) || typeof cachedProfile.name !== "string") {
                cachedProfiles = []
                break
            }
            cachedProfiles.push({
                pk: cachedProfile.pk,
                name: sanitizeText(cachedProfile.name, 160),
                disableTtl: cachedProfile.disableTtl === null || cachedProfile.disableTtl === undefined
                    ? null : integerOrNull(cachedProfile.disableTtl),
                pauseReadable: cachedProfile.pauseReadable === true
            })
        }
    }
    return {
        schemaVersion: 2,
        endpoint: {
            pk: endpoint.pk,
            resolverId: validId(endpoint.resolverId) ? endpoint.resolverId : endpoint.pk,
            name: sanitizeText(endpoint.name, 160),
            status: status,
            profileId: endpoint.profileId,
            profileId2: optionalProfileId(endpoint.profileId2)
        },
        profile: {
            pk: profile.pk,
            name: sanitizeText(profile.name, 160),
            disableTtl: disableTtl,
            pauseReadable: profile.pauseReadable === true,
            sharedEndpointCount: Math.max(0, integerOrNull(profile.sharedEndpointCount) || 0)
        },
        profiles: cachedProfiles,
        dns: {
            state: sanitizeText(typeof dns.state === "string" ? dns.state : "unknown", 40),
            lastCheckedAt: Number(dns.lastCheckedAt) || 0,
            detail: sanitizeText(dns.detail || "Not checked", 240)
        },
        api: {
            state: sanitizeText(typeof api.state === "string" ? api.state : "unknown", 40),
            lastSuccessAt: Number(api.lastSuccessAt) || 0,
            lastAttemptAt: Number(api.lastAttemptAt) || 0
        },
        lastError: error ? {
            subsystem: sanitizeText(error.subsystem || "unknown", 40),
            kind: sanitizeText(error.kind || "unknown", 40),
            httpStatus: Number(error.httpStatus) || 0,
            apiCode: error.apiCode === undefined ? null : error.apiCode,
            message: sanitizeText(error.message || "Operation failed", 240),
            retryable: error.retryable === true,
            at: Number(error.at) || 0
        } : null,
        cachedAt: Number(cache.cachedAt) || 0
    }
}
