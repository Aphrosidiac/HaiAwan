"""Prepare real Awan app captures for the site.

The captures come from the app's own headless snapshot harness:
  app/.build/.../Awan --snapshot home <out>/home.png 1320 840
  app/.build/.../Awan --snapshot notch-peek <out>/notch-peek.png
Usage: python3 site/scripts/shots.py <dir-with-pngs>
"""
import sys
from pathlib import Path
from PIL import Image

src = Path(sys.argv[1])
out = Path(__file__).resolve().parent.parent / "public/img"

home = Image.open(src / "home.png").convert("RGB")
home.resize((1320, 840), Image.LANCZOS).save(out / "shot-home.webp", "WEBP", quality=82, method=6)
# sidebar-only crop (the agent roster) for the small hero windows
side = home.crop((0, 0, 512, 1100))
side.resize((256, 550), Image.LANCZOS).save(out / "shot-roster.webp", "WEBP", quality=82, method=6)

peek = Image.open(src / "notch-peek.png").convert("RGB")
w, h = peek.size
# the harness paints a purple desk behind the notch panel: trim it
peek = peek.crop((22, 0, w - 22, h - 4))
peek.resize((peek.width // 2, peek.height // 2), Image.LANCZOS).save(out / "shot-peek.webp", "WEBP", quality=82, method=6)
print("ok", (out / "shot-home.webp").stat().st_size, (out / "shot-peek.webp").stat().st_size)
