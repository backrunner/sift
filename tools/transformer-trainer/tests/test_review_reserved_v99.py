from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import review_reserved_v99 as review


class ReviewTests(unittest.TestCase):
    def test_only_listed_families_leave_fine_scoring_and_gold_stays(self):
        rows = [dict(familyId='carrier.billing-5', label='carrier.billing', filterReview=dict(fineLabelScored=True, kind='normal')),
                dict(familyId='spam-4', label='spam', filterReview=dict(fineLabelScored=True, kind='harmful'))]
        output = review.reviewed(rows)
        self.assertFalse(output[0]['filterReview']['fineLabelScored'])
        self.assertTrue(output[1]['filterReview']['fineLabelScored'])
        self.assertEqual([r['label'] for r in output], ['carrier.billing', 'spam'])
        self.assertTrue(rows[0]['filterReview']['fineLabelScored'], 'source rows stay unchanged')

    def test_interval_resamples_families_so_translations_count_together(self):
        families = [f for i in range(40) for f in [i] * 3]
        better = [i % 3 == 0 or i < 30 for i in range(120)]
        result = review.family_difference(better, [False] * 120, families)
        self.assertEqual(result['difference'], sum(better))
        self.assertGreater(result['low'], 0)
        tied = review.family_difference([True] * 120, [True] * 120, families)
        self.assertEqual((tied['difference'], tied['low'], tied['high']), (0, 0, 0))


if __name__ == '__main__':
    unittest.main()
