import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import sys
import os
import time
import signal
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import numpy as np

spec = importlib.util.spec_from_file_location('runtime', Path(__file__).parents[1] / 'bin/whispermlx_runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class SafeguardsTests(unittest.TestCase):
    def test_timestamps_shared_word_objects_shift_only_once(self):
        word = {'word': 'Grüße', 'start': 0.1, 'end': 0.5}
        result = {'segments': [{'start': 0, 'end': 1, 'words': [word]}], 'word_segments': [word]}
        runtime.shift_times(result, 100)
        self.assertEqual(word['start'], 100.1)
        self.assertEqual(result['segments'][0]['end'], 101)

    def test_blocks_bound_segment_count_and_audio_span(self):
        segments = [{'start': i * 30, 'end': (i + 1) * 30} for i in range(10)]
        blocks = list(runtime.alignment_blocks(segments))
        self.assertEqual([len(b) for b in blocks], [4, 4, 2])
        for block in blocks:
            self.assertLessEqual(block[-1]['end'] - block[0]['start'], 120)
        with self.assertRaises(ValueError):
            list(runtime.alignment_blocks([{'start': 0, 'end': 6000}]))

    def test_failed_worker_preserves_completed_blocks_and_resume_skips_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = []
            segments = [{'start': i, 'end': i + 1, 'text': 'Grüße'} for i in range(6)]
            audio = np.zeros(6 * 16000, dtype=np.float32)
            def worker(path):
                job = json.loads(path.read_text())
                calls.append(job['offset'])
                if len(calls) == 2:
                    raise RuntimeError('simulated killed worker')
                self.assertLessEqual(len(np.load(job['audio'])), 4 * 16000)
                result = {'segments': job['segments'], 'word_segments': []}
                runtime.shift_times(result, job['offset'])
                runtime.atomic_json(job['output'], result)
            with self.assertRaisesRegex(RuntimeError, 'killed worker'):
                runtime.isolated_alignment(segments, audio, {'source': 'A'}, {}, tmp, worker)
            self.assertEqual(len(list(Path(tmp).glob('block-*.json'))), 1)
            result = runtime.isolated_alignment(segments, audio, {'source': 'A'}, {}, tmp, worker)
            self.assertEqual(result['segments'], segments)
            self.assertEqual(calls, [0, 4, 4])
            # Another source must not reuse the checkpoints.
            runtime.isolated_alignment(segments, audio, {'source': 'B'}, {}, tmp, worker)
            self.assertEqual(calls[-2:], [0, 4])

    def test_cancellation_reaps_active_worker(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            worker = tmp / 'worker.py'
            pidfile = tmp / 'pid'
            worker.write_text('import os, time\nfrom pathlib import Path\n'
                              + f'Path({str(pidfile)!r}).write_text(str(os.getpid()))\n'
                              + 'time.sleep(60)\n')
            code = (f'import sys; sys.path.insert(0, {str(Path(runtime.__file__).parent)!r}); '
                    'import whispermlx_runtime as r; '
                    f'r.__file__ = {str(worker)!r}; r.run_worker("unused.json")')
            parent = subprocess.Popen([sys.executable, '-c', code])
            child_pid = None
            try:
                deadline = time.monotonic() + 10
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(pidfile.exists())
                child_pid = int(pidfile.read_text())
                parent.terminate()
                self.assertEqual(parent.wait(timeout=8), -signal.SIGTERM)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait()
                if child_pid:
                    try:
                        os.kill(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_raw_cache_skips_model_loading_and_invalidates_changed_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / 'recording.wav'
            source.write_bytes(b'audio')
            result = {'segments': [{'start': 0, 'end': 1, 'text': 'Grüße'}], 'language': 'de'}
            loads = []
            module = SimpleNamespace(load_model=lambda: loads.append(True) or
                                     SimpleNamespace(transcribe=lambda: result),
                                     load_align_model=lambda: None, align=lambda: None)
            def task(args, parser):
                return module.load_model().transcribe()
            module.transcribe_task = task
            runtime.install_safeguards(module, release=lambda: None)
            args = {'audio': [str(source)], 'output_dir': tmp, 'model': 'test'}
            with patch.object(runtime, 'versions', return_value={'test': '1'}):
                self.assertEqual(module.transcribe_task(dict(args), None), result)
                self.assertEqual(module.transcribe_task(dict(args), None), result)
                self.assertEqual(len(loads), 1)
                source.write_bytes(b'other audio')
                module.transcribe_task(dict(args), None)
                self.assertEqual(len(loads), 2)


if __name__ == '__main__':
    unittest.main()
