# Offline SSE arrival metrics

`stream_metrics.py` is a standard-library collector and **offline-only CLI**.
It has no HTTP client, model loader, tool executor, retries, or automatic experiment
runner. Fixture success is not a benchmark or a candidate quality pass.

This is independent of [PR156's response validator](https://github.com/yuanying/dotfiles/pull/156)
and [PR160's frozen comparison plan/corpus](https://github.com/yuanying/dotfiles/pull/160).
Neither unmerged implementation is copied here. Use those reviewed versions for
request/corpus generation and quality validation after integration/approval; this
collector neither changes their hashes nor assembles their prompts.

## Local verification

```bash
python3 test/qwen_stream_metrics_test.py
bats test/qwen-stream-metrics.bats
python3 devbox/apps/llama-server/stream_metrics.py replay < synthetic-arrivals.json
python3 devbox/apps/llama-server/stream_metrics.py summary < same-cell-results.json
```

Replay input is JSON with `synthetic: true`, integer `start_ns`, `headers_ns`,
`end_ns`, HTTP `status`, and `chunks: [{at_ns, base64}]`. Each base64 value is one
transport read of synthetic SSE bytes. Times share one monotonic epoch; they are
not SSE server timestamps. The tests construct safe Japanese/reasoning/tool,
heartbeat, fragmented UTF-8, multiline SSE, coalesced event and failure fixtures.
A saved untimed stream cannot recover real arrival times. Do not label replay
results as measurements of a running model.

CLI limits: one fixture (zero HTTP requests), 8 MiB input, 4 MiB decoded stream,
180 seconds elapsed, 256 reported completion tokens. Optional
`--timeout-seconds` and `--max-output-tokens` set approved per-request bounds.
Timeout is checked against supplied arrival/end times, not replay CPU time.
No token count is inferred from chunks, characters, tool fields or bytes. Missing
usage means the generation budget cannot be verified by this collector. Every
measurement error returns exit 1 and a constant error code; discard that run and
stop the experiment, do not silently aggregate it. Ctrl-C aborts without replay.
No raw request, response, headers, IDs, model names or server error message is
printed or included in metrics. Only synthetic inputs belong in fixtures.

## Schema v1

All JSON `null` values mean **N/A**, not zero. Successful output:

| Key | Definition / units |
|---|---|
| `schema_version` | integer 1 |
| `ttft_seconds.{reasoning,content,tool,any}` | send start to first complete SSE event carrying a nonempty string in that category; `any` is earliest category |
| `header_seconds` | send start to HTTP response headers; not a first token or HTTP-body TTFB |
| `final_seconds` | send start to choice 0's finish_reason event (stop or tool_calls) |
| `done_seconds` | send start to `[DONE]` event, possibly after usage |
| `wall_seconds` | send start to transport end/close after final and DONE |
| `finish_reason` | allowlisted stop/tool_calls; length/error is failure |
| `usage` | allowlisted integer prompt_tokens/completion_tokens/total_tokens, or null |
| `server_timings` | allowlisted numeric prompt_n/prompt_ms/predicted_n/predicted_ms/cache_n/draft_n/draft_n_accepted, or null; server units retained, ms and counts |
| `client_decode_tokens_per_second` | completion_tokens / (last nonempty generation event arrival − first); null if usage missing or span zero |

Reasoning accepts `reasoning_content` or `reasoning`; content accepts `content`.
Tool TTFT requires a nonempty function name/arguments fragment, not just a call
ID/index/type. Role-only, empty strings, comments/heartbeats, headers, usage and
finish-only events do not count. Whitespace strings are nonempty. Tool arguments
remain untrusted text and are never executed. Multiple choices, malformed types,
HTTP errors, error events, invalid UTF-8/JSON, nonmonotonic clocks, byte/generation
budget excess and truncated/missing final/DONE fail closed. A well-framed empty
response may have all TTFTs null: quality validation is a separate gate.

Client decode is an approximate *arrival-span average*, with reasoning+content+
tool tokens combined as reported by the server's completion_tokens. It includes
the first event's tokens in the numerator; batching/MTP and network buffering
bias it. It is not per-token latency, a tokenizer count, or server decode speed.
If a runtime reports a different completion-token scope, record that separately
and do not compare this rate. No prefill rate is fabricated from wall time.
Server prefill/decode can be computed only from the recorded matching counts/ms;
server fields absent from the allowlist need a reviewed schema extension.

`summary` takes a JSON array of successful v1 results from **one externally
verified cell** (same runtime/revisions/prompt/template/context/cache/think/MTP).
For each TTFT, wall and client decode metric it emits n, missing, median, min,
max. Missing samples are excluded, counted explicitly, never imputed. It does
not group or validate experiment provenance; retain errors separately and never
mix successful subsets to hide failures. Three repetitions and quality gates
remain obligations of the comparison plan.

## Contract for a future live adapter (not implemented or approved here)

Capture `time.monotonic_ns()` immediately before the sole explicit send, after
headers, after each bounded byte read and after close. Call `Collector.headers`,
`feed`, `finish` respectively. Do not timestamp only after collecting a full
response; a transport that buffers an entire event/response biases arrival TTFT.
The supplied times in tests simulate this contract; there is no real HTTP
transport validation yet.

A live CLI must require an explicit reviewed request, local endpoint and approval
budget; `stream=true`, `n=1`, an explicit generation cap, max requests=1,
retries=0, no redirect/reconnect, bounded reads, connect/read **and total**
deadlines, and external abort/resource-watch cancellation. Send nothing by
default. Do not log auth/headers or input/output bodies; private opt-in evidence
is separate. Stop on the first HTTP/schema/quality/timeout/resource gate failure.
Token usage arriving at the end cannot enforce a server generation limit, so the
request cap and server-effective cap must be confirmed before sending. Client
close/cancellation does not establish that the GPU job stopped: confirm job
termination before recovery. No service operation or GPU work is part of this
collector. Host UMA/temperature/peak telemetry, tokenizer/template verification,
request-count accounting and quality validation still need the execution gate.

## Dependency preflight

[kyojin-preflight.json](kyojin-preflight.json) records a **non-installable**
metadata projection for engine e09322d and model rev247ef39b: Linux x86_64,
CPython 3.12, gfx1151, upstream's pinned alternative multi-arch ROCm stack.
It is not a requirements lock or permission to install. All 17 requirements.txt
entries plus AMD/build/transitive candidates have URL/version/publisher SHA256
and compressed size claims (55 artifacts, 2,412,447,088 bytes, about 2.247 GiB).
All artifact HEADs returned 200; no wheel bodies were fetched. The explicitly
approved 27,362-byte rocm sdist alone was fetched and locally hash-verified.
Forty-five PyPI artifact hashes/sizes also match version-specific JSON metadata.

The fixed engine already includes `uv.lock` (SHA256
`a0de566b8231a0fe387a655e08707a0317c59b5d6e49e08f3f8970f33255442e`).
Its ROCm cp312 hashes are hand-backfilled publisher claims, not local verification.
The projection evaluated dependency markers for Linux/Python 3.12 and the
`extra-9-exllamav3-rocm` fork; wheel tag selection used devbox CPython 3.12.10
`sys_tags` (glibc 2.39), not a verified service host. `wheel==0.48.0` was absent
from the source lock and added from exact-version PyPI JSON, including its
packaging dependency. Optional eval/examples/CUDA/Windows extras are excluded.

**Blocking:** `rocm==10.1.0a20260822` has only an sdist, no public wheel.
Its approved read-only archive review confirmed `setuptools.build_meta` with
`setuptools>=70.2.0`; propose already-listed setuptools84.0.0/wheel0.48.0/
packaging26.3 as build pins. PKG-INFO's selected dependencies match core/devel/
device-gfx1151/libraries pins. But metadata is dynamic: setup.py imports
_dist_info.py and can run `offload-arch`, falling back to gfx1010. A future
CPU-only/offline build must explicitly set `ROCM_SDK_TARGET_FAMILY=gfx1151`,
forbid unlisted dependencies and review the generated wheel/hash/METADATA before
installation. No source/backend was executed and no files were extracted.
Static inspection is not proof of backend-hook closure or reproducibility.

The 10 AMD wheel `.metadata` URLs returned 404, so actual Requires-Dist/license
closure still cannot be independently validated via PEP658. Do not download huge
wheels, run pip install/download, initialize SDK, compile, import torch or run
env.sh --check to bypass this gate. The original v2/gfx1151 nightly recipe is
mutable; it is not the same stack as this upstream-pinned multi-arch first
proposal and is not silently substituted.

### Minimal next approval proposal (not performed)

1. Fetch **only** the 54 fixed wheels remaining in the snapshot, verify their
   hashes, read ZIP METADATA/WHEEL/license manifests safely, and stop on any
   missing dependency, incompatible tag or license condition. Total list is
   2,412,447,088 bytes including the already-reviewed sdist; remaining wheel
   bytes are 2,412,419,726. Propose a 3 GiB transfer/staging cap, no retries or
   extra resolver downloads. This is an acquisition/metadata gate, not install.
2. Only after that review, approve a fresh candidate CPython3.12 venv plus a
   CPU-only rocm meta-wheel build with the above pinned build set, explicit
   gfx1151 environment, no network/GPU, no build isolation/resolution and no
   other source execution. Inspect generated metadata/hash, then install only
   the reviewed local wheel set without index/network and run dependency checks
   without importing torch. Propose a hard 20 GiB candidate dependency workspace
   cap and 50 GiB free-space reserve; stop/reapprove rather than exceed. This
   cap is not an estimated expansion size or permission for SDK init.

These are sequential approvals, not an unconditional pip command. Record the
installer/venv bootstrap version (current preflight interpreter has pip25.0.1)
and confirm target Python headers/glibc before installation. Any missing bootstrap
artifact requires another explicit pin/review, not network fallback. No model
DL, SDK expansion, engine extension/build/JIT, GPU probe, launch, service stop or
OS change is included. Those remain separate approvals after the full lock and
G0/G1. Keep the broader 260 GiB model/runtime plan provisional.

Compressed bytes do not bound SDK expansion (upstream says about 12 GB), venv,
source/extension build, JIT/cache or peak disk/RAM. Keep the plan's 260 GiB plus
50 GiB safety allowance provisional. Driver/HSA/compiler/header/glibc compatibility
and loaded runtime are unverified. Fixed install/env.sh warns about bundled HSA
segfaults, requires native gfx1151/ROCm >=7, no HSA_OVERRIDE_GFX_VERSION, separate
build-only SDK paths and bounded MAX_JOBS. Its --check performs GPU matmul and
has **not** been run. Host ROCm/toolchain/OS changes are not a fallback.

Engine MIT and model Qwen Community License 1.0 do not license the entire SDK
bundle. PyPI license expressions/classifiers are recorded; some are unspecified,
and AMD bundled notices need review. Model card requires separate licensing for
certain commercial Model-as-a-Service/AI Work Assistant uses; match intended
use before deployment. Conversion tooling is unpublished. Preset OFF/ON is a
separate output-distribution condition, not equivalence to abliterated IQ4_XS.
No candidate was installed, measured, adopted, or exposed.

Sources (retrieved 2026-10-22):
- [fixed install](https://github.com/Yamz-Labs/kyojin/blob/e09322da7209331c57e2a79cfc30d120f0299154/doc/install.md), [pyproject](https://github.com/Yamz-Labs/kyojin/blob/e09322da7209331c57e2a79cfc30d120f0299154/pyproject.toml), [uv.lock](https://github.com/Yamz-Labs/kyojin/blob/e09322da7209331c57e2a79cfc30d120f0299154/uv.lock), [requirements](https://github.com/Yamz-Labs/kyojin/blob/e09322da7209331c57e2a79cfc30d120f0299154/requirements.txt), [env.sh](https://github.com/Yamz-Labs/kyojin/blob/e09322da7209331c57e2a79cfc30d120f0299154/tools/strix_halo/env.sh)
- [AMD rocm index](https://rocm.nightlies.amd.com/whl-multi-arch/rocm/); exact artifact and PyPI metadata URLs in JSON
- [fixed model card/license](https://huggingface.co/yamz-labs/Qwen3.8-Flash-Next-EXL3-Yamz/blob/247ef39b06ff0b0fcba76026429e191b44e0e1f8/README.md)
