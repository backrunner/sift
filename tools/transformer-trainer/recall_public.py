"""Conservative review rendering and independent-family keys for recall studies.

Only message text is read. Public URL hosts are retained as attack evidence;
paths, queries, identifiers and redacted numeric values are never recovered.
"""
import hashlib
import re
import unicodedata
from urllib.parse import urlsplit

from sms_signatures import semantic_signature


def digest(text):return hashlib.sha256(text.encode()).hexdigest()


URL=re.compile(r'https?://[^\s<>\[\]。！？；，]+|(?<![\w@])(?:[a-z0-9-]+\.)+(?:com|vn|net|org|top|vip|xyz|win|club|bet|co|jp)(?:/[^\s<>\[\]]*)?',re.I)


def render(text,language):
    text=re.sub(r'\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b','sample@example.com',text,flags=re.I)
    text=re.sub(r'(Tôi là\s+)[^\s]+(?=\s*-)',r'\1cán bộ hỗ trợ',text)
    if re.search(r'\[(?:NUMBER|TIME)\]',text):raise ValueError('ambiguous source number/time roles')
    if re.search(r'https?://[^\s<>]*\[[A-Z_]+\]|https?://[^\s<>]+\s+(?:vip|top|com|net)\b',text,re.I):
        raise ValueError('redacted/truncated public host')
    hosts=[]
    def url(match):
        value=match.group().rstrip('.,;!?)')
        host=urlsplit(value if '://' in value else 'https://'+value).hostname
        if not host or len(host)>120 or not re.fullmatch(r'(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}',host,re.I):
            raise ValueError('malformed public host')
        if re.search(r'\d{7,}|[a-z0-9]{25}',host,re.I):raise ValueError('potential host identifier')
        hosts.append(host.casefold())
        return 'PUBLICURLSLOTVALUE'+str(len(hosts)-1)+'END'
    text=URL.sub(url,text)
    text=re.sub(r'((?:\bOTP|m[ãa]\s+OTP|m[ãa]\s+k[ií]ch\s+ho[aạ]t(?:\s+l[àa])?)\s*[:：]?\s*)\d{4,12}',
                r'\g<1>730821',text,flags=re.I)
    text=re.sub(r'((?:h[oó]a\s+[đd][oơ]n\s+s[oố]|m[ãa]\s+s[oố]\s+b[ií]\s+m[aậ]t)\s*)[A-Za-z0-9-]{4,}',
                r'\g<1>INV730821',text,flags=re.I)
    # Upstream redaction cannot tell us the optional hotline fee. Omit it,
    # instead of inserting an invented large charge or asserting it was free.
    text=re.sub(r'\s*\(\[MONEY\]\)','',text)
    text=re.sub(r'(?<!\w)\d{7,15}(?!\w)','0907000123',text)
    text=re.sub(r'\[MONEY\](\s*(?:đồng|dong|VND|VNĐ|đ|xu)\b)?',
                lambda m:'50000'+(m[1] if m[1] else ' VND'),text,flags=re.I).replace('[POINT]','500')
    text=text.replace('[PHONE]','0907000123').replace('[BANK_ACC]','120000123456')
    text=text.replace('[NAME]','khách hàng').replace('[DATE]','12/11/2026')
    # Missing URLs add no evidence. Only otherwise explicit records may be
    # approved by content review. Never invent a malicious/legitimate host.
    text=text.replace('<URL>','').replace('[URL]','')
    if re.search(r'\[[A-Z_]+\]|<[A-Z_]+>',text):raise ValueError('unreviewed anonymizer roles')
    if re.search(r'https?:(?!//)|https?://(?:\s|$)',text):raise ValueError('truncated url')
    for i,host in enumerate(hosts):text=text.replace('PUBLICURLSLOTVALUE'+str(i)+'END','https://'+host+'/r/730821')
    text=re.sub(r'\s+',' ',text).strip()
    if len(text)<24 or len(text)>600:raise ValueError('incomplete/oversized source text')
    return text,sorted(set(hosts))


def ascii_family(text):
    text=unicodedata.normalize('NFKD',text.casefold().replace('đ','d'))
    text=''.join(c for c in text if not unicodedata.combining(c))
    return digest(semantic_signature(text))
