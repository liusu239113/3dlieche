-- 铁路主题菜单与加载页：共享驾驶台 UI 上下文，只切换页面控件树。
local UI=require "urhox-libs/UI"
local Skin=require "ui.CabStyle"
local Config=require "config.GameConfig"
local Menu={}
local C=Skin.Colors
local DAWN="image/starwave_rail_menu_dawn_20261011122342.png"
local NIGHT="image/starwave_rail_loading_night_20261011122345.png"
local TIPS={
    "在驾驶画面的空白处拖动，可以环顾列车；操作手柄不会带动镜头。",
    "车门关闭、乘降完成后才能发车。别急着加油门，先看站台状态。",
    "提前收油并逐步制动，让列车平稳停入站台。",
    "视角选择中保留了外景、车内和驾驶舱机位，可以随时切换。",
    "超速不会替你收油或制动；危险驾驶可能导致脱轨，本局结束。",
    "换车前请先停稳。新编组需要容纳当前旅程的乘客。",
}
---@type Panel?
local root_=nil
---@type Panel?
local content_=nil
---@type ScrollView?
local scroll_=nil
---@type Label?
local progress_=nil
---@type ProgressBar?
local bar_=nil
---@type Label?
local percent_=nil
---@type Label?
local tip_=nil
local callbacks_={} ---@type table
local settings_={} ---@type table
local resume_,loadingResume_=false,false
local page_="menu"
local ratio_,tipClock_,tipIndex_=0,0,1
local sizeKey_=""

-- 沿用 CabStyle 的低饱和金属色、上下层边框和按压反馈，不使用默认主题按钮外观。
local function button(id,text,action,primary)
    local top=primary and {73,128,121,255} or {41,56,67,240}
    local bottom=primary and {29,70,70,255} or {16,28,38,240}
    return UI.Button{id=id,text=text,height=primary and 56 or 48,width="100%",
        fontSize=primary and 13.5 or 11.5,fontWeight="bold",textColor=C.text,
        variant="secondary",borderRadius=2,borderWidth={1,1,4,1},
        borderColor=primary and {117,176,154,220} or {87,109,120,160},
        padding={4,16,8,16},pressedPadding={8,16,4,16},
        backgroundGradient={direction="to-bottom",from=top,to=bottom},
        hoverBackgroundGradient={direction="to-bottom",from={76,103,112,255},to={29,50,60,255}},
        pressedBackgroundGradient={direction="to-bottom",from={12,26,33,255},to={32,55,62,255}},
        boxShadow={{x=0,y=4,blur=0,color={0,0,0,75}}},pressedBoxShadow={},
        decorations={secondary={{position="absolute",top=2,left=5,right=5,bottom=5,
            borderTopWidth=1,borderTopColor={211,226,221,35},pointerEvents="none"}}},
        onClick=function()
            if callbacks_.click then callbacks_.click() end
            action()
        end}
end
local function label(text,size,color)
    return UI.Label{text=text,fontSize=size or 11,fontColor=color or C.text,
        whiteSpace="normal",maxLines=3,lineHeight=1.2,minWidth=0}
end
local function heading(title,subtitle)
    return UI.Panel{width="100%",gap=8,pointerEvents="none",children={
        UI.Label{text="群域行旅联队  /  铁路运营",fontSize=9,letterSpacing=1.5,fontColor=C.orange},
        UI.Label{text=title,fontSize=26,fontWeight="bold",whiteSpace="normal",maxLines=2,
            textShadow={offsetX=0,offsetY=2,blur=0,color={0,0,0,180}}},
        label(subtitle,11,C.secondary),
        UI.Panel{width=72,height=3,backgroundColor=C.orange,pointerEvents="none"},
    }}
end
local function layoutPage()
    if not content_ or not scroll_ then return end
    local w,h=UI.GetViewportSize()
    local key=string.format("%.0f/%.0f/%s",w,h,page_)
    if key==sizeKey_ then return end
    sizeKey_=key
    local portrait=w<h
    local wide=page_=="settings" or page_=="loading"
    local width=math.min(w-32,wide and 500 or 380)
    content_:SetStyle({width=math.max(0,width),height="100%",
        alignSelf=portrait and "center" or "flex-start",paddingHorizontal=16,
        paddingVertical=h<500 and 12 or 26})
    UI.Widget.SetStyle(scroll_,{paddingVertical=page_=="settings" and 16 or 8})
