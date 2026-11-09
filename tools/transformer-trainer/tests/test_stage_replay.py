from pathlib import Path
import sys
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from stage_replay import audit_partition, audit_reviewed_partition, text_hash


class StageReplayTests(unittest.TestCase):
    def setUp(self):
        self.old=[{'text':'An already learned message','label':'spam','source':'public-reviewed-v9:a'}]
        self.new={'text':'A genuinely new stage message','label':'promotion','source':'public-reviewed-v12:b'}

    def test_only_new_rows_receive_correction_ownership(self):
        result=audit_partition(self.old,self.old+[self.new],['public-reviewed-v12:'])
        self.assertEqual(result['historicalMarkedCorrection'],0)
        self.assertEqual(result['correctionRows'],1)
        self.assertEqual(result['replayRows'],1)

    def test_broad_prefix_is_rejected_except_explicit_control(self):
        with self.assertRaisesRegex(ValueError,'historical rows'):
            audit_partition(self.old,self.old+[self.new],['public-reviewed-'])
        result=audit_partition(self.old,self.old+[self.new],['public-reviewed-'],allow_historical=True)
        self.assertEqual(result['historicalMarkedCorrection'],1)

    def test_new_rows_cannot_silently_become_replay_and_gold_cannot_change(self):
        with self.assertRaisesRegex(ValueError,'missing'):
            audit_partition(self.old,self.old+[self.new],['unrelated:'])
        with self.assertRaisesRegex(ValueError,'label changed'):
            audit_partition(self.old,[{**self.old[0],'label':'promotion'}],['public-reviewed-'])
        with self.assertRaisesRegex(ValueError,'omitted'):
            audit_partition(self.old,[self.new],['public-reviewed-v12:'])
        with self.assertRaisesRegex(ValueError,'duplicated'):
            audit_partition(self.old,self.old+self.old,['unrelated:'])
        with self.assertRaisesRegex(ValueError,'historical rows'):
            audit_partition(self.old,[{**self.old[0],'source':'public-reviewed-v12:renamed'}],
                ['public-reviewed-v12:'])

    def test_reviewed_relabel_cannot_be_distilled_or_reverted(self):
        old=self.old[0];key=text_hash(old)
        ownership={'count':1,'rows':[{'textSHA256':key,'label':'spam'}]}
        decision={'textSHA256':key,'oldLabel':'spam','action':'relabel','newLabel':'promotion'}
        repaired={**old,'label':'promotion','source':'repair:1'}
        result=audit_reviewed_partition(ownership,[repaired],[decision],['repair:'])
        self.assertEqual(result['correctionRows'],1)
        for row in [{**repaired,'source':old['source']},{**repaired,'label':'spam'}]:
            with self.assertRaises(ValueError):
                audit_reviewed_partition(ownership,[row],[decision],['repair:'])

    def test_reviewed_deletion_and_replacement_require_exact_contract(self):
        old=self.old[0];key=text_hash(old)
        ownership={'count':1,'rows':[{'textSHA256':key,'label':'spam'}]}
        drop={'textSHA256':key,'oldLabel':'spam','action':'drop'}
        self.assertEqual(audit_reviewed_partition(ownership,[],[drop],['repair:'])['reviewedHistoricalDeletions'],1)
        with self.assertRaises(ValueError):
            audit_reviewed_partition(ownership,[old],[drop],['repair:'])
        repaired={'text':'A coherent replacement body','label':'spam','source':'repair:1'}
        edit={**drop,'action':'edit','newTextSHA256':text_hash(repaired)}
        self.assertEqual(audit_reviewed_partition(ownership,[repaired],[edit],['repair:'])['correctionRows'],1)
        for rows in [[],[{**old,'source':'repair:old'}],[{**repaired,'label':'promotion'}]]:
            with self.assertRaises(ValueError):
                audit_reviewed_partition(ownership,rows,[edit],['repair:'])
