-- 中国车型目录。尺寸为米，速度为构造速度；不是当前环线的线路限速。
-- 资产校准只属于对应模型，原蓝白机车仍由Locomotive的专用算法处理。

---@class RollingStockContactBox
---@field x0 number
---@field x1 number
---@field y0 number
---@field y1 number
---@field z0 number
---@field z1 number

---@class RollingStockProfile
---@field id string
---@field modelId string
---@field length number 完整模型纵向包络（含车钩）
---@field width number 完整横向包络
---@field height number 完整垂向包络，升弓车含受电弓
---@field pivot number 两转向架中心半距
---@field cab Vector3 相对车辆中心、线路基准的驾驶位
---@field forwardSign number PCA正Z与驾驶端的关系，由源网格/四视图复核
---@field verified boolean 源网格方向/轮区已实测，未交付资产不能自动宣称就绪
---@field contactLeft RollingStockContactBox
---@field contactRight RollingStockContactBox
---@field underframeTop number 旋正源坐标：轮轨横向校准保持区上限
---@field transitionTop number 旋正源坐标：过渡到完整车宽的高度
---@field description string
---@field roofSource number|nil 源网格车顶基准，受电弓从该点以上独立缩放
---@field roofHeight number|nil 对应米制车顶高度（轨面为零）

---@class TrainCatalogEntry
---@field id string
---@field name string
---@field kind string locomotive|emu
---@field description string
---@field maxSpeedKmh number 构造速度，不等于运营/线路限速
---@field operatingSpeedKmh number 模拟运营速度上限
---@field serviceDeceleration number 保守服务制动 m/s²
---@field head string RollingStockProfile.id，blue_white为专用旧资产
---@field middle string|nil
---@field gap number 车辆完整包络间隙
---@field mass number 全编组质量 kg
---@field maxTractive number 轮周起动牵引力 N
---@field maxBrakeForce number 全编组最大制动力 N
---@field powerW number 轮周可用恒功率 W
---@field resistA number SI Davis 常数 N
---@field resistB number SI Davis 一次系数 N/(m/s)
---@field resistC number SI Davis 二次系数 N/(m/s)²

local TrainCatalog = {}
TrainCatalog.DefaultId = "CR400AF"
TrainCatalog.FallbackId = "blue_white"
TrainCatalog.RailTop = 0.34

