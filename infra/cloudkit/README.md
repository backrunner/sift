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

`FilterStats` remains in `schema.ckdb` only because CloudKit doesn't permit
deleting a record type after it becomes active in production. The app no longer
reads or writes this legacy type. A future clean container can omit it.

## Syncing the schema

CloudKit does not read `schema.ckdb` from git automatically. Treat this file as
the repo source of truth, then push it to the CloudKit **development**
environment and deploy the accepted changes to **production** from the CloudKit
Console.

Validate the checked-in schema against the development environment:

```bash
xcrun cktool validate-schema \
  --team-id <TEAM_ID> \
  --container-id iCloud.com.alkinum.sift \
  --environment development \
  --file infra/cloudkit/schema.ckdb
```

Import it into the development environment with Xcode's `cktool`:

```bash
xcrun cktool import-schema \
  --team-id <TEAM_ID> \
  --container-id iCloud.com.alkinum.sift \
  --environment development \
  --validate \
  --file infra/cloudkit/schema.ckdb
```

After importing, open the [CloudKit Console](https://icloud.developer.apple.com/)
for `iCloud.com.alkinum.sift`, verify the record types and security roles in
Development, then deploy/promote the development schema changes to Production.
Record-level security roles (`GRANT` lines) currently need a one-time review in
the Console after the first import.

For release sanity checks, export both environments and diff them:

```bash
mkdir -p build/cloudkit
xcrun cktool export-schema \
  --team-id <TEAM_ID> \
  --container-id iCloud.com.alkinum.sift \
  --environment development \
  --output-file build/cloudkit/development.ckdb
xcrun cktool export-schema \
  --team-id <TEAM_ID> \
  --container-id iCloud.com.alkinum.sift \
  --environment production \
  --output-file build/cloudkit/production.ckdb
diff -u build/cloudkit/development.ckdb build/cloudkit/production.ckdb
```

Production TestFlight/App Store builds write to the production CloudKit
environment, so schema changes must be deployed to Production before relying on
new record types, fields, indexes, or permissions in TestFlight.
