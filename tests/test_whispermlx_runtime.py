import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location('runtime', Path(__file__).parents[1] / 'bin/whispermlx_runtime.py')
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class SafeguardsTests(unittest.TestCase):
    def run_pipeline(self, *, load_failure=False, alignment_error='MPS backend out of memory'):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        output = Path(temporary.name)
        result = {'segments': [{'start': 0, 'end': 1, 'text': 'Grüße'}], 'language': 'de'}
        calls = []
        model = SimpleNamespace(to=lambda device: calls.append(('move', device)))

        def load_align(language, device, **kwargs):
            calls.append(('load', device))
            if load_failure and device == 'mps':
                raise RuntimeError('MPS backend out of memory')
            return model, {}

        def align(segments, model, metadata, audio, device, **kwargs):
            calls.append(('align', device))
            if device == 'mps':
                segments[0]['text'] = 'partially mutated'
                raise RuntimeError(alignment_error)
            self.assertEqual(segments[0]['text'], 'Grüße')
            return {'segments': segments}

        module = SimpleNamespace(load_model=lambda: SimpleNamespace(transcribe=lambda: result),
                                 load_align_model=load_align, align=align)
        def task(args, parser):
            raw = module.load_model().transcribe()
            self.assertEqual(json.loads(next(output.glob('*.json')).read_text()), raw)
            loaded, metadata = module.load_align_model('de', 'mps')
            return module.align(raw['segments'], loaded, metadata, None, 'mps')
        module.transcribe_task = task
        runtime.install_safeguards(module, release=lambda: calls.append(('release', None)))
        try:
            module.transcribe_task({'audio': ['Aufnahme.m4a'], 'output_dir': str(output)}, None)
        finally:
            self.assertIs(module.align, align)
            self.assertEqual(json.loads(next(output.glob('*.json')).read_text()), result)
        return calls

    def test_alignment_oom_retries_on_cpu_with_unmodified_segments(self):
        calls = self.run_pipeline()
        self.assertIn(('move', 'cpu'), calls)
        self.assertEqual([c for c in calls if c[0] == 'align'], [('align', 'mps'), ('align', 'cpu')])

    def test_model_loading_oom_retries_on_cpu(self):
        calls = self.run_pipeline(load_failure=True)
        self.assertEqual([c for c in calls if c[0] == 'load'], [('load', 'mps'), ('load', 'cpu')])

    def test_unrelated_errors_propagate_and_checkpoint_survives(self):
        with self.assertRaisesRegex(RuntimeError, 'invalid data'):
            self.run_pipeline(alignment_error='invalid data')


if __name__ == '__main__':
    unittest.main()
