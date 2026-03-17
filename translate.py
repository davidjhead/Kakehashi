import re
import pyaudio
import numpy as np
import threading
import queue
import time
import sys
import signal
import argparse

# Line-buffered stdout so the Swift GUI receives output in real time
sys.stdout.reconfigure(line_buffering=True)


def main():
    parser = argparse.ArgumentParser(
        description="Zoom audio → English real-time transcription / translation"
    )
    parser.add_argument(
        "--model",
        default="large-v3-turbo",
        choices=["small", "medium", "large-v3", "large-v3-turbo"],
        help="Whisper model to use (default: large-v3-turbo)",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=0.002,
        help="Silence threshold — chunks quieter than this are skipped (default: 0.002)",
    )
    parser.add_argument(
        "--chunk-size",
        type=int,
        default=4,
        choices=range(2, 9),
        help="Audio chunk size in seconds, 2–8 (default: 4)",
    )
    parser.add_argument(
        "--hf-token",
        default=None,
        help="HuggingFace token for speaker diarization (optional)",
    )
    parser.add_argument(
        "--show-original",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Show original Japanese text below the translation (default: on)",
    )
    args = parser.parse_args()

    _MODEL_MAP = {
        "small":          "mlx-community/whisper-small-mlx",
        "medium":         "mlx-community/whisper-medium-mlx",
        "large-v3":       "mlx-community/whisper-large-v3-mlx",
        "large-v3-turbo": "mlx-community/whisper-large-v3-turbo",
    }
    model_repo = _MODEL_MAP[args.model]

    print(f"Loading model: {args.model} …")
    import mlx_whisper

    # Warm up — downloads model on first run, loads from cache thereafter
    mlx_whisper.transcribe(
        np.zeros(16000, dtype=np.float32),
        path_or_hf_repo=model_repo,
        verbose=False,
    )

    print(f"Model ready.  threshold={args.threshold}  chunk={args.chunk_size}s")

    # ── Translation models (MarianMT, CPU, offline) ───────────────────────────

    import transformers
    transformers.logging.set_verbosity_error()
    from transformers import MarianMTModel, MarianTokenizer

    def _load_mt(model_id: str):
        print(f"Loading translation model ({model_id}) …")
        tok = MarianTokenizer.from_pretrained(model_id)
        mdl = MarianMTModel.from_pretrained(model_id)
        return tok, mdl

    def _translate(text: str, tokenizer, model) -> str:
        if not text:
            return ""
        inputs = tokenizer([text], return_tensors="pt", padding=True,
                           truncation=True, max_length=512)
        ids = model.generate(**inputs)
        return tokenizer.decode(ids[0], skip_special_tokens=True)

    _ja_tok, _ja_mdl = _load_mt("Helsinki-NLP/opus-mt-ja-en")
    _ko_tok, _ko_mdl = _load_mt("Helsinki-NLP/opus-mt-ko-en")
    print("Translation models ready.")

    def _translate_ja(text: str) -> str:
        return _translate(text, _ja_tok, _ja_mdl)

    def _translate_ko(text: str) -> str:
        return _translate(text, _ko_tok, _ko_mdl)

    # ── Speaker tracking (optional) ───────────────────────────────────────────

    _embedding_inference = None
    _known_speakers = []   # list of [label, embedding_ndarray]
    _speaker_threshold = [0.65]  # list so nested functions can mutate it

    if args.hf_token:
        try:
            print("Loading speaker embedding model…")
            import torch
            from pyannote.audio import Model, Inference
            _emb_model = Model.from_pretrained(
                "pyannote/wespeaker-voxceleb-resnet34-LM",
                token=args.hf_token,
            )
            _embedding_inference = Inference(_emb_model, window="whole")
            print("Speaker tracking ready.")
        except Exception as e:
            print(f"Speaker tracking unavailable: {e}")

    def identify_speaker(audio):
        if _embedding_inference is None:
            return None
        import torch
        waveform = torch.from_numpy(audio).unsqueeze(0).float()
        emb = _embedding_inference({"waveform": waveform, "sample_rate": SAMPLE_RATE})
        norm = float(np.linalg.norm(emb))
        if norm == 0:
            return None
        emb = emb / norm

        best_dist = float("inf")
        best_idx = -1
        for i, (_, known_emb) in enumerate(_known_speakers):
            dist = 1.0 - float(np.dot(emb, known_emb))
            if dist < best_dist:
                best_dist = dist
                best_idx = i

        if best_idx >= 0 and best_dist < _speaker_threshold[0]:
            label, old_emb = _known_speakers[best_idx]
            # Exponential moving average keeps the embedding current
            new_emb = old_emb * 0.9 + emb * 0.1
            new_emb /= np.linalg.norm(new_emb)
            _known_speakers[best_idx] = [label, new_emb]
            return label
        else:
            letter = chr(ord("A") + len(_known_speakers))
            label = f"Speaker {letter}"
            _known_speakers.append([label, emb])
            return label

    audio_queue: queue.Queue = queue.Queue()
    SAMPLE_RATE = 16000
    MAX_BACKLOG = 100  # cap memory (~25 MB at 4 s / chunk)

    _silence_threshold = [args.threshold]
    _chunk_frames = [int(SAMPLE_RATE * args.chunk_size)]
    _show_original = [args.show_original]

    # Dropped chunks saved for review after stop: list of (timestamp_str, audio_array)
    dropped_backlog: list = []

    # Set by SIGTERM handler to break the translate loop cleanly
    shutdown_event = threading.Event()

    def handle_sigterm(signum, frame):
        shutdown_event.set()

    signal.signal(signal.SIGTERM, handle_sigterm)

    # ── Stdin command reader (live setting updates from Swift UI) ─────────────

    def stdin_reader():
        for raw in sys.stdin:
            cmd = raw.strip()
            if cmd.startswith("speaker_threshold:"):
                try:
                    _speaker_threshold[0] = float(cmd.split(":", 1)[1])
                except ValueError:
                    pass
            elif cmd.startswith("silence_threshold:"):
                try:
                    _silence_threshold[0] = float(cmd.split(":", 1)[1])
                except ValueError:
                    pass
            elif cmd.startswith("chunk_size:"):
                try:
                    _chunk_frames[0] = int(SAMPLE_RATE * int(cmd.split(":", 1)[1]))
                except ValueError:
                    pass
            elif cmd.startswith("show_original:"):
                _show_original[0] = cmd.split(":", 1)[1].lower() == "true"

    threading.Thread(target=stdin_reader, daemon=True).start()

    # ── Speaker block accumulation state ─────────────────────────────────────
    # Tracks the current open block so same-speaker chunks grow in place.

    _block = {"speaker": None, "ts": "", "en": "", "jp": "", "lang": None}

    # ── Voice activity detection (speech vs music/noise pre-filter) ──────────

    import webrtcvad as _webrtcvad
    _vad = _webrtcvad.Vad(2)  # aggressiveness 0–3; 2 = medium

    def is_speech(audio: np.ndarray) -> bool:
        """Return True if the chunk contains enough speech frames to be worth transcribing."""
        audio_int16 = np.clip(audio * 32767, -32768, 32767).astype(np.int16)
        frame_len = 480  # 30 ms at 16 kHz
        speech, total = 0, 0
        for i in range(0, len(audio_int16) - frame_len + 1, frame_len):
            frame = audio_int16[i:i + frame_len].tobytes()
            try:
                if _vad.is_speech(frame, SAMPLE_RATE):
                    speech += 1
            except Exception:
                pass
            total += 1
        return (speech / total) >= 0.15 if total else True

    _BASE_ARGS = dict(
        verbose=False,
        condition_on_previous_text=False,
        no_speech_threshold=0.6,
    )

    def _run(audio, task="transcribe", language=None):
        """Single mlx-whisper call, returns (text, detected_language)."""
        kwargs = dict(**_BASE_ARGS, path_or_hf_repo=model_repo, task=task)
        if language:
            kwargs["language"] = language
        result = mlx_whisper.transcribe(audio, **kwargs)
        return result.get("text", "").strip(), result.get("language", "")

    _CHARS_PER_LINE = 72   # estimated characters per visual line at default window width
    _MAX_BLOCK_LINES = 8  # force a new block after this many visual lines

    def _emit(tag: str, english: str, kanji, ts: str, speaker, speaker_tag: str, same_speaker: bool):
        """Append to or start a speaker block, then print."""
        block_lang = "en" if tag == "EN" else tag.lower()  # "ja" or "ko"
        # Force a new block when the current one has reached the line limit
        if same_speaker and _block["lang"] == block_lang:
            est_lines = (len(_block["en"]) + _CHARS_PER_LINE - 1) // _CHARS_PER_LINE
            if est_lines >= _MAX_BLOCK_LINES:
                same_speaker = False
        if same_speaker and _block["lang"] == block_lang:
            _block["en"] += " " + english
            if kanji:
                _block["jp"] += " " + kanji
            print("[STATUS] replace_last_block")
            print(f"[{_block['ts']}]{speaker_tag} {tag}: {_block['en'].strip()}")
            if _block["jp"]:
                print(_block["jp"].strip())
        else:
            _block.update(speaker=speaker, ts=ts, en=english, jp=kanji or "", lang=block_lang)
            print(f"[{ts}]{speaker_tag} {tag}: {english}")
            if kanji:
                print(kanji)
        print()

    # ── Shared transcription helper ───────────────────────────────────────────

    def _has_japanese(text: str) -> bool:
        return any(
            '\u3040' <= c <= '\u30ff' or  # hiragana / katakana
            '\u4e00' <= c <= '\u9fff'      # CJK ideographs
            for c in text
        )

    def _has_korean(text: str) -> bool:
        return any(
            '\uac00' <= c <= '\ud7af' or  # hangul syllables
            '\u1100' <= c <= '\u11ff' or  # hangul jamo
            '\u3130' <= c <= '\u318f'      # hangul compatibility jamo
            for c in text
        )

    # Common Whisper sound-effect hallucinations to strip from output
    _HALLUCINATION_TOKENS = re.compile(
        r'[\(\[]('
        r'Laughter|Applause|Music|Silence|Noise|Crowd|Cheering|Clapping|'
        r'Background noise|Inaudible|Crosstalk|Indistinct|Static|Beep|'
        r'♪[^♪]*♪|♫[^♫]*♫'
        r')[\)\]]',
        re.IGNORECASE
    )

    def _clean(text: str) -> str:
        """Strip hallucinated sound-effect tokens and tidy whitespace."""
        return re.sub(r'\s+', ' ', _HALLUCINATION_TOKENS.sub('', text)).strip()

    def _is_hallucination(text: str) -> bool:
        """Detect Whisper repetition hallucinations (e.g. 'come come come...')."""
        words = text.split()
        if len(words) < 8:
            return False
        for n in range(2, 5):  # check 2-, 3-, 4-word phrases
            for i in range(len(words) - n):
                phrase = " ".join(words[i:i + n])
                if text.count(phrase) >= 6:
                    return True
        return False

    def transcribe_and_print(audio: np.ndarray, ts: str) -> None:
        """Auto-detect language and always output English."""
        if not is_speech(audio):
            return

        speaker = identify_speaker(audio)
        speaker_tag = f" [{speaker}]" if speaker else ""
        same_speaker = speaker is not None and speaker == _block["speaker"]
        show_orig = _show_original[0]

        # Transcribe to detect language and get source text
        transcript, detected = _run(audio, task="transcribe")
        transcript = _clean(transcript)
        if not transcript or _is_hallucination(transcript):
            return

        is_japanese = (
            detected.startswith("ja")
            or "japanese" in detected.lower()
            or _has_japanese(transcript)
        )
        is_korean = (
            detected.startswith("ko")
            or "korean" in detected.lower()
            or _has_korean(transcript)
        )

        if is_japanese:
            orig = transcript if show_orig else None
            english = _clean(_translate_ja(transcript))
            if not english:
                return
            _emit("JP", english, orig, ts, speaker, speaker_tag, same_speaker)
        elif is_korean:
            orig = transcript if show_orig else None
            english = _clean(_translate_ko(transcript))
            if not english:
                return
            _emit("KO", english, orig, ts, speaker, speaker_tag, same_speaker)
        else:
            _emit("EN", transcript, None, ts, speaker, speaker_tag, same_speaker)

    # ── Audio device detection ────────────────────────────────────────────────

    def find_audio_device():
        p = pyaudio.PyAudio()
        PREFER = ["BlackHole", "ZoomAudioDevice", "Loopback"]

        devices = [
            (i, p.get_device_info_by_index(i)["name"])
            for i in range(p.get_device_count())
            if p.get_device_info_by_index(i)["maxInputChannels"] > 0
        ]

        def priority(item):
            name = item[1]
            for rank, keyword in enumerate(PREFER):
                if keyword in name:
                    return rank
            return 99

        devices.sort(key=priority)

        if not devices:
            print("No audio input devices found")
            print("[STATUS] blackhole:not_found")
            p.terminate()
            raise SystemExit(1)

        idx, name = devices[0]
        print(f"Audio source: {name} (index {idx})")
        print("[STATUS] blackhole:detected")
        return idx, p

    # ── Audio capture ─────────────────────────────────────────────────────────

    def audio_capture(device_index, pa):
        device_name = pa.get_device_info_by_index(device_index)["name"]
        stream = pa.open(
            format=pyaudio.paFloat32,
            channels=1,
            rate=SAMPLE_RATE,
            input=True,
            input_device_index=device_index,
            frames_per_buffer=1024,
        )
        print(f"Capturing audio via {device_name} …")
        print("[STATUS] audio:flowing")
        buffer = []
        level_buf = []
        LEVEL_INTERVAL = int(SAMPLE_RATE * 0.5)   # emit level every 0.5 s
        while not shutdown_event.is_set():
            data = stream.read(1024, exception_on_overflow=False)
            chunk = np.frombuffer(data, dtype=np.float32)
            buffer.append(chunk)
            level_buf.append(chunk)
            if sum(len(b) for b in level_buf) >= LEVEL_INTERVAL:
                level = float(np.abs(np.concatenate(level_buf)).mean())
                print(f"[STATUS] level:{level:.6f}")
                level_buf = []
            if sum(len(b) for b in buffer) >= _chunk_frames[0]:
                audio_queue.put(np.concatenate(buffer))
                buffer = []

    # ── Live translation loop ─────────────────────────────────────────────────

    def translate_loop():
        print("Ready. Listening …")
        while not shutdown_event.is_set():
            try:
                # Use a timeout so we re-check shutdown_event regularly
                audio = audio_queue.get(timeout=0.5)
            except queue.Empty:
                continue

            # Drain backlog — save dropped chunks for later review
            dropped = 0
            capture_ts = time.strftime("%H:%M:%S")
            while not audio_queue.empty():
                try:
                    old_audio = audio_queue.get_nowait()
                    if len(dropped_backlog) < MAX_BACKLOG:
                        dropped_backlog.append((capture_ts, old_audio))
                    dropped += 1
                except queue.Empty:
                    break
            if dropped:
                print(f"[STATUS] dropping:{dropped}")

            if np.abs(audio).mean() < _silence_threshold[0]:
                continue

            transcribe_and_print(audio, time.strftime("%H:%M:%S"))

    # ── Backlog review (runs after stop) ──────────────────────────────────────

    def process_backlog():
        if not dropped_backlog:
            return

        # Sort by captured timestamp string (HH:MM:SS lexicographic = chronological)
        dropped_backlog.sort(key=lambda x: x[0])

        print(f"[STATUS] processing_backlog:{len(dropped_backlog)}")

        for ts, audio in dropped_backlog:
            if np.abs(audio).mean() < _silence_threshold[0]:
                continue
            transcribe_and_print(audio, ts)

        print("[STATUS] backlog_complete")

    # ── Start ─────────────────────────────────────────────────────────────────

    device_index, pa = find_audio_device()
    capture_thread = threading.Thread(
        target=audio_capture, args=(device_index, pa), daemon=True
    )
    capture_thread.start()
    translate_loop()

    # translate_loop exits when shutdown_event is set (SIGTERM received)
    process_backlog()


if __name__ == "__main__":
    main()
