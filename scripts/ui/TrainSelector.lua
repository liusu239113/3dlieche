-- 车型抽屉只接收 HUD 注入的数据，不反向引用 Train 或车型资源。
-- UI 组件树负责文字/交互/分页；不另建 NanoVG 上下文或加载图片。
local UI = require "urhox-libs/UI"
local Skin = require "ui.CabStyle"
local C = Skin.Colors

---@class CabTrainCatalogEntry
---@field id string
---@field name string
---@field kind string 动力 / 车型类别，由 Train 提供
---@field description string 编组与车型介绍，由 Train 提供
---@field maxSpeedKmh number 仅保留目录信息，不当作线路限速显示
---@field ready boolean

---@class CabTrainSelectorCallbacks
---@field onSelect? fun(id: string): boolean, string?
---@field onOpen? fun(open: boolean)

---@class CabTrainCardRefs
---@field panel Panel
---@field button Button
---@field name Label
---@field status Label

---@class CabTrainSelector : Panel
---@overload fun(props?: PanelProps): CabTrainSelector
---@field catalog_ CabTrainCatalogEntry[]
---@field rows_ table<string, CabTrainCardRefs>
---@field callbacks_ CabTrainSelectorCallbacks
---@field drawer_ Panel
---@field list_ Panel
---@field pageLabel_ Label
---@field previousPage_ Button
---@field nextPage_ Button
---@field page_ integer
---@field pageSize_ integer
---@field current_ Label
---@field notice_ Label
---@field feedback_ Label
---@field confirm_ Button
---@field selectedId_ string
---@field selectedName_ string
---@field pendingId_ string
---@field open_ boolean
---@field busy_ boolean
---@field speed_ number
---@field limit_ number
local Selector = UI.Panel:Extend("CabTrainSelector")

---@param props PanelProps?
function Selector:Init(props)
    props = props or {}
    props.id = "trainSelector"
    -- Widget:new 在 Init 前快照 instance.id，FindById 只读该字段。
    -- 同步实例 ID，使直接 TrainSelector{} 与 HUD 显式传 ID 都可被查找。
    self.id = props.id
    props.position = "absolute"
    props.left, props.top = 0, 0
    props.width, props.height = "100%", "100%"
    props.visible = false
    props.zIndex = 1000
    -- 透明背景只拦截输入，不给常规仪表铺一层大色块。
    props.onClick = function() self:Close() end
    UI.Panel.Init(self, props)
    self.catalog_, self.rows_, self.callbacks_ = {}, {}, {}
    self.selectedId_, self.selectedName_, self.pendingId_ = "", "待同步车型", ""
    self.open_, self.busy_ = false, false
    self.speed_, self.limit_ = 0, 80
    self.page_, self.pageSize_ = 1, 2

    self.current_ = UI.Label { id = "selectorCurrentTrain", text = "当前：待同步车型",
        fontSize = 10.5, fontColor = C.secondary, maxLines = 1, minWidth = 0 }
    self.notice_ = UI.Label { id = "trainStopNotice", text = "请先停车，再确认换车。",
        fontSize = 10.5, fontColor = C.orange, whiteSpace = "normal", maxLines = 2,
        height = 34, flexShrink = 0 }
    self.feedback_ = UI.Label { id = "trainSelectionFeedback", text = "选择车型后点击确认。",
        fontSize = 10.5, fontColor = C.secondary, whiteSpace = "normal", maxLines = 2,
        height = 34, flexShrink = 0 }
    self.confirm_ = UI.Button { id = "confirmTrain", text = "确认换车", height = 44,
        flexGrow = 1, flexShrink = 1, minWidth = 0, disabled = true,
        variant = "primary", textColor = C.black,
        onClick = function() self:Confirm() end }
    self.list_ = UI.Panel { id = "trainCatalogList", width = "100%",
        flexGrow = 1, flexBasis = 0, flexShrink = 1, minHeight = 0,
        gap = 6, overflow = "hidden" }
    self.pageLabel_ = UI.Label { id = "trainPageNumber", text = "1 / 1",
        fontSize = 10.5, fontColor = C.secondary, textAlign = "center",
        flexGrow = 1, flexShrink = 1, minWidth = 0 }
    self.previousPage_ = UI.Button { id = "previousTrainPage", text = "上一页", height = 44, width = 80,
        variant = "secondary", onClick = function() self:GoToPage(self.page_ - 1) end }
    self.nextPage_ = UI.Button { id = "nextTrainPage", text = "下一页", height = 44, width = 80,
        variant = "secondary", onClick = function() self:GoToPage(self.page_ + 1) end }
    local pagination = UI.Panel { height = 44, flexDirection = "row", alignItems = "center", gap = 6,
        children = { self.previousPage_, self.pageLabel_, self.nextPage_ } }
    self.drawer_ = UI.Panel { id = "trainSelectorDrawer", position = "absolute",
        width = 360, height = 560, padding = 8, gap = 5,
        backgroundColor = C.black, borderColor = C.edge, borderWidth = 1, borderRadius = 6,
        overflow = "hidden", onClick = function() end, children = {
            UI.Panel { height = 44, flexDirection = "row", alignItems = "center", gap = 8,
                children = {
                    UI.Label { text = "选择车型", fontSize = 13.5, fontWeight = "bold",
                        fontColor = C.text, flexGrow = 1, flexShrink = 1, minWidth = 0 },
                    UI.Button { id = "closeTrainSelector", text = "关闭", width = 64, height = 44,
                        variant = "secondary", onClick = function() self:Close() end },
                } },
            self.current_, self.notice_, self.list_, pagination, self.feedback_,
            UI.Panel { height = 44, flexDirection = "row", gap = 8, children = {
                UI.Button { id = "cancelTrainSelection", text = "取消", width = 72, height = 44,
                    variant = "secondary", onClick = function() self:Close() end },
                self.confirm_,
            } },
        } }
    self:AddChild(self.drawer_)
