-- Soulstone - move your WoW 3.3.5a setup between characters, realms and servers.
-- Copyright (C) 2026 pabhoz - https://github.com/pabhoz/Soulstone-WoW-Addon
-- Licensed under the GNU General Public License v3.0 or later. See LICENSE.

local L = Soulstone.L

local ROWS = 18
local ROW_HEIGHT = 20
local GRID_COLS, GRID_ROWS, CELL = 12, 10, 22
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

local frame, rows, cells, scroll
local selected, viewSpec

---------------------------------------------------------------- popups

StaticPopupDialogs["SOULSTONE_OTHER_SPEC"] = {
	text = L["Save the bars of your other spec too?\n\nSoulstone will switch to spec %d (5 sec cast, don't move), save its bars and then offer to switch back."],
	button1 = YES,
	button2 = L["Not now"],
	OnAccept = function(self, name) Soulstone.CaptureOtherSpec(name) end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

local function SaveAndOfferOtherSpec(text)
	selected = Soulstone.Save(text)
	viewSpec = nil
	Soulstone.RefreshUI()
	if Soulstone.CanCaptureOtherSpec() then
		local name = selected
		Soulstone.After(function()
			local dialog = StaticPopup_Show("SOULSTONE_OTHER_SPEC", 3 - (GetActiveTalentGroup() or 1))
			if dialog then dialog.data = name end
		end)
	end
end

StaticPopupDialogs["SOULSTONE_SAVE"] = {
	text = L["Snapshot name:"],
	button1 = SAVE,
	button2 = CANCEL,
	hasEditBox = 1,
	maxLetters = 64,
	OnShow = function(self)
		local eb = self.editBox or _G[self:GetName() .. "EditBox"]
		eb:SetText(Soulstone.CharKey())
		eb:HighlightText()
		eb:SetFocus()
	end,
	OnAccept = function(self)
		local eb = self.editBox or _G[self:GetName() .. "EditBox"]
		SaveAndOfferOtherSpec(eb:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		local parent = self:GetParent()
		SaveAndOfferOtherSpec(self:GetText())
		parent:Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["SOULSTONE_RESTORE"] = {
	text = L["Restore '%s' onto this character?\n\nBars from %s go to your active spec. A backup of your current setup is saved first."],
	button1 = L["Restore"],
	button2 = CANCEL,
	OnAccept = function(self, data)
		local report = Soulstone.Restore(data.name, nil, data.spec)
		if report then
			local msg = L["Last result"] .. ": " .. report.placed .. " OK"
			if #report.failed > 0 then msg = msg .. ", |cffff5555" .. L["%d failed - see chat"]:format(#report.failed) .. "|r" end
			frame.status:SetText(msg)
			local other, snap = Soulstone.OtherRestorableSpec(data.name, data.spec)
			if other then
				Soulstone.After(function()
					local dialog = StaticPopup_Show("SOULSTONE_RESTORE_OTHER", Soulstone.SpecLabel(snap, other), 3 - (GetActiveTalentGroup() or 1))
					if dialog then dialog.data = { name = data.name, spec = other } end
				end)
			end
		end
		Soulstone.RefreshUI()
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
}

StaticPopupDialogs["SOULSTONE_RESTORE_OTHER"] = {
	text = L["Restore %s onto your other spec too?\n\nSoulstone will switch to spec %d (5 sec cast, don't move), restore its bars and talents and then offer to switch back."],
	button1 = YES,
	button2 = L["Not now"],
	OnAccept = function(self, data) Soulstone.RestoreOtherSpec(data.name, data.spec) end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["SOULSTONE_DELETE"] = {
	text = L["Delete snapshot '%s'?"],
	button1 = L["Delete"],
	button2 = CANCEL,
	OnAccept = function(self, name)
		Soulstone.Delete(name)
		selected = nil
		Soulstone.RefreshUI()
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

---------------------------------------------------------------- refresh

local function ClassColor(class)
	local c = class and RAID_CLASS_COLORS[class]
	if c then return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255) end
	return "|cffffffff"
end

local function UpdateList()
	local names = Soulstone.SortedNames()
	local offset = FauxScrollFrame_GetOffset(scroll)
	FauxScrollFrame_Update(scroll, #names, ROWS, ROW_HEIGHT)
	for i = 1, ROWS do
		local row = rows[i]
		local name = names[i + offset]
		if name then
			local snap = Soulstone.Snapshots()[name]
			row.name = name
			if Soulstone.IsBackup(name) then
				row.text:SetText("|cff808080" .. name .. "|r")
			else
				row.text:SetText(ClassColor(snap.class) .. name .. "|r")
			end
			if name == selected then row.sel:Show() else row.sel:Hide() end
			row:Show()
		else
			row:Hide()
		end
	end
	if #names == 0 then frame.empty:Show() else frame.empty:Hide() end -- no SetShown in 3.3.5
end

local function UpdateDetails()
	local snap = selected and Soulstone.Snapshots()[selected]
	if not snap then
		selected = nil
		frame.title2:SetText("")
		frame.info:SetText(L["Select a snapshot on the left, or save this character first."])
		frame.counts:SetText("")
		for _, cell in ipairs(cells) do cell:Hide() end
		for _, tab in ipairs(frame.specTabs) do tab:Hide() end
		frame.restore:Disable()
		frame.delete:Disable()
		return
	end
	local className = snap.class and (LOCALIZED_CLASS_NAMES_MALE[snap.class] or snap.class) or "?"
	frame.title2:SetText(selected)
	frame.info:SetText(ClassColor(snap.class) .. className .. "|r  |  " .. (snap.char or "?") .. "  |  " .. (snap.date or "?"))
	if not (viewSpec and snap.specs[viewSpec]) then viewSpec = Soulstone.DefaultSpec(snap) end
	local counts = L["%d actions  |  %d macros  |  %d keybinds"]:format(Soulstone.Count(snap, viewSpec))
	local spec = viewSpec and snap.specs[viewSpec]
	if spec and spec.talents then counts = counts .. "  |  " .. spec.talents end
	frame.counts:SetText(counts)
	for i, tab in ipairs(frame.specTabs) do
		if snap.specs[i] then
			tab:SetText(Soulstone.SpecShortLabel(snap, i))
			tab.tooltip = Soulstone.SpecLabel(snap, i)
			tab:Enable()
		else
			tab:SetText(i .. ": " .. L["not saved"])
			tab.tooltip = nil
			tab:Disable()
		end
		if i == viewSpec then tab:LockHighlight() else tab:UnlockHighlight() end
		tab:Show()
	end
	local actions = viewSpec and snap.specs[viewSpec].actions
	if viewSpec and not actions then
		frame.status:SetText("|cffffd100" .. L["The bars of this spec aren't saved yet - save again and accept the spec switch."] .. "|r")
	end
	actions = actions or {}
	for slot, cell in ipairs(cells) do
		local a = actions[slot]
		cell.action = a or nil
		if a then
			cell.icon:SetTexture(a.icon or QUESTION_MARK)
			cell.icon:SetAlpha(1)
		else
			cell.icon:SetTexture(nil)
		end
		cell:Show()
	end
	if viewSpec then frame.restore:Enable() else frame.restore:Disable() end
	frame.delete:Enable()
end

local function UpdateCopySpec()
	local b = frame.copySpec
	if (GetNumTalentGroups() or 1) < 2 then
		b:SetText(L["Copy bars from the other spec"])
		b:Disable()
		return
	end
	local from = 3 - (GetActiveTalentGroup() or 1)
	b:SetText(L["Copy bars from spec %d"]:format(from))
	if Soulstone.RememberedBars(from) then b:Enable() else b:Disable() end
end

function Soulstone.RefreshUI()
	if not frame or not frame:IsShown() then return end
	UpdateCopySpec()
	if frame.panels[1]:IsShown() then
		UpdateList()
		UpdateDetails()
	else
		Soulstone.RefreshTalentsUI()
	end
end

-- shared helpers for the other panels
Soulstone.ClassColor = ClassColor

---------------------------------------------------------------- construction

function Soulstone.MakeButton(parent, text, width)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	return b
end

local MakeButton = Soulstone.MakeButton

local function MakeCheck(parent, name, label, key)
	local c = CreateFrame("CheckButton", "SoulstoneCheck" .. name, parent, "UICheckButtonTemplate")
	c:SetSize(24, 24)
	_G[c:GetName() .. "Text"]:SetText(label)
	c:SetScript("OnShow", function(self) self:SetChecked(SoulstoneDB.options[key]) end)
	c:SetScript("OnClick", function(self) SoulstoneDB.options[key] = self:GetChecked() and true or false end)
	return c
end

local function CellOnEnter(self)
	local a = self.action
	if not a then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(a.name or tostring(a.id), 1, 1, 1)
	local sub = a.type
	if a.rank and a.rank ~= "" then sub = sub .. " - " .. a.rank end
	GameTooltip:AddLine(sub .. "  (slot " .. self.slot .. ")", 0.7, 0.7, 0.7)
	if a.type == "macro" and a.body then GameTooltip:AddLine(a.body, 1, 0.82, 0, true) end
	GameTooltip:Show()
end

local function CreateUI()
	frame = CreateFrame("Frame", "SoulstoneFrame", UIParent)
	frame:SetSize(600, 494)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetScript("OnShow", Soulstone.RefreshUI)
	frame:Hide()
	tinsert(UISpecialFrames, "SoulstoneFrame")

	local header = frame:CreateTexture(nil, "ARTWORK")
	header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
	header:SetSize(300, 64)
	header:SetPoint("TOP", 0, 12)
	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOP", header, "TOP", 0, -14)
	title:SetText("Soulstone")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	-- "Setup" tab
	local p = CreateFrame("Frame", nil, frame)
	p:SetAllPoints()
	frame.panels = { p }

	-- left: snapshot list
	local list = CreateFrame("Frame", nil, p)
	list:SetPoint("TOPLEFT", 20, -36)
	list:SetSize(220, ROWS * ROW_HEIGHT + 10)
	list:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	list:SetBackdropColor(0, 0, 0, 0.6)

	local label = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("BOTTOMLEFT", list, "TOPLEFT", 4, 1)
	label:SetText(L["Snapshots"])

	scroll = CreateFrame("ScrollFrame", "SoulstoneListScroll", list, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 5, -5)
	scroll:SetPoint("BOTTOMRIGHT", -27, 5)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, UpdateList)
	end)

	rows = {}
	for i = 1, ROWS do
		local row = CreateFrame("Button", nil, list)
		row:SetSize(185, ROW_HEIGHT)
		row:SetPoint("TOPLEFT", 6, -5 - (i - 1) * ROW_HEIGHT)
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
		row.sel = row:CreateTexture(nil, "BACKGROUND")
		row.sel:SetAllPoints()
		row.sel:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row.sel:SetVertexColor(0.2, 0.6, 1)
		row.sel:SetBlendMode("ADD")
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.text:SetPoint("LEFT", 4, 0)
		row.text:SetPoint("RIGHT", -4, 0)
		row.text:SetJustifyH("LEFT")
		row:SetScript("OnClick", function(self)
			selected = self.name
			viewSpec = nil
			frame.status:SetText("")
			Soulstone.RefreshUI()
		end)
		rows[i] = row
	end

	frame.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.empty:SetPoint("CENTER")
	frame.empty:SetText(L["No snapshots yet."])

	local save = MakeButton(p, L["Save current character"], 220)
	save:SetPoint("BOTTOMLEFT", 20, 18)
	save:SetScript("OnClick", function() StaticPopup_Show("SOULSTONE_SAVE") end)

	-- dual spec: the other spec's bars onto this one (SpecCopy.lua)
	frame.copySpec = MakeButton(p, "", 220)
	frame.copySpec:SetPoint("BOTTOM", save, "TOP", 0, 4)
	frame.copySpec:SetScript("OnClick", function() Soulstone.ConfirmCopySpec(SoulstoneDB.options.copyFillOnly) end)
	if frame.copySpec.SetMotionScriptsWhileDisabled then frame.copySpec:SetMotionScriptsWhileDisabled(true) end
	frame.copySpec:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(self:GetText(), 1, 1, 1)
		GameTooltip:AddLine(L["Uses the other spec's bars as a base so you only change what is different. Soulstone remembers each spec's bars by itself while you play."], nil, nil, nil, true)
		GameTooltip:Show()
	end)
	frame.copySpec:SetScript("OnLeave", GameTooltip_Hide)

	-- right: details
	local x = 260
	frame.title2 = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	frame.title2:SetPoint("TOPLEFT", x, -38)
	frame.title2:SetPoint("RIGHT", -24, 0)
	frame.title2:SetJustifyH("LEFT")

	frame.info = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.info:SetPoint("TOPLEFT", x, -60)
	frame.info:SetPoint("RIGHT", -24, 0)
	frame.info:SetJustifyH("LEFT")

	frame.counts = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.counts:SetPoint("TOPLEFT", x, -76)
	frame.counts:SetJustifyH("LEFT")

	frame.specTabs = {}
	for i = 1, 2 do
		local tab = MakeButton(p, "", 150)
		tab:SetPoint("TOPLEFT", x + (i - 1) * 156, -96)
		tab:GetFontString():SetFontObject(GameFontNormalSmall)
		tab:GetFontString():SetWidth(140) -- truncate instead of overflowing the button
		tab:SetDisabledFontObject(GameFontDisableSmall)
		if tab.SetMotionScriptsWhileDisabled then tab:SetMotionScriptsWhileDisabled(true) end -- not in every 3.3.5 build
		tab:SetScript("OnEnter", function(self)
			if not self.tooltip then return end
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(self.tooltip, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		tab:SetScript("OnLeave", GameTooltip_Hide)
		tab:SetScript("OnClick", function()
			viewSpec = i
			frame.status:SetText("")
			Soulstone.RefreshUI()
		end)
		tab:Hide()
		frame.specTabs[i] = tab
	end

	local grid = CreateFrame("Frame", nil, p)
	grid:SetPoint("TOPLEFT", x, -124)
	grid:SetSize(GRID_COLS * CELL, GRID_ROWS * CELL)
	cells = {}
	for slot = 1, GRID_COLS * GRID_ROWS do
		local cell = CreateFrame("Button", nil, grid)
		cell:SetSize(CELL - 2, CELL - 2)
		local col, row = (slot - 1) % GRID_COLS, math.floor((slot - 1) / GRID_COLS)
		cell:SetPoint("TOPLEFT", col * CELL, -row * CELL)
		local bg = cell:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetTexture(0, 0, 0, 0.5)
		cell.icon = cell:CreateTexture(nil, "ARTWORK")
		cell.icon:SetAllPoints()
		cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		cell.slot = slot
		cell:SetScript("OnEnter", CellOnEnter)
		cell:SetScript("OnLeave", GameTooltip_Hide)
		cell:Hide()
		cells[slot] = cell
	end

	local checks = {
		MakeCheck(p, "Actions", L["Action bars"], "actions"),
		MakeCheck(p, "Macros", L["Character macros"], "macros"),
		MakeCheck(p, "Bindings", L["Keybindings"], "bindings"),
		MakeCheck(p, "ClearEmpty", L["Clear empty slots"], "clearEmpty"),
		MakeCheck(p, "Talents", L["Talents (needs unspent points)"], "talents"),
		MakeCheck(p, "CopyFillOnly", L["Copy spec: only empty slots"], "copyFillOnly"),
	}
	checks[1]:SetPoint("TOPLEFT", x - 4, -350)
	checks[2]:SetPoint("TOPLEFT", x + 150, -350)
	checks[3]:SetPoint("TOPLEFT", x - 4, -374)
	checks[4]:SetPoint("TOPLEFT", x + 150, -374)
	checks[5]:SetPoint("TOPLEFT", x - 4, -398)
	checks[6]:SetPoint("TOPLEFT", x + 150, -398)

	frame.status = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.status:SetPoint("TOPLEFT", x, -428)
	frame.status:SetPoint("RIGHT", -24, 0)
	frame.status:SetJustifyH("LEFT")

	frame.restore = MakeButton(p, L["Restore"], 150)
	frame.restore:SetPoint("BOTTOMLEFT", x, 18)
	frame.restore:SetScript("OnClick", function()
		local snap = Soulstone.Snapshots()[selected]
		local dialog = StaticPopup_Show("SOULSTONE_RESTORE", selected, Soulstone.SpecLabel(snap, viewSpec))
		if dialog then dialog.data = { name = selected, spec = viewSpec } end
	end)

	frame.delete = MakeButton(p, L["Delete"], 100)
	frame.delete:SetPoint("LEFT", frame.restore, "RIGHT", 8, 0)
	frame.delete:SetScript("OnClick", function()
		local dialog = StaticPopup_Show("SOULSTONE_DELETE", selected)
		if dialog then dialog.data = selected end
	end)

	frame.panels[2] = Soulstone.CreateTalentsPanel(frame)

	-- bottom tabs
	for i, text in ipairs({ L["Setup"], L["Talents"] }) do
		local tab = CreateFrame("Button", "SoulstoneFrameTab" .. i, frame, "CharacterFrameTabButtonTemplate")
		tab:SetID(i)
		tab:SetText(text)
		if i == 1 then
			tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 16, 10)
		else
			tab:SetPoint("LEFT", _G["SoulstoneFrameTab" .. (i - 1)], "RIGHT", -16, 0)
		end
		tab:SetScript("OnClick", function(self) Soulstone.ShowPanel(self:GetID()) end)
	end
	PanelTemplates_SetNumTabs(frame, 2)
	Soulstone.ShowPanel(1)
end

function Soulstone.ShowPanel(i)
	PanelTemplates_SetTab(frame, i)
	for n, panel in ipairs(frame.panels) do
		if n == i then panel:Show() else panel:Hide() end
	end
	Soulstone.RefreshUI()
end

function Soulstone.ToggleUI()
	if not frame then CreateUI() end
	if frame:IsShown() then
		frame:Hide()
	else
		if not selected then
			local own = Soulstone.CharKey()
			if Soulstone.Snapshots()[own] then selected = own end
		end
		frame:Show()
	end
end

---------------------------------------------------------------- minimap button

local mm

local function PositionMinimapButton()
	local angle = math.rad(SoulstoneDB.minimap.angle)
	mm:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
end

function Soulstone.UpdateMinimapButton()
	if not mm then return end
	if SoulstoneDB.minimap.hide then mm:Hide() else mm:Show() end
end

function Soulstone.CreateMinimapButton()
	mm = CreateFrame("Button", "SoulstoneMinimapButton", Minimap)
	mm:SetSize(31, 31)
	mm:SetFrameStrata("MEDIUM")
	mm:SetFrameLevel(8)
	mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local icon = mm:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\Icons\\Spell_Shadow_SoulGem")
	icon:SetSize(20, 20)
	icon:SetPoint("TOPLEFT", 7, -5)
	icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	local border = mm:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")

	mm:RegisterForClicks("LeftButtonUp")
	mm:RegisterForDrag("LeftButton")
	mm:SetScript("OnClick", Soulstone.ToggleUI)
	mm:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			SoulstoneDB.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
			PositionMinimapButton()
		end)
	end)
	mm:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	mm:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Soulstone")
		GameTooltip:AddLine(L["Left-click: open/close\nDrag: move"], 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	mm:SetScript("OnLeave", GameTooltip_Hide)

	PositionMinimapButton()
	Soulstone.UpdateMinimapButton()
end
