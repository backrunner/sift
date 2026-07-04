# CloudKit schema

`schema.ckdb` is the canonical schema for the `iCloud.com.alkinum.sift`
container. The `SmsSample` record type stores opt-in anonymous sanitized
samples in the **public database**:

- `text` — sanitized SMS body (never sender/account/device fields)
- `label` / `labelGroup` — taxonomy leaf and group ids
- `modelVersion` — classifier version active at submission time
- `predictedLabel` / `predictedConfidence` / `agreement` — the on-device
  model's own coarse classification of the submitted text; used by the
  training-side quality gate to weigh user/model disagreement (submissions
  are never blocked on it)
- `schemaVersion` — payload schema revision (currently `1`)
- `source` — client platform tag (`ios`)
- `locale` — coarse language/region tag such as `zh-CN`, used to balance
  multilingual training corpora
- `createdAt` — client epoch milliseconds; queryable + sortable so exports can
  paginate deterministically and filter incrementally

Permissions: any signed-in iCloud user can create records, only the creator
can modify/delete their own record, and reads require authentication.
`___createdBy` is marked QUERYABLE so the app can implement the GDPR flows
("export all my submissions" / "erase all my submissions") by querying the
current user's own records — no identity is ever stored in the payload.

`FilterStats` is the second record type: daily filtering counters the app
mirrors into each user's **private database** as a backup. It contains counts
only, never message content, and is invisible to the developer.

Import into the development environment with Xcode's `cktool`:

```bash
xcrun cktool save-schema \
  --team-id <TEAM_ID> \
  --container-id iCloud.com.alkinum.sift \
  --environment development \
  --file infra/cloudkit/schema.ckdb
```

then promote development → production from the CloudKit Console once
verified. Record-level security roles (`GRANT` lines) currently need a
one-time review in the Console after the first import.
