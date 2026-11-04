"""Balance whole optimizer windows while preserving every shuffled training row."""
import math


def window_plan(rows, microbatch_size, accumulation):
    if min(rows, microbatch_size, accumulation) < 1:
        raise ValueError('positive row/batch/accumulation counts required')
    updates = math.ceil(rows / (microbatch_size * accumulation))
    base, extra = divmod(rows, updates)
    if base < accumulation:
        raise ValueError('too few rows for nonempty balanced accumulation windows')
    windows = [base + (i < extra) for i in range(updates)]
    microbatches = []
    for count in windows:
        q, r = divmod(count, accumulation)
        microbatches.extend(q + (i < r) for i in range(accumulation))
    assert sum(microbatches) == rows and max(microbatches) <= microbatch_size
    return {'rows': rows, 'targetEffectiveBatch': microbatch_size * accumulation,
        'updatesPerEpoch': updates, 'accumulation': accumulation,
        'windowRows': windows, 'microbatchRows': microbatches,
        'rowsDropped': 0, 'rowsRepeated': 0, 'rowPermutationUnchanged': True}


class BalancedAccumulationBatchSampler:
    def __init__(self, sampler, microbatch_size, accumulation):
        self.sampler = sampler
        self.plan = window_plan(len(sampler), microbatch_size, accumulation)

    def __len__(self): return len(self.plan['microbatchRows'])

    def __iter__(self):
        # Use the original RandomSampler, including its RNG consumption at the
        # end of an epoch. No new shuffle or sample replication is introduced.
        order = list(iter(self.sampler))
        if sorted(order) != list(range(self.plan['rows'])):
            raise ValueError('balanced windows require one full permutation')
        offset = 0
        for count in self.plan['microbatchRows']:
            yield order[offset:offset + count]
            offset += count
        assert offset == len(order)


def install(*, expected_rows, microbatch_size, accumulation):
    import torch.utils.data as data
    from torch.utils.data import RandomSampler
    original = data.DataLoader; audits = []

    class Loader(original):
        def __init__(self, dataset, **kwargs):
            if not kwargs.get('shuffle', False):
                super().__init__(dataset, **kwargs)
                return
            if (len(dataset) != expected_rows or kwargs.get('batch_size') != microbatch_size
                    or kwargs.get('sampler') is not None or kwargs.get('drop_last', False)
                    or kwargs.get('batch_sampler') is not None or kwargs.get('num_workers', 0) != 0
                    or kwargs.get('generator') is None):
                raise ValueError('balanced training loader contract differs')
            sampler = RandomSampler(dataset, generator=kwargs['generator'])
            balanced = BalancedAccumulationBatchSampler(sampler, microbatch_size, accumulation)
            kwargs = {k: v for k, v in kwargs.items() if k not in ('batch_size', 'shuffle', 'sampler', 'drop_last')}
            super().__init__(dataset, batch_sampler=balanced, **kwargs)
            audits.append(balanced.plan)
    data.DataLoader = Loader

    def restore(): data.DataLoader = original
    return restore, audits
