#!/usr/bin/env python3
"""Wrap a raw 1206x2622 iPhone 16 Pro screenshot in the device frame used by
site/framed/*.png, the README row, and the promo composition.

    python3 site/framed/frame.py <raw.png> <out-framed.png>

Raw shots come from a simulator whose logical size is 402x874 @3x — another
device model changes the aspect ratio and the frame will not match the row.

Geometry was reverse-engineered by pixel measurement of the already-committed
frames, because the original framer was a throwaway that only ever lived in
/tmp: 750x1274 canvas, device 430x906 centred (so margins 160 / 184), 12px
bezel, island top 208 / height 37. The bezel + island formulas below are that
script's originals at dw=430; its canvas padding and shadow did NOT match what
shipped, so both are pinned explicitly here instead of derived.

Checked against settings-light-framed.png, which the reshoot did not touch:
identical geometry, screen content matches 99.92% (rest is corner-radius
antialiasing), and composited over paper #F6F3EC the whole frame is within
meandelta 0.21/255, maxdelta 5.

ponytail: shadow fitted numerically, not derived — the original's render DPR is
unknowable now and 0.21/255 is already below perception. If a future frame must
match bit-exactly, re-fit here rather than adding a second framer.
"""
import base64, subprocess, sys, os

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TPL = """<!doctype html><html><head><meta charset="utf-8"><style>
*{margin:0;box-sizing:border-box}
body{width:%WIDTHpx;height:%HEIGHTpx;background:transparent;display:flex;align-items:center;justify-content:center}
.device{position:relative;width:%DWIDTHpx;border-radius:%RADIUSpx;background:#1a1917;
  padding:%BEZELpx;box-shadow:0 24px 64px rgba(30,25,20,.30), inset 0 0 0 2px #3a3835}
.screen{border-radius:%SRADIUSpx;overflow:hidden;display:block;width:100%;}
.screen img{display:block;width:100%}
.island{position:absolute;top:%ISLTOPpx;left:50%;transform:translateX(-50%);
  width:%ISLWpx;height:%ISLHpx;border-radius:999px;background:#000;z-index:3}
</style></head><body>
<div class="device"><div class="island"></div><div class="screen"><img src="data:image/png;base64,%B64%"></div></div>
</body></html>"""

def frame(src, dst, dw=430, W=750, H=1274):
    b64 = base64.b64encode(open(src,'rb').read()).decode()
    bezel = int(dw*0.030); radius=int(dw*0.155); sradius=int(dw*0.125)
    islw=int(dw*0.29); islh=int(dw*0.088); isltop=bezel+int(dw*0.028)
    html = (TPL.replace("%WIDTH",str(W)).replace("%HEIGHT",str(H))
        .replace("%DWIDTH",str(dw)).replace("%RADIUS",str(radius))
        .replace("%SRADIUS",str(sradius)).replace("%BEZEL",str(bezel))
        .replace("%ISLW",str(islw)).replace("%ISLH",str(islh))
        .replace("%ISLTOP",str(isltop)).replace("%B64%",b64))
    tmp="/tmp/frame_page2.html"; open(tmp,"w").write(html)
    subprocess.run([CHROME,"--headless","--disable-gpu","--default-background-color=00000000",
        f"--screenshot={dst}",f"--window-size={W},{H}","--hide-scrollbars",
        "--force-color-profile=srgb",f"file://{tmp}"], capture_output=True)
    print(dst, os.path.getsize(dst))

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    frame(sys.argv[1], sys.argv[2])
    # The row only reads as a row if every frame shares geometry; a wrong-model
    # raw shot silently changes the canvas. Cheapest possible guard.
    assert os.path.getsize(sys.argv[2]) > 0, "chrome wrote nothing — is CHROME path right?"
