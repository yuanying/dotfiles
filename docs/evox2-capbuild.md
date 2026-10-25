# One-shot Kyojin build under a temporary CPU ceiling

`bin/evox2-capbuild.py` is a machine-specific experiment, not an installer or
production service. Each execution needs explicit approval. **The latest user
instruction supersedes automatic restoration: leave the retained llama-server
STOPPED after success, failure or timeout until the user orders restoration.**
CPU restoration and scoped build-child termination remain mandatory. No model
download/load, benchmark, fan/EC/SMU change, persistent setting or retry follows.
A 3 GHz CPU policy ceiling is not a wattage cap or cooling improvement claim.

## Observed result: extension build/import succeeded; baseline STOPPED

The approved bg6 execution finished exit0 in about26m37s. The actual build plus
minimal import took1346.776 seconds (22m26.8s), within3600 seconds. Observed ninja
was exactly `ninja -v -j 1`; an independently rehashed136,685,256-byte extension
was generated (SHA256 `52369c1e5b2d3dbb2f144b230c7a32e448cb8dccf6c998f60767f6690b19d984`).
The same fixed environment imported `torch` and `exllamav3_ext`, printed the
artifact path and confirmed torch2.12a0/HIP7.13.60980. This establishes **native
extension build/loader-ABI feasibility**, not full engine/model execution,
GPU-model readiness, speed, quality or adoption. No model body was acquired or
loaded, and no candidate inference or extra build was run.

During the build,1263 observations covered1345.560 seconds: maximum monitored
CPU/GPU temperature49.125°C, available memory minimum127,965,995,008bytes and
GPUbusy0. Maximum build sample gap was1.083 seconds, not strict1Hz. Across the
whole run,1499 pre-decision samples included a3.242-second maximum transition
gap; all1498 full CPU-state records matched the expected original/capped state.
All32 maxima stayed3,000,000kHz while capped; surrounding fields were unchanged.
There were167 kernel deltas/222 new records, zero detected new faults, zero
coverage losses/read errors/OOM deltas and no swap increase from initial.

The release observation had available130,966,712,320bytes/GTT18,628,608bytes and
GPUbusy3. The corrected cooldown waited rather than aborting:62.376 seconds of
observations included60.278 seconds continuously ready. This **does not identify
the missing failed sample from the earlier attempt**. Capped/post-restore ready
intervals were60.810/60.282 seconds. Post-restore temperature separately peaked
63.5°C; it is not the compile peak. Different cache progress/ambient/external
activity and no uncapped same-workload control prevent causal thermal or wattage
improvement claims.

All206 tracked PID/starttime identities were independently non-live afterward,
no compiler/candidate remained, and all32 original CPU maxima5,187,500kHz plus
**every** snapshot field matched independently. The root journal is `restored`
with320 events/zero errors. Same retained container/image is **EXITED**, OOMfalse/
restart0; no automatic start or restoration smoke was performed. It remains
stopped until a separate user instruction. Private raw logs/root journals and
the large extension are not committed; [compact evidence](evox2-capbuild-result.json)
records hashes and limitations. Final offline tests do not launch the engine.

## Fixed references

These **unmerged** implementations are hash-checked and executed from the same
bytes, not copied or modified:

