"""Validate reviewed URL contrasts; this is an admission check, not a labeler."""
from collections import defaultdict
import hashlib
from urllib.parse import urlsplit


def action(label):
    return 'junk' if label=='spam' else 'promotion' if label in ('promotion','carrier.promotion') else 'normal'


def validate_url_review(rows,review):
    if review.get('schemaVersion')!=1 or review.get('maxLength')!=96:
        raise ValueError('unsupported URL review contract')
    decisions={r['textSHA256']:r for r in review['decisions'] if r['split']=='train'}
    seen=set();url_actions=defaultdict(set);hosts=set()
    for row in rows:
        if not row['source'].startswith('authored-reviewed-v20:'):continue
        digest=hashlib.sha256(row['text'].encode()).hexdigest();record=decisions.get(digest)
        if record is None or record.get('decision')!='retain':raise ValueError('URL row lacks accepted review')
        if any(record[k]!=row[k] for k in ('label','language','source')):raise ValueError('URL review metadata drift')
        if not record['reason'] or not 0<record['tokenCount']<=96:raise ValueError('URL evidence exceeds input window')
        url=record['url']
        if row['text'].count(url)!=1:raise ValueError('reviewed link missing or repeated')
        host=urlsplit(url if '://' in url else 'https://'+url).hostname
        if not host or not host.endswith(('.test','.example','.invalid')):
            raise ValueError('authored contrast link is not a reserved fixture')
        hosts.add(host);url_actions[url].add(action(row['label']));seen.add(digest)
    if seen!=set(decisions):raise ValueError('reviewed URL training rows missing')
    if any(a!={'normal','junk','promotion'} for a in url_actions.values()):
        raise ValueError('URL fixture has become a label shortcut')
    if hosts & set(review['diagnosticHosts']):raise ValueError('URL diagnostic host leaked into training')
    return {'reviewedTrainingRows':len(seen),'sharedAllActionURLs':len(url_actions),'diagnosticHostOverlap':0}
