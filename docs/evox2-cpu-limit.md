# Evo-X2 temporary CPU frequency ceiling

`bin/evox2-cpu-limit.py` limits only the 32 existing CPUFreq policies' maximum
frequency to `min(saved maximum, 3000000)` kHz. **It is not a 45 W cap or any
other wattage guarantee.** It does not change minimum frequency, governor, EPP,
boost, GPU performance level, EC registers, fan mode, SMU settings or modules.
No service or persistence is installed. The `trial` action performs only idle
observation, with no inference/compilation/stress workload.

The default invocation is read-only:

```sh
python3 bin/evox2-cpu-limit.py
```

## Supported identity and safety envelope

The current allowlist is intentionally restricted to the observed GMKtec
NucBox_EVO-X2, board version 1.0, BIOS EVO-X2 1.04 dated 05/14/2025 and DMI EC
release 1.1. These DMI values **do not establish fan-register compatibility**.
The script performs no EC access. All 32 policies must use `amd-pstate-epp`,
`powersave` and `balance_performance`, with the expected one-CPU mappings and
online CPUs 0–31. A different machine, firmware or policy layout fails closed;
do not bypass that check for an experiment.

A snapshot records only allowlisted DMI fields (no serial/UUID), boot ID, online
CPU set, global boost/pstate status and all policies' limits/CPU mapping/driver/
governor/EPP/boost. Apply requires exactly the saved state and the same boot.
A fresh snapshot is required for every apply. Settings below 3 GHz are never
raised. A minimum above 3 GHz, unknown state or unexpected policy is refused.

Before any root operation, establish the existing legitimate management route
and try to inspect power-management services/processes for competing controllers
(power-profiles-daemon, tuned, TLP, Ryzen/fan scripts, etc.). In this environment,
existing container sudo permits root and visible sysfs is writable, but host
systemd units/managers remain unobservable. **Host managers were not inventoried;
absence of competing daemons is not proven.** For the specifically approved
short idle experiment, stability observation and compare-before-write/readback
are the competition gate instead. This is not authorization for a persistent
setting. There is no atomic compare-and-swap sysfs interface: a residual race
with an external controller remains even with immediate checks.

Do not create a privileged container, use nsenter, remount sysfs, mount the host
bus or install a module to obtain access. Do not stop another service.

## Apply and restore (explicit approval required)

These are a runbook, **not authorization to run them**. Verify the script's
reviewed hash and use a private root-owned mode0700 directory on persistent
storage. Use a new snapshot name, not an existing file. The parent directory
must be an absolute path without symlinks; snapshot and lock must be regular,
single-link files owned by the effective user and mode0600. Run snapshot and
subsequent mutations as the same approved root identity. A non-root plan needs
no elevation.

```text
sudo python3 /reviewed/path/bin/evox2-cpu-limit.py trial --snapshot /private/root-dir/cpu.json --telemetry /private/root-dir/idle.jsonl --confirm-host-change
```

Only `apply`, `restore` and `trial` can write sysfs, and only with root and the explicit
confirmation flag. Standalone `snapshot`/`apply`/`restore` actions are also available
for manual recovery; `--snapshot` is mandatory. Trial is the preferred approved
bounded experiment, not a background auto-start. There is no alternative sysfs-root CLI option. Attribute
writes use fixed allowlisted paths with no create/truncate flags.

The 32 writes are **not a hardware transaction**. Each intent is journaled with
atomic replacement and fsync before writing. Every step checks the complete
state and readback. Any apply failure stops additional apply writes and
attempts restoration of only journaled policies, including a write that may
have succeeded before reporting an error. Failed rollback leaves
`restore_failed` and its journal intact. Restore accepts only the saved or
expected target max for touched policies; unexpected max or surrounding-policy changes are skipped for that policy,
while other still-owned targets are restored. Global identity/boot/topology/
boost/status changes refuse all restoration. Remaining drift is reported as a
failure, not silently overwritten. It is safe to retry restore
once the conflict has been understood; it never retries automatically. A per-snapshot lock prevents concurrent mutations of the same journal, not
experiments using different journals or unrelated controllers. Run only one
experiment at a time.

`trial` verifies the entire state for 60 seconds before snapshot/apply, observes
the limited state for 60 seconds, restores in a `finally` block, then verifies
that the original state holds for another 60 seconds. Before and after periods
are outside an independent 180-second SIGALRM deadline covering the active
phase. SIGTERM/SIGINT and the deadline raise an error into cleanup; the alarm is
cancelled before restoring so it does not interrupt cleanup. The telemetry
contains per-policy max readbacks, Tctl, available memory, swap and a fixed local
`/health` GET result; no chat is sent. Missing/unsafe CPU temperature, loss of
critical margin, memory below8 GiB, swap growth above512 MiB or unhealthy service
stops the trial. The idle trial conservatively aborts immediately at95°C rather
than using ten hot samples; it never raises the prior thermal guard thresholds.
No health body or private request content is retained.

