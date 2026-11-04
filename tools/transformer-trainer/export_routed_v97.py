#!/usr/bin/env python3
"""Export a rebuilt encoder with its action head and signed gate weights for local qualification.

Keeps the shipped NeuralNetwork profile: FP32 encoder, mapped W4 embeddings, CPU only. The
encoder is rebuilt from its training state, and the action head becomes a second output.
Gate weights go in the manifest as base64 so the signed payload is identical in Python and
Swift. This writes an unsigned candidate on a non-stable track. It cannot publish.
"""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path
import shutil
import struct

from export_neuralnetwork import quantize_checkpoint_embeddings, unsigned_candidate_manifest
from externalize_embeddings import EMBEDDING_PATH, directory_sha256, sha256, write_embeddings

ROUTED_ALGORITHM = 'supervised-rebuild-directional-routing'
ROUTED_MINIMUM_APP_BUILD = 34
TRACKS = ('dev', 'beta')
GATE_VALUES = 3 * 18 + 3


def encode_gate(weight, bias) -> str:
    """Little-endian float32: 3x18 weights by row, then 3 biases."""
    values = [float(v) for row in weight for v in row] + [float(v) for v in bias]
    if len(values) != GATE_VALUES:
        raise ValueError('gate must have 3 outputs over 18 features')
    return base64.b64encode(struct.pack(f'<{GATE_VALUES}f', *values)).decode()


def routed_manifest(source: dict, *, version: str, sequence: int, track: str, gate: str, package_sha: str, trained_at: str, training_count: int) -> dict:
    if track not in TRACKS:
        raise ValueError('a rebuilt encoder can only use a non-stable track')
    candidate = unsigned_candidate_manifest(source)
    candidate.pop('distillation', None); candidate.pop('quantizationSource', None); candidate.pop('embeddingTransform', None)
    candidate.update(version=version, releaseSequence=sequence, minimumAppBuild=ROUTED_MINIMUM_APP_BUILD, algorithm=ROUTED_ALGORITHM,
                     releaseTrack=track, routing=dict(kind='directional-v75', gateWeights=gate), sha256=package_sha,
                     trainedAt=trained_at, trainingCount=training_count, releaseEligible=False)
    return candidate


