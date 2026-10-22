# Kyojin wheel static verification

`verify_artifacts.py` verifies the 54 wheel artifacts in the separately reviewed
PR #162 preflight snapshot. It is not an installer, resolver, runtime launcher,
license compliance certification, or a complete lock file. The rocm sdist is not
downloaded again. Candidate Python/native code is never executed or imported.

## Inputs and execution

Requires the existing CPython 3.12 Linux x86_64 environment and its existing
`pip._vendor.packaging` parser. No bootstrap/install or network fallback is used.
The snapshot must have SHA256
`64343f512b2037dc6a3f5e894ffdb5a17849442b92811d6edea12a5db5431162`.
It must select exactly 54 wheels totaling 2,412,419,726 bytes. The snapshot is
not duplicated here; preserve it separately when removing its source checkout.

```sh
python3 devbox/apps/llama-server/verify_artifacts.py \
  --snapshot /absolute/path/to/kyojin-preflight.json \
  --directory /absolute/path/outside/git/kyojin-wheels \
  --report /absolute/path/outside/git/kyojin-verification-full.json \
  --inventory /absolute/path/to/compact-evidence.json
```

The default is **offline and strict**: missing files or nonconformant RECORDs
fail, without a network request. For an explicitly authorized read-only diagnosis,
add `--diagnose-offline`. This forbids `--acquire`, reports all safely readable
artifacts, and exits nonzero if any record/dependency/security check fails. It
never promotes a nonstandard digest or missing RECORD self-row to PASS. Add
`--acquire` only under an explicit fixed-artifact acquisition authorization.
No model download, install, backend hook, SDK initialization, GPU probe, torch
import, or service operation is present. The report contains full license texts;
review it locally and commit only the compact inventory/results, never wheels.
`--inventory` omits notice bodies and reduces large hex-path/link lists to
counts/samples/list hashes; the external full report retains every exact path.
The compact evidence also hashes that full report and the verifier itself.

## Resource and failure policy

- Acquisition/staging cap: each 3 GiB; minimum free reserve: 50 GiB in addition
  to the declared acquisition size. Existing cache entries are rehashed, not
  overwritten or deleted. A single streamed `.partial` is renamed after hash
  verification; no second full-size copy is created.
- HTTPS, two fixed publisher hosts, no credentials/query/fragment URLs, no
  proxy discovery, content encoding, redirects, resume, or retries. A persistent
  `.attempt` marker is created before any request. A previous attempt or partial
  without a valid final artifact stops the run; do not remove it to retry without
  review. Existing successful finals can be reverified without transfer.
- ZIP: no extraction; reject traversal, symlinks/special files, duplicate names,
  encryption, unsupported WHEEL tags, and excessive expansion. Bound the central
  directory to 64 MiB before allocation (CPython's ZIP64-aware EOCD reader).
  Limit 200,000
  entries, 8 GiB/member, 32 GiB aggregate expanded bytes, ratio 2000, 4 MiB/text
  member and RECORD, 64 MiB license/notice text per wheel. These are verifier
  read budgets, **not** permissions to write 32 GiB to disk.
- Uncompressed nested `.tar` members are streamed without extraction, recursion
  or following links. Parse fixed 512-byte tar headers (including bounded
  PAX/GNU long-name records); cap 100,000 headers, 8 GiB payload, 4 MiB text and
  the same aggregate notice budget. Record symlink/hardlink targets as unresolved,
  not as approved deployment paths. Other embedded formats are not interpreted.
- Read RECORD-covered members with supported SHA256/SHA384/SHA512 digests using
  1 MiB streaming buffers; compare size, digest and CRC. RECORD itself must have
  an empty-hash/size row. Directory entries are not real files; detached
  `RECORD.jws`/`RECORD.p7s` can be omitted from RECORD, and are not authenticated.
  In diagnostic mode, independently verify hexadecimal digests but classify
  them as **nonconformant**, not standard base64url. Report missing self-row,
  unlisted real files, absent referenced paths and failed/unsupported hashes
  separately. Publisher SHA256 equality is integrity
  against the input snapshot, not an independent publisher identity proof.
- Dangerous ZIP paths, duplicates, symlinks/special files and budget violations
  remain hard rejections even in diagnostic mode; record them as inspection
  failures and do not claim their metadata/contents were fully verified.
- Constant/type-only unexpected errors avoid leaking URLs, response bodies,
  headers, proxies, or credentials. A failed run writes an incomplete report
  and exits nonzero. Preserve artifacts and diagnose; never auto-redownload.

## Dependency and license interpretation

Compare METADATA name/version, Requires-Python, WHEEL and filename ABI/platform
tags against the existing CPython 3.12 Linux evaluator's compatible tags. This
does **not** test the service host's glibc/HSA/driver compatibility or gfx1151
native code. Marker evaluation explicitly targets CPython 3.12.10/Linux x86_64.
All selected packages are roots with no optional extras initially; propagate
extras requested by active dependencies to a fixed point. Record inactive edges
rather than dropping them. Include the reviewed rocm sdist's static selected
core/devel/libraries/device-gfx1151 requirements; its dynamic metadata still
requires a separate backend/produced-wheel review. No additional dependency is
fetched on mismatch.

The report compares actual wheel Requires-Dist/Requires-Python with the snapshot
PyPI metadata, and active dependency names with its projected uv.lock names.
It does not re-download uv.lock or independently reproduce the entire original
lock projection. Preserve literal PyPI differences but separately compare parsed
Requirement sets and Requires-Python specifiers, so quote/whitespace/ordering
normalizations are not confused with dependency changes. Dependency requirements' extras/markers and selected-version
constraints are checked, not just names. Optional unselected extras are not
claimed to be closed. Build pins setuptools 84.0.0, wheel 0.48.0 and packaging
26.3 remain candidates for backend `setuptools.build_meta` requiring
`setuptools>=70.2.0`, with explicit
`ROCM_SDK_TARGET_FAMILY=gfx1151`; no backend is run here.

License expressions/classifiers are evidence, not sufficient on their own.
Review embedded notices (including vendored/native AMD/torch/triton code),
redistribution/source-offer/patent obligations and the intended internal use.
Preserve notices for downstream redistribution. Unknown terms remain a gate,
not an implicit MIT assumption. Model licensing is separate from engine MIT
and from the full dependency stack.

## Tests

```sh
python3 test/kyojin_artifacts_test.py
bats test/kyojin-artifacts.bats
```
