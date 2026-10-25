"""Deterministic original vector mark and app-icon exports from one geometry spec.

Requires Pillow only for raster export. No external images, models or fonts.
"""
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]


def svg(spec, palette, background=True):
    commands = ' '.join(c[0]+' '+' '.join(str(n) for n in c[1:]) for c in spec['nest'])
    backdrop = '<rect width="1024" height="1024" fill="'+palette['background']+'"/>' if background else ''
    shapes = []
    for key in ['core','node']:
        x1,y1,x2,y2,radius = spec[key]
        shapes.append(f'<rect x="{x1}" y="{y1}" width="{x2-x1}" height="{y2-y1}" rx="{radius}" fill="{palette[key]}"/>')
    viewbox='0 0 1024 1024' if background else '224 224 640 576'
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="'+viewbox+'">'+backdrop+
            f'<path d="{commands}" fill="none" stroke="{palette["nest"]}" stroke-width="{spec["strokeWidth"]}" stroke-linecap="round" stroke-linejoin="round"/>'+
            ''.join(shapes)+'</svg>\n')


def raster(spec, palette, size=1024, background=True):
    scale = 3
    canvas = spec['canvas']*scale
    image = Image.new('RGB' if background else 'RGBA', (canvas,canvas),
                      palette['background'] if background else (0,0,0,0))
    draw = ImageDraw.Draw(image)
    points=[]
    current=(0,0)
    for command in spec['nest']:
        if command[0] in {'M','L'}:
            current=tuple(command[1:]);points.append(current)
        else:
            p0=current;p1=command[1:3];p2=command[3:5];p3=command[5:7]
            for step in range(1,65):
                t=step/64;u=1-t
                points.append(tuple(u*u*u*p0[i]+3*u*u*t*p1[i]+3*u*t*t*p2[i]+t*t*t*p3[i] for i in [0,1]))
            current=tuple(p3)
    draw.line([(round(x*scale),round(y*scale)) for x,y in points],
              fill=palette['nest'],width=spec['strokeWidth']*scale,joint='curve')
    radius=spec['strokeWidth']/2
    for x,y in [points[0],points[-1]]:
        draw.ellipse([(round((x-radius)*scale),round((y-radius)*scale)),
                      (round((x+radius)*scale),round((y+radius)*scale))],fill=palette['nest'])
    for key in ['core','node']:
        x1,y1,x2,y2,r=spec[key]
        draw.rounded_rectangle([x1*scale,y1*scale,x2*scale,y2*scale],radius=r*scale,fill=palette[key])
    if not background:
        image=image.crop((224*scale,224*scale,864*scale,800*scale))
        return image.resize((640,576),Image.Resampling.LANCZOS)
    return image.resize((size,size),Image.Resampling.LANCZOS)


def main():
    spec=json.loads((ROOT/'brand/identity.json').read_text())
    assets=ROOT/'ios/Cubie/Assets.xcassets'
    icons=assets/'AppIcon.appiconset';icons.mkdir(parents=True,exist_ok=True)
    mark=assets/'CoreNestMark.imageset';mark.mkdir(parents=True,exist_ok=True)
    exports=ROOT/'brand/exports';exports.mkdir(exist_ok=True)
    images=[];mark_images=[];manifest={}
    for variant,palette in spec['palettes'].items():
        png=icons/f'AppIcon-{variant}.png'
        raster(spec,palette).save(png,optimize=True)
        (exports/f'corenest-icon-{variant}.svg').write_text(svg(spec,palette),encoding='utf-8')
        item={'filename':png.name,'idiom':'universal','platform':'ios','size':'1024x1024'}
        if variant!='light':item['appearances']=[{'appearance':'luminosity','value':variant}]
        images.append(item)
        manifest[png.name]=hashlib.sha256(png.read_bytes()).hexdigest()
        if variant!='tinted':
            name=f'CoreNestMark-{variant}.png'
            raster(spec,palette,background=False).save(mark/name,optimize=True)
            (exports/f'corenest-mark-{variant}.svg').write_text(svg(spec,palette,False),encoding='utf-8')
            entry={'filename':name,'idiom':'universal'}
            if variant=='dark':entry['appearances']=[{'appearance':'luminosity','value':'dark'}]
            mark_images.append(entry)
    (icons/'Contents.json').write_text(json.dumps({'images':images,'info':{'author':'xcode','version':1}},indent=2)+'\n')
    (mark/'Contents.json').write_text(json.dumps({'images':mark_images,'info':{'author':'xcode','version':1}},indent=2)+'\n')
    (assets/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}},indent=2)+'\n')
    (exports/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps({'brand':spec['name'],'opaque_app_icons':3,'vector_exports':5,'source':'brand/identity.json'}))


if __name__=='__main__':main()
