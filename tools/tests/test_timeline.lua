-- Engine tests. Run from kitchentimer.koplugin/:  luajit ../tools/tests/test_timeline.lua
local T = dofile("timeline.lua")

local function eq(a, b, msg)
    if a ~= b then error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- A small recipe shaped like the real one: a tracker that alerts twice, a step that waits on it.
local R = {
    slug = "fixture", title = "Fixture",
    steps = {
        { title = "A", dur = 60 },
        { title = "Pans in", dur = 0, tracker_start = "t" },
        { title = "C", dur = 120 },
        { title = "Wait", dur = 0, wait_for = "t" },
        { title = "Last", dur = 0 },
    },
    trackers = { t = { name = "Tray", stages = {
        { id = "s1", dur = 600 },
        { id = "a", alert = true, buttons = { { label = "Go", to = "s2" } } },
        { id = "s2", dur = 300 },
        { id = "chk", alert = true, buttons = { { label = "Done", to = "fin" }, { label = "+1", to = "s2", dur = 60 } } },
        { id = "fin", final = true },
    } } },
}

-- Tiny serializer so the resume test goes through text, as the settings file does.
local function ser(v)
    if type(v) == "table" then
        local p = {}
        for k, x in pairs(v) do p[#p + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
        return "{" .. table.concat(p, ",") .. "}"
    elseif type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end
local function roundtrip(S) return loadstring("return " .. ser(S))() end

local t0 = 1000000

-- 1. Flow: tracker starts when the "Pans in" step is left, wait step is gated until it is final.
do
    local S = T.new("fixture")
    eq(T.can_next(S, R), false, "can't advance before Start")
    T.start(S, t0)
    eq(T.elapsed(S, t0 + 5), 5)
    assert(T.next(S, R, t0 + 10)); eq(S.idx, 2)
    assert(S.trackers.t == nil, "tracker idle before the Pans-in step is left")
    assert(T.next(S, R, t0 + 20)); eq(S.idx, 3)
    eq(S.trackers.t.stage, "s1"); eq(S.trackers.t.target, t0 + 620)
    assert(T.next(S, R, t0 + 30)); eq(S.idx, 4)
    local ok, why = T.next(S, R, t0 + 31)
    eq(ok, false, "wait step is gated"); eq(why, "waiting"); eq(S.idx, 4)
end

-- 2. Tracker alerts exactly once, with the right "since"; a long gap lands on the first alert.
do
    local S = T.new("fixture"); T.start(S, t0)
    T.next(S, R, t0); T.next(S, R, t0)               -- tracker started at t0, now on step 3
    eq(#T.tick(S, R, t0 + 100), 0, "nothing yet")
    local ev = T.tick(S, R, t0 + 600)
    eq(#ev, 2, "step end and tracker alert land together")
    local kinds = {}
    for _, e in ipairs(ev) do kinds[e.kind] = e end
    eq(kinds.tracker.stage, "a"); eq(kinds.tracker.since, t0 + 600)
    eq(kinds.step.idx, 3)
    eq(#T.tick(S, R, t0 + 601), 0, "reported once")
    -- Suspend for three hours: still on the first alert, not skipped to the check.
    local S2 = T.new("fixture"); T.start(S2, t0); T.next(S2, R, t0); T.next(S2, R, t0)
    local ev2 = T.tick(S2, R, t0 + 3 * 3600)
    local trk
    for _, e in ipairs(ev2) do if e.kind == "tracker" then trk = e end end
    eq(trk.stage, "a"); eq(trk.since, t0 + 600, "alert is dated when it became due")
end

-- 3. Buttons: Go starts s2 from the press time; the check alert can be extended and fires again.
do
    local S = T.new("fixture"); T.start(S, t0); T.next(S, R, t0); T.next(S, R, t0)
    T.tick(S, R, t0 + 700)                            -- alert "a" shown, late
    assert(T.press(S, R, "t", 1, t0 + 730))
    eq(S.trackers.t.stage, "s2"); eq(S.trackers.t.target, t0 + 1030, "second half runs from the press")
    local ev = T.tick(S, R, t0 + 1030)
    local chk
    for _, e in ipairs(ev) do if e.kind == "tracker" then chk = e end end
    eq(chk.stage, "chk")
    assert(T.press(S, R, "t", 2, t0 + 1040))          -- +1 min
    eq(S.trackers.t.stage, "s2"); eq(S.trackers.t.target, t0 + 1100)
    ev = T.tick(S, R, t0 + 1100)
    chk = nil
    for _, e in ipairs(ev) do if e.kind == "tracker" then chk = e end end
    assert(chk and chk.stage == "chk", "the check alert fires again after +1")
    eq(T.press(S, R, "t", 5, t0 + 1110), false, "no such button")
    assert(T.press(S, R, "t", 1, t0 + 1120)); eq(S.trackers.t.stage, "fin")
    T.next(S, R, t0 + 1121); eq(S.idx, 4)
    assert(T.next(S, R, t0 + 1122), "wait step opens once the tracker is final"); eq(S.idx, 5)
    assert(T.next(S, R, t0 + 1130)); eq(S.finished, true)
    eq(T.elapsed(S, t0 + 99999), 1130, "elapsed stops at Finish")
    eq(T.next(S, R, t0 + 1140), false, "nothing after Finish")
end

-- 4. Six-hour reset, against run_start. Exactly six hours is still the same run.
do
    local S = T.new("fixture"); T.start(S, t0)
    local same, reset = T.load(S, R, t0 + 6 * 3600)
    eq(reset, false); assert(same == S)
    local fresh, reset2 = T.load(S, R, t0 + 6 * 3600 + 1)
    eq(reset2, true); eq(fresh.started, false)
    local nothing, reset3 = T.load(nil, R, t0)
    eq(reset3, false); eq(nothing.slug, "fixture")
    -- A finished run older than six hours is also dropped.
    local F = T.new("fixture"); T.start(F, t0); F.finished, F.finished_at = true, t0 + 100
    local _, r4 = T.load(F, R, t0 + 7 * 3600); eq(r4, true)
end

-- 5. Stale state (recipe changed under a saved run) is dropped, not trusted.
do
    local S = T.new("other"); T.start(S, t0)
    local _, r = T.load(S, R, t0); eq(r, true, "slug mismatch")
    local S2 = T.new("fixture"); T.start(S2, t0); S2.idx = 99
    _, r = T.load(S2, R, t0); eq(r, true, "step out of range")
    local S3 = T.new("fixture"); T.start(S3, t0); S3.trackers.t = { stage = "gone", target = 0, since = 0, announced = "" }
    _, r = T.load(S3, R, t0); eq(r, true, "unknown tracker stage")
end

-- 6. Resume from saved state: a round trip through text behaves like the original.
do
    local S = T.new("fixture"); T.start(S, t0); T.next(S, R, t0 + 5); T.next(S, R, t0 + 6)
    T.tick(S, R, t0 + 700)
    local back = roundtrip(S)
    local loaded, reset = T.load(back, R, t0 + 710)
    eq(reset, false)
    assert(T.press(loaded, R, "t", 1, t0 + 720))
    eq(loaded.trackers.t.stage, "s2")
    eq(#T.tick(loaded, R, t0 + 721), 0, "alert already announced before the restart is not repeated")
end

-- 7. Step timer, time's-up card, acknowledging it, and priority of tracker alerts.
do
    local S = T.new("fixture"); T.start(S, t0)
    eq(T.step_left(S, R, t0 + 20), 40)
    eq(T.step_left(S, R, t0 + 70), -10, "negative once over")
    eq(T.active_alert(S, R, t0 + 59), nil)
    local a = T.active_alert(S, R, t0 + 61)
    eq(a.kind, "step"); eq(a.since, t0 + 60)
    T.ack_step(S)
    eq(T.active_alert(S, R, t0 + 90), nil, "dismissed card stays dismissed")
    T.next(S, R, t0 + 100); T.next(S, R, t0 + 100)   -- step 3 (120 s), tracker running
    eq(T.step_left(S, R, t0 + 100), 120)
    T.tick(S, R, t0 + 750)                           -- step 3 over AND tracker alert due
    local top = T.active_alert(S, R, t0 + 750)
    eq(top.kind, "tracker", "tracker alert outranks the step card")
    T.press(S, R, "t", 1, t0 + 751)
    eq(T.active_alert(S, R, t0 + 752).kind, "step", "step card returns after the tracker alert")
    eq(T.step_left(S, R, t0 + 100) , 120)
    eq(T.step_left({ idx = 4, step_start = 0 }, R, 5), nil, "untimed step has no clock")
end

-- 8. Back restarts the step clock; no back from step 1 or from Finish.
do
    local S = T.new("fixture"); T.start(S, t0)
    eq(T.back(S, t0 + 1), false, "no back from step 1")
    T.next(S, R, t0 + 100); T.next(S, R, t0 + 101)
    eq(T.back(S, t0 + 200), true); eq(S.idx, 2); eq(S.step_start, t0 + 200)
    eq(S.trackers.t ~= nil, true, "going back does not stop the tracker")
    T.next(S, R, t0 + 210)
    eq(S.trackers.t.target, t0 + 101 + 600, "going forward again does not restart it")
end

-- 9. Clock corrected backwards: elapsed never goes negative.
do
    local S = T.new("fixture"); T.start(S, t0)
    eq(T.elapsed(S, t0 - 500), 0)
end

-- 10. Pulses: every 45 s for 15 min after the alert first showed, then quiet.
do
    eq(T.pulse_due(t0, nil, t0), true, "first pulse right away")
    eq(T.pulse_due(t0, t0, t0 + 44), false)
    eq(T.pulse_due(t0, t0, t0 + 45), true)
    eq(T.pulse_due(t0, t0 + 855, t0 + 899), false)
    eq(T.pulse_due(t0, t0 + 855, t0 + 900), false, "window closed")
    eq(T.pulse_over(t0, t0 + 899), false); eq(T.pulse_over(t0, t0 + 900), true)
end

-- 11. Plan: tracker starts after its step, waits are measured from there.
do
    local p = T.plan(R)
    -- A 60, Pans in 0, C 120 -> tracker started at 60, takes 600 + 300 = 900 -> done at 960; wait step opens then.
    eq(p.steps[3].finish, 180); eq(p.steps[4].start, 960); eq(p.total, 960)
    eq(T.header_minutes(R), 16)
    local bad = { slug = "x", steps = { { wait_for = "t", dur = 0 } }, trackers = R.trackers }
    assert(not pcall(T.plan, bad), "waiting on a tracker that never starts is an error")
end

print("ok test_timeline")
