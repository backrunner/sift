import { strict as assert } from "node:assert";
import { test } from "node:test";
import { residualSensitiveKinds, sanitizeText } from "../privacy-redaction.ts";

test("redacts contextual CloudKit account, nickname, resource, and URL values", () => {
  const input =
    "云服务账号ID：acct-synthetic-568******，昵称：DemoUser，实例ID:cdb-demo1234，请访问 https://cloud.example/renew。";
  const result = sanitizeText(input);

  assert.equal(
    result.text,
    "云服务账号ID：{{ID}}，昵称：{{NAME}}，实例ID:{{ID}}，请访问 {{URL}}。",
  );
  assert.deepEqual(new Set(result.kinds), new Set(["id", "name", "url"]));
  assert.deepEqual(residualSensitiveKinds(result.text), []);
  assert.equal(result.text.includes("acct-synthetic-568******"), false);
  assert.equal(result.text.includes("DemoUser"), false);
  assert.equal(result.text.includes("cdb-demo1234"), false);
});

test("redacts QQ and WeChat handles only with social-account context", () => {
  const result = sanitizeText("客服QQ号：12345****，微信号: demo_user_7，微博ID：demo_weibo_8；状态码 WK88421 已完成。");

  assert.equal(result.text, "客服QQ号：{{ID}}，微信号: {{ID}}，微博ID：{{ID}}；状态码 WK88421 已完成。");
  assert.equal(result.text.includes("WK88421"), true);
});

test("redacts @handles and keeps the captured value span exact", () => {
  assert.equal(
    sanitizeText("Instagram handle: @safe_user_77；WeChat ID: WeChat").text,
    "Instagram handle: {{ID}}；WeChat ID: {{ID}}",
  );
});

test("covers the supported Chinese and international social labels", () => {
  const handles = [
    "demo_xhs_7",
    "demo_dy_7",
    "demo_ks_7",
    "demo_zh_7",
    "demo_wa_7",
    "demo_tt_7",
    "demo_tw_7",
    "demo_x_77",
  ];
  const result = sanitizeText(
    "小红书号：demo_xhs_7，抖音号：demo_dy_7，快手号：demo_ks_7，知乎号：demo_zh_7；"
      + "WhatsApp ID: demo_wa_7，TikTok username: demo_tt_7，Twitter handle: demo_tw_7，X ID: demo_x_77",
  );
  assert.equal(result.redactions.length, handles.length);
  for (const handle of handles) assert.equal(result.text.includes(handle), false);
});

test("keeps product/build identifiers and ordinary quantities", () => {
  const samples = [
    "QQ音乐活动编号 12345678 已发布。",
    "Build wxid_demo_7 passed the release check.",
    "Product code SKU-4821 is active.",
    "本次活动共有2,345名参与者。",
    "QQ account available for support; no handle is shown.",
    "WeChat username is active in the settings panel.",
  ];
  for (const sample of samples) assert.equal(sanitizeText(sample).text, sample);
});

test("redacts masked-prefix cloud account IDs", () => {
  assert.equal(
    sanitizeText("云资源账号：****acct-safe-31，昵称：合成用户。").text,
    "云资源账号：{{ID}}，昵称：{{NAME}}。",
  );
});

test("redacts Japanese contextual identifiers", () => {
  assert.equal(
    sanitizeText("表示名：テスト利用者、アカウントID：acct-ja-55、インスタンスID：db-ja-55。").text,
    "表示名：{{NAME}}、アカウントID：{{ID}}、インスタンスID：{{ID}}。",
  );
});

test("trims URL punctuation without retaining the original value", () => {
  const result = sanitizeText("详情见 https://example.invalid/path，感谢。");
  assert.equal(result.text, "详情见 {{URL}}，感谢。");
  assert.deepEqual(residualSensitiveKinds(result.text), []);
});
