#!/usr/bin/env bash
#
# Build an ARMSX3-Amaral APK, with the guarantees a measured build needs.
#
# This is a thin layer over android/build-variants.sh, not a replacement. That
# script already does configure -> ninja -> strip -> copy -> gradle and knows
# the variant matrix; duplicating it would mean two definitions of what a build
# is, and they would drift.
#
# What this adds is the part measurement depends on:
#
#   1. Dependencies are at their pinned commits (tools/fork/check-deps.sh).
#      Upstream leaves librashader and libadrenotools as manual checkouts, so
#      without this the binary depends on when you last cloned.
#
#   2. The git version stamp is refreshed before anything compiles, so the APK
#      reports the commit being built rather than whichever one cmake last
#      configured against.
#
#   3. The .so inside the APK is verified to be the one just built, by hash.
#      This is the failure this script exists for: gradle does NOT build the
#      core, it packages whatever sits in jniLibs. A build that errors, or a
#      variant whose ninja step was skipped, leaves the PREVIOUS core in place
#      and gradle happily ships it. The APK looks new, reports a new version,
#      and contains old code -- an A/B that measures nothing, with no symptom.
#
#   4. A build record (JSON) next to the APK: commit, variant, dependency
#      pins, .so hash, APK hash, toolchain versions. PERF-LOG.md entries cite
#      it, so a number can always be traced back to a binary.
#
# Usage:
#   tools/fork/build.sh [variant ...]     # default: a13
#
# Environment:
#   ANDROID_HOME, JAVA_HOME   resolved by android/host-tools.sh when unset
#   OUT_DIR                   where the APK lands (default: $HOME/Downloads)
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# shellcheck source=android/host-tools.sh
. "$ROOT/android/host-tools.sh"

if [ -z "${ANDROID_HOME:-}" ]; then
	ANDROID_HOME="$(armsx3_default_android_home)" || exit 1
fi
export ANDROID_HOME

VARIANTS="${*:-a13}"
: "${OUT_DIR:=$HOME/Downloads}"
RECORD_DIR="${RECORD_DIR:-$OUT_DIR}"

say() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Pins
# ---------------------------------------------------------------------------
say "checking dependency pins"
# --require-all: a real build needs llvm, glslang, zlib and the rest, not just
# the two pins the fork added.
"$ROOT/tools/fork/check-deps.sh" --require-all

# ---------------------------------------------------------------------------
# 2. Version stamp
# ---------------------------------------------------------------------------
# build-variants.sh also does this, but it has to happen before the hashes below
# are read so the record describes the build that is about to run.
say "stamping git version"
bash "$ROOT/android/stamp-git-version.sh"

GIT_SHA="$(git rev-parse HEAD)"
GIT_SHORT="$(git rev-parse --short=8 HEAD)"
GIT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
GIT_DIRTY="false"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
	GIT_DIRTY="true"
	echo "WARNING: the working tree has uncommitted changes." >&2
	echo "         This APK is not reproducible from any commit. Fine for" >&2
	echo "         iterating; do not put its numbers in PERF-LOG.md." >&2
fi

# ---------------------------------------------------------------------------
# 3. Build, then prove the APK carries the core just built
# ---------------------------------------------------------------------------
JNI_LIBS="$ROOT/android/armsx3-ui/app/src/main/jniLibs/arm64-v8a"

sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1   # macOS has no sha256sum
	fi
}

