# WhisperMLX upgrade experiment

Candidate: `whispermlx==3.14.0` (installed app runtime: 3.12.2). Keep the managed runtime at `~/.local/share/whispermlx-ui/venv` unchanged until end-to-end validation passes. The app resolves this managed environment by default; for a test run set `WHISPERMLX_PYTHON` to an isolated environment's interpreter.

The app's `bin/whispermlx_runtime.py` replaces `transcribe_task` and wraps `load_model`, `load_align_model`, and `align` at runtime. Compared with 3.12.2, the upstream `transcribe.py` in 3.14.0 additionally passes the optional `interleaved_context` argument to `model.transcribe`; the existing hooks and alignment call sites remain in place. Existing five unit tests pass against 3.14.0, and `bin/whispermlx_runtime.py --help` loads successfully. These checks do **not** establish transcription quality or end-to-end compatibility.

Before switching the app runtime: test representative German/English recordings with and without diarization, verify word timestamps and outputs, interrupt alignment and resume with the same settings, and compare memory and runtime with 3.12.2. Run in a separate environment and use separate copies of recordings so checkpoints from the baseline are not overwritten. In particular, check whether the new optional context mode improves names/punctuation before exposing it in the UI; it is off by default.
