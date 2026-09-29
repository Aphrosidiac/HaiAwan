"""Convert the FF brand-system Instrument fonts (SIL OFL) to woff2 for the site.

Run once: python3 site/scripts/fonts.py  (needs fonttools + brotli)
"""
import shutil
from pathlib import Path
from fontTools.ttLib import TTFont

SRC = Path.home() / "Desktop/dev/ffdevstudio/brand-system/assets/fonts"
OUT = Path(__file__).resolve().parent.parent / "public/fonts"
OUT.mkdir(parents=True, exist_ok=True)
for name in ["InstrumentSans-Variable", "InstrumentSans-Italic-Variable", "InstrumentSerif-Regular", "InstrumentSerif-Italic"]:
    f = TTFont(SRC / f"{name}.ttf")
    f.flavor = "woff2"
    f.save(OUT / f"{name}.woff2")
    axes = [(a.axisTag, a.minValue, a.maxValue) for a in f["fvar"].axes] if "fvar" in f else []
    print(name, (OUT / f"{name}.woff2").stat().st_size, axes)
for lic in SRC.glob("OFL-*.txt"):
    shutil.copy(lic, OUT / lic.name)
