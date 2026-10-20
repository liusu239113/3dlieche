-- 压缩解码器设备探针：不仅检查LoadOggVorbis头信息，更验证解码器实际推进。
local root_=Node()
local sounds_={} ---@type Sound[]
local buffers_={} ---@type VectorBuffer[]
local sources_={} ---@type SoundSource[]
local frame_=0
local PATH="audio/music/rage_ignition_loop.ogg"
function Start()
    local ok,message=pcall(function()
        assert(audio:SetMode(50,44100,true,true) and audio:Play(),"audio device not initialized")
        for i=1,3 do
            local sound
            if i==3 then sound=assert(cache:GetResource("Sound",PATH)) --[[@as Sound]]
            else
                local file=assert(cache:GetFile(PATH)) --[[@as File]]
                local buffer=file:Read(file:GetSize());file:Dispose();buffer:Seek(0)
                sound=Sound()
                if i==2 then sound.name=PATH end
                assert(sound:LoadOggVorbis(tolua.cast(buffer,"Deserializer") --[[@as Deserializer]]))
                buffers_[#buffers_+1]=buffer
            end
            sound:SetLooped(true);sounds_[i]=sound
            local source=root_:CreateChild("Decoder"..i):CreateComponent("SoundSource")
            source:SetSoundType("FantasyRail.DecoderProbe");source:Play(sound,0,.05)
            sources_[i]=source
            print(string.format("[RageDecoder] initial i=%d name=%s playing=%s bytes=%d length=%.3f frequency=%.0f",i,sound.name,tostring(source:IsPlaying()),sound:GetDataSize(),sound:GetLength(),source:GetFrequency()))
        end
        engine:SetMaxFps(20);SubscribeToEvent("Update","RageDecoderUpdate")
    end)
    if not ok then print("RAGE_DECODER_FAILED "..tostring(message));engine:Exit() end
end
function RageDecoderUpdate()
    frame_=frame_+1
    if frame_==10 then
        for i,source in ipairs(sources_) do
            print(string.format("[RageDecoder] end i=%d playing=%s time=%.3f frequency=%.0f",i,tostring(source:IsPlaying()),source:GetTimePosition(),source:GetFrequency()))
        end
        engine:Exit()
    end
end
function Stop()
    for _,source in ipairs(sources_) do source:StopImmediate();source:Remove();source:Dispose() end
    root_:Dispose()
    for i,sound in ipairs(sounds_) do if i~=3 then sound:Dispose() end end
end
