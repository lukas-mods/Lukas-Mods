--[[
    Parts Manager v1.1.1 -- by Luka's Mods  (live edits number the VERSION below)

    Adds a "Parts Manager" app to the in-game tablet and the office
    computer. It shows what is in your warehouse storage and how many complete
    cars that stock can build, and buys parts at normal store prices straight
    into storage:

      - whole car builds: pick a kit (Stock / Sport / Race), a number of cars,
        and whether to include body parts and consumables;
      - single parts by car count: e.g. brake calipers for 2 cars = 8;
      - auto-stock: keeps a chosen number of complete builds in storage by
        topping it up in the background.
      - workshop supplies (Workshop tab): car wash and body shop supplies,
        bought 10 at a time or kept stocked by Auto Supplies;
      - fuel delivery (Fuel Delivery tab): fills the gas pump hub's unlocked
        tanks at the pump's price, by hand or with Auto Fuel.

      - Part names, prices and per-car quantities come from the game's own
        data tables (a car takes 4 calipers, 2 front shocks, ...).
      - Sport / Race tabs show a padlock until every part in them is unlocked;
        the app asks the same fame check the shop uses.
      - Settings (and per-car consumable amounts) are kept in settings.txt
        next to this mod.

    No game objects are kept between ticks: only their paths are stored, and
    everything is looked up again when it is used.
--]]

local MOD = "PartsManager"
local VERSION = "1.1.1"  -- live-edit number: the log names the code that ran
local function log(msg) print("[" .. MOD .. "] " .. tostring(msg) .. "\n") end

-- Trace logging, off by default: debug_trace=1 in settings.txt turns on the
-- crash breadcrumbs ("#n > what" when the mod starts a piece of real work on the
-- game thread, "#n <" when it finishes) and a 10 s heartbeat.
local traceOn = false
local crumbSeq = 0
local function crumb(what, fn, ...)
    if not traceOn then return fn(...) end
    crumbSeq = crumbSeq + 1
    local n = crumbSeq
    log("#" .. n .. " > " .. what)
    local r = table.pack(fn(...))
    log("#" .. n .. " <")
    return table.unpack(r, 1, r.n)
end

-------------------------------------------------------------------------------
-- paths

local TABLET_CLASS = "/Game/CarDealerSim/UI/InGame/Tablet/WBP_Tablet.WBP_Tablet_C"
local COMPUTER_CLASS = "/Game/CarDealerSim/UI/InGame/Computer/WBP_DesktopComputer.WBP_DesktopComputer_C"
local ICON_CLASS = "/Game/CarDealerSim/UI/InGame/Computer/WBP_DesktopIconWidget.WBP_DesktopIconWidget_C"
local ICON_CLICK = ICON_CLASS
    .. ":BndEvt__WBP_DesktopIconWidget_Button_112_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature"
local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"
local FONT = "/Game/CarDealerSim/UI/Fonts/Montserrat/Lato-Medium_Font.Lato-Medium_Font"

local PRODUCT_TABLES = {
    { path = "/Game/CarDealerSim/DataAssets/Products/CarParts/DT_CarPartsMaster.DT_CarPartsMaster", group = "part" },
    { path = "/Game/CarDealerSim/DataAssets/Products/DT_Fluids.DT_Fluids", group = "fluid" },
    { path = "/Game/CarDealerSim/DataAssets/Products/DT_Components.DT_Components", group = "component" },
    { path = "/Game/CarDealerSim/DataAssets/Products/DT_FusesParts.DT_FusesParts", group = "fuse" },
    -- Workshop supplies: soap, wax, polish, discs, putty, pads, paint. Row IDs
    -- carry the tier as a suffix (Wax_Base = Wax - Basic). The first table holds
    -- the Basic tier; _Special holds the others (Large, Range+, Eco-friendly,
    -- Extra Durable), whose labels come from the product names, not the suffix.
    { path = "/Game/CarDealerSim/DataAssets/Products/DT_ConsumableMaterials.DT_ConsumableMaterials", group = "supply" },
    { path = "/Game/CarDealerSim/DataAssets/Products/DT_ConsumableMaterials_Special.DT_ConsumableMaterials_Special", group = "supply" },
}
-- Body work rather than mechanical parts: bought with the consumables.
local BODY_PARTS = { Windshield = true }

-- Default per-car amounts for body parts and consumables (by ProductID).
-- Editable in settings.txt as "per_car.<ProductID>=<amount>".
local DEFAULT_PER_CAR = {
    Windshield = 1, CarplateRepairKit = 1,
    EngineOil4L = 1, Coolant5L = 1, BrakeFluid1L = 1,
}

local ADDS_PER_TICK = 20          -- items added to storage per game-thread pass
local FUSES_PER_PACK = 3          -- fuses in one pack (the shop sells packs)
local AVAIL_REFRESH_SECONDS = 60  -- how often the unlock check is re-run
local AUTO_CHECK_SECONDS = 30     -- how often auto-stock looks at storage
local SUPPLY_PACK = 10            -- workshop supplies bought by hand come 10 at a time
local SUPPLY_STEP = 5             -- Auto Supplies' keep-N steps

-------------------------------------------------------------------------------
-- helpers

