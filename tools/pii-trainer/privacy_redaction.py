#!/usr/bin/env python3
"""Portable, conservative second-pass redaction for training corpora.

The iOS sanitizer remains the production source of truth.  This module is a
defence-in-depth copy of the high-risk contextual rules used by the export and
curation tools.  It deliberately emits the same placeholders as
``PrivacySanitizer`` and never returns the original value in an audit result.
"""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Iterable


PLACEHOLDER_PATTERN = re.compile(
    r"\{\{(PHONE|URL|EMAIL|ADDRESS|CARD|ID|ORDER_ID|AMOUNT|CODE|PLATE|NAME)\}\}"
)
ANY_PLACEHOLDER_PATTERN = re.compile(r"\{\{[^{}\n]{1,64}\}\}")

# The order is also used when two detectors overlap.  A URL or a complete
# account identifier must win over a weaker generic number match.
TOKEN_PRIORITY = (
    "{{URL}}",
    "{{EMAIL}}",
    "{{PHONE}}",
    "{{CARD}}",
    "{{ID}}",
    "{{ADDRESS}}",
    "{{ORDER_ID}}",
    "{{AMOUNT}}",
    "{{CODE}}",
    "{{NAME}}",
)


@dataclass(frozen=True)
class Redaction:
    start: int
    end: int
    token: str

    @property
    def kind(self) -> str:
        return self.token.removeprefix("{{").removesuffix("}}").lower()


@dataclass(frozen=True)
class SanitizationResult:
    text: str
    redactions: tuple[Redaction, ...]

    @property
    def changed(self) -> bool:
        return bool(self.redactions)

    @property
    def kinds(self) -> tuple[str, ...]:
        return tuple(dict.fromkeys(redaction.kind for redaction in self.redactions))


def _regex_redactions(
    text: str,
    pattern: re.Pattern[str],
    token: str,
    group: int = 0,
) -> Iterable[Redaction]:
    for match in pattern.finditer(text):
        start, end = match.span(group)
        if start >= end:
            continue
        yield Redaction(start, end, token)


CONTEXTUAL_STOPWORDS = {
    "account", "active", "available", "online", "offline", "pending", "status",
    "number", "username", "handle", "music", "version", "is", "are", "none",
    "null", "已绑定", "已认证", "已登录", "状态", "可用", "在线", "离线",
}


def _plausible_contextual_value(value: str) -> bool:
    normalized = value.strip().casefold()
    if not normalized or normalized in CONTEXTUAL_STOPWORDS:
        return False
    return any(character.isalnum() for character in normalized)


def _contextual_regex_redactions(
    text: str,
    pattern: re.Pattern[str],
    token: str,
    group: int,
) -> Iterable[Redaction]:
    for match in pattern.finditer(text):
        value = match.group(group)
        if not _plausible_contextual_value(value):
            continue
        start, end = match.span(group)
        if start < end:
            yield Redaction(start, end, token)


URL = re.compile(r"(?<![A-Za-z0-9])https?://[^\s<>\"'（）()\[\]{},，。！？；：、]+", re.IGNORECASE)
EMAIL = re.compile(r"(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}(?![A-Za-z0-9.-])")
PHONE = re.compile(r"(?<![\dA-Za-z])\+?\d[\d ()\-]{5,}\d(?![\dA-Za-z])")
CARD = re.compile(r"(?<!\d)(?:\d[ -]?){15,18}\d(?!\d)")
CHINESE_ID = re.compile(
    r"(?<![0-9Xx])\d{6}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:[0-2]\d|3[01])\d{3}[\dXx](?![0-9Xx])"
)
CHINESE_ID_OLD = re.compile(r"(?<!\d)\d{6}\d{2}(?:0[1-9]|1[0-2])(?:[0-2]\d|3[01])\d{3}(?!\d)")
PASSPORT = re.compile(r"(?<![A-Za-z0-9])[EG][A-Z]?\d{8}(?![A-Za-z0-9])", re.IGNORECASE)

