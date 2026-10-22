# Evo-X2 Qwen3.8 比較実験の承認用計画

2026-10-22。**準備のみ完了。以下のDL・build・起動・推論・停止復帰コマンドは未実行で、別承認が必要。** 既存サービス、OS、GPU、EC、ファン、公開設定は変更しない。候補を採用済み・最速とは扱わない。

## 1. 比較するものと優先順位

初回承認申請にはKyojin/Gufoを含める。大容量だからという理由だけで後段へ追いやらない。実行順は保守枠に合わせ **現行 → Kyojin → Gufo＋同pack対照 → 最新halo-box → upstream → Halogen** を提案する。各候補後に現行へ復帰し、GPUは常に一台分だけロードする。導入承認は候補単位で選べる。

| 群 / 候補 | 固定点 | 証明できること / 証明できないこと |
|---|---|---|
| 対照: 現行prefill-opt | `94461c7f49fbdb43228d864584b06f25c8d4f0e4`（宣言・build-info） | 現行運用の基準。稼働実体の同定前はcommit確定と呼ばない |
| A: 最新halo-box | `da731374077f2ad9bdffd4848f782b5694b9bb68` | 同じuncensored IQ4_XS・shared MTPでfork更新差。HIPとVulkanは別行、spec-prefill OFF |
| A: upstream | `0693dbfb915f33233818373b5f6969396658d02c` | 同GGUFで保守性と速度/互換性。shared MTPが未対応ならAR対ARのみ、無断のhead置換不可 |
| A: Halogen 0.18.14 | docs `e601b84d88dd1ff0185a06daa9778254ceca4492`、imageはassets JSON | 同じIQ4_XS、別kernel/repack/専用MTP。AR対ARと各MTPを分け、MTP差をkernel単独効果としない |
| B: Kyojin | engine `e09322da7209331c57e2a79cfc30d120f0299154`、EXL3 revisionはassets JSON | 別packを含むシステム全体の有用性。abliterated GGUFと同品質/同アラインメントの証明にはならない |
| B: Gufo | image engine label `7110c7954ebc85d4a4d96aa0643b102615adca27`、UD-Q4_K_XL | 同じUD-Q4_K_XLを最新halo-boxにも渡しruntime差を分離。IQ4_XS現行との差はpack変更込み |

Gufoの既存調査commit `3aa068b419e6272482298c1c6daccafb122764fa` と配布imageは異なる。image版のモデル資料も取得し、qualified revision/起動例の一致を確認したが、性能・品質は再検証が必要。Halogenもimage revision label `9a80df1a2e68` とdocs commitは同一ではない。digest固定は供給物の固定であり、ソース再現性の証明ではない。

Kyojinはpreset OFFを機能/agent比較の主群とし、uncensor preset ONとuncensor-thinkは別群（後者は初回対象外）。重み非変更でも出力分布を変える。tool-heavyではOFFを推奨するモデルカードを尊重し、ONでも同じtool試験を行う。GufoのIQ4_XS loader非対応はuncensoredの政策禁止ではない。対応する別uncensored packは未検証で今回変換しない。

各候補で日本語prose、code、tool-heavy、vision、thinking OFF/ON、単独/2並列、cache cold/warmを検査する。非対応はN/Aで残し、黙って機能を外して合格にしない。vLLM/SGLangは公式FP8約172.78 GiB/BF16約335.28 GiBとgfx1151適合未確認のため今回の導入候補外。Halogen専用v2/tatianyi pack、cache2、composable context、spec-prefill、YaRN、OS tuningは品質条件変更の別群。

ライセンス: llama.cpp/halo-box/Gufo/Kyojin engineはMIT系。Kyojin EXL3を含むQwen重みはQwen Community License 1.0、変換tool公開は確認できない。uncensored派生の出典・利用条件は既存ファイル名だけでは確定しない。HalogenはEULA（OSSではない）、benchmark公開可でも改変image再配布に制約。導入前に固定revisionのLICENSE/モデルカードを利用目的に照合し、同意を記録する。重みはPRへ含めない。

## 2. 固定metadata・容量・分離配置

[benchmark-assets.json](benchmark-assets.json) は公開HF API `?blobs=true`、OCI manifest/config（layer本体は未取得）、ローカル`stat`だけから取得。GB=10^9 bytes、GiB=2^30 bytes。API全repositoryサイズを必要DL量と取り違えない。

