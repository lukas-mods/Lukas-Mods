-- Automation Manager: profiles for the game's automation platform.
-- Profiles saved to a file, applied to cars through the game's own Add
-- Automation Task; intake of cars on the warehouse bays; a board; a targeted
-- reset; and an app on the Tablet and Computer.
-- Every mechanism here was measured in the game or read from its shipped code.

-- This file's main body is at Lua's limit of 200 live locals (no spare: one
-- more top-level local fails to compile; luac -l's "locals" count is a
-- cumulative debug count and isn't this number).
-- New file-level state goes into an existing table, not a new local, and
-- every change is checked with luac -p before it ships.
local MOD = "AutomationManager"
local VERSION = "1.0.3"
local function log(msg) print("[" .. MOD .. "] " .. tostring(msg) .. "\n") end

---------------------------------------------------------------------------
-- Object helpers
---------------------------------------------------------------------------
local function valid(o)
    if not o then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function path_of(o)
    local ok, s = pcall(function() return o:GetFullName() end)
    if not ok or not s then return "?" end
    return s:match("^%S+%s+(.+)$") or s
end
local function name_of(o)
    local ok, s = pcall(function() return o:GetFName():ToString() end)
    return ok and s or "?"
end
local function prop_type(p)
    local ok, s = pcall(function() return p:GetClass():GetFName():ToString() end)
    return ok and s or "?"
end
local function text_of(v)
    if v == nil then return "" end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" then return s end
    return tostring(v)
end
local function find_all(cls)
    local ok, all = pcall(function() return FindAllOf(cls) end)
    return (ok and all) or {}
end
local function live(o) return valid(o) and not path_of(o):find("Default__", 1, true) end
local function first_live(cls)
    for _, o in ipairs(find_all(cls)) do if live(o) then return o end end
    return nil
end

---------------------------------------------------------------------------
-- The task struct (F_AutomationTask_FullList)
-- Field names carry a GUID suffix (Name_3_ABC...); they are found by their
-- bare name so a game update that re-suffixes them doesn't break the mod.
---------------------------------------------------------------------------
local function struct_fields(st, depth)
    local list = {}
    pcall(function()
        st:ForEachProperty(function(fp)
            local t, sub = prop_type(fp), nil
            -- Nested structs are followed four levels deep.
            if t == "StructProperty" and depth < 4 then
                local ok, inner = pcall(function() return fp:GetStruct() end)
                if ok and inner then sub = struct_fields(inner, depth + 1) end
            end
            list[#list + 1] = { name_of(fp), t, sub }
        end)
    end)
    return list
end

local function bare(n) return (n:gsub("_%d+_%x+$", "")) end
local function field_named(fields, b)
    for _, f in ipairs(fields or {}) do if bare(f[1]) == b then return f end end
    return nil
end

local taskFields = nil
local function task_fields()
    if taskFields then return taskFields end
    for _, kind in ipairs({ "UserDefinedStruct", "ScriptStruct" }) do
        local ok, st = pcall(function() return FindObject(kind, "F_AutomationTask_FullList") end)
        if ok and valid(st) and name_of(st) == "F_AutomationTask_FullList" then
            local f = struct_fields(st, 0)
            if #f > 0 then taskFields = f return f end
        end
    end
    return nil
end

-- A Lua table in the struct's shape, for Add Automation Task. `want` holds
-- bare names; anything not given is false or 0. Maps and arrays are left out
-- (passing them as Lua tables crashes the game); parts are added to the
-- stored task afterwards with Map Add and an FName key.
local function build_task(fields, want, car)
    local t = {}
    for _, f in ipairs(fields) do
        local n, ty, sub = f[1], f[2], f[3]
        local b = bare(n)
        if b == "CarID" or b == "CarId" then
            t[n] = car
        elseif ty == "StructProperty" and sub then
            t[n] = build_task(sub, (want and want[b]) or {}, car)
        elseif ty == "BoolProperty" then
            t[n] = (want and want[b]) == true
        elseif ty == "ByteProperty" or ty == "EnumProperty" or ty == "IntProperty" then
            t[n] = (want and type(want[b]) == "number") and want[b] or 0
        end
    end
    return t
end

---------------------------------------------------------------------------
-- The robot and its tasks
---------------------------------------------------------------------------
local function robot_now() return first_live("BP_AutomationRoboticManager_C") end

local function task_entries(robot)
    local TASK_MAP = "AUTOMATION TASKS MAP"
    local list = {}
    local ok = pcall(function()
        robot[TASK_MAP]:ForEach(function(k, v)
            local okK, kv = pcall(function() return k:get() end)
            local okV, sv = pcall(function() return v:get() end)
            list[#list + 1] = { text_of(okK and kv or k), okV and sv or v }
        end)
    end)
    return ok and list or nil
end

-- The car's task, or nil. A second result of "unreadable" means the map
-- couldn't be read at all, which must never be taken as "no task": callers
-- that add a task refuse on it.
local function stored_task(robot, car)
    local entries = task_entries(robot)
    if not entries then return nil, "unreadable" end
    for _, e in ipairs(entries) do
        if e[1] == car then return e[2] end
    end
    return nil
end

-- The car the robot is working on. The robot copies a car's task into
-- CurrentTaskOrder when it takes the car, and works from that copy, so a car
-- is only safe to edit while it isn't this one. The task struct spells the
-- field CarID; the car record spells it CarId.
local function current_car(robot)
    local fields = task_fields()
    local f = fields and field_named(fields, "CarID")
    if not f then return nil, "task struct not found" end
    local ok, v = pcall(function() return robot.CurrentTaskOrder[f[1]] end)
    if not ok then return nil, "CurrentTaskOrder unreadable" end
    return text_of(v), nil
end

local function car_id_of(vehicle)
    local ok, info = pcall(function() return vehicle.VehicleInfoObject end)
    if not ok or not valid(info) then return nil end
    local okC, id = pcall(function() return info.CarId end)
    return okC and text_of(id) or nil
end

---------------------------------------------------------------------------
-- Profiles
-- A profile is the stations to run, the destination, and the mechanic
-- step: "replace" (damaged parts, one class), "custom" (a class per slot,
-- every slot set) or "disassemble". Stored as a Lua table in profiles.lua.
---------------------------------------------------------------------------
-- E_Automation_PartType has four members (0-3). Default/Stock/Sport were measured
-- in game as 0/1/2; Race is the remaining member, so 3.
local PART_TYPE = { Default = 0, Stock = 1, Sport = 2, Race = 3 }
-- Sport and Race parts come only with the Up 2 You DLC, whose racing manager
-- exists only when the DLC is installed. Without it, only Default and Stock
-- are offered or applied.
-- Cached once true: the racing manager may not exist yet during a load, but a
-- DLC can't be removed mid-session.
local dlcSeen = false
local function dlc_ok()
    if not dlcSeen then dlcSeen = first_live("BP_RacingManagerComp_C") ~= nil end
    return dlcSeen
end
local DLC_TIERS = { Sport = true, Race = true }
-- applied: the profile each car was last given (an assignment is cleared
-- when it's applied, so this is what the car's details show afterwards).
-- sales: cars the mod has left at Front Parking, by car id: { s = state,
-- why = reason code, profile = the profile they finished on, price, back =
-- the profile to post with when a car was sent back for photos }. State is
-- "unpriced" (its profile doesn't post), "pending", "posted", "refused",
-- "check" (the ad couldn't be confirmed) or "sent" (on its way back for
-- photos).
local profiles, assignments, applied, sales = {}, {}, {}, {}

local function mod_dir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return (src:gsub("[/\\][^/\\]+[/\\][^/\\]+$", ""))
end

local function serialize(v, indent)
    indent = indent or ""
    if type(v) == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local out = { "{\n" }
        for _, k in ipairs(keys) do
            local ks = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
            out[#out + 1] = indent .. "  " .. ks .. " = " .. serialize(v[k], indent .. "  ") .. ",\n"
        end
        out[#out + 1] = indent .. "}"
        return table.concat(out)
    elseif type(v) == "string" then
        return string.format("%q", v)
    else
        return tostring(v)
    end
end

local function copy_table(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = copy_table(v) end
    return c
end

local function default_profile()
    return {
        steps = { PhotoStudio = true, PaintBooth = false, CarWash = true, BodyWorkshop = true,
            MechanicalWorkshop = true, Compressor = true, GasPump = true, ParkingSlot = true },
        destination = 0,
        -- The windshield only comes in one class, so it's set from the start.
        mechanic = { mode = "replace", partType = "Stock", slots = { Windshield = "Stock" } },
        body = { RenovateCar = true, ReplaceLicensePlates = false },
        gas = { RefuelCar = true, PressuriseTires = true },
        paint = { color = 0 },
        -- Post for Sale: off until the player turns it on. compete is the
        -- level of the ad screen's competitiveness bar to price for, 1-100
        -- (60 is where the game's bar turns blue); the four flags are the ad
        -- screen's own checkboxes.
        sale = { on = false, compete = 60, nonNegotiable = false, leasing = false, online = false, warranty = false },
    }
end

-- A profile by name: a saved one, or "Photos Only", the job a car sent back
-- from Front Parking gets (Photo Studio, then Front Parking). That one isn't
-- saved or listed with the player's profiles.
local function profile_of(name)
    if name == "Photos Only" then
        local p = default_profile()
        for k in pairs(p.steps) do p.steps[k] = false end
        p.steps.PhotoStudio, p.steps.ParkingSlot = true, true
        p.destination = 0
        return p
    end
    return profiles[name]
end

local function load_profiles()
    local f = io.open(mod_dir() .. "/profiles.lua", "r")
    if f then
        local src = f:read("*a")
        f:close()
        local chunk = load("return " .. src, "profiles", "t", {})
        local ok, data = pcall(chunk or function() return nil end)
        if ok and type(data) == "table" then
            profiles = type(data.profiles) == "table" and data.profiles or {}
            assignments = type(data.assignments) == "table" and data.assignments or {}
            applied = type(data.applied) == "table" and data.applied or {}
            sales = type(data.sales) == "table" and data.sales or {}
        else
            log("profiles.lua unreadable, starting with defaults")
        end
    end
    -- Every profile is checked against the default's shape here, once, so the
    -- rest of the mod can rely on it (the file can be edited by hand).
    local d = default_profile()
    local MODE_OK = { replace = true, custom = true, disassemble = true }
    for name, pr in pairs(profiles) do
        if type(name) ~= "string" or type(pr) ~= "table" then
            profiles[name] = nil
        else
            for key, val in pairs(d) do
                if type(pr[key]) ~= type(val) then pr[key] = copy_table(val) end
            end
            local m = pr.mechanic
            if MODE_OK[m.mode] == nil then m.mode = "replace" end
            if PART_TYPE[m.partType] == nil then m.partType = "Stock" end
            if type(m.slots) ~= "table" then m.slots = { Windshield = "Stock" } end
            if type(pr.destination) ~= "number" or pr.destination < 0 or pr.destination > 3 then pr.destination = 0 end
            local c = pr.paint.color
            if type(c) ~= "number" or c < 0 or c > 15 or c % 1 ~= 0 then pr.paint.color = 0 end
            local sl = pr.sale
            local cv = sl.compete
            if type(cv) ~= "number" or cv < 1 or cv > 100 or cv % 1 ~= 0 then sl.compete = 60 end
            if sl.percent ~= nil then
                log("profile " .. name .. ": Post for Sale now prices by competitiveness (" .. sl.compete .. "), not by percent (" .. tostring(sl.percent) .. ")")
                sl.percent = nil
            end
            for _, k in ipairs({ "on", "nonNegotiable", "leasing", "online", "warranty" }) do
                if type(sl[k]) ~= "boolean" then sl[k] = false end
            end
        end
    end
    for car, name in pairs(assignments) do
        if type(car) ~= "string" or profile_of(name) == nil then assignments[car] = nil end
    end
    for car, e in pairs(sales) do
        if type(car) ~= "string" or type(e) ~= "table" or type(e.s) ~= "string" then sales[car] = nil end
    end
    for car, name in pairs(applied) do
        if type(car) ~= "string" or type(name) ~= "string" then applied[car] = nil end
    end
    -- The default profile is editable but always present.
    if not profiles.Default then profiles.Default = d end
    -- What was read, so a record left over from an earlier session shows in
    -- the log before anything acts on it.
    local ids = {}
    for car, name in pairs(applied) do ids[#ids + 1] = car .. "=" .. name end
    table.sort(ids)
    log("profiles.lua read: applied " .. (#ids > 0 and table.concat(ids, ", ") or "none"))
end

local function save_profiles()
    local f = io.open(mod_dir() .. "/profiles.lua", "w")
    if not f then log("could not write profiles.lua") return false end
    local okW = f:write(serialize({ profiles = profiles, assignments = assignments, applied = applied, sales = sales }))
    local okC = f:close()
    if not (okW and okC) then log("profiles.lua write failed") return false end
    return true
end

-- A Custom profile must name a class for every slot, so the result is a
-- complete car. Returns the missing slot names.
local function custom_missing(profile, slotNames)
    local missing = {}
    for _, s in ipairs(slotNames) do
        if not (profile.mechanic.slots or {})[s] then missing[#missing + 1] = s end
    end
    return missing
end

---------------------------------------------------------------------------
-- The car's record and what it needs
---------------------------------------------------------------------------
-- The car's record (BP_VehicleInfoObject), found by CarId. Records come
-- and go as cars are bought and sold, so none is trusted without a check.
-- The game holds a record for every car it knows (over a thousand), so a
-- page of rows would scan them all per row. One index by CarId is built at
-- most once a second; an entry is checked (live, same CarId) before it is
-- used, and a car not in it gets the full scan.
-- (A block-local index: the main chunk is at Lua's limit of locals.)
local info_by_id
do
    local idx = { at = -1, by = {} }
    info_by_id = function(id)
        local now, fresh = os.clock(), false
        if now - idx.at > 1 then
            fresh = true
            local by = {}
            for _, info in ipairs(find_all("BP_VehicleInfoObject_C")) do
                if live(info) then
                    local ok, cid = pcall(function() return text_of(info.CarId) end)
                    -- The first record with an id wins, as in the scan below.
                    if ok and cid ~= "" and by[cid] == nil then by[cid] = info end
                end
            end
            idx = { at = now, by = by }
        end
        local info = idx.by[id]
        if info and live(info) then
            local ok, cid = pcall(function() return text_of(info.CarId) end)
            if ok and cid == id then return info end
        end
        -- Just rebuilt and not in it: a second scan can't find it either.
        if fresh and id ~= "" then return nil end
        for _, i2 in ipairs(find_all("BP_VehicleInfoObject_C")) do
            if live(i2) then
                local ok, cid = pcall(function() return text_of(i2.CarId) end)
                if ok and cid == id then
                    idx.by[id] = i2
                    return i2
                end
            end
        end
        return nil
    end
end

-- A user struct's full field name for a bare name (the editor appends a
-- GUID suffix, e.g. PreviewCarImages_111_<guid>). Looked up from the struct
-- definition, so a game update that re-suffixes fields doesn't break it.
local structFieldCache = {}
local function struct_field(structName, b)
    local key = structName .. "/" .. b
    if structFieldCache[key] ~= nil then return structFieldCache[key] or nil end
    local found = false
    pcall(function()
        local st = FindObject("UserDefinedStruct", structName)
        if valid(st) then
            st:ForEachProperty(function(fp)
                if not found and bare(name_of(fp)) == b then found = name_of(fp) end
            end)
        end
    end)
    structFieldCache[key] = found
    return found or nil
end

---------------------------------------------------------------------------
-- Applying a profile to a car
---------------------------------------------------------------------------
local function mech_on(p) return (p.steps or {}).MechanicalWorkshop == true end
-- Post for Sale counts only for cars the platform leaves at Front Parking
-- (destination 0): a car parked anywhere else is the player's to price.
local function sale_on(p) return p ~= nil and (p.sale or {}).on == true and (p.destination or 0) == 0 end

-- What a car actually needs, by the same tests the game's own automation
-- screen uses to grey a station out; its workers refuse a car by the same
-- tests. A station the car doesn't need is dropped from its task: the robot
-- would park the car there and wait for a worker who never starts.
local function near(a, b, tol) return math.abs(a - b) <= tol end
-- The first time each call runs, the out table's actual keys are logged, so
-- a parameter name that differs at runtime shows up in the log instead of
-- reading as "not needed". Names are the functions' own parameter names from
-- the game's files.
-- A result from whichever out table holds it (see store_item).
local function out_field(name, ...)
    for i = 1, select("#", ...) do
        local t = select(i, ...)
        if type(t) == "table" and t[name] ~= nil then return t[name] end
    end
    return nil
end
local outKeysLogged = {}
local function log_out_keys(what, ok, ...)
    if outKeysLogged[what] == true then return end
    -- Spent by a call that ran and filled a table, so a failed first call
    -- doesn't use up the look at the real names; after 3 tries either way,
    -- so a call that legitimately fills nothing doesn't log forever.
    local filled = false
    for i = 1, select("#", ...) do
        local t = select(i, ...)
        if type(t) == "table" and next(t) ~= nil then filled = true end
    end
    local tries = (tonumber(outKeysLogged[what]) or 0) + 1
    outKeysLogged[what] = ((ok and filled) or tries >= 3) or tries
    -- Every out table passed, since a result can land in any of them.
    local keys = {}
    for i = 1, select("#", ...) do
        local out = select(i, ...)
        if type(out) == "table" then
            for k, v in pairs(out) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(v) end
        end
    end
    table.sort(keys)
    log("out keys " .. what .. (ok and "" or " (call failed)") .. ": " .. (#keys > 0 and table.concat(keys, ", ") or "none"))
end
local function tank_has_fuel()
    local tank = first_live("BP_UndergroundTankSystem_C")
    if not tank then return false end
    local out = {}
    local ok = pcall(function() tank:HasAnyFuel(out) end)
    log_out_keys("HasAnyFuel", ok, out)
    return ok and out.HasFuel == true
end
-- Returns a table of needs (fuel, tyres, body, wash, paint), or nil when the
-- car's record can't be read; the second result holds the readings for the log.
local function car_needs(car)
    local info = info_by_id(car)
    if not info then return nil, "no record" end
    local seen = {}
    local vehicle = nil
    pcall(function() vehicle = info.Vehicle end)
    -- Fuel: the pump worker's own reading (the car's tank 0), within 1 of full is full.
    if valid(vehicle) then
        local o1, o2 = {}, {}
        log_out_keys("GetFuel", pcall(function() vehicle:GetFuel(0, o1) end), o1)
        log_out_keys("GetMaxFuel", pcall(function() vehicle:GetMaxFuel(0, o2) end), o2)
        seen.fuel, seen.max = tonumber(o1.Fuel), tonumber(o2.MaxFuel)
    end
    -- Tyres: any tyre more than 0.1 from the model's best pressure.
    local o = {}
    -- GetTiresPressure(out MIN, out OPT, out MAX): a table per out-parameter.
    local o2, o3 = {}, {}
    log_out_keys("GetTiresPressure", pcall(function() info:GetTiresPressure(o, o2, o3) end), o, o2, o3)
    seen.opt = tonumber(out_field("Out Row Pressure OPT", o, o2, o3))
    local tyres, read = false, false
    if seen.opt then
        pcall(function()
            info.TirePressures:ForEach(function(_, v)
                local okV, pv = pcall(function() return v:get() end)
                local pr = tonumber(okV and pv or v)
                if pr then
                    read = true
                    if not near(pr, seen.opt, 0.1) then tyres = true end
                end
            end)
        end)
    end
    -- In the apply log: whether the tyres need air, or couldn't be read (an
    -- unreadable pressure skips the compressor, so the log says which it was).
    seen.tyres = read and (tyres and "low" or "ok") or "unread"
    -- A tuned car skips body, wash and paint in the game's automation.
    -- Unreadable counts as tuned: that skips body, wash and paint, the safe side.
    -- An empty string is a real reading (the game's own test finds no tuning
    -- in it); only a failed read or a missing field is unread.
    local okJ, raw = pcall(function() return info.GarageVehicleJsonData end)
    if okJ and raw ~= nil then
        seen.tuning = text_of(raw):find("BP_VehicleTuningComponent_C", 1, true) ~= nil
    else
        seen.tuning = "unread"
    end
    local tuned = seen.tuning ~= false
    local function score(fn)
        local out = {}
        local ok = pcall(function() info[fn](info, out) end)
        log_out_keys(fn, ok, out)
        return ok and tonumber(out.Score) or nil
    end
    seen.body, seen.visuals = score("GetScoreForBodyWork"), score("GetScoreForVisuals")
    local n = {
        fuel = seen.fuel ~= nil and seen.max ~= nil and not near(seen.fuel, seen.max, 1) and tank_has_fuel(),
        tyres = read and tyres,
        body = seen.body ~= nil and seen.body < 0.98 and not tuned,
        wash = seen.visuals ~= nil and seen.visuals < 0.98 and not tuned,
        -- The paint booth paints by itself (the robot doesn't wait for a
        -- worker) and doesn't compare colours, so only tuning rules it out,
        -- as on the game's own screen.
        paint = not tuned,
    }
    return n, seen
end

-- The game's paint colours a profile can pick, in value order 0-15: the
-- task's PaintShop.Color is an E_VehiclePaintColor (Core/Vehicle/
-- VehicleProperties), whose display names by value are Black, Silver, Red,
-- Blue, Purple, NavyBlue, White, Gray, Gold, Green, Brown, Orange, Yellow,
-- Graphite, Light-Blue, Light-Green, then SUPER-SILVER/GOLD/DIAMOND and Custom. The
-- three SUPER colours unlock per model and per car, and Custom isn't offered
-- by the game's automation, so they're left out.
local PAINT_COLORS = { "Black", "Silver", "Red", "Blue", "Purple", "Navy Blue", "White", "Gray", "Gold",
    "Green", "Brown", "Orange", "Yellow", "Graphite", "Light Blue", "Light Green" }

-- `needs` is car_needs' result; nil drops every station that depends on the
-- car's condition, since a station the car doesn't need stalls the robot.
local function want_from_profile(p, needs)
    local m = p.mechanic or {}
    local n = needs or {}
    local steps = {}
    for k, v in pairs(p.steps or {}) do steps[k] = v end
    local gas = p.gas or {}
    local refuel = steps.GasPump == true and gas.RefuelCar == true and n.fuel == true
    local tyres = steps.Compressor == true and gas.PressuriseTires == true and n.tyres == true
    steps.GasPump, steps.Compressor = refuel, tyres
    steps.BodyWorkshop = steps.BodyWorkshop == true and n.body == true
    steps.CarWash = steps.CarWash == true and n.wash == true
    steps.PaintBooth = steps.PaintBooth == true and n.paint == true
    steps.Destination = p.destination or 0
    -- The game won't post an ad without a photo, so Post for Sale keeps the
    -- Photo Studio on (also for a profiles.lua edited by hand).
    if sale_on(p) then steps.PhotoStudio = true end
    return {
        AutomationSteps = steps,
        -- With the Mechanical Workshop station off, its options are sent off too.
        MechanicalWorkshop = {
            ReplaceAllDamagedParts = mech_on(p) and m.mode == "replace",
            CustomizedPartSelection = mech_on(p) and m.mode == "custom",
            DisassembleEverything = mech_on(p) and m.mode == "disassemble",
            PartType = PART_TYPE[m.partType or "Stock"] or 1,
        },
        BodyWorkshop = steps.BodyWorkshop and (p.body or {}) or {},
        GasPumpHub = { RefuelCar = refuel, PressuriseTires = tyres },
        PaintShop = { ChangePartColor = steps.PaintBooth, Color = (p.paint or {}).color or 0 },
    }
end

-- Adds a task built from the profile. Parts for a Custom profile are added
-- separately (add_custom_parts) while the task is still queued.
-- opts.noMech: the car gets the profile's task without its mechanic step
-- (the mechanic has nothing to change on it); every other station still runs.
local function apply_profile(car, profileName, opts)
    local p = profile_of(profileName)
    if not p then return false, "no profile " .. tostring(profileName) end
    local robot = robot_now()
    if not robot then return false, "robot manager not found" end
    local fields = task_fields()
    if not fields then return false, "task struct not found" end
    if mech_on(p) and p.mechanic.mode == "replace" and DLC_TIERS[p.mechanic.partType] and not dlc_ok() then
        return false, "Sport and Race parts need the DLC"
    end
    if mech_on(p) and p.mechanic.mode == "custom" and not dlc_ok() then
        for _, tier in pairs(p.mechanic.slots or {}) do
            if DLC_TIERS[tier] then return false, "Sport and Race parts need the DLC (custom)" end
        end
    end
    local existing, unread = stored_task(robot, car)
    if unread then return false, "task map unreadable" end
    if existing then return false, "car already has a task" end
    local needs, seen = car_needs(car)
    -- Without the car's record its needs are unknown; the car waits and is
    -- tried again rather than getting a task with stations guessed away.
    if not needs then return false, "car record unreadable" end
    local want = want_from_profile(p, needs)
    if opts and opts.noMech then
        want.AutomationSteps.MechanicalWorkshop = false
        want.MechanicalWorkshop = { ReplaceAllDamagedParts = false, CustomizedPartSelection = false,
            DisassembleEverything = false, PartType = want.MechanicalWorkshop.PartType }
    end
    local skipped = {}
    for _, st in ipairs({ "GasPump", "Compressor", "BodyWorkshop", "CarWash", "PaintBooth" }) do
        if (p.steps or {})[st] and not want.AutomationSteps[st] then skipped[#skipped + 1] = st end
    end
    if #skipped > 0 then
        local r = {}
        for k, v in pairs(type(seen) == "table" and seen or { record = seen }) do r[#r + 1] = k .. "=" .. tostring(v) end
        table.sort(r)
        log("apply " .. car .. ": not needed, skipped " .. table.concat(skipped, ",") .. " (" .. table.concat(r, " ") .. ")")
    end
    local value = build_task(fields, want, car)
    local ok, err = pcall(function() return robot["Add Automation Task"](robot, value) end)
    if not ok then return false, "Add Automation Task failed: " .. tostring(err) end
    local back, unreadAfter = stored_task(robot, car)
    if unreadAfter then return false, "task map unreadable after the add" end
    if not back then return false, "task not in the map after the add" end
    return true
end

-- Storage and map writes, each confirmed by reading the result back.
-- UE4SS takes one table per out-parameter; some builds write every result
-- into the first table, newer ones give each its own, so a result is read
-- from whichever table has it.
-- BC_ItemContainer AddItem(Item, ForceAdd, out Success, out ItemStack).
local function store_item(st, it)
    local out, out2 = {}, {}
    local ok, err = pcall(function() st:AddItem(it, false, out, out2) end)
    log_out_keys("AddItem", ok, out, out2)
    if not ok then log("AddItem failed: " .. tostring(err)) end
    return ok and out_field("Success", out, out2) == true
end
-- BC_ItemContainer RemoveItem(Item, out Success).
local function take_item(st, it)
    local out = {}
    local ok, err = pcall(function() st:RemoveItem(it, out) end)
    log_out_keys("RemoveItem", ok, out)
    if not ok then log("RemoveItem failed: " .. tostring(err)) end
    return ok and out_field("Success", out) == true
end
-- Two handles to one object compare by full name, not by the Lua value.
local function same_obj(a, b)
    local okA, na = pcall(function() return a:GetFullName() end)
    local okB, nb = pcall(function() return b:GetFullName() end)
    return okA and okB and na ~= nil and na == nb
end
-- The map holds this key with this very object (an Add on a key already
-- there replaces it, so the key alone proves nothing).
local function map_has(map, key, value)
    local want, found = text_of(key), false
    pcall(function()
        map:ForEach(function(k, v)
            local okK, kv = pcall(function() return k:get() end)
            local okV, vv = pcall(function() return v:get() end)
            if not found and text_of(okK and kv or k) == want and okV and same_obj(vv, value) then found = true end
        end)
    end)
    return found
end

---------------------------------------------------------------------------
-- Custom parts
-- Slot keys are the game's own FNames for the task's parts map. Each tiered
-- slot's part class is BP_Product_CarPart_<Base>_C, with _Sport_C and _Race_C
-- variants (all three ship in the game's files); the windshield has only the
-- base class. Fuse slots are numbered and untiered, so a Custom profile
-- doesn't cover them.
---------------------------------------------------------------------------
local SLOT_BASE = {
    Battery = "Battery", Catalytic = "CatalyticConverter", ClutchDisk = "Clutch", Engine = "Engine",
    FrontBrakeClipL = "BrakeClips", FrontBrakeClipR = "BrakeClips", RearBrakeClipL = "BrakeClips", RearBrakeClipR = "BrakeClips",
    FrontBrakeDiscL = "BrakeDisc", FrontBrakeDiscR = "BrakeDisc", RearBrakeDiscL = "BrakeDisc", RearBrakeDiscR = "BrakeDisc",
    FrontShockAbsorberL = "FrontShockAbsorber", FrontShockAbsorberR = "FrontShockAbsorber",
    RearShockAbsorberL = "RearShockAbsorber", RearShockAbsorberR = "RearShockAbsorber",
    LeftSuspentionPin = "SupsensionArmPin", RightSuspentionPin = "SupsensionArmPin",
    MainFold = "ExhaustManifold", Muffler = "ExhaustMuffler", Resonator = "ExhaustResonator", TailPipe = "TailPipe",
    Radiator = "Intercooler", Windshield = "Windshield",
}
local STOCK_ONLY = { Windshield = true }
-- In the order of the game's own Customize screen: Brake, Suspension,
-- Exhaust, Electric Parts, Other.
local SLOT_NAMES = {
    "FrontBrakeClipL", "FrontBrakeClipR", "RearBrakeClipL", "RearBrakeClipR",
    "FrontBrakeDiscL", "FrontBrakeDiscR", "RearBrakeDiscL", "RearBrakeDiscR",
    "FrontShockAbsorberL", "FrontShockAbsorberR", "RearShockAbsorberL", "RearShockAbsorberR",
    "LeftSuspentionPin", "RightSuspentionPin",
    "MainFold", "Catalytic", "TailPipe", "Resonator", "Muffler",
    "Battery",
    "Engine", "Radiator", "ClutchDisk", "Windshield",
}
local SLOT_LABELS = {
    FrontBrakeClipL = "Front Left Brake Caliper", FrontBrakeClipR = "Front Right Brake Caliper",
    RearBrakeClipL = "Rear Left Brake Caliper", RearBrakeClipR = "Rear Right Brake Caliper",
    FrontBrakeDiscL = "Front Left Brake Disc", FrontBrakeDiscR = "Front Right Brake Disc",
    RearBrakeDiscL = "Rear Left Brake Disc", RearBrakeDiscR = "Rear Right Brake Disc",
    FrontShockAbsorberL = "Front Left Shock Absorber", FrontShockAbsorberR = "Front Right Shock Absorber",
    RearShockAbsorberL = "Rear Left Shock Absorber", RearShockAbsorberR = "Rear Right Shock Absorber",
    LeftSuspentionPin = "Left Suspension Arm Pin", RightSuspentionPin = "Right Suspension Arm Pin",
    MainFold = "Exhaust Manifold", Catalytic = "Catalytic Converter", TailPipe = "Tail Pipe",
    Resonator = "Resonator", Muffler = "Muffler", Battery = "Battery",
    Engine = "Engine", Radiator = "Radiator", ClutchDisk = "Clutch", Windshield = "Windshield",
}

local function slot_class(slot, tier)
    local base = SLOT_BASE[slot]
    if not base then return nil end
    if tier == "Sport" and not STOCK_ONLY[slot] then return "BP_Product_CarPart_" .. base .. "_Sport_C" end
    if tier == "Race" and not STOCK_ONLY[slot] then return "BP_Product_CarPart_" .. base .. "_Race_C" end
    return "BP_Product_CarPart_" .. base .. "_C"
end

local function player_storage()
    for _, gm in ipairs(find_all("BP_GameMode_C")) do
        if live(gm) then
            local ok, st = pcall(function() return gm.BPC_PlayerStorage end)
            if ok and valid(st) then return st end
        end
    end
    return nil
end

-- Storage's Items array holds stacks (ItemClass + ItemInstances). Returns
-- class name -> list of item objects, and how many stacks couldn't be read.
local function storage_by_class(st)
    local byClass, bad = {}, 0
    local ok = pcall(function()
        st.Items:ForEach(function(_, e)
            local okG, stack = pcall(function() return e:get() end)
            if not (okG and valid(stack)) then bad = bad + 1 return end
            local okC, cls = pcall(function() return stack.ItemClass end)
            if not (okC and valid(cls)) then bad = bad + 1 return end
            local cn = name_of(cls)
            pcall(function()
                stack.ItemInstances:ForEach(function(_, ie)
                    local okI, it = pcall(function() return ie:get() end)
                    if okI and valid(it) then
                        byClass[cn] = byClass[cn] or {}
                        table.insert(byClass[cn], it)
                    end
                end)
            end)
        end)
    end)
    if not ok then return nil, bad end
    -- Only parts in full condition count, best last (taken first by
    -- table.remove): storage also holds worn parts taken off cars, and a
    -- Custom job once refitted a car's own 7% clutch. Durability reads as a
    -- fraction or a percentage depending on the part, so either full mark counts.
    local function dur(it)
        local okD, d = pcall(function() return it.Durability end)
        return (okD and type(d) == "number") and d or -1
    end
    for cn, list in pairs(byClass) do
        local fresh = {}
        for _, it in ipairs(list) do
            local d = dur(it)
            if (d >= 0.995 and d <= 1.005) or d >= 99.5 then fresh[#fresh + 1] = it end
        end
        table.sort(fresh, function(a, b) return dur(a) < dur(b) end)
        byClass[cn] = fresh
    end
    return byClass, bad
end

-- Puts the profile's parts on a car's task. The robot works from its own copy
-- of a task (CurrentTaskOrder), taken when it starts on the car and written
-- back over the stored task at the first station; a free robot takes a car in
-- the same moment the car gets its task. So when the robot is already on this
-- car, the parts go on its copy as well as the stored task. Every write
-- happens in this one call. All parts are found before any is taken; on any
-- failure the parts taken so far go back to storage, but only once they're
-- off every list they were put on.
-- With checkOnly, it only checks that every part is in storage, before the
-- car is given its task: a car whose parts are missing then gets no task at
-- all, instead of one with an empty parts list.
local function add_custom_parts(car, profileName, checkOnly)
    local p = profiles[profileName]
    if not (p and p.mechanic and p.mechanic.mode == "custom") then return false, "not a Custom profile" end
    local missingSlots = custom_missing(p, SLOT_NAMES)
    if #missingSlots > 0 then return false, "profile has unset slots: " .. table.concat(missingSlots, ", ") end
    if not dlc_ok() then
        for _, tier in pairs(p.mechanic.slots) do
            if DLC_TIERS[tier] then return false, "Sport and Race parts need the DLC (custom)" end
        end
    end
    local robot = robot_now()
    if not robot then return false, "robot manager not found" end
    local fields = task_fields()
    local mw = fields and field_named(fields, "MechanicalWorkshop")
    local ptc = mw and field_named(mw[3], "PartsToChange")
    local sto = ptc and field_named(ptc[3], "CarPartsForSwap_Storage")
    if not sto then return false, "task struct not found" end
    local st = player_storage()
    if not st then return false, "player storage not found" end
    local byClass, bad = storage_by_class(st)
    if not byClass then return false, "storage unreadable" end
    if bad > 0 then return false, bad .. " storage stacks unreadable" end
    -- Storage per class as picked from, for the count check after the take.
    local before = {}
    for cls, list in pairs(byClass) do before[cls] = #list end
    -- Pick every part first, so nothing is taken unless all are there.
    local picks, short = {}, {}
    for _, slot in ipairs(SLOT_NAMES) do
        local cls = slot_class(slot, p.mechanic.slots[slot])
        local pool = byClass[cls]
        if pool and #pool > 0 then picks[#picks + 1] = { slot, table.remove(pool), cls }
        else short[#short + 1] = slot .. " (" .. tostring(cls) .. ")" end
    end
    -- On the real call this returns without removing the task apply_profile
    -- just added. That's safe only because intake runs the check-only call
    -- first in the same tick, with nothing able to change storage between.
    if #short > 0 then return false, "missing in storage: " .. table.concat(short, ", ") end
    if checkOnly then return true end
    local cur, why = current_car(robot)
    -- Not knowing which car the robot has is treated as "it may have this one":
    -- the parts wait (taking them now could lose them on the robot's copy).
    if cur == nil then
        log("custom parts " .. car .. ": can't tell which car the robot is on (" .. tostring(why) .. "); parts wait")
        return true, "deferred"
    end
    local task, unread = stored_task(robot, car)
    if unread then return false, "task map unreadable" end
    if not task then return false, "car has no task" end
    local okM, map = pcall(function() return task[mw[1]][ptc[1]][sto[1]] end)
    if not (okM and map) then return false, "task parts list unreadable" end
    local copyMap = nil
    if cur == car then
        -- The robot already has the car and works from its own copy
        -- (CurrentTaskOrder) for the whole job, writing it back over the stored
        -- task at each station; so the parts must be on that copy. An earlier
        -- write there passed a read-back on the same handle yet never reached
        -- the mechanic, so after the write the copy is fetched again from the
        -- robot and checked there (see freshCheck below).
        local okC, cmap = pcall(function() return robot.CurrentTaskOrder[mw[1]][ptc[1]][sto[1]] end)
        if not (okC and cmap) then
            log("custom parts " .. car .. ": the robot has the car and its copy can't be read; no parts taken")
            return true, "no parts: the robot's copy couldn't be read"
        end
        copyMap = cmap
    end
    local taken, added = {}, {}
    -- On a failure the task comes off first and is checked gone; only then do
    -- the parts taken so far go back to storage. If the task can't be removed,
    -- the parts stay on it (taken from storage and on the task, so nothing is
    -- doubled) and the reason says so.
    -- toReturn: the parts to put back in storage (all taken, by default).
    local function put_back(reason, toReturn)
        toReturn = toReturn or taken
        if copyMap then
            -- The robot is driving this car on its own copy, so the task stays;
            -- the parts come off both lists, and go back only once they're off.
            -- Only the slots this call added: the robot's copy may hold others.
            for _, pk in ipairs(added) do
                pcall(function() map:Remove(FName(pk[1])) end)
                pcall(function() copyMap:Remove(FName(pk[1])) end)
            end
            for _, it in ipairs(taken) do
                for _, pk in ipairs(picks) do
                    if same_obj(pk[2], it) and (map_has(map, pk[1], it) or map_has(copyMap, pk[1], it)) then
                        log("custom parts " .. car .. ": " .. reason .. "; parts couldn't be taken off the task, " .. #taken .. " left on it")
                        return false, reason .. "; parts left on the task"
                    end
                end
            end
            local back = 0
            for _, it in ipairs(toReturn) do if store_item(st, it) then back = back + 1 end end
            log("custom parts " .. car .. ": " .. reason .. "; parts taken off the task, " .. back .. " of " .. #toReturn .. " returned to storage")
            return false, reason .. "; " .. back .. " of " .. #toReturn .. " parts returned to storage", back == #toReturn
        end
        pcall(function() robot["Remove Automation Task"](robot, car, false) end)
        local still, unreadNow = stored_task(robot, car)
        if still or unreadNow then
            log("custom parts " .. car .. ": " .. reason .. "; the task could not be removed, " .. #taken .. " parts left on it")
            return false, reason .. "; task kept with " .. #taken .. " parts on it"
        end
        local back = 0
        for _, it in ipairs(toReturn) do
            if store_item(st, it) then back = back + 1 end
        end
        log("custom parts " .. car .. ": " .. reason .. "; task removed, " .. back .. " of " .. #toReturn .. " parts returned to storage")
        return false, reason .. "; task removed, " .. back .. " of " .. #toReturn .. " parts returned to storage", back == #toReturn
    end
    -- RemoveItem's Success isn't proof a part left storage: one run logged 24
    -- successes while Parts Manager still showed the same number of complete
    -- builds (whether storage really kept them is unconfirmed). So storage is
    -- counted per class after the take and must have dropped by exactly what
    -- was taken.
    for _, pk in ipairs(picks) do
        local slot, item = pk[1], pk[2]
        if not take_item(st, item) then return put_back("couldn't take " .. pk[3] .. " from storage") end
        taken[#taken + 1] = item
        pcall(function() map:Add(FName(slot), item) end)
        added[#added + 1] = pk
        if copyMap then pcall(function() copyMap:Add(FName(slot), item) end) end
    end
    -- Read back: every slot must hold the very part taken for it, on the task
    -- and on the robot's copy when it has one: that copy fetched again from
    -- the robot, not the handle the write went through (a detached copy would
    -- pass a same-handle check).
    for _, pk in ipairs(picks) do
        if not map_has(map, pk[1], pk[2]) then return put_back("slot " .. pk[1] .. " not on the task after the add") end
    end
    if copyMap then
        local okF, fresh = pcall(function() return robot.CurrentTaskOrder[mw[1]][ptc[1]][sto[1]] end)
        if not (okF and fresh) then
            -- A re-fetch that failed proves nothing either way: undone, and said so.
            local _, whyB, clean = put_back("the robot's copy couldn't be re-read after the add")
            if not clean then return false, whyB end
            return true, "no parts: the robot's copy couldn't be re-read"
        end
        local sameOk, freshOk = 0, 0
        for _, pk in ipairs(picks) do
            if map_has(copyMap, pk[1], pk[2]) then sameOk = sameOk + 1 end
            if map_has(fresh, pk[1], pk[2]) then freshOk = freshOk + 1 end
        end
        log("custom parts " .. car .. ": robot's copy holds " .. sameOk .. "/" .. #picks .. " through the write handle, "
            .. freshOk .. "/" .. #picks .. " fetched again")
        if freshOk < #picks then
            -- Not on the robot's real copy: the parts come back off and go back
            -- to storage; the car carries on without them.
            local _, whyB, clean = put_back("the robot's copy didn't take the parts (" .. freshOk .. "/" .. #picks .. ")")
            if not clean then return false, whyB end
            return true, "no parts: the robot's copy didn't take them"
        end
    end
    local bc2, bad2 = storage_by_class(st)
    if not bc2 or bad2 > 0 then
        -- A count that failed is no reason to change anything: the parts are on
        -- the task (read back above), so they stay, and the log says the debit
        -- couldn't be checked.
        log("custom parts " .. car .. ": " .. #picks .. " parts on the task" .. (copyMap and " and the robot's copy" or "")
            .. "; storage couldn't be re-read, so the debit is unverified")
        return true
    end
    -- Each taken part must be gone from storage: checked by identity (its
    -- full name against what storage still holds), not by a count, which a
    -- different part leaving could fake. Only parts that really left go back.
    -- A name that won't read makes the check unverifiable (neither "left" nor
    -- "still in"), and like a failed re-read that changes nothing.
    local stillIn, unreadable = {}, 0
    for _, list in pairs(bc2) do
        for _, it in ipairs(list) do
            local okN, nm = pcall(function() return it:GetFullName() end)
            if okN and nm then stillIn[nm] = true else unreadable = unreadable + 1 end
        end
    end
    local pickNames = {}
    for i, pk in ipairs(picks) do
        local okN, nm = pcall(function() return pk[2]:GetFullName() end)
        if okN and nm then pickNames[i] = nm else unreadable = unreadable + 1 end
    end
    if unreadable > 0 then
        log("custom parts " .. car .. ": " .. #picks .. " parts on the task" .. (copyMap and " and the robot's copy" or "")
            .. "; " .. unreadable .. " part names couldn't be read, so the debit is unverified")
        return true
    end
    local toReturn, notLeft = {}, 0
    for i, pk in ipairs(picks) do
        if not stillIn[pickNames[i]] then toReturn[#toReturn + 1] = pk[2]
        else notLeft = notLeft + 1 end
    end
    if notLeft > 0 then
        local detail, want = {}, {}
        for _, pk in ipairs(picks) do want[pk[3]] = (want[pk[3]] or 0) + 1 end
        for cls, n in pairs(want) do
            local dropped = (before[cls] or 0) - #(bc2[cls] or {})
            if dropped ~= n then detail[#detail + 1] = cls .. " " .. dropped .. "/" .. n end
        end
        return put_back(notLeft .. " of " .. #picks .. " parts still in storage after being taken (count dropped/taken: "
            .. table.concat(detail, ", ") .. ")", toReturn)
    end
    log("custom parts " .. car .. ": " .. #picks .. " parts on the task" .. (copyMap and " and the robot's copy" or "")
        .. ", " .. #picks .. " left storage")
    return true
end

---------------------------------------------------------------------------
-- Intake: a car on a warehouse bay (ZoneType 7) with a profile assigned and
-- no task gets its profile applied. A car with no profile waits.
---------------------------------------------------------------------------
local function bay_cars()
    local cars = {}
    for _, slot in ipairs(find_all("BP_ParkingSlot_Automation_C")) do
        if live(slot) then
            local okZ, zt = pcall(function() return slot.ZoneType end)
            local okV, v = pcall(function() return slot.ParkingSlotVehicle end)
            -- Automation spots are the ones with a robot route marker; the level
            -- has other warehouse-parking slots (by the storage bays) without one.
            local okW, wp = pcall(function() return slot.AutomationWaypointRef end)
            if okZ and tonumber(zt) == 7 and okV and valid(v) and okW and valid(wp) then
                local id = car_id_of(v)
                if id and id ~= "" then cars[#cars + 1] = { id = id, vehicle = v } end
            end
        end
    end
    return cars
end

-- A car whose profile keeps failing is tried a few times, then left for
-- the player to look at, so a persistent problem doesn't repeat forever.
local MAX_TRIES = 3
-- failures holds retry counts by car id, plus two kinds of extra key (no
-- top-level local to spare for their own tables): "<id>@" = the time a parts
-- wait started (a number) and "<id>#parts" = a profile name whose parts are
-- waiting (a string). Code that walks it must check the key first.
local failures, lastReason = {}, {}
-- Cars whose task just ended on a Post for Sale profile, by car id: the
-- profile name and when the task ended. Checked by the main loop. A key
-- "@<id>" (true) marks a car seen with a task in this session; code that
-- walks the table must skip those keys.
local salePending = {}

local function intake_tick()
    local robot = robot_now()
    if not robot then return end
    -- The parts, fuses and fluids for a Replace Damaged job, picked by the
    -- game's own mechanic dialogue the way its automation page does: open the
    -- dialogue on the car, choose the part type, press Replace All, read the
    -- worker's picks, then clear them and close. The robot and the mechanic
    -- act only on these lists, so a job without them is closed with no work.
    -- Returns { storage = {slot -> part}, fluids = {kind -> value}, fuses = {...}, n = count } or nil and why.
    local function plan_parts(car, partType, mode)
        local info = info_by_id(car)
        local worker = first_live("BP_Worker_MechanicalWorkshop_C")
        if not info then return nil, "car record unreadable" end
        if not worker then return nil, "no mechanic hired" end
        local function step(name, fn)
            local ok, err = pcall(fn)
            return ok, name .. "=" .. (ok and "ok" or tostring(err):gsub("^.-main%.lua:%d+: ", ""):sub(1, 200))
        end
        local trail = {}
        local function run(name, fn)
            local ok, line = step(name, fn)
            trail[#trail + 1] = line
            return ok
        end
        -- CreateDialogue (one out-parameter, the widget) rather than
        -- CreateSimpleDialogue, whose out-delegates UE4SS can't store into.
        local o1 = {}
        run("keep", function() worker:AutomationBuforAlreadyScheduledParts() end)
        run("open", function() worker:CreateDialogue(o1) end)
        local okD, dlg = pcall(function() return worker.DialogueWidget end)
        if not (okD and valid(dlg)) then dlg = out_field("Widget", o1) end
        local plan, picked = nil, nil
        if valid(dlg) then
            run("hide", function() dlg:SetVisibility(2) end)
            if run("setup", function() dlg["Schedule Mechanical Work"](dlg, info, worker, true) end)
                and run("type", function() dlg.WBP_SwitchCarPartSelector:SelectOption(partType) end)
                and run(mode == "disassemble" and "disassembleAll" or "replaceAll", function()
                    if mode == "disassemble" then dlg:ForceClickDissasembleAll() else dlg:ForceClickReplaceAll() end
                end) then
                local outs = { {}, {}, {}, {}, {}, {} }
                if run("read", function() worker:GetCarPartsToChange(outs[1], outs[2], outs[3], outs[4], outs[5], outs[6]) end) then
                    -- UE4SS hands map out-parameters back as plain Lua tables whose
                    -- keys and values are handles into the call's own memory, gone
                    -- once it returns: writing those into the task crashed the game.
                    -- So each one is resolved here, at once: a key to its text (or
                    -- number), a value to the object or plain value it holds.
                    local bad = 0
                    local function resolve(h)
                        local okG, got = pcall(function() return h:get() end)
                        if okG then h = got end
                        if type(h) == "userdata" and not valid(h) then
                            local okT, txt = pcall(function() return h:ToString() end)
                            if okT and type(txt) == "string" then return txt end
                        end
                        return h
                    end
                    local function tbl(n)
                        local v = out_field(n, table.unpack(outs))
                        local t = {}
                        local function put(k, x)
                            local key, val = resolve(k), resolve(x)
                            if type(key) ~= "string" and type(key) ~= "number" then bad = bad + 1 return end
                            t[key] = val
                        end
                        if type(v) == "table" then for k, x in pairs(v) do put(k, x) end
                        elseif v ~= nil then pcall(function() v:ForEach(put) end) end
                        return t
                    end
                    -- The two name lists (fuses to swap, parts to take off), kept in order.
                    local function names(n)
                        local t, out = tbl(n), {}
                        local idx = {}
                        for k in pairs(t) do idx[#idx + 1] = k end
                        table.sort(idx, function(a, b) return tostring(a) < tostring(b) end)
                        for _, k in ipairs(idx) do
                            local v = t[k]
                            if type(v) == "string" then out[#out + 1] = v else bad = bad + 1 end
                        end
                        return out
                    end
                    -- Array out-parameters don't come back from UE4SS at all (the
                    -- take-off list read empty on a Disassemble), so the two name
                    -- lists are read from the worker's own fields, before the clear.
                    local function worker_names(field, fallback)
                        local out, okA, arr = {}, pcall(function() return worker[field] end)
                        if okA and arr then
                            pcall(function()
                                for i = 1, #arr do
                                    local e = arr[i]
                                    local okE, ev = pcall(function() return e:get() end)
                                    if okE then e = ev end
                                    local okT, txt = pcall(function() return e:ToString() end)
                                    out[#out + 1] = (okT and type(txt) == "string") and txt or text_of(e)
                                end
                            end)
                        end
                        if #out == 0 then out = names(fallback) end
                        return out
                    end
                    -- Each part row's condition as the dialogue shows it, by slot:
                    -- a fallback for Custom's all-or-nothing check.
                    local cond = {}
                    for _, rn in ipairs({ "Battery", "BrakeClipLF", "BrakeClipLR", "BrakeClipRF", "BrakeClipRR", "BrakeDiscLF",
                        "BrakeDiscLR", "BrakeDiscRF", "BrakeDiscRR", "Clutch", "Engine", "ExhaustCatalyticConverter",
                        "ExhaustMainfold", "ExhaustMuffer", "ExhaustResonator", "ExhaustTailPipe", "Intercooler",
                        "ShockAbsorberLF", "ShockAbsorberLR", "ShockAbsorberRF", "ShockAbsorberRR", "SuspensionPinLF",
                        "SuspensionPinRF", "Windshield" }) do
                        pcall(function()
                            local row = dlg["CarPart_" .. rn]
                            if not valid(row) then return end
                            local key = text_of(row.CarPartIndex)
                            local inst = row.IsCarPartInstalled
                            -- The row's condition is only kept as the text it shows
                            -- ("79%"); the game's own condition call returns its state
                            -- struct as an out-parameter, which UE4SS doesn't hand back.
                            local txt = ""
                            pcall(function() txt = row.Text_InstalledDuration:GetText():ToString() end)
                            local num = tostring(txt):match("(%d+[%.,]?%d*)%s*%%")
                            local pct = num and tonumber((num:gsub(",", "."))) or nil
                            if key and key ~= "" then cond[key] = { d = pct and pct / 100 or nil, installed = inst, txt = txt } end
                        end)
                    end
                    -- Each fluid's level as its row shows it, keyed by fluid type (the
                    -- same numbers as the plan's FluidsToChange keys).
                    local fluidLevel = {}
                    for _, rn in ipairs({ "EngineFluid", "BrakeFluid", "CoolerFluid" }) do
                        pcall(function()
                            local row = dlg["CarPart_" .. rn]
                            if not valid(row) then return end
                            local ft = row.E_FluidType
                            local txt = ""
                            pcall(function() txt = row.Text_InstalledDuration:GetText():ToString() end)
                            local num = tostring(txt):match("(%d+[%.,]?%d*)%s*%%")
                            local pct = num and tonumber((num:gsub(",", "."))) or nil
                            if type(ft) == "number" then fluidLevel[ft] = pct end
                        end)
                    end
                    local fl = {}
                    for k, v in pairs(fluidLevel) do fl[#fl + 1] = tostring(k) .. "=" .. tostring(v) end
                    trail[#trail + 1] = "fluid levels " .. (#fl > 0 and table.concat(fl, " ") or "unread")
                    local n, first = 0, nil
                    for k, v in pairs(cond) do
                        n = n + 1
                        first = first or (k .. " installed=" .. tostring(v.installed) .. " text='" .. tostring(v.txt) .. "'")
                    end
                    trail[#trail + 1] = "rows " .. n .. (first and (" (" .. first .. ")") or "")
                    picked = tbl("CarPartsForSwap_Storage")
                    plan = { storage = picked, cond = cond, fluidLevel = fluidLevel, fluids = tbl("FluidsToChange"),
                        fuses = worker_names("FusesToSwap_Keys", "FusesToSwap_Keys"), off = worker_names("CarPartsToDisassemble", "CarPartsToDisassemble"),
                        offFuses = out_field("DisassembleFusses", table.unpack(outs)) == true, n = 0 }
                    local counts = {}
                    -- Replace All ticks every fluid even on a car with full fluids. With
                    -- no part or fuse to change, a fluid at full is dropped, so a car
                    -- with nothing to do skips the mechanic instead of having full
                    -- fluids changed. With parts to change, the game's pick stands.
                    if mode ~= "disassemble" and next(plan.storage) == nil and #plan.fuses == 0 then
                        for k in pairs(plan.fluids) do
                            local lv = plan.fluidLevel[k]
                            if type(lv) == "number" and lv >= 99.5 then plan.fluids[k] = nil end
                        end
                    end
                    for _, k in ipairs({ "storage", "fluids", "fuses", "off" }) do
                        local c = 0
                        for _ in pairs(plan[k]) do c = c + 1 end
                        counts[#counts + 1] = k .. " " .. c
                        plan.n = plan.n + c
                    end
                    if plan.offFuses then plan.n = plan.n + 1 end
                    local keys = {}
                    for k, v in pairs(plan.storage) do keys[#keys + 1] = tostring(k) .. ":" .. prop_type(v):gsub("^BP_Product_CarPart_", ""):gsub("_C$", "") end
                    table.sort(keys)
                    log("plan " .. car .. " slots: " .. table.concat(keys, " "))
                    if #plan.fuses > 0 or #plan.off > 0 then
                        log("plan " .. car .. " names: fuses " .. table.concat(plan.fuses, ",") .. " | off " .. table.concat(plan.off, ","))
                    end
                    trail[#trail + 1] = table.concat(counts, ", ") .. (plan.offFuses and ", fuses off" or "") .. (bad > 0 and (", " .. bad .. " unreadable keys") or "")
                    -- Every storage pick must be a live part object, or the plan is refused.
                    for slot, part in pairs(plan.storage) do
                        if not valid(part) then
                            trail[#trail + 1] = "slot " .. tostring(slot) .. " holds no part"
                            plan = nil
                            break
                        end
                    end
                    if plan and bad > 0 then plan = nil end
                end
            end
        else
            trail[#trail + 1] = "no dialogue"
        end
        run("clear", function() worker:AutomationClearPartsToChange() end)
        if valid(dlg) then run("close", function() worker:DestroyDialogue() end) end
        log("plan " .. car .. " type " .. partType .. ": " .. table.concat(trail, " "))
        if not plan then
            -- The pick already took its parts out of storage; a refused plan
            -- puts every one it can still name back, so none is lost.
            local st, n, back = player_storage(), 0, 0
            for _, it in pairs(picked or {}) do
                if valid(it) then
                    n = n + 1
                    if st and store_item(st, it) then back = back + 1 end
                end
            end
            if n > 0 then log("plan " .. car .. ": refused, " .. back .. " of " .. n .. " picked parts back to storage") end
            return nil, "the mechanic's parts list couldn't be read"
        end
        return plan
    end
    -- Writes a plan's lists onto the car's stored task, and onto the robot's
    -- own copy when it already has the car; each count is read back.
    local function add_plan(car, plan)
        local fields = task_fields()
        local mw = fields and field_named(fields, "MechanicalWorkshop")
        local ptc = mw and field_named(mw[3], "PartsToChange")
        if not ptc then return false, "task struct not found" end
        local names = {}
        for _, f in ipairs({ { "storage", "CarPartsForSwap_Storage" }, { "fluids", "FluidsToChange" }, { "fuses", "FusesToSwap_Keys" },
            { "off", "CarPartsToDisassemble" }, { "offFuses", "bDisassembleFusses" } }) do
            local fd = field_named(ptc[3], f[2])
            if fd then names[f[1]] = fd[1] end
        end
        local task, unread = stored_task(robot, car)
        if unread or not task then return false, "car has no task to add parts to" end
        local targets = { { "task", function() return task[mw[1]][ptc[1]] end } }
        if current_car(robot) == car then
            targets[#targets + 1] = { "robot copy", function() return robot.CurrentTaskOrder[mw[1]][ptc[1]] end }
        end
        local report = {}
        for _, tg in ipairs(targets) do
            local okP, parts = pcall(tg[2])
            if not (okP and parts) then return false, tg[1] .. " parts lists unreadable" end
            -- FluidsToChange maps a fluid kind (an enum number) to true; only those
            -- plain values are written, anything else refuses the plan.
            for k, v in pairs(plan.fluids) do
                if type(k) ~= "number" or type(v) ~= "boolean" then
                    return false, "fluid entry of an unexpected type (" .. type(k) .. "=" .. type(v) .. ")"
                end
            end
            for kind, list in pairs({ storage = plan.storage, fluids = plan.fluids }) do
                local okM, map = pcall(function() return parts[names[kind]] end)
                if names[kind] and okM and map then
                    local want = 0
                    for k, v in pairs(list) do
                        local key = (kind == "storage") and FName(tostring(k)) or k
                        pcall(function() map:Add(key, v) end)
                        want = want + 1
                    end
                    local n = 0
                    pcall(function() map:ForEach(function() n = n + 1 end) end)
                    report[#report + 1] = tg[1] .. " " .. kind .. " " .. n .. "/" .. want
                    if n < want then
                        log("parts " .. car .. ": " .. table.concat(report, ", "))
                        return false, tg[1] .. " " .. kind .. " holds " .. n .. " of " .. want
                    end
                end
            end
            -- Name lists: written one entry at a time from index 1, in order and
            -- with no gaps (the only safe way on this UE4SS build, as Reset does),
            -- then read back by name.
            for kind, list in pairs({ fuses = plan.fuses, off = plan.off }) do
                if #list > 0 then
                    local okA, arr = pcall(function() return parts[names[kind]] end)
                    if not (names[kind] and okA and arr) then return false, tg[1] .. " " .. kind .. " list unreadable" end
                    for i, nm in ipairs(list) do pcall(function() arr[i] = FName(nm) end) end
                    local got = {}
                    pcall(function() arr:ForEach(function(_, e)
                        local okE, ev = pcall(function() return e:get() end)
                        got[#got + 1] = text_of(okE and ev or e)
                    end) end)
                    local same = #got == #list
                    for i = 1, #list do if got[i] ~= list[i] then same = false end end
                    report[#report + 1] = tg[1] .. " " .. kind .. " " .. #got .. "/" .. #list
                    if not same then
                        log("parts " .. car .. ": " .. table.concat(report, ", "))
                        return false, tg[1] .. " " .. kind .. " list not kept"
                    end
                end
            end
            if plan.offFuses and names.offFuses then
                pcall(function() parts[names.offFuses] = true end)
                local okR, v = pcall(function() return parts[names.offFuses] end)
                report[#report + 1] = tg[1] .. " fuses off " .. tostring(okR and v)
                if not (okR and v == true) then
                    log("parts " .. car .. ": " .. table.concat(report, ", "))
                    return false, tg[1] .. " fuse-removal flag not kept"
                end
            end
        end
        log("parts " .. car .. ": " .. table.concat(report, ", "))
        return true
    end
    -- The profile shown for a car is the one behind its current task, so it
    -- goes once the car has no task (a later task started in the game's own
    -- scanner mustn't show an old profile).
    local entries = task_entries(robot)
    if entries then
        local hasTask, pruned = {}, false
        for _, e in ipairs(entries) do hasTask[e[1]] = true end
        -- The robot's car is out of the task map while the robot carries it
        -- (the game re-adds it at each station), so it still has its task.
        local cur = current_car(robot)
        if cur and cur ~= "" then hasTask[cur] = true end
        for id in pairs(hasTask) do salePending["@" .. id] = true end
        -- A task that goes away counts as done only if the platform took the
        -- car after the profile was applied. One gone before that was removed
        -- by something else (the game's reset, another automation mod): the
        -- profile drops, and no sale check starts for a car that wasn't worked.
        if cur and applied[cur] then failures[cur .. "~carried"] = true end
        for id in pairs(applied) do
            if not hasTask[id] and not failures[id .. "~carried"] then
                log("profile for " .. id .. " (" .. tostring(applied[id]) .. ") dropped: its task was removed before the platform took the car (the game's reset, or another automation mod)")
                salePending["@" .. id] = nil
                applied[id] = nil pruned = true
            elseif not hasTask[id] then
                failures[id .. "~carried"] = nil
                log("profile for " .. id .. " (" .. tostring(applied[id]) .. ") dropped: no task in the map and not the robot's car")
                -- The task is gone and the platform has let the car go: with Post
                -- for Sale on, it should now be on its Front Parking spot. Only
                -- for a car seen with its task in this session: a profile record
                -- left in profiles.lua from an earlier session (the game quit
                -- without saving) is dropped on load, for a car that may never
                -- have been worked on (measured).
                -- A car sent back for photos posts with the profile it first
                -- finished on.
                local sp = (sales[id] and sales[id].back) or applied[id]
                local fp = profile_of(applied[id])
                if salePending["@" .. id] and fp and (fp.destination or 0) == 0 then
                    if sale_on(profile_of(sp)) then
                        salePending[id] = { profile = sp, at = os.clock() }
                        sales[id] = { s = "pending", profile = sp }
                        log("sale " .. id .. ": task done on " .. tostring(applied[id]) .. ", checking the listing")
                    elseif sp ~= "Photos Only" then
                        -- (A Photos Only job whose first profile is no longer known
                        -- leaves no record: it would name a job the player never chose.)
                        sales[id] = { s = "unpriced", profile = sp }
                    end
                end
                salePending["@" .. id] = nil
                applied[id] = nil pruned = true
            end
        end
        -- A mark lasts only while its car has a task, so it stands for this
        -- task, not any task the car had earlier. Cleared after the loop above,
        -- which reads it in the same tick.
        for k in pairs(salePending) do
            local mid = type(k) == "string" and k:match("^@(.+)$")
            if mid and not hasTask[mid] then salePending[k] = nil end
        end
        -- No log on a failed write: this runs every couple of seconds, so it
        -- would flood the log, and the next apply reports the same failure.
        if pruned then save_profiles() end
    end
    -- Custom parts held back while the robot had the car go on once it has set
    -- the car down at a station: its next pickup copies the stored task, parts
    -- included. If the car has already been through the mechanic (or lost its
    -- task), nothing is taken.
    local pending = {}
    for k, prof in pairs(failures) do
        local id = type(k) == "string" and k:match("^(.+)#parts$")
        if id then pending[#pending + 1] = { id = id, prof = prof } end
    end
    if #pending > 0 then
        local cur = current_car(robot)
        local fields = task_fields()
        local asf = fields and field_named(fields, "AutomationSteps")
        local mwf = asf and field_named(asf[3], "MechanicalWorkshop")
        for _, pd in ipairs(pending) do
            -- Each check has three answers; one that can't be read keeps the car
            -- waiting rather than being taken as "no task" or "mechanic done".
            local task, unread = stored_task(robot, pd.id)
            local mechLeft = nil
            if task and asf and mwf then
                -- Only a boolean answers; anything else counts as unread.
                local raw
                local okM = pcall(function() raw = task[asf[1]][mwf[1]] end)
                if okM and type(raw) == "boolean" then mechLeft = raw end
            end
            if cur ~= nil and cur ~= pd.id and not unread and (not task or mechLeft ~= nil) then
                failures[pd.id .. "#parts"] = nil
                if not task or mechLeft == false then
                    log("custom parts " .. pd.id .. ": " .. (task and "the mechanic was already done" or "the car has no task") .. ", so no parts were taken (robot's car read as '" .. tostring(cur) .. "')")
                else
                    local okP, whyP = add_custom_parts(pd.id, pd.prof)
                    if okP and whyP == "deferred" then failures[pd.id .. "#parts"] = pd.prof
                    elseif not okP then log("custom parts " .. pd.id .. ": not added after the wait, " .. tostring(whyP)) end
                end
            end
        end
    end
    for _, c in ipairs(bay_cars()) do
        local profileName = assignments[c.id]
        local existing, unread = stored_task(robot, c.id)
        -- A car waiting only for parts is checked again every 30 seconds, so it
        -- carries on by itself once they're bought (Try Again checks at once).
        local partsWait = lastReason[c.id] and tostring(lastReason[c.id]):find("^missing in storage: ")
            and failures[c.id] and failures[c.id] >= MAX_TRIES and os.clock() - (failures[c.id .. "@"] or 0) >= 30
        if partsWait then failures[c.id] = MAX_TRIES - 1 end
        if profileName and not unread and not existing and (failures[c.id] or 0) < MAX_TRIES then
            local ok, why = true, nil
            local pp = profile_of(profileName)
            local mode = mech_on(pp) and pp.mechanic.mode or nil
            local plan, noMech = nil, false
            -- The game's pick takes its parts out of storage at once (the
            -- mechanic's AddCarPart does), and clearing the pick doesn't put them
            -- back. So any picked part that doesn't end up on a task goes back to
            -- storage here: a job that's refused, or a Custom pick of another tier.
            local function give_back(parts, reason)
                local st, n, back = player_storage(), 0, 0
                for _, it in pairs(parts or {}) do
                    if valid(it) then
                        n = n + 1
                        if st and store_item(st, it) then back = back + 1 end
                    end
                end
                if n > 0 then log("intake " .. c.id .. ": " .. back .. " of " .. n .. " picked parts back to storage (" .. reason .. ")") end
            end
            if mode == "replace" or mode == "disassemble" then
                -- Picked before the task is added, so a car with nothing to do
                -- stays put instead of riding to the mechanic for nothing.
                local okP, res, whyP = pcall(plan_parts, c.id, PART_TYPE[pp.mechanic.partType or "Stock"] or 1, mode)
                if not okP then ok, why = false, "parts plan failed: " .. tostring(res)
                elseif not res then ok, why = false, whyP
                elseif res.n == 0 then
                    -- Nothing for the mechanic: the car still gets the rest of its profile.
                    noMech = true
                    log("intake " .. c.id .. ": nothing for the mechanic (" .. mode .. "), so the task goes without the mechanic step")
                else plan = res end
            elseif mode == "custom" then
                -- Custom is the game's own pick, one per part type the profile
                -- uses: each slot takes the part the game picks for it in that
                -- slot's type, so it fits the car. A slot the game doesn't pick
                -- (it doesn't need replacing, or none of that type is in storage)
                -- is left as it is. The fuses and fluids come from the first pick.
                local tiers, order = {}, {}
                for _, slot in ipairs(SLOT_NAMES) do
                    local t = pp.mechanic.slots[slot] or "Stock"
                    if not tiers[t] then tiers[t] = {} order[#order + 1] = t end
                    tiers[t][slot] = true
                end
                plan = { storage = {}, fluids = {}, fuses = {}, off = {}, offFuses = false, n = 0 }
                for i, t in ipairs(order) do
                    local okP, res, whyP = pcall(plan_parts, c.id, PART_TYPE[t] or 1, "replace")
                    if not (okP and res) then
                        ok, why = false, "parts plan failed (" .. t .. "): " .. tostring(okP and whyP or res)
                        break
                    end
                    local spare = {}
                    for k, it in pairs(res.storage) do
                        local fuseKey = tonumber(k) ~= nil
                        if tiers[t][k] or (fuseKey and i == 1) then plan.storage[k] = it else spare[#spare + 1] = it end
                    end
                    if i == 1 then plan.fluids, plan.fuses, plan.cond = res.fluids, res.fuses, res.cond end
                    give_back(spare, t .. " parts not used by this profile")
                end
                if ok then
                    -- All or nothing: every worn or missing part the profile covers
                    -- must have its pick, or the car gets no task (a part-done car
                    -- mustn't go on to sale). A part's condition is read the way the
                    -- game's dialogue reads it.
                    local info = info_by_id(c.id)
                    local short, unreadSlots, worn = {}, {}, 0
                    for _, slot in ipairs(SLOT_NAMES) do
                        local o1, o2 = {}, {}
                        local okD = info and pcall(function() info:GetPartDurability(FName(slot), o1, o2) end)
                        -- Out-parameters come back as handles into the call; each is
                        -- resolved with get() before it's read, or the read fails.
                        local function got(v)
                            local okG, g = pcall(function() return v:get() end)
                            return okG and g or v
                        end
                        local isValid = got(out_field("IsValid", o1, o2))
                        local st = got(out_field("PartState", o1, o2))
                        local inst, d = nil, nil
                        pcall(function() inst = got(st.Installed) end)
                        pcall(function() d = got(st.Durability) end)
                        if slot == SLOT_NAMES[1] then
                            log("intake " .. c.id .. ": condition read " .. slot .. " ok=" .. tostring(okD) .. " valid=" .. tostring(isValid)
                                .. " state=" .. type(st) .. " installed=" .. tostring(inst) .. " durability=" .. tostring(d))
                        end
                        -- The direct read failing, the dialogue row's reading stands in.
                        if not okD or type(d) ~= "number" then
                            local cr = plan.cond and plan.cond[slot]
                            if cr and type(cr.d) == "number" then
                                okD, isValid, inst, d = true, true, cr.installed, cr.d
                            elseif cr and cr.installed == false then
                                okD, isValid, inst, d = true, true, false, 0
                            end
                        end
                        if not okD or (isValid == true and type(d) ~= "number") then
                            unreadSlots[#unreadSlots + 1] = slot
                        else
                            local full = type(d) == "number" and ((d >= 0.995 and d <= 1.005) or d >= 99.5)
                            if isValid ~= true or inst == false or not full then
                                worn = worn + 1
                                if not plan.storage[slot] then
                                    short[#short + 1] = slot .. " (" .. tostring(slot_class(slot, pp.mechanic.slots[slot] or "Stock")) .. ")"
                                end
                            end
                        end
                    end
                    if #unreadSlots > 0 then
                        ok, why = false, "part condition unreadable: " .. table.concat(unreadSlots, ", ")
                    elseif #short > 0 then
                        ok, why = false, "missing in storage: " .. table.concat(short, ", ")
                    end
                    if not ok then
                        give_back(plan.storage, "not every worn part has its replacement")
                        plan = nil
                    else
                        for _ in pairs(plan.storage) do plan.n = plan.n + 1 end
                        for _ in pairs(plan.fluids) do plan.n = plan.n + 1 end
                        log("intake " .. c.id .. ": custom, " .. worn .. " worn or missing, all picked")
                        if plan.n == 0 then
                            noMech, plan = true, nil
                            log("intake " .. c.id .. ": nothing for the mechanic (custom), so the task goes without the mechanic step")
                        end
                    end
                else
                    give_back(plan.storage, "plan failed")
                end
            end
            if ok then
                ok, why = apply_profile(c.id, profileName, { noMech = noMech })
                if not ok and plan then give_back(plan.storage, "task not added") end
            end
            if ok and plan then
                ok, why = add_plan(c.id, plan)
                -- A job without its parts would be closed with no work, so it
                -- comes off, and its parts go back.
                if not ok then
                    pcall(function() robot["Remove Automation Task"](robot, c.id, false) end)
                    give_back(plan.storage, "parts not kept on the task")
                end
            end
            log("intake " .. c.id .. " profile " .. profileName .. ": " .. (ok and (why == "deferred" and "applied, parts deferred" or (why and ("applied, " .. why) or "applied")) or ("not applied, " .. tostring(why))))
            if ok then
                assignments[c.id] = nil
                applied[c.id] = profileName
                failures[c.id], lastReason[c.id] = nil, nil
                if not save_profiles() then log("intake " .. c.id .. ": applied, but profiles.lua couldn't be written") end
            else
                failures[c.id] = (failures[c.id] or 0) + 1
                lastReason[c.id] = why
                -- Missing parts won't appear by retrying, so the player is told at once.
                if tostring(why):find("^missing in storage: ") then
                    failures[c.id] = MAX_TRIES
                    failures[c.id .. "@"] = os.clock()
                end
                if failures[c.id] >= MAX_TRIES then log("intake " .. c.id .. ": waiting, " .. tostring(why)) end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Targeted reset
-- The game's red reset removes every car's task without returning parts
-- and clears the current bay without a return, so on its own it loses every
-- queued part. This reset deals with one stuck car: its listed parts go back
-- to storage, every other task is copied (part objects included), the game's
-- reset runs to free the robot, and the copies go straight back in the same
-- call, before the dropped part objects can be collected. If the re-add only
-- partly works, the rest are lost, which is no worse than the red reset; it
-- can't duplicate, since those parts were never returned.
---------------------------------------------------------------------------
-- A Lua copy of a task: plain fields by full name (as Add Automation Task
-- takes them), every map's entries kept apart as {key text, value}, and
-- every list of names (the parts to take off, the fuses to swap) kept apart
-- as { names = {...} }. Lists go back onto the stored task after the add,
-- like the maps, so a list the game won't take can't cost the task itself.
local function copy_task(sv, fields, lists, path)
    local PLAIN_TYPES = { BoolProperty = true, ByteProperty = true, IntProperty = true, EnumProperty = true,
        StrProperty = true, NameProperty = true, FloatProperty = true, DoubleProperty = true }
    local t = {}
    for _, f in ipairs(fields) do
        local n, ty, sub = f[1], f[2], f[3]
        local here = path .. "/" .. bare(n)
        if ty == "StructProperty" and sub then
            local ok, inner = pcall(function() return sv[n] end)
            if ok then t[n] = copy_task(inner, sub, lists, here) end
        elseif PLAIN_TYPES[ty] then
            local ok, v = pcall(function() return sv[n] end)
            if ok then t[n] = (ty == "StrProperty" or ty == "NameProperty") and text_of(v) or v end
        elseif ty == "MapProperty" then
            local entries = {}
            pcall(function()
                sv[n]:ForEach(function(k, v)
                    local okK, kv = pcall(function() return k:get() end)
                    local okV, vv = pcall(function() return v:get() end)
                    entries[#entries + 1] = { okK and kv or nil, okV and vv or nil }
                end)
            end)
            if #entries > 0 then lists[here] = entries end
        elseif ty == "ArrayProperty" then
            local names = {}
            pcall(function()
                sv[n]:ForEach(function(_, e)
                    local okE, ev = pcall(function() return e:get() end)
                    names[#names + 1] = text_of(okE and ev or e)
                end)
            end)
            if #names > 0 then lists[here] = { names = names } end
        end
    end
    return t
end

-- The map at a copied path, on the stored task.
local function map_at(task, fields, path)
    local node, fs = task, fields
    for part in path:gmatch("[^/]+") do
        local f = field_named(fs, part)
        if not f then return nil end
        local ok, v = pcall(function() return node[f[1]] end)
        if not ok then return nil end
        node, fs = v, f[3]
    end
    return node
end

-- The stuck car's part objects, read before the reset. They go back to
-- storage only after the reset has removed the task, so a part is never in
-- storage and on a task at once. Returns the list, or nil if a list couldn't
-- be read.
local function parts_of(robot, car)
    local fields = task_fields()
    local mw = field_named(fields, "MechanicalWorkshop")
    local ptc = mw and field_named(mw[3], "PartsToChange")
    local task, unread = stored_task(robot, car)
    if unread or not ptc then return nil end
    local items = {}
    if not task then return items end
    for _, listName in ipairs({ "CarPartsForSwap_Storage", "CarPartsForSwap_Inventory" }) do
        local lf = field_named(ptc[3], listName)
        if lf then
            local okL = pcall(function()
                task[mw[1]][ptc[1]][lf[1]]:ForEach(function(_, v)
                    local ok, it = pcall(function() return v:get() end)
                    if ok and valid(it) then items[#items + 1] = it end
                end)
            end)
            if not okL then return nil end
        end
    end
    -- The station clears the task's Mechanical Workshop step when the mechanic
    -- starts, and the mechanic works from his own copy of the parts. Parts
    -- still listed after that (a task saved before the game emptied the list
    -- at that point) are on the car or with the mechanic, so returning them
    -- would make new ones. An unreadable step keeps the old behaviour.
    local asf = field_named(fields, "AutomationSteps")
    local mwf = asf and field_named(asf[3], "MechanicalWorkshop")
    -- Only a boolean answers; anything else counts as unread. The withheld
    -- parts go with the task, so their names are logged in case one has to
    -- be given back.
    local raw
    local okM = asf and mwf and pcall(function() raw = task[asf[1]][mwf[1]] end)
    if #items > 0 and not (okM and type(raw) == "boolean") then
        local why = (not asf and "no AutomationSteps field") or (not mwf and "no MechanicalWorkshop member")
            or (not okM and "read failed") or ("read as " .. type(raw))
        log("parts for " .. car .. ": Mechanical Workshop step " .. why .. "; parts returned as listed")
    end
    if okM and raw == false and #items > 0 then
        local names = {}
        for _, it in ipairs(items) do names[#names + 1] = name_of(it) end
        log("parts for " .. car .. ": withheld, " .. table.concat(names, ", "))
        return {}, #items
    end
    return items
end

-- After a reset the stuck car is put on a free automation parking spot by
-- the warehouse, so it's out of the station and ready for a new task. A spot
-- is free when no car is parked or standing on it (the spot's own test for
-- whether it can take a car).
local slotClaimed = {}
-- Moves waiting for the spot to report the car (the robot only sees a car a
-- spot reports, and a spot notices a car by overlap, a moment after the move).
local moveChecks = {}
local function free_bay_slot()
    for _, slot in ipairs(find_all("BP_ParkingSlot_Automation_C")) do
        -- A spot just used by a reset isn't offered again for a few seconds,
        -- before the spot itself has noticed the car.
        local claimed = slotClaimed[name_of(slot)]
        if live(slot) and not (claimed and os.clock() - claimed < 10) then
            local okZ, zt = pcall(function() return slot.ZoneType end)
            local okV, v = pcall(function() return slot.ParkingSlotVehicle end)
            local okO, o = pcall(function() return slot.OnlyVehicleOverlapping end)
            -- Only automation spots (with a route marker), never a storage-bay slot.
            local okW, wp = pcall(function() return slot.AutomationWaypointRef end)
            if okZ and tonumber(zt) == 7 and okV and not valid(v) and okO and not valid(o) and okW and valid(wp) then return slot end
        end
    end
    return nil
end
local function move_to_bay(car, mode)
    local info = info_by_id(car)
    local vehicle = nil
    if info then pcall(function() vehicle = info.Vehicle end) end
    if not valid(vehicle) then return false, "car not found" end
    local slot = free_bay_slot()
    if not slot then return false, "no free spot" end
    local okL, loc = pcall(function() return slot:K2_GetActorLocation() end)
    local okR, rot = pcall(function() return slot:K2_GetActorRotation() end)
    if not (okL and okR and loc and rot) then return false, "spot position unreadable" end
    -- A little above the spot, so the car settles onto it instead of clipping into the floor.
    local target = { X = loc.X, Y = loc.Y, Z = loc.Z + 10 }
    local okM, moved = pcall(function()
        -- Facing the spot's right vector: the game's own parking check counts a
        -- car as the right way round when its forward vector is within
        -- 0.7..1 (dot product) of the spot's right vector (WrongDirection).
        return vehicle:K2_SetActorLocationAndRotation(target, { Pitch = 0, Yaw = rot.Yaw + 90, Roll = 0 }, false, {}, true)
    end)
    -- A third result says whether the car may have moved: "moved" when the
    -- move went through but its landing couldn't be confirmed, "unknown"
    -- when the move call itself failed.
    if not okM then return false, "move failed: " .. tostring(moved), "unknown" end
    if moved ~= true then return false, "the game refused the move" end
    -- Confirmed by where the car actually is now (height is left out: the car settles).
    local okP, now = pcall(function() return vehicle:K2_GetActorLocation() end)
    if not (okP and now) then return false, "position unreadable after the move", "moved" end
    local dist = math.sqrt((now.X - target.X) ^ 2 + (now.Y - target.Y) ^ 2)
    if dist > 50 then return false, string.format("car is %.0f from the spot after the move", dist), "moved" end
    slotClaimed[name_of(slot)] = os.clock()
    -- This append must stay right before the only "return true": free_robot
    -- takes the last entry as this move's (and logs "in no station or spot"
    -- on that basis).
    moveChecks[#moveChecks + 1] = { car = car, slot = slot, vehicle = vehicle, at = os.clock() }
    log(string.format("%s %s: moved to spot %s (%.0f off, z %.0f -> %.0f)", mode or "move", car, tostring(name_of(slot)), dist, target.Z, now.Z))
    return true
end

-- Puts part objects into storage; returns how many went in.
local function to_storage(st, items)
    local n = 0
    for _, it in ipairs(items) do
        if store_item(st, it) then n = n + 1 end
    end
    return n
end

-- The car standing in a station or spot, or nil, and whether the station is
-- running work (its second value: nil if unread). The shared zone call first:
-- IsRunningAutomatedWork(out IsRunning, out AutomatedCar), a table per
-- out-parameter. Read in the game: IsRunning is true while the station is
-- reserved for work (and for a car not in automation), and then no car is
-- reported, so the station's own car field is read.
local function zone_vehicle(z)
    local o1, o2 = {}, {}
    local okR = pcall(function() z:IsRunningAutomatedWork(o1, o2) end)
    log_out_keys("IsRunningAutomatedWork " .. prop_type(z), okR, o1, o2)
    -- nil when it couldn't be read, so "not working" is never a guess.
    local running = nil
    if okR then
        local r = out_field("IsRunning", o1, o2)
        if r ~= nil then running = (r == true) end
    end
    local car = out_field("AutomatedCar", o1, o2)
    if valid(car) then return car, running end
    for _, f in ipairs({ "VehicleIn", "VehicleInZone", "ParkingSlotVehicle", "OnlyVehicleOverlapping" }) do
        local ok, v = pcall(function() return z[f] end)
        if ok and valid(v) then return v, running end
    end
    return nil, running
end

-- Frees the robot from one car. The game's reset clears every task, so every
-- task is copied first (part objects included) and re-added in the same call,
-- before the dropped part objects can be collected. Any part of a copy that
-- can't go back goes to storage instead, so nothing is lost.
--   mode "reset":   the car's own task is dropped, its parts go to storage,
--                   and the car is moved to a free spot.
--   mode "unstick": the car keeps its task too and is moved to a free spot,
--                   where the robot picks it up again (the reset makes the
--                   station forget its car, so left in the station the robot
--                   would never see it).
-- The game's reset drops the car the robot is carrying wherever it is, in
-- mid-air if need be. So the robot is reset only when it's on this car or on
-- none; when it's on another car it's left alone, and only this car changes:
-- Reset removes just its task, Unstick keeps it, and the car is moved.
-- A zone's station type, from its own GetZoneType (one out-parameter, so one
-- table), then the ZoneType field. With logKeys the out-table's keys are
-- logged, for the reads a player's button press depends on.
local function zone_type(z, logKeys)
    local out = {}
    local ok = pcall(function() z:GetZoneType(out) end)
    if logKeys then log_out_keys("GetZoneType " .. prop_type(z), ok, out) end
    if ok and tonumber(out.ZoneType) then return tonumber(out.ZoneType) end
    local okF, t = pcall(function() return z.ZoneType end)
    return okF and tonumber(t) or nil
end
local function free_robot(car, mode)
    local robot = robot_now()
    if not robot then return false, "robot manager not found" end
    local fields = task_fields()
    if not fields then return false, "task struct not found" end
    local entries = task_entries(robot)
    if not entries then return false, "task map unreadable" end
    local st = player_storage()
    if not st then return false, "player storage not found" end
    local cur = current_car(robot)
    if cur == nil then return false, "can't tell which car the robot is on" end
    local glow = nil
    pcall(function() glow = tonumber(robot.Robot.CurrentGlowStatus) end)
    -- Logged every time, quoted, so what an idle robot's car field reads as
    -- (empty or some placeholder) shows in the log.
    log(string.format("%s %s: robot's car read as '%s', status %s", mode, car, cur, tostring(glow)))
    -- A car on a mechanic's lift while the mechanic is still at work can't be
    -- taken: measured, the lift (still holding it) pulled the moved car back,
    -- the robot then counted the mechanic as done and its parts were never
    -- fitted, and the lift stayed up over an empty bay.
    -- A lift keeps holding a car moved away mid-job, and its bay stays reserved
    -- until the lift comes down, so the refusal needs this car to be in the bay
    -- (otherwise the Reset that returns its parts could never run). The bay's
    -- own car and work state come from zone_vehicle (nil running = unread).
    local info0, veh0 = info_by_id(car), nil
    if info0 then pcall(function() veh0 = info0.Vehicle end) end
    local lifts, holding, onLift = 0, 0, nil
    for _, lift in ipairs(valid(veh0) and find_all("BP_VehicleRepairLift_C") or {}) do
        lifts = lifts + 1
        local okH, held = pcall(function() return lift.VehicleOnLift end)
        if okH and valid(held) then
            holding = holding + 1
            local okHV, heldV = pcall(function() return held.Vehicle end)
            if not onLift and (same_obj(held, info0) or (okHV and valid(heldV) and same_obj(heldV, veh0))) then onLift = lift end
        end
    end
    -- Logged every press, so "not on a lift" can be told from a missed match.
    log(string.format("%s %s: %d lifts, %d holding a car, this car %s", mode, car, lifts, holding, onLift and ("on " .. name_of(onLift)) or "on none"))
    if onLift then
        local okZ, zone = pcall(function() return onLift.RelatedZone end)
        -- RelatedZone is filled only once the game asks for it, so it can be
        -- empty; the bay is then found the way the game's FindRelatedZone
        -- does, by the lift's ZoneIndex against each bay's ID.
        if not (okZ and valid(zone)) then
            local okI, li = pcall(function() return onLift.ZoneIndex end)
            local key = okI and text_of(li) or ""
            zone = nil
            -- The game searches BP_RepairZone and its subclasses. FindAllOf is
            -- exact-class, so the station classes are listed: the same five as
            -- the station scans further down here and in map_state (no room for a
            -- shared main-chunk local), wash/body/mechanic first, where lifts
            -- live.
            for _, cls in ipairs(key ~= "" and { "BP_WashZone_C", "BP_CompressorZone_C", "BP_UndergroundTankSystem_C", "BP_PaintZone_C", "BP_PhotoZone_C" } or {}) do
                for _, z in ipairs(zone and {} or find_all(cls)) do
                    local okD, zi = pcall(function() return z.ID end)
                    if not zone and live(z) and okD and text_of(zi) == key then zone = z end
                end
            end
            okZ = zone ~= nil
        end
        local zcar, running = nil, nil
        if okZ and valid(zone) then zcar, running = zone_vehicle(zone) end
        local mine = valid(zcar) and same_obj(zcar, veh0)
        log(string.format("%s %s: lift's bay at work=%s, bay's car is %s", mode, car, tostring(running),
            not valid(zcar) and "none" or (same_obj(zcar, veh0) and "this one" or "another")))
        -- Unread is refused too (refusing changes nothing), with its own reason.
        if running == true and mine then return false, "on a mechanic's lift while the mechanic works" end
        if running == nil and mine then return false, "on a mechanic's lift, bay state unread" end
    end
    -- An idle robot (status 0) carries nothing, whatever its car field holds.
    local other = (cur ~= "" and cur ~= car and glow ~= 0) and cur or nil
    -- The game's reset is robot-wide: every task is re-added after it, and a car
    -- whose mechanic step had started is taken off the lift mid-job. So it runs
    -- only when the robot is busy with this car; otherwise only this car's
    -- task is touched.
    local spare = not (cur == car and glow ~= 0)
    -- The game's reset is the most destructive path, so it runs only on a read
    -- status: an unread one could be an idle robot.
    if not spare and glow == nil then return false, "platform status unread" end
    -- Measured: a car moved away while the platform was picking it up was
    -- pulled back through a parked car as the platform picked it up again
    -- from where it stood. Driving and picking up clear in seconds, and a
    -- blocked path clears once its blocker moves (a car blocking it can be
    -- reset on its own), so none of them needs the game's reset.
    if not spare and (glow == 1 or glow == 2) then return false, "the platform is moving" end
    if not spare and glow == 4 then return false, "the platform's path is blocked" end
    -- The station or spot the car is leaving, to check after the move whether
    -- it still names the car: without the game's reset nothing tells it the
    -- car left. A car in neither (dropped off-zone) has nothing to check.
    local fromZone = nil
    if spare then
        local info, veh = info_by_id(car), nil
        if info then pcall(function() veh = info.Vehicle end) end
        -- Fields outermost: the ones that say which car a place holds are tried
        -- everywhere before overlap, which a car can have with a neighbouring
        -- spot it was never on.
        local actors = {}
        if valid(veh) then
            for _, cls in ipairs({ "BP_WashZone_C", "BP_CompressorZone_C", "BP_UndergroundTankSystem_C", "BP_PaintZone_C", "BP_PhotoZone_C", "BP_ParkingSlot_Automation_C" }) do
                for _, z in ipairs(find_all(cls)) do actors[#actors + 1] = z end
            end
        end
        for _, f in ipairs({ "VehicleIn", "VehicleInZone", "VehicleInAdditionalZone", "ParkingSlotVehicle", "OnlyVehicleOverlapping" }) do
            for _, z in ipairs(fromZone and {} or actors) do
                local ok, v = pcall(function() return z[f] end)
                if not fromZone and ok and valid(v) and same_obj(v, veh) then fromZone = { zone = z, field = f } end
            end
        end
    end
    -- Copy first, so nothing is changed if a copy fails.
    local keep = {}
    for _, e in ipairs(entries) do
        if not spare and (e[1] ~= car or mode == "unstick") then
            local lists = {}
            local okC, value = pcall(copy_task, e[2], fields, lists, "")
            if not okC then return false, "couldn't copy the task of " .. e[1] end
            keep[#keep + 1] = { car = e[1], value = value, lists = lists }
        end
    end
    local stuckParts = {}
    if mode == "reset" then
        local withheld
        stuckParts, withheld = parts_of(robot, car)
        if not stuckParts then return false, "task map unreadable" end
        if withheld then log("reset " .. car .. ": " .. withheld .. " listed parts not returned; the mechanic step is already done or under way") end
    end
    local waitFor, waitInside, waitRef, waitRunning = nil, nil, nil, nil
    if spare then
        -- On a full lot a Reset would remove the task and then fail to move the
        -- car, so nothing is done without a free spot. Only here: with the
        -- platform on the car the game's reset is what frees it, so that path
        -- goes ahead and the car stays where it stopped (the help says so).
        if not free_bay_slot() then return false, "no free parking spot" end
        log(mode .. " " .. car .. ": the robot is " .. (other and ("on " .. other) or "not on it") .. ", so it isn't reset")
        -- A wash or body bay hides the car and works on a stand-in; a car moved
        -- out mid-job leaves the stand-in shown in the bay until the job ends
        -- (measured). So a Reset there takes the task now and the car is moved
        -- once the bay is done; Unstick refuses, as that car isn't stuck. Other
        -- stations keep moving the car at once until their own end of a job is
        -- measured.
        if fromZone and tostring(name_of(fromZone.zone)):find("BP_WashZone_C", 1, true) then
            local zone = fromZone.zone
            -- GetZoneType first: the ZoneType field alone missed a car wash (measured).
            local zt = zone_type(zone, true)
            if zt == 2 or zt == 3 then
                local _, running = zone_vehicle(zone)
                local okI, inside = pcall(function() return zone.VehicleInside end)
                local okR, ref = pcall(function() return zone["Washable Vehicle"] end)
                local refSet = okR and valid(ref)
                log(string.format("%s %s: %s (type %d) names it in %s; at work=%s, car inside=%s, stand-in %s", mode, car, name_of(zone), zt,
                    fromZone.field, tostring(running), okI and tostring(inside) or "unread", not okR and "unread" or (refSet and "set" or "none")))
                -- Its work state stays true while the car stands in the bay after
                -- the job (measured), so it can't tell a job under way from one
                -- done. A job under way shows as the car-inside flag or the
                -- stand-in reference being set (either one, as which of them
                -- tracks the job isn't measured yet); with neither, no job is
                -- under way and moving the car leaves no stand-in behind.
                if (okI and inside == true) or refSet or (not okI and not okR and running == true) then
                    waitFor = zone
                    waitInside = (okI and inside == true) or nil
                    waitRef = refSet or nil
                    waitRunning = (running == true) or nil
                end
            elseif zt == nil then
                return false, "station type unread"
            end
        end
        if waitFor and mode == "unstick" then return false, "a station is working on this car" end
        if mode == "reset" then
            pcall(function() robot["Remove Automation Task"](robot, car, false) end)
            local still, unreadNow = stored_task(robot, car)
            if still or unreadNow then
                -- Its parts haven't been touched, so nothing changed.
                log("reset " .. car .. ": the task could not be removed; nothing changed")
                return false, "the task could not be removed", { failed = true, other = other, spared = true }
            end
        end
    else
        -- Measured: after the game's reset a car a station is still working on
        -- is collected mid-job (a mechanic's lift was left up and its parts
        -- never fitted). So the reset waits while any station works another
        -- car. The mechanic's bays are BP_WashZone_C (zone type 4). A station
        -- whose work state can't be read doesn't block it; one at work whose
        -- car can't be read does, with its own reason. A platform waiting for a
        -- station isn't stuck, so the refusal says that instead.
        local notStuck = glow == 3 and "the platform is waiting for a station" or nil
        for _, cls in ipairs({ "BP_WashZone_C", "BP_CompressorZone_C", "BP_UndergroundTankSystem_C", "BP_PaintZone_C", "BP_PhotoZone_C" }) do
            for _, z in ipairs(find_all(cls)) do
                local zcar, running = zone_vehicle(z)
                local zid = valid(zcar) and car_id_of(zcar) or nil
                if running == true and zid == nil then
                    log(mode .. " " .. car .. ": " .. name_of(z) .. " is at work and its car can't be read, so the game's reset waits (platform status " .. tostring(glow) .. ")")
                    return false, notStuck or "a station is at work, its car unread"
                elseif running == true and zid == car then
                    -- The platform waits there for this car's station: it isn't
                    -- stuck, and the game's reset would take the car out mid-job.
                    log(mode .. " " .. car .. ": " .. name_of(z) .. " is at work on it and the platform waits for it (platform status " .. tostring(glow) .. ")")
                    return false, notStuck or "a station is working on this car"
                elseif running == true and zid ~= car then
                    log(mode .. " " .. car .. ": " .. name_of(z) .. " is at work on " .. zid .. ", so the game's reset waits (platform status " .. tostring(glow) .. ")")
                    return false, notStuck or "a station is at work on another car"
                end
            end
        end
        local okR, errR = pcall(function() robot["FORCE RESET"](robot) end)
        if not okR then
            -- Nothing was returned or moved yet, so every car keeps its task.
            log(mode .. " " .. car .. ": the game's reset failed: " .. tostring(errR))
            return false, "the game's reset failed", { failed = true }
        end
    end
    local returned = to_storage(st, stuckParts)
    local restored, lost, partsCopied, partsBack, rescued, rescueTried = 0, {}, 0, 0, 0, 0
    local listLost = {}
    -- A map entry counts as back only when it can be read back (map_has).
    -- The task's part lists are the only maps whose values are objects
    -- (name -> BP_ProductDataBase_C, every product's base class); every
    -- object a copy loses from them is a part and goes to storage.
    local function part_list(path) return path:find("CarPartsForSwap_", 1, true) ~= nil end
    for _, k in ipairs(keep) do
        local okA = pcall(function() robot["Add Automation Task"](robot, k.value) end)
        local task = okA and stored_task(robot, k.car)
        local stray = {}
        if task then
            for path, list in pairs(k.lists) do
                if list.names then
                    -- A list of names: written onto the stored task's array,
                    -- one entry at a time, then read back by name. Writing
                    -- past the end grows the array by one; that is the only
                    -- way UE4SS offers, and it is only safe written in order
                    -- from 1 with no gaps (never a later index first), and only
                    -- on the experimental UE4SS the mod needs: the 3.0.1
                    -- release grows it wrongly and writes past its end. The
                    -- read-back can't catch an out-of-bounds write, only a
                    -- list that didn't come out the same.
                    local arr = map_at(task, fields, path)
                    if arr then
                        for i, nm in ipairs(list.names) do pcall(function() arr[i] = FName(nm) end) end
                    end
                    local got = {}
                    if arr then pcall(function() arr:ForEach(function(_, e)
                        local okE, ev = pcall(function() return e:get() end)
                        got[#got + 1] = text_of(okE and ev or e)
                    end) end) end
                    local same = #got == #list.names
                    for i = 1, #list.names do if got[i] ~= list.names[i] then same = false end end
                    log(mode .. " " .. k.car .. ": list " .. path .. " " .. #got .. "/" .. #list.names .. (same and "" or " NOT kept"))
                    if not same then listLost[#listLost + 1] = k.car end
                    goto nextList
                end
                do
                local map = map_at(task, fields, path)
                for _, kv in ipairs(list) do
                    partsCopied = partsCopied + 1
                    local added = false
                    if map and kv[1] ~= nil and kv[2] ~= nil then
                        local key = kv[1]
                        if type(key) ~= "number" then key = FName(text_of(key)) end
                        pcall(function() map:Add(key, kv[2]) end)
                        added = map_has(map, kv[1], kv[2])
                    end
                    if added then partsBack = partsBack + 1
                    elseif part_list(path) then stray[#stray + 1] = kv[2]
                    else log(mode .. " " .. k.car .. ": couldn't re-add " .. path .. " " .. text_of(kv[1]) .. " (not a part)") end
                end
                end
                ::nextList::
            end
            restored = restored + 1
        else
            lost[#lost + 1] = k.car
            for path, list in pairs(k.lists) do
                for _, kv in ipairs(list.names and {} or list) do
                    partsCopied = partsCopied + 1
                    if part_list(path) then stray[#stray + 1] = kv[2] end
                end
            end
        end
        -- Every stray counts toward the claim; one that isn't a live object
        -- can't be stored and is logged by what it is.
        local parts = {}
        for _, it in ipairs(stray) do
            if valid(it) then parts[#parts + 1] = it
            else log(mode .. " " .. k.car .. ": part entry not storable: " .. tostring(it)) end
        end
        rescueTried = rescueTried + #stray
        rescued = rescued + to_storage(st, parts)
    end
    local okMove, whyMove = false, "waiting for the station"
    if waitFor then
        log(mode .. " " .. car .. ": " .. name_of(waitFor) .. " is still working on it, so it's moved once the station is done")
    else
        okMove, whyMove = move_to_bay(car, mode)
        if not okMove then log(mode .. " " .. car .. ": not moved, " .. tostring(whyMove)) end
    end
    local lastMove = moveChecks[#moveChecks]
    if okMove and fromZone and lastMove and lastMove.car == car then lastMove.from = fromZone
    elseif okMove and spare then log(mode .. " " .. car .. ": it was in no station or spot, so there's none to check after the move") end
    -- Any car the mod puts back on the parking (Reset or Unstick) loses its
    -- profile. Normally a car with a task has none left (intake clears it on
    -- apply), so this guards the other ways a car gets both: an assignment
    -- left in profiles.lua by an older build, or a car started through the
    -- game's own scanner while it had a profile. Left set, intake would give
    -- a reset car a fresh task the moment it lands.
    -- Only once the car is really back on the parking: a car the move left in a
    -- station keeps its profile, as every other failure here keeps everything.
    -- Outside the okMove gate on purpose: FORCE RESET has removed the task
    -- whether or not the car moved, so its shown profile goes either way; and
    -- saved here, since the save below only runs for a leftover assignment.
    if mode == "reset" and applied[car] ~= nil then
        log("reset " .. car .. ": profile " .. tostring(applied[car]) .. " cleared")
        applied[car] = nil
        if not save_profiles() then log("reset " .. car .. ": profile cleared, but profiles.lua couldn't be written") end
    end
    if okMove or waitFor then
        local had = assignments[car]
        assignments[car], failures[car], failures[car .. "@"], lastReason[car] = nil, nil, nil, nil
        failures[car .. "#parts"] = nil
        if had and not save_profiles() then log(mode .. " " .. car .. ": profile cleared, but profiles.lua couldn't be written") end
    end
    local msg = returned .. " of " .. #stuckParts .. " parts returned; " .. restored .. " of " .. #keep
        .. " tasks restored; " .. partsBack .. " of " .. partsCopied .. " list entries re-added; "
        .. rescued .. " parts from tasks that couldn't go back put in storage"
    if #lost > 0 then msg = msg .. "; lost: " .. table.concat(lost, ", ") end
    log(mode .. " " .. car .. ": " .. msg)
    local short = #stuckParts - returned
    return #lost == 0 and short == 0, msg,
        { returned = returned, attempted = #stuckParts, restored = restored, total = #keep, lost = lost,
          shortfall = short, rescued = rescued, rescueTried = rescueTried, listLost = listLost, moved = okMove, moveWhy = whyMove, other = other, spared = spare, wait = waitFor, waitInside = waitInside, waitRef = waitRef, waitRunning = waitRunning }
end
local function reset_car(car) return free_robot(car, "reset") end

---------------------------------------------------------------------------
-- Board data: each car's remaining stations, and the robot's current car.
---------------------------------------------------------------------------
local STEP_NAMES = { "PhotoStudio", "PaintBooth", "CarWash", "BodyWorkshop", "MechanicalWorkshop", "Compressor",
    "GasPump", "ParkingSlot" }
local function board_rows()
    local robot = robot_now()
    if not robot then return nil, "robot manager not found" end
    local fields = task_fields()
    local asf = fields and field_named(fields, "AutomationSteps")
    if not asf then return nil, "task struct not found" end
    local cur = current_car(robot)
    local entries = task_entries(robot)
    if not entries then return nil, "task map unreadable" end
    local rows = {}
    for _, e in ipairs(entries) do
        local remaining = {}
        for _, s in ipairs(STEP_NAMES) do
            local sf = field_named(asf[3], s)
            if sf then
                local ok, v = pcall(function() return e[2][asf[1]][sf[1]] end)
                if ok and v == true then remaining[#remaining + 1] = s end
            end
        end
        rows[#rows + 1] = { car = e[1], current = (e[1] == cur), remaining = remaining }
    end
    return rows
end

---------------------------------------------------------------------------
-- Map data: which car is in which station or parking spot, from what each
-- one reports (the robot reads cars the same way when it picks its next one).
-- Station types are the game's own (E_AutomationZoneType).
---------------------------------------------------------------------------
local ZONE_FULL = { [0] = "Photo Studio", [1] = "Paint Booth", [2] = "Car Wash", [3] = "Body Workshop",
    [4] = "Mechanical Workshop", [5] = "Air Compressor", [6] = "Fuel Dispenser" }
local WAREHOUSE_PARKING = 7
-- One-time map flags and the kept spot list, in one table (the file is at
-- Lua's limit of 200 locals in its main body).
local mapOnce = { zonesLogged = false }
local function vector_dist(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
local function actor_loc(a)
    local ok, l = pcall(function() return a:K2_GetActorLocation() end)
    return ok and l and { X = l.X, Y = l.Y } or nil
end

-- Spots are numbered from the paint booth end (nearest the fuel dispenser),
-- stations of one type from the main door (nearest the parking): the order
-- the map draws them in.
local function map_state()
    local robot = robot_now()
    if not robot then return nil, "robot manager not found" end
    local state = { stations = {}, spots = {}, where = {}, current = current_car(robot) }
    local zones = {}
    pcall(function()
        -- "ODERED" is the game's own spelling of this robot property.
        robot["ODERED AUTOMATED ZONES"]:ForEach(function(_, v)
            local ok, z = pcall(function() return v:get() end)
            if ok and live(z) then zones[#zones + 1] = z end
        end)
    end)
    -- Stations the robot hasn't registered are still on the lot (a second
    -- compressor, for one): they're drawn too, from the game's station
    -- classes, so the map never calls a built station "not built".
    -- The station classes: BP_WashZone is the car wash, body and mechanic bays
    -- (its type is set per bay); the photo studio, compressor, fuel and paint
    -- each have their own. An actor whose name can't be read is left out
    -- rather than matched by a placeholder name.
    local seen = {}
    for _, z in ipairs(zones) do
        local n = name_of(z)
        if n ~= "?" then seen[n] = true end
    end
    local registered = #zones
    for _, cls in ipairs({ "BP_CompressorZone_C", "BP_UndergroundTankSystem_C", "BP_WashZone_C", "BP_PaintZone_C", "BP_PhotoZone_C" }) do
        for _, z in ipairs(find_all(cls)) do
            local n = live(z) and name_of(z) or "?"
            if n ~= "?" and not seen[n] then
                seen[n] = true
                zones[#zones + 1] = z
            end
        end
    end
    if not mapOnce.zonesLogged then
        mapOnce.zonesLogged = true
        local parts = {}
        for i, z in ipairs(zones) do
            local l = actor_loc(z)
            parts[#parts + 1] = name_of(z) .. "=" .. tostring(zone_type(z))
                .. (l and string.format("@%.0f,%.0f", l.X, l.Y) or "@?") .. (i > registered and "(not registered)" or "")
        end
        log("map zones: " .. table.concat(parts, ", "))
    end
    local fuelAt = nil
    for _, z in ipairs(zones) do
        local t = zone_type(z)
        if t and ZONE_FULL[t] then
            local list = state.stations[t] or {}
            state.stations[t] = list
            local v, running = zone_vehicle(z)
            list[#list + 1] = { actor = z, loc = actor_loc(z), vehicle = v, running = running }
            if t == 6 then fuelAt = list[#list].loc end
        end
    end
    -- Parking spots. The robot's ordered station list holds none (measured:
    -- 0 of 14), so its ZoneActors list is tried first; failing that, the
    -- level's spot objects that aren't hidden (the level holds more spot
    -- objects than a lot has spots). The counts are logged once.
    local fromZoneActors = 0
    pcall(function()
        robot.ZoneActors:ForEach(function(_, v)
            local ok, z = pcall(function() return v:get() end)
            local okW, wp = pcall(function() return z.AutomationWaypointRef end)
            if ok and live(z) and zone_type(z) == WAREHOUSE_PARKING and okW and valid(wp) then
                fromZoneActors = fromZoneActors + 1
                state.spots[#state.spots + 1] = { actor = z, loc = actor_loc(z), vehicle = zone_vehicle(z) }
            end
        end)
    end)
    -- The level's spot objects are enumerated each time: their hidden state
    -- changes when a lot gains spots, so a kept list would go stale. The
    -- first call always counts them, for the one-time log line.
    -- Measured: 14 warehouse-parking slots, 9 with a robot route marker
    -- (AutomationWaypointRef) in a row in front of the paint booth, 5 without
    -- by the storage bays. Only the 9 are automation spots.
    local all, routed, unread = 0, 0, 0
    if fromZoneActors == 0 then
        for _, slot in ipairs(find_all("BP_ParkingSlot_Automation_C")) do
            if live(slot) and zone_type(slot) == WAREHOUSE_PARKING then
                all = all + 1
                local okW, wp = pcall(function() return slot.AutomationWaypointRef end)
                -- A failed read draws nothing (a storage bay must not be drawn)
                -- but is counted apart, so "0 with a marker" can't hide failed reads.
                local draw = false
                if not okW then unread = unread + 1
                elseif valid(wp) then routed = routed + 1 draw = true end
                if draw and fromZoneActors == 0 then
                    state.spots[#state.spots + 1] = { actor = slot, loc = actor_loc(slot), vehicle = zone_vehicle(slot) }
                end
            end
        end
    end
    -- The count is logged whenever it changes, not once: the level streams in,
    -- so the first reading can come before every spot exists. Each line has a
    -- reading number and the seconds since the first map pass (os.clock is
    -- process uptime, so it's measured from a stamp), so the settled reading
    -- is the last one.
    local key = fromZoneActors .. "/" .. all .. "/" .. routed .. "/" .. unread
    mapOnce.firstClock = mapOnce.firstClock or os.clock()
    if fromZoneActors == 0 and key ~= mapOnce.spotKey then
        mapOnce.spotKey = key
        mapOnce.spotPass = (mapOnce.spotPass or 0) + 1
        log(string.format("map: spots (reading %d, %.0f s after the first map pass): %d in ZoneActors, %d live warehouse-parking slots (ZoneType 7), %d with a robot route marker, %d unreadable; drawing %d%s",
            mapOnce.spotPass, os.clock() - mapOnce.firstClock, fromZoneActors, all, routed, unread, #state.spots,
            fuelAt and ", numbered from the fuel dispenser end" or ", no fuel dispenser found, numbered in game order"))
    end
    local parkAt = nil
    if #state.spots > 0 then
        local x, y, n = 0, 0, 0
        for _, sp in ipairs(state.spots) do if sp.loc then x, y, n = x + sp.loc.X, y + sp.loc.Y, n + 1 end end
        if n > 0 then parkAt = { X = x / n, Y = y / n } end
    end
    local function by_dist(list, from)
        if not from then return end
        table.sort(list, function(a, b)
            if not (a.loc and b.loc) then return a.loc ~= nil end
            return vector_dist(a.loc, from) < vector_dist(b.loc, from)
        end)
    end
    by_dist(state.spots, fuelAt)
    for _, list in pairs(state.stations) do by_dist(list, parkAt) end
    -- The lot's two air bays are one compressor station with two zones (the
    -- level holds a single BP_CompressorZone; its second bay's car is
    -- VehicleInAdditionalZone, which the compressor worker reads too). So a
    -- lone compressor is drawn as Air 1 and Air 2.
    local air = state.stations[5]
    if air and #air == 1 then
        local second = nil
        pcall(function() second = air[1].actor.VehicleInAdditionalZone end)
        -- One compressor, so both bays show its work state.
        air[2] = { actor = air[1].actor, loc = air[1].loc, vehicle = valid(second) and second or nil, secondBay = true,
            running = air[1].running }
        -- The station-wide reading for bay 1 also reports a car in bay 2, so a car
        -- the second bay holds belongs to Air 2 only; bay 1 then shows the car
        -- its own field (VehicleInZone) reports, if that's a different one.
        if air[2].vehicle and air[1].vehicle and same_obj(air[1].vehicle, air[2].vehicle) then
            local first = nil
            pcall(function() first = air[1].actor.VehicleInZone end)
            air[1].vehicle = (valid(first) and not same_obj(first, air[2].vehicle)) and first or nil
        end
    end
    -- Where each car is, by car id.
    for t, list in pairs(state.stations) do
        for i, z in ipairs(list) do
            local id = z.vehicle and car_id_of(z.vehicle)
            if id and id ~= "" then
                z.car = id
                local an = name_of(z.actor)
                if an ~= "?" and z.secondBay then an = an .. ":2" end
                state.where[id] = { kind = "station", type = t, n = i, count = #list, key = an ~= "?" and (t .. ":" .. an) or nil, running = z.running }
            end
        end
    end
    -- Every station class's IsRunningAutomatedWork reports running while the
    -- game holds the station for automated work (AutomationStationReserved),
    -- with or without a car in it. Held with no car is reserved, not work.
    -- "No car" is no vehicle at all: a car whose id can't be read is still a
    -- car, and a station working on it must stay at work for the stall rule.
    -- The two air bays share one compressor, so an empty bay beside a busy
    -- one is idle rather than reserved. With the compressor held and both bays
    -- empty, both bays read reserved: one station, counted twice, as its
    -- working state always has been.
    -- How long a station has been held with no car is kept by its name. The
    -- game sets the hold only while a station works on a car
    -- (AutomationWorkProgress), so a hold that outlasts its car is stuck. A
    -- gap in the readings starts the count again rather than carrying it over.
    local now = os.clock()
    for t, list in pairs(state.stations) do
        for _, z in ipairs(list) do
            local an = name_of(z.actor)
            local key = an ~= "?" and ("held:" .. an .. (z.secondBay and ":2" or "")) or nil
            if z.running == true and not z.vehicle then
                local other = (t == 5 and #list == 2) and list[z.secondBay and 1 or 2] or nil
                if other and other.secondBay ~= z.secondBay and other.vehicle then z.running = false
                else
                    z.running, z.reserved = false, true
                    if key then
                        local hv = mapOnce[key]
                        if type(hv) ~= "table" or now - hv.seen > 5 then hv = { since = now } end
                        hv.seen = now
                        mapOnce[key] = hv
                        z.heldFor = now - hv.since
                    end
                end
            end
            if key and not z.reserved then mapOnce[key], mapOnce["offer:" .. key:sub(6)] = nil, nil end
        end
    end
    for i, sp in ipairs(state.spots) do
        local id = sp.vehicle and car_id_of(sp.vehicle)
        if id and id ~= "" then
            sp.car = id
            state.where[id] = { kind = "spot", n = i }
        end
    end
    return state
end

-- A car the robot has been on at the same station for this long, with no
-- change, counts as possibly stalled. Seconds of play; tuned in testing. The
-- mechanic gets twice as long: a full custom set is one long job there.
local STALL_SECS = 300
local stallSeen = {}      -- car -> { key = station key, since = clock }
local unstuckAt = {}      -- car -> clock of the last Unstick
-- Two ways a car counts as possibly stalled:
--   the robot is on it, at the same station, for STALL_SECS with no change;
--   the car, which still has a task, has sat in one place (a station, a
--   spot, or neither) for a minute or more while the whole shop is idle (the
--   robot idle and no station at work, for 30 s): the robot is ignoring a car
--   it should take. A car at a station still at work while the robot is idle
--   gets twice STALL_SECS instead (a lift stuck at work still shows, later).
-- Each visit's length is logged when the car leaves, so slow stations can be
-- told from stuck ones.
local function stall_track(state)
    local robot = robot_now()
    local glow, tasks = nil, {}
    local entries = robot and task_entries(robot)
    -- One unreadable moment mustn't zero every clock: nothing changes then.
    if not entries then return end
    pcall(function() glow = tonumber(robot.Robot.CurrentGlowStatus) end)
    for _, e in ipairs(entries) do tasks[e[1]] = true end
    -- The clock is how long the car has sat at this station, whatever the robot
    -- does meanwhile; which limit applies (if any) is decided each pass.
    local live_keys = {}
    -- Cars with a task (or the robot's car) in a station, on a spot, or in
    -- neither: a car the robot let go of in mid-air is in neither, and is the
    -- one most in need of the idle-robot rule.
    local places = {}
    for id, w in pairs(state.where) do
        if (w.kind == "station" or w.kind == "spot") and (tasks[id] or id == state.current) then places[id] = w end
    end
    for id in pairs(tasks) do
        local w = state.where[id]
        if not w or w.kind == "moving" then places[id] = { kind = "off" } end
    end
    if state.current and state.current ~= "" and not places[state.current] and not state.where[state.current] then
        places[state.current] = { kind = "off" }
    end
    -- The idle-robot rule needs the whole shop idle, and for a while: the robot
    -- also goes idle while a station works a car (measured: 112 s at the
    -- mechanic) and blinks idle between jobs, while cars wait their turn on
    -- the spots. So it applies only once the robot has been idle (or has no
    -- task it can do) with no station at work for 30 s. A station whose state
    -- is unread is left out here, so one unreadable station can't silence the
    -- rule for every car; it still protects its own car (below).
    -- A station the game holds with no car in it reads as not running (see
    -- map_state), so it counts as idle here. That's safe only because the rule
    -- also needs the robot idle for 30 s: a station held for a car the robot
    -- is still driving to is the normal case, and the robot isn't idle then.
    -- A car the robot dropped off-zone while a station works isn't caught here;
    -- it's caught when it blocks the robot's path (robot_blockers).
    local anyWork, nWork, nIdle, held, unreadNames = false, 0, 0, {}, {}
    for _, list in pairs(state.stations) do
        for _, z in ipairs(list) do
            if z.running == true then anyWork, nWork = true, nWork + 1
            elseif z.running == false then
                nIdle = nIdle + 1
                if z.reserved then held[#held + 1] = name_of(z.actor) .. (z.secondBay and ":2" or "") end
            elseif not z.secondBay then unreadNames[#unreadNames + 1] = name_of(z.actor) end
        end
    end
    table.sort(unreadNames)
    table.sort(held)
    local census = string.format("shop: %d at work, %d idle%s, %d unread%s", nWork, nIdle,
        #held > 0 and (" (reserved, no car: " .. table.concat(held, ", ") .. ")") or "", #unreadNames,
        #unreadNames > 0 and (" (" .. table.concat(unreadNames, ", ") .. ")") or "")
    if census ~= mapOnce.shopCensus then
        mapOnce.shopCensus = census
        log(census)
    end
    if (glow == 0 or glow == 5) and not anyWork then mapOnce.shopIdleSince = mapOnce.shopIdleSince or os.clock()
    else mapOnce.shopIdleSince = nil end
    -- Only once at least one station can be read: with none readable, "no
    -- station at work" would be a guess.
    local shopIdle = mapOnce.shopIdleSince and (nWork + nIdle) > 0 and os.clock() - mapOnce.shopIdleSince >= 30
    for id, w in pairs(places) do
        local key, place
        if w.kind == "station" then key, place = w.key or (w.type .. ":" .. w.n), (ZONE_FULL[w.type] or "station") .. " " .. tostring(w.n)
        elseif w.kind == "spot" then key, place = "spot:" .. tostring(w.n), "Parking Spot " .. tostring(w.n)
        else key, place = "off", "no station or spot" end
        local s = stallSeen[id]
        if not s or s.key ~= key then
            if s then log(string.format("visit %s: %.0f s at %s", id, os.clock() - s.since, s.place)) end
            s = { key = key, since = os.clock(), place = place }
            stallSeen[id] = s
        end
        -- A station whose work state couldn't be read (running == nil) is
        -- treated as at work, so a failed read can't report a stalled car.
        -- Each limit is timed from when its own condition began, not from
        -- when the car reached its place: a car queued for minutes was
        -- otherwise "stalled" the moment the robot picked it up.
        local reason
        if id == state.current then reason, s.limit = "robot", (w.type == 4) and 2 * STALL_SECS or STALL_SECS
        elseif shopIdle then reason, s.limit = "shop idle", 60
        elseif glow == 0 and w.kind == "station" and w.running ~= false then reason, s.limit = "station", 2 * STALL_SECS
        else reason, s.limit = nil, nil end
        if reason ~= s.reason then s.reason, s.reasonSince = reason, os.clock() end
        if s.limit and not s.logged and os.clock() - s.reasonSince >= s.limit then
            -- Logged once, when the car turns "possibly stalled" on the panel;
            -- it then stays so until the car moves on (s.logged).
            s.logged = true
            local why = id == state.current and "robot on it, no change"
                or shopIdle and "robot idle and no station at work, car left with a task"
                or (w.running and "robot idle, station still at work" or "robot idle, station's work state unread")
            log(string.format("stall %s: %s, %.0f s (%.0f s at %s) (%s)", id, why, os.clock() - s.reasonSince, os.clock() - s.since, s.place, tostring(key)))
        end
        live_keys[id] = true
    end
    for id, s in pairs(stallSeen) do
        if not live_keys[id] then
            log(string.format("visit %s: %.0f s at %s", id, os.clock() - s.since, tostring(s.place)))
            stallSeen[id] = nil
        end
    end
end
local function stalled_for(id)
    local s = stallSeen[id]
    if not s then return nil end
    if s.logged then return os.clock() - s.since end
    if not s.limit then return nil end
    local secs = os.clock() - (s.reasonSince or s.since)
    return secs >= s.limit and secs or nil
end

---------------------------------------------------------------------------
-- Start-up
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Screens: an app on the Tablet and the office Computer, built the same way
-- as Parts Manager's (the game's own icon widget as a button, our panel in the
-- screen's app switcher). Pages: Board, Cars, Profiles.
---------------------------------------------------------------------------
local TABLET_CLASS = "/Game/CarDealerSim/UI/InGame/Tablet/WBP_Tablet.WBP_Tablet_C"
local COMPUTER_CLASS = "/Game/CarDealerSim/UI/InGame/Computer/WBP_DesktopComputer.WBP_DesktopComputer_C"
local ICON_CLASS = "/Game/CarDealerSim/UI/InGame/Computer/WBP_DesktopIconWidget.WBP_DesktopIconWidget_C"
local WIDGET_LIBRARY = "/Script/UMG.Default__WidgetBlueprintLibrary"

-- Objects are remembered by path and handed back without a search: asking
-- StaticFindObject for a path that no longer exists makes UE4SS walk every
-- object in the game, which has crashed it.
local known, gone, missing = {}, {}, {}
local function remember(o)
    local ok, s = pcall(function() return o:GetFullName() end)
    if not ok or not s then return nil end
    s = s:match("^%S+%s+(.+)$") or s
    known[s], gone[s] = o, nil
    return s
end
local function resolve(p)
    if not p then return nil end
    local k = known[p]
    if k ~= nil then
        if valid(k) then return k end
        known[p], gone[p] = nil, true
        return nil
    end
    if gone[p] then return nil end
    if missing[p] and os.clock() - missing[p] < 10 then return nil end
    local o = nil
    pcall(function() o = StaticFindObject(p) end)
    if valid(o) then known[p], missing[p] = o, nil return o end
    missing[p] = os.clock()
    return nil
end

-- Teal (the same family as the robot pad's colour, not the same value), so the app reads as its own and not as
-- Parts Manager, which is blue. (UMG colours are linear.)
local COLORS = {
    body = { R = 0.035, G = 0.04, B = 0.05, A = 1.0 },
    header = { R = 0.0, G = 0.16, B = 0.17, A = 1.0 },
    -- Help headings in the teal the tab buttons show on screen, so the page
    -- reads as one app. Text colour renders darker than the same value on a
    -- brush, so the header's own value came out too dark to read.
    section = { R = 0.07, G = 0.60, B = 0.61, A = 1.0 },
    card = { R = 0.07, G = 0.08, B = 0.10, A = 1.0 },
    text = { R = 0.92, G = 0.92, B = 0.92, A = 1.0 },
    white = { R = 1, G = 1, B = 1, A = 1 },
    dim = { R = 0.55, G = 0.57, B = 0.60, A = 1.0 },
    good = { R = 0.25, G = 0.80, B = 0.25, A = 1.0 },
    bad = { R = 1.0, G = 0.30, B = 0.22, A = 1.0 },
    btn = { R = 0.0, G = 0.26, B = 0.28, A = 1.0 },
    btnOff = { R = 0.16, G = 0.16, B = 0.17, A = 1.0 },
    btnDark = { R = 0.0, G = 0.05, B = 0.06, A = 1.0 },
    btnOn = { R = 0.05, G = 0.45, B = 0.12, A = 1.0 },
    btnWarn = { R = 0.62, G = 0.05, B = 0.04, A = 1.0 },
    -- An ad the mod couldn't confirm: purple, well apart from the yellow
    -- and red tiles beside it.
    checkAd = { R = 0.45, G = 0.15, B = 0.70, A = 1.0 },
    -- The ad screen's competitiveness bar, by bar level: 0.6 and up blue,
    -- 0.4 green, 0.25 yellow, below that red (the game's own values).
    barBlue = { R = 0.063998, G = 0.367279, B = 0.760417, A = 1.0 },
    barGreen = { R = 0.194248, G = 0.760417, B = 0.059061, A = 1.0 },
    barYellow = { R = 0.760417, G = 0.738953, B = 0.070243, A = 1.0 },
    barRed = { R = 0.760417, G = 0.011806, B = 0.0, A = 1.0 },
}

local function umg(kind) return resolve("/Script/UMG." .. kind) end
local widgetCounter = 0
local function new_widget(kind, outer)
    local c = umg(kind)
    if not c then error("UMG class missing: " .. kind) end
    widgetCounter = widgetCounter + 1
    -- "AM_<kind>_<n>": the engine keeps the trailing number apart from the
    -- name's text, so only one text per widget kind is ever stored (names
    -- are never freed, and the map rebuilds its widgets every refresh).
    local w = StaticConstructObject(c, outer, FName(string.format("AM_%s_%d", kind, widgetCounter)))
    if not valid(w) then error("could not create " .. kind) end
    return w
end
local function set_color(dst, c) dst.R, dst.G, dst.B, dst.A = c.R, c.G, c.B, c.A end
local function set_text(tb, str, color)
    if not tb then return end
    pcall(function() tb:SetText(FText(str)) end)
    if color then pcall(function() tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 }) end) end
end
local function make_text(outer, str, size, color)
    local t = new_widget("TextBlock", outer)
    local font = resolve("/Game/CarDealerSim/UI/Fonts/Montserrat/Lato-Medium_Font.Lato-Medium_Font")
    if font then
        pcall(function() t:SetFont({ FontObject = font, TypefaceFontName = FName("Default"), Size = size, LetterSpacing = 0, SkewAmount = 0.0 }) end)
    end
    set_text(t, str, color or COLORS.text)
    return t
end
local function pad(slot, l, t, r, b) pcall(function() slot:SetPadding({ Left = l, Top = t, Right = r, Bottom = b }) end) end
local function fill(slot, weight) pcall(function() slot:SetSize({ SizeRule = 1, Value = weight or 1.0 }) end) end
local function valign(slot, v) pcall(function() slot:SetVerticalAlignment(v) end) end
local function halign(slot, v) pcall(function() slot:SetHorizontalAlignment(v) end) end
local function make_border(outer, color, l, t, r, b)
    local bd = new_widget("Border", outer)
    pcall(function() bd:SetBrushColor(color) end)
    pcall(function() bd:SetPadding({ Left = l or 0, Top = t or 0, Right = r or 0, Bottom = b or 0 }) end)
    return bd
end

local hosts, buttons = {}, {}

-- A button: the game's clickable icon widget with our text on top (the text
-- ignores the mouse, so clicks reach the button).
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
    local t = make_text(outer, label, size or 18, COLORS.white)
    pcall(function() t:SetVisibility(3) end)
    local ts = ov:AddChildToOverlay(t)
    halign(ts, 2)
    valign(ts, 2)
    pcall(function() b:UpdateVisual() end)
    pcall(function() b:SetInteractable(true) end)
    return ov
end

local function add_button(h, box, label, w, action, color, size)
    local host = resolve(h.hostPath)
    local ov = make_button(host, h.hostPath, box:GetOuter(), label, w, 40, action, size, color)
    local slot = box:AddChildToHorizontalBox(ov)
    pad(slot, 0, 4, 8, 4)
    valign(slot, 2)
    return ov
end

local function new_row(outer, list)
    local row = new_widget("HorizontalBox", outer)
    pad(list:AddChildToVerticalBox(row), 0, 2, 0, 2)
    return row
end
local function row_text(row, outer, str, weight, color, size)
    local t = make_text(outer, str, size or 18, color)
    -- Text given a share of the row wraps inside it, so a long name or reason
    -- never runs under the buttons beside it.
    if weight then pcall(function() t:SetAutoWrapText(true) end) end
    local sl = row:AddChildToHorizontalBox(t)
    if weight then fill(sl, weight) end
    valign(sl, 2)
    pad(sl, 0, 0, 12, 0)
    return t
end

-- UI state, shared by both screens.
local ui = { page = "board", selected = "Default", status = "", statusGood = true, drafts = {}, boardView = "map", pendingReset = {} }
-- Stations the game has held with no car for 30 s. Only the wash, body and
-- mechanic bays (BP_WashZone) have the game's own release, EndWorkOnZone: it
-- clears the hold, lets the station's worker go, empties the station's task
-- and has the platform plan its queue again, as when a job ends normally.
-- The other station classes have no such call, so they aren't offered.
-- A bay whose lift is found and isn't down and still isn't offered: ending
-- the work under a raised lift hasn't been tried. A bay whose lift can't be
-- found is offered (see lift_state).
-- IsRunningAutomatedWork is also true for a car not in automation standing in
-- the bay (a player's own job), so the hold and the bay's car field are read
-- directly as well: offered (and freed) only when both read, the hold is set
-- and the bay is empty. Anything unread refuses.
ui.stale_hold = function(zone)
    local okR, held = pcall(function() return zone.AutomationStationReserved end)
    local okV, vin = pcall(function() return zone.VehicleIn end)
    return okR and held == true and okV and not valid(vin)
end
-- Whether a lift belongs to a bay. The game fills a lift's RelatedZone only
-- when something asks for it (GetRelatedZone caches what FindRelatedZone
-- finds), so on a fresh load every lift reads none. FindRelatedZone matches
-- the lift's ZoneIndex to a repair zone's ID; that's matched here too, with
-- reads only. A cached RelatedZone, when there is one, wins.
ui.lift_is_for = function(lift, zone)
    local okZ, rz = pcall(function() return lift.RelatedZone end)
    if okZ and valid(rz) then return same_obj(rz, zone) end
    local okI, li = pcall(function() return lift.ZoneIndex end)
    local okD, zi = pcall(function() return zone.ID end)
    if not (okI and okD) then return false end
    local key = text_of(li)
    return key ~= "" and key == text_of(zi)
end
-- A mechanic bay's lift, found by ui.lift_is_for. A lift that is found
-- blocks the offer unless it reads down and still; an unread one blocks too.
-- If none matches (ZoneIndex or ID unread or empty), refusing would leave the
-- bay held for good, so "no lift found" doesn't block. That is an accepted
-- risk, not a covered one: a lift can hold a car the bay's own field no
-- longer shows (VehicleOnLift; see the stuck_lifts comment), and with the
-- lift not found that can't be read from here.
-- Every matching lift is read: if a bay matched two (or an ID turned out to
-- be shared), one lift reading down mustn't speak for another that isn't.
ui.lift_state = function(zone)
    local found = false
    for _, lift in ipairs(find_all("BP_VehicleRepairLift_C")) do
        if live(lift) and ui.lift_is_for(lift, zone) then
            local okU, up = pcall(function() return lift.IsLiftUp end)
            local okP, busy = pcall(function() return lift.IsProcessing end)
            if not (okU and up == false and okP and busy == false) then return "not down" end
            found = true
        end
    end
    return found and "down" or "none"
end
-- Why a held station is or isn't offered, logged once per change, so a row
-- that doesn't appear can be read from the log rather than guessed at.
ui.hold_why = function(t, z)
    local okR, held = pcall(function() return z.actor.AutomationStationReserved end)
    local okV, vin = pcall(function() return z.actor.VehicleIn end)
    local parts = { string.format("held %ds", math.floor(z.heldFor or -1)),
        "30 s " .. ((z.heldFor or 0) >= 30 and "passed" or "not yet"),
        "hold field " .. (okR and tostring(held) or "unread"),
        "car field " .. (okV and (valid(vin) and "a car" or "empty") or "unread") }
    if not name_of(z.actor):find("^BP_WashZone_C") then parts[#parts + 1] = "this kind of station has no EndWorkOnZone" end
    if t == 4 then
        local lf, zones, nMatch = "no lift found", {}, 0
        local lifts = find_all("BP_VehicleRepairLift_C")
        for _, lift in ipairs(lifts) do
            local okZ, rz = pcall(function() return lift.RelatedZone end)
            local okI, li = pcall(function() return lift.ZoneIndex end)
            zones[#zones + 1] = (okZ and (valid(rz) and name_of(rz) or "none") or "unread") .. "/" .. (okI and text_of(li) or "?")
            if live(lift) and ui.lift_is_for(lift, z.actor) then
                nMatch = nMatch + 1
                local okU, up = pcall(function() return lift.IsLiftUp end)
                local okP, busy = pcall(function() return lift.IsProcessing end)
                -- Each match is listed, as the gate reads every one of them.
                lf = (nMatch == 1 and "" or (lf .. "; ")) .. "lift up " .. (okU and tostring(up) or "unread") .. ", moving " .. (okP and tostring(busy) or "unread")
            end
        end
        local okB, bid = pcall(function() return z.actor.ID end)
        parts[#parts + 1] = lf .. " (" .. nMatch .. " matched; bay ID \"" .. (okB and text_of(bid) or "unread") .. "\" vs "
            .. #lifts .. " lifts, zone/ZoneIndex: " .. table.concat(zones, ", ") .. ")"
    end
    return table.concat(parts, ", ")
end
ui.held_stations = function(state)
    local found = {}
    for t, list in pairs(state and state.stations or {}) do
        for i, z in ipairs(list) do
            if z.reserved then
                local okW, why = pcall(ui.hold_why, t, z)
                why = okW and why or ("couldn't check: " .. tostring(why))
                -- The seconds change every read, so only the rest is compared.
                local key = "offer:" .. name_of(z.actor) .. (z.secondBay and ":2" or "")
                local cmp = why:gsub("^held %-?%d+s, ", "")
                if mapOnce[key] ~= cmp then
                    mapOnce[key] = cmp
                    log("held station " .. (ZONE_FULL[t] or "?") .. " " .. i .. " (" .. name_of(z.actor) .. "): " .. why)
                end
            end
            if z.reserved and (z.heldFor or 0) >= 30 and name_of(z.actor):find("^BP_WashZone_C")
                and ui.stale_hold(z.actor) and (t ~= 4 or ui.lift_state(z.actor) ~= "not down") then
                found[#found + 1] = { t = t, n = i, actor = z.actor,
                    label = (ZONE_FULL[t] or "Station") .. (#list > 1 and (" " .. i) or "") }
            end
        end
    end
    table.sort(found, function(a, b) return a.t < b.t or (a.t == b.t and a.n < b.n) end)
    return found
end

-- Mechanic lifts left up over an empty bay. Read in the game: the mechanic
-- lowers its lift at the end of work only while the car is still in the bay,
-- so a car taken out mid-job (Unstick, Reset) leaves the lift up and the bay
-- blocked. A mechanic bay's lift is found by ui.lift_is_for (RelatedZone, or
-- the lift's ZoneIndex against the bay's ID).
-- Returns { n = bay number, lift = lift, label = bay name } for each lift up,
-- not moving, over an empty bay.
-- A lift can still hold a car moved away mid-job (VehicleOnLift; measured).
-- Lowering it would pull that car back onto it, so such a lift is named but
-- not offered Lower Lift. Each lift up over an empty bay is logged when its
-- state changes, only while the Board is open (this runs when the panel is
-- drawn), so no line doesn't mean no stuck lift.
ui.stuck_lifts = function(state)
    local found = {}
    local bays = state and state.stations[4] or {}
    if #bays == 0 then return found end
    for _, lift in ipairs(find_all("BP_VehicleRepairLift_C")) do
        local okU, up = pcall(function() return lift.IsLiftUp end)
        local okP, busy = pcall(function() return lift.IsProcessing end)
        if live(lift) and okU and up == true and okP and busy == false then
            for i, z in ipairs(bays) do
                if ui.lift_is_for(lift, z.actor) and not z.vehicle then
                    local okV, held = pcall(function() return lift.VehicleOnLift end)
                    local heldId = nil
                    if okV and valid(held) then
                        local okI, cid = pcall(function() return held.CarId end)
                        heldId = okI and text_of(cid) or nil
                        if heldId == "" then heldId = nil end
                    end
                    local holding = not okV and "unreadable" or (valid(held) and ("a car " .. (heldId or "unnamed")) or "none")
                    -- Measured, and in the lift's move timeline: while it moves it
                    -- sets the held car's position every frame, so lowering a lift
                    -- that still holds a car pulls that car back onto it.
                    local holds = holding ~= "none"
                    local key = "lift:" .. name_of(lift)
                    if mapOnce[key] ~= holding then
                        mapOnce[key] = holding
                        log("lift " .. name_of(lift) .. " (bay " .. i .. "): up over an empty bay, holding " .. holding .. (holds and "; not offered" or "; Lower Lift offered"))
                    end
                    -- Named as everywhere else: numbered only when there's more than one.
                    found[#found + 1] = { n = i, lift = lift, heldId = heldId, holds = holds, zone = z.actor, label = "Mechanical Workshop" .. (#bays > 1 and (" " .. i) or "") }
                end
            end
        end
    end
    return found
end
-- The game's destination values: 0 measured in game; 1-3 from the game's own
-- labels for its destination enum.
local DEST_NAMES = { [0] = "Front Parking", [1] = "Side Parking", [2] = "Underground Garage", [3] = "Tuning Garage" }
local MODE_NAMES = { replace = "Replace Damaged", custom = "Custom", disassemble = "Disassemble" }
local MODES = { "replace", "custom", "disassemble" }
-- The ad screen's four checkboxes, as profile keys and the game's own labels.
local SALE_FLAGS = { { "nonNegotiable", "Non-negotiable" }, { "leasing", "Available for installments" },
    { "online", "Available for online sale" }, { "warranty", "Offer Warranty" } }
local TIERS = { "Default", "Stock", "Sport", "Race" }
local SLOT_TIERS = { "Stock", "Sport", "Race" }
-- The game's own station names (its automation zone labels).
local STEP_LABELS = { PhotoStudio = "Photo Studio", PaintBooth = "Paint Booth", CarWash = "Car Wash",
    BodyWorkshop = "Body Workshop", MechanicalWorkshop = "Mechanical Workshop", Compressor = "Air Compressor",
    GasPump = "Fuel Dispenser", ParkingSlot = "Parking" }

local function set_status(msg, good) ui.status, ui.statusGood = msg, good ~= false end
local NOT_ON_DISK = "Done, but the mod folder can't be written, so this lasts only until you quit the game."

-- Whether the player has bought the Vehicle Platform: true, false, or nil when
-- it can't be read. The game loads its automation area, platform included,
-- only once it's bought. "Robtics" is the game's own spelling.
ui.platform_owned = function()
    local owned = nil
    for _, econ in ipairs(find_all("BP_EconomySystem_C")) do
        if live(econ) then
            local ok, v = pcall(function() return econ.HasAutomationRobtics end)
            if not ok or type(v) ~= "boolean" then return nil end
            -- Two that disagree (one left from another save) tell nothing.
            if owned ~= nil and owned ~= v then return nil end
            owned = v
        end
    end
    return owned
end

-- What the player sees for an engine reason. The raw reason always goes to
-- the log (and so into the bug report).
local function player_reason(why)
    why = tostring(why or "")
    -- Mechanic-plan reasons first: two of them contain "unreadable"/"couldn't be read"
    -- and would otherwise get the platform-list text below.
    if why:find("no mechanic hired") then
        return "There's no mechanic at the Mechanical Workshop, so the car got no task. Hire one, or give the car a profile with the Mechanical Workshop off, then click Try Again."
    elseif why:find("^the mechanic's parts list couldn't be read") or why:find("^parts plan failed") then
        return "Couldn't read the mechanic's parts list, so the car got no task. Click Try Again."
    elseif why:find("^part condition unreadable") then
        return "Couldn't read the condition of this car's parts, so the car got no task. Click Try Again."
    elseif why:find("holds %d+ of %d+") or why:find("list not kept") or why:find("flag not kept")
        or why:find("parts lists unreadable") or why:find(" list unreadable")
        or why:find("^fluid entry of an unexpected type") or why:find("^car has no task to add parts to") then
        return "Couldn't add the parts to the car's task, so the task was taken off again and its parts put back in storage. Click Try Again."
    elseif why:find("robot manager not found") or why:find("task struct not found") then
        local owned = ui.platform_owned()
        local seen = why .. ", Vehicle Platform owned=" .. tostring(owned)
        if mapOnce.noPlatform ~= seen then
            mapOnce.noPlatform = seen
            log("automation not ready: " .. seen)
        end
        if owned == false then return "Automation needs the Vehicle Platform, which you don't own yet. It's available in the game's Store." end
        return "Automation isn't ready yet. Try again in a moment."
    elseif why:find("storage unreadable") or why:find("storage stacks unreadable") then
        return "Couldn't read your storage, so nothing was changed."
    -- Matches any reason containing "unreadable": an arm for a more specific
    -- unreadable reason must go above this one or it never fires.
    elseif why:find("unreadable") then
        return "Couldn't read the platform's list, so nothing was changed."
    elseif why:find("player storage not found") then
        return "Couldn't find your storage, so nothing was changed."
    elseif why:find("^missing in storage: ") then
        local names = {}
        for slot, cls in why:gmatch("([%w]+) %(([%w_]+)%)") do
            local tier = cls:match("_(Sport)_C$") or cls:match("_(Race)_C$") or "Stock"
            names[#names + 1] = tier .. " " .. (SLOT_LABELS[slot] or slot)
        end
        return "Missing in storage: " .. table.concat(names, ", ")
    elseif why:find("already working on this car") then
        return "The platform has already started on this car, so its parts can't be changed now."
    elseif why:find("need the DLC %(custom%)") then
        return "Sport and Race parts need the Up 2 You DLC. Pick Stock for those parts in this profile."
    elseif why:find("need the DLC") then
        return "Sport and Race parts need the Up 2 You DLC. Pick Stock or Default in this profile."
    elseif why:find("on a mechanic's lift while the mechanic works") then
        return "The mechanic is still working on this car on the lift. Wait until the mechanic is done, then try again."
    elseif why:find("on a mechanic's lift, bay state unread") then
        return "Couldn't tell whether the mechanic is done with this car, so nothing was changed. Try again in a moment."
    elseif why:find("can't tell which car the robot is on") then
        return "Couldn't tell which car the platform is working on, so nothing was changed. Try again in a moment."
    elseif why:find("a station is at work, its car unread") then
        return "A station is still working, and freeing the platform now could take its car out mid-job. Try again once the station is done."
    elseif why:find("platform status unread") then
        return "Couldn't read what the platform is doing, so nothing was changed. Try again in a moment."
    elseif why:find("a station is at work on another car") then
        return "A station is still working on another car, and freeing the platform now would take that car out mid-job. Try again once the station is done."
    elseif why:find("the platform is moving") then
        return "The platform is still moving, so it isn't stuck. Nothing was changed."
    elseif why:find("the platform is waiting for a station") then
        return "The platform isn't stuck. It's waiting for a station to finish and will carry on by itself, so nothing was changed."
    elseif why:find("the platform's path is blocked") then
        return "The platform isn't stuck. Something is in its way (the platform line on the Board names it when it can), and it carries on once that moves. If it's a car in automation, Reset Car on that car moves it out of the way, but takes it out of automation. Nothing was changed."
    elseif why:find("a station is working on this car") then
        return "A Car Wash or Body Workshop is still working on this car, so it isn't stuck. Nothing was changed."
    elseif why:find("station type unread") then
        return "Couldn't tell what kind of station the car is in, so nothing was changed. Try again in a moment."
    elseif why:find("no free parking spot") then
        return "There's no free spot in the parking near the warehouse, so nothing was changed. Free one up and try again."
    elseif why:find("already has a task") then
        return "This car already has an automation task."
    end
    return "Something went wrong. Report a Bug sends us the details."
end

-- The name the game itself shows: the record's own GetVehicleDisplayName
-- (brand and model). Falls back to the car's class name if that fails.
local function car_label_by_id(id, vehicle)
    local info = info_by_id(id)
    if info then
        local ok, t = pcall(function() return info:GetVehicleDisplayName(" ") end)
        local name = ok and text_of(t) or ""
        if name ~= "" then return name end
        if not valid(vehicle) then pcall(function() vehicle = info.Vehicle end) end
    end
    local n = valid(vehicle) and name_of(vehicle) or "Car"
    n = n:gsub("^BP_", ""):gsub("_C_%d+$", ""):gsub("Vehicle$", ""):gsub("(%l)(%u)", "%1 %2")
    return n
end

-- After Reset Car or Unstick: a car whose list of parts to take off (or
-- fuses to swap) didn't come back with its task is named, after whatever
-- the result said.
ui.note_lists_lost = function(r)
    if not (r and r.listLost and #r.listLost > 0) then return end
    local names = {}
    for _, id in ipairs(r.listLost) do names[#names + 1] = car_label_by_id(id) end
    set_status(ui.status .. " The mod couldn't keep the parts picked to take off or fuses to swap for "
        .. table.concat(names, ", ") .. ". Pick them again in the game's Automation screen.", false)
end

-- The car's preview photo, as the Underground Garage shows it, loaded by
-- its path from photos.lua (see ui.photo_key below). Cached by path; a
-- cached texture is checked before each use and loaded again if gone.
-- Photos crashed the game twice, both times copying the preset's
-- PreviewCarImages map, first from GetVehiclePreset's struct out-parameter
-- (Cars tab), then from the record's own ModelPresetInfo (on opening the
-- app). That map is no longer read. Each load is logged before it runs, so
-- the log of a crash names the photo.
local photoCache = {}
local PHOTOS_ON = true
local function car_photo(id)
    if not PHOTOS_ON then return nil end
    local info = info_by_id(id)
    if not info then return nil end
    local _, _, path = ui.photo_key(info)
    if not path then return nil end
    local tex = photoCache[path]
    if tex == false then return nil end
    if tex ~= nil and valid(tex) and prop_type(tex) == "Texture2D" then return tex end
    log("car photo loading: " .. path)
    tex = nil
    -- LoadAsset only: a lookup by path for an object that isn't loaded makes
    -- UE4SS walk every object, which has crashed it. Its second result says
    -- whether the game knows the path at all.
    local found = nil
    if type(LoadAsset) == "function" then
        local pok, perr = pcall(function() tex, found = LoadAsset(path) end)
        if not pok then log("car photo LoadAsset error: " .. tostring(perr)) end
    else
        log("car photo: LoadAsset isn't available")
    end
    local ok = valid(tex) and prop_type(tex) == "Texture2D"
    log("car photo " .. (ok and "loaded: " or ("not loaded (" .. (valid(tex) and prop_type(tex) or "nothing")
        .. ", found " .. tostring(found) .. "): ")) .. path)
    -- A path the game doesn't know stays blank for the session. Any other
    -- failure (found but not loaded, an error) is tried again on the next
    -- refresh, until it has failed three times in a row.
    ui.photoTries = ui.photoTries or {}
    if ok then
        photoCache[path] = tex
        ui.photoTries[path] = nil
    else
        ui.photoTries[path] = (ui.photoTries[path] or 0) + 1
        if found == false or ui.photoTries[path] >= 3 then photoCache[path] = false
        else photoCache[path] = nil end
    end
    return ok and tex or nil
end

-- Photo paths by model and paint colour, from photos.lua beside the mod
-- (generated from the game's table, since the map itself can't be read).
-- Read once; a missing or broken file means no photos, nothing else.
ui.photo_paths = function()
    if ui.photoTable ~= nil then return ui.photoTable or nil end
    ui.photoTable = false
    local f = io.open(mod_dir() .. "/photos.lua", "r")
    if not f then log("photos.lua not found") return nil end
    local src = f:read("*a")
    f:close()
    local chunk, err = load(src, "photos", "t", {})
    if not chunk then log("photos.lua broken: " .. tostring(err)) return nil end
    local ok, data = pcall(chunk)
    if ok and type(data) == "table" then ui.photoTable = data end
    local n = 0
    for _, row in pairs(ui.photoTable or {}) do for _ in pairs(row) do n = n + 1 end end
    log("photos.lua read: " .. n .. " photos")
    return ui.photoTable or nil
end

-- A photo's path under the saved-files folder, moved to the current save, and
-- how it was found; nil and the reason when there isn't one. The game's call
-- splits the whole path on "_" and keeps two pieces, so a "_" in a folder above
-- the photos loses the saved folder or the file's own end. Then the call gets
-- only Photos/<file>, and if that fails too the photo keeps the file name it
-- has. The reason says whether a folder has a "_" or a non-English letter,
-- never the folder itself.
ui.photo_rel = function(gm, fp)
    if not fp or fp == "" then return nil, "no file path" end
    local function moved(p)
        local o = {}
        local okN = gm and pcall(function() gm:ChangePhotoPathToCurrentSaveFile(p, o) end)
        local np = okN and out_field("NewPath", o) or nil
        np = np and text_of(np)
        return np ~= "" and np or nil, okN and "call ran" or "call failed"
    end
    local np, ran = moved(fp)
    local _, cut = (np or ""):lower():find("saved", 1, true)
    -- The same file type at the end, or the call lost part of the path.
    local ext = fp:match("%.%w+$") or ""
    local function whole(p) return p:sub(-#ext) == ext or ext == "" end
    if cut and whole(np:sub(cut + 1)) then return np:sub(cut + 1), "by the game's call" end
    local folder, tail = fp:match("^(.*[/\\])([Pp]hotos[/\\][^/\\]+)$")
    local why = string.format("%s, %s, folder has _=%s, folder plain=%s", ran, not np and "no result" or cut and "the file's end lost" or "no saved folder in the result",
        tostring((folder or fp):find("_", 1, true) ~= nil), tostring((folder or fp):find("[\128-\255]") == nil))
    if not tail then return nil, "no Photos folder in the file path (" .. why .. ")" end
    local short = moved(tail)
    if short and short:match("^[Pp]hotos[/\\][^/\\_]+_[^/\\_]+_[^/\\_]+$") and whole(short) then
        return "/" .. short, "by the file name (" .. why .. ")"
    end
    return "/" .. tail, "file name unchanged (" .. why .. ")"
end

-- A car's photo path from two plain numbers on its record: the model and
-- the paint colour. Returns model, colour and the path (nil: no photo).
-- Takes a live record. The safety is in never touching the photo map; the
-- pcalls catch Lua errors only, not a fault inside the game or UE4SS.
ui.photo_key = function(info)
    local m, c = nil, nil
    pcall(function() m = info.ModelName end)
    local colorField = struct_field("S_VehiclePaintColor", "ColorName")
    if colorField then pcall(function() c = info.Color[colorField] end) end
    m = type(m) == "number" and math.tointeger(m) or nil
    c = type(c) == "number" and math.tointeger(c) or nil
    if not (m and c) then return m, c, nil end
    local t = ui.photo_paths()
    local rel = t and t[m] and t[m][c]
    if not rel then return m, c, nil end
    return m, c, "/Game/CarDealerSim/Core/Vehicle/VehicleProperties/VehiclePhotos/" .. rel
end

-- A photo's width over its height, read from the texture, so a box can
-- match it instead of stretching it. nil if unread. A good read is kept for
-- the session; a failed one is tried again on later draws, up to three.
ui.photoAspect, ui.photoAspectTries = {}, {}
ui.photo_aspect = function(tex)
    local key = name_of(tex)
    if ui.photoAspect[key] then return ui.photoAspect[key] end
    local tries = ui.photoAspectTries[key] or 0
    if tries >= 3 then return nil end
    local w, ht = nil, nil
    pcall(function() w = tex:Blueprint_GetSizeX() end)
    pcall(function() ht = tex:Blueprint_GetSizeY() end)
    local a = (type(w) == "number" and type(ht) == "number" and w > 0 and ht > 0) and w / ht or nil
    log("car photo size " .. key .. ": " .. tostring(w) .. " x " .. tostring(ht))
    if a then ui.photoAspect[key] = a else ui.photoAspectTries[key] = tries + 1 end
    return a
end

-- A grey box the photo's size with a word on why there's none: the game
-- has no photo for a custom paint job (colour 19), on any model.
ui.no_photo = function(outer, id, w, ht)
    local info = info_by_id(id)
    local c = nil
    if info then c = select(2, ui.photo_key(info)) end
    -- A record or colour that didn't read turns "Custom Paint" into "No
    -- Photo" for that draw, and a colour that changes to or from custom
    -- changes the word. The state carries the colour, and each change of it
    -- is logged (the first draw included), so either flip shows as
    -- alternating lines.
    ui.noPhotoLast = ui.noPhotoLast or {}
    local st = (not info) and "record not found" or (not c) and "colour unread" or ("ok " .. tostring(c))
    if ui.noPhotoLast[id] ~= st then
        ui.noPhotoLast[id] = st
        log("no photo " .. car_label_by_id(id) .. " (" .. tostring(id):sub(1, 8) .. "): " .. st)
    end
    local box = new_widget("SizeBox", outer)
    pcall(function() box:SetWidthOverride(w) end)
    pcall(function() box:SetHeightOverride(ht) end)
    local bd = make_border(outer, COLORS.btnOff)
    local ov = new_widget("Overlay", outer)
    -- Two words on two lines in the small row box, broken by hand: wrapped
    -- text is measured after each redraw and flashed while it settled.
    local small = w < 100
    local word = c == 19 and "Custom Paint" or "No Photo"
    if small then word = word:gsub(" ", "\n", 1) end
    local t = make_text(outer, word, small and 11 or 15, COLORS.dim)
    pcall(function() t:SetJustification(1) end)
    local ts = ov:AddChildToOverlay(t)
    halign(ts, 2)
    valign(ts, 2)
    bd:SetContent(ov)
    box:SetContent(bd)
    return box
end

-- A photo widget for a row, or a placeholder if there's no photo. 54 high,
-- as wide as the photo's shape needs.
local function row_photo(row, outer, id)
    local tex = car_photo(id)
    if not tex then
        local sl = row:AddChildToHorizontalBox(ui.no_photo(outer, id, 54, 54))
        pad(sl, 0, 0, 12, 0)
        valign(sl, 2)
        return
    end
    local img = new_widget("Image", outer)
    pcall(function() img:SetBrushFromTexture(tex, false) end)
    pcall(function() img:SetVisibility(3) end)
    local box = new_widget("SizeBox", outer)
    local a = ui.photo_aspect(tex)
    local bw = a and math.max(54, math.min(160, math.floor(54 * a + 0.5))) or 96
    pcall(function() box:SetHeightOverride(54) end)
    pcall(function() box:SetWidthOverride(bw) end)
    box:SetContent(img)
    local sl = row:AddChildToHorizontalBox(box)
    pad(sl, 0, 0, 12, 0)
    valign(sl, 2)
end

local function deep_copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = deep_copy(v) end
    return c
end
-- Edits are kept per profile until saved, so moving between profiles loses nothing.
local function draft()
    if not ui.drafts[ui.selected] then ui.drafts[ui.selected] = deep_copy(profiles[ui.selected] or default_profile()) end
    return ui.drafts[ui.selected]
end
local function next_in(list, cur)
    for i, v in ipairs(list) do if v == cur then return list[i % #list + 1] end end
    return list[1]
end
local function profile_names()
    local names = {}
    for k in pairs(profiles) do names[#names + 1] = k end
    table.sort(names, function(a, b) if a == "Default" then return true elseif b == "Default" then return false end return a < b end)
    return names
end

-- Page bodies, rebuilt on every refresh (they're short lists).
-- The List's second section: cars on the parking spots with no task yet.
-- The profile picker: a "Profile: <name>" button opens a row of
-- choices (None and every profile); picking one assigns it and closes the
-- row. Built from the mod's own buttons (a UMG dropdown's selection event
-- can't be bound from a mod). A field of ui: the main body has no local to spare.
ui.picker_button = function(h, outer, id, w)
    local a = assignments[id]
    local host = resolve(h.hostPath)
    return make_button(host, h.hostPath, outer, "Profile: " .. (a or "None"), w or 260, 40,
        "pick:" .. id, 16, a and COLORS.btn or COLORS.btnOff)
end
ui.picker_choices = function(h, outer, id)
    local wrap = new_widget("WrapBox", outer)
    local host = resolve(h.hostPath)
    local cur = assignments[id]
    local function choice(label, name)
        local b = make_button(host, h.hostPath, outer, label, 200, 36, "assignto:" .. id .. "|" .. (name or ""), 15,
            (name == cur and id ~= "*") and COLORS.btnOn or COLORS.btnDark)
        pad(wrap:AddChildToWrapBox(b), 0, 4, 8, 4)
    end
    choice("None", nil)
    for _, n in ipairs(profile_names()) do choice(n, n) end
    return wrap
end
-- Cars that can be ticked for one shared profile: on an automation spot, no task yet.
ui.multi_free = function()
    local robot, free = robot_now(), {}
    for _, c in ipairs(bay_cars()) do if not (robot and stored_task(robot, c.id) ~= nil) then free[c.id] = true end end
    return free
end
-- The ticked-cars bar, shared by the Cars page and the Board (one selection
-- for both). A car that has its task (or has left) drops out. On the Board it
-- leads with Select Cars, which makes a click on the map tick a car instead
-- of opening its panel (a held Shift can't be read while the tablet has the
-- keyboard: the controller reports it up).
ui.multi_bar = function(h, list, outer, board)
    local free, n = ui.multi_free(), 0
    ui.multi = ui.multi or {}
    for id in pairs(ui.multi) do if free[id] then n = n + 1 else ui.multi[id] = nil end end
    if n == 0 and ui.pickFor == "*" then ui.pickFor = nil end
    if not next(free) then ui.boardTick = nil end
    if next(free) then
        local bar = new_row(outer, list)
        if board then
            add_button(h, bar, ui.boardTick and "Done Selecting" or "Select Cars", 200, "btick:",
                ui.boardTick and COLORS.btnOn or COLORS.btn, 16)
        end
        row_text(bar, outer, n == 1 and "1 car selected" or (n .. " cars selected"), nil, n > 0 and COLORS.text or COLORS.dim, 16)
        if n > 0 then
            local ps = bar:AddChildToHorizontalBox(make_button(resolve(h.hostPath), h.hostPath, outer,
                "Set Profile", 220, 40, "pick:*", 16, COLORS.btn))
            pad(ps, 12, 4, 8, 4)
            valign(ps, 2)
        end
        add_button(h, bar, "Select All", 160, "mall:", COLORS.btnDark, 16)
        if n > 0 then add_button(h, bar, "Clear", 120, "mclear:", COLORS.btnDark, 16) end
        if ui.pickFor == "*" and n > 0 then pad(list:AddChildToVerticalBox(ui.picker_choices(h, outer, "*")), 0, 0, 0, 6) end
    end
    return free, n
end

local function fill_waiting_list(h, list, outer)
    pad(list:AddChildToVerticalBox(make_text(outer, "Waiting for Automation", 20, COLORS.white)), 0, 14, 0, 4)
    local robot = robot_now()
    local n = 0
    for _, c in ipairs(bay_cars()) do
        local hasTask = robot and stored_task(robot, c.id) ~= nil
        if not hasTask then
            n = n + 1
            local row = new_row(outer, list)
            row_photo(row, outer, c.id)
            local a = assignments[c.id]
            local col = new_widget("VerticalBox", outer)
            local cs = row:AddChildToHorizontalBox(col)
            fill(cs, 1)
            valign(cs, 2)
            pad(cs, 0, 0, 12, 0)
            col:AddChildToVerticalBox(make_text(outer, car_label_by_id(c.id, c.vehicle), 18, COLORS.text))
            -- Intake stops trying after MAX_TRIES, so past that the car isn't queued.
            local gaveUp = a and (failures[c.id] or 0) >= MAX_TRIES
            local status = gaveUp and player_reason(lastReason[c.id]) or (a and "Queued: gets its task in a couple of seconds" or "Needs a profile")
            local st = make_text(outer, status, 15, (a and not gaveUp) and COLORS.dim or COLORS.bad)
            pcall(function() st:SetAutoWrapText(true) end)
            col:AddChildToVerticalBox(st)
            local ps = row:AddChildToHorizontalBox(ui.picker_button(h, outer, c.id))
            pad(ps, 0, 4, 8, 4)
            valign(ps, 2)
            if gaveUp then add_button(h, row, "Try Again", 150, "retry:" .. c.id, COLORS.btnDark, 16) end
            if ui.pickFor == c.id then pad(list:AddChildToVerticalBox(ui.picker_choices(h, outer, c.id)), 108, 0, 0, 6) end
        end
    end
    if n == 0 then row_text(new_row(outer, list), outer, "No cars waiting on the parking spots.", 1, COLORS.dim) end
end

local function fill_board_list(h, list, outer)
    local rows, why = board_rows()
    if not rows then row_text(new_row(outer, list), outer, player_reason(why), 1, COLORS.dim) return end
    pad(list:AddChildToVerticalBox(make_text(outer, "In Automation", 20, COLORS.white)), 0, 4, 0, 4)
    if #rows == 0 then row_text(new_row(outer, list), outer, "No cars in automation.", 1, COLORS.dim) end
    for _, r in ipairs(rows) do
        local row = new_row(outer, list)
        row_photo(row, outer, r.car)
        -- Name on top, the stations still to go underneath, wrapping inside
        -- their own column so they never run under the button.
        local col = new_widget("VerticalBox", outer)
        local cs = row:AddChildToHorizontalBox(col)
        fill(cs, 1)
        valign(cs, 2)
        pad(cs, 0, 0, 12, 0)
        col:AddChildToVerticalBox(make_text(outer, (r.current and "> " or "") .. car_label_by_id(r.car), 18, r.current and COLORS.good or COLORS.text))
        local left = {}
        for _, st in ipairs(r.remaining) do left[#left + 1] = STEP_LABELS[st] or st end
        local stations = make_text(outer, #left > 0 and table.concat(left, " > ") or "Finishing", 15, COLORS.dim)
        pcall(function() stations:SetAutoWrapText(true) end)
        col:AddChildToVerticalBox(stations)
        if ui.confirmUnstick == r.car then
            add_button(h, row, "Click to Confirm", 170, "unstick:" .. r.car, COLORS.btn, 16)
        else
            add_button(h, row, "Unstick", 170, "askunstick:" .. r.car, COLORS.btn, 16)
        end
        -- Two clicks: the reset runs the game's own reset for the platform.
        if ui.confirmReset == r.car then
            add_button(h, row, "Click to Confirm", 200, "reset:" .. r.car, COLORS.btnWarn, 16)
        else
            add_button(h, row, "Reset Car", 200, "askreset:" .. r.car, COLORS.btnWarn, 16)
        end
    end
end

-- The map view of the Board: a fixed plan of the lot (the same for every
-- player), each car drawn in the station or spot that reports it, and the
-- selected car's panel above. Plan units are pixels on the tablet.
local MAP_W, MAP_H = 1000, 640
local PLAN = {
    { t = 6, n = 1, x = 20,  y = 30,  w = 70,  h = 110, label = "Fuel" },
    { t = 5, n = 1, x = 130, y = 30,  w = 70,  h = 110, label = "Air 1" },
    { t = 5, n = 2, x = 220, y = 30,  w = 70,  h = 110, label = "Air 2" },
    { t = 1, n = 1, x = 20,  y = 170, w = 120, h = 110, label = "Paint" },
    { t = 2, n = 1, x = 470, y = 55,  w = 95,  h = 150, label = "Wash 1" },
    { t = 2, n = 2, x = 575, y = 55,  w = 95,  h = 150, label = "Wash 2" },
    { t = 3, n = 1, x = 680, y = 55,  w = 95,  h = 150, label = "Body 1" },
    { t = 3, n = 2, x = 785, y = 55,  w = 95,  h = 150, label = "Body 2" },
    { t = 0, n = 1, x = 890, y = 55,  w = 90,  h = 150, label = "Photo" },
    { t = 4, n = 1, x = 465, y = 450, w = 150, h = 160, label = "Mechanic 1" },
    { t = 4, n = 2, x = 620, y = 450, w = 150, h = 160, label = "Mechanic 2" },
}
local SPOT_X, SPOT_Y, SPOT_W, SPOT_AREA = 220, 172, 96, 432
local MAPC = {
    lot = { R = 0.105, G = 0.11, B = 0.125, A = 1 },
    floor = { R = 0.14, G = 0.15, B = 0.17, A = 1 },
    building = { R = 0.08, G = 0.09, B = 0.10, A = 1 },
    wall = { R = 0.23, G = 0.25, B = 0.28, A = 1 },
    zone = { R = 0.18, G = 0.42, B = 0.23, A = 1 },
    fuel = { R = 0.85, G = 0.76, B = 0.10, A = 1 },
    air = { R = 0.10, G = 0.56, B = 0.85, A = 1 },
    spot = { R = 0.79, G = 0.64, B = 0.15, A = 1 },
    off = { R = 0.25, G = 0.26, B = 0.28, A = 1 },
    robot = { R = 0.18, G = 0.88, B = 0.90, A = 1 },
    label = { R = 0.44, G = 0.82, B = 0.50, A = 1 },
    working = { R = 0.11, G = 0.34, B = 0.11, A = 1 },
    stuck = { R = 0.36, G = 0.08, B = 0.07, A = 1 },
    noprofile = { R = 0.36, G = 0.27, B = 0.03, A = 1 },
    queued = { R = 0.23, G = 0.26, B = 0.31, A = 1 },
    idle = { R = 0.16, G = 0.16, B = 0.17, A = 1 },
    sel = { R = 1, G = 1, B = 1, A = 1 },
    -- The screen value that converts to the app's dim text (0.55, 0.57, 0.60),
    -- so map labels match the legend and the rest of the app.
    dimtext = { R = 0.7674, G = 0.7797, B = 0.7977, A = 1 },
}
-- The values above are screen colours; the engine's brushes
-- and text take linear colour, so each is converted once with the sRGB curve
-- the engine itself uses, or the map comes out far paler than designed.
-- (The app's COLORS were picked by eye in game, so they're linear already.)
local function to_linear(v)
    if v <= 0.04045 then return v / 12.92 end
    return ((v + 0.055) / 1.055) ^ 2.4
end
for k, c in pairs(MAPC) do
    MAPC[k] = { R = to_linear(c.R), G = to_linear(c.G), B = to_linear(c.B), A = c.A }
end
local function at_canvas(canvas, w, x, y, cw, ch)
    local sl = canvas:AddChildToCanvas(w)
    pcall(function() sl:SetPosition({ X = x, Y = y }) end)
    pcall(function() sl:SetSize({ X = cw, Y = ch }) end)
    return sl
end
-- A box: an outline border around a filled border, with an optional label.
local function map_box(canvas, outer, x, y, w, h, fillC, lineC, label, labelC)
    local o = make_border(outer, lineC or fillC, 2, 2, 2, 2)
    local inner = make_border(outer, fillC, 6, 4, 6, 4)
    o:SetContent(inner)
    if label then
        local t = make_text(outer, label, 13, labelC or MAPC.label)
        pcall(function() t:SetAutoWrapText(true) end)
        inner:SetContent(t)
    end
    at_canvas(canvas, o, x, y, w, h)
end

-- What a car looks like on the map: queued, working, stuck, needs a profile, idle.
local function car_look(id, w, state, tasks)
    -- A car the robot is waiting on to move is drawn red, wherever it is.
    if state.blocking and state.blocking[id] then return "stuck" end
    local hasTask = tasks[id] == true
    if w.kind == "spot" and id ~= state.current then
        if hasTask and stalled_for(id) then return "stuck" end
        if hasTask or assignments[id] then return "queued" end
        return "noprofile"
    end
    if not hasTask and id ~= state.current then return "idle" end
    if stalled_for(id) then return "stuck" end
    return "working"
end

local function short_name(id)
    local full = car_label_by_id(id)
    local last = full:match("(%S+)$") or full
    if #last > 11 then last = last:sub(1, 10) .. "." end
    return last
end

local function car_tile(h, canvas, outer, id, look, cx, cy, w, ht, state)
    local host = resolve(h.hostPath)
    local line = (ui.selCar == id) and MAPC.sel or (ui.multi and ui.multi[id]) and MAPC.label
        or (id == state.current and MAPC.robot or nil)
    local btn = make_button(host, h.hostPath, outer, short_name(id), w - 6, ht - 6, "car:" .. id, 12, MAPC[look])
    local wrap = make_border(outer, line or MAPC[look], 3, 3, 3, 3)
    wrap:SetContent(btn)
    at_canvas(canvas, wrap, cx - w / 2, cy - ht / 2, w, ht)
end

-- The car the panel shows when nothing is picked: a stalled car, else the
-- robot's car, else the first in the robot's queue.
local function pick_car(state, entries)
    if ui.selCar and state.where[ui.selCar] then return ui.selCar end
    for id in pairs(state.where) do if stalled_for(id) then return id end end
    if state.current and state.where[state.current] then return state.current end
    for _, e in ipairs(entries or {}) do if state.where[e[1]] then return e[1] end end
    return nil
end

local function where_full(w)
    if w.kind == "spot" then return "Parking Spot " .. w.n end
    if w.kind == "moving" then return nil end
    local name = ZONE_FULL[w.type] or "a station"
    return w.count > 1 and (name .. " " .. w.n) or name
end

local function remaining_of(entry)
    local fields = task_fields()
    local asf = fields and field_named(fields, "AutomationSteps")
    local left = {}
    if not (asf and entry) then return left end
    for _, st in ipairs(STEP_NAMES) do
        local sf = field_named(asf[3], st)
        if sf then
            local ok, v = pcall(function() return entry[asf[1]][sf[1]] end)
            if ok and v == true then left[#left + 1] = STEP_LABELS[st] or st end
        end
    end
    return left
end

-- The photo fitted inside w x ht at its own shape; the placeholder if none.
local function photo_box(outer, id, w, ht)
    local tex = car_photo(id)
    if not tex then return ui.no_photo(outer, id, w, ht) end
    local box = new_widget("SizeBox", outer)
    local a = ui.photo_aspect(tex)
    if a then
        if ht * a <= w then w = math.floor(ht * a + 0.5) else ht = math.floor(w / a + 0.5) end
    end
    pcall(function() box:SetWidthOverride(w) end)
    pcall(function() box:SetHeightOverride(ht) end)
    local img = new_widget("Image", outer)
    pcall(function() img:SetBrushFromTexture(tex, false) end)
    pcall(function() img:SetVisibility(3) end)
    box:SetContent(img)
    return box
end

local function fill_panel(h, list, outer, state, entries, tasks)
    local card = make_border(outer, COLORS.card, 14, 12, 14, 12)
    local sbox = new_widget("SizeBox", outer)
    pcall(function() sbox:SetHeightOverride(210) end)
    sbox:SetContent(card)
    pad(list:AddChildToVerticalBox(sbox), 0, 0, 0, 10)
    local row = new_widget("HorizontalBox", outer)
    card:SetContent(row)
    local id = pick_car(state, entries)
    if not id then
        local col = new_widget("VerticalBox", outer)
        fill(row:AddChildToHorizontalBox(col), 1)
        col:AddChildToVerticalBox(make_text(outer, "Click a car on the map.", 20, COLORS.text))
        local inAuto, free = 0, 0
        for _ in pairs(tasks) do inAuto = inAuto + 1 end
        for _, sp in ipairs(state.spots) do if not sp.car then free = free + 1 end end
        col:AddChildToVerticalBox(make_text(outer, inAuto .. (inAuto == 1 and " car" or " cars") .. " in automation \194\183 "
            .. free .. (free == 1 and " free spot" or " free spots"), 15, COLORS.dim))
        return
    end
    local w = state.where[id]
    -- The game's own garage list shows these photos 150 square. Top-aligned,
    -- so the card's height doesn't stretch the photo.
    local ps = row:AddChildToHorizontalBox(photo_box(outer, id, 150, 150))
    pad(ps, 0, 0, 16, 0)
    valign(ps, 1)
    local info = new_widget("VerticalBox", outer)
    local is = row:AddChildToHorizontalBox(info)
    fill(is, 1)
    pad(is, 0, 0, 16, 0)
    info:AddChildToVerticalBox(make_text(outer, car_label_by_id(id), 20, COLORS.white))
    local place = where_full(w)
    -- A car with a task that no station or spot reports: on the robot, or parked off the plan.
    info:AddChildToVerticalBox(make_text(outer, (place and ("At " .. place) or "Not at a station or parking spot")
        .. (id == state.current and " \194\183 platform is on it" or ""), 15, COLORS.dim))
    local pr = ui.pendingReset[id]
    if pr then
        info:AddChildToVerticalBox(make_text(outer, pr.told and "Reset: waiting for a free spot in the parking near the warehouse."
            or pr.slow and ("Reset: " .. tostring(pr.place) .. " still hasn't finished after 5 minutes. The car goes to the parking near the warehouse once it's done.")
            or ("Reset: goes to the parking near the warehouse when " .. tostring(pr.place) .. " is done."), 15, pr.slow and COLORS.bad or COLORS.good))
    end
    local actions = new_widget("VerticalBox", outer)
    row:AddChildToHorizontalBox(actions)
    if tasks[id] then
        local entry
        for _, e in ipairs(entries) do if e[1] == id then entry = e[2] end end
        local left = remaining_of(entry)
        if applied[id] then info:AddChildToVerticalBox(make_text(outer, "Profile: " .. applied[id], 15, COLORS.dim)) end
        info:AddChildToVerticalBox(make_text(outer, "Still to Visit", 14, COLORS.dim))
        -- One chip per station; the first is green while the
        -- robot is on this car (it's the station it's at or heading to).
        local chips = new_widget("WrapBox", outer)
        local chipBg, chipFg = { R = 0.010, G = 0.040, B = 0.050, A = 1 }, { R = 0.62, G = 0.78, B = 0.80, A = 1 }
        local nowBg, nowFg = { R = 0.012, G = 0.090, B = 0.016, A = 1 }, { R = 0.55, G = 0.92, B = 0.55, A = 1 }
        local names = #left > 0 and left or { "Finishing" }
        -- Green marks the station the robot is taking this car to (its current
        -- target), not the first in the list: the robot's route doesn't follow
        -- the list's order.
        local target = nil
        if id == state.current then
            local r = robot_now()
            local tz = nil
            if r then pcall(function() tz = r.CurrentTaskTargetZone end) end
            if valid(tz) then
                local t = zone_type(tz)
                -- Stations by their one shared name table; the parking zones (7-11)
                -- are the Parking step.
                target = ZONE_FULL[t] or ((t and t >= 7 and t <= 11) and STEP_LABELS.ParkingSlot) or nil
            end
        end
        for i, nm in ipairs(names) do
            local now = target ~= nil and nm == target
            local chip = make_border(outer, now and nowBg or chipBg, 10, 3, 10, 3)
            chip:SetContent(make_text(outer, nm, 14, now and nowFg or chipFg))
            pad(chips:AddChildToWrapBox(chip), 0, 3, 6, 3)
        end
        info:AddChildToVerticalBox(chips)
        local secs = stalled_for(id)
        if secs then
            local again = unstuckAt[id] and os.clock() - unstuckAt[id] < 1800
            local mins = math.floor(secs / 60)
            info:AddChildToVerticalBox(make_text(outer, again and "Unstick didn't help this car. Reset Car takes it out of automation."
                or ("Here " .. mins .. (mins == 1 and " minute" or " minutes") .. " of play with no progress."), 15, COLORS.bad))
        end
        local host = resolve(h.hostPath)
        local function act(label, action, color)
            local b = make_button(host, h.hostPath, outer, label, 260, 44, action, 16, color)
            pad(actions:AddChildToVerticalBox(b), 0, 0, 0, 8)
        end
        act(ui.confirmUnstick == id and "Click to Confirm" or "Unstick", (ui.confirmUnstick == id and "unstick:" or "askunstick:") .. id, COLORS.btn)
        act(ui.confirmReset == id and "Click to Confirm" or "Reset Car", (ui.confirmReset == id and "reset:" or "askreset:") .. id, COLORS.btnWarn)
    else
        local a = assignments[id]
        local gaveUp = a and (failures[id] or 0) >= MAX_TRIES
        local msg = gaveUp and player_reason(lastReason[id]) or (a and "Profile set: the car gets its task in a couple of seconds."
            or "No profile yet. Click Profile to pick one, and the car gets its task.")
        -- A car waiting on a queued Reset has its own line above, and no Profile
        -- button until it's on a spot.
        if not ui.pendingReset[id] then
            local mt = make_text(outer, msg, 15, (a and not gaveUp) and COLORS.text or COLORS.bad)
            pcall(function() mt:SetAutoWrapText(true) end)
            info:AddChildToVerticalBox(mt)
        end
        if w.kind == "spot" then
            local host = resolve(h.hostPath)
            pad(actions:AddChildToVerticalBox(ui.picker_button(h, outer, id)), 0, 0, 0, 8)
            local on = ui.multi and ui.multi[id]
            pad(actions:AddChildToVerticalBox(make_button(host, h.hostPath, outer, on and "Selected" or "Select", 260, 44,
                "msel:" .. id, 16, on and COLORS.btnOn or COLORS.btnDark)), 0, 0, 0, 8)
            if ui.pickFor == id then info:AddChildToVerticalBox(ui.picker_choices(h, outer, id)) end
            if gaveUp then
                actions:AddChildToVerticalBox(make_button(host, h.hostPath, outer, "Try Again", 260, 44, "retry:" .. id, 16, COLORS.btnDark))
            end
        end
    end
end

-- What the robot is doing, from its own state (E_AutomationRobotGlowStatus,
-- the state behind its glow) and the manager's current task.
local ROBOT_STATE = {
    [0] = "Idle, no task",
    [1] = "Driving",
    [2] = "Picking up or setting down a car",
    [3] = "Waiting for a station to finish its work",
    [4] = "Waiting: its path is blocked",
    [5] = "Has no task it can do",
}
local ROBOT_PROBLEM = { [4] = true, [5] = true }
-- The cars in the robot's way. The robot stops for a car overlapping the box
-- at its front that isn't the car it's working on; each car on the map is
-- asked whether that box overlaps it (a yes/no answer; the game's own list of
-- overlapping actors comes back through an out-parameter array, the kind of
-- read kept out of this mod).
local function robot_blockers(robot, state)
    local box, cur = nil, nil
    pcall(function() box = robot.Robot.BoxComponent end)
    pcall(function() cur = robot.CurrentTaskVehicle end)
    if not valid(box) or not state then return {} end
    local found = {}
    local function check(vehicle, where)
        if not valid(vehicle) or (valid(cur) and same_obj(vehicle, cur)) then return end
        local ok, hit = pcall(function() return box:IsOverlappingActor(vehicle) end)
        if ok and hit == true then
            local id = car_id_of(vehicle)
            if id and id ~= "" then found[#found + 1] = { id = id, where = where } end
        end
    end
    -- Place phrases: "on Parking Spot 5", "at Car Wash 2", or "at the Car Wash"
    -- when a lot has only one of that station.
    for i, sp in ipairs(state.spots) do check(sp.vehicle, "on Parking Spot " .. i) end
    for t, list in pairs(state.stations) do
        for i, z in ipairs(list) do
            check(z.vehicle, #list > 1 and ("at " .. (ZONE_FULL[t] or "a station") .. " " .. i) or ("at the " .. (ZONE_FULL[t] or "station")))
        end
    end
    -- Cars with a task that are in no station or spot: one the robot let go
    -- of in mid-air blocked it this way and wasn't named.
    for _, e in ipairs(task_entries(robot) or {}) do
        local id, w = e[1], state.where[e[1]]
        if not w or w.kind == "moving" then
            local info, vehicle = info_by_id(id), nil
            if info then pcall(function() vehicle = info.Vehicle end) end
            check(vehicle, "(not at a station or parking spot)")
        end
    end
    -- The player, who the robot also stops for.
    local okP, pawn = pcall(function() return FindFirstOf("PlayerController").Pawn end)
    if okP and valid(pawn) then
        local ok, hit = pcall(function() return box:IsOverlappingActor(pawn) end)
        if ok and hit == true then found[#found + 1] = { you = true } end
    end
    return found
end
local function robot_line(state)
    local robot = robot_now()
    if not robot then return nil end
    local glow = nil
    pcall(function() glow = tonumber(robot.Robot.CurrentGlowStatus) end)
    glow = glow and math.floor(glow) or nil
    -- A state a game update adds still shows its number rather than a blank.
    local text = "Platform: " .. (ROBOT_STATE[glow] or (glow and ("Status " .. glow) or "Status unknown"))
    if glow == 4 then
        local blockers = robot_blockers(robot, state or map_state())
        if #blockers > 0 then
            local names = {}
            for _, b in ipairs(blockers) do names[#names + 1] = b.you and "you" or (car_label_by_id(b.id) .. " " .. b.where) end
            text = "Platform: Waiting: its path is blocked by " .. table.concat(names, ", ")
        else
            text = "Platform: Waiting: its path is blocked, but not by you or by a car on a parking spot, at a station or in automation"
        end
        return text, true, glow
    end
    local car, target = nil, nil
    pcall(function() car = robot.CurrentTaskVehicle end)
    pcall(function() target = robot.CurrentTaskTargetZone end)
    local id = valid(car) and car_id_of(car) or nil
    if id and id ~= "" then text = text .. " \194\183 " .. car_label_by_id(id) end
    if valid(target) then
        local t = zone_type(target)
        local place = (t == WAREHOUSE_PARKING) and "Parking Near the Warehouse" or ZONE_FULL[t]
        if place then text = text .. ", going to " .. place end
    end
    return text, ROBOT_PROBLEM[glow] == true, glow
end
local lastRobotGlow = nil

local function fill_board_map(h, list, outer)
    local state, why = map_state()
    if not state then row_text(new_row(outer, list), outer, player_reason(why), 1, COLORS.dim) return end
    stall_track(state)
    local robot = robot_now()
    local entries = (robot and task_entries(robot)) or {}
    local tasks = {}
    for _, e in ipairs(entries) do tasks[e[1]] = true end
    local aisle = {}
    for _, e in ipairs(entries) do
        if not state.where[e[1]] then
            aisle[#aisle + 1] = e[1]
            state.where[e[1]] = { kind = "moving" }
        end
    end
    if ui.selCar and not state.where[ui.selCar] then ui.selCar = nil end
    fill_panel(h, list, outer, state, entries, tasks)
    ui.multi_bar(h, list, outer, true)
    local rtext, rbad, glow = robot_line(state)
    if glow == 4 then
        state.blocking = {}
        for _, b in ipairs(robot_blockers(robot_now(), state)) do if b.id then state.blocking[b.id] = true end end
    end
    -- The platform line keeps two lines' height whether its text wraps or
    -- not, so the map below doesn't move each time the line changes. A
    -- minimum, not an override: a longer line still pushes the map down
    -- rather than being cut off. No line (no platform yet), no space.
    if rtext then
        local rt = make_text(outer, rtext, 16, rbad and COLORS.bad or COLORS.text)
        pcall(function() rt:SetAutoWrapText(true) end)
        local rsb = new_widget("SizeBox", outer)
        pcall(function() rsb:SetMinDesiredHeight(44) end)
        rsb:SetContent(rt)
        pad(list:AddChildToVerticalBox(rsb), 0, 0, 0, 8)
    end
    for _, sl in ipairs(ui.stuck_lifts(state)) do
        local row = new_row(outer, list)
        if sl.holds then
            row_text(row, outer, sl.label .. ": the lift is stuck up. It still counts " .. (sl.heldId and car_label_by_id(sl.heldId) or "a car")
                .. " as on it, though the car has left the bay, so the bay can't be used. Lowering it from here would pull that car back, so the mod can't lower it yet.", 1, COLORS.bad, 16)
        else
            row_text(row, outer, sl.label .. ": the lift is up with no car in the bay, so the bay can't be used.", 1, COLORS.bad, 16)
            add_button(h, row, "Lower Lift", 180, "lowerlift:" .. sl.n, COLORS.btn, 18)
        end
    end
    for _, hs in ipairs(ui.held_stations(state)) do
        local row = new_row(outer, list)
        row_text(row, outer, hs.label .. ": the game is still holding this station, though no car is in it.", 1, COLORS.bad, 16)
        add_button(h, row, "Free Station", 180, "freestation:" .. hs.t .. ":" .. hs.n, COLORS.btn, 18)
    end

    local canvas = new_widget("CanvasPanel", outer)
    local frame = new_widget("SizeBox", outer)
    pcall(function() frame:SetWidthOverride(MAP_W) end)
    pcall(function() frame:SetHeightOverride(MAP_H) end)
    frame:SetContent(canvas)
    list:AddChildToVerticalBox(frame)
    -- Ground, building, and the fixed parts of the lot.
    map_box(canvas, outer, 0, 0, MAP_W, MAP_H, MAPC.lot, MAPC.lot)
    map_box(canvas, outer, 455, 40, 535, 580, MAPC.building, MAPC.wall)
    map_box(canvas, outer, 20, 280, 120, 330, MAPC.wall, MAPC.wall, "Warehouse Storage", MAPC.dimtext)
    map_box(canvas, outer, 775, 450, 210, 160, MAPC.floor, MAPC.zone, "Office")
    map_box(canvas, outer, 820, 392, 120, 50, MAPC.building, MAPC.robot, "Platform Dock", MAPC.robot)
    at_canvas(canvas, make_text(outer, "Main Door", 11, MAPC.dimtext), 380, 316, 70, 16)
    at_canvas(canvas, make_text(outer, "Back Door", 11, MAPC.dimtext), 920, 250, 70, 16)
    at_canvas(canvas, make_text(outer, "Parking Near the Warehouse", 11, MAPC.dimtext), SPOT_X, SPOT_Y - 18, 240, 16)
    -- Stations: a box per plan slot; a slot past the stations the player has is "not built".
    for _, slot in ipairs(PLAN) do
        local list_t = state.stations[slot.t] or {}
        local z = list_t[slot.n]
        local line = slot.t == 6 and MAPC.fuel or (slot.t == 5 and MAPC.air or MAPC.zone)
        if z then
            map_box(canvas, outer, slot.x, slot.y, slot.w, slot.h, MAPC.floor, line, slot.label)
            -- Whether the station is working, from its own work state (left off when unread).
            if z.running ~= nil then
                at_canvas(canvas, make_text(outer, z.running and "Working" or (z.reserved and "Reserved" or "Idle"), 13, z.running and COLORS.good or (z.reserved and COLORS.text or MAPC.dimtext)),
                    slot.x + 6, slot.y + slot.h - 22, slot.w - 12, 18)
            end
            if z.car then
                local look = car_look(z.car, state.where[z.car], state, tasks)
                local tw = math.min(slot.w - 8, 86)
                car_tile(h, canvas, outer, z.car, look, slot.x + slot.w / 2, slot.y + slot.h / 2 + 10, tw, 40, state)
            end
        else
            map_box(canvas, outer, slot.x, slot.y, slot.w, slot.h, MAPC.building, MAPC.off, slot.label .. " (Not Built)", MAPC.dimtext)
        end
    end
    -- Parking spots, from the paint booth end.
    local n = #state.spots
    local step = n > 0 and math.min(48, SPOT_AREA / n) or 48
    for i, sp in ipairs(state.spots) do
        local y = SPOT_Y + (i - 1) * step
        map_box(canvas, outer, SPOT_X, y, SPOT_W, step - 6, MAPC.lot, MAPC.spot)
        if sp.car then
            car_tile(h, canvas, outer, sp.car, car_look(sp.car, state.where[sp.car], state, tasks), SPOT_X + SPOT_W / 2, y + (step - 6) / 2, 82, math.max(26, step - 10), state)
        end
    end
    -- Cars with a task that aren't in a station or spot (on the robot, or
    -- elsewhere on the lot) are lined up in the aisle.
    for i, id in ipairs(aisle) do
        if i <= 4 then
            local look = ((state.blocking and state.blocking[id]) or stalled_for(id)) and "stuck" or (id == state.current and "working" or "queued")
            car_tile(h, canvas, outer, id, look, 500 + (i - 1) * 92 + 40, 320, 82, 40, state)
        end
    end
    if #aisle > 4 then
        at_canvas(canvas, make_text(outer, "+" .. (#aisle - 4) .. " more (see List)", 13, MAPC.dimtext), 870, 310, 110, 20)
    end
    -- The legend, under the map.
    -- A WrapBox, so a long legend goes onto a second line instead of being cut off.
    local legW = new_widget("WrapBox", outer)
    pad(list:AddChildToVerticalBox(legW), 0, 2, 0, 2)
    for _, it in ipairs({ { MAPC.queued, MAPC.queued, "Queued" }, { MAPC.working, MAPC.working, "In Automation" },
        { MAPC.working, MAPC.robot, "Platform Is on It" }, { MAPC.stuck, MAPC.stuck, "Possibly Stalled" },
        { MAPC.noprofile, MAPC.noprofile, "Needs a Profile" }, { MAPC.queued, MAPC.label, "Selected" },
        { MAPC.lot, MAPC.spot, "Parking Spot" }, { MAPC.building, MAPC.off, "Not Built" } }) do
        local leg = new_widget("HorizontalBox", outer)
        legW:AddChildToWrapBox(leg)
        local sw = make_border(outer, it[2], 2, 2, 2, 2)
        sw:SetContent(make_border(outer, it[1]))
        local sb = new_widget("SizeBox", outer)
        pcall(function() sb:SetWidthOverride(16) end)
        pcall(function() sb:SetHeightOverride(16) end)
        sb:SetContent(sw)
        local sl = leg:AddChildToHorizontalBox(sb)
        valign(sl, 2)
        pad(sl, 0, 4, 6, 4)
        row_text(leg, outer, it[3], nil, COLORS.dim, 13)
    end
end

local function fill_board(h, list, outer)
    if ui.boardView == "list" then
        local rtext, rbad = robot_line()
        -- Same two-line minimum as the map view, so the rows don't move either.
        if rtext then
            local rt = make_text(outer, rtext, 16, rbad and COLORS.bad or COLORS.text)
            pcall(function() rt:SetAutoWrapText(true) end)
            local rsb = new_widget("SizeBox", outer)
            pcall(function() rsb:SetMinDesiredHeight(44) end)
            rsb:SetContent(rt)
            pad(list:AddChildToVerticalBox(rsb), 0, 0, 0, 8)
        end
        fill_board_list(h, list, outer)
        fill_waiting_list(h, list, outer)
    else
        fill_board_map(h, list, outer)
    end
end

local function fill_cars(h, list, outer)
    local cars = bay_cars()
    if #cars == 0 then row_text(new_row(outer, list), outer, "No cars in the parking near the warehouse.", 1, COLORS.dim) return end
    local robot = robot_now()
    local free = ui.multi_bar(h, list, outer, false)
    for _, c in ipairs(cars) do
        local row = new_row(outer, list)
        if free[c.id] then
            add_button(h, row, ui.multi[c.id] and "Selected" or "Select", 130, "msel:" .. c.id,
                ui.multi[c.id] and COLORS.btnOn or COLORS.btnDark, 16)
        end
        row_photo(row, outer, c.id)
        row_text(row, outer, car_label_by_id(c.id, c.vehicle), 2, COLORS.text)
        local hasTask = robot and stored_task(robot, c.id) ~= nil
        if hasTask then
            row_text(row, outer, "in automation" .. (applied[c.id] and (" \194\183 Profile: " .. applied[c.id]) or ""), 1, COLORS.good)
        else
            local a = assignments[c.id]
            local ps = row:AddChildToHorizontalBox(ui.picker_button(h, outer, c.id))
            pad(ps, 0, 4, 8, 4)
            valign(ps, 2)
            if (failures[c.id] or 0) >= MAX_TRIES then
                row_text(row, outer, player_reason(lastReason[c.id]), 2, COLORS.bad, 16)
                add_button(h, row, "Try Again", 150, "retry:" .. c.id, COLORS.btnDark, 16)
            end
            if ui.pickFor == c.id then pad(list:AddChildToVerticalBox(ui.picker_choices(h, outer, c.id)), 108, 0, 0, 6) end
        end
    end
end

-- Front Parking: every customer spot and the car on it. The mod's cars (the
-- ones it brought here, kept in `sales`) are filled: green when listed,
-- purple when the mod couldn't confirm the ad, yellow when their profile
-- doesn't post, red when the post was refused. The player's own cars are
-- green-outlined when listed and grey otherwise, and the mod never acts on
-- them.
ui.SALE_WHY = {
    spot = "it isn't on a Front Parking spot", parked = "it isn't parked inside the spot's lines",
    owned = "you don't own it", canOffer = "the game doesn't allow an ad for this car",
    serviceRequest = "it has a service request", canBeSold = "this model can't be sold",
    offer = "it's already listed", excluded = "the game won't sell this car", price = "no price could be worked out",
    photo = "it has no photos from the Photo Studio", adFields = "the ad couldn't be prepared",
    restore = "the mod couldn't put back the ad details it changed on the car",
    postNone = "no ad showed up for it after posting",
    postError = "the mod ran into an error while posting it",
    record = "its record couldn't be read",
}
-- A price as the game shows it: whole dollars with thousands separators.
ui.money = function(n)
    local t = tostring(math.floor(tonumber(n) or 0))
    local out = t:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return "$" .. out:gsub("^,", "")
end
-- The customer spots in a stable order (by position), each with its car's id.
ui.front_spots = function()
    local list = {}
    for _, gm in ipairs(find_all("BP_GameMode_C")) do
        if live(gm) and #list == 0 then
            pcall(function()
                gm.CustomerSystem.ParkingSlots:ForEach(function(_, v)
                    local okV, sp = pcall(function() return v:get() end)
                    -- A spot that can't be read keeps its place (at the end), marked,
                    -- so it isn't taken for "no car" and the numbers don't shift.
                    if not (okV and valid(sp)) then
                        -- unread also keeps it in the office list below (its kind is unknown).
                        list[#list + 1] = { unread = true, nopos = true, x = #list, y = 1e9 }
                        return
                    end
                    local okC, veh = pcall(function() return sp.ParkingSlotVehicle end)
                    local loc = actor_loc(sp)
                    if not (loc and type(loc.X) == "number" and type(loc.Y) == "number") then loc = nil end
                    local cid = okC and valid(veh) and car_id_of(veh) or nil
                    -- A car on the spot whose id couldn't be read (or a spot that
                    -- couldn't be read) is marked, so it isn't taken for "no car".
                    -- A spot whose position can't be read has no place in the row.
                    list[#list + 1] = { slot = sp, id = cid, unread = (not okC) or (valid(veh) and cid == nil),
                        nopos = loc == nil, x = loc and loc.X or #list, y = loc and loc.Y or 1e9,
                        kind = name_of(sp):match("^(.-_C)_") or "?" }
                end)
            end)
        end
    end
    -- The game's customer spots include more than Front Parking (23 against
    -- 14 in play); the car the platform left at Front Parking stood on a
    -- BP_OfficeParkingSlot_C, so only those are kept, if there are any. The
    -- kinds and positions are logged once, to check this against the lot.
    -- Logged again whenever the number of spots changes, so a census taken
    -- while the list was still filling isn't the only one.
    if ui.frontKindsN ~= #list and #list > 0 then
        ui.frontKindsN = #list
        local w = {}
        for _, sp in ipairs(list) do w[#w + 1] = string.format("%s@%.0f,%.0f", tostring(sp.kind), sp.x, sp.y) end
        table.sort(w)
        log("Front Parking: customer spots (" .. #list .. "): " .. table.concat(w, ", "))
    end
    local office = {}
    for _, sp in ipairs(list) do
        if sp.unread or tostring(sp.kind):find("OfficeParkingSlot", 1, true) then office[#office + 1] = sp end
    end
    local hasOffice = false
    for _, sp in ipairs(office) do if not sp.unread then hasOffice = true end end
    if hasOffice then list = office end
    -- The spots stand in one row: numbered along its long axis, from the end
    -- the player counts from (checked in play: the opposite end to ascending
    -- X). A spot whose car can't be read keeps its place in the row; only a
    -- spot with no position goes last.
    local lo, hi = { x = math.huge, y = math.huge }, { x = -math.huge, y = -math.huge }
    for _, sp in ipairs(list) do
        if not sp.nopos then
            lo.x, lo.y = math.min(lo.x, sp.x), math.min(lo.y, sp.y)
            hi.x, hi.y = math.max(hi.x, sp.x), math.max(hi.y, sp.y)
        end
    end
    local axis = (hi.x - lo.x >= hi.y - lo.y) and "x" or "y"
    table.sort(list, function(a, b)
        if a.nopos ~= b.nopos then return not a.nopos end
        if a.nopos then return a.x < b.x end
        return a[axis] > b[axis]
    end)
    return list
end
-- What the Front Parking page shows, as one string: the timed refresh
-- rebuilds the page only when this changes, so it doesn't blink every pass
-- (a rebuild clears the page, and slow-to-draw parts showed the gap).
ui.front_sig = function()
    local parts = { tostring(ui.frontSel), tostring(ui.status), tostring(ui.statusGood) }
    for _, sp in ipairs(ui.front_spots()) do
        local p = tostring(sp.id) .. (sp.unread and "?" or "")
        if sp.id then
            local e, offer, info = sales[sp.id], false, info_by_id(sp.id)
            if info then pcall(function() offer = valid(info.VehicleOffer) end) end
            p = p .. (offer and "+" or "")
            -- The photo: a repaint changes it, a texture the engine drops has
            -- to be drawn again, and a failed load is retried on the next
            -- pass (its count of tries moves the signature).
            if info then
                local m, cc, path = ui.photo_key(info)
                local tx = path and photoCache[path]
                p = p .. ":" .. tostring(m) .. "/" .. tostring(cc) .. "/" .. tostring(tx ~= nil and tx ~= false and valid(tx))
                    .. "/" .. tostring(path and ui.photoTries and ui.photoTries[path])
            end
            if e then
                p = p .. ":" .. table.concat({ tostring(e.s), tostring(e.why), tostring(e.market), tostring(e.price),
                    tostring(e.bar), tostring(e.opts), tostring(e.profile) }, ":")
            end
        end
        parts[#parts + 1] = p
    end
    return table.concat(parts, "|")
end
ui.fill_front = function(h, list, outer)
    pcall(function() h.frontSig = ui.front_sig() end)
    local spots = ui.front_spots()
    if #spots == 0 then row_text(new_row(outer, list), outer, "No Front Parking spots found.", 1, COLORS.dim) return end
    local host = resolve(h.hostPath)
    local here, changed, anyUnread = {}, false, false
    -- Drawn like the lot: one row of spots, each a painted outline open at
    -- the front, with its number below.
    local LOT, PAINT = { R = 0.03, G = 0.035, B = 0.04, A = 1.0 }, { R = 0.55, G = 0.57, B = 0.60, A = 1.0 }
    local lot = make_border(outer, LOT, 14, 12, 14, 12)
    local inner = new_widget("VerticalBox", outer)
    lot:SetContent(inner)
    pad(list:AddChildToVerticalBox(lot), 0, 4, 0, 8)
    -- Up to 14 spots in a row (the lot's own row); more wrap onto further
    -- rows rather than running off the page. A spot is its box plus 16 of
    -- outline and spacing, and the row has ROW_W to fill.
    local ROW_W, PER_ROW = 1372, 14
    local perRow = math.min(#spots, PER_ROW)
    local boxW = math.min(82, math.floor(ROW_W / perRow) - 16)
    local spotRow = nil
    for i, sp in ipairs(spots) do
        if (i - 1) % perRow == 0 then spotRow = new_row(outer, inner) end
        if sp.unread then anyUnread = true end
        local id, cell = sp.id, new_widget("VerticalBox", outer)
        local num = make_text(outer, "F" .. i, 13, COLORS.white)
        local tile
        if id then
            here[id] = i
            local e, offer = sales[id], false
            local info = info_by_id(id)
            local okOf = info and pcall(function() offer = valid(info.VehicleOffer) end)
            -- A mod car the player listed by hand is the player's from then on,
            -- and so is one whose ad the player took down. A car whose ad the
            -- mod couldn't confirm keeps its record either way.
            if e and offer and e.s ~= "posted" and e.s ~= "check" then sales[id], e, changed = nil, nil, true end
            if e and e.s == "posted" and okOf and not offer then
                log("sale " .. id .. ": its ad is gone, so it's the player's now")
                sales[id], e, changed = nil, nil, true
            end
            local fillC, line
            if e then
                fillC = e.s == "posted" and COLORS.btnOn or e.s == "refused" and COLORS.btnWarn
                    or e.s == "unpriced" and COLORS.barYellow or e.s == "check" and COLORS.checkAd or COLORS.btn
            else
                fillC, line = offer and LOT or COLORS.btnOff, offer and COLORS.barGreen or nil
            end
            if ui.frontSel == id then line = COLORS.white end
            -- A long name at 14 ran past its tile into the next one; the font
            -- shrinks to fit the tile (about 0.72 of the size per letter,
            -- measured off a 14 pt "Highrunner"), never below 10.
            local nm = short_name(id)
            local fs = math.max(10, math.min(14, math.floor((boxW - 12) / (math.max(#nm, 1) * 0.72))))
            local btn = make_button(host, h.hostPath, outer, nm, boxW - 6, 154, "fsel:" .. id, fs, fillC)
            tile = make_border(outer, line or LOT, 3, 3, 3, 3)
            tile:SetContent(btn)
        else
            -- Centred the way a button centres its label: an overlay slot.
            tile = new_widget("Overlay", outer)
            local ts = tile:AddChildToOverlay(make_text(outer, sp.unread and "?" or "empty", 13, COLORS.dim))
            halign(ts, 2)
            valign(ts, 2)
        end
        local spot = make_border(outer, PAINT, 2, 2, 2, 0)
        local face = make_border(outer, LOT, 4, 6, 4, 6)
        local box = new_widget("SizeBox", outer)
        -- The tile's 3-px outline on all four sides: the button fills the box less the outline.
        pcall(function() box:SetWidthOverride(boxW) end)
        pcall(function() box:SetHeightOverride(160) end)
        box:SetContent(tile)
        face:SetContent(box)
        spot:SetContent(face)
        halign(cell:AddChildToVerticalBox(spot), 2)
        halign(cell:AddChildToVerticalBox(num), 2)
        pad(spotRow:AddChildToHorizontalBox(cell), 0, 0, 4, 0)
    end
    -- A record whose car has left Front Parking (sold, or moved away) goes,
    -- except while the car is on its way (pending, or sent back for photos),
    -- and not on a pass where any spot's car couldn't be read.
    if not anyUnread then
        ui.frontSkipLogged = nil
        for id, e in pairs(sales) do
            if not here[id] and e.s ~= "pending" and e.s ~= "sent" then sales[id] = nil changed = true end
        end
    elseif not ui.frontSkipLogged then
        ui.frontSkipLogged = true
        log("Front Parking: a spot or its car couldn't be read, so records for cars that left are kept for now")
    end
    if changed then save_profiles() end
    -- The legend: a swatch for each state.
    local leg = new_row(outer, list)
    for _, it in ipairs({ { COLORS.btnOn, nil, "Listed by the Mod" }, { COLORS.barYellow, nil, "Post for Sale Off" },
        { COLORS.btnWarn, nil, "Not Posted" }, { COLORS.checkAd, nil, "Check the Ad" }, { COLORS.btn, nil, "Being Checked" },
        { LOT, COLORS.barGreen, "Listed by You" }, { COLORS.btnOff, nil, "Yours, Not Listed" },
        { LOT, COLORS.white, "Details Shown Below" } }) do
        local sw = make_border(outer, it[2] or it[1], 3, 3, 3, 3)
        local fillb = make_border(outer, it[1], 0, 0, 0, 0)
        local sz = new_widget("SizeBox", outer)
        pcall(function() sz:SetWidthOverride(22) end)
        pcall(function() sz:SetHeightOverride(12) end)
        fillb:SetContent(sz)
        sw:SetContent(fillb)
        valign(leg:AddChildToHorizontalBox(sw), 2)
        row_text(leg, outer, it[3], nil, COLORS.dim, 14)
    end
    row_text(new_row(outer, list), outer, "? means a spot couldn't be read.", 1, COLORS.dim, 14)
    local id = ui.frontSel
    if not (id and here[id]) then
        row_text(new_row(outer, list), outer, "Click a car for its details.", 1, COLORS.dim)
        return
    end
    local e, info, offer = sales[id], info_by_id(id), false
    if info then pcall(function() offer = valid(info.VehicleOffer) end) end
    if e and offer and e.s ~= "posted" and e.s ~= "check" then e = nil end
    -- The car's panel: its photo, then what the mod knows about it.
    local card = make_border(outer, COLORS.card, 14, 12, 14, 12)
    local prow = new_widget("HorizontalBox", outer)
    card:SetContent(prow)
    pad(list:AddChildToVerticalBox(card), 0, 6, 0, 0)
    row_photo(prow, outer, id)
    local col = new_widget("VerticalBox", outer)
    fill(prow:AddChildToHorizontalBox(col), 1)
    row_text(new_row(outer, col), outer, car_label_by_id(id), 1, COLORS.text, 20)
    row_text(new_row(outer, col), outer, "Front Parking, spot F" .. here[id], 1, COLORS.dim, 15)
    local line, good
    if not e then
        -- Not listed isn't a success, so it's drawn plain rather than green.
        line, good = offer and "Your ad. The mod doesn't change it." or "Not listed. Price it in Your Ads.", offer and true or "plain"
    elseif e.s == "posted" then
        line, good = "Listed by the mod.", true
    elseif e.s == "check" and e.why == "postMismatch" then
        line, good = "Listed, but the ad isn't what the mod set up (the price, options or photos). Check it in Your Ads.", false
    elseif e.s == "check" and e.why == "postPartial" then
        line, good = "Listed, but the mod couldn't check all of its details. Check it in Your Ads.", false
    elseif e.s == "check" then
        line, good = "Couldn't tell whether it was listed. Look for it in Your Ads, or click Try Again.", false
    elseif e.s == "refused" then
        line, good = "Not posted: " .. (ui.SALE_WHY[e.why] or tostring(e.why)) .. "."
            .. (e.why == "postError" and " Report a Bug sends us the details." or ""), false
    elseif e.s == "unpriced" then
        line, good = "Not priced: its profile (" .. tostring(e.profile) .. ") has Post for Sale off.", "plain"
    else
        line, good = "Checking the listing.", true
    end
    row_text(new_row(outer, col), outer, line, 1, good == "plain" and COLORS.dim or good and COLORS.good or COLORS.bad, 17)
    -- The price the mod posted at, so it can be matched with Your Ads.
    if e and tonumber(e.price) and (e.s == "posted" or e.s == "check") then
        row_text(new_row(outer, col), outer, "Price: " .. ui.money(e.price), 1, COLORS.text, 15)
    end
    if e and e.market then row_text(new_row(outer, col), outer, "Market Value: " .. ui.money(e.market), 1, COLORS.dim, 15) end
    if e and e.opts and e.opts ~= "" then row_text(new_row(outer, col), outer, "Options: " .. e.opts, 1, COLORS.dim, 15) end
    if e and e.profile then row_text(new_row(outer, col), outer, "Profile: " .. e.profile, 1, COLORS.dim, 15) end
    -- The game's bar at that price, in the ad screen's colours.
    if e and tonumber(e.bar) then
        local cv = tonumber(e.bar)
        row_text(new_row(outer, col), outer, "Competitiveness of the offer:", 1, COLORS.dim, 15)
        pcall(function()
            local bar = new_widget("ProgressBar", outer)
            pcall(function() bar:SetPercent(cv) end)
            pcall(function() bar:SetFillColorAndOpacity(cv >= 0.6 and COLORS.barBlue or cv >= 0.4 and COLORS.barGreen
                or cv >= 0.25 and COLORS.barYellow or COLORS.barRed) end)
            local sb = new_widget("SizeBox", outer)
            pcall(function() sb:SetWidthOverride(360) end)
            pcall(function() sb:SetHeightOverride(16) end)
            sb:SetContent(bar)
            -- Left-aligned (1; 0 is Fill), or the column stretches it past its width.
            local bs = col:AddChildToVerticalBox(sb)
            pad(bs, 0, 6, 0, 2)
            halign(bs, 1)
        end)
    end
    if e and e.s ~= "posted" then
        local brow = new_row(outer, col)
        if e.s == "refused" and e.why == "photo" then add_button(h, brow, "Send Back for Photos", 300, "sendback:" .. id, COLORS.btn, 16) end
        if (e.s == "refused" or e.s == "check") and e.profile then add_button(h, brow, "Try Again", 160, "salecheck:" .. id, COLORS.btn, 16) end
        add_button(h, brow, "Dismiss", 140, "saledismiss:" .. id, COLORS.btnWarn, 16)
    end
end

---------------------------------------------------------------------------
-- Car Pickup: the transporter's list and its minimum
-- Once the list (VehiclesToTransport) has as many cars as its minimum (the
-- Car Pickup screen's Pick up when, 1-7), the employee with the pickup task
-- starts the trip. Add
-- Bought Cars puts every car the screen would offer on that list, through
-- the manager's own AddVehicleToTransport; Send Now lowers the minimum to
-- the list's length and puts it back once the transporter has left.
---------------------------------------------------------------------------
ui.deliv = { auto = false, tried = {}, drivenSeen = {} }
ui.load_delivery = function()
    local f = io.open(mod_dir() .. "/delivery.lua", "r")
    if not f then return end
    local src = f:read("*a")
    f:close()
    local chunk = load("return " .. src, "delivery", "t", {})
    local ok, data = pcall(chunk or function() return nil end)
    if ok and type(data) == "table" and type(data.auto) == "boolean" then ui.deliv.auto = data.auto end
    -- A Send Now whose trip never started before the game was quit: the
    -- player's Pick up when goes back as soon as the transporter reads.
    if ok and type(data) == "table" and math.type(data.restoreMin) == "integer" and data.restoreMin >= 1 and data.restoreMin <= ui.TRANSPORT_MAX then
        ui.deliv.restoreMin, ui.deliv.restoreNow = data.restoreMin, true
    end
    log("delivery.lua read: Add Bought Cars " .. (ui.deliv.auto and "on" or "off") .. ", restore " .. tostring(ui.deliv.restoreMin))
end
ui.save_delivery = function()
    local f = io.open(mod_dir() .. "/delivery.lua", "w")
    if not f then log("could not write delivery.lua") return false end
    local okW = f:write(serialize({ auto = ui.deliv.auto, restoreMin = ui.deliv.restoreMin }))
    local okC = f:close()
    return (okW and okC) and true or false
end
-- The Car Pickup screen's own cap on the list: a constant in its code
-- (Is Vehicle Selection Limit Reached), not a value the game stores.
ui.TRANSPORT_MAX = 7
-- The manager, its state (0 = at home), its list and its minimum. Any of
-- them unreadable comes back nil, and nothing acts on a nil.
ui.transporter = function()
    local m = first_live("BP_TransporterVehicleManager_C")
    if not m then return nil end
    local t = { mgr = m, ids = {}, n = nil }
    local okS, s = pcall(function() return m.ManagerState end)
    t.state = okS and tonumber(s) or nil
    local okM, mn = pcall(function() return m:GetMinVehiclesToActivateTask() end)
    t.min = okM and tonumber(mn) or nil
    local okL = pcall(function()
        local n = 0
        m.VehiclesToTransport:ForEach(function(_, v)
            local okV, car = pcall(function() return v:get() end)
            n = n + 1
            local id = okV and valid(car) and car_id_of(car)
            if id then t.ids[id] = true end
        end)
        t.n = n
    end)
    if not okL then t.n = nil end
    -- The trip's time left and its length in seconds, from the manager's own
    -- getters; the game's Car Pickup screen shows the countdown only while
    -- 0 < left < total, so the mod does the same.
    local okT, total = pcall(function() return m:GetDeliveryDuration() end)
    local okLeft, left = pcall(function() return m:GetLeftDeliveryDuration() end)
    total, left = okT and tonumber(total) or nil, okLeft and tonumber(left) or nil
    if total and left and left > 0 and left < total then t.left = left end
    -- Logged when a countdown starts and when it ends, with the state at the
    -- end, so the log shows what the time counts down to.
    if t.left and not ui.deliv.timing then
        ui.deliv.timing = true
        log(string.format("delivery: trip timer started, %.0f of %.0f s left, state %s", t.left, total, tostring(t.state)))
    elseif not t.left and ui.deliv.timing then
        ui.deliv.timing = nil
        log(string.format("delivery: trip timer ended (left %s, total %s), state %s", tostring(left), tostring(total), tostring(t.state)))
    end
    return t
end
-- Seconds as the game's Car Pickup screen writes them ({x}m{y}s): 3m45s.
ui.mins = function(sec)
    sec = math.max(0, math.floor(sec))
    return string.format("%dm%ds", sec // 60, sec % 60)
end
-- The office volume, as the Car Pickup screen finds it: the enter volume
-- whose VolumeID is OfficeVolume. Its box is kept for the session.
ui.office_box = function()
    local b = ui.officeBox
    if b and valid(b.comp) then return b end
    ui.officeBox = nil
    for _, vol in ipairs(find_all("BP_EnterVolume_C")) do
        local okI, vid = pcall(function() return vol.VolumeID end)
        if live(vol) and okI and text_of(vid) == "OfficeVolume" then
            local ok = pcall(function()
                local c = vol.Box
                local l, e, r = c:K2_GetComponentLocation(), c:GetScaledBoxExtent(), c:K2_GetComponentRotation()
                ui.officeBox = { comp = c, X = l.X, Y = l.Y, Z = l.Z, eX = e.X, eY = e.Y, eZ = e.Z, yaw = math.rad(r.Yaw) }
            end)
            if ok then return ui.officeBox end
        end
    end
    return nil
end
-- True when the point is inside the box (rotated by its yaw), nil if unread.
ui.in_box = function(b, l)
    if not (b and l) then return nil end
    local dx, dy = l.X - b.X, l.Y - b.Y
    local c, s = math.cos(-b.yaw), math.sin(-b.yaw)
    local lx, ly = dx * c - dy * s, dx * s + dy * c
    return math.abs(lx) <= b.eX and math.abs(ly) <= b.eY and math.abs(l.Z - b.Z) <= b.eZ
end
-- Cars the Car Pickup screen would offer (its HasAccessToVehicle): owned,
-- not on a tow dolly, hauled or winched, more than 70 m from the office
-- spawn and outside the office volume, not lock-picked, not a wreck for
-- sale or an abandoned wreck, not listed for sale, and storable in the
-- underground garage. These are copies of the screen's rules (its own
-- functions return through out parameters, which the mod avoids), so a
-- game update to them needs a re-read. Any field that doesn't read leaves
-- the car out.
ui.pickup_cars = function()
    local box = ui.office_box()
    -- The screen's distance is to GameMode.GetGarageLocation, which is the
    -- first player spawn whose ID is Couch (in the office; the game's string
    -- compare ignores case), measured in 3D and rounded to whole metres; that
    -- spawn is read here directly. The screen also clamps to 0-99999 m,
    -- which no car on the map reaches, so there's no clamp here.
    local gl, gm = nil, first_live("BP_GameMode_C")
    pcall(function()
        gm.PlayerSpawns:ForEach(function(_, v)
            local okS, sp = pcall(function() return v:get() end)
            if gl == nil and okS and valid(sp) and text_of(sp.ID):lower() == "couch" then
                local l = sp:K2_GetActorLocation()
                gl = { X = l.X, Y = l.Y, Z = l.Z }
            end
        end)
    end)
    if not (box and gl) then return nil, box and "office spawn not found" or "office area not found" end
    local storable = struct_field("S_VehiclePresets", "CanBeStoredInUndergroundGarage")
    if not storable then return nil, "garage flag not found" end
    -- Cars the mod or the platform has in hand stay out, wherever they are:
    -- on an automation spot, with a task, a profile waiting or a sales record.
    -- Tasks live in the robot manager, so with none in the world (no platform
    -- yet) there are none to keep out.
    -- Once a manager has been seen in this game (the same game mode object),
    -- a later miss is a failed lookup, not a platform that went away; a save
    -- loaded since has a new game mode and starts unseen.
    local robot, held = robot_now(), {}
    local world = gm and path_of(gm) or "?"
    if robot then ui.deliv.robotSeen = world
    elseif ui.deliv.robotSeen == world then return nil, "robot manager not found" end
    if robot then
        local entries = task_entries(robot)
        if not entries then return nil, "tasks unreadable" end
        for _, e in ipairs(entries) do held[e[1]] = true end
    end
    for _, c in ipairs(bay_cars()) do held[c.id] = true end
    -- Cars on any of the shop's own parking (ZoneType 7 warehouse, 8 Side,
    -- 9 Front, 10 Tuning Garage, 11 Underground Garage) stay out too, whatever
    -- the office volume covers. The base class also returns slots that aren't
    -- the shop's parking (the set changes as the level streams in; a car
    -- crusher slot is one example). A spot whose zone doesn't read counts as
    -- the shop's, so a car on one of those is kept out too: a missed offer,
    -- never a wrong one.
    -- Spots are looked up through their base class and through each spot
    -- class by name as well: measured in play, the base lookup
    -- returned 23 fewer automation spots than the named lookup on every
    -- reading, while both counts grew as the level streamed in. The office spots aren't
    -- reached by either lookup (they are found through the game mode's
    -- customer spots instead); cars on them are kept out by the office volume
    -- and the 70 m rule, so their name stays in the list only as a fallback.
    -- A spot counted twice is harmless. The counts per lookup, and the classes
    -- the base lookup returns, are logged when the total changes. None found
    -- at all means the lookups failed, and nothing is offered.
    do
        local lookups = { "BP_ParkingSlot_Base_C", "BP_ParkingSlot_C", "BP_OfficeParkingSlot_C", "BP_ParkingSlot_Automation_C",
            "BP_ParkingSlot_Indoor_C", "BP_VehicleService_ParkingSlot_C" }
        local found, n = {}, 0
        for i, cls in ipairs(lookups) do
            found[i] = find_all(cls)
            n = n + #found[i]
            for _, slot in ipairs(found[i]) do
                if live(slot) then
                    local okV, v = pcall(function() return slot.ParkingSlotVehicle end)
                    if okV and valid(v) then
                        local okZ, zt = pcall(function() return slot.ZoneType end)
                        zt = okZ and tonumber(zt) or nil
                        local id = car_id_of(v)
                        if id and (zt == nil or (zt >= 7 and zt <= 11)) then held[id] = true end
                    end
                end
            end
        end
        if ui.deliv.nSlots ~= n then
            ui.deliv.nSlots = n
            local per, kinds, w = {}, {}, {}
            for i, cls in ipairs(lookups) do per[#per + 1] = cls .. " " .. #found[i] end
            for _, slot in ipairs(found[1]) do local k = prop_type(slot) kinds[k] = (kinds[k] or 0) + 1 end
            for k, c in pairs(kinds) do w[#w + 1] = k .. " " .. c end
            table.sort(w)
            log("delivery: parking spots by lookup (" .. table.concat(per, ", ") .. "); base classes (" .. table.concat(w, ", ") .. ")")
        end
        if n == 0 then return nil, "no parking spots found" end
    end
    -- A car within 30 m of the player is left for now: one they've just got
    -- into without starting it isn't marked as driven yet. It's offered
    -- again once they walk away; a missed offer, never a wrong one.
    local me = nil
    pcall(function()
        local pawn = FindFirstOf("PlayerController").Pawn
        if valid(pawn) then
            local l = pawn:K2_GetActorLocation()
            me = { X = l.X, Y = l.Y, Z = l.Z }
        end
    end)
    local out, all = {}, find_all("BP_VehicleBase_C")
    -- The count of cars found by their base class goes in the log when it
    -- changes, so an empty page can be told from a lookup that finds nothing.
    if ui.deliv.nCars ~= #all then
        ui.deliv.nCars = #all
        log("delivery: " .. #all .. " cars found by base class")
    end
    for _, v in ipairs(all) do
        if live(v) then
            local ok, keep = pcall(function()
                if v.IsHauled or v.IsWinched or v.IsOnTowdolly or v.IsTowingTowDolly or v.InRepairZone then return false end
                local info = v.VehicleInfoObject
                if not valid(info) then return false end
                if info.PlayerOwned ~= true then return false end
                -- Only cars the player has never driven: the game marks a car
                -- (WasDrivenByPlayer, saved with the game) the first time the
                -- player starts it, and never clears the mark. A bought car
                -- that's waiting to be collected hasn't been driven; a car
                -- the player uses, or has used, has. A mark that doesn't read
                -- keeps the car off: a missed offer, never a wrong one.
                if info.WasDrivenByPlayer ~= false then
                    -- A car whose id doesn't read is keyed by its object path, so a
                    -- build that breaks the id read logs every car, not one.
                    local id, mark = car_id_of(v) or ("no id, " .. path_of(v)), info.WasDrivenByPlayer
                    if not ui.deliv.drivenSeen[id] then
                        ui.deliv.drivenSeen[id] = true
                        log("delivery: " .. id .. " left off, " .. (mark == true and "the player has driven it" or ("its driven mark reads " .. tostring(mark))))
                    end
                    return false
                end
                if info.CarPickLock or info.IsWreckForSell or info.IsAbandonedWreck then return false end
                if valid(info.VehicleOffer) then return false end
                if info.ModelPresetInfo[storable] ~= true then return false end
                local l = v:K2_GetActorLocation()
                local p = { X = l.X, Y = l.Y, Z = l.Z }
                local d = math.sqrt((p.X - gl.X) ^ 2 + (p.Y - gl.Y) ^ 2 + (p.Z - gl.Z) ^ 2) / 100
                if math.floor(d + 0.5) <= 70 then return false end
                if me and math.sqrt((p.X - me.X) ^ 2 + (p.Y - me.Y) ^ 2 + (p.Z - me.Z) ^ 2) / 100 <= 30 then return false end
                return ui.in_box(box, p) == false
            end)
            local id = ok and keep and car_id_of(v)
            if id and (held[id] or assignments[id] or sales[id]) then id = nil end
            if id then out[#out + 1] = { id = id, vehicle = v } end
            if not ok and not ui.deliv.readErr then
                ui.deliv.readErr = true
                log("delivery: a car's fields didn't read, so it was left out: " .. tostring(keep))
            end
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    if ui.deliv.nPickup ~= #out then
        ui.deliv.nPickup = #out
        log("delivery: " .. #out .. " cars waiting for pickup")
    end
    return out
end
-- One pass of Add Bought Cars: only with the transporter at home and room
-- on its list. Each add is read back from the list; a car that doesn't
-- show up isn't tried again this session.
ui.delivery_tick = function()
    if not ui.deliv.auto then return end
    local t = ui.transporter()
    if not (t and t.state == 0 and t.n) then return end
    -- Send Now's minimum goes back once the transporter has left (above).
    if t.n >= ui.TRANSPORT_MAX then return end
    local cars, why = ui.pickup_cars()
    if not cars then
        if ui.deliv.lastWhy ~= why then log("delivery: not adding cars, " .. tostring(why)) end
        ui.deliv.lastWhy = why
        return
    end
    ui.deliv.lastWhy = nil
    local n = t.n
    for _, c in ipairs(cars) do
        if n >= ui.TRANSPORT_MAX then break end
        -- A car whose add didn't show up is tried again a minute later.
        local at, now = ui.deliv.tried[c.id], os.clock()
        if not t.ids[c.id] and now > 0 and not (at and now - at < 60) then
            local reserved = nil
            pcall(function() reserved = c.vehicle.IsReservedByNPCTransporter end)
            if reserved == false then
                ui.deliv.tried[c.id] = now
                local okA, errA = pcall(function() t.mgr:AddVehicleToTransport(c.vehicle) end)
                local back = ui.transporter()
                if back and back.ids[c.id] then
                    n = n + 1
                    log("delivery: " .. car_label_by_id(c.id, c.vehicle) .. " (" .. c.id .. ") added to the transporter's list, " .. n .. " of " .. tostring(back.min))
                else
                    log("delivery: " .. c.id .. " not on the list after the add (" .. (okA and "call ok" or tostring(errA)) .. ")")
                end
            end
        end
    end
end
-- Send Now's restore, every pass: once the transporter has left home, the
-- minimum the player had goes back, read back.
ui.delivery_restore = function()
    if ui.deliv.unsaved and ui.save_delivery() then
        ui.deliv.unsaved = nil
        log("delivery: delivery.lua written")
    end
    local want = ui.deliv.restoreMin
    if not want then return end
    local t = ui.transporter()
    if not (t and t.state) then return end
    -- Restored on the pass after the one that first sees the transporter away,
    -- so the departure has begun; a whole trip between two passes still counts.
    if not ui.deliv.restoreNow then
        if t.state ~= 0 and not ui.deliv.sawAway then ui.deliv.sawAway = true return end
        if not ui.deliv.sawAway then return end
    end
    pcall(function() t.mgr:SetMinVehiclesToActivateTask(want) end)
    local back = ui.transporter()
    if back and back.min == want then
        log("delivery: minimum back to " .. want .. (ui.deliv.restoreNow and " (saved from an earlier session)" or " after Send Now"))
        if not ui.deliv.restoreNow then set_status("Pick up when is back to " .. want .. ".") end
        ui.deliv.restoreMin, ui.deliv.restoreNow, ui.deliv.sawAway = nil, nil, nil
        -- A file that still holds the old restore would undo a later change
        -- on the next load, so the save is retried until it lands.
        ui.deliv.unsaved = not ui.save_delivery()
        if ui.deliv.unsaved then log("delivery: delivery.lua not written after the restore, retrying") end
    elseif not ui.deliv.restoreLogged then
        log("delivery: minimum not restored to " .. want .. " (reads " .. tostring(back and back.min) .. "), retrying")
        ui.deliv.restoreLogged = true
    end
end
ui.set_min = function(t, n)
    pcall(function() t.mgr:SetMinVehiclesToActivateTask(n) end)
    local back = ui.transporter()
    return back and back.min == n
end
-- ETransporterManagerState: 0 Idle, 1 LeavingHome, 2 OutsideHome.
ui.TRANSPORT_STATE = { [0] = "idle", [1] = "leaving", [2] = "out on a trip" }
-- What the Car Pickup page shows, as one string: the timed refresh
-- rebuilds the page only when this changes, so it doesn't jump every pass.
-- The page draws from one snapshot, and the snapshot's sig is kept on the
-- host, so a pass that would draw the same thing skips the rebuild.
ui.delivery_snapshot = function()
    local t = ui.transporter()
    if not t then return { sig = "none" } end
    -- Only whether a countdown shows is in the signature; the time itself is
    -- written into the line in place, so the page doesn't rebuild (and jump)
    -- every time it ticks.
    local parts = { tostring(t.state), tostring(t.n), tostring(t.min), tostring(ui.deliv.auto), tostring(ui.deliv.restoreMin), ui.status, tostring(ui.statusGood),
        t.left and "timing" or "-" }
    local cars, why = ui.pickup_cars()
    if not cars then parts[#parts + 1] = "?" .. tostring(why) end
    for _, c in ipairs(cars or {}) do parts[#parts + 1] = c.id .. (t.ids[c.id] and "+" or "") end
    return { t = t, cars = cars, sig = table.concat(parts, "|") }
end
ui.fill_delivery = function(h, list, outer)
    local snap = ui.deliv.snap or ui.delivery_snapshot()
    ui.deliv.snap = nil
    h.delivSig = snap.sig
    local t = snap.t
    if not t then row_text(new_row(outer, list), outer, "No transporter found.", 1, COLORS.dim) return end
    local st = ui.TRANSPORT_STATE[t.state] or (t.state and ("in state " .. t.state) or "can't be read")
    h.delivStateBase = "Transporter: " .. st
    h.delivState = remember(row_text(new_row(outer, list), outer, h.delivStateBase .. (t.left and (", back in " .. ui.mins(t.left)) or ""), 1, COLORS.text, 20))
    local row = new_row(outer, list)
    row_text(row, outer, "On the List: " .. tostring(t.n or "?") .. " of " .. ui.TRANSPORT_MAX
        .. " \194\183 Pick up when: " .. tostring(t.min or "?"), 1, COLORS.dim, 17)
    if t.min then
        add_button(h, row, "-", 60, "dmin:" .. (t.min - 1), t.min > 1 and COLORS.btn or COLORS.btnOff, 18)
        add_button(h, row, "+", 60, "dmin:" .. (t.min + 1), t.min < ui.TRANSPORT_MAX and COLORS.btn or COLORS.btnOff, 18)
    end
    if ui.deliv.restoreMin then
        row_text(new_row(outer, list), outer, "Pick up when goes back to " .. ui.deliv.restoreMin .. " once the transporter leaves.", 1, COLORS.dim, 15)
    end
    row = new_row(outer, list)
    add_button(h, row, "Add Bought Cars: " .. (ui.deliv.auto and "On" or "Off"), 300, "dauto", ui.deliv.auto and COLORS.btnOn or COLORS.btnOff, 16)
    local canSend = t.state == 0 and t.n and t.min and t.n >= 1 and t.n < t.min
    add_button(h, row, "Send Now", 180, "dsend", canSend and COLORS.btn or COLORS.btnOff, 16)
    local cars = snap.cars
    row_text(new_row(outer, list), outer, "Waiting for Pickup:", 1, COLORS.section, 17)
    if not cars then
        row_text(new_row(outer, list), outer, "Can't tell which cars are waiting for pickup." .. (ui.deliv.auto and " Add Bought Cars adds none until it can." or ""), 1, COLORS.dim, 15)
        return
    end
    if #cars == 0 then row_text(new_row(outer, list), outer, "None.", 1, COLORS.dim, 15) end
    for _, c in ipairs(cars) do
        row_text(new_row(outer, list), outer, car_label_by_id(c.id, c.vehicle) .. (t.ids[c.id] and " (On the List)" or ""), 1,
            t.ids[c.id] and COLORS.good or COLORS.text, 16)
    end
end

local function fill_profiles(h, list, outer)
    local p = draft()
    local row = new_row(outer, list)
    row_text(row, outer, "Profiles:", nil, COLORS.dim)
    for _, n in ipairs(profile_names()) do
        add_button(h, row, n, 160, "select:" .. n, n == ui.selected and COLORS.btnOn or COLORS.btnOff, 16)
    end
    add_button(h, row, "+ New", 110, "newprofile", COLORS.btnDark, 16)

    row = new_row(outer, list)
    row_text(row, outer, "Name:", nil, COLORS.dim)
    if ui.selected == "Default" then
        row_text(row, outer, "Default (always there, can't be renamed or deleted)", 1, COLORS.text, 16)
    else
        local box = new_widget("EditableTextBox", outer)
        pcall(function() box:SetText(FText(ui.selected)) end)
        pcall(function() box:SetHintText(FText("Type a name")) end)
        local sb = new_widget("SizeBox", outer)
        pcall(function() sb:SetWidthOverride(360) end)
        pcall(function() sb:SetHeightOverride(44) end)
        sb:SetContent(box)
        local sl = row:AddChildToHorizontalBox(sb)
        pad(sl, 0, 0, 12, 0)
        valign(sl, 2)
        ui.nameBox = remember(box)
        add_button(h, row, "Rename", 150, "rename", COLORS.btn, 16)
    end

    row = new_row(outer, list)
    row_text(row, outer, "Stations:", nil, COLORS.dim)
    -- Seven stations at 210 px don't fit the panel in one row (the last one
    -- was cut off), so they go on rows of four under their label, as the
    -- paint colours do under theirs.
    do
        local n = 0
        for _, st in ipairs(STEP_NAMES) do
            if st ~= "ParkingSlot" then
                if n % 4 == 0 then row = new_row(outer, list) end
                n = n + 1
                add_button(h, row, STEP_LABELS[st], 210, "step:" .. st, p.steps[st] and COLORS.btnOn or COLORS.btnOff, 15)
            end
        end
    end

    if p.steps.PaintBooth then
        row = new_row(outer, list)
        row_text(row, outer, "Paint Color: " .. (PAINT_COLORS[((p.paint or {}).color or 0) + 1] or "?"), 1, COLORS.dim)
        local perRow, i = 6, 0
        for idx, name in ipairs(PAINT_COLORS) do
            if i % perRow == 0 then row = new_row(outer, list) end
            i = i + 1
            add_button(h, row, name, 170, "color:" .. (idx - 1), ((p.paint or {}).color or 0) == idx - 1 and COLORS.btnOn or COLORS.btnOff, 15)
        end
    end

    row = new_row(outer, list)
    row_text(row, outer, "Finish At:", nil, COLORS.dim)
    add_button(h, row, DEST_NAMES[p.destination or 0] or "?", 240, "dest", COLORS.btn, 16)
    row_text(row, outer, "Mechanic:", nil, COLORS.dim)
    -- Dark and inert while the Mechanical Workshop station is off.
    local on = mech_on(p)
    add_button(h, row, MODE_NAMES[p.mechanic.mode] or "?", 220, on and "mode" or "noop", on and COLORS.btn or COLORS.btnOff, 16)
    if p.mechanic.mode == "replace" then
        add_button(h, row, "Parts: " .. (p.mechanic.partType or "Stock"), 180, on and "tier" or "noop", on and COLORS.btn or COLORS.btnOff, 16)
    end

    if on and p.mechanic.mode == "custom" then
        local missingSlots = custom_missing(p, SLOT_NAMES)
        row = new_row(outer, list)
        row_text(row, outer, #missingSlots == 0 and "Every slot is set." or (#missingSlots .. (#missingSlots == 1 and " slot" or " slots") .. " still to set (every slot is needed for a complete car)"),
            1, #missingSlots == 0 and COLORS.good or COLORS.bad)
        local perRow, i = 4, 0
        for _, slot in ipairs(SLOT_NAMES) do
            if i % perRow == 0 then row = new_row(outer, list) end
            i = i + 1
            local tier = p.mechanic.slots[slot]
            add_button(h, row, (SLOT_LABELS[slot] or slot) .. ": " .. (tier or "-"), 360, "slot:" .. slot, tier and COLORS.btn or COLORS.btnWarn, 15)
        end
    end

    -- Post for Sale: dark and inert unless the car finishes at Front Parking.
    ui.saleSlider, ui.saleBar = nil, nil
    local front = (p.destination or 0) == 0
    local sl = p.sale or {}
    row = new_row(outer, list)
    row_text(row, outer, "Post for Sale:", nil, COLORS.dim)
    add_button(h, row, (front and sl.on) and "On" or "Off", 110, front and "sale" or "noop", (front and sl.on) and COLORS.btnOn or COLORS.btnOff, 16)
    if not front then
        row_text(row, outer, "Only for cars that finish at Front Parking.", 1, COLORS.dim, 15)
    elseif sl.on then
        -- The game's bar, drawn the way the ad screen draws it, under a slider
        -- the main loop reads while the page is open; -5/+5 work without it.
        local cv = (sl.compete or 60) / 100
        row_text(row, outer, "Competitiveness:", nil, COLORS.dim)
        pcall(function()
            local sd = new_widget("Slider", outer)
            pcall(function() sd:SetMinValue(0.01) end)
            pcall(function() sd:SetMaxValue(1.0) end)
            pcall(function() sd:SetStepSize(0.01) end)
            pcall(function() sd:SetValue(cv) end)
            pcall(function() sd:SetSliderBarColor(COLORS.dim) end)
            pcall(function() sd:SetSliderHandleColor(COLORS.white) end)
            local sb = new_widget("SizeBox", outer)
            pcall(function() sb:SetWidthOverride(420) end)
            pcall(function() sb:SetHeightOverride(44) end)
            sb:SetContent(sd)
            local sl2 = row:AddChildToHorizontalBox(sb)
            pad(sl2, 0, 0, 12, 0)
            valign(sl2, 2)
            ui.saleSlider = remember(sd)
        end)
        add_button(h, row, "-5", 70, "salecomp:-5", COLORS.btn, 15)
        add_button(h, row, "+5", 70, "salecomp:5", COLORS.btn, 15)
        -- No number: the game shows players the bar, never a figure for it.
        row = new_row(outer, list)
        pcall(function()
            local bar = new_widget("ProgressBar", outer)
            pcall(function() bar:SetPercent(cv) end)
            pcall(function() bar:SetFillColorAndOpacity(cv >= 0.6 and COLORS.barBlue or cv >= 0.4 and COLORS.barGreen
                or cv >= 0.25 and COLORS.barYellow or COLORS.barRed) end)
            local sb = new_widget("SizeBox", outer)
            pcall(function() sb:SetWidthOverride(700) end)
            pcall(function() sb:SetHeightOverride(28) end)
            sb:SetContent(bar)
            local sl3 = row:AddChildToHorizontalBox(sb)
            pad(sl3, 0, 0, 12, 0)
            valign(sl3, 2)
            ui.saleBar = remember(bar)
        end)
        row_text(row, outer, "The highest price that keeps the game's bar at this level.", 1, COLORS.dim, 15)
        row = new_row(outer, list)
        for _, f in ipairs(SALE_FLAGS) do
            add_button(h, row, f[2], 330, "saleflag:" .. f[1], sl[f[1]] and COLORS.btnOn or COLORS.btnOff, 15)
        end
    end

    row = new_row(outer, list)
    local unsaved = serialize(p) ~= serialize(profiles[ui.selected] or {})
    -- One width for both labels, and both must fit inside 380: the slider
    -- changes this button's text in place, and if the button (or its text)
    -- grew there, the row wouldn't make room and it would be drawn over
    -- Delete Profile (seen in play).
    ui.saveBtn = remember(add_button(h, row, unsaved and "Save Profile (unsaved changes)" or "Save Profile", 380, "save", unsaved and COLORS.btnWarn or COLORS.btnOn, 18))
    if ui.selected ~= "Default" then
        if ui.confirmDelete == ui.selected then
            add_button(h, row, "Click to Confirm Delete", 300, "delete", COLORS.btnWarn, 18)
        else
            add_button(h, row, "Delete Profile", 200, "askdelete", COLORS.btnWarn, 18)
        end
    end
end

-- Help: a one-line hint on top of each page, and a full Help page.
local HINTS = {
    board = "Your shop from above. Click any car for its options, or use Select Cars to give several the same profile. The legend shows what each color means.",
    cars = "Cars in the parking near the warehouse. Give one a profile and it gets its task by itself.",
    profiles = "A profile is a plan for a car: which stations, which parts, where it ends up. Set it up once, use it on any car.",
    front = "Your Front Parking spots. Click a car for its details; the mod only acts on cars it brought here.",
    delivery = "Your transporter's Car Pickup list. The employee with the pickup task starts the trip once the list has as many cars as Pick up when is set to. Add Bought Cars adds cars you own that are away from your shop and that the game hasn't marked as driven by you.",
}
local HELP = {
    { "What This App Does",
      "It runs your Automation Platform for you. Make a profile once, give it to cars in the parking near the warehouse, and each car gets the game's own automation task with no clicking through the scanner. The platform and your employees do the work exactly as they do without the mod." },
    { "Board",
      "Every car with an automation task, in the order the platform takes them, with the stations each car still has to visit. In List, the car the platform is on now is green, with \">\" before its name. \"Finishing\" means only the drive to its final spot is left." },
    { "Map",
      "Your shop from above, with every car where it is now. Gray: queued on a parking spot. Green: being worked on. Cyan outline: the car the platform is on. Red: waiting too long with no progress (possibly stalled), or in the platform's way. When the platform's path is blocked, the platform line names what's in its way (a car, or you). Amber: on a parking spot with no profile. Each station says whether it's Working, Idle or Reserved. Reserved means the game is holding that station, though no car is in it. Idle with a car in it means the car is waiting there: its work is done, or hasn't started yet. Click a car to see where it's going and what you can do. To give several cars the same profile, click Select Cars, then click cars on a parking spot that don't have a task yet to tick them (green outline), then click Set Profile to give them all the same one. Click Done Selecting when you're finished, and a click opens a car's panel again. You can also tick a car without Select Cars: Shift-click it, or use Select in its panel. List shows the same cars as rows." },
    { "Unstick",
      "For a car the platform has got stuck on (click it, then Click to Confirm). The car keeps its task and is moved to a free parking spot, if there is one, so the platform picks it up again. If the platform is on this car, it's freed first and every other car keeps its task; if it's on another car, it isn't interrupted. A car in a Car Wash or Body Workshop that's still working on it isn't stuck, so nothing is changed. If the platform is on this car but is moving or its path is blocked, it isn't stuck and nothing is changed; if a car in automation is in its way, Reset Car on that car moves it, but takes it out of automation. While a station is still working on another car, freeing the platform waits, so try again once it's done. If that doesn't help, use Reset Car." },
    { "Lower Lift",
      "If a mechanic's lift is left up with no car in the bay, the bay can't be used, and the Board shows it under the platform line. When the lift doesn't still count a car as on it, a Lower Lift button shows there; nothing can be under the lift when you press it, you included. When it does, the mod can't lower it safely yet." },
    { "Free Station",
      "A Car Wash, Body Workshop or Mechanical Workshop can be left held by the game after its car has gone, so it reads Reserved with no car in it. After 30 s like that, the Board names it under the platform line with a Free Station button. Free Station ends the station's work the way the game does when a job finishes, so the platform can use it again." },
    { "Reset Car",
      "For a car that's stuck and holding up the platform. Click Reset Car, then Click to Confirm. The car's task is removed, any parts set aside for it go back to storage, and the car is moved to a free spot in the parking near the warehouse; if a Car Wash or Body Workshop is still working on it, it's moved once that's done. If every spot there is taken, nothing is changed, unless the platform is on this car: then the reset still goes ahead and the car stays where it stopped. It won't go through automation again until you give it a profile. Every other car keeps its task and its parts. If the platform is on this car, it's reset too, but nothing is changed while it's moving, while its path is blocked, or while a station is working on this car or another one. The game's own red reset button clears every car and loses their parts; this one only touches the stuck car." },
    { "Cars",
      "Cars in the parking near the warehouse. Click Profile and pick one; the car gets its task within a couple of seconds. Cars that already have a task show \"in automation\" and the profile they were given. If a Custom profile's parts aren't all in storage, the car gets no task and the missing parts are listed at once; it carries on by itself once they're in storage (checked every 30 seconds), or click Try Again. Any other problem is shown after a few tries, with the same button." },
    { "Front Parking",
      "Your Front Parking spots and the car on each. Cars the mod brought there are green when listed, yellow when their profile has Post for Sale off, red when the mod didn't post them, and teal while it checks. Purple (Check the Ad) means the mod couldn't confirm the car's ad. Look for it in Your Ads; Try Again looks again and never posts a second time, and Dismiss makes it yours. Your own cars are grey, or outlined in green once you've listed them; the mod never changes them. Click a car for its details. A red car says why it wasn't posted: Send Back for Photos takes a car with no photo to a free spot in the parking near the warehouse, through the Photo Studio and back, and the mod tries again; Try Again checks once more where it stands; Dismiss makes it yours to price." },
    { "Profiles",
      "Pick a profile at the top, or + New to make one. Type a new name and click Rename to rename it. Default is always there and can't be renamed or deleted. Changes only count once you click Save Profile; the button turns red while there are unsaved changes. Delete Profile (click it, then Click to Confirm Delete) also takes the profile off any car waiting for it." },
    { "Stations",
      "Turn on the stations a car should visit. A station the car doesn't need is skipped for that car, the same way the game's own screen grays it out: a tank within a gallon of full skips the Fuel Dispenser, tires already at the right pressure skip the Air Compressor, a body or shine already at 98% or more skips the Body Workshop or the Car Wash, and a tuned car skips paint, body and wash." },
    { "Paint Booth",
      "With the Paint Booth on, pick the color to paint the car. The SUPER colors aren't listed: the game unlocks them car by car." },
    { "Finish At",
      "Where the platform leaves the car when it's done: Front Parking, Side Parking, Underground Garage or Tuning Garage." },
    { "Post for Sale",
      "Only for profiles that finish at Front Parking. Turn it on and set Competitiveness: the same bar as Competitiveness of the offer on the game's ad screen. For each car the mod picks the highest price that keeps the bar at that level, counting its photos, wash and other bonuses the way the game does. A fuller bar sells sooner but means a lower price, and a full bar can mean well under the market value. With Non-negotiable on, the game's bar only compares the price with the market value, and so does the mod. Non-negotiable, Available for installments, Available for online sale and Offer Warranty are the same choices as on the game's ad screen; one the game hasn't unlocked yet, or doesn't offer for that car, is left off. The game needs a photo to post a car, so the Photo Studio stays on while this is on. When the platform leaves a car with this profile at Front Parking, the car is posted once, if the game's ad screen would accept it (for example, it has a photo and is parked properly on the spot); from then on it's the game's ad like any other. The mod never takes an ad down. A car you park there yourself is yours to price." },
    { "Mechanic",
      "Only when the Mechanical Workshop is on; otherwise these buttons are dark and do nothing. Replace Damaged has the mechanic replace each worn part, and the fuses and fluids, with the part type you pick under Parts (Default, Stock, Sport or Race), taken from your storage the way the game's own Automation tab picks them. A part with no replacement of that type in storage is left as it is. Custom lets you pick Stock, Sport or Race for every part, and every part has to be set before the profile saves. It replaces every worn or missing part, plus the fuses and fluids, and the car gets its task only once every part it needs is in storage, so it comes out complete. Disassemble takes every part and fuse off the car and drains its fluids. If there's nothing for the mechanic to do, the car skips the mechanic and gets the rest of its profile." },
    { "Sport and Race Parts",
      "These need the Up 2 You DLC. Without it, Replace Damaged offers Default and Stock, and Custom offers Stock." },
    { "Car Pickup",
      "The transporter is the game's Car Pickup: an employee you've given the pickup task at reception drives it to collect cars you own that are away from your shop. The trip starts once its list has as many cars as Pick up when is set to (1 to 7, the same setting as on the Car Pickup screen), which - and + change here. Add Bought Cars (off until you turn it on) puts cars on that list for you, up to 7, the same way Add to list does. It takes only cars you own that are away from your shop and that you've never driven, and leaves out any the platform or the mod is working on. To bring back a car you've driven, add it on the game's Car Pickup screen. Send Now sets Pick up when to the number of cars already on the list, so the trip starts with those, then sets it back to your number once the transporter has left (or when you next load, if you quit first). The trip, the driver and the time it takes are the game's own; the mod only adds cars to the list and changes Pick up when." },
    { "Problems",
      "Report a Bug saves a report file in the mod's folder and opens GitHub; drag the file into the issue and click Submit new issue. Request a Feature opens the feature form. Your profiles are saved in profiles.lua in the mod's folder." },
}
-- Laid out like Parts Manager's help: headings in capitals in the section
-- colour, 18 pt text, and a section without a heading continues the one above.
local function fill_help(h, list, outer)
    for i, sec in ipairs(HELP) do
        if sec[1] then
            pad(list:AddChildToVerticalBox(make_text(outer, sec[1]:upper(), 18, COLORS.section)), 0, i > 1 and 14 or 0, 0, 2)
        end
        local body = make_text(outer, sec[2], 18, COLORS.text)
        pcall(function() body:SetAutoWrapText(true) end)
        pad(list:AddChildToVerticalBox(body), 0, (sec[1] or i == 1) and 0 or 14, 24, 0)
    end
end
local function page_hint(list, outer)
    local hint = HINTS[ui.page]
    if not hint then return end
    local t = make_text(outer, hint, 15, COLORS.dim)
    pcall(function() t:SetAutoWrapText(true) end)
    pad(list:AddChildToVerticalBox(t), 0, 0, 0, 8)
end

local function refresh_panel(h)
    local list, outer = resolve(h.listPath), resolve(h.treePath)
    if not (list and outer) then return end
    for name, b in pairs(buttons) do
        if b.host == h.hostPath and b.page then buttons[name] = nil end
    end
    pcall(function() list:ClearChildren() end)
    local before = {}
    for k in pairs(buttons) do before[k] = true end
    page_hint(list, outer)
    if ui.page == "board" then
        local row = new_row(outer, list)
        add_button(h, row, "Map", 110, "view:map", ui.boardView ~= "list" and COLORS.btnOn or COLORS.btnOff, 15)
        add_button(h, row, "List", 110, "view:list", ui.boardView == "list" and COLORS.btnOn or COLORS.btnOff, 15)
        fill_board(h, list, outer)
    elseif ui.page == "cars" then fill_cars(h, list, outer)
    elseif ui.page == "help" then fill_help(h, list, outer)
    elseif ui.page == "front" then ui.fill_front(h, list, outer)
    elseif ui.page == "delivery" then ui.fill_delivery(h, list, outer)
    else fill_profiles(h, list, outer) end
    for k, b in pairs(buttons) do if not before[k] then b.page = true end end
    set_text(resolve(h.statusPath), ui.status, ui.statusGood and COLORS.good or COLORS.bad)
end

-- The Luka's Mods logo: Assets\logo.png in this mod's folder (square, 256 x
-- 256, the same file Parts Manager and Installed Mods use), loaded at runtime
-- with the engine's ImportFileAsTexture2D. The header works without it.
ui.make_logo = function(ctx, outer, size)
    local lib = resolve("/Script/Engine.Default__KismetRenderingLibrary")
    local tex = nil
    local ok = valid(lib) and pcall(function() tex = lib:ImportFileAsTexture2D(ctx, mod_dir() .. "\\Assets\\logo.png") end)
    if not ok or not valid(tex) then
        if not ui.logoLogged then log("logo not loaded: Assets\\logo.png") ui.logoLogged = true end
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

local function build_panel(h, host)
    local tree = host.WidgetTree
    local switcher = host.ApplicationWidgetSwitcher
    if not valid(tree) or not valid(switcher) then error("host has no app switcher") end
    local root = make_border(tree, COLORS.body)
    local main = new_widget("VerticalBox", tree)
    root:SetContent(main)
    local header = make_border(tree, COLORS.header, 40, 14, 30, 14)
    local top = new_widget("HorizontalBox", tree)
    header:SetContent(top)
    local logo = ui.make_logo(host, tree, 64)
    if logo then
        local ls = top:AddChildToHorizontalBox(logo)
        valign(ls, 2)
        pad(ls, 0, 0, 18, 0)
    end
    local tb = new_widget("VerticalBox", tree)
    tb:AddChildToVerticalBox(make_text(tree, "AUTOMATION MANAGER", 34, COLORS.white))
    tb:AddChildToVerticalBox(make_text(tree, "v" .. VERSION .. "  by Luka's Mods", 16, { R = 0.55, G = 0.85, B = 0.85, A = 1.0 }))
    fill(top:AddChildToHorizontalBox(tb), 1)
    add_button(h, top, "Report a Bug", 200, "bugreport", COLORS.btnDark, 18)
    add_button(h, top, "Request a Feature", 240, "feature", COLORS.btnDark, 18)
    add_button(h, top, "Help", 150, "help", COLORS.btnDark, 18)
    add_button(h, top, "X", 60, "close", COLORS.btnDark, 26)
    main:AddChildToVerticalBox(header)
    local tabs = new_widget("HorizontalBox", tree)
    pad(main:AddChildToVerticalBox(tabs), 30, 10, 30, 0)
    add_button(h, tabs, "Board", 160, "page:board", COLORS.btn, 20)
    add_button(h, tabs, "Cars", 160, "page:cars", COLORS.btn, 20)
    add_button(h, tabs, "Car Pickup", 200, "page:delivery", COLORS.btn, 20)
    add_button(h, tabs, "Front Parking", 220, "page:front", COLORS.btn, 20)
    add_button(h, tabs, "Profiles", 160, "page:profiles", COLORS.btn, 20)
    local status = make_text(tree, "", 18, COLORS.good)
    -- Wrapped: a status can run to two sentences (car names included).
    pcall(function() status:SetAutoWrapText(true) end)
    pad(main:AddChildToVerticalBox(status), 34, 6, 30, 4)
    local scroll = new_widget("ScrollBox", tree)
    local list = new_widget("VerticalBox", tree)
    scroll:AddChild(list)
    local card = make_border(tree, COLORS.card, 20, 12, 20, 12)
    card:SetContent(scroll)
    local cs = main:AddChildToVerticalBox(card)
    fill(cs, 1)
    pad(cs, 30, 6, 30, 20)
    switcher:AddChild(root)
    h.panelPath, h.listPath, h.treePath, h.statusPath = remember(root), remember(list), remember(tree), remember(status)
end

local function panel_visible(h)
    local host, panel = resolve(h.hostPath), resolve(h.panelPath)
    if not (host and panel) then return false end
    local ok, active = pcall(function() return host.ApplicationWidgetSwitcher:GetActiveWidget() end)
    return ok and valid(active) and remember(active) == h.panelPath
end

local function open_panel(hostPath)
    local h, host = hosts[hostPath], resolve(hostPath)
    if not (h and host) then return end
    if not resolve(h.panelPath) then build_panel(h, host) end
    local panel = resolve(h.panelPath)
    if not panel then return end
    log("panel open (" .. tostring(ui.page) .. ")")
    refresh_panel(h)
    local switcher = host.ApplicationWidgetSwitcher
    if not pcall(function() switcher:SetActiveWidget(panel) end) then
        pcall(function() switcher:SetActiveWidgetIndex(switcher:GetChildIndex(panel)) end)
    end
end
local function close_panel(hostPath)
    local host = resolve(hostPath)
    if host then pcall(function() host:ReturnToDesktop() end) end
end

-- Report a Bug / Request a Feature: saves a report file and opens the public
-- issue form pre-filled, the same way as the other Luka's Mods apps.
local ISSUES = { url = "https://github.com/lukas-mods/Lukas-Mods/issues/new", name = "CDS - Automation Manager" }
local function url_encode(v) return (tostring(v):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end)) end
local function issue_url(template)
    return ISSUES.url .. "?template=" .. template .. "&title=" .. url_encode("[" .. ISSUES.name .. "] ")
        .. "&mod=" .. url_encode(ISSUES.name) .. "&version=" .. url_encode(VERSION)
end
local function open_external(target, select)
    if select then os.execute('start "" explorer.exe /select,"' .. target .. '"')
    else os.execute('start "" "' .. target .. '"') end
end
-- The player's folders and name, swapped out of a bug report. The profile
-- folder's name needn't match the user name (an account renamed, or a
-- Microsoft account's shortened folder), so the folders go first, whole,
-- matched without case and with either slash.
-- The Windows user name, or nil when it can't be read or is too short to
-- replace safely. The profile folder's own name stands in for it.
ui.user_name = function()
    local u = os.getenv("USERNAME")
    if not u or #u <= 1 then u = (os.getenv("USERPROFILE") or ""):match("([^\\/]+)[\\/]*$") end
    return u and #u > 1 and u or nil
end
local function scrub(v)
    v = tostring(v or "")
    local function loose(t)
        return (t:gsub("%p", "%%%0"):gsub("%%[\\/]", "[\\/]"):gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
    end
    for _, k in ipairs({ "LOCALAPPDATA", "USERPROFILE" }) do
        local d = os.getenv(k)
        if d and #d > 3 then v = v:gsub(loose(d), "<" .. k:lower() .. ">") end
    end
    local user = ui.user_name()
    -- The name alone only as a whole word, with and without "_" counted as
    -- part of a word: so "Art" doesn't eat "parts", "Sam2" and "sam_"
    -- still scrub, and so does "Sam_backup". A slash or space next to it
    -- is a word edge, so a path still scrubs. A marker stands in until both
    -- passes are done, so a name like "user" can't match inside "<user>".
    if user then
        v = v:gsub("%f[%w_]" .. loose(user) .. "%f[^%w_]", "\1"):gsub("%f[%w]" .. loose(user) .. "%f[%W]", "\1")
        v = v:gsub("\1", "<user>")
    end
    return v
end
local function write_bug_report()
    local dir = mod_dir():gsub("/", "\\") .. "\\"
    local path = dir .. MOD .. "-bug-" .. os.date("%Y%m%d-%H%M%S") .. ".txt"
    local out = {}
    -- Text that can't be scrubbed is left out, never written as it is.
    local function add(v)
        local ok, s = pcall(scrub, v)
        out[#out + 1] = ok and s or "(left out: this part couldn't be checked for your Windows user name)"
    end
    -- Each part on its own, so one that fails doesn't take the report with it.
    local function part(what, fn)
        local ok, err = pcall(fn)
        if not ok then
            log("bug report: " .. what .. " failed, " .. tostring(err))
            add("(" .. what .. " couldn't be read in full: " .. tostring(err) .. ")")
        end
    end
    add(MOD .. " v" .. VERSION .. " (" .. tostring(ui.build) .. ") bug report -- " .. os.date("%Y-%m-%d %H:%M:%S"))
    local okU, user = pcall(ui.user_name)
    add(okU and user and "Drag this file into the GitHub issue. Your Windows user name has been replaced with <user>."
        or "Your Windows user name couldn't be replaced, so it may still be in this file. Check the file before you drag it into the GitHub issue.")
    add("== profiles.lua ==")
    part("profiles.lua", function()
        local f = io.open(mod_dir() .. "/profiles.lua", "r")
        add(f and f:read("*a") or "(none)")
        if f then f:close() end
    end)
    part("board", function()
        local rows = board_rows() or {}
        add("== board: " .. #rows .. " cars ==")
        for _, r in ipairs(rows) do add(r.car .. (r.current and " (current)" or "") .. ": " .. table.concat(r.remaining, ",")) end
    end)
    part("intake failures", function()
        for id, n in pairs(failures) do
            if not tostring(id):find("[@#~]") then add("intake failures " .. tostring(id) .. ": " .. tostring(n)) end
        end
    end)
    part("UE4SS.log", function()
        local lf = io.open(dir .. "..\\..\\UE4SS.log", "r")
        if not lf then return end
        local mine = {}
        for line in lf:lines() do if line:find("[" .. MOD .. "]", 1, true) then mine[#mine + 1] = line end end
        lf:close()
        add("== UE4SS.log: " .. MOD .. " lines (last 300) ==")
        add(table.concat(mine, "\n", math.max(1, #mine - 299), #mine))
    end)
    local wf = io.open(path, "w")
    if not wf then return nil end
    local okW = wf:write(table.concat(out, "\n"), "\n")
    local okC = wf:close()
    if not (okW and okC) then return nil end
    log("bug report saved: " .. path:match("[^\\]+$"))
    return path
end

local function do_action(hostPath, action)
    local h = hosts[hostPath]
    local verb, arg = action:match("^(%w+):?(.*)$")
    -- A confirm only counts as the very next click (closing the app counts too).
    if verb ~= "reset" then ui.confirmReset = nil end
    if verb ~= "unstick" then ui.confirmUnstick = nil end
    if verb ~= "delete" then ui.confirmDelete = nil end
    if action == "open" then open_panel(hostPath) return end
    if action == "close" then close_panel(hostPath) return end
    if verb == "bugreport" then
        local path = write_bug_report()
        if path then
            open_external(issue_url("bug_report.yml"))
            open_external(path, true)
            set_status("Bug report saved to ue4ss\\Mods\\AutomationManager\\" .. path:match("[^\\]+$")
                .. ". GitHub is opening in your browser: drag the file into the issue and press Submit new issue.")
        else set_status("Couldn't save the bug report file.", false) end
    elseif verb == "feature" then
        open_external(issue_url("feature_request.yml"))
        set_status("GitHub's feature request form is opening in your browser.")
    elseif verb == "help" then
        if ui.page == "help" then ui.page = ui.helpReturn or "board"
        else ui.helpReturn, ui.page = ui.page, "help" end
        set_status("")
    elseif verb == "page" then
        log("page " .. tostring(arg))
        ui.page = arg
        set_status("")
    elseif verb == "askreset" then ui.confirmReset = arg
    elseif verb == "car" then
        -- With Select Cars on, or Shift held, a click ticks a car for Set Profile; otherwise
        -- (or for a car that already has its task) it opens the car's panel.
        local free = ui.multi_free()[arg] and true or false
        local shift = ui.shift_held()
        local age = ui.shiftAt and string.format("%.2f", os.clock() - ui.shiftAt) or "none"
        local tick = (ui.boardTick or shift) and free
        log("board click " .. arg .. ": " .. (tick and "tick" or "panel") .. " (mode=" .. tostring(ui.boardTick and true or false)
            .. " shift=" .. tostring(shift) .. " age=" .. age .. " free=" .. tostring(free) .. ")")
        if tick then
            ui.multi = ui.multi or {}
            ui.multi[arg] = (not ui.multi[arg]) or nil
        else
            ui.selCar = arg
        end
        set_status("")
    elseif verb == "fsel" then
        ui.frontSel = (ui.frontSel ~= arg) and arg or nil
        set_status("")
        -- Which spot number the player clicked, with its position, so the
        -- numbering can be checked against the lot from the log. Silence
        -- would read as "no click", so a miss and an error are logged too.
        local okL, errL = pcall(function()
            for i, sp in ipairs(ui.front_spots()) do
                if sp.id == arg then
                    log(string.format("front click F%d %s at %.0f,%.0f", i, car_label_by_id(arg), sp.x, sp.y))
                    return
                end
            end
            log("front click: car not on a spot now")
        end)
        if not okL then log("front click log failed: " .. tostring(errL)) end
    elseif verb == "sendback" then
        -- The car goes to a free spot near the warehouse and gets the photos-only
        -- job, which brings it back to Front Parking; the post is tried again
        -- with the profile it first finished on.
        local okM, why, moved = move_to_bay(arg, "send back")
        if okM then
            local e = sales[arg] or {}
            sales[arg] = { s = "sent", profile = e.profile, back = e.profile }
            assignments[arg] = "Photos Only"
            failures[arg], lastReason[arg] = nil, nil
            ui.frontSel = nil
            local saved = save_profiles()
            set_status(saved and (car_label_by_id(arg) .. " is going back for photos. It returns to Front Parking when they're done, and the mod tries to post it again.") or NOT_ON_DISK, saved)
        elseif moved == "moved" then
            log("send back " .. arg .. ": " .. tostring(why))
            set_status(car_label_by_id(arg) .. " was moved, but the mod couldn't confirm it landed on a spot, so it wasn't sent back for photos.", false)
        elseif moved == "unknown" then
            log("send back " .. arg .. ": " .. tostring(why))
            set_status(car_label_by_id(arg) .. " may not have moved. Check where it is, then try again.", false)
        else
            log("send back " .. arg .. ": not moved, " .. tostring(why))
            set_status(car_label_by_id(arg) .. " wasn't moved: " .. (why == "no free spot" and "every spot in the parking near the warehouse is taken"
                or why == "car not found" and "the car couldn't be found" or "the game didn't move it. Try again in a moment") .. ".", false)
        end
    elseif verb == "salecheck" and sales[arg] and sales[arg].s == "check" then
        -- An ad the mod couldn't confirm is only read again, never posted twice.
        local e, info = sales[arg], info_by_id(arg)
        if info and e.want then
            local res, detail = ui.sale_readback(arg, info, e.want)
            ui.sale_settle(arg, res, detail, info)
        else ui.sale_settle(arg, "unread", "record " .. (info and "found, nothing to compare" or "not found")) end
    elseif verb == "salecheck" then
        local e = sales[arg]
        if e and e.profile then
            -- Already settled on its spot, so only a few seconds' grace for a
            -- read that misses once.
            salePending[arg] = { profile = e.profile, at = os.clock() - 55 }
            e.s = "pending"
            save_profiles()
            set_status("Checking " .. car_label_by_id(arg) .. " again.")
        end
    elseif verb == "saledismiss" then
        sales[arg] = nil
        ui.frontSel = nil
        local saved = save_profiles()
        set_status(saved and (car_label_by_id(arg) .. " is off the mod's list. It's yours to price.") or NOT_ON_DISK, saved)
    elseif verb == "view" then ui.boardView = arg set_status("")
    elseif verb == "askunstick" then ui.confirmUnstick = arg
    elseif verb == "unstick" then
        ui.confirmUnstick = nil
        local ok, msg, r = free_robot(arg, "unstick")
        unstuckAt[arg] = os.clock()
        stallSeen[arg] = nil
        if not r then
            log("unstick " .. arg .. ": " .. tostring(msg))
            set_status(player_reason(msg), false)
        elseif r.failed then
            set_status("The game's reset didn't run, so nothing was changed.", false)
        elseif #r.lost > 0 then
            local names = {}
            for _, id in ipairs(r.lost) do names[#names + 1] = car_label_by_id(id) end
            set_status("Platform freed, but these cars lost their tasks and need setting again: " .. table.concat(names, ", ")
                .. (r.rescued == r.rescueTried and ". Their parts are back in storage." or ". Some of their parts couldn't be put back; Report a Bug sends us the details."), false)
        elseif r.other and not r.moved then
            set_status(car_label_by_id(arg) .. " couldn't be moved to a free parking spot, so nothing was changed. The platform was busy with "
                .. car_label_by_id(r.other) .. ", so it wasn't interrupted.", false)
        elseif r.spared and not r.moved then
            set_status(car_label_by_id(arg) .. " couldn't be moved to a free parking spot, so nothing was changed.", false)
        elseif not r.moved then
            set_status("Platform freed and every car kept its task, but " .. car_label_by_id(arg)
                .. " couldn't be moved to a free parking spot, so the platform may not pick it up. If it doesn't move on, use Reset Car.", false)
        elseif r.other then
            set_status(car_label_by_id(arg) .. " is on a free parking spot and kept its task, so the platform will pick it up again. The platform was busy with "
                .. car_label_by_id(r.other) .. ", so it wasn't interrupted.")
        elseif r.spared then
            set_status(car_label_by_id(arg) .. " is on a free parking spot and kept its task, so the platform will pick it up again.")
        else
            set_status("Platform freed. Every car kept its task; " .. car_label_by_id(arg) .. " is on a free parking spot, so the platform will pick it up again.")
        end
        ui.note_lists_lost(r)
    elseif verb == "reset" then
        ui.confirmReset = nil
        local ok, msg, r = reset_car(arg)
        local function parts(n) return n .. (n == 1 and " part is" or " parts are") .. " back in storage" end
        -- A car a station is still working on is queued to move when it's done,
        -- whichever message the rest of the result gives.
        local qc = ""
        if r and r.wait then
            local okW, w = pcall(function() return map_state().where[arg] end)
            w = okW and w or nil
            local place = w and where_full(w) or nil
            place = place and ((w.count == 1 and "the " or "") .. place) or "the station"
            ui.pendingReset[arg] = { zone = r.wait, place = place, at = os.clock(), sawInside = r.waitInside, sawRef = r.waitRef, sawRunning = r.waitRunning }
            qc = " " .. car_label_by_id(arg) .. " goes to a free spot in the parking near the warehouse when " .. place .. " is done."
        end
        if not r then
            log("reset " .. arg .. ": " .. tostring(msg))
            set_status(player_reason(msg), false)
        elseif r.failed and r.other then
            set_status("The platform is busy with " .. car_label_by_id(r.other) .. " and " .. car_label_by_id(arg) .. "'s task couldn't be removed, so nothing was changed. Try again once the platform sets "
                .. car_label_by_id(r.other) .. " down.", false)
        elseif r.failed and r.spared then
            set_status(car_label_by_id(arg) .. "'s task couldn't be removed, so nothing was changed. Try again in a moment.", false)
        elseif r.failed then
            set_status("The game's reset didn't run, so nothing was changed: this car and the others keep their tasks.", false)
        elseif r.wait and #r.lost == 0 and r.shortfall == 0 then
            set_status("Car reset. " .. parts(r.returned) .. "." .. qc)
        elseif #r.lost == 0 and r.shortfall > 0 then
            set_status("Car reset, but " .. r.shortfall .. (r.shortfall == 1 and " part" or " parts")
                .. " couldn't be put back. Report a Bug sends us the details." .. qc, false)
        elseif #r.lost == 0 then
            local others = r.other and ("; the platform was busy with " .. car_label_by_id(r.other) .. ", so it wasn't interrupted.")
                or (r.spared or r.total == 0) and "." or (r.total == 1 and "; the other car kept its task." or ("; the other " .. r.total .. " cars kept their tasks."))
            local where = r.moved and " The car is on a free spot in the parking near the warehouse."
                or (r.moveWhy == "no free spot" and " There's no free spot in the parking near the warehouse, so the car stays where it stopped."
                or " The car couldn't be moved, so it stays where it stopped.")
            set_status("Car reset. " .. parts(r.returned) .. others .. where)
        else
            local names = {}
            for _, id in ipairs(r.lost) do names[#names + 1] = car_label_by_id(id) end
            set_status("Car reset. " .. parts(r.returned) .. ". These cars lost their tasks and need setting again: "
                .. table.concat(names, ", ") .. (r.rescued == r.rescueTried and ". Their parts are back in storage." or ". Some of their parts couldn't be put back; Report a Bug sends us the details.") .. qc, false)
        end
        ui.note_lists_lost(r)
    elseif verb == "pick" then
        ui.pickFor = (ui.pickFor ~= arg) and arg or nil
    elseif verb == "dauto" then
        ui.deliv.auto = not ui.deliv.auto
        ui.deliv.tried = {}
        local saved = ui.save_delivery()
        ui.deliv.unsaved = not saved
        log("delivery: Add Bought Cars " .. (ui.deliv.auto and "on" or "off") .. (saved and "" or " (not saved)"))
        if not saved then set_status(NOT_ON_DISK, false)
        elseif ui.deliv.auto then set_status("Add Bought Cars is on. Cars the Car Pickup screen offers go on the transporter's list by themselves, up to 7.")
        else set_status("Add Bought Cars is off. Cars already on the list stay there.") end
    elseif verb == "dmin" then
        local t, n = ui.transporter(), tonumber(arg)
        if not (t and t.min and n) or n < 1 or n > ui.TRANSPORT_MAX then set_status("")
        elseif ui.set_min(t, n) then
            ui.deliv.restoreMin, ui.deliv.restoreNow = nil, nil
            local saved = ui.save_delivery()
            ui.deliv.unsaved = not saved
            log("delivery: minimum set to " .. n .. (saved and "" or " (not saved)"))
            set_status(saved and ("Pick up when is now " .. n .. ".") or NOT_ON_DISK, saved)
        else set_status("The game didn't take the change, so Pick up when is still " .. t.min .. ".", false) end
    elseif verb == "dsend" then
        local t = ui.transporter()
        if not (t and t.state == 0 and t.n and t.min and t.n >= 1 and t.n < t.min) then
            set_status("Send Now needs the transporter idle, with at least one car on its list but fewer than Pick up when is set to.", false)
        else
            local old = t.min
            if ui.set_min(t, t.n) then
                ui.deliv.restoreMin, ui.deliv.restoreLogged, ui.deliv.restoreNow, ui.deliv.sawAway = old, nil, nil, nil
                local saved = ui.save_delivery()
                ui.deliv.unsaved = not saved
                log("delivery: Send Now with " .. t.n .. ", minimum " .. old .. " -> " .. t.n .. (saved and "" or " (restore not saved)"))
                set_status("Pick up when is now " .. t.n .. ", so the trip can start with the " .. t.n .. (t.n == 1 and " car" or " cars")
                    .. " on the list. It goes back to " .. old .. " once the transporter has left.")
            else set_status("The game didn't take the change, so Pick up when is still " .. old .. " and nothing was sent.", false) end
        end
    elseif verb == "msel" then
        ui.multi = ui.multi or {}
        ui.multi[arg] = (not ui.multi[arg]) or nil
        set_status("")
    elseif verb == "mall" then
        ui.multi = {}
        local robot = robot_now()
        for _, c in ipairs(bay_cars()) do
            if not (robot and stored_task(robot, c.id) ~= nil) then ui.multi[c.id] = true end
        end
        set_status("")
    elseif verb == "btick" then
        ui.boardTick = (not ui.boardTick) or nil
        set_status("")
    elseif verb == "mclear" then
        ui.multi, ui.pickFor = {}, nil
        set_status("")
    elseif verb == "assignto" and arg:match("^%*|") then
        -- One profile for every ticked car still waiting for its task.
        local name = arg:sub(3)
        local robot, n, here = robot_now(), 0, {}
        for _, c in ipairs(bay_cars()) do here[c.id] = true end
        for id in pairs(ui.multi or {}) do
            if here[id] and not (robot and stored_task(robot, id) ~= nil) then
                assignments[id] = (name ~= "" and profiles[name]) and name or nil
                failures[id], failures[id .. "@"], failures[id .. "#parts"], lastReason[id] = nil, nil, nil, nil
                n = n + 1
            end
        end
        ui.multi, ui.pickFor = {}, nil
        local cars = n == 1 and "1 car" or (n .. " cars")
        if n == 0 then set_status("The selected cars already have their tasks or have left, so nothing was changed.", false)
        elseif not save_profiles() then set_status(NOT_ON_DISK, false)
        elseif name ~= "" and profiles[name] then set_status("Profile set to " .. name .. " for " .. cars .. ".")
        else set_status("Profile set to None for " .. cars .. ".") end
    elseif verb == "assignto" then
        local id, name = arg:match("^([^|]+)|(.*)$")
        if id and id ~= "*" then
            assignments[id] = (name ~= "" and profiles[name]) and name or nil
            failures[id], failures[id .. "@"], failures[id .. "#parts"], lastReason[id] = nil, nil, nil, nil
            ui.pickFor = nil
            if not save_profiles() then set_status(NOT_ON_DISK, false) end
        end
    elseif verb == "assign" then
        local names = profile_names()
        local cur = assignments[arg]
        local nxt
        if not cur then nxt = names[1] else
            for i, n in ipairs(names) do if n == cur then nxt = names[i + 1] end end
        end
        assignments[arg] = nxt
        if not save_profiles() then set_status(NOT_ON_DISK, false) end
    elseif verb == "lowerlift" then
        local n = tonumber(arg)
        local target, label, picked = nil, nil, nil
        for _, sl in ipairs(ui.stuck_lifts(map_state())) do if sl.n == n then target, label, picked = sl.lift, sl.label, sl end end
        if not target then
            log("lower lift " .. tostring(arg) .. ": no stuck lift there now")
            set_status("That lift isn't stuck any more, so nothing was done.", false)
        elseif picked.holds then
            log("lower lift " .. tostring(arg) .. ": the lift holds a car, not lowered")
            set_status("That lift still counts a car as on it, and lowering it would pull that car back, so nothing was done.", false)
        else
            -- Lowering cancels itself (and the lift goes back up) if a car, a
            -- dolly or the player is under it, so that's checked first.
            -- Read as a return value first, then as an out-parameter (a table),
            -- the way the mod's other Blueprint calls deliver results; the
            -- log names the out field if that's where it came.
            local okC, under = pcall(function() return target:CheckCollisionUnder() end)
            if not (okC and type(under) == "boolean") then
                local outC = {}
                okC, under = pcall(function() return target:CheckCollisionUnder(outC) end)
                log_out_keys("CheckCollisionUnder", okC, outC)
                if okC and type(under) ~= "boolean" then
                    -- Only a single boolean is taken; with more than one, which
                    -- is the answer isn't known yet, so it's left unread (and
                    -- the lift isn't lowered) until the log names the field.
                    local bools = {}
                    for _, v in pairs(outC) do if type(v) == "boolean" then bools[#bools + 1] = v end end
                    if #bools == 1 then under = bools[1] end
                end
            end
            if not okC or type(under) ~= "boolean" then
                log("lower lift " .. n .. ": couldn't check under the lift (" .. tostring(under) .. ")")
                set_status("Couldn't check whether anything is under the lift, so it wasn't lowered.", false)
            elseif under then
                log("lower lift " .. n .. ": something is under the lift")
                set_status("Something is under the " .. label .. " lift. Move it away, or step out from under it, then try again.", false)
            else
                local okM, errM = pcall(function() target:MoveLiftDown() end)
                log("lower lift " .. n .. ": " .. (okM and "asked the lift to go down" or ("the call failed: " .. tostring(errM))))
                if okM then
                    ui.liftCheck = { lift = target, n = n, label = label, heldId = picked.heldId, zone = picked.zone, at = os.clock() }
                    set_status("Lowering the " .. label .. " lift. It takes a few seconds.")
                else
                    set_status("The lift couldn't be lowered. Report a Bug sends us the details.", false)
                end
            end
        end
    elseif verb == "freestation" then
        local t, n = tostring(arg):match("^(%d+):(%d+)$")
        t, n = tonumber(t), tonumber(n)
        local picked = nil
        for _, hs in ipairs(ui.held_stations(map_state())) do if hs.t == t and hs.n == n then picked = hs end end
        -- Read once more right before the call: a car may have arrived since.
        local v0, r0 = nil, nil
        if picked then v0, r0 = zone_vehicle(picked.actor) end
        if not picked or v0 or r0 ~= true or not ui.stale_hold(picked.actor)
            or (picked.t == 4 and ui.lift_state(picked.actor) == "not down") then
            log("free station " .. tostring(arg) .. ": not freed, "
                .. ((not picked and "no such station held for 30 s") or (v0 and "a car is in it")
                    or (r0 ~= true and "not running") or (not ui.stale_hold(picked.actor) and "the hold field doesn't say held, or the bay's car didn't read")
                    or "its lift isn't down and still"))
            set_status("That station isn't held any more, so nothing was done.", false)
        else
            local okE, errE = pcall(function() picked.actor:EndWorkOnZone() end)
            -- The game's call ends at once, so the station is read back now:
            -- only "not running, no car" counts as freed.
            local v1, r1 = zone_vehicle(picked.actor)
            log("free station " .. picked.label .. " (" .. name_of(picked.actor) .. "): "
                .. (okE and "EndWorkOnZone called" or ("the call failed: " .. tostring(errE)))
                .. ", read back " .. (r1 == nil and "unread" or (r1 and "still held" or "free")) .. (v1 and ", a car is in it" or ""))
            if okE and r1 == false and not v1 then
                set_status(picked.label .. " is free again.")
            else
                set_status(picked.label .. " couldn't be freed. Report a Bug sends us the details.", false)
            end
        end
    elseif verb == "retry" then failures[arg], failures[arg .. "@"], failures[arg .. "#parts"], lastReason[arg] = nil, nil, nil, nil
    elseif verb == "select" then ui.selected, ui.confirmDelete = arg, nil
    elseif verb == "newprofile" then
        local i = 1
        while profiles["Profile " .. i] do i = i + 1 end
        profiles["Profile " .. i] = default_profile()
        ui.selected, ui.confirmDelete = "Profile " .. i, nil
        if not save_profiles() then set_status(NOT_ON_DISK, false) end
    elseif verb == "rename" and ui.selected ~= "Default" then
        local typed = ""
        pcall(function() typed = resolve(ui.nameBox):GetText():ToString() end)
        local name = typed:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
        if name == ui.selected then
            set_status("That's already its name.")
        elseif name == "" then
            set_status("Not renamed: type a name first.", false)
        elseif (utf8.len(name) or #name) > 24 then
            set_status("Not renamed: names can be up to 24 characters.", false)
        elseif name:find("[%c]") then
            set_status("Not renamed: that name has characters a profile name can't use.", false)
        elseif profiles[name] or name:lower() == "default" or name:lower() == "photos only" then
            set_status("Not renamed: there's already a profile called " .. name .. ".", false)
        else
            local old = ui.selected
            profiles[name], profiles[old] = profiles[old], nil
            ui.drafts[name], ui.drafts[old] = ui.drafts[old], nil
            for id, n in pairs(assignments) do if n == old then assignments[id] = name end end
            for id, n in pairs(applied) do if n == old then applied[id] = name end end
            ui.selected = name
            local saved = save_profiles()
            set_status(saved and ("Renamed to " .. name .. ".") or NOT_ON_DISK, saved)
        end
    elseif verb == "color" then
        local p = draft()
        p.paint = p.paint or {}
        p.paint.color = tonumber(arg) or 0
    elseif verb == "step" then
        local p = draft()
        if arg == "PhotoStudio" and p.steps.PhotoStudio and sale_on(p) then
            set_status("The Photo Studio stays on while Post for Sale is on: the game needs a photo to post a car.", false)
        else
            p.steps[arg] = not p.steps[arg]
        end
    elseif verb == "dest" then
        local p = draft()
        p.destination = ((p.destination or 0) + 1) % 4
        if sale_on(p) then p.steps.PhotoStudio = true end
    elseif verb == "sale" or verb == "salecomp" or verb == "saleflag" then
        local p = draft()
        p.sale = p.sale or default_profile().sale
        if verb == "sale" then
            p.sale.on = not p.sale.on
            if sale_on(p) then p.steps.PhotoStudio = true end
        elseif verb == "salecomp" then
            p.sale.compete = math.max(1, math.min(100, (p.sale.compete or 60) + (tonumber(arg) or 0)))
        else
            for _, f in ipairs(SALE_FLAGS) do
                if f[1] == arg then p.sale[arg] = not p.sale[arg] end
            end
        end
    elseif verb == "mode" then
        local p = draft()
        p.mechanic.mode = next_in(MODES, p.mechanic.mode)
        p.mechanic.slots = p.mechanic.slots or {}
        p.mechanic.slots.Windshield = p.mechanic.slots.Windshield or "Stock"
    elseif verb == "tier" then local p = draft() p.mechanic.partType = next_in(dlc_ok() and TIERS or { "Default", "Stock" }, p.mechanic.partType)
    elseif verb == "slot" then
        local p = draft()
        p.mechanic.slots = p.mechanic.slots or {}
        local opts = (STOCK_ONLY[arg] and { "Stock" }) or (dlc_ok() and SLOT_TIERS) or { "Stock" }
        p.mechanic.slots[arg] = next_in(opts, p.mechanic.slots[arg])
    elseif verb == "save" then
        local p = draft()
        local missingSlots = (mech_on(p) and p.mechanic.mode == "custom") and custom_missing(p, SLOT_NAMES) or {}
        if #missingSlots > 0 then
            set_status("Not saved: a Custom profile needs every slot set (" .. #missingSlots .. " left).", false)
        else
            profiles[ui.selected] = deep_copy(p)
            if save_profiles() then
                ui.drafts[ui.selected] = nil
                set_status("Profile saved.")
            else
                set_status("Not saved: the mod folder can't be written. Your changes are still here.", false)
            end
        end
    elseif verb == "askdelete" then ui.confirmDelete = ui.selected
    elseif verb == "delete" and ui.selected ~= "Default" and ui.confirmDelete == ui.selected then
        local n = 0
        for id, name in pairs(assignments) do if name == ui.selected then assignments[id] = nil n = n + 1 end end
        for id, name in pairs(applied) do if name == ui.selected then applied[id] = nil end end
        profiles[ui.selected], ui.drafts[ui.selected] = nil, nil
        ui.selected, ui.confirmDelete = "Default", nil
        local saved = save_profiles()
        set_status(not saved and NOT_ON_DISK or n > 0 and ("Profile deleted. " .. n .. (n == 1 and " car no longer has" or " cars no longer have") .. " a profile.") or "Profile deleted.", saved)
    end
    if h then refresh_panel(h) end
end

local function add_icon(host, kind)
    local hostPath = remember(host)
    if not hostPath then return end
    local h = hosts[hostPath]
    if h and resolve(h.iconPath) then return end
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
    icon.Icon = FText("\239\128\147")   -- "cog" glyph in the icon font
    icon.Text = FText("")
    set_color(icon.IconColor, COLORS.white)
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
    pcall(function() icon:UpdateVisual() end)
    pcall(function() icon:SetInteractable(true) end)
    pcall(function() icon:SetToolTipText(FText("Automation Manager")) end)
    -- The game draws its tablet icons scaled; without the same render scale
    -- this icon draws larger than its neighbours.
    pcall(function()
        local sc = source.RenderTransform.Scale
        icon:SetRenderScale({ X = sc.X, Y = sc.Y })
    end)
    hosts[hostPath] = { kind = kind, hostPath = hostPath, iconPath = remember(icon), panelPath = h and h.panelPath or nil }
    buttons[icon:GetFullName()] = { host = hostPath, action = "open" }
    log("app icon added to " .. kind)
end

local function on_icon_clicked(ctx)
    local ok, clicked = pcall(function() return ctx:get() end)
    if not ok or not valid(clicked) then return end
    local b = buttons[clicked:GetFullName()]
    if not b then return end
    -- Act on the next game-thread pass, after the click has finished dispatching.
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

-- Esc closes the app (the screens' own key events; several can see the same
-- press, so it acts once). Escape with a pending confirm just clears it.
-- os.clock() is wall time since the process started (Microsoft's clock(),
-- not ISO's CPU time). Its clock_t is 32-bit milliseconds: after about 24.8
-- days of uptime it returns -1 for good and every timer here stops (parts
-- re-checks, spot holds, the Esc debounce, the Unstick window).
local lastEscape = -1e9
local function on_escape()
    for hostPath, h in pairs(hosts) do
        if panel_visible(h) then
            if ui.page == "help" then
                ui.page = ui.helpReturn or "board"
                refresh_panel(h)
            elseif ui.confirmReset or ui.confirmDelete or ui.confirmUnstick then
                ui.confirmReset, ui.confirmDelete, ui.confirmUnstick = nil, nil, nil
                refresh_panel(h)
            else
                close_panel(hostPath)
            end
        end
    end
end
local function key_hook(_, _, keyEvent)
    local key = nil
    pcall(function()
        local k = resolve("/Script/Engine.Default__KismetInputLibrary"):GetKey(keyEvent:get())
        key = k.KeyName:ToString()
    end)
    -- A held Shift for Shift-click on the Board: the controller reports it up
    -- while the tablet has the keyboard, but the screens' key hooks see it,
    -- repeating while held. See ui.shift_held.
    if key == "LeftShift" or key == "RightShift" then ui.shiftAt = os.clock() end
    if key ~= "Escape" then return end
    if os.clock() - lastEscape < 0.25 then return end
    lastEscape = os.clock()
    ExecuteInGameThread(function()
        local ok, err = xpcall(on_escape, debug.traceback)
        if not ok then log("escape failed: " .. tostring(err)) end
    end)
end

-- Shift counts as held for 1.1 s after its last key-down. The screens have no
-- key-up event to hook (they override only the key-down ones), so a held Shift
-- is known only from its repeating key-downs, which start after the keyboard's
-- repeat delay; Windows lets the player set that up to 1 s, so a shorter window
-- would drop a Shift held through it.
-- Both readings must be positive: a clock stuck at -1 (see on_escape) reads
-- as not held, rather than held for good.
ui.shift_held = function()
    local now = os.clock()
    return ui.shiftAt ~= nil and ui.shiftAt > 0 and now > 0 and now - ui.shiftAt < 1.1
end

-- Each hook is registered once a live instance of its class exists (a hashed
-- lookup), never by searching for an unloaded class.
local HOOKS = {
    { name = "icon click", gate = "WBP_DesktopIconWidget_C", path = ICON_CLASS .. ":BndEvt__WBP_DesktopIconWidget_Button_112_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature", fn = on_icon_clicked },
    { name = "tablet", gate = "WBP_Tablet_C", path = TABLET_CLASS .. ":ActivateApplications", fn = on_host_ready("tablet") },
    { name = "computer", gate = "WBP_DesktopComputer_C", path = COMPUTER_CLASS .. ":Activate Applications", fn = on_host_ready("computer") },
    { name = "tablet keys", gate = "WBP_Tablet_C", path = TABLET_CLASS .. ":OnKeyDown", fn = key_hook, keys = true },
    { name = "computer keys", gate = "WBP_DesktopComputer_C", path = COMPUTER_CLASS .. ":OnKeyDown", fn = key_hook, keys = true },
    -- The screens' shared base class sees a key first (OnPreviewKeyDown),
    -- even while a button inside the app has focus.
    { name = "preview keys", gate = "WBP_Tablet_C", base = true, fn = key_hook, keys = true },
}

local function hooks_tick()
    for _, hk in ipairs(HOOKS) do
        -- A screen's hook is registered as soon as its class can be loaded (once,
        -- in the game world, as Parts Manager does), so it's in place before the
        -- tablet first opens and the app icon appears with the game's own. Until
        -- then, or if the load fails, a live screen still lets it register.
        local ready = not hk.done and first_live(hk.gate)
        if not hk.done and not ready and not hk.base and not hk.loadTried and hk.path and robot_now() then
            hk.loadTried = true
            local cls = hk.path:gsub(":.*$", "")
            local okL, c = pcall(function() return LoadAsset(cls) end)
            ready = okL and valid(c)
            -- Held, so the loaded class has a reference and isn't collected
            -- out from under its hook.
            if ready then hk.loadedClass = c end
            log((ready and "loaded " or "could not load ") .. cls .. (ready and "" or "; waiting for a live screen instead"))
        end
        if ready then
            if hk.base then
                local live_host = first_live(hk.gate)
                local okS, sup = pcall(function() return live_host:GetClass():GetSuperStruct() end)
                hk.path = (okS and valid(sup)) and (path_of(sup) .. ":OnPreviewKeyDown") or nil
            end
            local ok, err = false, "base class not found"
            if hk.path then ok, err = pcall(function() RegisterHook(hk.path, hk.fn) end) end
            hk.done = true
            -- The error's first line only: the rest is a stack trace that reads as a crash.
            log(hk.name .. (ok and " hook registered" or (" hook FAILED: " .. (tostring(err):match("^[^\n]*") or "") .. " [" .. tostring(hk.path) .. "]")))
            if ok and hk.name ~= "icon click" and not hk.keys then
                local live_host = first_live(hk.gate)
                if live_host then pcall(add_icon, live_host, hk.name) end
            end
        end
    end
end

-- The ad a post sent, read back from the car's record. "posted" is set
-- (in ui.sale_settle) only when every field reads and matches what was sent.
-- Returns "ok", "none" (no ad on the record), "unread" (the ad itself
-- couldn't be read), "partial" (the ad is there but a field couldn't be read)
-- or "mismatch" (every field read, one differs), and a line with each field
-- as read / as sent, so the state can be re-derived from the log.
ui.sale_readback = function(id, info, want)
    local okO, offer = pcall(function() return info.VehicleOffer end)
    if not okO then return "unread", "offer=unread" end
    if not valid(offer) then return "none", "offer=none" end
    local got, unread, differ = { "offer=yes" }, {}, {}
    local function rd(k)
        local ok, v = pcall(function() return offer[k] end)
        return ok and v ~= nil, v
    end
    -- Counted with ForEach, as the mod reads every other game array.
    local function count(k)
        local n = nil
        pcall(function() local c = 0 offer[k]:ForEach(function() c = c + 1 end) n = c end)
        return n
    end
    local function field(name, okR, read, sent, same)
        got[#got + 1] = name .. "=" .. (okR and tostring(read) or "unread") .. "/" .. tostring(sent)
        if not okR or sent == nil then unread[#unread + 1] = name
        elseif not same(read, sent) then differ[#differ + 1] = name end
    end
    local eq = function(x, y) return x == y end
    local okB, back = rd("VehicleInfoObject")
    field("back", okB and valid(back), valid(back) and name_of(back) or nil, name_of(info), function() return same_obj(back, info) end)
    local okP, pr = rd("OfferPrice")
    field("price", okP and tonumber(pr) ~= nil, tonumber(pr), want.price, function(x, y) return math.floor(x + 0.5) == y end)
    local okS, sid = rd("ParkingSlotID")
    field("slot", okS, okS and text_of(sid) or nil, want.slot, eq)
    local okD, days = rd("DaysLeft")
    field("days", okD and tonumber(days) ~= nil, tonumber(days), 9999999, eq)
    local nPh, nPa = count("Photos"), count("PlayerPhotoPaths")
    field("photos", nPh ~= nil, nPh, want.n, eq)
    field("paths", nPa ~= nil, nPa, want.n, eq)
    for _, k in ipairs({ "Negotiable", "AllowLeasing", "CanSellOnline", "IsOnWarranty" }) do
        local okF, v = rd(k)
        field(k, okF and type(v) == "boolean", v, want[k], eq)
    end
    local detail = table.concat(got, " ") .. (#unread > 0 and (" unread:" .. table.concat(unread, ",")) or "")
        .. (#differ > 0 and (" differs:" .. table.concat(differ, ",")) or "")
    if #unread > 0 then return "partial", detail end
    if #differ > 0 then return "mismatch", detail end
    return "ok", detail
end
-- Applies a read-back to the car's record and says it once.
-- With no ad on the record, the ad details the post set on the car are put
-- back, since the game only leaves them alongside a real ad.
ui.sale_settle = function(id, res, detail, info)
    local e = sales[id]
    if not e then return end
    -- The post call itself raised and no ad came of it: the cause is the
    -- mod's call, not the game, so it gets its own reason.
    if e.raised and res == "none" then res, detail = "error", tostring(detail) .. " call=raised" end
    log("sale " .. id .. " readback: " .. tostring(detail) .. " -> " .. tostring(res))
    if (res == "none" or res == "error") and e.undo and info then
        local back = true
        for i = #e.undo, 1, -1 do
            local k, old = e.undo[i][1], e.undo[i][2]
            pcall(function() info[k] = old end)
            local okB, now = pcall(function() return info[k] end)
            if not (okB and now == old) then back = false end
        end
        log("sale " .. id .. ": no ad, ad details " .. (back and "put back" or "NOT all put back"))
    end
    if res ~= "unread" and res ~= "partial" and res ~= "mismatch" then e.undo = nil end
    if res == "ok" then
        e.s, e.why = "posted", nil
        set_status(car_label_by_id(id) .. " is listed at " .. ui.money(e.price) .. ".")
    elseif res == "none" or res == "error" then
        e.s, e.why = "refused", res == "error" and "postError" or "postNone"
        set_status(car_label_by_id(id) .. " wasn't posted: " .. ui.SALE_WHY[e.why] .. ". See Front Parking.", false)
    elseif res == "partial" then
        e.s, e.why = "check", "postPartial"
        set_status(car_label_by_id(id) .. " was listed, but the mod couldn't check all of its ad's details. Check it in Your Ads.", false)
    elseif res == "mismatch" then
        e.s, e.why = "check", "postMismatch"
        set_status(car_label_by_id(id) .. " was listed, but its ad isn't what the mod set up. Check it in Your Ads.", false)
    else
        e.s, e.why = "check", "postUnread"
        set_status("The mod couldn't tell whether " .. car_label_by_id(id) .. " was listed. Look for it in Your Ads.", false)
    end
    if not save_profiles() then log("sale " .. id .. ": result not written to profiles.lua") end
end

-- Post for Sale: every test the game's ad screen makes before it lists a car
-- (its car list and its Post button), read for one car, then the ad posted
-- through the game's own CreatePlayerVehicleOffer, as the ad screen's Post
-- does, and read back. Returns nil while the car may still be settling onto
-- its spot (with what it's waiting on), else true once the result is logged.
local function sale_post(id, entry)
    local p = profiles[entry.profile]
    local sl = (p and p.sale) or {}
    -- The ad screen lists the cars on the customer parking spots, so the car
    -- has to be on one, and the game counts it only once it's parked inside
    -- the spot's lines.
    -- The spot count and how many hold a car go in the log, so a car not
    -- found can be told from a list that was never read.
    local slot, parked, nSlots, nFull, unreadCar = nil, nil, nil, 0, false
    for _, gm in ipairs(find_all("BP_GameMode_C")) do
        if not slot and live(gm) then
            pcall(function()
                gm.CustomerSystem.ParkingSlots:ForEach(function(_, v)
                    nSlots = (nSlots or 0) + 1
                    local okV, sp = pcall(function() return v:get() end)
                    -- A spot, or its car, that can't be read might hold this car.
                    if not (okV and valid(sp)) then unreadCar = true return end
                    local okC, veh = pcall(function() return sp.ParkingSlotVehicle end)
                    if not okC then unreadCar = true end
                    if okC and valid(veh) then
                        nFull = nFull + 1
                        local cid = car_id_of(veh)
                        if cid == nil then unreadCar = true end
                        if not slot and cid == id then slot = sp end
                    end
                end)
            end)
        end
    end
    if slot then
        local okP, pp = pcall(function() return slot.ProperlyParked end)
        if okP and type(pp) == "boolean" then parked = pp end
    end
    if not (slot and parked == true) and os.clock() - entry.at < 60 then
        return nil, (slot and ("on " .. name_of(slot) .. ", parked=" .. tostring(parked)) or "not on a customer spot yet")
            .. string.format(" (slots=%s occupied=%d)", tostring(nSlots), nFull)
    end
    -- A spot holding a car whose id couldn't be read might be this car, so
    -- the check waits (up to 2 minutes in all) rather than give up on it.
    if not slot and unreadCar and os.clock() - entry.at < 120 then
        return nil, "a spot's car couldn't be read" .. string.format(" (slots=%s occupied=%d)", tostring(nSlots), nFull)
    end
    if not slot then
        -- The car never reached a customer spot (its task ended some other
        -- way, or it went elsewhere), so there's nothing to check.
        log(string.format("sale %s: not on a customer spot after 60 s (slots=%s occupied=%d), so not posted", id, tostring(nSlots), nFull))
        sales[id] = nil
        save_profiles()
        return true
    end
    local info = info_by_id(id)
    local fails, out = {}, {}
    -- One reading: a boolean, or "unread" (which counts as a fail).
    local function flag(label, read, want)
        local ok, v = pcall(read)
        -- Not "cond and v or unread": that turns a read false into unread.
        local r = "unread"
        if ok and type(v) == "boolean" then r = v end
        -- An unread value says why: the call's error, or the type it gave.
        local why = r ~= "unread" and "" or ("(" .. (ok and type(v) or tostring(v):sub(1, 80)) .. ")")
        out[#out + 1] = label .. "=" .. tostring(r) .. why
        -- An unread value isn't a reason the player can act on.
        if r ~= want then fails[#fails + 1] = (r == "unread") and "record" or label end
    end
    out[#out + 1] = "spot=" .. (slot and name_of(slot) or "none") .. string.format(" slots=%s occupied=%d", tostring(nSlots), nFull)
    if not slot then fails[#fails + 1] = "spot" end
    out[#out + 1] = "parked=" .. tostring(parked)
    if parked ~= true then fails[#fails + 1] = (parked == nil and slot) and "record" or "parked" end
    if not info then
        fails[#fails + 1] = "record"
        log("sale " .. id .. ": car record not found, so not posting (" .. table.concat(out, " ") .. ")")
        return true
    end
    flag("owned", function() return info.PlayerOwned end, true)
    flag("canOffer", function() return info.CanCreateOffer end, true)
    flag("serviceRequest", function() return info["Has Service Request"] end, false)
    flag("canBeSold", function()
        local fn = struct_field("S_VehiclePresets", "CanBeSold")
        return fn and info.ModelPresetInfo[fn]
    end, true)
    local okO, offer = pcall(function() return info.VehicleOffer end)
    out[#out + 1] = "offer=" .. (not okO and "unread" or (valid(offer) and "yes" or "none"))
    if not okO or valid(offer) then fails[#fails + 1] = "offer" end
    -- The economy's list of cars that can't be sold, by car id.
    local econ = first_live("BP_EconomySystem_C")
    -- Its size and first element go in the log: a list of something other
    -- than car ids would otherwise read the same as one without this car.
    local excluded, nEx, firstEx = "unread", 0, nil
    if econ then
        pcall(function()
            local hit = false
            econ.CarsExcludedFromSelling:ForEach(function(_, e)
                local okE, ev = pcall(function() return e:get() end)
                local t = text_of(okE and ev or e)
                nEx = nEx + 1
                if nEx == 1 then firstEx = t end
                if t == id then hit = true end
            end)
            excluded = hit
        end)
    end
    out[#out + 1] = "excluded=" .. tostring(excluded) .. " excludedN=" .. nEx .. " first=" .. tostring(firstEx)
    if excluded ~= false then fails[#fails + 1] = (excluded == "unread") and "record" or "excluded" end
    -- Photos: the economy's photos of this car, as the ad screen's photo
    -- picker lists them. Studio photos score double, and the score counts
    -- each tag once across all the photos chosen.
    local photos, studio, tags, nTags = 0, 0, {}, 0
    local po = {}
    local okF = econ and pcall(function() econ:GetPhotosForCar(id, po) end)
    log_out_keys("GetPhotosForCar", okF and true or false, po)
    -- The list's own read is checked too: a wrong name would otherwise
    -- show as 0 photos rather than unread.
    -- The call hands the photos back as the out table's own numbered entries
    -- (measured: 1..6 for a car with photos, no named key), each needing :get().
    -- entries counts every key, so a gap in the numbering can't read as a
    -- short list; badEntry says what the first entry that isn't a photo was.
    local firstPhoto, entries, badEntry, phs = nil, 0, nil, {}
    for _ in pairs(po) do entries = entries + 1 end
    if okF then
        okF = pcall(function()
            for _, e in ipairs(po) do
                local okG, ph = pcall(function() return e:get() end)
                if not (okG and valid(ph)) then
                    badEntry = badEntry or (okG and type(ph) or ("get failed: " .. tostring(ph):sub(1, 60)))
                end
                if okG and valid(ph) then
                    firstPhoto = firstPhoto or name_of(ph)
                    photos = photos + 1
                    local okS, st = pcall(function() return ph.MadeByPhotoStudio end)
                    if okS and st == true then studio = studio + 1 end
                    -- Studio photos first: the ad's first photo is its main one.
                    table.insert(phs, (okS and st == true) and 1 or #phs + 1, ph)
                    pcall(function()
                        ph.CapturedTags:ForEach(function(_, t)
                            local okT, tv = pcall(function() return t:get() end)
                            local key = text_of(okT and tv or t)
                            if key and not tags[key] then tags[key], nTags = true, nTags + 1 end
                        end)
                    end)
                end
            end
        end)
    end
    local okX, maxPts = pcall(function() return tonumber(info.CapturedPointsMax) end)
    maxPts = okX and maxPts or nil
    local score = (maxPts and maxPts > 0) and (nTags / maxPts) * (studio > 0 and 1.0 or 0.5) or nil
    out[#out + 1] = string.format("photos=%s studio=%d tags=%d/%s score=%s entries=%d first=%s bad=%s", okF and tostring(photos) or "unread", studio, nTags,
        tostring(maxPts), score and string.format("%.2f", score) or "unread", entries, tostring(firstPhoto), tostring(badEntry))
    if not okF or photos == 0 then fails[#fails + 1] = "photo" end
    -- The ad screen shows installments from reputation 12, online sale from
    -- 10, and the warranty once its level is reached (never on a special
    -- car). A choice the game hides is sent as off, so the mod never uses
    -- one the player hasn't unlocked; unread counts as hidden.
    local ro = {}
    local okR = econ and pcall(function() econ:GetReputationLevel(ro) end)
    log_out_keys("GetReputationLevel", okR and true or false, ro)
    -- Out-param ReputationLevel, as Parts Manager reads it.
    local rep = okR and tonumber(ro.ReputationLevel) or nil
    local wo, warrantyOk = {}, false
    local ws = first_live("BPS_Warranty_Subsystem_C")
    local okW = ws and pcall(function() ws:HasEnoughLevel(wo) end)
    log_out_keys("HasEnoughLevel", okW and true or false, wo)
    local okSp, special = pcall(function() return info.IsSpecialVehicle end)
    warrantyOk = okW and wo.Unlock == true and okSp and special == false
    out[#out + 1] = string.format("reputation=%s warrantyLevel=%s special=%s", tostring(rep), okW and tostring(wo.Unlock) or "unread",
        okSp and tostring(special) or "unread")
    local leasing = sl.leasing == true and rep ~= nil and rep >= 12
    local online = sl.online == true and rep ~= nil and rep >= 10
    local warranty = sl.warranty == true and warrantyOk
    -- The value and the bar both depend on the ad: the photos chosen for it
    -- (the ad screen writes their tag count and studio flag onto the record)
    -- and the warranty (value x1.1). So those three are set on the record the
    -- way the ad screen sets them, every write read back, and the price is
    -- worked out. They stay set when the car is posted, as the ad screen
    -- leaves them; if it isn't posted, each is put back as it was. Measured:
    -- without them a car with 7/7 studio photos priced about 15% of market low.
    local m0 = {}
    local okM0 = pcall(function() info:GetVehicleAdjustedPrice(m0) end)
    local market0 = okM0 and tonumber(m0.Value) and math.floor(tonumber(m0.Value) + 0.5) or nil
    -- Each bonus term as the game works it out, logged before and after the
    -- ad fields are set, so a later difference from the ad screen can be put
    -- down to one term.
    local function terms(tag, pr)
        local o = { {}, {}, {}, {}, {}, {}, {}, {} }
        local okC = pcall(function() info:OfferCompetitiveness(pr or market0 or 1, o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8]) end)
        local t = {}
        for _, k in ipairs({ "Photo", "Wash", "Polish", "Worker", "Exposition", "Carplate", "TirePressure" }) do
            t[#t + 1] = k .. "=" .. tostring(out_field(k .. "Bonus", table.unpack(o)))
        end
        log("sale " .. id .. ": bonuses " .. tag .. (okC and "" or " (call failed)") .. ": " .. table.concat(t, " "))
    end
    terms("before the ad fields")
    local saved, setOk = {}, true
    local function setf(k, v)
        if not setOk then return end
        local okR, old = pcall(function() return info[k] end)
        if not okR or old == nil then setOk = false return end
        -- Already the value the ad would give: no write, nothing to restore.
        if old == v then return end
        saved[#saved + 1] = { k, old }
        pcall(function() info[k] = v end)
        local okB, now = pcall(function() return info[k] end)
        if not (okB and now == v) then setOk = false end
    end
    if okF and photos > 0 then
        setf("CapturedPointsInOffer", nTags)
        setf("PhotoMadeByPhotoStudio", studio > 0)
    end
    setf("IsOnWarranty", warranty)
    -- What was changed and its old value go in the log before the pricing,
    -- so a crash in the game's own code mid-pricing (which no pcall catches)
    -- leaves a record of what to put back.
    if #saved > 0 then
        local w = {}
        for _, sv in ipairs(saved) do w[#w + 1] = sv[1] .. " was " .. tostring(sv[2]) end
        log("sale " .. id .. ": ad fields set for pricing, " .. table.concat(w, ", "))
    end
    if setOk and #saved > 0 then terms("with the ad fields")
    elseif setOk then log("sale " .. id .. ": ad fields already as the ad would set them, nothing changed") end
    local price, barAt, mkt = nil, nil, nil
    local okPr, errPr = pcall(function()
        -- The ad screen's market price is the record's adjusted value, rounded,
        -- and a price is whole dollars above 0.
        local mo = {}
        local okM = pcall(function() info:GetVehicleAdjustedPrice(mo) end)
        log_out_keys("GetVehicleAdjustedPrice", okM, mo)
        local value = okM and tonumber(mo.Value) or nil
        local market = value and math.floor(value + 0.5) or nil
        -- The price is the highest whole-dollar price whose competitiveness,
        -- as the game's OfferCompetitiveness works it out (every bonus counted),
        -- is at least the profile's level. With Non-negotiable ticked the ad
        -- screen's bar compares price with market value only, full at 0.8 and
        -- empty at 1.3, so that formula is used instead.
        if not setOk then return end
        local target = (sl.compete or 60) / 100
        local function fv(pr)
            local o = { {}, {}, {}, {}, {}, {}, {}, {} }
            local okC = pcall(function() info:OfferCompetitiveness(pr, o[1], o[2], o[3], o[4], o[5], o[6], o[7], o[8]) end)
            log_out_keys("OfferCompetitiveness", okC, table.unpack(o))
            return okC and tonumber(out_field("FinalValue", table.unpack(o))) or nil
        end
        local atPrice = nil
        -- On a special vehicle the ad screen always draws a full green bar; the
        -- price still comes from OfferCompetitiveness, which the game uses for
        -- the offer itself.
        if value and sl.nonNegotiable then
            -- The widget compares the price with the market value rounded to cents.
            price = math.floor(math.floor(value / 0.01 + 0.5) * 0.01 * (1.3 - 0.5 * target))
        elseif value then
            -- At price 1 the bar is always full, so this only checks the call
            -- works. The top starts at twice the value and doubles while it still
            -- reaches the level: a well-prepared car at a low level can price
            -- above twice its value.
            local lo, hi = 1, math.floor(value * 2)
            local f1 = fv(lo)
            for _ = 1, 4 do
                local fh = f1 and fv(hi)
                if not (fh and fh >= target) then break end
                lo, hi = hi, hi * 2
            end
            if f1 and f1 >= target then
                while lo < hi do
                    local mid = (lo + hi + 1) // 2
                    local fm = fv(mid)
                    if fm == nil then lo, hi = nil, nil break end
                    if fm >= target then lo = mid else hi = mid - 1 end
                end
                price = lo
            end
        end
        if price and not sl.nonNegotiable then
            atPrice = fv(price)
            -- The bonuses don't depend on the price in the game's formula; read
            -- at the chosen price too, so the log shows it.
            terms("at the price " .. price, price)
        end
        barAt, mkt = atPrice or (price and sl.nonNegotiable and target) or nil, market
        out[#out + 1] = string.format("market=%s (before the ad fields were set %s) compete=%d price=%s barAtPrice=%s", tostring(market), tostring(market0), sl.compete or 60, tostring(price),
            atPrice and string.format("%.3f", atPrice) or (sl.nonNegotiable and "price-only" or "unread"))
        if not (price and price > 0) then fails[#fails + 1] = "price" end
    end)
    if not okPr then fails[#fails + 1] = "price" log("sale " .. id .. ": pricing failed, " .. tostring(errPr)) end
    -- The ad's photos as the ad screen builds them: each photo's texture,
    -- and its file path moved to the current save (the game's own call)
    -- then rebuilt on the saved-files folder. The paths are what the ad
    -- keeps across a reload.
    local gm, paths, texs = first_live("BP_GameMode_C"), {}, {}
    if #fails == 0 and setOk then
        if not ui.savedDir then
            pcall(function() ui.savedDir = text_of(StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):GetProjectSavedDirectory()) end)
        end
        local how, dropped = {}, {}
        for _, ph in ipairs(phs) do
            local okT, tex = pcall(function() return ph.Texture end)
            local okP2, fp = pcall(function() return text_of(ph.FilePath) end)
            local rel, note = ui.photo_rel(gm, okP2 and fp or nil)
            if not (okT and valid(tex)) then rel, note = nil, "no texture" end
            if not (ui.savedDir and ui.savedDir ~= "") then rel, note = nil, "saved folder unread" end
            if rel then
                paths[#paths + 1] = ui.savedDir .. rel
                texs[#texs + 1] = tex
                how[note] = (how[note] or 0) + 1
            else
                dropped[note] = (dropped[note] or 0) + 1
            end
        end
        local function counts(t)
            local c = {}
            for k, n in pairs(t) do c[#c + 1] = n .. " " .. k end
            table.sort(c)
            return #c > 0 and table.concat(c, "; ") or "none"
        end
        -- The first path as it sits under the saved-files folder: the folder
        -- itself holds the player's profile path, so it stays out of the log.
        local firstRel = paths[1] and ui.savedDir and paths[1]:sub(#ui.savedDir + 1) or nil
        log(string.format("sale %s photos: n=%d of %d first=<saved>%s savedDir=%s", id, #paths, #phs, tostring(firstRel),
            (ui.savedDir and ui.savedDir ~= "") and "read" or "unread"))
        log("sale " .. id .. " photo paths: " .. counts(how) .. ", dropped: " .. counts(dropped))
        if #paths == 0 then fails[#fails + 1] = "photo" end
        if not gm then fails[#fails + 1] = "record" end
    end
    local posting = #fails == 0 and setOk
    local restored = true
    if not posting then
        for i = #saved, 1, -1 do
            local k, old = saved[i][1], saved[i][2]
            pcall(function() info[k] = old end)
            local okB, now = pcall(function() return info[k] end)
            if not (okB and now == old) then restored = false end
        end
    end
    out[#out + 1] = "adFields=" .. (setOk and "set" or "NOT set, not priced") .. " changed=" .. #saved
        .. " restored=" .. (posting and "kept for the ad" or #saved == 0 and "nothing to restore" or (restored and "yes" or "NO"))
    if not setOk then fails[#fails + 1] = "adFields" end
    -- A record left changed is worse than a wrong price, so it blocks too.
    if not restored then
        fails[#fails + 1] = "restore"
        log("sale " .. id .. ": the record's ad fields could not all be put back")
    end
    log("sale " .. id .. " (" .. car_label_by_id(id) .. ") checks, profile " .. tostring(entry.profile) .. ": " .. table.concat(out, " "))
    log("sale " .. id .. ": " .. (#fails == 0 and "checks passed" or ("checks failed (" .. table.concat(fails, ", ") .. ")"))
        .. string.format(": price=%s nonNegotiable=%s leasing=%s online=%s warranty=%s photos=%d", tostring(price), tostring(sl.nonNegotiable == true),
        tostring(leasing), tostring(online), tostring(warranty), #fails == 0 and #paths or photos))
    -- The Front Parking page shows the result; a refusal is also said once.
    local opts = {}
    if sl.nonNegotiable then opts[#opts + 1] = "Non-negotiable" end
    if leasing then opts[#opts + 1] = "Installments" end
    if online then opts[#opts + 1] = "Online Sale" end
    if warranty then opts[#opts + 1] = "Warranty" end
    -- What the ad must read back as, kept so Try Again can read it again.
    local okSI, slotId = pcall(function() return text_of(slot.ParkingID) end)
    local want = { price = price, slot = okSI and slotId or nil, n = #paths, Negotiable = not sl.nonNegotiable,
        AllowLeasing = leasing, CanSellOnline = online, IsOnWarranty = warranty }
    sales[id] = { s = posting and "pending" or "refused", why = fails[1], profile = entry.profile, price = price,
        bar = barAt, market = mkt, opts = table.concat(opts, ", "), want = want, undo = posting and saved or nil }
    if not posting then
        if not save_profiles() then log("sale " .. id .. ": result not written to profiles.lua") end
        set_status(car_label_by_id(id) .. " wasn't posted: " .. (ui.SALE_WHY[fails[1]] or fails[1]) .. ". See Front Parking.", false)
        return true
    end
    -- Logged before the call, so a crash inside it names the car.
    log(string.format("sale %s posting: price=%d photos=%d negotiable=%s leasing=%s online=%s warranty=%s", id, price, #paths,
        tostring(want.Negotiable), tostring(leasing), tostring(online), tostring(warranty)))
    local okC, errC = pcall(function()
        gm:CreatePlayerVehicleOffer(info, price + 0.0, paths, texs, slot, want.Negotiable, leasing, online, warranty)
    end)
    if not okC then
        log("sale " .. id .. ": the post call failed, " .. tostring(errC))
        -- Kept on the record, so a later Try Again that finds no ad still
        -- puts it down to the mod's call, not the game.
        sales[id].raised = true
    end
    -- A special car is marked new once posted, as the ad screen does.
    if okSp and special == true then
        local okA = pcall(function() if valid(info.VehicleOffer) then info.IsSetAsNewVehicle = true end end)
        local okB, nv = pcall(function() return info.IsSetAsNewVehicle end)
        log("sale " .. id .. ": special car, IsSetAsNewVehicle " .. ((okA and okB and nv == true) and "set" or "NOT set"))
    end
    local res, detail = ui.sale_readback(id, info, want)
    ui.sale_settle(id, res, detail, info)
    return true
end

-- A moved car is confirmed once its spot reports it. Checked a few seconds
-- after the move; if the spot still hasn't noticed the car, the player is told.
local function check_moves()
    local keepList = {}
    -- Sampled every tick for as long as the spot is held for the car (10 s);
    -- the warning comes once, only if the spot never reports it.
    for _, m in ipairs(moveChecks) do
        local v = live(m.slot) and zone_vehicle(m.slot)
        local there = v and same_obj(v, m.vehicle)
        -- Once the spot has reported the car, it's watched to the 10 s mark
        -- too, so a car that lands and is then taken (by the robot, or pulled
        -- back) shows as its own line rather than as a clean move.
        if m.seen then
            if not there then
                -- Where the car went, so a car pulled back to a station shows as a distance.
                local cl, sl = actor_loc(m.vehicle), live(m.slot) and actor_loc(m.slot)
                local d = (cl and sl) and math.sqrt((cl.X - sl.X) ^ 2 + (cl.Y - sl.Y) ^ 2) or nil
                log(string.format("move %s: spot %s no longer reports the car, %.1f s after the move; the car is %s from the spot", m.car, name_of(m.slot), os.clock() - m.at,
                    d and string.format("%.0f cm", d) or "an unread distance"))
            elseif os.clock() - m.at < 10 then
                keepList[#keepList + 1] = m
            else
                -- Where the car really is when the watch ends: a spot can go on
                -- naming a car that has been pulled away (seen after a Reset
                -- from the car wash, with the car back in the wash bay).
                local cl, sl = actor_loc(m.vehicle), actor_loc(m.slot)
                local d = (cl and sl) and math.sqrt((cl.X - sl.X) ^ 2 + (cl.Y - sl.Y) ^ 2) or nil
                log(string.format("move %s: at 10 s the spot still reports it and the car is %s from the spot", m.car,
                    d and string.format("%.0f cm", d) or "an unread distance"))
            end
        elseif there then
            m.seen = true
            keepList[#keepList + 1] = m
            log(string.format("move %s: spot %s reports the car after %.1f s", m.car, name_of(m.slot), os.clock() - m.at))
            if m.from then
                local ok, sv = pcall(function() return m.from.zone[m.from.field] end)
                log(string.format("move %s: the station or spot it left (%s) %s", m.car, name_of(m.from.zone),
                    not ok and ("couldn't be read (" .. m.from.field .. ")") or ((valid(sv) and same_obj(sv, m.vehicle)) and ("still names it in " .. m.from.field) or ("no longer names it in " .. m.from.field))))
            end
        elseif os.clock() - m.at < 10 then
            keepList[#keepList + 1] = m
        else
            do
                log("move " .. m.car .. ": spot " .. tostring(live(m.slot) and name_of(m.slot)) .. " does NOT report the car")
                set_status(car_label_by_id(m.car) .. " is on a parking spot, but the game hasn't registered it there, so the platform may not see it. If it doesn't move on, use Reset Car.", false)
                for _, h in pairs(hosts) do if panel_visible(h) then pcall(refresh_panel, h) end end
            end
        end
    end
    moveChecks = keepList
    -- The lift's own lowering takes 5 s; read back after 7. It counts as down
    -- only when the lift reads not up, not moving, and holding no car.
    local lc = ui.liftCheck
    if lc and os.clock() - lc.at >= 7 then
        ui.liftCheck = nil
        local okU, up = pcall(function() return lc.lift.IsLiftUp end)
        local okP, busy = pcall(function() return lc.lift.IsProcessing end)
        local okV, held = pcall(function() return lc.lift.VehicleOnLift end)
        local down = okU and up == false and okP and busy == false and okV and not valid(held)
        -- Lowering should also end the bay's job (it waits for the lift).
        local _, bayRunning = nil, nil
        if valid(lc.zone) then _, bayRunning = zone_vehicle(lc.zone) end
        log(string.format("lower lift %d: after %.0f s up=%s moving=%s holding a car=%s, bay at work=%s (held %s)", lc.n, os.clock() - lc.at,
            tostring(okU and up), tostring(okP and busy), tostring(okV and valid(held)), tostring(bayRunning), tostring(lc.heldId)))
        -- The parts hint only when parts are really still on that car's task.
        local rb = robot_now()
        local left = (down and lc.heldId and rb) and parts_of(rb, lc.heldId) or nil
        if left and #left > 0 then
            set_status("The " .. lc.label .. " lift is down and the bay is free. " .. car_label_by_id(lc.heldId)
                .. " left before the mechanic fitted its parts; they're still set aside for it, and Reset Car puts them back in storage.")
        elseif down then set_status("The " .. lc.label .. " lift is down and the bay is free.")
        else set_status("The " .. lc.label .. " lift didn't come down. If something was under it, move it away and try again; otherwise Report a Bug sends us the details.", false) end
        for _, h in pairs(hosts) do if panel_visible(h) then pcall(refresh_panel, h) end end
    end
end

load_profiles()
ui.load_delivery()
local ticks = 0
local okLoop = pcall(function()
    LoopInGameThreadWithDelay(1000, function()
        ticks = ticks + 1
        local okM, errM = pcall(check_moves)
        if not okM then log("move check error: " .. tostring(errM)) end
        -- A Reset made while a station was working on the car moves it once the
        -- station is done; the game's own end of the job has then put the car
        -- back as the one the player sees.
        local okQ, errQ = pcall(function()
            for car, p in pairs(ui.pendingReset) do
                local zl = live(p.zone)
                local zcar, running = nil, nil
                if zl then zcar, running = zone_vehicle(p.zone) end
                local named = valid(zcar) and car_id_of(zcar) == car
                -- Three readings of whether the bay is done. Its work state stays
                -- true while the car is still in the bay after the job (measured),
                -- so the bay's own "car inside" flag and its stand-in reference
                -- (both cleared by the game's end of the job) count too; each one
                -- is logged when it changes, to show which one tracks the job.
                local okI, inside = false, nil
                local okR, ref = false, nil
                if zl then
                    okI, inside = pcall(function() return p.zone.VehicleInside end)
                    okR, ref = pcall(function() return p.zone["Washable Vehicle"] end)
                end
                local refState = not okR and "unread" or (valid(ref) and "set" or "none")
                local info, veh = info_by_id(car), nil
                if info then pcall(function() veh = info.Vehicle end) end
                local a, b = valid(veh) and actor_loc(veh) or nil, zl and actor_loc(p.zone) or nil
                local dist = (a and a.X and b and b.X) and vector_dist(a, b) or nil
                -- A car the bay no longer names counts as there while it stands
                -- in the bay. 300 read a car still standing in the bay as gone
                -- (measured), so 600; the distance is logged so a measured figure
                -- can replace this.
                local here = named or (dist ~= nil and dist < 600)
                local flags = string.format("inside=%s ref=%s at work=%s named=%s", okI and tostring(inside) or "unread", refState,
                    tostring(running), tostring(named))
                local state = flags .. " " .. (dist and string.format("%.0f cm from the bay", dist) or "distance unread")
                -- Logged on a change of the flags or of the distance by 50 cm, so a
                -- car standing still doesn't log every second.
                local key = flags .. "|" .. (dist and tostring(math.floor(dist / 50)) or "?")
                -- Each flag counts only after it was seen set: done means set and
                -- then cleared, as a reading of "clear" alone can come before the
                -- job (any one arm firing early would move the car mid-job).
                if refState == "set" then p.sawRef = true end
                if okI and inside == true then p.sawInside = true end
                if running == true then p.sawRunning = true end
                local done = (p.sawInside and okI and inside == false) or (p.sawRef and refState == "none") or (p.sawRunning and running == false)
                if key ~= p.lastKey then
                    p.lastKey = key
                    log(string.format("reset %s: %s at %.0f s: %s", car, tostring(p.place), os.clock() - p.at, state))
                end
                if not zl then
                    ui.pendingReset[car] = nil
                    log("reset " .. car .. ": the station is gone, so it isn't moved")
                elseif not here then
                    ui.pendingReset[car] = nil
                    log("reset " .. car .. ": no longer in " .. tostring(p.place) .. " before it was done (" .. state .. "), so it isn't moved")
                    set_status(car_label_by_id(car) .. " left " .. tostring(p.place) .. " before it was done, so it wasn't moved.", false)
                elseif done then
                    local okMv, why = move_to_bay(car, "reset")
                    if okMv then
                        ui.pendingReset[car] = nil
                        log("reset " .. car .. ": " .. tostring(p.place) .. " is done after " .. string.format("%.0f s", os.clock() - p.at) .. " (" .. state .. "), car moved")
                        set_status(car_label_by_id(car) .. " is on a free spot in the parking near the warehouse.")
                    elseif not p.told then
                        p.told = true
                        log("reset " .. car .. ": " .. tostring(p.place) .. " is done but the car couldn't be moved yet (" .. tostring(why) .. "); trying again")
                    end
                elseif not p.slow and os.clock() - p.at >= 300 then
                    -- A bay that never finishes, or that can't be read, would hold
                    -- the car with nothing said; the car isn't taken out mid-job,
                    -- so the player is told and the wait goes on.
                    p.slow = true
                    log("reset " .. car .. ": " .. tostring(p.place) .. " not done after 300 s (" .. state .. "); still waiting")
                    set_status(car_label_by_id(car) .. ": " .. tostring(p.place) .. " still hasn't finished after 5 minutes. The car goes to a free spot in the parking near the warehouse once it's done.", false)
                elseif os.clock() - (p.logged or p.at) >= 60 then
                    p.logged = os.clock()
                    log("reset " .. car .. ": still waiting for " .. tostring(p.place) .. " (" .. string.format("%.0f s", os.clock() - p.at) .. ", " .. state .. ")")
                end
            end
        end)
        if not okQ then log("queued reset error: " .. tostring(errQ)) end
        local okSale, errSale = pcall(function()
            for id, e in pairs(salePending) do
                -- "@<id>" keys are seen-with-a-task marks, not cars to check.
                if type(e) == "table" then
                    -- A check that errors is dropped, so it can't repeat every second.
                    local okD, done, waiting = pcall(sale_post, id, e)
                    if not okD then
                        salePending[id] = nil
                        log("sale " .. id .. ": check failed, " .. tostring(done))
                    elseif done then salePending[id] = nil
                    elseif waiting ~= e.waiting then
                        e.waiting = waiting
                        log("sale " .. id .. ": waiting, " .. tostring(waiting))
                    end
                end
            end
        end)
        if not okSale then log("sale check error: " .. tostring(errSale)) end
        local okH, errH = pcall(hooks_tick)
        if not okH then log("hooks error: " .. tostring(errH)) end
        if ticks % 5 == 0 then
            local okD, errD = pcall(function() ui.delivery_restore() ui.delivery_tick() end)
            if not okD then log("delivery error: " .. tostring(errD)) end
        end
        if ticks % 2 == 0 then
            local ok, err = pcall(intake_tick)
            if not ok then log("intake error: " .. tostring(err)) end
            local st = nil
            local okS, errS = pcall(function() st = map_state() if st then stall_track(st) end end)
            if not okS then log("map state error: " .. tostring(errS)) end
            -- Every robot state change is logged here, with the app open or not,
            -- so the log shows when and from what the robot went red.
            local okR, errR = pcall(function()
                -- The state this tick already read is passed in, so a blocked robot
                -- costs one scan, not two; a failed read (nil) isn't logged as a change.
                local rtext, _, glow = robot_line(st)
                if rtext and glow and glow ~= lastRobotGlow then
                    log("robot state " .. tostring(lastRobotGlow) .. " -> " .. tostring(glow) .. ": " .. rtext)
                    lastRobotGlow = glow
                end
            end)
            if not okR then log("robot state error: " .. tostring(errR)) end
        end
        for _, h in pairs(hosts) do
            if ticks % 2 == 1 and panel_visible(h) and ui.page == "board" then pcall(refresh_panel, h) end
            if ticks % 2 == 1 and panel_visible(h) and ui.page == "front" then
                local okS, sig = pcall(ui.front_sig)
                if not okS or sig ~= h.frontSig then pcall(refresh_panel, h) end
            end
            if ticks % 2 == 1 and panel_visible(h) and ui.page == "delivery" then
                local okG, snap = pcall(ui.delivery_snapshot)
                if not okG or snap.sig ~= h.delivSig then
                    ui.deliv.snap = okG and snap or nil
                    pcall(refresh_panel, h)
                elseif snap.t and snap.t.left and h.delivStateBase then
                    -- Same page: only the countdown moves, in its own line.
                    local w = resolve(h.delivState)
                    if w then pcall(function() w:SetText(FText(h.delivStateBase .. ", back in " .. ui.mins(snap.t.left))) end) end
                end
            end
        end
    end)
end)
-- The Post for Sale slider is read several times a second while the
-- Profiles page shows it. The bar and the Save Profile button
-- change in place: rebuilding the page would replace the slider under a
-- player still holding it. An error is logged once per distinct message.
pcall(function()
    LoopInGameThreadWithDelay(150, function()
        local okP, errP = pcall(function()
            local sd = ui.page == "profiles" and resolve(ui.saleSlider)
            if not sd then return end
            local okV, v = pcall(function() return sd:GetValue() end)
            v = okV and tonumber(v) or nil
            if not v then return end
            local p = draft()
            if not (p.sale and sale_on(p)) then return end
            local c = math.max(1, math.min(100, math.floor(v * 100 + 0.5)))
            if c == p.sale.compete then return end
            p.sale.compete = c
            local bar, cv = resolve(ui.saleBar), c / 100
            if bar then
                pcall(function() bar:SetPercent(cv) end)
                pcall(function() bar:SetFillColorAndOpacity(cv >= 0.6 and COLORS.barBlue or cv >= 0.4 and COLORS.barGreen
                    or cv >= 0.25 and COLORS.barYellow or COLORS.barRed) end)
            end
            -- The button is an overlay of the game's button and its label.
            local ov = resolve(ui.saveBtn)
            if ov then
                local unsaved = serialize(p) ~= serialize(profiles[ui.selected] or {})
                pcall(function() set_text(ov:GetChildAt(1), unsaved and "Save Profile (unsaved changes)" or "Save Profile", COLORS.white) end)
                pcall(function()
                    local b = ov:GetChildAt(0)
                    set_color(b.BackgroundColor, unsaved and COLORS.btnWarn or COLORS.btnOn)
                    b:UpdateVisual()
                end)
            end
        end)
        if not okP and tostring(errP) ~= ui.saleErr then
            ui.saleErr = tostring(errP)
            log("sale slider error: " .. ui.saleErr)
        end
    end)
end)

-- Every build shares VERSION, so the file reports its own size and checksum:
-- the log and bug reports then say which build ran, with nothing to bump.
ui.build = "size unread"
pcall(function()
    local f = io.open((debug.getinfo(1, "S").source:gsub("^@", "")), "rb")
    if not f then return end
    local data = f:read("a")
    f:close()
    if not data then return end
    local sum = 0
    for i = 1, #data do sum = (sum * 31 + data:byte(i)) & 0xFFFFFFFF end
    ui.build = string.format("%d B, sum %08x", #data, sum)
end)
log("v" .. VERSION .. " (" .. ui.build .. ") loaded (" .. (okLoop and "running" or "loop NOT started") .. "), " .. tostring(_VERSION))

-- Exposed for other scripts.
AutomationManager = {
    profiles = function() return profiles end,
    assignments = function() return assignments end,
    save = save_profiles,
    apply = apply_profile,
    board = board_rows,
    custom_missing = custom_missing,
    add_custom_parts = add_custom_parts,
    reset_car = reset_car,
    slot_names = function() return SLOT_NAMES end,
    failures = function() return failures end,
    bay_cars = bay_cars,
}