end
---@class RailwayMenuRoot : Panel
---@overload fun(props?: PanelProps): RailwayMenuRoot
local MenuRoot=UI.Panel:Extend("RailwayMenuRoot")
function MenuRoot:Update(dt)
    layoutPage()
    if page_=="loading" and tip_ then
        tipClock_=tipClock_+dt
        if tipClock_>=5 then
            tipClock_=tipClock_%5
            tipIndex_=tipIndex_%#TIPS+1
            tip_:SetText("驾驶提示 "..tipIndex_.." / "..#TIPS.."\n"..TIPS[tipIndex_])
        end
    end
end
local function mount(children)
    sizeKey_=""
    scroll_=UI.ScrollView{id="menuScroll",width="100%",flexGrow=1,flexBasis=0,
        flexShrink=1,showScrollbar=true,bounces=false,children={
            UI.Panel{width="100%",gap=12,paddingHorizontal=4,paddingBottom=8,children=children}}}
    content_=UI.Panel{id="menuContent",width=380,height="100%",padding=16,
        backgroundGradient={direction="to-bottom",from={8,20,31,170},to={8,18,27,220}},
        borderLeftWidth=1,borderLeftColor={153,175,182,55},children={scroll_}}
    root_=MenuRoot{id="applicationRoot",width="100%",height="100%",pointerEvents="box-none",
        -- 深色底仅用于背景尚在下载的情况；图片就绪后覆盖底色。
        backgroundColor={10,23,35,255},backgroundImage=page_=="menu" and DAWN or NIGHT,
        backgroundFit="cover",children={
            UI.Panel{position="absolute",left=0,top=0,width="100%",height="100%",
                pointerEvents="none",backgroundGradient={direction="to-right",
                    from={5,16,28,95},to={5,16,28,0}}},
            UI.SafeAreaView{width="100%",height="100%",nativeMenuInset=true,
                paddingHorizontal=12,pointerEvents="box-none",children={content_}},
        }}
    UI.SetRoot(root_,true)
    layoutPage()
    print("[Menu] 页面切换 -> "..page_.."；保留 UI 渲染上下文")
end
local function clearProgress()
    progress_,bar_,percent_,tip_=nil,nil,nil,nil
end
function Menu.Init(callbacks,settings)
    callbacks_,settings_=callbacks,settings
    if not UI.GetNVGContext() then UI.Init({theme=Skin.CreateTheme(),scale=UI.Scale.DEFAULT}) end
    UI.SetEnabled(true)
end
function Menu.Show(canResume)
    page_,resume_="menu",canResume==true
    clearProgress()
    ---@type Widget[]
    local children={heading(Config.Title,"星汐 — 云湾干线  /  五站开放旅程"),
        label("沿着山海之间的铁道，驾驶自己的列车。",12),
        UI.Panel{height=4,pointerEvents="none"},
    }
    if resume_ then
        children[#children+1]=button("continueGame","继续旅程  ›",function() callbacks_.start(true) end,true)
    end
    children[#children+1]=button("startGame",resume_ and "开始新旅程" or "开始游戏  ›",function() callbacks_.start(false) end,not resume_)
    children[#children+1]=button("gameSettings","游戏设置",function() Menu.Settings() end,false)
    children[#children+1]=UI.Divider{color={117,142,153,70},spacing=3}
    children[#children+1]=label("六款车队  ·  十六机位  ·  自主驾驶",10,C.orange)
    children[#children+1]=label("点击开始后才加载场景。设备自动存档；网页刷新持久化需启用云存档。",9,C.secondary)
    mount(children)
end
function Menu.Loading(message,ratio,resuming)
    page_,loadingResume_="loading",resuming==true
    ratio_,tipClock_,tipIndex_=0,0,1
    progress_=label(message or "正在准备资源",12)
    progress_.props.id="loadingProgress"
    percent_=UI.Label{id="loadingPercent",text="0%",fontSize=18,fontWeight="bold",fontColor=C.orange}
    bar_=UI.ProgressBar{id="loadingBar",value=0,max=1,showLabel=false,width="100%",height=12,
        borderRadius=1,borderWidth=1,borderColor={113,142,151,180},backgroundColor={8,17,25,245},
        fillGradient={direction="to-right",from={52,127,124,255},to=C.orange}}
    tip_=label("驾驶提示 1 / "..#TIPS.."\n"..TIPS[1],11,C.secondary)
    tip_.props.id="loadingTip"
    mount({heading(resuming and "继续旅程" or "准备旅程","正在准备你的列车与沿线世界"),
        UI.Panel{height=8,pointerEvents="none"},
        UI.Panel{width="100%",flexDirection="row",alignItems="center",justifyContent="space-between",
            children={label("旅程装载",10,C.secondary),percent_}},bar_,progress_,
        UI.Divider{color={117,142,153,70},spacing=5},tip_,
        button("cancelLoading","取消加载 · 返回主菜单",function() callbacks_.cancel() end,false)})
    Menu.Progress(message or "正在准备资源",ratio or 0)
end
function Menu.Progress(message,ratio)
    if page_~="loading" or not progress_ or not bar_ or not percent_ then return end
    ratio_=math.max(ratio_,math.max(0,math.min(1,ratio)))
    progress_:SetText(message)
    bar_:SetValue(ratio_)
    percent_:SetText(math.floor(ratio_*100).."%")
end
function Menu.Error(message)
    page_="error"
    clearProgress()
    mount({heading("加载未完成","旅程尚未开始，可以安全返回或重新尝试"),label(message,11,C.orange),
        button("retryLoading","重试加载",function() callbacks_.start(loadingResume_) end,true),
        button("backToMenu","返回主菜单",function() callbacks_.cancel() end,false)})
end
function Menu.Settings()
    page_="settings"
    clearProgress()
    local function update() if callbacks_.settings then callbacks_.settings(settings_) end end
    mount({heading("游戏设置","设置自动保存；返回后沿用当前旅程"),
        label("画面与声音",11,C.orange),
        button("settingsQuality","画质 · "..(settings_.quality=="detailed" and "细致" or "流畅"),function()
            settings_.quality=settings_.quality=="detailed" and "performance" or "detailed";update();Menu.Settings()
        end,false),
        button("settingsSound",settings_.sound and "声音 · 开启" or "声音 · 关闭",function()
            settings_.sound=not settings_.sound;update();Menu.Settings()
        end,false),label("主音量",10,C.secondary),
        UI.Slider{id="settingsVolume",min=0,max=1,value=settings_.volume,height=44,width="100%",
            trackFillColor=C.teal,thumbColor=C.orange,
            onChange=function(self,value) settings_.volume=value;update() end},
        button("settingsLanguage","上车广播 · "..(settings_.language=="both" and "中英双语" or settings_.language=="zh" and "中文" or settings_.language=="en" and "English" or "关闭"),function()
            local nextLanguage={both="zh",zh="en",en="off",off="both"}
            settings_.language=nextLanguage[settings_.language] or "both";update();Menu.Settings()
        end,false),UI.Divider{color={117,142,153,70},spacing=3},label("操作与存档",11,C.orange),
        label("拖动视角灵敏度",10,C.secondary),
        UI.Slider{id="settingsSensitivity",min=.05,max=.6,value=settings_.sensitivity,height=44,width="100%",
            trackFillColor=C.teal,thumbColor=C.orange,
            onChange=function(self,value) settings_.sensitivity=value;update() end},
        button("settingsCloud",settings_.cloud and "云存档 · 已开启" or "云存档 · 关闭（仅设备）",function()
            settings_.cloud=not settings_.cloud;update();Menu.Settings()
        end,false),label("开启云存档后，进度和设置会保存到当前 TapTap 账号。",9,C.secondary),
        button("settingsBack","返回旅程 / 主菜单",function() if callbacks_.back then callbacks_.back() else Menu.Show(resume_) end end,true)})
end
function Menu.GetRoot() return root_ end
function Menu.GetPage() return page_ end
function Menu.GetProgress() return ratio_ end
-- 页面离开只释放引用。下一页 SetRoot(...,true) 销毁旧树；应用 Stop 才关闭 UI。
function Menu.Shutdown()
    clearProgress()
    root_,content_,scroll_=nil,nil,nil
    page_="inactive"
end
return Menu
