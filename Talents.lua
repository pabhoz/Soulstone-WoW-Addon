-- Soulstone - move your WoW 3.3.5a setup between characters, realms and servers.
-- Copyright (C) 2026 pabhoz - https://github.com/pabhoz/Soulstone-WoW-Addon
-- Licensed under the GNU General Public License v3.0 or later. See LICENSE.

-- Talent templates: capture, Wowhead-compatible encoding, import/export and apply.
--
-- A talent build is stored as a Wowhead talent-calculator string: one digit per
-- talent (its rank), talents ordered by tier then column, trees separated by "-".
-- e.g. "-05503201-05232051203331302133231331" (trailing zeros may be omitted).

local L = Soulstone.L
local Print = Soulstone.Print

-- Wowhead URL slug <-> class token
local CLASS_SLUGS = {
	WARRIOR = "warrior", PALADIN = "paladin", HUNTER = "hunter", ROGUE = "rogue", PRIEST = "priest",
	DEATHKNIGHT = "death-knight", SHAMAN = "shaman", MAGE = "mage", WARLOCK = "warlock", DRUID = "druid",
}
local SLUG_CLASSES = { deathknight = "DEATHKNIGHT" }
for class, slug in pairs(CLASS_SLUGS) do SLUG_CLASSES[slug] = class end

local function PlayerClass()
	local _, class = UnitClass("player")
	return class
end

---------------------------------------------------------------- layout & encoding

