"""App-owned checkpoints and bounded alignment workers; no site-packages edits."""
import copy
import gc
import hashlib
import importlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

CACHE_VERSION = 2
SAMPLE_RATE = 16000
BLOCK_SEGMENTS = 4
BLOCK_SECONDS = 120


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
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                     delete=False) as file:
        temporary = Path(file.name)
        try:
            json.dump(result, file, ensure_ascii=False, indent=2, allow_nan=False)
            file.flush()
            os.fsync(file.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    allow_nan=False).encode()).hexdigest()[:24]


def source_identity(path):
    path = Path(path).resolve()
    stat = path.stat()
    return {'path': str(path), 'size': stat.st_size, 'mtime_ns': stat.st_mtime_ns}


def versions():
    from importlib.metadata import version
    return {name: version(name) for name in ('whispermlx', 'torch', 'torchaudio', 'mlx-whisper')}


def read_result(path, aligned=False):
    try:
        value = json.loads(Path(path).read_text())
        if not isinstance(value['segments'], list):
            return None
        if aligned and not isinstance(value['word_segments'], list):
            return None
        return value
    except (OSError, ValueError, KeyError, TypeError):
        return None


def alignment_blocks(segments):
    block = []
    for segment in segments:
        start, end = float(segment['start']), float(segment['end'])
        if not math.isfinite(start + end) or start < 0 or end < start or end - start > 60:
            raise ValueError('Ungültiger oder zu langer Alignment-Abschnitt (maximal 60 Sekunden).')
        if block and (len(block) >= BLOCK_SEGMENTS or end - block[0]['start'] > BLOCK_SECONDS):
            yield block
            block = []
        block.append(segment)
    if block:
        yield block


def shift_times(value, offset, seen=None):
    """Shift segment, word and optional character timestamps, preserving missing times."""
    if seen is None:
        seen = set()
    if isinstance(value, (dict, list)):
        if id(value) in seen:
            return
        seen.add(id(value))
    if isinstance(value, dict):
        for key, item in value.items():
            if key in ('start', 'end') and isinstance(item, (float, int)):
                value[key] = round(item + offset, 6)
            else:
                shift_times(item, offset, seen)
    elif isinstance(value, list):
        for item in value:
            shift_times(item, offset, seen)


def run_worker(job_path):
    environment = os.environ.copy()
    environment.update(OMP_NUM_THREADS='2', OPENBLAS_NUM_THREADS='2',
                       MKL_NUM_THREADS='2', PYTHONUNBUFFERED='1')
    process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                '--alignment-worker', str(job_path)], env=environment)
    previous = signal.getsignal(signal.SIGTERM)
    terminated = False

    def stop_worker():
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()

    def terminate(signum, frame):
        nonlocal terminated
        terminated = True
        # Do not call Popen methods inside a signal handler: wait() may hold
        # its internal lock. Unwind wait() first, then reap the child below.
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    try:
        code = process.wait()
        if code:
            raise RuntimeError(f'Alignment-Teilprozess beendet (Code {code}). '
                               'Rohtranskript und fertige Blöcke bleiben gespeichert; erneut starten zum Fortsetzen.')
    finally:
        stop_worker()
        signal.signal(signal.SIGTERM, previous)
        if terminated:
            signal.signal(signal.SIGTERM, signal.SIG_DFL)
            os.kill(os.getpid(), signal.SIGTERM)


def isolated_alignment(segments, audio, config, options, cache, worker=run_worker):
    import numpy as np
    if isinstance(audio, str):
        from whispermlx.audio import load_audio
        audio = load_audio(audio)
    audio = np.asarray(audio).reshape(-1)
    blocks = list(alignment_blocks(segments))
    combined = {'segments': [], 'word_segments': []}
    for index, block in enumerate(blocks):
        # Key includes audio identity, ASR content, model/options and runtime versions.
        key = digest({'v': CACHE_VERSION, 'block': block, 'config': config, 'options': options})
        result_path = Path(cache) / f'block-{key}.json'
        result = read_result(result_path, aligned=True)
        if result is None:
            print(f'Alignment: Block {index + 1}/{len(blocks)} – separater CPU-Prozess', flush=True)
            first = max(0, math.floor(min(s['start'] for s in block) * SAMPLE_RATE))
            last = min(len(audio), math.ceil(max(s['end'] for s in block) * SAMPLE_RATE))
            if first >= last:
                raise ValueError('Alignment-Abschnitt liegt außerhalb der Aufnahme.')
            offset = first / SAMPLE_RATE
            local = copy.deepcopy(block)
            shift_times(local, -offset)
            with tempfile.TemporaryDirectory(prefix='whispermlx-align-') as directory:
                directory = Path(directory)
                np.save(directory / 'audio.npy', audio[first:last])
                job = {'segments': local, 'audio': str(directory / 'audio.npy'),
                       'offset': offset, 'config': config, 'options': options,
                       'output': str(result_path.resolve())}
                atomic_json(directory / 'job.json', job)
                worker(directory / 'job.json')
            result = read_result(result_path, aligned=True)
            if result is None:
                raise RuntimeError('Alignment-Teilprozess lieferte kein gültiges Ergebnis.')
        else:
            print(f'Alignment: Block {index + 1}/{len(blocks)} aus Zwischenspeicher übernommen.', flush=True)
        combined['segments'].extend(result['segments'])
        combined['word_segments'].extend(result['word_segments'])
    return combined


