"""Versioned, explicitly typed source anonymizers; never recover identities."""
from __future__ import annotations

import re

from curate_dataset import rehydrate_placeholders
from sms_signatures import BARE_URL_PATTERN

NUMBER_ROLES = {'code':'CODE','phone':'PHONE','shortcode':'SMS_SHORTCODE',
    'command':'SMS_COMMAND','year':'YEAR','quantity':'QUANTITY','card_tail':'CARD_TAIL',
    'order':'ORDER_ID','bank_account':'CARD','points':'POINTS','date':'DATE'}
TIME_ROLES = {'clock':'CLOCK','minutes':'DURATION_MINUTES','hours':'DURATION_HOURS','period':'PERIOD'}


def prepare_template(text: str, language: str, number_roles: list[str], time_roles: list[str]) -> str:
    text=re.sub(r'https?//(?=[A-Za-z0-9])','https://',text)
    text=re.sub(r'https?://[^\s<>]+','{{URL}}',text)
    text = BARE_URL_PATTERN.sub('{{URL}}',text)
    if language != 'vi':
        if number_roles or time_roles or re.search(r'\[[A-Z_]+\]',text):
            raise ValueError('typed square placeholders require reviewed Vietnamese source')
        return text
    for token, roles, mapping in [('NUMBER',number_roles,NUMBER_ROLES),('TIME',time_roles,TIME_ROLES)]:
        if text.count('['+token+']') != len(roles) or any(role not in mapping for role in roles):
            raise ValueError('missing or invalid reviewed '+token+' roles')
        iterator=iter(roles)
        text=text.replace('['+token+']','\x00'+token+'\x00')
        text=re.sub('\x00'+token+'\x00',lambda _: '{{'+mapping[next(iterator)]+'}}',text)
    mapping={'PHONE':'PHONE','BANK_ACC':'CARD','MONEY':'AMOUNT','DATE':'DATE',
             'NAME':'NAME','POINT':'POINTS'}
    text=re.sub(r'\[([A-Z_]+)\]',lambda m:'{{'+mapping[m[1]]+'}}' if m[1] in mapping else m[0],text)
    if any(tag not in {'QC','TB'} for tag in re.findall(r'\[([A-Z_]+)\]',text)):
        raise ValueError('unreviewed source anonymizer')
    return text


def render_template(text: str, language: str, rng) -> str:
    if language != 'vi':
        return rehydrate_placeholders(text,language,rng)

    def value(match):
        token=match[1]
        after=text[match.end():]
        if token=='AMOUNT':
            amount=str(rng.next_int(1,200)*1000)
            return amount if re.match(r'\s*(?:đồng|dong|vnd|vnđ|đ|điểm|diem|xu)(?=\W|$)',after,re.I) else amount+' VND'
        if token=='CREDIT_LIMIT':
            amount=str(rng.next_int(3,20)*10000000)
            return amount if re.match(r'\s*(?:đồng|dong|vnd|vnđ|đ)(?=\W|$)',after,re.I) else amount+' VND'
        values={'PHONE':'0900000000','CARD':'000000000000','CARD_TAIL':'0000',
            'URL':'https://example.com/m/'+str(rng.next_int(100000,999999)),
            'EMAIL':'sample@example.com','NAME':'khách hàng','ADDRESS':'địa chỉ mẫu',
            'CODE':str(rng.next_int(100000,999999)),'SMS_SHORTCODE':'199','SMS_COMMAND':'1',
            'YEAR':'2026','QUANTITY':str(rng.next_int(1,50)),
            'POINTS':str(rng.next_int(1,200)*10),'ORDER_ID':str(rng.next_int(100000000,999999999)),
            'DATE':'12/11/2026','CLOCK':'12:30','DURATION_MINUTES':'5 phút',
            'DURATION_HOURS':'24 giờ','PERIOD':'chu kỳ','ID':'000000000000'}
        if token not in values:
            raise ValueError('unhandled typed placeholder '+token)
        return values[token]
    return re.sub(r'\{\{([A-Z_]+)\}\}',value,text)