end

---@param callbacks CabTrainSelectorCallbacks
function Selector:SetCallbacks(callbacks)
    self.callbacks_ = callbacks or {}
    self:Refresh()
end

---@param id string
---@return CabTrainCatalogEntry?
function Selector:FindTrain(id)
    for _, entry in ipairs(self.catalog_) do
        if entry.id == id then return entry end
    end
    return nil
end

--- 复制目录，避免写回 Train 的表；重复或空 ID 不创建可选卡片。
---@param catalog CabTrainCatalogEntry[]?
function Selector:SetCatalog(catalog)
    local copy = {} ---@type CabTrainCatalogEntry[]
    local seen = {} ---@type table<string, boolean>
    for _, entry in ipairs(catalog or {}) do
        if type(entry.id) == "string" and entry.id ~= "" and not seen[entry.id] then
            seen[entry.id] = true
            copy[#copy + 1] = {
                id = entry.id, name = entry.name or entry.id, kind = entry.kind or "待补充",
                description = entry.description or "车型与编组介绍待补充。",
                maxSpeedKmh = entry.maxSpeedKmh or 0, ready = entry.ready == true,
            }
        end
    end
    self.catalog_ = copy
    self.page_ = math.min(self.page_, self:GetPageCount())
    local pending = self:FindTrain(self.pendingId_)
    if not pending or not pending.ready then self.pendingId_ = "" end
    self:BuildCards()
    self:Refresh()
end

