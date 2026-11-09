import unittest
import sys
from pathlib import Path
import torch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from evaluation_audit_v86 import action_map, score, subaction, composition, without_vi


class EvaluationAuditTests(unittest.TestCase):
    def row(self, label='promotion', kind='commercial', text='example', form='sms-text', fine=True):
        return dict(text=text, label=label, language='en', filterReview=dict(kind=kind,inputForm=form,fineLabelScored=fine))

    def pred(self, label='promotion', action='junk', leaf='spam', sub='none'):
        return dict(label=label,engineAction=action,engineLabel=leaf,engineSubAction=sub)

    def test_policy_is_not_strict_action_or_fine(self):
        result=score([self.row()],[self.pred()],{'promotion':'promotion'})
        self.assertEqual(result['policyActionAccuracy'],1.)
        self.assertEqual(result['strictActionAccuracy'],0.)
        self.assertEqual(result['fineAccuracy'],0.)

    def test_harmful_promotion_is_error(self):
        result=score([self.row('spam','harmful')],[self.pred('spam','promotion','promotion')],{'spam':'junk'})
        self.assertEqual(result['policyActionAccuracy'],0.)

    def test_normal_requires_correct_action(self):
        result=score([self.row('__sift_abstain__','normal')],[self.pred('__sift_abstain__','transaction','life.other')],{'__sift_abstain__':'none'})
        self.assertEqual(result['policyActionAccuracy'],0.)

    def test_exclusions_independent_of_prediction(self):
        rows=[self.row(kind='unresolved',form='scenario-description'),self.row(form='scenario-description'),self.row(fine=False)]
        result=score(rows,[self.pred()]*3,{'promotion':'promotion'})
        self.assertEqual((result['total'],result['actionScored'],result.get('fineScored',0)),(3,1,0))
        self.assertEqual((result['excludedUnresolved'],result['excludedScenario']),(1,1))

    def test_supported_subaction_and_gold_disagreement(self):
        self.assertEqual(subaction('finance.refund','transaction'),'transactionalFinance')
        self.assertEqual(subaction('life.medical','transaction'),'none')
        self.assertEqual(subaction('work.meeting','transaction'),'transactionalReminders')
        p=self.pred();p['expectedSubAction']='none'
        with self.assertRaises(ValueError):score([self.row()],[p],{'promotion':'promotion'})

    def test_membership_mismatch_fails(self):
        with self.assertRaises(ValueError):score([self.row()],[],{'promotion':'promotion'})
        with self.assertRaises(ValueError):score([self.row()],[self.pred(label='spam')],{'promotion':'promotion'})

    def test_taxonomy_override(self):
        a=action_map({'groups':[{'systemAction':'transaction','leaves':[{'id':'x'},{'id':'y','systemAction':'promotion'}]}]})
        self.assertEqual(a,{'__sift_abstain__':'none','x':'transaction','y':'promotion'})

    def test_digit_duplicates_and_label_conflict(self):
        rows=[self.row(text='CODE １２３'),self.row('spam','harmful',text='code 987')]
        c=composition(rows)
        self.assertEqual((c['uniqueExact'],c['digitClusters'],c['conflictingDigitClusters']),(2,1,1))

    def test_zero_vi_preserves_other_weights_and_does_not_mutate(self):
        w=torch.tensor([.12,1.,.2,3.]);masked=without_vi(w,['vi','zh','vi','ja'])
        self.assertTrue(torch.equal(masked,torch.tensor([0.,1.,0.,3.])))
        self.assertEqual(float(w[2]),float(torch.tensor(.2)))
        with self.assertRaises(ValueError):without_vi(w,['vi'])


if __name__=='__main__':unittest.main()
