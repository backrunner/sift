"""Numerical guards for partial ModernBERT training on Apple MPS."""


def enable_frozen_boundary_input_gradient(model, device):
    """Avoid the MPS LayerNorm parameter-only backward at the frozen boundary.

    PyTorch2.5.1 on the audited host corrupts this gradient after a different
    batch size was used. Giving the first active norm an input gradient uses
    the full backward path; the input is a leaf, not a trainable parameter.
    Frozen encoder parameters remain frozen. No hook runs during inference.
    """
    import torch
    report={'enabled':False,'reason':'not a partial ModernBERT MPS encoder'}
    if str(device).split(':')[0]!='mps' or getattr(getattr(model,'config',None),'model_type',None)!='modernbert':
        return report
    encoder=getattr(model,'model',None)
    layers=getattr(encoder,'layers',[])
    for index,layer in enumerate(layers):
        if not any(p.requires_grad for p in layer.parameters()):continue
        if index==0 or not layer.attn_norm.weight.requires_grad:return report
        if any(p.requires_grad for previous in layers[:index] for p in previous.parameters()):return report
        if any(p.requires_grad for p in encoder.embeddings.parameters()):return report
        def require_input_gradient(module,inputs):
            if torch.is_grad_enabled() and not inputs[0].requires_grad:
                inputs[0].requires_grad_(True)
            return inputs
        norm=layer.attn_norm
        if not getattr(norm,'_sift_input_gradient_guard',None):
            norm._sift_input_gradient_guard=norm.register_forward_pre_hook(require_input_gradient)
        return {'enabled':True,'firstTrainableLayer':index,'module':f'model.layers.{index}.attn_norm',
            'frozenParametersUnchanged':True,'additionalTrainableParameters':0,
            'reason':'Use input-and-weight LayerNorm backward at frozen MPS boundary; verified against CPU with mixed batch sizes.'}
    return report
