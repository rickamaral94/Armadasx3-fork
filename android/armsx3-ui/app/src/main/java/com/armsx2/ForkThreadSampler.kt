package com.armsx2

import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Fork-only: which CPU core is each emulator thread actually running on?
 *
 * The question this exists to answer, from the 2026-09-16 profiles: the guest
 * cannot feed the RSX FIFO and it is not reservation contention, so SPU
 * throughput is the suspect -- but six SPU threads plus PPU, RSX and audio share
 * EIGHT ASYMMETRIC CORES here (1x Cortex-X3, 2x A715, 2x A710, 3x A510). An A510
 * is a fraction of an X3. If SPU threads sit on the little cluster, throughput
 * collapses for reasons that have nothing to do with the code the recompiler
 * emits, and optimising codegen would be answering the wrong question.
 *
 * RPCS3's own Thread Scheduler Mode cannot help: its "alt"/"old" modes in
 * Utilities/Thread.cpp are hand-written affinity masks for Threadripper and Zen
 * desktop parts, with no case for ARM at all. So on this device the OS decides,
 * and nothing in the emulator knows a big core from a little one.
 *
 * Sampling rather than tracing: /proc/<pid>/task/<tid>/stat field 39 is the CPU
 * the task last ran on. One sample says little; a histogram over a whole session
 * says where a thread LIVES, which is the question. At 1 Hz the cost is ~60 small
 * reads per second -- far below the noise it is measuring.
 */
object ForkThreadSampler {

    private val started = AtomicBoolean(false)

    /** thread group -> cpu index -> times seen there */
    private val histogram = HashMap<String, IntArray>()
    private var samples = 0
    private var cpuCount = 0

    fun start() {
        if (!started.compareAndSet(false, true)) return

        cpuCount = runCatching { Runtime.getRuntime().availableProcessors() }.getOrDefault(8)

        Thread({
            while (true) {
                runCatching {
                    // Only while a game is actually executing. Paused or stopped, the
                    // "last CPU" field is stale and would pollute the histogram with
                    // wherever a thread happened to stop.
                    if (net.rpcsx.RPCSX.initialized &&
                        net.rpcsx.RPCSX.state.value == net.rpcsx.EmulatorState.Running
                    ) {
                        sampleOnce()
                    }
                }
                runCatching { Thread.sleep(1000) }.getOrElse { return@Thread }
            }
        }, "fork-thread-sampler").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }.start()
    }

    private fun sampleOnce() {
        val tasks = File("/proc/self/task").listFiles() ?: return
        synchronized(histogram) {
            for (task in tasks) {
                val stat = runCatching { File(task, "stat").readText() }.getOrNull() ?: continue

                // comm is field 2 and is parenthesised, and CAN CONTAIN SPACES AND
                // PARENTHESES -- RPCS3 names threads things like "SPU[0x1000100]
                // Thread (BigCellSpursKernel1)". Splitting the whole line on spaces
                // is the classic way to read the wrong field. Cut at the LAST ')'.
                val close = stat.lastIndexOf(')')
                if (close < 0) continue
                val open = stat.indexOf('(')
                if (open < 0 || open > close) continue

                val comm = stat.substring(open + 1, close)
                // After the comm, field 3 is state; the processor is field 39, so it
                // is the 37th token of the remainder.
                val rest = stat.substring(close + 2).trim().split(' ')
                if (rest.size < 37) continue
                val cpu = rest[36].toIntOrNull() ?: continue
                if (cpu < 0 || cpu >= cpuCount) continue

                val key = groupOf(comm)
                histogram.getOrPut(key) { IntArray(cpuCount) }[cpu]++
            }
            samples++
        }
    }

    /**
     * Collapse per-thread names into the groups a decision is made about.
     *
     * Hex ids and trailing digits are stripped so eight SPU threads land in one
     * row instead of eight. The prefixes come from what RPCS3 actually names its
     * threads; anything unrecognised keeps its (normalised) name rather than
     * being lumped into "other", because an unexpected heavy thread is exactly
     * the kind of thing this should surface rather than hide.
     */
    private fun groupOf(comm: String): String {
        val normalised = comm
            .replace(Regex("0x[0-9a-fA-F]+"), "")
            .replace(Regex("\\d+"), "")
            .trim()

        return when {
            normalised.startsWith("SPU", true) -> "SPU"
            normalised.startsWith("PPU", true) -> "PPU"
            normalised.startsWith("RSX", true) -> "RSX"
            normalised.contains("rsx", true) -> "RSX"
            else -> normalised.ifBlank { "(unnamed)" }
        }
    }

    /** Human-readable histogram, or a line saying why there is none. */
    fun report(cpuKinds: List<String>): String {
        val snapshot: Map<String, IntArray>
        val n: Int
        synchronized(histogram) {
            if (samples == 0) {
                return "no samples: the emulator was never in the Running state while the app was up.\n" +
                    "Play first, then export without stopping the game.\n"
            }
            n = samples
            snapshot = histogram.mapValues { it.value.copyOf() }
        }

        return buildString {
            appendLine("$n samples at 1 Hz while a game was running")
            append("thread".padEnd(22))
            for (cpu in 0 until cpuCount) {
                append(("cpu$cpu").padStart(9))
            }
            appendLine()
            append("".padEnd(22))
            for (cpu in 0 until cpuCount) {
                append((cpuKinds.getOrNull(cpu) ?: "?").padStart(9))
            }
            appendLine()

            for ((group, counts) in snapshot.entries.sortedByDescending { it.value.sum() }) {
                val total = counts.sum()
                if (total == 0) continue
                append(group.take(21).padEnd(22))
                for (cpu in 0 until cpuCount) {
                    val pct = 100.0 * counts[cpu] / total
                    append((if (pct >= 0.5) "%.0f%%".format(pct) else "-").padStart(9))
                }
                appendLine("   ($total)")
            }
        }
    }
}
