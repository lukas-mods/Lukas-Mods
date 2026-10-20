--[[
    Steam Achievements v1.0.1 -- by Luka's Mods  (live edits number the VERSION below)

    Adds a "Steam Achievements" app to the in-game tablet and the office
    computer, and a small panel on the right of the HUD:

      - the app lists every Steam achievement for the game with its icon,
        description and progress ("37 / 50"), filtered (All / Tracked /
        In Progress / Locked / Done) and searchable;
      - Track pins up to four achievements to the HUD panel; with nothing
        tracked it suggests the four easiest to get next (closest to done, or
        the one-off most players have);
      - progress moves the moment the game reports it to Steam: the mod hooks
        the game's own ProgressAchievementStat / UnlockAchievement calls.

    Where the numbers come from:
      - starting values: Steam's own files on this PC (appcache\stats\
        UserGameStats_<account>_2404880.bin and the schema beside it), read
        the way the Steam client stores them; re-read every 30 s;
      - the achievement list, English text, icons and global unlock
        percentages are also baked into Scripts\sa_data.lua and
        Assets\icons\ at build time, so the app works when Steam's schema
        can't be found. Nothing is downloaded while you play.

    No game objects are kept between ticks: only their paths are stored, and
    everything is looked up again when it is used.
--]]

local MOD = "SteamAchievements"
local VERSION = "1.0.1"  -- live-edit number: the log names the code that ran
local function log(msg) print("[" .. MOD .. "] " .. tostring(msg) .. "\n") end
-- Crash breadcrumbs: the last one logged before a crash says what the mod
-- was doing. Off by default; trace=1 in settings.txt turns them on.
local traceOn = false
local function crumb(msg) if traceOn then log("> " .. msg) end end

local APP_ID = "2404880"
local MAX_TRACKED = 4
local FILE_CHECK_SECONDS = 30     -- how often Steam's progress file is re-read
-- 25 rows per page, by design: a paged list reads better than one long one.
-- An earlier build assembled every row at once and the game crashed on the
-- first app open. Whether the row count caused it was never proven, so don't
-- raise this without retesting.
local LIST_LIMIT = 25             -- rows per page in the app's list

-------------------------------------------------------------------------------
-- paths

local TABLET_CLASS = "/Game/CarDealerSim/UI/InGame/Tablet/WBP_Tablet.WBP_Tablet_C"
local COMPUTER_CLASS = "/Game/CarDealerSim/UI/InGame/Computer/WBP_DesktopComputer.WBP_DesktopComputer_C"
local ICON_CLASS = "/Game/CarDealerSim/UI/InGame/Computer/WBP_DesktopIconWidget.WBP_DesktopIconWidget_C"
local ICON_CLICK = ICON_CLASS
    .. ":BndEvt__WBP_DesktopIconWidget_Button_112_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"
local FONT = "/Game/CarDealerSim/UI/Fonts/Montserrat/Lato-Medium_Font.Lato-Medium_Font"
local ENUM_LIBRARY = "/Script/Engine.Default__KismetNodeHelperLibrary"
local ACH_ENUM = "/Game/CarDealerSim/DataAssets/E_Achievement.E_Achievement"
local STAT_ENUM = "/Game/CarDealerSim/DataAssets/E_AchievementStats.E_AchievementStats"

-------------------------------------------------------------------------------
-- helpers

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
-- Objects are remembered by path, and resolve() hands back the remembered
-- object instead of searching for it: StaticFindObject on a path that no
-- longer exists makes UE4SS walk every object in the game, and that walk
-- has crashed. A path that has died returns nil without a search, and an
-- unknown path that isn't found is only retried every 10 s.
local known, gone, missing = {}, {}, {}
local function path_of(o)
    local ok, s = pcall(function() return o:GetFullName() end)
    if not ok or not s then return nil end
    s = s:match("^%S+%s+(.+)$") or s
    known[s], gone[s] = o, nil
    return s
end
local MISSING_RETRY_SECONDS = 10
local function resolve(p)
    if not p then return nil end
    local k = known[p]
    if k ~= nil then
        if valid(k) then return k end
        known[p], gone[p] = nil, true
        return nil
    end
    if gone[p] then return nil end
    if missing[p] and os.clock() - missing[p] < MISSING_RETRY_SECONDS then return nil end
    local o = nil
    pcall(function() o = StaticFindObject(p) end)
    if valid(o) then
        known[p], missing[p] = o, nil
        return o
    end
    missing[p] = os.clock()
    return nil
end
local function text_of(v)
    if v == nil then return "" end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and s then return s end
    return tostring(v)
end
local function first_live(className, mustContain)
    local ok, all = pcall(function() return FindAllOf(className) end)
    if not ok or not all then return nil end
    for _, o in ipairs(all) do
        if valid(o) then
            local p = path_of(o) or ""
            if not p:find("Default__", 1, true) and not p:find("_C:WidgetTree.", 1, true)
                and (not mustContain or p:find(mustContain, 1, true)) then
                return o
            end
        end
    end
    return nil
