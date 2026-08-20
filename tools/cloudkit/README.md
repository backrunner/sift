# @sift/cloudkit-tools

Exports opt-in anonymous `SmsSample` records from the CloudKit public database
into the framework-neutral `{"text": ..., "label": ...}` NDJSON corpus used by
`tools/apple-trainer` and `tools/transformer-trainer`.

## Setup

1. In the [CloudKit Console](https://icloud.developer.apple.com/) open the
   `iCloud.com.alkinum.sift` container → **API Access → Server-to-Server
   Keys** and create a key.
2. Save the private key PEM outside the repo (for example `~/.keys/sift-ck.pem`)
   and register the public key in the Console.
3. Import the schema once per environment: see `infra/cloudkit/README.md`.

## Usage

```bash
export CLOUDKIT_KEY_ID=<key id from the console>
export CLOUDKIT_PRIVATE_KEY=~/.keys/sift-ck.pem

# development environment, default output build/remote-training.ndjson
pnpm export:training

# production, custom output, incremental since a given instant
pnpm export:training -- --env production \
  --since 2026-06-01T00:00:00Z \
  --out ../../build/remote-training.ndjson

# keep metadata columns (locale, modelVersion, createdAt, recordNameHash)
pnpm export:training -- --env production --raw --out ../../build/remote-raw.ndjson
```

Rows contain `text`, `label`, a source marker (`cloudkit:development` or
`cloudkit:production`), optional device-detected `textLanguage`, and the
non-identifying assessment fields `predictedLabel`, `predictedConfidence`,
`agreement`, `modelVersion`, and `schemaVersion`. Every export runs a
dependency-free second redaction pass for URLs, contact values, identity and
payment values, cloud account/resource IDs, nicknames, and contextual QQ,
WeChat, Weibo, Xiaohongshu, Douyin, Kuaishou, Zhihu, LINE, Telegram, Discord,
WhatsApp, Facebook, Instagram, TikTok, and Twitter/X handles. The exporter never
writes a raw record name; `--raw` contains only a one-way `recordNameHash`.

Rows that still contain a detector hit after the second pass are dropped. The
export may contain `{{...}}` tokens from an earlier on-device sanitizer; those
tokens are an intermediate representation only. Curation must reverse-redact
them with deterministic synthetic values and rejects any output that still
contains a token before model training. Rejected remote rows contain only a
hash and length, never their text. Curation validates and downsamples
high-confidence disagreements before emitting training-only `text`/`label`
rows.
They are validated against `packages/taxonomy/taxonomy.json`, deduplicated on
`label + text`, and length-filtered (8–500 characters) so the file can feed the
curation pipeline directly:

```bash
cd tools/apple-trainer
swift run SiftAppleTrainer --input ../../build/remote-training.ndjson --out ../../build/apple-model
```

`--raw` adds the remaining curation metadata, including locale, model version,
agreement, timestamps, and `recordNameHash` for audit correlation. It never
includes creator identity or the raw CloudKit record name.