-- Talents of the player's class per tree, ordered by tier then column (Wowhead order).
local layoutCache
local function Layout()
	if layoutCache then return layoutCache end
	local layout = {}
	for tab = 1, GetNumTalentTabs() do
		local list = {}
		for index = 1, GetNumTalents(tab) do
			local name, icon, tier, column, _, maxRank = GetTalentInfo(tab, index)
			if name then
				list[#list + 1] = { tab = tab, index = index, name = name, icon = icon, tier = tier, column = column, maxRank = maxRank }
			end
		end
		table.sort(list, function(a, b)
			if a.tier ~= b.tier then return a.tier < b.tier end
			return a.column < b.column
		end)
		layout[tab] = list
	end
	if #layout > 0 and #layout[1] > 0 then layoutCache = layout end
	return layout
end
Soulstone.TalentLayout = Layout

-- "0550-05232051-" -> { {0,5,5,0}, {0,5,2,3,2,0,5,1}, {} }
local function Decode(str)
	local trees = {}
	for part in (str .. "-"):gmatch("([^-]*)-") do
		local ranks = {}
		for d in part:gmatch("%d") do ranks[#ranks + 1] = tonumber(d) end
		trees[#trees + 1] = ranks
	end
	while #trees < 3 do trees[#trees + 1] = {} end
	return trees
end
Soulstone.DecodeTalents = Decode

local function Encode(trees)
	local parts = {}
	for t = 1, 3 do
		local s = table.concat(trees[t] or {}):gsub("0+$", "")
		parts[t] = s
	end
	return (table.concat(parts, "-"):gsub("%-+$", ""))
end

-- Points per tree for any class (no layout needed): "0/53/18", 71
function Soulstone.TalentPoints(str)
	local pts, total = {}, 0
	for t, ranks in ipairs(Decode(str)) do
		local sum = 0
		for _, r in ipairs(ranks) do sum = sum + r end
		pts[t] = sum
		total = total + sum
	end
	return table.concat(pts, "/", 1, 3), total, pts
end

-- Talent string of a spec (talentGroup). With usePreview, pending preview
-- points from Blizzard's talent frame are included.
local function CaptureString(group, usePreview)
	local trees = {}
	for tab, list in ipairs(Layout()) do
		local ranks = {}
		for i, t in ipairs(list) do
			local _, _, _, _, rank, _, _, _, previewRank = GetTalentInfo(t.tab, t.index, false, false, group)
			rank = rank or 0
			if usePreview and previewRank and previewRank > rank then rank = previewRank end
			ranks[i] = rank
		end
		trees[tab] = ranks
	end
	return Encode(trees)
end
Soulstone.CaptureTalentString = CaptureString

local function CaptureGlyphs(group)
	local glyphs = { major = {}, minor = {} }
	for socket = 1, (GetNumGlyphSockets and GetNumGlyphSockets() or 6) do
		-- 3.3.5: enabled, glyphType, glyphSpellID, icon
		local enabled, glyphType, a, b = GetGlyphSocketInfo(socket, group)
		local spellID = type(b) == "number" and b or a
		if enabled and spellID then
			local name = GetSpellInfo(spellID)
			if name then
				local list = glyphType == 1 and glyphs.major or glyphs.minor
				list[#list + 1] = name
			end
		end
	end
	return glyphs
end
Soulstone.CaptureGlyphs = CaptureGlyphs

-- "Holy 51/5/15" for the player's class, or just "51/5/15" for others.
function Soulstone.TalentSummary(str, class)
	local points, total, pts = Soulstone.TalentPoints(str)
	if total == 0 then return nil end
	local main, best = nil, -1
	for t = 1, 3 do
		if pts[t] > best then main, best = t, pts[t] end
	end
	if class == PlayerClass() then
		local treeName = GetTalentTabInfo(main)
		if treeName then return treeName .. " " .. points end
	end
	return points
end

---------------------------------------------------------------- templates

function Soulstone.Templates()
	return SoulstoneDB.templates
end

function Soulstone.SortedTemplates()
	local own, other = PlayerClass(), {}
	local names = {}
	for k in pairs(SoulstoneDB.templates) do names[#names + 1] = k end
	table.sort(names, function(a, b)
		local ca, cb = SoulstoneDB.templates[a].class == own, SoulstoneDB.templates[b].class == own
		if ca ~= cb then return ca end
		return a:lower() < b:lower()
	end)
	return names
end

local function DefaultName(tpl)
	local className = LOCALIZED_CLASS_NAMES_MALE[tpl.class] or tpl.class
	return className .. " " .. (Soulstone.TalentSummary(tpl.talents, tpl.class) or "")
end

local function UniqueName(name)
	if not SoulstoneDB.templates[name] then return name end
	local n = 2
	while SoulstoneDB.templates[name .. " (" .. n .. ")"] do n = n + 1 end
	return name .. " (" .. n .. ")"
end

function Soulstone.NewTemplateFromSpec(usePreview)
	local group = GetActiveTalentGroup() or 1
	local tpl = {
		class = PlayerClass(),
		talents = CaptureString(group, usePreview),
		glyphs = CaptureGlyphs(group),
		date = date("%Y-%m-%d %H:%M"),
	}
	return tpl, DefaultName(tpl)
end

-- Accepts a Wowhead talent-calc URL (".../talent-calc/paladin/-0550...") or a bare string.
function Soulstone.ParseImport(text)
	text = strtrim(text or "")
	local slug, str = text:match("talent%-calc/([%a%-]+)/([%d%-]+)")
	local class
	if slug then
		class = SLUG_CLASSES[slug:lower()]
		if not class then return nil, L["Unknown class in link: %s"]:format(slug) end
	else
		str = text:match("^([%d%-]+)$") or text:match("^([%d%-]+)_")
		class = PlayerClass()
	end
	if not str or not str:find("[1-5]") then return nil, L["Not a valid talent link or string."] end
	local tpl = { class = class, talents = str, glyphs = { major = {}, minor = {} }, date = date("%Y-%m-%d %H:%M") }
	return tpl, DefaultName(tpl)
end

-- Keeps one template per snapshot spec (tpl.source), replacing it when the
-- snapshot is saved again. With onlyIfMissing, existing ones are left alone.
function Soulstone.SyncTemplate(snapName, snap, spec, onlyIfMissing)
	if Soulstone.IsBackup(snapName) then return end
	local s = snap.specs[spec]
	if not (s and s.build and s.build:find("[1-5]")) then return end
	for k, t in pairs(SoulstoneDB.templates) do
		if t.source and t.source.snapshot == snapName and t.source.spec == spec then
			if onlyIfMissing then return end
			SoulstoneDB.templates[k] = nil
		end
	end
	local name = UniqueName(snapName .. " - " .. (s.talents or L["Spec %d"]:format(spec)))
	SoulstoneDB.templates[name] = {
		class = snap.class,
		talents = s.build,
		glyphs = s.glyphs,
		date = s.date or snap.date,
		source = { snapshot = snapName, spec = spec },
	}
	return name
end

function Soulstone.SaveTemplate(name, tpl)
	name = strtrim(name or "")
	if name == "" then name = DefaultName(tpl) end
	name = UniqueName(name)
	SoulstoneDB.templates[name] = tpl
	Print(L["Template '%s' saved."]:format(name))
	return name
end

function Soulstone.DeleteTemplate(name)
	SoulstoneDB.templates[name] = nil
end

function Soulstone.ExportURL(tpl)
	return "https://www.wowhead.com/wotlk/talent-calc/" .. (CLASS_SLUGS[tpl.class] or "") .. "/" .. tpl.talents
end

function Soulstone.GlyphText(glyphs)
	if not glyphs then return nil end
	local parts = {}
	if #glyphs.major > 0 then parts[#parts + 1] = L["Major"] .. ": " .. table.concat(glyphs.major, ", ") end
	if #glyphs.minor > 0 then parts[#parts + 1] = L["Minor"] .. ": " .. table.concat(glyphs.minor, ", ") end
	if #parts == 0 then return nil end
	return table.concat(parts, "  |  ")
end

---------------------------------------------------------------- apply

-- Fallback when the preview API doesn't take: learn one point at a time,
-- waiting for the server to confirm each one.
local queue, queueFrame, lastStep = {}, CreateFrame("Frame"), 0
local function LearnNext()
	lastStep = GetTime()
	local step = table.remove(queue, 1)
	if not step then
		queueFrame:UnregisterEvent("CHARACTER_POINTS_CHANGED")
		Print(L["Talents learned."])
		return
	end
	LearnTalent(step.tab, step.index)
end
queueFrame:SetScript("OnEvent", LearnNext)

-- Applies a talent string to the active spec using unspent points.
-- Returns true if something was applied.
function Soulstone.ApplyTalents(str, class)
	if class and class ~= PlayerClass() then
		Print(L["This build is for a %s."]:format(LOCALIZED_CLASS_NAMES_MALE[class] or class))
		return
	end
	if InCombatLockdown() then Print(L["Not possible in combat."]) return end
	if #queue > 0 then
		if GetTime() - lastStep < 5 then Print(L["Still learning the previous build, wait a moment."]) return end
		wipe(queue) -- the server stopped answering; drop the stale queue
	end

	local group = GetActiveTalentGroup() or 1
	local layout = Layout()
	local target = Decode(str)

	-- validate and collect what's missing
	local conflicts, steps, wanted = {}, {}, {}
	for tab, list in ipairs(layout) do
		wanted[tab] = 0
		for i, t in ipairs(list) do
			local want = math.min(target[tab][i] or 0, t.maxRank)
			local _, _, _, _, rank = GetTalentInfo(t.tab, t.index, false, false, group)
			rank = rank or 0
			if rank > want then
				conflicts[#conflicts + 1] = t.name
			elseif want > rank then
				steps[#steps + 1] = { tab = tab, index = t.index, tier = t.tier, column = t.column, points = want - rank }
				wanted[tab] = wanted[tab] + want
			end
		end
	end
	if #conflicts > 0 then
		Print("|cffff5555" .. L["Your active spec has talents that aren't in this build (%s). Reset your talents at a trainer first."]:format(table.concat(conflicts, ", ")) .. "|r")
		return
	end
	if #steps == 0 then Print(L["Your active spec already matches this build."]) return end

	local unspent = GetUnspentTalentPoints(false, false, group) or 0
	if unspent == 0 then Print(L["You have no unspent talent points."]) return end

	-- main tree first, each tree top to bottom, so tier requirements are met as we go
	table.sort(steps, function(a, b)
		if a.tab ~= b.tab then
			if wanted[a.tab] ~= wanted[b.tab] then return wanted[a.tab] > wanted[b.tab] end
			return a.tab < b.tab
		end
		if a.tier ~= b.tier then return a.tier < b.tier end
		return a.column < b.column
	end)

	local remaining, needed = unspent, 0
	for _, s in ipairs(steps) do needed = needed + s.points end

	ResetGroupPreviewTalentPoints(false, group)
	local added = 0
	for _, s in ipairs(steps) do
		local n = math.min(s.points, remaining)
		if n <= 0 then break end
		AddPreviewTalentPoints(s.tab, s.index, n, false, group)
		remaining = remaining - n
		added = added + n
	end

	if (GetGroupPreviewTalentPointsSpent(false, group) or 0) > 0 then
		LearnPreviewTalents(false)
	else
		-- preview API unavailable: queue one LearnTalent per point
		ResetGroupPreviewTalentPoints(false, group)
		local left = added
		for _, s in ipairs(steps) do
			for _ = 1, math.min(s.points, left) do
				queue[#queue + 1] = { tab = s.tab, index = s.index }
			end
			left = left - s.points
			if left <= 0 then break end
		end
		queueFrame:RegisterEvent("CHARACTER_POINTS_CHANGED")
		LearnNext()
	end

	Print(L["Applying %d talent points to your active spec (%d)."]:format(added, group))
	if needed > added then
		Print(L["%d more points needed to complete this build - apply it again after leveling."]:format(needed - added))
	end
	return true
end
