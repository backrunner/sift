"""Fail-closed admission for a source-separated prospective Signal study.

This verifies a declared, hash-pinned review contract, not the truthfulness of
publisher provenance or human annotations. No model is loaded or scored here.
"""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path

from import_reviewed_public import keys
from public_group_isolation import Groups, Suffixes, family, links, shingles, similar

ROLES = ("train", "development", "calibration", "final")
KINDS = ("observed_sms", "official_template", "synthetic", "translated", "unknown")


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def pinned(root, spec):
    path = (root / spec["path"]).resolve()
    if not path.is_relative_to(root.resolve()) or sha(path) != spec["sha256"]:
        raise ValueError("pinned input missing, outside root, or changed: " + spec["path"])
    return path


def bucket(label, actions):
    action = actions[label]
    return "junk" if action == "junk" else "promotion" if action == "promotion" else "nonpromotion"


def audit(plan, root):
    """Return all admission failures; empty or provisional inputs never pass."""
    if plan.get("schemaVersion") != 1:
        raise ValueError("unsupported prospective data contract")
    suffix = Suffixes(pinned(root, plan["publicSuffixes"]).read_text())
    taxonomy = json.loads(pinned(root, plan["taxonomy"]).read_text())
    actions = {leaf["id"]: leaf.get("systemAction", group["systemAction"])
               for group in taxonomy["groups"] for leaf in group["leaves"]}
    actions["__sift_abstain__"] = "none"
    source_path = pinned(root, plan["sources"])
    source_list = json.loads(source_path.read_text())
    sources = {s["id"]: s for s in source_list}
    if len(sources) != len(source_list):
        raise ValueError("duplicate source id")
    errors, records, counts, observed_train = [], [], Counter(), Counter()
    if plan.get("reviewStatus") != "sealed":
        errors.append("study review is not sealed")
    if plan.get("finalAlreadyScored") is not False:
        errors.append("final exposure status missing or spent")
    if not plan.get("historicalExclusions"):
        errors.append("historical exclusions missing")
    for role in ROLES:
        spec = plan.get("datasets", {}).get(role)
        if not spec:
            errors.append(f"{role}: dataset not collected")
            continue
        data = [json.loads(line) for line in pinned(root, spec).read_text().splitlines() if line]
        if not data:
            errors.append(f"{role}: empty dataset")
        for i, row in enumerate(data):
            tag = f"{role}:{i}"
            for field in ("text", "label", "language", "sourceId", "originalId", "familyId"):
                if not isinstance(row.get(field), str) or not row[field].strip():
                    raise ValueError(f"{tag}: missing {field}")
            if row["label"] not in actions:
                raise ValueError(f"{tag}: invalid taxonomy label")
            source = sources.get(row["sourceId"])
            if not source:
                raise ValueError(f"{tag}: undeclared source")
            if not isinstance(source.get("lineageId"), str) or not source["lineageId"].strip():
                raise ValueError(f"{tag}: source has no upstream lineage")
            if source.get("role") != role:
                errors.append(f"{tag}: source role differs from preregistration")
            if source.get("kind") not in KINDS or source.get("kind") == "unknown":
                errors.append(f"{tag}: unresolved acquisition type")
            if row.get("acquisitionKind") != source.get("kind"):
                errors.append(f"{tag}: row acquisition type missing or differs from source")
            if source.get("commercialReuseReviewed") is not True:
                errors.append(f"{tag}: source reuse unresolved")
            for evidence in ("provenanceEvidence", "licenseEvidence"):
                if evidence not in source:
                    errors.append(f"{tag}: {evidence} missing")
                else:
                    pinned(root, source[evidence])
            if role != "train" and source.get("kind") != "observed_sms":
                errors.append(f"{tag}: non-observed SMS in prospective evaluation")
            if role != "train" and (row.get("isTranslated") is not False or row.get("isSynthetic") is not False):
                errors.append(f"{tag}: synthetic/translation status unresolved or ineligible")
            if role != "train" and (source.get("previouslyUsed") is not False or row.get("predictionSeen") is not False):
                errors.append(f"{tag}: prior exposure unresolved or already seen")
            review = row.get("goldReview", {})
            if review.get("status") != "accepted" or review.get("withoutModelPredictions") is not True:
                errors.append(f"{tag}: gold not blindly reviewed")
            if not review.get("reason") or not review.get("reviewerRole"):
                errors.append(f"{tag}: review rationale/ownership missing")
            if row["label"] == "spam":
                evidence = review.get("junkEvidence", {})
                if evidence.get("kind") == "body":
                    if not evidence.get("clause") or evidence["clause"] not in row["text"]:
                        errors.append(f"{tag}: junk clause absent from model input")
                elif evidence.get("kind") == "documented_destination":
                    if not evidence.get("host") or evidence["host"] not in row["text"] or not evidence.get("sourceEvidence"):
                        errors.append(f"{tag}: destination evidence missing")
                    else:
                        pinned(root, evidence["sourceEvidence"])
                else:
                    errors.append(f"{tag}: unsupported junk gold")
            counts[role, row["language"], bucket(row["label"], actions)] += 1
            if (role == "train" and source.get("kind") == "observed_sms"
                    and row.get("isTranslated") is False and row.get("isSynthetic") is False):
                observed_train[row["language"]] += 1
            records.append((role, tag, row, source))

    # Full graph first, then compare roles: a bridge can connect two otherwise
    # distinct examples. Mirrors share lineage; translations share originalId.
    groups, nodes = Groups(), []
    for role, tag, row, source in records:
        group_keys = ["lineage:" + source["lineageId"], "family:" + row["familyId"],
                      "original:" + row["originalId"], "text-family:" + family(row["text"], suffix)]
        if row.get("parentOriginalId"):
            group_keys.append("original:" + row["parentOriginalId"])
        group_keys.extend("signature:" + k for k in keys(row["text"], family=True))
        group_keys.extend("host:" + suffix.registrable(host) for _, _, host in links(row["text"], suffix))
        nodes.append((role, tag, groups.union(group_keys)))
    components = defaultdict(set)
    for role, _, node in nodes:
        components[groups.find(node)].add(role)
    for roles in components.values():
        if len(roles) > 1:
            errors.append("cross-role connected component: " + "/".join(sorted(roles)))

    # A conservative near-family check in addition to exact/digit signatures.
    features = [shingles(row["text"], suffix) for _, _, row, _ in records]
    for i, (role, tag, _, _) in enumerate(records):
        for j in range(i):
            if records[j][0] != role and similar(features[i], features[j]):
                errors.append(f"cross-role near family: {tag}/{records[j][1]}")
    historical = []
    if not plan.get("baseTraining"):
        errors.append("base training ownership missing")
    exclusions = list(plan.get("historicalExclusions", []))
    if plan.get("baseTraining"):
        exclusions.append(plan["baseTraining"])
    for spec in exclusions:
        for line in pinned(root, spec).read_text().splitlines():
            if line:
                row = json.loads(line)
                historical.append(row["text"])
    old_keys = {k for text in historical for k in keys(text, family=True)}
    old_families = {family(text, suffix) for text in historical}
    old_hosts = {suffix.registrable(host) for text in historical for _, _, host in links(text, suffix)}
    old_features = [shingles(text, suffix) for text in dict.fromkeys(historical)]
    for i, (_, tag, row, _) in enumerate(records):
        if (old_keys.intersection(keys(row["text"], family=True))
                or family(row["text"], suffix) in old_families
                or old_hosts.intersection(suffix.registrable(host) for _, _, host in links(row["text"], suffix))):
            errors.append(f"{tag}: overlaps historical exclusion")
        elif any(similar(features[i], feature) for feature in old_features):
            errors.append(f"{tag}: near historical exclusion")

    requirements = plan.get("minimumCounts", {})
    for lang, minimum in plan.get("minimumObservedTrainingCounts", {}).items():
        if type(minimum) is not int or minimum <= 0:
            raise ValueError("observed training minimum must be a positive integer")
        if observed_train[lang] < minimum:
            errors.append(f"train/{lang}/native-observed: {observed_train[lang]} < {minimum}")
    for role in ROLES:
        if not requirements.get(role):
            errors.append(f"{role}: coverage requirements absent")
        for lang, minimums in requirements.get(role, {}).items():
            for action, minimum in minimums.items():
                if action not in ("junk", "promotion", "nonpromotion") or type(minimum) is not int or minimum <= 0:
                    raise ValueError("coverage minimum must be a positive integer for a known action bucket")
                actual = counts[role, lang, action]
                if actual < minimum:
                    errors.append(f"{role}/{lang}/{action}: {actual} < {minimum}")
    return {"schemaVersion": 1, "trainingReady": not errors, "releaseEligible": False,
            "newInference": False, "errors": errors,
            "counts": {"/".join(k): v for k, v in sorted(counts.items())},
            "nativeObservedTrainingCounts": dict(observed_train),
            "sourceComponents": len(components), "inputRows": len(records),
            "limitations": "Verifies declared provenance/review and local separation; does not certify publisher truth, native-speaker quality, or unknown upstream pretrained-model ownership."}