| 内容 | 必要ファイル容量 GB / GiB | 追加導入の保守的disk予算 GiB | RAM（disk容量と別） |
|---|---:|---:|---|
| 現行target / mmproj / MTP | 97.473 / 90.779、0.904 / 0.842、2.787 / 2.595 | コピー不要。現物・buildを保持 | 箱全体used約110 GiBは過去の時点値、peakではない |
| halo-box / upstream | 重み追加0 | 各30（source/build/deps/cache、未確定） | 同GGUFでもKV/scratch増減は未確定、現行並みから検査 |
| Kyojin EXL3一式（assets画像除外） | 95.370 / 88.820 | **260**（model89＋重複/途中DL90＋venv/wheels/JIT61＋logs20） | 配布元約113 GiB。128GB箱でOS共存余裕が小さい。低contextでも起動可能保証なし |
| Gufo target4shard＋shared MTP＋BF16 mmproj | 115.029 / 107.129 | **280**（model108＋途中/重複108＋image展開/cache44＋logs20） | 公称HIP peak89〜91 GiBはallocator値。host totalではなく実測必須 |
| Halogen head＋tokenizer（既存GGUF参照） | 1.546 / 1.440、vision追加0.898 / 0.836 | **40**（assets3＋image展開10＋scratch/cache17＋logs10） | 公称repacked68 GiBは総RAMでない。dense staging約1.8 GiB、pool/lookup page cache等を含め再測定 |

OCI圧縮layer合計: Halogen 925,174,958 bytes =0.925 GB/0.862 GiB、Gufo 2,890,833,952 bytes =2.891 GB/2.692 GiB。**展開後サイズ・一時重複・Kyojin依存wheel総量はmetadataでは未確定**。上の予算は正確な必要量ではない。Kyojin requirementsは下限指定でlockではなくnightlyも可変。固定engineだけで再現可能とはしない。導入前に選択wheel版/URL/hash＋transitive lock＋合計量をレビューするgateを置く。Gufo imageはruntime依存をdigestで固定するがhost driver/権限は別gate。

本準備時の`df -B1 .`: available 766,981,103,616 bytes（714.307 GiB）、`free -b`: total134,159,831,040、available15,258,488,832 bytes（14.21 GiB）、swap40,353,792 bytes。コンテナ/時点値でありDocker storage filesystemの空きではない。上記全候補予算640 GiB＋安全余白50 GiBは近いので、一括導入せず候補ごと確認し、可能ならDL重複を避ける。現行を消して空きを作らない。

配置案: `$HOME/qwen38-comparison/{halo,upstream,kyojin,gufo,halogen}` 以下にsource/build/venv/models/cacheを分離。imageはdigest保持、現行imageをpruneしない。HFは候補の`--local-dir`へ、HF_HOME/PIP_CACHE_DIR/TORCH_EXTENSIONS_DIRも候補別。ホストapt/ROCm/driver/python既定/既存buildは変更しない。新しいtoolchainが必要なら候補image内で固定し、別承認。Gufo shared MTPは現行と同サイズだが同hash未確認なので、再利用を確定せず最大予算に含めた。巨大ファイルhashは本準備で読んでいない。

## 3. 段階的承認と実行gate

- [x] 公開metadata、既存設定/ファイル名/サイズ読み取り、文書のoffline検証のみ。
- [ ] **導入のみ**: 候補名、最大追加disk、固定revision/digest、ライセンス、依存lockを承認。DL/build/JITは推論と別に明示承認。GPU初回JITを導入だけの承認で行わない。
- [ ] **停止比較**: 実container/runtimeの限定同定に対する新しい具体的許可、保守枠、復帰先の実物保存、候補1台、2K/8Kと復帰smokeのリクエスト数を承認。
- [ ] **長文**: 32Kを別枠で承認、結果確認後128Kを承認。単独と2並列は別gate。128K×2は総KVと生成分が262144を超えるため初回不可。
- [ ] **OS/品質変更実験**: EC/fan/BIOS/IOMMU/governor、YaRN、approx cache、preset ON等を個別承認。今回の承認に含めない。

実行前にユーザーが決めることは3つ: (1) Kyojin/Gufoを含め導入する候補と容量上限、(2) 60〜120分/候補の停止枠と安全中止閾値、(3) uncensoredを必須条件とするか、tool-heavy/vision/2並列のどれを採用必須にするか。

**G0（現在未通過）**: Docker同定依頼は既に拒否されており、本準備では再試行しない。実container ID/image/Compose project/service/実行binary/args/loaded HIP/HSA/稼働jobを承認された方法で同定できるまで停止コマンドを実行禁止。`llama-server`という宣言名だけでは不足。全部のenvや`docker inspect` JSON全体を保存しない。必要な識別子、restart policy、mount、許可したruntime変数だけをprivateに記録する。

