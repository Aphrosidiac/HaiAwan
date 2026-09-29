#!/usr/bin/env python3
"""Synthesizes Awan's UI sounds (soft sine / FM blips) into app/Resources/Sounds/*.wav.

Awan's own sounds — nothing sampled from anywhere. Pure standard library, deterministic output.
Run: python3 app/scripts/make-sounds.py
"""
import math
import os
import struct
import wave

RATE = 44100
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Sounds")
PEAK = 10 ** (-10 / 20)  # -10 dBFS: UI sounds sit under speech


def note(name):
    """'A5' → Hz."""
    names = {"C": -9, "C#": -8, "D": -7, "D#": -6, "E": -5, "F": -4, "F#": -3, "G": -2, "G#": -1, "A": 0, "A#": 1, "B": 2}
    pitch, octave = name[:-1], int(name[-1])
    return 440.0 * 2 ** ((names[pitch] + (octave - 4) * 12) / 12)


def env(t, dur, attack=0.004, release=None, curve=5.0):
    """Fast attack, exponential-ish decay to zero at `dur`."""
    if t < attack:
        return t / attack
    if release is None:
        x = (t - attack) / max(1e-6, dur - attack)
        return max(0.0, (1 - x)) ** 1.6 * math.exp(-curve * x * 0.35)
    if t > dur - release:
        return max(0.0, (dur - t) / release)
    return 1.0


def tone(freq, dur, start=0.0, gain=1.0, fm_ratio=0.0, fm_index=0.0, glide_to=None, curve=5.0, attack=0.004, vibrato=0.0):
    """One partial: sine carrier, optional FM modulator, optional pitch glide. Returns (start, samples)."""
    n = int(dur * RATE)
    out = []
    phase = 0.0
    mphase = 0.0
    for i in range(n):
        t = i / RATE
        f = freq if glide_to is None else freq * (glide_to / freq) ** (t / dur)
        if vibrato:
            f *= 1 + vibrato * math.sin(2 * math.pi * 6.0 * t)
        e = env(t, dur, attack=attack, curve=curve)
        mod = 0.0
        if fm_ratio:
            mphase += 2 * math.pi * f * fm_ratio / RATE
            mod = fm_index * e * math.sin(mphase)
        phase += 2 * math.pi * f / RATE
        out.append(gain * e * math.sin(phase + mod))
    return start, out


def mix(parts, tail=0.02):
    length = max(int(s * RATE) + len(x) for s, x in parts) + int(tail * RATE)
    buf = [0.0] * length
    for s, x in parts:
        o = int(s * RATE)
        for i, v in enumerate(x):
            buf[o + i] += v
    peak = max(1e-9, max(abs(v) for v in buf))
    return [v / peak * PEAK for v in buf]


def soft(freq, dur, start=0.0, gain=1.0, **kw):
    """A rounded blip: fundamental + a quiet octave for body."""
    return [tone(freq, dur, start, gain, **kw), tone(freq * 2, dur * 0.7, start, gain * 0.18, **kw)]


def bell(freq, dur, start=0.0, gain=1.0):
    return [tone(freq, dur, start, gain, fm_ratio=3.5, fm_index=1.4, curve=7), tone(freq * 2.01, dur * 0.5, start, gain * 0.12, curve=9)]


SOUNDS = {
    "listen-start": lambda: mix(soft(note("E5"), 0.09, 0, 0.8) + soft(note("A5"), 0.12, 0.055, 1.0)),
    "listen-end": lambda: mix(soft(note("A5"), 0.08, 0, 0.9) + soft(note("E5"), 0.12, 0.05, 0.8)),
    "text-open": lambda: mix([tone(note("C6"), 0.11, 0, 1, fm_ratio=2, fm_index=0.6, curve=8)]),
    "text-send": lambda: mix([tone(note("G5"), 0.09, 0, 1, glide_to=note("D6"), curve=6)] + soft(note("D6"), 0.06, 0.05, 0.4)),
    "text-close": lambda: mix([tone(note("A5"), 0.09, 0, 1, glide_to=note("E5"), curve=7)]),
    "agent-launch": lambda: mix([tone(note("C5"), 0.3, 0, 0.7, glide_to=note("C6"), fm_ratio=1.5, fm_index=0.8, curve=3)] + soft(note("G5"), 0.18, 0.16, 0.6)),
    "agent-done": lambda: mix(bell(note("C6"), 0.45, 0, 0.9) + bell(note("E6"), 0.55, 0.11, 0.8)),
    "agent-needs-you": lambda: mix(soft(note("G5"), 0.12, 0, 0.9) + soft(note("G5"), 0.12, 0.14, 0.7) + soft(note("C6"), 0.2, 0.28, 0.9)),
    "agent-close": lambda: mix([tone(note("E5"), 0.16, 0, 0.9, glide_to=note("B4"), curve=6)]),
    "question": lambda: mix([tone(note("D5"), 0.12, 0, 0.8, curve=5)] + [tone(note("A5"), 0.22, 0.1, 1.0, vibrato=0.006, curve=4)]),
    "reveal": lambda: mix(sum((bell(note(n), 0.5, i * 0.07, 0.8 - i * 0.08) for i, n in enumerate(["C5", "E5", "G5", "C6"])), [])),
    "hatch": lambda: mix([tone(220, 0.07, 0, 0.9, glide_to=660, curve=9)] + bell(note("E6"), 0.35, 0.06, 0.5) + bell(note("B6"), 0.3, 0.14, 0.35)),
    "home-reveal": lambda: mix([tone(note(n), 0.75, 0, 0.5, attack=0.12, curve=2.5) for n in ["C4", "G4", "E5"]] + bell(note("G5"), 0.5, 0.18, 0.35)),
    "thumbs-up": lambda: mix(soft(note("E6"), 0.07, 0, 0.9) + soft(note("A6"), 0.1, 0.08, 1.0)),
    "skill-up": lambda: mix(sum((soft(note(n), 0.12, i * 0.075, 0.9) for i, n in enumerate(["C5", "E5", "A5"])), [])),
    "skill-down": lambda: mix(sum((soft(note(n), 0.12, i * 0.075, 0.9) for i, n in enumerate(["A5", "E5", "C5"])), [])),
    "connection": lambda: mix(bell(note("A5"), 0.3, 0, 0.8) + bell(note("E6"), 0.35, 0.09, 0.7)),
}


def write(name, samples):
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, v)) * 32767)) for v in samples))
    return path


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, make in SOUNDS.items():
        s = make()
        print(f"{name:16s} {len(s) / RATE * 1000:5.0f} ms → {os.path.relpath(write(name, s))}")
