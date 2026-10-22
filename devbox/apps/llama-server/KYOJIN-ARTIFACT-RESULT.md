# Kyojin 固定wheel取得・静的検証結果 — 2026-10-22

## 結論

固定54wheelの取得・本体SHA256・全RECORD対象内容hashの照合と、
METADATA/WHEEL/通知の読取りを完了した。**段階Aの標準適合gateは非合格、install不可。**
取得artifactは公開snapshotと一致するが、wheel仕様適合や安全性を保証しない。
RECORDの仕様逸脱とライセンス対応情報不足を、実体の整合性異常とは区別する。
GPL/LGPLの存在だけを内部検証禁止の理由にはしていない。

再送・追加依存取得・resolver・install/build・SDK init・torch import・GPUアクセス・
モデル取得・Docker・サービス・OS操作は実施していない。診断の追加networkも0。

## 固定入力・再現物

- engine `e09322da7209331c57e2a79cfc30d120f0299154`、model
  `247ef39b06ff0b0fcba76026429e191b44e0e1f8`（モデル本体は取得しない）。
- 入力はPR #162/head `579581d` の非installable `kyojin-preflight.json`。
  SHA256 `64343f512b2037dc6a3f5e894ffdb5a17849442b92811d6edea12a5db5431162`。
  そのsnapshotはこのPRへ重複同梱しない。
- 検証器と再現手順: [ARTIFACT-VERIFICATION.md](ARTIFACT-VERIFICATION.md)。
  `--diagnose-offline` は取得を禁止し、非準拠を記録してexit **1** にする。
- [kyojin-artifact-evidence.json](kyojin-artifact-evidence.json) は54件の実hash、
  bytes、依存・tag、通知237件のpath/hash、差分・非準拠集計を保持する。
  大量のhex対象path/内部tarのlinkは件数・サンプル・全リストhashに縮約。
- 原文通知・全対象path入りの外部full reportのSHA256:
  `772ea239939a31f61eeebb398d0e5d2ee395e6fe8f3337f832f186c5791c8d43`。
  verifier SHA256もevidenceに記録。秘密・署名URL・wheel本体はGitへ含めない。

## 取得・容量

| 項目 | 結果 |
|---|---:|
| 取得wheel数 / whole-wheel SHA256一致数 | 54 / 54 |
| HTTP body取得量 / wheel保存量 | 2,412,419,726 bytes（2.247 GiB） |
| 再送 / redirect / 追加artifact | 0 / 0 / 0 |
| wheelディレクトリ実使用（marker等込み、du -sb） | 2,412,423,614 bytes |
| ZIP member展開予定bytes（diskには展開しない） | 9,412,212,786（8.766 GiB） |
| devel内tar regular payload（非展開読取り） | 2,922,173,963（2.721 GiB） |
| ZIP展開＋tar payloadを同時保持する場合の単純和 | 12,334,386,749（11.487 GiB） |

開始時free 766,957,207,552 bytes、取得後free 764,594,233,344 bytes。
transfer/staging各3GiB、free reserve50GiBを満たした。既存cacheなし。
全artifact一度だけHTTPS取得し、単一partialからhash照合後rename、二重保存なし。
rocm sdist27,362bytesは既存レビューを継承し再取得しない。
展開予定量はファイル長の合計であり、filesystem blocks/venv/一時複製/cache/JIT/
source/model/peak RAMを含む容量保証ではない。

## RECORD: 仕様逸脱と整合性を分離

| 対象 | 標準base64urlで内容一致 | 非標準hexで内容一致 | self行 |
|---|---:|---:|---|
| amd-torch-device-gfx1151 | 0 | 4 | 欠落 |
| amd-torch-device-gfx115x | 0 | 11 | 欠落 |
| torch | 0 | 12,609 | あり、空hash/size |
| 残り51wheel | 9,050 | 0 | あり、空hash/size |

- **配布仕様逸脱:** SHA256のhex表記12,624行（3wheel）とself行欠落2件。
  hexを独立照合できても標準base64urlとしてPASSにしない。
  前2wheelのWHEEL Generatorは `rocm-kpack-split-python-wheels`。
  分割/repack時のRECORD生成形式が原因という仮説はあるが、上流原因は未確認。
