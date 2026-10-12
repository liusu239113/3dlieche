-- 非模态镜头选择：目录与权威选择由 main 注入，不依赖 Camera/Game。
-- 只在自身小面板内优先命中；不暂停物理、不占用油门/制动区域。
local UI = require "urhox-libs/UI"
local Skin = require "ui.CabStyle"
local C = Skin.Colors

---@class CabCameraCatalogEntry
---@field id string
---@field name string

---@class CabCameraSelectorCallbacks
---@field onSelect? fun(id: string): boolean?, string? false 拒绝；nil/true 仅表示已发出请求
---@field onOpen? fun(open: boolean)

---@class CabCameraButtonRefs
---@field button Button
---@field name Label
---@field current boolean

---@class CabCameraSelector : Panel
---@overload fun(props?: PanelProps): CabCameraSelector
---@field catalog_ CabCameraCatalogEntry[]
---@field buttons_ table<string, CabCameraButtonRefs>
---@field callbacks_ CabCameraSelectorCallbacks
---@field current_ Label
---@field grid_ Panel
---@field pageLabel_ Label
---@field previous_ Button
---@field next_ Button
---@field page_ integer
---@field pageSize_ integer
---@field columns_ integer
---@field selectedId_ string
---@field selectedName_ string
---@field open_ boolean
---@field busy_ boolean
local Selector = UI.Panel:Extend("CabCameraSelector")

---@param props PanelProps?
function Selector:Init(props)
    props = props or {}
    props.id = props.id or "cameraSelector"
    self.id = props.id
    props.position = "absolute"
    props.width, props.height = 320, 282
    props.visible, props.zIndex = false, 900
    props.padding, props.gap = 6, 6
    -- 与 CabStyle/TrainSelector 相同的低饱和金属表面，不新增主题或字体。
    props.backgroundColor, props.borderColor = C.black, C.edge
    props.borderWidth, props.borderRadius = 1, 6
    props.overflow = "hidden"
    props.onClick = function() end
    UI.Panel.Init(self, props)
    self.catalog_, self.buttons_, self.callbacks_ = {}, {}, {}
    self.page_, self.pageSize_, self.columns_ = 1, 6, 2
    self.selectedId_, self.selectedName_ = "", "待同步视角"
    self.open_, self.busy_ = false, false
    self.current_ = UI.Label { id = "cameraSelectorCurrent", text = "当前：待同步视角",
        height = 18, fontSize = 9, fontColor = C.secondary, maxLines = 1,
        minWidth = 0, flexShrink = 1 }
    self.grid_ = UI.Panel { id = "cameraCatalogGrid", width = "100%", gap = 6,
        minHeight = 44, flexGrow = 1, flexBasis = 0, flexShrink = 1 }
    self.pageLabel_ = UI.Label { id = "cameraPageNumber", text = "1 / 1",
        fontSize = 9, fontColor = C.secondary, textAlign = "center", maxLines = 1,
        flexGrow = 1, flexShrink = 1, minWidth = 0 }
    self.previous_ = UI.Button { id = "previousCameraPage", text = "上页",
        width = 48, height = 44, paddingHorizontal = 3, variant = "secondary",
        onClick = function() self:GoToPage(self.page_ - 1) end }
    self.next_ = UI.Button { id = "nextCameraPage", text = "下页",
        width = 48, height = 44, paddingHorizontal = 3, variant = "secondary",
        onClick = function() self:GoToPage(self.page_ + 1) end }
    self:AddChild(UI.Panel { height = 44, flexDirection = "row", alignItems = "center", gap = 6,
        pointerEvents = "box-none", children = {
            UI.Label { text = "视角", fontSize = 12, fontWeight = "bold", fontColor = C.text,
                flexGrow = 1, flexShrink = 1, minWidth = 0, maxLines = 1 },
            UI.Button { id = "closeCameraSelector", text = "关闭", width = 48, height = 44,
                paddingHorizontal = 3, variant = "secondary", onClick = function() self:Close() end },
        } })
    self:AddChild(self.current_)
    self:AddChild(self.grid_)
    self:AddChild(UI.Panel { height = 44, flexDirection = "row", alignItems = "center", gap = 3,
        pointerEvents = "box-none", children = { self.previous_, self.pageLabel_, self.next_ } })
end

---@param callbacks CabCameraSelectorCallbacks?
function Selector:SetCallbacks(callbacks)
    self.callbacks_ = callbacks or {}
    self:RefreshButtons()
end

---@param id string
---@return CabCameraCatalogEntry?
function Selector:FindCamera(id)
    for _, entry in ipairs(self.catalog_) do
        if entry.id == id then return entry end
    end
    return nil
end

--- 去重并复制；相同目录不重建控件，也不写回 Camera 的目录表。
---@param catalog CabCameraCatalogEntry[]?
function Selector:SetCatalog(catalog)
    local copy = {} ---@type CabCameraCatalogEntry[]
    local seen = {} ---@type table<string, boolean>
    for _, entry in ipairs(catalog or {}) do
        if type(entry.id) == "string" and entry.id ~= "" and not seen[entry.id] then
            seen[entry.id] = true
            copy[#copy + 1] = { id = entry.id,
                name = type(entry.name) == "string" and entry.name ~= "" and entry.name or entry.id }
        end
    end
    local changed = #copy ~= #self.catalog_
    if not changed then
        for i, entry in ipairs(copy) do
            if entry.id ~= self.catalog_[i].id or entry.name ~= self.catalog_[i].name then changed = true; break end
        end
    end
    if not changed then return end
    self.catalog_ = copy
    self.page_ = math.min(self.page_, self:GetPageCount())
    self:BuildButtons()
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
    self:BuildButtons()
