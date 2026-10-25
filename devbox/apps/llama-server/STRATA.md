# Strata trial on anietta

Experimental tooling, not a production switch. It builds
[Strata](https://github.com/Niko1221/Strata) v0.2.4 for the Strix Halo
(gfx1151) and serves the existing llama.cpp GGUF
`~/models/qwen3.8-flash-next/Qwen3.8-Flash-Next-Uncensored.i1-IQ4_XS.gguf`
(mradermacher's i1 IQ4_XS of `orcarouter/Qwen3.8-Flash-Next-Uncensored`)
through Strata's OrcaRouter path (`docs/ORCA.md`, `tools/iq_pack.py
--compat-bf16`). The GGUF is only read. Since 2026-10-25 the compose file
serves it this way (`--profile strix` below, `STRATA_ALLOWED_HOSTS` for the
names proxyd and the devbox use) with the CPU capped at 3 GHz; README.md says
how to go back.

## Result (2026-10-25)

Strata loaded the pack in 24 s at a 262,144-token context (available memory
steady at 18.8 GiB, swap flat) and answered the short gates (Japanese,
thinking off and on, auto tool, a three-turn tool chain, two pictures through
the CPU reader). The over-refusal set's thinking-off half answered 10 of 10
without a refusal, and no repetition loop was found in 43 replies. Decode was
36-45 tok/s on 512-token answers, 75-100 tok/s on tool calls.

Both runs stopped on the guard's temperature rule (95 °C for 10 s): the CPU
(k10temp) reached 98 °C while the GPU stayed near 53 °C, about 3 minutes into
decoding with the engine's default 15 CPU expert workers and about 1 minute
with `--pool-workers 8`. The rest of the trial (thinking-on refusals, the
Japanese set, long outputs, 8K/32K/128K prompts) did not run. A run with the
CPU capped is a separate decision.

With the CPU capped at 3 GHz and every expert in the GPU's cache
(`--write-config --profile strix`: `--expert-cache 24576 --mmap-experts`,
`--prefill 16384`, `--lookup-chain 3 --mtp-q4 all --mtp-window 8192` and the
switches of `docs/STRIX_HALO.md` sections 4-5, several of which round
differently) the CPU pool has no work and the trial ran through (37 requests,
max 77 °C, available at least 41 GiB, swap at most 2 GiB):

| Prompt | Prefill | TTFT | Decode |
|---|---|---|---|
| 8K cold (5,990 tokens) | 1,244-1,304 tok/s | 4.6-4.8 s | 52 tok/s |
| 32K cold (31,704) | 1,365-1,380 tok/s | 23 s | 48-51 tok/s |
| 128K cold (125,728), 3 runs | 1,302-1,317 tok/s | 96 s | 49-53 tok/s |
| 128K warm (125,721 reused) | | 2.7 s | 46 tok/s |

The same capped run with the exact defaults (RAM arena, 12,000 cache slots,
`--prefill 512`) read prompts at 332-348 tok/s (128K TTFT 378 s). The needles
were answered at every length, the thinking-on over-refusal half had no
refusal, and the long outputs had no loop. Uncapped, the strix profile is not
measured yet.

Serving it, run by hand: the cap is `evox2-cpu-limit.py snapshot` then `apply`
(all 32 CPU max to min(original, 3 GHz)), kept while Strata serves and lifted
by `restore` from the same snapshot or by a reboot. It is not persisted, so
after a reboot `restart: always` starts Strata uncapped until it is applied
again.

API: `/v1/models` names the config's `model_name`; `/health` says `ok` before
the engine is up (`loaded: true` is the ready signal);
`chat_template_kwargs.enable_thinking` and `reasoning_effort: none` work;
`tool_choice` auto, forced and `required` return tool calls; `json_schema`
and `json_object` return JSON (checked only as one object without the
`jsonschema` package); `logprobs` is ignored (a client asking for it gets none); `tool_choice: "none"` offers no tool; `stream_options.include_usage`
adds a usage chunk.

## Fixed inputs

- Strata `96ca4383c7b05a8a3e6064c65d9e9977d4b3bb59` (v0.2.4) in
  `~/src/github.com/Niko1221/Strata`, with llama.cpp `3cf03257` (the revision
  `third_party/ggml/VERSION.txt` pins) in `third_party/llama.cpp` and a `.venv`
  from `requirements.txt` and `requirements-build.txt`.
- ROCm 7.14.1 for gfx1151 from AMD's TheRock tarball, sha256 `c40e8f2b...`,
  extracted to `~/opt/strata-rocm/install`. The system ROCm is not used: the
  guard runs everything with only that SDK and the venv on `PATH` and
  `LD_LIBRARY_PATH`, and the hipBLASLt table `tools/hip/gfx1151-hipblaslt-100401.txt`.
- The engine is configured once by hand (`docs/STRIX_HALO.md` section 2 with
  `-DSTRATA_GGML_DIR=<checkout>/third_party/llama.cpp`), and the CPU picture
  reader by `cmake -S tools/vision -B build-vision -DSTRATA_PORTABLE=OFF`.
- The pack (`iq_pack.py --compat-bf16`, 363 small projections rounded to
  BF16, `attn_qkv`/`attn_v` Q5_K served from the GGUF) and the MTP draft head
  (`mtp_fetch.py` 5.2 GB from the original checkout, `mtp_pack.py --experts
  q2_0`, `mtp_rt.py`) as `docs/ORCA.md` says.
- Only exact defaults: none of the opt-in switches of
  `docs/STRIX_HALO.md` section 5, which change the output bits.

## Guard

`strata_guard.py` reuses the pinned capbuild monitor and
`kyojin_infer_guard.py`'s long memory gate (95 °C for 10 s, available < 2 GiB
for 10 s, swap > 6 GiB, swap-in thrashing, OOM/cgroup events, new kernel GPU
faults). The build and the server run as the user; a `STOP` file in the run
directory ends either.

```sh
python3 devbox/apps/llama-server/strata_guard.py --write-baseline /abs/baseline.json
# build: production keeps running; all 32 CPU max min(original, 3 GHz) for the build, restored after
sudo python3 devbox/apps/llama-server/strata_guard.py --confirm-single-run --mode build --cpu-cap --jobs 4 \
  --strata ~/src/github.com/Niko1221/Strata --sdk ~/opt/strata-rocm/install \
  --directory /abs/new-private-output --references /abs/preserved-notes --root /abs/run-root \
  --progress /abs/progress.md --baseline /abs/baseline.json
python3 devbox/apps/llama-server/strata_guard.py --write-config /abs/serve.json --strata ... --pack ... \
  --gguf ... --mtp .../rt --mmproj ... --log /abs/new-private-output/engine.log --ctx 262144 --expert-cache 12000
docker stop llama-server
sudo python3 devbox/apps/llama-server/strata_guard.py --confirm-single-run --mode serve --config /abs/serve.json \
  --pack ... (the rest as for the build, without --cpu-cap)
git -C ~/dotfiles show ef00aa7:devbox/apps/compose.anietta.yaml | \
  docker compose -f - --project-directory ~/dotfiles/devbox/apps up -d --no-build llama-server
```

- build: the monitor waits for 60 s under 85 °C first (capbuild's idle-GPU
  condition does not apply while production serves), checks that every ninja
  keeps the given `-j`, and that production stays running.
- serve: production must be stopped and 100 GiB available. The server listens
  on 127.0.0.1:18083; `strata_trial.py` sends its fixed requests (at most
  100, 5,400 s): the Kyojin trial's gates and over-refusal set, the Japanese
  set, API probes, four 1,536-2,048-token outputs checked for repetition
  loops, and 8K/32K/128K prompts with the needles. Strata has no `/tokenize`,
  so the long prompts are sized from the 8K request's prompt tokens. Wait for
  the guard to exit before starting production again: its release check
  reads the temperature too.

## Offline verification

```sh
python3 test/strata_guard_test.py
python3 -m py_compile devbox/apps/llama-server/strata_*.py
git diff --check
```
