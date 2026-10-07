#!/usr/bin/env python
"""Generate one narration WAV per beat in beats.json with a local TTS backend.

Each beat -> native-rate WAV -> 48 kHz mono 24-bit, loudness-normalised to -18 LUFS
(ffmpeg loudnorm, two-pass linear), leading/trailing silence trimmed to exactly 80 ms.
Writes demo/video/narration/<backend>-<voice>/<beat-id>.wav, durations.json {beat_id: seconds}
and timing.json (generation seconds per beat). Same voice and settings as the author's earlier demo (Kokoro-82M af_heart, speed 0.95).
bin/demo runs it for you; by hand, INSIDE the Kokoro venv:

  ~/.cache/vrinda-tts/kokoro/bin/python demo/video/narrate.py --backend kokoro --voice af_heart --speed 0.95

Add --only <beat-id> to regenerate one beat. Sentences are synthesised separately and joined
with a 250 ms gap (same rule as the audition). Voices are the models' built-in presets; no
reference audio is ever used. Needs ffmpeg on PATH (or /opt/homebrew/bin) and numpy + soundfile.
"""
import argparse, json, re, shutil, subprocess, sys, time, random
from pathlib import Path
import numpy as np, soundfile as sf

HERE = Path(__file__).resolve().parent
FFMPEG = shutil.which("ffmpeg") or ("/opt/homebrew/bin/ffmpeg" if Path("/opt/homebrew/bin/ffmpeg").exists() else "ffmpeg")
TARGET_LUFS, EDGE_MS, GAP_S, OUT_SR = -18.0, 80, 0.25, 48000
QWEN_REPO = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit"


def sentences(text):
    return [s for s in re.split(r"(?<=[.!?])\s+", text.strip()) if s]


def make_backend(a):
    """Return (label, say) where say(text) -> (float32 mono samples, sample_rate)."""
    if a.backend == "kokoro":
        from kokoro import KPipeline
        import torch
        voice = a.voice or "af_heart"
        pipe = KPipeline(lang_code=voice[0], repo_id="hexgrad/Kokoro-82M", device="cpu")
        def say(t):
            torch.manual_seed(a.seed)
            return np.concatenate([x.numpy() for _, _, x in pipe(t, voice=voice, speed=a.speed)]), 24000
        return voice if a.speed == 1.0 else f"{voice}-speed{a.speed}", say
    if a.backend == "chatterbox":
        import torch
        from chatterbox.tts import ChatterboxTTS
        device = a.device or ("mps" if torch.backends.mps.is_available() else "cpu")
        model = ChatterboxTTS.from_pretrained(device=device)  # built-in default voice (conds.pt); no audio prompt
        def say(t):
            random.seed(a.seed); np.random.seed(a.seed); torch.manual_seed(a.seed)
            if device == "mps": torch.mps.manual_seed(a.seed)
            return model.generate(t, exaggeration=a.exaggeration, cfg_weight=a.cfg).squeeze().cpu().numpy(), model.sr
        return f"default-exa{a.exaggeration}-cfg{a.cfg}-seed{a.seed}", say
    if a.backend == "qwen3":
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model
        voice = a.voice or "aiden"
        model = load_model(QWEN_REPO)
        def say(t):
            mx.random.seed(a.seed)
            parts = [np.array(r.audio, dtype=np.float32).reshape(-1) for r in model.generate(text=t, voice=voice, lang_code="english")]
            return np.concatenate(parts), model.sample_rate
        return voice, say
    sys.exit(f"unknown backend {a.backend}")


def speak(say, text):
    chunks, sr = [], None
    for s in sentences(text):
        y, sr = say(s)
        chunks += [np.zeros(int(GAP_S * sr), np.float32)] * bool(chunks) + [np.asarray(y, np.float32).reshape(-1)]
    return np.concatenate(chunks), sr


