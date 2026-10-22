-- Soulstone spec copy tests: a simulated 3.3.5a client. Run from the addon folder: lua5.1 tests/speccopy.lua (tests/run.sh does it in Docker)
local now = 0
local frames = {}
local popups = {}
local chat = {}

local specs = { {}, {} }        -- action slots per spec
local active, numGroups = 1, 1
local cursor
local book = { "Fireball", "Frostbolt", "Arcane Missiles", "Blink" } -- spec 2 lacks "Pyroblast"

function GetTime() return now end
function GetLocale() return "enUS" end
function UnitName() return "Tester" end
function GetRealmName() return "Stormrage" end
function UnitClass() return "Mage", "MAGE" end
function date() return "2026-10-21 12:00" end
function InCombatLockdown() return false end
function GetActiveTalentGroup() return active end
function GetNumTalentGroups() return numGroups end
function GetNumTalentTabs() return 0 end
function GetGlyphSocketInfo() end
function GetTalentInfo() end
function GetSpellInfo(id) if id == 63644 then return "Activate Secondary Spec" elseif id == 63645 then return "Activate Primary Spec" end end
BOOKTYPE_SPELL = "spell"
function GetSpellName(i) if type(i) == "string" then return i, "" end return book[i], "" end
function GetActionInfo(slot)
	local a = specs[active][slot]
	if a then return "spell", a, "spell" end
end
function GetActionTexture() return "icon" end
function GetNumMacros() return 0, 0 end
function GetNumBindings() return 0 end
function GetBindingKey() end
function ClearCursor() cursor = nil end
function GetCursorInfo() return cursor end
function PickupSpell(i) cursor = book[i] end
function PickupAction(slot) cursor = specs[active][slot]; specs[active][slot] = nil end
function PlaceAction(slot) specs[active][slot] = cursor; cursor = nil end
function GetMacroIndexByName() return 0 end
function strtrim(s) return s end
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) chat[#chat + 1] = m end }
StaticPopupDialogs = {}
function StaticPopup_Show(name, ...) local d = { name = name, args = { ... } }; popups[#popups + 1] = d; return d end
SLASH_SOULSTONE1 = nil
SlashCmdList = {}
YES, NO, CANCEL, SAVE = "Yes", "No", "Cancel", "Save"
LOCALIZED_CLASS_NAMES_MALE = {}

function CreateFrame()
	local f = { scripts = {}, events = {}, shown = true }
	function f:SetScript(k, fn) self.scripts[k] = fn end
	function f:RegisterEvent(e) self.events[e] = true end
	function f:UnregisterEvent(e) self.events[e] = nil end
	function f:UnregisterAllEvents() self.events = {} end
	function f:Hide() self.shown = false end
	function f:Show() self.shown = true end
	frames[#frames + 1] = f
	return f
end

local function fire(event, ...)
	for _, f in ipairs(frames) do
		if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
	end
end
local function tick(seconds)
	local target = now + seconds
	while now < target do
		now = now + 0.1
		for _, f in ipairs(frames) do
			if f.shown and f.scripts.OnUpdate then f.scripts.OnUpdate(f, 0.1) end
		end
	end
end

for _, file in ipairs({ "Locales.lua", "Core.lua", "SpecCopy.lua", "Talents.lua" }) do dofile(file) end
Soulstone.CreateLauncher = function() end
Soulstone.RefreshUI = function() end
fire("ADDON_LOADED", "Soulstone")

local function check(cond, msg) if not cond then error("FAIL: " .. msg .. "\n" .. table.concat(chat, "\n"), 2) end print("ok  " .. msg) end

-- 1. login on spec 1 with bars
specs[1] = { [1] = "Fireball", [2] = "Frostbolt", [3] = "Pyroblast", [13] = "Blink" }
fire("PLAYER_ENTERING_WORLD")
tick(4)
local mem = SoulstoneDB.bars["Tester-Stormrage"]
check(mem and mem[1] and mem[1].actions[1].name == "Fireball", "spec 1 remembered after login")
check(#popups == 0, "no popup with a single spec")

-- 2. buy dual spec and switch: bars change while casting, then the group changes
numGroups = 2
fire("UNIT_SPELLCAST_START", "player", "Activate Secondary Spec")
active = 2 -- the client swaps bars slightly before the event
fire("ACTIONBAR_SLOT_CHANGED", 1)
tick(2.5)
check(mem[1].actions[1].name == "Fireball", "spec 1 memory not overwritten mid-switch")
fire("ACTIVE_TALENT_GROUP_CHANGED", 2, 1)
tick(4)
check(mem[2] and not mem[2].actions[1], "spec 2 remembered empty")
check(#popups == 1 and popups[1].name == "SOULSTONE_EMPTY_SPEC" and popups[1].data == 1, "offers copying spec 1 onto empty spec 2")

-- 3. fill only, with one slot already placed by hand
specs[2][2] = "Arcane Missiles"
local placed, failed = Soulstone.CopySpec(1, true)
check(specs[2][1] == "Fireball" and specs[2][13] == "Blink", "fill copies the empty slots")
check(specs[2][2] == "Arcane Missiles", "fill keeps what was already placed")
check(#failed == 1 and failed[1]:find("Pyroblast"), "unknown talent spell is reported")
check(SoulstoneDB.snapshots["backup-Tester-Stormrage"] ~= nil, "backup saved before copying")

-- 4. replace all
specs[2][50] = "Frostbolt"
Soulstone.CopySpec(1, false)
check(specs[2][2] == "Frostbolt" and specs[2][50] == nil, "replace makes spec 2 identical (extra slot cleared)")

-- 5. spec 2 memory follows the copy, spec 1 untouched; no second popup
fire("ACTIONBAR_SLOT_CHANGED", 1)
tick(3)
check(mem[2].actions[1].name == "Fireball" and mem[1].actions[3].name == "Pyroblast", "memories updated per spec")
check(#popups == 1, "popup offered once")

-- 6. a fresh login with bars not loaded yet doesn't wipe the memory
local saved = specs[2]; specs[2] = {}
fire("PLAYER_ENTERING_WORLD")
tick(4)
check(mem[2].actions[1] and mem[2].actions[1].name == "Fireball", "login with empty bars keeps the memory")
specs[2] = saved
-- 7. the other way round: from spec 1, paste its bars onto spec 2 (switches spec)
function SetActiveTalentGroup(g)
	fire("UNIT_SPELLCAST_START", "player", "Activate Primary Spec")
	active = g
	fire("ACTIONBAR_SLOT_CHANGED", 1)
	fire("ACTIVE_TALENT_GROUP_CHANGED", g, 3 - g)
end
SetActiveTalentGroup(1)
tick(4)
specs[1][5] = "Frostbolt" -- something new in spec 1 that spec 2 doesn't have yet
specs[2] = { [1] = "Arcane Missiles" }
local shown = #popups
Soulstone.CopyToOtherSpec(true)
check(active == 2, "copy-to switches to the other spec")
tick(3)
check(specs[2][5] == "Frostbolt" and specs[2][1] == "Arcane Missiles", "this spec's bars pasted onto the other, keeping what it had")
local last = popups[#popups]
check(last.name == "SOULSTONE_SWITCH_BACK" and last.data == 1, "offers to switch back to spec 1")
for i = shown + 1, #popups do check(popups[i].name ~= "SOULSTONE_EMPTY_SPEC", "no empty-spec offer while pasting") end
print("all passed")
