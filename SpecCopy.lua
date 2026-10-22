-- Soulstone - move your WoW 3.3.5a setup between characters, realms and servers.
-- Copyright (C) 2026 pabhoz - https://github.com/pabhoz/Soulstone-WoW-Addon
-- Licensed under the GNU General Public License v3.0 or later. See LICENSE.

-- Copy the bars of one spec onto the other. The client only knows the active
-- spec's bars, so Soulstone remembers each spec's bars on its own while you
-- play (SoulstoneDB.bars[Character-Realm][spec]) and uses that memory to copy.

local L = Soulstone.L
local Print = Soulstone.Print
local NUM_SLOTS = Soulstone.NUM_SLOTS

local SETTLE = 2 -- seconds without slot changes before remembering the bars
local SWITCH_SETTLE = 3 -- after a spec switch the new bars keep arriving for a moment

-- "Activate Primary Spec" / "Activate Secondary Spec": while one of these is
-- being cast the bars are about to change and must not be remembered.
local SWITCH_SPELLS = {}
for _, id in ipairs({ 63645, 63644 }) do
	local name = GetSpellInfo(id)
	if name then SWITCH_SPELLS[name] = true end
end

local function Memory()
	local key = Soulstone.CharKey()
	SoulstoneDB.bars[key] = SoulstoneDB.bars[key] or {}
	return SoulstoneDB.bars[key]
end

local function CountActions(actions)
	local n = 0
	for slot = 1, NUM_SLOTS do
		if actions[slot] then n = n + 1 end
	end
	return n
end

-- The remembered bars of `spec` for this character, or nil. Before the first
-- switch since installing this version, the character's own snapshot is used.
function Soulstone.RememberedBars(spec)
	local key = Soulstone.CharKey()
	local m = SoulstoneDB.bars[key]
	if m and m[spec] then return m[spec] end
	local snap = Soulstone.Snapshots()[key]
	local s = snap and snap.specs[spec]
	if s and s.actions then return { actions = s.actions, date = s.barsDate or s.date } end
end

local function ActiveIsEmpty()
	for slot = 1, NUM_SLOTS do
		if GetActionInfo(slot) then return false end
	end
	return true
end

---------------------------------------------------------------- copy

