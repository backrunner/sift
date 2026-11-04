import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import admit_reviewed_v89 as admit


class Retired:
    def __init__(self, reason=None): self.value = reason
    def reason(self, _row): return self.value


def decision(text, label='work.alert', state='admit'):
    return {'textSHA256': admit.digest(text), 'label': label, 'language': 'en', 'originalSource': 'augmentation:boundary:x',
            'decision': state, 'reason': 'reviewed'}


class AdmissionTests(unittest.TestCase):
    BASE = [{'text': 'An unrelated existing row about something else'}]

    def test_only_admit_decisions_are_selected(self):
        ledger = dict(independentNativeReview=False, relabeled=0, decisions=[decision('a'), decision('b', state='exclude')])
        self.assertEqual(set(admit.admitted_hashes(ledger)), {admit.digest('a')})

    def test_ledger_cannot_claim_native_review_or_relabel(self):
        with self.assertRaises(ValueError):
            admit.admitted_hashes(dict(independentNativeReview=True, relabeled=0, decisions=[]))
        with self.assertRaises(ValueError):
            admit.admitted_hashes(dict(independentNativeReview=False, relabeled=1, decisions=[]))

    def test_decision_without_reason_is_rejected(self):
        bad = dict(decision('a'), reason='')
        with self.assertRaises(ValueError):
            admit.admitted_hashes(dict(independentNativeReview=False, relabeled=0, decisions=[bad]))

    def test_admitted_row_is_prefixed_and_keeps_its_label(self):
        text = 'The backup vault certificate expires tonight'
        kept = admit.merge(self.BASE, [{'text': text, 'label': 'work.alert'}], {admit.digest(text): decision(text)}, set(), Retired())
        self.assertEqual(kept[0]['label'], 'work.alert')
        self.assertTrue(kept[0]['source'].startswith(admit.SOURCE_PREFIX))

    def test_guards_refuse_label_drift_retired_and_holdout_rows(self):
        text = 'The backup vault certificate expires tonight'; decisions = {admit.digest(text): decision(text)}
        with self.assertRaises(ValueError):
            admit.merge(self.BASE, [{'text': text, 'label': 'promotion'}], decisions, set(), Retired())
        with self.assertRaises(ValueError):
            admit.merge(self.BASE, [{'text': text, 'label': 'work.alert'}], decisions, set(), Retired('retired'))
        with self.assertRaises(ValueError):
            admit.merge(self.BASE, [{'text': text, 'label': 'work.alert'}], decisions, set(admit.keys(text, family=True)), Retired())

    def test_missing_admitted_row_is_an_error(self):
        with self.assertRaises(ValueError):
            admit.merge(self.BASE, [], {admit.digest('gone'): decision('gone')}, set(), Retired())

    def test_coverage_reports_thin_core_cells(self):
        rows = [{'label': 'spam', 'language': g} for g in admit.CORE for _ in range(10)]
        rows = rows[:-1]
        self.assertEqual(admit.coverage(rows, ['spam']), {'spam:ja': 9})


if __name__ == '__main__': unittest.main()
