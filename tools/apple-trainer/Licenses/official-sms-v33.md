# Official SMS template attribution (2026-10-29)

These are derived training **candidates**, not independently collected user SMS.
The source organisations do not endorse Sift or the modified examples. No logos,
images, recipient records or third-party attachments are included in the corpus.
The per-record originals, changes, labels and cached source/license hashes are in
[`public-sms-v33-review.json`](../Training/public-sms-v33-review.json).

## NHS England: two English templates

Source: [Writing NHS messages](https://service-manual.nhs.uk/content/writing-nhs-messages),
the two examples in the **Text message examples** section only.
Contains information licensed under the
[Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).
The [website terms](https://service-manual.nhs.uk/terms-and-conditions) explicitly
apply OGL v3.0 to website content; the repository's code licence is not used as
the content licence.

Reproducible source: `nhsuk/nhsuk-service-manual`, commit
`9dac6c2a4b90f7c0dbefe12a243efa36b06695a8`:

- `app/views/content/writing-nhs-messages.njk`, Git blob `a54da5951f404e811e9cf67c2e34ff8839c5a84d`.
- `app/views/terms-and-conditions.njk`, Git blob `ca34e9acf92561613cfda76f33183cf5b5d510a6`.

Changes: replace the name placeholders with fictional `Alex Morgan`; normalize
paragraph whitespace. Preserve the original two template URLs exactly. The
published example path is a template, not a claim that the service is live.

## City of Osaka: one Japanese tax template

出典：[大阪市・市税の納付勧奨SMS](https://www.city.osaka.lg.jp/zaisei/page/0000659692.html)
を加工して作成（Sift、2026-10-29）。
[大阪市利用規約](https://www.city.osaka.lg.jp/main/site_policy/0000000160.html)
permits reuse of the city's own HTML text with attribution and modification
notice, and states compatibility with CC BY 4.0. The exception for unlicensed
images and attachments is respected: this record uses the HTML message text.

Changes: fill the office slot with the publicly listed 梅田 office and replace
the phone slot with synthetic `06-0000-0000`. No URL is added.

## City of Kobe: one Japanese insurance template

出典：[神戸市・国民健康保険料のSMS通知](https://www.city.kobe.lg.jp/a52670/kenko/fukushi/kokuhonenkiniryou/20260316.html)
を加工して作成（Sift、2026-10-29）。
[神戸市ウェブサイト利用規約](https://www.city.kobe.lg.jp/documents/19135/20170630041802-1.pdf)
permits reuse, including commercial use, with source and modification notices,
and states compatibility with CC BY 4.0. Only the city's own HTML SMS text is
used; the PDF is retained locally solely as licence evidence.

Changes: replace the public service telephone with synthetic `078-000-0000`
and normalize whitespace. The entire SMS is retained, including its already-paid
caveat, contact hours and no-reply note. No URL is added.
