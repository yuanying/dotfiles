# Kyojin v2/gfx1151 validation

This is a candidate validation record, not a production configuration or an
installer. Engine: `e09322da7209331c57e2a79cfc30d120f0299154`.
The official [install guide](https://github.com/Yamz-Labs/kyojin/blob/e09322da7209331c57e2a79cfc30d120f0299154/doc/install.md)
recommends AMD's `v2/gfx1151` index. Its multi-arch alternative produces a
different dependency set and can produce slightly different text.

## Selection and trust boundary

The v2 torch and SDK were selected from **ROCm 7.13.0a20260411 together**, not
independently from each index's latest entry. CPython 3.12/Linux x86_64 is the
static target; native driver/HSA/compiler compatibility is not established by
wheel tags.

| Package | Version | Compressed bytes |
|---|---|---:|
| torch | 2.12.0a0+rocm7.13.0a20260411 | 712,336,644 |
| triton | 3.7.0+git18f89f64.rocm7.13.0a20260411 | 638,324,683 |
| rocm-sdk-core | 7.13.0a20260411 | 409,098,742 |
| rocm-sdk-libraries-gfx1151 | 7.13.0a20260411 | 282,682,436 |
| rocm-sdk-devel | 7.13.0a20260411 | 1,710,689,059 |
| setuptools | 81.0.0 | 1,062,021 |

New wheel bodies total **3,754,193,585 bytes (3.496 GiB)**. Torch requires
`setuptools<82`, so the previous multi-arch snapshot's 84.0.0 is not compatible;
81.0.0 satisfies both torch and the rocm build backend (`>=70.2.0`).
The matching rocm sdist is 17,595 bytes; its statically reviewed metadata selects
core and, through torch's `rocm[libraries]`, libraries-gfx1151. Devel is separately
selected. Device/profiler extras are not requested. It also declares a self-edge
`rocm==7.13.0a20260411`. A generated wheel still needs independent inspection.

The AMD index links do not publish SHA256 or PEP658 metadata. `.metadata` HEAD
returned 404 for torch and devel. **Publisher-hash comparison is unavailable**;
S3 multipart ETags are not SHA256. An HTTPS acquisition with an unchanged ETag
and a locally saved SHA256 pins the observed bytes, but is not independent
publisher-hash verification. PyPI setuptools does publish SHA256. None of these
checks proves native execution safety or full license compliance.

The previous nonconformant multi-arch AMD wheels are not installed, repaired,
repacked, or reused. Compliant PyPI artifacts can be independently reverified;
that does not promote the rejected AMD set to PASS.

## Small metadata preview

`wheel_metadata.py` reads only bounded ZIP metadata over HTTPS Range requests:

```sh
python3 devbox/apps/llama-server/wheel_metadata.py \
  'https://rocm.nightlies.amd.com/v2/gfx1151/rocm_sdk_devel-7.13.0a20260411-py3-none-linux_x86_64.whl' \
  /absolute/path/outside/git/sdk-preview.json
```

The output must not already exist. This command makes network requests but does
not install, extract, import candidate code, initialize an SDK, or touch a GPU.
Budget: 4 MiB of response bodies/wheel, 2 MiB/request, 64 Range requests/wheel.
HTTP206, exact Content-Range/Content-Length/ETag and identity encoding are
required; HTTP200 is closed without reading the body. Redirects and retries are
not implemented. ZIP paths/duplicates and selected-member expansion are checked.
This is **only a preview**, not whole-wheel SHA256, RECORD, dependency closure,
license inventory, or a safe-to-install verdict. The initial five-wheel preview
used 1,835,961 body bytes across 48 Range requests.

Full static inspection uses the preserved [PR163 verifier at 4370d6a](https://github.com/yuanying/dotfiles/blob/4370d6a8e18ed6bb78db50059192cc1104dddfec/devbox/apps/llama-server/verify_artifacts.py);
it is not copied into this change. [kyojin-v2-selection.json](kyojin-v2-selection.json)
pins 50 selected wheels (44 prior compliant PyPI artifacts plus these six) and
the source-only rocm package. It is deliberately **not an installable lock**:
rocm has not been built, and native/notice gates remain separate. The AMD
`local_sha256` fields are acquisition hashes, not publisher attestations.

### Scoped SDK streaming inspection

The initial unchanged-verifier run inspected 49 wheels: 22,955 standard RECORD
content hashes matched, zero RECORD/security issues and zero dependency issues.
SDK devel was not inspected: its `_devel.tar` member is 9,252,270,080 bytes,
above that verifier's 8 GiB/member limit (compression ratio 5.41, not an expansion
anomaly). This resource-limit failure is retained, not reported as PASS.

An explicitly approved **resource-only** override permits that pinned SDK's tar
member and tar regular-payload aggregate up to 12 GiB, using streaming only.
Other ZIP members/internal tar members retain 8 GiB limits. Standard RECORD,
content hash, CRC, path/link/type checks, 32 GiB ZIP aggregate, entry/notice/text
budgets, and non-extraction/non-execution behavior are unchanged.

`verify_v2_sdk.py` checks the reference source SHA256 and the exact SDK wheel
name/size/SHA256 before deriving a verifier with exactly two scoped substitutions.
The reference file is never changed, and no wheel is repaired or repacked.
Source hashes:

- Original: `3a12637c49b98c5c33f8623e2ee44f5d9a165b083b2505f9a3c19028c2cfddce`
- Derived: `78c1734fa2c2c55bb9173ce2e63383600b2c587cd65d131315463381d527dbb1`

Given the preserved hash-pinned reference and already acquired wheel:

```sh
python3 devbox/apps/llama-server/verify_v2_sdk.py \
  --reference /absolute/path/to/reference-artifacts/verify_artifacts.py \
  --wheel /absolute/path/to/wheels/rocm_sdk_devel-7.13.0a20260411-py3-none-linux_x86_64.whl \
  --derived-source /absolute/path/outside/git/sdk-scoped-verifier.py \
  --report /absolute/path/outside/git/sdk-verification-full.json
```

The derived source/report must not already exist. This command is offline;
it executes the hash-pinned verifier, never the candidate package. Keep the full
notice/link report outside Git. An override permits inspection, not installation.
The prior preflight, corpus, collector, and smoke tools remain separate dependencies ([PR162](https://github.com/yuanying/dotfiles/pull/162),
[PR160](https://github.com/yuanying/dotfiles/pull/160),
[PR156](https://github.com/yuanying/dotfiles/pull/156)).

For the other 49 wheels, use the **original** verifier (no override), with prior
and new wheel directories kept separate. This offline example reproduces the
integrity/RECORD/dependency projection; it executes only the hash-pinned verifier
and uses the existing `pip._vendor.packaging`, without installing anything:

```sh
python3 - /path/to/reference-artifacts/verify_artifacts.py \
  /path/to/prior-compliant-pypi-wheels /path/to/new-v2-wheels <<'PY'
import hashlib, importlib.util, json, pathlib, sys
reference, prior, new = map(pathlib.Path, sys.argv[1:])
assert hashlib.sha256(reference.read_bytes()).hexdigest() == '3a12637c49b98c5c33f8623e2ee44f5d9a165b083b2505f9a3c19028c2cfddce'
spec = importlib.util.spec_from_file_location('verifier', reference)
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)
base = pathlib.Path('devbox/apps/llama-server')
selection = json.loads((base / 'kyojin-v2-selection.json').read_text())
evidence = json.loads((base / 'kyojin-v2-evidence.json').read_text())
rows = []
for p in selection['packages']:
    if p['name'] == 'rocm-sdk-devel': continue  # Separately verified above.
    directory = prior if p['storage'] == 'prior-compliant-pypi' else new
    name = pathlib.Path(p['url']).name.replace('%2B', '+')
    package = dict(name=p['name'], version=p['version'], artifact=dict(
        size=p['bytes'], head_bytes=p['bytes'], hash='sha256:' + p['local_sha256']))
    rows.append(v.inspect_wheel(directory / name, package))  # Strict RECORD.
versions = {p['name']: p['version'] for p in selection['packages']}
versions['rocm'] = '7.13.0a20260411'
issues, _ = v.closure(rows + [evidence['rocm_static']], versions)
assert len(rows) == 49 and not issues
print('49 strict wheel checks and static dependency projection passed')
PY
```

## Static results and remaining install gates

The scoped SDK run exited **0**: seven standard RECORD content hashes matched,
with zero RECORD/security issues. It streamed 54,452 tar headers and
9,204,975,498 regular-payload bytes, retaining only bounded notice texts.
3,398 tar links were recorded, **never followed or approved for deployment**.
The unmodified verifier remained unchanged.

Combined results: **50 wheel bodies pinned, 22,962 standard RECORD content
hashes matched, zero hex records, zero RECORD/security issues, zero dependency
projection issues**. Default/extras closure uses the reviewed rocm sdist's static
edges, not generated metadata; it is not a complete build/native lock.
[kyojin-v2-evidence.json](kyojin-v2-evidence.json) retains the initial failure,
full-report hashes, source provenance, dependency evaluation, and new-wheel
notice path/hash inventories without whole wheel bodies or notice texts.

ZIP member expansion totals 15,757,764,126 bytes (14.676 GiB). Devel's nested tar
regular payload adds 9,204,975,498 bytes (8.573 GiB). Prior retained wheels plus
new compressed wheels plus both expansion layers total about **28.992 GiB**;
this is a file-length estimate, not filesystem allocation or a peak guarantee.
The approved dependency workspace budget is 60 GiB inside the whole 260 GiB
budget (which includes old artifacts), with 50 GiB free reserve. Source/build/
JIT/cache/duplicate staging and filesystem overhead must fit the remaining
headroom; do not treat the 3.496 GiB download as installed size. No ZIP/tar
payload was actually expanded to disk. Free disk after inspection was
760,819,253,248 bytes.

144 notices were read across the 50 wheels and SDK tar. AMD devel contains
named hipblas/hipsparse/rocsparse/rocblas/MIOpen/etc. notices and umbrella
`NOTICES.txt` (SHA256 `52d2c9ea42f14953ba8383c373a41fba2d7d841dd0c2ca2e5a67833dba948b4c`).
Terms include MIT/BSD/Apache/LLVM exceptions and GPL/LGPL components. GPL/LGPL
presence alone does not forbid internal non-redistributed testing. Distribution
or modification requires component-specific notice, source/offer, relinking,
and other applicable terms; the dependency stack is not uniformly MIT.
Libraries-gfx1151 has no notice in its own wheel: matching devel notices exist,
but exhaustive binary-to-source/notice correspondence is unconfirmed. Prior
PyPI tokenizers also lacks an embedded notice/declaration. These are recorded
scope gaps, not evidence that the packages are unlicensed. Model licensing is
separate (Qwen Community License 1.0); no model body was acquired.

**Recommendation:** this v2 set avoids the observed multi-arch RECORD defects
and is a viable static candidate, not an approved/runnable installation. Before
installation, establish target native ABI and SDK link containment, assess the
recorded notice scope for the internal use, and build/inspect the rocm wheel
CPU-only/offline with explicit gfx1151 and pinned build tools. Do not install
from this manifest or silently fall back to host ROCm. Independent G0 refusal
below prevents proceeding to the actual service/GPU comparison.

## Runtime safety boundary

The newly requested limited Docker inspect was **not permitted by the sandbox
external-execution confirmation**, and did not run. No alternate syntax,
location, tool, socket access, or proxy was used to bypass that decision.
Actual container/image/args/loaded HIP/HSA, concurrent jobs, and no-build/no-pull
restoration remain unconfirmed. The existing service was never stopped or
modified; restoration has not been exercised or claimed successful.

Consequently no native import, SDK initialization, engine build/JIT, model body
download, candidate launch, GPU inference, service stop/start, or live benchmark
is justified by this record. No TTFT, throughput, peak UMA, tool/vision/needle,
preset OFF/ON, or long-context comparison result is available. The ~95GB model
must not be downloaded before runtime feasibility is established.

Continuation requires explicit permission for limited service identification,
then confirmed rollback and native ABI/visibility gates. Use the fixed plan's
corpus/template/token and request budgets, monitor memory/temperature during
loading, keep only one model resident, and restore the verified current image
without build/pull. Never infer permission for OS/driver/ROCm/performance/fan/
IOMMU/publication changes or permanent switching from a comparison approval.

## Tests

```sh
python3 test/kyojin_range_test.py
python3 test/kyojin_sdk_budget_test.py
bats test/devbox-apps-anietta.bats test/devbox-apps-entrypoints.bats test/kyojin-range.bats
bats -r .
git diff --check
```

Offline fixtures: 8 Range tests and 3 scoped-budget tests PASS; related Bats
24/24 PASS. Final full suite: **282/285 PASS, 3 FAIL** in unchanged
`test/pi-sandbox.bats:113` and `test/zsh-ssh-agent.bats:334,347`, consistent with
the outer Unix socket restriction; no outside rerun or workaround was used.
All four documented shell blocks pass `bash -n`; the 49-wheel strict example
was actually reproduced successfully. Fixture success is not native execution
or service restoration success.

No standalone shell is added or changed; the Bats wrapper runs through Bats.
