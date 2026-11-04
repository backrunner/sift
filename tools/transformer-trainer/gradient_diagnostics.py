"""Full-corpus, unclipped gradient diagnostics without changing training RNG.

The dropout-disabled data objective includes reviewed weights, KD, smoothing
and action/spam auxiliaries. R-Drop KL is zero for identical eval passes;
decoupled AdamW decay is not a data-loss term. Thus this is a deterministic
optimization proxy, not a claim of zero expected stochastic-training gradient.
"""
from dataclasses import dataclass, field
import math


def deterministic_terms(model, batch, arguments, teacher=None, spam_positive_weight=None):
    import torch
    import torch.nn.functional as F
    from replay_distillation import correction_loss_weights, replay_distillation_loss
    from hard_label_loss import supervised_loss
    labels=batch.pop('labels')
    weights=batch.pop('loss_weights')
    mask=batch.pop('correction_mask',None)
    from multilingual_views import pop_view_batch
    view_batch, pair_mask = pop_view_batch(batch)
    scene_group=batch.pop('scene_group',None)
    from scene_contrastive import forward_features,scene_loss
    output,scene_features=forward_features(model,batch,scene_group is not None)
    if teacher is None:
        losses=supervised_loss(output.logits,labels,label_smoothing=arguments.label_smoothing,
            focal_gamma=getattr(arguments,'focal_gamma',0.))
    else:
        if mask is None:
            raise ValueError('replay gradient probe requires the correction mask')
        with torch.no_grad():
            teacher_logits=teacher(**batch).logits
        weights=correction_loss_weights(weights,mask,arguments.replay_new_loss_weight)
        losses=replay_distillation_loss(output.logits,teacher_logits,labels,mask,
            arguments.replay_alpha,arguments.replay_temperature,arguments.label_smoothing,
            only_correct_teacher=arguments.replay_only_correct_teacher,
            agreement_all_rows=getattr(arguments,'replay_agreement_all_rows',False),
            hard_label_mode=getattr(arguments,'replay_hard_label_mode','mixed'),
            focal_gamma=getattr(arguments,'focal_gamma',0.))
    if view_batch is not None:
        from multilingual_views import paired_loss
        if teacher is None: raise ValueError('paired gradient probe requires a frozen teacher')
        view_logits = model(**view_batch).logits
        with torch.no_grad(): view_teacher = teacher(**view_batch).logits
        losses = paired_loss(output.logits, view_logits, teacher_logits, view_teacher,
            labels, mask, pair_mask, arguments)
    if action_weight:=getattr(arguments,'action_loss_weight',0.):
        from semantic_regularization import action_cross_entropy
        losses=losses+action_weight*action_cross_entropy(model.classifier,labels)
    if getattr(arguments,'spam_loss_weight',0.):
        from spam_objective import spam_binary_loss
        spam_id=model.config.label2id['spam']
        losses=losses+arguments.spam_loss_weight*spam_binary_loss(
            output.logits,labels,spam_id,spam_positive_weight)
    if scene_group is not None:
        losses=losses+arguments.scene_contrastive_weight*scene_loss(
            scene_features,labels,scene_group,arguments.scene_contrastive_temperature)
    return (losses*weights).sum(),weights.sum(),len(labels)


def full_gradient_probe(model, loader, loss_terms, device, regularizer=None):
    """Sum gradients over all rows, normalize once, never clip or step."""
    import torch
    modes={module:module.training for module in model.modules()}
    cpu_rng=torch.get_rng_state()
    accelerator_rng=(torch.mps.get_rng_state() if device=='mps' else
        torch.cuda.get_rng_state_all() if device.startswith('cuda') else None)
    parameters=[p for p in model.parameters() if p.requires_grad]
    model.eval();model.zero_grad(set_to_none=True)
    total_loss=torch.zeros((),device=device)
    total_weight=torch.zeros((),device=device)
    count=0
    try:
        for batch in loader:
            batch={k:v.to(device) for k,v in batch.items()}
            loss,weight,size=loss_terms(batch)
            if not bool(torch.isfinite(loss)) or not bool(torch.isfinite(weight)) or weight<=0:
                raise ValueError('invalid full-gradient probe loss or weight')
            loss.backward();total_loss+=loss.detach();total_weight+=weight.detach();count+=size
        if count==0:
            raise ValueError('empty full-gradient probe')
        for parameter in parameters:
            if parameter.grad is not None:
                parameter.grad.div_(total_weight)
        penalty = regularizer() if regularizer is not None else None
        if penalty is not None:
            penalty.backward()
        gradients=[p.grad for p in parameters if p.grad is not None]
        norm=torch.linalg.vector_norm(torch.stack([torch.linalg.vector_norm(g.float()) for g in gradients]))
        parameter_count=sum(p.numel() for p in parameters)
        value=float(norm.detach().cpu())
        if not math.isfinite(value):
            raise ValueError('non-finite full-gradient probe')
        return {'rows':count,'totalWeight':float(total_weight.cpu()),
            'objective':float((total_loss/total_weight).cpu()) + (float(penalty.detach().cpu()) if penalty is not None else 0.),
            'parameterAnchorPenalty':float(penalty.detach().cpu()) if penalty is not None else 0.,
            'unclippedFullGradientNorm':value,'gradientRMS':value/math.sqrt(parameter_count),
            'trainableParameters':parameter_count,'dropoutEnabled':False,
            'gradientClipped':False,'optimizerStepped':False}
    finally:
        model.zero_grad(set_to_none=True)
        for module,mode in modes.items():module.training=mode
        torch.set_rng_state(cpu_rng)
        if device=='mps':torch.mps.set_rng_state(accelerator_rng)
        elif device.startswith('cuda'):torch.cuda.set_rng_state_all(accelerator_rng)


@dataclass
class TrainingPlateauMonitor:
    window: int = 6
    relative_loss_tolerance: float = .005
    absolute_loss_tolerance: float = .001
    gradient_rms_tolerance: float = 1e-4
    history: list = field(default_factory=list)

    def update(self,probe):
        self.history.append({key:probe[key] for key in ('objective','gradientRMS','unclippedFullGradientNorm')})
        self.history=self.history[-self.window:]
        losses=[p['objective'] for p in self.history]
        ready=len(losses)==self.window
        tolerance=max(self.absolute_loss_tolerance,self.relative_loss_tolerance*max(losses))
        stationary=probe['gradientRMS']<=self.gradient_rms_tolerance
        return {'windowChecks':len(losses),'requiredChecks':self.window,
            'objectivePlateau':ready and max(losses)-min(losses)<=tolerance,
            'objectiveWindowRange':max(losses)-min(losses),'objectiveTolerance':tolerance,
            'gradientRMSBelowTolerance':stationary,'gradientRMSTolerance':self.gradient_rms_tolerance,
            'interpretation':'A flat objective and a small gradient are separate diagnostics; neither alone proves a stochastic or global optimum.'}
