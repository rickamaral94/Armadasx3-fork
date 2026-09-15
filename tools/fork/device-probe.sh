#!/usr/bin/env bash
#
# Record what the target device actually is, once per GPU driver.
#
# Runs on the HOST and drives the device over adb. Nothing is pushed to the
# device and nothing here needs root.
#
# There is no vulkaninfo on a stock Android device, and shipping one is a
# second binary to trust and keep current. The emulator already enumerates the
# device at boot and writes it to ARMSX3.log -- GPU name, driver identity and
# conformance version, every requested extension marked supported or not, the
# features it asked for, BC1-BC3 support, native float16 -- so the Vulkan half
# of this probe reads that rather than duplicating the query. The consequence
# is that the app has to have been RUN at least once since the driver was
# changed, which the script checks rather than assumes.
#
# The driver is selected inside the app, so this cannot switch it. Run once per
# driver and label the run. The label is cross-checked against the driver the
# log reports, because "I thought I had switched drivers" is the single easiest
# way to record a measurement against the wrong one.
#
# Usage:
#   tools/fork/device-probe.sh --label proprietary
#   tools/fork/device-probe.sh --label turnip-26.0 --serial <adb serial>
#
# Environment:
#   ADB      adb command to use (default: adb). Overridable for testing.
#   PKG      package to read the log from (default: com.armsx3.amaral)
#
# Output:
#   docs/fork/probe/<label>-<timestamp>.json   committed; cite it from BASELINE.md
#   a Markdown block on stdout for A740-QUIRKS.md
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

: "${ADB:=adb}"
: "${PKG:=com.armsx3.amaral}"
LABEL=""
SERIAL=""
OUT_DIR="$ROOT/docs/fork/probe"

while [ $# -gt 0 ]; do
	case "$1" in
		--label)  LABEL="${2:-}"; shift 2 ;;
		--serial) SERIAL="${2:-}"; shift 2 ;;
		--out)    OUT_DIR="${2:-}"; shift 2 ;;
		-h|--help) sed -n '2,32p' "$0"; exit 0 ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

[ -n "$LABEL" ] || { echo "--label is required (e.g. proprietary, turnip-26.0)" >&2; exit 2; }

if [ -n "$SERIAL" ]; then
	dev() { "$ADB" -s "$SERIAL" shell "$@" 2>/dev/null; }
else
	dev() { "$ADB" shell "$@" 2>/dev/null; }
fi

command -v "$ADB" >/dev/null 2>&1 || { echo "adb not found (set ADB=)" >&2; exit 1; }

# Android's shell strips \r on some hosts and not others; normalise once here so
# every comparison below does not have to.
strip_cr() { tr -d '\r'; }

# Read a file from the device, or print nothing. Callers treat empty as absent,
# because "this kernel does not expose it" and "this file is empty" are the same
# thing for our purposes and neither should abort the probe.
devcat() { dev "cat $1" | strip_cr; }

note() { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ! dev true >/dev/null 2>&1; then
	echo "no device reachable over adb${SERIAL:+ (serial $SERIAL)}" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------
prop() { dev "getprop $1" | strip_cr; }

MODEL="$(prop ro.product.model)"
DEVICE="$(prop ro.product.device)"
SDK="$(prop ro.build.version.sdk)"
RELEASE="$(prop ro.build.version.release)"
FINGERPRINT="$(prop ro.build.fingerprint)"
SOC_MAN="$(prop ro.soc.manufacturer)"
SOC_MODEL="$(prop ro.soc.model)"
BOARD="$(prop ro.board.platform)"

# ---------------------------------------------------------------------------
# CPU topology
#
# /proc/cpuinfo only lists ONLINE cpus, and an offline core has no MIDR to read,
# so the cpu list comes from sysfs and offline cores are reported as offline
# rather than silently dropped. A topology recorded while a core was parked is
# a wrong topology, not a partial one.
# ---------------------------------------------------------------------------
CPU_IDS="$(dev 'ls -d /sys/devices/system/cpu/cpu[0-9]*' | strip_cr | sed 's#.*/cpu##' | sort -n)"
CPUINFO="$(devcat /proc/cpuinfo)"

# MIDR part number -> marketing name. Only parts that could plausibly appear on
# an arm64 Android device. An unknown part prints its raw id rather than a
# guess: naming a core wrongly is worse than not naming it.
part_name() {
	case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
		0xd03) echo "Cortex-A53"  ;; 0xd05) echo "Cortex-A55"  ;;
		0xd07) echo "Cortex-A57"  ;; 0xd08) echo "Cortex-A72"  ;;
		0xd09) echo "Cortex-A73"  ;; 0xd0a) echo "Cortex-A75"  ;;
		0xd0b) echo "Cortex-A76"  ;; 0xd0d) echo "Cortex-A77"  ;;
		0xd41) echo "Cortex-A78"  ;; 0xd44) echo "Cortex-X1"   ;;
		0xd46) echo "Cortex-A510" ;; 0xd47) echo "Cortex-A710" ;;
		0xd48) echo "Cortex-X2"   ;; 0xd4d) echo "Cortex-A715" ;;
		0xd4e) echo "Cortex-X3"   ;; 0xd80) echo "Cortex-A520" ;;
		0xd81) echo "Cortex-A720" ;; 0xd82) echo "Cortex-X4"   ;;
		*)     echo "unknown"     ;;
	esac
}

# The n-th "CPU part" line in /proc/cpuinfo belongs to the n-th "processor"
# block, so they are read as a pair rather than by index into the cpu list --
# with a core offline those two numberings disagree.
ONLINE_PARTS="$(printf '%s\n' "$CPUINFO" | awk '
	/^processor/ { id = $NF }
	/^CPU part/  { print id, $NF }
')"

# ---------------------------------------------------------------------------
# Cache line sizes, per core
#
# This decides whether a real hazard applies to this device. Publishing JIT code
# on ARM64 needs a DC/IC loop that steps by the cache line size, and if that size
# is read once on a big core and later used on a LITTLE core with a smaller line,
# the loop strides past lines it should have touched -- stale instructions,
# intermittently, with no other symptom.
#
# Dolphin refuses __builtin___clear_cache over exactly this and reads CTR_EL0
# itself, keeping a running minimum. asmjit -- which this fork's JIT uses for all
# its cache maintenance -- calls __builtin___clear_cache. Linux mitigates the
# hazard by trapping and sanitising CTR_EL0 on mismatched systems, so the
# question is not settled by argument: it is settled by whether the line sizes on
# THIS device actually differ.
#
# sysfs reports them per CPU without needing to execute an MRS.
# ---------------------------------------------------------------------------
CACHE_LINES="$(dev 'for c in /sys/devices/system/cpu/cpu[0-9]*/cache/index[0-9]*; do
  echo "$c|$(cat $c/level 2>/dev/null)|$(cat $c/type 2>/dev/null)|$(cat $c/coherency_line_size 2>/dev/null)"
done' | strip_cr)"

# ---------------------------------------------------------------------------
# ISA features
#
# Read from the Features line, which is the kernel reporting HWCAP. Note the
# spellings differ from the architecture names: LSE atomics appear as
# "atomics", dot product as "asimddp", FP16 arithmetic as "asimdhp".
# ---------------------------------------------------------------------------
FEATURES="$(printf '%s\n' "$CPUINFO" | sed -n 's/^Features[[:space:]]*:[[:space:]]*//p' | head -1)"

has_feature() {
	case " $FEATURES " in *" $1 "*) echo true ;; *) echo false ;; esac
}

# ---------------------------------------------------------------------------
# Memory, thermal, display
# ---------------------------------------------------------------------------
MEM_TOTAL_KB="$(printf '%s\n' "$(devcat /proc/meminfo)" | sed -n 's/^MemTotal:[[:space:]]*\([0-9]*\).*/\1/p')"

THERMAL="$(dev 'for z in /sys/class/thermal/thermal_zone*; do echo "$z|$(cat $z/type 2>/dev/null)|$(cat $z/temp 2>/dev/null)"; done' | strip_cr)"

