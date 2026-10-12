"""Local, reproducible fictional liveries; original atlases and meshes stay untouched.
UVs are unchanged. Only chromatic paint pixels and explicit marking masks change.
Masks also clear embossed source logos from normal maps, not just diffuse color.
"""
from pathlib import Path
import hashlib
import json
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path('/workspace/assets')
OUT = ROOT / 'FictionalLiveries'
FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'

# Coordinates refer to each original image, not to rescaled previews.
# Polygon masks avoid windows, door edges, grilles and UV-island boundaries.
SPECS = [
    dict(name='Cangyu_D12', source='model/228b03702ab649048d477f0df9bf5feb/Textures/228b03702ab649048d477f0df9bf5feb_00_D.jpg',
         normal='model/228b03702ab649048d477f0df9bf5feb/Textures/228b03702ab649048d477f0df9bf5feb_00_N.png',
         hue='blue', color=(27,121,134), code='D12',
         masks=[[(1060,927),(1096,927),(1096,970),(1060,970)]],
         badges=[(1095,924,10,90)], labels=[], repairColor=(207,209,209), note='Old nose symbol cleared in D and N; saturated blue paint becomes sea teal. Original yellow stripe remains a warm-gold accent.'),
    dict(name='Chiluan_D18', source='RollingStockBaked/DF4D_D.jpg', normal='RollingStockBaked/DF4D_N.png',
         hue='red', color=(155,67,71), code='D18',
         masks=[[(105,1182),(132,1182),(132,1208),(105,1208)],
                [(791,1203),(825,1196),(833,1228),(796,1237)]],
         badges=[(118,1195,8,0),(810,1217,8,-14)], labels=[(940,812,18,0)],
         note='Two real/source red technical plates removed, copper-red paint remapped while grilles, cab glass, cream stripe, underframe and all UV islands remain.'),
    dict(name='Cangqiong_E21', source='RollingStockBaked/SS9G_D.jpg', normal='RollingStockBaked/SS9G_N.png',
         hue='red', color=(55,76,140), code='E21',
         masks=[[(399,1114),(490,1114),(490,1166),(399,1166)],
                [(38,1370),(81,1370),(81,1460),(38,1460)],
                [(1037,482),(1065,482),(1065,493),(1037,493)]],
         badges=[(441,1140,19,0)], labels=[(802,949,17,90)],
         note='Unreadable cyan nameplate/source lettering and small plates cleared; red body becomes indigo, original glazing/doors/cream stripe/roof retained.'),
    dict(name='Leisun_E32', source='RollingStockBaked/HXD3D_D.jpg', normal='RollingStockBaked/HXD3D_N.png',
         hue='red', color=(112,62,145), code='E32',
         masks=[[(74,1338),(101,1338),(101,1375),(74,1375)],
                [(118,1325),(151,1325),(151,1377),(118,1377)],
                [(126,1408),(148,1408),(148,1428),(126,1428)],
                [(33,1420),(55,1420),(55,1440),(33,1440)],
                [(30,1606),(121,1606),(121,1653),(30,1653)],
                [(20,1710),(47,1710),(47,1742),(20,1742)],
                [(161,1482),(201,1482),(201,1539),(161,1539)],
                [(548,1404),(562,1404),(562,1424),(548,1424)],
                [(576,1370),(604,1370),(604,1417),(576,1417)],
                [(624,1352),(654,1352),(654,1428),(624,1428)],
                [(1006,1062),(1049,1080),(1040,1102),(1004,1089)],
                [(970,1100),(1029,1120),(1017,1148),(965,1130)],
                [(932,1650),(958,1650),(958,1695),(932,1695)],
                [(1000,1652),(1026,1652),(1026,1693),(1000,1693)],
                [(985,1665),(1003,1665),(1003,1689),(985,1689)],
                [(1045,1903),(1069,1903),(1069,1930),(1045,1930)],
                [(74,1950),(100,1950),(100,1991),(74,1991)],
                [(105,1950),(128,1950),(128,1983),(105,1983)],
                [(128,1940),(151,1940),(151,2020),(128,2020)],
                [(165,1945),(207,1945),(207,2022),(165,2022)]],
         badges=[(135,1352,13,90),(640,1385,15,90),(999,1124,13,-14),(181,1975,13,90),(1058,1918,10,0)],
         labels=[(88,1357,11,90),(944,1672,12,90)],
         note='All observed CRH/HCD/railway/manufacturer-like symbols, source fleet numbers and source technical lettering are separately masked in D/N. Purple paint is selective; windows, white stripes and hardware remain.'),
    dict(name='Liuying_M30_head', source='RollingStockBaked/CRH380A_head_D.jpg', normal='RollingStockBaked/CRH380A_head_N.png',
         hue='blue', color=(31,134,119), code='M30',
         masks=[[(736,731),(781,729),(782,749),(736,751)],
                [(500,1350),(524,1350),(524,1389),(500,1389)]],
         badges=[(758,740,9,0)], labels=[(499,1290,13,90)],
         note='Small nose lettering/emblem and side lettering removed from color and embossed normal map; blue stripes become green-teal without repainting white body, glass or doors.'),
    dict(name='Liuying_M30_middle', source='RollingStockBaked/CRH380A_middle_D.jpg', normal='RollingStockBaked/CRH380A_middle_N.png',
         hue='blue', color=(31,134,119), code='M30',
         masks=[[(423,1418),(472,1369),(607,1504),(558,1553)],
                [(693,1230),(724,1199),(841,1316),(810,1347)]],
         badges=[(483,1426,17,-46),(794,1290,17,134)], repairColor=(217,219,220),
         labels=[(537,1483,18,-46),(749,1244,18,134)],
         note='Two large CRH text/logo groups removed in D and embossed N using narrow diagonal masks between window/blue/grey bands; replaced with independent double-diamond symbols and M30, keeping every window and door UV.'),
    dict(name='Xinglan_M35_head', source='RollingStockBaked/CR400AF_head_D.jpg', normal='RollingStockBaked/CR400AF_head_N.png',
         hue='red', color=(103,98,190), code='M35',
         masks=[[(415,1573),(455,1573),(455,1619),(415,1619)]],
         badges=[(433,1597,17,90)], labels=[(1200,959,16,0)],
         note='Nose source railway emblem removed in D/N; red speed ribbon becomes violet-blue, thin teal accent and window/door masks retained.'),
    dict(name='Xinglan_M35_middle', source='RollingStockBaked/CR400AF_middle_v2_aligned_D.png',
         normal='model/fb6db791acae4c95a0455e5270f4e417/Textures/fb6db791acae4c95a0455e5270f4e417_00_N.png',
         hue='red', color=(103,98,190), code='M35',
         masks=[], badges=[], labels=[(226,1510,24,90),(770,1510,24,90)],
         note='Accepted v2 diffuse inspected: no legible real brand found. Selective violet-blue ribbon replaces red only; central black window strip, all doors, side panels and vents stay unchanged.'),
    dict(name='Xinglan_M35_spare', source='RollingStockBaked/CR400AF_middle_D.jpg', normal='RollingStockBaked/CR400AF_middle_N.png',
         hue='red', color=(103,98,190), code='M35',
         masks=[[(1213,1536),(1259,1534),(1260,1556),(1215,1558)]],
         badges=[(1235,1546,9,0)], labels=[],
         note='Inactive/rejected spare atlas also gets source plate removal and violet ribbon; not promoted to service and no geometric claims changed.'),
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def mark_mask(size, polygons):
    mask = Image.new('L', size, 0)
    draw = ImageDraw.Draw(mask)
    for polygon in polygons:
        draw.polygon(polygon, fill=255)
    return np.array(mask)


def clear_local(array, mask):
    # Large lettering is repaired from local homogeneous paint, not propagated from
    # the nearby blue/window band. Inpainting alone smeared dark glyph strokes.
    # Only explicit pixels are changed; fit the surrounding paint's mild gradient.
    if not np.any(mask):
        return array.copy()
    result = array.copy()
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    normal_map = np.median(array[:, :, 2]) > 210 and np.median(array[:, :, 0]) < 180
    for i in range(1, count):
        x, y, w, h, _ = stats[i]
        a, b = max(0, x-26), max(0, y-26)
        c, d = min(array.shape[1], x+w+26), min(array.shape[0], y+h+26)
        local = (labels[b:d, a:c] == i).astype(np.uint8)*255
        roi = result[b:d, a:c]
        yy, xx = np.indices(local.shape)
        available = (local == 0)
        if normal_map:
            # Same tangent basis is retained. Branding relief only becomes flat paint.
            typical = np.median(roi[available], axis=0)
            distance = np.linalg.norm(roi.astype(np.float32)-typical, axis=2)
            samples = available & (distance < 22)
        else:
            # Probe nearby paint pixels, excluding dark letters/bright logos.
            hsv=cv2.cvtColor(roi,cv2.COLOR_RGB2HSV)
            chromatic=available & (hsv[:,:,1]>70) & (hsv[:,:,2]>55)
            neutral=available & (hsv[:,:,1]<45) & (hsv[:,:,2]>120)
            samples = chromatic if np.count_nonzero(chromatic)>np.count_nonzero(neutral) else neutral
            if np.count_nonzero(samples)>0:
                typical=np.median(roi[samples],axis=0)
                samples &= np.linalg.norm(roi.astype(np.float32)-typical,axis=2)<45
        if np.count_nonzero(samples) < 12:
            cleaned=cv2.inpaint(roi,local,5,cv2.INPAINT_TELEA)
            roi[local>0]=cleaned[local>0]
            continue
        design=np.stack([np.ones_like(xx),xx,yy],axis=2).astype(np.float64)
        coefficient=np.linalg.lstsq(design[samples],roi[samples].astype(np.float64),rcond=None)[0]
        fitted=design[local>0]@coefficient
        median=np.median(roi[samples],axis=0)
        roi[local>0]=np.clip(fitted,median-22,median+22).clip(0,255).astype(np.uint8)
    return result


def symbol(image, cx, cy, radius, angle=0, color=(236,221,163)):
    tile = Image.new('RGBA', (radius*6, radius*6), (0,0,0,0))
    d = ImageDraw.Draw(tile)
    mid = radius*3
    for dx, dy in [(-radius*.48, -radius*.18), (radius*.48, radius*.18)]:
        x,y=mid+dx,mid+dy
        d.line([(x,y-radius*.75),(x+radius*.53,y),(x,y+radius*.75),(x-radius*.53,y),(x,y-radius*.75)],fill=color+(255,),width=max(2,radius//5))
    d.line([(mid+radius*.80,mid+radius*.43),(mid+radius*1.55,mid+radius*.43)],fill=color+(255,),width=max(2,radius//6))
    tile=tile.rotate(angle,Image.Resampling.BICUBIC,expand=True)
    image.paste(tile,(round(cx-tile.width/2),round(cy-tile.height/2)),tile)


def code_label(image, text, cx, cy, size, angle):
    font=ImageFont.truetype(FONT,size)
    box=font.getbbox(text)
    tile=Image.new('RGBA',(box[2]-box[0]+8,box[3]-box[1]+8),(0,0,0,0))
    ImageDraw.Draw(tile).text((4-box[0],4-box[1]),text,font=font,fill=(235,221,176,255))
    tile=tile.rotate(angle,Image.Resampling.BICUBIC,expand=True)
    image.paste(tile,(round(cx-tile.width/2),round(cy-tile.height/2)),tile)


def paint_mask(array, family):
    hsv=cv2.cvtColor(array,cv2.COLOR_RGB2HSV)
    h,s,v=hsv[:,:,0],hsv[:,:,1],hsv[:,:,2]
    hue=((h>=90)&(h<=126)) if family=='blue' else ((h<20)|(h>167))
    return hue & (s>85) & (v>48)


def recolor(array, family, color):
    mask=paint_mask(array,family)
    hsv=cv2.cvtColor(array,cv2.COLOR_RGB2HSV)
    shade=hsv[:,:,2].astype(np.float32)/255
    target=np.array(color,np.float32)
    # Original brightness/metal shading remains, only the base chromatic paint changes.
    mapped=np.clip(target[None,None,:]*(.28+.95*shade[:,:,None]),0,255).astype(np.uint8)
    result=array.copy();result[mask]=mapped[mask]
    return result,mask


def main():
    OUT.mkdir(exist_ok=True)
    records=[]
    for spec in SPECS:
        source=ROOT/spec['source']; normal=ROOT/spec['normal']
        image=Image.open(source).convert('RGB');original=np.array(image)
        mask=mark_mask(image.size,spec['masks'])
        clean=clear_local(original,mask)
        if 'repairColor' in spec:
            if spec['name']=='Cangyu_D12':
                xx=np.indices(mask.shape)[1]
                white=(mask>0)&(xx<=1080)
                teal=(mask>0)&(xx>1080)
                clean[white]=spec['repairColor'];clean[teal]=(39,106,165)
            else:
                clean[mask>0]=spec['repairColor']
        recolored,paint=recolor(clean,spec['hue'],spec['color'])
        result=Image.fromarray(recolored)
        if spec['name']=='Liuying_M30_middle':
            # After removing the wordmarks, restore the pre-existing thin stripe
            # only where the mask intersected it; no window/door pixels are added.
            stripe=Image.new('L',image.size,0);sd=ImageDraw.Draw(stripe)
            sd.line([(450,1352),(635,1537)],fill=255,width=18)
            sd.line([(682,1243),(873,1434)],fill=255,width=18)
            sm=(np.array(stripe)>0)&(mask>0)
            arr=np.array(result);arr[sm]=(30,116,107);result=Image.fromarray(arr)
        for badge in spec['badges']:symbol(result,*badge)
        for label in spec['labels']:code_label(result,spec['code'],*label)
        diffuse_out=OUT/(spec['name']+'_D.png');result.save(diffuse_out,optimize=True)
        # Copy/inpaint normal only where branding existed; normal scale/handedness unchanged.
        nimage=Image.open(normal).convert('RGB');narray=np.array(nimage)
        nmask=np.array(Image.fromarray(mask).resize(nimage.size,Image.Resampling.NEAREST))
        normal_out=OUT/(spec['name']+'_N.png')
        nresult=clear_local(narray,nmask);Image.fromarray(nresult).save(normal_out,optimize=True)
        records.append(dict(name=spec['name'],displayCode=spec['code'],source=spec['source'],sourceSHA256=sha(source),
            normalSource=spec['normal'],normalSourceSHA256=sha(normal),diffuse=str(diffuse_out.relative_to(ROOT)),
            normal=str(normal_out.relative_to(ROOT)),dimensions=list(image.size),normalDimensions=list(nimage.size),
            clearingPolygons=spec['masks'],markedPixels=int(np.count_nonzero(mask)),paintPixels=int(np.count_nonzero(paint)),
            changedDiffusePixels=int(np.count_nonzero(np.any(np.array(result)!=original,axis=2))),
            changedNormalPixels=int(np.count_nonzero(np.any(nresult!=narray,axis=2))),operation=spec['note']))
        print(spec['name'], 'clearing',records[-1]['markedPixels'],'paint',records[-1]['paintPixels'],'normal',records[-1]['changedNormalPixels'])
    # Coach detail atlas is procedural; keep the three equipment tiles and rebuild only name/text tiles.
    path=ROOT/'Textures/Railway/coach_detail.png';coach=Image.open(path).convert('RGB');d=ImageDraw.Draw(coach)
    d.rectangle((36,63,477,449),fill=(30,57,70))
    d.rounded_rectangle((44,165,469,269),radius=12,fill=(31,75,89),outline=(204,195,143),width=2)
    d.text((58,179),'QY / C24',font=ImageFont.truetype(FONT,47),fill=(235,223,177))
    d.text((59,290),'24.0 m / 52 t',font=ImageFont.truetype(FONT,27),fill=(214,220,215))
    d.text((59,341),'GROUP TRANSIT',font=ImageFont.truetype(FONT,24),fill=(214,220,215))
    symbol(coach,411,104,24)
    d.rectangle((550,815,989,875),fill=(60,77,86))
    d.text((555,833),'FLEET QY / C24',font=ImageFont.truetype(FONT,27),fill=(204,214,219))
    coach.save(OUT/'Yunzhou_C24_detail_D.png',optimize=True)
    records.append(dict(name='Yunzhou_C24_detail',source='Textures/Railway/coach_detail.png',sourceSHA256=sha(path),
        diffuse='FictionalLiveries/Yunzhou_C24_detail_D.png',dimensions=[1024,1024],
        operation='Removed YZ 25K/SERVICE 25K, rebuilt fictional QY/C24 nameplates only; retained equipment louvers and diamond-tread tile unchanged.'))
    (OUT/'liveries.json').write_text(json.dumps(dict(world='星澜群域',operator='群域行旅联队',symbol='双棱航迹',
        provenance='Derived from existing supplied atlases; not original new models. No external upload or AI regeneration.',
        method='Local Pillow + masked OpenCV inpaint; no geometry, UV, material lifecycle or source-asset modification.',
        runtimeVerification='Requires unified official build and in-game preview; texture-space inspection alone is not final rendered acceptance.',
        textures=records),ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

if __name__=='__main__':main()
