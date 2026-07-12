const screenshots = {
  "zh-Hans": [
    ["短信再多，也能一眼看清", "01-dashboard.png"],
    ["两种模型，各有所长", "02-models.png"],
    ["你的短信，你定规则", "03-rules.png"],
    ["每一类，都有它的去处", "04-mappings.png"],
    ["分享内容，不分享隐私", "05-redaction.png"],
    ["数据始终在你手里", "06-settings.png"],
  ],
  "en-US": [
    ["Your inbox, already sorted", "01-dashboard.png"],
    ["Choose the model that fits", "02-models.png"],
    ["Your messages. Your rules.", "03-rules.png"],
    ["Every category in its place", "04-mappings.png"],
    ["Share the message, not the details", "05-redaction.png"],
    ["Your data stays yours", "06-settings.png"],
  ],
  ja: [
    ["届くSMSを、すっきり整理", "01-dashboard.png"],
    ["SMSに合うモデルを選べる", "02-models.png"],
    ["ルールは、自分好みに", "03-rules.png"],
    ["カテゴリの行き先も自由に", "04-mappings.png"],
    ["共有前に、個人情報だけ伏せる", "05-redaction.png"],
    ["データを残すか、消すかも自由", "06-settings.png"],
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
