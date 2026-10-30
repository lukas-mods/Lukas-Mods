--[[
    Installed Mods -- core rules, no game calls.

    Kept apart from main.lua so every rule here can be run and tested outside
    the game. main.lua loads this file and does the reading and the drawing.
--]]

local core = {}

-- Caps from the mod-support.json convention (v1). Over a cap is refused,
-- never cut short: a shortened name or version is a wrong one.
core.MAX_FILE = 4096
core.MAX_KEYS = 16
core.MAX_NAME = 48
core.MAX_VERSION = 24
core.MAX_ROWS = 200

-------------------------------------------------------------------------------
-- mod-support.json: a flat object of strings and integers, nothing else.
-- A hand-written parser because UE4SS ships no JSON library, and because a
-- strict small one refuses what a general one would quietly accept.

local function skip_ws(s, i)
    return s:match("^[ \t\r\n]*()", i)
end

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function parse_string(s, i)
    -- s:sub(i, i) is the opening quote
    local out, j = {}, i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then return nil, "unterminated string" end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if ESC[e] then
                out[#out + 1] = ESC[e]
                j = j + 2
            elseif e == "u" then
                local hex = s:sub(j + 2, j + 5)
                if not hex:match("^%x%x%x%x$") then return nil, "bad \\u escape" end
                local cp = tonumber(hex, 16)
                -- Anything outside printable ASCII is refused later anyway;
                -- keep it as a marker so the field fails its own check.
                out[#out + 1] = (cp >= 32 and cp < 127) and string.char(cp) or "\0"
                j = j + 6
            else
                return nil, "bad escape"
            end
        else
            out[#out + 1] = c
            j = j + 1
        end
    end
end

function core.parse_manifest(text)
    if type(text) ~= "string" then return nil, "no file" end
    if #text > core.MAX_FILE then return nil, "file over " .. core.MAX_FILE .. " bytes" end
    if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end  -- UTF-8 BOM
    local i = skip_ws(text, 1)
    if text:sub(i, i) ~= "{" then return nil, "not an object" end
    i = skip_ws(text, i + 1)
    local obj, keys = {}, 0
    if text:sub(i, i) == "}" then
        i = i + 1
    else
        while true do
            if text:sub(i, i) ~= '"' then return nil, "expected a key" end
            local k, ni = parse_string(text, i)
            if not k then return nil, ni end
            i = skip_ws(text, ni)
            if text:sub(i, i) ~= ":" then return nil, "expected ':'" end
            i = skip_ws(text, i + 1)
            local c, v = text:sub(i, i), nil
            if c == '"' then
                v, ni = parse_string(text, i)
                if not v then return nil, ni end
                i = ni
            else
                local num = text:match("^%-?%d+", i)
                if not num then return nil, "values must be strings or whole numbers" end
                v = tonumber(num)
                i = i + #num
            end
            keys = keys + 1
            if keys > core.MAX_KEYS then return nil, "over " .. core.MAX_KEYS .. " keys" end
            if obj[k] ~= nil then return nil, "duplicate key " .. k end
            obj[k] = v
            i = skip_ws(text, i)
            local d = text:sub(i, i)
            if d == "}" then i = i + 1 break end
            if d ~= "," then return nil, "expected ',' or '}'" end
            i = skip_ws(text, i + 1)
        end
    end
    if skip_ws(text, i) <= #text then return nil, "text after the object" end
    return obj
end

-------------------------------------------------------------------------------
-- Field checks. Each field degrades on its own: a bad version costs only the
-- version, a bad name falls back to the folder name, a bad schema drops the file.

local function printable(s)
    return type(s) == "string" and not s:find("[%z\1-\31\127-\255]")
end

function core.clean_name(v)
    if not printable(v) then return nil end
    v = v:match("^%s*(.-)%s*$")
    if v == "" or #v > core.MAX_NAME then return nil end
    return v
end

function core.clean_version(v)
    if type(v) ~= "string" or v == "" or #v > core.MAX_VERSION then return nil end
    if not v:match("^[0-9A-Za-z%.%+%-]+$") then return nil end
    return v
end

-- Returns the fields that passed, plus one line per field that did not (for
-- the log; the player sees only the result).
function core.read_manifest(text)
    local obj, err = core.parse_manifest(text)
    if not obj then return nil, { err } end
    if obj.schema ~= 1 then return nil, { "schema is not 1" } end
    local out, notes = {}, {}
    if obj.name ~= nil then
        out.name = core.clean_name(obj.name)
        if not out.name then notes[#notes + 1] = "name refused" end
    end
    if obj.version ~= nil then
        out.version = core.clean_version(obj.version)
        if not out.version then notes[#notes + 1] = "version refused" end
    end
    return out, notes
end

-------------------------------------------------------------------------------
-- mods.txt: "Name : 1" per line. Every line is kept as it was, so a later
-- write can change one line and give back every other byte untouched.

function core.parse_mods_txt(text)
    local lines, index = {}, {}
    if type(text) ~= "string" then return nil end
    for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("(.-)\n") do
        lines[#lines + 1] = line
        local name, val = line:gsub("\r$", ""):match("^%s*([^;:][^:]-)%s*:%s*([01])%s*$")
        if name and not index[name] then index[name] = { line = #lines, on = (val == "1") } end
    end
    return { lines = lines, index = index, crlf = text:find("\r\n") ~= nil }
end

-- What the player is shown for one mod. Either mechanism can switch a mod on;
-- a missing enabled.txt says nothing. The one real disagreement is a marker
-- present while mods.txt says 0, and which of those wins isn't known,
-- so that case is shown as "mixed" rather than guessed.
function core.state_of(hasMarker, listEntry)
    if hasMarker and listEntry and not listEntry.on then return "mixed" end
    if hasMarker or (listEntry and listEntry.on) then return "on" end
    return "off"
end

-- Versions mods announce in UE4SS.log, by the name in their tag. Mods print
-- their tag two ways: "[PartsManager] v1.1.1 loaded" and
-- "[SomeMod v2.3.1 RELEASE] ...". The last line per name
-- wins (the log is from this launch, newest at the bottom). Only a version
-- the mod printed right at its tag counts, so a number elsewhere in a
-- message is never taken for one.
function core.versions_from_log(text)
    local found = {}
    if type(text) ~= "string" then return found end
    for line in text:gmatch("[^\r\n]+") do
        -- "[Name vX..." inside the tag
        for name, ver in line:gmatch("%[([%w_%-]+) v(%d+[%w%.%-]*)[%] ]") do
            found[name] = ver
        end
        -- "[Name] vX" right after the tag
        for name, ver in line:gmatch("%[([%w_%-]+)%]%s+v(%d+[%w%.%-]*)") do
            found[name] = ver
        end
    end
    for name, ver in pairs(found) do
        if not core.clean_version(ver) then found[name] = nil end
    end
    return found
end

-- The GitHub issue-form address. Each value is encoded on its own; the
-- separators (? & =) are not, or GitHub silently opens the plain form
-- instead of the template. Every input is a source literal today; VERSION
-- is the one most likely to be read from a file one day, and then this needs
-- the same care as the explorer call.
function core.url_encode(v)
    return (tostring(v):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

function core.issue_url(base, template, name, version)
    return base .. "?" .. table.concat({ "template=" .. core.url_encode(template),
        "title=" .. core.url_encode("[" .. name .. "] "),
        "mod=" .. core.url_encode(name), "version=" .. core.url_encode(version) }, "&")
end

-- Replaces a Windows user name in text, matched without regard to case.
-- Only a backstop: the report must never contain an absolute path in the
-- first place. A one-letter name is left alone on purpose (it would eat that
-- letter everywhere); an 8.3 short name (like JOHNSM~1) is not caught.
function core.scrub(v, user)
    v = tostring(v or "")
    if type(user) ~= "string" or #user < 2 then return v end
    -- Letters become [aA] classes first; then the magic characters are
    -- escaped. "[" and "]" are not in that set, so the classes survive, and
    -- neither can appear in a Windows user name.
    local pat = user:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end)
    pat = pat:gsub("[%^%$%(%)%%%.%*%+%-%?]", "%%%0")
    return (v:gsub(pat, "<user>"))
end

-- Why a row gets no switch, or nil if it gets one. A folder with nothing
-- UE4SS can start and no enabled.txt gets none (switching it on would only log
-- "failed to start"); with an enabled.txt it keeps one, because switching it
-- off is what stops that error.
-- A mod switched by a mods.txt line is not changed by this mod (only
-- enabled.txt is), so it gets no switch either: a switch there could only fail.
function core.lock_reason(isBuiltin, isSelf, hasMarker, hasStartable, hasListEntry)
    if isBuiltin then return "built-in" end
    if isSelf then return "this mod" end
    if hasListEntry then return "set in mods.txt" end
    if not hasMarker and not hasStartable then return "no mod files" end
    return nil
end

core.BUILTINS = {
    CheatManagerEnablerMod = true, ConsoleCommandsMod = true, ConsoleEnablerMod = true,
    BPML_GenericFunctions = true, BPModLoaderMod = true, Keybinds = true,
    LineTraceMod = true, SplitScreenMod = true, jsbLuaProfilerMod = true, shared = true,
}

return core
