"""Generate original, deterministic paper-like Foley from filtered noise (not recordings)."""
from pathlib import Path
import math
import random
import struct
import wave

RATE = 44100
ROOT = Path(__file__).resolve().parents[1] / 'assets' / 'sounds'
random.seed(1701)


def render(name, duration, strokes):
    samples = [0.0] * round(duration * RATE)
    for start, length, strength, roughness in strokes:
        low = 0.0
        slow = 0.0
        for i in range(round(length * RATE)):
            t = i / (length * RATE)
            noise = random.uniform(-1, 1)
            low += 0.24 * (noise - low)
            slow += 0.025 * (noise - slow)
            # Broad friction, irregular folds, soft attack and release.
            friction = low - slow
            envelope = math.sin(math.pi * t) ** 1.5
            folds = 0.55 + 0.45 * math.sin(t * roughness * math.pi) ** 2
            index = round(start * RATE) + i
            if index < len(samples):
                samples[index] += friction * envelope * folds * strength
    peak = max(abs(x) for x in samples) or 1
    samples = [x * 0.65 / peak for x in samples]
    with wave.open(str(ROOT / name), 'wb') as out:
        out.setparams((1, 2, RATE, 0, 'NONE', 'not compressed'))
        out.writeframes(b''.join(struct.pack('<h', round(x * 32767)) for x in samples))


ROOT.mkdir(parents=True, exist_ok=True)
render('click.wav', .12, [(0, .09, 1, 3)])
render('calendar.wav', .15, [(0, .12, 1, 4)])
render('success.wav', .30, [(0, .14, 1, 2), (.10, .18, .5, 6)])
render('page_flip.wav', .48, [(0, .35, .7, 7), (.29, .17, .8, 3)])
render('book_open.wav', .75, [(0, .57, .7, 12), (.46, .25, 1, 4)])
render('page_rustle.wav', 1.64, [(i * .28, .46, 1, 9 + i) for i in range(5)])
render('tear.wav', .62, [(i * .055, .12, 1, 23) for i in range(9)])
print('Generated 7 original paper sound assets.')
