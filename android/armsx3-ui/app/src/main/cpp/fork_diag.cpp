// Fork-only: on-device diagnostics, so a report can be produced without a PC.
//
// This file exists because tools/fork/device-probe.sh needs adb, and the log it
// pairs with lives under Android/data, which no file manager can reach since
// Android 11. Everything here is read in-process instead.
//
// It answers one question the shell probe cannot answer at all, which is why it
// is native rather than more Kotlin: what does CTR_EL0 read as ON EACH CORE.
//
// A740 devices are big.LITTLE, and the JIT's instruction-cache maintenance
// (DC CVAU / IC IVAU strides) depends on the cache line size. Dolphin refuses
// __builtin___clear_cache for exactly this reason: a block compiled on a big
// core and flushed with its line size can be left partially stale for a little
// core. But Linux has a countermeasure -- ARM64_MISMATCHED_CACHE_TYPE traps EL0
// reads of CTR_EL0 on such systems and returns one sanitised value. Where that
// is active, userspace CANNOT observe the mismatch and the hazard does not
// apply to us; where it is not, it can and does.
//
// So the report prints both halves and lets them disagree:
//   - sysfs coherency_line_size per core, which is the hardware's own answer
//   - CTR_EL0 read while pinned to each core, which is what our code would get
//
// sysfs differing while CTR_EL0 is uniform is the kernel sanitising, and is the
// answer that closes A740-QUIRKS Q6 in favour of trusting the value.

#include <jni.h>

#include <sched.h>
#include <unistd.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>

namespace {

// CTR_EL0 field decode (ARM ARM D17.2.34). The line-size fields are log2 of the
// number of WORDS, so a value of 4 means 4 * 2^4 = 64 bytes.
struct ctr_fields {
    unsigned iminline;  // bytes, smallest instruction cache line
    unsigned dminline;  // bytes, smallest data cache line
    unsigned erg;       // bytes, exclusives reservation granule
    unsigned cwg;       // bytes, cache writeback granule
    bool idc;           // data-to-instruction coherency: no DC CVAU needed
    bool dic;           // instruction cache invalidation not needed
};

ctr_fields decode_ctr(unsigned long ctr) {
    ctr_fields f{};
    f.iminline = 4u << (ctr & 0xF);
    f.dminline = 4u << ((ctr >> 16) & 0xF);
    f.erg = 4u << ((ctr >> 20) & 0xF);
    f.cwg = 4u << ((ctr >> 24) & 0xF);
    f.idc = ((ctr >> 28) & 1) != 0;
    f.dic = ((ctr >> 29) & 1) != 0;
    return f;
}

bool read_ctr_el0(unsigned long *out) {
#if defined(__aarch64__)
    unsigned long value = 0;
    // Readable from EL0 whenever SCTLR_EL1.UCT allows it, which Linux sets. On a
    // mismatched-cache system the kernel traps this and emulates a safe value --
    // that emulation is the thing this whole file is measuring.
    __asm__ volatile("mrs %0, ctr_el0" : "=r"(value));
    *out = value;
    return true;
#else
    (void) out;
    return false;
#endif
}

// Pin to one CPU, run fn, restore. Returns false when the CPU is not in this
// process's allowed set, which Android does impose: a backgrounded app can be
// confined to the little cluster, so a core being unreachable is a real outcome
// to report rather than an error to hide.
template <typename Fn>
bool on_cpu(int cpu, Fn &&fn) {
    cpu_set_t previous;
    CPU_ZERO(&previous);
    if (sched_getaffinity(0, sizeof(previous), &previous) != 0) {
        return false;
    }

    cpu_set_t one;
    CPU_ZERO(&one);
    CPU_SET(cpu, &one);
    if (sched_setaffinity(0, sizeof(one), &one) != 0) {
        return false;
    }

    // The kernel moves the thread at the next reschedule, not on return from the
    // syscall, so read only after yielding.
    sched_yield();
    fn();

    sched_setaffinity(0, sizeof(previous), &previous);
    return true;
}

std::string read_sysfs_line_size(int cpu) {
    // index0..index3: L1d, L1i, L2, L3. Report every level that answers, because
    // the mismatch that matters can be at any of them.
    std::string out;
    for (int index = 0; index < 4; ++index) {
        char path[128];
        std::snprintf(path, sizeof(path),
                      "/sys/devices/system/cpu/cpu%d/cache/index%d/coherency_line_size", cpu, index);
        FILE *f = std::fopen(path, "re");
        if (!f) {
            continue;
        }
        unsigned value = 0;
        const bool ok = std::fscanf(f, "%u", &value) == 1;
        std::fclose(f);
        if (!ok) {
            continue;
        }

        char level[64];
        std::snprintf(level, sizeof(level), "%sindex%d=%u", out.empty() ? "" : " ", index, value);
        out += level;
    }
    return out.empty() ? std::string("unreadable (SELinux or no sysfs cache nodes)") : out;
}

} // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_armsx2_ForkNative_cacheGeometry(JNIEnv *env, jobject /*thiz*/) {
    std::string report;

#if !defined(__aarch64__)
    report = "not aarch64; CTR_EL0 unavailable\n";
    return env->NewStringUTF(report.c_str());
#else
    const long configured = sysconf(_SC_NPROCESSORS_CONF);
    const long online = sysconf(_SC_NPROCESSORS_ONLN);

    char header[160];
    std::snprintf(header, sizeof(header), "cpus: %ld configured, %ld online\n", configured, online);
    report = header;

    unsigned first_dmin = 0;
    bool uniform = true;
    bool any = false;

    for (long cpu = 0; cpu < configured; ++cpu) {
        unsigned long ctr = 0;
        bool got = false;
        const bool pinned = on_cpu(static_cast<int>(cpu), [&] { got = read_ctr_el0(&ctr); });

        char line[512];
        if (!pinned || !got) {
            std::snprintf(line, sizeof(line),
                          "cpu%ld: CTR_EL0 unreadable (%s); sysfs %s\n", cpu,
                          pinned ? "mrs failed" : std::strerror(errno),
                          read_sysfs_line_size(static_cast<int>(cpu)).c_str());
            report += line;
            continue;
        }

        const ctr_fields f = decode_ctr(ctr);
        if (!any) {
            first_dmin = f.dminline;
            any = true;
        } else if (f.dminline != first_dmin) {
            uniform = false;
        }

        std::snprintf(line, sizeof(line),
                      "cpu%ld: CTR_EL0=0x%08lx dminline=%u iminline=%u erg=%u cwg=%u idc=%d dic=%d;"
                      " sysfs %s\n",
                      cpu, ctr, f.dminline, f.iminline, f.erg, f.cwg, f.idc ? 1 : 0, f.dic ? 1 : 0,
                      read_sysfs_line_size(static_cast<int>(cpu)).c_str());
        report += line;
    }

    // The verdict line, phrased so it can be grepped and cannot be misread as a
    // claim about the hardware. CTR_EL0 uniform means uniform AS SEEN FROM EL0,
    // which is the only thing the JIT can act on.
    if (!any) {
        report += "verdict: NO CTR_EL0 READ SUCCEEDED\n";
    } else if (uniform) {
        report += "verdict: CTR_EL0 UNIFORM across every readable core\n";
    } else {
        report += "verdict: CTR_EL0 DIFFERENT between cores\n";
    }

    return env->NewStringUTF(report.c_str());
#endif
}
