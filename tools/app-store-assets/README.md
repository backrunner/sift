# App Store Screenshot Assets

The source screenshots under `output/app-store/1.0/raw/` come from the real
Sift app running in iPhone Simulator. The HTML template only adds the localized
headline, background, and framing.

Generate all 18 screenshots at the App Store Connect-compatible 1320 x 2868
portrait size for 6.9-inch iPhones:

```bash
bash tools/app-store-assets/render.sh
```

The current render is written to `output/app-store/1.0/final-v3/`, preserving
the previous deliveries.

Open a single composition for editing:

```text
tools/app-store-assets/index.html?locale=zh-Hans&screen=1
```

Supported locales are `zh-Hans`, `en-US`, and `ja`. Keep screenshot order and
headlines synchronized in `screenshots.js`.

Each locale contains six static screenshots, which is within App Store
Connect's limit of ten screenshots. This tool does not generate App Preview
videos; App Previews have a separate limit of three per device size and locale.

## Git Policy

The HTML, CSS, JavaScript, and render script are reusable release tooling and
belong in the repository. Raw Simulator captures, rendered screenshots,
localized submission copy, and other generated deliverables live under
`output/`, which is intentionally ignored by Git.