-- Places the remembered bars of `fromSpec` on the active spec. fillOnly keeps
-- every slot that already has something; otherwise the active spec ends up
-- identical to `fromSpec` (empty slots included). A backup is saved first.
function Soulstone.CopySpec(fromSpec, fillOnly)
	if InCombatLockdown() then Print(L["Not possible in combat."]) return end
	local active = GetActiveTalentGroup() or 1
	if (GetNumTalentGroups() or 1) < 2 then Print(L["This character has only one spec."]) return end
	if fromSpec == active then return end
	local source = Soulstone.RememberedBars(fromSpec)
	if not source then
		Print(L["Soulstone doesn't know the bars of spec %d yet: switch to it once and come back."]:format(fromSpec))
		return
	end
	local backup = Soulstone.Backup()
	local placed, kept, cleared, failed = 0, 0, 0, {}
	for slot = 1, NUM_SLOTS do
		local a = source.actions[slot]
		local occupied = GetActionInfo(slot) ~= nil
		ClearCursor()
		if fillOnly and occupied then
			kept = kept + 1
		elseif a then
			if Soulstone.PickupSaved(a) then
				PlaceAction(slot)
				placed = placed + 1
			else
				failed[#failed + 1] = ("slot %d: %s '%s'"):format(slot, a.type, tostring(a.name or a.id))
			end
		elseif occupied then
			PickupAction(slot)
			cleared = cleared + 1
		end
		ClearCursor()
	end
	if fillOnly then
		Print(L["Bars of spec %d copied onto spec %d: %d placed, %d slots you already had were kept."]:format(fromSpec, active, placed, kept))
	else
		Print(L["Bars of spec %d copied onto spec %d: %d placed, %d cleared."]:format(fromSpec, active, placed, cleared))
	end
	if #failed > 0 then
		-- usually talent spells this spec doesn't have
		Print(L["%d could not be placed (spells this spec doesn't know, or items you don't carry):"]:format(#failed))
		for _, f in ipairs(failed) do Print("  - " .. f) end
	end
	Print(L["Previous setup saved as '%s'."]:format(backup))
	return placed, failed
end

StaticPopupDialogs["SOULSTONE_COPY_SPEC"] = {
	text = "%s",
	button1 = L["Copy"],
	button2 = CANCEL,
	OnAccept = function(self, data)
		Soulstone.CopySpec(data.from, data.fillOnly)
		Soulstone.RefreshUI()
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

-- Asks before copying the other spec onto the active one.
function Soulstone.ConfirmCopySpec(fillOnly)
	local active = GetActiveTalentGroup() or 1
	local from = 3 - active
	local text
	if fillOnly then
		text = L["Copy the bars of spec %d onto spec %d?\n\nOnly the empty slots are filled: what you already placed stays. A backup is saved first."]:format(from, active)
	else
		text = L["Copy the bars of spec %d onto spec %d?\n\nSpec %d ends up identical to spec %d. A backup is saved first."]:format(from, active, active, from)
	end
	local dialog = StaticPopup_Show("SOULSTONE_COPY_SPEC", text)
	if dialog then dialog.data = { from = from, fillOnly = fillOnly } end
end

-- The other way round: this spec's bars onto the other spec. The client can
-- only change the active spec's bars, so Soulstone remembers these bars now,
-- switches spec (5 sec cast), pastes them and offers to switch back.
local pushing

function Soulstone.CopyToOtherSpec(fillOnly)
	if InCombatLockdown() then Print(L["Not possible in combat."]) return end
	if (GetNumTalentGroups() or 1) < 2 then Print(L["This character has only one spec."]) return end
	local from = GetActiveTalentGroup() or 1
	local to = 3 - from
	Memory()[from] = { actions = Soulstone.CaptureActions(), date = date("%Y-%m-%d %H:%M") }
	pushing = to -- no "your spec is empty" offer on arrival: we are about to fill it
	Soulstone.SwitchSpecThen(function()
		pushing = nil
		Soulstone.CopySpec(from, fillOnly)
	end, L["Spec switch was interrupted - nothing was copied."], L["Bars of spec %d copied onto spec %d."]:format(from, to))
end

StaticPopupDialogs["SOULSTONE_COPY_TO"] = {
	text = "%s",
	button1 = L["Copy"],
	button2 = CANCEL,
	OnAccept = function(self, fillOnly) Soulstone.CopyToOtherSpec(fillOnly) end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

-- Asks before copying the active spec onto the other one.
function Soulstone.ConfirmCopyToOtherSpec(fillOnly)
	local from = GetActiveTalentGroup() or 1
	local to = 3 - from
	local text
	if fillOnly then
		text = L["Copy the bars of spec %d onto spec %d?\n\nSoulstone switches to spec %d (5 sec cast, don't move), fills its empty slots and offers to switch back. A backup is saved first."]:format(from, to, to)
	else
		text = L["Copy the bars of spec %d onto spec %d?\n\nSoulstone switches to spec %d (5 sec cast, don't move), makes it identical to spec %d and offers to switch back. A backup is saved first."]:format(from, to, to, from)
	end
	local dialog = StaticPopup_Show("SOULSTONE_COPY_TO", text)
	if dialog then dialog.data = fillOnly end
end

-- The freshly bought second spec starts with empty bars: offer the other one.
StaticPopupDialogs["SOULSTONE_EMPTY_SPEC"] = {
	text = L["Your spec %d has empty action bars.\n\nCopy the bars of spec %d as a starting point? Then you only change what is different."],
	button1 = L["Copy"],
	button2 = L["Not now"],
	OnAccept = function(self, from)
		Soulstone.CopySpec(from, true)
		Soulstone.RefreshUI()
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

local offered = {}

local function OfferIfEmpty(active)
	if pushing == active then pushing = nil return end
	if offered[active] or (GetNumTalentGroups() or 1) < 2 or InCombatLockdown() then return end
	local from = 3 - active
	local source = Soulstone.RememberedBars(from)
	if not (source and CountActions(source.actions) > 0 and ActiveIsEmpty()) then return end
	offered[active] = true
	local dialog = StaticPopup_Show("SOULSTONE_EMPTY_SPEC", active, from)
	if dialog then dialog.data = from end
end

---------------------------------------------------------------- tracker

-- Remembers the active spec's bars a moment after they stop changing. The
-- spec is read when the change happens and checked again when saving: if a
-- spec switch happened in between, the half-changed bars are discarded.
local tracker = CreateFrame("Frame")
local dueAt, dueSpec, switching, holdUntil, offerSpec, fromLogin
tracker:Hide()

local function Remember()
	local spec = GetActiveTalentGroup() or 1
	local actions = Soulstone.CaptureActions()
	local old = Memory()[spec]
	-- right after logging in the bars may not have arrived yet: never forget a
	-- spec's bars because of that (clearing them by hand later is remembered)
	if fromLogin and CountActions(actions) == 0 and old and CountActions(old.actions) > 0 then return end
	Memory()[spec] = { actions = actions, date = date("%Y-%m-%d %H:%M") }
end

local function Schedule(delay)
	local spec = GetActiveTalentGroup() or 1
	if dueAt and dueSpec ~= spec then dueSpec = nil end -- bars from two specs mixed: start over
	dueSpec = dueSpec or spec
	dueAt = math.max(GetTime() + delay, holdUntil or 0)
	tracker:Show()
end

tracker:SetScript("OnUpdate", function(self)
	if not dueAt or GetTime() < dueAt or (switching and GetTime() < switching) then return end
	local spec = GetActiveTalentGroup() or 1
	local expected = dueSpec
	dueAt, dueSpec = nil, nil
	self:Hide()
	if expected ~= spec then Schedule(SETTLE) return end
	Remember()
	fromLogin = nil
	if offerSpec == spec then
		offerSpec = nil
		OfferIfEmpty(spec)
	end
end)

tracker:SetScript("OnEvent", function(self, event, unit, spell)
	if event == "ACTIONBAR_SLOT_CHANGED" then
		Schedule(SETTLE)
	elseif event == "PLAYER_ENTERING_WORLD" then
		fromLogin = true
		offerSpec = GetActiveTalentGroup() or 1
		Schedule(SWITCH_SETTLE)
	elseif event == "ACTIVE_TALENT_GROUP_CHANGED" then
		switching = nil
		holdUntil = GetTime() + SWITCH_SETTLE
		dueSpec = nil
		offerSpec = GetActiveTalentGroup() or 1
		Schedule(SWITCH_SETTLE)
	elseif event == "UNIT_SPELLCAST_START" then
		-- with a deadline, in case the cast ends without an event we listen to
		if unit == "player" and SWITCH_SPELLS[spell] then switching = GetTime() + 10 end
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
		if unit == "player" and SWITCH_SPELLS[spell] then switching = nil end
	end
end)

function Soulstone.StartBarTracker()
	for _, e in ipairs({ "ACTIONBAR_SLOT_CHANGED", "PLAYER_ENTERING_WORLD", "ACTIVE_TALENT_GROUP_CHANGED",
		"UNIT_SPELLCAST_START", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED" }) do
		tracker:RegisterEvent(e)
	end
end
