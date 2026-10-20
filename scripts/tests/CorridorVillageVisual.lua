-- 隔离乡野场景图验入口，无存档/云访问。
local Visual = require "tests.CorridorVisualValidation"
function Start() Visual.Run("village") end
