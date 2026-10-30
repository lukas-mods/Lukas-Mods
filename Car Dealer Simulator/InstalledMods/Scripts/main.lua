--[[
    Installed Mods v1.0 -- by Luka's Mods

    Adds an INSTALLED MODS button to the game's title menu. It opens a page
    listing your installed UE4SS mods: each mod's on/off state and its
    version, when the mod gives one. Switch mods on or off, press Apply, and
    the change takes effect the next time you start the game. After Apply, a
    box offers to quit the game now, so you can start it again.

    What it changes on disk: only a mod's enabled.txt (renamed to
    enabled.txt.off to switch it off, and back to switch it on), and only when
    you press Apply. It never switches itself or UE4SS's built-in mods, and
    never touches anything else in a mod's folder. The one file of its own it
    writes is the bug report, in this mod's folder. It makes no web requests
    of its own.

    Report a Bug and Request a Feature open the GitHub issue forms in your
    browser. Report a Bug first saves a report file in this mod's folder (the
    mod list, with no file paths in it) and, when it can, opens its folder
    with the file selected, so you can drag it into the form.

    Versions come from each mod's mod-support.json, when it has one, or else
    from the version the mod printed in UE4SS.log when it loaded.
--]]
local MOD = "InstalledMods"
local VERSION = "1.0"
local function log(msg) print("[" .. MOD .. "] " .. tostring(msg) .. "\n") end

local src = debug.getinfo(1, "S").source
local SCRIPTS_DIR = (src:sub(1, 1) == "@") and src:sub(2):match("(.*[/\\])") or ".\\"
local MOD_DIR = SCRIPTS_DIR .. "..\\"
local MODS_DIR = MOD_DIR .. "..\\"

local okCore, core = pcall(dofile, SCRIPTS_DIR .. "core.lua")
if not okCore then
    log("v" .. VERSION .. " could not load core.lua: " .. tostring(core))
    return
end