# Refresh rates matter for Phase 3's frame pacing: aligning 30/60fps output to
# the panel is impossible without knowing what the panel offers.
DISPLAY_MODES="$(dev 'dumpsys display' | strip_cr | sed -n 's/.*\(fps=[0-9.]*\).*/\1/p' | sort -u | tr '\n' ' ')"

# ---------------------------------------------------------------------------
# Vulkan, from the emulator's own log
# ---------------------------------------------------------------------------
# get_log_dir() is the cache dir under whatever root the app was pointed at, so
# the location is not fixed. Try the ones that exist in practice, newest first.
LOG_PATH=""
for candidate in \
	"/sdcard/Android/data/$PKG/files/cache/ARMSX3.log" \
	"/sdcard/Android/data/$PKG/files/ARMSX3.log" \
	"/sdcard/Android/data/$PKG/cache/ARMSX3.log"
do
	if [ "$(dev "[ -f '$candidate' ] && echo yes" | strip_cr)" = "yes" ]; then
		LOG_PATH="$candidate"
		break
	fi
done

VK_GPU=""; VK_DRIVER=""; VK_DRIVER_ID=""; VK_CONFORMANCE=""
VK_BC="unknown"; VK_FLOAT16="unknown"; VK_EXT_SUPPORTED=""; VK_EXT_MISSING=""
VK_D24="unknown"; VK_D32="unknown"
VK_MEM_LOCAL=""; VK_MEM_COHERENT=""; VK_MEM_BAR=""
LOG_AGE_NOTE=""

if [ -z "$LOG_PATH" ]; then
	note "WARNING: no ARMSX3.log found for $PKG."
	note "         The Vulkan section will be empty. Launch the app once with the"
	note "         driver you want recorded, then run this again."
else
	LOG="$(dev "cat '$LOG_PATH'" | strip_cr)"

	VK_GPU="$(printf '%s\n' "$LOG" | sed -n "s/.*Found Vulkan-compatible GPU: '\([^']*\)'.*/\1/p" | tail -1)"
	VK_DRIVER="$(printf '%s\n' "$LOG" | sed -n 's/.*running on driver \(.*\)$/\1/p' | tail -1)"
	VK_DRIVER_ID="$(printf '%s\n' "$LOG" | sed -n "s/.*Vulkan driver identity: '\([^']*\)'.*/\1/p" | tail -1)"
	VK_CONFORMANCE="$(printf '%s\n' "$LOG" | sed -n 's/.*conformance \([0-9.]*\).*/\1/p' | tail -1)"

	# Depth-stencil: without D24_UNORM_S8_UINT every depth surface becomes
	# D32_SFLOAT_S8_UINT, a different size and precision. Phase 5 needs to know
	# which one the device is actually running.
	vk_depth="$(printf '%s\n' "$LOG" | sed -n 's/.*Depth-stencil formats -- //p' | tail -1)"
	if [ -n "$vk_depth" ]; then
		VK_D24="$(printf '%s' "$vk_depth" | sed -n 's/.*D24_UNORM_S8_UINT: \([a-zA-Z]*\).*/\1/p')"
		VK_D32="$(printf '%s' "$vk_depth" | sed -n 's/.*D32_SFLOAT_S8_UINT: \([a-zA-Z]*\).*/\1/p')"
	fi

	# Heap sizes, already reported by the core. Relevant because this SoC has
	# unified memory: "device local" and "host coherent" are the same physical
	# RAM, so the numbers say how the driver partitions it, not how much exists.
	VK_MEM_LOCAL="$(printf '%s\n' "$LOG" | sed -n 's/.*Detected \([0-9]*\) MB of device local memory.*/\1/p' | tail -1)"
	VK_MEM_COHERENT="$(printf '%s\n' "$LOG" | sed -n 's/.*Detected \([0-9]*\) MB of host coherent memory.*/\1/p' | tail -1)"
	VK_MEM_BAR="$(printf '%s\n' "$LOG" | sed -n 's/.*Detected \([0-9]*\) MB of BAR memory.*/\1/p' | tail -1)"

	printf '%s\n' "$LOG" | grep -q "BC1-BC3 texture compression supported" && VK_BC="true"
	printf '%s\n' "$LOG" | grep -q "lacks support for float16" && VK_FLOAT16="false"
	printf '%s\n' "$LOG" | grep -q "supports float16 data types natively" && VK_FLOAT16="true"

	# The core prints "[Supported] <ext>" / "[Not supported] <ext>" for every
	# extension it asks for. That list is what matters -- an extension the
	# emulator never requests is not a capability gap for us.
	VK_EXT_SUPPORTED="$(printf '%s\n' "$LOG" | sed -n 's/.*\[Supported\] \(VK_[A-Za-z0-9_]*\).*/\1/p' | sort -u | tr '\n' ' ')"
	VK_EXT_MISSING="$(printf '%s\n' "$LOG" | sed -n 's/.*\[Not supported\] \(VK_[A-Za-z0-9_]*\).*/\1/p' | sort -u | tr '\n' ' ')"

	# A log from before the driver was switched describes the OTHER driver.
	# Cross-check the label against what the log says rather than trusting it.
	driver_lc="$(printf '%s %s' "$VK_DRIVER_ID" "$VK_DRIVER" | tr 'A-Z' 'a-z')"
	label_lc="$(printf '%s' "$LABEL" | tr 'A-Z' 'a-z')"

	case "$label_lc:$driver_lc" in
		turnip*:*turnip*|turnip*:*mesa*)   ;;
		proprietary*:*qualcomm*|proprietary*:*adreno*) ;;
		*:) note "WARNING: the log reports no driver identity; the label '$LABEL' is unverified." ;;
		*)  note "WARNING: label says '$LABEL' but the log reports '$VK_DRIVER_ID / $VK_DRIVER'."
		    note "         One of the two is wrong. Do not attach measurements to this run"
		    note "         until you know which."
		    LOG_AGE_NOTE="label/driver mismatch"
		    ;;
	esac
