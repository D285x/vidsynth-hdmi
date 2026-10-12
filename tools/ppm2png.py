#!/usr/bin/env python3
"""Convert the testbench's P3 PPM frames to PNG, and optionally build a
contact sheet or an animated GIF.

  python3 ppm2png.py mode*.ppm                 -> mode0.png ...
  python3 ppm2png.py --sheet sheet.png mode*.ppm
  python3 ppm2png.py --gif plasma.gif anim*.ppm
"""
import sys
from PIL import Image, ImageDraw


def read_ppm(path):
    with open(path) as f:
        tok = f.read().split()
    assert tok[0] == "P3", path
    w, h, mx = int(tok[1]), int(tok[2]), int(tok[3])
    vals = [int(v) * 255 // mx for v in tok[4:4 + w * h * 3]]
    img = Image.new("RGB", (w, h))
    img.putdata(list(zip(vals[0::3], vals[1::3], vals[2::3])))
    return img


def main(argv):
    sheet = gif = None
    files = []
    i = 0
    while i < len(argv):
        if argv[i] == "--sheet":
            sheet = argv[i + 1]; i += 2
        elif argv[i] == "--gif":
            gif = argv[i + 1]; i += 2
        else:
            files.append(argv[i]); i += 1
    imgs = [read_ppm(f) for f in files]

    if gif:
        imgs[0].save(gif, save_all=True, append_images=imgs[1:],
                     duration=50, loop=0)
    elif sheet:
        cols = 4
        tw, th = 320, 240
        rows = (len(imgs) + cols - 1) // cols
        out = Image.new("RGB", (cols * tw, rows * (th + 18)), (20, 20, 20))
        d = ImageDraw.Draw(out)
        for k, (im, f) in enumerate(zip(imgs, files)):
            x, y = (k % cols) * tw, (k // cols) * (th + 18)
            out.paste(im.resize((tw, th)), (x, y))
            d.text((x + 4, y + th + 3), f.rsplit("/", 1)[-1], fill=(220, 220, 220))
        out.save(sheet)
    else:
        for im, f in zip(imgs, files):
            im.save(f.rsplit(".", 1)[0] + ".png")


if __name__ == "__main__":
    main(sys.argv[1:])
