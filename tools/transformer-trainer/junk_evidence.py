"""Admission checks for explicitly reviewed junk evidence, not auto-labeling.

Semantic decisions remain human/agent review. These checks prevent subsequent
source, text, truncation or URL rewrites from silently invalidating that review.
"""
import hashlib


def text_sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def validate_junk_evidence(rows, review):
    if review.get('schemaVersion')!=1 or review.get('maxLength')!=96:
        raise ValueError('unsupported junk evidence input contract')
    decisions={r['textSHA256']:r for r in review['decisions']}
    if len(decisions)!=len(review['decisions']):raise ValueError('duplicate junk review identity')
    counts={'bodyEvidence':0,'domainEvidence':0,'excludedRowsAbsent':0}
    seen=set()
    for row in rows:
        key=text_sha(row['text']);seen.add(key);record=decisions.get(key)
        if record and record['decision']=='exclude':
            raise ValueError('excluded ambiguous example reintroduced')
        if row['label']!='spam':continue
        if record is None or record['decision']!='retain':
            raise ValueError('junk training row lacks accepted evidence review')
        if record['source']!=row['source']:
            raise ValueError('junk evidence source drift')
        visible=record['visibleCharacterEnd']
        if not 0<visible<=len(row['text']):raise ValueError('invalid visible input bound')
        spans=record['supportSpans']
        if not spans or any(not 0<=a<b<=visible for a,b in spans):
            raise ValueError('junk evidence is absent from the reviewed model input')
        kind=record['evidenceKind']
        if kind=='body':
            counts['bodyEvidence']+=1
        elif kind=='domain':
            source=review['sourceEvidence'].get(record.get('sourceEvidenceKey'))
            if not source or not source.get('file') or not source.get('sha256'):
                raise ValueError('domain-based gold lacks source evidence')
            hosts=record.get('requiredHosts',[])
            if not hosts:raise ValueError('domain-based gold lacks a retained host')
            for host in hosts:
                start=row['text'].find(host)
                if start<0 or start+len(host)>visible:
                    raise ValueError('domain evidence removed or truncated')
                if not any(a<=start and start+len(host)<=b for a,b in spans):
                    raise ValueError('host is outside the reviewed evidence span')
            counts['domainEvidence']+=1
        else:raise ValueError('unsupported junk evidence kind')
    counts['excludedRowsAbsent']=sum(r['decision']=='exclude' and k not in seen for k,r in decisions.items())
    return counts


def validate_profile_input(corpus,arguments,frozen=None):
    if not corpus.get('junkEvidenceReview'):return
    if '--max-length' not in arguments or arguments[arguments.index('--max-length')+1]!='96':
        raise ValueError('reviewed junk evidence requires the pinned 96-token input; re-audit before changing it')
    expected=corpus.get('junkEvidenceTokenizerSHA256')
    if not expected or frozen is None or any(frozen['filesSHA256'].get(k)!=v for k,v in expected.items()):
        raise ValueError('reviewed junk evidence tokenizer changed; re-audit visible evidence')