def export(args) -> dict:
    import coremltools as ct
    import numpy as np
    import torch
    from train_mmbert import patch_modernbert_for_coreml_export
    import rebuild_v88 as base
    import routing_fresh_v93 as v93
    import score_v101

    def epoch_of():
        if args.arm in score_v101.ARMS: return score_v101.selected_epoch(args.arm, args.seed)
        return json.loads((v93.v92.OUT / 'selection.json').read_text())['results'][f'{args.arm}:{args.seed}']['selectedEpoch']

    if args.out.exists():
        raise ValueError('output already exists; use a new candidate directory')
    source_dir = args.mapped_source
    source = json.loads((source_dir / 'SiftSignalModel.manifest.json').read_text())
    package = source_dir / source['modelArtifact']; tokenizer = source_dir / source['tokenizerArtifact']
    if sha256(tokenizer) != source['tokenizerSHA256']:
        raise ValueError('tokenizer checksum mismatch')
    model, _ = score_v101.load_encoder(args.arm, args.seed)
    model = model.float().eval(); labels = [model.config.id2label[i] for i in range(model.config.num_labels)]
    if labels != source['labels'] or model.config.num_hidden_layers != 12:
        raise ValueError('checkpoint differs from the qualified 12-layer label contract')
    head = torch.nn.Linear(384, 4); head.load_state_dict(torch.load(args.head, weights_only=True)); head = head.float().eval()
    gate = torch.load(args.gate, weights_only=True)
    length = source['maxSequenceLength']
    with (package / EMBEDDING_PATH).open('rb') as stream:
        magic, abi, rows, width, block, scale_bytes, stride = struct.unpack('<8s6I', stream.read(32))
    if magic != b'SIFTEMB1' or abi != 1 or rows != model.config.vocab_size or width != model.config.hidden_size:
        raise ValueError('mapped embedding format does not match the checkpoint')
    patch_modernbert_for_coreml_export(model, length)

    class Routed(torch.nn.Module):
        def __init__(self):
            super().__init__(); self.model = model; self.head = head; self.pooled = None
            model.classifier.register_forward_pre_hook(self.capture)

        def capture(self, _module, inputs):
            self.pooled = inputs[0]

        def forward(self, input_embeddings, attention_mask):
            logits = self.model(inputs_embeds=input_embeddings, attention_mask=attention_mask.long(), return_dict=True).logits
            return logits.softmax(-1), self.head(self.pooled).softmax(-1)

    traced = torch.jit.trace(Routed().eval(), (torch.ones(1, length, width), torch.ones(1, length, dtype=torch.int32)), strict=False)
    converted = ct.convert(traced, convert_to='neuralnetwork', minimum_deployment_target=ct.target.iOS14,
        inputs=[ct.TensorType(name='input_embeddings', shape=(1, length, width), dtype=np.float32),
                ct.TensorType(name='attention_mask', shape=(1, length), dtype=np.int32)],
        outputs=[ct.TensorType(name='probabilities'), ct.TensorType(name='actionProbabilities')])
    args.out.mkdir(parents=True); target = args.out / source['modelArtifact']; converted.save(str(target))
    (target / EMBEDDING_PATH).parent.mkdir(parents=True, exist_ok=True)
    quantized, scales = quantize_checkpoint_embeddings(model.get_input_embeddings().weight.detach().cpu().numpy(), block)
    info = write_embeddings(target / EMBEDDING_PATH, quantized, scales, scale_bytes=scale_bytes)
    same_embedding = sha256(target / EMBEDDING_PATH) == sha256(package / EMBEDDING_PATH)
    shutil.copy2(tokenizer, args.out / tokenizer.name)
    training = len(score_v101.training_rows(args.arm))
    candidate = routed_manifest(source, version=args.version, sequence=args.release_sequence, track=args.track,
        gate=encode_gate(gate['weight'].tolist(), gate['bias'].tolist()), package_sha=directory_sha256(target),
        trained_at=args.trained_at, training_count=training)
    files = sorted(p for p in target.rglob('*') if p.is_file()) + [args.out / tokenizer.name]
    candidate['remoteArtifacts'] = [dict(path=p.relative_to(args.out).as_posix(), sha256=sha256(p), byteCount=p.stat().st_size) for p in files]
    candidate['downloadBytes'] = sum(a['byteCount'] for a in candidate['remoteArtifacts'])
    (args.out / 'SiftSignalModel.manifest.json').write_text(json.dumps(candidate, indent=2, ensure_ascii=False) + '\n')
    (args.out / 'export-provenance.json').write_text(json.dumps(dict(arm=args.arm, seed=args.seed, encoderEpoch=epoch_of(),
        headSHA256=sha256(args.head), gateSHA256=sha256(args.gate), sourceManifestSHA256=sha256(source_dir / 'SiftSignalModel.manifest.json'),
        embeddingIdenticalToSource=same_embedding, embedding=info, packageSHA256=candidate['sha256'], releaseEligible=False), indent=1, default=str) + '\n')
    return candidate


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--arm', default='free-v92'); parser.add_argument('--seed', type=int, default=321)
    parser.add_argument('--head', type=Path, required=True); parser.add_argument('--gate', type=Path, required=True)
    parser.add_argument('--mapped-source', type=Path, required=True); parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--version', required=True); parser.add_argument('--release-sequence', type=int, default=7)
    parser.add_argument('--track', choices=TRACKS, default='dev'); parser.add_argument('--trained-at', required=True)
    parsed = parser.parse_args(); result = export(parsed)
    print('unselected candidate', result['sha256'], result['downloadBytes'])
