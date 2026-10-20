-- One non-modal, bounded dropdown below the actual 线路 action; map and timetable
-- share it instead of stacking over the driving desk. No gameplay/environment dependency.
local UI=require "urhox-libs/UI"
local Skin=require "ui.CabStyle"
local Timetable=require "game.Timetable"
local C=Skin.Colors
---@class CabTimetablePanel
---@field root Panel
---@field map CabMinimap
---@field mapPage ScrollView
---@field timetablePage ScrollView
---@field content Panel
---@field summary Label
---@field condition Label
---@field notice Label
---@field mapTab Button
---@field timeTab Button
---@field rows table[]
---@field signature string
---@field tab string
---@field snapshot table
local Panel={}
Panel.__index=Panel

local function label(id,text,height,color)
    return UI.Label{id=id,text=text,fontSize=10,fontColor=color or C.text,height=height or 18,
        minHeight=height or 18,flexShrink=0,minWidth=0,maxLines=1}
end
local function setText(widget,text)
    if widget:GetText()~=text then widget:SetText(text) end
end

---@param map CabMinimap
---@param onClose fun()
---@return CabTimetablePanel
function Panel.new(map,onClose)
    local self=setmetatable({},Panel)
    self:Init(map,onClose)
    return self
end
function Panel:Init(map,onClose)
    self.map,self.rows,self.signature,self.tab,self.snapshot=map,{},"","map",{}
    self.mapTab=UI.Button{id="routeMapTab",text="线路图",height=48,width=92,paddingHorizontal=3,
        onClick=function() self:SetTab("map") end}
    self.timeTab=UI.Button{id="routeTimetableTab",text="时刻表",height=48,width=92,paddingHorizontal=3,
        onClick=function() self:SetTab("timetable") end}
    self.summary=label("timetableSummary","模拟运行计划待同步",38,C.teal)
    self.summary:SetStyle({whiteSpace="normal",maxLines=2,lineHeight=1.1})
    self.condition=label("timetableCondition","预测以实际驾驶和信号许可为条件",32,C.secondary)
    self.condition:SetStyle({whiteSpace="normal",maxLines=2,lineHeight=1.1})
    self.notice=label("timetableNotice","模拟运行计划 · 非真实班次",32,C.muted)
    self.notice:SetStyle({whiteSpace="normal",maxLines=2,lineHeight=1.1})
    self.content=UI.Panel{id="timetableContent",width="100%",height=112,minHeight=112,padding=6,gap=4,
        flexShrink=0,pointerEvents="box-none",children={self.summary,self.condition,self.notice}}
    self.timetablePage=UI.ScrollView{id="timetableScroll",width="100%",flexGrow=1,flexBasis=0,minHeight=0,
        scrollY=true,scrollX=false,bounces=false,showScrollbar=true,visible=false,
        children={self.content}}
    map:SetStyle({position="relative",width="100%",height=124,minHeight=124,flexShrink=0,visible=true})
    self.mapPage=UI.ScrollView{id="routeMapScroll",width="100%",flexGrow=1,flexBasis=0,minHeight=0,
        scrollY=true,scrollX=false,bounces=false,showScrollbar=true,
        children={UI.Panel{width="100%",height=154,minHeight=154,flexShrink=0,padding=4,gap=4,
            pointerEvents="box-none",children={map,label("mapPlanHint","切换“时刻表”查看计划、预计与实际",18,C.secondary)}}}}
    self.root=UI.Panel{id="routeDropdown",position="absolute",width=314,height=280,visible=false,
        padding=2,gap=2,overflow="hidden",pointerEvents="auto",zIndex=20,
        backgroundColor={12,21,27,238},borderWidth=1,borderColor=C.edge,borderRadius=5,children={
            UI.Panel{height=48,minHeight=48,flexShrink=0,flexDirection="row",gap=4,pointerEvents="box-none",children={
                self.mapTab,self.timeTab,
                UI.Button{id="closeRouteDropdown",text="收起",height=48,minWidth=48,flexGrow=1,
                    paddingHorizontal=2,onClick=onClose},
            }},self.mapPage,self.timetablePage,
        }}
    self:SetTab("map")
