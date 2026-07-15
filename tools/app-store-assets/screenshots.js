const screenshots = {
  "zh-Hans": [
    ["智能过滤短信，少一点打扰", "01-dashboard.png"],
    ["双模型过滤，兼顾轻量与多语言", "02-models.png"],
    ["允许或阻止，过滤规则由你定", "03-rules.png"],
    ["分类映射，让过滤更合心意", "04-mappings.png"],
    ["个人信息先脱敏，再匿名提交", "05-redaction.png"],
    ["本地处理优先，数据始终可控", "06-settings.png"],
  ],
  "en-US": [
    ["Filter SMS. Cut the noise.", "01-dashboard.png"],
    ["Two models for smarter filtering", "02-models.png"],
    ["Allow or block. Your rules.", "03-rules.png"],
    ["Map every category your way", "04-mappings.png"],
    ["Redact personal details before sharing", "05-redaction.png"],
    ["On-device by default. In your control.", "06-settings.png"],
  ],
  ja: [
    ["SMSを賢くフィルタリング", "01-dashboard.png"],
    ["2つのモデルで、多言語SMSも分類", "02-models.png"],
    ["許可もブロックも、自分のルールで", "03-rules.png"],
    ["カテゴリごとに、振り分け先を設定", "04-mappings.png"],
    ["個人情報をマスキングしてから共有", "05-redaction.png"],
    ["基本は端末内処理。データは自分で管理", "06-settings.png"],
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
document.querySelector("#app-screenshot").src =
  `../../output/app-store/1.0/raw/${locale}/${filename}`;

window.appStoreAssetReady = document.querySelector("#app-screenshot").decode();
