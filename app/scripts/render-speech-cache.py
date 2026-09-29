#!/usr/bin/env python3
"""Pre-renders Awan's fixed spoken lines (voice previews, onboarding, stock replies) into
app/Resources/SpeechCache/<sha256(voice|speed|text)>.pcm — the same key SpeechCache.swift computes —
so they play instantly with the good voice, signed out or offline. Needs the Awan server running."""
import hashlib, json, os, sys, urllib.request

API = os.environ.get("AWAN_API", "http://127.0.0.1:8787")
TOKEN = os.environ.get("AWAN_TOKEN", "")
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "SpeechCache")
VOICES = ["cedar", "marin", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"]

jobs = []
for v in VOICES:                                    # Settings → Voice preview
    jobs.append((v, "Hi, I'm Awan. This is how I sound."))
jobs += [                                           # onboarding intro voice cards
    ("cedar", "hi, i'm awan. i'll keep you company while you work."),
    ("marin", "hey! i'm awan. show me what you're making."),
    ("verse", "hello! i'm awan, and i'm ready when you are."),
]
default_lines = [                                   # spoken in the default voice
    "can you hear me? if you can, we're good to go.",
    "see? i can fly over and point at things on your screen.",
    "so, i'm awan. i'm here to help you start a business, ship that side project, or just get through the job. four quick questions. what are you working on these days?",
    "What would you like to change about it?",
    "What would you like this new Awan to do?",
    "i'm out of juice for this month. upgrade and i'm all yours again.",
    "okay, stopping the walkthrough.",
    "always-on voice is on. talk whenever, no keys needed.",
    "always-on voice is off.",
    "heads up, always-on works best with headphones, so i don't hear myself talking.",
]
jobs += [("cedar", l) for l in default_lines]

def trim(pcm, thresh=500, pad=4800):
    """Drop leading/trailing silence (16-bit mono), keep 0.1 s of air at each end."""
    import struct
    n = len(pcm) // 2
    s = struct.unpack(f"<{n}h", pcm[: n * 2])
    first = next((i for i, v in enumerate(s) if abs(v) > thresh), 0)
    last = next((i for i in range(n - 1, -1, -1) if abs(s[i]) > thresh), n - 1)
    a, b = max(0, first - pad // 2), min(n, last + pad // 2)
    return pcm[a * 2 : b * 2]

os.makedirs(OUT, exist_ok=True)
for voice, text in jobs:
    key = hashlib.sha256(f"{voice}|1.00|{text}".encode()).hexdigest()
    path = os.path.join(OUT, key + ".pcm")
    if os.path.exists(path) and os.path.getsize(path) > 4800:
        continue
    req = urllib.request.Request(f"{API}/v1/speech", data=json.dumps({"text": text, "voice": voice, "speed": 1}).encode(),
                                 headers={"Content-Type": "application/json", **({"Authorization": f"Bearer {TOKEN}"} if TOKEN else {})})
    pcm = trim(urllib.request.urlopen(req, timeout=120).read())
    if len(pcm) < 4800:
        print("FAILED", voice, text); continue
    open(path, "wb").write(pcm)
    print(f"{voice:8} {len(pcm)/48000:4.1f}s  {text[:60]}")
