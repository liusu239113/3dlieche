-- 铁路主题菜单与加载页：共享驾驶台 UI 上下文，只切换页面控件树。
local UI=require "urhox-libs/UI"
local Skin=require "ui.CabStyle"
local Config=require "config.GameConfig"
local GameModes=require "config.GameModes"
local VisualQuality=require "config.VisualQuality"
local EnvironmentSettings=require "ui.EnvironmentSettings"
local Menu={}
local C=Skin.Colors
local DAWN="image/starwave_rail_menu_dawn_20261012054718.png"
local NIGHT="image/starwave_rail_loading_night_20261012054745.png"
local TIPS={
    "在驾驶画面的空白处拖动，可以环顾列车；操作手柄不会带动镜头。",
    "车门关闭、乘降完成后才能发车。别急着加油门，先看站台状态。",
    "提前收油并逐步制动，让列车平稳停入站台。",
    "视角选择中保留了外景、车内和驾驶舱机位，可以随时切换。",
    "超速不会替你收油或制动；危险驾驶可能导致脱轨，本局结束。",
    "换车前请先停稳。新编组需要容纳当前旅程的乘客。",
    "车灯按钮或 L 键循环自动 / 常亮 / 关闭；自动模式白天熄灯并非失效。",
    "音乐按钮只开关音乐；若显示总静音或音量0，请点声音或音量调整。",
}
local RAGE_TIPS={
    "其他列车正常成列行驶；玩家撞击才会触发后续连锁，不会自行撞飞。",
    "道岔改变真实路径，不会把列车瞬移到另一条股道。提前规划分流。",
    "追尾会把动量传给前车；玩家触发后的连撞与清线来自列车之间的相互作用。",
    "狂暴模式取消线路限速与超速侧翻，仍可使用制动控制撞击时机。",
    "长直道适合追逐，大弯与站场适合观察混合车流重新汇合。",
    "此模式自由驾驶，不要求逐站完成客运任务；回主菜单可切回普通运营。",
}
---@type Panel?
local modeCards_=nil
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
local context_={} ---@type table
local resume_,loadingResume_=false,false
local loadingMode_="normal"
local page_="menu"
local ratio_,tipClock_,tipIndex_=0,0,1
local sizeKey_=""
local pendingAction_=nil ---@type fun()?
local pendingActionId_=""

-- 触摸抬起事件仍在 UI 输入分发栈内时，不直接替换根节点。
-- 移动端嵌套 SetRoot 会让本次点击只有按压反馈；下一帧执行可保证页面切换可靠。
local function executePendingAction()
    local action=pendingAction_
    local id=pendingActionId_
    pendingAction_,pendingActionId_=nil,""
    if not action then return end
    print("[Menu] 执行按钮动作："..id)
    local ok,err=pcall(action)
    if not ok then
        print("[Menu] 按钮动作失败："..tostring(err))
        if callbacks_.actionError then callbacks_.actionError(err) end
    end
end

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
            -- 音效是可选资源，不能因为异步音效加载/设备状态异常阻断按钮业务。
            if callbacks_.click then
                local clicked,clickError=pcall(callbacks_.click)
                if not clicked then
                    print("[Menu] 按钮音效失败，继续执行按钮动作："..tostring(clickError))
                end
            end
            local acted,actionError=pcall(function()
                pendingActionId_=id
                pendingAction_=action
            end)
            if not acted then
                print("[Menu] 按钮动作排队失败："..tostring(actionError))
                if callbacks_.actionError then callbacks_.actionError(actionError) end
            end
        end}
end
local function label(text,size,color)
    return UI.Label{text=text,fontSize=size or 11,fontColor=color or C.text,
        whiteSpace="normal",maxLines=3,lineHeight=1.2,minWidth=0}
