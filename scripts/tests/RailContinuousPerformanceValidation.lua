-- 连续性能观察入口：复用严格A/B脚手架，只把完整几何核对放在采样前后。
-- 严格逐帧核对仍使用tests/RailPerformanceValidation.lua，不被本入口取代。
-- 真实640×360渲染，保留默认100ms框架阈值，不从wallFrameMs扣减检查耗时。
RailPerformanceContinuousSampling = true
require "tests.RailPerformanceValidation"
