--[[
Kitchen Timer engine. Pure Lua: no KOReader modules, so it runs under plain LuaJIT tests.

Time is always the wall clock (os.time() seconds passed in as `now`), never a tick count. The UI
calls tick() now and then; tick() compares the clock with the saved targets, so a missed tick or a
suspended Kindle can't drift anything. All state is plain data (numbers, strings, booleans,
tables), so the UI can save it to a settings file on every change and resume after a crash.

State:
  { slug, started, idx, step_start, run_start, finished, finished_at,
    step_ack,        -- step index whose "time's up" card was dismissed
    step_announced,  -- step index whose time's-up event was already reported
    trackers = { [id] = { stage = <stage id>, target = <time a timed stage ends>,
                          since = <time the current stage began>, announced = <stage id> } } }

Recipe (see recipes/*.lua): steps[] with dur, tracker_start, wait_for; trackers[id].stages[] where a
stage has either dur (timed), alert=true plus buttons (waits for a press), or final=true.
]]

local Timeline = {}

Timeline.RESET_AFTER = 6 * 3600   -- a run older than this is a previous cook day
Timeline.PULSE_WINDOW = 15 * 60   -- frontlight pulses stop this long after an alert first shows
Timeline.PULSE_EVERY = 45         -- seconds between pulses while the window is open

-- Helpers ---------------------------------------------------------------------------------------

local function stage_index(tr, id)
    for i, st in ipairs(tr.stages) do
        if st.id == id then return i end
    end
end

local function stage_of(recipe, id, stage_id)
    local tr = recipe.trackers and recipe.trackers[id]
    if not tr then return nil end
    local i = stage_index(tr, stage_id)
    return i and tr.stages[i], i, tr
end

-- State ----------------------------------------------------------------------------------------

function Timeline.new(slug)
    return {
        slug = slug, started = false, idx = 1, step_start = 0, run_start = 0,
        finished = false, finished_at = 0, step_ack = 0, step_announced = 0, trackers = {},
    }
end

-- Is the saved state usable with this recipe? (A recipe update can change step or stage ids.)
local function valid(S, recipe)
    if type(S) ~= "table" or S.slug ~= recipe.slug then return false end
    if type(S.idx) ~= "number" or S.idx < 1 or S.idx > #recipe.steps then return false end
    if type(S.trackers) ~= "table" then return false end
    for id, t in pairs(S.trackers) do
        if not stage_of(recipe, id, t.stage) then return false end
    end
    return true
end

-- Returns the state to use, and true when a saved run was thrown away (too old, or stale).
function Timeline.load(S, recipe, now)
    if S == nil then return Timeline.new(recipe.slug), false end
    if not valid(S, recipe) then return Timeline.new(recipe.slug), true end
    if S.started and now - S.run_start > Timeline.RESET_AFTER then
        return Timeline.new(recipe.slug), true
    end
    return S, false
end

function Timeline.start(S, now)
    S.started, S.finished = true, false
    S.run_start, S.step_start, S.idx = now, now, 1
    S.step_ack, S.step_announced, S.trackers = 0, 0, {}
end

function Timeline.step(S, recipe) return recipe.steps[S.idx] end

-- Clocks ----------------------------------------------------------------------------------------

-- Seconds since Start; stops at Finish. Never negative (the Kindle's clock can be corrected).
function Timeline.elapsed(S, now)
    if not S.started then return 0 end
    local e = (S.finished and S.finished_at or now) - S.run_start
    return e > 0 and e or 0
end

-- Seconds left on the current step (negative once over), or nil for a step with no timer.
function Timeline.step_left(S, recipe, now)
    local step = recipe.steps[S.idx]
    if not step or not step.dur or step.dur <= 0 then return nil end
    return step.dur - (now - S.step_start)
end

-- Trackers ----------------------------------------------------------------------------------------

-- { id, name, stage, left, alert, final } for a running tracker, nil when idle.
function Timeline.tracker_view(S, recipe, id, now)
    local t = S.trackers[id]
    if not t then return nil end
    local stage, _, tr = stage_of(recipe, id, t.stage)
    if not stage then return nil end
    return {
        id = id, name = tr.name, stage = stage,
        left = stage.dur and t.target and (t.target - now) or nil,
        alert = stage.alert and true or false, final = stage.final and true or false,
        since = t.since,
    }
end

local function begin_stage(t, stage, at, dur)
    t.stage, t.since, t.announced = stage.id, at, ""
    t.target = stage.dur and (at + (dur or stage.dur)) or nil
end

-- Press button `n` on the tracker's current alert stage.
function Timeline.press(S, recipe, id, n, now)
    local t = S.trackers[id]
    if not t then return false, "idle" end
    local stage, _, tr = stage_of(recipe, id, t.stage)
    local b = stage and stage.alert and stage.buttons and stage.buttons[n]
    if not b then return false, "no such button" end
    local to = tr.stages[stage_index(tr, b.to)]
    if not to then return false, "bad target" end
    begin_stage(t, to, now, b.dur)
    return true
end

-- Steps -------------------------------------------------------------------------------------------

-- A step with wait_for stays shut until that tracker is on its final stage.
function Timeline.can_next(S, recipe)
    if not S.started or S.finished then return false, "not running" end
    local step = recipe.steps[S.idx]
    if step.wait_for then
        local v = Timeline.tracker_view(S, recipe, step.wait_for, 0)
        if not (v and v.final) then return false, "waiting" end
    end
    return true
end

local function enter(S, idx, now)
    S.idx, S.step_start, S.step_ack, S.step_announced = idx, now, 0, 0
end

function Timeline.next(S, recipe, now)
    local ok, why = Timeline.can_next(S, recipe)
    if not ok then return false, why end
    local step = recipe.steps[S.idx]
    if step.tracker_start and not S.trackers[step.tracker_start] then
        local tr = recipe.trackers[step.tracker_start]
        local t = {}
        begin_stage(t, tr.stages[1], now)
        S.trackers[step.tracker_start] = t
    end
    if S.idx < #recipe.steps then
        enter(S, S.idx + 1, now)
    else
        S.finished, S.finished_at = true, now
    end
    return true
end

function Timeline.back(S, now)
    if not S.started or S.finished or S.idx <= 1 then return false end
    enter(S, S.idx - 1, now)
    return true
end

-- Dismiss the "time's up" card for the current step; its clock keeps counting up.
function Timeline.ack_step(S) S.step_ack = S.idx end

-- Ticking -----------------------------------------------------------------------------------------

-- Moves timed tracker stages whose time has passed to their next stage, and reports each alert and
-- each step end exactly once. A long gap (suspend) lands on the first alert, never skips past it.
-- Returns a list of { kind = "tracker", tracker, stage, since } or { kind = "step", idx, since }.
function Timeline.tick(S, recipe, now)
    local events = {}
    if not S.started then return events end
    for id, t in pairs(S.trackers) do
        local tr = recipe.trackers[id]
        while true do
            local stage, i = stage_of(recipe, id, t.stage)
            if stage.dur and t.target and now >= t.target then
                local nxt = tr.stages[i + 1]
                if not nxt then break end
                begin_stage(t, nxt, t.target)       -- it became due at the old target, not now
            else
                break
            end
        end
        local stage = stage_of(recipe, id, t.stage)
        if stage.alert and t.announced ~= stage.id then
            t.announced = stage.id
            events[#events + 1] = { kind = "tracker", tracker = id, stage = stage.id, since = t.since }
        end
    end
    if not S.finished then
        local step = recipe.steps[S.idx]
        if step.dur and step.dur > 0 and now - S.step_start >= step.dur and S.step_announced ~= S.idx then
            S.step_announced = S.idx
            events[#events + 1] = { kind = "step", idx = S.idx, since = S.step_start + step.dur }
        end
    end
    table.sort(events, function(a, b) return a.since < b.since end)
    return events
end

-- What the screen must show over everything else right now, or nil. A tracker alert outranks a
-- step's "time's up" card; the step card comes back once the tracker alert is handled.
function Timeline.active_alert(S, recipe, now)
    if not S.started then return nil end
    local best
    for id in pairs(S.trackers) do
        local v = Timeline.tracker_view(S, recipe, id, now)
        if v and v.alert and (not best or v.since < best.since) then
            best = { kind = "tracker", tracker = id, view = v, since = v.since }
        end
    end
    if best then return best end
    if not S.finished then
        local step = recipe.steps[S.idx]
        if step.dur and step.dur > 0 and S.step_ack ~= S.idx and now - S.step_start >= step.dur then
            return { kind = "step", idx = S.idx, step = step, since = S.step_start + step.dur }
        end
    end
    return nil
end

-- Frontlight pulses: every PULSE_EVERY seconds for PULSE_WINDOW after the alert first showed.
function Timeline.pulse_due(first_shown, last_pulse, now)
    if now - first_shown >= Timeline.PULSE_WINDOW then return false end
    return last_pulse == nil or now - last_pulse >= Timeline.PULSE_EVERY
end

function Timeline.pulse_over(first_shown, now) return now - first_shown >= Timeline.PULSE_WINDOW end

-- Plan --------------------------------------------------------------------------------------------

-- The run as it goes when nobody is late: { total = seconds, steps = { {start, finish}, ... } }.
-- A tracker starts when its tracker_start step ends and takes the sum of its timed stages; a
-- wait_for step cannot start before the tracker is done.
function Timeline.plan(recipe)
    local t, started_at, out = 0, {}, { steps = {} }
    local function tracker_len(id)
        local sum = 0
        for _, st in ipairs(recipe.trackers[id].stages) do sum = sum + (st.dur or 0) end
        return sum
    end
    for i, step in ipairs(recipe.steps) do
        if step.wait_for then
            local s = started_at[step.wait_for]
            assert(s, "step " .. i .. " waits for a tracker that has not started: " .. step.wait_for)
            local done = s + tracker_len(step.wait_for)
            if done > t then t = done end
        end
        local start = t
        t = t + (step.dur or 0)
        if step.tracker_start then started_at[step.tracker_start] = t end
        out.steps[i] = { start = start, finish = t }
    end
    out.total = t
    return out
end

-- Header time in minutes, rounded to the nearest minute.
function Timeline.header_minutes(recipe)
    return math.floor(Timeline.plan(recipe).total / 60 + 0.5)
end

return Timeline
