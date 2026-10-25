# Kyojin isolated trial

Experimental tooling, **not a production switch**. Keep the current container,
image, build, libraries and model files; never prune them to make room.

## Fixed inputs and dependencies

- Engine: [e09322da7209331c57e2a79cfc30d120f0299154](https://github.com/Yamz-Labs/kyojin/tree/e09322da7209331c57e2a79cfc30d120f0299154).
- Model: `yamz-labs/Qwen3.8-Flash-Next-EXL3-Yamz`, revision
  `247ef39b06ff0b0fcba76026429e191b44e0e1f8`, excluding `assets/`:
  95,370,160,976 bytes. Engine feasibility must precede this download.
- [PR164](https://github.com/yuanying/dotfiles/pull/164): fixed v2/gfx1151
  50-wheel selection, acquisition hashes and strict RECORD checks. AMD hashes
  are locally acquired SHA256, not independently published attestations.
- [PR163](https://github.com/yuanying/dotfiles/pull/163): strict artifact verifier,
  source SHA256 `3a12637c49b98c5c33f8623e2ee44f5d9a165b083b2505f9a3c19028c2cfddce`.
- [PR162](https://github.com/yuanying/dotfiles/pull/162): `stream_metrics.py`,
  required by the live adapter, SHA256
  `626a173a461267954275ecc85c34509ad74279d4581c17f0fd308d7f346c07e3`.
- [PR160](https://github.com/yuanying/dotfiles/pull/160): frozen corpus and
  comparison protocol; [PR156](https://github.com/yuanying/dotfiles/pull/156):
  existing smoke generator/validator. These unmerged implementations are not
  duplicated here. Supply their exact preserved references explicitly.

## Deployment and safety tools

`kyojin_trial.py <fixed-sdk-wheel>` streams the nested SDK tar without
extracting or executing it. It rejects escaping/absolute paths, duplicate
members, unsupported types, writes through links and link cycles. Relative
links to sibling SDK packages are allowed **within the isolated site-packages
root**, not an arbitrary host SDK. Check actual deployed link resolution too;
a containment PASS does not prove all targets exist or satisfy native ABI.

`qwen_stream_live.py` sends one local synthetic streaming request, with no
retry. Require `stream:true`, `max_tokens` from 1 to 256 and a private directory
for its exclusive mode0600 raw SSE file. Arguments: `--collector`, `--url`,
`--request`, `--raw`. Only loopback and the existing `llama-server` hostname
are allowed. It timestamps received bytes with `monotonic_ns` and delegates
schema/arrival metrics to the pinned collector. Stdout is body-free JSON.
Header latency is not TTFT. A timeout does not establish server cancellation;
check the job before restoring another model. This tool does not establish
quality, cache state, actual prompt tokens or request-budget compliance.

`qwen_trial_guard.py` launches and monitors one command after confirming the
specified baseline container is exited and available memory is at least
100 GiB. Arguments: `--baseline-container <verified-id>`, `--telemetry <new-file>`,
`--log <new-file>`, `--max-seconds <limit>`, optional `--ninja-jobs 1`, then
`-- <command>`. CPU/GPU temperatures, host available/swap, GPU/GTT counters,
child RSS and visible cgroup counters are sampled once per second. UMA counters
must not be summed as independent RAM allocations. Cgroup values describe the
visible execution cgroup, not necessarily just the candidate.

Stops on available memory below8 GiB for two samples, swap growth over512 MiB,
95°C for10 seconds, critical minus5°C, missing temperature, cgroup event delta,
or elapsed-time limit. Compiler parallelism can be verified from actual ninja
arguments. SIGTERM targets only tracked descendants, including hipcc's separate
process groups; SIGKILL follows a20-second grace only for those same identified
processes. PID start times protect against signalling reused PIDs. The guard
waits for tracked descendants to exit before returning. A stuck descendant is a
hard failure: **do not load the baseline on top of it**. GPU reset/error logs
and external service restarts still require separate observation; this is not
an exhaustive hardware-fault detector.

Keep telemetry/log files private. Do not alter fan, EC, IOMMU, driver, host
ROCm, governor, power or publication settings to pass a gate. A thermal abort
is a result, not permission to retry automatically. The first build with four
jobs hit CPU Tctl98.25°C for10 seconds and was stopped; the GPU was idle.
Exactly one continuation was authorized at one job after60 seconds below85°C.
The measured cooldown lasted60.145 seconds, maximum32.125°C. Actual ninja
arguments were `-v -j 1`. That continuation also stopped thermally after264
samples /263.79 seconds: maximum98.625°C, final hot interval10.030 seconds
(11 consecutive samples at least95°C). Minimum available memory was118.79GiB;
GPU busy remained0 and no cgroup OOM/event delta occurred. All tracked compiler
descendants exited. No third build, threshold relaxation, OS tuning or model
body download followed. This establishes a thermal feasibility blocker under
the approved safety envelope, **not** a compiler/ABI defect or inference result.

## Observed installation scope

In a dedicated Python3.12.10/glibc2.39 venv, the51 local fixed wheels installed
with no-index/no-deps/require-hashes; `pip check` passed. The generated rocm
wheel used explicit `ROCM_SDK_TARGET_FAMILY=gfx1151`, offline setuptools81,
wheel0.48 and packaging26.3;22,786 bytes, SHA256
`50c2f3cc4e969445d4c2edcf2df6fc2c9cbf2be02aa92d067cf3027604a8a634`.
Its14 standard RECORD entries and generated metadata passed verification.
`rocm-sdk init` expanded only the isolated venv. Actual deployed links had
zero escapes and one dangling unused AMD SMI library link. No package repair
or host fallback was performed.

Torch2.12.0a0/ROCm7.13.60980 imported and a16×16 GPU matrix multiplication
returned4096 on gfx1151 with the matching candidate SDK HSA preload. This does
**not** prove engine build, model loading, quality or benchmark success.
License scope is internal, non-redistributed testing. Preserve dependency
notices and Qwen Community License1.0; incomplete binary/source notice mapping
remains a redistribution concern, not evidence of native compatibility.

## Reproduction boundaries

The successful dependency steps were:

1. Rehash every selected local wheel against PR164's fixed selection, excluding
   all rejected multi-arch AMD wheels. Create an isolated Python3.12 venv and
   install only local setuptools81.0.0/wheel0.48.0/packaging26.3, no resolver.
2. Safely extract the fixed17,595-byte rocm sdist. Use explicit
   `ROCM_SDK_TARGET_FAMILY=gfx1151`, hidden HIP/CUDA devices, isolated `TMPDIR`,
   and `python -m pip --isolated wheel --no-index --no-deps
   --no-build-isolation --no-cache-dir -w <isolated-wheel-output> <rocm-source>`.
   Validate generated METADATA, standard RECORD and SHA256 before installation.
3. Build a local-path/hash requirements file for those51 packages (generated
   rocm included). Install with `python -m pip --isolated install --no-index
   --no-deps --no-cache-dir --require-hashes -r <reviewed-local-lock>` and run
   `pip check`. This generated lock is machine-local; PR164's selection alone
   is not that installable lock.
4. Audit the original fixed devel wheel with `kyojin_trial.py`, then run the
   isolated venv's `rocm-sdk init`. Inspect actual deployed links under the
   isolated site-packages root, preserving the recorded dangling AMD SMI link.
5. For the engine, set `EXL3_VENV=<isolated-venv>`,
   `EXL3_ROCM_SDK=<venv>/lib/python3.12/site-packages/_rocm_sdk_devel`,
   `TORCH_EXTENSIONS_DIR=<isolated-cache>`, `TMPDIR=<isolated-tmp>`,
   `PIP_NO_INDEX=1`, `PIP_NO_DEPS=1`, `PIP_NO_CACHE_DIR=1`,
   `PIP_DISABLE_PIP_VERSION_CHECK=1`, and `MAX_JOBS=1`. In the fixed engine
   checkout, source `tools/strix_halo/env.sh` and invoke `bash build.sh`
   **only through the guard after explicit continuation authorization**.
   `--ninja-jobs 1 --max-seconds 3600` verifies actual parallelism and time.

These are recorded commands, not authorization for another build. Both actual
build attempts failed the thermal gate; no third attempt or model download is
part of this result. Before any later authorized continuation, confirm old
compilers exited, GPU idle, memory gates and temperature below85°C for60 seconds.

## Comparison status

| Observation | Current IQ4_XS/shared MTP | Kyojin EXL3 |
|---|---|---|
| Runtime identity | actual core-10.0 HIP7.15.26333/HSA1.21 | isolated SDK7.13 / torch HIP7.13.60980 |
| Native initialization | existing server health OK before stop | torch import and small matmul PASS |
| Engine build | retained existing binary | two thermal stops; build incomplete |
| Candidate model acquired/loaded | existing files retained | neither acquired nor loaded |
| Comparable TTFT/prefill/decode | not measured in this trial | not measured |
| Quality/tool/vision/needle/preset OFF/ON | not measured in this trial | not measured |
| Long context/parallel/cache equivalence | not measured in this trial | not measured |

Previous short smoke results are references, not substitute benchmark results.
No speedup, quality parity, adoption or permanent switch is claimed. Future
build continuation requires a separate decision about the thermal blocker;
these tools must not automatically relax a threshold or repeat a stopped run.

## Restoration contract

Identify the actual Compose project/service/container before stopping anything.
Save only selected runtime metadata, whitelisted environment, Compose,
entrypoint, mapped binary/library hashes and existing model paths/sizes in a
private directory. Retain the actual container and image. Stopping an identified
Compose service and subsequently using `docker compose ... start <service>`
reuses that container without build or pull; do not substitute an `up` operation
that may recreate it from drifted declarations.

The observed baseline used HIP/HSA from **core-10.0**, not the currently declared
10.1 image. Preserve this difference. After service stop, available memory rose
from2.51GB to131.24GB; GTT fell from89.03GB to18.6MB, satisfying the100GiB absolute
and60GiB recovery gates. Before stopping, memory was already below the8GiB
threshold, so no benchmark request was sent. Health and four approved smoke
cases, restart/OOM counters and memory must be checked after restoration before
claiming restoration success. If memory remains unsafe, report that limitation
rather than forcing inference or changing configuration.

**Observed restoration succeeded.** Same-container Compose `start` restored
health and five consecutive healthy observations in58.20 seconds, with18.23GB
available (the initial2GB shortage did not recur after restart). The four approved
serial smoke cases each passed once, with no retry and256-token/180-second caps:

| Restoration smoke | Prompt/output tokens | Finish | Wall seconds |
|---|---:|---|---:|
| Japanese | 27/41 | stop | 1.650 |
| Thinking OFF | 30/4 | stop | 0.308 |
| Thinking ON, low | 59/173 | stop | 3.815 |
| Forced tool JSON | 302/26 | tool_calls | 1.397 |

Tool name/arguments/finish reason and thinking separation were checked by the
preserved PR156 validator; no real tool was executed. Smoke memory minimum
17,261,314,048 bytes (16.08GiB), temperature maximum53°C, swap delta−1,093,632
bytes, no safety breach. Final health OK, same container/image and unchanged
binary/library hashes; actual core-10.0 HIP/HSA preserved. Manual start reset
Docker's restart counter from8 to0; it remained0 after smoke, OOM false and
restart policy always. Observed post-smoke server cgroup current40.11GB,
peak53.71GB, OOM counters0, process RSS31,229,176KiB. These UMA/cgroup/RSS
indicators are separate, not additive or isolated inference allocator peaks.

[Machine-readable results](kyojin-trial-result.json) retain the measured
installation, thermal and restoration fields without raw request/reply bodies.
The restoration smoke is **not** a candidate comparison or TTFT benchmark.

## Offline tests

```sh
python3 test/kyojin_trial_test.py
python3 test/qwen_stream_live_test.py
python3 test/qwen_trial_guard_test.py
bats test/kyojin-trial.bats
bats -r .
git diff --check
```

Fixtures exercise containment, live arrival forwarding and safety thresholds,
including terminating a descendant in a separate process group. They do not
claim hardware or candidate-model acceptance.