def trim(y, sr, floor_db=-50.0, keep_ms=10):
    """Cut leading/trailing samples quieter than floor_db (10 ms RMS frames), keeping keep_ms of margin."""
    n = int(sr * 0.01); f = len(y) // n
    rms = 20 * np.log10(np.sqrt((y[: f * n].reshape(f, n) ** 2).mean(1)) + 1e-12)
    loud = np.where(rms > floor_db)[0]
    if not len(loud): return y
    keep = int(keep_ms / 10)
    return y[max(0, loud[0] - keep) * n : min(f, loud[-1] + 1 + keep) * n]


def ffmpeg_loudnorm(src, dst):
    """Two-pass loudnorm to TARGET_LUFS, linear gain, resampled to 48 kHz mono 24-bit."""
    tgt = f"I={TARGET_LUFS}:TP=-1.5:LRA=11"
    p1 = subprocess.run([FFMPEG, "-hide_banner", "-nostats", "-i", str(src), "-af", f"loudnorm={tgt}:print_format=json", "-f", "null", "-"],
                        capture_output=True, text=True).stderr
    m = json.loads(p1[p1.rfind("{") : p1.rfind("}") + 1])
    af = (f"loudnorm={tgt}:measured_I={m['input_i']}:measured_TP={m['input_tp']}:measured_LRA={m['input_lra']}"
          f":measured_thresh={m['input_thresh']}:offset={m['target_offset']}:linear=true,aresample={OUT_SR}")
    subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", str(src), "-af", af, "-ac", "1", "-ar", str(OUT_SR),
                    "-c:a", "pcm_s24le", str(dst)], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", required=True, choices=["kokoro", "chatterbox", "qwen3"])
    ap.add_argument("--voice"); ap.add_argument("--speed", type=float, default=1.0)
    ap.add_argument("--exaggeration", type=float, default=0.5); ap.add_argument("--cfg", type=float, default=0.5)
    ap.add_argument("--seed", type=int, default=42); ap.add_argument("--device")
    ap.add_argument("--beats", default=str(HERE / "beats.json"))
    ap.add_argument("--out", default=str(HERE / "narration")); ap.add_argument("--only")
    a = ap.parse_args()
    beats = [b for s in json.load(open(a.beats))["segments"] for b in s["beats"] if not a.only or b["id"] == a.only]
    label, say = make_backend(a)
    out = Path(a.out) / f"{a.backend}-{label}"; (out / "raw").mkdir(parents=True, exist_ok=True)
    durs_f, times_f = out / "durations.json", out / "timing.json"
    durs = json.load(open(durs_f)) if a.only and durs_f.exists() else {}
    times = json.load(open(times_f)) if a.only and times_f.exists() else {}
    say("Hello there.")  # warm-up, untimed
    for b in beats:
        t = time.time(); y, sr = speak(say, b["text"]); times[b["id"]] = round(time.time() - t, 2)
        sf.write(out / "raw" / f"{b['id']}.wav", trim(y, sr), sr, subtype="FLOAT")
        ffmpeg_loudnorm(out / "raw" / f"{b['id']}.wav", out / "tmp.wav")
        z, osr = sf.read(out / "tmp.wav", dtype="float64")
        pad = np.zeros(int(osr * EDGE_MS / 1000))
        final = np.concatenate([pad, z, pad])
        sf.write(out / f"{b['id']}.wav", final, osr, subtype="PCM_24")
        durs[b["id"]] = round(len(final) / osr, 3)
        print(f"{b['id']:<20} {durs[b['id']]:7.2f}s audio  {times[b['id']]:7.1f}s to generate", flush=True)
    (out / "tmp.wav").unlink(missing_ok=True)
    json.dump(durs, open(durs_f, "w"), indent=1); json.dump({**times, "_total": round(sum(times.values()), 1)}, open(times_f, "w"), indent=1)
    print(f"{len(durs)} beats, {sum(durs.values()):.1f}s of narration, generated in {sum(times.values()):.0f}s -> {out}")


if __name__ == "__main__":
    main()
