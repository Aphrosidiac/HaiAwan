#!/usr/bin/env python3
"""Awan's own tutorial loop (the ♫ toggle): a soft 16-second pad, four chords, seamless.
Writes app/Resources/Sounds/tour-music.m4a (needs numpy + ffmpeg). Run from anywhere:
    python3 app/scripts/make-tour-music.py
"""
import os
import subprocess
import tempfile
import wave

import numpy as np

SR = 44100
BAR = 4.0  # seconds per chord
# Fmaj7 - Am7 - Dm9 - Bbmaj7 (Hz), voiced low and close
CHORDS = [
    [174.61, 220.00, 261.63, 329.63],
    [220.00, 261.63, 329.63, 392.00],
    [146.83, 220.00, 261.63, 329.63],
    [233.08, 293.66, 349.23, 440.00],
]

def pad(freqs, dur):
    t = np.arange(int(SR * dur)) / SR
    out = np.zeros_like(t)
    for i, f in enumerate(freqs):
        detune = 1 + 0.0025 * (i - 1.5)
        tone = np.sin(2 * np.pi * f * detune * t) + 0.25 * np.sin(2 * np.pi * 2 * f * t + i)
        out += tone * (0.9 - 0.1 * i)
    # slow swell in and out inside each bar so chords cross-fade
    env = np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 0.6
    trem = 0.85 + 0.15 * np.sin(2 * np.pi * 0.25 * t)
    return out * env * trem

def pluck(f, start, total):
    y = np.zeros(total)
    n = int(SR * 1.6)
    t = np.arange(n) / SR
    s = (np.sin(2 * np.pi * f * t) + 0.3 * np.sin(2 * np.pi * 2 * f * t)) * np.exp(-t * 3.2)
    i = int(start * SR)
    seg = s[: max(0, min(n, total - i))]
    y[i : i + len(seg)] += seg
    return y

total = int(SR * BAR * len(CHORDS))
mix = np.zeros(total)
for k, ch in enumerate(CHORDS):
    seg = pad(ch, BAR + 1.0)  # 1 s overlap into the next bar
    i = int(k * BAR * SR)
    end = min(total, i + len(seg))
    mix[i:end] += seg[: end - i]
    if i + len(seg) > total:  # wrap the tail to the start for a seamless loop
        rest = seg[end - i :]
        mix[: len(rest)] += rest
    # a few soft high notes over each chord
    for j, beat in enumerate([0.5, 1.75, 2.75]):
        mix += 0.35 * pluck(ch[(j + k) % 4] * 2, k * BAR + beat, total)

mix /= np.max(np.abs(mix)) * 1.25
pcm = (mix * 32767).astype(np.int16)

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = os.path.join(root, 'Resources', 'Sounds', 'tour-music.m4a')
with tempfile.TemporaryDirectory() as d:
    wav_path = os.path.join(d, 'tour.wav')
    with wave.open(wav_path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', wav_path, '-c:a', 'aac', '-b:a', '96k', out], check=True)
print('wrote', out)