def require_ready(plan_path, root):
    plan = json.loads(plan_path.read_text())
    result = audit(plan, root)
    if not result["trainingReady"]:
        raise ValueError("prospective data gate not ready: " + "; ".join(result["errors"][:8]))
    return result


def verify_profile_contract(profile, corpus, root):
    """Bind the gate to the actual runner input, not an unrelated good receipt."""
    if not profile.get("prospectiveDataPlan"):
        return None
    plan_path = pinned(root, {"path": profile["prospectiveDataPlan"],
                              "sha256": profile["prospectiveDataPlanSHA256"]})
    result = require_ready(plan_path, root)
    plan = json.loads(plan_path.read_text())

    def signatures(path):
        return Counter((row["text"], row["label"], row["language"])
                       for row in (json.loads(line) for line in path.read_text().splitlines() if line))

    expected_train = signatures(pinned(root, plan["baseTraining"]))
    expected_train.update(signatures(pinned(root, plan["datasets"]["train"])))
    if signatures(root / corpus["training"]) != expected_train:
        raise ValueError("prospective gate training rows differ from actual approved corpus")
    if signatures(root / corpus["development"]) != signatures(pinned(root, plan["datasets"]["development"])):
        raise ValueError("prospective gate development differs from actual approved corpus")
    return {**result, "planSHA256": sha(plan_path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = audit(json.loads(args.plan.read_text()), args.root)
    result["planSHA256"] = sha(args.plan)
    result["scriptSHA256"] = sha(Path(__file__))
    with args.out.open("x") as stream:
        stream.write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: result[k] for k in ("trainingReady", "inputRows", "errors")}, ensure_ascii=False))
    raise SystemExit(0 if result["trainingReady"] else 2)


if __name__ == "__main__":
    main()
