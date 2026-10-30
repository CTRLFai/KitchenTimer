--[[
Keep the Kindle awake while a cook is running (it can't alert if it's asleep).

Same recipe as Relic's meditation screen (relic.koplugin/meditate.lua), which found the hard way that a
bare `preventScreenSaver 1` crashes KOReader's AutoSuspend: KOReader's own KeepAlive plugin also
sets PluginShare.keepalive so AutoSuspend stands down, and pauses its timer with
PluginShare.pause_auto_suspend.

A missed release drains the battery overnight, so:
  * the hold is recorded in a settings flag of its own (not Relic's), so a crash can't leave it on
    forever: releaseStale() clears one left behind the next time KOReader starts;
  * on()/off() are idempotent, and off() restores exactly what was there before;
  * the screen calls off() on Finish, on leaving, on suspend, on exit/restart and in its error path.

Dependencies are passed in so the release paths can be tested without KOReader.
]]

local KeepAwake = {}
KeepAwake.__index = KeepAwake

KeepAwake.FLAG = "kitchentimer_keep_awake"

-- deps = { device = Device, share = PluginShare, settings = G_reader_settings, exec = os.execute,
--          logger = logger }
function KeepAwake.new(deps)
    return setmetatable({
        device = deps.device, share = deps.share, settings = deps.settings,
        exec = deps.exec or os.execute, logger = deps.logger,
    }, KeepAwake)
end

function KeepAwake:_preventScreenSaver(on)
    if self.device:isKindle() then
        self.exec("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (on and "1" or "0"))
    end
end

function KeepAwake:isOn() return self.settings:isTrue(KeepAwake.FLAG) end

function KeepAwake:on()
    if self:isOn() then return end
    self.had_keepalive = self.share.keepalive
    self.had_pause = self.share.pause_auto_suspend
    self.share.pause_auto_suspend = true
    self.share.keepalive = true      -- AutoSuspend must not touch powerd's timer while this is on
    self:_preventScreenSaver(true)
    self.settings:makeTrue(KeepAwake.FLAG)
    self.settings:flush()
end

function KeepAwake:off()
    if not self:isOn() then return end
    self.share.pause_auto_suspend = self.had_pause or nil
    self.share.keepalive = self.had_keepalive or nil
    -- If something else (KOReader's KeepAlive, Relic) already held it before us, leave their hold alone.
    if not self.had_keepalive then self:_preventScreenSaver(false) end
    self.settings:delSetting(KeepAwake.FLAG)
    self.settings:flush()
end

-- Called when the plugin starts: a flag that survived means KOReader died while holding.
function KeepAwake:releaseStale()
    if self:isOn() then
        if self.logger then self.logger.warn("Kitchen Timer: clearing a keep-awake left over from an interrupted cook") end
        self.had_keepalive, self.had_pause = nil, nil
        self:off()
    end
end

return KeepAwake