**No persistent lease or background auto-restore is installed.** Standalone apply
leaves the cap until restore. SIGKILL, power loss or a host crash can interrupt
any userspace operation; keep the snapshot and a working administrative session.
A durable pending journal permits a subsequent explicit restore after an
interrupted apply or restore on the same boot. Version2 journals retain up to512
structured diagnostic events (bounded2 MiB snapshot), including fixed policy/path,
operation, requested/observed kHz, surrounding fields, errno and rollback outcome.
Readback events identify before/after edges. Open/write failures preserve errno
and original exception chaining; arbitrary exception text is not logged. Flush
is recorded as not-applicable because sysfs uses unbuffered `os.write`, not a
buffered stream. Version1 recovery snapshots remain readable. After reboot, do not replay a
stale snapshot. A changed setting/CPU topology or unavailable sysfs can make
restoration impossible: stop the experiment and report the precise incomplete
state, rather than broadening the write scope.

The trial's cleanup must finish successfully and all saved max values and
unchanged min/governor/EPP/boost/online CPUs, temperature, memory and the existing
service's health must pass the final observation before claiming success. Do not
run inference or compilation to test heat unless separately approved. Frequency
readback alone proves neither a wattage reduction nor a thermal improvement;
actual frequency samples may differ from requested policy ceilings.

## Fan and SMU investigation (not applied)

The visible DMI board name is `GMKtec`, not `AXB35-02`. Existing hwmon exposes
Tctl/edge but no fan RPM/PWM. EC identity/register map, original fan mode/levels
and a validated restoration path remain unknown. The
[cmetz driver at f62c2c2](https://github.com/cmetz/ec-su_axb35-linux/tree/f62c2c228959a08683273a26ef3afd8991e69f6d)
lists EVO-X2 but does not prove this BIOS/EC revision. Its curve is maintained by
a 1 Hz Linux worker, many EC read/write errors are unchecked, and unloading
writes AUTO to three fan modes. Loading/unloading is therefore not a read-only
probe. No module was added or loaded. Bosgame M5 register values/curves/RPM must
not be copied to this machine.

RyzenAdj's
[5775fc3 source](https://github.com/FlyGoat/RyzenAdj/tree/5775fc3e6dbb25c7030ee2d100a1bdd6e8bf2d0a)
contains Strix Halo support, but actual STAPM/fast/slow limits, currents and time
constants are not known here. Even its `--info` uses SMU requests, not plain
sysfs reading. No installation or SMU request was performed. A possible
`min(original,45 W)` shared APU budget is only a future proposal; it can also
reduce GPU performance and is distinct from the CPU frequency ceiling.

## Observed trial: safe abort, not a successful 3 GHz application

On2026-10-22 the authorized idle trial observed its baseline for60 seconds
(58 successful health/telemetry samples; sampled span59.99955 seconds). CPU Tctl
was30.5–33.25°C; minimum available memory17,197,817,856 bytes. The first apply
failed with only policy0's write intent journaled. The original implementation
reported `apply failed; snapshot limits restored` but did **not** retain the
underlying errno or immediate failed readback. There were **zero limited-state
samples**. Whether the cause was open/write rejection, frequency rounding, an
external controller or an implementation issue is unknown; no retry was made.

Read-only verification afterward compared all32 policies' entire saved fields:
no differences, all maxima5,187,500kHz/minima2,000,000kHz, boost1 and CPUs0–31;
health was normal. An additional read-only60-second full-snapshot hold passed
(58 samples, Tctl30.625–33.375°C, minimum available17,206,280,192 bytes, unchanged
swap, all maxima5,187,500kHz). The journal was `restored`.
[Machine-readable results](evox2-cpu-trial-result.json) preserve the failed attempt
and restoration separately from the improved diagnostic code. Visible `/sys` was read-write,
the attribute root0644 and writable by access checks; existing devbox was already
privileged with seccomp unconfined and effective root capabilities. No new
privilege was added. These observations do not suggest a simple read-only mount
or missing-capability explanation, but **do not prove driver write acceptance**.

The diagnostic improvements were tested offline after that abort, not by another
real write. A possible next experiment is one separately approved repetition of
the same bounded idle trial with these diagnostics; no new privileges, alternate
path, fan/SMU changes, workload or automatic retry. A success must include target
readbacks and successful restoration, not just a generic cleanup message.

## Offline verification

```sh
python3 test/evox2_cpu_limit_test.py
bats test/evox2-cpu-limit.bats
bats -r .
git diff --check
```

Fixtures use an in-memory backend, including partial/write-then-error failure,
interrupted transaction recovery, competing-setting refusal, private snapshots
and CLI confirmation. They never redirect a real apply to a fixture sysfs tree.
The default plan has also been exercised on the actual machine without writes.
