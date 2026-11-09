"""Scene-local supervised contrastive loss with complete-family minibatches.

No added inference parameters. Only reviewed scene members participate; unrelated
messages (including unrelated spam types) are never forced into one cluster.
"""
import hashlib
import json
import math


def text_hash(text):
    return hashlib.sha256(text.encode()).hexdigest()


def load_groups(rows, path):
    spec=json.loads(path.read_text())
    if spec.get('kind')!='reviewed-scene-contrastive-groups':raise ValueError('unsupported scene specification')
    positions={text_hash(r['text']):i for i,r in enumerate(rows)}
    if len(positions)!=len(rows):raise ValueError('duplicate scene corpus text')
    groups=[];seen=set();mapping={}
    for number,group in enumerate(spec['groups']):
        members=group['members'];indices=[];labels={}
        for item in members:
            key=item['textSHA256']
            if key in seen or key not in positions:raise ValueError('missing or repeated scene member')
            i=positions[key]
            if rows[i]['label']!=item['label']:raise ValueError('scene gold mismatch')
            seen.add(key);indices.append(i);mapping[key]=number
            labels[item['label']]=labels.get(item['label'],0)+1
        if len(labels)<2 or min(labels.values())<2:raise ValueError('each scene needs repeated positives and negatives')
        groups.append(indices)
    return groups,mapping


class SceneBatchSampler:
    """Visit each root once, keep each scene whole, retain ceil(N/batch) batches."""
    def __init__(self,count,batch_size,groups,generator,shuffle=True):
        self.count,self.batch_size,self.groups,self.generator,self.shuffle=count,batch_size,groups,generator,shuffle
        flat=[i for g in groups for i in g]
        if count<1 or batch_size<1 or len(set(flat))!=len(flat) or any(i<0 or i>=count for i in flat):
            raise ValueError('invalid scene partition')
        if any(not g or len(g)>batch_size for g in groups):raise ValueError('scene exceeds minibatch')
        self.singles=[i for i in range(count) if i not in set(flat)]

    def __len__(self):return math.ceil(self.count/self.batch_size)

    def __iter__(self):
        import torch
        def perm(items):
            return [items[i] for i in torch.randperm(len(items),generator=self.generator).tolist()] if self.shuffle else list(items)
        capacities=[self.batch_size]*len(self)
        capacities[-1]=self.count-self.batch_size*(len(self)-1)
        bins=[[] for _ in capacities];order=perm(list(range(len(self))))
        for group in perm(self.groups):
            available=[i for i in order if capacities[i]>=len(group)]
            if not available:raise ValueError('scene groups cannot fit fixed batch capacity')
            chosen=max(available,key=lambda i:capacities[i])
            bins[chosen].extend(group);capacities[chosen]-=len(group)
        singles=perm(self.singles);offset=0
        for i in order:
            bins[i].extend(singles[offset:offset+capacities[i]]);offset+=capacities[i]
        if offset!=len(singles):raise ValueError('scene sampler lost roots')
        for i in order:yield perm(bins[i])


def make_plan(rows,collate,arguments,generator,shuffle=True):
    import torch
    groups,mapping=load_groups(rows,arguments.scene_contrastive_spec)
    def scene_collate(batch):
        encoded=collate(batch)
        encoded['scene_group']=torch.tensor([mapping.get(text_hash(r['text']),-1) for r in batch],dtype=torch.long)
        return encoded
    sampler=SceneBatchSampler(len(rows),arguments.batch_size,groups,generator,shuffle)
    return scene_collate,sampler,{'groups':len(groups),'pairedRows':sum(map(len,groups)),
        'specSHA256':hashlib.sha256(arguments.scene_contrastive_spec.read_bytes()).hexdigest(),
        'weight':arguments.scene_contrastive_weight,'temperature':arguments.scene_contrastive_temperature,
        'allRootsOncePerEpoch':True,'groupLocalOnly':True,'inferenceParametersAdded':0}


def forward_features(model,batch,enabled):
    if not enabled:return model(**batch),None
    captured=[]
    handle=model.classifier.register_forward_pre_hook(lambda module,inputs:captured.append(inputs[0]))
    try:output=model(**batch)
    finally:handle.remove()
    if len(captured)!=1 or captured[0].ndim!=2:raise ValueError('expected one pooled classifier input')
    return output,captured[0]


def scene_loss(features,labels,groups,temperature):
    import torch
    import torch.nn.functional as F
    if not math.isfinite(temperature) or temperature<=0:raise ValueError('invalid contrastive temperature')
    if features.ndim!=2 or len(labels)!=len(features) or groups.shape!=labels.shape:raise ValueError('scene tensor shape mismatch')
    z=F.normalize(features.float(),dim=1)
    logits=z@z.T/temperature
    diagonal=torch.eye(len(labels),dtype=torch.bool,device=labels.device)
    same=(groups[:,None]==groups[None,:])&(groups[:,None]>=0)&~diagonal
    positive=same&(labels[:,None]==labels[None,:])
    count=positive.sum(1)
    logden=torch.logsumexp(logits.masked_fill(~same,-1e4),dim=1)
    result=-((logits-logden[:,None])*positive).sum(1)/count.clamp_min(1)
    return torch.where(count>0,result,torch.zeros_like(result))