end

function Selector:BuildButtons()
    local children = self.grid_:GetChildren()
    for i = #children, 1, -1 do children[i]:Destroy() end
    self.grid_:ClearChildren()
    self.buttons_ = {}
    local first = (self.page_ - 1) * self.pageSize_ + 1
    local last = math.min(#self.catalog_, first + self.pageSize_ - 1)
    for rowFirst = first, last, self.columns_ do
        local row = UI.Panel { height = 44, width = "100%", flexDirection = "row", gap = 6,
            pointerEvents = "box-none" }
        for index = rowFirst, math.min(last, rowFirst + self.columns_ - 1) do
            local entry = self.catalog_[index]
            local id = entry.id
            local name = UI.Label { text = entry.name, fontSize = 9.5, fontWeight = "bold",
                fontColor = C.text, width = "100%", height = "100%", textAlign = "center",
                verticalAlign = "middle", whiteSpace = "normal", maxLines = 2, minWidth = 0 }
            local button = UI.Button { id = "selectCamera_" .. id, height = 44, width = 0,
                flexGrow = 1, flexBasis = 0, flexShrink = 1, minWidth = 0, padding = 3,
                variant = "secondary", disabled = not self.callbacks_.onSelect,
                alignItems = "center", justifyContent = "center", children = { name },
                onClick = function() self:Choose(id) end }
            row:AddChild(button)
            self.buttons_[id] = { button = button, name = name, current = false }
        end
        self.grid_:AddChild(row)
    end
    if #self.catalog_ == 0 then
        self.grid_:AddChild(UI.Label { text = "视角目录待同步", fontSize = 9,
            fontColor = C.muted, maxLines = 2, whiteSpace = "normal" })
    end
    self.pageLabel_:SetText(self.page_ .. "/" .. self:GetPageCount())
    self.previous_:SetDisabled(self.page_ <= 1)
    self.next_:SetDisabled(self.page_ >= self:GetPageCount())
    self:RefreshButtons()
end

function Selector:RefreshButtons()
    for id, row in pairs(self.buttons_) do
        local current = id == self.selectedId_
        if row.current ~= current then
            row.current = current
            row.button:SetStyle({ borderColor = current and C.teal or C.edge })
            row.name:SetFontColor(current and C.teal or C.text)
        end
        local disabled = current or self.busy_ or not self.callbacks_.onSelect
        if row.button:IsDisabled() ~= disabled then row.button:SetDisabled(disabled) end
    end
end

---@param id string
---@param name string?
function Selector:SetSelected(id, name)
    local entry = self:FindCamera(id)
    local selectedName = name or (entry and entry.name) or id
    if self.selectedId_ == id and self.selectedName_ == selectedName then return end
    self.selectedId_, self.selectedName_ = id, selectedName
    self.current_:SetText("当前：" .. selectedName)
    self:RefreshButtons()
end

--- 唯一选镜头路径：真实 Button -> onSelect(id) -> main -> Camera。
--- 不使用 onCamera 重放 N 次，也不把发出请求当作权威选择。
---@param id string
function Selector:Choose(id)
    if not self.open_ or self.busy_ or id == self.selectedId_ then return end
    local entry = self:FindCamera(id)
    local callback = self.callbacks_.onSelect
    if not entry or not callback then return end
    self.busy_ = true
    local ok, accepted, message = pcall(callback, id)
    self.busy_ = false
    if ok and accepted ~= false then
        self:Close()
    else
        self.current_:SetText(ok and (message or "视角未切换，请重试") or "视角回调失败")
        if not ok then print("[Hud] 视角回调异常：" .. tostring(accepted)) end
    end
    self:RefreshButtons()
end

--- bounds 已由 HUD 排除油门/制动矩形，不接受全屏捕获层。
---@param left number
---@param top number
---@param width number
---@param height number
function Selector:SetBounds(left, top, width, height)
    local columns = width >= 270 and 2 or 1
    local rows = math.max(1, math.min(4, math.floor((height - 138 + 6) / 50)))
    local pageSize = columns * rows
    self:SetStyle({ left = left, top = top, width = width, height = math.min(height, 138 + rows * 50 - 6) })
    if self.columns_ ~= columns or self.pageSize_ ~= pageSize then
        local first = (self.page_ - 1) * self.pageSize_ + 1
        self.columns_, self.pageSize_ = columns, pageSize
        self.page_ = math.min(self:GetPageCount(), math.floor((first - 1) / pageSize) + 1)
        self:BuildButtons()
    end
end

function Selector:Open()
    if self.open_ then return end
    local selectedIndex = 1
    for i, entry in ipairs(self.catalog_) do
        if entry.id == self.selectedId_ then selectedIndex = i; break end
    end
    self.page_ = math.floor((selectedIndex - 1) / self.pageSize_) + 1
    self:BuildButtons()
    self.current_:SetText(self.callbacks_.onSelect and ("当前：" .. self.selectedName_) or "选择回调未接入")
    self.open_ = true
    self:Show()
    UI.PushOverlay(self)
    if self.callbacks_.onOpen then self.callbacks_.onOpen(true) end
end

function Selector:Close()
    if not self.open_ then return end
    self.open_ = false
    UI.PopOverlay(self)
    self:Hide()
    if self.callbacks_.onOpen then self.callbacks_.onOpen(false) end
end
---@return boolean
function Selector:IsOpen() return self.open_ end

---@param dt number
function Selector:Update(dt)
    if self.open_ and input:GetKeyPress(KEY_ESCAPE) then self:Close() end
end
function Selector:Destroy()
    self:Close()
    UI.Panel.Destroy(self)
end

return Selector