- self行欠落の正確なpathは
  `amd_torch_device_gfx1151-2.14.0+rocm10.1.0a20260822.dist-info/RECORD` と
  `amd_torch_device_gfx115x-2.14.0+rocm10.1.0a20260822.dist-info/RECORD`。
- **実体整合性の検査範囲:** whole-wheel SHA256 54件、およびRECORD記載の
  非self通常ファイル **21,674件** のsize/内容digest/ZIP CRCがすべて一致。
  RECORD自体の改ざん耐性はwhole-wheel hashに依存し、RECORD self/署名を認証しない。
  未対応/照合失敗digest、実未記載ファイル、参照先欠落は各0。
- **検出されたセキュリティ異常:** ZIPの危険path、duplicate、symlink/special file、
  暗号化、予算超過、RECORD内容hash不一致は0。malware検査・native実行安全性の証明ではない。
- ZIP directory entryは通常ファイルではなく、`RECORD.jws`/`RECORD.p7s`は
  RECORD非記載の仕様上例外。これらのpositive fixtureと実未記載ファイルのnegative fixtureを分けた。
- setuptoolsはvendored package内にもdist-infoを含む。wheel直下のdist-infoだけを
  root METADATAとして選ぶ修正を正負fixture付きで適用。これはverifierの誤検知であり、
  上記AMDのself/hex逸脱を緩和したものではない。
