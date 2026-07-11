const screenshots = {
  "zh-Hans": [
    ["每天的短信，分好类了", "01-dashboard.png"],
    ["经典或多语言，按需选择", "02-models.png"],
    ["规则，按你的方式", "03-rules.png"],
    ["分类结果，也能自定义", "04-mappings.png"],
    ["分享之前，先脱敏", "05-redaction.png"],
    ["数据由你掌控", "06-settings.png"],
  ],
  "en-US": [
    ["A quieter SMS inbox", "01-dashboard.png"],
    ["Classic or multilingual", "02-models.png"],
    ["Rules that fit you", "03-rules.png"],
    ["Map categories your way", "04-mappings.png"],
    ["Redact before sharing", "05-redaction.png"],
    ["Your data, your controls", "06-settings.png"],
  ],
  ja: [
    ["SMSをすっきり分類", "01-dashboard.png"],
    ["2つのモデルを選択", "02-models.png"],
    ["自分に合うルール", "03-rules.png"],
    ["カテゴリを自由に振り分け", "04-mappings.png"],
    ["共有前にマスキング", "05-redaction.png"],
    ["データは自分で管理", "06-settings.png"],
  ],
};

const params = new URLSearchParams(window.location.search);
const locale = params.get("locale") || "zh-Hans";
const requestedScreen = Number.parseInt(params.get("screen") || "1", 10);
const screen = Number.isFinite(requestedScreen)
  ? Math.min(Math.max(requestedScreen, 1), 6)
  : 1;
const [headline, filename] = screenshots[locale][screen - 1];

document.documentElement.lang = locale;
document.querySelector("#headline").textContent = headline;
document.querySelector("#sequence").textContent = `${String(screen).padStart(2, "0")} / 06`;
document.querySelector("#app-screenshot").src =
  `../../output/app-store/1.0/raw/${locale}/${filename}`;

window.appStoreAssetReady = document.querySelector("#app-screenshot").decode();