**G1**: private mode0700ディレクトリへ現行Compose/entrypoint、image ID/digest、binaryと共有libraryの実体（コピーまたは変更禁止の既存build）、args、target/mmproj/MTP path+sizeを保存。モデル全コピー不要。現行の未コミット設定と元repoのローカル変更を保持。復帰にpull/build/networkが不要なことを確認。候補/現行のmountはread-only、cacheだけ別書込み先。

**G2**: 候補imageのCLI `--help`と実効設定を導入後に照合。model capacityはまず32768（A群も同じ低context対照を別測定）、総KV/slot/ubatchの意味を記録。現行262144宣言そのままの測定行を消さない。公開8082/proxyは不変、候補は実行hostの127.0.0.1:18082のみ、engine内部portは公開しない。作業devboxからhost loopbackには届かないので、測定clientも同じ実行host/namespaceに置く。新規公開・v6net接続による公開代替はしない。

## 4. 承認後だけ使う導入・起動のレシピ

以下はshell構文検査用テンプレート。`CANDIDATE_IMAGE`等の未確定変数はG0/G1で埋めて人間がレビューする。動的latest追随・自動DL・無断再試行を禁止する。`hf`/Docker/コンパイラが無い場合に自動インストールしない。

### 重み取得（導入承認後、モデル本体DL）

```bash
ROOT="$HOME/qwen38-comparison"
mkdir -p "$ROOT"/{kyojin,gufo,halogen}
HF_HOME="$ROOT/kyojin/cache/hf" hf download yamz-labs/Qwen3.8-Flash-Next-EXL3-Yamz \
  --revision 247ef39b06ff0b0fcba76026429e191b44e0e1f8 --exclude 'assets/*' \
  --local-dir "$ROOT/kyojin/models"
HF_HOME="$ROOT/gufo/cache/hf" hf download unsloth/Qwen3.8-Flash-Next-GGUF \
  --revision 38bb39ee97821de2c9009abb7e93950eec396e66 \
  --include 'UD-Q4_K_XL/*' 'MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf' 'mmproj-BF16.gguf' \
  --local-dir "$ROOT/gufo/models"
HF_HOME="$ROOT/halogen/cache/hf" hf download peonist-ai/halogen-qwen3.8-flash-next \
  --revision 647e3814953e8435d58f5d5aa13b97aca85a7d93 \
  --include qwen38-flash-next-mtp.hgn qwen38-flash-next-vision.hgn 'tokenizer/*' \
  --local-dir "$ROOT/halogen/models"
```

### 新しいsource/build（承認された隔離toolchain内のみ）

```bash
ROOT="$HOME/qwen38-comparison"
git clone https://github.com/halo-box/strix-llama.cpp "$ROOT/halo/src"
git -C "$ROOT/halo/src" checkout --detach da731374077f2ad9bdffd4848f782b5694b9bb68
git clone https://github.com/ggml-org/llama.cpp "$ROOT/upstream/src"
git -C "$ROOT/upstream/src" checkout --detach 0693dbfb915f33233818373b5f6969396658d02c
# 各候補ごとに、別build dirで実施。現行buildには触れない。
SRC="$ROOT/halo/src"
cmake -S "$SRC" -B "$ROOT/halo/build" -DCMAKE_BUILD_TYPE=Release \
  -DGGML_HIP=ON -DGPU_TARGETS=gfx1151
cmake --build "$ROOT/halo/build" --parallel 4
```

upstreamもSRC/buildを置換して同手順。候補compiler/ROCm/container digestとCMakeCacheを記録し、現行固有オプションは存在確認なしにコピーしない。halo-box HIPの`HIP_LAUNCH_BLOCKING=1`推奨は候補設定として明示し、現行へ適用しない。Vulkanは別build/別承認。

Kyojinは次のsourceと専用venvを用いる。requirements.txtをそのまま無制限pip解決するレシピは承認しない。一次install資料はnightly torch/SDKを案内するがlockではないため、以下のlockを作成・検証してから実行する。

```bash
ROOT="$HOME/qwen38-comparison"
git clone https://github.com/Yamz-Labs/kyojin "$ROOT/kyojin/src"
git -C "$ROOT/kyojin/src" checkout --detach e09322da7209331c57e2a79cfc30d120f0299154
python3 -m venv "$ROOT/kyojin/venv"
: "${REVIEWED_LOCK:?wheel URLs, versions and hashesを含む承認済みlockが必要}"
PIP_CACHE_DIR="$ROOT/kyojin/cache/pip" "$ROOT/kyojin/venv/bin/python" -m pip install \
  --require-hashes -r "$REVIEWED_LOCK"
```