- 仕様参照: [Binary distribution format](https://packaging.python.org/en/latest/specifications/binary-distribution-format/)
  / [PEP 427](https://peps.python.org/pep-0427/)。診断開始後に外部取得していない参照URL。

## METADATA / runtime・build closure

全54wheelのName/Version、Requires-Python、WHEEL version/filename tagと互換tagを確認。
評価環境はCPython3.12.10/Linux x86_64/glibc2.39のdevbox。gfx1151ネイティブ実行、
実service hostのdriver/glibc/HSA/compiler/header適合は未検証。

- 選択packageをrootとするdefault extras＋依存が要求するextrasの固定点投影:
  runtime依存の欠落・版制約競合0、未宣言extra要求0。
- PyPI snapshotとの差は14packageの空白/quote/括弧/順序等の表記差。
  packaging parserでのRequires-Dist集合/Requires-Python specifier比較は全件同値。
  実際のraw Requires-Distと全active/inactive marker結果はevidenceに保持した。
- snapshotのuv.lock投影依存名との差0。元uv.lock全体を再取得・再resolverしたという意味ではない。
- 未選択test/doc/CUDA/Windows/eval/examples等のoptional extrasを閉じたとはしない。
- rocmはsdistの既存静的レビューによるcore/devel/device-gfx1151/libraries固定edgeを使用。
  backend `setuptools.build_meta`、`setuptools>=70.2.0`は選択84.0.0で充足。
  wheel0.48.0/packaging26.3も候補固定済み。ただしdynamic metadata/backend hooksは未実行で
  完全build lockではない。将来buildには `ROCM_SDK_TARGET_FAMILY=gfx1151` が必要。

## 実license・noticeと未確定項目

wheel内およびdevel tar内から通知 **237件/957,149bytes** を上限付き読取りしpath/hashを保存。
文字列検索による候補抽出であり、全binaryと権利者/条件の完全対応を確定したとはしない。

- **確認した条件:** MIT/BSD/Apache/PSF、LLVM exception、MPL-2.0（tqdm）、
  marisaの `MIT AND (BSD-2-Clause OR LGPL-2.1-or-later)` 等。依存全体はMITではない。
  torchのvendored通知90件、setuptoolsのvendored通知17件、numpyの20件も別途存在する。
- **AMD実bundle:** coreの通知9件と、devel内tarの通知50件を確認。
  `rocm_sdk_devel/_devel.tar!_rocm_sdk_devel/share/doc/NOTICES.txt`
  （SHA256 `52d2c9ea42f14953ba8383c373a41fba2d7d841dd0c2ca2e5a67833dba948b4c`）は
  GDB/BashのGPLv3-or-later、glibcのLGPL2.1-or-later、NCSA、zlib等を含む。
  GPL/LGPLは内部の非再配布検証を一律禁止しない。再配布する場合はcomponent毎の
  Corresponding Source/offer、通知保持、改変表示、LGPLの再link等の条件を確認する必要がある。
- **通知/出典対応不足:** amd device2wheelはlicense header/classifier/expression/通知がない。
  rocm-sdk-device-gfx1151/librariesは自wheel内に通知/宣言がなく、devel/core内通知との
  正確なbinary対応が未確定。MIT宣言のrocm-bootstrapは本文通知なし。
  tokenizersはsnapshot PyPIのApache classifierはあるが実wheelにlicense通知/宣言なし。
  これらを「無許可」や「MIT」と即断せず、不足情報として保留する。
- **再配布/商用用途:** MIT/BSD等の著作権・通知維持、ApacheのNOTICE/変更表示/特許条件、
  MPL対象改変ファイル等の条件を用途別に確認する。モデルのQwen Community License1.0と
  engine MITは別。商用Model-as-a-Service/AI Work Assistant等のモデル条件はこのwheel検証で解決しない。
- **未検証:** devel tarの41,176header/2.922GB payloadをstream読取りし、3,343の
  symlink/hardlinkを記録したがfollow/展開せず、deployment先に対するlink安全性は未承認。
  kpackや他の埋込み形式まで再帰解釈しない。法的な完全適合保証は行わない。

## 後続workerへの引き継ぎ

タスクディレクトリを `$TASK_DIR` とする。
- wheel保存先: `$TASK_DIR/artifacts/kyojin-wheels`。自動削除・上書き・再送しない。
- 固定入力: `$TASK_DIR/notes/reference-measure/kyojin-preflight.json`。
- full report: `$TASK_DIR/artifacts/kyojin-verification-diagnostic.json`。
  初回strict停止report `kyojin-verification-full.json` は54件診断の最終結果ではない。
- 今回は**install不可**。標準RECORDを持つ配布物の出典固定、通知欠落/対応不明の解消、
  rocm生成wheel/backend/installer確認、実体同定・sandbox・容量・ABI gateが先。
  既承認の後続検証を「Bの再承認待ち」だけで止めないが、非合格gateを無視して導入しない。
- 解消後の具体候補操作（このworkerでは未実施）: 専用CPython3.12 venv、固定build wheels、
  explicit gfx1151でrocmのみCPU/offline/no-isolation/no-resolver wheel化し生成hash/METADATAを確認。
  local wheelsのみno-index install、torchをimportしない依存確認。
  20GiB workspace hard cap＋free reserve50GiB案は、11.487GiBの単純和にコピー/venv等が加わるため
  peak見積もりを再点検する。SDK init/engine build/JIT/model/GPU/serviceはさらに実体・安全gateに従う。
- **対案v2/gfx1151:** 既存notesにindex調査とmutable nightly recipeの存在はあるが、
  固定URL/hash/実RECORD/license metadataの対照セットは保存されていない。
  multi-archのkpack分割wheelと異なる配布工程なら本逸脱を避ける可能性はあるが、
  gfx1151というindex名から標準RECORD/通知充足は推論できない。追加DLせず評価できる結論は
  「未確認、次候補として出典・版・hash・依存差分から固定し直す」であり、黙って置換しない。

## テスト

- TDD: verifier未作成、diagnostic API未実装、vendored METADATA、nested tar未対応でRED確認後に実装。
- `python3 test/kyojin_artifacts_test.py`: **23 PASS**（offline正負fixture）。
- `bats test/devbox-apps-anietta.bats test/devbox-apps-entrypoints.bats test/kyojin-artifacts.bats`: **23 PASS**。
- 全体 `bats -r .`: **281/284 PASS、3 FAIL**。未変更の
  `test/pi-sandbox.bats:113` と `test/zsh-ssh-agent.bats:334,347`、外側sandboxのUnix socket制限と整合。
  診断拡張前の全体実行であり、拡張後は上記単体/関連を再実行した。全体PASSとはしない。
- 最終offline全54件診断は **exit1 / static_gate_not_passed** が期待結果。
  `git diff --check` を実施。standalone shell変更なし、Bats wrapperはBatsで検証。
