-- Soulstone - move your WoW 3.3.5a setup between characters, realms and servers.
-- Copyright (C) 2026 pabhoz - https://github.com/pabhoz/Soulstone-WoW-Addon
-- Licensed under the GNU General Public License v3.0 or later. See LICENSE.

-- "Talents" tab: list of talent templates, tree preview, import/export/apply.

local L = Soulstone.L
local MakeButton = Soulstone.MakeButton

local ROWS = 19
local ROW_HEIGHT = 20
local CELL = 20
local TREE_GAP = 100

local panel, rows, scroll, treeCells, treeHeaders
local selected

local function NormalEditBox(self) return self.editBox or _G[self:GetName() .. "EditBox"] end
local function WideEditBox(self) return self.wideEditBox or _G[self:GetName() .. "WideEditBox"] end

---------------------------------------------------------------- popups

local function SaveFromPopup(dialog, text)
	selected = Soulstone.SaveTemplate(text, dialog.data)
	Soulstone.RefreshUI()
end

StaticPopupDialogs["SOULSTONE_TPL_SAVE"] = {
	text = L["Template name:"],
	button1 = SAVE,
	button2 = CANCEL,
	hasEditBox = 1,
	maxLetters = 64,
	OnShow = function(self)
		local eb = NormalEditBox(self)
		eb:SetText(self.data2 or "")
		eb:HighlightText()
		eb:SetFocus()
	end,
	OnAccept = function(self) SaveFromPopup(self, NormalEditBox(self):GetText()) end,
	EditBoxOnEnterPressed = function(self)
		local dialog = self:GetParent()
		SaveFromPopup(dialog, self:GetText())
		dialog:Hide()
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

local function ImportFromPopup(text)
	local tpl, nameOrErr = Soulstone.ParseImport(text)
	if not tpl then
		Soulstone.Print("|cffff5555" .. nameOrErr .. "|r")
		return
	end
	local dialog = StaticPopup_Show("SOULSTONE_TPL_SAVE")
	if dialog then
		dialog.data, dialog.data2 = tpl, nameOrErr
		StaticPopupDialogs["SOULSTONE_TPL_SAVE"].OnShow(dialog)
	end
end

StaticPopupDialogs["SOULSTONE_TPL_IMPORT"] = {
	text = L["Paste a Wowhead WotLK talent calculator link (or a talent string):"],
	button1 = L["Import"],
	button2 = CANCEL,
	hasEditBox = 1,
	hasWideEditBox = 1,
	maxLetters = 512,
	OnShow = function(self)
		local eb = WideEditBox(self)
		eb:SetText("")
		eb:SetFocus()
	end,
	OnAccept = function(self)
		local text = WideEditBox(self):GetText()
		-- open the name dialog after this one has closed
		Soulstone.After(function() ImportFromPopup(text) end)
	end,
	EditBoxOnEnterPressed = function(self)
		local text = self:GetText()
		self:GetParent():Hide()
		ImportFromPopup(text)
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["SOULSTONE_TPL_EXPORT"] = {
	text = L["Copy this link with Ctrl+C:"],
	button1 = OKAY,
	hasEditBox = 1,
	hasWideEditBox = 1,
	maxLetters = 512,
	OnShow = function(self)
		local eb = WideEditBox(self)
		eb:SetText(self.data or "")
		eb:HighlightText()
		eb:SetFocus()
	end,
	EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["SOULSTONE_TPL_APPLY"] = {
	text = L["Apply '%s' to your active spec?\n\n%s"],
	button1 = L["Apply"],
	button2 = CANCEL,
	OnAccept = function(self, name)
		local tpl = Soulstone.Templates()[name]
		if tpl and Soulstone.ApplyTalents(tpl.talents, tpl.class) then
			local glyphs = Soulstone.GlyphText(tpl.glyphs)
			if glyphs then Soulstone.Print(L["Glyphs of this build (apply them manually):"] .. " " .. glyphs) end
		end
		Soulstone.After(Soulstone.RefreshUI)
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["SOULSTONE_TPL_DELETE"] = {
	text = L["Delete template '%s'?"],
	button1 = L["Delete"],
	button2 = CANCEL,
	OnAccept = function(self, name)
		Soulstone.DeleteTemplate(name)
		selected = nil
		Soulstone.RefreshUI()
	end,
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
}

---------------------------------------------------------------- refresh

local function UpdateList()
	local names = Soulstone.SortedTemplates()
	local offset = FauxScrollFrame_GetOffset(scroll)
	FauxScrollFrame_Update(scroll, #names, ROWS, ROW_HEIGHT)
	for i = 1, ROWS do
		local row = rows[i]
		local name = names[i + offset]
		if name then
			local tpl = Soulstone.Templates()[name]
			row.name = name
			row.text:SetText(Soulstone.ClassColor(tpl.class) .. name .. "|r")
			if name == selected then row.sel:Show() else row.sel:Hide() end
			row:Show()
		else
			row:Hide()
		end
	end
	if #names == 0 then panel.empty:Show() else panel.empty:Hide() end
end

local function GetCell(tab, i)
	treeCells[tab] = treeCells[tab] or {}
	local cell = treeCells[tab][i]
	if cell then return cell end
	cell = CreateFrame("Button", nil, panel.tree)
	cell:SetSize(CELL - 2, CELL - 2)
	cell.icon = cell:CreateTexture(nil, "ARTWORK")
	cell.icon:SetAllPoints()
	cell.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	cell.rank = cell:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
	cell.rank:SetPoint("BOTTOMRIGHT", 2, -1)
	cell:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self.talent.name, 1, 1, 1)
		GameTooltip:AddLine(RANK .. " " .. self.value .. "/" .. self.talent.maxRank, 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	cell:SetScript("OnLeave", GameTooltip_Hide)
	treeCells[tab][i] = cell
	return cell
end

local function HideTree()
	for _, cells in pairs(treeCells) do
		for _, cell in ipairs(cells) do cell:Hide() end
	end
	for _, h in ipairs(treeHeaders) do h:SetText("") end
end

local function ShowTree(tpl)
	HideTree()
	local _, playerClass = UnitClass("player")
	if tpl.class ~= playerClass then
		panel.treeMsg:SetText(L["Log in with a %s to preview and apply this build."]:format(LOCALIZED_CLASS_NAMES_MALE[tpl.class] or tpl.class))
		return
	end
	panel.treeMsg:SetText("")
	local target = Soulstone.DecodeTalents(tpl.talents)
	local _, _, pts = Soulstone.TalentPoints(tpl.talents)
	for tab, list in ipairs(Soulstone.TalentLayout()) do
		treeHeaders[tab]:SetText((GetTalentTabInfo(tab) or "?") .. " (" .. pts[tab] .. ")")
		for i, t in ipairs(list) do
			local cell = GetCell(tab, i)
			local value = math.min(target[tab][i] or 0, t.maxRank)
			cell.talent, cell.value = t, value
			cell:ClearAllPoints()
			cell:SetPoint("TOPLEFT", (tab - 1) * TREE_GAP + (t.column - 1) * CELL, -(t.tier - 1) * CELL)
			cell.icon:SetTexture(t.icon)
			cell.icon:SetDesaturated(value == 0)
			cell.icon:SetAlpha(value == 0 and 0.35 or 1)
			if value > 0 then
				cell.rank:SetText(value)
				if value == t.maxRank then cell.rank:SetTextColor(1, 0.82, 0) else cell.rank:SetTextColor(0.1, 1, 0.1) end
			else
				cell.rank:SetText("")
			end
			cell:Show()
		end
	end
end

local function UpdateDetails()
	local tpl = selected and Soulstone.Templates()[selected]
	if not tpl then
		selected = nil
		panel.title:SetText("")
		panel.info:SetText(L["Save your current talents, or import a build from Wowhead."])
		panel.glyphs:SetText("")
		panel.treeMsg:SetText("")
		HideTree()
		panel.apply:Disable()
		panel.export:Disable()
		panel.delete:Disable()
		return
	end
	local points, total = Soulstone.TalentPoints(tpl.talents)
	panel.title:SetText(selected)
	panel.info:SetText(Soulstone.ClassColor(tpl.class) .. (LOCALIZED_CLASS_NAMES_MALE[tpl.class] or tpl.class) .. "|r  |  "
		.. points .. "  |  " .. L["%d points"]:format(total) .. "  |  " .. (tpl.date or ""))
	ShowTree(tpl)
	local glyphs = Soulstone.GlyphText(tpl.glyphs)
	panel.glyphs:SetText(glyphs and (L["Glyphs"] .. " - " .. glyphs) or "")
	local _, playerClass = UnitClass("player")
	if tpl.class == playerClass then panel.apply:Enable() else panel.apply:Disable() end
	panel.export:Enable()
	panel.delete:Enable()
end

function Soulstone.RefreshTalentsUI()
	if not panel then return end
	UpdateList()
	UpdateDetails()
end

---------------------------------------------------------------- construction

function Soulstone.CreateTalentsPanel(parent)
	panel = CreateFrame("Frame", nil, parent)
	panel:SetAllPoints()
	panel:Hide()
	treeCells, treeHeaders = {}, {}

	-- left: template list
	local list = CreateFrame("Frame", nil, panel)
	list:SetPoint("TOPLEFT", 20, -36)
	list:SetSize(220, ROWS * ROW_HEIGHT + 10)
	list:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	list:SetBackdropColor(0, 0, 0, 0.6)

	local label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("BOTTOMLEFT", list, "TOPLEFT", 4, 1)
	label:SetText(L["Talent templates"])

	scroll = CreateFrame("ScrollFrame", "SoulstoneTemplateScroll", list, "FauxScrollFrameTemplate")
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
			Soulstone.RefreshUI()
		end)
		rows[i] = row
	end

	panel.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	panel.empty:SetPoint("CENTER")
	panel.empty:SetText(L["No templates yet."])

	local save = MakeButton(panel, L["Save my talents"], 108)
	save:SetPoint("BOTTOMLEFT", 20, 18)
	save:SetScript("OnClick", function()
		local tpl, name = Soulstone.NewTemplateFromSpec(true)
		local dialog = StaticPopup_Show("SOULSTONE_TPL_SAVE")
		if dialog then
			dialog.data, dialog.data2 = tpl, name
			StaticPopupDialogs["SOULSTONE_TPL_SAVE"].OnShow(dialog)
		end
	end)
	save:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L["Save my talents"], 1, 1, 1)
		GameTooltip:AddLine(L["Saves your active spec as a template. Tip: design a build in Blizzard's talent window using preview mode (spend points, don't click Learn) and save it here."], nil, nil, nil, true)
		GameTooltip:Show()
	end)
	save:SetScript("OnLeave", GameTooltip_Hide)

	local import = MakeButton(panel, L["Import"], 108)
	import:SetPoint("LEFT", save, "RIGHT", 4, 0)
	import:SetScript("OnClick", function() StaticPopup_Show("SOULSTONE_TPL_IMPORT") end)

	-- right: details
	local x = 260
	panel.title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	panel.title:SetPoint("TOPLEFT", x, -38)
	panel.title:SetPoint("RIGHT", -24, 0)
	panel.title:SetJustifyH("LEFT")

	panel.info = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	panel.info:SetPoint("TOPLEFT", x, -60)
	panel.info:SetPoint("RIGHT", -24, 0)
	panel.info:SetJustifyH("LEFT")

	for tab = 1, 3 do
		local h = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		h:SetPoint("TOPLEFT", x + (tab - 1) * TREE_GAP, -84)
		h:SetWidth(TREE_GAP - 4)
		h:SetJustifyH("LEFT")
		treeHeaders[tab] = h
	end

	panel.tree = CreateFrame("Frame", nil, panel)
	panel.tree:SetPoint("TOPLEFT", x, -100)
	panel.tree:SetSize(3 * TREE_GAP, 11 * CELL)

	panel.treeMsg = panel:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	panel.treeMsg:SetPoint("CENTER", panel.tree, "CENTER", -20, 0)
	panel.treeMsg:SetWidth(280)

	panel.glyphs = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	panel.glyphs:SetPoint("TOPLEFT", x, -334)
	panel.glyphs:SetPoint("RIGHT", -24, 0)
	panel.glyphs:SetJustifyH("LEFT")
	panel.glyphs:SetJustifyV("TOP")
	panel.glyphs:SetHeight(60)

	panel.apply = MakeButton(panel, L["Apply to active spec"], 140)
	panel.apply:SetPoint("BOTTOMLEFT", x, 18)
	panel.apply:SetScript("OnClick", function()
		local tpl = Soulstone.Templates()[selected]
		local _, total = Soulstone.TalentPoints(tpl.talents)
		local unspent = GetUnspentTalentPoints(false, false, GetActiveTalentGroup() or 1) or 0
		local detail = L["Build uses %d points. You have %d unspent."]:format(total, unspent)
		local dialog = StaticPopup_Show("SOULSTONE_TPL_APPLY", selected, detail)
		if dialog then dialog.data = selected end
	end)

	panel.export = MakeButton(panel, L["Export"], 80)
	panel.export:SetPoint("LEFT", panel.apply, "RIGHT", 6, 0)
	panel.export:SetScript("OnClick", function()
		local dialog = StaticPopup_Show("SOULSTONE_TPL_EXPORT")
		if dialog then
			dialog.data = Soulstone.ExportURL(Soulstone.Templates()[selected])
			StaticPopupDialogs["SOULSTONE_TPL_EXPORT"].OnShow(dialog)
		end
	end)

	panel.delete = MakeButton(panel, L["Delete"], 80)
	panel.delete:SetPoint("LEFT", panel.export, "RIGHT", 6, 0)
	panel.delete:SetScript("OnClick", function()
		local dialog = StaticPopup_Show("SOULSTONE_TPL_DELETE", selected)
		if dialog then dialog.data = selected end
	end)

	return panel
end
