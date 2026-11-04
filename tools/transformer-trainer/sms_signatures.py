"""Conservative SMS-family signatures, including rehydrated numeric values.

Not a semantic similarity model: this detects dynamic-value template reuse.
Negations and other content words remain intact. Do not use it as a labeler.
"""
from __future__ import annotations

import html
import re
import unicodedata


# Scheme-free SMS links are common. Without this pass, identical templates
# with go.app/a versus trk.li/b evade both digit and whole-string isolation.
# Restrict bare hosts to common TLDs so 1.5GB, abbreviations and versions are
# not treated as URLs. Schemed URLs continue to accept arbitrary domains.
BARE_URL_PATTERN = re.compile(
    r"(?<![A-Za-z0-9_@.\-])(?:www\.)?"
    r"(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+"
    r"(?:com|net|org|info|biz|app|dev|io|co|me|ly|li|do|link|shop|site|xyz|top|cc|"
    r"cn|jp|vn|uk|us|id|kr|ru|fr|de|es|pt|th|tw|hk|sg|au|ca|gov|edu)"
    r"(?![A-Za-z0-9_\-])(?::\d{1,5})?(?:[/?#][^\s<>。！？，；、）》】]*)?",
    re.IGNORECASE,
)


def semantic_signature(text: str) -> str:
    text = unicodedata.normalize("NFKC", html.unescape(text)).casefold()
    text = re.sub(r"https?://[^\s<>]+|www\.[^\s<>]+|<(?:url|email_address)>", " dynamicurl ", text)
    text = BARE_URL_PATTERN.sub(" dynamicurl ", text)
    text = re.sub(r"\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b", " dynamicemail ", text)
    text = re.sub(r"\{\{(?:url|email)\}\}", " dynamicurl ", text)
    text = re.sub(r"\{\{(?:name|address)\}\}|<(?:named_entity|location)>", " dynamicname ", text)
    text = re.sub(r"\{\{[a-z_]+\}\}|<(?:#|decimal|date_time|phone_number|us_bank_number|us_driver_license|uk_nhs|nrp)>", " 0 ", text)
    text = re.sub(r'\b\d{1,4}[-/]\d{1,2}[-/]\d{1,4}\b',' 0 ',text)
    # Consume whole amounts, including grouped/decimal amounts, before phone
    # matching so e.g. USD 1,500.00 does not become a different token count.
    text = re.sub(r"(?:[$£€¥￥]|\b(?:usd|gbp|eur|rmb|cny|jpy)\s*)\s*\d+(?:[,.]\d+)*", " 0 ", text)
    text = re.sub(r'\d+(?:[,.]\d+)*\s*(?:vnd|vnđ|đồng|dong)\b',' 0 ',text)
    def phone(match):
        value = match.group()
        count = sum(c.isdigit() for c in value)
        return " 0 " if 7 <= count <= 15 else value
    text = re.sub(r"(?<![\w])\+?\d[\d ()-]{5,}\d(?![\w])", phone, text)
    text = re.sub(r"\d+(?:[,.]\d+)*", "0", text)
    return re.sub(r"[\W_]+", "", text, flags=re.UNICODE)
