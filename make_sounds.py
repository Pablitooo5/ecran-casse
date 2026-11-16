"""Fabrique les bruitages d'Écran Cassé (fichiers .wav), sans aucun fichier externe.
Usage : python3 make_sounds.py <dossier de sortie>"""
import math
import os
import random
import struct
import sys
import wave

SR = 44100
random.seed(7)


def write(path, x, level=0.9):
    peak = max(1e-9, max(abs(v) for v in x))
    g = level / peak
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1.0, min(1.0, v * g)) * 32767)) for v in x))


def lowpass(x, fc):
    a = 1 - math.exp(-2 * math.pi * fc / SR)
    y, out = 0.0, []
    for v in x:
        y += a * (v - y)
        out.append(y)
    return out


def highpass(x, fc):
    return [a - b for a, b in zip(x, lowpass(x, fc))]


def noise(n, sparse=False):
    if sparse:
        return [(random.uniform(-1, 1) if random.random() < 0.06 else random.uniform(-0.12, 0.12)) for _ in range(n)]
    return [random.uniform(-1, 1) for _ in range(n)]


def mix(*tracks):
    n = max(len(t) for t in tracks)
    return [sum(t[i] if i < len(t) else 0.0 for t in tracks) for i in range(n)]


def sweep_tone(dur, f_start, f_end, tau_f, tau_a, amp=1.0):
    n, ph, out = int(SR * dur), 0.0, []
    for i in range(n):
        t = i / SR
        f = f_end + (f_start - f_end) * math.exp(-t / tau_f)
        ph += 2 * math.pi * f / SR
        out.append(amp * math.sin(ph) * math.exp(-t / tau_a))
    return out


def decay(x, tau, start=0.0):
    return [v * (math.exp(-((i / SR) - start) / tau) if i / SR >= start else 0.0) for i, v in enumerate(x)]


def punch():
    n = int(SR * 0.32)
    body = sweep_tone(0.32, 150, 38, 0.06, 0.09)
    hit = [v * 0.7 for v in decay(lowpass(noise(n), 900), 0.02)]
    return mix(body, hit)


def knock():
    out = [0.0] * int(SR * 0.42)
    for start in (0.0, 0.17):
        s = int(start * SR)
        tone = sweep_tone(0.2, 260, 170, 0.03, 0.035)
        click = decay(lowpass(noise(int(SR * 0.2)), 2200), 0.006)
        for i, v in enumerate(mix(tone, [c * 0.8 for c in click])):
            if s + i < len(out):
                out[s + i] += v
    return out


def crack():
    n = int(SR * 0.4)
    c = decay(highpass(noise(n, sparse=True), 2500), 0.1)
    snap = [v * 0.9 for v in decay(highpass(noise(int(SR * 0.03)), 1500), 0.008)]
    return mix(c, snap)


def whoosh():
    n = int(SR * 0.38)
    x = highpass(lowpass(noise(n), 2600), 350)
    T = n / SR
    return [v * math.sin(math.pi * (i / SR) / T) ** 2 for i, v in enumerate(x)]


def shatter():
    dur = 1.9
    n = int(SR * dur)
    glass = [v * 0.8 for v in decay(highpass(noise(n), 2500), 0.38)]
    thump = [v * 1.2 for v in decay(lowpass(noise(int(SR * 0.5)), 300), 0.12)]
    tinkles = decay(highpass(noise(n, sparse=True), 4000), 0.6)
    pings = [0.0] * n
    for _ in range(42):
        start = random.uniform(0, 1.45)
        f = random.uniform(2600, 8200)
        amp = random.uniform(0.12, 0.38)
        tau = random.uniform(0.04, 0.14)
        s = int(start * SR)
        for i in range(int(SR * tau * 5)):
            if s + i >= n:
                break
            t = i / SR
            pings[s + i] += amp * math.sin(2 * math.pi * f * t) * math.exp(-t / tau)
    return mix(glass, thump, tinkles, pings)


if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)
    write(os.path.join(out_dir, "punch.wav"), punch(), 0.95)
    write(os.path.join(out_dir, "knock.wav"), knock(), 0.8)
    write(os.path.join(out_dir, "crack.wav"), crack(), 0.75)
    write(os.path.join(out_dir, "whoosh.wav"), whoosh(), 0.6)
    write(os.path.join(out_dir, "shatter.wav"), shatter(), 0.95)
