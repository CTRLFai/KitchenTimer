-- Write a saved Kitchen Timer run so the emulator opens straight into a given state.
-- Usage (KOReader stopped!):  luajit fixture.lua <settings-dir> <slug> key=value ...
--   idx=7            step number
--   step=120         seconds spent in this step so far
--   run=1500         seconds since Start
--   oven=roast1:300  tracker "oven" in stage roast1 with 300 s left   (a minus sign means that long ago)
--   oven=flip:-120   tracker in an alert stage that began 120 s ago
--   oven=done        tracker finished
--   finished=1       the cook is over
-- With no key=value the run is not started (fresh Pull page).
local dir, slug = arg[1], arg[2]
local kv = {}
for i = 3, #arg do local k, v = arg[i]:match("^(%w+)=(.*)$"); kv[k] = v end
local now = os.time()
local S = { slug = slug, started = false, idx = 1, step_start = 0, run_start = 0, finished = false,
            finished_at = 0, step_ack = 0, step_announced = 0, trackers = {} }
if next(kv) then
    S.started = true
    S.idx = tonumber(kv.idx or 1)
    S.run_start = now - tonumber(kv.run or 600)
    S.step_start = now - tonumber(kv.step or 5)
    if kv.finished then S.finished, S.finished_at = true, now - 30 end
    if kv.oven then
        local stage, secs = kv.oven:match("^(%w+):?(-?%d*)$")
        local n = tonumber(secs) or 0
        local t = { stage = stage, announced = "" }
        if stage == "roast1" or stage == "roast2" then t.target = now + n; t.since = now - 60
        else t.since = now + n end
        if stage == "flip" or stage == "check" then t.announced = stage end   -- already announced
        S.trackers.oven = t
    end
end
local function ser(v)
    if type(v) == "table" then
        local p = {}
        for k, x in pairs(v) do p[#p + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
        return "{" .. table.concat(p, ",") .. "}"
    elseif type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end
local f = assert(io.open(dir .. "/kitchentimer_run.lua", "w"))
f:write("return { [\"run\"] = " .. ser(S) .. " }\n"); f:close()
