#!/usr/bin/env python3
"""Create original MIT generic code icon (not the copyrighted Minyra character)."""
from pathlib import Path
from PIL import Image, ImageDraw
root=Path(__file__).resolve().parent.parent
im=Image.new("RGBA",(1024,1024),(0,0,0,0))
draw=ImageDraw.Draw(im)
draw.rounded_rectangle((40,40,984,984),radius=225,fill=(58,40,105,255))
draw.rounded_rectangle((125,125,899,899),radius=160,outline=(145,113,217,255),width=20)
draw.line([(383,409),(278,512),(383,615)],fill=(242,229,255,255),width=65)
draw.line([(642,409),(747,512),(642,615)],fill=(242,229,255,255),width=65)
draw.line([(586,346),(464,686)],fill=(242,229,255,255),width=55)
master=root/"Assets/MiniAgentIcon.png"
master.parent.mkdir(parents=True,exist_ok=True)
im.save(master,optimize=True)
for location in ("Assets/MiniAgent.iconset","Assets.xcassets/AppIcon.appiconset"):
    folder=root/location
    folder.mkdir(parents=True,exist_ok=True)
    for logical in (16,32,128,256,512):
        for scale in (1,2):
            actual=logical*scale
            name=f"icon_{logical}x{logical}{'@2x' if scale==2 else ''}.png"
            im.resize((actual,actual),Image.Resampling.LANCZOS).save(folder/name,optimize=True)
print("PUBLIC_GENERIC_ICON_READY")
