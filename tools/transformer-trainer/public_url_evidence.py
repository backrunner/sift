"""Preserve reviewed public hosts without retaining URL identifiers.

This is a data-rendering contract, not a runtime domain allowlist. No URL is
fetched and no legitimacy is inferred from a brand name or hostname.
"""
from __future__ import annotations

import re
from urllib.parse import urlsplit

# Unlike a phishing labeler, require a reviewer to enumerate every host.
URL = re.compile(
    r"(?<![\w@.-])(?:https?://|https?//|www\.)[^\s<>]+|"
    r"(?<![\w@.-])(?:[a-z0-9-]+\.)+(?:com|vn|net|org|online|health|top|vip|xyz|win|club|bet|co|jp|link|ly)(?![\w-]|\.[\w-])(?:/[^\s<>]*)?",
    re.I,
)


def public_urls(text: str) -> list[tuple[int, int, str, str]]:
    """Return spans, normalized hosts and identifier-free URL roots.

    Preserve http/https/bare shape. A truncated or anonymized host cannot be
    reconstructed. Missing schemes such as https// are corrected explicitly.
    """
    found=[]
    for match in URL.finditer(text):
        value=match.group().rstrip('.,;!?)\"\'】]')
        value=re.sub(r'^https?//',lambda m:m[0][:-2]+'://',value,flags=re.I)
        parsed=urlsplit(value if re.match(r'^https?://',value,re.I) else 'https://'+value)
        host=parsed.hostname
        if parsed.username or parsed.password or not host or not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,24}',host,re.I):
            raise ValueError('redacted, credentialed or malformed public host')
        if re.search(r'\d{7,}',host) or any(len(part)>=25 and any(c.isdigit() for c in part) for part in host.split('.')):
            raise ValueError('potential identifier in public host')
        scheme=parsed.scheme+'://' if re.match(r'^https?://',value,re.I) else ''
        root=scheme+host.lower()+'/'
        found.append((match.start(),match.start()+len(match.group().rstrip('.,;!?)\"\'】]')),host.lower(),root))
    return found


def mask_reviewed_urls(text: str, approved_hosts: list[str]) -> tuple[str, list[str]]:
    if 'SIFTPUBLICURLSLOT' in text:raise ValueError('reserved URL slot in source')
    urls=public_urls(text)
    actual=sorted({r[2] for r in urls})
    if actual!=sorted(set(approved_hosts)):raise ValueError('public host review differs from source')
    for i,(start,end,_,_) in reversed(list(enumerate(urls))):
        text=text[:start]+f'SIFTPUBLICURLSLOT{i}END'+text[end:]
    return text,[r[3] for r in urls]


def restore_urls(text: str, roots: list[str]) -> str:
    for i,root in enumerate(roots):
        slot=f'SIFTPUBLICURLSLOT{i}END'
        if text.count(slot)!=1:raise ValueError('public URL slot lost during sanitization')
        text=text.replace(slot,root)
    return text


def restore_existing_render(rendered: str, original: str, approved_hosts: list[str]) -> str:
    """Repair only old fabricated URLs, preserving earlier text/label repairs."""
    _,roots=mask_reviewed_urls(original,approved_hosts)
    fabricated=list(re.finditer(r'https://example\.com/m/\d+',rendered))
    if len(fabricated)!=len(roots):raise ValueError('source and fabricated URL counts differ')
    for match,root in reversed(list(zip(fabricated,roots))):
        rendered=rendered[:match.start()]+root+rendered[match.end():]
    return rendered
