from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from prepare_public_generalization import render,public_hosts,valid_contributor


class PublicGeneralizationTests(unittest.TestCase):
    def test_contributor_grouping_accepts_upstream_opaque_ids(self):
        self.assertTrue(valid_contributor('51'))
        self.assertTrue(valid_contributor('c57e431fa8694589a21c037eba26d4f1'))
        for value in ['',None,'Unknown','null','0']:self.assertFalse(valid_contributor(value))

    def test_public_host_preserved_but_identifying_url_tail_removed(self):
        text,hosts,missing=render('Account notice: https://secure-service.test/path/session123456789?person=abc')
        self.assertEqual(hosts,['secure-service.test'])
        self.assertNotIn('session123456789',text)
        self.assertEqual(text,'Account notice: https://secure-service.test/review')
        self.assertFalse(missing)

    def test_missing_url_cannot_invent_fraud_evidence(self):
        text,hosts,missing=render('Your parcel status is available here: <URL>')
        self.assertEqual(hosts,[]);self.assertTrue(missing)
        self.assertNotIn('https://',text)

    def test_hosts_still_detected_when_other_roles_make_body_unusable(self):
        text='Call 123456789 to view https://example.net/a and https://second.org/b'
        with self.assertRaises(ValueError):render(text)
        self.assertEqual(public_hosts(text),{'example.net','second.org'})

    def test_unknown_number_time_and_contact_roles_are_rejected(self):
        for text in ['Appointment <DATE_TIME> is ready for you.', 'Pay [NUMBER] now for service.',
                     'Send a response to person@domain.com now.','Your reference is 123456789 today.']:
            with self.subTest(text=text),self.assertRaises(ValueError):render(text)
