-- 离线烘焙路径表：所有正式 PCM 资源使用字面路径，方便构建引用扫描。
-- 车型运行声始终由 ProceduralAudio.lua 算法生成，不引用现实机车行驶录音。
local Paths = {}
Paths.Version = "fantasy-pcm-v1"
Paths.Metadata = "audio/synthesized/metadata.json"
Paths.Root = "/workspace/assets/"
Paths.TrainLayers = { "idle", "traction", "rolling", "wind" }
Paths.CueKinds = { "horn", "brake", "arrival", "departure" }
Paths.Environments = { "city", "forest", "river", "tunnel" }

---@type table<string, string>
Paths.Wavs = {
    ["blue_white:idle"] = "audio/synthesized/blue_white_idle.wav",
    ["blue_white:traction"] = "audio/synthesized/blue_white_traction.wav",
    ["blue_white:rolling"] = "audio/synthesized/blue_white_rolling.wav",
    ["blue_white:wind"] = "audio/synthesized/blue_white_wind.wav",
    ["DF4D:idle"] = "audio/synthesized/DF4D_idle.wav",
    ["DF4D:traction"] = "audio/synthesized/DF4D_traction.wav",
    ["DF4D:rolling"] = "audio/synthesized/DF4D_rolling.wav",
    ["DF4D:wind"] = "audio/synthesized/DF4D_wind.wav",
    ["SS9G:idle"] = "audio/synthesized/SS9G_idle.wav",
    ["SS9G:traction"] = "audio/synthesized/SS9G_traction.wav",
    ["SS9G:rolling"] = "audio/synthesized/SS9G_rolling.wav",
    ["SS9G:wind"] = "audio/synthesized/SS9G_wind.wav",
    ["HXD3D:idle"] = "audio/synthesized/HXD3D_idle.wav",
    ["HXD3D:traction"] = "audio/synthesized/HXD3D_traction.wav",
    ["HXD3D:rolling"] = "audio/synthesized/HXD3D_rolling.wav",
    ["HXD3D:wind"] = "audio/synthesized/HXD3D_wind.wav",
    ["CRH380A:idle"] = "audio/synthesized/CRH380A_idle.wav",
    ["CRH380A:traction"] = "audio/synthesized/CRH380A_traction.wav",
    ["CRH380A:rolling"] = "audio/synthesized/CRH380A_rolling.wav",
    ["CRH380A:wind"] = "audio/synthesized/CRH380A_wind.wav",
    ["CR400AF:idle"] = "audio/synthesized/CR400AF_idle.wav",
    ["CR400AF:traction"] = "audio/synthesized/CR400AF_traction.wav",
    ["CR400AF:rolling"] = "audio/synthesized/CR400AF_rolling.wav",
    ["CR400AF:wind"] = "audio/synthesized/CR400AF_wind.wav",
    ["environment:city"] = "audio/synthesized/environment_city.wav",
    ["environment:forest"] = "audio/synthesized/environment_forest.wav",
    ["environment:river"] = "audio/synthesized/environment_river.wav",
    ["environment:tunnel"] = "audio/synthesized/environment_tunnel.wav",
    ["blue_white:cue:horn"] = "audio/synthesized/blue_white_horn_fallback.wav",
    ["blue_white:cue:brake"] = "audio/synthesized/blue_white_brake.wav",
    ["blue_white:cue:arrival"] = "audio/synthesized/blue_white_arrival.wav",
    ["blue_white:cue:departure"] = "audio/synthesized/blue_white_departure.wav",
    ["DF4D:cue:horn"] = "audio/synthesized/DF4D_horn_fallback.wav",
    ["DF4D:cue:brake"] = "audio/synthesized/DF4D_brake.wav",
    ["DF4D:cue:arrival"] = "audio/synthesized/DF4D_arrival.wav",
    ["DF4D:cue:departure"] = "audio/synthesized/DF4D_departure.wav",
    ["SS9G:cue:horn"] = "audio/synthesized/SS9G_horn_fallback.wav",
    ["SS9G:cue:brake"] = "audio/synthesized/SS9G_brake.wav",
    ["SS9G:cue:arrival"] = "audio/synthesized/SS9G_arrival.wav",
    ["SS9G:cue:departure"] = "audio/synthesized/SS9G_departure.wav",
    ["HXD3D:cue:horn"] = "audio/synthesized/HXD3D_horn_fallback.wav",
    ["HXD3D:cue:brake"] = "audio/synthesized/HXD3D_brake.wav",
    ["HXD3D:cue:arrival"] = "audio/synthesized/HXD3D_arrival.wav",
    ["HXD3D:cue:departure"] = "audio/synthesized/HXD3D_departure.wav",
    ["CRH380A:cue:horn"] = "audio/synthesized/CRH380A_horn_fallback.wav",
    ["CRH380A:cue:brake"] = "audio/synthesized/CRH380A_brake.wav",
    ["CRH380A:cue:arrival"] = "audio/synthesized/CRH380A_arrival.wav",
    ["CRH380A:cue:departure"] = "audio/synthesized/CRH380A_departure.wav",
    ["CR400AF:cue:horn"] = "audio/synthesized/CR400AF_horn_fallback.wav",
    ["CR400AF:cue:brake"] = "audio/synthesized/CR400AF_brake.wav",
    ["CR400AF:cue:arrival"] = "audio/synthesized/CR400AF_arrival.wav",
    ["CR400AF:cue:departure"] = "audio/synthesized/CR400AF_departure.wav",
}

---@type table<string, string>
Paths.Details = {
    city = "audio/sfx/fantasy/ambience_city_loop.wav",
    forest = "audio/sfx/fantasy/ambience_forest_loop.wav",
    river = "audio/sfx/fantasy/ambience_river_loop.wav",
    tunnel = "audio/sfx/fantasy/ambience_tunnel_loop.wav",
}

return Paths