function Selector:BuildCards()
    -- ClearChildren 只移除；显式销毁旧卡片，避免多次同步目录留下对象。
    local children = self.list_:GetChildren()
    for i = #children, 1, -1 do children[i]:Destroy() end
    self.list_:ClearChildren()
    self.rows_ = {}
    if #self.catalog_ == 0 then
        self.list_:AddChild(UI.Label { text = "车型目录尚未同步。", fontSize = 10.5,
            whiteSpace = "normal", fontColor = C.secondary })
    end
    local first = (self.page_ - 1) * self.pageSize_ + 1
    local last = math.min(#self.catalog_, first + self.pageSize_ - 1)
    for index = first, last do
        local entry = self.catalog_[index]
        local id = entry.id
        -- 仅映射展示文案，不修改目录中的类型标识；未知类型保留原值。
        local kindText = entry.kind == "emu" and "动车组"
            or (entry.kind == "locomotive" and "机车牵引" or entry.kind)
        local name = UI.Label { text = entry.name, fontSize = 12, fontWeight = "bold",
            fontColor = C.text, flexGrow = 1, flexShrink = 1, minWidth = 0,
            whiteSpace = "normal", maxLines = 2 }
        local status = UI.Label { text = "", fontSize = 9, fontColor = C.secondary,
            maxLines = 1, minHeight = 17 }
        local button = UI.Button { id = "selectTrain_" .. id, text = "选择", width = 76, height = 44,
            variant = "secondary", disabled = not entry.ready,
            onClick = function() self:Choose(id) end }
        local card = UI.Panel { id = "trainCard_" .. id, width = "100%", padding = 7, gap = 3,
            flexGrow = 1, flexBasis = 0, flexShrink = 1, minHeight = 126,
            backgroundColor = C.surface, borderColor = C.edge,
            borderWidth = 1, borderRadius = 3, children = {
                UI.Panel { flexDirection = "row", alignItems = "center", gap = 6,
                    children = { name, button } },
                UI.Label { text = "动力 / 类型：" .. kindText, fontSize = 10.5,
                    fontColor = C.secondary, whiteSpace = "normal", maxLines = 1, height = 18 },
                UI.Label { text = "编组介绍：" .. entry.description, fontSize = 10.5,
                    fontColor = C.secondary, whiteSpace = "normal", maxLines = 2,
                    minHeight = 32, flexGrow = 1, flexShrink = 1 },
                status,
            } }
        self.rows_[id] = { panel = card, button = button, name = name, status = status }
        self.list_:AddChild(card)
    end
    self.pageLabel_:SetText(self.page_ .. " / " .. self:GetPageCount())
    self.previousPage_:SetDisabled(self.page_ <= 1)
    self.nextPage_:SetDisabled(self.page_ >= self:GetPageCount())
end

---@return integer
function Selector:GetPageCount()
    return math.max(1, math.ceil(#self.catalog_ / self.pageSize_))
end

---@return integer
function Selector:GetPage() return self.page_ end

---@param page number
function Selector:GoToPage(page)
    local target = math.max(1, math.min(self:GetPageCount(), math.floor(page)))
    if target == self.page_ then return end
    self.page_ = target
    self:BuildCards()
    self:Refresh()
end

---@param id string
---@param name string
function Selector:SetSelected(id, name)
    self.selectedId_, self.selectedName_ = id or "", name or "待同步车型"
    if self.pendingId_ == self.selectedId_ then self.pendingId_ = "" end
    self.current_:SetText("当前：" .. self.selectedName_)
    self:Refresh()
end

---@param speed number
---@param limit number
function Selector:SetOperatingState(speed, limit)
    local stoppedBefore = math.abs(self.speed_) <= 0.1
    local changed = stoppedBefore ~= (math.abs(speed) <= 0.1) or self.limit_ ~= limit
    self.speed_, self.limit_ = speed, limit
    if changed then self:Refresh() end
end

function Selector:Refresh()
    local stopped = math.abs(self.speed_) <= 0.1
    self.notice_:SetText((stopped and "已停车，可确认换车。" or "请先停车，再确认换车。")
        .. "当前线路限速 " .. math.floor(self.limit_ + 0.5) .. " km/h。")
    for _, entry in ipairs(self.catalog_) do
        local row = self.rows_[entry.id]
        if row then
            local current = entry.id == self.selectedId_
            local pending = entry.id == self.pendingId_
            row.panel:SetStyle({ borderColor = pending and C.teal or C.edge })
            row.name:SetFontColor(entry.ready and C.text or C.muted)
            row.status:SetText(not entry.ready and "资源未就绪，暂不可选"
                or (current and "当前驾驶车型" or (pending and "待确认车型" or "可选，确认后按需加载")))
            row.status:SetFontColor(not entry.ready and C.orange or (pending and C.teal or C.secondary))
            row.button:SetText(current and "当前" or (pending and "已选" or "选择"))
            row.button:SetDisabled(not entry.ready or current or self.busy_)
        end
    end
    local pending = self:FindTrain(self.pendingId_)
    self.confirm_:SetDisabled(self.busy_ or not stopped or not self.callbacks_.onSelect
        or not pending or not pending.ready or pending.id == self.selectedId_)
end

---@param id string
function Selector:Choose(id)
    if not self.open_ or self.busy_ then return end
    local entry = self:FindTrain(id)
    if not entry or not entry.ready or id == self.selectedId_ then return end
    self.pendingId_ = id
    self.feedback_:SetText("待确认：" .. entry.name)
    self.feedback_:SetFontColor(C.teal)
    self:Refresh()
end

function Selector:Confirm()
    if not self.open_ or self.busy_ then return end
    local entry = self:FindTrain(self.pendingId_)
    if not entry or not entry.ready or entry.id == self.selectedId_ then return end
    if math.abs(self.speed_) > 0.1 then
        self.feedback_:SetText("请停车后再确认换车。")
        self.feedback_:SetFontColor(C.orange)
        return
    end
    local callback = self.callbacks_.onSelect
    if not callback then
        self.feedback_:SetText("换车回调未接入。")
        self.feedback_:SetFontColor(C.orange)
        return
    end
    self.busy_ = true
    self:Refresh()
    local ok, success, message = pcall(callback, entry.id)
    self.busy_ = false
    if ok and success == true then
        self:Close()
    else
        self.feedback_:SetText(ok and (message or "换车未成功，请重试。") or "换车失败，请重试。")
        self.feedback_:SetFontColor(C.orange)
        if not ok then print("[Hud] 换车回调异常：" .. tostring(success)) end
    end
    self:Refresh()
end

--- 采用 HUD 已计算的安全区/胶囊边距，所有数值为 UI 基准像素。
---@param left number
---@param top number
---@param width number
---@param height number
function Selector:SetBounds(left, top, width, height)
    -- 横屏尽量让右侧速度表和手柄保持可见；窄屏自动收敛到安全区。
    local drawerWidth = math.min(400, width >= 650 and math.max(260, width - 410) or width)
    local reserveTop = height >= 480 and 60 or 0
    local drawerHeight = math.max(0, math.min(560, height - reserveTop))
    local pageSize = drawerHeight >= 532 and drawerWidth >= 320 and 2 or 1
    local compact = drawerHeight < 400
    self.drawer_:SetStyle({ left = left, top = top + reserveTop,
        width = math.max(0, drawerWidth), height = drawerHeight,
        padding = compact and 6 or 8, gap = compact and 3 or 5 })
    self.notice_:SetHeight(compact and 18 or 34)
    self.feedback_:SetHeight(compact and 18 or 34)
    if pageSize ~= self.pageSize_ then
        -- 旋转/缩放时保持原首项所在页，不把用户带到目录另一端。
        local first = (self.page_ - 1) * self.pageSize_ + 1
        self.pageSize_ = pageSize
        self.page_ = math.min(self:GetPageCount(), math.floor((first - 1) / pageSize) + 1)
        self:BuildCards()
        self:Refresh()
    end
end

function Selector:Open()
    if self.open_ then return end
    self.pendingId_ = ""
    self.page_ = 1
    self:BuildCards()
    self.feedback_:SetText(self.callbacks_.onSelect and "选择车型后点击确认。" or "换车回调未接入。")
    self.feedback_:SetFontColor(C.secondary)
    self.open_ = true
    self:Show()
    UI.PushOverlay(self)
    self:Refresh()
    if self.callbacks_.onOpen then self.callbacks_.onOpen(true) end
end

function Selector:Close()
    if not self.open_ then return end
    self.open_, self.pendingId_ = false, ""
    UI.PopOverlay(self)
    self:Hide()
    if self.callbacks_.onOpen then self.callbacks_.onOpen(false) end
end

---@return boolean
function Selector:IsOpen() return self.open_ end

---@param dt number
function Selector:Update(dt)
    -- 用枚举而非数字；不接管既有驾驶键盘控制，main 负责开窗后的输入屏蔽。
    if self.open_ and input:GetKeyPress(KEY_ESCAPE) then self:Close() end
end

return Selector