-- 以下ROI是对实际LOD0旋正顶点及向下法线的实测轮区，明确避开两端排障器。
-- 与旧蓝白资产按低位/纵向比例猜轮区的算法无关，不共享其尺寸/轮距变形参数。
---@type table<string, RollingStockProfile>
TrainCatalog.Profiles = {
    DF4D = {
        id = "DF4D", modelId = "6eccf171dd6e441791f3ce61bd40fa33",
        length = 21.10, width = 3.309, height = 4.736, pivot = 6.35,
        cab = Vector3(0, 3.43, 8.18), forwardSign = 1, verified = true,
        contactLeft = { x0 = -.077, x1 = -.059, y0 = -.209, y1 = -.195, z0 = -.410, z1 = .414 },
        contactRight = { x0 = .060, x1 = .078, y0 = -.209, y1 = -.195, z0 = -.410, z1 = .414 },
        underframeTop = -.125, transitionTop = -.050,
        description = "LOD0长轴朝源-X；双端驾驶室，旋正+Z为前端；两组Co-Co轮区实测。",
    },
    SS9G = {
        id = "SS9G", modelId = "a85a88cc706247cd97c8e02f1f0f29ba",
        length = 22.216, width = 3.100, height = 5.760, pivot = 6.15,
        roofSource = .085, roofHeight = 4.400,
        cab = Vector3(0, 3.46, 8.62), forwardSign = 1, verified = true,
        contactLeft = { x0 = -.105, x1 = -.077, y0 = -.300, y1 = -.280, z0 = -.432, z1 = .442 },
        contactRight = { x0 = .077, x1 = .099, y0 = -.300, y1 = -.280, z0 = -.432, z1 = .442 },
        underframeTop = -.196, transitionTop = -.126,
        description = "双端电力机车；完整高度包含升起的受电弓，不能整体压成4.1米。",
    },
    HXD3D = {
        id = "HXD3D", modelId = "8171ec0365e941769569318954f384b3",
        length = 22.300, width = 3.100, height = 5.760, pivot = 6.40,
        roofSource = .120, roofHeight = 4.700,
        cab = Vector3(0, 3.51, 8.68), forwardSign = 1, verified = true,
        contactLeft = { x0 = -.105, x1 = -.079, y0 = -.333, y1 = -.312, z0 = -.441, z1 = .442 },
        contactRight = { x0 = .101, x1 = .121, y0 = -.333, y1 = -.312, z0 = -.441, z1 = .442 },
        underframeTop = -.216, transitionTop = -.142,
        description = "双端电力机车；两侧轮区不对称，分别测量，不套DF4D或蓝白参数。",
    },
    CRH380A_head = {
        id = "CRH380A_head", modelId = "80f9bb3515ea4f64bcfc2de900536c75",
        length = 26.50, width = 3.380, height = 3.700, pivot = 8.75,
        cab = Vector3(0, 2.94, 9.15), forwardSign = -1, verified = true,
        contactLeft = { x0 = -.059, x1 = -.038, y0 = -.100, y1 = -.091, z0 = -.365, z1 = .380 },
        contactRight = { x0 = .040, x1 = .059, y0 = -.100, y1 = -.091, z0 = -.365, z1 = .380 },
        underframeTop = -.063, transitionTop = -.038,
        description = "实际LOD0 yaw +0.731552°后鼻子在-Z；源四视图鼻端/平端核实，旋转180°朝+Z。",
    },
    CRH380A_middle = {
        id = "CRH380A_middle", modelId = "df89b600ae834a8c8c3210bae64286bc",
        length = 25.00, width = 3.380, height = 3.700, pivot = 8.75,
        cab = Vector3.ZERO, forwardSign = 1, verified = true,
        contactLeft = { x0 = -.043, x1 = -.028, y0 = -.104, y1 = -.095, z0 = -.430, z1 = .430 },
        contactRight = { x0 = .028, x1 = .044, y0 = -.104, y1 = -.095, z0 = -.430, z1 = .430 },
        underframeTop = -.067, transitionTop = -.038,
        description = "替换平端中间车LOD0重新实测：yaw +0.087950°，两端车顶高一致；不再引用带驾驶鼻的失败资产。",
    },
    CR400AF_head = {
        id = "CR400AF_head", modelId = "ba150fe5fc9841cda95f7109183c3c47",
        length = 27.910, width = 3.360, height = 4.050, pivot = 8.750,
        cab = Vector3(0, 3.04, 9.72), forwardSign = -1, verified = true,
        contactLeft = { x0 = -.052, x1 = -.038, y0 = -.128, y1 = -.117, z0 = -.380, z1 = .418 },
        contactRight = { x0 = .052, x1 = .069, y0 = -.128, y1 = -.117, z0 = -.380, z1 = .418 },
        underframeTop = -.084, transitionTop = -.053,
        description = "LOD0 yaw +24.431624°后鼻子在-Z；+Z为端门，按四视图复核鼻端需翻转180°。",
    },
    CR400AF_middle = {
        id = "CR400AF_middle", modelId = "93b1cac4ba724bddb92d058ca9f04c2f",
        length = 25.650, width = 3.360, height = 4.050, pivot = 8.750,
        cab = Vector3.ZERO, forwardSign = 1, verified = true,
        contactLeft = { x0 = -.050, x1 = -.034, y0 = -.125, y1 = -.114, z0 = -.438, z1 = .420 },
        contactRight = { x0 = .034, x1 = .052, y0 = -.125, y1 = -.114, z0 = -.438, z1 = .420 },
        underframeTop = -.083, transitionTop = -.051,
        description = "实际LOD0 yaw +89.991540°；两侧外踏面高于内轮缘，避开整体minY校准。",
    },
}

-- 模拟调校参数，不声称工程精确。R=A+B*v+C*v² 为全编组阻力(N)，v用m/s。
-- 机车质量含7×52t客车；动车质量为8节总质量。P为轮周可用W，非电源输入功率。
---@type TrainCatalogEntry[]
TrainCatalog.Entries = {
    { id = "blue_white", name = "蓝白经典内燃机车", kind = "locomotive", head = "blue_white", gap = 1.025,
        description = "原蓝白机车+7客车，专用校准已离线缓存；模拟运营120km/h。", maxSpeedKmh = 120,
        operatingSpeedKmh = 120, serviceDeceleration = .5,
        mass = 502000, maxTractive = 300000, maxBrakeForce = 450000, powerW = 2400000,
        resistA = 9000, resistB = 100, resistC = 25 },
    { id = "DF4D", name = "东风4D", kind = "locomotive", head = "DF4D", gap = .35,
        description = "中国客运内燃机车，1机车+7客车；模拟运营160km/h。", maxSpeedKmh = 170,
        operatingSpeedKmh = 160, serviceDeceleration = .5,
        mass = 502000, maxTractive = 330000, maxBrakeForce = 460000, powerW = 3300000,
        resistA = 9000, resistB = 90, resistC = 22 },
    { id = "SS9G", name = "韶山9G", kind = "locomotive", head = "SS9G", gap = .35,
        description = "中国客运电力机车，1机车+7客车；模拟运营160km/h。", maxSpeedKmh = 170,
        operatingSpeedKmh = 160, serviceDeceleration = .5,
        mass = 490000, maxTractive = 320000, maxBrakeForce = 450000, powerW = 4800000,
        resistA = 8500, resistB = 90, resistC = 22 },
    { id = "HXD3D", name = "和谐3D", kind = "locomotive", head = "HXD3D", gap = .35,
        description = "双驾驶室电力机车，1机车+7客车；模拟运营160km/h。", maxSpeedKmh = 160,
        operatingSpeedKmh = 160, serviceDeceleration = .5,
        mass = 490000, maxTractive = 330000, maxBrakeForce = 460000, powerW = 6000000,
        resistA = 8500, resistB = 85, resistC = 21 },
    { id = "CRH380A", name = "和谐号 CRH380A", kind = "emu", head = "CRH380A_head", middle = "CRH380A_middle", gap = .25,
        description = "8节：头+6中间+反向尾；模拟运营300km/h，构造380km/h。", maxSpeedKmh = 380,
        operatingSpeedKmh = 300, serviceDeceleration = .7,
        mass = 420000, maxTractive = 320000, maxBrakeForce = 500000, powerW = 8800000,
        resistA = 5000, resistB = 50, resistC = 6.5 },
    { id = "CR400AF", name = "复兴号 CR400AF", kind = "emu", head = "CR400AF_head", middle = "CR400AF_middle", gap = .25,
        description = "8节：头+6中间+反向尾；模拟运营350km/h，非统一限速80。", maxSpeedKmh = 350,
        operatingSpeedKmh = 350, serviceDeceleration = .7,
        mass = 430000, maxTractive = 330000, maxBrakeForce = 515000, powerW = 9750000,
        resistA = 5200, resistB = 48, resistC = 6.2 },
}

