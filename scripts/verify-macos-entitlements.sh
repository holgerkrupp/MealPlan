#!/bin/sh

set -eu

production=false
if [ "$#" -eq 2 ] && [ "$1" = "--production" ]; then
    production=true
    shift
fi

if [ "$#" -ne 1 ]; then
    echo "usage: $0 [--production] /path/to/MealPlan.app" >&2
    exit 64
fi

app_path=$1
if [ ! -d "$app_path" ]; then
    echo "error: app bundle not found: $app_path" >&2
    exit 66
fi

entitlements_file=$(mktemp "${TMPDIR:-/tmp}/mealplan-entitlements.XXXXXX")
trap 'rm -f "$entitlements_file"' EXIT HUP INT TERM

if ! codesign -d --entitlements :- "$app_path" >"$entitlements_file" 2>/dev/null; then
    echo "error: could not read signed entitlements from: $app_path" >&2
    exit 65
fi

assert_absent() {
    entitlement=$1
    if /usr/libexec/PlistBuddy -c "Print :$entitlement" "$entitlements_file" >/dev/null 2>&1; then
        echo "error: unexpected macOS entitlement: $entitlement" >&2
        return 1
    fi
}

assert_true() {
    entitlement=$1
    value=$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$entitlements_file" 2>/dev/null || true)
    if [ "$value" != "true" ]; then
        echo "error: required macOS entitlement is missing or false: $entitlement" >&2
        return 1
    fi
}

assert_present() {
    entitlement=$1
    if ! /usr/libexec/PlistBuddy -c "Print :$entitlement" "$entitlements_file" >/dev/null 2>&1; then
        echo "error: required macOS entitlement is missing: $entitlement" >&2
        return 1
    fi
}

assert_value() {
    entitlement=$1
    expected=$2
    actual=$(/usr/libexec/PlistBuddy -c "Print :$entitlement" "$entitlements_file" 2>/dev/null || true)
    if [ "$actual" != "$expected" ]; then
        echo "error: $entitlement must be $expected (found ${actual:-missing})" >&2
        return 1
    fi
}

assert_absent com.apple.security.device.camera
assert_absent com.apple.security.personal-information.photos-library

assert_true com.apple.security.app-sandbox
assert_true com.apple.security.device.audio-input
assert_true com.apple.security.files.user-selected.read-write
assert_true com.apple.security.network.client
assert_true com.apple.security.personal-information.calendars
assert_true com.apple.security.personal-information.location
assert_present com.apple.security.application-groups
assert_present com.apple.developer.icloud-container-identifiers
assert_present com.apple.developer.icloud-services
assert_present com.apple.developer.ubiquity-kvstore-identifier
assert_present com.apple.developer.aps-environment

if [ "$production" = true ]; then
    codesign --verify --deep --strict "$app_path"
    assert_value com.apple.developer.icloud-container-environment Production
    assert_value com.apple.developer.aps-environment production
    debuggable=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements_file" 2>/dev/null || true)
    if [ "$debuggable" = true ]; then
        echo "error: production app must not allow debugging" >&2
        exit 1
    fi
fi

echo "Verified signed macOS entitlements: $app_path"
