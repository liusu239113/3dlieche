-- 声音加载绑定回归：只验证已证实的 VectorBuffer 原生基类转换路径。
-- 不对 File 做多继承盲转换；失败立即记录，不能仅看入口运行帧数判断成功。
local function wave()
    local rate, count = 22050, 22050
    local buffer = VectorBuffer()
    buffer:WriteFileID("RIFF"); buffer:WriteUInt(36 + count * 2); buffer:WriteFileID("WAVE")
    buffer:WriteFileID("fmt "); buffer:WriteUInt(16); buffer:WriteUShort(1); buffer:WriteUShort(1)
    buffer:WriteUInt(rate); buffer:WriteUInt(rate * 2); buffer:WriteUShort(2); buffer:WriteUShort(16)
    buffer:WriteFileID("data"); buffer:WriteUInt(count * 2)
    for i = 1, count do buffer:WriteShort(math.floor(math.sin((i-1)*math.pi*2*440/rate)*6000)) end
    buffer:Seek(0)
    return buffer
end
function Start()
    local sound = Sound()
    local ok, err = pcall(function()
        local buffer = wave()
        local reader = tolua.cast(buffer, "Deserializer") --[[@as Deserializer]]
        assert(sound:LoadWav(reader), "原生内存 WAV 加载失败")
        assert(sound:GetDataSize() == 44100, "把 WAV 头错误计入 PCM 数据")
        assert(sound:GetFrequency() == 22050, "PCM 采样率错误")
        assert(math.abs(sound:GetLength()-1) < .00001, "PCM 时长错误")
        sound:SetLooped(true)
        assert(sound:IsLooped(), "循环标志未生效")
        print("SOUND_BINDING_VALIDATION_PASS assertions=5 bytes=44100 rate=22050 seconds=1")
    end)
    sound:Dispose()
    if not ok then log:Write(LOG_ERROR, tostring(err)); error(err, 0) end
end
