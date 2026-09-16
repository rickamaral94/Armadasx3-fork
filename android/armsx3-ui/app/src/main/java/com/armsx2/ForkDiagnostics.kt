package com.armsx2

import android.content.Context
import android.os.Build
import java.io.File
import java.io.OutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/**
 * JNI surface of the fork's on-device probe (cpp/fork_diag.cpp).
 *
 * Lives in libarmsx3-jni.so, which RPCSX has already loaded by the time any UI
 * exists. loadLibrary is still attempted, and failure is survivable: the export
 * then carries "cache geometry unavailable" instead of taking the app down for
 * a diagnostics feature.
 */
internal object ForkNative {
    private val available: Boolean = runCatching {
        System.loadLibrary("armsx3-jni"); true
    }.getOrDefault(false)

    external fun cacheGeometry(): String

    fun cacheGeometryOrError(): String =
        if (!available) "libarmsx3-jni not loaded\n"
        else runCatching { cacheGeometry() }.getOrElse { "cacheGeometry() failed: ${it.message}\n" }
}

/**
 * Fork-only: bundle everything a performance report needs into one zip the user
 * can send from the device.
 *
 * The measurement protocol this fork works to wants the emulator log, the build
 * that produced it, and the machine it ran on, together, from one session. On a
 * desktop that is two shell scripts. On Android it was impossible without a PC:
 * ARMSX3.log sits under Android/data, which no file manager has been able to
 * open since Android 11 -- not even with all-files access, since Android/data
 * and Android/obb are the documented exceptions to it.
 *
 * So the export goes through the Storage Access Framework instead. The user
 * picks the destination (Downloads, Drive, anywhere), we write into the stream
 * we are handed, and no new permission or FileProvider is involved.
 */
object ForkDiagnostics {

    class Outcome(val ok: Boolean, val detail: String)

    fun suggestedName(): String {
        val stamp = SimpleDateFormat("yyyyMMdd-HHmm", Locale.US).format(Date())
        return "armsx3-amaral-diag-$stamp.zip"
    }

    fun export(context: Context, out: OutputStream): Outcome {
        val included = ArrayList<String>()
        val missing = ArrayList<String>()

        runCatching {
            ZipOutputStream(out.buffered()).use { zip ->
                // The generated half first: it is the part that explains the rest,
                // and the part a reader should open first.
                zip.putNextEntry(ZipEntry("device.txt"))
                zip.write(deviceReport(context).toByteArray())
                zip.closeEntry()
                included += "device.txt"

                for (file in logFiles(context)) {
                    if (file.isFile && file.length() > 0) {
                        zip.putNextEntry(ZipEntry(file.name))
                        file.inputStream().use { it.copyTo(zip) }
                        zip.closeEntry()
                        included += "${file.name} (${file.length() / 1024} KB)"
                    } else {
                        missing += file.name
                    }
                }
            }
        }.onFailure { return Outcome(false, it.message ?: "zip failed") }

        // Naming what is NOT in the archive matters as much as what is: an absent
        // ARMSX3.log means the emulator has not run yet in this install, and a
        // report sent without one would otherwise look merely empty.
        val detail = buildString {
            append(included.size).append(" files")
            if (missing.isNotEmpty()) append("; absent: ").append(missing.joinToString(", "))
        }
        return Outcome(true, detail)
    }

    /**
     * Every log this build can produce.
     *
     * ARMSX3.log is written by the core to fs::get_log_dir(), which on Android is
     * the cache directory under the data root the app hands initialize() -- so it
     * is derived from RPCSX.rootDirectory rather than guessed. session.log and the
     * crash dumps are the Kotlin side's, under getExternalFilesDir/logs.
     */
    private fun logFiles(context: Context): List<File> {
        val files = ArrayList<File>()

        val root = net.rpcsx.RPCSX.rootDirectory
        if (root.isNotBlank()) {
            val cache = File(root, "cache")
            files += File(cache, "ARMSX3.log")
            files += File(cache, "ARMSX3.old.log")
        } else {
            // Nothing to list, and saying nothing would be the wrong outcome: the
            // export would look successful and simply have no emulator log in it.
            // A file that cannot exist is still named in the "absent" summary.
            files += File("ARMSX3.log (data root unknown: the emulator has not initialised)")
        }

        val logDir = File(context.getExternalFilesDir(null) ?: context.filesDir, "logs")
        files += File(logDir, "session.log")
        logDir.listFiles { f -> f.name.startsWith("crash-") }?.let { files += it }

        return files
    }

