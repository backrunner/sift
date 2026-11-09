#!/usr/bin/env python3
"""Materialize hash-pinned, explicitly reviewed public SMS; never infer labels.

Raw third-party corpora stay in a local cache. The versioned manifest contains
provenance, text digests, reviewed labels and frozen splits, not SMS bodies or
contributor metadata. Network acquisition is deliberately separate.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import html
import io
import json
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter

from curate_dataset import (normalize, near_duplicate_signature, template_signature,
                            residual_sensitive_kinds, sanitize_text, load_taxonomy_labels,
                            rehydrate_placeholders, stable_rng)
from model_contract import model_labels
from sms_signatures import semantic_signature


def digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def sanitized_text(text: str) -> str:
    text = html.unescape(text).replace("<#>", "3").replace("<DECIMAL>", "2.5")
    # Preserve the upstream redaction boundary; these are synthetic stand-ins,
    # not recovered identifiers. Leave missing organization names generic.
    upstream = {"PHONE_NUMBER": "{{PHONE}}", "NAMED_ENTITY": "{{NAME}}",
                "LOCATION": "{{ADDRESS}}", "DATE_TIME": "tomorrow",
                "US_DRIVER_LICENSE": "{{ID}}", "US_BANK_NUMBER": "{{CARD}}",
                "UK_NHS": "{{ID}}", "NRP": "{{ID}}"}
    for token, replacement in upstream.items():
        text = text.replace("<" + token + ">", replacement)
    text = re.sub(r"(?<![\w])\d{7,15}(?![\w])", "{{PHONE}}", text)
    text = re.sub(r"(?i)(?<![\w])(?:https?://|www\.)[^\s<>]+", "{{URL}}", text)
    # NUS already uses angle-bracket anonymization tokens; unify their shape.
    text = re.sub(r"<(?i:phone|number|mobile|email|url|name|address|date|time)>",
                  lambda m: "{{" + {"NUMBER": "PHONE", "MOBILE": "PHONE",
                                    "DATE": "CODE", "TIME": "CODE"}.get(
                      m.group()[1:-1].upper(), m.group()[1:-1].upper()) + "}}", text)
    return normalize(sanitize_text(normalize(text)).text)


def reviewed_text(text: str, redactions: list[dict], *, square_tokens: bool = False) -> str:
    previous = len(text)
    for span in sorted(redactions, key=lambda x: x["start"], reverse=True):
        start, end = span["start"], span["end"]
        if not 0 <= start < end <= previous or span["token"] not in ("{{NAME}}", "{{ADDRESS}}"):
            raise ValueError("invalid or overlapping reviewed redaction")
        text = text[:start] + span["token"] + text[end:]
        previous = start
    if square_tokens:
        tokens = {"PHONE": "{{PHONE}}", "BANK_ACC": "{{CARD}}", "MONEY": "{{AMOUNT}}",
                  "NUMBER": "{{CODE}}", "TIME": "12:30", "DATE": "2026-11-12",
                  "NAME": "{{NAME}}", "POINT": "300"}
        text = re.sub(r"\[([A-Z_]+)\]", lambda m: tokens.get(m[1], m[0]), text)
    return sanitized_text(text)


def source_rows(source: dict, cache: Path) -> list[dict]:
    path = (cache / source["file"]).resolve()
    if not path.is_relative_to(cache.resolve()):
        raise ValueError("source cache path escapes its directory")
    if hashlib.sha256(path.read_bytes()).hexdigest() != source["sha256"]:
        raise ValueError(f"source checksum mismatch: {source['id']}")
    fmt = source["format"]
    if fmt in ("xml", "zip-xml"):
        if fmt == "zip-xml":
            with zipfile.ZipFile(path) as archive:
                top = ET.fromstring(archive.read(source["member"]))
        else:
            top = ET.parse(path).getroot()
        records = [{"text": element.findtext("text", "")} for element in
                   top.findall("message")]
    else:
        if fmt == "zip-csv":
            with zipfile.ZipFile(path) as archive:
                data = archive.read(source["member"])
        elif fmt == "csv":
            data = path.read_bytes()
        else:
            raise ValueError("unsupported source format")
        records = list(csv.DictReader(io.StringIO(data.decode("utf-8-sig"))))
    result = []
    for record in records:
        text = normalize(record.get(source.get("textField", "text"), ""))
        if not text:
            continue
        result.append({"text": text, "key": digest(text),
                       "sourceLabel": record.get(source.get("labelField", "label"), "unlabelled"),
                       "language": source.get("language") or
                       {"English": "en", "Chinese": "zh", "Japanese": "ja"}.get(
                           record.get("language", ""), "other")})
    return result


def keys(text: str, *, family: bool = False) -> set[str]:
    result = {"exact:" + normalize(text).casefold(),
            "near:" + near_duplicate_signature(text),
            "template:" + template_signature(text)}
    if family:
        result.add("family:" + semantic_signature(text))
    return result


def review_template(row: dict, review: dict, version: int) -> str:
    if version == 4:
        from public_url_evidence import mask_reviewed_urls, restore_urls
        from reviewed_public_profile import prepare_template
        # Redaction offsets refer to the original source, before URL masking.
        text=row['text'];previous=len(text)
        for span in sorted(review.get('redactions',[]),key=lambda x:x['start'],reverse=True):
            start,end=span['start'],span['end']
            if not 0<=start<end<=previous or span['token'] not in ('{{NAME}}','{{ADDRESS}}'):
                raise ValueError('invalid or overlapping reviewed redaction')
            text=text[:start]+span['token']+text[end:];previous=start
        text,roots=mask_reviewed_urls(text,review.get('publicURLHosts',[]))
        if 'moneyRoles' in review:
            roles=review['moneyRoles']
            if row['language']!='vi' or len(roles)!=text.count('[MONEY]') or any(r not in ('amount','credit_limit') for r in roles):
                raise ValueError('missing or invalid reviewed MONEY roles')
            iterator=iter(roles)
            text=re.sub(r'\[MONEY\]',lambda _: '{{CREDIT_LIMIT}}' if next(iterator)=='credit_limit' else '[MONEY]',text)
        text=prepare_template(sanitized_text(text),row['language'],review.get('numberRoles',[]),review.get('timeRoles',[]))
        if '{{URL}}' in text:
            raise ValueError('source URL has no reviewed host evidence')
        return restore_urls(text,roots)
    text=reviewed_text(row['text'],review.get('redactions',[]),square_tokens=version==2)
    if version>=3:
        from reviewed_public_profile import prepare_template
        text=prepare_template(text,row['language'],review.get('numberRoles',[]),review.get('timeRoles',[]))
    return text


def render_review(text: str, row: dict, version: int) -> str:
    rng=stable_rng(f'public-v{version}:'+row['key'])
    if version>=3:
        from reviewed_public_profile import render_template
        return render_template(text,row['language'],rng)
    return rehydrate_placeholders(text,row['language'],rng)


def materialize(manifest: dict, cache: Path, holdout_texts: list[str]) -> tuple[list, list, dict]:
    if manifest.get("schemaVersion") not in (1, 2, 3, 4):
        raise ValueError("unsupported public-review schema")
    version = manifest["schemaVersion"]
    if version>=3 and manifest.get('profile')!=('typed-locale-host-v2' if version==4 else 'typed-locale-v1'):
        raise ValueError('unknown typed review profile')
    namespace = manifest.get("outputNamespace", f"public-reviewed-v{version}")
    if not re.fullmatch(r"public-reviewed-v[1-9][0-9]*", namespace):
        raise ValueError("invalid public package namespace")
    # v1 packages remain reproducible. New packages opt into stronger family
    # isolation and additional supported languages without changing v1 bytes.
    signature_keys_for = lambda text: keys(text, family=version >= 2)
    taxonomy = Path(__file__).resolve().parents[2] / "packages/taxonomy/taxonomy.json"
    valid_labels = model_labels(load_taxonomy_labels(taxonomy))
    sources = {}
    for source in manifest["sources"]:
        if (source["id"] in sources or source.get("license") not in
                ("CC-BY-4.0", "public-domain-per-author-paper") or not source.get("licenseEvidence")):
            raise ValueError("duplicate source or missing reuse provenance")
        sources[source["id"]] = {r["key"]: r for r in source_rows(source, cache)}
    protected = set().union(*(signature_keys_for(text) for text in holdout_texts)) if holdout_texts else set()
    upstream_holdouts = {}
    for source in manifest["sources"]:
        if test_source := source.get("upstreamTestSource"):
            if version < 2 or source.get("upstreamSplit") != "train" or test_source not in sources:
                raise ValueError("invalid official split contract")
            upstream_holdouts[source["id"]] = set().union(*(
                signature_keys_for(row["text"]) | signature_keys_for(
                    reviewed_text(row["text"], [], square_tokens=True))
                for row in sources[test_source].values()))
    train, test, seen_reviews = [], [], set()
    occupied: dict[str, tuple[str, str]] = {}
    split_groups: dict[str, str] = {}
    counts = Counter()
    for review in manifest["reviews"]:
        identity = (review["source"], review["key"])
        if identity in seen_reviews:
            raise ValueError("duplicate reviewed identity")
        seen_reviews.add(identity)
        row = sources[review["source"]].get(review["key"])
        if row is None:
            raise ValueError("review no longer matches a source message")
        if review['split']=='exclude' and version>=3:
            if review['label'] is not None or not review.get('reason'):
                raise ValueError('excluded review must carry a reason and no gold label')
            counts['excluded']+=1
            continue
        text = review_template(row,review,version)
        if digest(text) != review["sanitizedSHA256"]:
            raise ValueError("sanitizer output differs from reviewed text")
        split = review["split"]
        if split not in ("train", "test", "exclude") or not review.get("reason"):
            raise ValueError("review needs a frozen split and reason")
        if review["label"] is None:
            if split != "exclude":
                raise ValueError("unlabelled review cannot enter training or tests")
            counts["excluded"] += 1
            continue
        if split == "exclude" or review["label"] not in valid_labels:
            raise ValueError("invalid reviewed label")
        source_spec = next(s for s in manifest["sources"] if s["id"] == review["source"])
        if source_spec.get("upstreamSplit", split) != split:
            raise ValueError("review changes the official source split")
        for field in ("campaignGroup", "contributorGroup"):
            if group := review.get(field):
                if group in split_groups and split_groups[group] != split:
                    raise ValueError("campaign or contributor crosses frozen splits")
                split_groups[group] = split
        supported = ("zh", "en", "ja", "vi") if version >= 2 else ("zh", "en", "ja")
        if row["language"] not in supported or row["language"] != review["language"]:
            raise ValueError("reviewed language differs from source")
        sensitive_text=text
        if version==4:
            from public_url_evidence import mask_reviewed_urls
            sensitive_text,_=mask_reviewed_urls(text,review.get('publicURLHosts',[]))
        if residual_sensitive_kinds(sensitive_text):
            raise ValueError("review retains a sensitive value")
        signature_keys = signature_keys_for(row["text"]) | signature_keys_for(text)
        if signature_keys & upstream_holdouts.get(review["source"], set()):
            raise ValueError("review overlaps an official source test family")
        if signature_keys & protected:
            raise ValueError("review overlaps an external holdout")
        for key in signature_keys:
            if key in occupied and occupied[key] != (split, review["label"]):
                raise ValueError("cross-split duplicate or conflicting reviewed labels")
        if any(key in occupied for key in signature_keys):
            counts["duplicate"] += 1
            continue
        for key in signature_keys:
            occupied[key] = (split, review["label"])
        # Train on deterministic fictitious values, never source identifiers or
        # raw anonymizer syntax. Check isolation again after this transform.
        output_text = render_review(text,row,version)
        if signature_keys_for(output_text) & protected:
            raise ValueError("rehydrated review overlaps an external holdout")
        for key in signature_keys_for(output_text):
            if key in occupied and occupied[key] != (split, review["label"]):
                raise ValueError("rehydrated review crosses splits or labels")
            occupied[key] = (split, review["label"])
        output = {"text": output_text, "label": review["label"], "language": row["language"],
                  "source": namespace + ":" + review["source"],
                  "sourceLabel": row["sourceLabel"]}
        (train if split == "train" else test).append(output)
        counts[f"{split}:{review['source']}:{row['language']}:{review['label']}"] += 1
    return train, test, dict(sorted(counts.items()))


def filter_coarse_rows(rows: list[dict], manifest: dict, cache: Path) -> list[dict]:
    """Remove reviewed identities before old coarse labels can win deduplication.

    Includes excluded and held-out identities, not just positive training rows.
    The reviewed training subset is added separately after this filter.
    """
    selected = {(r["source"], r["key"]): r for r in manifest["reviews"]}
    version = manifest["schemaVersion"]
    signature_keys_for = lambda text: keys(text, family=version >= 2)
    blocked: set[str] = set()
    for source in manifest["sources"]:
        for row in source_rows(source, cache):
            if review := selected.get((source["id"], row["key"])):
                blocked.update(signature_keys_for(row["text"]))
                if version>=3 and review['split']=='exclude':
                    blocked.update(signature_keys_for(reviewed_text(row['text'],review.get('redactions',[]),square_tokens=True)))
                    continue
                text = review_template(row,review,version)
                blocked.update(signature_keys_for(text))
                blocked.update(signature_keys_for(render_review(text,row,version)))
    return [row for row in rows if not signature_keys_for(row["text"]) & blocked]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--holdout", type=Path, action="append", default=[],
                        help="additional holdout; all repository regression suites are always isolated")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--test-out", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "pipeline"))
    from sift_pipeline import holdout_test_sets
    args.holdout = list(dict.fromkeys(path.resolve() for path in [*holdout_test_sets(), *args.holdout]))
    outputs = [args.out.resolve(), args.test_out.resolve(), args.report.resolve()]
    if len(set(outputs)) != 3 or set(outputs) & {x.resolve() for x in args.holdout + [args.manifest]}:
        parser.error("outputs must be distinct and cannot overwrite inputs")
    texts = [json.loads(line)["text"] for p in args.holdout for line in p.read_text().splitlines() if line.strip()]
    train, test, counts = materialize(json.loads(args.manifest.read_text()), args.cache, texts)
    for path, rows in [(args.out, train), (args.test_out, test)]:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows), encoding="utf-8")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps({"trainRows": len(train), "testRows": len(test),
                                      "counts": counts, "manifestSHA256": digest(args.manifest.read_text()),
                                      "manifestPath": str(args.manifest.resolve()),
                                      "sourceCache": str(args.cache.resolve()),
                                      "holdouts": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in args.holdout},
                                      "trainSHA256": hashlib.sha256(args.out.read_bytes()).hexdigest(),
                                      "testSHA256": hashlib.sha256(args.test_out.read_bytes()).hexdigest(),
                                      "releaseEligible": False}, indent=2) + "\n", encoding="utf-8")
    print(f"reviewed public SMS: {len(train)} train, {len(test)} frozen test")


if __name__ == "__main__":
    main()
