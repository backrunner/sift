import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from privacy_redaction import residual_sensitive_kinds, sanitize_text  # noqa: E402


class PrivacyRedactionTests(unittest.TestCase):
    def test_second_pass_catches_partially_masked_cloud_identifiers(self) -> None:
        text = (
            "云服务账号ID：acct-synthetic-568******，昵称：DemoUser，实例ID:cdb-demo1234，"
            "请访问 https://cloud.example/renew。"
        )

        result = sanitize_text(text)

        self.assertEqual(
            result.text,
            "云服务账号ID：{{ID}}，昵称：{{NAME}}，实例ID:{{ID}}，请访问 {{URL}}。",
        )
        self.assertEqual({redaction.kind for redaction in result.redactions}, {"id", "name", "url"})
        self.assertNotIn("acct-synthetic-568******", result.text)
        self.assertNotIn("DemoUser", result.text)
        self.assertNotIn("cdb-demo1234", result.text)
        self.assertEqual(residual_sensitive_kinds(result.text), ())

    def test_account_suffix_is_redacted_only_with_account_context(self) -> None:
        self.assertIn("{{ID}}", sanitize_text("银行卡尾号4821已扣款。 ").text)
        self.assertEqual(
            sanitize_text("产品型号尾号4821是本周目录编号。 ").text,
            "产品型号尾号4821是本周目录编号。 ",
        )

    def test_public_build_identifiers_are_not_treated_as_account_ids(self) -> None:
        text = "Build identifier release-2026.4 passed; product code SKU-4821 is active."
        self.assertEqual(sanitize_text(text).text, text)

    def test_social_accounts_are_redacted_only_with_explicit_context(self) -> None:
        text = "客服QQ号：12345****，微信号: demo_user_7，微博ID：demo_weibo_8；状态码 WK88421 已完成。"
        result = sanitize_text(text)

        self.assertEqual(
            result.text,
            "客服QQ号：{{ID}}，微信号: {{ID}}，微博ID：{{ID}}；状态码 WK88421 已完成。",
        )
        self.assertEqual({redaction.kind for redaction in result.redactions}, {"id"})
        self.assertNotIn("12345****", result.text)
        self.assertNotIn("demo_user_7", result.text)
        self.assertNotIn("demo_weibo_8", result.text)
        self.assertIn("WK88421", result.text)

    def test_masked_prefix_account_ids_are_redacted(self) -> None:
        result = sanitize_text("云资源账号：****acct-safe-31，昵称：合成用户。")
        self.assertEqual(result.text, "云资源账号：{{ID}}，昵称：{{NAME}}。")

    def test_at_handles_and_repeated_context_are_redacted(self) -> None:
        result = sanitize_text("Instagram handle: @safe_user_77；WeChat ID: WeChat")
        self.assertEqual(result.text, "Instagram handle: {{ID}}；WeChat ID: {{ID}}")

    def test_supported_chinese_and_international_social_labels_are_redacted(self) -> None:
        text = (
            "小红书号：demo_xhs_7，抖音号：demo_dy_7，快手号：demo_ks_7，知乎号：demo_zh_7；"
            "WhatsApp ID: demo_wa_7，TikTok username: demo_tt_7，Twitter handle: demo_tw_7，X ID: demo_x_77"
        )
        result = sanitize_text(text)
        self.assertEqual(len(result.redactions), 8)
        for handle in ("demo_xhs_7", "demo_dy_7", "demo_ks_7", "demo_zh_7", "demo_wa_7", "demo_tt_7", "demo_tw_7", "demo_x_77"):
            self.assertNotIn(handle, result.text)

    def test_japanese_contextual_identifiers_are_redacted(self) -> None:
        result = sanitize_text("表示名：テスト利用者、アカウントID：acct-ja-55、インスタンスID：db-ja-55。")
        self.assertEqual(result.text, "表示名：{{NAME}}、アカウントID：{{ID}}、インスタンスID：{{ID}}。")

    def test_social_like_values_without_context_are_not_redacted(self) -> None:
        samples = [
            "QQ音乐活动编号 12345678 已发布。",
            "Build wxid_demo_7 passed the release check.",
            "微博热搜活动编号 12345678 已发布。",
            "TikTok app version 12.4 is available in the catalog.",
            "QQ account available for support; no handle is shown.",
            "WeChat username is active in the settings panel.",
            "状态码 demo_user_7 已完成。",
            "产品代码 12345**** 仅用于测试。",
        ]
        for sample in samples:
            self.assertEqual(sanitize_text(sample).text, sample)


if __name__ == "__main__":
    unittest.main()