- [PR166](https://github.com/yuanying/dotfiles/pull/166) snapshot/apply/restore:
  SHA256 `bd59f915a62609223507c6eabd38e6b0bfb52d48e866e51b8a9911582a7d5cb0`.
- [PR165](https://github.com/yuanying/dotfiles/pull/165) guard/sample/process APIs:
  SHA256 `fe1d8d148e71a973931d6474b3bc58208fcfc42b5a3fe1b832b8ef76cee9c404`.

The isolated engine revision is
`e09322da7209331c57e2a79cfc30d120f0299154`. Retain its existing venv, matching
ROCm7.13/gfx1151 SDK, install lock, build wrapper and partial cache. Retain the
actual container/image/binary/libraries/models; no recreate/build/pull/prune of
the baseline is used. Historical restoration archives also require the exact
[PR156](https://github.com/yuanying/dotfiles/pull/156) smoke implementation:
SHA256 `9364396b4882299d0e23b332eda7a89698f71c471e1d8027d4d16582f5844bab`.
Those archives are not part of the latest runner's lifecycle.

## Lifecycle and safety

1. Coordinate exclusive deliberate workload use: no parallel tests/builds/
   inference. Read-only preflight verifies the current container/image/args,
   actual mapped binary/library hashes, entrypoint/Compose, health, disk reserve,
   engine revision, absence of old compilers/candidates and 60-second full CPU
   state stability. Use existing administrative sudo/sysfs access only. Host
   power-manager absence and activity outside the visible PID namespace are
   not proven.
2. Stop the exact retained container by ID. Available memory must reach100 GiB
   and recover at least60 GiB. Wait **at most300 seconds** for temperature<85°C
   and GPUbusy0 to remain observed continuously for60 seconds. A non-ready
   observation resets the timer, not the experiment. All real safety guards
   continue operating during this wait; timeout means no build, service stays
   STOPPED. Temperature is the maximum CPU/GPU reading, conservative for Tctl.
3. Capture a fresh root-private durable journal. Apply only the32 CPU maxima's
   `min(original,3000000)` kHz; governor/EPP/minimum/boost/topology and surrounding
   fields must remain unchanged. Repeat the same bounded continuous cooldown
   under the capped state before compilation.
4. Launch exactly one unprivileged build with MAX_JOBS=1,
   CMAKE_BUILD_PARALLEL_LEVEL=1, MAKEFLAGS=-j1 and single-thread BLAS/OpenMP hints.
   Observed ninja arguments must contain exactly one `-j1` or `-j 1`. A3600-second
   budget includes the minimal torch/extension import. Success also requires
   an extension artifact, import marker and actual ninja observation; objects
   or subprocess exit alone are insufficient. No candidate model is loaded.
5. Stop/reap all observed build descendants before CPU recovery. PID/starttime
   plus pidfds restrict signaling, including separate process groups; TERM then
   KILL each have20-second grace. Never use process-name killing or signal an
   unrelated job. Unkillable descendants prevent restoration and must be
   escalated. Very short-lived unobserved processes remain a tracking limit.
6. Cancel alarms/ignore further cleanup termination signals, restore only
   still-owned CPU values with PR166's conflict-aware API, compare all original
   fields and perform bounded post-restore cooldown. **Only verify that the
   retained service remains exited; there is no service-start or smoke path in
   the current runner.** External conflicts are reported, not overwritten or
   repaired through another configuration/reboot. SIGKILL/power loss cannot run
   cleanup: retain the journal and administrative access for explicit recovery.

Nominal1 Hz observations enforce full CPU snapshot equality, required CPU/GPU
sensors, critical minus5°C, 95°C for10 seconds, available memory below8 GiB,
swap growth over512 MiB, cgroup/system OOM and new kernel faults. The inherited
conservative two-low-sample memory gate and an elapsed2-second check are both
retained. Missing sensors, monitor errors, unexpected baseline restart, sample
gap over5 seconds or build deadline aborts. SIGALRM interrupts blocked active
sampling after at most5 seconds or the remaining build budget. These are
userspace watchdogs, not hard-real-time or strict fixed-rate guarantees.

Fixed numeric/counter sample fields are saved **before** safety decisions with
a4 KiB bound. Unknown arbitrary content is excluded; read failures record a
fixed source/class/errno. Full expected CPU fields and bounded kernel diagnostics
are private telemetry. At most16 unidentified hwmon/name failures are recorded
per sample. Both k10temp and amdgpu must be identified; identified directories,
inputs and critical files must persist and contain plausible numeric readings.
Losing a previously identified name cannot be hidden by the unrelated-directory
skip. The initial missing hwmon4/name belonged to a Wi-Fi/ieee80211 path, while
CPUhwmon3/GPUhwmon5 remained readable.

Kernel monitoring uses timestamped default dmesg records and a retained tail
anchor/text delta, **not whole-buffer equality**. Old-line eviction is not a
fault when the previous tail remains observable. New GPU/reset/pagefault/
timeout/error, OOM, critical thermal or machine-check records abort. Deferred
printk text with an older timestamp is also checked, rather than silently
ignored. Tail-anchor loss, missing timestamps, read failure or a4 MiB read-budget
overflow means coverage is unverified and aborts; it is not a fault-free PASS.
Kernel timestamps are cursor metadata, not assumed equal to userspace monotonic
clock values. Private diagnostics retain at most16 fault lines of512 characters;
full host logs and arbitrary contents are never printed to stdout. The kernel
reader preserves stdout and uses consistent splitlines parsing; it does not
use the generic whole-output strip helper. Other command readers are unchanged.
Ring-buffer visibility still cannot prove global fault absence.

## Evidence and version boundaries

[Latest result](evox2-capbuild-result.json) is separate from the
[historical prebuild failures/restoration](evox2-capbuild-prebuild-result.json).
The historical resumed runner SHA256 was
`9e3c3ec14f86f0111053162f0442e0b5ba6bbfd6975c9ac155f755e7784f4bc5`:

- The first launch stopped on unrelated hwmon4/name ENOENT before mutation.
- Its approved sensor correction passed58 stability observations over60 seconds,
  stopped the service and passed memory release. A single non-idle post-stop
  predicate then aborted; cleanup cooldown and pre-start predicates also failed.
  **Failed sample values were not saved. Whether temperature or GPU busy caused
  those predicates to fail is unknown.** CPU apply/compiler spawn never ran.
- A restoration-only operation observed59 cool/GPU-idle samples over60.0755 seconds,
  found no visible GPU clients and started the retained container once. Its
  full-kernel-text equality assertion then aborted when an old error disappeared;
  it did not establish a new fault. The container stayed running.
- Read-only classification found zero current kernel errors/recent visible
  GPU/reset/OOM/thermal faults. Verification continued without another service
  operation: health5times, four serial smoke requests each once/max256/180seconds,
  original hashes/CPU fields and final60.974-second hold all passed. Same image/
  container RUNNING/OOMfalse/restart0; final available17,380,409,344bytes/T33.125°C.
  These are **historical** restored-state results, not the latest stopped-state
  instruction or a candidate build/benchmark result.

Historical final verification:73 samples/span75.090s/max gap1.076s, available
minimum17,165,197,312bytes/temperature maximum50°C. Baseline startup separately
peaked61.75°C; neither is a compile temperature. Cgroup OOM0; system oom_kill
stayed35 during final verification. Old failures and missing values stay intact.

The authorized reexecution changes behavior, not just diagnostics: pre-decision
sample/error logging adds I/O; cooldown now waits/resets up to5 minutes instead
of aborting on one non-ready reading; kernel delta/coverage replaces equality;
cleanup **cannot start the baseline**. Offline fixtures do not establish live
success; the exact latest source hash/live-validation status belongs in its
separate result. Another stopped build does not authorize retry or restoration.

The first execution of the stopped-baseline lifecycle (bg5) stopped after three
preflight observations with `kernel_coverage_lost`, before service stop, CPU
apply or compiler spawn. Its new-fault list was empty, but coverage-unverified
was not treated as PASS. The actual old tail text was not preserved, so its
specific cause remains unproven. A separately approved bounded read-only
[reader diagnosis](evox2-capbuild-dmesg-diagnostic.json) found nine stable reads:
1241 retained lines, no newly observed fault, a trailing space on the last line,
and identical hash/timestamp bounds. Whole-output strip can remove that space
only while the line is last; when appended-to history makes it interior, exact
tail comparison falsely reports loss. A synthetic fixture reproduces this
mechanism without losing any old record.

The subsequently approved minimal fix changes **only the kernel reader** to preserve
stdout instead of invoking generic output().strip(). No range/sentinel redesign
or coverage-policy relaxation is included. A new trailing-space/append fixture,
older-timestamp new-fault detection, actual gap and parse-failure fixtures must
pass before another explicitly approved preflight. Generic readers remain
unchanged. Bg6 then completed the capped build under that exact source; no
historical missing sample is retroactively filled by the successful run.

[Historical restoration-only scripts](evox2-capbuild-evidence/) are task-specific
archives, **not commands to rerun**. They use the historical runner by exact hash
and only pinned APIs/read-only hash helpers: they do not instantiate Run or
invoke run/lifecycle/build/CPU mutation. The
[version-difference patch](evox2-capbuild-evidence/executed-to-offline.patch) can
be reversed against the latest source in a disposable directory to recover the
exact historical resumed runner bytes; fixtures check that SHA. Archives fail
closed against newer source. Large raw logs, requests/replies, venvs and root
journals remain outside Git.

## Invocation contract (not authorization)

Use a new empty root-owned0700 directory without symlinks and a reviewed writable
progress-note path. The runner requires root, `--confirm-single-build`, `--cpu`,
`--guard`, `--trial`, `--directory` and `--progress`. A singleton lock prevents
concurrent instances, not unrelated jobs/controllers. It leaves the service
STOPPED until a separate human restoration instruction.

```sh
TEST_BUILD_GUARD_SOURCE=/reviewed/qwen_trial_guard.py python3 test/evox2_capbuild_test.py
TEST_BUILD_GUARD_SOURCE=/reviewed/qwen_trial_guard.py bats test/evox2-capbuild.bats
bats -r .
python3 -m py_compile bin/evox2-capbuild.py test/evox2_capbuild_test.py
git diff --check
```

Before and after the successful live build,27 runner fixtures,26 pinned CPU API
fixtures, the related Bats wrapper and the full284-test Bats suite passed.
The pinned API fixture import path was resolved to the reviewed reference in
memory; its tests were not otherwise changed. One earlier full run had an
unchanged tageditor startup-stub failure (`uv.args` absent;283/284); its13-test file and subsequent
full runs passed. That failure is retained, not silently excluded. Python
compile(), operational-wrapper bash-n, evidence/hash cross-checks and diff checks
were also performed; no production shell configuration changed.

Fixtures cover lifecycle failures, CPU cleanup, no automatic service start,
PID reuse/separate-process-group stop without affecting an unrelated sleep,
ninja option rejection, timeout/gap handling, sample-before-decision/error-source
records, sensor loss, conservative thermal gates, cooldown reset/timeout, old
kernel-line disappearance/new or delayed faults and ring-coverage loss. They
also verify historical-source reconstruction and compact artifact hashes.