# These are intentionally contextual.  A bare product/build identifier is
# useful classifier evidence and must not be erased by the fallback audit.
ACCOUNT_ID = re.compile(
    r"(?:账号(?:\s*(?:id|编号|号码))?|账户(?:\s*(?:id|编号|号码))?|"
    r"用户账号|客户账号|account\s+(?:id|number|no\.?)|"
    r"user\s+(?:id|number|no\.?)|customer\s+(?:id|number|no\.?)|"
    r"アカウント(?:\s*(?:ID|番号))?|ユーザー(?:\s*(?:ID|番号))|顧客番号|"
    r"(?:account|user|customer)(?=\s*[:：=#]))"
    r"\s*[:：=#]?\s*((?:[A-Za-z0-9][A-Za-z0-9_*.-]{2,}|[*#][A-Za-z0-9_*.-]{2,}))(?![A-Za-z0-9_*.-])",
    re.IGNORECASE,
)
ACCOUNT_SUFFIX = re.compile(r"(?:账户|账号|银行卡|信用卡)\s*尾号\s*([0-9]{4,8})(?!\d)", re.IGNORECASE)
RESOURCE_ID = re.compile(
    r"(?:实例\s*(?:ID|编号)|资源\s*(?:ID|编号)|项目\s*(?:ID|编号)|"
    r"云数据库实例|database\s+instance|instance\s+id|resource\s+id|project\s+id|"
    r"インスタンス\s*ID|リソース\s*ID|プロジェクト\s*ID)"
    r"\s*[:：=#]?\s*([A-Za-z][A-Za-z0-9_-]{3,})(?![A-Za-z0-9_-])",
    re.IGNORECASE,
)
# Social handles are deliberately contextual.  A bare number, SKU, build
# identifier, or short Latin word is useful classifier evidence and must stay
# visible; only a value introduced as a QQ/WeChat/social account is redacted.
SOCIAL_ACCOUNT = re.compile(
    r"(?:QQ(?:\s*(?:号|号码|番号|账号|帐号|ID|number|account)|\s*[:：=])|"
    r"微信(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|"
    r"微博(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|"
    r"小红书(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|"
    r"抖音(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|"
    r"快手(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|"
    r"知乎(?:\s*(?:号|号码|账号|帐号|ID)|\s*[:：=])|"
    r"WeChat(?:\s*(?:ID|account|username))?|"
    r"(?:LINE|Telegram|Discord|WhatsApp|Facebook|Instagram|TikTok|Twitter)\s*(?:ID|账号|帐号|username|handle|tag|account)|"
    r"X\s*(?:ID|username|handle))"
    r"\s*(?:是|为|：|:|=|#)?\s*"
    r"(@?(?:[A-Za-z0-9][A-Za-z0-9_*#._-]{4,31}|[*#][A-Za-z0-9_*#._-]{4,31}))(?![A-Za-z0-9_*#._-])",
    re.IGNORECASE,
)
NICKNAME = re.compile(
    r"(?:(?:昵称|用户名|显示名|称呼|ニックネーム|ユーザー名|表示名)\s*[:：=]?|"
    r"(?:nickname|username|display\s+name)\s*[:：=])"
    r"\s*([^,，、。；;：:\n()（）]{1,40})",
    re.IGNORECASE,
)
AMOUNT = re.compile(
    r"(?:[¥￥$€£]|(?:RMB|CNY|USD|EUR|GBP|JPY)(?![A-Z]))\s*"
    r"(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d{1,2})?"
    r"|(?<!\d)(?:\d{1,3}(?:[,，]\d{3})+|\d+)(?:\.\d{1,2})?\s*"
    r"(?:元|块|円|USD|EUR|GBP|JPY)(?![A-Z])",
    re.IGNORECASE,
)
CODE = re.compile(
    r"(?:验证码|校验码|动态码|安全码|确认码|認証コード|確認コード|"
    r"verification\s+code|security\s+code|one[- ]time\s+(?:code|password)|otp|passcode)"
    r"\s*(?:是|为|：|:|is|は)?\s*([A-Z0-9-]{4,10})(?![A-Z0-9-])",
    re.IGNORECASE,
)
ORDER_ID = re.compile(
    r"(?:订单号|订单编号|运单号|快递单号|流水号|取件码|注文番号|追跡番号|"
    r"order(?:\s+id|\s+number)?|tracking(?:\s+id|\s+number)?)"
    r"\s*(?:是|为|：|:|#)?\s*([A-Z0-9-]{4,24})(?![A-Z0-9-])",
    re.IGNORECASE,
)


def _plausible_phone(value: str) -> bool:
    digits = [character for character in value if character.isdigit()]
    if not 7 <= len(digits) <= 15:
        return False
    # Short, unformatted numeric strings are much more often order numbers,
    # dates, or product content than phone numbers.  Keep them for an explicit
    # phone/`+` context; international and Chinese mobile formats remain
    # covered by a leading plus, separators, or the canonical 11 digits.
    if len(digits) < 11 and "+" not in value and not any(mark in value for mark in (" ", "-", "(", ")")):
        return False
    return not (len(digits) == 8 and value.count("-") == 2 and "." not in value)


