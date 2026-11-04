from pathlib import Path
import random
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import rebuild_v101 as study
import sms_style_v101 as sms


class StyleTests(unittest.TestCase):
    def sample(self, text, label, language='en', count=400):
        rng = random.Random(1)
        return [sms.style(text, label, language, rng) for _ in range(count)]

    def test_existing_url_is_never_edited(self):
        url = 'https://bidv123.xyz/r/730821'
        for text in self.sample(f'Verify at {url} with 4415', 'spam'):
            self.assertIn(url, text)

    def test_links_are_added_at_the_same_rate_for_every_label(self):
        rates = [sum('https://' in t for t in self.sample('Your item is here', label)) for label in ('spam', 'promotion', 'finance.bank', '__sift_abstain__')]
        self.assertLess(max(rates) - min(rates), 80)
        self.assertTrue(all(70 < r < 170 for r in rates), rates)

    def test_conversations_get_no_signature_or_service_tail(self):
        for text in self.sample('see you at 7', '__sift_abstain__'):
            self.assertTrue(text.startswith('see you at'))
            self.assertNotIn('STOP', text)

    def test_opt_outs_favour_commercial_without_being_exclusive(self):
        commercial = sum('STOP' in t for t in self.sample('Sale today', 'promotion'))
        service = sum('STOP' in t for t in self.sample('Your bill is ready', 'finance.bank'))
        self.assertGreater(commercial, service); self.assertGreater(service, 0)
        self.assertFalse(any('STOP' in t for t in self.sample('Pay the fee now', 'spam')))

    def test_digits_change_but_lengths_hold_and_other_languages_pass_through(self):
        changed = {t for t in self.sample('Code 482913', 'verification') if t.startswith('Code ')}
        self.assertGreater(len(changed), 1)
        self.assertEqual(sms.style('Xin chao 123', 'spam', 'vi', random.Random(1)), 'Xin chao 123')


class TokenizerTests(unittest.TestCase):
    def test_only_training_batches_are_styled(self):
        seen = []
        wrapped = study.StyledTokenizer(lambda texts, **k: seen.append(list(texts)), {'Your bill': ('finance.bank', 'en')}, 3)
        for _ in range(30): wrapped(['Your bill'], padding='max_length')
        self.assertTrue(all(s == ['Your bill'] for s in seen))
        seen.clear()
        for _ in range(60): wrapped(['Your bill'], padding='longest')
        self.assertTrue(any(s != ['Your bill'] for s in seen))


class SelectionTests(unittest.TestCase):
    def test_serious_errors_outrank_fine_and_ties_prefer_earlier(self):
        metric = lambda serious, errors, fine: dict(serious=serious, errors=dict(a=errors), fine=dict(correct=fine))
        self.assertLess(study.rank_key(metric(1, 9, 1), 9), study.rank_key(metric(2, 2, 99), 1))
        self.assertLess(study.rank_key(metric(1, 2, 5), 3), study.rank_key(metric(1, 2, 5), 4))

    def test_budgets_stay_near_earlier_studies(self):
        for rows, arm in ((4294, 'process-v101'), (4631, 'process-data-v101')):
            updates = study.base.window_plan(rows, 32, 4)['updatesPerEpoch'] * study.ARMS[arm]['epochs']
            self.assertLess(abs(updates - 768), 32, arm)


if __name__ == '__main__':
    unittest.main()