lock候補はgfx1151向けtorch/rocm-sdk-develとrequirements全件。公開nightlyの存在/組合せ、Python ABI、全推移依存、容量は未確定。失敗時host ROCmへfallbackしない。SDK初期化/extension buildは候補venv/image内だけ、別build承認。初回起動がGPU JITを含むことも停止枠に計上。

### 候補起動例（G0〜G2通過・現行停止と解放確認後）

halo-box（承認済み隔離runtime内、build/モデルmount実体とG2で全flag対応を確認後）:

```bash
ROOT="$HOME/qwen38-comparison"
HIP_LAUNCH_BLOCKING=1 "$ROOT/halo/build/bin/llama-server" \
  -m /home/yuanying/models/qwen3.8-flash-next/Qwen3.8-Flash-Next-Uncensored.i1-IQ4_XS.gguf \
  --mmproj /home/yuanying/models/qwen3.8-flash-next/Qwen3.8-Flash-Next-Uncensored.mmproj-f16.gguf \
  --spec-type draft-mtp \
  -md /home/yuanying/models/qwen3.8-flash-next-mtp/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf \
  -ngl 999 -ot 'per_layer_token_embd\.weight=CPU' -lm none \
  -c 32768 -np 1 -kvu --kv-unified-per-slot 32768 -fa on \
  -ctk q8_0 -ctv q8_0 -b 2048 -ub 2048 --cache-ram 0 --min-p 0 --jinja \
  --alias qwen3.8-flash-next --host 127.0.0.1 --port 18082
```

upstreamはbinary pathを`$ROOT/upstream/build/bin/llama-server`へ変更し、最新のflag対応確認後に実施。ARはspec-typeとmdの両方を外す。Gufo同pack対照ではmをUD-Q4_K_XL第一shard、mmprojをBF16に変更し、同じshared MTPを照合する。容積差を混ぜないためGufoと同じcontext/単独で別測定する。

Kyojin（隔離runtime内、preset OFF）:

```bash
ROOT="$HOME/qwen38-comparison"
cd "$ROOT/kyojin/src"
. "$ROOT/kyojin/venv/bin/activate"
export EXL3_ROCM_SDK="$(rocm-sdk path --root)"
export TORCH_EXTENSIONS_DIR="$ROOT/kyojin/cache/torch"
unset EXL3_ABLIT_RUNTIME
. tools/strix_halo/env.sh
python tools/qwen/serve.py --model "$ROOT/kyojin/models" \
  --model-id qwen3.8-flash-next --host 127.0.0.1 --port 18082 -c 32768 \
  --sessions 1 --cache-bits 0 --draft-policy mix \
  --chat-template "$ROOT/kyojin/models/chat_template.jinja" --default-reasoning-effort xhigh
```

単独ARは`--draft-policy off`、2並列は`--sessions 2`の別起動。独自medium注入を避けmodelのtemplateを明示する。思考ON品質枠ではxhighを明示、短い互換性検査lowは全候補で揃える。起動環境出力はprivate、preset OFF実効確認に失敗したら測定しない。別承認のpreset ONは同じ起動に`EXL3_ABLIT_RUNTIME="$ROOT/kyojin/models/uncensor-preset/uncensor_spec.json"`を環境指定する（固定モデルカードのinterface）。specをmodel rootへコピーしない。自動適用条件と出力分布変更を記録する。

Gufo（CLI順序は固定docs例に合わせglobal host/portをllmの前に置く）:

```bash
ROOT="$HOME/qwen38-comparison"
GUFO_IMAGE=ghcr.io/gufo-org/toolboxes/gufo-runtime@sha256:2b481357c27c2634deef4901aeb7018814e6552a9b4ea49a43e7aa70db71d867
# pullは導入承認、runは停止比較承認が必要
 docker pull "$GUFO_IMAGE"
 docker run --name qwen38-compare-gufo --restart=no --network bridge \
  --device /dev/kfd --device /dev/dri --ipc=host \
  -p 127.0.0.1:18082:18082 -v "$ROOT/gufo/models:/models:ro" \
  "$GUFO_IMAGE" gufo serve --host 0.0.0.0 --port 18082 llm \
  --model /models/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf \
  --speculative mtp --mtp-model /models/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf \
  --sessions 1 --context 32768 --served-model-name qwen3.8-flash-next
```

