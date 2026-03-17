# Kakehashi — Setup Guide

## Requirements

- **Mac with Apple Silicon** (M1/M2/M3) — MLX requires Apple Silicon for GPU inference
- **macOS 13 Ventura or later**
- **Xcode 15 or later** — for building the Swift app
- **Homebrew** — for installing system dependencies

---

## 1. System Dependencies

### Homebrew
```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### PortAudio (required by PyAudio)
```bash
brew install portaudio
```

### BlackHole 2ch — Virtual Audio Driver
BlackHole routes Zoom's audio output into the app for transcription.

```bash
brew install blackhole-2ch
```

> Alternatively download directly from https://existential.audio/blackhole/

**After installing BlackHole, configure macOS Audio:**
1. Open **Audio MIDI Setup** (in /Applications/Utilities/)
2. Click **+** → **Create Multi-Output Device**
3. Check both **BlackHole 2ch** and your speakers/headphones
4. Set this Multi-Output Device as your system output in **System Settings → Sound**
5. In **Zoom → Settings → Audio**, set the speaker output to the same Multi-Output Device

This lets you hear audio normally while BlackHole captures it for transcription.

---

## 2. Python Environment

### Install Python 3.11
```bash
brew install python@3.11
```

### Create a virtual environment in the project directory
```bash
cd ~/kakehashi
python3.11 -m venv .
```

### Install Python dependencies
```bash
bin/pip install --upgrade pip

# Core audio & transcription
bin/pip install pyaudio mlx-whisper webrtcvad

# Japanese → English translation
bin/pip install transformers sentencepiece sacremoses

# Speaker diarization (optional — requires HuggingFace token)
bin/pip install pyannote.audio torch
```

### Fix webrtcvad compatibility
The bundled `webrtcvad.py` wrapper uses a deprecated `pkg_resources` import. Patch it:

```bash
SITE=$(bin/python -c "import site; print(site.getsitepackages()[0])")
sed -i '' 's/import pkg_resources//' "$SITE/webrtcvad.py"
sed -i '' "s/__version__ = pkg_resources.get_distribution('webrtcvad').version/__version__ = \"2.0.10\"/" "$SITE/webrtcvad.py"
```

---

## 3. Model Downloads

Models are downloaded automatically on first run and cached in `~/.cache/huggingface/`.

| Model | Size | Purpose |
|-------|------|---------|
| `mlx-community/whisper-large-v3-turbo` | ~1.6 GB | Speech transcription (default) |
| `Helsinki-NLP/opus-mt-ja-en` | ~300 MB | Japanese → English translation |
| `pyannote/wespeaker-voxceleb-resnet34-LM` | ~200 MB | Speaker diarization (optional) |

Other available transcription models (set in the app's Model picker):

| Model | Size | Speed |
|-------|------|-------|
| `whisper-small-mlx` | ~150 MB | Fastest |
| `whisper-medium-mlx` | ~500 MB | Fast |
| `whisper-large-v3-mlx` | ~3 GB | Slower, most accurate |
| `whisper-large-v3-turbo` | ~1.6 GB | **Recommended** |

---

## 4. HuggingFace Token (Optional — Speaker Diarization)

Speaker diarization identifies who is speaking (Speaker A, Speaker B, etc.).

1. Create a free account at https://huggingface.co
2. Go to **Settings → Access Tokens** and create a token with read access
3. Accept the model license at https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM
4. Paste the token into the **HF Token** field in the app before starting

---

## 5. Build & Run the App

```bash
cd ~/kakehashi/ZoomTranslateApp
open ZoomTranslateApp.xcodeproj
```

- Select the **ZoomTranslateApp** scheme
- Press **⌘R** to build and run
- Click **Start** in the app — the first run will download models automatically

---

## Troubleshooting

**No audio source detected**
- Confirm BlackHole 2ch is installed: `system_profiler SPAudioDataType | grep BlackHole`
- Make sure Zoom is playing audio through the Multi-Output Device

**Translation not working**
- Check the app output for "Translation model ready." — first run downloads ~300 MB
- Ensure you have an internet connection on first launch for model downloads

**Python not found / launch error**
- Verify the venv exists: `ls ~/kakehashi/bin/python`
- The app expects Python at `~/kakehashi/bin/python`

**Speaker tracking unavailable**
- Confirm your HF token is entered before clicking Start
- Ensure you accepted the model license on huggingface.co
