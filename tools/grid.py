"""Dev helper: tile game screenshots into one image. usage: python grid.py OUT.png PATTERN [cols]"""
import glob
import sys

from PIL import Image

out_path, pattern = sys.argv[1], sys.argv[2]
cols = int(sys.argv[3]) if len(sys.argv) > 3 else 2
files = sorted(glob.glob(pattern))
if not files:
    raise SystemExit("no files match " + pattern)
ims = [Image.open(f).convert("RGB").resize((640, 360)) for f in files]
rows = (len(ims) + cols - 1) // cols
out = Image.new("RGB", (640 * cols, 360 * rows))
for i, im in enumerate(ims):
    out.paste(im, ((i % cols) * 640, (i // cols) * 360))
out.save(out_path)
print(out_path, len(ims))
