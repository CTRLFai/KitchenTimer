-- Recipe check: meal-prep's handoff check, run over every recipes/*.lua.
-- Run from kitchentimer.koplugin/:  luajit ../tools/tests/test_recipes.lua
local T = dofile("timeline.lua")

local problems = {}
local function bad(slug, msg) problems[#problems + 1] = slug .. ": " .. msg end

-- Characters allowed beyond ASCII: each one was checked to exist in NotoSans Regular and Bold
-- (the Kindle body font). Add a character here only after checking the font.
local OK_GLYPHS = {}
for _, c in ipairs({ "\194\183", "\226\128\162", "\194\189", "\226\133\147", "\194\188", "\194\190",
                     "\226\133\148", "\194\176", "\226\128\147" }) do OK_GLYPHS[c] = true end
-- (· • ½ ⅓ ¼ ¾ ⅔ ° –)  Not allowed: em dash, check mark (no glyph).

local FR = { ["\194\189"] = 0.5, ["\226\133\147"] = 1 / 3, ["\194\188"] = 0.25, ["\194\190"] = 0.75, ["\226\133\148"] = 2 / 3 }
local UNITS = { lb = "lb", cup = "cup", cups = "cup", tbsp = "tbsp", tsp = "tsp", oz = "oz" }

-- "2½ lb yellow potatoes" -> 2.5, "lb", "yellow potatoes", false.  "1 to 2 Tbsp butter" -> range.
local function parse(s)
    s = s:gsub("^%s+", "")
    local val, had = 0, false
    local digits, rest = s:match("^(%d+)(.*)$")
    if digits then val, s, had = tonumber(digits), rest, true end
    for ch, v in pairs(FR) do
        if s:sub(1, #ch) == ch then val, s, had = val + v, s:sub(#ch + 1), true; break end
    end
    if not had then return nil end
    s = s:gsub("^%s+", "")
    local range = false
    if s:match("^to%s") then range = true; s = s:gsub("^to%s+%d+[^%a]*", "") end
    local word, after = s:match("^(%a+)%s*(.*)$")
    local unit = word and UNITS[word:lower()]
    if unit then return val, unit, after, range end
    return val, "", s, range
end

local function key_of(name)
    name = name:gsub("%b()", ""):gsub("[,;].*$", ""):gsub("%s+$", "")
    local last = name:match("(%a+)$")
    return last and last:lower() or nil
end

-- Pull entry -> { pairs = { {unit, val}, ... }, key = ..., presence = { keys } }
local function pull_entry(text)
    local main = text:gsub(",%s*plus.*$", "")
    local inner = {}
    for p in main:gmatch("%((.-)%)") do inner[#inner + 1] = p end
    main = main:gsub("%s*%b()", "")
    local e = { pairs = {}, presence = {} }
    if not parse(main) and main:find(",") then
        for name in main:gmatch("[^,]+") do e.presence[#e.presence + 1] = key_of(name) end
        return e
    end
    for seg in main:gmatch("[^+]+") do
        local v, u, name = parse(seg)
        if v then e.pairs[#e.pairs + 1] = { u, v } end
        if name and name ~= "" then e.key = key_of(name) end
    end
    if not parse(main) and not e.key then e.key = key_of(main) end
    for _, p in ipairs(inner) do
        local v, u = parse(p)
        if v then e.pairs[#e.pairs + 1] = { u, v } end
    end
    return e
end

local function check(slug, r)
    local function need(cond, msg) if not cond then bad(slug, msg) end end

    -- Shape
    need(type(r.title) == "string" and r.title ~= "", "title")
    need(type(r.servings) == "number", "servings")
    need(r.slug == slug, "slug field must match the file name")
    need(type(r.steps) == "table" and #r.steps > 0, "steps")
    need(type(r.pull) == "table" and #r.pull.food > 0 and #r.pull.gear > 0, "pull list needs food and gear")
    need(type(r.finish) == "string" and r.finish ~= "", "finish text")
    if #problems > 0 then return end

    for i, s in ipairs(r.steps) do
        need(type(s.title) == "string" and type(s.text) == "string" and s.text ~= "", "step " .. i .. " title/text")
        need(type(s.dur) == "number" and s.dur >= 0, "step " .. i .. " dur")
        if s.tracker_start then need(r.trackers and r.trackers[s.tracker_start], "step " .. i .. " starts an unknown tracker") end
        if s.wait_for then need(r.trackers and r.trackers[s.wait_for], "step " .. i .. " waits for an unknown tracker") end
    end

    -- Trackers: stages chain correctly, buttons lead somewhere real, one final stage at the end.
    for id, tr in pairs(r.trackers or {}) do
        local ids, finals = {}, 0
        for i, st in ipairs(tr.stages) do
            need(not ids[st.id], id .. ": duplicate stage " .. st.id); ids[st.id] = true
            if st.final then finals = finals + 1; need(i == #tr.stages, id .. ": final stage must be last") end
            if st.alert then need(st.buttons and #st.buttons > 0, id .. "/" .. st.id .. ": alert without buttons") end
            if not st.alert and not st.final then need(st.dur and st.dur > 0, id .. "/" .. st.id .. ": timed stage needs dur") end
        end
        need(finals == 1, id .. ": needs exactly one final stage")
        need(tr.stages[1].dur, id .. ": first stage must be timed")
        for _, st in ipairs(tr.stages) do
            for _, b in ipairs(st.buttons or {}) do
                need(ids[b.to], id .. "/" .. st.id .. ": button '" .. tostring(b.label) .. "' leads to unknown stage")
            end
        end
    end
    local started = {}
    for i, s in ipairs(r.steps) do
        if s.wait_for then need(started[s.wait_for], "step " .. i .. " waits for a tracker that hasn't started yet") end
        if s.tracker_start then started[s.tracker_start] = true end
    end

    -- Header time: computed from the steps and the tracker waits, never typed in. It must exist.
    local ok, plan = pcall(T.plan, r)
    need(ok, "plan failed: " .. tostring(plan))
    if not ok then return end
    local sum = 0
    for _, s in ipairs(r.steps) do sum = sum + s.dur end
    need(plan.total >= sum, "plan shorter than the sum of the steps")
    need(T.header_minutes(r) == math.floor(plan.total / 60 + 0.5), "header minutes")

    -- A long wait at the end is a phone/stove timer, not a Kindle timer.
    local last = r.steps[#r.steps]
    need(last.dur < 1800, "last step has a timer of " .. last.dur / 60 .. " min: long final waits become 'set a timer on your phone or stove'")

    -- A tracker alert that lands inside a timed step (ideal flow) needs that step to say what to do with the pan.
    for id, tr in pairs(r.trackers or {}) do
        local t
        for i, s in ipairs(r.steps) do if s.tracker_start == id then t = plan.steps[i].finish end end
        for _, st in ipairs(tr.stages) do
            t = t + (st.dur or 0)
            if st.alert then
                for i, s in ipairs(r.steps) do
                    local p = plan.steps[i]
                    if s.dur > 0 and t > p.start and t <= p.finish then
                        need(s.alert_hint, "step " .. i .. " (" .. s.title .. ") is running when the '" .. st.id .. "' alert lands: add an alert_hint")
                    end
                end
            end
        end
    end

    -- Ingredients: every food item is used in a step, the amounts add up, and nothing is used that isn't listed.
    local entries, keys = {}, {}
    for _, line in ipairs(r.pull.food) do
        local e = pull_entry(line); e.line = line
        entries[#entries + 1] = e
        if e.key then keys[e.key] = true end
        for _, k in ipairs(e.presence) do keys[k] = true end
    end
    local sums, seen = {}, {}
    for i, s in ipairs(r.steps) do
        for _, u in ipairs(s.uses or {}) do
            local v, unit, name, range = parse(u)
            local k = key_of(name or u)
            if k then
                seen[k] = true
                need(keys[k], "step " .. i .. " uses '" .. u .. "' which is not in the pull list")
                if v and not range and not s.portion then
                    sums[k] = sums[k] or {}
                    sums[k][unit] = (sums[k][unit] or 0) + v
                end
            end
        end
    end
    for _, e in ipairs(entries) do
        for _, k in ipairs(e.presence) do need(seen[k], "'" .. k .. "' is in the pull list but no step uses it") end
        if e.key then
            need(seen[e.key], "'" .. e.line .. "' is in the pull list but no step uses it")
            if #e.pairs > 0 then
                local matched = false
                for unit, total in pairs(sums[e.key] or {}) do
                    local want
                    for _, p in ipairs(e.pairs) do if p[1] == unit then want = p[2] end end
                    if want == nil then
                        need(false, "'" .. e.line .. "': steps use " .. total .. " " .. unit .. " but the list has no amount in that unit")
                    elseif math.abs(want - total) > 1e-6 then
                        need(false, "'" .. e.line .. "': list says " .. want .. " " .. unit .. ", steps add up to " .. total)
                    else
                        matched = true
                    end
                end
                need(matched, "'" .. e.line .. "': no step amount to check the total against")
            end
        end
    end

    -- Storage: fridge and freezer handled separately.
    local f, z = false, false
    for _, sec in ipairs(r.storage or {}) do
        if sec.title:lower():find("fridge") then f = true end
        if sec.title:lower():find("freezer") then z = true end
    end
    need(f and z, "storage needs separate fridge and freezer sections")
end

local function strings_of(v, out)
    if type(v) == "string" then out[#out + 1] = v
    elseif type(v) == "table" then for _, x in pairs(v) do strings_of(x, out) end end
    return out
end

local files = {}
for name in io.popen("ls recipes/*.lua 2>/dev/null"):lines() do files[#files + 1] = name end
assert(#files > 0, "no recipes found (run from kitchentimer.koplugin/)")

for _, path in ipairs(files) do
    local slug = path:match("recipes/(.-)%.lua$")
    local before = #problems
    local f = assert(io.open(path, "rb")); local src = f:read("*a"); f:close()
    if src:find("\226\128\148") then bad(slug, "contains an em dash") end
    local r = dofile(path)
    for _, s in ipairs(strings_of(r, {})) do
        for ch in s:gmatch("[\194-\244][\128-\191]*") do
            if not OK_GLYPHS[ch] then bad(slug, "character '" .. ch .. "' is not on the checked-glyph list: " .. s:sub(1, 50)) end
        end
        local low = s:lower()
        for _, w in ipairs({ "chime", "scroll", "bottom of the page", "top of the page" }) do
            if low:find(w, 1, true) then bad(slug, "phone-only wording '" .. w .. "': " .. s:sub(1, 60)) end
        end
    end
    -- The text must not tell him to tap a button that is named differently or locked on this step.
    for i, st in ipairs(r.steps) do
        if (st.next_label or st.wait_for) and st.text:lower():find("tap next", 1, true) then
            bad(slug, "step " .. i .. " says 'tap Next' but its button is " .. (st.next_label and ("'" .. st.next_label .. "'") or "locked until the tracker allows it"))
        end
    end
    check(slug, r)
    if #problems == before then
        print(string.format("  %s: %d steps, header about %d min, clean", slug, #r.steps, T.header_minutes(r)))
    end
end

if #problems > 0 then
    for _, p in ipairs(problems) do print("PROBLEM " .. p) end
    os.exit(1)
end
print("ok test_recipes")
