-- 模式菜单回调/返回/存档隔离与真实布局验收；不加载世界，不接触存档或云。
local UI=require "urhox-libs/UI"
local Menu=require "ui.Menu"
local Modes=require "config.GameModes"
local Validation={}
local checks_=0
local function check(value,message) checks_=checks_+1;assert(value,"[GameModesMenuValidation] "..message) end
local function click(id)
    local root=assert(Menu.GetRoot())
    local widget=assert(root:FindById(id),"missing "..id)
    assert(widget.props.onClick,"not clickable "..id)(widget)
end
function Validation.Run()
    local requests={}
    local saved={normal=true,rage=true}
    Menu.Init({start=function(resume,id) requests[#requests+1]={resume=resume,id=id} end,
        cancel=function() Menu.Show(true) end},
        {quality="performance",sound=true,volume=.75,sensitivity=.2},
        {getSavedMode=function() return "rage" end,hasSavedMode=function(id) return saved[id] end})
    Menu.Show(true)
    check(Menu.GetPage()=="menu","未进入主菜单")
    click("startGame")
    check(Menu.GetPage()=="modes" and #requests==0,"开始按钮未经选择就加载世界")
    check(Modes.GetId()=="normal","打开模式页提前切换了运行配置")
    check(Menu.GetRoot():FindById("modeCard_normal")~=nil and Menu.GetRoot():FindById("modeCard_rage")~=nil,"模式卡片缺失")
    click("modesBack")
    check(Menu.GetPage()=="menu" and #requests==0,"模式返回触发了加载")
    click("continueGame")
    check(#requests==1 and requests[1].resume and requests[1].id=="rage","继续未保留最后存档模式")
    Menu.Show(true);click("startGame");click("selectMode_rage")
    check(#requests==2 and not requests[2].resume and requests[2].id=="rage","狂暴新开错误恢复了普通存档")
    Menu.Loading("测试加载",.25,false,"rage")
    check(Menu.GetPage()=="loading" and Menu.GetProgress()==.25,"加载页未显示")
    Menu.Error("隔离验收，不加载实际世界");click("retryLoading")
    check(#requests==3 and requests[3].id=="rage" and not requests[3].resume,"失败重试丢失模式")
    Menu.Show(true);click("startGame");click("continueMode_normal")
    check(#requests==4 and requests[4].id=="normal" and requests[4].resume,"普通独立继续未带正确模式")
    Menu.Show(true);click("startGame");click("continueMode_rage")
    check(#requests==5 and requests[5].id=="rage" and requests[5].resume,"狂暴独立继续未带正确模式")
    Menu.Show(false);click("startGame")
    check(Menu.GetPage()=="modes","无最后旅程时无法选择模式")
    print(string.format("GAME_MODES_MENU_PASS checks=%d callbacks=%d noScene=true noSave=true noCloud=true",checks_,#requests))
    return checks_
end
function Start()
    local ok,err=xpcall(Validation.Run,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(err));engine:Exit() end
end
function Stop() Menu.Shutdown();UI.Shutdown() end
return Validation