    private fun deviceReport(context: Context): String = buildString {
        appendLine("ARMSX3 Amaral -- on-device diagnostics")
        appendLine("generated: " + SimpleDateFormat("yyyy-MM-dd HH:mm:ss Z", Locale.US).format(Date()))
        appendLine()

        appendLine("[build]")
        appendLine("applicationId: " + context.packageName)
        runCatching {
            val info = context.packageManager.getPackageInfo(context.packageName, 0)
            appendLine("versionName: " + info.versionName)
            appendLine("versionCode: " +
                androidx.core.content.pm.PackageInfoCompat.getLongVersionCode(info))
        }.onFailure { appendLine("versionName: unavailable (" + it.message + ")") }
        // The core's own stamp, which is the authoritative one: it names the march,
        // API level and LTO settings the binary was actually compiled with. The
        // first line of ARMSX3.log carries it too; having it here as well means a
        // report is still attributable when the log is the missing piece.
        appendLine("core version: " + if (!net.rpcsx.RPCSX.initialized) "core not initialised" else
            runCatching { net.rpcsx.RPCSX.instance.getVersion() }
                .getOrElse { "unavailable (" + it.message + ")" })
        appendLine("data root: " + net.rpcsx.RPCSX.rootDirectory.ifBlank { "(not initialised)" })
        // Worth knowing when reading the tail of a log captured mid-session: the
        // core's file listener buffers, so the last few lines of play may not have
        // reached disk when the export ran.
        appendLine("emulator running: " + net.rpcsx.RPCSX.initialized +
            " (a log captured while it runs can be missing its last lines)")
        appendLine()

        appendLine("[device]")
        appendLine("model: ${Build.MANUFACTURER} ${Build.MODEL} (${Build.DEVICE})")
        appendLine("board: ${Build.BOARD}  hardware: ${Build.HARDWARE}")
        appendLine("soc: " + DeviceTier.socIdentity().ifBlank { "unknown" })
        appendLine("android: ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
        appendLine("build: " + Build.FINGERPRINT)
        appendLine("abis: " + Build.SUPPORTED_ABIS.joinToString(", "))
        appendLine()

        appendLine("[cache geometry]")
        appendLine("# CTR_EL0 read while pinned to each core, beside what sysfs reports.")
        appendLine("# They can disagree: Linux sanitises CTR_EL0 on mismatched-cache")
        appendLine("# systems, and where it does, userspace cannot observe the mismatch.")
        append(ForkNative.cacheGeometryOrError())
        appendLine()

        appendLine("[cpu]")
        append(procCpuInfo())
        appendLine()

        appendLine("[thread placement]")
        appendLine("# Which core each emulator thread ran on, sampled at 1 Hz while a game")
        appendLine("# was running. SPU work on the little cluster costs throughput for")
        appendLine("# reasons that have nothing to do with the code the recompiler emits.")
        append(ForkThreadSampler.report(cpuKinds()))
        appendLine()

        appendLine("[memory]")
        append(readFirstLines("/proc/meminfo", 3))
    }

    /**
     * The MIDR of each core, which is what identifies a big.LITTLE layout.
     *
     * /proc/cpuinfo lists ONLY online cores, and the "processor:" numbers are its
     * own indices, not stable CPU ids -- so the lines are reproduced verbatim
     * rather than parsed into a table that would silently mispair a MIDR with the
     * wrong core. tools/fork/device-probe.sh makes the same choice for the same
     * reason.
     */
    private fun procCpuInfo(): String = runCatching {
        File("/proc/cpuinfo").readLines()
            .filter { line ->
                val key = line.substringBefore(':').trim().lowercase()
                key == "processor" || key.startsWith("cpu ") || key == "cpu part" ||
                    key == "cpu implementer" || key == "cpu variant" || key == "cpu revision" ||
                    key == "features"
            }
            .joinToString("\n", postfix = "\n")
    }.getOrElse { "unreadable: ${it.message}\n" }

    /**
     * A short label per CPU index, so the placement table reads as "A510" rather
     * than "cpu2" and the answer is legible without cross-referencing.
     *
     * From /proc/cpuinfo's MIDR parts, which ARE readable here -- unlike the sysfs
     * cache and capacity nodes, which SELinux blocked on this device (see the
     * 2026-09-16 capture). The part list covers the cores this fork targets; an
     * unknown part prints its raw id rather than a guess.
     */
    private fun cpuKinds(): List<String> = runCatching {
        val known = mapOf(
            0xd46 to "A510", 0xd47 to "A710", 0xd4d to "A715", 0xd4e to "X3",
            0xd48 to "X2", 0xd44 to "X1", 0xd0d to "A77", 0xd41 to "A78",
            0xd05 to "A55", 0xd03 to "A53",
        )
        val kinds = ArrayList<String>()
        var pending: String? = null
        for (line in File("/proc/cpuinfo").readLines()) {
            val key = line.substringBefore(':').trim().lowercase()
            val value = line.substringAfter(':', "").trim()
            // "processor" opens an entry and "CPU part" closes the part of it we
            // want; cpuinfo lists ONLY online cores, so this follows its order
            // rather than indexing by cpu number.
            if (key == "processor") pending = "?"
            if (key == "cpu part" && pending != null) {
                val part = value.removePrefix("0x").toIntOrNull(16)
                kinds += known[part] ?: ("part" + (part?.toString(16) ?: "?"))
                pending = null
            }
        }
        kinds
    }.getOrDefault(emptyList())

    private fun readFirstLines(path: String, count: Int): String = runCatching {
        File(path).readLines().take(count).joinToString("\n", postfix = "\n")
    }.getOrElse { "unreadable: ${it.message}\n" }
}
