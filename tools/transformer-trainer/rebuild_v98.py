"""Can a new 22-layer teacher lift a 12-layer student on the current data?

The v56 depth comparison stopped on a defect, and every earlier distillation copied a
SAM-era teacher inside a trust region. V98 trains a teacher with the free recipe, and
distills a student only if the teacher beats the current encoder on the spent pool. Alpha
.7 and temperature 2 match the app's distillation contract. It cannot install a model.

Stages run in order: smoke, seal, warm, teacher --seed S, teacher-select,
student --seed S, student-select.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile

import rebuild_v88 as base
import rebuild_v89 as v89
import rebuild_v92 as v92
import rebuild_v94 as v94

ROOT = base.ROOT
NAME = 'signal-rebuild-v98'
OUT = ROOT / 'build/signal-rebuild-v98-20261104'
STORAGE = Path.home() / 'Library/Caches/SiftTraining' / OUT.name
PROTOCOL = ROOT / 'tools/transformer-trainer/experiments' / (NAME + '-protocol.json')
TRAINING = v94.HOSTS
INITIAL_22 = 'build/signal-capacity-v56-20261101/initial-22/checkpoint'
TEACHER = 'teacher-v98'
STUDENT = 'student-v98'
SPEC = {TEACHER: dict(init='warmed', layers=22, lr=2e-5), STUDENT: dict(init='sam', layers=12, lr=1e-5)}
EPOCHS = 23
ALPHA = .7
TEMPERATURE = 2.
THREADS = 4


def teacher_passes(teacher, reference):
    """Worth distilling only if the teacher is at least as good on action and on fine labels."""
    return bool(teacher['policyActionCorrect'] >= reference['policyActionCorrect']
                and teacher['fineCorrect'] >= reference['fineCorrect'])


def soft_targets(teacher_logits, labels, hard, temperature=TEMPERATURE, alpha=ALPHA):
    """Mix hard loss with KL only where the teacher agrees with the reviewed label."""
    def loss(student_logits, target):
        import torch.nn.functional as F
        kl = F.kl_div(F.log_softmax(student_logits / temperature, -1), F.softmax(target / temperature, -1), reduction='none').sum(-1) * temperature ** 2
        correct = (target.argmax(-1) == labels).float()
        return (1 - alpha * correct) * hard + alpha * correct * kl
    return loss(teacher_logits[0], teacher_logits[1])


def install(arm):
    base.ARMS[arm] = dict(SPEC[arm]); base.STORAGE = STORAGE; base.PROTOCOL = PROTOCOL; base.COMMON['threads'] = THREADS
    base.PRETRAINED = INITIAL_22
    rows = base.read(ROOT / TRAINING); weights = v89.weights_for(rows, v89.cell_weights())
    base.training_inputs = lambda: (rows, weights)
    return rows


def check():
    protocol = json.loads(PROTOCOL.read_text())
    for path, digest in protocol['filesSHA256'].items():
        if base.sha(ROOT / path) != digest: raise ValueError('sealed dependency drift: ' + path)
    return protocol


def reference():
    results = json.loads((v92.OUT / 'selection.json').read_text())['results']
    return {s: results[f'free-v92:{s}']['selected'] for s in base.SEEDS}


def smoke():
    rows = install(TEACHER); base.warm()
    with tempfile.TemporaryDirectory() as folder:
        print('smoke', len(rows), base.fit(TEACHER, base.SEEDS[0], Path(folder), 1, max_updates=2, evaluate=False), flush=True)


def seal():
    if PROTOCOL.exists(): raise ValueError('protocol is sealed; use a new version')
    rows = base.read(ROOT / TRAINING); others = {p: base.read(ROOT / p) for p in [*base.SELECTION.values(), base.HISTORY, *base.ISOLATION]}
    leaks = base.overlap(rows, others)
    if any(leaks.values()): raise ValueError(f'holdout overlap {leaks}')
    me = Path(__file__).resolve()
    files = [TRAINING, base.RUNTIME, INITIAL_22 + '/config.json', INITIAL_22 + '/model.safetensors', 'build/signal-rebuild-v92-20261104/selection.json', *base.SELECTION.values(),
             *[str(me.with_name(n).relative_to(ROOT)) for n in ('rebuild_v88.py', 'rebuild_v89.py', 'rebuild_v92.py', 'rebuild_v94.py')],
             str(me.with_name('tests').joinpath('test_rebuild_v98.py').relative_to(ROOT)), str(me.relative_to(ROOT))]
    PROTOCOL.write_text(json.dumps(dict(name=NAME, createdUTC=datetime.now(timezone.utc).isoformat(), teacher=SPEC[TEACHER], student=SPEC[STUDENT], epochs=EPOCHS, alpha=ALPHA, temperature=TEMPERATURE,
        common=base.COMMON | {'threads': THREADS}, seeds=base.SEEDS, rows=len(rows), updates=base.window_plan(len(rows), 32, 4)['updatesPerEpoch'] * EPOCHS,
        reference='free-v92 selected epochs on the spent pool.',
        teacherRule='Per seed, teacher policy action and fine on spent old493+dev636 at or above free-v92. If either seed fails, no student is trained.',
        studentRule='Epoch selected on the spent pool like v88. Student and free-v92 are judged only on a test written before the student is first scored, on serious errors first.',
        limits=['The teacher nearly memorizes training rows, so soft targets may carry little extra information; only rows it labels correctly use them.', 'The spent pool has few harmful rows and no real-format normal links.', 'All existing test sets are spent, so a new one is needed. Reserved 636 needs user approval.'],
        reservedScored=False, automaticReplacement=False, releaseEligible=False, filesSHA256={f: base.sha(ROOT / f) for f in files}), ensure_ascii=False, indent=2) + '\n')
    print('sealed', flush=True)


def warm():
    check(); install(TEACHER); base.warm()


def train_teacher(seed):
    check(); install(TEACHER); target = STORAGE / f'{TEACHER}-{seed}'
    if target.exists(): raise ValueError('trial output exists: ' + str(target))
    base.fit(TEACHER, seed, target, EPOCHS)


def select_arm(arm):
    results = {}; cohorts = {k: base.read(ROOT / p) for k, p in base.SELECTION.items()}
    for seed in base.SEEDS:
        trial = STORAGE / f'{arm}-{seed}'; records = []
        for epoch in range(EPOCHS + 1):
            parts = {name: base.replay(rows, base.read(trial / f'epoch-{epoch:03d}-{name}-predictions.ndjson'), trial / f'epoch-{epoch:03d}-{name}')[1] for name, rows in cohorts.items()}
            records.append(dict(epoch=epoch, **base.pooled(list(parts.values()))))
        chosen = base.select_epoch(records)
        results[f'{arm}:{seed}'] = dict(selectedEpoch=chosen['epoch'], selected={k: chosen[k] for k in ('policyActionCorrect', 'fineCorrect', 'normalToJunk', 'actionScored')})
        print(arm, seed, results[f'{arm}:{seed}'], flush=True)
    return results


def teacher_select():
    check(); results = select_arm(TEACHER); ref = reference()
    signal = {str(s): teacher_passes(results[f'{TEACHER}:{s}']['selected'], ref[s]) for s in base.SEEDS}
    OUT.mkdir(exist_ok=True); (OUT / 'teacher.json').write_text(json.dumps(dict(results=results, reference={str(k): v for k, v in ref.items()}, signal=signal, authorized=all(signal.values())), indent=1) + '\n')
    print('teacher signal', signal, flush=True)


def teacher_logits(seed, rows):
    import torch
    from transformers import AutoTokenizer
    source = STORAGE / 'warmed-12'; tokenizer = AutoTokenizer.from_pretrained(source, local_files_only=True); model = base.load_model(source).eval()
    epoch = json.loads((OUT / 'teacher.json').read_text())['results'][f'{TEACHER}:{seed}']['selectedEpoch']
    state = torch.load(STORAGE / f'{TEACHER}-{seed}/epoch-{epoch:03d}.pt', weights_only=True)['parameters']
    with torch.no_grad():
        for name, value in model.named_parameters():
            if name in state: value.copy_(state[name])
    torch.set_num_threads(8); result = {}
    with torch.inference_mode():
        for start in range(0, len(rows), 32):
            batch = rows[start:start + 32]
            tokens = tokenizer([r['text'] for r in batch], padding='longest', truncation=True, max_length=base.COMMON['maxLength'], return_tensors='pt')
            for row, value in zip(batch, model(**tokens).logits): result[row['text']] = value.clone()
    return result


def train_student(seed):
    import transformers
    check()
    if not json.loads((OUT / 'teacher.json').read_text())['authorized']: raise ValueError('teacher did not pass; student is not authorized')
    rows = install(STUDENT); soft = teacher_logits(seed, rows); holder = {}; hard_objective = base.commercial_objective
    loader = transformers.AutoTokenizer.from_pretrained

    class Recording:
        def __init__(self, tokenizer): self.tokenizer = tokenizer
        def __call__(self, texts, **kwargs):
            holder['texts'] = texts
            return self.tokenizer(texts, **kwargs)
        def __getattr__(self, name): return getattr(self.tokenizer, name)

    def objective(logits, labels, label_to_id):
        import torch
        target = torch.stack([soft[t] for t in holder['texts']])
        return soft_targets((logits, target), labels, hard_objective(logits, labels, label_to_id))

    transformers.AutoTokenizer.from_pretrained = lambda *a, **k: Recording(loader(*a, **k))
    base.commercial_objective = objective
    target = STORAGE / f'{STUDENT}-{seed}'
    if target.exists(): raise ValueError('trial output exists: ' + str(target))
    base.fit(STUDENT, seed, target, EPOCHS)


def student_select():
    check(); results = select_arm(STUDENT)
    (OUT / 'student.json').write_text(json.dumps(dict(testsUsed=False, results=results), indent=1) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('stage', choices=('smoke', 'seal', 'warm', 'teacher', 'teacher-select', 'student', 'student-select'))
    parser.add_argument('--seed', type=int, choices=base.SEEDS)
    a = parser.parse_args()
    if a.stage == 'teacher': train_teacher(a.seed)
    elif a.stage == 'student': train_student(a.seed)
    else: dict(smoke=smoke, seal=seal, warm=warm, **{'teacher-select': teacher_select, 'student-select': student_select})[a.stage]()
