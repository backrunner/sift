from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import evaluate_signal_v100 as e

ACTIONS = dict(spam='junk', promotion='promotion', a='transaction', b='none')


def row(label, kind, text='x', **extra):
    return dict(label=label, text=text, language='en', filterReview=dict(kind=kind, inputForm='sms-text', fineLabelScored=True), **extra)


def decision(action, label='a'): return dict(engineAction=action, engineLabel=label)


class ErrorTests(unittest.TestCase):
    def test_every_error_type(self):
        cases = ((row('spam', 'harmful'), 'none', 'harmful missed'), (row('spam', 'harmful'), 'junk', None),
                 (row('promotion', 'commercial'), 'none', 'commercial missed'), (row('promotion', 'commercial'), 'junk', None),
                 (row('a', 'normal'), 'junk', 'normal to junk'), (row('a', 'normal'), 'promotion', 'normal to promotion'),
                 (row('a', 'normal'), 'none', 'filing'), (row('a', 'normal'), 'transaction', None))
        for r, action, expected in cases:
            self.assertEqual(e.error_of(r, decision(action), ACTIONS), expected)

    def test_unscorable_filing_never_hides_a_false_block(self):
        self.assertIsNone(e.error_of(row('a', 'normal'), decision('none'), ACTIONS, filing=False))
        self.assertEqual(e.error_of(row('a', 'normal'), decision('junk'), ACTIONS, filing=False), 'normal to junk')


class StrataTests(unittest.TestCase):
    def test_link_kinds(self):
        self.assertEqual(e.link_kind('hello'), 'no link')
        self.assertEqual(e.link_kind('see https://x.invalid/r'), 'placeholder host')
        self.assertEqual(e.link_kind('see https://x.jp/r'), 'real-format host')

    def test_translations_share_a_family(self):
        rows = [dict(text='您的包裹已到达', familyId='f1'), dict(text='Your parcel has arrived today', familyId='f1'), dict(text='午後から雨が降ります', familyId='f2')]
        groups = e.families(rows)
        self.assertEqual(groups[0], groups[1]); self.assertNotEqual(groups[0], groups[2])


class ReportTests(unittest.TestCase):
    def test_report_counts_serious_first_and_respects_fine_exclusion(self):
        rows = [row('spam', 'harmful', 'a b c'), dict(row('a', 'normal', 'd e f'), _fine=False), row('a', 'normal', 'g h i')]
        result = e.report(rows, [decision('none', 'spam'), decision('junk', 'b'), decision('transaction', 'b')], ACTIONS)
        self.assertEqual(result['serious'], 2)
        self.assertEqual(result['errors']['harmful missed'], 1)
        self.assertEqual(result['fine'], dict(correct=1, scored=2, rate=.5))

    def test_comparison_sign_favours_first_model(self):
        rows = [row('spam', 'harmful', f'unique message number {w}') for w in 'abcdefghij']
        good = [decision('junk', 'spam')] * 10; bad = [decision('none', 'a')] * 10
        result = e.compare(rows, good, bad, ACTIONS)
        self.assertEqual(result['seriousFewerInA']['difference'], 10)
        self.assertEqual(result['fineMoreInA']['difference'], 10)
        self.assertGreater(result['seriousFewerInA']['low'], 0)


class SealTests(unittest.TestCase):
    def test_sealed_set_is_refused_until_opened(self):
        import json
        from pathlib import Path
        import tempfile
        original = e.REGISTRY
        try:
            with tempfile.TemporaryDirectory() as folder:
                e.REGISTRY = Path(folder) / 'registry.json'
                e.REGISTRY.write_text(json.dumps(dict(sets=dict(locked=dict(tier='sealed', path='unused')))))
                with self.assertRaises(SystemExit):
                    e.load_set('locked')
        finally:
            e.REGISTRY = original


if __name__ == '__main__':
    unittest.main()
