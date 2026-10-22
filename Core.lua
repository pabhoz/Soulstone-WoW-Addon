-- Soulstone - move your WoW 3.3.5a setup between characters, realms and servers.
-- Copyright (C) 2026 pabhoz - https://github.com/pabhoz/Soulstone-WoW-Addon
-- Licensed under the GNU General Public License v3.0 or later. See LICENSE.

-- Capture and restore logic. Snapshots live in SoulstoneDB.snapshots (account-wide),
-- so they can be shared between any characters/realms/servers using the same
-- WTF/Account folder.

local L = Soulstone.L

local NUM_SLOTS = 120
local MAX_CHAR_MACROS = 18
local MAX_ACCOUNT_MACROS = 36
local BACKUP_PREFIX = "backup-"

Soulstone.NUM_SLOTS = NUM_SLOTS
Soulstone.BACKUP_PREFIX = BACKUP_PREFIX

function Soulstone.Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffSoulstone|r: " .. msg)
end
local Print = Soulstone.Print

-- Runs fn on the next frame (e.g. to open a popup after another one closed).
local afterFrame, afterQueue = CreateFrame("Frame"), {}
afterFrame:Hide()
afterFrame:SetScript("OnUpdate", function(self)
	self:Hide()
	local list = afterQueue
	afterQueue = {}
	for _, fn in ipairs(list) do fn() end
end)
function Soulstone.After(fn)
	afterQueue[#afterQueue + 1] = fn
	afterFrame:Show()
end

function Soulstone.CharKey()
	return UnitName("player") .. "-" .. GetRealmName()
end

function Soulstone.IsBackup(name)
	return name:sub(1, #BACKUP_PREFIX) == BACKUP_PREFIX
end

---------------------------------------------------------------- database

local function InitDB()
	SoulstoneDB = SoulstoneDB or {}
	if not SoulstoneDB.snapshots then
		-- v0 stored snapshots directly at the top level
		local old = SoulstoneDB
		SoulstoneDB = { snapshots = {} }
		for k, v in pairs(old) do
			if type(v) == "table" and v.actions then SoulstoneDB.snapshots[k] = v end
		end
	end
	-- v1 had a single action list (the spec that was active when saving)
	for _, snap in pairs(SoulstoneDB.snapshots) do
		if not snap.specs then
			snap.specs = { [1] = { actions = snap.actions } }
			snap.actions = nil
		end
	end
	SoulstoneDB.minimap = SoulstoneDB.minimap or { angle = 200, hide = false }
	SoulstoneDB.options = SoulstoneDB.options or { actions = true, macros = true, bindings = true, clearEmpty = true }
	if SoulstoneDB.options.talents == nil then SoulstoneDB.options.talents = true end
	if SoulstoneDB.options.copyFillOnly == nil then SoulstoneDB.options.copyFillOnly = true end
	SoulstoneDB.bars = SoulstoneDB.bars or {}
	SoulstoneDB.templates = SoulstoneDB.templates or {}
	-- snapshots saved before templates existed also show up in the Talents tab
	for name, snap in pairs(SoulstoneDB.snapshots) do
		for spec in pairs(snap.specs) do Soulstone.SyncTemplate(name, snap, spec, true) end
	end
end

function Soulstone.Snapshots()
	return SoulstoneDB.snapshots
end

function Soulstone.SortedNames()
	local names = {}
	for k in pairs(SoulstoneDB.snapshots) do names[#names + 1] = k end
	table.sort(names, function(a, b)
		local ba, bb = Soulstone.IsBackup(a), Soulstone.IsBackup(b)
		if ba ~= bb then return bb end
		return a:lower() < b:lower()
	end)
	return names
end

function Soulstone.Find(name)
	if not name then return end
	if SoulstoneDB.snapshots[name] then return name end
	local lname = name:lower()
	for k in pairs(SoulstoneDB.snapshots) do
		if k:lower() == lname then return k end
	end
end

function Soulstone.Count(snap, spec)
	local actions, binds = 0, 0
	local s = spec and snap.specs[spec]
	if s and s.actions then
		for slot = 1, NUM_SLOTS do
			if s.actions[slot] then actions = actions + 1 end
		end
	end
	for _, keys in pairs(snap.bindings or {}) do binds = binds + #keys end
	return actions, #(snap.macros or {}), binds
end

-- Talents/glyphs are saved for both specs, bars only for specs that were active at some save.
function Soulstone.HasBars(snap, spec)
	return snap.specs[spec] and snap.specs[spec].actions ~= nil
end

-- Spec to show/restore by default: the active one if it has bars, else any with bars.
function Soulstone.DefaultSpec(snap)
	local active = GetActiveTalentGroup() or 1
	if Soulstone.HasBars(snap, active) then return active end
	for i = 1, 2 do
		if Soulstone.HasBars(snap, i) then return i end
	end
	for i = 1, 2 do
		if snap.specs[i] then return i end
	end
end

function Soulstone.SpecLabel(snap, spec)
	local s = snap.specs[spec]
	local label = L["Spec %d"]:format(spec)
	if s and s.talents then label = label .. ": " .. s.talents end
	return label
end

-- Compact label for the spec buttons: "1: Retribution"
function Soulstone.SpecShortLabel(snap, spec)
	local s = snap.specs[spec]
	local tree = s and s.talents and (s.talents:match("^(.-)%s+[%d/]+$") or s.talents)
	return spec .. ": " .. (tree or L["Spec %d"]:format(spec))
end

---------------------------------------------------------------- capture

local function CaptureActions()
	local actions = {}
	for slot = 1, NUM_SLOTS do
		local kind, id, subType, spellID = GetActionInfo(slot)
		local a
		if kind == "spell" then
			local name, rank
			if spellID then name, rank = GetSpellInfo(spellID) end
			if not name then name, rank = GetSpellName(id, subType or BOOKTYPE_SPELL) end
			if name then a = { type = "spell", name = name, rank = rank, spellID = spellID } end
		elseif kind == "item" then
			a = { type = "item", id = id, name = GetItemInfo(id) }
		elseif kind == "macro" then
			local name, _, body = GetMacroInfo(id)
			if name then a = { type = "macro", name = name, body = body } end
		elseif kind == "companion" then
			local _, cname, cspell = GetCompanionInfo(subType, id)
			if cspell then a = { type = "companion", sub = subType, spellID = cspell, name = cname } end
		elseif kind == "equipmentset" then
			a = { type = "equipmentset", name = id }
		end
		if a then a.icon = GetActionTexture(slot) end
		actions[slot] = a or false
	end
	return actions
end
Soulstone.CaptureActions = CaptureActions

local function CaptureMacros()
	local macros = {}
	local _, numChar = GetNumMacros()
	for i = MAX_ACCOUNT_MACROS + 1, MAX_ACCOUNT_MACROS + numChar do
		local name, texture, body = GetMacroInfo(i)
		if name then macros[#macros + 1] = { name = name, texture = texture, body = body } end
	end
	return macros
end

-- Bindable commands: everything in Bindings.xml plus Bartender4's CLICK bindings
local function BindingCommands()
	local cmds = {}
	for i = 1, GetNumBindings() do
		local cmd = GetBinding(i)
		if cmd then cmds[#cmds + 1] = cmd end
	end
	for n = 1, NUM_SLOTS do
		cmds[#cmds + 1] = "CLICK BT4Button" .. n .. ":LeftButton"
	end
	return cmds
end

local function CaptureBindings()
	local binds = {}
	for _, cmd in ipairs(BindingCommands()) do
		local keys = { GetBindingKey(cmd) }
		if #keys > 0 then binds[cmd] = keys end
	end
	return binds
end

-- e.g. "Holy 51/5/15"
local function TalentSummary(group)
	local points, mainName, mainPoints = {}, nil, -1
	for tab = 1, GetNumTalentTabs() do
		local name, _, spent = GetTalentTabInfo(tab, false, false, group)
		spent = spent or 0
		points[#points + 1] = spent
		if spent > mainPoints then mainName, mainPoints = name, spent end
	end
	if mainPoints <= 0 then return end
	return mainName .. " " .. table.concat(points, "/")
end

-- Talents and glyphs can be read for every spec; action bars only for the
-- active one (the client doesn't have the other spec's bars).
local function Capture()
	local _, class = UnitClass("player")
	local active = GetActiveTalentGroup() or 1
	local now = date("%Y-%m-%d %H:%M")
	local specs = {}
	for group = 1, (GetNumTalentGroups() or 1) do
		specs[group] = {
			talents = TalentSummary(group),
			build = Soulstone.CaptureTalentString(group),
			glyphs = Soulstone.CaptureGlyphs(group),
			date = now,
		}
	end
	specs[active].actions = CaptureActions()
	specs[active].barsDate = now
	return {
		version = 3,
		char = Soulstone.CharKey(),
		class = class,
		date = now,
		numSpecs = GetNumTalentGroups() or 1,
		specs = specs,
		macros = CaptureMacros(),
		bindings = CaptureBindings(),
	}, active
end

-- Saves into `name`. If `name` already holds a snapshot of this same
-- character, the inactive spec keeps its previously saved bars.
local function Store(name)
	local snap, active = Capture()
	local old = SoulstoneDB.snapshots[name]
	if old and old.char == snap.char and old.specs then
		for s, data in pairs(old.specs) do
			if s ~= active and data.actions then
				snap.specs[s] = snap.specs[s] or {}
				snap.specs[s].actions = data.actions
				snap.specs[s].barsDate = data.barsDate or data.date
			end
		end
	end
	SoulstoneDB.snapshots[name] = snap
	return snap, active
end

-- Saves the current setup as this character's backup snapshot (before changing the bars).
function Soulstone.Backup()
	local backup = BACKUP_PREFIX .. Soulstone.CharKey()
	Store(backup)
	return backup
end

function Soulstone.Save(name)
	name = name and strtrim(name) or ""
	if name == "" then name = Soulstone.CharKey() end
	local snap, spec = Store(name)
	local actions, macros = Soulstone.Count(snap, spec)
	Print(L["Saved '%s' (%s): %d actions, %d character macros."]:format(name, Soulstone.SpecLabel(snap, spec), actions, macros)
		.. " " .. L["It is written to disk on /reload or logout."])
	for group in pairs(snap.specs) do
		local tplName = Soulstone.SyncTemplate(name, snap, group)
		if tplName then Print(L["Talents also saved as template '%s' (Talents tab)."]:format(tplName)) end
	end
	return name, snap
end

---------------------------------------------------------------- dual spec

-- The inactive spec's bars only exist on the server, so to save or restore
-- them we switch spec (5s cast), wait for the server to send that spec's bars,
-- run the action, and offer to switch back. Must start from a click (spec
-- switching needs a hardware event).
local switch = CreateFrame("Frame")
local pending

local function FinishSwitch(msg)
	switch:UnregisterAllEvents()
	switch:SetScript("OnUpdate", nil)
	if msg then Print("|cffff5555" .. msg .. "|r") end
	local p = pending
	pending = nil
	return p
end

switch:SetScript("OnEvent", function(self, event, arg1)
	if not pending then return end
	if event == "ACTIVE_TALENT_GROUP_CHANGED" then
		-- bars arrive right after the switch: wait until they stop changing
		pending.settleAt = GetTime() + 1.5
		pending.deadline = GetTime() + 6
	elseif event == "ACTIONBAR_SLOT_CHANGED" and pending.settleAt then
		pending.settleAt = math.min(math.max(pending.settleAt, GetTime() + 0.5), pending.deadline)
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" and arg1 == "player" and not pending.settleAt then
		FinishSwitch(pending.failMsg)
	end
end)

local function SwitchOnUpdate()
	if not pending then return end
	local now = GetTime()
	if not pending.settleAt then
		if now > pending.timeout then FinishSwitch(pending.failMsg) end
		return
	end
	if now < pending.settleAt then return end
	local p = FinishSwitch()
	p.action()
	Soulstone.RefreshUI()
	local dialog = StaticPopup_Show("SOULSTONE_SWITCH_BACK", p.doneText, p.back)
	if dialog then dialog.data = p.back end
end

StaticPopupDialogs["SOULSTONE_SWITCH_BACK"] = {
	text = L["%s\n\nSwitch back to spec %d?"],
	button1 = YES,
	button2 = NO,
	OnAccept = function(self, group) SetActiveTalentGroup(group) end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

local function SwitchSpecThen(action, failMsg, doneText)
	if pending then Print(L["Already switching spec, wait a moment."]) return end
	if InCombatLockdown() then Print(L["Not possible in combat."]) return end
	local active = GetActiveTalentGroup() or 1
	pending = { back = active, timeout = GetTime() + 12, action = action, failMsg = failMsg, doneText = doneText }
	switch:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
	switch:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
	switch:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
	switch:SetScript("OnUpdate", SwitchOnUpdate)
	Print(L["Switching to spec %d (5 sec cast, don't move)..."]:format(3 - active))
	SetActiveTalentGroup(3 - active)
end

-- True if this character has a second spec to switch to.
function Soulstone.CanCaptureOtherSpec()
	return (GetNumTalentGroups() or 1) > 1
end

-- Saves the other spec's bars into snapshot `name`.
function Soulstone.CaptureOtherSpec(name)
	if not Soulstone.CanCaptureOtherSpec() then return end
	SwitchSpecThen(function()
		Soulstone.Save(name)
		Print(L["Both specs saved in '%s'."]:format(name))
	end, L["Spec switch was interrupted - the other spec's bars were not saved."], L["Both specs saved."])
end

-- Restores the bars (and talents) of snapshot spec `fromSpec` onto the other
-- spec of this character. Macros and keybindings are per character, so they
-- were already handled by the first restore.
function Soulstone.RestoreOtherSpec(name, fromSpec)
	if not Soulstone.CanCaptureOtherSpec() then return end
	SwitchSpecThen(function()
		local opts = {}
		for k, v in pairs(SoulstoneDB.options) do opts[k] = v end
		opts.macros, opts.bindings = false, false
		Soulstone.Restore(name, opts, fromSpec)
	end, L["Spec switch was interrupted - the other spec was not restored."], L["Both specs restored."])
end

-- The other snapshot spec to offer after restoring `fromSpec`, if it has bars.
function Soulstone.OtherRestorableSpec(name, fromSpec)
	local key = Soulstone.Find(name)
	local snap = key and SoulstoneDB.snapshots[key]
	if not (snap and fromSpec and Soulstone.CanCaptureOtherSpec() and SoulstoneDB.options.actions) then return end
	local other = 3 - fromSpec
	if Soulstone.HasBars(snap, other) then return other, snap end
end

---------------------------------------------------------------- restore

local function FindIcon(texture)
	if texture then
		local want = texture:lower()
		for i = 1, GetNumMacroIcons() do
			local t = GetMacroIconInfo(i)
			if t and t:lower() == want then return i end
		end
	end
	return 1 -- question mark
end

local function RestoreMacros(snap, report)
	for _, m in ipairs(snap.macros or {}) do
		if GetMacroIndexByName(m.name) == 0 then
			local _, numChar = GetNumMacros()
			if numChar >= MAX_CHAR_MACROS then
				report.failed[#report.failed + 1] = "macro '" .. m.name .. "' (" .. L["character macro limit reached"] .. ")"
			else
				CreateMacro(m.name, FindIcon(m.texture), m.body, 1)
				report.macrosCreated = report.macrosCreated + 1
			end
		else
			report.macrosSkipped = report.macrosSkipped + 1
		end
	end
end

local function FindSpellbookIndex(name, rank)
	local best
	local i = 1
	while true do
		local n, r = GetSpellName(i, BOOKTYPE_SPELL)
		if not n then break end
		if n == name then
			if rank and rank ~= "" and r == rank then return i end
			best = i -- the last match is the highest rank
		end
		i = i + 1
	end
	return best
end

local function PickupSaved(a)
	if a.type == "spell" then
		local idx = FindSpellbookIndex(a.name, a.rank)
		if idx then PickupSpell(idx, BOOKTYPE_SPELL) end
	elseif a.type == "item" then
		PickupItem(a.id)
	elseif a.type == "macro" then
		local idx = GetMacroIndexByName(a.name)
		if idx > 0 then PickupMacro(idx) end
	elseif a.type == "companion" then
		for i = 1, GetNumCompanions(a.sub) do
			local _, _, spellID = GetCompanionInfo(a.sub, i)
			if spellID == a.spellID then PickupCompanion(a.sub, i) break end
		end
	elseif a.type == "equipmentset" then
		PickupEquipmentSetByName(a.name)
	end
	return GetCursorInfo() ~= nil
end
Soulstone.PickupSaved = PickupSaved

local function RestoreActions(actions, opts, report)
	for slot = 1, NUM_SLOTS do
		local a = actions[slot]
		ClearCursor()
		if a then
			if PickupSaved(a) then
				PlaceAction(slot)
				report.placed = report.placed + 1
			else
				report.failed[#report.failed + 1] = ("slot %d: %s '%s'"):format(slot, a.type, tostring(a.name or a.id))
			end
		elseif opts.clearEmpty and GetActionInfo(slot) then
			PickupAction(slot)
		end
		ClearCursor()
	end
end

local function RestoreBindings(snap)
	for _, cmd in ipairs(BindingCommands()) do
		for _, key in ipairs({ GetBindingKey(cmd) }) do SetBinding(key) end
	end
	for cmd, keys in pairs(snap.bindings or {}) do
		for _, key in ipairs(keys) do SetBinding(key, cmd) end
	end
	SaveBindings(2) -- CHARACTER_BINDINGS: this character only
end

-- Restores the bars of `fromSpec` (default: Soulstone.DefaultSpec) onto the
-- currently active spec. Returns the report table, or nil if nothing was done.
function Soulstone.Restore(name, opts, fromSpec)
	opts = opts or SoulstoneDB.options
	if InCombatLockdown() then Print(L["Not possible in combat."]) return end
	local key = Soulstone.Find(name)
	if not key then Print(L["No snapshot named '%s'."]:format(tostring(name))) return end
	local snap = SoulstoneDB.snapshots[key]
	fromSpec = fromSpec or Soulstone.DefaultSpec(snap)
	local source = fromSpec and snap.specs[fromSpec]
	if not source then Print(L["No snapshot named '%s'."]:format(key)) return end
	local doBars = opts.actions and source.actions
	if opts.actions and not doBars then Print(L["'%s' has no saved bars for spec %d."]:format(key, fromSpec)) end
	local active = GetActiveTalentGroup() or 1

	local _, class = UnitClass("player")
	if snap.class and snap.class ~= class then
		Print("|cffff5555" .. L["Warning: snapshot is from a %s, this character is a %s."]:format(
			LOCALIZED_CLASS_NAMES_MALE[snap.class] or snap.class, LOCALIZED_CLASS_NAMES_MALE[class] or class) .. "|r")
	end

	local backup = BACKUP_PREFIX .. Soulstone.CharKey()
	if key ~= backup then Store(backup) end

	local report = { placed = 0, macrosCreated = 0, macrosSkipped = 0, failed = {} }
	if opts.macros then RestoreMacros(snap, report) end
	if doBars then RestoreActions(source.actions, opts, report) end
	if opts.bindings then RestoreBindings(snap) end
	if opts.talents and source and source.build and source.build ~= "" then
		Soulstone.ApplyTalents(source.build, snap.class)
		local glyphs = Soulstone.GlyphText(source.glyphs)
		if glyphs then Print(L["Glyphs of this build (apply them manually):"] .. " " .. glyphs) end
	end

	Print(L["Restored '%s': %d actions placed, %d macros created, %d macros already existed (untouched)."]:format(
		key, report.placed, report.macrosCreated, report.macrosSkipped))
	if doBars then
		Print(L["Bars from %s applied to your active spec (%d)."]:format(Soulstone.SpecLabel(snap, fromSpec), active))
	end
	if opts.bindings then Print(L["Keybindings applied."]) end
	if #report.failed > 0 then
		Print(L["%d items could not be restored:"]:format(#report.failed))
		for _, f in ipairs(report.failed) do Print("  - " .. f) end
	end
	if key ~= backup then Print(L["Previous setup saved as '%s'."]:format(backup)) end
	return report
end

function Soulstone.Delete(name)
	local key = Soulstone.Find(name)
	if not key then Print(L["No snapshot named '%s'."]:format(tostring(name))) return end
	SoulstoneDB.snapshots[key] = nil
	Print(L["Deleted '%s'."]:format(key))
	return key
end

---------------------------------------------------------------- slash command

SLASH_SOULSTONE1 = "/soulstone"
SLASH_SOULSTONE2 = "/sstone"
SlashCmdList.SOULSTONE = function(msg)
	local cmd, arg = msg:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	if arg == "" then arg = nil end

	if cmd == "" then
		Soulstone.ToggleUI()
	elseif cmd == "copy" then
		-- /soulstone copy [fill|all]: the other spec's bars onto the active spec
		local fillOnly = SoulstoneDB.options.copyFillOnly
		if arg == "fill" then fillOnly = true elseif arg == "all" then fillOnly = false end
		Soulstone.CopySpec(3 - (GetActiveTalentGroup() or 1), fillOnly)
		Soulstone.RefreshUI()
	elseif cmd == "save" then
		Soulstone.Save(arg)
		Soulstone.RefreshUI()
	elseif cmd == "saveboth" then
		local name = Soulstone.Save(arg)
		Soulstone.RefreshUI()
		Soulstone.CaptureOtherSpec(name)
	elseif cmd == "load" and arg then
		-- optional trailing spec number: /soulstone load Name-Realm 2
		local name, spec = arg:match("^(.-)%s+([12])$")
		if name and Soulstone.Find(name) then
			Soulstone.Restore(name, nil, tonumber(spec))
		else
			Soulstone.Restore(arg)
		end
		Soulstone.RefreshUI()
	elseif cmd == "loadboth" and arg then
		local key = Soulstone.Find(arg)
		local snap = key and SoulstoneDB.snapshots[key]
		local fromSpec = snap and Soulstone.DefaultSpec(snap)
		if Soulstone.Restore(arg, nil, fromSpec) then
			Soulstone.RefreshUI()
			if Soulstone.OtherRestorableSpec(key, fromSpec) then Soulstone.RestoreOtherSpec(key, 3 - fromSpec) end
		end
	elseif cmd == "delete" and arg then
		Soulstone.Delete(arg)
		Soulstone.RefreshUI()
	elseif cmd == "list" then
		local names = Soulstone.SortedNames()
		if #names == 0 then Print(L["No snapshots yet."]) end
		for _, k in ipairs(names) do
			local s = SoulstoneDB.snapshots[k]
			Print(("%s  [%s, %s]"):format(k, s.class or "?", s.date or "?"))
		end
	elseif cmd == "minimap" then
		SoulstoneDB.minimap.hide = not SoulstoneDB.minimap.hide
		Soulstone.UpdateMinimapButton()
	else
		Print(L["Commands:"])
		Print("  /soulstone - " .. L["open the window"])
		Print("  /soulstone save [name] - " .. L["save a snapshot (default name: Character-Realm)"])
		Print("  /soulstone saveboth [name] - " .. L["save, switch spec, save the other spec's bars"])
		Print("  /soulstone load <name> [1|2] - " .. L["restore a snapshot onto this character"])
		Print("  /soulstone loadboth <name> - " .. L["restore both specs (switches spec)"])
		Print("  /soulstone copy [fill|all] - " .. L["copy the other spec's bars onto this spec"])
		Print("  /soulstone list | delete <name> - " .. L["list / delete snapshots"])
		Print("  /soulstone minimap - " .. L["show / hide the minimap button"])
	end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, _, addon)
	if addon == "Soulstone" then
		InitDB()
		Soulstone.CreateMinimapButton()
		Soulstone.StartBarTracker()
		self:UnregisterEvent("ADDON_LOADED")
	end
end)