fi

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
# Minimal JSON string escaping: backslash and double quote, then control chars.
# Driver info strings come from the driver and are not ours to assume about.
jstr() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | tr -d '\000-\010\013\014\016-\037'
}

mkdir -p "$OUT_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
JSON="$OUT_DIR/$LABEL-$STAMP.json"

{
	printf '{\n'
	printf '  "label": "%s",\n' "$(jstr "$LABEL")"
	printf '  "probed_at": "%s",\n' "$STAMP"
	printf '  "probe_note": "%s",\n' "$(jstr "$LOG_AGE_NOTE")"
	printf '  "device": {\n'
	printf '    "model": "%s",\n'       "$(jstr "$MODEL")"
	printf '    "device": "%s",\n'      "$(jstr "$DEVICE")"
	printf '    "soc_manufacturer": "%s",\n' "$(jstr "$SOC_MAN")"
	printf '    "soc_model": "%s",\n'   "$(jstr "$SOC_MODEL")"
	printf '    "board_platform": "%s",\n' "$(jstr "$BOARD")"
	printf '    "android_sdk": "%s",\n' "$(jstr "$SDK")"
	printf '    "android_release": "%s",\n' "$(jstr "$RELEASE")"
	printf '    "fingerprint": "%s",\n' "$(jstr "$FINGERPRINT")"
	printf '    "mem_total_kb": %s\n'   "${MEM_TOTAL_KB:-null}"
	printf '  },\n'

	printf '  "cpus": [\n'
	first=1
	for id in $CPU_IDS; do
		online="$(devcat "/sys/devices/system/cpu/cpu$id/online")"
		# cpu0 usually has no online node because it cannot be offlined.
		[ -n "$online" ] || online=1
		cap="$(devcat "/sys/devices/system/cpu/cpu$id/cpu_capacity")"
		maxf="$(devcat "/sys/devices/system/cpu/cpu$id/cpufreq/cpuinfo_max_freq")"
		scalf="$(devcat "/sys/devices/system/cpu/cpu$id/cpufreq/scaling_max_freq")"
		part="$(printf '%s\n' "$ONLINE_PARTS" | awk -v c="$id" '$1==c {print $2}')"
		name="unknown"
		[ -n "$part" ] && name="$(part_name "$part")"

		[ $first -eq 1 ] || printf ',\n'
		first=0
		printf '    {"cpu": %s, "online": %s, "part": "%s", "name": "%s", "capacity": %s, "max_freq_khz": %s, "scaling_max_khz": %s}' \
			"$id" "$([ "$online" = "1" ] && echo true || echo false)" \
			"$(jstr "${part:-}")" "$(jstr "$name")" \
			"${cap:-null}" "${maxf:-null}" "${scalf:-null}"
	done
	printf '\n  ],\n'

	printf '  "isa": {\n'
	printf '    "raw_features": "%s",\n' "$(jstr "$FEATURES")"
	printf '    "dotprod_asimddp": %s,\n' "$(has_feature asimddp)"
	printf '    "fp16_asimdhp": %s,\n'    "$(has_feature asimdhp)"
	printf '    "lse_atomics": %s,\n'     "$(has_feature atomics)"
	printf '    "i8mm": %s,\n'            "$(has_feature i8mm)"
	printf '    "bf16": %s,\n'            "$(has_feature bf16)"
	printf '    "crc32": %s,\n'           "$(has_feature crc32)"
	printf '    "sha3": %s,\n'            "$(has_feature sha3)"
	printf '    "sve": %s,\n'             "$(has_feature sve)"
	printf '    "sve2": %s\n'             "$(has_feature sve2)"
	printf '  },\n'

	printf '  "cache_lines": [\n'
	first=1
	printf '%s\n' "$CACHE_LINES" | while IFS='|' read -r path level type line; do
		[ -n "${path:-}" ] || continue
		cpu="$(printf '%s' "$path" | sed -n 's#.*/cpu\([0-9]*\)/cache/index\([0-9]*\)#\1#p')"
		idx="$(printf '%s' "$path" | sed -n 's#.*/index\([0-9]*\)$#\1#p')"
		[ $first -eq 1 ] || printf ',\n'
		first=0
		printf '    {"cpu": %s, "index": %s, "level": %s, "type": "%s", "line_bytes": %s}' \
			"${cpu:-null}" "${idx:-null}" "${level:-null}" "$(jstr "${type:-}")" "${line:-null}"
	done
	printf '\n  ],\n'

	printf '  "thermal_zones": [\n'
	first=1
	printf '%s\n' "$THERMAL" | while IFS='|' read -r path type temp; do
		[ -n "${path:-}" ] || continue
		[ $first -eq 1 ] || printf ',\n'
		first=0
		printf '    {"zone": "%s", "type": "%s", "temp_raw": %s}' \
			"$(jstr "${path##*/}")" "$(jstr "${type:-}")" "${temp:-null}"
	done
	printf '\n  ],\n'

	printf '  "display_fps_modes": "%s",\n' "$(jstr "$DISPLAY_MODES")"

	printf '  "vulkan": {\n'
	printf '    "source_log": "%s",\n'      "$(jstr "$LOG_PATH")"
	printf '    "gpu": "%s",\n'             "$(jstr "$VK_GPU")"
	printf '    "driver": "%s",\n'          "$(jstr "$VK_DRIVER")"
	printf '    "driver_identity": "%s",\n' "$(jstr "$VK_DRIVER_ID")"
	printf '    "conformance": "%s",\n'     "$(jstr "$VK_CONFORMANCE")"
	printf '    "bc1_bc3": "%s",\n'         "$(jstr "$VK_BC")"
	printf '    "d24_unorm_s8": "%s",\n'    "$(jstr "$VK_D24")"
	printf '    "d32_sfloat_s8": "%s",\n'   "$(jstr "$VK_D32")"
	printf '    "mem_device_local_mb": %s,\n' "${VK_MEM_LOCAL:-null}"
	printf '    "mem_host_coherent_mb": %s,\n' "${VK_MEM_COHERENT:-null}"
	printf '    "mem_bar_mb": %s,\n'        "${VK_MEM_BAR:-null}"
	printf '    "native_float16": "%s",\n'  "$(jstr "$VK_FLOAT16")"
	printf '    "extensions_supported": "%s",\n' "$(jstr "$VK_EXT_SUPPORTED")"
	printf '    "extensions_missing": "%s"\n'    "$(jstr "$VK_EXT_MISSING")"
	printf '  }\n'
	printf '}\n'
} > "$JSON"

# ---------------------------------------------------------------------------
# Human summary + the block to paste into A740-QUIRKS.md
# ---------------------------------------------------------------------------
cat <<SUMMARY

### Probe: $LABEL ($STAMP)

| | |
|---|---|
| Device | ${MODEL:-?} (${DEVICE:-?}) |
| SoC | ${SOC_MAN:-?} ${SOC_MODEL:-?} / ${BOARD:-?} |
| Android | ${RELEASE:-?} (API ${SDK:-?}) |
| RAM | $( [ -n "$MEM_TOTAL_KB" ] && echo "$((MEM_TOTAL_KB / 1024)) MiB" || echo "?" ) |
| Panel fps modes | ${DISPLAY_MODES:-?} |
| GPU | ${VK_GPU:-?} |
| Driver | ${VK_DRIVER_ID:-?} / ${VK_DRIVER:-?} |
| BC1-BC3 | $VK_BC |
| D24_UNORM_S8_UINT | $VK_D24 |
| D32_SFLOAT_S8_UINT | $VK_D32 |
| Native float16 | $VK_FLOAT16 |
| Heaps (device local / host coherent / BAR) | ${VK_MEM_LOCAL:-?} / ${VK_MEM_COHERENT:-?} / ${VK_MEM_BAR:-?} MB |

CPU topology:

SUMMARY

for id in $CPU_IDS; do
	part="$(printf '%s\n' "$ONLINE_PARTS" | awk -v c="$id" '$1==c {print $2}')"
	cap="$(devcat "/sys/devices/system/cpu/cpu$id/cpu_capacity")"
	maxf="$(devcat "/sys/devices/system/cpu/cpu$id/cpufreq/cpuinfo_max_freq")"
	if [ -n "$part" ]; then
		printf '    cpu%-2s %-12s part=%-6s capacity=%-5s max=%s MHz\n' \
			"$id" "$(part_name "$part")" "$part" "${cap:-?}" \
			"$( [ -n "$maxf" ] && echo $((maxf / 1000)) || echo '?' )"
	else
		printf '    cpu%-2s %-12s (offline -- MIDR unreadable; bring it online and re-probe)\n' "$id" "OFFLINE"
	fi
done

echo
echo "Cache line sizes (the JIT publication hazard):"
printf '%s\n' "$CACHE_LINES" | awk -F'|' '
  $4 != "" { key = "L" $2 " " $3; if (!(key in seen)) { order[++n] = key } seen[key] = 1;
             sizes[key "|" $4] = 1; all[$4] = 1 }
  END {
    for (i = 1; i <= n; i++) {
      k = order[i]; out = ""
      for (s in sizes) { split(s, p, "|"); if (p[1] == k) out = out " " p[2] }
      printf "    %-12s%s bytes\n", k, out
    }
    d = 0; for (a in all) d++
    if (d > 1)
      print "    DIFFERENT line sizes across this device -- see docs/fork/A740-QUIRKS.md Q6."
    else if (d == 1)
      print "    Uniform. The big.LITTLE cache-line hazard does not apply here."
    else
      print "    <unreadable>"
  }'

cat <<SUMMARY

ISA: ${FEATURES:-<unreadable>}

Missing Vulkan extensions the emulator asked for:
    ${VK_EXT_MISSING:-<none recorded -- run the app once with this driver>}

Not covered by this probe: device limits (maxBoundDescriptorSets and the rest).
The core does not enumerate them, and nothing has needed them yet. Add it when
something does, rather than carrying a wall of numbers nobody reads.

JSON: $JSON
SUMMARY
