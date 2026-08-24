import QtQuick
import QtTest
import "../ControlDApi.js" as Api
import "../ControlDModels.js" as Models

TestCase {
    name: "ControlD"

    function textFixture(name) {
        var request = new XMLHttpRequest()
        request.open("GET", Qt.resolvedUrl("fixtures/" + name), false)
        request.send()
        compare(request.status, 200)
        return request.responseText
    }

    function jsonFixture(name) {
        return JSON.parse(textFixture(name))
    }

    function fixtures() {
        return {
            devices: jsonFixture("devices-success.json"),
            profiles: jsonFixture("profiles-success.json"),
            apiError: jsonFixture("api-error.json")
        }
    }

    function test_form_encoding() {
        compare(Api.formEncode({ name: "Home profile", profile_id: "profile/a", symbol: "a&b" }),
                "name=Home+profile&profile_id=profile%2Fa&symbol=a%26b")
        compare(Api.formEncode({ skip: undefined, empty: "", zero: 0 }), "empty=&zero=0")
        compare(Api.encodePathSegment("profile/a b"), "profile%2Fa%20b")
    }

    function test_api_parsing() {
        var data = fixtures()
        var parsed = Api.parseResponse(200, JSON.stringify(data.devices), 1000)
        verify(parsed.ok)
        var devices = Models.normalizeDevices(parsed.value)
        verify(devices.ok)
        compare(devices.value.length, 2)
        compare(devices.value[0].profileId, "profile_home")
        compare(devices.value[0].profileId2, "profile_shared")

        var profiles = Models.normalizeProfiles(data.profiles)
        verify(profiles.ok)
        compare(profiles.value[0].disableTtl, 0)
        verify(profiles.value[0].pauseReadable)

        var unreadablePause = Models.normalizeProfiles({
            success: true,
            body: { profiles: [{ PK: "profile_home", name: "Home" }] }
        })
        verify(unreadablePause.ok)
        compare(unreadablePause.value[0].disableTtl, null)
        verify(!unreadablePause.value[0].pauseReadable)

        var apiFailure = Api.parseResponse(403, JSON.stringify(data.apiError), 2000)
        verify(!apiFailure.ok)
        compare(apiFailure.error.kind, "permission")
        compare(apiFailure.error.apiCode, 403001)
        compare(apiFailure.error.message, "Token is not authorized for this organization")

        var clientFailure = Api.parseResponse(400, JSON.stringify({ success: false }), 2500)
        verify(!clientFailure.ok)
        compare(clientFailure.error.kind, "unknown")
        compare(clientFailure.error.retryable, false)
        compare(clientFailure.error.at, 2500)

        var invalid = Api.parseResponse(200, "not json", 3000)
        compare(invalid.error.kind, "parse")
    }

    function test_state_reducer() {
        var data = fixtures()
        var devices = Models.normalizeDevices(data.devices).value
        compare(Models.countProfileAssignments(devices, "profile_home"), 2)
        compare(Models.countProfileAssignments(devices, "profile_shared"), 1)
        compare(Models.endpointConfigState(3), "hardDisabled")
        compare(Models.pauseSource(2, 2000000300, 2000000000000), "both")
        compare(Models.remainingPauseSeconds(2000000300, 2000000000000), 300)
        compare(Models.profilePauseMode({ pauseReadable: true }, false), "confirmed")
        compare(Models.profilePauseMode({ pauseReadable: false }, true), "unconfirmed")
        compare(Models.profilePauseMode({ pauseReadable: false }, false), "unavailable")
        compare(Models.profilePauseMode(null, true), "unavailable")

        var base = {
            phase: "ready",
            hasConfirmedData: true,
            auth: { secretPresent: true, state: "verified" },
            api: { state: "online" },
            endpoint: { status: 1 },
            profile: { disableTtl: 0, pauseReadable: true },
            dns: { state: "healthy" }
        }
        compare(Models.deriveSnapshot(base, 1000).overallState, "healthy")
        compare(Models.deriveSnapshot(Object.assign({}, base, { dns: { state: "misconfigured" } }), 1000).overallState,
                "misconfigured")
        compare(Models.deriveSnapshot(Object.assign({}, base, { endpoint: { status: 3 } }), 1000).overallState,
                "hardDisabled")

        var dayPause = Models.deriveSnapshot(Object.assign({}, base, {
            profile: { disableTtl: 2000086400, pauseReadable: true }
        }), 2000000000000)
        compare(dayPause.remainingPauseSeconds, 86400)
        compare(dayPause.pauseSource, "profile")
        compare(dayPause.overallState, "paused")

        var localPause = Models.deriveSnapshot(Object.assign({}, base, {
            profile: { disableTtl: null, pauseReadable: false }
        }), 2000000000000, 2000000300)
        compare(localPause.remainingPauseSeconds, 300)
        compare(localPause.pauseSource, "profile")
        compare(localPause.overallState, "paused")

        var expiredLocalPause = Models.deriveSnapshot(Object.assign({}, base, {
            profile: { disableTtl: null, pauseReadable: false }
        }), 2000000400000, 2000000300)
        compare(expiredLocalPause.remainingPauseSeconds, 0)
        compare(expiredLocalPause.overallState, "healthy")

        var authoritativeActive = Models.deriveSnapshot(Object.assign({}, base, {
            profile: { disableTtl: 0, pauseReadable: true }
        }), 2000000000000, 2000000300)
        compare(authoritativeActive.remainingPauseSeconds, 0)
        compare(authoritativeActive.overallState, "healthy")

        compare(Models.deriveSnapshot({
            phase: "loading", hasConfirmedData: false,
            auth: { secretPresent: true, state: "stored" },
            api: { state: "loading" }, endpoint: null, profile: null,
            dns: { state: "unknown" }
        }, 1000).overallState, "loading")
        compare(Models.deriveSnapshot({
            phase: "error", hasConfirmedData: false,
            auth: { secretPresent: true, state: "rejected" },
            api: { state: "error" }, endpoint: null, profile: null,
            dns: { state: "unknown" }
        }, 1000).overallState, "authError")

        var ids = Models.rememberCommandId([], "command-1", 2)
        verify(Models.commandIsDuplicate(ids, "command-1"))
        ids = Models.rememberCommandId(ids, "command-2", 2)
        ids = Models.rememberCommandId(ids, "command-3", 2)
        compare(ids.length, 2)
        verify(!Models.commandIsDuplicate(ids, "command-1"))

        var restored = Models.restoreSanitizedCache({
            schemaVersion: 2,
            endpoint: {
                pk: "device_1", resolverId: "resolver_1", name: "Laptop",
                status: 1, profileId: "profile_1", profileId2: null
            },
            profile: {
                pk: "profile_1", name: "Home", disableTtl: 0,
                pauseReadable: true, sharedEndpointCount: 1
            },
            cachedAt: 5000
        })
        verify(restored !== null)
        verify(restored.services === undefined)
        verify(Models.restoreSanitizedCache({
            schemaVersion: 2,
            endpoint: { pk: "device_1" },
            profile: { pk: "profile_1", name: "Home" }
        }) === null)

        var cachedSnapshot = Models.sanitizedCache({
            endpoint: {
                pk: "device_1", resolverId: "resolver_1", name: "Laptop",
                status: 2, profileId: "profile_1", profileId2: null
            },
            profile: {
                pk: "profile_1", name: "Home", disableTtl: 2000000300,
                pauseReadable: true, sharedEndpointCount: 1
            },
            profiles: [],
            dns: { state: "healthy", lastCheckedAt: 1000, detail: "Healthy" },
            api: { state: "online", lastSuccessAt: 1000, lastAttemptAt: 1000 },
            configState: "softDisabled",
            pauseSource: "both",
            overallState: "paused",
            remainingPauseSeconds: 300,
            capabilities: { pause: true, pauseMode: "unconfirmed" },
            localDisableTtl: 2000000300,
            lastError: null
        })
        verify(cachedSnapshot.configState === undefined)
        verify(cachedSnapshot.pauseSource === undefined)
        verify(cachedSnapshot.overallState === undefined)
        verify(cachedSnapshot.remainingPauseSeconds === undefined)
        verify(cachedSnapshot.capabilities === undefined)
        verify(cachedSnapshot.localDisableTtl === undefined)

        var rehydrated = Models.restoreSanitizedCache(cachedSnapshot)
        verify(rehydrated !== null)
        var rederived = Models.deriveSnapshot(Object.assign({}, rehydrated, {
            phase: "ready",
            hasConfirmedData: true,
            auth: { secretPresent: true, state: "verified" }
        }), 2000000000000)
        compare(rederived.configState, "softDisabled")
        compare(rederived.pauseSource, "both")
        compare(rederived.overallState, "paused")
        compare(rederived.remainingPauseSeconds, 300)
    }

    function test_mutation_guards() {
        compare(Models.protectionStatus(true), 1)
        compare(Models.protectionStatus(false), 2)
        verify(Models.allowedPauseSeconds(300))
        verify(Models.allowedPauseSeconds(900))
        verify(Models.allowedPauseSeconds(3600))
        verify(Models.allowedPauseSeconds(86400))
        verify(!Models.allowedPauseSeconds(-1))
        verify(!Models.allowedPauseSeconds(600))
        verify(!Models.allowedPauseSeconds(86401))

        var snapshot = {
            endpoint: { pk: "device_1", status: 2, profileId: "profile_2" },
            profile: { pk: "profile_2", disableTtl: 1234 }
        }
        verify(Models.mutationReadbackMatches({
            type: "setProtection", expected: { endpointId: "device_1", status: 2 }
        }, snapshot))
        verify(Models.mutationReadbackMatches({
            type: "switchProfile", expected: { endpointId: "device_1", profileId: "profile_2" }
        }, snapshot))
        verify(Models.mutationReadbackMatches({
            type: "pauseProfile", expected: { profileId: "profile_2", disableTtl: 1234 }
        }, snapshot))
    }

    function test_dns_parser() {
        var healthy = Models.parseNslookupAnswer(textFixture("nslookup-healthy.txt"))
        verify(healthy.ok)
        compare(healthy.addresses.length, 2)
        verify(healthy.addresses.indexOf("127.0.0.53") === -1)
        verify(!Models.parseNslookupAnswer(textFixture("nslookup-misconfigured.txt")).ok)
        verify(!Models.parseNslookupAnswer(textFixture("nslookup-offline.txt")).ok)
    }
}
