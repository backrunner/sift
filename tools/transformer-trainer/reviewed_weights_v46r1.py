"""Keep the frozen v46 training objective out of ordinary validation collation."""
from reviewed_weights import build_spec, validate, row_weight, identity


def install(path, enabled):
    import train_mmbert as train
    from reviewed_weights import install as install_training
    original_collate = train.make_collate
    original_evaluate = train.evaluate_model
    install_training(path, enabled)

    def evaluate(*args, **kwargs):
        training_collate = train.make_collate
        train.make_collate = original_collate
        try:
            return original_evaluate(*args, **kwargs)
        finally:
            train.make_collate = training_collate

    train.evaluate_model = evaluate

    def restore():
        train.make_collate = original_collate
        train.evaluate_model = original_evaluate

    return restore