local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
-- Objects are remembered by path, and resolve() hands back the remembered
-- object instead of searching for it. Why: when StaticFindObject is asked for a
-- path that no longer exists (a widget the tablet has rebuilt), UE4SS falls back
-- to a slow walk over every object in the game, and that walk crashed (crash 4,
-- symbolized: FindObject -> ObjectSearcherSlow -> ForEachUObject ->
-- GetOutermost). So a path we have seen and that has died returns nil without
-- a search, and an unknown path that isn't found is only retried every 10 s.
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
-- UFunction out-parameters: UE4SS g44afb36d writes every result into the
-- FIRST table passed; newer builds (fix #1454) may give each its own table.
-- Take the field from whichever table has it.
local function out_field(name, ...)
    for i = 1, select("#", ...) do
        local t = select(i, ...)
        if type(t) == "table" and t[name] ~= nil then return t[name] end
    end
    return nil
end
local function each(arr, fn)
    if arr == nil then return end
    if type(arr) == "table" then
        for _, v in ipairs(arr) do fn(v) end
        return
    end
    pcall(function()
        arr:ForEach(function(_, e)
            local v = e
            pcall(function() v = e:get() end)
            fn(v)
        end)
    end)
end
local function array_len(arr)
    if arr == nil then return 0 end
    if type(arr) == "table" then return #arr end
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    return ok and n or 0
end
-- 12345 -> "12,345" (counts and money read the same way).
local function num_text(v)
    local s = tostring(math.floor((v or 0) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end
local function money_text(v) return "$" .. num_text(v) end

-------------------------------------------------------------------------------
-- settings (settings.txt beside this mod)

local src = debug.getinfo(1, "S").source
local MOD_DIR = ((src:sub(1, 1) == "@") and src:sub(2):match("(.*[/\\])") or ".\\") .. "..\\"
local SETTINGS_FILE = MOD_DIR .. "settings.txt"

local settings = {
    kit = "Stock", builds = 1, extras = true,
    countWorn = true,
    -- auto-stock per kit: on/off and how many complete cars to keep
    autoOn = { Stock = false, Sport = false, Race = false },
    autoTarget = { Stock = 5, Sport = 5, Race = 5 },
    -- auto fuses: keep this many fuses of every size (loose + 3 per pack)
    fuseOn = false, fuseTarget = 9,
    -- auto-stock never takes the balance below this (0 = off)
    moneyFloor = 0,
    -- pause auto-stock whenever a save is loaded: off by default (most players
    -- keep one career); turn on with pause_auto_on_load=1 if you play several
    pauseOnLoad = false,
    perCar = {},
    -- auto supplies: keep this many of each workshop supply (the chosen tier)
    supplyOn = false, supplyTarget = 10,
    -- auto fuel: fill every unlocked hub tank to full once their combined
    -- fuel is below 10% of their combined capacity
    fuelOn = false,
    supplyTier = {},   -- supply group -> tier suffix ("Base"); unset = cheapest
}
for k, v in pairs(DEFAULT_PER_CAR) do settings.perCar[k] = v end

local function load_settings()
    local f = io.open(SETTINGS_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_%.]+)%s*=%s*(.-)%s*$")
        if k then
            local id = k:match("^per_car%.(.+)$")
            if id then settings.perCar[id] = tonumber(v) or 0
            elseif k == "kit" and (v == "Stock" or v == "Sport" or v == "Race") then settings.kit = v
            elseif k == "builds" then settings.builds = math.max(1, math.min(999, tonumber(v) or 1))
            elseif k == "extras" then settings.extras = (v == "1" or v == "true")
            elseif k:match("^auto%.") and settings.autoOn[k:sub(6)] ~= nil then
                settings.autoOn[k:sub(6)] = (v == "1" or v == "true")
            elseif k:match("^auto_target%.") and settings.autoTarget[k:sub(13)] ~= nil then
                settings.autoTarget[k:sub(13)] = math.max(1, math.min(999, tonumber(v) or 5))
            elseif k == "count_worn" then settings.countWorn = (v == "1" or v == "true")
            elseif k == "auto_fuses" then settings.fuseOn = (v == "1" or v == "true")
            elseif k == "auto_fuses_target" then settings.fuseTarget = math.max(1, math.min(999, tonumber(v) or 9))
            elseif k == "money_floor" then settings.moneyFloor = math.max(0, tonumber(v) or 0)
            elseif k == "debug_trace" then traceOn = (v == "1")
            elseif k == "pause_auto_on_load" then settings.pauseOnLoad = (v == "1" or v == "true")
            elseif k == "auto_supplies" then settings.supplyOn = (v == "1" or v == "true")
            elseif k == "auto_fuel" then settings.fuelOn = (v == "1" or v == "true")
            elseif k == "auto_supplies_target" then settings.supplyTarget = math.max(0, math.min(999, tonumber(v) or 10))
            elseif k:match("^supply_tier%.") and v ~= "" then settings.supplyTier[k:sub(13)] = v
            end
        end
    end
    f:close()
end

local function save_settings()
    local lines = {
        "# Parts Manager settings (edited by the app; per_car lines may be edited by hand)",
        "kit=" .. settings.kit,
        "builds=" .. settings.builds,
        "extras=" .. (settings.extras and "1" or "0"),
        "count_worn=" .. (settings.countWorn and "1" or "0"),
        "auto_fuses=" .. (settings.fuseOn and "1" or "0"),
        "auto_fuses_target=" .. settings.fuseTarget,
        "money_floor=" .. string.format("%d", settings.moneyFloor),
        "pause_auto_on_load=" .. (settings.pauseOnLoad and "1" or "0"),
        "auto_supplies=" .. (settings.supplyOn and "1" or "0"),
        "auto_supplies_target=" .. settings.supplyTarget,
        "auto_fuel=" .. (settings.fuelOn and "1" or "0"),
    }
    local groups = {}
    for g in pairs(settings.supplyTier) do groups[#groups + 1] = g end
    table.sort(groups)
    for _, g in ipairs(groups) do lines[#lines + 1] = "supply_tier." .. g .. "=" .. settings.supplyTier[g] end
    if traceOn then lines[#lines + 1] = "debug_trace=1" end
    for _, c in ipairs({ "Stock", "Sport", "Race" }) do
        lines[#lines + 1] = "auto." .. c .. "=" .. (settings.autoOn[c] and "1" or "0")
        lines[#lines + 1] = "auto_target." .. c .. "=" .. settings.autoTarget[c]
    end
    lines[#lines + 1] = "# Body parts and consumables bought per car when 'Body & Consumables' is on."
    local ids = {}
    for id in pairs(settings.perCar) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do lines[#lines + 1] = "per_car." .. id .. "=" .. settings.perCar[id] end
    local f = io.open(SETTINGS_FILE, "w")
    if not f then return end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
end

load_settings()

-------------------------------------------------------------------------------
-- catalogue (built once from the data tables; class paths, not objects)

local catalog, catalogById = nil, {}

local function tier_of(rowName)
    if rowName:match("Race$") then return "Race" end
    if rowName:match("Sport$") then return "Sport" end
    return "Stock"
end

local function build_catalog()
    local list, byId = {}, {}
    for _, t in ipairs(PRODUCT_TABLES) do
        local dt = resolve(t.path)
        if not dt and LoadAsset then
            pcall(function() LoadAsset(t.path) end)
            dt = resolve(t.path)
        end
        if dt then
            -- The row struct is a Blueprint struct, so its field names are
            -- mangled (ProductClass_2_<guid>): find the class field by type.
            local classField = nil
            pcall(function()
                dt.RowStruct:ForEachProperty(function(p)
                    if classField then return end
                    local okT, pt = pcall(function() return p:GetClass():GetFName():ToString() end)
                    if okT and pt == "ClassProperty" then classField = p:GetFName():ToString() end
                end)
            end)
            pcall(function()
                dt:ForEachRow(function(rowName, row)
                    local rn = text_of(rowName)
                    local cls = nil
                    if classField then pcall(function() cls = row[classField] end) end
                    if not valid(cls) then return end
                    local cdo = nil
                    pcall(function() cdo = cls:GetCDO() end)
                    if not valid(cdo) then return end
                    local e = { row = rn, group = t.group, clsPath = path_of(cls), clsName = text_of(cls:GetFName()) }
                    pcall(function() e.id = text_of(cdo.ProductID) end)
                    if not e.id or e.id == "" then e.id = rn end
                    pcall(function() e.name = text_of(cdo.DisplayName) end)
                    pcall(function() e.price = tonumber(cdo.BasePrice) end)
                    e.name = (e.name and e.name ~= "") and e.name or rn
                    e.price = e.price or 0
                    e.perCar, e.tier = 0, ""
                    if t.group == "part" then
                        pcall(function() e.perCar = array_len(cdo.PartSlots) end)
                        e.tier = tier_of(rn)
                        if BODY_PARTS[rn] then e.group = "body" end
                    end
                    -- Sport/Race start locked until the first unlock check.
                    local gated = (e.tier == "Sport" or e.tier == "Race")
                    e.avail, e.reason = not gated, gated and "not checked yet" or ""
                    if not byId[e.id] then
                        list[#list + 1] = e
                        byId[e.id] = e
                    end
                end)
            end)
        end
    end
    if #list > 0 then
        catalog, catalogById = list, byId
        log("catalogue: " .. #list .. " products")
    end
end

-------------------------------------------------------------------------------
-- game state (looked up fresh every time)

local function get_storage()
    return first_live("BPC_PlayerStorage_C", "PersistentLevel") or first_live("BPC_PlayerStorage_C")
end
local function get_economy() return first_live("BP_EconomySystem_C") end
local function get_money(eco)
    local ok, v = pcall(function() return eco.PlayerMoney end)
    return ok and tonumber(v) or nil
end
-- Sport and Race parts come with the Up 2 You DLC, but their product classes
-- load from the base game even without it, and IsProductAvailableToBuy then
-- says "available". The racing manager's CLASS also loads without the DLC
-- (measured), but a live racing manager only runs with it, so a live one is
-- the sign the DLC is installed. Fails closed: not found = no DLC.
local dlcLogged = nil
local function dlc_present()
    local present = first_live("BP_RacingManagerComp_C") ~= nil
    if dlcLogged ~= present then
        log("Up 2 You DLC " .. (present and "detected (live racing manager)"
            or "not detected (no live racing manager) - Sport/Race hidden"))
        dlcLogged = present
    end
    return present
end

-- Reputation level, from the economy's own GetReputationLevel (out-param
-- ReputationLevel, like GetFameLevel).
local function get_rep_level(eco)
    if not eco then return nil end
    local out = {}
    if pcall(function() eco:GetReputationLevel(out) end) then return tonumber(out.ReputationLevel) end
    return nil
end

local function get_fame()
    -- No DLC means no racing manager: skip the object search (once a second
    -- from the panel) until the DLC check finds one.
    if dlcLogged == false then return nil end
    local rm = first_live("BP_RacingManagerComp_C")
    if not rm then return nil end
    local out = {}
    if pcall(function() rm:GetFameLevel(out) end) then return tonumber(out.ReputationLevel) end
    return nil
end
local function get_free_space(storage)
    local out = {}
    if pcall(function() storage:GetFreeSpaceLeft(out) end) then return tonumber(out.NumberOfFreeSpace) end
    return nil
end

-- What is in storage, per product class path: { ready = n, repair = n }.
-- "ready" = full condition; "repair" = anything below it.
local function count_container(container, counts)
    -- Read the container's own Items array. (Not GetAllItemsStackList: its
    -- out-array lives in the call's temporary memory, which is freed when the
    -- call returns -- iterating it afterwards crashed the game.)
    local stacks = nil
    pcall(function() stacks = container.Items end)
    each(stacks, function(stack)
        if not valid(stack) then return end
        local cls = nil
        pcall(function() cls = stack.ItemClass end)
        if not valid(cls) then return end
        local p = path_of(cls)
        if not p then return end
        local c = counts[p] or { ready = 0, repair = 0 }
        counts[p] = c
        local instances = nil
        pcall(function() instances = stack.ItemInstances end)
        each(instances, function(item)
            local d = nil
            if valid(item) then pcall(function() d = tonumber(item.Durability) end) end
            if d and d > 1.0001 then d = d / 100 end   -- some report 0-100
            if d == nil or d >= 0.999 then c.ready = c.ready + 1 else c.repair = c.repair + 1 end
        end)
    end)
    return counts
end

local function count_storage(storage) return count_container(storage, {}) end

-- Parts carried outside storage: the player's inventory and car trunks.
-- Shown for reference only -- the game's automation (and so auto-stock and
-- the complete-car counts) only draws on warehouse storage. Trunk containers
-- are found with a full object search, so their paths are cached for a minute.
local trunkPaths, trunkScan = {}, -1e9
local function count_carried()
    local counts = {}
    local inv = first_live("BP_InventoryComp_C", "BP_PlayerController_C")
    if inv then count_container(inv, counts) end
    if os.clock() - trunkScan > 60 then
        trunkScan = os.clock()
        trunkPaths = {}
        pcall(function()
            for _, c in ipairs(FindAllOf("BC_VehicleContainer_C") or {}) do
                local p = valid(c) and path_of(c)
                if p and not p:find("Default__", 1, true) and not p:find("_C:WidgetTree.", 1, true) then
                    trunkPaths[#trunkPaths + 1] = p
                end
            end
        end)
    end
    for _, p in ipairs(trunkPaths) do
        local c = resolve(p)
        if c then count_container(c, counts) end
    end
    return counts
end

-- Ready and needs-repair counts for a product. Fluids and consumables are
-- used up rather than repaired, so a part-used one still counts as ready.
local function stock_of(counts, e)
    local c = counts[e.clsPath]
    if not c then return 0, 0 end
    if e.group ~= "part" and e.group ~= "body" then return c.ready + c.repair, 0 end
    return c.ready, c.repair
end

-- How many count toward builds and auto-stock (worn ones only if the
-- "Count Worn Parts" setting is on).
local function usable(counts, e)
    local ready, repair = stock_of(counts, e)
    return ready + (settings.countWorn and repair or 0)
end

-- The shop's own fame check, IsProductAvailableToBuy, asked of a product
-- object. The shop creates those while it is open; otherwise we create our
-- own copy (a plain data object owned by the player controller, never placed
-- in the world) and ask it. Its path is kept so it is reused, not re-made.
-- (The class default objects were tried instead: they answer "available"
-- to everything, so Sport/Race opened at fame 1. The save crashes those builds
-- chased turned out to be the in-game email, not these objects.)
local lastAvailCheck = -1e9
local checkObjects = {}   -- product id -> path of our check object
local staleLogged = {}
local checkCounter = 0
local availLogged = {}

local function check_object(e, ctx)
    local p = checkObjects[e.id]
    local o = resolve(p)
    if o then
        -- Nothing holds these objects, so the engine may collect one and
        -- reuse its slot for another product's check object; a stale cached
        -- pointer then answers for the wrong part (Sport showed Race's fame
        -- level). Trust it only while its own name still matches.
        local ok, n = pcall(function() return o:GetFullName() end)
        if ok and n and n:find(p, 1, true) then return o end
        known[p], gone[p], checkObjects[e.id] = nil, true, nil
        if not staleLogged[e.id] then log("check object for " .. e.id .. " was reused by the engine; making a new one") staleLogged[e.id] = true end
    end
    local cls = resolve(e.clsPath)
    if not cls or not ctx then return nil end
    checkCounter = checkCounter + 1
    local ok, made = pcall(function()
        return StaticConstructObject(cls, ctx, FName(string.format("IM_Check_%s_%d", e.id, checkCounter)))
    end)
    if ok and valid(made) then
        checkObjects[e.id] = path_of(made)
        return made
    end
    if not availLogged[e.id] then log("could not create check object for " .. e.id .. ": " .. tostring(made)) end
    return nil
end

-- UE4SS needs a table for every out-parameter (IsAvailable, FailReason);
-- g44afb36d writes all the results into the first one (see out_field).
local function ask_available(obj)
    local out, out2 = {}, {}
    local ok, err = pcall(function() obj:IsProductAvailableToBuy(out, out2) end)
    local isAvail = out_field("IsAvailable", out, out2)
    if ok and isAvail ~= nil then
        return isAvail == true, text_of(out_field("FailReason", out, out2))
    end
    return nil, tostring(err)
end

-- Every product is asked (Stock parts and consumables too, in case early-game
-- progression locks them). A product whose class has no availability rule
-- counts as available -- except Sport/Race (DLC, fame-locked), which stay
-- locked if their check can't be answered, and are always locked without the
-- DLC (the game's own check does not cover that case).
local function refresh_availability()
    if not catalog then return end
    local ctx = first_live("BP_PlayerController_C", "PersistentLevel")
    local hasDlc = dlc_present()
    for _, e in ipairs(catalog) do
        local dlc = (e.tier == "Sport" or e.tier == "Race")
        local avail, reason = nil, nil
        e.noDlc = dlc and not hasDlc
        if e.noDlc then
            e.avail, e.reason, e.fameNeeded = false, "needs the Up 2 You DLC", nil
        else
            local own = check_object(e, ctx)
            if own then avail, reason = ask_available(own) end
        end
        if e.noDlc then
            -- already set above
        elseif avail == nil then
            if dlc then
                e.avail, e.reason = false, "could not check unlock"
                if not availLogged[e.id] then
                    log("unlock check failed for " .. e.id .. ": " .. tostring(reason))
                    availLogged[e.id] = true
                end
            else
                e.avail, e.reason = true, ""
            end
        else
            e.avail, e.reason = avail, reason or ""
            -- Only a fame reason gives a fame level; any other lock (workshop
            -- upgrade, DLC...) keeps its own text instead of a made-up level.
            local lr = (reason or ""):lower()
            e.fameNeeded = nil
            if not avail and (lr:find("fame") or lr:find("reputation")) then
                e.fameNeeded = tonumber(lr:match("(%d+)"))
            end
            if not avail and not availLogged[e.id] then
                log(e.id .. " is locked: " .. tostring(reason))
                availLogged[e.id] = true
            end
        end
    end
    lastAvailCheck = os.clock()
end

-- Re-run the unlock check every AVAIL_REFRESH_SECONDS, or at once if the DLC
-- wasn't seen last time but its racing manager is running now (it starts
-- after a save loads, so an owner isn't left with Sport/Race hidden).
local DLC_PROBE_SECONDS = 10
local lastDlcProbe = -1e9
local function availability_due()
    if os.clock() - lastAvailCheck > AVAIL_REFRESH_SECONDS then return true end
    -- Look for a late racing manager only every few seconds: each look is a
    -- full object search, and without the DLC it never finds anything.
    if dlcLogged == false and os.clock() - lastDlcProbe > DLC_PROBE_SECONDS then
        lastDlcProbe = os.clock()
        return first_live("BP_RacingManagerComp_C") ~= nil
    end
    return false
end

-------------------------------------------------------------------------------
-- kits

-- The products (with per-car amounts) for a kit, optionally with extras.
local function kit_lines(kit, withExtras)
    local lines = {}
    if not catalog then return lines end
    for _, e in ipairs(catalog) do
        if e.group == "part" and e.tier == kit and e.perCar > 0 then
            lines[#lines + 1] = { entry = e, perCar = e.perCar }
        end
    end
    if withExtras then
        for _, e in ipairs(catalog) do
            local n = settings.perCar[e.id] or 0
            if n > 0 and e.group ~= "part" then lines[#lines + 1] = { entry = e, perCar = n } end
        end
    end
    return lines
end

local function kit_unlocked(kit)
    local lines = kit_lines(kit, false)
    if #lines == 0 then return false, "" end
    if lines[1].entry.noDlc then return false, kit .. " Needs the Up 2 You DLC" end
    -- Locked: report the highest fame level any of its parts needs.
    local need, other = nil, nil
    for _, l in ipairs(lines) do
        if not l.entry.avail then
            if l.entry.fameNeeded then need = math.max(need or 0, l.entry.fameNeeded)
            else other = other or (l.entry.name .. ": " .. l.entry.reason) end
        end
    end
    if need then return false, kit .. " Unlocks at Fame Level " .. need end
    if other then return false, kit .. " Locked (" .. other .. ")" end
    return true, ""
end

local function builds_in_stock(lines, counts)
    local best = nil
    for _, l in ipairs(lines) do
        local have = usable(counts, l.entry)
        local b = math.floor(have / l.perCar)
        if best == nil or b < best then best = b end
    end
    return best or 0
end

-------------------------------------------------------------------------------
-- workshop supplies, grouped by base item; each group offers its tiers

-- "Wax_Base" / "Wax - Basic" -> group "Wax", tier "Base", base "Wax", label "Basic".
-- Built from the catalogue each time (it is short), in table order, so tiers
-- added by a game update show up without a mod update.
local function supply_groups()
    local list, byKey = {}, {}
    if not catalog then return list end
    for _, e in ipairs(catalog) do
        if e.group == "supply" then
            local key, suffix = e.id:match("^(.+)_([^_]+)$")
            if not key then key, suffix = e.id, "" end
            local base, label = e.name:match("^(.-)%s+%-%s+(.+)$")
            if not base then base, label = e.name, suffix end
            local g = byKey[key]
            if not g then
                g = { key = key, name = base, tiers = {} }
                byKey[key] = g
                list[#list + 1] = g
            end
            g.tiers[#g.tiers + 1] = { suffix = suffix, label = label, entry = e }
        end
    end
    -- Cheapest tier first: the default when nothing is chosen.
    for _, g in ipairs(list) do
        table.sort(g.tiers, function(a, b) return a.entry.price < b.entry.price end)
    end
    return list
end

local function supply_tier(g)
    local want = settings.supplyTier[g.key]
    for _, t in ipairs(g.tiers) do if t.suffix == want then return t end end
    return g.tiers[1]
end

-------------------------------------------------------------------------------
-- purchase jobs (spread over several ticks so big orders don't stall the game)

local job = nil
local status = { text = "", good = true }

-- The game's own UI error sound, played whenever a purchase or auto-stock is
-- refused (the shop plays its cash sound on success; this is the opposite).
-- Loaded with LoadAsset if it isn't in memory yet, never searched for.
local ERROR_SOUND = "/Game/CarDealerSim/Audio/SFX/UI/Error1.Error1"
local errorSound, errorSoundTried = nil, false
local function play_error()
    if not valid(errorSound) then
        errorSound = nil
        if known[ERROR_SOUND] then errorSound = resolve(ERROR_SOUND) end
        if not errorSound and not errorSoundTried then
            errorSoundTried = true
            pcall(function() errorSound = LoadAsset(ERROR_SOUND) end)
            if valid(errorSound) then path_of(errorSound) else errorSound = nil end
            log("error sound " .. (errorSound and "loaded" or "NOT loaded") .. ": " .. ERROR_SOUND)
        end
    end
    if not errorSound then return end
    local ctx = get_economy()
    local lib = resolve("/Script/Engine.Default__GameplayStatics")
    if not ctx or not lib then return end
    pcall(function() lib:PlaySound2D(ctx, errorSound, 1.0, 1.0, 0.0, nil, nil, true) end)
end

local function set_status(text, good, silent)
    status.text, status.good = text, good ~= false
    status.staleOnMoney, status.money = nil, nil
    log(text)
    if good == false and not silent then play_error() end
end

-- Copy a struct value into a plain Lua table (numbers, bools and nested
-- structs only), so it can be handed back to a UFunction as a parameter.
local PLAIN = { IntProperty = true, Int64Property = true, FloatProperty = true, DoubleProperty = true,
    BoolProperty = true, ByteProperty = true, EnumProperty = true }
local function struct_to_table(def, value)
    local t = {}
    pcall(function()
        def:ForEachProperty(function(p)
            local n = p:GetFName():ToString()
            local okT, pt = pcall(function() return p:GetClass():GetFName():ToString() end)
            local okV, v = pcall(function() return value[n] end)
            if not okT or not okV or v == nil then return end
            if PLAIN[pt] then
                t[n] = v
            elseif pt == "StructProperty" then
                local okS, sub = pcall(function() return p:GetStruct() end)
                if okS and sub then t[n] = struct_to_table(sub, v) end
            end
        end)
    end)
    return t
end

local function find_prop(def, prefix)
    local found = nil
    pcall(function()
        def:ForEachProperty(function(p)
            if not found and p:GetFName():ToString():find("^" .. prefix) then found = p end
        end)
    end)
    return found
end

-- Charge like the game's own shop does: SpendMoneyAsTransaction with
-- { Amount, Name = "Buying items: Parts Manager", Date = current in-game date }, so the
-- purchase shows in the game's transaction history. (S_TransactionData's
-- field names are Blueprint-mangled, so they are looked up by prefix.)
local txLogged = false
local function spend_as_transaction(eco, amount, ledger)
    local fn = resolve(path_of(eco:GetClass()) .. ":SpendMoneyAsTransaction")
    if not fn then return false, "no SpendMoneyAsTransaction" end
    local param = find_prop(fn, "TransactionData")
    local def = param and param:GetStruct()
    if not def then return false, "no TransactionData struct" end
    local fAmount, fName, fDate = find_prop(def, "Amount"), find_prop(def, "Name"), find_prop(def, "Date")
    if not fAmount or not fName then return false, "unexpected TransactionData layout" end
    local data = {}
    data[fAmount:GetFName():ToString()] = amount
    -- The bank app's ledger line: says where the purchase came from.
    data[fName:GetFName():ToString()] = FText(ledger or "Buying items: Parts Manager")
    -- Date: S_GameTime { Time, Day }. The bank app shows the day ("Wednesday
    -- 94"), which is the economy's DayCounter; the time of day is left at 0.
    if fDate then
        local okS, dateDef = pcall(function() return fDate:GetStruct() end)
        local fDay = okS and dateDef and find_prop(dateDef, "Day")
        local okD, day = pcall(function() return eco.DayCounter end)
        if fDay and okD and tonumber(day) then
            data[fDate:GetFName():ToString()] = { [fDay:GetFName():ToString()] = tonumber(day) }
        elseif not txLogged then
            log("transaction date: no Day field / DayCounter; date left blank")
        end
    end
    local ok, err = pcall(function() eco:SpendMoneyAsTransaction(data) end)
    if not txLogged then
        txLogged = true
        log("SpendMoneyAsTransaction: " .. (ok and "ok" or ("failed: " .. tostring(err))))
    end
    return ok, err
end

-- Charge the player; falls back to a plain SpendMoney (no transaction record)
-- if the transaction call didn't take effect.
local function charge(eco, amount, ledger)
    if amount <= 0 then return true end
    local before = get_money(eco)
    spend_as_transaction(eco, amount, ledger)
    local after = get_money(eco)
    -- Money went down = paid (whatever the call reported); never charge twice.
    if before and after and after < before then return true end
    if before and after and after >= before then
        pcall(function() eco:SpendMoney(amount) end)
        after = get_money(eco)
        if after and after < before then
            log("charged with SpendMoney fallback")
            return true
        end
    end
    log(string.format("charging %.2f failed (%s -> %s)", amount, tostring(before), tostring(after)))
    return false
end

-- items: list of { entry, qty }
local function start_job(items, label)
    if job then return false, "A purchase is already running." end
    local eco, storage = get_economy(), get_storage()
    if not catalog or not eco or not storage then return false, "Not ready yet: wait for your save to finish loading." end
    local queue, total, count = {}, 0, 0
    for _, it in ipairs(items) do
        if not it.entry.avail then return false, it.entry.name .. " is locked. " .. it.entry.reason end
        if it.qty > 0 then
            queue[#queue + 1] = { entry = it.entry, left = it.qty }
            total = total + it.entry.price * it.qty
            count = count + it.qty
        end
    end
    if count == 0 then return false, "Nothing to buy - it's already in storage." end
    local money = get_money(eco) or 0
    if money < total then return false, "Not enough money: need " .. money_text(total) .. ", have " .. money_text(money) .. "." end
    local free = get_free_space(storage)
    if free and free < count then
        return false, string.format("Not enough storage space: %s item(s) to add, %s free.", num_text(count), num_text(free))
    end
    job = { label = label, queue = queue, added = 0, cost = 0, total = count }
    set_status(string.format("%s: buying %s item(s)...", label, num_text(count)), true)
    return true
end

local function finish_job(full)
    local eco = get_economy()
    local paid = eco and charge(eco, job.cost)
    -- Fuses are bought in packs of FUSES_PER_PACK: say so, not "parts".
    local packs, supplies = job.fusePacks or 0, job.supplies or 0
    local parts = job.added - packs - supplies
    local bits = {}
    if parts > 0 then bits[#bits + 1] = num_text(parts) .. " part(s)" end
    if packs > 0 then
        bits[#bits + 1] = string.format("%s fuse pack(s) (%s fuses)", num_text(packs), num_text(packs * FUSES_PER_PACK))
    end
    -- One supply bought on its own reads "added 10 to storage" ("10 workshop
    -- supplies" reads like ten different ones). Mixed buys keep the noun.
    if supplies > 0 then
        bits[#bits + 1] = (parts == 0 and packs == 0 and job.oneSupply) and num_text(supplies) or (num_text(supplies) .. " workshop supplies")
    end
    local what = #bits > 0 and table.concat(bits, " and ") or "nothing"
    local msg = string.format("%s: added %s to storage for %s.", job.label, what, money_text(job.cost))
    -- The Report a Bug pointer only when a failed add isn't already giving it:
    -- both together on a long mixed-buy line overflow STATUS's two lines.
    if not paid then msg = msg .. (job.error and " Couldn't charge you for it." or " Couldn't charge you for it. Report a Bug sends us the details.") end
    if full then msg = msg .. " Storage is full." end
    if job.error then msg = msg .. " " .. job.error end
    set_status(msg, not full and not job.error and paid)
    job = nil
end

local function job_step()
    local storage = get_storage()
    if not storage then finish_job(false) return end
    local adds = ADDS_PER_TICK
    while adds > 0 and #job.queue > 0 do
        local q = job.queue[1]
        local cls = resolve(q.entry.clsPath)
        if not cls then
            table.remove(job.queue, 1)
        else
            -- One table per out-parameter (Success, OutputPin); see out_field.
            local out, out2 = {}, {}
            local ok, err = pcall(function() storage:AddItemByClass(cls, false, out, out2) end)
            if not ok then
                log("AddItemByClass failed for " .. q.entry.id .. ": " .. tostring(err))
                job.error = "Couldn't add " .. q.entry.name .. " to storage. Report a Bug sends us the details."
                finish_job(false)
                return
            end
            if not out_field("Success", out, out2) then
                finish_job(true)
                return
            end
            job.added = job.added + 1
            -- Fuse packs by ProductID ("Fusepack<amps>", as fuse_stock finds them):
            -- the old group test counted none of them in the 1.0 run ("added 75 part(s)").
            if (q.entry.id or ""):match("^Fusepack%d+$") then job.fusePacks = (job.fusePacks or 0) + 1 end
            if q.entry.group == "supply" then job.supplies = (job.supplies or 0) + 1 end
            job.cost = job.cost + q.entry.price
            q.left = q.left - 1
            if q.left <= 0 then table.remove(job.queue, 1) end
            adds = adds - 1
        end
    end
    if #job.queue == 0 then finish_job(false) end
end

local function buy_builds()
    local items = {}
    for _, l in ipairs(kit_lines(settings.kit, settings.extras)) do
        items[#items + 1] = { entry = l.entry, qty = l.perCar * settings.builds }
    end
    local ok, err = start_job(items, string.format("%d %s build(s)", settings.builds, settings.kit))
    if not ok then set_status(err, false) status.staleOnMoney = true end
end

-- Auto-stock: top every line of the chosen kit up to target builds.
-- It waits until a loaded world has settled: the economy exists from the
-- main menu (money reads $500 until the save loads) and storage fills in
-- during loading, so buying straight away would see empty storage and too
-- little money. Settled = the same world's storage seen for a minute and its
-- item total unchanged since the previous check.
local lastAutoCheck = -1e9
local AUTO_SETTLE_SECONDS = 60
local AUTO_KITS = { "Stock", "Sport", "Race" }
local MONEY_FLOORS = { 0, 10000, 50000, 100000, 250000, 500000, 1000000, 2500000, 5000000, 10000000 }
local autoWorld = { path = nil, since = 0, total = nil }
local lastAutoWarning = nil
-- Auto-stock warnings: the text updates whenever it changes (amounts move as
-- stock changes), but the error sound plays once per KIND of problem -- the
-- message with its numbers taken out -- until auto-stock next has nothing to do
-- or buys something.
local lastAutoKind = nil
local queue_alert   -- (defined with the alerts, further down)

local function auto_warn(msg, reason)
    local kind = msg:gsub("[%$%d][%d,%.]*", "#")
    if msg == lastAutoWarning then return end
    lastAutoWarning = msg
    local fresh = kind ~= lastAutoKind
    set_status(msg, false, not fresh)
    -- The sound plays even with the app closed, so say why on the HUD too.
    if fresh and queue_alert then
        queue_alert("AUTO-STOCK CAN'T BUY", reason .. " Auto-stock tries again every 30 seconds.")
    end
    lastAutoKind = kind
end

-- Paused after a save loads (when settings.pauseOnLoad): the switches keep
-- their state, but nothing is bought until the player clicks any Auto button.
local autoPaused = false

-- Fuel Delivery's functions live in this table (filled in further down, with
-- the hub code); declared here so auto-stock can call Auto Fuel.
local Hub = {}

local function any_auto_configured()
    if settings.fuseOn or settings.supplyOn or settings.fuelOn then return true end
    for _, k in ipairs(AUTO_KITS) do if settings.autoOn[k] then return true end end
    return false
end
local function any_auto() return any_auto_configured() and not autoPaused end

-- Fuses: the shop sells packs of 3 (Fusepack<amps>); opened packs leave loose
-- fuses (Fuse<amps>). Stock of a size = loose + 3 per unopened pack.
local FUSE_SIZES = { 5, 10, 15, 20, 25, 30, 40, 50, 60 }
local function fuse_stock(counts)
    local list = {}
    for _, a in ipairs(FUSE_SIZES) do
        local pack, loose = catalogById["Fusepack" .. a], catalogById["Fuse" .. a]
        if pack then
            local have = usable(counts, pack) * FUSES_PER_PACK + (loose and usable(counts, loose) or 0)
            list[#list + 1] = { amps = a, pack = pack, have = have }
        end
    end
    return list
end

-- Notices a newly loaded save (run every second, so the pause alert appears
-- as soon as the world is ready). Returns the storage once the current
-- world is known, or nil while loading / in the main menu / just switched.
-- The status line belongs to the save it was written in: a different save (or
-- the menu) has its own storage object, so a change of storage clears it.
local statusWorld = nil
local function clear_status_on_new_world(storage)
    local sp = storage and path_of(storage) or nil
    if sp ~= statusWorld then
        if statusWorld then
            status.text, status.good = "", true
            lastAutoWarning, lastAutoKind = nil, nil
        end
        statusWorld = sp
    end
end

local function watch_world()
    local storage = get_storage()
    if not storage then autoWorld.path = nil return nil end
    -- The economy reports Loaded = true once a save has finished loading
    -- (the main menu has a world and storage too, with $500 and no parts).
    local eco = get_economy()
    local okL, loaded = pcall(function() return eco.Loaded end)
    if not eco or not okL or loaded ~= true then autoWorld.path = nil return nil end
    local sp = path_of(storage)
    if sp ~= autoWorld.path then
        clear_status_on_new_world(storage)
        autoWorld.path, autoWorld.since, autoWorld.total, autoWorld.settled = sp, os.clock(), nil, false
        -- A pause belongs to the save it was made in (new-career or pause-on-load).
        autoPaused = false
        -- A save was just loaded (possibly a different career): pause.
        if settings.pauseOnLoad and any_auto() then
            autoPaused = true
            set_status("Auto-stock paused: a save was loaded. Click any Auto button to resume it for this save.", false)
            if queue_alert then
                queue_alert("AUTO-STOCK PAUSED", "A save was loaded, so auto-stock is paused in case it's a different career. "
                    .. "To resume, open Parts Manager and click any Auto button.")
            end
        end
        return nil
    end
    return storage
end

local function auto_stock()
    lastAutoCheck = os.clock()
    if job or not any_auto() or not catalog then return end
    local storage = watch_world()
    if not storage then return end
    local counts = count_storage(storage)
    if not autoWorld.settled then
        local total = 0
        for _, c in pairs(counts) do total = total + c.ready + c.repair end
        local stable = autoWorld.total == total
        autoWorld.total = total
        if os.clock() - autoWorld.since < AUTO_SETTLE_SECONDS or not stable then return end
        autoWorld.settled = true
        log("auto-stock: world settled, checking storage")
        -- A brand-new career (day 1 or earlier, empty storage, no reputation XP): never spend a
        -- new player's money unasked. Pause for this save, loudly. (Saves
        -- carry no career ID, so this is the one case that can be told apart.)
        local eco = get_economy()
        local okD, day = pcall(function() return eco.DayCounter end)
        day = okD and tonumber(day) or nil
        local okR, rep = pcall(function() return eco.ReputationExperience end)
        rep = okR and tonumber(rep) or nil
        log("auto-stock: day " .. tostring(day) .. ", rep XP " .. tostring(rep) .. ", " .. total .. " item(s) in storage")
        -- Reputation too: a day-1 save that has played (or been given XP) is not new.
        if day and day <= 1 and total == 0 and rep == 0 then
            autoPaused = true
            set_status("New career: auto-stock is paused for this save. Click any Auto button to start it.", false)
            if queue_alert then
                queue_alert("NEW CAREER: AUTO-STOCK PAUSED", "This looks like a brand-new career, so nothing has been bought. "
                    .. "To start auto-stock, open Parts Manager and click any Auto button.")
            end
            return
        end
    end
    -- Auto Fuel first: it isn't a storage purchase, so it runs on its own.
    if settings.fuelOn then Hub.auto_fuel() end
    -- Total wanted per product across every switched-on, unlocked kit. Body
    -- parts and consumables (when "Body & Consumables" is on) are needed by
    -- every car whatever its grade, so their targets add up across kits.
    local wanted, order = {}, {}
    local function want(e, n)
        if not wanted[e.id] then wanted[e.id] = { entry = e, qty = 0 } order[#order + 1] = e.id end
        wanted[e.id].qty = wanted[e.id].qty + n
    end
    for _, k in ipairs(AUTO_KITS) do
        if settings.autoOn[k] and (k == "Stock" or kit_unlocked(k)) then
            for _, l in ipairs(kit_lines(k, settings.extras)) do
                want(l.entry, l.perCar * settings.autoTarget[k])
            end
        end
    end
    local items = {}
    for _, id in ipairs(order) do
        local w = wanted[id]
        local missing = w.qty - usable(counts, w.entry)
        -- Locked parts (early-game progression) are skipped, not fatal.
        if missing > 0 and w.entry.avail then items[#items + 1] = { entry = w.entry, qty = missing } end
    end
    -- Fuses: enough packs to bring every size up to the target.
    if settings.fuseOn then
        for _, f in ipairs(fuse_stock(counts)) do
            local short = settings.fuseTarget - f.have
            if short > 0 and f.pack.avail then
                items[#items + 1] = { entry = f.pack, qty = math.ceil(short / FUSES_PER_PACK) }
            end
        end
    end
    -- Workshop supplies: the chosen tier of each, topped up to the target.
    if settings.supplyOn and settings.supplyTarget > 0 then
        for _, g in ipairs(supply_groups()) do
            local t = supply_tier(g)
            local short = settings.supplyTarget - usable(counts, t.entry)
            if short > 0 and t.entry.avail then items[#items + 1] = { entry = t.entry, qty = short } end
        end
    end
    if #items == 0 then lastAutoWarning = nil lastAutoKind = nil return end
    -- Money floor: never let auto-stock take the balance below it.
    if settings.moneyFloor > 0 then
        local cost = 0
        for _, it in ipairs(items) do cost = cost + it.entry.price * it.qty end
        local eco = get_economy()
        local money = eco and get_money(eco) or 0
        if money - cost < settings.moneyFloor then
            local reason = string.format("Buying %s would take your balance below %s (Keep Balance Above).",
                money_text(cost), money_text(settings.moneyFloor))
            auto_warn("Auto-stock can't buy. " .. reason, reason)
            return
        end
    end
    local ok, err = start_job(items, "Auto-stock")
    -- Not enough money / space: stay on, warn once, and try again next check.
    if ok then lastAutoKind = nil else auto_warn("Auto-stock can't buy. " .. err, err) end
end

-------------------------------------------------------------------------------
-- Gas Pump Hub: refill the dealership's three underground tanks at the gas
-- station's price, skipping the drive with the mobile tank (feature request
-- #11; spirit-of-the-game ruling: needs a mobile tank you own, standard fuel
-- price, no fee). Levels are in gallons (MaxFuel 265 at the hub's first level).
-- One table (declared above auto-stock), not top-level locals: the file is at
-- Lua's 200-local limit.

Hub.HUB_SETTLE_SECONDS = 60     -- a hub loads its save's levels late: wait this long
Hub.FUEL_PRICE_FALLBACK = 3.07  -- Regular on build 25989974, if no pump widget is loaded
Hub.PUMP_WIDGET_CLASS = "/Game/CarDealerSim/Mechanics/RepairZone/Refuel/WBP_FuelWidget.WBP_FuelWidget_C"
Hub.HUB_STEPS = { 10, 25, 50, 100 }   -- percent of a tank; 100 = fill
Hub.hubSeen = { path = nil, since = 0 }
Hub.hubBase = nil               -- SetFuel/GetFuel index of Tank #1 (0 or 1), learned on first write
Hub.tankerOwned = {}            -- world (storage path) -> true once an owned mobile tank was seen
Hub.priceLogged = nil

function Hub.get_hub() return first_live("BP_UndergroundTankSystem_C") end

-- The pump panels hold the price as FuelPrice; their class defaults carry it
-- too, so no panel needs to be open. Falls back to the known price.
function Hub.fuel_price()
    for _, cls in ipairs({ "WBP_FuelDispenserWidget_C", "WBP_FuelWidget_C" }) do
        local ok, all = pcall(function() return FindAllOf(cls) end)
        for _, o in ipairs((ok and all) or {}) do
            local v = nil
            if valid(o) then pcall(function() v = tonumber(o.FuelPrice) end) end
            if v and v > 0 then
                if Hub.priceLogged ~= v then
                    -- The class path, so a later build can load it without a pump visit.
                    local cp = "?"
                    pcall(function() cp = path_of(o:GetClass()) or "?" end)
                    log(string.format("fuel price %.2f/gal (from %s, class %s)", v, cls, cp))
                    Hub.priceLogged = v
                end
                return v, true
            end
        end
    end
    -- No pump panel made yet this session: load the car pump panel's class
    -- (path logged on build 25989974) and read its default. Once per session,
    -- only in the game world (not the menu), and only if it gives a price.
    if not Hub.classTried then
        local pc = first_live("BP_PlayerController_C")
        local p = pc and path_of(pc) or ""
        if p ~= "" and not p:find("MenuMap", 1, true) and type(LoadAsset) == "function" then
            Hub.classTried = true
            local cls = nil
            pcall(function() cls = LoadAsset(Hub.PUMP_WIDGET_CLASS) end)
            local cdo = nil
            if valid(cls) then pcall(function() cdo = cls:GetCDO() end) end
            local v = nil
            if valid(cdo) then pcall(function() v = tonumber(cdo.FuelPrice) end) end
            log("pump widget class default: " .. (v and string.format("FuelPrice %.2f", v) or "not readable"))
            if v and v > 0 then Hub.classPrice = v end
        end
    end
    if Hub.classPrice then return Hub.classPrice, true end
    if Hub.priceLogged ~= false then log("fuel price: no pump widget loaded; using " .. Hub.FUEL_PRICE_FALLBACK) Hub.priceLogged = false end
    return Hub.FUEL_PRICE_FALLBACK, false
end

function Hub.tanker_owned()
    local w = statusWorld or "?"
    if Hub.tankerOwned[w] then return true end
    local ok, all = pcall(function() return FindAllOf("BP_MobileTank_C") end)
    for _, o in ipairs((ok and all) or {}) do
        if valid(o) and not (path_of(o) or ""):find("Default__", 1, true) then
            local okO, owned = pcall(function() return o.PlayerOwned end)
            if okO and owned == true then Hub.tankerOwned[w] = true return true end
        end
    end
    return false
end

-- The Gas Pump Hub's upgrade level (0-3), from the game's own "at least
-- level N" check on its upgrade type. The game unlocks one underground tank
-- per level, but the hub reports a capacity for all three even when they're
-- locked, so the level decides which tanks are real. nil if it can't be read
-- (then no tank is offered).
Hub.HUB_UPGRADE_TYPE = 5   -- the Gas Pump Hub's upgrade type (6 is the Underground Garage)
function Hub.hub_level()
    -- Asked about once a second (hub watch, open page): re-read every 5 s.
    if Hub.levelAt and os.clock() - Hub.levelAt < 5 then return Hub.levelCached end
    -- Every exit caches what it returns (an early return once cached nil for
    -- 5 s and made the tab flicker locked).
    local function done(v) Hub.levelAt, Hub.levelCached = os.clock(), v return v end
    local us = first_live("BP_UpgradeSystem_C")
    if not us then return done(nil) end
    local level = 0
    for l = 1, 3 do
        local out = {}
        local ok = pcall(function() us:Condition_UpgradeLevel(Hub.HUB_UPGRADE_TYPE, l, out) end)
        if not ok then return done(level > 0 and level or nil) end
        if out.Result ~= true then break end
        level = l
    end
    if Hub.levelLogged ~= level then log("gas pump hub level " .. level) Hub.levelLogged = level end
    return done(level)
end

-- Each tank's fuel and capacity; a tank above the hub's level is locked
-- (capacity 0 here, so nothing is offered, charged or counted for it).
function Hub.tank_levels(hub)
    local t = {}
    local level = Hub.hub_level() or 0
    for i = 1, 3 do
        local f, m = nil, nil
        pcall(function() f = tonumber(hub["Fuel" .. i]) end)
        pcall(function() m = tonumber(hub["MaxFuel" .. i]) end)
        local locked = i > level
        t[i] = { fuel = locked and 0 or (f or 0), max = locked and 0 or (m or 0), locked = locked }
    end
    return t, level
end

-- Whether the hub can be refilled now; nil + the reason if not.
function Hub.hub_state()
    local hub = Hub.get_hub()
    if not hub then
        Hub.hubSeen.path = nil
        return nil, "Your Gas Pump Hub isn't loaded: go back to your dealership."
    end
    local p = path_of(hub)
    if p ~= Hub.hubSeen.path then Hub.hubSeen.path, Hub.hubSeen.since = p, os.clock() end
    local level = Hub.hub_level()
    if not level or level < 1 then
        return nil, "Needs the Gas Pump Hub upgrade (Upgrades app on your tablet)."
    end
    if not Hub.tanker_owned() then
        return nil, "Needs your own mobile fuel tank (sold at the gas station)."
    end
    if os.clock() - Hub.hubSeen.since < Hub.HUB_SETTLE_SECONDS then
        return nil, "Reading your tank levels (about a minute)..."
    end
    return hub
end

function Hub.floor_cents(v) return math.floor(v * 100 + 1e-6) / 100 end
function Hub.cents_text(v)
    local c = math.floor(v * 100 + 0.5)
    return "$" .. num_text(math.floor(c / 100)) .. string.format(".%02d", c % 100)
end

-- Gallons to add to each tank for a step: pct of capacity, never past full.
function Hub.hub_adds(levels, tanks, pct)
    local adds, total = {}, 0
    for _, i in ipairs(tanks) do
        local l = levels[i]
        local a = math.max(0, math.min(l.max * pct / 100, l.max - l.fuel))
        if a < 0.05 then a = 0 end
        adds[i] = a
        total = total + a
    end
    return adds, total
end

-- Set one tank through the game's own SetFuel (it updates the gauges), then
-- check which tank actually moved: the first write learns whether the game
-- numbers them from 0 or 1, and puts a wrongly moved tank back.
function Hub.write_tank(hub, tank, value)
    local function read(i) local v = nil pcall(function() v = tonumber(hub["Fuel" .. i]) end) return v or 0 end
    local before = { read(1), read(2), read(3) }
    -- Measured on build 25989974: the game numbers them from 0. Still checked,
    -- in case an update changes it.
    local tries = Hub.hubBase and { Hub.hubBase } or { 0, 1 }
    for _, base in ipairs(tries) do
        local idx = base + tank - 1
        pcall(function() hub:SetFuel(value, idx) end)
        local moved = nil
        for j = 1, 3 do if math.abs(read(j) - before[j]) > 0.001 then moved = j end end
        if moved == tank then
            if Hub.hubBase ~= base then Hub.hubBase = base log("hub tanks are numbered from " .. base) end
            return true, before[tank], read(tank)
        end
        if moved then
            pcall(function() hub:SetFuel(before[moved], idx) end)
            log(string.format("SetFuel(%d) moved tank %d, not %d; put it back", idx, moved, tank))
        end
    end
    -- Fallback: the game's function didn't move it. Write the level directly.
    pcall(function() hub["Fuel" .. tank] = value end)
    local now = read(tank)
    if math.abs(now - before[tank]) > 0.001 then
        log("SetFuel had no effect; wrote Fuel" .. tank .. " directly (gauge updates on the next load)")
        return true, before[tank], now
    end
    return false, before[tank], now
end

-- Auto Fuel: when the three tanks TOGETHER are below 10% of
-- their combined capacity, every unlocked tank is filled to full; never topped up, so
-- it doesn't refill after every car a worker fuels. Waits 3 minutes
-- after the hub loads (its save levels arrive late and read 0 first: a manual
-- fill waits 1, this one spends unattended), and obeys Keep Balance Above.
Hub.AUTO_FUEL_AT = 0.10
Hub.AUTO_FUEL_SETTLE = 180
function Hub.auto_fuel()
    local hub = Hub.hub_state()
    if not hub or os.clock() - Hub.hubSeen.since < Hub.AUTO_FUEL_SETTLE then return end
    local levels = Hub.tank_levels(hub)
    local f, m = 0, 0
    for i = 1, 3 do f, m = f + levels[i].fuel, m + levels[i].max end
    -- Strictly below 10%. Tanks with no capacity
    -- count toward neither total, and hub_adds gives them nothing to fill.
    if m <= 0 or f >= m * Hub.AUTO_FUEL_AT then return end
    local low = { 1, 2, 3 }
    local price = Hub.fuel_price()
    local _, gal = Hub.hub_adds(levels, low, 100)
    local cost = Hub.floor_cents(gal * price)
    local eco = get_economy()
    local money = eco and get_money(eco) or 0
    if settings.moneyFloor > 0 and money - cost < settings.moneyFloor then
        local reason = string.format("Filling the tanks (%s) would take your balance below %s (Keep Balance Above).",
            Hub.cents_text(cost), money_text(settings.moneyFloor))
        auto_warn("Auto Fuel can't buy. " .. reason, reason)
        return
    end
    if money < cost then
        local reason = "Not enough money to fill the tanks: need " .. Hub.cents_text(cost) .. "."
        auto_warn("Auto Fuel can't buy. " .. reason, reason)
        return
    end
    Hub.hub_fill(low, 100, "Auto Fuel")
end

function Hub.hub_fill(tanks, pct, who)
    local hub, why = Hub.hub_state()
    if not hub then set_status(why, false) return end
    local eco = get_economy()
    if not eco then set_status("Not ready yet: wait for your save to finish loading.", false) return end
    local price = Hub.fuel_price()
    local levels = Hub.tank_levels(hub)
    if #tanks == 1 and levels[tanks[1]].locked then
        set_status("Tank #" .. tanks[1] .. " unlocks at Gas Pump Hub level " .. tanks[1] .. ".", false)
        return
    end
    local adds, gal = Hub.hub_adds(levels, tanks, pct)
    local _, fillGal = Hub.hub_adds(levels, tanks, 100)
    if pct < 100 and gal > 0 and gal >= fillGal - 0.05 then
        set_status(string.format("+%d%% would go past full: use Fill (%.1f gal).", pct, fillGal), false)
        return
    end
    if gal <= 0 then set_status(#tanks > 1 and "All tanks are already full." or ("Tank #" .. tanks[1] .. " is already full."), false) return end
    local cost = Hub.floor_cents(gal * price)
    local money = get_money(eco) or 0
    if money < cost then set_status("Not enough money: need " .. Hub.cents_text(cost) .. ", have " .. money_text(money) .. ".", false) status.staleOnMoney = true return end
    local done, added = {}, 0
    for _, i in ipairs(tanks) do
        if adds[i] > 0 then
            local ok, was, now = Hub.write_tank(hub, i, levels[i].fuel + adds[i])
            if not ok then
                for _, d in ipairs(done) do Hub.write_tank(hub, d.tank, d.was) end
                set_status("Couldn't fill Tank #" .. i .. ". Nothing was charged. Report a Bug sends us the details.", false)
                return
            end
            done[#done + 1] = { tank = i, was = was }
            added = added + (now - was)
        end
    end
    local paid = Hub.floor_cents(added * price)
    if not charge(eco, paid, "Fuel delivery: Parts Manager") then
        for _, d in ipairs(done) do Hub.write_tank(hub, d.tank, d.was) end
        set_status("Couldn't charge you, so the fuel was taken back out. Report a Bug sends us the details.", false)
        return
    end
    local which = #tanks > 1 and "your tanks" or ("Tank #" .. tanks[1])
    set_status(string.format("%s: added %.1f gal to %s at %s/gal for %s.", who or "Fuel Delivery", added, which, Hub.cents_text(price), Hub.cents_text(paid)), true)
end

-------------------------------------------------------------------------------
-- UI: an app on the tablet and the computer, built from the game's widgets

local hosts = {}     -- host path -> { kind, iconPath, panelPath, w = {name -> path}, rows = {...} }
local buttons = {}   -- button full name -> { host = host path, action = string }

-- Laid out like the game's Car Part Mart app, but in blue (no game app uses
-- it) so it reads as its own app: blue header and buttons, dark grey body
-- split into section cards, yellow prices. (UMG colours are linear.)
local COLORS = {
    header = { R = 0.012, G = 0.11, B = 0.42, A = 1.0 },
    body = { R = 0.03, G = 0.03, B = 0.03, A = 1.0 },
    card = { R = 0.06, G = 0.065, B = 0.075, A = 1.0 },
    row = { R = 0.06, G = 0.06, B = 0.06, A = 1.0 },
    rowAlt = { R = 0.045, G = 0.045, B = 0.045, A = 1.0 },
    white = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 },
    text = { R = 0.92, G = 0.92, B = 0.92, A = 1.0 },
    dim = { R = 0.55, G = 0.57, B = 0.60, A = 1.0 },
    section = { R = 0.25, G = 0.55, B = 1.0, A = 1.0 },
    price = { R = 1.0, G = 0.68, B = 0.03, A = 1.0 },
    good = { R = 0.25, G = 0.80, B = 0.25, A = 1.0 },
    bad = { R = 1.0, G = 0.30, B = 0.22, A = 1.0 },
    btn = { R = 0.02, G = 0.20, B = 0.70, A = 1.0 },
    btnOff = { R = 0.16, G = 0.16, B = 0.17, A = 1.0 },
    btnDark = { R = 0.005, G = 0.04, B = 0.16, A = 1.0 },
    btnLocked = { R = 0.09, G = 0.09, B = 0.10, A = 1.0 },
    btnFill = { R = 0.62, G = 0.05, B = 0.04, A = 1.0 },   -- Fuel Delivery's Fill button (red)
    -- part grades in the list
    tier = {
        Stock = { R = 0.92, G = 0.92, B = 0.92, A = 1.0 },
        Sport = { R = 0.20, G = 0.85, B = 0.85, A = 1.0 },
        Race = { R = 1.0, G = 0.32, B = 0.25, A = 1.0 },
    },
}

local function umg(kind) return resolve("/Script/UMG." .. kind) end
local widgetCounter = 0
local function new_widget(kind, outer)
    local c = umg(kind)
    if not c then error("UMG class missing: " .. kind) end
    -- Unique names: rows are rebuilt, and a reused name in the same outer
    -- would replace an existing widget.
    widgetCounter = widgetCounter + 1
    local name = string.format("IM_%s_%d_%d", kind, os.time() % 100000, widgetCounter)
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

local function pad(slot, l, t, r, b)
    pcall(function() slot:SetPadding({ Left = l, Top = t, Right = r, Bottom = b }) end)
end
local function fill(slot, weight)
    pcall(function() slot:SetSize({ SizeRule = 1, Value = weight or 1.0 }) end)
end
local function valign(slot, v) pcall(function() slot:SetVerticalAlignment(v) end) end   -- 1 top, 2 center
local function halign(slot, v) pcall(function() slot:SetHorizontalAlignment(v) end) end -- 1 left, 2 center, 3 right

local function make_border(outer, color, l, t, r, b)
    local bd = new_widget("Border", outer)
    pcall(function() bd:SetBrushColor(color) end)
    pcall(function() bd:SetPadding({ Left = l or 0, Top = t or 0, Right = r or 0, Bottom = b or 0 }) end)
    return bd
end

local function finish_button(b)
    pcall(function() b:UpdateVisual() end)
    pcall(function() b:SetInteractable(true) end)
end

-- A button: the game's clickable icon widget (no glyph, no caption) with our
-- own text centred on top of it. The text ignores the mouse, so clicks reach
-- the button underneath. Returns the overlay to place, and a record
-- { b = button path, l = label path } for later restyling.
-- "Auto Fuses: on" -> "Auto Fuses: ", "ON", green. Switch states are shown in
-- capitals, ON green and OFF red; PAUSED stays white on its amber button.
local function split_state(label)
    local name, st = label:match("^(.-: )(%a+)$")
    if st == "on" then return name, "ON", { R = 0.35, G = 1.0, B = 0.35, A = 1.0 } end
    if st == "off" then return name, "OFF", COLORS.bad end
    if st == "paused" then return name, "PAUSED", COLORS.white end
    return label, "", COLORS.white
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
    -- Label in two parts, so a switch's state ("ON" / "OFF") gets its own colour.
    local row = new_widget("HorizontalBox", outer)
    pcall(function() row:SetVisibility(3) end)   -- HitTestInvisible
    local name, state, scol = split_state(label)
    local t = make_text(outer, name, size or 20, COLORS.white)
    local s = make_text(outer, state, size or 20, scol)
    row:AddChildToHorizontalBox(t)
    row:AddChildToHorizontalBox(s)
    local ts = ov:AddChildToOverlay(row)
    halign(ts, 2)
    valign(ts, 2)
    finish_button(b)
    return ov, { b = path_of(b), l = path_of(t), s = path_of(s), row = path_of(row) }
end

local function style_button(rec, label, color)
    if not rec then return end
    if label then
        local name, state, scol = split_state(label)
        set_text(resolve(rec.l), name)
        if rec.s then set_text(resolve(rec.s), state, scol) end
    end
    if color then
        local b = resolve(rec.b)
        if b then pcall(function() set_color(b.BackgroundColor, color) b:UpdateVisual() end) end
    end
end

local function hw(h, name) return resolve(h.w[name]) end

-- The logo: Assets\logo.png in this mod's folder, loaded at runtime with the
-- engine's ImportFileAsTexture2D (no cooked asset needed) and shown in an
-- Image inside a SizeBox. `ctx` is any live object (world context). Returns
-- the SizeBox, or nil (and one log line) if the picture can't be loaded --
-- the app works the same without it.
local LOGO_FILE = MOD_DIR .. "Assets\\logo.png"
local LOGO_ASPECT = 1                   -- the PNG is square (256 x 256)
local LOCK_FILE = MOD_DIR .. "Assets\\lock.png"   -- square padlock for locked kit tabs
local HELP_FILE = MOD_DIR .. "Assets\\help.png"   -- outlined "?" in the card titles' blue
local logoLogged = false

-- A square picture from this mod's folder (like the logo); nil if missing.
local iconsLogged = {}
local function make_icon(ctx, outer, file, size)
    local lib = resolve("/Script/Engine.Default__KismetRenderingLibrary")
    local tex = nil
    local ok = lib and pcall(function() tex = lib:ImportFileAsTexture2D(ctx, file) end)
    if not ok or not valid(tex) then
        if not iconsLogged[file] then log("icon not loaded: " .. file) iconsLogged[file] = true end
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

local function make_logo(ctx, outer, height)
    local lib = resolve("/Script/Engine.Default__KismetRenderingLibrary")
    local tex = nil
    local ok = lib and pcall(function() tex = lib:ImportFileAsTexture2D(ctx, LOGO_FILE) end)
    if not ok or not valid(tex) then
        if not logoLogged then log("logo not loaded: " .. LOGO_FILE) logoLogged = true end
        return nil
    end
    local img = new_widget("Image", outer)
    pcall(function() img:SetBrushFromTexture(tex, false) end)
    pcall(function() img:SetVisibility(3) end)   -- never takes the mouse
    local box = new_widget("SizeBox", outer)
    pcall(function() box:SetHeightOverride(height) end)
    pcall(function() box:SetWidthOverride(math.floor(height * LOGO_ASPECT)) end)
    box:SetContent(img)
    return box
end

-- Adds a button to a horizontal box; its record goes in h.b[name].
local function add_hbutton(h, host, box, name, label, w, action, color, size)
    local ov, rec = make_button(host, h.hostPath, box:GetOuter(), label, w, 44, action, size, color)
    local slot = box:AddChildToHorizontalBox(ov)
    pad(slot, 0, 0, 10, 0)
    valign(slot, 2)
    h.b[name] = rec
    return rec
end

-- Column layout shared by the list header and its rows: text columns fill
-- by weight; the per-part buy controls follow at a fixed width.
local COLUMNS = { { "Part", 2.7 }, { "Price", 0.7 }, { "Per Car", 0.78 }, { "Ready", 0.62 }, { "Needs Repair", 1.2 }, { "Cars' Worth", 1.08 }, { "Carried", 0.85 } }
-- Matches a row's buy controls (- N + Add: about 332) plus the list's scroll bar,
-- so the header columns line up with the rows below them.
local BUY_CONTROLS_WIDTH = 365

-- Per-part car counts for the single-part buy buttons (not saved).
local rowCars = {}

-- (Re)build the parts list rows for the current kit.
local function rebuild_rows(h)
    local list = hw(h, "list")
    local host = resolve(h.hostPath)
    if not list or not host then return end
    pcall(function() list:ClearChildren() end)
    for name, b in pairs(buttons) do
        if b.host == h.hostPath and b.action:match("^row") then buttons[name] = nil end
    end
    h.rows = {}
    local outer = list:GetOuter()
    for i, l in ipairs(kit_lines(settings.kit, settings.extras)) do
        local id = l.entry.id
        local bg = make_border(outer, (i % 2 == 1) and COLORS.row or COLORS.rowAlt, 14, 6, 10, 6)
        local row = new_widget("HorizontalBox", outer)
        bg:SetContent(row)
        local cells = {}
        for c, spec in ipairs(COLUMNS) do
            local color = (c == 1 and COLORS.white) or (c == 2 and COLORS.price) or COLORS.dim
            local t = make_text(outer, "", c == 1 and 20 or 18, color)
            local slot = row:AddChildToHorizontalBox(t)
            fill(slot, spec[2])
            pad(slot, 0, 0, 6, 0)
            valign(slot, 2)
            cells[c] = path_of(t)
        end
        local r = { id = id, perCar = l.perCar, cells = cells, b = {} }
        local function rbutton(name, label, width, action, color)
            local ov, rec = make_button(host, h.hostPath, outer, label, width, 38, action, 18, color)
            local slot = row:AddChildToHorizontalBox(ov)
            pad(slot, 0, 0, 8, 0)
            valign(slot, 2)
            r.b[name] = rec
        end
        rbutton("minus", "-", 40, "rowminus:" .. id, COLORS.btnOff)
        local cars = make_text(outer, "", 20, COLORS.white)
        -- Fixed width, centred, so 1- and 2-digit counts keep the row's buttons lined up.
        pcall(function() cars:SetMinDesiredWidth(36) end)   -- fits "99" (the per-row cap)
        pcall(function() cars:SetJustification(1) end)
        local cs = row:AddChildToHorizontalBox(cars)
        pad(cs, 4, 0, 12, 0)
        valign(cs, 2)
        r.cars = path_of(cars)
        rbutton("plus", "+", 40, "rowplus:" .. id, COLORS.btnOff)
        rbutton("buy", "Add", 215, "rowbuy:" .. id, COLORS.btn)
        local rs = list:AddChild(bg)
        pad(rs, 0, 0, 0, 2)
        h.rows[#h.rows + 1] = r
    end
    h.rowsKey = settings.kit .. (settings.extras and "+" or "-")
end

-- Workshop supplies list: one row per supply (its chosen tier), same look as
-- the parts list. Columns, then the tier and buy buttons at a fixed width.
-- (No Tier column: the Tier button in each row names the tier.)
-- The Tier button fits the longest label, "Extra Durable  >".
local SUPPLY_COLUMNS = { { "Supply", 3.0 }, { "Price", 0.8 }, { "In Storage", 1.0 }, { "Carried", 0.9 } }
local SUPPLY_CONTROLS_WIDTH = 510

local function rebuild_supply_rows(h, groups)
    local list = hw(h, "slist")
    local host = resolve(h.hostPath)
    if not list or not host then return end
    pcall(function() list:ClearChildren() end)
    for name, b in pairs(buttons) do
        if b.host == h.hostPath and b.action:match("^srow") then buttons[name] = nil end
    end
    h.srows = {}
    local outer = list:GetOuter()
    for i, g in ipairs(groups) do
        local bg = make_border(outer, (i % 2 == 1) and COLORS.row or COLORS.rowAlt, 14, 6, 10, 6)
        local row = new_widget("HorizontalBox", outer)
        bg:SetContent(row)
        local cells = {}
        for c, spec in ipairs(SUPPLY_COLUMNS) do
            local color = (c == 1 and COLORS.white) or (c == 2 and COLORS.price) or COLORS.dim
            local t = make_text(outer, "", c == 1 and 20 or 18, color)
            local slot = row:AddChildToHorizontalBox(t)
            fill(slot, spec[2])
            pad(slot, 0, 0, 6, 0)
            valign(slot, 2)
            cells[c] = path_of(t)
        end
        local r = { key = g.key, cells = cells, b = {} }
        local function rbutton(name, label, width, action, color)
            local ov, rec = make_button(host, h.hostPath, outer, label, width, 38, action, 18, color)
            local slot = row:AddChildToHorizontalBox(ov)
            pad(slot, 0, 0, 8, 0)
            valign(slot, 2)
            r.b[name] = rec
        end
        rbutton("tier", "Tier", 240, "srowtier:" .. g.key, COLORS.btnOff)
        if #g.tiers > 1 then
            local tb = resolve(r.b.tier.b)
            if tb then pcall(function() tb:SetToolTipText(FText("Click for the next tier.")) end) end
        end
        rbutton("add", "Add", 240, "srowadd:" .. g.key, COLORS.btn)
        local rs = list:AddChild(bg)
        pad(rs, 0, 0, 0, 2)
        h.srows[#h.srows + 1] = r
    end
    -- Rebuilt when the set of supplies or tiers changes (a game update).
    local key = {}
    for _, g in ipairs(groups) do key[#key + 1] = g.key .. "/" .. #g.tiers end
    h.supplyKey = table.concat(key, ",")
end

-- Help page: { heading or nil, paragraph }. Headings are drawn in the section blue.
local HELP_SECTIONS = {
    { "HOW TO USE", "Parts are bought at store prices and go straight into your warehouse. No delivery truck, no waiting. "
        .. "The tabs at the top switch between the parts kits, Workshop and Fuel Delivery. Hover a ? or an Auto button for a short explanation." },
    { "OVERVIEW", "Your money, levels, free storage, and how many complete cars your stored parts can build." },
    { "BUY COMPLETE CARS", "Pick a kit. Sport and Race need the Up 2 You DLC and unlock with fame; a locked tab shows a padlock, and clicking it says why. "
        .. "Body & Consumables adds a windshield, plate repair kit and fluids per car. Set the number of cars and press Buy: you get that many full sets, whatever is already in storage." },
    { "PARTS", "Every part in the kit, what's in storage, and how many cars it covers. Add buys one part for N cars: brake calipers for 2 cars = 8." },
    { "AUTO-STOCK", "Every 30 seconds, once a save has settled, auto-stock buys whatever is below its target. "
        .. "Auto Stock, Sport and Race keep N complete cars per kit; with Body & Consumables on, each car gets its own fluids, so 5 Stock + 5 Sport = fluids for 10. "
        .. "Auto Fuses keeps N of every fuse size (packs of 3). Auto Supplies keeps N of every workshop supply. "
        .. "Auto Fuel fills every unlocked hub tank when together they drop below 10%. Count Worn Parts decides whether Needs Repair parts count as stock. "
        .. "Short on money or space? It tries again at the next check." },
    { nil, "Keep Balance Above: auto-stock never spends below it; buying by hand isn't limited. A brand-new career starts with auto-stock paused. "
        .. "Playing several careers? Set pause_auto_on_load=1 in settings.txt to pause after every load; any Auto button resumes." },
    { "WORKSHOP SUPPLIES", "Car wash and body shop supplies at store prices. Add buys 10. The Tier button switches tiers once the game has more than Basic." },
    { "FUEL DELIVERY", "Your Gas Pump Hub's tanks: one unlocks per hub level. +10%, +25% and +50% add that much of a tank, Fill tops it up, and the All Tanks row does every unlocked tank. "
        .. "You pay the pump's price per gallon and nothing more. Needs your own mobile fuel tank, with your dealership loaded. Levels take a minute to read after a save loads." },
    { "CARRIED", "In your inventory and car trunks, for reference only. Ready, Needs Repair, Cars' Worth and auto-stock count only your warehouse." },
    { nil, "Per-car amounts for body parts and consumables are in settings.txt in the mod folder (0 skips one)." },
}

local function build_panel(h, host, hostPath)
    local tree = host.WidgetTree
    local switcher = host.ApplicationWidgetSwitcher
    if not valid(tree) or not valid(switcher) then error("host has no app switcher") end
    h.w, h.b = {}, {}

    local root = make_border(tree, COLORS.body, 0, 0, 0, 0)
    local main = new_widget("VerticalBox", tree)
    root:SetContent(main)

    -- blue header bar: title, help, close
    local header = make_border(tree, COLORS.header, 40, 14, 30, 14)
    local top = new_widget("HorizontalBox", tree)
    header:SetContent(top)
    local logo = make_logo(host, tree, 80)
    if logo then
        local ls = top:AddChildToHorizontalBox(logo)
        pad(ls, 0, 0, 16, 0)
        valign(ls, 2)
    end
    -- Title with the version and by-line on a small line under it (beside it,
    -- the by-line ran into the header buttons).
    local titleBox = new_widget("VerticalBox", tree)
    local title = make_text(tree, "PARTS MANAGER", 36, COLORS.white)
    titleBox:AddChildToVerticalBox(title)
    local ver = make_text(tree, "v" .. VERSION .. "  by Luka's Mods", 18, { R = 0.55, G = 0.68, B = 0.95, A = 1.0 })
    pad(titleBox:AddChildToVerticalBox(ver), 2, 0, 0, 0)
    local tslot = top:AddChildToHorizontalBox(titleBox)
    fill(tslot, 1)
    valign(tslot, 2)
    add_hbutton(h, host, top, "bug", "Report a Bug", 210, "bugreport", COLORS.btnDark, 20)
    add_hbutton(h, host, top, "feature", "Request a Feature", 250, "feature", COLORS.btnDark, 20)
    add_hbutton(h, host, top, "help", "Help", 150, "help", COLORS.btnDark, 22)
    add_hbutton(h, host, top, "close", "X", 64, "close", COLORS.btnDark, 30)
    main:AddChildToVerticalBox(header)

    -- body: a column of section cards
    local bodyPad = make_border(tree, COLORS.body, 30, 10, 30, 10)
    local body = new_widget("VerticalBox", tree)
    bodyPad:SetContent(body)
    fill(main:AddChildToVerticalBox(bodyPad), 1)

    -- A card: titled, described section with its own background.
    -- Every card except help is listed in h.cards, so Help can swap them out.
    h.cards, h.wcards = {}, {}
    h.pageCards = h.cards
    h.tips = {}
    -- The help icon: a small outlined "?" in the titles' blue,
    -- not a red eye-catcher. It is still the game's button widget (that gives
    -- the rounded tooltip and the click), with the card's colour as its
    -- background so only Assets\help.png shows; a plain "?" if the PNG is missing.
    local function help_button(box, key, text)
        h.tips[key] = text
        local icon = make_icon(host, tree, HELP_FILE, 24)
        local ov, rec = make_button(host, hostPath, tree, icon and "" or "?", 26, 26, "tip:" .. key, 16,
            icon and COLORS.card or COLORS.btnOff)
        if icon then
            local sl = ov:AddChildToOverlay(icon)
            halign(sl, 2)
            valign(sl, 2)
        end
        local b = resolve(rec.b)
        if b then
            pcall(function() b.Roundness = 13 b:UpdateVisual() end)
            pcall(function() b:SetToolTipText(FText(text)) end)
        end
        local sl = box:AddChildToHorizontalBox(ov)
        pad(sl, 0, 0, 12, 0)
        valign(sl, 2)
    end
    local function card(name, titleText, desc, grow)
        local bd = make_border(tree, COLORS.card, 22, 8, 22, 8)
        local box = new_widget("VerticalBox", tree)
        bd:SetContent(box)
        local slot = body:AddChildToVerticalBox(bd)
        pad(slot, 0, 0, 0, 6)
        if name ~= "helpCard" then h.pageCards[#h.pageCards + 1] = path_of(bd) end
        if grow then fill(slot, 1) end
        if titleText then
            local hdr = new_widget("HorizontalBox", tree)
            local tt = make_text(tree, titleText, 20, COLORS.section)
            local ts = hdr:AddChildToHorizontalBox(tt)
            pad(ts, 0, 0, 16, 0)
            valign(ts, 3)
            -- The description is a "?" icon beside the title: its
            -- tooltip has the game's rounded style, like the Auto buttons'
            -- (a plain text tooltip gets UMG's square box), and a click puts
            -- the same text in STATUS.
            if desc then help_button(hdr, titleText, desc) end
            pad(box:AddChildToVerticalBox(hdr), 0, 0, 0, 4)
        end
        if name then h.w[name] = path_of(bd) end
        return box
    end
    local function add(box, w, t, b)
        local slot = box:AddChildToVerticalBox(w)
        pad(slot, 0, t or 0, 0, b or 0)
        return slot
    end

    -- The page tabs: one slim bar above every page (parts kits, Workshop,
    -- Fuel Delivery). Locked tabs (Sport / Race by fame, Gas Pump Hub without a mobile tank)
    -- are dimmed with a padlock; refresh_panel styles them.
    local function tabs_row(box, prefix)
        local row = new_widget("HorizontalBox", tree)
        for _, k in ipairs({ "Stock", "Sport", "Race" }) do
            add_hbutton(h, host, row, prefix .. k, k, 150, "kit:" .. k, COLORS.btnOff, 24)
        end
        add_hbutton(h, host, row, prefix .. "Workshop", "Workshop", 190, "workshop", COLORS.btnOff, 24)
        add_hbutton(h, host, row, prefix .. "Hub", "Fuel Delivery", 240, "gashub", COLORS.btnOff, 24)
        for _, k in ipairs({ "Sport", "Race", "Hub" }) do
            local rec = h.b[prefix .. k]
            local icon = rec and make_icon(host, tree, LOCK_FILE, 20)
            local r = icon and resolve(rec.row)
            if r then
                local sl = r:AddChildToHorizontalBox(icon)
                pad(sl, 8, 0, 0, 0)
                valign(sl, 2)
                rec.lock = path_of(icon)
            end
        end
        if box then add(box, row, 0, 6) end
        return row
    end

    tabs_row(body, "kit")

    -- help: a page of its own, shown instead of the other cards
    local help = card("helpCard", nil, nil, true)   -- its title scrolls with the text
    -- scrolls, so the text never runs past the card on a small screen
    local helpScroll = new_widget("ScrollBox", tree)
    local helpCol = new_widget("VerticalBox", tree)
    pcall(function() helpScroll:AddChild(helpCol) end)
    for i, sec in ipairs(HELP_SECTIONS) do
        if sec[1] then
            pad(helpCol:AddChildToVerticalBox(make_text(tree, sec[1], 18, COLORS.section)), 0, i > 1 and 14 or 0, 0, 2)
        end
        local para = make_text(tree, sec[2], 18, COLORS.text)
        pcall(function() para:SetAutoWrapText(true) end)
        pad(helpCol:AddChildToVerticalBox(para), 0, (sec[1] or i == 1) and 0 or 14, 24, 0)
    end
    fill(help:AddChildToVerticalBox(helpScroll), 1)
    pcall(function() resolve(h.w.helpCard):SetVisibility(1) end)
    h.page = "main"

    -- overview
    local ov = card(nil, "OVERVIEW", "Your money, levels, free storage, and how many complete cars your stored parts can build.")
    local ovRow = new_widget("HorizontalBox", tree)
    local info = make_text(tree, "", 20, COLORS.dim)
    h.w.info = path_of(info)
    local is = ovRow:AddChildToHorizontalBox(info)
    valign(is, 2)
    add(ov, ovRow)

    -- buy complete cars
    local cc = card(nil, "BUY COMPLETE CARS", "Every part of a kit for N cars, in one go.")
    -- One row: Body & Consumables, the car count, the price and Buy (the
    -- tabs moved to the bar above, to give the parts table its rows back).
    local brow = new_widget("HorizontalBox", tree)
    add_hbutton(h, host, brow, "extras", "Body & Consumables: off", 390, "extras", COLORS.btnOff, 20)
    local blabel = make_text(tree, "Cars", 24, COLORS.white)
    local bls = brow:AddChildToHorizontalBox(blabel)
    pad(bls, 0, 0, 16, 0)
    valign(bls, 2)
    add_hbutton(h, host, brow, "bm10", "-10", 64, "builds:-10", COLORS.btnOff)
    add_hbutton(h, host, brow, "bm1", "-1", 52, "builds:-1", COLORS.btnOff)
    local bval = make_text(tree, "", 28, COLORS.white)
    h.w.builds = path_of(bval)
    local bvs = brow:AddChildToHorizontalBox(bval)
    pad(bvs, 4, 0, 14, 0)
    valign(bvs, 2)
    add_hbutton(h, host, brow, "bp1", "+1", 52, "builds:1", COLORS.btnOff)
    add_hbutton(h, host, brow, "bp10", "+10", 64, "builds:10", COLORS.btnOff)
    local instock = make_text(tree, "", 18, COLORS.dim)
    h.w.instock = path_of(instock)
    local iss = brow:AddChildToHorizontalBox(instock)
    pad(iss, 10, 0, 0, 0)
    valign(iss, 2)
    local total = make_text(tree, "", 28, COLORS.price)
    h.w.total = path_of(total)
    local tts = brow:AddChildToHorizontalBox(total)
    fill(tts, 1)
    pad(tts, 20, 0, 16, 0)
    valign(tts, 2)
    halign(tts, 3)
    add_hbutton(h, host, brow, "buy", "Buy", 360, "buy", COLORS.btn, 22)
    add(cc, brow)

    -- parts list
    -- Kept to two STATUS lines (the bar is two lines tall).
    local pl = card(nil, "PARTS", "Ready: stored at 100%. Needs Repair: stored below 100%. Cars' Worth: cars covered. "
        .. "Carried: inventory and trunks, for reference. Add buys one part for N cars.", true)
    local headBg = make_border(tree, COLORS.header, 14, 6, 10, 6)
    local head = new_widget("HorizontalBox", tree)
    headBg:SetContent(head)
    for _, spec in ipairs(COLUMNS) do
        local t = make_text(tree, spec[1], 18, COLORS.white)
        local slot = head:AddChildToHorizontalBox(t)
        fill(slot, spec[2])
        pad(slot, 0, 0, 6, 0)
    end
    local buyHead = make_text(tree, "Buy One Part for N Cars", 18, COLORS.white)
    pcall(function() buyHead:SetMinDesiredWidth(BUY_CONTROLS_WIDTH) end)
    head:AddChildToHorizontalBox(buyHead)
    add(pl, headBg, 0, 2)
    local list = new_widget("ScrollBox", tree)
    h.w.list = path_of(list)
    fill(pl:AddChildToVerticalBox(list), 1)

    -- auto-stock: one card for everything automatic, a 3 x 3 grid of equal
    -- columns: kits / fuses, supplies, fuel / worn, floor.
    -- Each switch explains itself in a tooltip on its button.
    local au = card(nil, "AUTO-STOCK", "Every 30 seconds, anything switched on here that's below its target is topped up, at store prices.")
    local function tip(rec, text)
        local b = rec and resolve(rec.b)
        if b then pcall(function() b:SetToolTipText(FText(text)) end) end
    end
    local COL = 540
    local function group(row, name, label, action, minus, plus, valueName, tipText, width)
        local box = new_widget("SizeBox", tree)
        pcall(function() box:SetWidthOverride(COL) end)
        local g = new_widget("HorizontalBox", tree)
        box:SetContent(g)
        add_hbutton(h, host, g, name, label, width or 270, action, COLORS.btnOff, 20)
        tip(h.b[name], tipText)
        if minus then
            add_hbutton(h, host, g, name .. "Minus", "-", 44, minus, COLORS.btnOff)
            local v = make_text(tree, "", 24, COLORS.white)
            pcall(function() v:SetMinDesiredWidth(64) end)
            pcall(function() v:SetJustification(1) end)
            h.w[valueName] = path_of(v)
            local vs = g:AddChildToHorizontalBox(v)
            pad(vs, 0, 0, 10, 0)
            valign(vs, 2)
            add_hbutton(h, host, g, name .. "Plus", "+", 44, plus, COLORS.btnOff)
        end
        local gs = row:AddChildToHorizontalBox(box)
        valign(gs, 2)
        return box
    end
    -- Row 1: kits. Sport / Race columns are hidden until unlocked.
    local row1 = new_widget("HorizontalBox", tree)
    for _, k in ipairs(AUTO_KITS) do
        local box = group(row1, "auto" .. k, "Auto " .. k .. ": off", "autokit:" .. k,
            "autotarget:" .. k .. ":-1", "autotarget:" .. k .. ":1", "target" .. k,
            "Keeps N complete " .. k .. " cars' worth of parts in storage.")
        h.w["autoGroup" .. k] = path_of(box)
    end
    add(au, row1, 0, 4)
    -- Row 2: fuses, workshop supplies, fuel.
    local row2 = new_widget("HorizontalBox", tree)
    group(row2, "autoFuses", "Auto Fuses: off", "autofuses", "fusetarget:-3", "fusetarget:3", "fuseTarget",
        "Keeps N of every fuse size, counting 3 per unopened pack. Buys packs of 3.")
    group(row2, "autoSupplies", "Auto Supplies: off", "autosupplies", "supplytarget:-" .. SUPPLY_STEP, "supplytarget:" .. SUPPLY_STEP, "supplyTarget",
        "Keeps N of every workshop supply, in the tier picked on the Workshop page.")
    group(row2, "autoFuel", "Auto Fuel: off", "autofuel", nil, nil, nil,
        "When your unlocked hub tanks together drop below 10%, fills them all at the pump's price. Needs your own mobile fuel tank.")
    add(au, row2, 0, 4)
    -- Row 3: what counts as stock, and the money floor.
    local row3 = new_widget("HorizontalBox", tree)
    group(row3, "worn", "Count Worn Parts: on", "worn", nil, nil, nil,
        "On: Needs Repair parts count as stock and aren't replaced. Off: only Ready parts count.",
        360)   -- no -/+ beside it, so it can be wider (270 clipped its label)
    local fbox = new_widget("SizeBox", tree)
    pcall(function() fbox:SetWidthOverride(COL) end)
    local floorRow = new_widget("HorizontalBox", tree)
    fbox:SetContent(floorRow)
    local flabel = make_text(tree, "Keep Balance Above", 20, COLORS.dim)
    local fls0 = floorRow:AddChildToHorizontalBox(flabel)
    pad(fls0, 0, 0, 8, 0)
    valign(fls0, 2)
    help_button(floorRow, "Keep Balance Above", "Auto-stock never spends below this. Buying by hand isn't limited.")
    add_hbutton(h, host, floorRow, "floorDown", "-", 44, "floor:-1", COLORS.btnOff)
    local floorVal = make_text(tree, "", 22, COLORS.price)
    h.w.floor = path_of(floorVal)
    local fvs0 = floorRow:AddChildToHorizontalBox(floorVal)
    pad(fvs0, 2, 0, 12, 0)
    valign(fvs0, 2)
    add_hbutton(h, host, floorRow, "floorUp", "+", 44, "floor:1", COLORS.btnOff)
    valign(row3:AddChildToHorizontalBox(fbox), 2)
    add(au, row3)

    -- Workshop page (hidden until Workshop is pressed): supplies.
    h.pageCards = h.wcards
    local ws = card(nil, "WORKSHOP SUPPLIES", "Car wash and body shop supplies at store prices. Add buys " .. SUPPLY_PACK
        .. ". Carried: inventory and trunks, for reference.", true)
    local sheadBg = make_border(tree, COLORS.header, 14, 6, 10, 6)
    local shead = new_widget("HorizontalBox", tree)
    sheadBg:SetContent(shead)
    for _, spec in ipairs(SUPPLY_COLUMNS) do
        local t = make_text(tree, spec[1], 18, COLORS.white)
        local slot = shead:AddChildToHorizontalBox(t)
        fill(slot, spec[2])
        pad(slot, 0, 0, 6, 0)
    end
    local sbuyHead = make_text(tree, "Tier and Buy", 18, COLORS.white)
    pcall(function() sbuyHead:SetMinDesiredWidth(SUPPLY_CONTROLS_WIDTH) end)
    shead:AddChildToHorizontalBox(sbuyHead)
    add(ws, sheadBg, 0, 2)
    local slist = new_widget("ScrollBox", tree)
    h.w.slist = path_of(slist)
    fill(ws:AddChildToVerticalBox(slist), 1)

    for _, p in ipairs(h.wcards) do pcall(function() resolve(p):SetVisibility(1) end) end

    -- Gas Pump Hub page (its own tab, locked without a mobile tank).
    h.hcards = {}
    h.pageCards = h.hcards
    -- Gas Pump Hub: one row per tank (name, level bar, gallons, refill steps)
    -- and a row for all three. Buttons carry the cost; refreshed every second.
    local hc = card(nil, "FUEL DELIVERY", "Fills your Gas Pump Hub's tanks at the pump's price. Skips the drive, not the cost.", true)
    local hinfo = make_text(tree, "", 18, COLORS.dim)
    h.w.hubInfo = path_of(hinfo)
    add(hc, hinfo, 0, 4)
    -- A tank gauge like the game's hub dials: our face (Assets\gauge_face.png)
    -- with our needle (gauge_needle.png, drawn pointing up) on top, turned by
    -- refresh_panel: -135 degrees = empty, +135 = full. Nil if the art is missing.
    local function make_gauge(size)
        local lib = resolve("/Script/Engine.Default__KismetRenderingLibrary")
        local function img(file)
            local tex = nil
            local ok = lib and pcall(function() tex = lib:ImportFileAsTexture2D(host, MOD_DIR .. "Assets\\" .. file) end)
            if not ok or not valid(tex) then log("gauge art not loaded: " .. file) return nil end
            local im = new_widget("Image", tree)
            pcall(function() im:SetBrushFromTexture(tex, false) end)
            pcall(function() im:SetDesiredSizeOverride({ X = size, Y = size }) end)
            pcall(function() im:SetVisibility(3) end)
            return im
        end
        local face, needle = img("gauge_face.png"), img("gauge_needle.png")
        if not face or not needle then return nil end
        -- Overlay slots default to top-left at the image's desired size (a
        -- 32 px brush): fill them, or the gauge draws as a 32 px dot.
        local ov = new_widget("Overlay", tree)
        for _, im in ipairs({ face, needle }) do
            local sl = ov:AddChildToOverlay(im)
            halign(sl, 0)
            valign(sl, 0)
        end
        local box = new_widget("SizeBox", tree)
        pcall(function() box:SetWidthOverride(size) end)
        pcall(function() box:SetHeightOverride(size) end)
        box:SetContent(ov)
        return box, path_of(needle)
    end

    -- All Tanks first, so Fill All is always on screen; then one band per tank
    -- (name over the gauge, stats under it, refill buttons two by two, Fill in
    -- red), in a scroll box so a small screen never cuts one off.
    h.hubRows = {}
    do
        local row = new_widget("HorizontalBox", tree)
        local name = make_text(tree, "All Tanks", 22, COLORS.white)
        pcall(function() name:SetMinDesiredWidth(194) end)
        local ns = row:AddChildToHorizontalBox(name)
        pad(ns, 18, 0, 0, 0)
        valign(ns, 2)
        local lvl = make_text(tree, "", 20, COLORS.dim)
        local lvs = row:AddChildToHorizontalBox(lvl)
        fill(lvs, 1)
        valign(lvs, 2)
        for _, pct in ipairs(Hub.HUB_STEPS) do
            add_hbutton(h, host, row, "huball_" .. pct, pct == 100 and "Fill All" or ("+" .. pct .. "%"), 220, "hub:all:" .. pct, COLORS.btnLocked, 18)
        end
        add(hc, row, 2, 8)
        h.hubRows.all = { level = path_of(lvl) }
    end
    -- The three tanks side by side, like the hub's dials in the game: each a
    -- column with its name, gauge, gallons and percent, and the refill
    -- buttons two by two (Fill in red). Fits the tablet without scrolling.
    local tanksRow = new_widget("HorizontalBox", tree)
    for _, t in ipairs({ 1, 2, 3 }) do
        local band = make_border(tree, (t % 2 == 1) and COLORS.row or COLORS.rowAlt, 12, 10, 12, 10)
        local col = new_widget("VerticalBox", tree)
        band:SetContent(col)
        local r = {}
        halign(col:AddChildToVerticalBox(make_text(tree, "TANK #" .. t, 24, COLORS.white)), 2)
        local gauge, needle = make_gauge(160)
        if gauge then
            local gs = col:AddChildToVerticalBox(gauge)
            halign(gs, 2)
            pad(gs, 0, 4, 0, 4)
            r.needle = needle
        else
            local barBox = new_widget("SizeBox", tree)
            pcall(function() barBox:SetWidthOverride(260) end)
            pcall(function() barBox:SetHeightOverride(22) end)
            local bar = new_widget("ProgressBar", tree)
            barBox:SetContent(bar)
            r.bar = path_of(bar)
            local bs = col:AddChildToVerticalBox(barBox)
            halign(bs, 2)
            pad(bs, 0, 8, 0, 8)
        end
        local stats = new_widget("HorizontalBox", tree)
        local lvl = make_text(tree, "", 18, COLORS.dim)
        r.level = path_of(lvl)
        valign(stats:AddChildToHorizontalBox(lvl), 2)
        local pctText = make_text(tree, "", 24, COLORS.dim)
        r.pct = path_of(pctText)
        local ps = stats:AddChildToHorizontalBox(pctText)
        pad(ps, 12, 0, 0, 0)
        valign(ps, 2)
        local ss = col:AddChildToVerticalBox(stats)
        halign(ss, 2)
        pad(ss, 0, 0, 0, 6)
        for _, pair in ipairs({ { 10, 25 }, { 50, 100 } }) do
            local line = new_widget("HorizontalBox", tree)
            for _, pct in ipairs(pair) do
                add_hbutton(h, host, line, "hub" .. t .. "_" .. pct, pct == 100 and "Fill" or ("+" .. pct .. "%"), 220, "hub:" .. t .. ":" .. pct, COLORS.btnLocked, 20)
            end
            local ls = col:AddChildToVerticalBox(line)
            halign(ls, 2)
            pad(ls, 10, 3, 0, 3)   -- add_hbutton pads 10 on the right; balance it
        end
        local slot = tanksRow:AddChildToHorizontalBox(band)
        fill(slot, 1)
        pad(slot, t == 1 and 0 or 4, 0, t == 3 and 0 or 4, 0)
        h.hubRows[t] = r
    end
    add(hc, tanksRow, 0, 4)
    -- Auto Fuel here too, under the gauges: the same switch as the AUTO-STOCK
    -- grid's (one setting, two buttons).
    local afRow = new_widget("HorizontalBox", tree)
    add_hbutton(h, host, afRow, "autoFuelHub", "Auto Fuel: off", 270, "autofuel", COLORS.btnOff, 20)
    do
        local b = resolve(h.b.autoFuelHub.b)
        if b then pcall(function() b:SetToolTipText(FText("When your unlocked hub tanks together drop below 10%, fills them all at the pump's price. Needs your own mobile fuel tank.")) end) end
    end
    local afNote = make_text(tree, "Fills every unlocked tank when together they drop below 10%.", 18, COLORS.dim)
    local afs = afRow:AddChildToHorizontalBox(afNote)
    pad(afs, 6, 0, 0, 0)
    valign(afs, 2)
    add(hc, afRow, 8, 0)
    for _, p in ipairs(h.hcards) do pcall(function() resolve(p):SetVisibility(1) end) end
    h.pageCards = nil

    -- One STATUS bar, full width under every page, at a FIXED two-line height
    -- so a long message never takes rows from the parts table (a three-line
    -- message once shrank the table to two rows).
    -- A dark console panel (like the cards' inner boxes) inside a card-coloured
    -- bar, so the messages read as a console rather than loose text.
    local msgBox = make_border(tree, COLORS.card, 22, 6, 22, 6)
    local console = make_border(tree, COLORS.body, 14, 4, 14, 4)
    pcall(function() console:SetClipping(1) end)   -- ClipToBounds: a third line is cut, not drawn over
    msgBox:SetContent(console)
    local msgRow = new_widget("HorizontalBox", tree)
    console:SetContent(msgRow)
    local mts = msgRow:AddChildToHorizontalBox(make_text(tree, "STATUS", 18, COLORS.section))
    pad(mts, 0, 0, 14, 0)
    valign(mts, 2)
    local st = make_text(tree, "", 20, COLORS.dim)
    h.w.status = path_of(st)
    pcall(function() st:SetAutoWrapText(true) end)
    local sts = msgRow:AddChildToHorizontalBox(st)
    fill(sts, 1)
    valign(sts, 2)
    local msgSize = new_widget("SizeBox", tree)
    pcall(function() msgSize:SetHeightOverride(84) end)   -- two 20 pt lines (about 58 px) plus both paddings
    msgSize:SetContent(msgBox)
    pad(body:AddChildToVerticalBox(msgSize), 0, 0, 0, 0)

    switcher:AddChild(root)
    h.panelPath = path_of(root)
    h.rowsKey = nil
    log("app screen built on " .. h.kind)
end

local function panel_visible(h)
    local host = resolve(h.hostPath)
    local panel = resolve(h.panelPath)
    if not host or not panel then return false end
    local ok, active = pcall(function() return host.ApplicationWidgetSwitcher:GetActiveWidget() end)
    return ok and valid(active) and path_of(active) == h.panelPath
end

local function refresh_panel(h)
    if not resolve(h.panelPath) then return end
    if not catalog then build_catalog() end
    if availability_due() then refresh_availability() end

    -- Fall back to Stock if the chosen kit is (no longer) unlocked.
    if settings.kit ~= "Stock" and not kit_unlocked(settings.kit) then settings.kit = "Stock" end

    local storage, eco = get_storage(), get_economy()
    clear_status_on_new_world(storage)
    local counts = storage and count_storage(storage) or {}
    local carried = storage and count_carried() or {}
    local money = eco and get_money(eco) or 0
    local fame = get_fame()
    local free = storage and get_free_space(storage)
    local rep = get_rep_level(eco)
    -- A manual "Not enough money" quotes the balance at that moment; once the
    -- balance moves it is out of date, so it clears instead of going stale.
    if status.staleOnMoney and eco then
        if status.money == nil then status.money = money
        elseif money ~= status.money then status.text, status.good, status.staleOnMoney = "", true, nil end
    end
    -- One line, short labels (with the complete-cars counts added below): the
    -- longer two-part line ran past the panel edge with Sport unlocked.
    local infoText = string.format("Balance %s  ·  Reputation %s  ·  Fame %s  ·  Free Storage %s",
        money_text(money), rep and tostring(rep) or "-", fame and tostring(fame) or "-", free and num_text(free) or "-")

    -- Kit tabs: Sport / Race only appear once every part in them is unlocked.
    local lockedNotes = {}
    for _, k in ipairs({ "Stock", "Sport", "Race" }) do
        local rec = h.b["kit" .. k]
        local ok, why = kit_unlocked(k)
        local b = rec and resolve(rec.b)
        -- Sport / Race stay as tabs when locked: dimmed, with a padlock.
        local locked = not ok and k ~= "Stock"
        if b then pcall(function() b:GetParent():SetVisibility(0) end) end
        style_button(rec, nil, locked and COLORS.btnLocked or ((settings.kit == k and h.page == "main") and COLORS.btn or COLORS.btnOff))
        if rec then set_text(resolve(rec.l), k, locked and COLORS.dim or COLORS.white) end
        if rec and rec.lock then pcall(function() resolve(rec.lock):SetVisibility(locked and 3 or 1) end) end
        -- Short form beside the tabs (the tabs themselves now show the lock):
        -- "Sport: Fame Level 6". A click on the tab gives the full reason.
        if not ok and why ~= "" then
            lockedNotes[#lockedNotes + 1] = (why:gsub(" Unlocks at ", ": "):gsub(" Needs the ", ": Needs "))
        end
    end
    set_text(hw(h, "locked"), table.concat(lockedNotes, "      "))
    -- The other pages' copies of the kit tabs, and the Workshop / Gas Pump Hub
    -- tabs on every page (lit on their own page; the hub locked without a tank).
    local hubOk = (Hub.hub_level() or 0) >= 1 and Hub.tanker_owned()
    for _, pre in ipairs({ "kit", "wkit", "hkit" }) do
        if pre ~= "kit" then
            for _, k in ipairs({ "Stock", "Sport", "Race" }) do
                local rec = h.b[pre .. k]
                local ok = k == "Stock" or kit_unlocked(k)
                style_button(rec, nil, ok and COLORS.btnOff or COLORS.btnLocked)
                if rec then set_text(resolve(rec.l), k, ok and COLORS.white or COLORS.dim) end
                if rec and rec.lock then pcall(function() resolve(rec.lock):SetVisibility(ok and 1 or 3) end) end
            end
        end
        style_button(h.b[pre .. "Workshop"], nil, h.page == "workshop" and COLORS.btn or COLORS.btnOff)
        local hr = h.b[pre .. "Hub"]
        style_button(hr, nil, (not hubOk and COLORS.btnLocked) or (h.page == "hub" and COLORS.btn) or COLORS.btnOff)
        if hr then set_text(resolve(hr.l), "Fuel Delivery", hubOk and COLORS.white or COLORS.dim) end
        if hr and hr.lock then pcall(function() resolve(hr.lock):SetVisibility(hubOk and 1 or 3) end) end
    end
    style_button(h.b.extras, settings.extras and "Body & Consumables: on" or "Body & Consumables: off",
        settings.extras and COLORS.btn or COLORS.btnOff)

    if h.rowsKey ~= settings.kit .. (settings.extras and "+" or "-") then rebuild_rows(h) end

    -- How many complete cars storage can build right now, per unlocked kit.
    local canParts = {}
    for _, k in ipairs({ "Stock", "Sport", "Race" }) do
        if k == "Stock" or kit_unlocked(k) then
            canParts[#canParts + 1] = string.format("%s %d", k, builds_in_stock(kit_lines(k, settings.extras), counts))
        end
    end
    set_text(hw(h, "info"), infoText .. "  ·  Complete Cars: " .. table.concat(canParts, ", "))

    local lines = kit_lines(settings.kit, settings.extras)
    local total = 0
    for _, r in ipairs(h.rows or {}) do
        local e = catalogById[r.id]
        if e then
            total = total + r.perCar * settings.builds * e.price
            local ready, repair = stock_of(counts, e)
            local worth = math.floor(usable(counts, e) / r.perCar)
            local cars = rowCars[r.id] or 1
            local qty = cars * r.perCar
            -- Grade shown in the name and its colour; stock names get "Stock".
            local name = e.name
            if e.group == "part" and e.tier == "Stock" then name = "Stock " .. name end
            -- Long names ran into the Price column ("Stock Exhaust Catalytic
            -- Converter"): shorten the long words; the full name is the tooltip.
            local shown = name
            if #shown > 28 then shown = shown:gsub("Catalytic Converter", "Cat. Converter"):gsub("Exhaust ", "Exh. ") end
            local cell = resolve(r.cells[1])
            set_text(cell, shown, COLORS.tier[e.tier] or COLORS.white)
            if shown ~= name and cell then pcall(function() cell:SetToolTipText(FText(name)) end) end
            set_text(resolve(r.cells[2]), money_text(e.price))
            set_text(resolve(r.cells[3]), "x" .. r.perCar)
            set_text(resolve(r.cells[4]), tostring(ready))
            set_text(resolve(r.cells[5]), tostring(repair), repair > 0 and COLORS.price or COLORS.dim)
            set_text(resolve(r.cells[6]), tostring(worth), (worth == 0 and COLORS.bad) or (worth >= settings.builds and COLORS.good) or COLORS.dim)
            local cc = carried[e.clsPath]
            local cn = cc and (cc.ready + cc.repair) or 0
            local cr = cc and cc.repair or 0
            -- Worn carried parts are shown, like the Needs repair column.
            if cr > 0 then
                set_text(resolve(r.cells[7]), string.format("%d (%d Repair)", cn, cr), COLORS.price)
            else
                set_text(resolve(r.cells[7]), tostring(cn), cn > 0 and COLORS.text or COLORS.dim)
            end
            set_text(resolve(r.cars), tostring(cars))
            if e.avail then
                style_button(r.b.buy, string.format("Add %d  (%s)", qty, money_text(qty * e.price)), COLORS.btn)
            else
                style_button(r.b.buy, "Locked", COLORS.btnOff)
            end
        end
    end
    set_text(hw(h, "builds"), tostring(settings.builds))
    set_text(hw(h, "total"), money_text(total), money >= total and COLORS.price or COLORS.bad)
    set_text(hw(h, "instock"), string.format("(%d in Storage)", builds_in_stock(lines, counts)))
    style_button(h.b.buy, job and string.format("Buying %d/%d", job.added, job.total)
        or string.format("Buy %d Complete Car%s", settings.builds, settings.builds == 1 and "" or "s"))
    -- Switches that are on show "paused" (amber) while auto-stock is paused.
    local PAUSED = { R = 0.40, G = 0.22, B = 0.02, A = 1.0 }
    local function auto_label(name, on)
        if on and autoPaused then return name .. ": paused", PAUSED end
        return name .. (on and ": on" or ": off"), on and COLORS.btn or COLORS.btnOff
    end
    for _, k in ipairs(AUTO_KITS) do
        style_button(h.b["auto" .. k], auto_label("Auto " .. k, settings.autoOn[k]))
        set_text(hw(h, "target" .. k), tostring(settings.autoTarget[k]))
        local g = hw(h, "autoGroup" .. k)
        if g then pcall(function() g:SetVisibility(kit_unlocked(k) and 0 or 1) end) end
    end
    style_button(h.b.worn, settings.countWorn and "Count Worn Parts: on" or "Count Worn Parts: off",
        settings.countWorn and COLORS.btn or COLORS.btnOff)
    style_button(h.b.autoFuses, auto_label("Auto Fuses", settings.fuseOn))
    set_text(hw(h, "fuseTarget"), tostring(settings.fuseTarget))
    set_text(hw(h, "floor"), settings.moneyFloor > 0 and money_text(settings.moneyFloor) or "OFF", settings.moneyFloor > 0 and COLORS.price or COLORS.bad)
    -- Workshop supplies (rows rebuilt only when the game's list changes).
    local groups = supply_groups()
    local skey = {}
    for _, g in ipairs(groups) do skey[#skey + 1] = g.key .. "/" .. #g.tiers end
    if h.supplyKey ~= table.concat(skey, ",") then rebuild_supply_rows(h, groups) end
    local byKey = {}
    for _, g in ipairs(groups) do byKey[g.key] = g end
    for _, r in ipairs(h.srows or {}) do
        local g = byKey[r.key]
        if g then
            local t = supply_tier(g)
            local e = t.entry
            local have = usable(counts, e)
            local cc = carried[e.clsPath]
            local cn = cc and (cc.ready + cc.repair) or 0
            set_text(resolve(r.cells[1]), g.name, COLORS.white)
            set_text(resolve(r.cells[2]), money_text(e.price))
            local enough = settings.supplyOn and have >= settings.supplyTarget
            set_text(resolve(r.cells[3]), tostring(have), (have == 0 and COLORS.bad) or (enough and COLORS.good) or COLORS.text)
            set_text(resolve(r.cells[4]), tostring(cn), cn > 0 and COLORS.text or COLORS.dim)
            -- One tier: the button only names it. More: it steps to the next
            -- one, and the trailing arrow says so (it never goes back).
            if #g.tiers > 1 then
                style_button(r.b.tier, t.label .. "  >", COLORS.btnOff)
            else
                style_button(r.b.tier, t.label, COLORS.btnLocked)
            end
            if e.avail then
                style_button(r.b.add, string.format("Add %d  (%s)", SUPPLY_PACK, money_text(SUPPLY_PACK * e.price)), COLORS.btn)
            else
                style_button(r.b.add, "Locked", COLORS.btnOff)
            end
        end
    end
    -- Gas Pump Hub (only looked at while the workshop page is showing).
    if h.page == "hub" and h.hubRows then
        local hub, why = Hub.hub_state()
        local price, fromGame = Hub.fuel_price()
        local levels = hub and Hub.tank_levels(hub) or nil
        set_text(hw(h, "hubInfo"), hub and string.format("Gas station price: %s per gallon%s.", Hub.cents_text(price),
            fromGame and "" or " (the pump's usual price)") or why, hub and COLORS.dim or COLORS.price)
        local sumF, sumM = 0, 0
        for _, t in ipairs({ 1, 2, 3, "all" }) do
            local r = h.hubRows[t]
            local tanks = t == "all" and { 1, 2, 3 } or { t }
            local lockedTank = levels and t ~= "all" and levels[t].locked
            if lockedTank then
                -- Above the hub's level: greyed dial at zero, no buttons.
                local needle = resolve(r.needle)
                if needle then pcall(function() needle:SetRenderTransformAngle(-135) end) end
                set_text(resolve(r.level), "Locked", COLORS.dim)
                if r.pct then set_text(resolve(r.pct), "Gas Hub Level " .. t, COLORS.dim) end
            elseif levels then
                local f, m = 0, 0
                for _, i in ipairs(tanks) do f, m = f + levels[i].fuel, m + levels[i].max end
                local pctFull = m > 0 and f / m or 0
                -- The game's dials: red below 20%, green from 80%.
                local col = (pctFull < 0.2 and COLORS.bad) or (pctFull >= 0.8 and COLORS.good) or COLORS.price
                local bar = resolve(r.bar)
                if bar then
                    pcall(function() bar:SetPercent(pctFull) end)
                    pcall(function() bar:SetFillColorAndOpacity(col) end)
                end
                local needle = resolve(r.needle)
                if needle then pcall(function() needle:SetRenderTransformAngle(-135 + 270 * math.max(0, math.min(1, pctFull))) end) end
                local pctStr = string.format("%d%%", math.floor(pctFull * 100 + 0.5))
                if r.pct then
                    set_text(resolve(r.level), string.format("%.1f / %s gal", f, num_text(m)), COLORS.dim)
                    set_text(resolve(r.pct), pctStr, col)
                else
                    set_text(resolve(r.level), string.format("%.1f / %s gal   %s", f, num_text(m), pctStr), col)
                end
            else
                set_text(resolve(r.level), "-", COLORS.dim)
                if r.pct then set_text(resolve(r.pct), "") end
            end
            for _, pct in ipairs(Hub.HUB_STEPS) do
                local rec = h.b["hub" .. t .. "_" .. pct]
                local label = pct == 100 and (t == "all" and "Fill All" or "Fill") or ("+" .. pct .. "%")
                if lockedTank then
                    style_button(rec, "Locked", COLORS.btnLocked)
                elseif levels then
                    local _, gal = Hub.hub_adds(levels, tanks, pct)
                    local _, fillGal = Hub.hub_adds(levels, tanks, 100)
                    -- A step that would be capped at full is the same as Fill: grey it.
                    if pct < 100 and gal > 0 and gal >= fillGal - 0.05 then
                        style_button(rec, label, COLORS.btnOff)
                    elseif gal > 0 then
                        style_button(rec, string.format("%s  (%s)", label, money_text(Hub.floor_cents(gal * price))), pct == 100 and COLORS.btnFill or COLORS.btn)
                    else
                        style_button(rec, "Full", COLORS.btnOff)
                    end
                else
                    style_button(rec, label, COLORS.btnLocked)
                end
            end
        end
    end
    style_button(h.b.autoSupplies, auto_label("Auto Supplies", settings.supplyOn))
    style_button(h.b.autoFuel, auto_label("Auto Fuel", settings.fuelOn))
    style_button(h.b.autoFuelHub, auto_label("Auto Fuel", settings.fuelOn))
    set_text(hw(h, "supplyTarget"), tostring(settings.supplyTarget))

    for _, name in ipairs({ "status", "status2", "status3" }) do
        local st = hw(h, name)
        set_text(st, status.text, status.good and COLORS.good or COLORS.bad)
        if st then pcall(function() st:SetVisibility(3) end) end
    end
end

-- Three pages share the body: "main" (parts), "workshop" (supplies) and
-- "help". Each shows its own cards and hides the others'.
local function show_page(h, page)
    if page == "help" and h.page ~= "help" then h.helpReturn = h.page or "main" end
    h.page = page
    pcall(function() resolve(h.w.helpCard):SetVisibility(page == "help" and 0 or 1) end)
    for list, name in pairs({ [h.cards or {}] = "main", [h.wcards or {}] = "workshop", [h.hcards or {}] = "hub" }) do
        for _, p in ipairs(list) do
            local c = resolve(p)
            if c then pcall(function() c:SetVisibility(page == name and 0 or 1) end) end
        end
    end
    style_button(h.b.help, page == "help" and "Hide Help" or "Help")
end

local function open_panel(hostPath)
    local h = hosts[hostPath]
    local host = resolve(hostPath)
    if not h or not host then return end
    if not resolve(h.panelPath) then build_panel(h, host, hostPath) end
    local panel = resolve(h.panelPath)
    if not panel then return end
    -- Always open on the main page, however the app was last closed, with the
    -- buy counts (Cars, each part row) back at 1. Auto targets are kept.
    settings.builds = 1
    for k in pairs(rowCars) do rowCars[k] = nil end
    if h.page ~= "main" then show_page(h, "main") end
    lastAvailCheck = -1e9
    refresh_panel(h)
    local switcher = host.ApplicationWidgetSwitcher
    local ok = pcall(function() switcher:SetActiveWidget(panel) end)
    if not ok then
        pcall(function() switcher:SetActiveWidgetIndex(switcher:GetChildIndex(panel)) end)
    end
end

local function close_panel(hostPath)
    local host = resolve(hostPath)
    if host then pcall(function() host:ReturnToDesktop() end) end
end

-------------------------------------------------------------------------------
-- Report a Bug / request a feature. The mod never posts anything itself (that
-- would need a login built in): it saves a report file, opens the issue form
-- pre-filled, and opens the report's folder so the player can drag the file in
-- and press Submit. The buttons open the public repo's GitHub issue forms at
-- the org's final path (1.0 used the old github.com/lukarick/... path, which
-- only works through GitHub's redirect). A later version moves them to
-- lukasmods.com/bug and /request once that domain is live.
-- Reports are titled with the game code and display name, not the code id
-- MOD, which stays the log prefix the report scans for.
local ISSUES = { url = "https://github.com/lukas-mods/Lukas-Mods/issues/new", name = "CDS - Parts Manager" }
local UE4SS_LOG = MOD_DIR .. "..\\..\\UE4SS.log"

local function url_encode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Spaces become %20, never "+": a "+" re-encoded by the redirect would show
-- in the form as a plus (url_encode escapes everything but -._~ and letters).
local function issue_url(template, extra)
    local q = { "template=" .. template, "title=" .. url_encode("[" .. ISSUES.name .. "] "),
        "mod=" .. url_encode(ISSUES.name), "version=" .. url_encode(VERSION) }
    for k, v in pairs(extra or {}) do q[#q + 1] = k .. "=" .. url_encode(v) end
    return ISSUES.url .. "?" .. table.concat(q, "&")
end

local function open_external(target, select)
    -- `start` returns at once; the game keeps running (alt-tab to the browser).
    if select then
        os.execute('start "" explorer.exe /select,"' .. target .. '"')
    else
        os.execute('start "" "' .. target .. '"')
    end
end

-- Remove the Windows user name from anything written to the report.
local function scrub(s)
    s = tostring(s or "")
    local user = os.getenv("USERNAME")
    if user and #user > 1 then
        for _, u in ipairs({ user, user:lower() }) do
            local pattern = u:gsub("%p", "%%%0")   -- (gsub's 2nd result must not leak in)
            s = s:gsub(pattern, "<user>")
        end
    end
    return s
end

local function read_all(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function write_bug_report()
    local stamp = os.date("%Y%m%d-%H%M%S")
    -- The mod folder itself ("...\Scripts\..\" collapsed, for Explorer's /select).
    local dir = MOD_DIR:gsub("[^\\/]+[\\/]%.%.[\\/]$", "")
    local path = dir .. MOD .. "-bug-" .. stamp .. ".txt"
    local out = {}
    local function add(s) out[#out + 1] = scrub(s) end

    add(string.format("%s v%s bug report -- %s", MOD, VERSION, os.date("%Y-%m-%d %H:%M:%S")))
    add("Drag this file into the GitHub issue. Your Windows user name has been replaced with <user>.")
    add("")
    add("== State ==")
    add("catalogue products: " .. tostring(catalog and #catalog or 0))
    local n = 0
    for _, h in pairs(hosts) do n = n + 1 add("app on " .. tostring(h.kind) .. ": screen built = " .. tostring(resolve(h.panelPath) ~= nil)) end
    add("hosts: " .. n .. "   purchase running: " .. tostring(job ~= nil))
    add("last status: " .. tostring(status.text))
    add("")
    add("== settings.txt ==")
    add(read_all(SETTINGS_FILE) or "(none)")
    add("== UE4SS mods.txt ==")
    add(read_all(MOD_DIR .. "..\\mods.txt") or "(not found)")

    -- Every folder in Mods\: mods.txt alone misses the mods
    -- turned on by their own enabled.txt. Per mod: how it is turned on, the
    -- version it logged this session (if it logs one), and a fingerprint of its
    -- Scripts\main.lua (size + FNV-1a; Lua has no file dates). Plus the build.
    local modsDir = MOD_DIR .. "..\\"
    local names, how = {}, "IterateGameDirectories"
    pcall(function()
        local m = IterateGameDirectories().Game.Binaries.Win64.ue4ss.Mods
        for k, v in pairs(m) do
            if type(k) == "string" and not k:find("^__") and type(v) == "table" then names[#names + 1] = k end
        end
    end)
    if #names == 0 then
        how = "dir"
        pcall(function()
            local p = io.popen('dir /b /ad "' .. modsDir .. '" 2>nul')
            if p then
                for l in p:lines() do if l ~= "" then names[#names + 1] = l end end
                p:close()
            end
        end)
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    local listed = {}
    for line in (read_all(modsDir .. "mods.txt") or ""):gmatch("[^\r\n]+") do
        local nm, v = line:match("^%s*([^:;]-)%s*:%s*(%d)")
        if nm then listed[nm] = (v == "1") end
    end
    local logText = read_all(UE4SS_LOG) or ""
    local function logged_version(name)
        local found, tag = nil, "[" .. name .. "]"
        for line in logText:gmatch("[^\r\n]+") do
            if line:find(tag, 1, true) then found = line:match("[%s%(]v(%d+[%w%.%-]*)") or found end
        end
        return found
    end
    local function fingerprint(file)
        local f = io.open(file, "rb")
        if not f then return nil end
        local data = f:read("a")
        f:close()
        local h = 2166136261
        for i = 1, #data do h = ((h ~ data:byte(i)) * 16777619) & 0xFFFFFFFF end
        return string.format("%d bytes, fnv %08x", #data, h)
    end
    add("== Installed UE4SS mods (" .. #names .. ", listed with " .. how .. ") ==")
    for _, nm in ipairs(names) do
        local d = modsDir .. nm .. "\\"
        local on = {}
        local et = io.open(d .. "enabled.txt", "r")
        if et then et:close() on[#on + 1] = "enabled.txt" end
        if listed[nm] == true then on[#on + 1] = "mods.txt:1" elseif listed[nm] == false then on[#on + 1] = "mods.txt:0" end
        local v = logged_version(nm)
        add(string.format("%-30s on: %-24s version: %-12s main.lua: %s", nm, #on > 0 and table.concat(on, ", ") or "no",
            v and ("v" .. v) or "-", fingerprint(d .. "Scripts\\main.lua") or "none"))
    end
    -- Steam's manifest sits in steamapps\, eight folders up from this mod.
    local acf = read_all(MOD_DIR .. string.rep("..\\", 8) .. "appmanifest_2404880.acf")
    add("game build: " .. ((acf and acf:match('"buildid"%s+"(%d+)"')) or "unknown (not found; a non-Steam install?)"))
    add("")

    local log = read_all(UE4SS_LOG)
    if log then
        local header, mine, errors = {}, {}, {}
        local i = 0
        for line in log:gmatch("[^\r\n]+") do
            i = i + 1
            if i <= 5 then header[#header + 1] = line end
            if line:find("[" .. MOD .. "]", 1, true) then mine[#mine + 1] = line end
            local l = line:lower()
            if l:find("error") or l:find("exception") or l:find("fatal") then errors[#errors + 1] = line end
        end
        local function tail(list, k)
            local from = math.max(1, #list - k + 1)
            return table.concat(list, "\n", from, #list)
        end
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
        if h then refresh_panel(h) end
        return
    end
    if action == "feature" then
        open_external(issue_url("feature_request.yml"))
        set_status("GitHub's feature request form is opening in your browser: alt-tab to it.", true)
        if h then refresh_panel(h) end
        return
    end
    if action == "help" then
        if h then show_page(h, h.page == "help" and (h.helpReturn or "main") or "help") end
        return
    end
    local tipKey = action:match("^tip:(.+)$")
    if tipKey then
        if h and h.tips and h.tips[tipKey] then set_status(h.tips[tipKey], true) refresh_panel(h) end
        return
    end
    if action == "gashub" then
        if h then
            if (Hub.hub_level() or 0) < 1 then
                set_status("Fuel Delivery needs the Gas Pump Hub upgrade (Upgrades app on your tablet).", false)
            elseif Hub.tanker_owned() then
                show_page(h, "hub")
            else
                set_status("Fuel Delivery needs your own mobile fuel tank (sold at the gas station). Own one? Go near it, then try again.", false)
            end
            refresh_panel(h)
        end
        return
    end
    if action == "workshop" then
        if h then
            show_page(h, "workshop")
            refresh_panel(h)
        end
        return
    end
    local kind, arg = action:match("^(%w+):?(.*)$")
    if kind == "kit" then
        -- A locked kit tab explains itself instead of switching.
        local ok, why = true, ""
        if arg ~= "Stock" then ok, why = kit_unlocked(arg) end
        -- STATUS is sentences: "Sport unlocks at fame level 6." (the labels are Title Case).
        if ok then
            settings.kit = arg
            if h and (h.page == "workshop" or h.page == "hub") then show_page(h, "main") end
        else
            local msg = why ~= "" and (why:gsub(" Unlocks at Fame Level ", " unlocks at fame level "):gsub(" Needs the ", " needs the "):gsub(" Locked ", " locked ") .. ".") or (arg .. " is locked.")
            set_status(msg, false)
        end
    elseif kind == "extras" then settings.extras = not settings.extras
    elseif kind == "builds" then settings.builds = math.max(1, math.min(999, settings.builds + tonumber(arg)))
    elseif kind == "autotarget" then
        local k, d = arg:match("^(%a+):(%-?%d+)$")
        if k and settings.autoTarget[k] then
            settings.autoTarget[k] = math.max(1, math.min(999, settings.autoTarget[k] + tonumber(d)))
        end
    elseif kind == "floor" then
        -- step through preset floors
        local idx = 1
        for i, v in ipairs(MONEY_FLOORS) do if v <= settings.moneyFloor then idx = i end end
        idx = math.max(1, math.min(#MONEY_FLOORS, idx + tonumber(arg)))
        settings.moneyFloor = MONEY_FLOORS[idx]
        lastAutoWarning = nil
    elseif kind == "fusetarget" then
        settings.fuseTarget = math.max(FUSES_PER_PACK, math.min(999, settings.fuseTarget + tonumber(arg)))
    elseif (kind == "autofuses" or kind == "autokit" or kind == "autosupplies" or kind == "autofuel") and autoPaused then
        -- While paused, any Auto button resumes (it does not toggle). The
        -- player is in the loaded world now, so take it as the settled one.
        autoPaused = false
        local st = get_storage()
        autoWorld.path, autoWorld.since, autoWorld.total, autoWorld.settled =
            st and path_of(st) or nil, os.clock(), nil, true
        lastAutoCheck = -1e9
        lastAutoWarning = nil
        set_status("Auto-stock resumed for this save.", true)
    elseif kind == "autofuses" then
        settings.fuseOn = not settings.fuseOn
        lastAutoCheck = -1e9
        lastAutoWarning = nil
        set_status(settings.fuseOn and string.format("Auto Fuses on: keeping %d of each fuse size (packs of %d).", settings.fuseTarget, FUSES_PER_PACK)
            or "Auto Fuses off.", true)
    elseif kind == "autosupplies" then
        settings.supplyOn = not settings.supplyOn
        lastAutoCheck = -1e9
        lastAutoWarning = nil
        set_status(settings.supplyOn and string.format("Auto Supplies on: keeping %d of each workshop supply.", settings.supplyTarget)
            or "Auto Supplies off.", true)
    elseif kind == "autofuel" then
        settings.fuelOn = not settings.fuelOn
        lastAutoCheck = -1e9
        lastAutoWarning = nil
        set_status(settings.fuelOn and "Auto Fuel on: when your unlocked tanks together drop below 10%, they're all filled."
            or "Auto Fuel off.", true)
    elseif kind == "supplytarget" then
        settings.supplyTarget = math.max(0, math.min(999, settings.supplyTarget + tonumber(arg)))
    elseif kind == "srowtier" or kind == "srowadd" then
        local g = nil
        for _, x in ipairs(supply_groups()) do if x.key == arg then g = x end end
        if g and kind == "srowtier" then
            -- Step to the next tier (wraps); one tier = nothing to switch to.
            if #g.tiers > 1 then
                local cur = supply_tier(g)
                local idx = 1
                for i, t in ipairs(g.tiers) do if t == cur then idx = i end end
                local nxt = g.tiers[idx % #g.tiers + 1]
                settings.supplyTier[g.key] = nxt.suffix
                set_status(string.format("%s: buying the %s tier.", g.name, nxt.label), true)
            else
                set_status(string.format("%s only comes in %s so far.", g.name, g.tiers[1].label), true)
            end
        elseif g and not job then
            local t = supply_tier(g)
            local ok, err = start_job({ { entry = t.entry, qty = SUPPLY_PACK } }, string.format("%s - %s", g.name, t.label))
            if ok and job then job.oneSupply = true end
            if not ok then set_status(err, false) status.staleOnMoney = true end
        end
    elseif kind == "hub" then
        local t, pct = arg:match("^(%w+):(%d+)$")
        pct = tonumber(pct)
        if t and pct then Hub.hub_fill(t == "all" and { 1, 2, 3 } or { tonumber(t) }, pct) end
    elseif kind == "worn" then
        settings.countWorn = not settings.countWorn
        lastAutoCheck = -1e9
    elseif kind == "autokit" then
        if settings.autoOn[arg] ~= nil then
            settings.autoOn[arg] = not settings.autoOn[arg]
            lastAutoCheck = -1e9
            lastAutoWarning = nil
            set_status(settings.autoOn[arg]
                and string.format("Auto %s on: keeping %d complete %s car(s) in storage%s.", arg, settings.autoTarget[arg], arg,
                    settings.extras and ", with Body & Consumables" or "")
                or ("Auto " .. arg .. " off."), true)
        end
    elseif kind == "buy" then
        if not job then buy_builds() end
    elseif kind == "rowminus" or kind == "rowplus" then
        rowCars[arg] = math.max(1, math.min(99, (rowCars[arg] or 1) + (kind == "rowplus" and 1 or -1)))
    elseif kind == "rowbuy" then
        local e = catalogById[arg]
        local per = nil
        for _, l in ipairs(kit_lines(settings.kit, settings.extras)) do
            if l.entry.id == arg then per = l.perCar end
        end
        if e and per and not job then
            local cars = rowCars[arg] or 1
            local ok, err = start_job({ { entry = e, qty = per * cars } },
                string.format("%s for %d car(s)", e.name, cars))
            if not ok then set_status(err, false) status.staleOnMoney = true end
        end
    end
    save_settings()
    if h then refresh_panel(h) end
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
    if not valid(row) or not valid(source) then
        log("icon row not found on " .. kind)
        return
    end
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
    icon.Icon = FText("\239\134\179")   -- "cubes" glyph in the icon font
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
    pcall(function() icon:SetToolTipText(FText("Parts Manager")) end)
    pcall(function()
        local s = source.RenderTransform.Scale
        icon:SetRenderScale({ X = s.X, Y = s.Y })
    end)
    hosts[hostPath] = { kind = kind, hostPath = hostPath, iconPath = path_of(icon), panelPath = h and h.panelPath or nil, w = h and h.w or {}, b = h and h.b or {} }
    buttons[icon:GetFullName()] = { host = hostPath, action = "open" }
    log("app icon added to " .. kind)
end

-------------------------------------------------------------------------------
-- hooks

local function on_icon_clicked(ctx)
    local ok, clicked = pcall(function() return ctx:get() end)
    if not ok or not valid(clicked) then return end
    local b = buttons[clicked:GetFullName()]
    if not b then return end
    -- Act on the next game-thread pass, after the click has finished dispatching.
    ExecuteInGameThread(function()
        local okA, err = xpcall(crumb, debug.traceback, "action " .. b.action, do_action, b.host, b.action)
        if not okA then log("action " .. b.action .. " failed: " .. tostring(err)) end
    end)
end

local function on_host_ready(kind)
    return function(ctx)
        local ok, host = pcall(function() return ctx:get() end)
        if not ok or not valid(host) then return end
        -- Straight away, inside the hook (no frame delay, which made our icons
        -- pop in late): the CarShopTablet mod adds its icon the same way.
        -- Post-hooks on this function never fired in game.
        local okI, err = xpcall(crumb, debug.traceback, kind .. " icon", add_icon, host, kind)
        if not okI then log(kind .. " icon failed: " .. tostring(err)) end
    end
end

-------------------------------------------------------------------------------
-- Alerts: a large message on the HUD, so an important notice (e.g. "auto-stock
-- paused") can't be missed. Requested with queue_alert(); delivered from the
-- main loop once the HUD exists.
--
-- No in-game email any more: an email added with economy:AddMail
-- filled only 8 of S_MailData's 13 fields, and on game build 25832017 the next
-- autosave crashed every time.

local ALERT_SECONDS = 20
local alertState = { pending = nil, bannerPath = nil, hideAt = nil }

-- The banner: our own widgets added to the game's HUD (WBP_MainUI) canvas,
-- near the top. Plain shadowed text with no background box, so it doesn't
-- block the view while driving. The HUD doesn't take mouse input during
-- play, so it removes itself after ALERT_SECONDS.
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
    pcall(function() t:SetShadowOffset({ X = 2, Y = 2 }) end)
    pcall(function() t:SetShadowColorAndOpacity(SHADOW) end)
    pcall(function() t:SetAutoWrapText(true) end)
    pcall(function() t:SetJustification(1) end)   -- centred
end

local function show_banner(title, body)
    local hud = first_live("WBP_MainUI_C")
    if not hud then return false end
    local tree = hud.WidgetTree
    local root = nil
    pcall(function() root = tree.RootWidget end)
    local canvas = find_canvas(root, 0)
    if not canvas then return false end

    local box = new_widget("VerticalBox", tree)
    local logo = make_logo(hud, tree, 80)
    if logo then
        local lsl = box:AddChildToVerticalBox(logo)
        halign(lsl, 2)
        pad(lsl, 0, 0, 0, 6)
    end
    local t = make_text(tree, title, 34, COLORS.white)
    shadowed(t)
    local ts = box:AddChildToVerticalBox(t)
    halign(ts, 2)
    pad(ts, 0, 0, 0, 8)
    local b = make_text(tree, body, 20, COLORS.white)
    shadowed(b)
    local bs = box:AddChildToVerticalBox(b)
    halign(bs, 2)
    local sz = new_widget("SizeBox", tree)
    pcall(function() sz:SetWidthOverride(1000) end)
    sz:SetContent(box)
    pcall(function() sz:SetVisibility(3) end)       -- never takes the mouse

    local slot = canvas:AddChildToCanvas(sz)
    pcall(function() slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.12 }, Maximum = { X = 0.5, Y = 0.12 } }) end)
    pcall(function() slot:SetAlignment({ X = 0.5, Y = 0.5 }) end)
    pcall(function() slot:SetAutoSize(true) end)
    pcall(function() slot:SetZOrder(1000) end)
    alertState.bannerPath = path_of(sz)
    alertState.hideAt = os.clock() + ALERT_SECONDS
    return true
end

local function hide_banner()
    local w = resolve(alertState.bannerPath)
    if w then pcall(function() w:RemoveFromParent() end) end
    alertState.bannerPath, alertState.hideAt = nil, nil
end

-- Ask for an alert. Delivered by alert_tick() when the HUD exists.
queue_alert = function(title, body)
    alertState.pending = { title = title, body = body, since = os.clock(), shown = false }
end

local function alert_tick()
    if alertState.hideAt and os.clock() > alertState.hideAt then hide_banner() end
    local a = alertState.pending
    if not a then return end
    if not a.shown then a.shown = show_banner(a.title, a.body) end
    -- Give up after a minute if the HUD never appears.
    if a.shown or os.clock() - a.since > 60 then alertState.pending = nil end
end

-- Escape: the tablet/computer only handle "back" for their own apps, so do
-- it for ours -- close Help if it is open, otherwise return to the desktop.
-- Taken from the game's own key handling on the tablet / computer screen
-- (hooks on WBP_DesktopComputer_BASE_C:OnPreviewKeyDown and the subclasses'
-- OnKeyDown, all game thread). Not RegisterKeyBind: UE4SS runs those callbacks
-- on its own input thread. Not IsInputKeyDown: it doesn't see keys while the
-- tablet has focus (tested).
local function on_escape()
    for hostPath, h in pairs(hosts) do
        if panel_visible(h) then
            -- Escape steps back: Help -> its page, Workshop -> the parts page, parts -> desktop.
            if h.page == "help" then do_action(hostPath, "help")
            elseif h.page == "workshop" or h.page == "hub" then
                show_page(h, "main")
                refresh_panel(h)
            else close_panel(hostPath) end
        end
    end
end
local INPUT_LIBRARY = "/Script/Engine.Default__KismetInputLibrary"
local lastEscape = -1e9
local keyHookLogged = {}
local function key_hook(name)
    return function(self, geometry, keyEvent)
        local key = nil
        pcall(function()
            local k = resolve(INPUT_LIBRARY):GetKey(keyEvent:get())
            key = k.KeyName:ToString()
        end)
        if not keyHookLogged[name] then
            keyHookLogged[name] = true
            log("key hook " .. name .. " fired (key " .. tostring(key) .. ")")
        end
        if key ~= "Escape" then return end
        -- Several hooks see the same press; act once.
        if os.clock() - lastEscape < 0.25 then return end
        lastEscape = os.clock()
        ExecuteInGameThread(function()
            local ok, err = xpcall(crumb, debug.traceback, "escape", on_escape)
            if not ok then log("escape failed: " .. tostring(err)) end
        end)
    end
end

-- The tablet's and computer's shared base class, found from a live screen.
-- The screens' Blueprint classes, loaded by us at start-up with LoadAsset (a
-- load, not a search) so the hooks are in place before the first tablet is
-- built -- the icon then goes in with the game's own (as the CarShopTablet
-- mod's does). One attempt per class; if it fails, the hooks fall back to
-- waiting for a live screen.
local function in_game_world()
    local pc = first_live("BP_PlayerController_C")
    local p = pc and path_of(pc) or ""
    return p ~= "" and not p:find("MenuMap", 1, true)
end
local classTried, classLoaded = {}, {}
local function load_class(classPath)
    if classLoaded[classPath] then return classLoaded[classPath] end
    if classTried[classPath] or type(LoadAsset) ~= "function" then return nil end
    -- Only in the game world: loaded from the main menu, the class could be
    -- unloaded at the level change, leaving the hook on a dead class.
    if not in_game_world() then return nil end
    classTried[classPath] = true
    local c = nil
    pcall(function() c = LoadAsset(classPath) end)
    if valid(c) then
        path_of(c)
        classLoaded[classPath] = c
        log("loaded " .. classPath)
        return c
    end
    log("could not load " .. classPath .. "; waiting for a live screen instead")
    return nil
end

local function base_class_path()
    local tc = load_class(TABLET_CLASS)
    if tc then
        local ok, sup = pcall(function() return tc:GetSuperStruct() end)
        if ok and valid(sup) then return path_of(sup) end
    end
    for _, cls in ipairs({ "WBP_Tablet_C", "WBP_DesktopComputer_C" }) do
        local o = first_live(cls)
        if o then
            local ok, sup = pcall(function() return o:GetClass():GetSuperStruct() end)
            if ok and valid(sup) then return path_of(sup) end
        end
    end
    return nil
end

-- Each hook waits until an instance of its class is live (FindAllOf, a hashed
-- lookup) before RegisterHook is called: RegisterHook on a class that isn't
-- loaded yet makes UE4SS search for it, every retry.
local HOOKS = {
    { name = "icon click", gate = "WBP_DesktopIconWidget_C", path = ICON_CLICK, fn = on_icon_clicked },
    { name = "tablet", gate = "WBP_Tablet_C", kind = "tablet", path = TABLET_CLASS .. ":ActivateApplications", fn = on_host_ready("tablet") },
    { name = "computer", gate = "WBP_DesktopComputer_C", kind = "computer", path = COMPUTER_CLASS .. ":Activate Applications", fn = on_host_ready("computer") },
    { name = "tablet keys", gate = "WBP_Tablet_C", path = TABLET_CLASS .. ":OnKeyDown", fn = key_hook("tablet OnKeyDown") },
    { name = "computer keys", gate = "WBP_DesktopComputer_C", path = COMPUTER_CLASS .. ":OnKeyDown", fn = key_hook("computer OnKeyDown") },
    { name = "preview keys", base = true, fn = key_hook("base OnPreviewKeyDown") },
}
-- Repeating work runs on the GAME thread. UE4SS's LoopInGameThreadWithDelay
-- does exactly that (LoopAsync is deprecated: it runs Lua on UE4SS's own
-- thread, alongside the game thread's Lua). fn returns true to stop.
-- Older UE4SS without it: an async loop handing one tick at a time over.
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
        log(name .. " loop: game thread (LoopInGameThreadWithDelay, " .. ms .. " ms)")
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
    log(name .. " loop: LoopAsync + ExecuteInGameThread (" .. ms .. " ms)")
end

-- Registers each hook once its class is live. A hook whose class is live but
-- which still fails is given up (not retried): retrying a missing function
-- would make UE4SS search for it every time.
game_loop("hooks", 2000, function()
    local pending = 0
    for _, hk in ipairs(HOOKS) do
        if not hk.done then
            local path = hk.path
            if hk.base then
                local b = base_class_path()
                path = b and (b .. ":OnPreviewKeyDown") or nil
            elseif hk.gate and not load_class((path:gsub(":.*$", ""))) and not first_live(hk.gate) then
                path = nil
            end
            if path then
                local ok, err = pcall(function()
                    if hk.post then RegisterHook(path, function() end, hk.fn) else RegisterHook(path, hk.fn) end
                end)
                hk.done = true
                log(hk.name .. (ok and " hook registered" or (" hook FAILED, not retried: " .. tostring(err))))
                -- The screen already exists, so its ActivateApplications has
                -- run before the hook did: add the icon to it now.
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
-- main loop: purchases every 100 ms, UI refresh every second, auto-stock check

local ticks = 0
game_loop("main", 100, function()
        ticks = ticks + 1
        local ok, err = xpcall(function()
            if job then crumb("job step", job_step) end
            if ticks % 10 == 5 then
                -- Watched while paused too, so a pause ends when another save loads.
                if any_auto_configured() and not job then crumb("watch world", watch_world) end
                if alertState.pending or alertState.hideAt then crumb("alert", alert_tick) end
                -- Notes when the gas pump hub loads, so its settle minute runs
                -- from then, not from the first look at the workshop page.
                crumb("hub watch", Hub.hub_state)
            end
            if ticks % 10 == 0 then
                for _, h in pairs(hosts) do
                    if panel_visible(h) then crumb("refresh " .. h.kind, refresh_panel, h) end
                end
            end
            -- DEBUG (save-crash hunt): every 10 s, what the mod is holding in the game.
            if traceOn and ticks % 100 == 0 then
                local made, live = 0, 0
                for _, p in pairs(checkObjects) do
                    made = made + 1
                    if resolve(p) then live = live + 1 end
                end
                local nh, open = 0, 0
                for _, h in pairs(hosts) do
                    nh = nh + 1
                    if panel_visible(h) then open = open + 1 end
                end
                local n = 0
                for _ in pairs(known) do n = n + 1 end
                log(string.format("heartbeat: check objects %d made / %d live; hosts %d, panels open %d; remembered objects %d; auto %s%s%s",
                    made, live, nh, open, n, any_auto_configured() and "on" or "off",
                    autoPaused and " (paused)" or "", job and ", buying" or ""))
            end
            if any_auto() and not job and os.clock() - lastAutoCheck > AUTO_CHECK_SECONDS then
                crumb("auto-stock", function()
                    if not catalog then build_catalog() end
                    if catalog then
                        if availability_due() then refresh_availability() end
                        auto_stock()
                    end
                end)
            end
        end, debug.traceback)
        if not ok then
            log("tick error: " .. tostring(err))
            job = nil
        end
        return false
end)

log("v" .. VERSION .. " loaded")