end
function Panel:SetTab(tab)
    if tab~="map" and tab~="timetable" then return end
    self.tab=tab
    self.mapPage:SetVisible(tab=="map")
    self.timetablePage:SetVisible(tab=="timetable")
    UI.Layout()
    self.mapPage:UpdateContentSize()
    self.timetablePage:UpdateContentSize()
    self.mapTab:SetStyle({backgroundColor=tab=="map" and C.teal or C.surface})
    self.timeTab:SetStyle({backgroundColor=tab=="timetable" and C.teal or C.surface})
end

--- Width/height computed against the driving desk's bounding edge, NOT the left info card.
--- The dropdown keeps a fixed header while each page scrolls on short screens.
function Panel:SetBounds(anchorX,anchorBottom,rightEdge,deskTop,meterTop,meterLeft)
    local width=math.min(360,math.max(240,rightEdge-anchorX))
    local left=math.min(anchorX,rightEdge-width)
    local top=anchorBottom+6
    local boundary=deskTop
    if left<meterLeft+184 and left+width>meterLeft then boundary=math.min(boundary,meterTop) end
    local height=math.max(70,math.min(414,boundary-top-8))
    self.root:SetStyle({left=left,top=top,width=width,height=height})
end
function Panel:SetVisible(visible) self.root:SetVisible(visible) end

---@param status table?
function Panel:SetStatus(status)
    if not status then return end
    self.snapshot=status
    local nextStop=status.next
    local departure=status.departure
    local summary="世界 "..Timetable.FormatTime(status.minutes).." · 第"..tostring(status.trip or 1).."趟"
    if nextStop then
        summary=summary.."\n"..nextStop.name.." 计划 "..Timetable.FormatTime(nextStop.plannedArrival)
            .." / 预计 "..Timetable.FormatTime(nextStop.expectedArrival)
    elseif departure then summary=summary.."\n"..departure.name..(departure.terminal and " · 终到" or " · 待发") end
    setText(self.summary,summary)
    setText(self.condition,status.condition or "")
    setText(self.notice,status.notice or "模拟运行计划 · 非真实班次")
    local signature=""
    for _,row in ipairs(status.rows or {}) do signature=signature..row.name..":"..row.trip..":"..row.phase..";" end
    if signature~=self.signature then
        for _,refs in ipairs(self.rows) do refs.card:Remove();refs.card:Destroy() end
        self.rows={}
        self.signature=signature
        for i,row in ipairs(status.rows or {}) do
            local title=label("timetableStation_"..i,"",18,C.teal)
            local plan=label("timetablePlan_"..i,"",18)
            local actual=label("timetableActual_"..i,"",18,C.secondary)
            local prediction=label("timetablePrediction_"..i,"",18,C.orange)
            local card=UI.Panel{id="timetableRow_"..i,width="100%",height=82,minHeight=82,flexShrink=0,
                padding=4,gap=0,borderBottomWidth=1,borderBottomColor=C.edge,pointerEvents="none",
                children={title,plan,actual,prediction}}
            self.rows[i]={card=card,title=title,plan=plan,actual=actual,prediction=prediction}
            self.content:AddChild(card)
        end
        local height=126+#self.rows*86
        self.content:SetStyle({height=height,minHeight=height})
    end
    local phases={pending="待到",arrived="站停",departed="已发",cancelled="原计划取消",missed="越站未停"}
    for i,row in ipairs(status.rows or {}) do
        local refs=self.rows[i]
        setText(refs.title,string.format("%s · 第%d趟 · %s",row.name,row.trip,phases[row.phase] or "未知"))
        setText(refs.plan,"计划 到 "..(row.origin and "始发" or Timetable.FormatTime(row.plannedArrival))
            .." / 发 "..(row.terminal and "终到" or Timetable.FormatTime(row.plannedDeparture)))
        setText(refs.actual,"实际 到 "..(row.origin and "—" or Timetable.FormatTime(row.actualArrival))
            .." / 发 "..Timetable.FormatTime(row.actualDeparture))
        local prediction="预计到 "..Timetable.FormatTime(row.expectedArrival)
        if row.expectedDeparture and row.phase=="arrived" then prediction="最早预计发 "..Timetable.FormatTime(row.expectedDeparture) end
        if row.delayKind=="实际发车" or row.delayKind=="实际到达" then prediction=row.delayKind end
        if row.phase=="cancelled" then prediction="旧计划已取消 · 实际记录保留"
        elseif row.phase=="missed" then prediction="未停车 · 无实际到达"
        else prediction=prediction.." · "..Timetable.FormatDelay(row.delayMinutes) end
        setText(refs.prediction,prediction)
    end
end
return Panel
