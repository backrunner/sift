"""Run the frozen method only against the verified standalone approved corpus."""
import argparse
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from approved_signal import ROOT,verify


def training_entrypoint(corpus, profile):
    if not corpus.get('filterTargetReview'):
        if profile.get('filterPolicyMode'):
            raise ValueError('filter policy requested without reviewed targets')
        return ROOT/'tools/transformer-trainer/train_mmbert.py', []
    if profile.get('filterPolicyMode') not in ('grouped', 'strict-control'):
        raise ValueError('reviewed target corpus needs explicit grouped/strict-control mode')
    if (profile.get('externalEpochSelection') != 'swift-filter-policy-v47-with-epoch-zero'
            or not profile.get('trainerSelectionIsDiagnosticOnly')):
        raise ValueError('filter policy requires external Swift policy selection including epoch zero')
    return ROOT/corpus['trainingEntrypoint'], [
        '--filter-policy-manifest', str(ROOT/profile['corpusManifest']),
        '--filter-policy-mode', profile['filterPolicyMode'],
    ]


def verify_checkpoint(manifest_path):
    frozen=json.loads(manifest_path.read_text())
    checkpoint=ROOT/frozen['checkpoint']
    for name,digest in frozen['filesSHA256'].items():
        if hashlib.sha256((checkpoint/name).read_bytes()).hexdigest()!=digest:
            raise ValueError('frozen research checkpoint drift: '+name)
    return frozen


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile',type=Path,required=True,
        help='Explicit study profile; historical corpus bodies may have been retired.')
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--resume-state',type=Path,default=None)
    args=parser.parse_args();profile=json.loads(args.profile.read_text())
    corpus=verify(ROOT/profile['corpusManifest'])
    entrypoint, policy_arguments = training_entrypoint(corpus, profile)
    from prospective_data_gate import verify_profile_contract
    prospective_audit=verify_profile_contract(profile,corpus,ROOT)
    frozen=verify_checkpoint(ROOT/profile['frozenBaselineManifest'])
    teacher_manifest=profile.get('teacherManifest')
    if teacher_manifest:
        teacher=verify_checkpoint(ROOT/teacher_manifest)
        if teacher['checkpoint']!=profile['teacherCheckpoint']:
            raise ValueError('teacher checkpoint does not match its frozen manifest')
    from junk_evidence import validate_profile_input
    validate_profile_input(corpus,profile['arguments'],frozen)
    stage_audit=None
    if stage:=profile.get('stageReplayAudit'):
        from stage_replay import audit_partition,audit_reviewed_partition
        read=lambda path:[json.loads(line) for line in (ROOT/path).read_text().splitlines() if line]
        prefixes=[profile['arguments'][i+1] for i,value in enumerate(profile['arguments'])
                  if value=='--replay-new-source-prefix']
        if 'reviewLedger' in stage:
            # Data admission lineage and optimization initialization are distinct.
            # r33 does not acquire invented ownership of A's reviewed corpus.
            ownership_path=ROOT/stage.get('ownershipManifest',profile['frozenBaselineManifest'])
            ownership=json.loads(ownership_path.read_text())
            index_path=ROOT/ownership['ownershipIndex']
            if hashlib.sha256(index_path.read_bytes()).hexdigest()!=ownership['ownershipIndexSHA256']:
                raise ValueError('checkpoint ownership index drift')
            ledger_path=ROOT/stage['reviewLedger']
            if hashlib.sha256(ledger_path.read_bytes()).hexdigest()!=stage['reviewLedgerSHA256']:
                raise ValueError('review ledger drift')
            stage_audit=audit_reviewed_partition(json.loads(index_path.read_text()),
                read(corpus['training']),json.loads(ledger_path.read_text())['decisions'],prefixes)
        else:
            baseline=verify(ROOT/stage['baselineCorpusManifest'])
            if stage['baselineCorpusManifest']!=frozen.get('corpusManifest'):
                raise ValueError('stage baseline corpus does not belong to the frozen checkpoint')
            stage_audit=audit_partition(read(baseline['training']),read(corpus['training']),prefixes,
                allow_historical=stage.get('allowHistoricalControl',False))
    checkpoint=ROOT/frozen['checkpoint']
    for name,digest in frozen['filesSHA256'].items():
        if hashlib.sha256((checkpoint/name).read_bytes()).hexdigest()!=digest:
            raise ValueError('frozen research checkpoint drift: '+name)
    out=args.out.resolve()
    if out.exists():raise ValueError('use a new output directory; existing trial evidence must not be overwritten')
    out.mkdir(parents=True)
    command=[sys.executable,'-u',str(entrypoint),*policy_arguments,
        '--input',str(ROOT/corpus['training']),'--validation-input',str(ROOT/corpus['development']),
        '--resume-from',str(checkpoint),'--replay-teacher',str(ROOT/profile['teacherCheckpoint']),
        '--out',str(out),'--training-state',str(out/'training-state.pt'),
        '--write-predictions',str(out/'development-predictions.ndjson'),
        '--version',profile.get('version','signal-approved-v8-extended'),*profile['arguments']]
    if args.resume_state:command.extend(['--resume-training-state',str(args.resume_state.resolve())])
    files=[args.profile,ROOT/profile['frozenBaselineManifest'],ROOT/profile['corpusManifest'],
        *[ROOT/p for p in corpus['filesSHA256']],
        *[ROOT/'tools/transformer-trainer'/f for f in ('train_mmbert.py','training_progress.py',
            'training_optimization.py','generalization_validation.py','semantic_regularization.py',
            'replay_distillation.py','retired_samples.py','approved_signal.py','prepare_approved_signal.py',
            'spam_objective.py','stage_replay.py','gradient_diagnostics.py','low_rank_adaptation.py','parameter_anchor.py','junk_evidence.py','loss_tail.py','run_approved_signal.py')]]
    if args.resume_state:files.append(args.resume_state.resolve())
    if '--extend-training-state' in profile['arguments']:
        files.append(ROOT/profile['arguments'][profile['arguments'].index('--extend-training-state')+1])
        files.append(ROOT/'tools/transformer-trainer/training_extension.py')
    files.append(ROOT/'tools/transformer-trainer/url_contrast.py')
    files.append(ROOT/'tools/transformer-trainer/label_mass.py')
    files.append(ROOT/'tools/transformer-trainer/hard_label_loss.py')
    files.append(ROOT/'tools/transformer-trainer/multilingual_views.py')
    files.append(ROOT/'tools/transformer-trainer/training_backend.py')
    files.append(ROOT/'tools/transformer-trainer/sharpness_aware.py')
    files.append(ROOT/'tools/transformer-trainer/scene_contrastive.py')
    if '--scene-contrastive-spec' in profile['arguments']:
        spec=ROOT/profile['arguments'][profile['arguments'].index('--scene-contrastive-spec')+1]
        if corpus['filesSHA256'].get(str(spec.relative_to(ROOT)))!=hashlib.sha256(spec.read_bytes()).hexdigest():
            raise ValueError('scene groups must be pinned in the approved corpus')
        files.append(spec)
    if '--multilingual-view-spec' in profile['arguments']:
        view_spec = ROOT/profile['arguments'][profile['arguments'].index('--multilingual-view-spec')+1]
        if corpus['filesSHA256'].get(str(view_spec.relative_to(ROOT))) != hashlib.sha256(view_spec.read_bytes()).hexdigest():
            raise ValueError('multilingual views must be pinned in the approved corpus')
        files.append(view_spec)
    if '--preserve-label-mass-from' in profile['arguments']:
        reference = ROOT/profile['arguments'][profile['arguments'].index('--preserve-label-mass-from')+1]
        if corpus['filesSHA256'].get(str(reference.relative_to(ROOT))) != hashlib.sha256(reference.read_bytes()).hexdigest():
            raise ValueError('label-mass reference must be pinned in the approved corpus')
        files.append(reference)
    if profile.get('studyProtocol'):files.append(ROOT/profile['studyProtocol'])
    if profile.get('prospectiveDataPlan'):
        files.extend([ROOT/profile['prospectiveDataPlan'],
                      ROOT/'tools/transformer-trainer/prospective_data_gate.py'])
    if stage and 'reviewLedger' in stage:
        files.extend([ownership_path,index_path,ledger_path])
    if teacher_manifest:files.append(ROOT/teacher_manifest)
    protocol={'createdUTC':datetime.now(timezone.utc).isoformat(),'profile':profile,'argv':command,
        'inputAndSourceSHA256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
        'releaseEligible':False,'newFinalHoldoutEvaluated':False,'stageReplayAudit':stage_audit,
        'prospectiveDataAudit':prospective_audit}
    (out/'protocol.json').write_text(json.dumps(protocol,ensure_ascii=False,indent=2)+'\n')
    with (out/'training.log').open('w') as log:
        subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,check=True)
    summary=json.loads((out/'tuning-summary.json').read_text())
    print(json.dumps({'out':str(out),'updates':summary['optimization']['completedUpdates'],
        'stopReason':summary['optimization']['stopReason'],
        'eligible':summary['developmentSelection']['eligibleEpochFound']},indent=2))


if __name__=='__main__':main()
