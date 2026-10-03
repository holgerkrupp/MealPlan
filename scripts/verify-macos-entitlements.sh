#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/MealPlan.app" >&2
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

echo "Verified signed macOS entitlements: $app_path"
