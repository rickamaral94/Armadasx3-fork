#!/usr/bin/env bash
#
# Fail if the fork has drifted back into upstream's identity, or if the
# portability fixes have been undone.
#
# These are regressions that a build does NOT catch. An APK with upstream's
# applicationId builds and installs perfectly -- it just installs OVER the
# official app instead of beside it, which quietly destroys the ability to A/B
# the two, and nobody notices until a measurement session goes wrong. Same for
# the updater: pointing at upstream's releases produces a working app that
# offers the wrong binary.
#
# Cheap enough to run on every push, which is the point: the expensive core
# build cannot run that often.
#
# Usage: tools/fork/check-identity.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

fail=0

# $1 = description, $2 = file, $3 = regex that MUST match
require() {
	if grep -qE "$3" "$2"; then
		echo "  ok   $1"
	else
		echo "  FAIL $1 -- expected /$3/ in $2" >&2
		fail=1
	fi
}

# $1 = description, $2..$n = files; fails if the regex in $FORBID matches
forbid() {
	local desc="$1" regex="$2"; shift 2
	local hits
	hits="$(grep -rnE "$regex" "$@" 2>/dev/null || true)"

	if [ -z "$hits" ]; then
		echo "  ok   $desc"
	else
		echo "  FAIL $desc" >&2
		echo "$hits" | sed 's/^/       /' >&2
		fail=1
	fi
}

echo "fork identity:"
UI_GRADLE="android/armsx3-ui/app/build.gradle.kts"
require "github flavor installs as com.armsx3.amaral" "$UI_GRADLE" \
	'applicationId = "com\.armsx3\.amaral"'
require "play flavor installs as com.armsx3.amaral.play" "$UI_GRADLE" \
	'applicationId = "com\.armsx3\.amaral\.play"'
require "launcher label distinguishes the fork" \
	"android/armsx3-ui/app/src/main/res/values/strings.xml" \
	'<string name="app_name">ARMSX3 Amaral</string>'

# The bare upstream ids, not as a prefix of the fork's. \b would also match
# com.armsx3.amaral, so the boundary has to exclude a following dot too.
forbid "no applicationId left on upstream's ids" \
	'applicationId = "com\.armsx3(\.play)?"' \
	android/armsx3-ui/app/build.gradle.kts android/armsx3-app/app/build.gradle.kts

echo
echo "updater points at the fork:"
UPDATER="android/armsx3-ui/app/src/github/java/com/armsx2/update/UpdaterEntry.kt"
require "release feed is the fork's" "$UPDATER" \
	'api\.github\.com/repos/rickamaral94/Armadasx3-fork/releases'
forbid "updater does not fetch upstream releases" \
	'^[^/]*"https://api\.github\.com/repos/ARMSX2/ARMSX3' "$UPDATER"

echo
echo "build scripts stay host-portable:"
# The three scripts were macOS-only; host-tools.sh replaced the hardcoding. A
# regression here means CI stops working, so it is worth a cheap guard.
forbid "no hardcoded NDK host triple" \
	'prebuilt/(darwin|linux|windows)-x86_64' \
	android/configure.sh android/build-variants.sh android/build-play-aab.sh tools/fork/build.sh
forbid "no macOS-only default paths" \
	'(Library/Android/sdk|/Applications/Android Studio)' \
	android/configure.sh android/build-variants.sh android/build-play-aab.sh

echo
if [ "$fail" != 0 ]; then
	echo "Fork identity check FAILED. See docs/fork/DECISIONS.md ADR-0002." >&2
	exit 1
fi
echo "OK: fork identity and build portability intact."
