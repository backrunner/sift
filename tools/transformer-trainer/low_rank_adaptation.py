"""Attention-only LoRA that merges back into the unchanged ModernBERT ABI.

Hu et al., https://arxiv.org/abs/2106.09685. This controls adaptation capacity;
it is not a guarantee against forgetting or a claim of a new SOTA method.
"""
import math
import torch
from torch import nn
from torch.nn import functional as F


class LoRALinear(nn.Module):
    def __init__(self,base,rank,alpha,dropout):
        super().__init__()
        if not isinstance(base,nn.Linear) or not 1<=rank<=min(base.in_features,base.out_features):
            raise ValueError('LoRA requires a linear projection and a valid rank')
        if not math.isfinite(alpha) or alpha<=0 or not 0<=dropout<1:
            raise ValueError('invalid LoRA scale or dropout')
        self.base=base.requires_grad_(False)
        self.in_features,self.out_features=base.in_features,base.out_features
        self.rank,self.scale=rank,alpha/rank
        self.lora_A=nn.Parameter(base.weight.new_empty(rank,base.in_features))
        self.lora_B=nn.Parameter(base.weight.new_zeros(base.out_features,rank))
        nn.init.kaiming_uniform_(self.lora_A,a=math.sqrt(5))
        self.dropout=nn.Dropout(dropout)
        self._merged=False

    @property
    def weight(self):return self.base.weight

    @property
    def bias(self):return self.base.bias

    def forward(self,x):
        if self._merged:return self.base(x)
        return self.base(x)+self.scale*F.linear(F.linear(self.dropout(x),self.lora_A),self.lora_B)

    def merged(self):
        if self._merged:return self.base
        if self.training:raise ValueError('merge LoRA only in evaluation mode')
        with torch.no_grad():self.base.weight.add_(self.scale*(self.lora_B@self.lora_A))
        self._merged=True
        return self.base


def install_attention_lora(model,last_layers,rank=4,alpha=8.,dropout=.05):
    encoder=getattr(model,'model',None);layers=getattr(encoder,'layers',None)
    if layers is None or not 1<=last_layers<=len(layers):
        raise ValueError('LoRA requires a valid last-layer count')
    encoder.requires_grad_(False)
    installed=[]
    for index in range(len(layers)-last_layers,len(layers)):
        attention=layers[index].attn
        for name in ('Wqkv','Wo'):
            projection=getattr(attention,name,None)
            setattr(attention,name,LoRALinear(projection,rank,alpha,dropout))
            installed.append(f'model.layers.{index}.attn.{name}')
    return {'rank':rank,'alpha':alpha,'dropout':dropout,'modules':installed,
        'encoderBaseFrozen':True,
        'adapterParameters':sum(p.numel() for n,p in model.named_parameters() if '.lora_' in n),
        'trainableParameters':sum(p.numel() for p in model.parameters() if p.requires_grad)}


def merge_attention_lora(model):
    if model.training:raise ValueError('merge LoRA only in evaluation mode')
    modules=[(name,module) for name,module in model.named_modules() if isinstance(module,LoRALinear)]
    for name,module in modules:
        parent,key=name.rsplit('.',1)
        setattr(model.get_submodule(parent),key,module.merged())
    if any(isinstance(module,LoRALinear) for module in model.modules()):raise RuntimeError('unmerged LoRA module')
    return {'mergedModules':len(modules),'runtimeAdditionalParameters':0}