ARはspeculative/mtp-modelの両方を省略。2並列はsessions2。served model name、vision projector発見、cache policyはimageの`--help`/実効metadata確認gateで照合する。DockerのGPU group IDは現行の実際の権限から確認し、podmanの`keep-groups`をDockerへコピーしない。`--privileged`で解決しない。

Halogen（外向き自動DLは設定しない）:

```bash
ROOT="$HOME/qwen38-comparison"
HALOGEN_IMAGE=ghcr.io/peonist-ai/halogen-flash-server@sha256:e0c1d1b48e07c8acdd204fbdbafbb421a395a73cf704271845a1846ad1fd767f
 docker pull "$HALOGEN_IMAGE"
 docker run --name qwen38-compare-halogen --restart=no --network bridge \
  --device /dev/kfd --device /dev/dri --ipc=host --ulimit memlock=-1:-1 \
  -p 127.0.0.1:18082:8731 \
  -v /home/yuanying/models/qwen3.8-flash-next:/existing:ro \
  -v "$ROOT/halogen/models:/models:ro" \
  -e HALOGEN_CHECKPOINT=/existing/Qwen3.8-Flash-Next-Uncensored.i1-IQ4_XS.gguf \
  -e HALOGEN_MTP_HEAD=/models/qwen38-flash-next-mtp.hgn \
  -e HALOGEN_TOKENIZER=/models/tokenizer -e HALOGEN_MODEL_ID=qwen3.8-flash-next \
  -e HALOGEN_VISION_TOWER=/models/qwen38-flash-next-vision.hgn \
  -e HALOGEN_CTX=32768 -e HALOGEN_KV_POOL_POSITIONS=65536 -e HALOGEN_KV_SLOTS=1 \
  -e HALOGEN_PROMPT_CACHE=1 -e HALOGEN_INDEXER_BUDGET=2048 \
  -e HALOGEN_COMPOSABLE_CONTEXT=0 "$HALOGEN_IMAGE"
```

