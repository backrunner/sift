#!/usr/bin/env python3
"""Train the Sift transformer variant with mmBERT and export Core ML.

This trainer uses supervised fine-tuning (`AutoModelForSequenceClassification`).
The default backbone is `jhu-clsp/mmBERT-small`, a
ModernBERT multilingual encoder with a Gemma-style metaspace BPE tokenizer.

Artifacts:

  SiftSignalModel.mlpackage                 Core ML classifier
  SiftSignalModel.tokenizer.siftbpe         memory-mapped BPE tokenizer
  SiftSignalModel.manifest.json             iOS loader metadata

The Core ML model takes `input_ids` / `attention_mask` int32 tensors of shape
`[1, max_length]` and emits a Core ML classifier label plus probabilities.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import shutil
import sys
import tempfile
import types
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

from compact_tokenizer import write_compact_bpe_tokenizer
from model_contract import MODEL_ABI_V1, model_labels

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

MODEL_INPUT_IDS = "input_ids"
MODEL_ATTENTION_MASK = "attention_mask"
DEFAULT_BACKBONE = "jhu-clsp/mmBERT-small"


@dataclass
class Arguments:
    input: Path
    out: Path
    backbone: str
    model_name: str
    version: str
    languages: list[str]
    max_length: int
    validation_fraction: float
    num_epochs: int
    batch_size: int
    learning_rate: float
    weight_decay: float
    warmup_ratio: float
    label_smoothing: float
    classifier_dropout: float | None
    attention_dropout: float | None
    embedding_dropout: float | None
    mlp_dropout: float | None
    classifier_pooling: str | None
    freeze_encoder: bool
    train_new_label_rows_only: bool
    train_label_rows: list[str]
    boundary_loss_weight: float
    selected_label_loss_weight: float
    truncate_layers: int
    quantize: str
    quantization_profile: str
    release_sequence: int
    model_abi: str
    minimum_app_build: int
    maximum_app_build: int
    device: str
    resume_from: Path | None
    save_checkpoint: str
    install_ios: bool
    max_rows: int | None
    test_input: Path | None
    write_predictions: Path | None
    skip_export: bool
    seed: int
    replay_teacher: Path | None = None
    replay_alpha: float = 0.9
    replay_temperature: float = 2.0
    replay_new_source_prefix: list[str] | None = None
    train_last_layers: int = 0
    replay_new_loss_weight: float = 1.
    replay_only_correct_teacher: bool = False
    validation_input: Path | None = None
    early_stopping_patience: int = 0
    early_stopping_delta: float = .002
    optimizer_policy: str = 'grouped'
    head_lr_multiplier: float = 1.
    layer_lr_decay: float = 1.
    lr_scheduler: str = 'linear'
    gradient_accumulation_steps: int = 1
    max_grad_norm: float = 1.
    adam_beta1: float = .9
    adam_beta2: float = .999
    adam_epsilon: float = 1e-8
    validation_max_benign_junk: int | None = None
    validation_selection_objective: str = "macro-f1"
    validation_min_spam_recall: float | None = None
    action_loss_weight: float = 0.
    rdrop_alpha: float = 0.
    spam_loss_weight: float = 0.
    spam_positive_weight: float | None = None
    max_updates: int = 0
    convergence_patience: int = 0
    convergence_min_updates: int = 1500
    training_state: Path | None = None
    resume_training_state: Path | None = None
    extend_training_state: Path | None = None
    gradient_probe_every: int = 0
    convergence_require_training_plateau: bool = False
    lora_rank: int = 0
    lora_alpha: float = 8.
    lora_dropout: float = .05
    validation_max_nonspam_junk: int | None = None
    replay_agreement_all_rows: bool = False
    replay_hard_label_mode: str = 'mixed'
    parameter_anchor_weight: float = 0.
    save_epoch_parameters: bool = False
    diagnostic_best_fallback: bool = False
    loss_tail_epochs: int = 0
    loss_tail_max_epochs: int = 0
    loss_tail_lr_ratio: float = .1
    loss_tail_patience: int = 6
    preserve_label_mass_from: Path | None = None
    focal_gamma: float = 0.
    multilingual_view_spec: Path | None = None
    multilingual_mode: str = 'uniform'
    translation_consistency_weight: float = .1
    sam_rho: float = 0.
    epoch_retention: str = 'all'
    scene_contrastive_spec: Path | None = None
    scene_contrastive_weight: float = 0.
    scene_contrastive_temperature: float = .1


def parse_arguments() -> Arguments:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--scene-contrastive-spec',type=Path)
    parser.add_argument('--scene-contrastive-weight',type=float,default=0.)
    parser.add_argument('--scene-contrastive-temperature',type=float,default=.1)
    parser.add_argument("--input", type=Path, required=True, help="text/label NDJSON corpus")
    parser.add_argument('--preserve-label-mass-from', type=Path, default=None,
                        help='Reviewed reference corpus for label-prior-preserving subset ablation')
    parser.add_argument("--out", type=Path, default=None, help="output directory (default build/transformer-model)")
    parser.add_argument("--backbone", default=DEFAULT_BACKBONE, help="mmBERT/ModernBERT sequence-classification backbone")
    parser.add_argument("--model-name", default="SiftSignalModel")
    parser.add_argument("--version", default="signal-v1")
    parser.add_argument(
        "--languages",
        default="zh,en,es,pt,fr,de,ru,ja,ko,id,vi,th",
        help="comma-separated language tags recorded in the manifest",
    )
    parser.add_argument("--max-length", type=int, default=96, help="token sequence length")
    parser.add_argument("--validation-fraction", type=float, default=0.1)
    parser.add_argument("--validation-input", type=Path,
                        help="pre-separated grouped development set; requires --validation-fraction 0")
    parser.add_argument("--early-stopping-patience", type=int, default=0,
                        help="select/restore best development macro F1; 0 preserves final-epoch behavior")
    parser.add_argument("--early-stopping-delta", type=float, default=.002)
    parser.add_argument("--num-epochs", type=int, default=3)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--learning-rate", type=float, default=2e-5)
    parser.add_argument('--optimizer-policy', choices=['legacy','grouped'], default='grouped')
    parser.add_argument('--sam-rho', type=float, default=0.,
                        help='SAM perturbation radius; zero preserves ordinary AdamW')
    parser.add_argument('--epoch-retention', choices=['all','selected-and-last'], default='all',
                        help='Optional compact epoch archive policy; never changes epoch selection')
    parser.add_argument('--head-lr-multiplier', type=float, default=1.)
    parser.add_argument('--layer-lr-decay', type=float, default=1.)
    parser.add_argument('--lr-scheduler', choices=['linear','cosine'], default='linear')
    parser.add_argument('--gradient-accumulation-steps', type=int, default=1)
    parser.add_argument('--max-grad-norm', type=float, default=1.)
    parser.add_argument('--adam-beta1', type=float, default=.9)
    parser.add_argument('--adam-beta2', type=float, default=.999)
    parser.add_argument('--adam-epsilon', type=float, default=1e-8)
    parser.add_argument('--validation-max-benign-junk',type=int)
    parser.add_argument('--validation-min-spam-recall',type=float)
    parser.add_argument('--validation-selection-objective', choices=['macro-f1', 'junk-recall-then-macro-f1'], default='macro-f1')
    parser.add_argument('--validation-max-nonspam-junk',type=int,
                        help='cap all legitimate-to-junk errors, including legitimate promotions')
    parser.add_argument('--lora-rank',type=int,default=0,
                        help='attention-only low-rank adaptation in last N layers; 0 disables')
    parser.add_argument('--lora-alpha',type=float,default=8.)
    parser.add_argument('--lora-dropout',type=float,default=.05)
    parser.add_argument("--weight-decay", type=float, default=0.01)
    parser.add_argument("--warmup-ratio", type=float, default=0.06)
    parser.add_argument("--label-smoothing", type=float, default=0.0, help="CrossEntropy label smoothing")
    parser.add_argument('--focal-gamma',type=float,default=0.,
                        help='Training-only hard-label focal exponent;0 preserves CE, incompatible with smoothing')
    parser.add_argument('--multilingual-view-spec', type=Path)
    parser.add_argument('--multilingual-mode', choices=['uniform','balanced','translated','consistent'], default='uniform')
    parser.add_argument('--translation-consistency-weight', type=float, default=.1)
    parser.add_argument("--classifier-dropout", type=float, default=None, help="override config.classifier_dropout")
    parser.add_argument("--attention-dropout", type=float, default=None, help="override config.attention_dropout")
    parser.add_argument("--embedding-dropout", type=float, default=None, help="override config.embedding_dropout")
    parser.add_argument("--mlp-dropout", type=float, default=None, help="override config.mlp_dropout")
    parser.add_argument("--classifier-pooling", choices=["cls", "mean"], default=None, help="override config.classifier_pooling")
    parser.add_argument("--freeze-encoder", action="store_true", help="train only the classification head")
    parser.add_argument("--train-last-layers", type=int, default=0,
                        help="freeze embeddings and lower encoder layers; train only the last N layers and head")
    parser.add_argument(
        "--train-new-label-rows-only",
        action="store_true",
        help="on label expansion, train only newly added classifier rows and preserve every shared row",
    )
    parser.add_argument(
        "--train-label-rows",
        default="",
        help="comma-separated classifier labels to update while freezing the encoder and every other output row",
    )
    parser.add_argument(
        "--boundary-loss-weight",
        type=float,
        default=1.0,
        help="loss multiplier for reviewed augmentation:boundary:* rows without duplicating corpus rows",
    )
    parser.add_argument(
        "--selected-label-loss-weight",
        type=float,
        default=1.0,
        help="positive-row loss multiplier for labels named by --train-label-rows",
    )
    parser.add_argument("--truncate-layers", type=int, default=0, help="keep only the first N encoder layers before training")
    parser.add_argument("--quantize", choices=["fp16", "int8"], default="int8")
    parser.add_argument("--quantization-profile", default=None, help="v2 profile id recorded in the release manifest")
    parser.add_argument("--release-sequence", type=int, default=0)
    parser.add_argument("--model-abi", default=MODEL_ABI_V1)
    parser.add_argument("--minimum-app-build", type=int, default=1)
    parser.add_argument("--maximum-app-build", type=int, default=2_147_483_647)
    parser.add_argument("--device", choices=["auto", "cpu", "cuda", "mps"], default="auto")
    parser.add_argument("--resume-from", type=Path, default=None,
                        help="initialize weights from checkpoint; optimizer moments and LR schedule restart")
    parser.add_argument("--save-checkpoint", default="auto", help="'auto' = <out>/checkpoint, 'off' disables saving")
    parser.add_argument("--install-ios", action="store_true", help="copy artifacts into apps/ios/GeneratedModels")
    parser.add_argument("--max-rows", type=int, default=None, help="debug/smoke: cap rows before splitting")
    parser.add_argument("--test-input", type=Path, default=None, help="optional held-out NDJSON evaluated after validation")
    parser.add_argument("--write-predictions", type=Path, default=None, help="write validation/test prediction rows as NDJSON")
    parser.add_argument("--skip-export", action="store_true", help="skip Core ML/tokenizer/manifest export for tuning runs")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--replay-teacher", type=Path, default=None,
                        help="frozen local checkpoint for replay preservation; requires --skip-export")
    parser.add_argument("--replay-alpha", type=float, default=0.9)
    parser.add_argument("--replay-temperature", type=float, default=2.0)
    parser.add_argument("--replay-only-correct-teacher", action="store_true",
                        help="use hard labels when the replay teacher disagrees with reviewed gold")
    parser.add_argument("--replay-new-loss-weight", type=float, default=1.,
                        help="additional loss multiplier for reviewed correction rows only")
    parser.add_argument("--replay-new-source-prefix", action="append", default=[],
                        help="reviewed correction source prefix exempt from teacher loss (repeatable)")
    parser.add_argument('--action-loss-weight', type=float, default=0.,
                        help='training-only additive action/leaf head; folded to one linear classifier')
    parser.add_argument('--rdrop-alpha', type=float, default=0.,
                        help='bidirectional KL between two dropout passes; zero disables R-Drop')
    parser.add_argument('--spam-loss-weight',type=float,default=0.,
                        help='train-only spam-vs-rest auxiliary BCE; positive weight from training counts, capped at 3')
    parser.add_argument('--spam-positive-weight',type=float,default=None,
                        help='explicit auxiliary BCE positive cost;1 treats junk/nonjunk equally; default uses training counts')
    parser.add_argument('--max-updates',type=int,default=0,help='cap optimizer updates; zero uses the epoch budget')
    parser.add_argument('--convergence-patience',type=int,default=0,help='ungated NLL/macro-F1 plateau guard; zero disables')
    parser.add_argument('--convergence-min-updates',type=int,default=1500)
    parser.add_argument('--training-state',type=Path,default=None,help='atomic epoch-boundary optimizer/scheduler/RNG state')
    parser.add_argument('--resume-training-state',type=Path,default=None,help='exact continuation with identical data and update plan')
    parser.add_argument('--extend-training-state',type=Path,default=None,
                        help='explicit budget extension preserving terminal weights/Adam/RNG and original anchor under a new bounded loss-tail schedule')
    parser.add_argument('--gradient-probe-every',type=int,default=0,
                        help='full dropout-disabled training gradient every N epochs; 0 disables')
    parser.add_argument('--convergence-require-training-plateau',action='store_true',
                        help='development plateau stops only after six full-training objective plateau checks')
    parser.add_argument('--replay-agreement-all-rows',action='store_true',
                        help='also distill reviewed corrections when the teacher agrees with gold')
    parser.add_argument('--replay-hard-label-mode',choices=('mixed','uniform'),default='mixed',
                        help='uniform: CE coefficient1 for all reviewed labels, plus alpha KD only where teacher agrees')
    parser.add_argument('--parameter-anchor-weight',type=float,default=0.,
                        help='L2-SP coefficient: 0.5 * weight * sum squared deviation from stage initial trainable parameters')
    parser.add_argument('--save-epoch-parameters',action='store_true',
                        help='archive trainable parameters at every epoch; rehydrate with the pinned stage base')
    parser.add_argument('--diagnostic-best-fallback',action='store_true',
                        help='research only: restore best ungated development epoch if no eligible epoch exists')
    parser.add_argument('--loss-tail-epochs',type=int,default=0,
                        help='extend the nominal epoch budget in blocks until training loss plateaus; 0 disables')
    parser.add_argument('--loss-tail-max-epochs',type=int,default=0,
                        help='hard additional epoch budget; reaching it is not convergence')
    parser.add_argument('--loss-tail-lr-ratio',type=float,default=.1,
                        help='nonzero nominal-end LR relative to each group peak; preserves LLRD')
    parser.add_argument('--loss-tail-patience',type=int,default=6,
                        help='full-training objective window before and after a confirming LR reduction')
    raw = parser.parse_args()
    if raw.spam_positive_weight is not None and (
            not math.isfinite(raw.spam_positive_weight) or raw.spam_positive_weight <= 0):
        parser.error('spam positive weight must be finite and positive')
    if not math.isfinite(raw.sam_rho) or raw.sam_rho < 0:
        parser.error('SAM rho must be finite and nonnegative')
    if raw.sam_rho and (not raw.skip_export or raw.rdrop_alpha or raw.install_ios):
        parser.error('SAM is research-only and requires --skip-export and no R-Drop')
    if raw.epoch_retention != 'all' and (not raw.save_epoch_parameters or not raw.early_stopping_patience):
        parser.error('compact epoch retention requires saved parameters and development selection')
    if raw.loss_tail_epochs or raw.loss_tail_max_epochs:
        if not (raw.loss_tail_epochs>=1 and raw.loss_tail_max_epochs>=raw.loss_tail_epochs
                and 0<raw.loss_tail_lr_ratio<=1 and raw.loss_tail_patience>=3):
            parser.error('invalid loss-tail budget, LR ratio or patience')
        if (raw.lr_scheduler!='linear' or raw.gradient_probe_every!=1 or not raw.training_state
                or not raw.convergence_patience or not raw.early_stopping_patience or not raw.skip_export):
            parser.error('loss-tail requires linear schedule, every-epoch probes, saved state, development monitoring/selection and --skip-export')
    if raw.replay_agreement_all_rows and (not raw.replay_only_correct_teacher or not raw.replay_teacher):
        parser.error('all-row agreement requires a frozen teacher and correct-teacher gate')
    if raw.replay_hard_label_mode=='uniform' and (not raw.replay_only_correct_teacher or not raw.replay_teacher):
        parser.error('uniform hard labels require a frozen teacher and correct-teacher gate')
    if not math.isfinite(raw.parameter_anchor_weight) or raw.parameter_anchor_weight<0:
        parser.error('invalid parameter anchor coefficient')
    if raw.diagnostic_best_fallback and (not raw.skip_export or not raw.early_stopping_patience):
        parser.error('diagnostic best fallback requires epoch selection and --skip-export')
    if raw.lora_rank<0 or not math.isfinite(raw.lora_alpha) or raw.lora_alpha<=0 or not 0<=raw.lora_dropout<1:
        parser.error('invalid LoRA rank, alpha or dropout')
    if raw.lora_rank and (not raw.train_last_layers or raw.freeze_encoder or raw.train_label_rows or raw.train_new_label_rows_only):
        parser.error('LoRA requires --train-last-layers and cannot combine with other freezing/row-only modes')
    if raw.validation_selection_objective != 'macro-f1' and (
            raw.validation_max_nonspam_junk is None or raw.early_stopping_delta != 0):
        parser.error('junk selection requires --validation-max-nonspam-junk and --early-stopping-delta 0')
    if raw.validation_max_nonspam_junk is not None and (raw.validation_max_nonspam_junk<0 or not raw.validation_input or not raw.early_stopping_patience):
        parser.error('all-nonspam action gate requires a nonnegative cap, validation input and epoch selection')
    if min(raw.max_updates,raw.convergence_patience,raw.convergence_min_updates)<0:
        parser.error('update and convergence budgets must be nonnegative')
    if raw.gradient_probe_every<0:
        parser.error('gradient probe interval must be nonnegative')
    if raw.convergence_require_training_plateau and (not raw.gradient_probe_every or not raw.convergence_patience):
        parser.error('joint convergence requires full-gradient probes and development convergence monitoring')
    if raw.convergence_patience and (not raw.validation_input or not raw.early_stopping_patience):
        parser.error('convergence monitoring requires explicit validation and epoch selection')
    if raw.resume_training_state and (not raw.training_state or not raw.resume_from):
        parser.error('state resume requires --resume-from and --training-state output')
    if raw.extend_training_state and (not raw.resume_from or not raw.training_state or
            not raw.loss_tail_epochs or not raw.skip_export or raw.install_ios):
        parser.error('state extension requires original --resume-from, saved state, bounded loss-tail and research-only --skip-export')
    if not math.isfinite(raw.focal_gamma) or raw.focal_gamma<0 or (raw.focal_gamma and raw.label_smoothing):
        parser.error('focal gamma must be finite/nonnegative and requires unsmoothed hard labels')
    if raw.multilingual_view_spec:
        if (not raw.replay_teacher or not raw.replay_only_correct_teacher or not raw.replay_agreement_all_rows
                or not raw.skip_export or raw.install_ios or raw.validation_fraction != 0
                or raw.rdrop_alpha or raw.action_loss_weight or raw.spam_loss_weight or raw.focal_gamma
                or raw.preserve_label_mass_from or raw.train_label_rows or raw.train_new_label_rows_only
                or raw.boundary_loss_weight != 1 or raw.selected_label_loss_weight != 1
                or raw.replay_new_loss_weight != 1):
            parser.error('paired views require research-only explicit validation, correct-teacher KD, unit row weights and no other loss/row adapters')
        if not math.isfinite(raw.translation_consistency_weight) or raw.translation_consistency_weight < 0:
            parser.error('translation consistency weight must be finite and nonnegative')
    if any(not math.isfinite(v) or v < 0 for v in (raw.action_loss_weight, raw.rdrop_alpha,raw.spam_loss_weight)):
        parser.error('regularization weights must be finite and non-negative')
    if raw.action_loss_weight and (raw.train_label_rows or raw.train_new_label_rows_only):
        parser.error('action hierarchy cannot combine with classifier-row-only tuning')
    if ((raw.validation_max_benign_junk is not None and raw.validation_max_benign_junk<0)
            or (raw.validation_min_spam_recall is not None and not 0<=raw.validation_min_spam_recall<=1)):
        parser.error('invalid development action gate')
    if ((raw.validation_max_benign_junk is not None or raw.validation_min_spam_recall is not None)
            and (not raw.validation_input or not raw.early_stopping_patience)):
        parser.error('development action gates require explicit validation and early stopping')
    if (not math.isfinite(raw.learning_rate) or raw.learning_rate <= 0
            or not math.isfinite(raw.weight_decay) or raw.weight_decay < 0
            or not 0 <= raw.warmup_ratio < 1 or not 0 <= raw.label_smoothing < 1
            or raw.gradient_accumulation_steps < 1 or not math.isfinite(raw.max_grad_norm)
            or raw.max_grad_norm <= 0 or not 0 <= raw.adam_beta1 < 1 or not 0 <= raw.adam_beta2 < 1
            or not math.isfinite(raw.adam_epsilon) or raw.adam_epsilon <= 0
            or not math.isfinite(raw.head_lr_multiplier) or raw.head_lr_multiplier <= 0
            or not 0 < raw.layer_lr_decay <= 1):
        parser.error('invalid optimizer, schedule or accumulation configuration')
    if raw.optimizer_policy == 'legacy' and (raw.head_lr_multiplier != 1 or raw.layer_lr_decay != 1):
        parser.error('differential learning rates require grouped optimizer policy')
    if raw.train_last_layers < 0 or (raw.train_last_layers and raw.freeze_encoder):
        parser.error("--train-last-layers must be non-negative and cannot combine with --freeze-encoder")
    if raw.train_last_layers and (raw.train_label_rows or raw.train_new_label_rows_only):
        parser.error("--train-last-layers cannot combine with classifier-row-only tuning")
    if not 0 <= raw.replay_alpha <= 1 or raw.replay_temperature < 1:
        parser.error("replay alpha must be in [0, 1] and temperature at least 1")
    if raw.validation_input and raw.validation_fraction != 0:
        parser.error("--validation-input requires --validation-fraction 0")
    if raw.early_stopping_patience < 0 or raw.early_stopping_delta < 0:
        parser.error("invalid early-stopping policy")
    if raw.early_stopping_patience and not raw.validation_input:
        parser.error("early stopping requires an explicitly separated --validation-input")
    if raw.replay_new_loss_weight < 1:
        parser.error("replay new-row loss weight must be at least 1")
    if raw.replay_teacher and (not raw.skip_export or raw.install_ios):
        parser.error("replay tuning requires --skip-export and cannot --install-ios")
    if raw.replay_teacher and not raw.replay_new_source_prefix:
        parser.error("replay tuning requires --replay-new-source-prefix")
    if any(not prefix.strip() for prefix in raw.replay_new_source_prefix):
        parser.error("replay correction source prefixes must not be empty")
    if raw.boundary_loss_weight < 1:
        parser.error("--boundary-loss-weight must be at least 1")
    if raw.selected_label_loss_weight < 1:
        parser.error("--selected-label-loss-weight must be at least 1")
    if raw.selected_label_loss_weight != 1 and not raw.train_label_rows.strip():
        parser.error("--selected-label-loss-weight requires --train-label-rows")

    repo_root = locate_repo_root()
    return Arguments(
        input=raw.input.expanduser().resolve(),
        out=(raw.out.expanduser().resolve() if raw.out else repo_root / "build/transformer-model"),
        backbone=raw.backbone,
        model_name=raw.model_name,
        version=raw.version,
        languages=[item.strip() for item in raw.languages.split(",") if item.strip()],
        max_length=raw.max_length,
        validation_fraction=raw.validation_fraction,
        num_epochs=raw.num_epochs,
        batch_size=raw.batch_size,
        learning_rate=raw.learning_rate,
        weight_decay=raw.weight_decay,
        warmup_ratio=raw.warmup_ratio,
        label_smoothing=raw.label_smoothing,
        focal_gamma=raw.focal_gamma,
        multilingual_view_spec=raw.multilingual_view_spec,
        multilingual_mode=raw.multilingual_mode,
        translation_consistency_weight=raw.translation_consistency_weight,
        classifier_dropout=raw.classifier_dropout,
        attention_dropout=raw.attention_dropout,
        embedding_dropout=raw.embedding_dropout,
        mlp_dropout=raw.mlp_dropout,
        classifier_pooling=raw.classifier_pooling,
        freeze_encoder=raw.freeze_encoder,
        train_new_label_rows_only=raw.train_new_label_rows_only,
        train_label_rows=[item.strip() for item in raw.train_label_rows.split(",") if item.strip()],
        boundary_loss_weight=raw.boundary_loss_weight,
        selected_label_loss_weight=raw.selected_label_loss_weight,
        truncate_layers=raw.truncate_layers,
        quantize=raw.quantize,
        quantization_profile=raw.quantization_profile or ("fp32-baseline" if raw.quantize == "fp16" else "w8a32-channel-ptq"),
        release_sequence=raw.release_sequence,
        model_abi=raw.model_abi,
        minimum_app_build=raw.minimum_app_build,
        maximum_app_build=raw.maximum_app_build,
        device=raw.device,
        resume_from=(raw.resume_from.expanduser().resolve() if raw.resume_from else None),
        save_checkpoint=raw.save_checkpoint,
        install_ios=raw.install_ios,
        max_rows=raw.max_rows,
        test_input=(raw.test_input.expanduser().resolve() if raw.test_input else None),
        write_predictions=(raw.write_predictions.expanduser().resolve() if raw.write_predictions else None),
        skip_export=raw.skip_export,
        seed=raw.seed,
        replay_teacher=raw.replay_teacher.expanduser().resolve() if raw.replay_teacher else None,
        replay_alpha=raw.replay_alpha,
        replay_temperature=raw.replay_temperature,
        replay_only_correct_teacher=raw.replay_only_correct_teacher,
        validation_input=raw.validation_input.expanduser().resolve() if raw.validation_input else None,
        early_stopping_patience=raw.early_stopping_patience,
        early_stopping_delta=raw.early_stopping_delta,
        replay_new_source_prefix=raw.replay_new_source_prefix,
        train_last_layers=raw.train_last_layers,
        replay_new_loss_weight=raw.replay_new_loss_weight,
        optimizer_policy=raw.optimizer_policy, head_lr_multiplier=raw.head_lr_multiplier,
        sam_rho=raw.sam_rho, epoch_retention=raw.epoch_retention,
        scene_contrastive_spec=raw.scene_contrastive_spec,
        scene_contrastive_weight=raw.scene_contrastive_weight,
        scene_contrastive_temperature=raw.scene_contrastive_temperature,
        layer_lr_decay=raw.layer_lr_decay, lr_scheduler=raw.lr_scheduler,
        gradient_accumulation_steps=raw.gradient_accumulation_steps,
        max_grad_norm=raw.max_grad_norm, adam_beta1=raw.adam_beta1,
        adam_beta2=raw.adam_beta2, adam_epsilon=raw.adam_epsilon,
        validation_max_benign_junk=raw.validation_max_benign_junk,
        validation_selection_objective=raw.validation_selection_objective,
        validation_min_spam_recall=raw.validation_min_spam_recall,
        spam_positive_weight=raw.spam_positive_weight,
        action_loss_weight=raw.action_loss_weight, rdrop_alpha=raw.rdrop_alpha,
        spam_loss_weight=raw.spam_loss_weight,
        max_updates=raw.max_updates,convergence_patience=raw.convergence_patience,
        convergence_min_updates=raw.convergence_min_updates,
        training_state=raw.training_state,resume_training_state=raw.resume_training_state,
        extend_training_state=raw.extend_training_state,
        gradient_probe_every=raw.gradient_probe_every,
        convergence_require_training_plateau=raw.convergence_require_training_plateau,
        lora_rank=raw.lora_rank,lora_alpha=raw.lora_alpha,lora_dropout=raw.lora_dropout,
        validation_max_nonspam_junk=raw.validation_max_nonspam_junk,
        replay_agreement_all_rows=raw.replay_agreement_all_rows,
        replay_hard_label_mode=raw.replay_hard_label_mode,
        parameter_anchor_weight=raw.parameter_anchor_weight,
        save_epoch_parameters=raw.save_epoch_parameters,
        diagnostic_best_fallback=raw.diagnostic_best_fallback,
        loss_tail_epochs=raw.loss_tail_epochs,loss_tail_max_epochs=raw.loss_tail_max_epochs,
        loss_tail_lr_ratio=raw.loss_tail_lr_ratio,loss_tail_patience=raw.loss_tail_patience,
        preserve_label_mass_from=raw.preserve_label_mass_from,
    )


def locate_repo_root() -> Path:
    directory = Path(__file__).resolve().parent
    while directory != directory.parent:
        if (directory / "packages/taxonomy/taxonomy.json").exists():
            return directory
        directory = directory.parent
    raise SystemExit("error: could not locate repo root containing packages/taxonomy/taxonomy.json")


def load_rows(path: Path, max_rows: int | None = None) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            text, label = record.get("text", "").strip(), record.get("label", "").strip()
            if text and label:
                rows.append({
                    "text": text,
                    "label": label,
                    "source": str(record.get("source", "")).strip(),
                    "language":str(record.get('language','')).strip(),
                })
                if max_rows is not None and len(rows) >= max_rows:
                    break
    if not rows:
        raise SystemExit(f"error: dataset is empty: {path}")
    return rows


def load_taxonomy_labels(repo_root: Path) -> set[str]:
    document = json.loads((repo_root / "packages/taxonomy/taxonomy.json").read_text(encoding="utf-8"))
    return {leaf["id"] for group in document["groups"] for leaf in group["leaves"]}


def label_row_transfers(
    previous_id_to_label: dict[int, str],
    current_label_to_id: dict[str, int],
) -> list[tuple[str, int, int]]:
    previous_labels = list(previous_id_to_label.values())
    if len(previous_labels) != len(set(previous_labels)):
        raise ValueError("checkpoint id2label contains duplicate labels")
    if sorted(previous_id_to_label) != list(range(len(previous_id_to_label))):
        raise ValueError("checkpoint id2label ids must be dense and zero-based")
    removed = sorted(set(previous_labels) - set(current_label_to_id))
    if removed:
        raise ValueError(f"checkpoint labels are absent from the current contract: {', '.join(removed)}")
    return [
        (label, previous_id, current_label_to_id[label])
        for previous_id, label in sorted(previous_id_to_label.items())
    ]


def added_label_ids(
    previous_id_to_label: dict[int, str],
    current_label_to_id: dict[str, int],
) -> list[int]:
    label_row_transfers(previous_id_to_label, current_label_to_id)
    previous_labels = set(previous_id_to_label.values())
    return sorted(
        current_id for label, current_id in current_label_to_id.items()
        if label not in previous_labels
    )


def migrate_resumed_classifier_rows(
    model,
    checkpoint: Path,
    previous_id_to_label: dict[int, str],
    current_label_to_id: dict[str, int],
) -> list[str]:
    import torch
    from safetensors import safe_open

    transfers = label_row_transfers(previous_id_to_label, current_label_to_id)
    tensor_files = sorted(checkpoint.glob("*.safetensors"))
    if not tensor_files:
        raise SystemExit(f"error: resume checkpoint has no safetensors weights: {checkpoint}")

    migrated_parameters: list[str] = []
    previous_count = len(previous_id_to_label)
    current_count = len(current_label_to_id)
    for name, parameter in model.named_parameters():
        if parameter.ndim == 0 or parameter.shape[0] != current_count:
            continue
        checkpoint_tensor = None
        for tensor_file in tensor_files:
            with safe_open(tensor_file, framework="pt", device="cpu") as handle:
                if name in handle.keys():
                    checkpoint_tensor = handle.get_tensor(name)
                    break
        if checkpoint_tensor is None:
            continue
        if (
            checkpoint_tensor.ndim != parameter.ndim
            or checkpoint_tensor.shape[0] != previous_count
            or checkpoint_tensor.shape[1:] != parameter.shape[1:]
        ):
            continue
        with torch.no_grad():
            for _, previous_id, current_id in transfers:
                parameter[current_id].copy_(checkpoint_tensor[previous_id].to(parameter.device, parameter.dtype))
        migrated_parameters.append(name)

    if not migrated_parameters:
        raise SystemExit("error: could not migrate any label-dependent classifier parameters from checkpoint")
    added = sorted(set(current_label_to_id) - set(previous_id_to_label.values()))
    print(
        f"migrated {len(transfers)} shared label rows across {', '.join(migrated_parameters)}; "
        f"new labels: {', '.join(added) if added else 'none'}"
    )
    return migrated_parameters


def stratified_split(
    rows: list[dict[str, str]], fraction: float, seed: int
) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    rng = random.Random(seed)
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        grouped[row["label"]].append(row)

    training: list[dict[str, str]] = []
    validation: list[dict[str, str]] = []
    for label in sorted(grouped):
        bucket = grouped[label][:]
        rng.shuffle(bucket)
        holdout = int(len(bucket) * fraction) if len(bucket) >= 5 else 0
        validation.extend(bucket[:holdout])
        training.extend(bucket[holdout:])
    rng.shuffle(training)
    rng.shuffle(validation)
    return training, validation


def select_device(requested: str) -> str:
    import torch

    cuda_available = torch.cuda.is_available()
    mps_available = bool(getattr(torch.backends, "mps", None)) and torch.backends.mps.is_available()
    if requested == "cuda" and not cuda_available:
        raise SystemExit("error: --device cuda requested but torch.cuda.is_available() is False")
    if requested == "mps" and not mps_available:
        raise SystemExit("error: --device mps requested but MPS is unavailable")
    if requested != "auto":
        return requested
    if cuda_available:
        return "cuda"
    if mps_available:
        return "mps"
    return "cpu"


def describe_device(device: str) -> str:
    import torch

    if device == "cuda":
        return f"cuda ({torch.cuda.get_device_name(0) if torch.cuda.device_count() else 'unknown GPU'})"
    if device == "mps":
        return "mps (Apple Silicon GPU via Metal)"
    return "cpu"


class TextDataset:
    def __init__(self, rows: list[dict[str, str]], label_to_id: dict[str, int]):
        self.rows = rows
        self.label_to_id = label_to_id

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, str | int]:
        row = self.rows[index]
        return {
            "text": row["text"],
            "label": self.label_to_id[row["label"]],
            "source": row.get("source", ""),
        }


def row_loss_weight(
    label_id: int,
    source: str,
    boundary_loss_weight: float,
    selected_label_ids: set[int] | frozenset[int],
    selected_label_loss_weight: float,
) -> float:
    weight = selected_label_loss_weight if label_id in selected_label_ids else 1.0
    if source.startswith("augmentation:boundary:"):
        weight *= boundary_loss_weight
    return weight


def make_collate(
    tokenizer,
    max_length: int,
    boundary_loss_weight: float = 1.0,
    selected_label_ids: set[int] | frozenset[int] = frozenset(),
    selected_label_loss_weight: float = 1.0,
    label_loss_weights: dict[int, float] | None = None,
):
    import torch

    def collate(batch: list[dict[str, str | int]]) -> dict[str, "torch.Tensor"]:
        encoded = tokenizer(
            [str(item["text"]) for item in batch],
            truncation=True,
            padding="max_length",
            max_length=max_length,
            return_tensors="pt",
        )
        label_ids = [int(item["label"]) for item in batch]
        encoded["labels"] = torch.tensor(label_ids, dtype=torch.long)
        encoded["loss_weights"] = torch.tensor([
            row_loss_weight(
                label_id,
                str(item.get("source", "")),
                boundary_loss_weight,
                selected_label_ids,
                selected_label_loss_weight,
            ) * (label_loss_weights or {}).get(label_id, 1.0)
            for item, label_id in zip(batch, label_ids)
        ], dtype=torch.float32)
        return encoded

    return collate


def train_model(
    model,
    tokenizer,
    rows: list[dict[str, str]],
    label_to_id: dict[str, int],
    arguments: Arguments,
    device: str,
    locked_classifier_rows: list[tuple[object, object, object]] | None = None,
    replay_teacher=None,
    validation_rows: list[dict[str, str]] | None = None,
    selection_history: list[dict] | None = None,
    optimization_summary: dict | None = None,
    validation_actions: dict | None = None,
):
    import torch
    from torch.utils.data import DataLoader
    from transformers import get_scheduler
    from training_optimization import parameter_groups, update_plan

    if arguments.num_epochs <= 0:
        return []

    generator = torch.Generator()
    generator.manual_seed(arguments.seed)
    dataset = TextDataset(rows, label_to_id)
    mass_weights = {}; mass_report = None
    if reference := getattr(arguments, 'preserve_label_mass_from', None):
        from label_mass import preserving_weights
        weights, mass_report = preserving_weights(rows, reference)
        mass_weights = {label_to_id[label]: value for label, value in weights.items()}
    collate = make_collate(tokenizer, arguments.max_length,
                           arguments.boundary_loss_weight,
                           {label_to_id[label] for label in arguments.train_label_rows},
                           arguments.selected_label_loss_weight, mass_weights)
    if replay_teacher is not None:
        from replay_distillation import is_reviewed_correction

        base_collate = collate

        def collate(batch):
            encoded = base_collate(batch)
            encoded["correction_mask"] = torch.tensor([
                is_reviewed_correction(str(item.get("source", "")),
                                      arguments.replay_new_source_prefix or [])
                for item in batch
            ], dtype=torch.bool)
            return encoded

        replay_teacher.to(device).eval().requires_grad_(False)
    sampler = None; probe_dataset = dataset; multilingual_report = None
    if getattr(arguments, 'multilingual_view_spec', None):
        from multilingual_views import make_plan
        dataset, collate, sampler, probe_dataset, multilingual_report = make_plan(
            dataset, rows, collate, tokenizer, arguments, generator)
    scene_report=None
    if getattr(arguments,'scene_contrastive_spec',None):
        from scene_contrastive import make_plan
        if sampler is not None or getattr(arguments,'rdrop_alpha',0.) or getattr(arguments,'action_loss_weight',0.):
            raise ValueError('scene contrastive study cannot combine other view samplers or action/dropout auxiliaries')
        if (not math.isfinite(arguments.scene_contrastive_weight) or arguments.scene_contrastive_weight<0
                or not math.isfinite(arguments.scene_contrastive_temperature) or arguments.scene_contrastive_temperature<=0):
            raise ValueError('invalid scene contrastive configuration')
        collate,batch_sampler,scene_report=make_plan(rows,collate,arguments,generator)
        loader=DataLoader(dataset,batch_sampler=batch_sampler,collate_fn=collate,generator=generator)
    else:
        if getattr(arguments,'scene_contrastive_weight',0.):raise ValueError('scene loss requires a reviewed group specification')
        loader = DataLoader(
            dataset,
            batch_size=arguments.batch_size,
            shuffle=sampler is None,
            sampler=sampler,
            collate_fn=collate,
            generator=generator,
        )
    model.to(device)
    from training_backend import enable_frozen_boundary_input_gradient
    backend_guard = enable_frozen_boundary_input_gradient(model, device)
    model.train()
    trainable_parameters = [parameter for parameter in model.parameters() if parameter.requires_grad]
    if not trainable_parameters:
        raise SystemExit("error: no trainable parameters remain")
    groups, group_report = parameter_groups(model, arguments.learning_rate, arguments.weight_decay,
        policy=getattr(arguments,'optimizer_policy','grouped'),
        head_multiplier=getattr(arguments,'head_lr_multiplier',1.),
        layer_decay=getattr(arguments,'layer_lr_decay',1.))
    betas=(getattr(arguments,'adam_beta1',.9),getattr(arguments,'adam_beta2',.999))
    epsilon=getattr(arguments,'adam_epsilon',1e-8)
    optimizer = torch.optim.AdamW(groups, lr=arguments.learning_rate, betas=betas, eps=epsilon)
    from sharpness_aware import validate_sam_model, sam_perturbation
    sam_rho = getattr(arguments, 'sam_rho', 0.)
    validate_sam_model(model, sam_rho, getattr(arguments, 'rdrop_alpha', 0.))
    from hard_label_loss import supervised_loss
    def loss_fn(logits,labels):
        return supervised_loss(logits,labels,label_smoothing=arguments.label_smoothing,
                               focal_gamma=getattr(arguments,'focal_gamma',0.))
    accumulation=getattr(arguments,'gradient_accumulation_steps',1)
    plan=update_plan(len(loader),arguments.num_epochs,accumulation,arguments.warmup_ratio)
    total_steps, warmup_steps = plan['plannedUpdates'], plan['warmupUpdates']
    requested_updates=getattr(arguments,'max_updates',0)
    if requested_updates:
        if requested_updates>total_steps:raise ValueError('max updates exceed the epoch budget')
        total_steps=requested_updates;warmup_steps=math.ceil(total_steps*arguments.warmup_ratio)
        plan.update(plannedUpdates=total_steps,warmupUpdates=warmup_steps)
    schedule_name=getattr(arguments,'lr_scheduler','linear')
    tail=None;epoch_limit=arguments.num_epochs
    if getattr(arguments,'loss_tail_epochs',0):
        from loss_tail import LossTailScheduler
        if total_steps!=plan['updatesPerEpoch']*arguments.num_epochs:
            raise ValueError('adaptive loss-tail requires a complete nominal epoch budget')
        tail=LossTailScheduler(optimizer,nominal_epochs=arguments.num_epochs,
            updates_per_epoch=plan['updatesPerEpoch'],warmup_updates=warmup_steps,
            extension_epochs=arguments.loss_tail_epochs,max_extension_epochs=arguments.loss_tail_max_epochs,
            tail_ratio=arguments.loss_tail_lr_ratio,patience=arguments.loss_tail_patience)
        scheduler=tail;epoch_limit=tail.maximum_epochs
        plan.update(nominalUpdates=total_steps,nominalEpochs=arguments.num_epochs,
                    hardMaximumEpochs=epoch_limit,hardMaximumUpdates=epoch_limit*plan['updatesPerEpoch'])
        plan['plannedUpdates']=plan['hardMaximumUpdates']
        total_steps=plan['hardMaximumUpdates'];schedule_name='linear_nonzero_tail_with_plateau_confirmation'
    else:
        scheduler = get_scheduler(schedule_name, optimizer=optimizer,
            num_warmup_steps=warmup_steps,num_training_steps=total_steps)
    max_norm=getattr(arguments,'max_grad_norm',1.)
    action_weight=getattr(arguments,'action_loss_weight',0.)
    rdrop_alpha=getattr(arguments,'rdrop_alpha',0.)
    spam_weight=getattr(arguments,'spam_loss_weight',0.)
    spam_id=label_to_id.get('spam')
    spam_positive_weight=None
    if spam_weight:
        from spam_objective import positive_weight,spam_binary_loss
        if spam_id is None:raise ValueError('spam objective requires spam label')
        spam_positive_weight=positive_weight([label_to_id[r['label']] for r in rows],spam_id,
            getattr(arguments,'spam_positive_weight',None))
    if action_weight or rdrop_alpha:
        from semantic_regularization import action_cross_entropy, symmetric_kl
    norms=[]
    peak_rates=[]
    first_rates=[]
    if optimization_summary is not None:
        optimization_summary['sceneContrastive']=scene_report
        optimization_summary['frozenBoundaryInputGradient'] = backend_guard
        optimization_summary['labelMassPreservation'] = mass_report
        optimization_summary['multilingualViews'] = multilingual_report
        optimization_summary['sam'] = {'rho':sam_rho, 'enabled':bool(sam_rho),
            'passesPerUpdate':2 if sam_rho else 1,
            'scope':'same effective batch, weighted CE/KD plus parameter anchor; unclipped ascent; one AdamW step',
            'dropoutEnabled':False if sam_rho else None}
        optimization_summary['epochRetention'] = getattr(arguments, 'epoch_retention', 'all')
        optimization_summary.update(policy=getattr(arguments,'optimizer_policy','grouped'),
            groups=group_report, betas=betas, epsilon=epsilon, schedule=schedule_name,
            gradientAccumulationSteps=accumulation, maxGradNorm=max_norm, **plan)
    losses: list[dict] = []
    stopping, best_parameters = None, None
    from parameter_anchor import ParameterAnchor
    anchor=ParameterAnchor(model,getattr(arguments,'parameter_anchor_weight',0.))
    observed_stopping, observed_parameters = None, None
    if arguments.early_stopping_patience:
        from generalization_validation import EarlyStopping
        if not validation_rows:
            raise ValueError("early stopping requires grouped development rows")
        stopping = EarlyStopping(arguments.early_stopping_patience, arguments.early_stopping_delta)
        if getattr(arguments,'diagnostic_best_fallback',False):
            observed_stopping=EarlyStopping(arguments.early_stopping_patience,arguments.early_stopping_delta)
    from training_progress import ConvergenceMonitor,frozen_sha256,save_state,load_state
    from dataclasses import asdict
    convergence=(ConvergenceMonitor(patience=arguments.convergence_patience,
        minimum_updates=getattr(arguments,'convergence_min_updates',1500))
        if getattr(arguments,'convergence_patience',0) else None)
    state_path=getattr(arguments,'training_state',None)
    resume_path=getattr(arguments,'resume_training_state',None)
    extension_path=getattr(arguments,'extend_training_state',None)
    extension_report=None
    epoch_metrics=[];start_epoch=0;step=0;stop_reason=None
    probe_every=getattr(arguments,'gradient_probe_every',0)
    probe_history=[];training_plateau=None;probe_status=None
    if probe_every:
        from gradient_diagnostics import deterministic_terms,full_gradient_probe,TrainingPlateauMonitor
        probe_loader=DataLoader(probe_dataset,batch_size=arguments.batch_size,shuffle=False,
            collate_fn=collate,generator=torch.Generator().manual_seed(0))
        if scene_report is not None:
            from scene_contrastive import SceneBatchSampler
            probe_sampler=SceneBatchSampler(len(rows),arguments.batch_size,batch_sampler.groups,
                torch.Generator().manual_seed(0),shuffle=False)
            probe_loader=DataLoader(probe_dataset,batch_sampler=probe_sampler,collate_fn=collate)
        training_plateau=TrainingPlateauMonitor()
        def probe(epoch,step):
            result=full_gradient_probe(model,probe_loader,
                lambda batch:deterministic_terms(model,batch,arguments,replay_teacher,spam_positive_weight),device,
                regularizer=anchor.penalty if anchor.parameters else None)
            result.update(epoch=epoch,step=step)
            status=training_plateau.update(result)
            result['plateauStatus']=status
            probe_history.append(result)
            print(f"full-gradient epoch {epoch}: objective {result['objective']:.6f}, norm {result['unclippedFullGradientNorm']:.6f}, RMS {result['gradientRMS']:.8f}")
            return status
    contract=None
    if state_path or resume_path:
        fields=('learning_rate','weight_decay','warmup_ratio','num_epochs','batch_size','seed',
            'max_length','label_smoothing','focal_gamma','optimizer_policy','head_lr_multiplier','layer_lr_decay',
            'gradient_accumulation_steps','max_grad_norm','adam_beta1','adam_beta2','adam_epsilon',
            'lr_scheduler','action_loss_weight','rdrop_alpha','spam_loss_weight','spam_positive_weight','replay_alpha','replay_temperature',
            'replay_only_correct_teacher','replay_new_loss_weight','replay_new_source_prefix',
            'boundary_loss_weight','selected_label_loss_weight','train_label_rows',
            'early_stopping_patience','early_stopping_delta','validation_max_benign_junk',
            'validation_selection_objective','validation_min_spam_recall','convergence_patience','convergence_min_updates',
            'gradient_probe_every','convergence_require_training_plateau',
            'lora_rank','lora_alpha','lora_dropout','validation_max_nonspam_junk',
            'replay_agreement_all_rows','replay_hard_label_mode','parameter_anchor_weight','diagnostic_best_fallback','save_epoch_parameters',
            'loss_tail_epochs','loss_tail_max_epochs','loss_tail_lr_ratio','loss_tail_patience',
            'multilingual_mode','translation_consistency_weight','sam_rho','epoch_retention',
            'scene_contrastive_weight','scene_contrastive_temperature')
        contract={'arguments':{k:getattr(arguments,k,None) for k in fields},'labels':label_to_id,
            'labelMassPreservation': mass_report,
            'multilingualViews': multilingual_report,
            'plan':plan,'trainingSHA256':file_sha256(arguments.input),
            'developmentSHA256':file_sha256(arguments.validation_input) if arguments.validation_input else None,
            'frozenWeightsSHA256':frozen_sha256(model),
            'parameterAnchorSHA256':anchor.sha256(),
            'teacherSHA256':directory_sha256(arguments.replay_teacher) if replay_teacher is not None else None,
            'trainableShapes':{n:list(p.shape) for n,p in model.named_parameters() if p.requires_grad},
            'device':device}
        if scene_report is not None:contract['sceneContrastive']=scene_report
        if extension_path:
            contract['extensionParent']={'sha256':file_sha256(extension_path)}
    if resume_path:
        restored=load_state(resume_path,model,optimizer,scheduler,generator,contract,device)
        extension_report=restored.get('scheduleExtension')
        if restored.get('stopReason'):
            raise ValueError('training state already stopped; an intentional new schedule requires a new weights-only stage')
        start_epoch,step=restored['nextEpoch'],restored['step']
        losses=restored['losses'];norms=restored['norms'];epoch_metrics=restored['epochMetrics']
        first_rates=restored['firstRates'];peak_rates=restored['peakRates'];best_parameters=restored['bestParameters']
        if stopping is not None:stopping.__dict__.update(restored['stopping'])
        if observed_stopping is not None:
            observed_stopping.__dict__.update(restored['observedStopping'])
            observed_parameters=restored['observedParameters']
        if convergence is not None:convergence=ConvergenceMonitor(**restored['convergence'])
        if selection_history is not None:selection_history.extend(restored['history'])
        if training_plateau is not None:
            probe_history=restored['gradientProbeHistory']
            training_plateau.history=restored['trainingPlateauHistory']
            probe_status=probe_history[-1]['plateauStatus']
        print(f'exact state resume: next epoch {start_epoch+1}, completed updates {step}')
    else:
        if extension_path:
            from training_extension import load_extension
            extension_report=load_extension(extension_path,model,optimizer,scheduler,generator,contract,device)
            print(f"schedule extension: preserving {extension_report['parentCompletedUpdates']} Adam updates and original anchor; new LRs {extension_report['newInitialLearningRates']}")
        if probe_every:
            probe_status=probe(0,0)
            if extension_report:
                delta=abs(probe_history[-1]['objective']-extension_report['parentTerminalObjective'])
                extension_report['initialObjectiveDifference']=delta
                if delta>1e-5:
                    raise ValueError('extension objective differs from the parent terminal objective')
    used_rates=[group['lr'] for group in optimizer.param_groups]
    for epoch in range(start_epoch,epoch_limit):
        if step>=total_steps:break
        if multilingual_report is not None: dataset.epoch = epoch
        epoch_loss=torch.zeros((),device=device);epoch_weight=torch.zeros((),device=device)
        first_norm=len(norms)
        parameters_before=[p.detach().clone() for p in trainable_parameters] if probe_every else None
        model.train()
        for batch_index, batch in enumerate(loader):
            batch = {key: value.to(device) for key, value in batch.items()}
            if batch_index % accumulation == 0:
                optimizer.zero_grad(set_to_none=True)
                accumulated_weight = torch.zeros((),device=device)
                accumulated_loss = torch.zeros((),device=device)
                sam_batches = []
            if sam_rho:
                sam_batches.append(dict(batch))
            labels = batch.pop("labels")
            loss_weights = batch.pop("loss_weights")
            correction_mask = batch.pop("correction_mask", None)
            from multilingual_views import pop_view_batch
            view_batch, pair_mask = pop_view_batch(batch)
            scene_group=batch.pop('scene_group',None)
            from scene_contrastive import forward_features,scene_loss
            output,scene_features=forward_features(model,batch,scene_group is not None)
            spam_loss=spam_binary_loss(output.logits,labels,spam_id,spam_positive_weight) if spam_weight else None
            action_loss = action_cross_entropy(model.classifier,labels) if action_weight else None
            if replay_teacher is None:
                losses_per_row = loss_fn(output.logits, labels)
            else:
                from replay_distillation import correction_loss_weights, replay_distillation_loss

                with torch.no_grad():
                    teacher_logits = replay_teacher(**batch).logits
                loss_weights = correction_loss_weights(
                    loss_weights, correction_mask, arguments.replay_new_loss_weight
                )
                losses_per_row = replay_distillation_loss(
                    output.logits, teacher_logits, labels, correction_mask,
                    arguments.replay_alpha, arguments.replay_temperature,
                    arguments.label_smoothing,
                    only_correct_teacher=arguments.replay_only_correct_teacher,
                    agreement_all_rows=getattr(arguments,'replay_agreement_all_rows',False),
                    hard_label_mode=getattr(arguments,'replay_hard_label_mode','mixed'),
                    focal_gamma=getattr(arguments,'focal_gamma',0.),
                )
            if rdrop_alpha:
                second = model(**batch)
                if spam_weight:
                    spam_loss=.5*(spam_loss+spam_binary_loss(second.logits,labels,spam_id,spam_positive_weight))
                if replay_teacher is None:
                    second_loss = loss_fn(second.logits, labels)
                else:
                    second_loss = replay_distillation_loss(
                        second.logits, teacher_logits, labels, correction_mask,
                        arguments.replay_alpha, arguments.replay_temperature,
                        arguments.label_smoothing,
                        only_correct_teacher=arguments.replay_only_correct_teacher,
                        agreement_all_rows=getattr(arguments,'replay_agreement_all_rows',False),
                        hard_label_mode=getattr(arguments,'replay_hard_label_mode','mixed'),
                        focal_gamma=getattr(arguments,'focal_gamma',0.))
                losses_per_row = .5*(losses_per_row+second_loss) + rdrop_alpha*symmetric_kl(output.logits,second.logits)
                if action_weight:
                    action_loss = .5*(action_loss+action_cross_entropy(model.classifier,labels))
            if action_weight:
                losses_per_row = losses_per_row + action_weight*action_loss
            if spam_weight:
                losses_per_row=losses_per_row+spam_weight*spam_loss
            if view_batch is not None:
                from multilingual_views import paired_loss
                view_logits = model(**view_batch).logits
                with torch.no_grad(): view_teacher = replay_teacher(**view_batch).logits
                losses_per_row = paired_loss(output.logits, view_logits, teacher_logits, view_teacher,
                    labels, correction_mask, pair_mask, arguments)
            if scene_group is not None:
                losses_per_row=losses_per_row+arguments.scene_contrastive_weight*scene_loss(
                    scene_features,labels,scene_group,arguments.scene_contrastive_temperature)
            weighted_sum = (losses_per_row * loss_weights).sum()
            epoch_loss+=weighted_sum.detach();epoch_weight+=loss_weights.sum().detach()
            accumulated_weight += loss_weights.sum().detach()
            accumulated_loss += weighted_sum.detach()
            weighted_sum.backward()
            if (batch_index+1)%accumulation != 0 and batch_index+1 != len(loader):
                continue
            # Normalize once by actual row weights, including an uneven final
            # microbatch. Averaging microbatch means would overweight its tail.
            for parameter in trainable_parameters:
                if parameter.grad is not None:
                    parameter.grad.div_(accumulated_weight)
            loss = accumulated_loss/accumulated_weight
            # Apply once per optimizer update after data-gradient normalization;
            # never scale L2-SP by microbatch size, row weight or accumulation.
            if anchor.parameters:
                penalty=anchor.penalty()
                penalty.backward()
                loss=loss+penalty.detach()
            if sam_rho:
                from gradient_diagnostics import deterministic_terms
                with sam_perturbation(trainable_parameters, sam_rho) as ascent_norm:
                    optimizer.zero_grad(set_to_none=True)
                    second_weight = torch.zeros((), device=device)
                    second_loss = torch.zeros((), device=device)
                    for cached in sam_batches:
                        weighted, weight, _ = deterministic_terms(model, dict(cached), arguments,
                            replay_teacher, spam_positive_weight)
                        if not bool(torch.isfinite(weighted)):
                            raise ValueError('Non-finite SAM second-pass objective')
                        weighted.backward()
                        second_weight += weight.detach()
                        second_loss += weighted.detach()
                    if not torch.equal(second_weight, accumulated_weight):
                        raise ValueError('SAM effective-batch weights changed between passes')
                    for parameter in trainable_parameters:
                        if parameter.grad is not None:
                            parameter.grad.div_(second_weight)
                    second_loss /= second_weight
                    if anchor.parameters:
                        penalty = anchor.penalty()
                        penalty.backward()
                        second_loss += penalty.detach()
                # Parameters have been restored exactly. Only the second-pass
                # gradients reach clipping and the single AdamW/scheduler step.
                sam_batches.clear()
            step += 1
            norm=torch.nn.utils.clip_grad_norm_(trainable_parameters,max_norm,error_if_nonfinite=True)
            norms.append(float(norm.detach().cpu()))
            used_rates=[group['lr'] for group in optimizer.param_groups]
            if not first_rates:first_rates=list(used_rates)
            peak_rates=[max(a,b) for a,b in zip(peak_rates,used_rates)] if peak_rates else list(used_rates)
            optimizer.step()
            if locked_classifier_rows:
                restore_locked_classifier_rows(locked_classifier_rows)
            scheduler.step()
            if step == 1 or step % 25 == 0 or step == total_steps:
                point = {"step": step, "epoch": epoch + 1, "loss": float(loss.detach().cpu()),
                    'learningRates':used_rates,'gradientNorm':norms[-1]}
                if sam_rho:
                    point.update(samAscentGradientNorm=ascent_norm,
                        samPerturbedObjective=float(second_loss.cpu()))
                losses.append(point)
                print(f"step {step}/{total_steps} epoch {epoch + 1}/{epoch_limit} loss {point['loss']:.4f}")
            if step>=total_steps:break
        metric={'epoch':epoch+1,'step':step,'trainingObjectiveMean':float((epoch_loss/epoch_weight).cpu()),
            'meanGradientNorm':sum(norms[first_norm:])/max(1,len(norms)-first_norm),
            'clippedFraction':sum(n>max_norm for n in norms[first_norm:])/max(1,len(norms)-first_norm)}
        if parameters_before is not None:
            delta=torch.linalg.vector_norm(torch.stack([torch.linalg.vector_norm(p.detach()-old)
                for p,old in zip(trainable_parameters,parameters_before)]))
            magnitude=torch.linalg.vector_norm(torch.stack([torch.linalg.vector_norm(old) for old in parameters_before]))
            metric.update(parameterDeltaNorm=float(delta.cpu()),
                relativeParameterDelta=float((delta/magnitude.clamp_min(1e-12)).cpu()))
            del parameters_before
        if probe_every and ((epoch+1)%probe_every==0 or step>=total_steps):
            probe_status=probe(epoch+1,step)
            metric['fullTrainingProbe']=probe_history[-1]
        if stopping is not None:
            from generalization_validation import macro_f1,action_metrics,selection_scores
            accuracy, _, pairs, development_predictions = evaluate_model(model, tokenizer, validation_rows,
                label_to_id, sorted(label_to_id, key=label_to_id.get), arguments.max_length, device)
            score = macro_f1(pairs)
            action=action_metrics(pairs,validation_actions) if validation_actions else None
            maximum=getattr(arguments,'validation_max_benign_junk',None)
            minimum=getattr(arguments,'validation_min_spam_recall',None)
            all_maximum=getattr(arguments,'validation_max_nonspam_junk',None)
            if (maximum is not None or minimum is not None or all_maximum is not None) and action is None:
                raise ValueError('development action gates require taxonomy actions')
            eligible=(maximum is None or action['benignToJunk']<=maximum) and (
                minimum is None or (action['spamRecall'] is not None and action['spamRecall']>=minimum)) and (
                all_maximum is None or action['nonSpamToJunk']<=all_maximum)
            selection_objective=getattr(arguments,'validation_selection_objective','macro-f1')
            selection_score,diagnostic_score=selection_scores(pairs,validation_actions,
                objective=selection_objective,maximum_nonspam_junk=all_maximum)
            improved, should_stop = stopping.update(epoch + 1, selection_score,eligible=eligible)
            observed_improved=False
            if observed_stopping is not None:
                observed_improved,_=observed_stopping.update(epoch+1,diagnostic_score)
                if observed_improved:
                    observed_parameters={name:p.detach().cpu().clone()
                        for name,p in model.named_parameters() if p.requires_grad}
            nll=sum(p['negativeLogLikelihood'] for p in development_predictions)/len(development_predictions)
            metric.update(developmentNLL=nll,developmentMacroF1=score)
            if convergence is not None:
                stop_reason=convergence.update(nll,score,step)
                if tail is not None:
                    # Development picks the retained checkpoint. Its numerical
                    # divergence remains a veto; a mere plateau does not block
                    # the separately bounded training-loss convergence study.
                    if stop_reason!='development_nll_divergence':stop_reason=None
                elif stop_reason=='development_plateau' and getattr(arguments,'convergence_require_training_plateau',False):
                    stop_reason=('joint_training_development_plateau' if probe_status and
                        probe_status['objectivePlateau'] and 'fullTrainingProbe' in metric else None)
                should_stop=stop_reason is not None
            elif should_stop:stop_reason='eligible_epoch_patience'
            if improved:
                best_parameters = {name: parameter.detach().cpu().clone()
                    for name, parameter in model.named_parameters() if parameter.requires_grad}
            if selection_history is not None:
                selection_history.append({"epoch": epoch + 1, "developmentMacroF1": score,
                    "developmentAccuracy": accuracy, "selected": improved,
                    "bestEpoch": stopping.best_epoch, "stop": should_stop,
                    'diagnosticSelected':observed_improved,
                    'diagnosticBestEpoch':observed_stopping.best_epoch if observed_stopping else None,
                    'selectionObjective':selection_objective,'selectionScore':selection_score,
                    'diagnosticSelectionScore':diagnostic_score,
                    'actionMetrics':action,'actionGatesPassed':eligible,'developmentNLL':nll,'step':step})
            print(f"development epoch {epoch + 1}: macro F1 {score:.4f}, accuracy {accuracy:.4f}, best epoch {stopping.best_epoch}")
        if tail is not None and not stop_reason:
            if not probe_history or probe_history[-1]['epoch']!=epoch+1:
                raise ValueError('adaptive continuation requires a fresh full-training probe')
            event=tail.finish_epoch(epoch+1,probe_history[-1]['objective'])
            metric['lossTail']=event
            stop_reason=tail.stop_reason
            if epoch+1>=arguments.num_epochs:
                print(f"loss-tail epoch {epoch+1}: {event['decision']}; active limit {tail.active_epoch_limit}; LRs {tail.get_last_lr()}")
            if selection_history:selection_history[-1]['stop']=stop_reason is not None
        epoch_metrics.append(metric)
        if getattr(arguments,'save_epoch_parameters',False):
            archive=Path(arguments.out)/'epochs'/f'epoch-{epoch+1:03d}.pt'
            archive.parent.mkdir(parents=True,exist_ok=True)
            temporary=archive.with_suffix('.pt.tmp')
            torch.save({'epoch':epoch+1,'step':step,'contract':contract,
                'parameters':{n:p.detach().cpu().clone() for n,p in model.named_parameters() if p.requires_grad},
                'development':selection_history[-1] if selection_history else None},temporary)
            temporary.replace(archive)
        if state_path:
            progress_path=Path(state_path).with_name('epoch-progress.json')
            progress_path.parent.mkdir(parents=True,exist_ok=True)
            progress_temp=progress_path.with_suffix('.json.tmp')
            progress_temp.write_text(json.dumps({'epochMetrics':epoch_metrics,
                'gradientProbes':probe_history,'developmentHistory':selection_history or [],
                'stopReason':stop_reason},indent=2)+'\n')
            progress_temp.replace(progress_path)
        if state_path:
            save_state(state_path,model,optimizer,scheduler,generator,contract,
                {'nextEpoch':epoch+1,'step':step,'losses':losses,'norms':norms,'epochMetrics':epoch_metrics,
                 'firstRates':first_rates,'peakRates':peak_rates,'bestParameters':best_parameters,
                 'stopping':stopping.__dict__ if stopping else None,
                 'observedStopping':observed_stopping.__dict__ if observed_stopping else None,
                 'observedParameters':observed_parameters,
                 'convergence':asdict(convergence) if convergence else None,
                 'history':selection_history or [],
                 'gradientProbeHistory':probe_history,
                 'trainingPlateauHistory':training_plateau.history if training_plateau else None,
                 'scheduleExtension':extension_report,
                 'stopReason':stop_reason or ('max_updates' if step>=total_steps else None)},device)
        if getattr(arguments,'save_epoch_parameters',False) and getattr(arguments,'epoch_retention','all')=='selected-and-last':
            from sharpness_aware import prune_epoch_archives
            selected = stopping.best_epoch if stopping and best_parameters is not None else (
                observed_stopping.best_epoch if observed_stopping else None)
            prune_epoch_archives(Path(arguments.out)/'epochs', epoch+1, selected)
        if stop_reason:break
    restored_epoch=stopping.best_epoch if stopping else None
    selected_eligible=best_parameters is not None
    if best_parameters is None and observed_parameters is not None:
        best_parameters=observed_parameters
        restored_epoch=observed_stopping.best_epoch
    if best_parameters is not None:
        with torch.no_grad():
            for name, parameter in model.named_parameters():
                if name in best_parameters:
                    parameter.copy_(best_parameters[name].to(parameter.device, parameter.dtype))
        print(f"restored development-selected epoch {restored_epoch}; action gates passed: {selected_eligible}")
    if optimization_summary is not None:
        optimization_summary.update(completedUpdates=step,
            meanGradientNorm=sum(norms)/len(norms) if norms else None,
            clippedUpdates=sum(n>max_norm for n in norms), learningRateTrace=losses,
            firstUsedLearningRates=first_rates,peakUsedLearningRates=peak_rates,
            lastUsedLearningRates=used_rates if norms else [],
            stateInitialization=('restored optimizer, scheduler and RNG state' if resume_path else
                'preserved terminal weights, Adam moments and RNG; explicit new bounded schedule and original anchor' if extension_path else
                'fresh optimizer and scheduler; weights-only resume'),
            scheduleExtension=extension_report,
            stateResumed=bool(resume_path),epochMetrics=epoch_metrics,
            selectedCheckpointEpoch=restored_epoch,selectedCheckpointEligible=selected_eligible,
            parameterAnchorWeight=anchor.coefficient,replayAgreementAllRows=getattr(arguments,'replay_agreement_all_rows',False),
            replayHardLabelMode=getattr(arguments,'replay_hard_label_mode','mixed'),
            trainingObjectiveMeanScope='weighted data objective; fullTrainingProbe.objective also includes parameter anchor',
            stopReason=stop_reason or ('max_updates' if step>=total_steps else 'epoch_budget'),
            convergenceState=asdict(convergence) if convergence else None,
            gradientProbes=probe_history,trainingPlateau=probe_status,
            lossTail=tail.state_dict() if tail is not None else None,
            spamObjective={'weight':spam_weight,'positiveWeight':spam_positive_weight,
                'trainingPositiveCount':sum(r['label']=='spam' for r in rows),
                'trainingNegativeCount':sum(r['label']!='spam' for r in rows)},
            torchVersion=torch.__version__)
    # The guard is a training/probe concern. Leave the returned model clean
    # for prediction and Core ML tracing; it is not part of the artifact.
    if backend_guard['enabled']:
        for module in model.modules():
            handle = getattr(module, '_sift_input_gradient_guard', None)
            if handle is not None:
                handle.remove()
                delattr(module, '_sift_input_gradient_guard')
    return losses


def evaluate_model(model, tokenizer, rows: list[dict[str, str]], label_to_id: dict[str, int], labels: list[str], max_length: int, device: str):
    if not rows:
        return 0.0, {}, [], []

    import torch
    from torch.utils.data import DataLoader

    dataset = TextDataset(rows, label_to_id)
    loader = DataLoader(dataset, batch_size=32, shuffle=False, collate_fn=make_collate(tokenizer, max_length))
    model.to(device)
    model.eval()
    expected_ids: list[int] = []
    predicted_ids: list[int] = []
    confidences: list[float] = []
    gold_nll: list[float] = []
    with torch.no_grad():
        for batch in loader:
            gold=batch.pop('labels')
            expected_ids.extend(int(item) for item in gold.tolist())
            batch.pop("loss_weights")
            batch = {key: value.to(device) for key, value in batch.items()}
            logits = model(**batch).logits
            gold_nll.extend(torch.nn.functional.cross_entropy(logits.float(),gold.to(device),reduction='none').cpu().tolist())
            probabilities = torch.softmax(logits, dim=-1)
            confidence, prediction = probabilities.max(dim=-1)
            predicted_ids.extend(int(item) for item in prediction.detach().cpu().tolist())
            confidences.extend(float(item) for item in confidence.detach().cpu().tolist())

    per_label_total: Counter[str] = Counter(labels[index] for index in expected_ids)
    per_label_correct: Counter[str] = Counter()
    pairs: list[tuple[str, str]] = []
    for want_id, got_id in zip(expected_ids, predicted_ids):
        want, got = labels[want_id], labels[got_id]
        pairs.append((want, got))
        if want == got:
            per_label_correct[want] += 1
    accuracy = sum(per_label_correct.values()) / len(expected_ids)
    per_label = {label: per_label_correct[label] / total for label, total in sorted(per_label_total.items())}
    predictions = [
        {
            "text": row["text"],
            "label": labels[want_id],
            "prediction": labels[got_id],
            "confidence": confidence,
            "correct": want_id == got_id,
            'negativeLogLikelihood':nll,
        }
        for row, want_id, got_id, confidence,nll in zip(rows, expected_ids, predicted_ids, confidences,gold_nll)
    ]
    return accuracy, per_label, pairs, predictions


def write_predictions(path: Path, predictions: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for prediction in predictions:
            handle.write(json.dumps(prediction, ensure_ascii=False) + "\n")
    print(f"predictions: {path}")


def apply_config_overrides(config, arguments: Arguments) -> None:
    overrides = {
        "classifier_dropout": arguments.classifier_dropout,
        "attention_dropout": arguments.attention_dropout,
        "embedding_dropout": arguments.embedding_dropout,
        "mlp_dropout": arguments.mlp_dropout,
        "classifier_pooling": arguments.classifier_pooling,
    }
    for name, value in overrides.items():
        if value is None:
            continue
        if not hasattr(config, name):
            raise SystemExit(f"error: backbone config has no field {name}")
        setattr(config, name, value)


def freeze_encoder(model) -> None:
    encoder = getattr(model, "model", None)
    if encoder is None:
        raise SystemExit("error: --freeze-encoder could not find model.model")
    for parameter in encoder.parameters():
        parameter.requires_grad = False
    trainable = sum(parameter.numel() for parameter in model.parameters() if parameter.requires_grad)
    frozen = sum(parameter.numel() for parameter in model.parameters() if not parameter.requires_grad)
    print(f"encoder frozen: {trainable:,} trainable parameters, {frozen:,} frozen")


def train_last_encoder_layers(model, count: int) -> None:
    encoder = getattr(model, "model", None)
    layers = getattr(encoder, "layers", None)
    if layers is None or not 1 <= count <= len(layers):
        raise ValueError("last-layer tuning requires a valid ModernBERT encoder layer count")
    encoder.requires_grad_(False)
    for layer in list(layers)[-count:]:
        layer.requires_grad_(True)
    final_norm = getattr(encoder, "final_norm", None)
    if final_norm is not None:
        final_norm.requires_grad_(True)
    trainable = sum(parameter.numel() for parameter in model.parameters() if parameter.requires_grad)
    print(f"training last {count}/{len(layers)} layers and head: {trainable:,} trainable parameters")


def restore_locked_classifier_rows(locked_classifier_rows) -> None:
    import torch

    with torch.no_grad():
        for parameter, indices, snapshot in locked_classifier_rows:
            # Long-tensor indexing returns a copy. index_copy_ writes into the
            # real parameter and reverses AdamW decay on every protected row.
            parameter.index_copy_(0, indices.to(parameter.device),
                                  snapshot.to(parameter.device, parameter.dtype))


def train_only_classifier_rows(
    model,
    migrated_parameter_names: list[str],
    current_label_to_id: dict[str, int],
    selected_labels: list[str],
) -> list[tuple[object, object, object]]:
    import torch

    unknown = sorted(set(selected_labels) - set(current_label_to_id))
    if unknown:
        raise SystemExit(f"error: unknown --train-label-rows labels: {', '.join(unknown)}")
    selected_indices = sorted(current_label_to_id[label] for label in set(selected_labels))
    if not selected_indices:
        raise SystemExit("error: classifier-row training requires at least one selected label")
    migrated = set(migrated_parameter_names)
    if not migrated:
        raise SystemExit("error: no migrated classifier rows are available to protect")

    locked_indices = sorted(set(current_label_to_id.values()) - set(selected_indices))
    locked: list[tuple[object, object, object]] = []
    for name, parameter in model.named_parameters():
        parameter.requires_grad = name in migrated
        if not parameter.requires_grad:
            continue
        locked_tensor = torch.tensor(locked_indices, dtype=torch.long, device=parameter.device)
        snapshot = parameter.detach()[locked_tensor].clone().cpu()
        mask = torch.zeros_like(parameter)
        mask[selected_indices] = 1
        parameter.register_hook(
            lambda gradient, row_mask=mask: gradient * row_mask.to(gradient.device)
        )
        locked.append((parameter, locked_tensor, snapshot))

    if not locked:
        raise SystemExit("error: no label-dependent classifier parameters remain trainable")
    trainable = sum(parameter.numel() for parameter in model.parameters() if parameter.requires_grad)
    print(
        f"classifier-row training: {trainable:,} output parameters available; "
        f"updating rows for {', '.join(sorted(selected_labels))} only"
    )
    return locked


def train_only_added_classifier_rows(
    model,
    migrated_parameter_names: list[str],
    previous_id_to_label: dict[int, str],
    current_label_to_id: dict[str, int],
) -> list[tuple[object, object, object]]:
    new_indices = set(added_label_ids(previous_id_to_label, current_label_to_id))
    labels = [label for label, index in current_label_to_id.items() if index in new_indices]
    if not labels:
        raise SystemExit("error: --train-new-label-rows-only requires at least one added label")
    return train_only_classifier_rows(
        model,
        migrated_parameter_names,
        current_label_to_id,
        labels,
    )


def truncate_modernbert_layers(model, keep: int) -> None:
    import torch

    if keep <= 0:
        return
    layers = getattr(getattr(model, "model", None), "layers", None)
    if layers is None:
        raise SystemExit("error: --truncate-layers is only implemented for ModernBERT-style models")
    if keep >= len(layers):
        return
    model.model.layers = torch.nn.ModuleList(list(layers)[:keep])
    model.config.num_hidden_layers = keep
    model.model.config.num_hidden_layers = keep
    print(f"transformer truncated to {keep} layers")


def patch_modernbert_for_coreml_export(model, seq_len: int) -> None:
    """Avoids TorchScript/Core ML conversion bugs in dynamic ModernBERT RoPE.

    Core ML Tools currently fails on the `x.shape[-1] // 2` path used by
    ModernBERT's `rotate_half`. For the app we always export a fixed sequence
    length, so we precompute RoPE cos/sin tensors and use constant dimensions.
    """
    import torch

    if getattr(model.config, "model_type", "") != "modernbert":
        return
    model.config._attn_implementation = "eager"
    positions = torch.arange(seq_len, dtype=torch.float32)
    for layer in model.model.layers:
        attention = layer.attn
        attention.config._attn_implementation = "eager"
        inv_freq = attention.rotary_emb.inv_freq.detach().float()
        freqs = torch.outer(positions, inv_freq)
        emb = torch.cat((freqs, freqs), dim=-1)
        scale = float(getattr(attention.rotary_emb, "attention_scaling", 1.0))
        attention.register_buffer(
            "_export_cos",
            (emb.cos() * scale).view(1, 1, seq_len, attention.head_dim),
            persistent=False,
        )
        attention.register_buffer(
            "_export_sin",
            (emb.sin() * scale).view(1, 1, seq_len, attention.head_dim),
            persistent=False,
        )

        def fixed_forward(self, hidden_states, output_attentions=False, **kwargs):
            qkv = self.Wqkv(hidden_states)
            qkv = qkv.view(1, seq_len, 3, self.num_heads, self.head_dim)
            query, key, value = qkv.transpose(3, 1).unbind(dim=2)
            cos = self._export_cos.to(dtype=query.dtype)
            sin = self._export_sin.to(dtype=query.dtype)
            half = self.head_dim // 2
            query_rotated = torch.cat((-query[..., half:], query[..., :half]), dim=-1)
            key_rotated = torch.cat((-key[..., half:], key[..., :half]), dim=-1)
            query = (query * cos) + (query_rotated * sin)
            key = (key * cos) + (key_rotated * sin)
            attention_mask = kwargs.get("attention_mask")
            if self.local_attention != (-1, -1):
                attention_mask = kwargs.get("sliding_window_mask")
            weights = torch.matmul(query, key.transpose(2, 3)) * (self.head_dim**-0.5)
            if attention_mask is not None:
                weights = weights + attention_mask
            weights = torch.nn.functional.softmax(weights, dim=-1, dtype=torch.float32).to(query.dtype)
            output = torch.matmul(weights, value)
            output = output.transpose(1, 2).contiguous().view(1, seq_len, self.all_head_size)
            output = self.out_drop(self.Wo(output))
            return (output, weights) if output_attentions else (output,)

        attention.forward = types.MethodType(fixed_forward, attention)


def export_coreml(model, labels: list[str], max_length: int, quantize: str):
    import coremltools as ct
    import numpy as np
    import torch

    class FusedClassifier(torch.nn.Module):
        def __init__(self, classifier):
            super().__init__()
            self.classifier = classifier.to("cpu").eval()

        def forward(self, input_ids, attention_mask):
            outputs = self.classifier(
                input_ids=input_ids.to(torch.long),
                attention_mask=attention_mask.to(torch.long),
                return_dict=True,
            )
            return torch.softmax(outputs.logits, dim=-1)

    model.to("cpu").eval()
    patch_modernbert_for_coreml_export(model, max_length)
    fused = FusedClassifier(model).eval()
    example_ids = torch.ones((1, max_length), dtype=torch.int32)
    example_mask = torch.ones((1, max_length), dtype=torch.int32)
    traced = torch.jit.trace(fused, (example_ids, example_mask))
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name=MODEL_INPUT_IDS, shape=(1, max_length), dtype=np.int32),
            ct.TensorType(name=MODEL_ATTENTION_MASK, shape=(1, max_length), dtype=np.int32),
        ],
        classifier_config=ct.ClassifierConfig(class_labels=labels),
        # Core ML Tools 9 can emit non-finite CPU_ONLY values for this
        # attention graph when every intermediate is lowered to FP16. Keep
        # the compute graph in FP32; the tournament still applies W8/W4
        # weight quantization and the physical-device gate remains required.
        compute_precision=ct.precision.FLOAT32,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
    )
    if quantize == "int8":
        from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

        config = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8")
        )
        mlmodel = linear_quantize_weights(mlmodel, config=config)
    return mlmodel


def directory_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    for file in sorted(path.rglob("*")):
        if file.is_file():
            digest.update(str(file.relative_to(path)).encode("utf-8"))
            digest.update(file.read_bytes())
    return digest.hexdigest()


def file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def remote_artifacts(paths: list[Path], root: Path) -> list[dict]:
    artifacts: list[dict] = []
    for path in paths:
        files = sorted(item for item in path.rglob("*") if item.is_file()) if path.is_dir() else [path]
        for file in files:
            artifacts.append(
                {
                    "path": file.relative_to(root).as_posix(),
                    "sha256": file_sha256(file),
                    "byteCount": file.stat().st_size,
                }
            )
    return sorted(artifacts, key=lambda item: item["path"])


def write_tokenizer_artifact(tokenizer, out_dir: Path, model_name: str) -> Path:
    artifact = out_dir / f"{model_name}.tokenizer.siftbpe"
    with tempfile.TemporaryDirectory() as temp:
        temp_dir = Path(temp)
        tokenizer.save_pretrained(temp_dir)
        write_compact_bpe_tokenizer(temp_dir / "tokenizer.json", artifact)
    return artifact


def write_training_report(
    out_dir: Path,
    arguments: Arguments,
    accuracy: float,
    per_label: dict[str, float],
    pairs: list[tuple[str, str]],
    loss_points: list[dict],
    label_counts: Counter,
) -> Path:
    metrics_path = out_dir / "metrics.jsonl"
    with metrics_path.open("w", encoding="utf-8") as handle:
        for point in loss_points:
            handle.write(json.dumps({"kind": "loss", **point}) + "\n")
        handle.write(json.dumps({"kind": "validation", "accuracy": accuracy, "perLabel": per_label}) + "\n")

    confusion: Counter = Counter((want, got) for want, got in pairs if want != got)
    confusion_rows = "".join(
        f'<tr><td class="mono">{want}</td><td class="mono">{got}</td><td class="mono">{count}</td></tr>'
        for (want, got), count in confusion.most_common(15)
    ) or '<tr><td colspan="3">No validation confusions</td></tr>'
    loss_rows = "".join(
        f'<tr><td class="mono">{point["step"]}</td><td class="mono">{point["epoch"]}</td><td class="mono">{point["loss"]:.4f}</td></tr>'
        for point in loss_points
    ) or '<tr><td colspan="3">Training skipped or no loss logged.</td></tr>'
    accuracy_rows = "".join(
        f'<tr><td class="mono">{label}</td><td class="mono">{score * 100:.1f}%</td><td class="mono">{label_counts.get(label, 0)}</td></tr>'
        for label, score in sorted(per_label.items(), key=lambda item: item[1])
    )
    html = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Sift mmBERT training report</title>
<style>
body{{font:14px/1.5 -apple-system,system-ui,sans-serif;margin:32px auto;max-width:820px;color:#222}}
h1{{font-size:20px}} h2{{font-size:15px;margin-top:28px}}
table{{border-collapse:collapse;width:100%}} td,th{{padding:3px 8px;border-bottom:1px solid #eee;text-align:left;font-size:12px}}
.mono{{font-family:ui-monospace,monospace}}
.kpi{{display:inline-block;margin-right:24px;padding:10px 14px;background:#f4f6f5;border-radius:8px}}
.kpi b{{display:block;font-size:20px}}
</style></head><body>
<h1>Sift mmBERT training report</h1>
<p class="mono">version {arguments.version} · backbone {arguments.backbone} · corpus {arguments.input.name}</p>
<div>
  <span class="kpi"><b>{accuracy * 100:.2f}%</b>validation accuracy</span>
  <span class="kpi"><b>{sum(label_counts.values())}</b>training rows</span>
  <span class="kpi"><b>{len(label_counts)}</b>labels</span>
</div>
<h2>Loss logs</h2>
<table><tr><th>step</th><th>epoch</th><th>loss</th></tr>{loss_rows}</table>
<h2>Per-label validation accuracy (worst first)</h2>
<table><tr><th>label</th><th>accuracy</th><th>train rows</th></tr>{accuracy_rows}</table>
<h2>Top validation confusions</h2>
<table><tr><th>expected</th><th>predicted</th><th>count</th></tr>{confusion_rows}</table>
</body></html>
"""
    report_path = out_dir / "training-report.html"
    report_path.write_text(html, encoding="utf-8")
    return report_path


