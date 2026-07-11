# App Store Screenshot Assets

The source screenshots under `output/app-store/1.0/raw/` come from the real
Sift app running in iPhone Simulator. The HTML template only adds the localized
headline, sequence indicator, background, and framing.

Generate all 18 screenshots at 1320 x 2868:

```bash
bash tools/app-store-assets/render.sh
```

Open a single composition for editing:

```text
tools/app-store-assets/index.html?locale=zh-Hans&screen=1
```

Supported locales are `zh-Hans`, `en-US`, and `ja`. Keep screenshot order and
headlines synchronized in `screenshots.js`.

## Git Policy

The HTML, CSS, JavaScript, and render script are reusable release tooling and
belong in the repository. Raw Simulator captures, rendered screenshots,
localized submission copy, and other generated deliverables live under
`output/`, which is intentionally ignored by Git.