local function read_all(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end

local function exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end


-------------------------------------------------------------------------------
-- The list. Three outcomes, never two: an unreadable folder must not look
-- like "no mods installed".

local function list_mods()
    local names, root = {}, nil
    local ok = pcall(function()
        local m = IterateGameDirectories().Game.Binaries.Win64.ue4ss.Mods
        root = m.__absolute_path
        for k, v in pairs(m) do
            if type(k) == "string" and not k:find("^__") and type(v) == "table" then names[#names + 1] = k end
        end
    end)
    if not ok then return nil, nil end
    table.sort(names, function(x, y) return x:lower() < y:lower() end)
    return names, root
end

-- One row per mod folder. Returns nil and a reason when the folder itself
-- can't be read, so that never shows as an empty list.
local function collect_rows()
    local names, root = list_mods()
    if not names then return nil, "Couldn't read your UE4SS Mods folder." end
    local list = core.parse_mods_txt(read_all(MODS_DIR .. "mods.txt"))
    -- Read once per list: the versions mods printed as they loaded this launch.
    local logged = core.versions_from_log(read_all(MODS_DIR .. "..\\UE4SS.log"))
    local rows = {}
    for i, name in ipairs(names) do
        if i > core.MAX_ROWS then break end
        local dir = MODS_DIR .. name .. "\\"
        local marker = exists(dir .. "enabled.txt")
        local entry = list and list.index[name] or nil
        local m, notes = nil, nil
        local text = read_all(dir .. "mod-support.json")
        if text then m, notes = core.read_manifest(text) end
        rows[#rows + 1] = {
            folder = name, marker = marker, entry = entry,
            state = core.state_of(marker, entry),
            locked = core.lock_reason(core.BUILTINS[name] == true, name == MOD, marker,
                exists(dir .. "Scripts\\main.lua") or exists(dir .. "dlls\\main.dll"), entry ~= nil),
            name = m and m.name or name, version = (m and m.version) or logged[name],
            versionFrom = (m and m.version) and "file" or (logged[name] and "log" or nil),
            notes = notes,
        }
    end
    return rows, nil, root, list
end


local function game_loop(ms, fn)
    if type(LoopInGameThreadWithDelay) ~= "function" then return false end
    local handle
    handle = LoopInGameThreadWithDelay(ms, function()
        local ok, stop = pcall(fn)
        if (not ok or stop) and handle and type(CancelDelayedAction) == "function" then CancelDelayedAction(handle) end
    end)
    return true
end

local TITLE_CLASS = "/Game/MenuSystemPro/ExampleContent/Designs/Design_Silence/Menus/TitleScreen/WBP_TitleScreenMenu_Silence.WBP_TitleScreenMenu_Silence_C"
local BUTTON_CLASS = "/Game/MenuSystemPro/ExampleContent/Designs/Design_Silence/Widgets/Buttons/WBP_TitleScreenButton_Silence.WBP_TitleScreenButton_Silence_C"

-------------------------------------------------------------------------------
-- Our button's size, checked ten times a second while the title menu is up,
-- so it grows and shrinks by the same rule as the game's own buttons.

local addedButton = nil
local pageMode = false
local buttonsByMenu, ourButtons = {}, {}
local titleMenu = nil
local grow
local toggle_window, refresh_window, show_restart_box
local lastHost, lastCanvas = nil, nil
local function border_scale(btn)
    local v = 1.0
    pcall(function() v = btn.OuterBorder.RenderTransform.Scale.X end)
    return v
end

local function playing_way(btn)
    local way = nil
    pcall(function()
        if btn:IsAnimationPlaying(btn.HoverScale) then
            way = btn:IsAnimationPlayingForward(btn.HoverScale) and "in" or "out"
        end
    end)
    return way
end

grow = function(btn)
    if playing_way(btn) == "in" or border_scale(btn) > 1.39 then return end
    pcall(function() btn:PlayAnimationForward(btn.HoverScale, 1.0, false) end)
end

local function shrink(btn)
    if playing_way(btn) == "out" or border_scale(btn) < 1.01 then return end
    pcall(function() btn:PlayAnimationReverse(btn.HoverScale, 1.0, false) end)
end

-- The pointer counts as gone after three checks in a row without it:
-- the hover state flickers for a tick or two even on the game's own buttons
-- while the pointer is still.
local offTicks = 0
local function keep_button_size()
    if not (addedButton and addedButton:IsValid()) then return end
    local on = false
    pcall(function() on = addedButton:IsHovered() end)
    if on then
        offTicks = 0
        return
    end
    offTicks = offTicks + 1
    if offTicks >= 3 then shrink(addedButton) end
end

-------------------------------------------------------------------------------
-- The title-menu button: one of the menu's own button widgets, placed above
-- Quit so it sits after the game's items, never between them.

local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"
local BUTTON_LABEL = "INSTALLED MODS"
local buttonGaveUp = false
local BUTTON_HOVER = BUTTON_CLASS
    .. ":BndEvt__WBP_MainButton_Silence_MainButton_K2Node_ComponentBoundEvent_3_OnButtonHoverEvent__DelegateSignature"
local BUTTON_CLICK = BUTTON_CLASS
    .. ":BndEvt__WBP_MainButton_Silence_MainButton_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature"

-- Registered only once the button class is live: RegisterHook on a class that
-- isn't loaded makes UE4SS search every object for it.
local clickHooked = false
local function hook_click()
    if clickHooked then return end
    clickHooked = true
    local okH, errH = pcall(function()
        RegisterHook(BUTTON_CLICK, function(ctx)
            local clicked = nil
            pcall(function() clicked = ctx:get() end)
            local menuOf = clicked and ourButtons[clicked:GetAddress()]
            if menuOf then
                local mine = buttonsByMenu[menuOf:GetAddress()]
                if mine then addedButton, titleMenu = mine, menuOf end
                log("button: Installed Mods clicked")
                ExecuteInGameThread(function()
                    local okW, errW = pcall(toggle_window)
                    if not okW then log("window failed: " .. tostring(errW)) end
                end)
            end
        end)
    end)
    log("button click hook " .. (okH and "registered" or ("FAILED, not retried: " .. tostring(errH))))

    -- The menu shrinks the last highlighted button when another of ITS
    -- buttons is hovered; ours isn't on its list, so a move between ours and
    -- one of the game's has to shrink the one left behind here.
    -- On the game's own buttons, HoverScale takes OuterBorder from 1.0 to 1.4
    -- in a quarter second on the way in, and back on the way out. The
    -- menu runs that for its buttons and not for ours, so ours runs it here:
    -- grow when the game reports the pointer on it, shrink once it has left
    -- (see keep_button_size). The drawn scale decides, never the animation's
    -- own clock, so nothing ever plays from the wrong end.
    local okV, errV = pcall(function()
        RegisterHook(BUTTON_HOVER, function(ctx)
            local hovered = nil
            pcall(function() hovered = ctx:get() end)
            if not (hovered and hovered:IsValid() and addedButton and addedButton:IsValid()) then return end
            if hovered:GetAddress() == addedButton:GetAddress() then grow(addedButton) end
        end)
    end)
    log("button hover hook " .. (okV and "registered" or ("FAILED, not retried: " .. tostring(errV))))
end

local function add_title_button(menu)
    -- One button per title menu, recorded by the menu's address the moment
    -- it is created, and never a second. After Settings the game has two
    -- title menus alive at once; a single "our button"
    -- slot made each menu think the other's button was missing, and a button
    -- was added every second.
    local key = menu:GetAddress()
    if buttonsByMenu[key] ~= nil then
        addedButton, titleMenu = buttonsByMenu[key], menu
        return
    end
    buttonsByMenu[key] = false   -- claimed before anything can fail
    local quit = menu.QuitTitleScreenButton
    if not (quit and quit:IsValid()) then log("button: no Quit button") return end
    local box = quit:GetParent()
    if not (box and box:IsValid()) then log("button: Quit has no parent") return end
    local cls = StaticFindObject(BUTTON_CLASS)
    local lib = StaticFindObject(WIDGET_LIBRARY)
    local owner = nil
    pcall(function() owner = menu:GetOwningPlayer() end)
    local btn = lib:Create(menu, cls, owner)
    if not (btn and btn:IsValid()) then log("button: could not create") return end
    -- No insert-at-index outside the editor, so: add ours at the end, then
    -- move Quit back to the end with the spacing its old slot had.
    local qs = quit.Slot
    local pad, ha, va = nil, nil, nil
    pcall(function()
        local p = qs.Padding
        pad = { Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom }
        ha, va = qs.HorizontalAlignment, qs.VerticalAlignment
    end)
    local function style(slot)
        pcall(function()
            if pad then slot:SetPadding(pad) end
            if ha then slot:SetHorizontalAlignment(ha) end
            if va then slot:SetVerticalAlignment(va) end
        end)
    end
    style(box:AddChildToVerticalBox(btn))
    box:RemoveChild(quit)
    style(box:AddChildToVerticalBox(quit))
    local okT, errT = pcall(function() btn.ButtonText:SetText(FText(BUTTON_LABEL)) end)
    addedButton = btn
    titleMenu = menu
    buttonsByMenu[key] = btn
    ourButtons[btn:GetAddress()] = menu
    hook_click()
    log(string.format("button: added, ours at %d, Quit at %d of %d, label %s",
        box:GetChildIndex(btn), box:GetChildIndex(quit), box:GetChildrenCount(),
        okT and "set" or ("not set: " .. tostring(errT))))
end

local function try_title_button()
    local ok, all = pcall(function() return FindAllOf("WBP_TitleScreenMenu_Silence_C") end)
    if not ok or not all then return end
    for _, m in ipairs(all) do
        local p = ""
        pcall(function() p = m:GetFullName() end)
        local shown = false
        pcall(function() shown = m:IsVisible() end)
        if m:IsValid() and shown and not p:find("Default__", 1, true) then
            if buttonGaveUp then return end
            local okB, errB = pcall(add_title_button, m)
            -- One failure is enough: retrying every second would create a
            -- new button widget each time.
            if not okB then buttonGaveUp = true log("button failed, not retried: " .. tostring(errB)) end
        end
    end
end

-------------------------------------------------------------------------------
-- The window: built from plain UMG widgets inside the title menu's own canvas,
-- so it sits over the menu and goes away with it. The header and its "added
-- by a mod" line sit above the list, never inside it, so a long list can't
-- scroll them away.

local COLORS = {
    panel = { R = 0.035, G = 0.04, B = 0.05, A = 1.0 },
    btn = { R = 0.16, G = 0.18, B = 0.22, A = 1.0 },
    btnOn = { R = 0.12, G = 0.40, B = 0.16, A = 1.0 },
    btnOff = { R = 0.45, G = 0.14, B = 0.12, A = 1.0 },
    white = { R = 1, G = 1, B = 1, A = 1 },
    dim = { R = 0.62, G = 0.64, B = 0.68, A = 1 },
    on = { R = 0.40, G = 0.95, B = 0.45, A = 1 },
    off = { R = 0.95, G = 0.40, B = 0.35, A = 1 },
    mixed = { R = 1.0, G = 0.75, B = 0.25, A = 1 },
}

local widgetCounter = 0
local function new_widget(kind, outer)
    local cls = StaticFindObject("/Script/UMG." .. kind)
    if not (cls and cls:IsValid()) then error("UMG class missing: " .. kind) end
    widgetCounter = widgetCounter + 1
    local w = StaticConstructObject(cls, outer, FName(string.format("IM_%s_%d", kind, widgetCounter)))
    if not (w and w:IsValid()) then error("could not create " .. kind) end
    return w
end

local function text(outer, s, size, color)
    local t = new_widget("TextBlock", outer)
    t:SetText(FText(s))
    pcall(function()
        local font = t.Font
        font.Size = size
        t:SetFont(font)
    end)
    pcall(function() t:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end)
    return t
end

-- The logo: Assets\logo.png in this mod's folder (square, 256 x 256), loaded
-- at runtime with the engine's ImportFileAsTexture2D. The window works the
-- same without it.
local LOGO_FILE = MOD_DIR .. "Assets\\logo.png"
local logoLogged = false
local function make_logo(ctx, outer, size)
    local lib = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
    local tex = nil
    local ok = lib and lib:IsValid() and pcall(function() tex = lib:ImportFileAsTexture2D(ctx, LOGO_FILE) end)
    if not ok or not (tex and tex:IsValid()) then
        if not logoLogged then log("logo not loaded: Assets\\logo.png") logoLogged = true end
        return nil
    end
    local img = new_widget("Image", outer)
    pcall(function() img:SetBrushFromTexture(tex, false) end)
    pcall(function() img:SetVisibility(3) end)   -- never takes the mouse
    local box = new_widget("SizeBox", outer)
    pcall(function() box:SetHeightOverride(size) end)
    pcall(function() box:SetWidthOverride(size) end)
    box:SetContent(img)
    return box
end

-- Fixed column widths: every row lines up whether it has a switch or not,
-- and a long name or label is cut at its column instead of running into the
-- next one.
local COL = { name = 440, state = 300, version = 230, switch = 170 }
local function cell(outer, content, width)
    local box = new_widget("SizeBox", outer)
    pcall(function() box:SetWidthOverride(width) end)
    pcall(function() box:SetHeightOverride(44) end)   -- every row the same height
    pcall(function() box:SetClipping(1) end)   -- clip to bounds
    box:SetContent(content)
    return box
end

local function pad(slot, l, t, r, b)
    pcall(function() slot:SetPadding({ Left = l, Top = t, Right = r, Bottom = b }) end)
end

-- Kept as the object, not a path: StaticFindObject on a path that has gone
-- makes UE4SS walk every object in the game.
local windowRef = nil

local function window_alive()
    local ok, alive = pcall(function() return windowRef and windowRef:IsValid() and windowRef:GetParent():IsValid() end)
    if ok and alive then return windowRef end
    windowRef = nil
    return nil
end

-- Our window's buttons are plain UMG Buttons. UMG's OnClicked can't be bound
-- from Lua, so a click is read from the button itself: pressed on one check,
-- released while the pointer is still on it on the next (checked every 20 ms
-- while the window is open).
local clickables = {}

local modalRef = nil        -- the quit box, while it is open

-- The box's buttons leave the click list with it. Once unparented, the
-- garbage collector can free them, and asking a freed button IsPressed is a
-- native crash that pcall can't catch. So every way modalRef is let go of
-- comes through here, whatever order the game loop runs things in.
local function drop_modal_clicks()
    local kept = {}
    for _, c in ipairs(clickables) do
        if c.group ~= "modal" then kept[#kept + 1] = c end
    end
    clickables = kept
end

local function modal_open()
    local ok, alive = pcall(function() return modalRef and modalRef:IsValid() and modalRef:GetParent():IsValid() end)
    if ok and alive then return true end
    if modalRef ~= nil then
        modalRef = nil
        drop_modal_clicks()
    end
    return false
end

local function button(outer, label, size, color, action, group)
    local b = new_widget("Button", outer)
    pcall(function() b:SetBackgroundColor(color) end)
    local t = text(outer, label, size, COLORS.white)
    local slot = b:AddChild(t)
    pcall(function() slot:SetPadding({ Left = 14, Top = 4, Right = 14, Bottom = 4 }) end)
    clickables[#clickables + 1] = { b = b, label = t, action = action, down = false, group = group }
    return b, t
end

local function poll_clicks()
    -- While the quit box is open, only its own buttons answer.
    local modal = modal_open()
    for _, c in ipairs(clickables) do
        if modal and c.group ~= "modal" then goto continue end
        local pressed, hovered = false, false
        pcall(function() pressed = c.b:IsPressed() hovered = c.b:IsHovered() end)
        if c.down and not pressed and hovered then
            local ok, err = pcall(c.action, c)
            if not ok then log("click failed: " .. tostring(err)) end
        end
        c.down = pressed
        ::continue::
    end
end

-- Switches the player has flipped but not applied, by folder name (in
-- memory only: lost if the game quits first). true = on, false = off.
local pending = {}
-- Switches Apply has written this session: on disk now, in effect only at
-- the next start.
local applied = {}
-- Each mod's state the first time the list read it this session: what UE4SS
-- started it as. An Apply that puts a mod back to this is no change at the
-- next start, so the row shows the plain state, not "at next start".
local startState = {}

-- What the status column says. Three states: switched but not saved,
-- saved this session (takes effect at the next start), or as it is.
local LOCK_WORDS = { ["this mod"] = "this mod", ["no mod files"] = "no mod files", ["set in mods.txt"] = "set in mods.txt" }
local function state_words(row)
    local want = pending[row.folder]
    if want ~= nil then
        return (want and "ON" or "OFF") .. ", not saved", COLORS.mixed
    end
    if applied[row.folder] ~= nil and (startState[row.folder] == "on") ~= applied[row.folder] then
        return (applied[row.folder] and "ON" or "OFF") .. " at next start", COLORS.mixed
    end
    local why = row.locked and LOCK_WORDS[row.locked]
    if row.state == "mixed" then return "MIXED (see mods.txt)", COLORS.mixed end
    local word, color = (row.state == "on") and "ON" or "OFF", (row.state == "on") and COLORS.on or COLORS.off
    if why then word = word .. " (" .. why .. ")" end
    return word, color
end

local function switch_label(row)
    local want = pending[row.folder]
    local on = want
    if on == nil then on = (row.state == "on") end
    return on and "Turn Off" or "Turn On", on and COLORS.btnOff or COLORS.btnOn
end

-------------------------------------------------------------------------------
-- Apply: the one place the mod changes another mod. Each change is the
-- mod's enabled.txt marker and nothing else:
--   off: enabled.txt is renamed to enabled.txt.off (kept, so on can restore
--        exactly what was there);
--   on:  enabled.txt.off is renamed back, or an empty enabled.txt is written
--        to a temporary name first and renamed into place, so a crash can't
--        leave a half-written file.
-- A mod switched by a mods.txt line is not changed by this mod.

local MARKER, PARKED, TEMP = "enabled.txt", "enabled.txt.off", "enabled.txt.im-tmp"

-- The folder name comes from the Mods folder listing; refuse anything that
-- could reach outside it, and refuse this mod and UE4SS's own.
local function safe_folder(folder)
    if type(folder) ~= "string" or folder == "" or folder:find("[\\/:]") or folder:find("%.%.") then return false end
    -- Windows drops trailing dots and spaces from a folder name, so
    -- "FuelProbe." would land on FuelProbe.
    if folder:find("[%. ]$") then return false end
    if folder == MOD or core.BUILTINS[folder] then return false end
    return true
end

local function apply_change(row, want)
    if not safe_folder(row.folder) then return false, "refused" end
    if row.entry then return false, "set by mods.txt; not changed by this build" end
    local dir = MODS_DIR .. row.folder .. "\\"
    local marker, parked, temp = dir .. MARKER, dir .. PARKED, dir .. TEMP
    if want then
        if exists(marker) then return true, "already on" end
        if exists(parked) then
            local ok = os.rename(parked, marker)
            if not ok then return false, "could not restore enabled.txt" end
        else
            local f = io.open(temp, "wb")
            if not f then return false, "could not write in the mod's folder" end
            f:close()
            local ok = os.rename(temp, marker)
            if not ok then pcall(os.remove, temp) return false, "could not create enabled.txt" end
        end
        return exists(marker), exists(marker) and "on" or "enabled.txt missing after the change"
    else
        if not exists(marker) then return true, "already off" end
        if exists(parked) then pcall(os.remove, parked) end
        local ok = os.rename(marker, parked)
        if not ok then return false, "could not rename enabled.txt" end
        return not exists(marker), (not exists(marker)) and "off" or "enabled.txt still there after the change"
    end
end

local lastApply = nil

local function apply_all(rows)
    local done, failed = 0, {}
    for _, row in ipairs(rows) do
        local want = pending[row.folder]
        if want ~= nil then
            local ok, err = apply_change(row, want)
            log(string.format("apply: %s -> %s: %s", row.folder, want and "on" or "off", ok and ("done (" .. err .. ")") or ("FAILED: " .. err)))
            if ok then done = done + 1 pending[row.folder] = nil applied[row.folder] = want else failed[#failed + 1] = row.name end
        end
    end
    local function saved_line(n, other)
        if n == 1 then return "1 " .. (other and "other " or "") .. "change saved. It takes effect the next time you start the game." end
        return n .. " " .. (other and "other " or "") .. "changes saved. They take effect the next time you start the game."
    end
    if #failed == 0 then
        lastApply = saved_line(done, false)
    elseif done == 0 then
        lastApply = "Couldn't change: " .. table.concat(failed, ", ") .. "."
    else
        lastApply = "Couldn't change: " .. table.concat(failed, ", ") .. ". " .. saved_line(done, true)
    end
end

local function count_pending()
    local n = 0
    for _ in pairs(pending) do n = n + 1 end
    return n
end

-------------------------------------------------------------------------------
-- Report a Bug / Request a Feature. The mod never posts anything itself: it
-- opens the public repo's issue form, pre-filled with this mod's name and
-- version, through the engine's own LaunchURL (no command is run). The URL is
-- a fixed address plus encoded fields, nothing read from another mod.

local ISSUES = { url = "https://github.com/lukas-mods/Lukas-Mods/issues/new", name = "CDS - Installed Mods" }

local function issue_url(template)
    return core.issue_url(ISSUES.url, template, ISSUES.name, VERSION)
end

local function launch(target)
    local ok, err = pcall(function()
        StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):LaunchURL(target)
    end)
    if not ok then log("could not open " .. target .. ": " .. tostring(err)) end
    return ok
end

-- THE RULE: no absolute path leaves the mod. Not the report, not a URL, not
-- a log line, not a note on screen. That is what keeps the Windows user name
-- out of everything a player might send us (the report and UE4SS.log travel
-- together). core.scrub is the backstop for the day someone adds a path to
-- the report. (A folder path handed to LaunchURL goes to the browser: the
-- same rule broken by a different channel.)
local function scrub(v) return core.scrub(v, os.getenv("USERNAME")) end

-- The report: written to this mod's own folder, the one place it writes
-- besides a mod's enabled.txt. Returns the file's path, or nil.
local function write_bug_report()
    local dir = MOD_DIR:gsub("[^\\/]+[\\/]%.%.[\\/]$", "")
    local path = dir .. MOD .. "-bug-" .. os.date("%Y%m%d-%H%M%S") .. ".txt"
    local out = {}
    local function add(v) out[#out + 1] = scrub(v) end
    add(string.format("%s v%s bug report -- %s", MOD, VERSION, os.date("%Y-%m-%d %H:%M:%S")))
    -- This line is a promise the code keeps: if any path, error text or log
    -- excerpt is ever written into the report, change this line in the same
    -- commit.
    add("Drag this file into the GitHub issue. It lists your installed mods and holds no file paths, so your Windows user name isn't in it.")
    add("")
    add("== Mods (folder | enabled.txt | mods.txt | shown as | locked | version (from)) ==")
    local rows, err = collect_rows()
    if not rows then add(err) else
        for _, row in ipairs(rows) do
            add(string.format("%s | %s | %s | %s | %s | %s", row.folder, row.marker and "yes" or "no",
                row.entry and (row.entry.on and "1" or "0") or "-", row.state, row.locked or "-",
                row.version and (row.version .. " (" .. row.versionFrom .. ")") or "-"))
        end
    end
    add("")
    add("pending switches: " .. tostring(count_pending()) .. "   last apply: " .. tostring(lastApply or "-"))
    add("")
    add("== UE4SS mods.txt ==")
    add(read_all(MODS_DIR .. "mods.txt") or "(not found)")
    local f = io.open(path, "wb")
    if not f then return nil end
    f:write(table.concat(out, "\r\n"))
    f:close()
    return path, dir
end

local lastNote = nil

local function report_bug()
    local path = write_bug_report()
    if not path then
        lastNote = "Could not save the bug report file."
    else
        launch(issue_url("bug_report.yml"))
        -- The report's folder opens in Explorer with the file selected, the
        -- same as Parts Manager does, so the button behaves the same in every
        -- mod. LaunchURL can't do it: it hands a folder to the browser.
        -- Explorer is started through cmd, which expands %;
        -- a path with % or " is not passed to it, and the note says where the
        -- file is instead.
        -- One note, always naming where the file is: `start` returns at once,
        -- so whether Explorer actually opened can't be known here, and the
        -- location costs nothing when it did.
        local file = path:match("[^\\]+$")
        if not path:find('[%%"]') then
            pcall(function() os.execute('start "" explorer.exe /select,"' .. path .. '"') end)
        end
        lastNote = "Bug report saved to ue4ss\\Mods\\" .. MOD .. "\\" .. file
            .. ". GitHub is opening in your browser: alt-tab to it, drag the report file into the issue and press Submit."
    end
    log("report: " .. tostring(path and path:match("[^\\]+$")))
    refresh_window()
end

local function request_feature()
    launch(issue_url("feature_request.yml"))
    lastNote = "GitHub's feature request form is opening in your browser: alt-tab to it."
    refresh_window()
end

-------------------------------------------------------------------------------
-- Quit to apply, rather than restart. Asking Steam to start the game while
-- it is still running is a race: sometimes it works, sometimes Steam says
-- "Game already running". So the game only quits, and the player
-- starts it again. QuitGame is checked to be available before anything else.

local function quit_game()
    local lib, pc = nil, nil
    pcall(function()
        lib = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if lastHost and lastHost:IsValid() then pc = lastHost:GetOwningPlayer() end
    end)
    if not (lib and lib:IsValid() and lastHost and lastHost:IsValid() and pc and pc:IsValid()) then
        lastNote = "Couldn't quit the game from here. Quit it yourself: your changes take effect the next time you start it."
        log("quit: not available")
        refresh_window()
        return
    end
    log("quit: quitting so the changes apply at the next start")
    local ok, err = pcall(function() lib:QuitGame(lastHost, pc, 0, false) end)
    if not ok then log("quit: failed: " .. tostring(err)) end
end

local function build_window(menu, canvas)
    local outer = menu.WidgetTree
    canvas = canvas or menu.MenuCanvasPanel
    lastHost, lastCanvas = menu, canvas
    local border = new_widget("Border", outer)
    pcall(function() border:SetBrushColor(COLORS.panel) end)
    pcall(function() border:SetPadding({ Left = 36, Top = 28, Right = 36, Bottom = 24 }) end)
    local col = new_widget("VerticalBox", outer)
    border:SetContent(col)

    clickables = {}
    local head = new_widget("HorizontalBox", outer)
    local logo = make_logo(menu, outer, 72)
    if logo then
        local logoSlot = head:AddChildToHorizontalBox(logo)
        pcall(function() logoSlot:SetVerticalAlignment(2) end)
        pad(logoSlot, 0, 0, 18, 0)
    end
    local titleSlot = head:AddChildToHorizontalBox(text(outer, "Installed Mods \u{2014} by Luka's Mods", 34, COLORS.white))
    pcall(function() titleSlot:SetSize({ SizeRule = 1, Value = 1.0 }) end)
    local closeBtn = button(outer, pageMode and "Back" or "Close", 22, COLORS.btn, function() toggle_window() end)
    local closeSlot = head:AddChildToHorizontalBox(closeBtn)
    pcall(function() closeSlot:SetVerticalAlignment(2) end)
    pad(col:AddChildToVerticalBox(head), 0, 0, 0, 2)
    -- Second line: the "added by a mod" note, with the report buttons on its
    -- right (on the title line they ran into the title).
    local sub = new_widget("HorizontalBox", outer)
    local subSlot = sub:AddChildToHorizontalBox(text(outer, "Added by a mod. Not part of Car Dealer Simulator.", 18, COLORS.dim))
    pcall(function() subSlot:SetSize({ SizeRule = 1, Value = 1.0 }) end)
    pcall(function() subSlot:SetVerticalAlignment(2) end)
    for i, b in ipairs({ { "Report a Bug", report_bug }, { "Request a Feature", request_feature } }) do
        -- button() returns two values; only the widget goes to the box.
        local hb = sub:AddChildToHorizontalBox((button(outer, b[1], 18, COLORS.btn, b[2])))
        pcall(function() hb:SetVerticalAlignment(2) end)
        pad(hb, i == 1 and 0 or 12, 0, 0, 0)
    end
    pad(col:AddChildToVerticalBox(sub), 0, 4, 0, 18)

    -- Column headings, above the list so they never scroll away.
    local heads = new_widget("HorizontalBox", outer)
    for _, h in ipairs({ { "Mod", COL.name }, { "Status", COL.state }, { "Version", COL.version } }) do
        heads:AddChildToHorizontalBox(cell(outer, text(outer, h[1], 18, COLORS.dim), h[2]))
    end
    pad(col:AddChildToVerticalBox(heads), 0, 0, 0, 2)

    local scroll = new_widget("ScrollBox", outer)
    local scrollSlot = col:AddChildToVerticalBox(scroll)
    pcall(function() scrollSlot:SetSize({ SizeRule = 1, Value = 1.0 }) end)

    local rows, err = collect_rows()
    for _, row in ipairs(rows or {}) do
        if startState[row.folder] == nil then startState[row.folder] = row.state end
    end
    -- UE4SS's own built-in mods are left out of the window. They
    -- can't be switched here anyway, and the bug report still lists them.
    local shown = {}
    for _, row in ipairs(rows or {}) do
        if row.locked ~= "built-in" then shown[#shown + 1] = row end
    end
    if not rows then
        scroll:AddChild(text(outer, err, 22, COLORS.mixed))
    elseif #shown == 0 then
        scroll:AddChild(text(outer, "No mods found in your UE4SS Mods folder.", 22, COLORS.dim))
    else
        for _, row in ipairs(shown) do
            local line = new_widget("HorizontalBox", outer)
            local function add(content, width)
                local sl = line:AddChildToHorizontalBox(cell(outer, content, width))
                pcall(function() sl:SetVerticalAlignment(2) end)
                return sl
            end
            add(text(outer, row.name, 22, COLORS.white), COL.name)
            local word, color = state_words(row)
            local stateText = text(outer, word, 22, color)
            add(stateText, COL.state)
            add(text(outer, row.version or "\u{2013}", 22, row.version and COLORS.white or COLORS.dim), COL.version)
            -- No switch for locked rows, or for MIXED while it isn't known which
            -- of UE4SS's two settings wins.
            if not row.locked and row.state ~= "mixed" then
                local label, bcolor = switch_label(row)
                local sw = button(outer, label, 18, bcolor, function(c)
                    local current = pending[row.folder]
                    if current == nil then current = (row.state == "on") end
                    local want = not current
                    if want == (row.state == "on") then pending[row.folder] = nil else pending[row.folder] = want end
                    local l2, c2 = switch_label(row)
                    pcall(function() c.label:SetText(FText(l2)) end)
                    pcall(function() c.b:SetBackgroundColor(c2) end)
                    local w2, col2 = state_words(row)
                    pcall(function() stateText:SetText(FText(w2)) end)
                    pcall(function() stateText:SetColorAndOpacity({ SpecifiedColor = col2, ColorUseRule = 0 }) end)
                end)
                add(sw, COL.switch)
            end
            pad(scroll:AddChild(line), 0, 4, 0, 4)
        end
    end

    local foot = new_widget("HorizontalBox", outer)
    local note = lastNote or lastApply
    lastNote = nil
    -- A note (after Apply or Report a Bug) gets its own line, wrapped, so a
    -- long one can't run under Apply or out of the window.
    if note then
        local noteText = text(outer, note, 17, COLORS.mixed)
        pcall(function() noteText:SetAutoWrapText(true) end)
        pad(col:AddChildToVerticalBox(noteText), 0, 10, 0, 0)
    end
    local footText = text(outer, "Installed Mods " .. VERSION .. " \u{00B7} Luka's Mods   |   Changes take effect the next time you start the game.", 16, COLORS.dim)
    local footSlot = foot:AddChildToHorizontalBox(footText)
    pcall(function() footSlot:SetSize({ SizeRule = 1, Value = 1.0 }) end)
    pcall(function() footSlot:SetVerticalAlignment(2) end)
    local applyBtn = button(outer, "Apply", 20, COLORS.btn, function()
        if count_pending() == 0 then return end
        local before = count_pending()
        apply_all(rows or {})
        local saved = before - count_pending()
        -- Rebuilt from the folders, so it shows what is on disk now.
        refresh_window()
        -- A box, not a button beside Apply, which was easy to miss.
        -- Quit Game, or Later.
        if saved > 0 then show_restart_box(saved) end
    end)
    local applySlot = foot:AddChildToHorizontalBox(cell(outer, applyBtn, 170))
    pcall(function() applySlot:SetVerticalAlignment(2) end)
    pad(col:AddChildToVerticalBox(foot), 0, 12, 0, 0)

    local slot = canvas:AddChildToCanvas(border)
    pcall(function()
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
        slot:SetAlignment({ X = 0.5, Y = 0.5 })
        slot:SetSize({ X = 1240, Y = 760 })
        slot:SetPosition({ X = 0, Y = 0 })
        slot:SetZOrder(100)
    end)
    windowRef = border
    -- As a page, keyboard focus goes to our Back button, not the page: the
    -- page underneath is the game's Credits, which leaves on "hold any key"
    -- once it has focus (it closed itself about two seconds after opening).
    -- Esc is handled by the key bind at the end of this file.
    if pageMode then
        pcall(function()
            local pc = menu:GetOwningPlayer()
            closeBtn:SetUserFocus(pc)
            closeBtn:SetKeyboardFocus()
        end)
    end
    log("window: opened, " .. (rows and (#rows .. " rows") or "COULD NOT READ"))
end

-------------------------------------------------------------------------------
-- The list as a page. The menu system opens pages from classes built into
-- the game, and a Lua mod can't make a new one; so the title menu is asked to
-- open its Credits page (exactly what clicking CREDITS does), and when that
-- page appears its contents are hidden and the list is built in their place.
-- The game then treats it as the page it is: Back and Esc go back to the
-- title menu, as on Settings. The real CREDITS button opens a fresh Credits
-- page that is left alone.

local CREDITS_CLICK = "BndEvt__WBP_TitleScreenMenu_Silence_CreditsTitleScreenButton_K2Node_ComponentBoundEvent_1_OnWidgetClicked__DelegateSignature"
local pageWanted = nil       -- os.clock() of the click that asked for a page
local ourPage = nil
local seenPages = {}         -- page addresses that existed before the click

local function container()
    local c = nil
    pcall(function()
        for _, o in ipairs(FindAllOf("WBP_MenuContainer_Silence_C") or {}) do
            if o:IsValid() and not o:GetFullName():find("Default__", 1, true) then c = o break end
        end
    end)
    return c
end

local function short_class(o)
    local n = "?"
    pcall(function() n = o:GetClass():GetFName():ToString() end)
    return n
end

local function take_over(page)
    ourPage = page
    pageMode = true
    local root = nil
    pcall(function() root = page.WidgetTree.RootWidget end)
    if not (root and root:IsValid()) then log("page: no root widget on " .. short_class(page)) return false end
    local kids = {}
    local count = 0
    pcall(function() count = root:GetChildrenCount() end)
    for i = 0, count - 1 do
        pcall(function()
            local c = root:GetChildAt(i)
            kids[#kids + 1] = c:GetFName():ToString() .. "[" .. short_class(c) .. "]"
            if short_class(c) == "ScrollBox" then
                -- Kept in the layout, only made invisible: collapsed, its
                -- scroll length is zero and the page may treat the credits
                -- as finished.
                c:SetRenderOpacity(0)
                c:SetVisibility(2)   -- hidden: keeps its size, takes no clicks
            else
                c:SetVisibility(1)   -- collapsed: the page's own content is hidden
            end
        end)
    end
    log("page: took over " .. short_class(page) .. ", root " .. short_class(root) .. ", hid " .. table.concat(kids, ", "))
    -- The Credits page leaves on its own in two ways: its scroll timer reaching the end of the credits (OnCreditsEnd),
    -- and holding the mouse down to skip (bHoldingMouse, SkipTimer). Its
    -- scroll speed is set to zero here, and hold_page keeps the hidden list at
    -- the top and the skip flags off while the page is ours.
    pcall(function() page.ScrollingSpeed = 0 end)
    windowRef = nil
    build_window(page, root)
    return true
end

local function hold_page()
    if not (pageMode and ourPage) then return end
    pcall(function()
        ourPage.bHoldingMouse = false
        ourPage.bSkipTimer = false
        -- Even with the timer stopped, the hidden list kept scrolling to its
        -- end after the credits' own length. Held at the top, it never gets there.
        ourPage.ScrollingSpeed = 0
        ourPage.ScrollBox:SetScrollOffset(0)
    end)
end

local function look_for_page()
    if not pageWanted then return end
    local c = container()
    if c then
        for _, layer in ipairs({ "Main", "SubMenu" }) do
            local m = nil
            pcall(function() m = c:GetMenuOnLayer(layer) end)
            if m and m:IsValid() and not seenPages[m:GetAddress()] and short_class(m) ~= "WBP_TitleScreenMenu_Silence_C" then
                pageWanted = nil
                log("page: " .. short_class(m) .. " appeared on layer " .. layer)
                local ok, err = pcall(take_over, m)
                if not ok then
                    -- The page rides the game's own menu, so a game update can
                    -- break it for everyone at once. Then the list still opens,
                    -- over the title menu as it did before it was a page, and
                    -- the player is told why it looks different.
                    log("page: take over failed; opening over the menu instead: " .. tostring(err))
                    pcall(toggle_window)
                    pageMode = false
                    lastNote = "Opened as a window over the menu: this game version wouldn't open it as a menu page."
                    ExecuteWithDelay(500, function()
                        ExecuteInGameThread(function()
                            if titleMenu and titleMenu:IsValid() then pcall(build_window, titleMenu) end
                        end)
                    end)
                end
                return
            end
        end
    end
    if os.clock() - pageWanted > 3 then
        pageWanted = nil
        log("page: no new page within 3 s; opening over the menu instead")
        pageMode = false
        lastNote = "Opened as a window over the menu: this game version wouldn't open it as a menu page."
        if titleMenu and titleMenu:IsValid() then pcall(build_window, titleMenu) end
    end
end

-- The page can be left without us (the game's own Back, or Esc): once it is
-- no longer the page on its layer, forget it.
local function check_page_still_open()
    if not (pageMode and ourPage) then return end
    local still = false
    pcall(function()
        local c = container()
        for _, layer in ipairs({ "Main", "SubMenu" }) do
            local m = c:GetMenuOnLayer(layer)
            if m and m:IsValid() and m:GetAddress() == ourPage:GetAddress() then still = true end
        end
    end)
    if not still then
        log("page: left (by the game's Back or Esc)")
        ourPage, pageMode, windowRef = nil, false, nil
    end
end

local function open_page()
    seenPages = {}
    local c = container()
    if c then
        for _, layer in ipairs({ "Main", "SubMenu" }) do
            pcall(function()
                local m = c:GetMenuOnLayer(layer)
                if m and m:IsValid() then seenPages[m:GetAddress()] = true end
            end)
        end
    end
    local ok, err = pcall(function() titleMenu[CREDITS_CLICK](titleMenu, titleMenu.CreditsTitleScreenButton) end)
    log("page: asked the title menu for its Credits page: " .. (ok and "ok" or ("failed: " .. tostring(err))))
    pageWanted = os.clock()
end

toggle_window = function()
    if pageMode and ourPage then
        -- Back the way the page's own Back does it.
        local ok = pcall(function() ourPage:NavigateBack() end)
        if not ok then
            local c = container()
            pcall(function() c:TransitionBack(ourPage) end)
        end
        log("page: back")
        ourPage, pageMode, windowRef = nil, false, nil
        return
    end
    local w = window_alive()
    if w then
        w:RemoveFromParent()
        windowRef = nil
        log("window: closed")
        return
    end
    if not (titleMenu and titleMenu:IsValid()) then log("window: no title menu") return end
    open_page()
end

-- Rebuilds the list where it is, from what is on disk now (after Apply).
refresh_window = function()
    local w = window_alive()
    if w then w:RemoveFromParent() end
    windowRef = nil
    if lastHost and lastHost:IsValid() and lastCanvas and lastCanvas:IsValid() then
        build_window(lastHost, lastCanvas)
    end
end

-------------------------------------------------------------------------------
-- The quit box, shown after Apply saves something.

local function close_restart_box()
    if modal_open() then pcall(function() modalRef:RemoveFromParent() end) end
    modalRef = nil
    drop_modal_clicks()
end

show_restart_box = function(saved)
    if not (lastHost and lastHost:IsValid() and lastCanvas and lastCanvas:IsValid()) then return end
    close_restart_box()
    local outer = lastHost.WidgetTree
    local box = new_widget("Border", outer)
    pcall(function() box:SetBrushColor({ R = 0.06, G = 0.07, B = 0.09, A = 1.0 }) end)
    pcall(function() box:SetPadding({ Left = 32, Top = 26, Right = 32, Bottom = 24 }) end)
    local col = new_widget("VerticalBox", outer)
    box:SetContent(col)
    pad(col:AddChildToVerticalBox(text(outer, "Quit the Game?", 30, COLORS.white)), 0, 0, 0, 12)
    local body = text(outer, saved == 1 and "1 change saved. It takes effect the next time you start the game."
        or (saved .. " changes saved. They take effect the next time you start the game."), 20, COLORS.dim)
    pcall(function() body:SetAutoWrapText(true) end)
    local bodyBox = new_widget("SizeBox", outer)
    pcall(function() bodyBox:SetWidthOverride(620) end)
    bodyBox:SetContent(body)
    pad(col:AddChildToVerticalBox(bodyBox), 0, 0, 0, 22)
    local btns = new_widget("HorizontalBox", outer)
    local spacer = btns:AddChildToHorizontalBox(text(outer, "", 18, COLORS.dim))
    pcall(function() spacer:SetSize({ SizeRule = 1, Value = 1.0 }) end)
    local restartSlot = btns:AddChildToHorizontalBox(cell(outer, (button(outer, "Quit Game", 20, COLORS.btnOn, function()
        close_restart_box()
        quit_game()
    end, "modal")), 200))
    pad(restartSlot, 0, 0, 14, 0)
    btns:AddChildToHorizontalBox(cell(outer, (button(outer, "Later", 20, COLORS.btn, function() close_restart_box() end, "modal")), 160))
    col:AddChildToVerticalBox(btns)
    local slot = lastCanvas:AddChildToCanvas(box)
    pcall(function()
        slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.5 }, Maximum = { X = 0.5, Y = 0.5 } })
        slot:SetAlignment({ X = 0.5, Y = 0.5 })
        slot:SetAutoSize(true)
        slot:SetPosition({ X = 0, Y = 0 })
        slot:SetZOrder(200)
    end)
    modalRef = box
end

-------------------------------------------------------------------------------
-- Start-up.

log("v" .. VERSION .. " loaded")

-- As soon as the game builds a title menu (its Construct), add the button,
-- so coming back from Settings shows it at once. The one-second check below
-- stays as the fallback. Registered once the title menu class is live.
local constructHooked = false
local function hook_construct()
    if constructHooked or not titleMenu then return end
    constructHooked = true
    local okC, errC = pcall(function()
        RegisterHook(TITLE_CLASS .. ":Construct", function(ctx)
            local m = nil
            pcall(function() m = ctx:get() end)
            if not (m and m:IsValid()) then return end
            ExecuteInGameThread(function()
                if buttonGaveUp then return end
                local okB, errB = pcall(add_title_button, m)
                if not okB then buttonGaveUp = true log("button failed, not retried: " .. tostring(errB)) end
            end)
        end)
    end)
    log("title construct hook " .. (okC and "registered" or ("FAILED: " .. tostring(errC))))
end

-- Every 100 ms, so the first title menu of a session (before the Construct
-- hook can be registered) gets its button within a tenth of a second.
game_loop(100, function()
    hook_construct()
    try_title_button()
    keep_button_size()
    return false
end)

game_loop(20, function()
    look_for_page()
    check_page_still_open()
    hold_page()
    if not window_alive() then close_restart_box() end
    if window_alive() then poll_clicks() end
    return false
end)

-- Esc closes the quit box if it is open; otherwise, on our page, it goes
-- back to the title menu. The page underneath is the game's Credits, which
-- doesn't treat Esc as Back. Checked a tenth of a second later, so a Back the
-- game already did is never done twice (a second Back on the title menu would
-- ask to quit).
if type(RegisterKeyBind) == "function" and Key and Key.ESCAPE then
    RegisterKeyBind(Key.ESCAPE, function()
        ExecuteInGameThread(function()
            if modal_open() then close_restart_box() return end
            if not (pageMode and ourPage) then return end
            local page = ourPage
            ExecuteWithDelay(100, function()
                ExecuteInGameThread(function()
                    check_page_still_open()
                    if pageMode and ourPage and ourPage:GetAddress() == page:GetAddress() then
                        log("esc: back to the title menu")
                        pcall(toggle_window)
                    end
                end)
            end)
        end)
    end)
end
