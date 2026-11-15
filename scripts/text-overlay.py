#!/usr/bin/env python3
"""Lays exact glyph outlines over magnified screenshots of the canvas, to
compare text display paths pixel by pixel.

Usage: text-overlay.py DIR x0,y0,x1,y1 SCALE OUT.svg
DIR holds o-exact.png, o-gamma.png and o-dark.png (screenshots of the app
run with GRAVEN_EXACT_TEXT=1, GRAVEN_TEXT_DARKEN=0, and neither) and
outl-o-dark.svg (written by GRAVEN_DUMP_OUTLINES). The box is in screen
pixels; the app's window is assumed at (50, 90) on the screen, where Xvfb
puts a 1500 x 820 window on a 1600 x 1000 screen. Needs Pillow.
"""
import sys, base64, io, re
from PIL import Image
S=sys.argv[1]; x0,y0,x1,y1=map(int,sys.argv[2].split(',')); k=int(sys.argv[3]); out=sys.argv[4]
wx,wy=50,90  # the window's corner on the screen
d=re.search(r'd="([^"]*)"',open(S+'/outl-o-dark.svg').read()).group(1)
w,h=x1-x0,y1-y0
parts=[]
labels=['Exact outlines (before)','Atlas, gamma 1.45, no darkening','Atlas, gamma 1.45, stem darkening (default)']
for i,(name,label) in enumerate(zip(['o-exact','o-gamma','o-dark'],labels)):
    im=Image.open('%s/%s.png'%(S,name)).convert('RGB').crop((x0,y0,x1,y1))
    b=io.BytesIO(); im.save(b,'PNG'); uri='data:image/png;base64,'+base64.b64encode(b.getvalue()).decode()
    oy=i*(h*k+40)
    parts.append(f'<text x="8" y="{oy+26}" font-family="sans-serif" font-size="20">{label}</text>')
    parts.append(f'<image x="0" y="{oy+36}" width="{w*k}" height="{h*k}" href="{uri}" style="image-rendering:pixelated"/>')
    # pixel grid
    parts.append(f'<g transform="translate(0,{oy+36})" stroke="#000" stroke-opacity="0.08" stroke-width="1">'+''.join(f'<line x1="{i*k}" y1="0" x2="{i*k}" y2="{h*k}"/>' for i in range(w+1))+''.join(f'<line x1="0" y1="{j*k}" x2="{w*k}" y2="{j*k}"/>' for j in range(h+1))+'</g>')
    parts.append(f'<svg x="0" y="{oy+36}" width="{w*k}" height="{h*k}" viewBox="{x0-wx} {y0-wy} {w} {h}" overflow="hidden"><path d="{d}" fill="none" stroke="#e0218a" stroke-width="{1.6/k}"/></svg>')
H=3*(h*k+40)
open(out,'w').write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{w*k}" height="{H}" viewBox="0 0 {w*k} {H}"><rect width="{w*k}" height="{H}" fill="#fff"/>'+''.join(parts)+'</svg>')
print(w*k,H)