def alignment_worker(job_path):
    import numpy as np
    import resource
    import torch
    from whispermlx.alignment import align, load_align_model
    torch.set_num_threads(2)
    torch.set_num_interop_threads(1)
    job = json.loads(Path(job_path).read_text())
    config = job['config']
    model, metadata = load_align_model(config['language'], 'cpu', **config['loader'])
    model.eval()
    with torch.inference_mode():
        result = align(job['segments'], model, metadata,
                       np.load(job['audio']), 'cpu', **job['options'])
    shift_times(result, job['offset'])
    atomic_json(job['output'], result)
    print(f'Alignment-Block gesichert; Spitzen-RAM des Teilprozesses: '
          f'{resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1024 ** 2):.0f} MiB', flush=True)


def install_safeguards(task_module, release=release_gpu_memory, resume_path=None):
    original_task = task_module.transcribe_task
    original_load = task_module.load_model
    original_load_align = task_module.load_align_model
    original_align = task_module.align

    def task(args, parser):
        paths = list(args['audio'])
        identities = [source_identity(path) for path in paths]
        output = Path(args['output_dir'])
        runtime_versions = versions()
        # Conservative cache: changed settings invalidate ASR reuse; never persist tokens.
        settings = {k: v for k, v in args.items()
                    if k not in ('audio', 'output_dir', 'hf_token')}
        keys = [digest({'source': identity, 'settings': settings, 'versions': runtime_versions})
                for identity in identities]
        raw_paths = [output / f'{Path(path).stem}.rohtranskript-{key}.json'
                     for path, key in zip(paths, keys)]
        raw_results = [read_result(path) for path in raw_paths]
        if resume_path:
            if len(paths) != 1:
                raise ValueError('--resume-transcript unterstützt genau eine Aufnahme.')
            raw_results[0] = read_result(resume_path)
            if raw_results[0] is None:
                raise ValueError('Das gewählte Rohtranskript ist ungültig.')
        input_index = 0
        input_sources = {}

        class CheckpointPipeline:
            def __init__(self, positional, keywords):
                self.pipeline = None
                self.positional, self.keywords = positional, keywords

            def transcribe(self, *positional, **keywords):
                nonlocal input_index
                index = input_index
                input_index += 1
                result = raw_results[index]
                if result is None:
                    if self.pipeline is None:
                        self.pipeline = original_load(*self.positional, **self.keywords)
                    result = self.pipeline.transcribe(*positional, **keywords)
                else:
                    print('Gesichertes Rohtranskript übernommen; Spracherkennung wird übersprungen.', flush=True)
                atomic_json(raw_paths[index], result)
                print(f'Rohtranskript gesichert: {raw_paths[index]}', flush=True)
                copied = copy.deepcopy(result)
                input_sources[id(copied["segments"])] = identities[index]
                return copied

        def load(*positional, **keywords):
            return CheckpointPipeline(positional, keywords)

        def load_align(language, device, **keywords):
            release()
            print('GPU-Speicher freigegeben. Alignment läuft blockweise in separaten CPU-Prozessen.', flush=True)
            return {'language': language, 'loader': keywords, 'versions': runtime_versions}, {'language': language}

        def align(segments, config, metadata, audio, device, **keywords):
            identity = input_sources[id(segments)]
            config = dict(config, source=identity)
            cache = output / '.alignment-cache'
            return isolated_alignment(segments, audio, config, keywords, cache)

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
    if len(sys.argv) == 3 and sys.argv[1] == '--alignment-worker':
        alignment_worker(sys.argv[2])
    else:
        resume_path = None
        if '--resume-transcript' in sys.argv:
            index = sys.argv.index('--resume-transcript')
            if index + 1 >= len(sys.argv):
                raise SystemExit('--resume-transcript benötigt den Pfad zum Rohtranskript.')
            resume_path = sys.argv[index + 1]
            del sys.argv[index:index + 2]
        install_safeguards(importlib.import_module('whispermlx.transcribe'), resume_path=resume_path)
        from whispermlx.__main__ import cli
        cli()
