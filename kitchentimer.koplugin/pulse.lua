--[[
Frontlight pulse: the Kindle has no speaker, so alerts flash the light.

Flashes between full and off a few times, then puts the light back exactly as it was. Uses the
hardware call (setIntensityHW) so KOReader's own idea of the brightness is never changed; if the
Kindle sleeps or the screen closes mid-flash, restore() puts the saved level back.

Dependencies are passed in so the restore paths can be tested without KOReader.
]]

local Pulse = {}
Pulse.__index = Pulse

Pulse.FLASHES = 3
Pulse.STEP = 0.45   -- seconds each way

-- deps = { device = Device, ui = UIManager, logger = logger }
function Pulse.new(deps)
    return setmetatable({ device = deps.device, ui = deps.ui, logger = deps.logger, saved = nil, queue = nil }, Pulse)
end

function Pulse:_pd()
    if not self.device:hasFrontlight() then return nil end
    return self.device:getPowerDevice()
end

function Pulse:_set(pd, level)
    local ok, err = pcall(pd.setIntensityHW, pd, level)
    if not ok and self.logger then self.logger.warn("Kitchen Timer: frontlight pulse failed", tostring(err)) end
    return ok
end

-- Put the light back and cancel anything still scheduled. Safe to call any time, any number of times.
function Pulse:restore()
    if self.tick_fn then self.ui:unschedule(self.tick_fn); self.tick_fn = nil end
    local saved = self.saved
    self.saved, self.queue = nil, nil
    if not saved then return end
    local pd = self:_pd()
    if pd then self:_set(pd, saved.on and saved.level or pd.fl_min) end
end

function Pulse:active() return self.saved ~= nil end

-- Start a flash sequence (ignored while one is already running or there is no frontlight).
function Pulse:flash()
    if self.saved then return false end
    local ok, pd = pcall(self._pd, self)
    if not ok or not pd then return false end
    self.saved = { on = pd:isFrontlightOn(), level = pd.fl_intensity }
    local q = {}
    for _ = 1, Pulse.FLASHES do
        q[#q + 1] = "hi"; q[#q + 1] = "lo"
    end
    self.queue = q
    self.tick_fn = function() self:_step() end
    self:_step()
    return true
end

function Pulse:_step()
    local pd = self:_pd()
    local q = self.queue
    if not pd or not q or #q == 0 then
        self:restore()
        return
    end
    local what = table.remove(q, 1)
    if not self:_set(pd, what == "hi" and pd.fl_max or pd.fl_min) then
        self:restore()
        return
    end
    self.ui:scheduleIn(Pulse.STEP, self.tick_fn)
end

return Pulse