end
local function heading(title,subtitle)
    -- 字体测量存在亚像素取整差异，底部留2px自然高度，避免长标题容器少1px。
    return UI.Panel{id="menuHeading",width="100%",gap=8,paddingBottom=2,pointerEvents="none",children={
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
    local safe=UI.GetSafeAreaInsets()
    local key=string.format("%.0f/%.0f/%s/%.0f/%.0f",w,h,page_,safe.left,safe.right)
    if key==sizeKey_ then return end
    sizeKey_=key
    local portrait=w<h
    local wide=page_=="settings" or page_=="loading" or page_=="modes"
    local width=math.min(w-safe.left-safe.right-32,page_=="modes" and 760 or (wide and 500 or 380))
    if modeCards_ then
        local sideBySide=width>=600
        modeCards_:SetStyle({flexDirection=sideBySide and "row" or "column",alignItems="stretch"})
        for _,card in ipairs(modeCards_:GetChildren()) do
            card:SetStyle({width=sideBySide and "auto" or "100%",flexGrow=sideBySide and 1 or 0,
                flexBasis=sideBySide and 0 or "auto",flexShrink=1,minWidth=0})
        end
    end
    content_:SetStyle({width=math.max(0,width),height="100%",
        alignSelf=portrait and "center" or "flex-start",paddingHorizontal=16,
        paddingVertical=h<500 and 12 or 26})
    UI.Widget.SetStyle(scroll_,{paddingVertical=page_=="settings" and 16 or 8})
end
---@class RailwayMenuRoot : Panel
---@overload fun(props?: PanelProps): RailwayMenuRoot
local MenuRoot=UI.Panel:Extend("RailwayMenuRoot")
function MenuRoot:Update(dt)
    executePendingAction()
    layoutPage()
    if page_=="loading" and tip_ then
        tipClock_=tipClock_+dt
        if tipClock_>=5 then
            tipClock_=tipClock_%5
            local tips=loadingMode_=="rage" and RAGE_TIPS or TIPS
            tipIndex_=tipIndex_%#tips+1
            tip_:SetText("驾驶提示 "..tipIndex_.." / "..#tips.."\n"..tips[tipIndex_])
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
        backgroundColor={10,23,35,255},backgroundImage=(page_=="menu" or page_=="modes") and DAWN or NIGHT,
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
    progress_,bar_,percent_,tip_,modeCards_=nil,nil,nil,nil,nil
end
local function savedMode()
    local get=context_.getSavedMode or callbacks_.getSavedMode
    return GameModes.Normalize(get and get() or nil)
end
local function hasSavedMode(id)
    local has=context_.hasSavedMode or callbacks_.hasSavedMode
    if has then return has(id)==true end
    return resume_ and savedMode()==id
end
local function beginJourney(resuming,id)
    if page_=="loading" then return end -- 同一次指针释放不能重复触发加载。
    loadingResume_,loadingMode_=resuming==true,GameModes.Normalize(id)
    print("[Menu] 请求"..(loadingResume_ and "继续" or "新旅程").." / "..loadingMode_)
    -- 主入口负责Apply -> Route.Build；菜单本身不更改已存在的世界/存档。
    callbacks_.start(loadingResume_,loadingMode_)
end
-- 环境真源属于 main；兼容旧 Init(callbacks,settings)，第三参仅传状态访问器。
function Menu.Init(callbacks,settings,context)
    callbacks_,settings_=callbacks or {},settings or {}
    context_=context or {}
    if not UI.GetNVGContext() then UI.Init({theme=Skin.CreateTheme(),scale=UI.Scale.DEFAULT}) end
    UI.SetEnabled(true)
end
function Menu.Show(canResume)
    page_,resume_="menu",canResume==true
    clearProgress()
    local normal=GameModes.Get("normal")
    ---@type Widget[]
    local children={heading(Config.Title,normal.routeName.."  /  十站开放旅程"),
        label("沿着山海之间的铁道，驾驶自己的列车。",12),
        UI.Panel{height=4,pointerEvents="none"},
    }
    if resume_ then
        local id=savedMode()
        children[#children+1]=button("continueGame","继续旅程 · "..GameModes.Get(id).name.."  ›",
            function() beginJourney(true,savedMode()) end,true)
    end
    children[#children+1]=button("startGame",resume_ and "开始新旅程" or "开始游戏  ›",function() Menu.Modes() end,not resume_)
    children[#children+1]=button("gameSettings","游戏设置",function() Menu.Settings() end,false)
    children[#children+1]=UI.Divider{color={117,142,153,70},spacing=3}
    children[#children+1]=label("六款车队  ·  十六机位  ·  自主驾驶",10,C.orange)
    children[#children+1]=label("点击开始后才加载场景。设备自动存档；网页刷新持久化需启用云存档。",9,C.secondary)
    mount(children)
end
---@param id string
---@return Panel
local function modeCard(id)
    local mode=GameModes.Get(id)
    local rage=id=="rage"
    local accent=rage and C.orange or C.teal
    local canContinue=hasSavedMode(id)
    ---@type Widget[]
    local children={
        label((rage and "02 / 涌现试验" or "01 / 铁路运营")..(canContinue and "  ·  已有旅程" or "  ·  全新旅程"),9,accent),
        UI.Label{text=mode.name,fontSize=20,fontWeight="bold",fontColor=C.text},
        label(mode.subtitle,10,accent),
        UI.Divider{color={117,142,153,70},spacing=2},
        label(string.format("%s · %.1f km · %d米站台",mode.routeName,mode.routeLength/1000,mode.platformLength),10,C.text),
        label(rage and "独立山地地图：多组S弯、山腰回头、高桥峡谷与高原山口。" or "十站山海干线：保留原五站，延伸翠川、石门、云脊、松岚与天池山地区段。",10,C.secondary),
        label(rage and "其他列车正常成列行驶，玩家撞击才形成连锁；区间道岔可提前预选分流。"
            or "按站序接送乘客，遵守站区与曲线速度；危险驾驶仍有脱轨风险。",10,C.secondary),
        label(rage and "自由驾驶、取消线路限速和超速侧翻，无强制客运任务。" or "熟悉列车、平稳停站，在山海之间完成旅程。",10,accent),
    }
    if canContinue then
        children[#children+1]=button("continueMode_"..id,"继续"..mode.name.."旅程  ›",function() beginJourney(true,id) end,true)
    end
    children[#children+1]=button("selectMode_"..id,canContinue and "重开此模式旅程" or ("进入"..mode.name.."  ›"),
        function() beginJourney(false,id) end,not canContinue)
    return UI.Panel{id="modeCard_"..id,width="100%",minWidth=0,flexShrink=1,padding=14,gap=9,
        backgroundGradient={direction="to-bottom",from=rage and {57,42,32,235} or {26,49,51,235},to={13,24,32,245}},
        borderRadius=2,borderWidth={2,1,3,1},borderColor={84,104,113,180},
        borderTopColor=accent,boxShadow={{x=0,y=4,blur=0,color={0,0,0,65}}},children=children}
end
--- 开始游戏只打开轻量模式页，不建Scene，不调用Apply，不覆盖另一个模式的存档。
function Menu.Modes()
    page_="modes"
    clearProgress()
    modeCards_=UI.Panel{id="modeCards",width="100%",gap=14,alignItems="stretch",
        children={modeCard("normal"),modeCard("rage")}}
    mount({heading("选择驾驶模式","同一片星澜群域，两种不同的铁路旅程"),
        modeCards_,label("两种模式的旅程分别保存。切换模式不会把旧线路坐标带入新地图。",9,C.secondary),
        button("modesBack","返回主菜单",function() Menu.Show(resume_) end,false)})
end
function Menu.Loading(message,ratio,resuming,modeId)
    page_,loadingResume_="loading",resuming==true
    if modeId then loadingMode_=GameModes.Normalize(modeId) end
    modeCards_=nil
    local mode=GameModes.Get(loadingMode_)
    local tips=loadingMode_=="rage" and RAGE_TIPS or TIPS
    ratio_,tipClock_,tipIndex_=0,0,1
    progress_=label(message or "正在准备资源",12)
    progress_.props.id="loadingProgress"
    percent_=UI.Label{id="loadingPercent",text="0%",fontSize=18,fontWeight="bold",fontColor=C.orange}
    bar_=UI.ProgressBar{id="loadingBar",value=0,max=1,showLabel=false,width="100%",height=12,
        borderRadius=1,borderWidth=1,borderColor={113,142,151,180},backgroundColor={8,17,25,245},
        fillGradient={direction="to-right",from={52,127,124,255},to=C.orange}}
    tip_=label("驾驶提示 1 / "..#tips.."\n"..tips[1],11,C.secondary)
    tip_.props.id="loadingTip"
    mount({heading(resuming and "继续旅程" or "准备旅程",mode.name.." / "..mode.routeName.." · 正在准备列车与沿线世界"),
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
    percent_:SetText(string.format("%.2f%%",ratio_*100))
end
function Menu.Error(message)
    page_="error"
    clearProgress()
    mount({heading("加载未完成","旅程尚未开始，可以安全返回或重新尝试"),label(message,11,C.orange),
        button("retryLoading","重试加载",function() beginJourney(loadingResume_,loadingMode_) end,true),
        button("backToMenu","返回主菜单",function() callbacks_.cancel() end,false)})
end
function Menu.Settings(context)
    if context then context_=context end
    page_="settings"
    clearProgress()
    local function update() if callbacks_.settings then callbacks_.settings(settings_) end end
    local environment=EnvironmentSettings{id="environmentSettings",width="100%",gap=10,pointerEvents="box-none"}
    environment:Configure(function()
        if not callbacks_.onEnvironmentChanged then return nil end
        if context_.getEnvironmentState then return context_.getEnvironmentState() end
        return context_.environment
    end,function(patch)
        if callbacks_.onEnvironmentChanged then callbacks_.onEnvironmentChanged(patch) end
    end,button)
    mount({heading("游戏设置","设置自动保存；返回后沿用当前旅程"),environment,
        UI.Divider{color={117,142,153,70},spacing=3},
        label("画面与声音",11,C.orange),
        button("settingsQuality","画质 · "..VisualQuality.Label(settings_.quality),function()
            settings_.quality=VisualQuality.Next(settings_.quality);update();Menu.Settings()
        end,false),
        button("settingsSound",settings_.sound and "总声音 · 开启" or "总声音 · 静音",function()
            settings_.sound=not settings_.sound;update();Menu.Settings()
        end,false),label("主音量（影响所有声音）",10,C.secondary),
        UI.Slider{id="settingsVolume",min=0,max=1,value=settings_.volume or .75,height=44,width="100%",
            trackFillColor=C.teal,thumbColor=C.orange,
            onChange=function(self,value) settings_.volume=value;update() end},
        label("列车音量 · 怠速 / 牵引 / 轮轨",10,C.secondary),
        UI.Slider{id="settingsTrainVolume",min=0,max=1,value=settings_.trainVolume or 1,height=44,width="100%",
            trackFillColor=C.teal,thumbColor=C.orange,
            onChange=function(self,value) settings_.trainVolume=value;update() end},
        button("settingsMusic",settings_.music~=false and "背景音乐 · 开启" or "背景音乐 · 关闭",function()
            settings_.music=settings_.music==false;update();Menu.Settings()
        end,false),label("音乐音量（关闭不丢失音量）",10,C.secondary),
        UI.Slider{id="settingsMusicVolume",min=0,max=1,value=settings_.musicVolume or .35,height=44,width="100%",
            trackFillColor=C.teal,thumbColor=C.orange,
            onChange=function(self,value) settings_.musicVolume=value;update() end},
        label("环境音量 · 人群 / 沿线环境",10,C.secondary),
        UI.Slider{id="settingsAmbienceVolume",min=0,max=1,value=settings_.ambienceVolume or .45,height=44,width="100%",
            trackFillColor=C.teal,thumbColor=C.orange,
            onChange=function(self,value) settings_.ambienceVolume=value;update() end},
        label("到站广播 · 车长播报",10,C.secondary),
        UI.Slider{id="settingsAnnouncementVolume",min=0,max=1,value=settings_.announcementVolume or .85,height=44,width="100%",
            trackFillColor=C.teal,thumbColor=C.orange,
            onChange=function(self,value) settings_.announcementVolume=value;update() end},
        label("行驶与牵引时，音乐、人群及广播自动降低；列车声音始终优先。",9,C.secondary),
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
function Menu.ShowSettings(context) Menu.Settings(context) end
function Menu.GetRoot() return root_ end
function Menu.GetPage() return page_ end
function Menu.GetProgress() return ratio_ end
-- 页面离开只释放引用。下一页 SetRoot(...,true) 销毁旧树；应用 Stop 才关闭 UI。
function Menu.Shutdown()
    pendingAction_,pendingActionId_=nil,""
    clearProgress()
    root_,content_,scroll_=nil,nil,nil
    page_="inactive"
end
return Menu
