#!/usr/bin/env python3
# Rasterize a proportional Roboto ASCII subset into 2-bit coverage spans.
import argparse
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
root=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--font',type=Path,default=root/'assets/fonts/Roboto-Regular.ttf')
parser.add_argument('--output',type=Path,default=root/'firmware/wp2-apps/sdk/cmf-workbench-tools/src')
args=parser.parse_args();out=args.output;out.mkdir(parents=True,exist_ok=True)
blob=bytearray();meta=[]
for size in [16,20,24]:
 font=ImageFont.truetype(str(args.font),size)
 for code in range(32,127):
  ch=chr(code);advance=round(font.getlength(ch));w=max(advance+3,1);h=size+6
  im=Image.new('L',(w,h))
  ImageDraw.Draw(im).text((1,0),ch,font=font,fill=255,anchor='la')
  pixels=[[min(3,(im.getpixel((x,y))+42)//85) for x in range(w)] for y in range(h)]
  used=[(x,y) for y in range(h) for x in range(w) if pixels[y][x]]
  gw=max((x+1 for x,y in used),default=0);gh=max((y+1 for x,y in used),default=0)
  flat=[pixels[y][x] for y in range(gh) for x in range(gw)]
  start=len(blob)
  for i in range(0,len(flat),4):
   value=0
   for j,alpha in enumerate(flat[i:i+4]):value|=alpha<<(6-2*j)
   blob.append(value)
  meta.append((start,gw,gh,advance))
(out/'font-data.bin').write_bytes(blob)
(out/'font-data.rs').write_text('// Roboto (Google), Apache-2.0; lossless 2-bit glyph coverage.\nconst GLYPHS:[(u16,u8,u8,u8);285]=[\n'+''.join(f'({a},{b},{c},{d}),\n' for a,b,c,d in meta)+'];\n')
print(f'{len(blob)} font bytes, {len(meta)} glyphs')
