ARMSX3 Amaral
=============

A fork of [ARMSX3](https://github.com/ARMSX2/ARMSX3) -- itself an Android port
of [RPCS3](https://github.com/RPCS3/rpcs3) -- tuned for one target: the
Qualcomm QCS8550 / Adreno 740 in the AYN Odin 2 Portal.

Everything here is driven by measurement. A change ships when it is backed by
numbers on that device, passes the PPU/SPU instruction suite without new
divergences, and does not regress the game matrix. See `docs/fork/` for the
baseline, the per-change log, and the decision records.

It installs as `com.armsx3.amaral`, alongside upstream rather than over it, so
the two can be compared on the same unit in the same session.


Building
--------

arm64-v8a only. You need the Android SDK with NDK 29, CMake 3.30.5 and a JDK 17
or newer; Android Studio ships all of them. NDK 29 is not a floor to round down
from -- clang 19 (NDK 28) miscompiles this tree, and `android/configure.sh`
records why.

Clone with submodules. In this fork librashader and libadrenotools are
submodules too, so there is nothing to fetch by hand:

    git clone --recursive https://github.com/rickamaral94/Armadasx3-fork.git
    cd Armadasx3-fork

Upstream ARMSX3 leaves those two as manual checkouts, which means the version
you build against depends on the day you cloned. Pinning them is what makes an
A/B measurement mean anything -- see docs/fork/DECISIONS.md. To confirm your
tree matches the pins before a measured build:

    tools/fork/check-deps.sh

Then build:

    tools/fork/build.sh a13

That is the whole thing: it checks the dependency pins, refreshes the version
stamp, builds the core, strips it, packages the APK, and writes a JSON build
record next to it. The first build is long -- it compiles LLVM -- and the
unstripped core is around 1.3 GB.

`ANDROID_HOME` and `JAVA_HOME` are found automatically when unset. Set them if
you have several.

Variants are `legacy`, `a11`, `a13` and `a15`; they differ in platform level and
ISA baseline, not in speed, and a device should install the highest it can run.
`android/build-variants.sh` documents the split.

**Gradle does not build the core.** It packages whatever sits in
`jniLibs/arm64-v8a/`, so a build that failed, or a variant whose ninja step was
skipped, leaves the previous core there and Gradle ships it -- a new-looking APK
reporting a new version and running old code, with no symptom. `build.sh`
refuses to finish when that happens: it compares the GNU build id of the freshly
linked core against the one it packaged. Use it rather than driving cmake and
gradle by hand, and if you do drive them by hand, check that yourself.

Every binary carries how it was built, not just which commit it came from. The
log's first line is the commit plus `type=`, `march=`, `api=`, `abi=`, `lto=`
and `pgo=`, because the shipped variants differ only in the last of those and
two logs from one commit can otherwise describe different code.

The Discord Social SDK is proprietary and is not redistributed here. Get it from
Discord's developer portal and drop it in app/libs/ and
app/src/main/cpp/discord_sdk/ if you want that feature. The build skips it
otherwise.

Running it needs PS3 firmware, which is not included. 
License
-------

GPL-2.0-only, the same as RPCS3. See LICENSE. Some files may be licensed
differently, check the file headers.

Forked from ARMSX3, https://github.com/ARMSX2/ARMSX3
Based on RPCS3, https://github.com/RPCS3/rpcs3
