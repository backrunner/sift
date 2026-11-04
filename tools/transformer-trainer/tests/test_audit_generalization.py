import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from audit_generalization import attach, audit, cohort, language, training_policy_findings


class GeneralizationAuditTests(unittest.TestCase):
    def rows(self, count, correct, source):
        rows = [{'text': 'private body ' + str(i), 'label': 'normal', 'source': source} for i in range(count)]
        predictions = [dict(r, prediction='normal' if i < correct else 'spam', confidence=.95)
                       for i,r in enumerate(rows)]
        return attach(rows, predictions, None, [20]*count)

    def test_source_matching_does_not_call_a_mixture_gap_pure_overfitting(self):
        train = self.rows(90, 90, 'synthetic:en') + self.rows(10, 6, 'public-reviewed-v3:nus-en')
        development = self.rows(4, 2, 'public-reviewed-v4:nus-en')
        result = audit(train, development, {'normal': 'none', 'spam': 'junk'})
        self.assertAlmostEqual(result['training']['overall']['accuracy'], .96)
        matched = result['matchedGaps'][1]
        self.assertAlmostEqual(matched['trainingAccuracyReweightedToDevelopmentCells'], .6)
        self.assertAlmostEqual(matched['residualGap'], .1)
        self.assertNotIn('private body', json.dumps(result))

    def test_missing_same_source_label_support_is_visible(self):
        train = self.rows(4, 4, 'synthetic:en')
        development = self.rows(2, 1, 'public-reviewed-v3:nus-en')
        result = audit(train, development, {'normal': 'none', 'spam': 'junk'})
        self.assertEqual(result['matchedGaps'][2]['matchedDevelopmentRows'], 0)
        self.assertEqual(result['matchedGaps'][2]['missingCells'][0]['developmentRows'], 2)

    def test_prediction_drift_fails_instead_of_realigning_gold(self):
        row = {'text': 'body', 'label': 'normal'}
        with self.assertRaisesRegex(ValueError, 'gold'):
            attach([row], [dict(row,label='spam',prediction='spam')], None, [12])

    def test_source_language_and_parent_variant_are_not_guessed_from_ascii(self):
        row = {'text': 'Ma xac nhan cua ban', 'source': 'public-reviewed-v3:vietnamese-train'}
        self.assertEqual(language(row), 'vi')
        self.assertEqual(cohort(row), 'vietnamese-train')
        row['source'] = 'augmentation:boundary:signal-v64:vi-ascii'
        self.assertEqual(language(row), 'vi')
        self.assertEqual(cohort(row), 'derived-v64')

    def test_truncation_and_action_boundary_are_separate_from_raw_label_error(self):
        rows = [{'text': 'an offer', 'label': 'promotion', 'source':'synthetic:en'}]
        predictions = [dict(rows[0],prediction='carrier.promotion',confidence=.99)]
        records = attach(rows, predictions, None, [97])
        result = audit(records, records, {'promotion':'promotion','carrier.promotion':'promotion'})
        self.assertEqual(result['training']['overall']['correct'], 0)
        self.assertEqual(result['training']['overall']['actionCorrect'], 1)
        self.assertEqual(result['training']['length']['truncated']['count'], 1)

    def test_policy_audit_flags_clear_money_movement_but_not_generic_loan_debit(self):
        rows = [dict(text=text,label='finance.bank') for text in [
            'Debit account 1234 recorded a merchant purchase yesterday.',
            '借记账户1234发生商户消费20元。', '口座から店舗決済で支出しました。',
            'Balance update: $30 credited to account ending 1234.',
            'Your loan is approved. Please review its debit terms.']]
        findings = training_policy_findings(rows)
        self.assertEqual(len(findings), 4)
        self.assertFalse(any(r['applied'] for r in findings))
        self.assertNotIn('Debit account', json.dumps(findings))


if __name__ == '__main__':
    unittest.main()
