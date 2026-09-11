# shellcheck shell=bash
#
# Resolve toolchain locations for whatever host this is running on.
#
# Sourced, not executed. Every function here prints its answer on stdout and
# returns non-zero when it cannot find one, so callers decide how to fail.
#
# Why: configure.sh, build-variants.sh and build-play-aab.sh each hardcoded
# macOS. The NDK's prebuilt directory was spelled "darwin-x86_64" outright, and
# ANDROID_HOME and JAVA_HOME defaulted to Apple paths. None of the three could
# run on Linux at all, which rules out building in CI -- the failure is a
# "command not found" on a path with darwin in the name, several minutes into a
# build, which does not read as "this script is macOS-only".
#
# The NDK host tag is discovered by globbing rather than mapped from `uname`.
# There are three today (darwin-x86_64, linux-x86_64, windows-x86_64) and an
# arm64 macOS tag has been expected for years; a glob keeps working when one
# appears, a case statement silently does not. Apple Silicon currently still
# ships darwin-x86_64, which is exactly the kind of detail a uname mapping gets
# wrong.

# Print the NDK's llvm toolchain bin directory.  $1 = the NDK root.
armsx3_ndk_bin() {
	local ndk="$1" bin

	for bin in "$ndk"/toolchains/llvm/prebuilt/*/bin; do
		# llvm-strip rather than the directory: a partially extracted NDK has the
		# directory and not the tools, and that fails later and less clearly.
		if [ -x "$bin/llvm-strip" ]; then
			printf '%s' "$bin"
			return 0
		fi
	done

	echo "no llvm toolchain under $ndk/toolchains/llvm/prebuilt/*/bin" >&2
	return 1
}

# Print a plausible Android SDK root for this host.
armsx3_default_android_home() {
	local candidate

	for candidate in \
		"${ANDROID_SDK_ROOT:-}" \
		"$HOME/Library/Android/sdk" \
		"$HOME/Android/Sdk" \
		"$HOME/android-sdk" \
		"/usr/local/lib/android/sdk" \
		"/opt/android-sdk" \
		"/usr/lib/android-sdk"
	do
		# ndk/ rather than the root: an SDK with no NDK cannot build the core, and
		# picking it here means failing later with a path that looks right.
		if [ -n "$candidate" ] && [ -d "$candidate/ndk" ]; then
			printf '%s' "$candidate"
			return 0
		fi
	done

	echo "no Android SDK with an ndk/ directory found; set ANDROID_HOME" >&2
	return 1
}

# Print a JDK home for this host.
armsx3_default_java_home() {
	local candidate

	# An already-set JAVA_HOME wins: it is the documented way to pick a JDK, and a
	# CI runner sets it to the one it means.
	if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
		printf '%s' "$JAVA_HOME"
		return 0
	fi

	for candidate in \
		"/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
		"/opt/android-studio/jbr" \
		"/usr/local/android-studio/jbr" \
		"$(/usr/libexec/java_home 2>/dev/null || true)" \
		"$(dirname "$(dirname "$(readlink -f "$(command -v javac 2>/dev/null || echo /nonexistent)" 2>/dev/null)")" 2>/dev/null)"
	do
		if [ -n "$candidate" ] && [ -x "$candidate/bin/java" ]; then
			printf '%s' "$candidate"
			return 0
		fi
	done

	echo "no JDK found; set JAVA_HOME" >&2
	return 1
}
