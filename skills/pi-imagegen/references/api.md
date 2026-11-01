# 接続先と認証

この拡張は Codex の ChatGPT バックエンドを使う。公開 OpenAI Platform API の
`https://api.openai.com/v1` とは別の経路であり、公開 API の互換性保証はない。
2026-11-01 に Pi の ChatGPT トークンで生成を実測した。

- 新規生成: `POST https://chatgpt.com/backend-api/codex/images/generations`
- 編集: 同じベースの `images/edits`。JSON に `images: [{image_url: "data:image/png;base64,..."}]` を追加。
- ヘッダー: Bearer token、`chatgpt-account-id`、`originator: pi`、JSON content type。
- ボディ: `model: gpt-image-2`、`prompt`、`background`、`quality`、`size`。
- 応答: `data[0].b64_json` を PNG として保存する。

根拠は Codex の [Images client](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/endpoint/images.rs)、
[リクエスト型](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/images.rs)、
[ツール実装](https://github.com/openai/codex/blob/main/codex-rs/ext/image-generation/src/tool.rs)。

認証は Pi の `ctx.modelRegistry.getApiKeyForProvider("openai-codex")` を通す。
Pi がホストごとの認証ストア、`PI_CODING_AGENT_DIR`、ロック、期限切れの更新を扱う。
JWT の `claims["https://api.openai.com/auth"].chatgpt_account_id` をヘッダーに使う。
この claim がなければ API キーなど別認証では続行しない。

拡張は追加依存なしの Node.js / Pi API だけで動く。Pi の版は他の拡張と同じく
devbox/Dockerfile の PI_VERSION に従う。スキルはセットアップ時にリンクされ、
拡張は `bin/setup-pi.sh` がディレクトリ単位でリンクする。

バックエンド変更時は公開ソースと実際の HTTP 応答を確認する。
HTTP 403 は接続経路の拒否でも起きるため、トークンの権限不足と断定しない。
エラー本文・認証値はモデルへの結果やログに含めず、HTTP ステータスで報告する。
