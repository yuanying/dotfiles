# Evo-X2: bounded single-CPU load under a temporary 3 GHz ceiling

`bin/evox2-cpu-load.py` is a one-shot experimental adapter, not a persistent
configuration or general stress tool. It reuses the exact CPU-limit API from
[PR166](https://github.com/yuanying/dotfiles/pull/166), reference head `a318254`:

```text
bd59f915a62609223507c6eabd38e6b0bfb52d48e866e51b8a9911582a7d5cb0
```

The source is hash-checked and compiled from those same bytes; it is neither
modified nor duplicated in this PR. PR166 is an **unmerged dependency**. Obtain
and review that source separately before using this adapter. It supplies the
DMI/BIOS/EC allowlist, fixed 32-policy paths, private durable journal,
compare-before-write/readback, partial conflict-aware restoration and original
health/thermal/memory monitor. Its `trial` function is **not** used: that function
was idle-only. The new adapter owns load lifecycle and stage progression.

## Safety and execution contract

Execution requires specific human approval, the existing legitimate sudo/sysfs
route, root and `--confirm-host-change`. Do not run this just to reproduce the
report: another load trial requires another decision. Do not install new
management tools, stop services, remount sysfs or add privileges to make it run.
A new empty root-owned mode0700 directory without symlinks is mandatory.
Snapshot, telemetry and result files remain root0600 and are not committed.
The runner also takes a singleton `/run/evox2-cpu-load.lock`; it does not lock
unrelated host controllers or the standalone PR166 tool.

```text
sudo -n python3 /reviewed/bin/evox2-cpu-load.py \
  --source /reviewed/evox2-cpu-limit.py \
  --directory /new/private/root0700-directory \
  --confirm-host-change
```

Before execution, coordinate an exclusive measurement interval: no concurrent
builds, tests, inference requests or other deliberate workloads. Read current
health, available memory, host CPU/GPU utilization and visible processes, check
the resident service's OOM/restart state and keep the original service running.
Host managers were **not inventoried** in this container; their absence is not
proven. Stability and per-write comparison detect visible changes but cannot
eliminate the residual race inherent in sysfs without compare-and-swap.

Stages:

1. Verify complete original state for60 seconds, then capture a fresh snapshot.
2. Apply only each maximum's `min(snapshot maximum,3000000)` kHz; all other
   fields, including minimum/governor/EPP/boost/topology/boot/DMI, must agree.
3. Observe capped idle for30 seconds.
4. Start one process, one thread, affinity to the lowest allowed CPU in0–31.
   Repeatedly hash a fixed1 MiB zero buffer using stdlib `hashlib.sha256`.
   No compiler, GPU, OpenMP, BLAS, automatic threading or model is invoked.
   Worker `RLIMIT_AS` is64 MiB; `RLIMIT_CPU` and wall alarm are stage seconds+1.
   Its hash loop checks its own monotonic30-second deadline between hashes.
5. Stop/reap the child, then require Tctl<85°C for a continuous observed60 seconds.
   If this is not achieved within90 seconds, skip the second stage (N/A).
6. Only after that gate, perform the same workload with a120-second deadline.
7. Stop/reap every load child **before** safe restore, verify every snapshot
   field, then verify the restored state/health/temperature/memory for60 seconds.

No automatic retry, uncapped control, multi-core stress or extended stage exists.
The configured hashing budget is150 seconds; process initialization, the final
hash, parent observation and stopping grace are not hard-real-time bounded to
that exact total. Parent timeout is stage duration+2 seconds; SIGTERM then
SIGKILL each have a1-second wait. A PID's recorded `/proc` starttime and Linux
pidfd restrict signaling to that one direct child, never a process-name search.
An unkillable child prevents restoration and raises an error; operators must
report the unresolved process/state rather than broaden termination scope.

The changed-settings phase has a420-second SIGALRM deadline. Its alarm is
cancelled before cleanup; termination/alarm signals are temporarily blocked
only during cleanup, then restored. SIGINT/SIGTERM/timeout/monitor errors unwind
through child stop and the existing safe restore. Global boot/topology/state
changes refuse restoration; external per-policy changes are not overwritten,
while still-owned targets can be restored by the pinned API. Recovery uses only
the original snapshot and that API's documented explicit restore action, never
an inferred frequency. SIGKILL/power loss cannot be caught; retain the journal
and an administrative session. Restoration itself has no hard timeout because
an interrupted sysfs/journal recovery would be unsafe.

The inherited monitor conservatively aborts **immediately** at95°C or below8 GiB,
stricter than the approved10-second/2-second persistence gates. Critical−5°C,
sensor loss, swap increase>512 MiB or non-OK health abort too. System OOM kills
and visible cgroup OOM/max events must not increase. Each nominal1Hz observation
records Tctl/memory/swap/health/all32 ceilings; additional telemetry records all
snapshot fields, CPU/GPU utilization and load PID/starttime/ticks/RSS/thread/
affinity. Synchronous health and sysfs reads add latency: this is not a strict
fixed-rate or independent real-time watchdog. Missing/failed reads abort.

## Observed once: 2026-10-22

Executed runner SHA256:
`8a823d6bec285d9f71161cc44a99a6b9d38faeb987cc992623f3e5e6176b2b74`.
Exit0 in about6m5s. Both stages ran onCPU0. The existing model stayed resident;
no service configuration or lifecycle changes were made.

| Stage | Samples / span seconds | Tctl °C | Minimum available bytes | All32 max kHz |
|---|---|---|---:|---:|
| Before |57 /60.000|28–31.375|17,311,662,080|5,187,500|
| Capped idle |29 /30.001|27.75–45.125|17,389,809,664|3,000,000|
| Load30 |29 /30.000|28.625–32.5|17,381,847,040|3,000,000|
| Cooldown |56 /60.066|28–32.75|17,387,515,904|3,000,000|
| Load120 |112 /120.000|28.625–34.375|17,384,263,680|3,000,000|
| Restored |57 /60.012|28.25–75.625|17,390,686,208|5,187,500|

Load PIDs413939/414158 exited0 and were independently absent afterward. Their
sampled maximum RSS was18,063,360/17,891,328 bytes, with one thread and CPU0
when running. Whole-child wall times30.092485/120.091962 seconds include startup
and stopping grace; whole-child user+system CPU times30.036082/120.035168 seconds
include interpreter overhead. **Measured whole-process time<=150 seconds is not
claimed** (wall total150.184447; CPU total150.071250). The hash loop's final
iteration can cross its deadline; that overrun was not separately measured.
No additional trial was run to adjust these numbers.

All340 recorded full-state samples matched the expected snapshot (only maxima
changed while capped). All health reads were OK; OOM counters did not increase;
GPUbusy remained0; swap never increased above its initial value. The journal
ended `restored` with320 successful/not-applicable events and zero errors.
An independent post-exit full snapshot comparison and health GET passed.
All32 original maxima were5,187,500kHz and were retained during the final60 seconds.
Private directory/file ownership and0700/0600 modes were verified separately.
The maximum observed sample gap, including apply/restore transitions, was2.198s.

[Compact machine-readable evidence](evox2-cpu-load-result.json) preserves timing
and limitations. This establishes capped-policy retention and absence of the
configured safety violations for **this single-CPU synthetic workload only**.
There was no uncapped same-workload control. The earlier98.625°C compiler trial
was a different workload, not a comparable baseline. No percentage temperature
improvement, wattage reduction/45W cap, build success, maximum-context inference
stability or actual-frequency trace is established. The restored-period75.625°C
peak is not the load-period peak; external host activity and ambient conditions
were not controlled. No fan/EC/SMU/module/GPU/persistent setting changes or third
Kyojin build occurred. The initial PR166 apply failure remains unexplained;
this trial does not retroactively diagnose it.

## Offline verification

```sh
python3 test/evox2_cpu_load_test.py
# Include pinned Monitor boundary checks (otherwise that integration test skips):
TEST_CPU_LIMIT_SOURCE=/reviewed/evox2-cpu-limit.py python3 test/evox2_cpu_load_test.py
TEST_CPU_LIMIT_SOURCE=/reviewed/evox2-cpu-limit.py bats -r .
python3 -m py_compile bin/evox2-cpu-load.py test/evox2_cpu_load_test.py
git diff --check
```

Eleven new fixtures passed with the pinned source, including real scoped
termination of an **idle sleep**, not a load. The existing source's26 fixtures
also passed with only their import path resolved to the reviewed source; they
cover partial/write-then-error rollback and external setting conflicts. Full
repository Bats:284/284 passed before measurement. No test runs overlapped the
live experiment.
