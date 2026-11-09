from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import sift_pipeline


class ApprovedEntryTests(unittest.TestCase):
    def test_entry_uses_verified_frozen_profile_and_optional_exact_state(self):
        args=SimpleNamespace(signal_study_out=Path('build/new-approved-study'),
            signal_study_profile=Path('tools/transformer-trainer/experiments/study.json'),
            signal_resume_state=Path('build/interrupted/training-state.pt'))
        with patch.object(sift_pipeline,'require_tool'),patch.object(sift_pipeline,'run') as run:
            sift_pipeline.stage_train_signal_approved(args)
        command=run.call_args.args[0]
        self.assertEqual(command[:3],['uv','run','run_approved_signal.py'])
        self.assertEqual(command[command.index('--profile')+1],str(args.signal_study_profile.resolve()))
        self.assertEqual(command[command.index('--resume-state')+1],str(args.signal_resume_state.resolve()))
        self.assertNotIn('--install-ios',command)
        self.assertEqual(run.call_args.kwargs['cwd'],sift_pipeline.TRANSFORMER_TRAINER)

    def test_retired_historical_default_is_not_started(self):
        with patch.object(sift_pipeline,'run') as run:
            with self.assertRaisesRegex(SystemExit,'signal-study-profile'):
                sift_pipeline.stage_train_signal_approved(SimpleNamespace(signal_study_profile=None))
        run.assert_not_called()


if __name__=='__main__':unittest.main()