end
-- 12345 -> "12,345"
local function num_text(v)
    local s = tostring(math.floor((v or 0) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end
local function read_all(path, mode)
    local f = io.open(path, mode or "r")
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
-- settings (settings.txt beside this mod)

local src = debug.getinfo(1, "S").source
local MOD_DIR = ((src:sub(1, 1) == "@") and src:sub(2):match("(.*[/\\])") or ".\\") .. "..\\"
local SETTINGS_FILE = MOD_DIR .. "settings.txt"

local settings = {
    widget = true,      -- the HUD panel
    track = {},         -- group keys pinned to the HUD panel, in pick order
    steamPath = nil,    -- Steam's folder, if it can't be found by itself
    filter = "all",
}

local function load_settings()
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if k == "widget" then settings.widget = (v == "1" or v == "true")
        elseif k == "track" then
            settings.track = {}
            for key in v:gmatch("[^,]+") do
                if #settings.track < MAX_TRACKED then settings.track[#settings.track + 1] = key end
            end
        elseif k == "steam_path" and v ~= "" then settings.steamPath = v
        elseif k == "trace" then traceOn = (v == "1" or v == "true")
        end
    end
    f:close()
end

local function save_settings()
    local lines = {
        "# Steam Achievements settings (edited by the app)",
        "widget=" .. (settings.widget and "1" or "0"),
        "track=" .. table.concat(settings.track, ","),
        "trace=" .. (traceOn and "1" or "0"),
        "# steam_path=C:\\Program Files (x86)\\Steam   (only if the app says it can't find your Steam folder)",
    }
    if settings.steamPath then lines[#lines] = "steam_path=" .. settings.steamPath end
    local f = io.open(SETTINGS_FILE, "w")
    if not f then log("could not write settings.txt") return end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
end

load_settings()

-------------------------------------------------------------------------------
-- Steam's binary KeyValues: [type byte][key\0][value]; 0x08 ends a section.

local function parse_kv(b)
    local i = 1
    local function cstr()
        local j = b:find("\0", i, true)
        if not j then error("unterminated string") end
        local s = b:sub(i, j - 1)
        i = j + 1
        return s
    end
    local function section()
        local d = {}
        while i <= #b do
            local t = b:byte(i)
            i = i + 1
            if t == 8 or t == 11 then return d end
            local k = cstr()
            local v
            if t == 0 then v = section()
            elseif t == 1 then v = cstr()
            elseif t == 2 or t == 4 or t == 6 then v = string.unpack("<i4", b, i) i = i + 4
            elseif t == 3 then v = string.unpack("<f", b, i) i = i + 4
            elseif t == 7 then v = string.unpack("<I8", b, i) i = i + 8
            elseif t == 10 then v = string.unpack("<i8", b, i) i = i + 8
            else error("unknown KeyValues type " .. t .. " at " .. (i - 1)) end
            d[k] = v
        end
        return d
    end
    return section()
end

-------------------------------------------------------------------------------
-- Finding Steam's folder (appcache\stats lives there, not in the game's
-- library). In order: settings.txt, Proton's variable, the game's own
-- library (when the game is installed in Steam's folder), the usual places.

local steam = { root = nil, how = nil, tried = false }

local function stats_dir(root) return root:gsub("[\\/]+$", "") .. "\\appcache\\stats\\" end
local function has_stats(root) return root and exists(stats_dir(root) .. "UserGameStatsSchema_" .. APP_ID .. ".bin") end

local function find_steam()
    if steam.tried then return steam.root end
    steam.tried = true
    local cands = {}
    if settings.steamPath then cands[#cands + 1] = { settings.steamPath, "settings.txt" } end
    local proton = os.getenv("STEAM_COMPAT_CLIENT_INSTALL_PATH")
    if proton and proton ~= "" then cands[#cands + 1] = { "Z:" .. proton:gsub("/", "\\"), "Proton" } end
    -- <library>\steamapps\common\<game>\CarDealerSimulator\Binaries\Win64\ue4ss\Mods\<mod>\: nine up
    local lib = MOD_DIR .. string.rep("..\\", 9)
    cands[#cands + 1] = { lib, "game library" }
    for _, d in ipairs({ "C", "D", "E", "F", "G", "H" }) do
        cands[#cands + 1] = { d .. ":\\Program Files (x86)\\Steam", "usual place" }
        cands[#cands + 1] = { d .. ":\\Program Files\\Steam", "usual place" }
        cands[#cands + 1] = { d .. ":\\Steam", "usual place" }
    end
    for _, c in ipairs(cands) do
        if has_stats(c[1]) then
            steam.root, steam.how = c[1], c[2]
            log("Steam folder: " .. c[1] .. " (" .. c[2] .. ")")
            return steam.root
        end
    end
    log("Steam folder not found; set steam_path in settings.txt")
    return nil
end

-- The progress file of the Steam account that signed in most recently, from
-- Steam's config\loginusers.vdf (MostRecent). Its account number is the
-- SteamID64 minus 76561197960265728. Without that file, the only progress
-- file in the folder, if there is just one.
local STEAMID64_BASE = 76561197960265728
local function user_file(root)
    local dir = stats_dir(root)
    local vdf = read_all(root:gsub("[\\/]+$", "") .. "\\config\\loginusers.vdf") or ""
    local ids, recent = {}, nil
    for id, body in vdf:gmatch('"(7656119%d+)"%s*(%b{})') do
        ids[#ids + 1] = id
        if body:find('"MostRecent"%s*"1"') then recent = id end
    end
    local order = {}
    if recent then order[1] = recent end
    for _, id in ipairs(ids) do if id ~= recent then order[#order + 1] = id end end
    for _, id in ipairs(order) do
        local acct = math.tointeger(tonumber(id) - STEAMID64_BASE)
        if acct then
            local f = dir .. "UserGameStats_" .. acct .. "_" .. APP_ID .. ".bin"
            if exists(f) then return f, #ids end
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- The data: achievements, their stats and groups.

local baked = nil
pcall(function() baked = dofile(MOD_DIR .. "Scripts\\sa_data.lua") end)
if not baked then log("Scripts\\sa_data.lua missing: no icons or global percentages") baked = { achievements = {}, pct = {} } end

local data = {
    list = {}, byName = {}, groups = {}, groupByKey = {}, groupsByStat = {},
    stats = {},           -- stat name -> value from Steam's file
    base = {},            -- stat name -> value when this session first read it
    delta = {},           -- stat name -> increments seen this session
    unlockedLive = {},    -- achievement name -> true when unlocked this session
    source = "none", error = nil, fileSig = nil, lastCheck = -1e9,
    unlocked = 0, total = 0,
}

local function current_value(stat)
    local file = data.stats[stat] or 0
    local live = (data.base[stat] or file) + (data.delta[stat] or 0)
    return math.max(file, live)
end

local function is_unlocked(a)
    if a.fileUnlocked or data.unlockedLive[a.name] then return true end
    if a.stat ~= "" and a.max and current_value(a.stat) >= a.max then return true end
    return false
end

-- "Bubble Bath II" -> "Bubble Bath"
local function strip_tier(t) return (t:gsub("%s+I[IV]*$", "")) end

-- Group fields (focus tier, progress, ...) from the current values.
local function update_group(g)
    local nextT, done = nil, 0
    for _, a in ipairs(g.tiers) do
        a.unlocked = is_unlocked(a)
        if a.unlocked then done = done + 1 elseif not nextT then nextT = a end
    end
    g.tiersDone = done
    g.complete = (nextT == nil)
    g.focus = nextT or g.tiers[#g.tiers]
    g.hasProgress = (g.focus.stat ~= "" and g.focus.max ~= nil)
    if g.hasProgress then
        g.cur = math.min(current_value(g.focus.stat), g.focus.max)
        g.target = g.focus.max
        g.pct = g.complete and 1 or (g.target > 0 and math.min(1, g.cur / g.target) or 0)
    else
        g.cur, g.target, g.pct = nil, nil, g.complete and 1 or 0
    end
    g.title = #g.tiers > 1 and strip_tier(g.focus.title) or g.focus.title
    g.globalPct = baked.pct[g.focus.name] or 0
    -- Easiest first: a counter by how far along it is, a one-off by how many
    -- players have it (both 0-100).
    g.ease = g.hasProgress and g.pct * 100 or g.globalPct
end

local function rebuild_groups()
    data.groups, data.groupByKey, data.groupsByStat = {}, {}, {}
    local byStat = {}
    for _, a in ipairs(data.list) do
        local key = (a.stat ~= "" and a.max) and ("stat:" .. a.stat) or ("ach:" .. a.name)
        local g = data.groupByKey[key]
        if not g then
            g = { key = key, tiers = {}, stat = a.stat ~= "" and a.stat or nil }
            data.groupByKey[key] = g
            data.groups[#data.groups + 1] = g
            if g.stat then byStat[g.stat] = g end
        end
        g.tiers[#g.tiers + 1] = a
    end
    for _, g in ipairs(data.groups) do
        table.sort(g.tiers, function(x, y) return (x.max or 0) < (y.max or 0) end)
        update_group(g)
    end
    data.groupsByStat = byStat
end

local function refresh_counts()
    local n = 0
    for _, a in ipairs(data.list) do if is_unlocked(a) then n = n + 1 end end
    data.unlocked, data.total = n, #data.list
end

-- Load the list (the player's schema if found, else the baked one) and the
-- player's progress file.
local function load_data()
    local root = find_steam()
    local schema = nil
    if root then
        local raw = read_all(stats_dir(root) .. "UserGameStatsSchema_" .. APP_ID .. ".bin", "rb")
        if raw then
            local ok, d = pcall(parse_kv, raw)
            if ok and d[APP_ID] and d[APP_ID].stats then schema = d[APP_ID].stats else log("Steam schema unreadable: " .. tostring(d)) end
        end
    end
    local list, statIds = {}, {}
    if schema then
        for sid, s in pairs(schema) do
            if s.bits then
                for bit, a in pairs(s.bits) do
                    local d = a.display or {}
                    local p = a.progress or {}
                    list[#list + 1] = {
                        name = a.name, title = (d.name and d.name.english) or a.name,
                        desc = (d.desc and d.desc.english) or "", hidden = tonumber(d.hidden) == 1,
                        icon = d.icon or "", gray = d.icon_gray or "",
                        stat = (p.value and p.value.operand1) or "", max = tonumber(p.max_val),
                        sid = tonumber(sid), bit = tonumber(bit),
                    }
                end
            elseif s.name then
                statIds[sid] = s.name
            end
        end
        data.source = "Steam"
    else
        for _, a in ipairs(baked.achievements) do
            list[#list + 1] = { name = a.name, title = a.title, desc = a.desc, hidden = a.hidden == 1, icon = a.icon,
                gray = a.gray, stat = a.stat, max = a.max, sid = a.sid, bit = a.bit }
        end
        for sid, name in pairs(baked.stats or {}) do statIds[sid] = name end
        data.source = "built in"
    end
    table.sort(list, function(x, y) if x.sid ~= y.sid then return x.sid < y.sid end return x.bit < y.bit end)
    data.list, data.byName = list, {}
    for _, a in ipairs(list) do data.byName[a.name] = a end
    data.statIds = statIds
    data.error = nil
    if not root then data.error = "Steam folder not found, so progress from before this session isn't shown. Set steam_path in settings.txt (in this mod's folder)." end
    rebuild_groups()
end

-- Steam's progress file: unlock bits and stat values. Called at start and
-- every FILE_CHECK_SECONDS; only re-parsed when its contents change.
local function read_progress()
    data.lastCheck = os.clock()
    local root = find_steam()
    if not root then return end
    local path, accounts = user_file(root)
    if not path then
        data.notice = "Steam hasn't saved progress for this game yet. Play signed into Steam and it will."
        return
    end
    local raw = read_all(path, "rb")
    if not raw then return end
    local sig = #raw .. ":" .. raw:sub(-64)
    if sig == data.fileSig then return end
    local ok, d = pcall(parse_kv, raw)
    if not ok then log("progress file unreadable: " .. tostring(d)) return end
    data.fileSig = sig
    local cache = d.cache or {}
    for sid, name in pairs(data.statIds or {}) do
        local e = cache[sid]
        local v = (type(e) == "table" and tonumber(e.data)) or 0
        data.stats[name] = v
        if data.base[name] == nil then data.base[name] = v end
    end
    -- Without the player's schema (baked list), stat ids come from the bake.
    for _, a in ipairs(data.list) do
        local e = cache[tostring(a.sid)]
        local mask = (type(e) == "table" and tonumber(e.data)) or 0
        a.fileUnlocked = ((mask & 0xFFFFFFFF) >> a.bit) & 1 == 1
    end
    for _, g in ipairs(data.groups) do update_group(g) end
    refresh_counts()
    data.error, data.notice = nil, nil
    log(string.format("progress file read (%s%s): %d / %d unlocked", path:match("[^\\]+$"),
        (accounts or 1) > 1 and (", " .. accounts .. " accounts") or "", data.unlocked, data.total))
end

-------------------------------------------------------------------------------
-- Live progress: the game's own calls to Steam.

local enumNames = {}   -- enum path -> { value -> display name }
local function enum_name(enumPath, value)
    local m = enumNames[enumPath]
    if not m then
        m = {}
        local lib, en = resolve(ENUM_LIBRARY), resolve(enumPath)
        if lib and en then
            for v = 0, 255 do
                local ok, s = pcall(function() return lib:GetEnumeratorUserFriendlyName(en, v) end)
                local n = ok and text_of(s) or ""
                if n == "" or n == "E_MAX" then break end
                m[v] = n
            end
        end
        if next(m) then enumNames[enumPath] = m end
    end
    return m[value]
end

local dirty = true      -- something changed: refresh the HUD and the app
local function on_stat_progress(stat, amount)
    if not stat or not amount or amount == 0 then return end
    data.delta[stat] = (data.delta[stat] or 0) + amount
    local g = data.groupsByStat[stat]
    if g then update_group(g) end
    refresh_counts()
    dirty = true
end

local function on_unlock(name)
    if not name or data.unlockedLive[name] then return end
    local a = data.byName[name]
    data.unlockedLive[name] = true
    if a and not a.fileUnlocked then
        log("achievement unlocked: " .. name)
        for _, g in ipairs(data.groups) do
            for _, t in ipairs(g.tiers) do if t == a then update_group(g) end end
        end
        refresh_counts()
        dirty = true
    end
end

-------------------------------------------------------------------------------
-- Which groups the HUD shows, and as what: the tracked ones only (in pick
-- order), or, with nothing tracked, the four easiest unfinished ones as
-- suggestions. Hidden achievements are never suggested.
local function hud_groups()
    local out = {}
    for _, key in ipairs(settings.track) do
        local g = data.groupByKey[key]
        if g and not g.complete and #out < MAX_TRACKED then out[#out + 1] = g end
    end
    if #out > 0 then return out, "tracked" end
    local pool = {}
    for _, g in ipairs(data.groups) do
        if not g.complete and not g.focus.hidden then pool[#pool + 1] = g end
    end
    table.sort(pool, function(x, y)
        if x.ease ~= y.ease then return x.ease > y.ease end
        return x.title < y.title
    end)
    for _, g in ipairs(pool) do
        if #out >= MAX_TRACKED then break end
        out[#out + 1] = g
    end
    return out, "suggested"
end

local function is_tracked(key)
    for _, k in ipairs(settings.track) do if k == key then return true end end
    return false
end

-- A tracked achievement that is done gives up its slot.
local function drop_completed_tracks()
    local keep, changed = {}, false
    for _, key in ipairs(settings.track) do
        local g = data.groupByKey[key]
        if g and g.complete then changed = true else keep[#keep + 1] = key end
    end
    if changed then settings.track = keep save_settings() end
end

-------------------------------------------------------------------------------
-- UI: colours and widget helpers (the same building blocks as Parts Manager).

local COLORS = {
    header = { R = 0.10, G = 0.04, B = 0.22, A = 1.0 },
    body = { R = 0.03, G = 0.03, B = 0.03, A = 1.0 },
    card = { R = 0.06, G = 0.065, B = 0.075, A = 1.0 },
    row = { R = 0.06, G = 0.06, B = 0.06, A = 1.0 },
    rowAlt = { R = 0.045, G = 0.045, B = 0.045, A = 1.0 },
    white = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 },
    text = { R = 0.92, G = 0.92, B = 0.92, A = 1.0 },
    dim = { R = 0.55, G = 0.57, B = 0.60, A = 1.0 },
    section = { R = 0.62, G = 0.45, B = 1.0, A = 1.0 },
    gold = { R = 1.0, G = 0.68, B = 0.03, A = 1.0 },
    good = { R = 0.25, G = 0.80, B = 0.25, A = 1.0 },
    bad = { R = 1.0, G = 0.30, B = 0.22, A = 1.0 },
    btn = { R = 0.22, G = 0.08, B = 0.55, A = 1.0 },
    btnOff = { R = 0.16, G = 0.16, B = 0.17, A = 1.0 },
    btnDark = { R = 0.05, G = 0.02, B = 0.12, A = 1.0 },
    barBack = { R = 0.12, G = 0.12, B = 0.13, A = 1.0 },
    barFill = { R = 0.45, G = 0.25, B = 0.95, A = 1.0 },
    hudBack = { R = 0.0, G = 0.0, B = 0.0, A = 0.55 },
    dotDone = { R = 0.25, G = 0.80, B = 0.25, A = 1.0 },
    dotNow = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 },
    dotTodo = { R = 0.30, G = 0.30, B = 0.32, A = 1.0 },
}

local function umg(kind) return resolve("/Script/UMG." .. kind) end
local widgetCounter = 0
local function new_widget(kind, outer)
    local c = umg(kind)
    if not c then error("UMG class missing: " .. kind) end
    -- Unique names: rows are rebuilt, and a reused name in the same outer
    -- would replace an existing widget.
    widgetCounter = widgetCounter + 1
    local name = string.format("SA_%s_%d_%d", kind, os.time() % 100000, widgetCounter)
    local w = StaticConstructObject(c, outer, FName(name))
    if not valid(w) then error("could not create " .. kind) end
    return w
end
local function set_color(dst, c) dst.R, dst.G, dst.B, dst.A = c.R, c.G, c.B, c.A end
local function set_text(tb, s, color)
    if not tb then return end
    pcall(function() tb:SetText(FText(s)) end)
    if color then pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end) end
end
local function make_text(outer, s, size, color)
    local t = new_widget("TextBlock", outer)
    local font = resolve(FONT)
    if font then
        pcall(function() t:SetFont({ FontObject = font, TypefaceFontName = FName("Default"), Size = size, LetterSpacing = 0, SkewAmount = 0.0 }) end)
    end
    set_text(t, s, color or COLORS.text)
    return t
end
local function pad(slot, l, t, r, b) pcall(function() slot:SetPadding({ Left = l, Top = t, Right = r, Bottom = b }) end) end
local function fill(slot, weight) pcall(function() slot:SetSize({ SizeRule = 1, Value = weight or 1.0 }) end) end
local function valign(slot, v) pcall(function() slot:SetVerticalAlignment(v) end) end   -- 1 top, 2 center
local function halign(slot, v) pcall(function() slot:SetHorizontalAlignment(v) end) end -- 1 left, 2 center, 3 right
local function make_border(outer, color, l, t, r, b)
    local bd = new_widget("Border", outer)
    pcall(function() bd:SetBrushColor(color) end)
    pcall(function() bd:SetPadding({ Left = l or 0, Top = t or 0, Right = r or 0, Bottom = b or 0 }) end)
    return bd
end
local function sized(outer, w, h, content)
    local box = new_widget("SizeBox", outer)
    if w then pcall(function() box:SetWidthOverride(w) end) end
    if h then pcall(function() box:SetHeightOverride(h) end) end
    if content then box:SetContent(content) end
    return box
end

-- Achievement icons: Assets\icons\<hash>.jpg, loaded with the engine's
-- ImportFileAsTexture2D. Textures are remembered by path and reused while
-- they are alive.
local textures = {}
local iconsLogged = {}
local function texture(ctx, hash)
    if not hash or hash == "" then return nil end
    local t = resolve(textures[hash])
    if t then return t end
    local file = MOD_DIR .. "Assets\\icons\\" .. hash
    local lib = resolve("/Script/Engine.Default__KismetRenderingLibrary")
    local tex = nil
    local ok = lib and pcall(function() tex = lib:ImportFileAsTexture2D(ctx, file) end)
    if not ok or not valid(tex) then
        if not iconsLogged[hash] then log("icon not loaded: " .. hash) iconsLogged[hash] = true end
        return nil
    end
    textures[hash] = path_of(tex)
    return tex
end
local function make_image(ctx, outer, hash, size)
    local img = new_widget("Image", outer)
    local tex = texture(ctx, hash)
    if tex then pcall(function() img:SetBrushFromTexture(tex, false) end) end
    pcall(function() img:SetVisibility(3) end)   -- never takes the mouse
    return sized(outer, size, size, img), img
end
local function set_image(ctx, img, hash)
    local tex = texture(ctx, hash)
    if img and tex then pcall(function() img:SetBrushFromTexture(tex, false) end) end
end
-- Always the achievement's own (unlocked) art: Steam's locked art is the
-- same grey padlock for most achievements, which says nothing.
-- A hidden achievement's art would give it away, so it keeps Steam's locked
-- art until it is unlocked.
local function group_icon(g)
    if g.focus.hidden and not g.complete and g.focus.gray ~= "" then return g.focus.gray end
    return g.focus.icon ~= "" and g.focus.icon or g.focus.gray
end

local function make_bar(outer, w, h)
    local pb = new_widget("ProgressBar", outer)
    pcall(function() pb:SetFillColorAndOpacity(COLORS.barFill) end)
    pcall(function()
        pb.WidgetStyle.BackgroundImage.TintColor.SpecifiedColor = COLORS.barBack
    end)
    return sized(outer, w, h, pb), pb
end
local function set_bar(pb, pct, color)
    if not pb then return end
    pcall(function() pb:SetPercent(pct or 0) end)
    if color then pcall(function() pb:SetFillColorAndOpacity(color) end) end
end

-- Tier dots: one small square per tier (done green, current white and a
-- little larger, to-do grey). Returns the box and the dot paths.
local function make_dots(outer, n, size)
    local row = new_widget("HorizontalBox", outer)
    local dots = {}
    for i = 1, n do
        local bd = make_border(outer, COLORS.dotTodo)
        local sz = sized(outer, size, size, bd)
        local sl = row:AddChildToHorizontalBox(sz)
        pad(sl, 0, 0, 4, 0)
        valign(sl, 2)
        dots[i] = { b = path_of(bd), s = path_of(sz) }
    end
    return row, dots
end
local function set_dots(dots, g, size)
    for i, d in ipairs(dots or {}) do
        local a = g.tiers[i]
        local color = COLORS.dotTodo
        local s = size
        if a and a.unlocked then color = COLORS.dotDone
        elseif a == g.focus then color, s = COLORS.dotNow, size + 4 end
        local bd, sz = resolve(d.b), resolve(d.s)
        if bd then pcall(function() bd:SetBrushColor(color) end) end
        if sz then pcall(function() sz:SetWidthOverride(s) sz:SetHeightOverride(s) end) end
    end
end

local function progress_text(g)
    if g.complete then return "Done" end
    if g.hasProgress then return num_text(g.cur) .. " / " .. num_text(g.target) end
    return "Locked"
end

-------------------------------------------------------------------------------
-- Buttons: the game's clickable icon widget (no glyph, no caption) with our
-- own text centred on top of it, as in Parts Manager.

local hosts = {}     -- tablet / computer widget path -> app state
local buttons = {}   -- button full name -> { host, action }

local function finish_button(b)
    pcall(function() b:UpdateVisual() end)
    pcall(function() b:SetInteractable(true) end)
end

local function make_button(host, hostPath, outer, label, w, h, action, size, color)
    local lib, cls = resolve(WIDGET_LIBRARY), resolve(ICON_CLASS)
    local b = lib:Create(host, cls, host:GetOwningPlayer())
    if not valid(b) then error("could not create button") end
    b.ButtonSize.X = w
    b.ButtonSize.Y = h
    b.Icon = FText("")
    b.IconSize = 0
    b.Text = FText("")
    b.FontSize = 0
    b.Roundness = 6
    b.OutlineWidth = 0
    b.IconTextSpace = 0
    b.HoveredAnimation = false
    set_color(b.BackgroundColor, color or COLORS.btn)
    b.IsInteractableAtStart = true
    buttons[b:GetFullName()] = { host = hostPath, action = action }
    local ov = new_widget("Overlay", outer)
    ov:AddChildToOverlay(b)
    local t = make_text(outer, label, size or 20, COLORS.white)
    pcall(function() t:SetVisibility(3) end)   -- HitTestInvisible: clicks reach the button
    local ts = ov:AddChildToOverlay(t)
    halign(ts, 2)
    valign(ts, 2)
    finish_button(b)
    return ov, { b = path_of(b), l = path_of(t) }
end

local function style_button(rec, label, color)
    if not rec then return end
    if label then set_text(resolve(rec.l), label) end
    if color then
        local b = resolve(rec.b)
        if b then pcall(function() set_color(b.BackgroundColor, color) b:UpdateVisual() end) end
    end
end

local LOGO_FILE = MOD_DIR .. "Assets\\logo.png"
local HELP_FILE = MOD_DIR .. "Assets\\help.png"   -- the outlined blue "?" from Parts Manager
local logoLogged = false
local function make_logo(ctx, outer, height, file)
    file = file or LOGO_FILE
    local lib = resolve("/Script/Engine.Default__KismetRenderingLibrary")
    local tex = nil
    local ok = lib and pcall(function() tex = lib:ImportFileAsTexture2D(ctx, file) end)
    if not ok or not valid(tex) then
        if not logoLogged then log("picture not loaded: " .. file) logoLogged = true end
        return nil
    end
    local img = new_widget("Image", outer)
    pcall(function() img:SetBrushFromTexture(tex, false) end)
    pcall(function() img:SetVisibility(3) end)
    return sized(outer, height, height, img)
end

-------------------------------------------------------------------------------
-- The app: header, a controls card (filters, search, HUD switch), the list.

local status = { text = "", good = true }
local function set_status(text, good) status.text, status.good = text, good ~= false end

-- In Progress is everything not yet finished: a player of the game is in
-- progress on all of them (a separate Locked list was almost the same list).
local FILTERS = { { "all", "All" }, { "tracked", "Tracked" }, { "progress", "In Progress" }, { "done", "Done" } }

local function add_hbutton(h, host, box, name, label, w, action, color, size)
    local ov, rec = make_button(host, h.hostPath, box:GetOuter(), label, w, 44, action, size, color)
    local slot = box:AddChildToHorizontalBox(ov)
    pad(slot, 0, 0, 10, 0)
    valign(slot, 2)
    h.b[name] = rec
    return rec
end

local function build_panel(h, host, hostPath)
    local tree = host.WidgetTree
    local switcher = host.ApplicationWidgetSwitcher
    if not valid(tree) or not valid(switcher) then error("host has no app switcher") end
    h.w, h.b = {}, {}

    local root = make_border(tree, COLORS.body, 0, 0, 0, 0)
    local main = new_widget("VerticalBox", tree)
    root:SetContent(main)

    local header = make_border(tree, COLORS.header, 40, 14, 30, 14)
    local top = new_widget("HorizontalBox", tree)
    header:SetContent(top)
    local logo = make_logo(host, tree, 80)
    if logo then
        local ls = top:AddChildToHorizontalBox(logo)
        pad(ls, 0, 0, 16, 0)
        valign(ls, 2)
    end
    local titleBox = new_widget("VerticalBox", tree)
    titleBox:AddChildToVerticalBox(make_text(tree, "STEAM ACHIEVEMENTS", 36, COLORS.white))
    pad(titleBox:AddChildToVerticalBox(make_text(tree, "v" .. VERSION .. "  by Luka's Mods", 18, { R = 0.75, G = 0.65, B = 1.0, A = 1.0 })), 2, 0, 0, 0)
    local tslot = top:AddChildToHorizontalBox(titleBox)
    fill(tslot, 1)
    valign(tslot, 2)
    add_hbutton(h, host, top, "bug", "Report a Bug", 210, "bugreport", COLORS.btnDark, 20)
    add_hbutton(h, host, top, "feature", "Request a Feature", 250, "feature", COLORS.btnDark, 20)
    add_hbutton(h, host, top, "close", "X", 64, "close", COLORS.btnDark, 30)
    main:AddChildToVerticalBox(header)

    local bodyPad = make_border(tree, COLORS.body, 30, 10, 30, 10)
    local body = new_widget("VerticalBox", tree)
    bodyPad:SetContent(body)
    fill(main:AddChildToVerticalBox(bodyPad), 1)

    -- controls card
    local cc = make_border(tree, COLORS.card, 22, 10, 22, 10)
    local col = new_widget("VerticalBox", tree)
    cc:SetContent(col)
    pad(body:AddChildToVerticalBox(cc), 0, 0, 0, 6)

    local r1 = new_widget("HorizontalBox", tree)
    local summary = make_text(tree, "", 24, COLORS.white)
    h.w.summary = path_of(summary)
    local ss = r1:AddChildToHorizontalBox(summary)
    fill(ss, 1)
    valign(ss, 2)
    add_hbutton(h, host, r1, "prev", "< Prev", 120, "page:-1", COLORS.btnOff, 20)
    add_hbutton(h, host, r1, "next", "Next >", 120, "page:1", COLORS.btnOff, 20)
    add_hbutton(h, host, r1, "widget", "HUD Panel: ON", 260, "widget", COLORS.btnOff, 20)
    pad(col:AddChildToVerticalBox(r1), 0, 0, 0, 8)

    local r2 = new_widget("HorizontalBox", tree)
    for _, f in ipairs(FILTERS) do
        add_hbutton(h, host, r2, "f_" .. f[1], f[2], f[1] == "progress" and 190 or 140, "filter:" .. f[1], COLORS.btnOff, 20)
    end
    -- the search box
    local search = new_widget("EditableTextBox", tree)
    pcall(function() search:SetHintText(FText("Search achievements...")) end)
    -- The default text colour is a pale grey that barely shows on the white box.
    pcall(function() search:SetForegroundColor({ R = 0.02, G = 0.02, B = 0.02, A = 1.0 }) end)
    local sbox = sized(tree, 420, 44, search)
    local sl = r2:AddChildToHorizontalBox(sbox)
    pad(sl, 12, 0, 0, 0)
    valign(sl, 2)
    h.w.search = path_of(search)
    col:AddChildToVerticalBox(r2)

    local st = make_text(tree, "", 18, COLORS.good)
    pcall(function() st:SetAutoWrapText(true) end)
    h.w.status = path_of(st)
    pad(col:AddChildToVerticalBox(st), 0, 8, 0, 0)

    -- the list
    local lc = make_border(tree, COLORS.card, 12, 8, 12, 8)
    local list = new_widget("ScrollBox", tree)
    lc:SetContent(list)
    fill(body:AddChildToVerticalBox(lc), 1)
    h.w.list = path_of(list)

    switcher:AddChild(root)
    h.panelPath = path_of(root)
    h.listKey = nil
    h.searchText = ""
    h.pageIdx = 0
    log("app screen built on " .. h.kind)
end

local function panel_visible(h)
    local host = resolve(h.hostPath)
    local panel = resolve(h.panelPath)
    if not host or not panel then return false end
    local ok, active = pcall(function() return host.ApplicationWidgetSwitcher:GetActiveWidget() end)
    return ok and valid(active) and path_of(active) == h.panelPath
end

local function filtered_groups(filter, search)
    local s = (search or ""):lower()
    local out = {}
    for _, g in ipairs(data.groups) do
        local ok = true
        if filter == "tracked" then ok = is_tracked(g.key)
        elseif filter == "progress" then ok = not g.complete
        elseif filter == "done" then ok = g.complete end
        if ok and s ~= "" then
            local hay = (g.title .. " " .. g.focus.desc):lower()
            for _, t in ipairs(g.tiers) do hay = hay .. " " .. t.title:lower() end
            ok = hay:find(s, 1, true) ~= nil
        end
        -- A hidden achievement's text stays hidden until it is unlocked.
        if ok and g.focus.hidden and not g.complete and s ~= "" then ok = false end
        if ok then out[#out + 1] = g end
    end
    table.sort(out, function(x, y)
        if x.complete ~= y.complete then return not x.complete end
        if x.ease ~= y.ease then return x.ease > y.ease end
        return x.title < y.title
    end)
    return out
end

-- (Re)build the list rows for the current filter and search.
local function rebuild_rows(h)
    local list = resolve(h.w.list)
    local host = resolve(h.hostPath)
    if not list or not host then return end
    pcall(function() list:ClearChildren() end)
    for name, b in pairs(buttons) do
        if b.host == h.hostPath and b.action:match("^track:") then buttons[name] = nil end
    end
    h.rows = {}
    local outer = list:GetOuter()
    local groups = filtered_groups(settings.filter, h.searchText)
    local pages = math.max(1, math.ceil(#groups / LIST_LIMIT))
    h.pageIdx = math.max(0, math.min(pages - 1, h.pageIdx or 0))
    local first = h.pageIdx * LIST_LIMIT
    crumb("rows: page " .. (h.pageIdx + 1) .. "/" .. pages)
    for i = 1, math.min(LIST_LIMIT, #groups - first) do
        local g = groups[first + i]
        crumb("row " .. i .. " " .. g.key .. " icon " .. tostring(group_icon(g)))
        local bg = make_border(outer, (i % 2 == 1) and COLORS.row or COLORS.rowAlt, 14, 8, 10, 8)
        local row = new_widget("HorizontalBox", outer)
        bg:SetContent(row)
        -- icon, with the tier dots under it
        local left = new_widget("VerticalBox", outer)
        local iconBox, img = make_image(host, outer, group_icon(g), 64)
        left:AddChildToVerticalBox(iconBox)
        crumb("row " .. i .. " icon done")
        local dots = nil
        if #g.tiers > 1 then
            local drow
            drow, dots = make_dots(outer, #g.tiers, 10)
            local ds = left:AddChildToVerticalBox(drow)
            pad(ds, 0, 6, 0, 0)
            halign(ds, 2)
        end
        local lsl = row:AddChildToHorizontalBox(left)
        pad(lsl, 0, 0, 16, 0)
        valign(lsl, 1)
        -- title, description, bar + count
        local mid = new_widget("VerticalBox", outer)
        local tt = make_text(outer, "", 22, COLORS.white)
        mid:AddChildToVerticalBox(tt)
        local dd = make_text(outer, "", 17, COLORS.dim)
        pcall(function() dd:SetAutoWrapText(true) end)
        pad(mid:AddChildToVerticalBox(dd), 0, 2, 0, 6)
        local br = new_widget("HorizontalBox", outer)
        local barBox, pb = make_bar(outer, 520, 12)
        crumb("row " .. i .. " bar done")
        local bs = br:AddChildToHorizontalBox(barBox)
        valign(bs, 2)
        local ct = make_text(outer, "", 18, COLORS.gold)
        local cs = br:AddChildToHorizontalBox(ct)
        pad(cs, 14, 0, 0, 0)
        valign(cs, 2)
        mid:AddChildToVerticalBox(br)
        local ms = row:AddChildToHorizontalBox(mid)
        fill(ms, 1)
        valign(ms, 2)
        -- Track
        local ov, rec = make_button(host, h.hostPath, outer, "Track", 150, 44, "track:" .. g.key, 20, COLORS.btnOff)
        crumb("row " .. i .. " button done")
        local ts = row:AddChildToHorizontalBox(ov)
        pad(ts, 10, 0, 0, 0)
        valign(ts, 2)
        local rs = list:AddChild(bg)
        pad(rs, 0, 0, 0, 2)
        h.rows[#h.rows + 1] = { key = g.key, img = path_of(img), title = path_of(tt), desc = path_of(dd),
            bar = path_of(pb), count = path_of(ct), dots = dots, track = rec, trackBox = path_of(ov), barBox = path_of(barBox) }
    end
    pcall(function() list:ScrollToStart() end)
    crumb("rows built")
    h.first, h.shown, h.matched, h.pages = first, #h.rows, #groups, pages
    h.listKey = settings.filter .. "|" .. (h.searchText or "") .. "|" .. h.pageIdx
end

local function refresh_row(h, host, r)
    local g = data.groupByKey[r.key]
    if not g then return end
    local hidden = g.focus.hidden and not g.complete
    set_text(resolve(r.title), hidden and "Hidden achievement" or g.title, g.complete and COLORS.good or COLORS.white)
    set_text(resolve(r.desc), hidden and "Details appear when it's unlocked." or g.focus.desc)
    set_image(host, resolve(r.img), group_icon(g))
    local bb = resolve(r.barBox)
    if bb then pcall(function() bb:SetVisibility((g.hasProgress or g.complete) and 0 or 1) end) end
    set_bar(resolve(r.bar), g.pct, g.complete and COLORS.good or COLORS.barFill)
    local extra = ""
    -- In the app every unfinished row says how many players have its current tier
    -- (the HUD keeps it to one-offs, to stay narrow).
    if not g.complete then extra = string.format(" (%.1f%% have it)", g.globalPct) end
    set_text(resolve(r.count), progress_text(g) .. extra, g.complete and COLORS.good or COLORS.gold)
    set_dots(r.dots, g, 10)
    local tracked = is_tracked(g.key)
    -- A finished achievement can't be tracked: no button (Hidden keeps the row's layout).
    local tb = resolve(r.trackBox)
    if tb then pcall(function() tb:SetVisibility(g.complete and 2 or 0) end) end
    -- The button says what a click does; purple marks the tracked ones.
    style_button(r.track, tracked and "Untrack" or "Track", tracked and COLORS.btn or COLORS.btnOff)
end

local function refresh_panel(h, rowsToo)
    local host = resolve(h.hostPath)
    if not host or not resolve(h.panelPath) then return end
    local search = resolve(h.w.search)
    if search then
        local okT, t = pcall(function() return search:GetText():ToString() end)
        if okT and t then h.searchText = t end
    end
    -- A new filter or search starts again on page 1.
    local fs = settings.filter .. "|" .. (h.searchText or "")
    if h.lastFS ~= fs then h.lastFS, h.pageIdx = fs, 0 end
    if h.listKey ~= fs .. "|" .. (h.pageIdx or 0) or h.rowsDirty then
        h.rowsDirty = false
        rebuild_rows(h)
        rowsToo = true
    end
    local sum = string.format("%d / %d unlocked", data.unlocked, data.total)
    if (h.pages or 1) > 1 then
        sum = sum .. string.format("   Page %d of %d", (h.pageIdx or 0) + 1, h.pages)
    end
    for _, k in ipairs({ "prev", "next" }) do
        local rec = h.b[k]
        local b = rec and resolve(rec.b)
        local on = (h.pages or 1) > 1
        local ov = b and b:GetParent()
        if ov then pcall(function() ov:SetVisibility(on and 0 or 2) end) end
    end
    set_text(resolve(h.w.summary), sum)
    style_button(h.b.widget, settings.widget and "HUD Panel: ON" or "HUD Panel: OFF", settings.widget and COLORS.btn or COLORS.btnOff)
    for _, f in ipairs(FILTERS) do
        style_button(h.b["f_" .. f[1]], nil, settings.filter == f[1] and COLORS.btn or COLORS.btnOff)
    end
    -- A click's message first; then a problem (red); then a plain notice (green).
    local st, good = status.text, status.good
    if st == "" and data.error then st, good = data.error, false end
    if st == "" and data.notice then st, good = data.notice, true end
    set_text(resolve(h.w.status), st or "", good and COLORS.good or COLORS.bad)
    if rowsToo then
        crumb("refresh rows")
        for _, r in ipairs(h.rows or {}) do refresh_row(h, host, r) end
        crumb("rows refreshed")
    end
end

local function open_panel(hostPath)
    local h = hosts[hostPath]
    local host = resolve(hostPath)
    if not h or not host then return end
    if not resolve(h.panelPath) then build_panel(h, host, hostPath) end
    local panel = resolve(h.panelPath)
    if not panel then return end
    if os.clock() - data.lastCheck > 5 then read_progress() end
    status.text = ""
    h.rowsDirty = true
    crumb("open: refresh")
    refresh_panel(h, true)
    crumb("open: show the page")
    local switcher = host.ApplicationWidgetSwitcher
    local ok = pcall(function() switcher:SetActiveWidget(panel) end)
    if not ok then pcall(function() switcher:SetActiveWidgetIndex(switcher:GetChildIndex(panel)) end) end
    crumb("open: done")
end

local function close_panel(hostPath)
    local host = resolve(hostPath)
    if host then pcall(function() host:ReturnToDesktop() end) end
end

-------------------------------------------------------------------------------
-- Report a Bug / Request a Feature: saves a report file, opens the public
-- repo's issue form pre-filled and the report's folder, so the player can
-- drag the file in and press Submit. The mod never posts anything itself.

-- lukasmods.com/bug and /request redirect to the public repo's issue forms.
-- They replace their own query with ours, so template= is always sent.
local ISSUES = {
    urls = { ["bug_report.yml"] = "https://lukasmods.com/bug", ["feature_request.yml"] = "https://lukasmods.com/request" },
    name = "CDS - Steam Achievements",
}
local UE4SS_LOG = MOD_DIR .. "..\\..\\UE4SS.log"

local function url_encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function issue_url(template)
    local q = { "template=" .. template, "title=" .. url_encode("[" .. ISSUES.name .. "] "),
        "mod=" .. url_encode(ISSUES.name), "version=" .. url_encode(VERSION) }
    return ISSUES.urls[template] .. "?" .. table.concat(q, "&")
end
local function open_external(target, select)
    if select then os.execute('start "" explorer.exe /select,"' .. target .. '"')
    else os.execute('start "" "' .. target .. '"') end
end
-- Remove the Windows user name and Steam account ids from anything in the
-- report. Belt and braces: the user name by value (when Windows says what it
-- is) AND any folder under Users\; a SteamID64 wherever it appears; the
-- account number in Steam's file names and userdata\ folders.
local USERNAME = os.getenv("USERNAME")
local function scrub(s)
    s = tostring(s or "")
    if USERNAME and #USERNAME > 1 then
        for _, u in ipairs({ USERNAME, USERNAME:lower() }) do
            local pattern = u:gsub("%p", "%%%0")
            s = s:gsub(pattern, "<user>")
        end
    end
    s = s:gsub("([Uu][Ss][Ee][Rr][Ss][\\/])[^\\/\r\n\"]+", "%1<user>")
    s = s:gsub("7656119%d%d%d%d%d%d%d%d%d%d", "<steamid>")
    s = s:gsub("UserGameStats_%d+_", "UserGameStats_<account>_")
    s = s:gsub("([Uu]serdata[\\/])%d+", "%1<account>")
    return s
end

local function write_bug_report()
    local stamp = os.date("%Y%m%d-%H%M%S")
    local dir = MOD_DIR:gsub("[^\\/]+[\\/]%.%.[\\/]$", "")
    local path = dir .. MOD .. "-bug-" .. stamp .. ".txt"
    local out = {}
    local function add(s) out[#out + 1] = scrub(s) end
    add(string.format("%s v%s bug report -- %s", MOD, VERSION, os.date("%Y-%m-%d %H:%M:%S")))
    -- Only promise what the scrub could do.
    if USERNAME and #USERNAME > 1 then
        add("Drag this file into the GitHub issue. Your Windows user name and Steam account numbers have been removed.")
    else
        add("Drag this file into the GitHub issue. Steam account numbers and your user folder name have been removed. "
            .. "Your Windows user name couldn't be detected, so check the file for it before you attach it.")
    end
    add("")
    add("== State ==")
    add("Steam folder: " .. tostring(steam.root) .. " (" .. tostring(steam.how) .. ")")
    add("achievement list from: " .. data.source .. ", " .. data.total .. " achievements, " .. #data.groups .. " groups")
    add("unlocked: " .. data.unlocked .. "   last error: " .. tostring(data.error))
    add("tracked: " .. table.concat(settings.track, ", ") .. "   HUD panel: " .. tostring(settings.widget))
    local live = {}
    for k, v in pairs(data.delta) do live[#live + 1] = k .. " +" .. v end
    add("progress this session: " .. (#live > 0 and table.concat(live, ", ") or "(none)"))
    add("")
    add("== settings.txt ==")
    add(read_all(SETTINGS_FILE) or "(none)")
    add("== UE4SS mods.txt ==")
    add(read_all(MOD_DIR .. "..\\mods.txt") or "(not found)")
    local modsDir = MOD_DIR .. "..\\"
    local names = {}
    pcall(function()
        local p = io.popen('dir /b /ad "' .. modsDir .. '" 2>nul')
        if p then
            for l in p:lines() do if l ~= "" then names[#names + 1] = l end end
            p:close()
        end
    end)
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    add("== Installed UE4SS mods (" .. #names .. ") ==")
    for _, nm in ipairs(names) do
        local on = exists(modsDir .. nm .. "\\enabled.txt") and "enabled.txt" or "-"
        add(string.format("%-30s %s", nm, on))
    end
    local acf = read_all(MOD_DIR .. string.rep("..\\", 8) .. "appmanifest_" .. APP_ID .. ".acf")
    add("game build: " .. ((acf and acf:match('"buildid"%s+"(%d+)"')) or "unknown"))
    add("")
    local logText = read_all(UE4SS_LOG)
    if logText then
        local header, mine, errors, i = {}, {}, {}, 0
        for line in logText:gmatch("[^\r\n]+") do
            i = i + 1
            if i <= 5 then header[#header + 1] = line end
            if line:find("[" .. MOD .. "]", 1, true) then mine[#mine + 1] = line end
            local l = line:lower()
            if l:find("error") or l:find("exception") or l:find("fatal") then errors[#errors + 1] = line end
        end
        local function tail(list, k) return table.concat(list, "\n", math.max(1, #list - k + 1), #list) end
        add("== UE4SS.log (start) ==")
        add(table.concat(header, "\n"))
        add("== UE4SS.log: errors (last 100) ==")
        add(#errors > 0 and tail(errors, 100) or "(none)")
        add("== UE4SS.log: " .. MOD .. " lines (last 300) ==")
        add(#mine > 0 and tail(mine, 300) or "(none)")
    else
        add("== UE4SS.log not found ==")
    end
    local f = io.open(path, "w")
    if not f then return nil end
    f:write(table.concat(out, "\n"), "\n")
    f:close()
    return path
end

-------------------------------------------------------------------------------
-- Clicks

local function do_action(hostPath, action)
    local h = hosts[hostPath]
    if action == "open" then open_panel(hostPath) return end
    if action == "close" then close_panel(hostPath) return end
    if action == "bugreport" then
        local path = write_bug_report()
        if path then
            open_external(issue_url("bug_report.yml"))
            open_external(path, true)
            set_status("Bug report saved (" .. path:match("[^\\]+$") .. "). GitHub is opening in your browser: "
                .. "alt-tab to it, drag the report file into the issue and press Submit.", true)
        else
            set_status("Could not save the bug report file.", false)
        end
    elseif action == "feature" then
        open_external(issue_url("feature_request.yml"))
        set_status("GitHub's feature request form is opening in your browser: alt-tab to it.", true)
    elseif action == "widget" then
        settings.widget = not settings.widget
        save_settings()
        dirty = true
        set_status(settings.widget and "HUD panel on." or "HUD panel off.", true)
    else
        local kind, arg = action:match("^(%w+):(.*)$")
        if kind == "filter" then
            settings.filter = arg
            status.text = ""
        elseif kind == "page" and h then
            h.pageIdx = math.max(0, math.min((h.pages or 1) - 1, (h.pageIdx or 0) + (tonumber(arg) or 0)))
        elseif kind == "track" then
            local g = data.groupByKey[arg]
            if g and not g.complete then
                -- A hidden achievement keeps its name hidden here too.
                local name = (g.focus.hidden and not g.complete) and "Hidden achievement" or g.title
                if is_tracked(arg) then
                    for i, k in ipairs(settings.track) do if k == arg then table.remove(settings.track, i) break end end
                    set_status(name .. " is no longer tracked.", true)
                elseif #settings.track >= MAX_TRACKED then
                    set_status("You're already tracking " .. MAX_TRACKED .. ". Untrack one first.", false)
                else
                    settings.track[#settings.track + 1] = arg
                    set_status(settings.widget and (name .. " is on your HUD panel.")
                        or (name .. " is tracked. Turn HUD Panel on to see it."), true)
                end
                save_settings()
                dirty = true
            end
        end
    end
    if h then refresh_panel(h, true) end
end

-- Put the app icon on a tablet / computer desktop (once per widget).
local function add_icon(host, kind)
    local hostPath = path_of(host)
    if not hostPath then return end
    local h = hosts[hostPath]
    if h then
        local icon = resolve(h.iconPath)
        if icon and valid(icon:GetParent()) then return end
    end
    local row, source
    if kind == "tablet" then
        local icons = host.WBP_TabletIcons
        row, source = icons.HorizontalBox_1, icons.Icon_Camera
    else
        local bar = host.WBP_TaskbarWidget
        row, source = bar.HorizontalBox, bar.Icon_ShoppingList
    end
    if not valid(row) or not valid(source) then log("icon row not found on " .. kind) return end
    local lib, cls = resolve(WIDGET_LIBRARY), resolve(ICON_CLASS)
    local icon = lib:Create(host, cls, host:GetOwningPlayer())
    if not valid(icon) then log("icon creation failed") return end
    icon.ButtonSize.X = source.ButtonSize.X
    icon.ButtonSize.Y = source.ButtonSize.Y
    icon.IconSize = source.IconSize
    icon.FontSize = source.FontSize
    icon.OutlineWidth = source.OutlineWidth
    icon.Roundness = source.Roundness
    icon.IconTextSpace = source.IconTextSpace
    icon.HoveredAnimation = source.HoveredAnimation
    set_color(icon.OutlineColor, source.OutlineColor)
    icon.Icon = FText("\239\130\145")   -- "trophy" glyph (U+F091) in the icon font
    icon.Text = FText("")
    set_color(icon.IconColor, { R = 1, G = 1, B = 1, A = 1 })
    set_color(icon.BackgroundColor, COLORS.btn)
    icon.IsInteractableAtStart = true
    local slot = row:AddChildToHorizontalBox(icon)
    pcall(function()
        local sp = source.Slot
        local p = sp.Padding
        slot:SetPadding({ Left = p.Left, Top = p.Top, Right = p.Right, Bottom = p.Bottom })
        slot:SetHorizontalAlignment(sp.HorizontalAlignment)
        slot:SetVerticalAlignment(sp.VerticalAlignment)
    end)
    finish_button(icon)
    pcall(function() icon:SetToolTipText(FText("Steam Achievements")) end)
    pcall(function()
        local s = source.RenderTransform.Scale
        icon:SetRenderScale({ X = s.X, Y = s.Y })
    end)
    hosts[hostPath] = { kind = kind, hostPath = hostPath, iconPath = path_of(icon), panelPath = h and h.panelPath or nil, w = h and h.w or {}, b = h and h.b or {} }
    buttons[icon:GetFullName()] = { host = hostPath, action = "open" }
    log("app icon added to " .. kind)
end

local function on_icon_clicked(ctx)
    local ok, clicked = pcall(function() return ctx:get() end)
    if not ok or not valid(clicked) then return end
    local b = buttons[clicked:GetFullName()]
    if not b then return end
    ExecuteInGameThread(function()
        local okA, err = xpcall(do_action, debug.traceback, b.host, b.action)
        if not okA then log("action " .. b.action .. " failed: " .. tostring(err)) end
    end)
end

local function on_host_ready(kind)
    return function(ctx)
        local ok, host = pcall(function() return ctx:get() end)
        if not ok or not valid(host) then return end
        local okI, err = xpcall(add_icon, debug.traceback, host, kind)
        if not okI then log(kind .. " icon failed: " .. tostring(err)) end
    end
end

-------------------------------------------------------------------------------
-- The HUD panel: our own widgets on the game's HUD (WBP_MainUI) canvas, at
-- the right edge. Two full rows and two condensed ones. The HUD takes no
-- mouse input, so the panel only shows; everything else is in the app.

local HUD_WIDTH = 360
local hud = { root = nil, hudPath = nil, rows = {}, keys = nil }

local function find_canvas(w, depth)
    if not valid(w) or depth > 4 then return nil end
    local okC, cn = pcall(function() return w:GetClass():GetFName():ToString() end)
    if okC and cn == "CanvasPanel" then return w end
    local n = 0
    pcall(function() n = w:GetChildrenCount() end)
    for i = 0, (n or 0) - 1 do
        local c = nil
        pcall(function() c = w:GetChildAt(i) end)
        local found = find_canvas(c, depth + 1)
        if found then return found end
    end
    return nil
end

local SHADOW = { R = 0, G = 0, B = 0, A = 0.9 }
local function shadowed(t)
    pcall(function() t:SetShadowOffset({ X = 1, Y = 1 }) end)
    pcall(function() t:SetShadowColorAndOpacity(SHADOW) end)
end

local function hud_remove()
    local r = resolve(hud.root)
    if r then pcall(function() r:RemoveFromParent() end) end
    hud.root, hud.rows, hud.keys = nil, {}, nil
end

local function hud_build(groups, mode)
    local main = first_live("WBP_MainUI_C")
    if not main then return false end
    local tree = main.WidgetTree
    local rootW = nil
    pcall(function() rootW = tree.RootWidget end)
    local canvas = find_canvas(rootW, 0)
    if not canvas then return false end
    hud_remove()
    local back = make_border(tree, COLORS.hudBack, 10, 8, 10, 8)
    local col = new_widget("VerticalBox", tree)
    back:SetContent(col)
    hud.rows = {}
    -- Title line, so the panel is recognisable: what it is, and whose picks.
    local head = new_widget("HorizontalBox", tree)
    local ht = make_text(tree, "STEAM ACHIEVEMENTS", 12, COLORS.section)
    shadowed(ht)
    fill(head:AddChildToHorizontalBox(ht), 1)
    local hm = make_text(tree, mode == "tracked" and "Tracked" or "Suggested", 12, COLORS.dim)
    shadowed(hm)
    head:AddChildToHorizontalBox(hm)
    pad(col:AddChildToVerticalBox(head), 0, 0, 0, 6)
    for i, g in ipairs(groups) do
        local full = i <= 2
        local r = { key = g.key, full = full }
        local row = new_widget("HorizontalBox", tree)
        local left = new_widget("VerticalBox", tree)
        local iconBox, img = make_image(main, tree, group_icon(g), full and 50 or 30)
        left:AddChildToVerticalBox(iconBox)
        r.img = path_of(img)
        if full and #g.tiers > 1 then
            local drow, dots = make_dots(tree, #g.tiers, 7)
            local ds = left:AddChildToVerticalBox(drow)
            pad(ds, 0, 4, 0, 0)
            halign(ds, 2)
            r.dots = dots
        end
        local ls = row:AddChildToHorizontalBox(left)
        pad(ls, 0, 0, 10, 0)
        valign(ls, 1)
        local mid = new_widget("VerticalBox", tree)
        if full then
            local t = make_text(tree, "", 15, COLORS.white)
            shadowed(t)
            mid:AddChildToVerticalBox(t)
            r.title = path_of(t)
            local barBox, pb = make_bar(tree, HUD_WIDTH - 95, 8)
            pad(mid:AddChildToVerticalBox(barBox), 0, 4, 0, 1)
            r.bar, r.barBox = path_of(pb), path_of(barBox)
            local c = make_text(tree, "", 13, COLORS.gold)
            shadowed(c)
            local cs = mid:AddChildToVerticalBox(c)
            halign(cs, 3)
            r.count = path_of(c)
        else
            local top = new_widget("HorizontalBox", tree)
            local t = make_text(tree, "", 13, COLORS.white)
            shadowed(t)
            -- A long title is cut short rather than running under the count.
            pcall(function() t:SetClipping(1) end)
            pcall(function() t:SetTextOverflowPolicy(1) end)   -- ellipsis, where the engine has it
            fill(top:AddChildToHorizontalBox(t), 1)
            local c = make_text(tree, "", 12, COLORS.gold)
            shadowed(c)
            local cs = top:AddChildToHorizontalBox(c)
            pad(cs, 8, 0, 0, 0)
            mid:AddChildToVerticalBox(top)
            r.title, r.count = path_of(t), path_of(c)
            local bot = new_widget("HorizontalBox", tree)
            if #g.tiers > 1 then
                local drow, dots = make_dots(tree, #g.tiers, 5)
                local ds = bot:AddChildToHorizontalBox(drow)
                pad(ds, 0, 0, 6, 0)
                valign(ds, 2)
                r.dots = dots
            end
            local barBox, pb = make_bar(tree, HUD_WIDTH - 120, 5)
            local bs = bot:AddChildToHorizontalBox(barBox)
            valign(bs, 2)
            r.bar, r.barBox = path_of(pb), path_of(barBox)
            -- A one-off has no bar: its "x% have it" goes on this line instead,
            -- because the title line has no room for it.
            local sub = make_text(tree, "", 11, COLORS.gold)
            shadowed(sub)
            local subs = bot:AddChildToHorizontalBox(sub)
            valign(subs, 2)
            r.sub = path_of(sub)
            pad(mid:AddChildToVerticalBox(bot), 0, 4, 0, 0)
        end
        local ms = row:AddChildToHorizontalBox(mid)
        fill(ms, 1)
        valign(ms, 2)
        local rs = col:AddChildToVerticalBox(row)
        pad(rs, 0, i == 1 and 0 or (full and 8 or 6), 0, 0)
        hud.rows[#hud.rows + 1] = r
    end
    if mode == "suggested" then
        local nrow = new_widget("HorizontalBox", tree)
        -- Two columns: the ? on the left, centred against the text block.
        local q = make_logo(main, tree, 20, HELP_FILE)
        if q then
            local qs = nrow:AddChildToHorizontalBox(q)
            pad(qs, 0, 0, 8, 0)
            valign(qs, 2)
        end
        local note = make_text(tree, "Choose your own achievements to track, or turn off this panel from the Steam Achievements app.", 10, COLORS.dim)
        shadowed(note)
        pcall(function() note:SetAutoWrapText(true) end)
        fill(nrow:AddChildToHorizontalBox(note), 1)
        pad(col:AddChildToVerticalBox(nrow), 0, 8, 0, 0)
    end
    local sz = sized(tree, HUD_WIDTH, nil, back)
    pcall(function() sz:SetVisibility(3) end)   -- never takes the mouse
    local slot = canvas:AddChildToCanvas(sz)
    -- Top right, level with the reputation box in the top left (the game's
    -- key hints, Tablet T, Map M ..., sit lower down on the right).
    pcall(function() slot:SetAnchors({ Minimum = { X = 1.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } }) end)
    pcall(function() slot:SetAlignment({ X = 1.0, Y = 0.0 }) end)
    pcall(function() slot:SetPosition({ X = -24, Y = 24 }) end)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetZOrder(900) end)
    hud.root, hud.hudPath = path_of(sz), path_of(main)
    local keys = { mode }
    for _, g in ipairs(groups) do keys[#keys + 1] = g.key end
    hud.keys = table.concat(keys, "|")
    return true
end

local function hud_refresh()
    local main = resolve(hud.hudPath)
    for _, r in ipairs(hud.rows) do
        local g = data.groupByKey[r.key]
        if g then
            local hidden = g.focus.hidden and not g.complete
            set_text(resolve(r.title), hidden and "Hidden achievement" or g.title, g.complete and COLORS.good or COLORS.white)
            local oneOff = not g.complete and not g.hasProgress
            local pct = string.format("%.1f%% have it", g.globalPct)
            local extra = (oneOff and r.full) and (" (" .. pct .. ")") or ""
            set_text(resolve(r.count), progress_text(g) .. extra, g.complete and COLORS.good or COLORS.gold)
            local sub = resolve(r.sub)
            if sub then
                set_text(sub, oneOff and pct or "")
                pcall(function() sub:SetVisibility(oneOff and 3 or 1) end)
            end
            local bb = resolve(r.barBox)
            if bb then pcall(function() bb:SetVisibility((g.hasProgress or g.complete) and 0 or 1) end) end
            set_bar(resolve(r.bar), g.pct, g.complete and COLORS.good or COLORS.barFill)
            set_dots(r.dots, g, r.full and 7 or 5)
            if main then set_image(main, resolve(r.img), group_icon(g)) end
        end
    end
end

-- Keeps the panel in step with the HUD, the settings and the data. A row
-- that has just been completed stays (showing Done) for a few seconds
-- before the panel moves on.
local DONE_LINGER = 8
local lingerUntil = 0
local function hud_tick()
    if not settings.widget or #data.groups == 0 then
        if hud.root then hud_remove() end
        return
    end
    local main = first_live("WBP_MainUI_C")
    if not main then hud.root = nil return end
    local live = resolve(hud.root)
    if live and hud.hudPath ~= path_of(main) then hud_remove() live = nil end
    -- Something on the panel just finished: let it show Done for a moment.
    if live and dirty then
        for _, r in ipairs(hud.rows) do
            local g = data.groupByKey[r.key]
            if g and g.complete and os.clock() > lingerUntil + DONE_LINGER then lingerUntil = os.clock() end
        end
    end
    if os.clock() < lingerUntil + DONE_LINGER and live then hud_refresh() return end
    drop_completed_tracks()
    local groups, mode = hud_groups()
    local keys = { mode }
    for _, g in ipairs(groups) do keys[#keys + 1] = g.key end
    if not live or table.concat(keys, "|") ~= hud.keys then
        if #groups == 0 then hud_remove() return end
        if not hud_build(groups, mode) then return end
    end
    hud_refresh()
end

-------------------------------------------------------------------------------
-- Escape: the tablet/computer only handle "back" for their own apps, so do
-- it for ours (taken from the game's key handling on the screens; game thread).

local INPUT_LIBRARY = "/Script/Engine.Default__KismetInputLibrary"
local lastEscape = -1e9
local function key_hook(name)
    return function(self, geometry, keyEvent)
        local key = nil
        pcall(function()
            local k = resolve(INPUT_LIBRARY):GetKey(keyEvent:get())
            key = k.KeyName:ToString()
        end)
        if key ~= "Escape" then return end
        if os.clock() - lastEscape < 0.25 then return end
        lastEscape = os.clock()
        ExecuteInGameThread(function()
            for hostPath, h in pairs(hosts) do
                if panel_visible(h) then close_panel(hostPath) end
            end
        end)
    end
end

-------------------------------------------------------------------------------
-- Hooks: the screens' icon rows, clicks, keys, and the game's achievement calls.

local function in_game_world()
    local pc = first_live("BP_PlayerController_C")
    local p = pc and path_of(pc) or ""
    return p ~= "" and not p:find("MenuMap", 1, true)
end
local classTried, classLoaded = {}, {}
local function load_class(classPath)
    if classLoaded[classPath] then return classLoaded[classPath] end
    if classTried[classPath] or type(LoadAsset) ~= "function" then return nil end
    if not in_game_world() then return nil end
    classTried[classPath] = true
    local c = nil
    pcall(function() c = LoadAsset(classPath) end)
    if valid(c) then
        path_of(c)
        classLoaded[classPath] = c
        return c
    end
    return nil
end
local function base_class_path()
    local tc = load_class(TABLET_CLASS)
    if tc then
        local ok, sup = pcall(function() return tc:GetSuperStruct() end)
        if ok and valid(sup) then return path_of(sup) end
    end
    return nil
end
local function game_instance_class()
    local gi = first_live("BP_CDSGameInstance_C")
    return gi and path_of(gi:GetClass()) or nil
end

local function on_progress_call(self, statP, amountP)
    local okS, v = pcall(function() return statP:get() end)
    local okA, n = pcall(function() return amountP:get() end)
    if not okS or not okA then return end
    local name = enum_name(STAT_ENUM, v)
    if name then on_stat_progress(name, tonumber(n) or 0) end
end
local function on_unlock_call(self, achP)
    local ok, v = pcall(function() return achP:get() end)
    if not ok then return end
    on_unlock(enum_name(ACH_ENUM, v))
end

local HOOKS = {
    { name = "icon click", gate = "WBP_DesktopIconWidget_C", path = ICON_CLICK, fn = on_icon_clicked },
    { name = "tablet", gate = "WBP_Tablet_C", kind = "tablet", path = TABLET_CLASS .. ":ActivateApplications", fn = on_host_ready("tablet") },
    { name = "computer", gate = "WBP_DesktopComputer_C", kind = "computer", path = COMPUTER_CLASS .. ":Activate Applications", fn = on_host_ready("computer") },
    { name = "tablet keys", gate = "WBP_Tablet_C", path = TABLET_CLASS .. ":OnKeyDown", fn = key_hook("tablet OnKeyDown") },
    { name = "computer keys", gate = "WBP_DesktopComputer_C", path = COMPUTER_CLASS .. ":OnKeyDown", fn = key_hook("computer OnKeyDown") },
    { name = "preview keys", base = true, fn = key_hook("base OnPreviewKeyDown") },
    { name = "achievement progress", gi = "ProgressAchievementStat", fn = on_progress_call },
    { name = "achievement unlock", gi = "UnlockAchievement", fn = on_unlock_call },
}

local function game_loop(name, ms, fn)
    local function step()
        local ok, stop = xpcall(fn, debug.traceback)
        if not ok then log(name .. " loop error: " .. tostring(stop)) return false end
        return stop == true
    end
    if type(LoopInGameThreadWithDelay) == "function" and type(CancelDelayedAction) == "function" then
        local handle
        handle = LoopInGameThreadWithDelay(ms, function()
            if step() and handle then CancelDelayedAction(handle) end
        end)
        return
    end
    local queued, stopped = false, false
    LoopAsync(ms, function()
        if stopped then return true end
        if queued then return false end
        queued = true
        ExecuteInGameThread(function()
            queued = false
            if step() then stopped = true end
        end)
        return false
    end)
end

-- Registers each hook once its class is live. A hook whose class is live but
-- which still fails is given up (not retried).
game_loop("hooks", 2000, function()
    local pending = 0
    for _, hk in ipairs(HOOKS) do
        if not hk.done then
            local path = hk.path
            if hk.base then
                local b = base_class_path()
                path = b and (b .. ":OnPreviewKeyDown") or nil
            elseif hk.gi then
                local c = game_instance_class()
                path = c and (c .. ":" .. hk.gi) or nil
            elseif hk.gate and not load_class((path:gsub(":.*$", ""))) and not first_live(hk.gate) then
                path = nil
            end
            if path then
                local ok, err = pcall(function() RegisterHook(path, hk.fn) end)
                hk.done = true
                log(hk.name .. (ok and " hook registered" or (" hook FAILED, not retried: " .. tostring(err))))
                local live = (ok and hk.kind) and first_live(hk.gate) or nil
                if live then
                    local okI, errI = pcall(add_icon, live, hk.kind)
                    if not okI then log(hk.kind .. " icon failed: " .. tostring(errI)) end
                end
            else
                pending = pending + 1
            end
        end
    end
    return pending == 0
end)

-------------------------------------------------------------------------------
-- main loop: HUD every second, open app refresh twice a second, Steam's file
-- every FILE_CHECK_SECONDS.

local loaded = false
local ticks = 0
game_loop("main", 500, function()
    ticks = ticks + 1
    if not loaded then
        loaded = true
        load_data()
        read_progress()
        log(string.format("%d achievements in %d groups (list from %s)", #data.list, #data.groups, data.source))
    end
    if os.clock() - data.lastCheck > FILE_CHECK_SECONDS then
        read_progress()
        dirty = true
    end
    if ticks % 2 == 0 and in_game_world() then hud_tick() end
    for _, h in pairs(hosts) do
        if panel_visible(h) then
            -- New progress can move rows between filters; on All it only
            -- changes what the rows say.
            if dirty and settings.filter ~= "all" then h.rowsDirty = true end
            refresh_panel(h, dirty)
        end
    end
    if ticks % 2 == 0 then dirty = false end
    return false
end)

log("v" .. VERSION .. " loaded")
