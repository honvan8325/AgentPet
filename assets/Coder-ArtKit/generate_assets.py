#!/usr/bin/env python3
"""Render the complete Coder mascot as independent pixel-art character frames."""
from __future__ import annotations
import io
import json
import math
import random
from copy import deepcopy
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT=Path(__file__).resolve().parent
THEME=ROOT/'Themes'/'coder'
PREVIEWS=ROOT/'previews'
ROOT.mkdir(exist_ok=True)
THEME.mkdir(parents=True,exist_ok=True)
PREVIEWS.mkdir(parents=True,exist_ok=True)
S=48
OUT='#332b3f'; OUT2='#4b3449'; HAIR='#252433'; HAIR_L='#43405a'
SKIN='#f3be96'; SHADOW='#d89774'; SKIN_LIGHT='#f9d3af'
SHIRT='#cce9f8'; SHIRT_L='#f0f7ff'; SHIRT_D='#8ab6d5'; SHIRT_DEEP='#5e89ad'
PANTS='#424960'; PANTS_D='#2b3147'; BAG='#292936'; BAG_H='#434555'
LAPTOP='#27485e'; LAPTOP_LIGHT='#6dd7d2'; LAPTOP_DARK='#1b3447'
TEAL='#58dac7'; VIOLET='#79688f'; BLUSH='#f58f96'; WHITE='#fff6dd'

source=json.loads((ROOT/'manifest_template.json').read_text(encoding='utf8'))

# Keep the exact engine clip contract and row ordering.
manifest=deepcopy(source)
manifest['name']='Coder'
manifest['character']={
  'species':'human_pixel_chibi','reference':'user-provided photo',
  'hair':'black_side_parted','eyewear':'black_rectangular_glasses',
  'outfit':'light_blue_button_shirt','accessories':['black_crossbody_bag','smartphone','peace_sign'],
  'workDevice':'mini_laptop','exactlyTwoArms':True
}
for t,obj in manifest['tiers'].items():obj['file']=t+'.png'
manifest['states']['glasses_adjust']=manifest['states'].pop('cap_adjust')
manifest['transitions']['adjust_glasses']=manifest['transitions'].pop('adjust_cap')
manifest['transitions']['adjust_glasses']['to']='glasses_adjust'
manifest['hud']['file']='Shared/bars.png'
manifest['hud']['taskBubble']['file']='Shared/task_bubble.png'
manifest['hud']['pixelFont']='Shared/digits.png'
manifest['hud']['positions']={'5H_bar':[2,1,32,4],'7D_bar':[2,6,32,4]}
manifest['layout']={'bubbleOffset':{'x':-11,'y':8},'hudOffsetY':-6}
activity_defs={
 'stretching':['stretch','stretching','stretch_finish'],
 'yawning':['yawn','yawning'],
 'coffee_break':['caffeinate','coffee_break'],
 'looking_around':['look','looking_around'],
 'tiny_dance':['dance','tiny_dance'],
 'glasses_adjust':['adjust_glasses','glasses_adjust'],
 'walking':['walking'],
}
manifest['logic']['idleActivities']=[{'name':n,'steps':s,**({'holdSecondsRange':[1,2]} if n=='walking' else {})}for n,s in activity_defs.items()]
THEME.joinpath('manifest.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf8')

TIERS=['fresh','focused','tired','exhausted','empty']
STATE_KEYS=list(manifest['states'])
TRANS_KEYS=list(manifest['transitions'])
assert len(STATE_KEYS)==30 and len(TRANS_KEYS)==38

# Render each fully assembled figure from scratch; no pasted body/limb layers.
def col(c, tier):
    if tier=='fresh':return c
    # Subtle fatigue palette shift accompanies geometry and facial changes.
    multiplier={'focused':0.98,'tired':0.96,'exhausted':0.93,'empty':0.91}[tier]
    rgb=tuple(int(c[i:i+2],16)*multiplier for i in (1,3,5))
    return '#%02x%02x%02x'%tuple(map(int,rgb))

