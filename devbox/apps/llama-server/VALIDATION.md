# Qwen3.8 validation and rollback

## Production baseline

The declaration in `../compose.anietta.yaml` is the starting point, not an old
Wiki command. It uses the existing uncensored i1-IQ4_XS target, f16 mmproj and
shared Q8_0 MTP head with `strix-prefill-opt/build-hip-rocm10`:

- Native 262144 context, unified KV, two slots, q8_0 K/V.
- Batch/ubatch 2048, `-lm none`, CPU per-layer token embedding.
- `--cache-ram 0`: no host-RAM prompt-cache copies. This does **not** disable
  prefix reuse inside a resident slot.
- Container `llama-server`, port 8082, reachable from the devbox at
  `http://llama-server:8082`, not devbox loopback.

The earlier 393216/YaRN configuration and RAM prompt cache caused OOM kills.
Do not restore them, or increase ubatch to 4096, based only on old throughput
numbers. Verify the actual process, binary commit, linked ROCm libraries and
memory usage before interpreting a benchmark. A checkout HEAD or image tag
alone does not identify the running executable/runtime.

## Offline regression tests (no GPU or network)

From the repository root:

```bash
python3 test/qwen38_smoke_test.py
bats test/qwen38-smoke.bats
```

`smoke.py` uses only the Python standard library. It **never contacts a
server**, starts a model or executes a tool. It generates bounded synthetic
requests or validates a saved non-streaming Chat Completions response from
stdin. Fixtures cover incomplete replies, missing Japanese, distinct thinking
paths, incorrect tool names and malformed/wrong-schema arguments.

## Approved small smoke test

**Obtain permission and a GPU timeslot before sending any completion request.**
Health alone can be checked without inference:

```bash
curl -fsS --max-time 10 http://llama-server:8082/health
```

After approval, run the following from the repository root, one case at a time.
Use `japanese`, `thinking-off`, `thinking-on`, then `tool` (no concurrent loop).
The example writes only synthetic prompts and their replies into a new private
directory; do not substitute private conversations or put credentials in a URL.

```bash
umask 077
out=$(mktemp -d /tmp/qwen38-smoke.XXXXXXXX)
case_name=japanese
python3 devbox/apps/llama-server/smoke.py request "$case_name" > "$out/request.json"
curl --fail --silent --show-error --max-time 120 \
  -H 'Content-Type: application/json' \
  --data-binary @"$out/request.json" \
  http://llama-server:8082/v1/chat/completions > "$out/response.json" &&
python3 devbox/apps/llama-server/smoke.py validate "$case_name" < "$out/response.json"
```

A nonzero curl/validator exit is **not** a successful smoke. Stop on errors;
do not automatically retry or restart the service. A client timeout need not
cancel inference: check health/activity and coordinate before the next case.
Retain responses privately only as long as needed; do not commit raw replies.

The validator requires `finish_reason=stop`, nonempty Japanese content and no
thinking tags in text replies. Thinking ON requires nonempty `reasoning_content`;
OFF requires it to be absent/empty. The tool case forces `get_temperature` and
requires `finish_reason=tool_calls` and the exact JSON arguments `{"city":"東京"}`.
It checks parser/schema compatibility, **not** autonomous tool selection or real
weather. The tool is never executed. Low-effort thinking is capped at 256 total
completion tokens: reaching `length` is a failed/inconclusive bounded test, not
proof that reasoning is unsupported. Do not silently increase the budget.
Japanese-character presence is a smoke heuristic, not an answer-quality grade.

All cases use temperature 0 and seed 42 for a functional comparison, not the
model's recommended creative sampling. Request fields unsupported by a runtime
must be recorded, not silently dropped to claim parity.

## Performance comparison (separate approval)

A smoke pass is not a performance or quality-equivalence result. Record:

- Exact target/draft/vision files, runtime commit and loaded libraries; context,
  slot count, KV type, ubatch, MTP, sampling and cache configuration.
- Fixed synthetic prompt hashes and actual token counts. Separate free Japanese
  generation from code rewrite and cold prompts from identical-prefix reuse.
- Prefill/decode from server timings, prompt/completion/cached token counts,
  speculation acceptance where available, wall duration and errors.
- Client streaming TTFT (first reasoning token **and** first content token
  separately). This non-streaming validator does not measure TTFT. Curl TTFB
  is not token latency.
- Host available RAM, swap, process RSS and GPU/GTT peak before/after. Do not
  add RSS and GPU allocations as independent pools on unified memory.
- Warmup, at least three measured repetitions, median and range. Progress
  from short prompts to 2K/8K, then separately approved 32K/128K workloads.

Use the same existing target quantization first when comparing prefill-opt,
latest upstream/halo-box and an alternative runtime. Halogen-specific MTP
assets require separate acquisition approval; a shared GGUF draft is not a
substitute. Compare its cache mode 1/cold mode 0 first; cache mode 2 does not
promise bit-identical cold/hit output. Model/quant changes, token dropping
(`spec-prefill`) and approximate cache modes belong in separate quality-change
experiments, not the same speedup table. Test Japanese, thinking, tools and,
when supported, vision and prefix reuse. PPL/KLD with a same-build control is a
separate potentially multi-GiB experiment; a short smoke cannot replace it.

## Apply and roll back (maintenance approval required)

Never start a second large model alongside production. `restart: always` means
killing the process alone can bring it back while a candidate starts. Obtain a
maintenance window and use the service lifecycle, not broad `pkill` commands.
Do not change GPU/OS settings, proxy configuration or published interfaces.

Before any approved change:

1. Save the exact current Compose file, image ID, executable/shared libraries
   (or immutable existing build), args and whitelisted runtime settings outside
   Git. Do not dump all container environment variables or private logs.
2. Confirm free disk/RAM and absence of a second large process. Preserve the
   existing target, mmproj and shared MTP files and the current prefill-opt
   checkout/build; rebuilding it in place destroys an easy rollback.
3. Change one variable in a separate candidate build/config. Render and inspect
   its Compose config privately, then stop only the approved service and verify
   memory is released before loading a candidate. Other apps remain running.
4. After testing, stop the candidate before restoring production. Health must
   recover, then repeat the approved smoke cases. Check restart count and memory.

For a saved known-good Compose file, the service-scoped restoration command is:

```bash
# Approval required; BASELINE_COMPOSE names the private saved declaration.
# The saved image/build must still exist and match the recorded baseline.
docker compose -f "$BASELINE_COMPOSE" up -d --no-build --pull never --force-recreate llama-server
```

Restoring the current `94461c7` build and its saved declaration is preferable to
falling back to the older `6994643` build. That old build cannot read shared MTP:
if explicitly approved as an emergency fallback, remove both `--spec-type
 draft-mtp` and `-md <shared-head>` together. Keep the memory-safe native context
and cache limits; do not copy the old 1M startup command. Do not call a rollback
successful until health and the approved content/thinking/tool checks pass.
