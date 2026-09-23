"""App-owned safeguards around WhisperMLX's CLI; no site-packages edits."""
import copy
import gc
import importlib
import json
import os
from pathlib import Path
import tempfile
import uuid


def is_mps_oom(error):
    message = str(error).lower()
    return 'mps' in message and 'out of memory' in message


def release_gpu_memory():
    import mlx.core as mx
    import torch
    holder = importlib.import_module('mlx_whisper.transcribe').ModelHolder
    mx.synchronize()
    holder.model = None
    holder.model_path = None
    gc.collect()
    mx.clear_cache()
    if torch.backends.mps.is_available():
        torch.mps.empty_cache()


def atomic_json(path, result):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                     delete=False) as file:
        temporary = Path(file.name)
        try:
            json.dump(result, file, ensure_ascii=False, indent=2)
            file.flush()
            os.fsync(file.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def install_safeguards(task_module, release=release_gpu_memory):
    original_task = task_module.transcribe_task
    original_load = task_module.load_model
    original_load_align = task_module.load_align_model
    original_align = task_module.align

    def task(args, parser):
        inputs = iter(args['audio'])
        output = Path(args['output_dir'])
        run_id = uuid.uuid4().hex[:12]
        cpu_alignment = False

        class CheckpointPipeline:
            def __init__(self, pipeline):
                self.pipeline = pipeline

            def transcribe(self, *positional, **keywords):
                result = self.pipeline.transcribe(*positional, **keywords)
                source = Path(next(inputs))
                checkpoint = output / f'{source.stem}.rohtranskript-{run_id}.json'
                atomic_json(checkpoint, result)
                print(f'Rohtranskript gesichert: {checkpoint}', flush=True)
                return result

        def load(*positional, **keywords):
            return CheckpointPipeline(original_load(*positional, **keywords))

        def load_align(language, device, **keywords):
            nonlocal cpu_alignment
            release()
            print('Whisper-Modell und GPU-Caches vor dem Alignment freigegeben.', flush=True)
            target = 'cpu' if cpu_alignment else device
            try:
                return original_load_align(language, target, **keywords)
            except RuntimeError as error:
                if str(target) != 'mps' or not is_mps_oom(error):
                    raise
            # Retry outside the except block so failed GPU tensors are released.
            cpu_alignment = True
            release()
            print('GPU-Speicher voll: Alignment-Modell wird auf der CPU geladen.', flush=True)
            return original_load_align(language, 'cpu', **keywords)

        def align(segments, model, metadata, audio, device, **keywords):
            nonlocal cpu_alignment
            target = 'cpu' if cpu_alignment else device
            try:
                return original_align(copy.deepcopy(segments), model, metadata, audio, target, **keywords)
            except RuntimeError as error:
                if str(target) != 'mps' or not is_mps_oom(error):
                    raise
            cpu_alignment = True
            model.to('cpu')
            release()
            print('GPU-Speicher voll: Alignment wird auf der CPU wiederholt. Das Rohtranskript bleibt erhalten.', flush=True)
            return original_align(copy.deepcopy(segments), model, metadata, audio, 'cpu', **keywords)

        task_module.load_model = load
        task_module.load_align_model = load_align
        task_module.align = align
        try:
            return original_task(args, parser)
        finally:
            task_module.load_model = original_load
            task_module.load_align_model = original_load_align
            task_module.align = original_align

    task_module.transcribe_task = task


if __name__ == '__main__':
    install_safeguards(importlib.import_module('whispermlx.transcribe'))
    from whispermlx.__main__ import cli
    cli()