-- 正常运行只引用这些独立缓存；源modelId仅供显式离线Bake使用。
-- 所有资源路径必须是完整字面量，避免Web增强引用遗漏动态拼接。
---@class RollingStockAsset
---@field modelPath string
---@field metadataPath string
---@field diffusePath string
---@field normalPath string
---@type table<string, RollingStockAsset>
TrainCatalog.Assets = {
    blue_white = { modelPath = "RollingStockBaked/blue_white.mdl", metadataPath = "RollingStockBaked/blue_white.json",
        diffusePath = "model/228b03702ab649048d477f0df9bf5feb/Textures/228b03702ab649048d477f0df9bf5feb_00_D.jpg",
        normalPath = "model/228b03702ab649048d477f0df9bf5feb/Textures/228b03702ab649048d477f0df9bf5feb_00_N.png" },
    DF4D = { modelPath = "RollingStockBaked/DF4D.mdl", metadataPath = "RollingStockBaked/DF4D.json",
        diffusePath = "RollingStockBaked/DF4D_D.jpg", normalPath = "RollingStockBaked/DF4D_N.png" },
    SS9G = { modelPath = "RollingStockBaked/SS9G.mdl", metadataPath = "RollingStockBaked/SS9G.json",
        diffusePath = "RollingStockBaked/SS9G_D.jpg", normalPath = "RollingStockBaked/SS9G_N.png" },
    HXD3D = { modelPath = "RollingStockBaked/HXD3D.mdl", metadataPath = "RollingStockBaked/HXD3D.json",
        diffusePath = "RollingStockBaked/HXD3D_D.jpg", normalPath = "RollingStockBaked/HXD3D_N.png" },
    CRH380A_head = { modelPath = "RollingStockBaked/CRH380A_head.mdl", metadataPath = "RollingStockBaked/CRH380A_head.json",
        diffusePath = "RollingStockBaked/CRH380A_head_D.jpg", normalPath = "RollingStockBaked/CRH380A_head_N.png" },
    CRH380A_middle = { modelPath = "RollingStockBaked/CRH380A_middle.mdl", metadataPath = "RollingStockBaked/CRH380A_middle.json",
        diffusePath = "RollingStockBaked/CRH380A_middle_D.jpg", normalPath = "RollingStockBaked/CRH380A_middle_N.png" },
    CR400AF_head = { modelPath = "RollingStockBaked/CR400AF_head.mdl", metadataPath = "RollingStockBaked/CR400AF_head.json",
        diffusePath = "RollingStockBaked/CR400AF_head_D.jpg", normalPath = "RollingStockBaked/CR400AF_head_N.png" },
    CR400AF_middle = { modelPath = "RollingStockBaked/CR400AF_middle.mdl", metadataPath = "RollingStockBaked/CR400AF_middle.json",
        diffusePath = "RollingStockBaked/CR400AF_middle_D.jpg", normalPath = "RollingStockBaked/CR400AF_middle_N.png" },
}

---@param id string
---@return TrainCatalogEntry|nil
function TrainCatalog.Find(id)
    for _, entry in ipairs(TrainCatalog.Entries) do
        if string.lower(entry.id) == string.lower(id) then return entry end
    end
    return nil
end

return TrainCatalog