def _passes_luhn(value: str) -> bool:
    digits = [int(character) for character in value if character.isdigit()]
    if not 13 <= len(digits) <= 19:
        return False
    total = 0
    parity = len(digits) % 2
    for index, digit in enumerate(digits):
        if index % 2 == parity:
            digit *= 2
            if digit > 9:
                digit -= 9
        total += digit
    return total % 10 == 0


def _outside_placeholders(text: str, start: int, end: int) -> bool:
    return not any(match.start() < end and start < match.end() for match in PLACEHOLDER_PATTERN.finditer(text))


def _collect(text: str) -> list[Redaction]:
    redactions: list[Redaction] = []
    for pattern, token in (
        (EMAIL, "{{EMAIL}}"),
        (CHINESE_ID, "{{ID}}"),
        (CHINESE_ID_OLD, "{{ID}}"),
        (PASSPORT, "{{ID}}"),
    ):
        redactions.extend(_regex_redactions(text, pattern, token))

    for match in URL.finditer(text):
        end = match.end()
        while end > match.start() and text[end - 1] in ".,!?;:，。！？；：、)]}>":
            end -= 1
        if end > match.start():
            redactions.append(Redaction(match.start(), end, "{{URL}}"))

    for match in CARD.finditer(text):
        value = match.group(0)
        if _passes_luhn(value):
            redactions.append(Redaction(match.start(), match.end(), "{{CARD}}"))

    for match in PHONE.finditer(text):
        value = match.group(0)
        if _plausible_phone(value):
            redactions.append(Redaction(match.start(), match.end(), "{{PHONE}}"))

    for pattern, token, group in (
        (ACCOUNT_ID, "{{ID}}", 1),
        (ACCOUNT_SUFFIX, "{{ID}}", 1),
        (RESOURCE_ID, "{{ID}}", 1),
        (SOCIAL_ACCOUNT, "{{ID}}", 1),
        (NICKNAME, "{{NAME}}", 1),
        (CODE, "{{CODE}}", 1),
        (ORDER_ID, "{{ORDER_ID}}", 1),
        (AMOUNT, "{{AMOUNT}}", 0),
    ):
        if token in ("{{ID}}", "{{NAME}}") and pattern in (ACCOUNT_ID, SOCIAL_ACCOUNT, NICKNAME):
            redactions.extend(_contextual_regex_redactions(text, pattern, token, group))
        else:
            redactions.extend(_regex_redactions(text, pattern, token, group))

    return [redaction for redaction in redactions if _outside_placeholders(text, redaction.start, redaction.end)]


def _priority(token: str) -> int:
    try:
        return TOKEN_PRIORITY.index(token)
    except ValueError:
        return len(TOKEN_PRIORITY)


def _merge(redactions: Iterable[Redaction]) -> list[Redaction]:
    ordered = sorted(redactions, key=lambda item: (item.start, item.end - item.start, _priority(item.token)))
    merged: list[Redaction] = []
    for candidate in ordered:
        if not merged or candidate.start >= merged[-1].end:
            merged.append(candidate)
            continue
        previous = merged[-1]
        start = min(previous.start, candidate.start)
        end = max(previous.end, candidate.end)
        token = previous.token if _priority(previous.token) <= _priority(candidate.token) else candidate.token
        merged[-1] = Redaction(start, end, token)
    return merged


def sanitize_text(text: str) -> SanitizationResult:
    """Redact high-risk values while preserving surrounding classifier text."""
    redactions = _merge(_collect(text))
    if not redactions:
        return SanitizationResult(text, ())
    output = text
    for redaction in reversed(redactions):
        output = output[: redaction.start] + redaction.token + output[redaction.end :]
    return SanitizationResult(output, tuple(redactions))


def residual_sensitive_kinds(text: str) -> tuple[str, ...]:
    """Return high-risk detector kinds still present after one redaction pass."""
    return tuple(dict.fromkeys(redaction.kind for redaction in _merge(_collect(text))))


def is_remote_source(source: str) -> bool:
    lowered = source.casefold().strip()
    # CloudKit exports use an explicit `cloudkit:<environment>` marker, while
    # older pipeline snapshots only carried a remote-training filename.  Keep
    # the broad filename forms here so a caller cannot accidentally bypass the
    # second pass by renaming an export file.
    return (
        "cloudkit" in lowered
        or "remote-training" in lowered
        or "remote_training" in lowered
        or "user-sample" in lowered
        or "user_sample" in lowered
        or lowered.startswith("remote")
        or ".remote." in lowered
    )
