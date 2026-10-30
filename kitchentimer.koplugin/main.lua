--[[
Kitchen Timer: walks you through a recipe step by step, at the moment each step is needed.
Open it from Tools > Kitchen Timer, or bind "Open Kitchen Timer" to a gesture.

Standalone from Relic: its own settings files (kitchentimer_*.lua), its own updater and folder.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")

local plugin_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Timeline = dofile(plugin_dir .. "timeline.lua")
local Updater = dofile(plugin_dir .. "updater.lua")
Updater.setPluginDir(plugin_dir)
local KeepAwake = dofile(plugin_dir .. "keepawake.lua")
local Pulse = dofile(plugin_dir .. "pulse.lua")
local CookScreen = dofile(plugin_dir .. "cookscreen.lua")

local keepawake = KeepAwake.new{ device = Device, share = PluginShare, settings = G_reader_settings, logger = logger }
local pulse = Pulse.new{ device = Device, ui = UIManager, logger = logger }

-- Run state: one active cook at a time, in a settings file of its own. One handle for the whole
-- session, so a later flush can't wipe an earlier one (Relic lesson).
local run_handle
local Store = {}
local function handle()
    run_handle = run_handle or LuaSettings:open(DataStorage:getSettingsDir() .. "/kitchentimer_run.lua")
    return run_handle
end
function Store.load(_self) return handle():readSetting("run") end
function Store.save(_self, state)
    local h = handle()
    h:saveSetting("run", state)
    h:flush()
end

-- Recipes: every recipes/*.lua next to this file. A broken one is skipped, not fatal.
local function loadRecipes()
    local list, dir = {}, plugin_dir .. "recipes"
    if lfs.attributes(dir, "mode") ~= "directory" then return list end
    for name in lfs.dir(dir) do
        local slug = name:match("^(.+)%.lua$")
        if slug then
            local ok, r = pcall(dofile, dir .. "/" .. name)
            if ok and type(r) == "table" and r.slug == slug and r.title and type(r.steps) == "table" and #r.steps > 0 then
                list[#list + 1] = r
            else
                logger.warn("Kitchen Timer: skipping recipe", name, ok and "(not a recipe)" or tostring(r))
            end
        end
    end
    table.sort(list, function(a, b) return a.title < b.title end)
    return list
end

local Kitchen = WidgetContainer:extend{
    name = "kitchentimer",
    is_doc_only = false,
}

local started_once = false

function Kitchen:init()
    Dispatcher:registerAction("kitchentimer_open", { category = "none", event = "OpenKitchenTimer",
        title = _("Open Kitchen Timer"), general = true })
    if self.ui and self.ui.menu then self.ui.menu:registerToMainMenu(self) end
    if not started_once then
        started_once = true
        -- A hold left behind by a crash during a cook: let go of it now.
        pcall(function() keepawake:releaseStale() end)
        UIManager:scheduleIn(20, function() self:checkForUpdate(false) end)
    end
end

-- Picker ------------------------------------------------------------------------------------------

function Kitchen:onOpenKitchenTimer()
    if self.screen then return true end
    if self.picker then return true end
    self:openPicker()
    return true
end

function Kitchen:openPicker()
    local recipes = loadRecipes()
    local saved = Store:load()
    local items = {}
    for _i, r in ipairs(recipes) do
        local note = string.format("about %d min", Timeline.header_minutes(r))
        if type(saved) == "table" and saved.slug == r.slug and saved.started and not saved.finished
            and tonumber(saved.idx) and saved.idx <= #r.steps and os.time() - (saved.run_start or 0) <= Timeline.RESET_AFTER then
            note = string.format("Resume: step %d of %d", saved.idx, #r.steps)
        end
        items[#items + 1] = { text = r.title, mandatory = note, callback = function() self:openRecipe(r) end }
    end
    if #items == 0 then
        items[1] = { text = _("No recipes installed yet. Connect to Wi-Fi and use Check for updates."), select_enabled = false }
    end
    local picker
    picker = Menu:new{
        title = _("Kitchen Timer"),
        item_table = items,
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        close_callback = function()
            UIManager:close(picker)
            if self.picker == picker then self.picker = nil end
        end,
    }
    self.picker = picker
    UIManager:show(picker)
end

function Kitchen:openRecipe(recipe)
    local saved = Store:load()
    local other = type(saved) == "table" and saved.slug ~= recipe.slug and saved.started and not saved.finished
        and os.time() - (saved.run_start or 0) <= Timeline.RESET_AFTER
    if other then
        UIManager:show(ConfirmBox:new{
            text = _("You are in the middle of another recipe. Start this one instead? That clears your place in the other."),
            ok_text = _("Start this one"),
            ok_callback = function()
                Store:save(Timeline.new(recipe.slug))
                self:showScreen(recipe)
            end,
        })
        return
    end
    self:showScreen(recipe)
end

function Kitchen:showScreen(recipe)
    local ok, screen = pcall(CookScreen.new, CookScreen, {
        recipe = recipe, store = Store, keepawake = keepawake, pulse = pulse,
        on_close = function()
            self.screen = nil
            UIManager:nextTick(function() self:onOpenKitchenTimer() end)
        end,
    })
    if not ok then
        logger.warn("Kitchen Timer: could not open the recipe:", tostring(screen))
        pcall(function() keepawake:off(); pulse:restore() end)
        UIManager:show(InfoMessage:new{ text = _("Kitchen Timer could not open this recipe.") })
        return
    end
    self.screen = screen
    UIManager:show(screen, "full")
end

-- Updates -------------------------------------------------------------------------------------------

-- force = the person asked from the menu, so always say what happened.
function Kitchen:checkForUpdate(force)
    if self.screen then
        -- Swapping files under a running cook would be a bad day. Never auto-update mid-cook.
        if force then UIManager:show(InfoMessage:new{ text = _("Finish or leave your cook first, then check for updates.") }) end
        return
    end
    local ok, result, version = pcall(Updater.check, force)
    if not ok then
        if force then UIManager:show(InfoMessage:new{ text = _("Update check failed.") }) end
        return
    end
    if result == "installed" then
        UIManager:show(ConfirmBox:new{
            text = string.format(_("Kitchen Timer update %d installed.\nRestart now to apply it?"), version),
            ok_text = _("Restart"),
            ok_callback = function() UIManager:askForRestart() end,
        })
    elseif force then
        local msg = ({
            no_config = _("No update source."),
            offline = _("Not connected to Wi-Fi."),
            failed = _("Update check failed. Try again later."),
            current = _("Kitchen Timer is up to date."),
        })[result] or tostring(result)
        UIManager:show(InfoMessage:new{ text = msg })
    end
end

function Kitchen:rollbackUpdate()
    if self.screen then
        UIManager:show(InfoMessage:new{ text = _("Finish or leave your cook first.") })
        return
    end
    if not Updater.canRollback() then
        UIManager:show(InfoMessage:new{ text = _("No previous version to roll back to.") })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Roll back to the previous Kitchen Timer version? Your place in a recipe is not affected."),
        ok_text = _("Roll back"),
        ok_callback = function()
            if Updater.rollback() then
                UIManager:askForRestart(_("Rolled back. Restarting to apply."))
            else
                UIManager:show(InfoMessage:new{ text = _("Rollback failed.") })
            end
        end,
    })
end

function Kitchen:onNetworkConnected()
    UIManager:scheduleIn(5, function() self:checkForUpdate(false) end)
end

function Kitchen:addToMainMenu(menu_items)
    menu_items.kitchentimer = {
        text = _("Kitchen Timer"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Open Kitchen Timer"), callback = function() self:onOpenKitchenTimer() end },
            { text = _("Check for updates"), keep_menu_open = true, callback = function() self:checkForUpdate(true) end },
            { text = _("Roll back last update"), keep_menu_open = true, callback = function() self:rollbackUpdate() end },
            { text_func = function() return string.format(_("Version %d"), Updater.installedVersion()) end, enabled = false },
        },
    }
end

-- KOReader quitting doesn't close widgets: let go of the light and the keep-awake whatever happens.
function Kitchen:onExit() pcall(function() pulse:restore(); keepawake:off() end) end
function Kitchen:onRestart() pcall(function() pulse:restore(); keepawake:off() end) end

return Kitchen
