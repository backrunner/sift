"""Reject deleted legacy training samples without retaining their bodies."""
import hashlib
import json
from pathlib import Path
import re
from import_reviewed_public import keys

DEFAULT_MANIFEST=Path(__file__).resolve().parents[1]/'apple-trainer/Training/retired-signal-samples-v8.json'


class RetiredSamples:
    def __init__(self,path=DEFAULT_MANIFEST):
        data=json.loads(path.read_text())
        self.hashes={r['textSHA256'] for r in data['entries']}
        if data.get('schemaVersion') != 2:
            raise ValueError('retirement manifest must store hashed signatures only')
        self.signatures=set().union(*(set(r['signatureSHA256']) for r in data['entries']))
        self.content_cache={}
        self.retired_labels={(r['textSHA256'],r['label']) for r in data.get('labelEntries',[])}

    def reason(self,row):
        text=row.get('text','');source=row.get('source','')
        if re.match(r'^synthetic:(?:zh|en|ja|es|pt|fr|de|ru|ko|id|vi|th)(?::|$)',source):
            return 'retired-context-free-decoration-generator'
        if row.get('label')=='spam' and source.startswith(('augmentation:','targeted')) and not source.startswith('augmentation:semantic:signal-v65:'):
            return 'retired-mixed-generated-spam-pool'
        digest=hashlib.sha256(text.encode()).hexdigest()
        if (digest,row.get('label')) in self.retired_labels:
            return 'retired-reviewed-label'
        if digest in self.hashes:return 'retired-reviewed-content-signature'
        matched=self.content_cache.get(digest)
        if matched is None:
            signatures={hashlib.sha256(k.encode()).hexdigest() for k in keys(text,family=True)} if text else set()
            matched=bool(signatures&self.signatures)
            self.content_cache[digest]=matched
        if matched:
            return 'retired-reviewed-content-signature'
        return None