固定[FLAGS](https://github.com/peonist-ai/halogen-flash-server/blob/e601b84d88dd1ff0185a06daa9778254ceca4492/docs/FLAGS.md)に従いtokenizer位置と専用vision towerを明示。text-only比較ではVISION_TOWERを省略し、vision込みのRAMと混ぜない。現行f16 mmprojは代用しない。既存BIOS条件不適合なら停止し、QuickstartのBIOS変更を勝手に行わない。ARは`HALOGEN_DRAFTER_DEFAULT=0`またはrequestの`"drafter":"serial"`、MTPは`"drafter":"mtp"`を明示し、G2で受理/実効を確認する。

## 5. 停止・復帰（停止コマンドはG0で確定するまで実行禁止）

`restart: always`に対しPID killだけでは自動復活する。宣言名を信じた`docker stop llama-server`は使わない。G0で同定したCompose project/serviceとcontainer IDの対応、外部autohealer/daemon再起動予定の不存在を確認し、候補はrestart=no。G0/G1後に確定した**service scoped stop/start**を使う。以下は未確定変数で意図的にfail-closedとする。

```bash
: "${BASELINE_COMPOSE:?保存済みで実体と照合したCompose}"
: "${BASELINE_PROJECT:?確認した既存Compose project}"
: "${BASELINE_SERVICE:?確認したservice}"
# 保存composeが実image IDまたは保持済みdigestを指し、build/pull無しで復元可能なこと。
docker compose -p "$BASELINE_PROJECT" -f "$BASELINE_COMPOSE" stop --timeout 60 "$BASELINE_SERVICE"
# ここで実container停止・restart無し・GPU/UMA解放を人間が確認。確認できなければ候補起動禁止。
```

停止前後のhost MemAvailable/swap、対象cgroup memory.current/peak、GPU/GTT・/dev/kfd利用者を許可された観測で確認。**MemAvailableが停止前より60 GiB以上回復、かつ100 GiB以上、現行のGPU allocationが消失**を初期gateの提案値とする。UMA/page cacheで満たせない場合は理由を調査して再承認、drop_caches/kill/強制起動で突破しない。Kyojin113GiBという公称値からも余裕は保証されず、ロード中監視で中止する。

各候補終了・異常時は新規送信を止め、候補の確定container IDまたは自分のlauncher PIDへ通常停止を要求する。広いpkillは禁止。停止が確認できないなら現行も二重起動しない。cgroup/GPU allocation解放後にのみ復帰する。

```bash
: "${BASELINE_COMPOSE:?}"
: "${BASELINE_PROJECT:?}"
: "${BASELINE_SERVICE:?}"
docker compose -p "$BASELINE_PROJECT" -f "$BASELINE_COMPOSE" up -d \
  --no-build --pull never "$BASELINE_SERVICE"
```

現行containerが残る停止/開始方式を優先する。再作成が必要なら保存実体との差分をレビューし別承認。health回復＋承認済み日本語/thinking/toolの各1回＋restart/OOM数/メモリ確認まで復帰完了としない。PR156の[VALIDATION](https://github.com/yuanying/dotfiles/blob/2da0f7a/devbox/apps/llama-server/VALIDATION.md) / [smoke.py](https://github.com/yuanying/dotfiles/blob/2da0f7a/devbox/apps/llama-server/smoke.py)を読み取り参照するが、未マージファイルを本PRへコピーしない。利用にはそのPRの承認/統合、または固定版offline利用の別承認が必要。旧`6994643`はshared MTP非対応であり通常復帰先にしない。

## 6. 比較protocol

### 基準・入力・条件固定

- 現行**宣言**はnative262144 / 総KV262144 / 2slot / b2048 / ub2048 / q8 K/V / cache-ram0 / IQ4_XS / shared Q8_0 MTP。実効値・loaded ROCmは未確認。cache-ram0でもresident slot prefix再利用はあり得る。過去384K/ub4096の値を現在のbaselineとして使わない。
- 主表は現行宣言行と、全候補を32768 capacity/単独に揃えた低context対照行を分ける。2並列でも総KVを揃える。Gufo/Kyojinのcontextのper-session/totalの意味は実効値で確認。131072試験はcapacity196608等、入力＋生成を確保し、別承認。slot/ubatchが非等価なら値と意味を併記し、同条件と断言しない。
- [benchmark-cases.json](benchmark-cases.json)に合成入力・tool schema・32×32赤PNG・組立契約を凍結した。corpus SHA256は`81426b78ce8bf0bcb9b32e98e5ba10651119ab4d79453424e5268ee4663f65da`。runtime templateは導入後G2で凍結しhash追加。日本語自由説明とcode修正（期待unit tests付き）各1問を2K/8Kで用意。ASCII固定fillerに位置別の日本語key/valueを埋め、先頭/中間/末尾needleを事前正答と照合。長さを文字数でtokensと呼ばない。2K/8Kは目標、**template後実prompt tokens、cached/prefilled tokens、生成reasoning/content tokens**を各runtimeで記録。tokenizer差があれば両方の長さを載せる。
- リクエスト本体とtemplate bytesのhashを保存。同じtextでもtemplateが違えば別条件。unsupported fieldはエラー/N/Aとし、黙って削除しない。最初のgreedy比較: temperature0/seed42/top_p1/top_k0/min_p0/presence0/repetition1、256生成上限。EOSで短く終わったものを256生成として割らない。
- thinking OFF/ONを別行、ONの互換検査はlow、品質枠はxhigh＋最大1024（別承認）。Kyojin独自mediumは除外。公式sampling品質枠はOFF temp0.7/top_p0.8/top_k20/presence1.5、ON temp1/top_p0.95/top_k20/presence0、共通min_p0/repetition1。greedy速度順位とsampling品質順位を混ぜない。
- 各runtimeでAR vs MTP（draft上限/lookup/accept率）、serial vs 2並列、prose vs codeを別行。同seedでもsampling時のMTP RNG差を直ちに品質劣化としない。greedyは同一runtime AR一致を確認し、runtime間byte一致は保証としない。

組立後raw user入力のSHA256（template前、実token数は未測定）:

| nominal tier | prose | code |
|---|---|---|
| 2K | `1f35178569c220627c0613005c45c5ab0cb9db03952fed1094943e845f361d44` | `9ab4c6be2af53a23cb3f10f5b46c52da4d9bb9de142e7b5a874a756d0b78d858` |
| 8K | `a0e569d5d30f59925f0def9d8fbcda10916d495aa80247977432515f97a33484` | `798ce988d8f7fb4d1a517226a07835a90d7b1d9b78f7c422a65ed17f0eef6dad` |
| 32K | `2a56ed9cc5428094fbe7bb4c5ba6bf9ea4763dd0dcce7f92feed9d3592e0d89a` | `7274d6bcce61c524c3fac6bdffe805241a354fff1e384b9b4028c51a554a7a5b` |
| 128K | `cf74b4f0de145a53e4380df4201a8b4579c8fb52ac71647d5bd09dd345110ef5` | `36396ca22886258a5db74ea10475c2695d9e906b3de78ffe6d4ac1e0b324217b` |

nominal名を実token数と報告しない。導入後のtokenizer-only確認で2K/8K/32K/128K目標から大きく外れれば、送信せずNを調整した新corpus/hash/予算を承認し直す。測定後にpromptを変更して同じセルへ混ぜない。

### 冷温と測定回数

1. **process cold**は起動→ready。OS page cache cold/warmとは別。drop_cachesを実行しないためOS disk coldは保証できず「未制御」と記録する。
2. **prompt cold**はresident prefix不在をcache counterで確認。新session/承認されたcache erase、あるいはrestartで確実化する。単なる異なるrequest IDはcoldの保証でない。
3. **prompt warm**は同一prefix＋固定follow-up。最初のpriming一回は計測外、その後3回。request/cache key、cached tokens、reasoning再送方針を揃える。Halogen cache1、Kyojin最新packのexact主張は実測する。cache2/approx/並列非一致は別表。
4. 各セルはwarmup1回＋cold3回＋warm3回、中央値/min/maxを保存。2並列では同期した2送信を1roundとして3round、各requestの遅延とaggregate throughput/fairnessを併記。最速だけ抜き出さない。
5. 2K/8K → 品質/安定gate → 32K → gate → 128K。cached depth128K＋pp2048と、全128K cold prefillを別caseとして報告する。短文を繰り返すだけで候補比較を完了としない。

初回2K/8Kはprose/code × OFF/ON × cold/warm × 3回 =48計測requests/候補（warmup/primeは別計上）。最初は単独・MTPのみ。AR ablationと2並列は有望候補だけの追加枠、各24requests等を事前に固定し、全factorの直積を無断実行しない。機能gateは日本語、算数OFF/ON、forced tool、auto tool選択、3turn tool-heavy（read-only合成tool response、実tool非実行）、vision2問を数えた別予算にする。visionはfixtureの固定小型PNGについて色/単色かの2問を採点し、画像token数も記録する。これはOCR/物体数/実用vision品質の検証ではない。tool JSON名/arguments型/値/finish_reasonと複数turnの保持を検査し、forced callだけでagent互換としない。

### 採取・中止基準

SSE clientはmonotonic clockでsend開始/最初の非空reasoning delta/最初の非空content delta/最初のtool delta/最終chunkをtimestampする。role-only delta/heartbeatはtoken扱いしない。thinking OFFのreasoning TTFT、tool-onlyのcontent TTFTはN/A。HTTP header TTFBをTTFTとしない。`curl --no-buffer -N --max-time ...`は送信/生stream保存には使えるが、arrival clock記録を持たないログからTTFTを復元しない。stream収集clientの実装/fixture確認は実行workerの前提gateであり、既存非stream smoke.pyを重複実装しない。

server timingsのprompt_n/prompt_ms、predicted_n/predicted_ms、cache_n、draft/accepted、finish_reason、HTTPエラー、wallを保存。server値が出なければN/Aとし、client wallからprefill t/sを捏造しない。client decodeは生成tokens/(最後−最初の生成delta)、短い/一chunk出力はN/A。reasoning+content合算tokensか区分か明記する。

hostで1秒間隔のMemAvailable/swap、対象cgroup memory.current/peak、process RSS、GPU/GTT allocator peak、温度を同時採取し時刻合わせする。**UMAはRSS＋GPUを加算しない**。container peakとhost used差も別列。センサー不可なら未測定とし、peak取得なしの128K進行は禁止。保存CSV列: run_id/runtime/image/model_rev/prompt_hash/template_hash/context/slots/KV/MTP/cache/think/effort/input_tokens/cached_tokens/output_tokens/prefill_ms/decode_ms/reasoning_TTFT/content_TTFT/tool_TTFT/wall/host_available_min/cgroup_peak/GPU_peak/swap_delta/quality/error。

提案中止値（安全保証ではなく実行前承認対象）:

- MemAvailable <8 GiBが2サンプル連続、またはswap増分>512 MiB、OOM/restart発生、GPU reset/driver errorは即中止。ロード中も監視する。
- 温度95°C以上が10秒、または機器既定criticalまで5°C以内は中止。温度が観測できなければ長文に進まない。ファンを変更して突破しない。
- 2K/8Kは1request180秒、32Kは300秒、128Kは900秒を提案timeout。中止後client切断だけでGPU停止とみなさず、実行中job解消を確認してから復帰。自動再送なし。
- schema破損、意図しないthinking漏洩、greedy AR/MTP不一致、needle誤答/lengthはgate不通過。判定heuristicの問題は応答をprivate保存してoffline調査、promptを都合よく変更して同じ測定にしない。
- 2K/8Kの3回で5xx/timeoutが1回でもあれば長文禁止。性能が低いだけでは品質gate失敗とせず、その結果を残す。

## 7. 停止時間と次の実施単位

既存smoke4件は日本語/thinking/toolの限定PASS、各1回でTTFT/peak未測定。候補の性能比較は未実施。旧外部記事の5〜7倍は別backend/重み/深度であり所要時間の根拠にしない。

1候補の短文枠: stop/解放確認2〜5分、load/ready **1〜10分**（Kyojin配布元cold7〜8分/warm90秒、Gufo16秒、現行25秒は未追試の参考値にすぎない）、48計測＋最大16warmup/primeを各10〜30秒と仮置きして11〜32分、機能gate5〜15分、停止/現行cold復帰・smoke3〜10分。合計**22〜72分、予約60〜120分/候補**を提案。初回JITが10〜30分超なら枠を分けて復帰し延長承認を求める。DL/buildは停止前に済ませ、停止枠へ混ぜない。

長文は別枠。32K/128Kそれぞれprose/code・cold/warm・3回=12requests/長さ。1requestの概算はinput_tokens/prefill_rate＋output_tokens/decode_rate。32Kを200〜1500 tok/s、decode20〜60 tok/sと仮置きすると256生成で約26〜177秒/回、12回で約5〜36分＋prime。128Kは150〜1500 tok/sなら約92〜887秒/回、約18〜178分＋prime/load/復帰。**32Kは60〜90分、128Kは60〜240分**を別予約する。これは予測であり速さの採用根拠ではない。32K実測から128Kの予算/timeoutを再承認し、2並列・AR追加は別枠とする。

最初の実施単位は「導入する候補の選択 → G0/G1とlock確定 → KyojinとGufoの短文品質/速度、Gufo同pack対照」で、現行tiny smokeだけの再反復ではない。最新halo/upstream/Halogenは同GGUF対照として続ける。採用判断は同条件速度・必須機能・品質・メモリ余白・保守/ライセンスを合わせて行う。

## 出典と検証境界

公開取得日は2026-10-22。HF固定API: `https://huggingface.co/api/models/<repo>/revision/<revision>?blobs=true`（repo/revisionはassets JSON）。sha256は公開LFS metadataでありlocal検証済みhashではない。OCIは`https://ghcr.io/v2/<repository>/manifests/<digest>`とconfig metadataのみ取得、registry bearer tokenは保存しない。

- [Kyojin install](https://github.com/Yamz-Labs/kyojin/blob/e09322da7209331c57e2a79cfc30d120f0299154/doc/install.md)、[SERVE](https://github.com/Yamz-Labs/kyojin/blob/e09322da7209331c57e2a79cfc30d120f0299154/tools/qwen/SERVE.md)、[モデルカード](https://huggingface.co/yamz-labs/Qwen3.8-Flash-Next-EXL3-Yamz/blob/247ef39b06ff0b0fcba76026429e191b44e0e1f8/README.md)
- [Gufo image版モデル資料](https://github.com/gufo-org/gufo/blob/7110c7954ebc85d4a4d96aa0643b102615adca27/docs/models/qwen3.8-flash-next/README.md)、[旧調査点README](https://github.com/gufo-org/gufo/blob/3aa068b419e6272482298c1c6daccafb122764fa/README.md)
- [Halogen GGUF](https://github.com/peonist-ai/halogen-flash-server/blob/e601b84d88dd1ff0185a06daa9778254ceca4492/docs/gguf.md)、[configuration](https://github.com/peonist-ai/halogen-flash-server/blob/e601b84d88dd1ff0185a06daa9778254ceca4492/docs/configuration.md)、[LICENSE](https://github.com/peonist-ai/halogen-flash-server/blob/e601b84d88dd1ff0185a06daa9778254ceca4492/LICENSE.md)
- [Qwen公式カード](https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/de4b8e4d43b917e7706784d8bb445c9af86a3540/README.md)（sampling/license、取得時revision）、[halo-box固定README](https://github.com/halo-box/strix-llama.cpp/blob/da731374077f2ad9bdffd4848f782b5694b9bb68/README.md)
- [Wiki比較 PR117](https://github.com/yuanying/llm-wiki/pull/117)、[既存smoke PR156](https://github.com/yuanying/dotfiles/pull/156) は未マージの読み取り参照。本PRはREADME/運用設定/既存smoke実装を変更しない。
