"""Offline grouping for reviewed SMS, independent of unrelated numeric row IDs.

Public suffix rules include private domains. URL paths are never fetched.
Connected components deliberately over-group shared infrastructure. This does
not establish complete semantic independence or certify a message's label.
"""
import html
import re
import unicodedata
from urllib.parse import urlsplit

from sms_signatures import semantic_signature

URL = re.compile(r'(?<![\w@.-])(?:https?://)?(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,24}(?![\w-])(?::\d{1,5})?(?:[/?#][^\s<>。！？，；、）》】]*)?', re.I)


class Suffixes:
    def __init__(self, text):
        self.rules = {line.strip().casefold() for line in text.splitlines()
                      if line.strip() and not line.startswith('//')}
        self.tlds = {r.split('.')[-1] for r in self.rules}

    def registrable(self, host):
        parts = host.lower().rstrip('.').split('.')
        suffix = 1
        for i in range(len(parts)):
            tail = '.'.join(parts[i:])
            if '!' + tail in self.rules:
                suffix = len(parts) - i - 1
                break
            if tail in self.rules or (i + 1 < len(parts) and '*.' + '.'.join(parts[i+1:]) in self.rules):
                suffix = max(suffix, len(parts) - i)
        return '.'.join(parts[-min(len(parts), suffix+1):])


def links(text, suffixes):
    result = []
    for m in URL.finditer(html.unescape(text)):
        value = m.group().rstrip('.,;!?)\"\'')
        host = urlsplit(value if '://' in value else 'https://' + value).hostname
        if host and host.split('.')[-1].lower() in suffixes.tlds:
            result.append((m.start(), m.end(), host.lower()))
    return result


def family(text, suffixes):
    text = unicodedata.normalize('NFKC', html.unescape(text))
    for start, end, _ in reversed(links(text, suffixes)):
        text = text[:start] + ' dynamicurl ' + text[end:]
    text = re.sub(r'#(?:URL|OTP|ID)\b', lambda m: ' dynamicurl ' if m[0] == '#URL' else ' 0 ', text)
    return semantic_signature(text)


def shingles(text, suffixes):
    value = family(text, suffixes)
    return {value[i:i+3] for i in range(max(0, len(value)-2))}


def similar(a, b, threshold=.65):
    if not a or not b or min(len(a), len(b)) / max(len(a), len(b)) < threshold:
        return False
    intersection = len(a & b)
    return intersection / (len(a) + len(b) - intersection) >= threshold


class Groups:
    def __init__(self):
        self.parent = {}

    def find(self, key):
        self.parent.setdefault(key, key)
        while key != self.parent[key]:
            self.parent[key] = self.parent[self.parent[key]]
            key = self.parent[key]
        return key

    def union(self, keys):
        roots = {self.find(k) for k in keys}
        root = min(roots)
        for other in roots:
            self.parent[other] = root
        return root