for variant in $VARIANTS; do
	build_dir="$ROOT/build-$variant"

	# Remember what was packaged BEFORE this build. If the build silently does
	# nothing, this is what would ship.
	previous_packaged=""
	[ -f "$JNI_LIBS/libarmsx3-core.so" ] && previous_packaged="$(sha256 "$JNI_LIBS/libarmsx3-core.so")"

	say "building variant $variant"
	OUT_DIR="$OUT_DIR" bash "$ROOT/android/build-variants.sh" "$variant"

	linked="$build_dir/android/libarmsx3-core.so"
	[ -f "$linked" ] || { echo "FAIL: $variant produced no core at $linked" >&2; exit 1; }

	packaged="$JNI_LIBS/libarmsx3-core.so"
	[ -f "$packaged" ] || { echo "FAIL: $variant left nothing in jniLibs" >&2; exit 1; }

	# The packaged .so is the STRIPPED copy of the linked one, so their hashes
	# differ by design and cannot be compared directly. What can be compared is
	# the build id: llvm-strip preserves .note.gnu.build-id, and the linker
	# derives it from the linked content, so equal build ids mean the packaged
	# library came from this link and not from the previous one.
	# Any readelf can read the note; prefer an NDK one and fall back to the host.
	# Walk the installed NDKs rather than assuming the newest, because a partially
	# extracted one sorts first just as easily.
	READELF=""
	for ndk in "$ANDROID_HOME"/ndk/*/; do
		for bin in "$ndk"toolchains/llvm/prebuilt/*/bin; do
			[ -x "$bin/llvm-readelf" ] && { READELF="$bin/llvm-readelf"; break 2; }
		done
	done
	[ -n "$READELF" ] || READELF="$(command -v llvm-readelf || command -v readelf || true)"
	[ -n "$READELF" ] || { echo "FAIL: no readelf available to check the build id" >&2; exit 1; }

	build_id() {
		"$READELF" --notes "$1" 2>/dev/null |
			sed -n 's/.*[Bb]uild ID: \([0-9a-f]\{8,\}\).*/\1/p' | head -1
	}

	linked_id="$(build_id "$linked")"
	packaged_id="$(build_id "$packaged")"

	if [ -z "$linked_id" ] || [ -z "$packaged_id" ]; then
		echo "FAIL: no GNU build id in the core -- cannot prove the APK is not stale." >&2
		echo "      linked=$linked packaged=$packaged" >&2
		exit 1
	fi

	if [ "$linked_id" != "$packaged_id" ]; then
		echo "FAIL: the packaged core is NOT the one just built." >&2
		echo "      linked   $linked_id  ($linked)" >&2
		echo "      packaged $packaged_id  ($packaged)" >&2
		[ -n "$previous_packaged" ] && echo "      jniLibs held sha256 $previous_packaged before this build" >&2
		echo "      Gradle does not build the core; it ships what is in jniLibs." >&2
		exit 1
	fi

	packaged_sha="$(sha256 "$packaged")"
	echo "  ok: packaged core matches this build (build id $packaged_id)"

	# ------------------------------------------------------------------
	# 4. Build record
	# ------------------------------------------------------------------
	apk="$(ls -t "$OUT_DIR"/ARMSX3-*"$variant"*.apk 2>/dev/null | head -1 || true)"
	apk_sha=""
	[ -n "$apk" ] && apk_sha="$(sha256 "$apk")"

	# Written by android/CMakeLists.txt at configure time.
	stamp=""
	[ -f "$build_dir/armsx3-build-stamp.txt" ] && stamp="$(head -1 "$build_dir/armsx3-build-stamp.txt")"

	mkdir -p "$RECORD_DIR"
	record="$RECORD_DIR/build-record-$variant-$GIT_SHORT.json"

	{
		printf '{\n'
		printf '  "variant": "%s",\n' "$variant"
		printf '  "git_commit": "%s",\n' "$GIT_SHA"
		printf '  "git_branch": "%s",\n' "$GIT_BRANCH"
		printf '  "git_dirty": %s,\n' "$GIT_DIRTY"
		printf '  "build_stamp": "%s",\n' "$stamp"
		printf '  "core_build_id": "%s",\n' "$packaged_id"
		printf '  "core_sha256": "%s",\n' "$packaged_sha"
		printf '  "apk": "%s",\n' "${apk##*/}"
		printf '  "apk_sha256": "%s",\n' "$apk_sha"
		printf '  "submodule_pins": {\n'
		printf '    "librashader": "%s",\n' "$(git rev-parse HEAD:3rdparty/librashader)"
		printf '    "libadrenotools": "%s"\n' "$(git rev-parse HEAD:android/armsx3-ui/app/src/main/cpp/libadrenotools)"
		printf '  },\n'
		printf '  "host": "%s",\n' "$(uname -sm)"
		printf '  "built_at": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf '}\n'
	} > "$record"

	say "$variant done"
	echo "  apk:    ${apk:-<not found in $OUT_DIR>}"
	echo "  record: $record"
done
