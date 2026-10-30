-- Keep-awake release paths, frontlight restore, updater config.
-- Run from kitchentimer.koplugin/:  luajit ../tools/tests/test_safety.lua
package.path = "./?.lua;" .. package.path
local function eq(a, b, msg)
    if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

------------------------------------------------------------------------------------------------
-- Keep-awake
------------------------------------------------------------------------------------------------
local KeepAwake = dofile("keepawake.lua")

local function rig(kindle, share)
    local cmds = {}
    local flags = {}
    local settings = {
        isTrue = function(_, k) return flags[k] == true end,
        makeTrue = function(_, k) flags[k] = true end,
        delSetting = function(_, k) flags[k] = nil end,
        flush = function() end,
    }
    local ka = KeepAwake.new{
        device = { isKindle = function() return kindle end },
        share = share or {}, settings = settings,
        exec = function(c) cmds[#cmds + 1] = c end,
        logger = { warn = function() end },
    }
    return ka, cmds, flags
end
local HOLD, FREE = "lipc-set-prop com.lab126.powerd preventScreenSaver 1", "lipc-set-prop com.lab126.powerd preventScreenSaver 0"

do -- on / off restore exactly what was there, and release the screensaver block
    local share = {}
    local ka, cmds, flags = rig(true, share)
    ka:on()
    eq(share.keepalive, true); eq(share.pause_auto_suspend, true); eq(cmds[1], HOLD); eq(flags[KeepAwake.FLAG], true)
    ka:on(); eq(#cmds, 1, "on() twice holds once")
    ka:off()
    eq(share.keepalive, nil); eq(share.pause_auto_suspend, nil); eq(cmds[2], FREE); eq(flags[KeepAwake.FLAG], nil)
    ka:off(); eq(#cmds, 2, "off() twice releases once")
end

do -- someone else already held it (KOReader's KeepAlive plugin, or Relic): we must not release their hold
    local share = { keepalive = true, pause_auto_suspend = true }
    local ka, cmds = rig(true, share)
    ka:on(); ka:off()
    eq(share.keepalive, true); eq(share.pause_auto_suspend, true)
    for _, c in ipairs(cmds) do assert(c ~= FREE, "released a hold that was not ours") end
end

do -- not a Kindle (emulator): no lipc call at all
    local ka, cmds = rig(false)
    ka:on(); ka:off(); eq(#cmds, 0)
end

do -- crash: the flag survives, the next start clears it and releases the hold
    local share = {}
    local ka, cmds, flags = rig(true, share)
    ka:on()
    -- KOReader dies here. A new process starts with fresh memory (share empty again) but the settings file kept the flag.
    local share2 = {}
    local ka2 = KeepAwake.new{ device = { isKindle = function() return true end }, share = share2,
        settings = ka.settings, exec = function(c) cmds[#cmds + 1] = c end, logger = { warn = function() end } }
    ka2:releaseStale()
    eq(flags[KeepAwake.FLAG], nil, "stale flag cleared")
    eq(cmds[#cmds], FREE, "screensaver block released after a crash")
    eq(share2.keepalive, nil)
    ka2:releaseStale()  -- nothing left: no second release
    eq(cmds[#cmds], FREE); eq(#cmds, 2)
end

do -- wiring: PluginShare is a module, not a global (the emulator crashed on START when main.lua used it bare)
    local f = assert(io.open("main.lua")); local src = f:read("*a"); f:close()
    assert(src:find('local PluginShare = require("pluginshare")', 1, true), "main.lua must require pluginshare")
end

------------------------------------------------------------------------------------------------
-- Frontlight pulse
------------------------------------------------------------------------------------------------
local Pulse = dofile("pulse.lua")

local function pulse_rig(opts)
    opts = opts or {}
    local log, queue, calls = {}, {}, 0
    local pd = { fl_min = 0, fl_max = 24, fl_intensity = opts.level or 12, _on = opts.on ~= false }
    function pd:isFrontlightOn() return self._on end
    function pd:setIntensityHW(n)
        calls = calls + 1
        if opts.fail_at and calls == opts.fail_at then error("lipc down") end  -- one failed call
        log[#log + 1] = n
    end
    local ui = {
        scheduleIn = function(_, d, fn) queue[#queue + 1] = fn end,
        unschedule = function(_, fn) for i = #queue, 1, -1 do if queue[i] == fn then table.remove(queue, i) end end end,
    }
    local dev = { hasFrontlight = function() return opts.has ~= false end, getPowerDevice = function() return pd end }
    local p = Pulse.new{ device = dev, ui = ui, logger = { warn = function() end } }
    local function run() while #queue > 0 do table.remove(queue, 1)() end end
    return p, pd, log, run, queue
end

do -- a full sequence ends exactly where it started (light was on at 12)
    local p, _, log, run = pulse_rig{ level = 12, on = true }
    assert(p:flash()); run()
    eq(log[1], 24); eq(log[2], 0); eq(log[#log], 12, "restored to the old level")
    eq(p:active(), false)
end

do -- light was off: ends off
    local p, _, log, run = pulse_rig{ level = 12, on = false }
    assert(p:flash()); run()
    eq(log[#log], 0, "stays off if it was off")
end

do -- the Kindle sleeps or the screen closes mid-flash: restore() puts it back and nothing else fires
    local p, _, log, run, queue = pulse_rig{ level = 9, on = true }
    p:flash()
    eq(log[#log], 24)
    p:restore()
    eq(log[#log], 9); eq(#queue, 0, "pending flash steps cancelled")
    p:restore(); eq(#log, 2, "restore twice does nothing more")
end

do -- no frontlight (emulator, some models): nothing happens, nothing throws
    local p, _, log = pulse_rig{ has = false }
    eq(p:flash(), false); eq(#log, 0)
end

do -- a second flash while one is running is ignored
    local p, _, log, run = pulse_rig{}
    assert(p:flash()); eq(p:flash(), false); run()
end

do -- hardware error mid-sequence: gives up and still tries to restore
    local p, pd, log, run = pulse_rig{ level = 12, on = true, fail_at = 3 }
    p:flash(); run()
    eq(p:active(), false)
    eq(log[#log], 12, "restored after a failure")
end

------------------------------------------------------------------------------------------------
-- Updater config (public repo only, own file names)
------------------------------------------------------------------------------------------------
local SETTINGS = os.tmpname() .. "_dir"
os.execute("mkdir -p " .. SETTINGS)
local stub = function(t) return function() return t end end
package.preload["datastorage"] = stub({ getSettingsDir = function() return SETTINGS end, getDataDir = function() return SETTINGS end })
for _, m in ipairs({ "luasettings", "ui/network/manager", "ffi/util", "socket.http", "libs/libkoreader-lfs",
    "logger", "ltn12", "ffi/sha2", "socket", "socketutil", "util" }) do package.preload[m] = stub({}) end
local Updater = dofile("updater.lua")
local function writeConfig(body)
    local f = assert(io.open(SETTINGS .. "/kitchentimer_config.lua", "w")); f:write(body); f:close()
end

os.remove(SETTINGS .. "/kitchentimer_config.lua")
local c = assert(Updater.config())
assert(c.public and c.github_repo == "CTRLFai/KitchenTimer" and c.branch == "main")
local url, h = Updater.request(c, "kitchentimer.koplugin/manifest.lua")
eq(url, "https://raw.githubusercontent.com/CTRLFai/KitchenTimer/main/kitchentimer.koplugin/manifest.lua")
assert(h.Authorization == nil)
writeConfig('return { public_repo = "Friend/fork", public_branch = "dev" }')
c = Updater.config(); eq(c.github_repo, "Friend/fork"); eq(c.branch, "dev")
writeConfig('return {'); c = Updater.config(); eq(c.github_repo, "CTRLFai/KitchenTimer", "broken config falls back")
-- it must never read or write Relic's files
local f = io.open("updater.lua"); local src = f:read("*a"); f:close()
assert(not src:find("relic_", 1, true), "updater touches a relic_* file")
assert(not src:find("relic.koplugin", 1, true), "updater points at Relic's plugin folder")
os.execute("rm -rf " .. SETTINGS)

print("ok test_safety")
