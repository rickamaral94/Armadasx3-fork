#!/usr/bin/env bash
#
# Say whether an ARMSX3.log actually contains the data a phase needs, before
# anyone tries to draw a conclusion from it.
#
# The failure this prevents is quiet: a log that is missing a section looks
# exactly like a log whose section had nothing to report. "No fallback lines"
# means either the recompiler never fell back -- a real and useful result -- or
# the build predates the instrumentation, or the app never got far enough to
# emit one. Those demand opposite next steps, and only the log's own markers can
# tell them apart.
#
# Usage:
#   tools/fork/check-log.sh <ARMSX3.log>
#   tools/fork/check-log.sh --pull            # fetch it off the device first
#
# Exit: 0 the log is usable for both phases; 1 something needed is missing.
set -uo pipefail

: "${ADB:=adb}"
: "${PKG:=com.armsx3.amaral}"

LOG=""

if [ "${1:-}" = "--pull" ]; then
	LOG="$(mktemp -t armsx3-log.XXXXXX)"
	found=""

	for candidate in \
		"/sdcard/Android/data/$PKG/files/cache/ARMSX3.log" \
		"/sdcard/Android/data/$PKG/files/ARMSX3.log" \
		"/sdcard/Android/data/$PKG/cache/ARMSX3.log"
	do
		if "$ADB" shell "[ -f '$candidate' ] && echo yes" 2>/dev/null | tr -d '\r' | grep -q yes; then
			found="$candidate"
			break
		fi
	done

	[ -n "$found" ] || { echo "no ARMSX3.log on the device for $PKG" >&2; exit 1; }
	"$ADB" shell "cat '$found'" 2>/dev/null | tr -d '\r' > "$LOG"
	echo "pulled $found -> $LOG"
	echo
else
	LOG="${1:-}"
	[ -n "$LOG" ] || { sed -n '2,20p' "$0"; exit 2; }
	[ -f "$LOG" ] || { echo "no such file: $LOG" >&2; exit 1; }
fi

missing=0

# $1 = what it is, $2 = regex, $3 = what to do when it is absent
need() {
	if grep -qE "$2" "$LOG"; then
		echo "  ok       $1"
	else
		echo "  MISSING  $1"
		echo "           -> $3"
		missing=1
	fi
}

# Same, but absence is a legitimate result rather than a problem.
report() {
	local n
	n="$(grep -cE "$2" "$LOG")"

	if [ "$n" -gt 0 ]; then
		echo "  ok       $1 ($n line(s))"
	else
		echo "  none     $1 -- $3"
	fi
}

echo "log: $LOG  ($(wc -l < "$LOG" | tr -d ' ') lines)"
echo
echo "Build identity:"
need "build stamp (commit + type/march/api/abi/lto/pgo)" \
	'ARMSX3 build: .*\[type=' \
	"this build predates the stamp, so nothing here can be tied to a binary. Rebuild from the fork."

echo
echo "Phase 1 -- device and driver:"
need "GPU and driver version" 'Found Vulkan-compatible GPU' \
	"the app never reached Vulkan init. Boot a game, not just the menu."
# Must be the form that NAMES the driver. The core prints the same prefix when
# VK_KHR_driver_properties is absent and it could only guess from the GPU name;
# matching the prefix alone would pass a log that cannot tell Turnip from the
# proprietary driver, which is the one thing this line exists to establish.
need "driver identity names the driver" "Vulkan driver identity: '" \
	"either the app never reached Vulkan init, or the driver did not expose VK_KHR_driver_properties -- check for the 'inferred from the GPU name only' line. Either way the run cannot be attributed to a driver."
need "depth-stencil format support" 'Depth-stencil formats --' \
	"this build predates the depth report. Phase 5 needs it; rebuild."
need "memory heaps" 'Detected [0-9]+ MB of device local memory' \
	"Vulkan device creation did not complete."
need "requested extensions supported/not" '\[(Supported|Not supported)\] VK_' \
	"the extension dump did not run; check the log level."

echo
echo "Phase 4 -- interpreter fallback:"
# Absence here is a RESULT, not a gap -- provided the build stamp above is
# present, which is what proves the instrumentation shipped.
report "PPU recompiler fallback" 'PPU fallback: recompiler could not compile' \
	"the PPU recompiler never gave up. Good news: PPU codegen is not the target."
report "PPU reservation fallback (by design)" 'PPU fallback: reservation path' \
	"no reservation interpretation was recorded."
report "SPU blocks that failed to compile" 'SPU block 0x[0-9a-f]+ cannot be compiled' \
	"the SPU backend compiled everything it was asked to."
report "SPU dispatches into failed blocks" 'SPU fallback: [0-9]+ dispatches' \
	"no failed SPU block was ever entered -- so none of them cost anything."

echo
echo "Session shape:"
report "stall / hang reports" 'stall|Stall' "no stalls recorded."
report "driver_env applied" 'driver_env: reading' \
	"no driver_env.txt was found; Mesa options were not set this run."

echo
if [ "$missing" != 0 ]; then
	echo "This log is NOT sufficient. Fix the items marked MISSING and capture again." >&2
	exit 1
fi

echo "This log carries what Phase 1 and Phase 4 need."
echo
echo "Send this file: $LOG"
echo "Together with the device probe JSON from docs/fork/probe/ for the same driver."
