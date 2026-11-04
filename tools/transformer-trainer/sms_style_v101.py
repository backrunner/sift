"""Label-preserving SMS styling applied afresh on each training pass.

Links are added to every label at the same rate, so a link carries no class signal by itself.
Existing URLs are never edited, because a host can be decisive evidence.
"""
import random
import re

URL = re.compile(r'https?://\S+|www\.\S+')
SIGNATURES = dict(zh=('【青云】', '【服务通知】', '【悦享】', '[官方]'), ja=('【さくら】', '【お知らせ】', '【みなと】', 'こだまより：'), en=('Alder: ', 'Notice: ', '[Harbor] ', 'Northwind: '))
HOSTS = dict(zh=('t.cn/A6{}', 'dwz.cn/{}', 'm.qingyun.cn/{}', 'h5.yuexiang.com/{}', 'u.jd.com/{}'), ja=('bit.ly/{}', 'sakura-net.co.jp/{}', 'r10.to/{}', 'minato.jp/{}', 'amzn.asia/d/{}'),
             en=('bit.ly/{}', 'tinyurl.com/{}', 'alder.co/{}', 'harbor.com/{}', 'amzn.to/{}'))
OPT_OUT = dict(zh=('回T退订', '退订回TD', '拒收请回复R'), ja=('配信停止はこちら', '配信停止は設定から'), en=('Reply STOP to opt out', 'STOP to end', 'Txt STOP to unsubscribe'))
SERVICE_TAIL = dict(zh=('如非本人操作请忽略。', '请勿回复。', '详情请查看App。'), ja=('お心当たりのない場合は無視してください。', 'このメッセージへの返信はできません。'), en=('Do not reply.', 'If this was not you, ignore this message.'))
COMMERCIAL = ('promotion', 'carrier.promotion')
CONVERSATION = '__sift_abstain__'
LINK_RATE = .3
SIGNATURE_RATE = .25
DIGIT_RATE = .5
COMMERCIAL_OPT_OUT_RATE = .5
SERVICE_OPT_OUT_RATE = .05
TAIL_RATE = .1


def _token(rng): return ''.join(rng.choices('abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789', k=rng.randint(3, 6)))


def _resample_digits(text, rng):
    """New digits of the same length, outside URLs, so amounts and codes stop being memorized."""
    parts = []; last = 0
    for match in URL.finditer(text):
        parts.append(re.sub(r'\d', lambda _: str(rng.randint(0, 9)), text[last:match.start()])); parts.append(match.group()); last = match.end()
    parts.append(re.sub(r'\d', lambda _: str(rng.randint(0, 9)), text[last:]))
    return ''.join(parts)


def style(text, label, language, rng):
    if language not in SIGNATURES: return text
    if rng.random() < DIGIT_RATE: text = _resample_digits(text, rng)
    if label != CONVERSATION:
        if not text.startswith(('【', '[')) and '【' not in text and rng.random() < SIGNATURE_RATE: text = rng.choice(SIGNATURES[language]) + text
        if label in COMMERCIAL:
            if rng.random() < COMMERCIAL_OPT_OUT_RATE: text = f'{text} {rng.choice(OPT_OUT[language])}'
        elif label != 'spam':
            if rng.random() < SERVICE_OPT_OUT_RATE: text = f'{text} {rng.choice(OPT_OUT[language])}'
            elif rng.random() < TAIL_RATE: text = f'{text} {rng.choice(SERVICE_TAIL[language])}'
    if not URL.search(text) and rng.random() < LINK_RATE:
        text = f'{text} https://{rng.choice(HOSTS[language]).format(_token(rng))}'
    return text