def poly(d,pts,fill,outline=OUT,width=1):d.polygon(pts,fill=fill);d.line(pts+[pts[0]], fill=outline,width=width,joint='curve')
def rect(d,xy,fill,outline=None,width=1):d.rectangle(xy,fill=fill,outline=outline,width=width)
def ell(d,xy,fill,outline=OUT):d.ellipse(xy,fill=fill,outline=outline,width=1)
def line(d,points,fill=OUT,width=1):d.line(points,fill=fill,width=width,joint='curve')

def draw_laptop(d,x,yy,typ,phase):
    # Screen and keyboard silhouette is consistent while typing motion is large.
    x=int(x); yy=int(yy)
    rect(d,(x,yy-8,x+17,yy+2),LAPTOP_DARK,OUT,1)
    rect(d,(x+2,yy-6,x+15,yy),LAPTOP_LIGHT)
    for ix in range(4):
        rect(d,(x+3+ix*3,yy-5+(ix%2),x+4+ix*3,yy-5+(ix%2)),SHIRT_L)
    rect(d,(x+6,yy-3,x+12,yy-2),'#2d899e')
    poly(d,[(x-2,yy+2),(x+20,yy+2),(x+19,yy+4),(x-3,yy+4)],BAG_H)
    rect(d,(x+6,yy+2,x+12,yy+2),TEAL)
    if typ and phase>0.75:
        rect(d,(x+0,yy-8,x+1,yy-7),WHITE)
        rect(d,(x+17,yy-10,x+18,yy-9),TEAL)