def tokenizer_kind(tokenizer) -> str:
    backend = getattr(tokenizer, "backend_tokenizer", None)
    if backend is None:
        return "unknown"
    return type(backend.model).__name__.lower()


def main() -> None:
    arguments = parse_arguments()
    repo_root = locate_repo_root()

    rows = load_rows(arguments.input, max_rows=arguments.max_rows)
    from retired_samples import RetiredSamples
    retirement=RetiredSamples()
    from prepare_approved_signal import quality_reason
    if any(retirement.reason(row) or quality_reason(row) for row in rows):
        raise SystemExit('error: input contains deleted/retired training samples; use the approved corpus')
    valid_labels = model_labels(load_taxonomy_labels(repo_root))
    unknown = {row["label"] for row in rows} - valid_labels
    if unknown:
        raise SystemExit(f"error: unknown labels in dataset: {', '.join(sorted(unknown))}")

    labels = sorted({row["label"] for row in rows})
    label_to_id = {label: index for index, label in enumerate(labels)}
    id_to_label = {index: label for label, index in label_to_id.items()}
    if arguments.validation_input:
        from import_reviewed_public import keys
        training_rows, validation_rows = rows, load_rows(arguments.validation_input)
        if not validation_rows or {r["label"] for r in validation_rows} - set(labels):
            raise SystemExit("error: development rows must be nonempty and use trained labels")
        protected = set().union(*(keys(r["text"], family=True) for r in validation_rows))
        if any(keys(r["text"], family=True) & protected for r in training_rows):
            raise SystemExit("error: training overlaps grouped development data")
    else:
        training_rows, validation_rows = stratified_split(rows, arguments.validation_fraction, arguments.seed)
    print(f"rows: {len(rows)} total, {len(training_rows)} train, {len(validation_rows)} validation, {len(labels)} labels")

    import torch
    from transformers import AutoConfig, AutoModelForSequenceClassification, AutoTokenizer, set_seed

    set_seed(arguments.seed)
    device = select_device(arguments.device)
    print(f"device: {describe_device(device)}")

    model_source = str(arguments.resume_from) if arguments.resume_from is not None else arguments.backbone
    tokenizer_source = model_source
    tokenizer = AutoTokenizer.from_pretrained(tokenizer_source)
    previous_id_to_label: dict[int, str] | None = None
    if arguments.resume_from is not None:
        previous_config = AutoConfig.from_pretrained(model_source)
        try:
            previous_id_to_label = {
                int(index): str(label) for index, label in previous_config.id2label.items()
            }
        except (TypeError, ValueError) as error:
            raise SystemExit("error: resume checkpoint has an invalid id2label mapping") from error
    config = AutoConfig.from_pretrained(
        model_source,
        num_labels=len(labels),
        id2label=id_to_label,
        label2id=label_to_id,
    )
    apply_config_overrides(config, arguments)
    model = AutoModelForSequenceClassification.from_pretrained(
        model_source,
        config=config,
        ignore_mismatched_sizes=True,
    )
    migrated_parameter_names: list[str] = []
    if arguments.resume_from is not None and previous_id_to_label is not None:
        try:
            migrated_parameter_names = migrate_resumed_classifier_rows(
                model,
                arguments.resume_from,
                previous_id_to_label,
                label_to_id,
            )
        except ValueError as error:
            raise SystemExit(f"error: incompatible resume label contract: {error}") from error
    model.config.problem_type = "single_label_classification"
    truncate_modernbert_layers(model, arguments.truncate_layers)
    locked_classifier_rows = None
    adaptation_report=None
    if arguments.train_new_label_rows_only and arguments.train_label_rows:
        raise SystemExit("error: use only one of --train-new-label-rows-only or --train-label-rows")
    if arguments.train_new_label_rows_only:
        if arguments.resume_from is None or previous_id_to_label is None:
            raise SystemExit("error: --train-new-label-rows-only requires --resume-from")
        locked_classifier_rows = train_only_added_classifier_rows(
            model,
            migrated_parameter_names,
            previous_id_to_label,
            label_to_id,
        )
    elif arguments.train_label_rows:
        if arguments.resume_from is None:
            raise SystemExit("error: --train-label-rows requires --resume-from")
        locked_classifier_rows = train_only_classifier_rows(
            model,
            migrated_parameter_names,
            label_to_id,
            arguments.train_label_rows,
        )
    elif arguments.lora_rank:
        from low_rank_adaptation import install_attention_lora
        adaptation_report=install_attention_lora(model,arguments.train_last_layers,arguments.lora_rank,
            arguments.lora_alpha,arguments.lora_dropout)
    elif arguments.freeze_encoder:
        freeze_encoder(model)
    elif arguments.train_last_layers:
        train_last_encoder_layers(model, arguments.train_last_layers)

    replay_teacher = None
    if arguments.replay_teacher is not None:
        from replay_distillation import validate_replay_contract

        replay_teacher = AutoModelForSequenceClassification.from_pretrained(
            arguments.replay_teacher, local_files_only=True, attn_implementation="eager"
        )
        replay_tokenizer = AutoTokenizer.from_pretrained(arguments.replay_teacher, local_files_only=True)
        validate_replay_contract(
            labels,
            [replay_teacher.config.id2label[index] for index in range(replay_teacher.config.num_labels)],
            tokenizer, replay_tokenizer,
        )

    selection_history = []
    optimization_summary = {}
    from model_contract import model_actions
    validation_actions=model_actions(json.loads((repo_root/'packages/taxonomy/taxonomy.json').read_text()))
    if arguments.action_loss_weight:
        from semantic_regularization import ActionResidualClassifier
        actions=sorted(set(validation_actions.values()))
        model.classifier=ActionResidualClassifier(model.classifier,
            [actions.index(validation_actions[label]) for label in labels])
    if adaptation_report is not None:
        adaptation_report['trainableParametersIncludingActionHead']=sum(p.numel() for p in model.parameters() if p.requires_grad)
    losses = train_model(
        model,
        tokenizer,
        training_rows,
        label_to_id,
        arguments,
        device,
        locked_classifier_rows,
        replay_teacher,
        validation_rows,
        selection_history,
        optimization_summary,
        validation_actions,
    )
    accuracy, per_label, prediction_pairs, validation_predictions = evaluate_model(
        model,
        tokenizer,
        validation_rows,
        label_to_id,
        labels,
        arguments.max_length,
        device,
    )
    fold_report=None
    if arguments.action_loss_weight:
        model.classifier=model.classifier.fold()
        folded=evaluate_model(model,tokenizer,validation_rows,label_to_id,labels,arguments.max_length,device)
        if folded[2] != prediction_pairs:
            raise RuntimeError('folded action hierarchy changed development predictions; refuse checkpoint/export')
        fold_report={'developmentPredictionAgreement':1.,'rows':len(validation_rows),
                     'classifierType':'Linear','runtimeAdditionalParameters':0}
    lora_report=None
    if arguments.lora_rank:
        from low_rank_adaptation import merge_attention_lora
        model.eval();lora_report=merge_attention_lora(model)
        merged=evaluate_model(model,tokenizer,validation_rows,label_to_id,labels,arguments.max_length,device)
        if merged[2]!=prediction_pairs:
            raise RuntimeError('merged LoRA changed development predictions; refuse checkpoint/export')
        lora_report.update(developmentPredictionAgreement=1.,rows=len(validation_rows))
    print(f"validation accuracy: {accuracy:.4f}")
    for label, score in per_label.items():
        print(f"  {label}: {score:.3f}")

    test_accuracy: float | None = None
    test_per_label: dict[str, float] = {}
    test_prediction_pairs: list[tuple[str, str]] = []
    test_predictions: list[dict] = []
    test_rows: list[dict[str, str]] = []
    if arguments.test_input is not None:
        test_rows = load_rows(arguments.test_input)
        test_unknown = {row["label"] for row in test_rows} - set(label_to_id)
        if test_unknown:
            raise SystemExit(f"error: labels in --test-input are absent from training data: {', '.join(sorted(test_unknown))}")
        test_accuracy, test_per_label, test_prediction_pairs, test_predictions = evaluate_model(
            model,
            tokenizer,
            test_rows,
            label_to_id,
            labels,
            arguments.max_length,
            device,
        )
        print(f"test accuracy: {test_accuracy:.4f}")
        for label, score in test_per_label.items():
            print(f"  test {label}: {score:.3f}")

    out = arguments.out
    out.mkdir(parents=True, exist_ok=True)
    if arguments.write_predictions is not None:
        write_predictions(
            arguments.write_predictions,
            test_predictions if arguments.test_input is not None else validation_predictions,
        )

    if arguments.save_checkpoint != "off":
        checkpoint_dir = out / "checkpoint" if arguments.save_checkpoint == "auto" else Path(arguments.save_checkpoint).expanduser().resolve()
        checkpoint_dir.mkdir(parents=True, exist_ok=True)
        model.save_pretrained(checkpoint_dir)
        tokenizer.save_pretrained(checkpoint_dir)
        print(f"checkpoint: {checkpoint_dir}")

    if arguments.skip_export:
        write_training_report(
            out,
            arguments,
            accuracy,
            per_label,
            prediction_pairs,
            losses,
            Counter(row["label"] for row in training_rows),
        )
        summary = {
            "version": arguments.version,
            "trainedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
            "algorithm": "supervised-sequence-classification",
            "backbone": arguments.backbone,
            "validationAccuracy": accuracy,
            "validationCount": len(validation_rows),
            "testAccuracy": test_accuracy,
            "testCount": len(test_rows),
            "trainingCount": len(training_rows),
            'optimization':optimization_summary,
            'semanticRegularization':{'actionLossWeight':arguments.action_loss_weight,
                'rdropAlpha':arguments.rdrop_alpha,'actionHeadFold':fold_report,'loraSetup':adaptation_report,'loraMerge':lora_report},
            'trainingState':{'path':str(arguments.training_state),
                'sha256':file_sha256(arguments.training_state),
                'semantics':'terminal epoch before development-best restoration (eligible or explicitly diagnostic) and action-head folding',
                'resumeInput':str(arguments.resume_training_state) if arguments.resume_training_state else None}
                if arguments.training_state else None,
            "developmentSelection": {"datasetSHA256": hashlib.sha256(arguments.validation_input.read_bytes()).hexdigest() if arguments.validation_input else None,
                "patience": arguments.early_stopping_patience, "minimumDelta": arguments.early_stopping_delta,
                "history": selection_history, "finalTestUsedForSelection": False,
                'actionGates':{'maxBenignJunk':arguments.validation_max_benign_junk,
                    'maxNonSpamJunk':arguments.validation_max_nonspam_junk,
                    'minSpamRecall':arguments.validation_min_spam_recall},
                'objective':arguments.validation_selection_objective,
                'eligibleEpochFound':any(p['selected'] for p in selection_history) if arguments.early_stopping_patience else None,
                'selectedCheckpointEpoch':optimization_summary.get('selectedCheckpointEpoch'),
                'selectedCheckpointEligible':optimization_summary.get('selectedCheckpointEligible'),
                'diagnosticBestFallback':arguments.diagnostic_best_fallback},
            "hyperparameters": {
                "numEpochs": arguments.num_epochs,
                'loraRank':arguments.lora_rank,'loraAlpha':arguments.lora_alpha,'loraDropout':arguments.lora_dropout,
                "batchSize": arguments.batch_size,
                "learningRate": arguments.learning_rate,
                "weightDecay": arguments.weight_decay,
                "warmupRatio": arguments.warmup_ratio,
                "labelSmoothing": arguments.label_smoothing,
                "focalGamma": arguments.focal_gamma,
                "multilingualMode": arguments.multilingual_mode if arguments.multilingual_view_spec else None,
                "translationConsistencyWeight": arguments.translation_consistency_weight if arguments.multilingual_view_spec else None,
                "classifierDropout": arguments.classifier_dropout,
                "attentionDropout": arguments.attention_dropout,
                "embeddingDropout": arguments.embedding_dropout,
                "mlpDropout": arguments.mlp_dropout,
                "classifierPooling": arguments.classifier_pooling,
                "freezeEncoder": arguments.freeze_encoder,
                "trainLastLayers": arguments.train_last_layers,
                "trainLabelRows": arguments.train_label_rows,
                "boundaryLossWeight": arguments.boundary_loss_weight,
                "selectedLabelLossWeight": arguments.selected_label_loss_weight,
                "maxLength": arguments.max_length,
                "seed": arguments.seed,
            },
            "labels": labels,
        }
        summary_path = out / "tuning-summary.json"
        if arguments.replay_teacher is not None:
            summary["replayPreservation"] = {
                "teacherCheckpointSHA256": directory_sha256(arguments.replay_teacher),
                "initialStudentCheckpointSHA256": directory_sha256(arguments.resume_from)
                    if arguments.resume_from else None,
                "alpha": arguments.replay_alpha,
                "temperature": arguments.replay_temperature,
                "correctionSourcePrefixes": arguments.replay_new_source_prefix,
                "correctionLossWeight": arguments.replay_new_loss_weight,
                "onlyCorrectTeacher": arguments.replay_only_correct_teacher,
                "agreementAllRows": arguments.replay_agreement_all_rows,
                "hardLabelMode": arguments.replay_hard_label_mode,
                "inputSHA256": file_sha256(arguments.input),
                "releaseEligible": False,
            }
        summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"summary: {summary_path}")
        print("export skipped")
        return

    from generalization_validation import require_export_selection
    try:
        require_export_selection(selection_history,early_stopping_enabled=bool(arguments.early_stopping_patience))
    except ValueError as error:
        raise SystemExit(f'error: {error}') from error
    package_path = out / f"{arguments.model_name}.mlpackage"
    if package_path.exists():
        shutil.rmtree(package_path)
    mlmodel = export_coreml(model, labels, arguments.max_length, arguments.quantize)
    mlmodel.save(str(package_path))

    tokenizer_path = write_tokenizer_artifact(tokenizer, out, arguments.model_name)
    downloadable_artifacts = remote_artifacts([package_path, tokenizer_path], out)
    manifest = {
        "schemaVersion": 2,
        "releaseSequence": arguments.release_sequence,
        "modelABI": arguments.model_abi,
        "minimumAppBuild": arguments.minimum_app_build,
        "maximumAppBuild": arguments.maximum_app_build,
        "minimumOSVersion": "18.0",
        "runtimeProfile": {
            "computeUnits": "cpuOnly",
            "modelType": "mlProgram",
            "inferenceBudgetMilliseconds": 500,
            "computePrecision": "float32",
        },
        "quantizationProfile": {
            "identifier": arguments.quantization_profile,
            "weightBits": 16 if arguments.quantize == "fp16" else 8,
            "activationBits": 32,
            "method": "baseline" if arguments.quantize == "fp16" else "ptq",
            "granularity": "per-tensor" if arguments.quantize == "fp16" else "per-channel",
        },
        "validationMetrics": {
            "fixedAccuracy": 0.0,
            "promotionAccuracy": test_accuracy or 0.0,
            "fp16Agreement": 0.0,
            "languageAccuracy": {},
        },
        "version": arguments.version,
        "trainedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z",
        "algorithm": "supervised-sequence-classification",
        "backbone": arguments.backbone,
        "languages": arguments.languages,
        "labels": labels,
        "maxSequenceLength": arguments.max_length,
        "doLowerCase": bool(getattr(tokenizer, "do_lower_case", False)),
        "tokenizerKind": tokenizer_kind(tokenizer),
        "tokenizerArtifact": tokenizer_path.name,
        "modelArtifact": package_path.name,
        "sha256": directory_sha256(package_path),
        "taxonomyHash": file_sha256(repo_root / "packages/taxonomy/taxonomy.json"),
        "tokenizerSHA256": file_sha256(tokenizer_path),
        "remoteArtifacts": downloadable_artifacts,
        "downloadBytes": sum(item["byteCount"] for item in downloadable_artifacts),
        "validationAccuracy": accuracy,
        "trainingCount": len(training_rows),
        "validationCount": len(validation_rows),
        "trainingParameters": {
            "boundaryLossWeight": arguments.boundary_loss_weight,
            "selectedLabelLossWeight": arguments.selected_label_loss_weight,
            "trainLabelRows": arguments.train_label_rows,
        },
    }
    if test_accuracy is not None:
        manifest["testAccuracy"] = test_accuracy
        manifest["testCount"] = len(test_rows)
    manifest_path = out / f"{arguments.model_name}.manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    report_path = write_training_report(
        out,
        arguments,
        accuracy,
        per_label,
        prediction_pairs,
        losses,
        Counter(row["label"] for row in training_rows),
    )

    print(f"model: {package_path}")
    print(f"tokenizer: {tokenizer_path}")
    print(f"manifest: {manifest_path}")
    print(f"report: {report_path}")

    if arguments.install_ios:
        generated = repo_root / "apps/ios/GeneratedModels"
        generated.mkdir(parents=True, exist_ok=True)
        installed_package = generated / package_path.name
        if installed_package.exists():
            shutil.rmtree(installed_package)
        shutil.copytree(package_path, installed_package)
        shutil.copy2(tokenizer_path, generated / tokenizer_path.name)
        shutil.copy2(manifest_path, generated / manifest_path.name)
        print(f"installed: {generated}")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
