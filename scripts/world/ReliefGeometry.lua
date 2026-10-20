-- 地貌条带沿既有Route切线扫掠；父节点由Landmarks/WorldStream拥有。
-- 净空设计（负侧例；米）
-- 山外脚outer -- 山脊crest -- 分级岩坡 -- toe>=28 |维护带| 下行0 上行+5
-- 坡底Y=轨基-.25；坡面端部80..180m smoothstep归零，禁止悬浮山片。
-- 普通条带沿Route高程；狂暴连续山体由MountainProfile+Terrain空间格承担，不叠两层地表。
-- 隧口边坡开放中央孔，不提交跨越两股道的端盖/地表/假门牌。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Relief = {}
local function smooth(v)
    local t=math.max(0,math.min(1,v))
    return t*t*(3-2*t)
end
local function point(s,x,y) return Route.SampleOffset(s,x,y) end
local function batch(owner,name,material)
    local out=World.NewBatch(owner:CreateChild(name),material,false,8)
    out.geometry.viewMask=6
    out.geometry.drawDistance=2600
    return out
end
local function rock()
    return World.Textured("ReliefWeatheredRock","Textures/Railway/ballast.png",Color(.48,.46,.40),.98)
end
local function quad(target,a,b,c,d)
    -- 每面真实绕序且双面可见；相机射线mask4同样识别实山，不靠反法线假双面。
    target:AddQuad(a,b,c,d);target:AddQuad(d,c,b,a)
end
function Relief.SlopeSection(def,s)
    local fade=math.min(180,(def.last-def.first)*.25)
    local envelope=smooth((s-def.first)/fade)*smooth((def.last-s)/fade)
    local phase=def.first*.0013
    local height=def.height*envelope*(.88+.08*math.sin(s/97+phase)+.04*math.sin(s/41-phase))
    local span=def.crest-def.toe
    local rows={
        {x=def.toe,y=-.25},
        {x=def.toe+span*.14,y=height*.16-.25},
        {x=def.toe+span*.29,y=height*.36-.25},
        {x=def.toe+span*.43,y=height*.38-.25},
        {x=def.toe+span*.62,y=height*.68-.25},
        {x=def.toe+span*.76,y=height*.70-.25},
        {x=def.crest,y=height-.25},
        {x=def.crest+(def.outer-def.crest)*.44,y=height*.64-.25},
        {x=def.outer,y=-.25},
    }
    return rows,height
end
function Relief.BuildSlope(owner,def,first,last,data,pause)
    local stone=batch(owner,def.id.."_连续分级岩切坡",rock())
    local grass=batch(owner,def.id.."_丘陵草坡",World.Grassland())
    local a,b=math.max(first,def.first),math.min(last,def.last)
    -- 固定全线20m采样并插入块边界，跨240m块使用同一解析断面。
    local s=a
    while s<b-.001 do
        local finish=math.min(b,(math.floor(s/20)+1)*20)
        local aa,ha=Relief.SlopeSection(def,s)
        local bb,hb=Relief.SlopeSection(def,finish)
        for i=1,#aa-1 do
            local target=(i==3 or i==5 or i>=7 or def.height<55) and grass or stone
            quad(target,point(s,def.side*aa[i].x,aa[i].y),point(finish,def.side*bb[i].x,bb[i].y),
                point(finish,def.side*bb[i+1].x,bb[i+1].y),point(s,def.side*aa[i+1].x,aa[i+1].y))
        end
        data.maxMountainHeight=math.max(data.maxMountainHeight,ha,hb)
        data.slopeLength=data.slopeLength+finish-s
        if pause then pause() end
        s=finish
    end
    data.vertices=data.vertices+stone:Finish();if pause then pause() end
    data.vertices=data.vertices+grass:Finish();if pause then pause() end
    data.meshes=data.meshes+2;data.slopes[def.id]=true
end
function Relief.BuildPortalApproach(owner,def,first,last,data,pause)
    local stone=batch(owner,def.id.."_渐变开敞洞口切坡",rock())
    local grass=batch(owner,def.id.."_洞口草坡",World.Grassland())
    local length=def.portalTransition or 80
    local function profile(s,entry)
        local progress=entry and (s-(def.first-length))/length or ((def.last+length)-s)/length
        local t=smooth(progress)
        local toe=28-(28-9.5)*t
        local height=38*t
        return {{x=toe,y=-.25},{x=toe+7*t,y=height*.62},{x=toe+22*t,y=height*.76},
            {x=60,y=height*.42},{x=94,y=-.25}}
    end
    for _,entry in ipairs({true,false}) do
        local a=math.max(first,entry and def.first-length or def.last)
        local b=math.min(last,entry and def.first or def.last+length)
        local s=a
        while s<b-.001 do
            local finish=math.min(b,(math.floor(s/20)+1)*20)
            local aa,bb=profile(s,entry),profile(finish,entry)
            for _,side in ipairs({-1,1}) do
                for i=1,#aa-1 do
                    quad(i<3 and stone or grass,
                        point(s,def.lateral+side*aa[i].x,aa[i].y),point(finish,def.lateral+side*bb[i].x,bb[i].y),
                        point(finish,def.lateral+side*bb[i+1].x,bb[i+1].y),point(s,def.lateral+side*aa[i+1].x,aa[i+1].y))
                end
            end
            data.portalApproachLength=data.portalApproachLength+finish-s
            if pause then pause() end
            s=finish
        end
    end
    data.vertices=data.vertices+stone:Finish();if pause then pause() end
    data.vertices=data.vertices+grass:Finish();if pause then pause() end
    data.meshes=data.meshes+2
end
return Relief
