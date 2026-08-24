.pragma library

var BASE_URL = "https://api.controld.com"

function formEncode(fields) {
    return Object.keys(fields || {})
        .filter(function(key) {
            return fields[key] !== undefined && fields[key] !== null
        })
        .sort()
        .map(function(key) {
            var encodedKey = encodeURIComponent(key).replace(/%20/g, "+")
            var encodedValue = encodeURIComponent(String(fields[key])).replace(/%20/g, "+")
            return encodedKey + "=" + encodedValue
        })
        .join("&")
}

function encodePathSegment(value) {
    return encodeURIComponent(String(value))
}

function sanitizeMessage(value, fallback) {
    var message = value === undefined || value === null ? "" : String(value)
    message = message.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim()
    if (!message)
        message = fallback || "Control D request failed"
    return message.slice(0, 240)
}

function errorKind(httpStatus) {
    if (httpStatus === 0)
        return "network"
    if (httpStatus === 401)
        return "auth"
    if (httpStatus === 403)
        return "permission"
    if (httpStatus === 404)
        return "not-found"
    if (httpStatus === 429)
        return "rate-limit"
    if (httpStatus >= 500)
        return "server"
    return "unknown"
}

function normalizeError(httpStatus, parsed, at) {
    var apiError = parsed && parsed.error && typeof parsed.error === "object" ? parsed.error : null
    var kind = errorKind(httpStatus)
    return {
        kind: kind,
        httpStatus: Number(httpStatus) || 0,
        apiCode: apiError && apiError.code !== undefined ? apiError.code : null,
        message: sanitizeMessage(apiError && apiError.message, defaultErrorMessage(kind)),
        retryable: kind === "network" || kind === "timeout" || kind === "rate-limit" || kind === "server",
        at: at || Date.now()
    }
}

function defaultErrorMessage(kind) {
    switch (kind) {
    case "auth":
        return "Token invalid or expired"
    case "permission":
        return "Control D denied this operation"
    case "not-found":
        return "The selected Control D object no longer exists"
    case "rate-limit":
        return "Control D rate limit reached"
    case "server":
        return "Control D is temporarily unavailable"
    case "network":
        return "Control D could not be reached"
    case "timeout":
        return "Control D request timed out"
    case "parse":
        return "Control D returned invalid JSON"
    case "contract":
        return "Control D returned an unsupported response"
    default:
        return "Control D request failed"
    }
}

function parseResponse(httpStatus, responseText, at) {
    var parsed = null
    try {
        parsed = responseText ? JSON.parse(responseText) : null
    } catch (error) {
        return {
            ok: false,
            error: {
                kind: "parse",
                httpStatus: Number(httpStatus) || 0,
                apiCode: null,
                message: defaultErrorMessage("parse"),
                retryable: false,
                at: at || Date.now()
            }
        }
    }

    if (httpStatus >= 200 && httpStatus < 300 && parsed && parsed.success === true)
        return { ok: true, value: parsed }

    return { ok: false, error: normalizeError(httpStatus, parsed, at) }
}

function timeoutError(at) {
    return {
        kind: "timeout",
        httpStatus: 0,
        apiCode: null,
        message: defaultErrorMessage("timeout"),
        retryable: true,
        at: at || Date.now()
    }
}

function request(method, path, formFields, context, callback) {
    var xhr = new XMLHttpRequest()
    var completed = false
    var url = BASE_URL + path

    function finish(result) {
        if (completed)
            return
        completed = true
        if (context && context.cancelTimeout)
            context.cancelTimeout()
        callback(result)
    }

    xhr.onreadystatechange = function() {
        if (xhr.readyState !== XMLHttpRequest.DONE || completed)
            return
        finish(parseResponse(xhr.status, xhr.responseText, Date.now()))
    }

    xhr.open(method, url, true)
    xhr.setRequestHeader("Accept", "application/json")
    xhr.setRequestHeader("Authorization", "Bearer " + context.token)
    if (context.organizationId)
        xhr.setRequestHeader("X-Force-Org-Id", context.organizationId)

    var body = null
    if (formFields !== null && formFields !== undefined) {
        xhr.setRequestHeader("Content-Type", "application/x-www-form-urlencoded")
        body = formEncode(formFields)
    }

    context.startTimeout(function() {
        if (completed)
            return
        completed = true
        xhr.abort()
        if (context && context.cancelTimeout)
            context.cancelTimeout()
        callback({ ok: false, error: timeoutError(Date.now()) })
    })

    if (body === null)
        xhr.send()
    else
        xhr.send(body)

    return {
        abort: function() {
            if (completed)
                return
            completed = true
            if (context && context.cancelTimeout)
                context.cancelTimeout()
            xhr.abort()
        }
    }
}