def draw_human(tier:str,kind:str,frame:int):
    im=Image.new('RGBA',(S,S),(0,0,0,0));d=ImageDraw.Draw(im)
    p=frame/8*2*math.pi
    fatigue=TIERS.index(tier)
    hshift=([0,0,1,2,3])[fatigue]
    sway=round(math.sin(p)*({'walking':2,'tiny_dance':2,'dragging':2,'hovering':1}.get(kind,0)))
    bounce=round(abs(math.sin(p)) * (2 if kind in ['tiny_dance','celebrating','giggling','walking','landing'] else 1 if kind in ['typing','hovering','reconnecting'] else 0))
    if kind != 'paused' and bounce == 0 and frame in (2,3):
        bounce = 1  # tiny breathing motion on otherwise quiet states
    if fatigue>=3 and kind not in ('dragging','walking','tiny_dance'):
        bounce = 1 if kind != 'paused' and frame in (2,3) else 0
    yy=hshift-bounce
    lean=(1 if fatigue>=3 else 0)+(1 if kind in ['failed','interrupted','critical_quota'] else 0)
    x=sway+lean
    # Effective state of transitioning clips is supplied by caller, not guessed by filename.
    work=kind in ('typing','thinking','syncing','needs_input','ready','failed','paused','start_work','resume_typing')
    sleep=kind in ('sleeping','yawning')
    stretch=kind in ('stretching',)
    phone=kind in ('idle','looking_around','booped','giggling','annoyed','unknown','glasses_adjust','hovering')
    focused=kind in ('typing','thinking','needs_input','syncing')
    jump=kind in ('celebrating','tiny_dance')
    walking=kind in ('walking','dragging')
    raise_left=kind in ('stretching','celebrating','tiny_dance','grabbed','dragging')
    raise_right=kind in ('stretching','celebrating','tiny_dance','grabbed','dragging','idle','hovering','booped','giggling')
    if fatigue >= 3 and kind in ('idle','hovering','booped','giggling'): raise_right=False
    thinking=kind in ('thinking','looking_around')
    # Walking feet with no added limbs.
    walk_stride=round(math.sin(p)*2) if walking else 0
    # Shoes/legs. Long vertical silhouette with tiny shoes.
    leg_y=39+yy
    poly(d,[(17+x,leg_y-1),(23+x,leg_y-1),(23+x+walk_stride,leg_y+4),(17+x+walk_stride,leg_y+4)],PANTS)
    poly(d,[(28+x,leg_y-1),(34+x,leg_y-1),(34+x-walk_stride,leg_y+4),(28+x-walk_stride,leg_y+4)],PANTS_D)
    rect(d,(16+x+walk_stride,leg_y+3,23+x+walk_stride,leg_y+5),HAIR,OUT)
    rect(d,(28+x-walk_stride,leg_y+3,35+x-walk_stride,leg_y+5),HAIR,OUT)
    rect(d,(17+x+walk_stride,leg_y+4,22+x+walk_stride,leg_y+4),SHIRT_L)
    rect(d,(29+x-walk_stride,leg_y+4,34+x-walk_stride,leg_y+4),SHIRT_L)
    # Cross-body bag behind right torso and near right hip.
    poly(d,[(30+x,32+yy),(37+x,32+yy),(38+x,40+yy),(29+x,41+yy)],BAG)
    poly(d,[(32+x,34+yy),(36+x,34+yy),(37+x,39+yy),(31+x,39+yy)],BAG_H,OUT2)
    line(d,[(32+x,35+yy),(36+x,35+yy)],VIOLET)
    rect(d,(35+x,35+yy,36+x,37+yy),SHIRT_D)
    # Shirt: defined shoulders, visible sleeves and button placket.
    if fatigue>=3:
        body_pts=[(19+x,23+yy),(30+x,23+yy),(34+x,27+yy),(33+x,37+yy),(30+x,39+yy),(18+x,39+yy),(15+x,35+yy),(17+x,28+yy)]
    else:
        body_pts=[(18+x,23+yy),(30+x,23+yy),(35+x,27+yy),(33+x,39+yy),(18+x,39+yy),(15+x,35+yy),(16+x,27+yy)]
    poly(d,body_pts,col(SHIRT,tier))
    poly(d,[(18+x,24+yy),(21+x,25+yy),(24+x,28+yy),(21+x,28+yy)],SHIRT_L,SHIRT_D)
    poly(d,[(28+x,24+yy),(31+x,25+yy),(28+x,29+yy),(25+x,28+yy)],SHIRT_L,SHIRT_D)
    line(d,[(24+x,27+yy),(24+x,38+yy)],SHIRT_D)
    for cy in (30,34,37):rect(d,(24+x,cy+yy,24+x,cy+yy),SHIRT_DEEP)
    line(d,[(18+x,34+yy),(20+x,36+yy)],SHIRT_D)
    line(d,[(30+x,34+yy),(31+x,32+yy)],SHIRT_D)
    rect(d,(28+x,30+yy,30+x,31+yy),SHIRT_L,SHIRT_D)
    # One crossbody strap: across shirt from left shoulder toward bag.
    line(d,[(18+x,24+yy),(23+x,29+yy),(30+x,36+yy)],OUT,width=2)
    line(d,[(19+x,24+yy),(24+x,30+yy),(30+x,36+yy)],BAG_H)
    # Neck beneath head.
    rect(d,(22+x,21+yy,27+x,25+yy),col(SKIN,tier),OUT)
    # Hair volume behind head.
    ell(d,(13+x,7+yy,35+x,24+yy),HAIR)
    poly(d,[(14+x,13+yy),(16+x,9+yy),(20+x,7+yy),(28+x,8+yy),(33+x,10+yy),(35+x,15+yy),(33+x,22+yy),(16+x,22+yy)],HAIR)
    # Large rounded face. Body position/face changes are physical across all tiers.
    ell(d,(15+x,11+yy,34+x,25+yy),col(SKIN,tier))
    ell(d,(15+x,16+yy,17+x,19+yy),col(SKIN_LIGHT,tier))
    ell(d,(32+x,16+yy,35+x,19+yy),col(SKIN_LIGHT,tier))
    # Face warm light and upper shadow.
    line(d,[(18+x,22+yy),(20+x,23+yy),(29+x,23+yy),(31+x,21+yy)],SHADOW)
    poly(d,[(14+x,15+yy),(15+x,11+yy),(18+x,9+yy),(23+x,8+yy),(26+x,10+yy),(30+x,9+yy),(34+x,12+yy),(35+x,15+yy),(30+x,13+yy),(28+x,15+yy),(23+x,13+yy),(19+x,15+yy)],HAIR)
    # Hairstyle matching reference: dark soft side part, uneven locks over forehead.
    poly(d,[(16+x,10+yy),(22+x,8+yy),(24+x,10+yy),(23+x,13+yy),(20+x,15+yy),(16+x,14+yy)],HAIR_L,HAIR)
    poly(d,[(27+x,9+yy),(32+x,11+yy),(33+x,15+yy),(29+x,13+yy),(27+x,15+yy)],HAIR,HAIR)
    line(d,[(25+x,9+yy),(25+x,12+yy)],HAIR_L)
    # glasses with pixel outline, little highlights.
    rect(d,(18+x,17+yy,23+x,20+yy),None,HAIR,1)
    rect(d,(26+x,17+yy,31+x,20+yy),None,HAIR,1)
    line(d,[(23+x,18+yy),(26+x,18+yy)],HAIR)
    line(d,[(16+x,17+yy),(18+x,18+yy)],HAIR)
    line(d,[(31+x,18+yy),(34+x,17+yy)],HAIR)
    rect(d,(18+x,17+yy,19+x,17+yy),SHIRT_L)
    rect(d,(26+x,17+yy,27+x,17+yy),SHIRT_L)
    # Expressive eyes and under-eye bags during fatigue.
    blink=(frame==3 and kind in ['idle','hovering','looking_around','unknown','ready'])
    if sleep or kind=='paused' or fatigue==4 or blink:
        line(d,[(20+x,19+yy),(22+x,19+yy)],HAIR)
        line(d,[(28+x,19+yy),(30+x,19+yy)],HAIR)
    elif fatigue>=2:
        rect(d,(21+x,19+yy,22+x,19+yy),HAIR)
        rect(d,(28+x,19+yy,29+x,19+yy),HAIR)
        if fatigue>=3:
            line(d,[(19+x,21+yy),(23+x,21+yy)],SHADOW)
            line(d,[(27+x,21+yy),(31+x,21+yy)],SHADOW)
    else:
        rect(d,(21+x,18+yy,21+x,19+yy),HAIR)
        rect(d,(28+x,18+yy,28+x,19+yy),HAIR)
    rect(d,(18+x,21+yy,19+x,21+yy),BLUSH)
    rect(d,(30+x,21+yy,31+x,21+yy),BLUSH)
    if kind in ('yawning','needs_input','unknown'):
        opening = (2 + [0,0,1,2,2,1,0,0][frame]) if kind == 'yawning' else 2
        ell(d,(24+x,22+yy,26+x,22+yy+opening),SHADOW,HAIR)
    elif kind in ('failed','interrupted','critical_quota','disconnected') or fatigue>=3:
        line(d,[(24+x,24+yy),(26+x,23+yy),(28+x,24+yy)],HAIR)
    elif kind in ('giggling','celebrating','tiny_dance','booped'):
        line(d,[(23+x,23+yy),(26+x,25+yy),(29+x,23+yy)],OUT)
        rect(d,(26+x,24+yy,26+x,24+yy),BLUSH)
    else:
        line(d,[(24+x,23+yy),(27+x,24+yy)],HAIR)
    if fatigue>=3 and frame%4==1:
        ell(d,(34+x,19+yy,35+x,23+yy),'#76d0e7','#447fac')
    if fatigue==4:
        line(d,[(18+x,12+yy),(19+x,11+yy)],OUT)
        rect(d,(31+x,24+yy,33+x,24+yy),SHADOW)
    # Work arms: screen is behind the actual moving forearms and fingertips.
    if work or kind in ('thinking','coffee_break'):
        impact = round(math.sin(p)*3) if kind == 'typing' else 0
        if work:
            draw_laptop(d,18+x,37+yy,kind=='typing',abs(math.sin(p)))
        # Exactly one arm per shoulder: each sleeve connects to a hand.
        left_hand_y=35+yy+max(0,impact)
        right_hand_y=35+yy+max(0,-impact)
        poly(d,[(16+x,28+yy),(19+x,27+yy),(19+x,33+yy),(22+x,35+yy+max(0,impact)),(20+x,37+yy+max(0,impact)),(16+x,33+yy)],col(SHIRT_D,tier))
        ell(d,(20+x,left_hand_y,23+x,left_hand_y+2),SKIN)
        if kind != 'thinking':
            poly(d,[(32+x,27+yy),(35+x,29+yy),(33+x,34+yy),(30+x,right_hand_y+2),(28+x,right_hand_y),(31+x,31+yy)],col(SHIRT_D,tier))
            ell(d,(27+x,right_hand_y,30+x,right_hand_y+2),SKIN)
        if kind=='typing':
            # Visible alternating hard keystrokes: one fist lifts while the other strikes.
            if impact > 1:
                rect(d,(20+x,40+yy,21+x,40+yy),WHITE)
                line(d,[(18+x,34+yy),(19+x,32+yy)],TEAL)
            elif impact < -1:
                rect(d,(29+x,40+yy,30+x,40+yy),WHITE)
                line(d,[(33+x,34+yy),(34+x,32+yy)],TEAL)
            if frame % 2 == 0:
                rect(d,(16+x,32+yy,16+x,33+yy),TEAL)
        if kind=='thinking':
            # Raise same right arm to the chin; do not duplicate it.
            poly(d,[(32+x,28+yy),(34+x,28+yy),(32+x,24+yy),(29+x,23+yy),(28+x,24+yy),(29+x,27+yy)],col(SHIRT_D,tier))
            ell(d,(27+x,22+yy,30+x,25+yy),SKIN)
        if kind=='coffee_break':
            rect(d,(28+x,30+yy,33+x,34+yy),WHITE,OUT)
            rect(d,(32+x,31+yy,34+x,33+yy),None,OUT)
            steam = (frame % 3)
            line(d,[(30+x,28-steam+yy),(29+x,26-steam+yy)],'#b5c2c7')
    elif stretch or raise_left or raise_right or kind in ('glasses_adjust',):
        # Each arm emerges directly from its respective shoulder; no separate extra hand shapes.
        amount=round((2+math.sin(p)*2))
        if kind=='glasses_adjust':
            # Left arm still down; right hand touches the glasses.
            poly(d,[(16+x,28+yy),(19+x,28+yy),(22+x,35+yy),(19+x,37+yy),(15+x,33+yy)],col(SHIRT_D,tier))
            ell(d,(20+x,35+yy,23+x,38+yy),SKIN)
            move = [0,1,3,4,4,3,1,0][frame]
            palm_y = 32 + yy - move * 3
            poly(d,[(32+x,27+yy),(36+x,27+yy),(36+x,30+yy),
                    (31+x,palm_y+2),(29+x,palm_y+1),(31+x,27+yy)],col(SHIRT_D,tier))
            ell(d,(28+x,palm_y,31+x,palm_y+3),SKIN)
            if move == 4:
                rect(d,(30+x,17+yy,31+x,17+yy),WHITE)
        else:
            left_high= kind=='stretching' or raise_left
            right_high= kind=='stretching' or raise_right
            if left_high:
                poly(d,[(17+x,27+yy),(19+x,27+yy),(15+x,21+yy-amount),(13+x,18+yy-amount),(11+x,20+yy-amount),(14+x,29+yy)],col(SHIRT_D,tier))
                ell(d,(10+x,16+yy-amount,13+x,20+yy-amount),SKIN)
            else:
                poly(d,[(16+x,28+yy),(19+x,28+yy),(22+x,35+yy),(19+x,37+yy),(15+x,33+yy)],col(SHIRT_D,tier))
                ell(d,(20+x,35+yy,23+x,38+yy),SKIN)
            if right_high:
                poly(d,[(32+x,27+yy),(35+x,26+yy),(39+x,21+yy-amount),(40+x,18+yy-amount),(43+x,20+yy-amount),(39+x,28+yy)],col(SHIRT_D,tier))
                if kind=='idle' or kind=='booped' or kind=='hovering':
                    # The two raised fingers are from the SAME right hand.
                    ell(d,(39+x,17+yy-amount,42+x,21+yy-amount),SKIN)
                    line(d,[(40+x,18+yy-amount),(39+x,13+yy-amount)],OUT,2)
                    line(d,[(40+x,18+yy-amount),(43+x,14+yy-amount)],OUT,2)
                    line(d,[(40+x,17+yy-amount),(39+x,13+yy-amount)],SKIN)
                    line(d,[(41+x,18+yy-amount),(43+x,14+yy-amount)],SKIN)
                else:
                    ell(d,(39+x,16+yy-amount,43+x,20+yy-amount),SKIN)
            else:
                poly(d,[(32+x,27+yy),(35+x,28+yy),(34+x,35+yy),(31+x,37+yy),(29+x,35+yy)],col(SHIRT_D,tier))
                ell(d,(29+x,35+yy,32+x,38+yy),SKIN)
            if phone and kind=='idle':
                # Left hand phone held at chest; ONLY move existing arm, do not add an extra one.
                rect(d,(19+x,27+yy,24+x,34+yy),HAIR,OUT)
                rect(d,(20+x,28+yy,23+x,32+yy),'#4c5865')
                rect(d,(21+x,29+yy,22+x,29+yy),SHIRT_D)
    else:
        # Neutral pose: two arms only; for fatigue hands hang lower.
        droop=2 if fatigue>=3 else 0
        poly(d,[(16+x,28+yy),(19+x,28+yy),(22+x,35+yy+droop),(19+x,38+yy+droop),(15+x,33+yy)],col(SHIRT_D,tier))
        ell(d,(20+x,35+yy+droop,23+x,38+yy+droop),SKIN)
        poly(d,[(32+x,27+yy),(35+x,28+yy),(34+x,35+yy+droop),(31+x,37+yy+droop),(29+x,35+yy)],col(SHIRT_D,tier))
        ell(d,(29+x,35+yy+droop,32+x,38+yy+droop),SKIN)
        if phone:
            rect(d,(20+x,29+yy,24+x,35+yy),HAIR,OUT)
            rect(d,(21+x,30+yy,23+x,33+yy),'#5e7d88')
    # Emotive effects are drawn after complete character.
    if kind in ('thinking','unknown'):
        float_y = int(math.sin(p)*2)
        rect(d,(39,10+yy+float_y,40,11+yy+float_y),TEAL)
        rect(d,(38,13+yy,39,13+yy),TEAL)
        rect(d,(39,15+yy,39,15+yy),TEAL)
    if kind in ('needs_input','interrupted'):
        alert_color='#f9bd62' if frame%4 <2 else '#fa8c6c'
        rect(d,(39,8+yy,40,13+yy),alert_color)
        rect(d,(39,15+yy,40,16+yy),'#f9bd62')
    if kind in ('ready','celebrating','tiny_dance'):
        line(d,[(39,9+yy),(42,12+yy),(45,7+yy)],TEAL,width=2)
    if kind in ('failed','disconnected'):
        line(d,[(40,8+yy),(44,12+yy)],BLUSH,width=2)
        line(d,[(44,8+yy),(40,12+yy)],BLUSH,width=2)
    if kind in ('sleeping','yawning'):
        for ox,oy in ((37,11),(41,7)):
            shift = (frame // 2) % 3
            line(d,[(ox,oy+3-shift),(ox+3,oy+3-shift),(ox,oy+1-shift),(ox+3,oy+1-shift)],SHIRT_D)
    if kind in ('syncing','reconnecting'):
        for i in range(3):
            pos=(37+(frame+i)%3*3,8+i*2)
            rect(d,(pos[0],pos[1],pos[0]+1,pos[1]+1),TEAL)
    if kind in ('hovering','booped','giggling','celebrating'):
        for ox,oy in ((11,16),(40,6)):
            rect(d,(ox,oy,ox,oy+3),TEAL)
            rect(d,(ox-1,oy+1,ox+1,oy+1),TEAL)
    if kind in ('empty','critical_quota','exhausted') or fatigue>=3:
        if frame%4 in (1,2):
            rect(d,(12,26+yy,13,28+yy),'#5db6d4')
    if kind == 'annoyed':
        # Anger marks pulse but the character still has exactly two arms.
        shade = BLUSH if frame % 4 < 2 else '#bc5475'
        line(d,[(16+x,16+yy),(19+x,15+yy)],shade,2)
        line(d,[(31+x,15+yy),(34+x,16+yy)],shade,2)
    if kind == 'failed' and frame % 4 < 2:
        rect(d,(35+x,23+yy,36+x,25+yy),'#74c8dc')
    if kind == 'disconnected' and frame % 4 < 2:
        rect(d,(42,14+yy,43,15+yy),VIOLET)
    if kind=='paused':
        rect(d,(39,10,40,15),SHIRT_D)
        rect(d,(43,10,44,15),SHIRT_D)
    return im

# Every transition's visual frame interpolates between two complete poses.
def transition_state(name, f):
    info=manifest['transitions'][name]
    a,b=info['from'],info['to']
    # Key-based ease: beginning mostly source pose, finish destination pose.
    if f<2:return a
    if f>=5:return b
    # Intermediate frames are independently rendered complete-body poses.
    if name in ('start_work','sleep','wake','pause','unpause','pickup','drop'):
        return 'neutral' if f == 3 else (a if f == 2 else b)
    return a if f==2 else b

def render(tier,key,f):
    if key == 'paused':
        return draw_human(tier,key,0)  # intentionally frozen at all energy tiers
    if key in manifest['states']:
        return draw_human(tier,key,f)
    kind=transition_state(key,f)
    # Transition frame can still bob, move, blink; whole figure constructed once.
    return draw_human(tier,kind,(f+2)%8)

# Detect/source file byte correctness with row positions exactly as declared.
for tier in TIERS:
    atlas=Image.new('RGBA',(8*96,68*96),(0,0,0,0))
    for name,clip in [*manifest['states'].items(),*manifest['transitions'].items()]:
        for f in range(8):
            frame=render(tier,name,f).resize((96,96),Image.Resampling.NEAREST)
            atlas.alpha_composite(frame,(f*96,clip['row']*96))
    atlas.save(THEME/(tier+'.png'),optimize=True)

# Standalone preview and targeted frame strips/GIFs for inspection.
def preview_sprite(tier,key,frame):
    return render(tier,key,frame).resize((96,96),Image.Resampling.NEAREST)

def panel_bg(w,h,bg='#ece9e0'):
    return Image.new('RGB',(w,h),bg)

def add_checker(img, sprite, x,y):
    # Light checkerboard helps alpha perception in still previews.
    tmp=Image.new('RGBA',sprite.size,(0,0,0,0));p=ImageDraw.Draw(tmp)
    for sy in range(0,sprite.height,16):
      for sx in range(0,sprite.width,16):
        p.rectangle((sx,sy,sx+15,sy+15),fill=('#edece9' if ((sx//16+sy//16)%2)==0 else '#e4e2dc'))
    tmp.alpha_composite(sprite)
    img.paste(tmp.convert('RGB'),(x,y))

preview=panel_bg(504,440)
d=ImageDraw.Draw(preview)
# magnified original theme on left; six different poses on right.
large=preview_sprite('fresh','idle',1).resize((256,256),Image.Resampling.NEAREST)
add_checker(preview,large,30,44)
for idx,(tier,key) in enumerate([('fresh','typing'),('tired','thinking'),('exhausted','idle'),('fresh','stretching'),('focused','celebrating'),('empty','sleeping')]):
    x0=295+idx%2*100;y0=33+(idx//2)*120
    add_checker(preview,preview_sprite(tier,key,idx%8),x0,y0)
# Small HUD presentation using simple 2 bar colors, not packaged over old UI.
d.rectangle((97,341,223,346),fill='#2f3345');d.rectangle((101,342,208,345),fill='#5bd2c8')
d.rectangle((97,353,223,358),fill='#2f3345');d.rectangle((101,354,162,357),fill='#efa95b')
d.text((36,14),'CODER  /  AgentPet Theme',fill='#343143')
preview.save(ROOT/'preview.png',optimize=True)

energy=panel_bg(5*140,210)
d=ImageDraw.Draw(energy)
for i,tier in enumerate(TIERS):
    x0=i*140+22
    s=preview_sprite(tier,'idle',1).resize((128,128),Image.Resampling.NEAREST)
    add_checker(energy,s,x0,30)
    d.text((x0,172),tier.upper(),fill='#3c3448')
energy.save(ROOT/'energy.png')

for key in ['idle','typing','stretching','glasses_adjust','tiny_dance','dragging','sleeping','needs_input']:
    frames=[preview_sprite('fresh',key,f) for f in range(8)]
    p=panel_bg(8*100+4,104)
    for i,fr in enumerate(frames):add_checker(p,fr,i*100+4,4)
    p.save(PREVIEWS/(key+'.png'))
    frames[0].save(PREVIEWS/(key+'.gif'),save_all=True,append_images=frames[1:],duration=125,loop=0,disposal=2,optimize=False)


# A small native-size sprite for the future Settings theme picker.
preview_sprite('fresh','idle',1).save(THEME/'preview.png')

# All 340 independent state/transition strips and looping visual previews.
for tier in TIERS:
    (ROOT/'strips'/tier).mkdir(parents=True,exist_ok=True)
    (ROOT/'gifs'/tier).mkdir(parents=True,exist_ok=True)
    for name, clip in [*manifest['states'].items(),*manifest['transitions'].items()]:
        frames=[preview_sprite(tier,name,f) for f in range(8)]
        strip=Image.new('RGBA',(768,96))
        for index,fr in enumerate(frames): strip.alpha_composite(fr,(index*96,0))
        strip.save(ROOT/'strips'/tier/(name+'.png'), optimize=True)
        frames[0].save(ROOT/'gifs'/tier/(name+'.gif'), save_all=True,
                       append_images=frames[1:],duration=max(70,round(1000/clip['fps'])),
                       loop=0,disposal=2,optimize=False)

# Small portable manifest hints: folder can be directly copied to app Resources/Themes/coder.
(ROOT/'README.txt').write_text('Coder: pixel chibi based on the provided photo.\nCopy Themes/coder into AgentPet/Resources/Themes/coder. The app discovers bundled themes from their manifests and energy atlases; no theme-specific Swift registration is required.\nUses common Shared HUD and bubble assets. Theme changes affect appearance and animation only.\nSource frames are independently redrawn; 30 states + 38 transitions, 5 energy atlas PNGs.\n',encoding='utf8')
print('Rendered',len(STATE_KEYS),'states,',len(TRANS_KEYS),'transitions, 5 tiers ->',len(STATE_KEYS+TRANS_KEYS)*8*5,'frames')
