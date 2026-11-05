--[[
The cooking screen: Pull these out list, the step pages, the alert card, finish and storage.

One screen object per recipe. All the timing logic is in timeline.lua; this file is layout, taps,
refreshes and the safety hooks (keep-awake and the frontlight are released on every way out).

Pages:  pull -> step ... -> finish -> storage.   The menu can show pull or storage during a run.
Over the top of the step/pull/storage pages, an alert card takes the whole screen whenever a tracker
alert or a step's time is up; it has the action buttons on it and flashes the frontlight.

Layout of a step page (portrait 758x1024), top to bottom:
    header: STEP n OF N . GROUP                                   [MENU]
    step title                                                    clock
    tracker band (only while a tracker runs)                      clock
    step text, in its own scrolling box
    Next: ...                                                   (info)
    scroll hint                                                Elapsed
    [ BACK ] [                NEXT                  ]     (fixed bar, 150 px)
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local Screen = Device.screen

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Timeline = dofile(plugin_dir .. "timeline.lua")

local MARGIN = 28
local BAR_H = 150          -- bottom button bar, fixed
local TICK = 1             -- seconds between clock redraws
local CLOCK_REFRESH = "ui" -- partial refresh mode for the clocks ("fast" is quicker but ghosts more)

local function F(size, bold) return Font:getFace(bold and "tfont" or "cfont", size) end

local function fmt(s)
    s = math.max(0, math.floor(s + 0.5))
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function durLabel(d) return d >= 120 and (math.floor(d / 60 + 0.5) .. " min") or fmt(d) end

local function elapsedLabel(s)
    local m = math.floor(s / 60)
    if m >= 60 then return string.format("%d h %02d min", math.floor(m / 60), m % 60) end
    return m .. " min"
end

-- ClockBox ---------------------------------------------------------------------------------------
-- A fixed-size text slot that remembers where it was painted, so a tick can refresh just that
-- rectangle instead of the whole screen.

local ClockBox = Widget:extend{ w = 200, h = 60, size = 40, text = "", align = "right", bold = true }

function ClockBox:getSize() return Geom:new{ w = self.w, h = self.h } end

function ClockBox:paintTo(bb, x, y)
    self.px, self.py = x, y
    bb:paintRect(x, y, self.w, self.h, Blitbuffer.COLOR_WHITE)
    if self.text == "" then return end
    local t = TextWidget:new{ text = self.text, face = F(self.size, self.bold), max_width = self.w }
    local sz = t:getSize()
    local tx = self.align == "right" and (x + self.w - sz.w) or x
    t:paintTo(bb, tx, y + math.floor((self.h - sz.h) / 2))
    t:free()
end

function ClockBox:region()
    if not self.px then return nil end
    return Geom:new{ x = self.px, y = self.py, w = self.w, h = self.h }
end

-- Screen -----------------------------------------------------------------------------------------

local CookScreen = InputContainer:extend{
    name = "kitchentimer_cook",
    covers_fullscreen = true,
    recipe = nil, store = nil, keepawake = nil, pulse = nil, on_close = nil,
}

function CookScreen:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.alive = true
    self.tick_fn = function() self:tick() end
    local saved = self.store:load()
    self.S = Timeline.load(saved, self.recipe, os.time())
    if self.S.started and self.S.finished then self.S = Timeline.new(self.recipe.slug) end  -- a finished cook is history
    self.page = self.S.started and "step" or "pull"
    self.return_page = nil
    self.alert_key = nil
    self:render("full")
    self:afterChange()
end

-- Drawing helpers --------------------------------------------------------------------------------

function CookScreen:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    InputContainer.paintTo(self, bb, x, y)
end

local function bigButton(o, registry)
    local border = o.thick and 6 or 3
    local btn = Button:new{   -- height is the inside; the border adds to it, so subtract it to keep every button 148 px tall
        text = o.text, width = o.w, height = (BAR_H - 2) - 2 * border, bordersize = border, padding_v = 0,
        padding_h = Screen:scaleBySize(6), margin = 0, text_font_size = o.size or 24, text_font_bold = true,
        enabled = o.enabled ~= false, callback = o.cb,
    }
    if registry then registry[#registry + 1] = btn end
    return btn
end

-- A row of big buttons filling the content width. spec = { {text, share, cb, enabled, thick}, ... }
function CookScreen:buttonRow(spec)
    local CW = self.dimen.w - 2 * MARGIN
    local gap = 16
    local total_share = 0
    for _, b in ipairs(spec) do total_share = total_share + (b.share or 1) end
    local avail = CW - gap * (#spec - 1)
    local row = HorizontalGroup:new{ align = "top" }
    for i, b in ipairs(spec) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = bigButton({ text = b.text, w = math.floor(avail * (b.share or 1) / total_share), cb = b.cb,
            enabled = b.enabled, thick = b.thick }, self.btns)
    end
    return row
end

local function frame(group)
    return FrameContainer:new{ bordersize = 0, margin = 0, padding = 0,
        padding_left = MARGIN, padding_right = MARGIN, padding_top = 16, background = Blitbuffer.COLOR_WHITE, group }
end

local function gap(h) return VerticalSpan:new{ width = h } end

local function textLine(text, size, bold, max_w)
    return TextWidget:new{ text = text, face = F(size, bold), max_width = max_w }
end

-- Rebuild the whole page. refresh = "full" for page changes and alerts, "ui" otherwise.
function CookScreen:render(refresh)
    if not self.alive then return end
    local ok, err = pcall(function()
        local now = os.time()
        self.step_clock, self.tracker_clocks, self.elapsed_box = nil, {}, nil
        self.btns, self.scroll = {}, nil
        local alert = self:currentAlert(now)
        if alert then
            self[1] = self:buildAlert(alert, now)
        elseif self.page == "pull" then self[1] = self:buildPull()
        elseif self.page == "storage" then self[1] = self:buildStorage()
        elseif self.page == "finish" then self[1] = self:buildFinish()
        else self[1] = self:buildStep(now) end
        UIManager:setDirty(self, refresh or "ui")
        if os.getenv("KT_DEBUG") then UIManager:scheduleIn(0.5, function() self:logLayout() end) end
    end)
    if not ok then self:fail("render", err) end
end

-- Debug only (KT_DEBUG=1, the emulator): log whether every button and the text box are fully on screen.
function CookScreen:logLayout()
    if not self.alive or not self[1] then return end
    local W, H = self.dimen.w, self.dimen.h
    local bad, rects = {}, {}
    local function check(name, d)
        if not d or not d.x then return end
        rects[#rects + 1] = string.format("%s@%d,%d %dx%d", name, d.x, d.y, d.w, d.h)
        if d.x < 0 or d.y < 0 or d.x + d.w > W or d.y + d.h > H then bad[#bad + 1] = name end
    end
    for i, b in ipairs(self.btns or {}) do check("button" .. i .. "[" .. tostring(b.text) .. "]", b.dimen) end
    local total = self[1]:getSize()
    if total.h > H then bad[#bad + 1] = "page is " .. total.h .. " tall" end
    if self.scroll then
        check("text", self.scroll.dimen)
        local top_of_bar
        for _, b in ipairs(self.btns or {}) do
            if b.dimen and (not top_of_bar or b.dimen.y > top_of_bar) and b.text ~= "MENU" then top_of_bar = b.dimen.y end
        end
        if top_of_bar and self.scroll.dimen.y + self.scroll.dimen.h > top_of_bar then bad[#bad + 1] = "text box runs into the button bar" end
    end
    logger.info(string.format("KT-LAYOUT page=%s alert=%s %s %s", tostring(self.page), tostring(self.alert_key),
        #bad == 0 and "OK" or ("OFFSCREEN: " .. table.concat(bad, "; ")), table.concat(rects, " | ")))
end

function CookScreen:currentAlert(now)
    local S = self.S
    if not S.started or S.finished then return nil end
    return Timeline.active_alert(S, self.recipe, now)
end

-- Step page ----------------------------------------------------------------------------------------

function CookScreen:buildStep(now)
    local S, R = self.S, self.recipe
    local step = R.steps[S.idx]
    local W, H = self.dimen.w, self.dimen.h
    local CW = W - 2 * MARGIN
    local group = VerticalGroup:new{ align = "left" }
    local used = 16 + BAR_H + 14  -- top padding, bar, bottom breathing room

    -- header: step n of N . group, and the Menu button
    local menu_w = 150
    local menu_btn = Button:new{ text = "MENU", width = menu_w, height = 44, bordersize = 3, padding_v = 0, margin = 0,
        text_font_size = 18, text_font_bold = true, callback = function() self:openMenu() end }
    self.btns[#self.btns + 1] = menu_btn
    local head = HorizontalGroup:new{ align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = CW - menu_w, h = 52 },
            textLine(string.format("STEP %d OF %d  \194\183  %s", S.idx, #R.steps, (step.group or ""):upper()), 17, true, CW - menu_w - 8) },
        menu_btn,
    }
    group[#group + 1] = head; used = used + head:getSize().h

    -- title, with the step clock to its right when the step has a timer
    local title_w = CW
    local trow = HorizontalGroup:new{ align = "center" }
    local clock
    if step.dur and step.dur > 0 then
        clock = ClockBox:new{ w = 250, h = 84, size = 54, text = self:stepClockText(now) }
        title_w = CW - 250 - 12
    end
    trow[#trow + 1] = TextBoxWidget:new{ text = step.title, face = F(30, true), width = title_w }
    if clock then trow[#trow + 1] = HorizontalSpan:new{ width = 12 }; trow[#trow + 1] = clock end
    self.step_clock = clock
    group[#group + 1] = gap(6); group[#group + 1] = trow
    used = used + 6 + trow:getSize().h

    -- trackers, directly under the title
    for id, tr in pairs(R.trackers or {}) do
        local v = Timeline.tracker_view(S, R, id, now)
        if v and not v.alert then
            local clk_w = v.left and 200 or 0
            local left_w = CW - 2 * 10 - 2 * 3 - (clk_w > 0 and clk_w + 12 or 0)
            local info = VerticalGroup:new{ align = "left",
                TextBoxWidget:new{ text = v.stage.label, face = F(24, true), width = left_w },
                TextBoxWidget:new{ text = v.stage.sub or "", face = F(17), width = left_w } }
            local inner = HorizontalGroup:new{ align = "center", info }
            if clk_w > 0 then
                local box = ClockBox:new{ w = clk_w, h = 60, size = 38, text = fmt(v.left) }
                box.stage_id = v.stage.id   -- a new stage, even another timed one, redraws the band
                self.tracker_clocks[id] = box
                inner[#inner + 1] = HorizontalSpan:new{ width = 12 }; inner[#inner + 1] = box
            end
            local band = FrameContainer:new{ bordersize = 3, padding = 10, margin = 0, background = Blitbuffer.COLOR_WHITE, inner }
            group[#group + 1] = gap(8); group[#group + 1] = band
            used = used + 8 + band:getSize().h
        end
    end

    -- bottom of the page: info lines and the button bar (measured now so the text box gets the rest)
    local nxt = R.steps[S.idx + 1]
    local info1 = textLine(nxt and ("Next: " .. nxt.title .. ((nxt.dur and nxt.dur > 0) and ("  \194\183  " .. durLabel(nxt.dur)) or "")) or "Last step", 18, false, CW)
    local elapsed = ClockBox:new{ w = 240, h = 30, size = 17, bold = false, align = "right",
        text = "Elapsed " .. elapsedLabel(Timeline.elapsed(S, now)) }
    self.elapsed_box = elapsed
    self.elapsed_minute = math.floor(Timeline.elapsed(S, now) / 60)
    local hint_box = ClockBox:new{ w = CW - 240, h = 30, size = 16, bold = false, align = "left", text = "" }
    local info2 = HorizontalGroup:new{ align = "center", hint_box, elapsed }
    local bar = self:stepBar(step)
    -- below the text box: 8 gap above it, then 6 + info1 + 4 + info2 (30) + 8 above the bar
    local text_h = H - used - 8 - 6 - info1:getSize().h - 4 - 30 - 8
    text_h = math.max(text_h, 140)

    local scroll = ScrollTextWidget:new{ text = step.text, face = F(24), width = CW, height = text_h, dialog = self }
    self.scroll = scroll
    if scroll.text_widget:getVisLineCount() < scroll.text_widget:getAllLineCount() then
        hint_box.text = "More: swipe up, or tap the right half"
    end
    group[#group + 1] = gap(8); group[#group + 1] = scroll
    group[#group + 1] = gap(6); group[#group + 1] = info1
    group[#group + 1] = gap(4); group[#group + 1] = info2
    group[#group + 1] = gap(8); group[#group + 1] = bar
    return frame(group)
end

function CookScreen:stepClockText(now)
    local left = Timeline.step_left(self.S, self.recipe, now)
    if not left then return "" end
    if left >= 0 then return fmt(left) end
    return "+" .. fmt(-left)
end

function CookScreen:stepBar(step)
    local S, R = self.S, self.recipe
    local can = Timeline.can_next(S, R)
    local last = S.idx == #R.steps
    local label
    if not can then
        local tr = step.wait_for and R.trackers[step.wait_for]
        label = "WAITING: " .. ((tr and tr.name) or "TIMER"):upper()
    elseif last then label = "FINISH"
    else label = (step.next_label or "NEXT"):upper() end
    return self:buttonRow{
        { text = S.idx == 1 and "PULL LIST" or "BACK", share = 3, cb = function() self:onBack() end },
        { text = label, share = 7, cb = function() self:onNext() end, enabled = can, thick = true },
    }
end

-- Alert card ---------------------------------------------------------------------------------------

function CookScreen:buildAlert(alert, now)
    local S, R = self.S, self.recipe
    local W = self.dimen.w
    local CW = W - 2 * MARGIN
    local group = VerticalGroup:new{ align = "left" }
    local step = R.steps[S.idx]
    local title, body, hint, buttons = nil, nil, nil, {}

    if alert.kind == "tracker" then
        local st = alert.view.stage
        title, body = st.label, st.sub or ""
        if step and step.alert_hint then hint = "You are on: " .. step.title .. "\n" .. step.alert_hint end
        for i, b in ipairs(st.buttons or {}) do
            local n, tid = i, alert.tracker
            buttons[#buttons + 1] = { text = b.label:upper(), cb = function() self:onAlertButton(tid, n) end, thick = i == 1 }
        end
    else
        title = "Time is up"
        body = step.title
        local nxt = R.steps[S.idx + 1]
        if nxt then body = body .. "\nNext: " .. nxt.title end
        local can = Timeline.can_next(S, R)
        if can then
            buttons[#buttons + 1] = { text = (S.idx == #R.steps) and "FINISH" or "NEXT STEP", cb = function() self:onNext() end, thick = true }
        end
        buttons[#buttons + 1] = { text = "NOT DONE YET", cb = function() self:onStepSnooze() end, thick = not can }
    end

    local late = now - (alert.since or now)
    local band = FrameContainer:new{ bordersize = 0, padding = 24, margin = 0, background = Blitbuffer.COLOR_BLACK,
        TextBoxWidget:new{ text = title:upper(), face = F(40, true), width = CW - 48, fgcolor = Blitbuffer.COLOR_WHITE,
            bgcolor = Blitbuffer.COLOR_BLACK } }
    group[#group + 1] = band
    group[#group + 1] = gap(20)
    group[#group + 1] = TextBoxWidget:new{ text = body, face = F(28), width = CW }
    if hint then
        group[#group + 1] = gap(18)
        group[#group + 1] = FrameContainer:new{ bordersize = 3, padding = 12, margin = 0, background = Blitbuffer.COLOR_WHITE,
            TextBoxWidget:new{ text = hint, face = F(24, true), width = CW - 30 } }
    end
    if late >= 60 then
        group[#group + 1] = gap(14)
        group[#group + 1] = textLine(string.format("This came up %d min ago.", math.floor(late / 60)), 20, false, CW)
    end
    -- buttons stacked at the bottom of the screen
    local used = 16 + group:getSize().h
    local stack = VerticalGroup:new{ align = "left" }
    for _, b in ipairs(buttons) do
        stack[#stack + 1] = self:buttonRow{ { text = b.text, share = 1, cb = b.cb, thick = b.thick } }
        stack[#stack + 1] = gap(14)
    end
    local free = self.dimen.h - used - stack:getSize().h - 14
    -- group was measured, and VerticalGroup caches child offsets when measured, so append nothing to it:
    -- nest it in a fresh group instead (appending after getSize() crashed on paint).
    return frame(VerticalGroup:new{ align = "left", group, gap(math.max(free, 8)), stack })
end

-- Pull / storage / finish pages ----------------------------------------------------------------------

function CookScreen:scrollPage(title_text, sub_text, body_text, bar)
    local H = self.dimen.h
    local CW = self.dimen.w - 2 * MARGIN
    local group = VerticalGroup:new{ align = "left" }
    local head = TextBoxWidget:new{ text = title_text, face = F(34, true), width = CW }
    group[#group + 1] = head
    local used = 16 + head:getSize().h + BAR_H + 14
    if sub_text then
        local sub = TextBoxWidget:new{ text = sub_text, face = F(19), width = CW }
        group[#group + 1] = gap(6); group[#group + 1] = sub
        used = used + 6 + sub:getSize().h
    end
    local text_h = math.max(H - used - 8 - 8, 140)
    -- Longer than the box? Say so, so nobody misses the gear list below the fold.
    local probe = TextBoxWidget:new{ text = body_text, face = F(25), width = CW }
    local overflows = probe:getSize().h > text_h
    probe:free()
    local hint
    if overflows then
        hint = TextBoxWidget:new{ text = "More below: swipe up, or tap the right side", face = F(19, true), width = CW }
        text_h = math.max(text_h - hint:getSize().h - 8, 140)
    end
    self.scroll = ScrollTextWidget:new{ text = body_text, face = F(25), width = CW, height = text_h, dialog = self }
    group[#group + 1] = gap(8); group[#group + 1] = self.scroll
    if hint then group[#group + 1] = gap(8); group[#group + 1] = hint end
    group[#group + 1] = gap(8); group[#group + 1] = bar
    return frame(group)
end

local function bullets(list)
    local out = {}
    for _, x in ipairs(list) do out[#out + 1] = "\226\128\162 " .. x end
    return table.concat(out, "\n")
end

function CookScreen:buildPull()
    local R, S = self.recipe, self.S
    local sub = string.format("%d servings (%s)\nabout %d min  \194\183  oven %s", R.servings, R.servings_note or "",
        Timeline.header_minutes(R), R.oven or "")
    local body = "FOOD\n" .. bullets(R.pull.food) .. "\n\nGEAR\n" .. bullets(R.pull.gear)
    local bar
    if S.started then
        bar = self:buttonRow{ { text = "BACK TO STEP", cb = function() self:showPage("step") end, thick = true } }
    else
        bar = self:buttonRow{
            { text = "BACK", share = 3, cb = function() self:close() end },
            { text = "START", share = 7, cb = function() self:onStart() end, thick = true },
        }
    end
    return self:scrollPage("Pull these out", R.title .. "\n" .. sub, body, bar)
end

function CookScreen:buildStorage()
    local R, S = self.recipe, self.S
    local parts = {}
    for _, sec in ipairs(R.storage or {}) do
        parts[#parts + 1] = sec.title:upper() .. "\n" .. bullets(sec.items)
    end
    local bar
    if S.finished then
        bar = self:buttonRow{
            { text = "BACK", share = 3, cb = function() self:showPage("finish") end },
            { text = "DONE", share = 7, cb = function() self:close() end, thick = true },
        }
    else
        bar = self:buttonRow{ { text = "BACK TO STEP", cb = function() self:showPage("step") end, thick = true } }
    end
    return self:scrollPage("Storage and reheating", R.title, table.concat(parts, "\n\n"), bar)
end

function CookScreen:buildFinish()
    local R = self.recipe
    local bar = self:buttonRow{
        { text = "DONE", share = 3, cb = function() self:close() end },
        { text = "STORAGE", share = 7, cb = function() self:showPage("storage") end, thick = true },
    }
    return self:scrollPage("Done", R.title, R.finish, bar)
end

-- Error page ----------------------------------------------------------------------------------------

function CookScreen:buildError()
    local CW = self.dimen.w - 2 * MARGIN
    local group = VerticalGroup:new{ align = "left",
        TextBoxWidget:new{ text = "Something went wrong", face = F(34, true), width = CW }, gap(16),
        TextBoxWidget:new{ text = "Your place is saved. Leave and open the recipe again to carry on.\n\n" .. tostring(self.last_error or ""),
            face = F(22), width = CW } }
    local free = math.max(self.dimen.h - group:getSize().h - BAR_H - 40, 8)
    return frame(VerticalGroup:new{ align = "left", group, gap(free),   -- nested: a measured group can't take more children
        self:buttonRow{ { text = "LEAVE", cb = function() self:close() end, thick = true } } })
end

-- Actions ------------------------------------------------------------------------------------------

function CookScreen:save()
    local ok, err = pcall(self.store.save, self.store, self.S)
    if not ok then logger.warn("Kitchen Timer: saving the run failed:", tostring(err)) end
end

-- Keep-awake and ticking follow the run: held while a cook is running, released otherwise.
-- Hold or release keep-awake by the timeline's rule (timers running, alert unanswered, or a recent touch).
function CookScreen:applyAwake(now)
    if not self.errored and self.alive and Timeline.needs_awake(self.S, self.recipe, now or os.time(), self.last_touch, self.quiet) then
        self.keepawake:on()
    else
        self.keepawake:off()
    end
end

function CookScreen:afterChange()
    local running = self.S.started and not self.S.finished
    self.last_touch = os.time()   -- every user action passes through here
    self:applyAwake()
    UIManager:unschedule(self.tick_fn)
    if running and self.alive then UIManager:scheduleIn(TICK, self.tick_fn) end
end

function CookScreen:showPage(page)
    self.page = page
    self:render("full")
    self:afterChange()
end

function CookScreen:onStart()
    Timeline.start(self.S, os.time())
    self.quiet, self.errored, self.alert_key = false, false, nil
    self:save()
    self.page = "step"
    self:render("full")
    self:afterChange()
end

function CookScreen:onNext()
    self:clearAlertState()
    local ok = Timeline.next(self.S, self.recipe, os.time())
    if not ok then return end
    self:save()
    if self.S.finished then self.page = "finish" end
    self:render("full")
    self:afterChange()
end

function CookScreen:onBack()
    if self.S.idx == 1 then return self:showPage("pull") end
    self:clearAlertState()
    if Timeline.back(self.S, os.time()) then
        self:save()
        self:render("full")
        self:afterChange()
    end
end

function CookScreen:onAlertButton(tracker, n)
    Timeline.press(self.S, self.recipe, tracker, n, os.time())
    self:clearAlertState()
    self:save()
    self:render("full")
    self:afterChange()
end

function CookScreen:onStepSnooze()
    Timeline.ack_step(self.S)
    self:clearAlertState()
    self:save()
    self:render("full")
    self:afterChange()
end

-- Back to a calm state after the person touched an alert: lights stop, the Kindle is held awake again.
function CookScreen:clearAlertState()
    self.alert_key, self.quiet = nil, false
    self.pulse:restore()
end

function CookScreen:openMenu()
    local dlg
    local function pick(fn) return function() UIManager:close(dlg); self.dialog = nil; fn() end end
    dlg = ButtonDialog:new{
        title = self.recipe.title,
        buttons = {
            { { text = "Pull these out list", callback = pick(function() self:showPage("pull") end) } },
            { { text = "Storage and reheating", callback = pick(function() self:showPage("storage") end) } },
            { { text = "Start over", callback = pick(function() self:confirmRestart() end) } },
            { { text = "Leave (keeps your place)", callback = pick(function() self:close() end) } },
            { { text = "Close menu", callback = pick(function() end) } },
        },
    }
    self.dialog = dlg
    UIManager:show(dlg)
end

function CookScreen:confirmRestart()
    UIManager:show(ConfirmBox:new{
        text = "Clear your place and start this recipe over?",
        ok_text = "Start over",
        ok_callback = function()
            self.S = Timeline.new(self.recipe.slug)
            self:save()
            self.pulse:restore()
            self.alert_key, self.quiet = nil, false
            self.page = "pull"
            self:render("full")
            self:afterChange()
        end,
    })
end

-- Ticking ------------------------------------------------------------------------------------------

function CookScreen:refreshBox(box)
    local r = box and box:region()
    if r then UIManager:setDirty(self, function() return CLOCK_REFRESH, r end) end
end

function CookScreen:tick()
    if not self.alive then return end
    local ok, err = pcall(self.tickInner, self)
    if not ok then self:fail("tick", err) end
    pcall(self.applyAwake, self)
    local S = self.S
    UIManager:unschedule(self.tick_fn)   -- a render inside the tick may already have scheduled the next one
    if self.alive and S.started and not S.finished and not self.errored then UIManager:scheduleIn(TICK, self.tick_fn) end
end

function CookScreen:tickInner()
    local S, R = self.S, self.recipe
    if not S.started or S.finished then return end
    local now = os.time()
    local events = Timeline.tick(S, R, now)
    if #events > 0 then self:save() end

    local alert = Timeline.active_alert(S, R, now)
    if alert then
        local key = alert.kind .. ":" .. tostring(alert.tracker or alert.idx) .. ":" .. tostring(alert.view and alert.view.stage.id or "")
        if key ~= self.alert_key then
            -- a new alert (or the first one): the card takes the screen, the light flashes
            self.alert_key, self.alert_first, self.last_pulse, self.quiet = key, now, nil, false
            if self.dialog then UIManager:close(self.dialog); self.dialog = nil end
            self:render("full")
        end
        if Timeline.pulse_due(self.alert_first, self.last_pulse, now) then
            if self.pulse:flash() then self.last_pulse = now end
        elseif Timeline.pulse_over(self.alert_first, now) and not self.quiet then
            -- Nobody came for 15 minutes: stop flashing and let the Kindle sleep. The card stays up.
            self.quiet = true
            self.pulse:restore()
            self.keepawake:off()
        end
        return
    end
    if self.alert_key then
        -- the alert was answered somewhere else; back to the page
        self.alert_key, self.quiet = nil, false
        self.pulse:restore()
        self:render("full")
        self:afterChange()
        return
    end
    if self.page ~= "step" then return end
    if self.step_clock then
        local t = self:stepClockText(now)
        if t ~= self.step_clock.text then self.step_clock.text = t; self:refreshBox(self.step_clock) end
    end
    for id, box in pairs(self.tracker_clocks) do
        local v = Timeline.tracker_view(S, R, id, now)
        if v and v.left and v.stage.id == box.stage_id then
            local t = fmt(v.left)
            if t ~= box.text then box.text = t; self:refreshBox(box) end
        else
            self:render("full")  -- a tracker changed stage: the band changes shape
            return
        end
    end
    local m = math.floor(Timeline.elapsed(S, now) / 60)
    if self.elapsed_box and m ~= self.elapsed_minute then
        self.elapsed_minute = m
        self.elapsed_box.text = "Elapsed " .. elapsedLabel(Timeline.elapsed(S, now))
        self:refreshBox(self.elapsed_box)
    end
end

-- Errors ---------------------------------------------------------------------------------------------

-- Anything thrown while ticking or drawing ends up here: log it, release the keep-awake and the
-- light (a broken screen must never keep the Kindle awake), and show a page with a way out.
function CookScreen:fail(where, err)
    logger.warn("Kitchen Timer: " .. where .. " failed:", tostring(err))
    self.last_error = where .. ": " .. tostring(err)
    self.errored = true
    pcall(function() self.keepawake:off() end)
    pcall(function() self.pulse:restore() end)
    pcall(function()
        UIManager:unschedule(self.tick_fn)
        self[1] = self:buildError()
        UIManager:setDirty(self, "full")
    end)
end

-- Lifecycle --------------------------------------------------------------------------------------------

-- Power button / auto-suspend: nothing can run while asleep, so let go of everything.
function CookScreen:onSuspend()
    UIManager:unschedule(self.tick_fn)
    pcall(function() self.pulse:restore() end)
    pcall(function() self.keepawake:off() end)
end

function CookScreen:onResume()
    if not self.alive then return end
    if self.errored then   -- keep the error page (and its way out) instead of a frozen step page
        UIManager:setDirty(self, "full")
        return
    end
    self.alert_key, self.quiet = nil, false   -- an alert still waiting gets its pulses again
    local ok, err = pcall(function() self:render("full"); self:afterChange(); self:tick() end)
    if not ok then self:fail("resume", err) end
end

-- KOReader quitting doesn't close widgets, so release on these too (don't consume them).
function CookScreen:onExit() pcall(function() self.pulse:restore(); self.keepawake:off() end) end
function CookScreen:onRestart() pcall(function() self.pulse:restore(); self.keepawake:off() end) end

function CookScreen:close()
    if not self.alive then return end
    self.alive = false
    UIManager:unschedule(self.tick_fn)
    pcall(function() self.pulse:restore() end)
    pcall(function() self.keepawake:off() end)
    if self.dialog then UIManager:close(self.dialog); self.dialog = nil end
    self:save()
    UIManager:close(self, "flashui")
    if self.on_close then self.on_close() end
end

function CookScreen:onCloseWidget()
    self.alive = false
    UIManager:unschedule(self.tick_fn)
    pcall(function() self.pulse:restore() end)
    pcall(function() self.keepawake:off() end)
end

return CookScreen
