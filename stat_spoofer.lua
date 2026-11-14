-- Roblox Bedwars | client-side Stat Spoofer | Delta (iOS)
-- Only changes what YOUR client displays. Nothing is sent to the server.
--
--   X button        = hides the UI, the edits KEEP running
--   Re-run script   = brings the UI back (it won't start a second copy)
--   Unload button   = stops everything and restores your real stats

local env = (getgenv and getgenv()) or _G
if env.StatsSpoofShow then
	env.StatsSpoofShow()
	return
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local guiParent = (gethui and gethui()) or Players.LocalPlayer:WaitForChild("PlayerGui")
local LP = Players.LocalPlayer
local REAL_NAME, REAL_DISPLAY = LP.Name, LP.DisplayName -- read before any hook is installed

-- clean up an older version of this script if it is still running
pcall(function() RunService:UnbindFromRenderStep("StatsSpoof") end)
for _, name in ipairs({ "StatsSpoofUI", "StatsSpoofToggle" }) do
	local old = guiParent:FindFirstChild(name)
	if old then old:Destroy() end
end

------------------------------------------------------------------ config
-- Direct image links only (the link must open the picture itself, e.g.
-- https://i.ibb.co/xxxx/name.png), NOT the ibb.co page link.
local ICON = {
	Diamond = "https://i.ibb.co/WNgy9fHy/IMG-2172.png",
	Emerald = "https://files.catbox.moe/xcx2v8.png",
	Nightmare = "https://i.ibb.co/RTFBFrB2/IMG-2173.png",
}
local DECAY_TEXT = "Rank Decay: 14 Days"

-- level colours: each entry starts at that level and lasts until the next one
-- (level 1000+ is drawn as a rainbow gradient, see RAINBOW / styleLevel below)
local LEVEL_COLORS = {
	{ 1,    Color3.fromRGB(255, 255, 255) }, -- white
	{ 10,   Color3.fromRGB(255, 250, 176) }, -- pale yellow
	{ 20,   Color3.fromRGB(188, 252, 148) }, -- light green
	{ 30,   Color3.fromRGB(228, 155, 250) }, -- purple
	{ 40,   Color3.fromRGB(152, 218, 252) }, -- light blue
	{ 50,   Color3.fromRGB(255, 133, 133) }, -- salmon (50-99)
	{ 100,  Color3.fromRGB(245, 150, 70) },  -- orange (100-149)
	{ 150,  Color3.fromRGB(70, 235, 110) },  -- bright green (150-199)
	{ 200,  Color3.fromRGB(0, 255, 255) },   -- bright cyan (200-999)
	{ 1000, Color3.fromRGB(0, 255, 255) },   -- fallback only, 1000+ uses the rainbow
}
-- level 1000+ gradient, matched to the "(1000)" nametag screenshot
local RAINBOW = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 110, 255)),
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(130, 190, 255)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(90, 240, 230)),
	ColorSequenceKeypoint.new(0.75, Color3.fromRGB(150, 255, 170)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 130, 200)),
})
-- XP bar colours (separate from the level text colours). Sampled from the real bar at level 80;
-- the other ranges are the same orange until you tell me their colours.
local ORANGE = Color3.fromRGB(237, 166, 58)
local XP_BAR_COLORS = {
	{ 1, ORANGE }, { 10, ORANGE }, { 20, ORANGE }, { 30, ORANGE }, { 40, ORANGE },
	{ 50, ORANGE }, { 100, ORANGE }, { 150, ORANGE }, { 200, ORANGE }, { 1000, ORANGE },
}
local function pickColor(list, lv)
	local n = tonumber(lv) or 1
	local col = list[1][2]
	for _, e in ipairs(list) do
		if n >= e[1] then col = e[2] end
	end
	return col
end
local function levelColor(lv) return pickColor(LEVEL_COLORS, lv) end
local function barColor(lv) return pickColor(XP_BAR_COLORS, lv) end
local function isRainbow(lv) return (tonumber(lv) or 0) >= 1000 end

local ORDER = { "Diamond", "Emerald", "Nightmare" }
local RANKS = {
	Diamond = { bar = Color3.fromRGB(90, 230, 250), dot = Color3.fromRGB(90, 230, 250) },
	Emerald = { bar = Color3.fromRGB(0, 200, 70), dot = Color3.fromRGB(0, 200, 70) },
	Nightmare = { bar = nil, dot = Color3.fromRGB(170, 70, 255) }, -- no bar at all
}

local state = {
	rank = "Emerald", division = 2, lb = "1000", rp = "1000",
	wins = "1024", bedBreaks = "478", finalKills = "1068", honor = "40", level = "80", streak = "0", -- Spoof Other
	xpCur = "15000", xpTotal = "52000", -- XP shown under Player Level
	rpTier = "50", -- RP on the Emerald / Diamond bar (0-99)
}
local enabled = false -- starts OFF; flip the switch in the UI to apply
local enabledOther = false -- Spoof Other switch (starts OFF)
local enabledProfile = false -- Player Profile switch (starts OFF)
local enabledUserSpoof = false -- Misc > User Spoofer switch
local spoofNames = { name = "", display = "" } -- fake username / display name
local mode = "rank" -- which tab is open: "rank", "other" or "misc"

------------------------------------------------------------------ helpers
local originals = {} -- [instance] = { [prop] = original value }
local barFrames = {}
local fillClones, fillConn, rpTextHooked = {}, {}, {} -- our own RP bars / the game fills we hide / RP text hooks
local rainbows = {} -- [UIGradient] = true, the level 1000 gradients we added
local clone = nil
local profileClone = nil -- the Rank Decay line added to the Player Profile
local cachedScroll = nil
local rankImage = nil

-- finds a child by name, ignoring capitalisation if there is no exact match
local function child(parent, name)
	local c = parent:FindFirstChild(name)
	if c then return c end
	local lname = name:lower()
	for _, k in ipairs(parent:GetChildren()) do
		if k.Name:lower() == lname then return k end
	end
	return nil
end

local function get(root, ...)
	local cur = root
	for _, name in ipairs({ ... }) do
		if not cur then return nil end
		cur = child(cur, name)
	end
	return cur
end

local function setProp(inst, prop, value)
	if inst[prop] ~= value then
		originals[inst] = originals[inst] or {}
		if originals[inst][prop] == nil then
			originals[inst][prop] = inst[prop]
		end
		inst[prop] = value
	end
end

local function unsetProp(inst, prop)
	local o = originals[inst]
	if o and o[prop] ~= nil then
		pcall(function() inst[prop] = o[prop] end)
		o[prop] = nil
	end
end

-- colours a level text: plain colour normally, rainbow gradient at level 1000+
local function styleLevel(lbl)
	local g = lbl:FindFirstChild("LvlRainbow")
	if isRainbow(state.level) then
		setProp(lbl, "TextColor3", Color3.new(1, 1, 1)) -- gradient tints white text
		if not g then
			g = Instance.new("UIGradient")
			g.Name = "LvlRainbow"
			g.Color = RAINBOW
			g.Parent = lbl
			rainbows[g] = true
		end
	else
		if g then
			rainbows[g] = nil
			g:Destroy()
		end
		setProp(lbl, "TextColor3", levelColor(state.level))
	end
end

local function near(c, r, g, b)
	return math.abs(c.R * 255 - r) < 12 and math.abs(c.G * 255 - g) < 12 and math.abs(c.B * 255 - b) < 12
end

local function sameColor(a, b)
	return math.abs(a.R - b.R) * 255 < 4 and math.abs(a.G - b.G) * 255 < 4 and math.abs(a.B - b.B) * 255 < 4
end

local function looksTeal(frame)
	if near(frame.BackgroundColor3, 0, 253, 192) then return true end
	if (frame:IsA("ImageLabel") or frame:IsA("ImageButton")) and near(frame.ImageColor3, 0, 253, 192) then
		return true
	end
	for _, g in ipairs(frame:GetChildren()) do
		if g:IsA("UIGradient") and near(g.Color.Keypoints[1].Value, 0, 253, 192) then
			return true
		end
	end
	return false
end

local function paintBar(frame, color)
	setProp(frame, "BackgroundColor3", color)
	if (frame:IsA("ImageLabel") or frame:IsA("ImageButton")) and not sameColor(frame.ImageColor3, color) then
		setProp(frame, "ImageColor3", color)
	end
	-- a UIGradient tints the frame, so it has to change too
	for _, g in ipairs(frame:GetChildren()) do
		if g:IsA("UIGradient") then
			local kp = g.Color.Keypoints
			if not (#kp == 2 and sameColor(kp[1].Value, color) and sameColor(kp[2].Value, color)) then
				setProp(g, "Color", ColorSequence.new(color))
			end
		end
	end
end

local function commas(s)
	local r = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (r:gsub("^,", ""))
end

-- swaps the first number in a (rich) text for `repl`, ignoring anything inside <tags>
local function replaceFirstNumber(text, repl)
	local out, i, done = {}, 1, false
	while i <= #text do
		local ts, te = text:find("<[^>]*>", i)
		local chunk = text:sub(i, (ts or (#text + 1)) - 1)
		if not done then
			local replaced, count = chunk:gsub("%d[%d,]*", repl, 1)
			if count > 0 then
				chunk = replaced
				done = true
			end
		end
		table.insert(out, chunk)
		if not ts then break end
		table.insert(out, text:sub(ts, te))
		i = te + 1
	end
	return table.concat(out)
end

------------------------------------------------------------------ rank data
local assets, imgErrors = {}, {}

local function currentDivision() return state.rank == "Nightmare" and 1 or state.division end

local function rankLabel()
	if state.rank == "Nightmare" then return "NIGHTMARE" end
	local name = (state.rank == "Emerald") and "EMERALD" or state.rank -- Diamond stays "Diamond"
	return name .. " " .. tostring(state.division)
end

local function lbText()
	return 'Leaderboard Rank: <b><font color="rgb(185,188,255)">' .. commas(state.lb) .. "</font></b>"
end

-- download each icon once and load it from a local file
for rank, url in pairs(ICON) do
	task.spawn(function()
		local ok, err = pcall(function()
			local fname = "rankicon_" .. rank .. ".png"
			writefile(fname, game:HttpGet(url))
			assets[rank] = getcustomasset(fname)
		end)
		if not ok then imgErrors[rank] = tostring(err) end
	end)
end

local function setImage(img)
	local a = assets[state.rank]
	if a then
		setProp(img, "Image", a)
		setProp(img, "ImageRectOffset", Vector2.new(0, 0))
		setProp(img, "ImageRectSize", Vector2.new(0, 0)) -- 0,0 = whole image
	else
		unsetProp(img, "Image")
		unsetProp(img, "ImageRectOffset")
		unsetProp(img, "ImageRectSize")
	end
end

------------------------------------------------------------------ edits
-- props changed on the CurrentRP label while Nightmare is selected
local RP_PROPS = { "Position", "AnchorPoint", "Size", "Text", "RichText", "TextSize",
	"TextScaled", "TextWrapped", "TextXAlignment", "TextColor3",
	"TextTransparency" }

local function plain(t) return (t:gsub("<[^>]*>", "")) end

-- the part of the RP bar that grows: a child named like "Fill"/"Curr..." if there is one, else ProgressBar
-- the game rewrites the RP text itself every few seconds; fix it the instant it does
local function hookRPText(lbl)
	if rpTextHooked[lbl] then return end
	rpTextHooked[lbl] = lbl:GetPropertyChangedSignal("Text"):Connect(function()
		if not enabled or state.rank == "Nightmare" then return end
		local t = lbl.Text
		if t:find("%d") then
			local rp = math.clamp(tonumber(state.rpTier) or 0, 0, 99)
			local new = replaceFirstNumber(t, tostring(rp))
			if new ~= t then lbl.Text = new end
		end
	end)
end

local function findFill(container)
	local bar = get(container, "ProgressBar")
	for _, d in ipairs(container:GetDescendants()) do
		if d:IsA("GuiObject") and d ~= bar then
			local n = d.Name:lower()
			if n:find("fill") or n:find("curr") then return d end
		end
	end
	return bar
end

-- Player Profile info texts: sorted by what they say, so it works whatever they are named
local function applyProfileInfo(info)
	local labels = {}
	for _, d in ipairs(info:GetChildren()) do
		if d:IsA("TextLabel") then table.insert(labels, d) end
	end
	local function origOf(d) return (originals[d] and originals[d].Text) or d.Text end

	local captionOnly = false -- a "Leaderboard Rank:" label whose number lives in another text
	local lbLabel, hasDecay = nil, false
	for _, d in ipairs(labels) do
		if d ~= profileClone then
			local o = plain(origOf(d))
			local lo = o:lower()
			if lo:find("leaderboard") then
				lbLabel = lbLabel or d
				if not o:find("%d") then captionOnly = true end
			elseif lo:find("decay") then
				hasDecay = true
			end
		end
	end

	-- the profile has no Rank Decay line of its own, so add one under the leaderboard line
	if lbLabel and not hasDecay then
		if not (profileClone and profileClone.Parent == lbLabel.Parent) then
			if profileClone then profileClone:Destroy() end
			profileClone = lbLabel:Clone()
			profileClone.Name = "RankDecay"
			profileClone.LayoutOrder = lbLabel.LayoutOrder + 1
			local hasLayout = false
			for _, c in ipairs(lbLabel.Parent:GetChildren()) do
				if c:IsA("UIListLayout") or c:IsA("UIGridLayout") or c:IsA("UITableLayout") then
					hasLayout = true
				end
			end
			if not hasLayout then
				profileClone.Position = lbLabel.Position + UDim2.new(0, 0, lbLabel.Size.Y.Scale, lbLabel.Size.Y.Offset)
			end
			profileClone.Parent = lbLabel.Parent
		end
		if profileClone.Text ~= DECAY_TEXT then profileClone.Text = DECAY_TEXT end
	end

	for _, d in ipairs(labels) do
		local o = plain(origOf(d))
		local lo = o:lower()
		if d == profileClone then
			-- our own Rank Decay line, leave it
		elseif lo:find("decay") then
			setProp(d, "Text", DECAY_TEXT)
		elseif lo:find("leaderboard") then
			if o:find("%d") then
				setProp(d, "Text", replaceFirstNumber(origOf(d), commas(state.lb)))
			end
		elseif not o:find("%a") then -- digits only
			if captionOnly then
				setProp(d, "Text", commas(state.lb))
			else
				setProp(d, "Text", tostring(currentDivision()))
			end
		else
			setProp(d, "Text", rankLabel()) -- EMERALD 2 / NIGHTMARE / Diamond 1, same as the board
		end
	end
end

-- one ranked row (the lobby board's row or the Player Profile's row)
local function applyRankRow(row, isProfile)
	-- rank image
	local img = get(row, "2")
	if img and img:IsA("ImageLabel") then
		if not isProfile then rankImage = img end
		setImage(img)
	end

	-- rank name, leaderboard rank, rank decay
	local info = get(row, "3", "2")
	if info then
		if isProfile then
			applyProfileInfo(info)
		else
			local rankName = get(info, "RankName")
			if rankName then setProp(rankName, "Text", rankLabel()) end

			local lb = get(info, "LeaderboardRank")
			if lb then
				setProp(lb, "RichText", true)
				setProp(lb, "Text", lbText())

				if not (clone and clone.Parent == lb.Parent) then
					if clone then clone:Destroy() end
					clone = lb:Clone()
					clone.Name = "RankDecay"
					clone.LayoutOrder = lb.LayoutOrder + 1

					local hasLayout = false
					for _, c in ipairs(lb.Parent:GetChildren()) do
						if c:IsA("UIListLayout") or c:IsA("UIGridLayout") or c:IsA("UITableLayout") then
							hasLayout = true
						end
					end
					if not hasLayout then
						clone.Position = lb.Position + UDim2.new(0, 0, lb.Size.Y.Scale, lb.Size.Y.Offset)
					end
					clone.Parent = lb.Parent
				end
				if clone.Text ~= DECAY_TEXT then clone.Text = DECAY_TEXT end
			end
		end
	end

	-- RP area: row > 3 > 3 holds ProgressBarContainer and CurrentRP
	local rpArea = get(row, "3", "3")
	if rpArea then
		local container = get(rpArea, "ProgressBarContainer")
		local currentRP = get(rpArea, "CurrentRP")

		if state.rank == "Nightmare" then
			if container then setProp(container, "Visible", false) end -- no RP bar at all
			if currentRP then
				setProp(rpArea, "ClipsDescendants", false)

				-- sit just under the Rank Decay line, lined up with the text column
				local x, y = 0, 84
				local dec = isProfile and profileClone or clone
				local anchor = (dec and dec.Parent) and dec or info
				if info and anchor then
					x = info.AbsolutePosition.X - rpArea.AbsolutePosition.X
					y = anchor.AbsolutePosition.Y + anchor.AbsoluteSize.Y - rpArea.AbsolutePosition.Y
				end

				setProp(currentRP, "AnchorPoint", Vector2.new(0, 0))
				setProp(currentRP, "Size", UDim2.new(0, 160, 0, 10))
				setProp(currentRP, "Position", UDim2.new(0, x, 0, y))
				setProp(currentRP, "TextScaled", false)
				setProp(currentRP, "TextWrapped", false)
				setProp(currentRP, "TextSize", 6)
				setProp(currentRP, "TextColor3", Color3.new(1, 1, 1)) -- white
				setProp(currentRP, "TextXAlignment", Enum.TextXAlignment.Left)
				setProp(currentRP, "TextTransparency", 0)
				setProp(currentRP, "RichText", true)
				setProp(currentRP, "Text", "<b>" .. commas(state.rp) .. " RP</b>") -- no "/ 100"
			end
		else
			unsetProp(rpArea, "ClipsDescendants")
			if currentRP then
				for _, p in ipairs(RP_PROPS) do unsetProp(currentRP, p) end
			end
			if container then
				unsetProp(container, "Visible")
				local bar = get(container, "ProgressBar")
				if bar then
					barFrames[bar] = true
					for _, f in ipairs(bar:GetDescendants()) do
						if f:IsA("GuiObject") and looksTeal(f) then
							barFrames[f] = true
						end
					end
				end
				local rp = math.clamp(tonumber(state.rpTier) or 0, 0, 99)
				local fill = findFill(container)
				-- the game keeps tweening/refreshing its own fill, so we hide it and draw our own bar
				for f, m in pairs(fillClones) do -- drop bars whose fill the game threw away
					if not f.Parent then
						pcall(function() m:Destroy() end)
						fillClones[f] = nil
						local c = fillConn[f]
						if c then
							c:Disconnect()
							fillConn[f] = nil
						end
					end
				end
				if fill and fill.Parent then
					local mine = fillClones[fill]
					if not (mine and mine.Parent == fill.Parent) then
						if mine then pcall(function() mine:Destroy() end) end
						mine = fill:Clone()
						mine.Name = "SpoofBar"
						mine.Parent = fill.Parent
						fillClones[fill] = mine
					end
					local ratio = rp / 100
					local cur = fill.Size
					local want = nil
					if cur.X.Offset == 0 then
						want = UDim2.new(ratio, 0, cur.Y.Scale, cur.Y.Offset)
					elseif fill.Parent:IsA("GuiObject") then
						want = UDim2.new(0, fill.Parent.AbsoluteSize.X * ratio, cur.Y.Scale, cur.Y.Offset)
					end
					if want and mine.Size ~= want then mine.Size = want end
					mine.Visible = true
					setProp(fill, "Visible", false)
					barFrames[mine] = true -- gets the rank colour like the real bar
					if not fillConn[fill] then
						fillConn[fill] = fill:GetPropertyChangedSignal("Visible"):Connect(function()
							if enabled and fillClones[fill] and fill.Visible then fill.Visible = false end
						end)
					end
				end
				if currentRP then
					hookRPText(currentRP)
					local base = (originals[currentRP] and originals[currentRP].Text) or currentRP.Text
					if base:find("%d") then
						setProp(currentRP, "Text", replaceFirstNumber(base, tostring(rp)))
					end
				end
				local color = RANKS[state.rank].bar
				for f in pairs(barFrames) do
					if f.Parent then
						paintBar(f, color)
					else
						barFrames[f] = nil
					end
				end
			end
		end
	end
end

local function applyBoard()
	local surface = get(workspace, "Lobby", "Boards", "StatsBoard", "Board", "StatsBoard")
	if not surface then return false end

	if not cachedScroll or not cachedScroll:IsDescendantOf(surface) then
		cachedScroll = surface:FindFirstChild("AutoCanvasScrollingFrame", true)
	end
	local row = cachedScroll and get(cachedScroll, "4", "4")
	if not row then return false end

	applyRankRow(row, false)
	return true
end

-- the bar above your own head: Character > Head > Nametag > RankDisplay
local function applyNametag()
	local char = Players.LocalPlayer.Character
	local icon = get(char, "Head", "Nametag", "RankDisplay")
	if icon and icon:IsA("ImageLabel") then
		setImage(icon)
	end
end

local function apply()
	pcall(applyNametag)
	return applyBoard()
end

------------------------------------------------------------------ Spoof Other edits
local function getScroll()
	local surface = get(workspace, "Lobby", "Boards", "StatsBoard", "Board", "StatsBoard")
	if not surface then return nil end
	if not cachedScroll or not cachedScroll:IsDescendantOf(surface) then
		cachedScroll = surface:FindFirstChild("AutoCanvasScrollingFrame", true)
	end
	return cachedScroll
end

-- swaps the first number in a text for `repl`; if there is no number, just uses `repl`
local function swapNumber(txt, repl)
	if not txt:find("%d") then return repl end
	return replaceFirstNumber(txt, repl)
end

-- AutoCanvasScrollingFrame > 5 > 3 > 2 holds the stat boxes; each has a text called "5"
local STAT_FRAMES = { honor = "2", wins = "3", bedBreaks = "4", finalKills = "5" }

local function applyStatGrid(grid)
	if not grid then return false end
	for key, frameName in pairs(STAT_FRAMES) do
		local lbl = get(grid, frameName, "5")
		if lbl and lbl:IsA("TextLabel") then
			setProp(lbl, "Text", state[key])
		end
	end
	return true
end

local function applyOtherBoard()
	local scroll = getScroll()
	if not scroll then return false end

	if not applyStatGrid(get(scroll, "5", "3", "2")) then return false end

	-- AutoCanvasScrollingFrame > 3 > 2 is the "Player Level" text
	local lvl = get(scroll, "3", "2")
	if lvl and lvl:IsA("TextLabel") then
		if not lvl.Text:find("%d") then
			setProp(lvl, "Text", "Player Level " .. state.level)
		else
			setProp(lvl, "Text", replaceFirstNumber(lvl.Text, state.level))
		end
		styleLevel(lvl)
	end

	-- XP text (AutoCanvasScrollingFrame > 3 > 3), shown as "cur / total"
	local xp = get(scroll, "3", "3")
	if xp and xp:IsA("TextLabel") then
		setProp(xp, "Text", state.xpCur .. " / " .. state.xpTotal)
	end

	-- progress bar (AutoCanvasScrollingFrame > 3 > ProgressBar > CurrProgress): level colour + fill
	local curr = get(scroll, "3", "ProgressBar", "CurrProgress")
	if curr and curr:IsA("GuiObject") then
		paintBar(curr, barColor(state.level))
		local total = tonumber(state.xpTotal) or 0
		if total > 0 then
			local ratio = math.clamp((tonumber(state.xpCur) or 0) / total, 0, 1)
			local sz = curr.Size
			if sz.X.Offset == 0 then -- only when the game sizes the fill by scale
				setProp(curr, "Size", UDim2.new(ratio, 0, sz.Y.Scale, sz.Y.Offset))
			end
		end
	end
	return true
end

-- nametag above your head: level in the "(200)" part, streak in a label named like "Streak"
local function applyOtherNametag()
	local tag = get(Players.LocalPlayer.Character, "Head", "Nametag")
	if not tag then return false, false end
	local lvlOk, streakOk = false, false
	for _, d in ipairs(tag:GetDescendants()) do
		if d:IsA("TextLabel") then
			local lname = d.Name:lower()
			if lname:find("streak") then
				setProp(d, "Text", swapNumber(d.Text, state.streak))
				streakOk = true
			elseif lname:find("level") or d.Text:find("%(%s*%d+%s*%)") then
				if d.Text:find("%(%s*%d+%s*%)") then
					setProp(d, "Text", (d.Text:gsub("%(%s*%d+%s*%)", "(" .. state.level .. ")", 1)))
				else
					setProp(d, "Text", swapNumber(d.Text, state.level))
				end
				-- colour it only when the label is just the level part, so other text keeps its colour
				if d.Text:find("^%s*%(%s*%d+%s*%)%s*$") then
					styleLevel(d)
				end
				lvlOk = true
			end
		end
	end
	return lvlOk, streakOk
end

-- Players > you > leaderstats > Wins
local function applyLeaderstats()
	local ls = get(Players.LocalPlayer, "leaderstats")
	local w = ls and get(ls, "Wins")
	if w and (w:IsA("IntValue") or w:IsA("NumberValue")) then
		setProp(w, "Value", tonumber(state.wins) or 0)
	end
end

local function deepFind(root, name)
	local lname = name:lower()
	for _, d in ipairs(root:GetDescendants()) do
		if d.Name:lower() == lname then return d end
	end
	return nil
end

local function firstPath(root, paths)
	for _, path in ipairs(paths) do
		local cur = root
		for _, n in ipairs(path) do
			cur = get(cur, n)
			if not cur then break end
		end
		if cur then return cur end
	end
	return nil
end

-- PlayerGui > PlayerProfile (only exists while the profile is open)
local function applyProfile()
	local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
	local pp = pg and get(pg, "PlayerProfile")
	if not pp then return false end

	local content = firstPath(pp, {
		{ "2", "1", "4", "PlayerProfileContent", "1", "AutoCanvasScrollingFrame" },
		{ "2", "4", "PlayerProfileContent", "1", "AutoCanvasScrollingFrame" },
	})
	if not content then
		local pc = deepFind(pp, "PlayerProfileContent")
		content = pc and deepFind(pc, "AutoCanvasScrollingFrame")
	end
	if content then
		if enabled then -- ranked row: AutoCanvasScrollingFrame > 3 > 4
			local row = get(content, "3", "4")
			if row then applyRankRow(row, true) end
		end
		if enabledOther then -- stats: AutoCanvasScrollingFrame > 4 > 3 > 2
			applyStatGrid(get(content, "4", "3", "2"))
		end
	end

	if enabledOther then -- level: PlayerInfo > 2 > Level > 2 ("Lv. 80")
		local lvl = firstPath(pp, {
			{ "2", "1", "4", "3", "2", "PlayerInfo", "2", "Level", "2" },
			{ "2", "4", "3", "2", "PlayerInfo", "2", "Level", "2" },
		})
		if not lvl then
			local pi = deepFind(pp, "PlayerInfo")
			lvl = pi and get(pi, "2", "Level", "2")
		end
		if lvl and lvl:IsA("TextLabel") then
			if lvl.Text:find("%d") then
				setProp(lvl, "Text", replaceFirstNumber(lvl.Text, state.level))
			else
				setProp(lvl, "Text", "Lv. " .. state.level)
			end
			styleLevel(lvl)
		end
	end
	return true
end

local function restore()
	for inst, props in pairs(originals) do
		for prop, val in pairs(props) do
			pcall(function() inst[prop] = val end)
		end
	end
	table.clear(originals)
	table.clear(barFrames)
	for f, m in pairs(fillClones) do pcall(function() m:Destroy() end) end
	table.clear(fillClones)
	for _, c in pairs(fillConn) do c:Disconnect() end
	table.clear(fillConn)
	for _, c in pairs(rpTextHooked) do c:Disconnect() end
	table.clear(rpTextHooked)
	for g in pairs(rainbows) do
		pcall(function() g:Destroy() end)
	end
	table.clear(rainbows)
	if clone then clone:Destroy() clone = nil end
	if profileClone then profileClone:Destroy() profileClone = nil end
end

------------------------------------------------------------------ Misc edits (all client-side)
local uiRoot = nil -- our ScreenGui, set once the UI exists
local miscMsg, miscKind = "Nothing on", "dim"
local function setMisc(msg, kind) miscMsg, miscKind = msg, kind or "dim" end
local miscConns = {}
local miscAlive = true

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function esc(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

---------------- User Spoofer + Display Spoofer
-- 1) every text on your screen (PlayerGui, CoreGui chat/leaderboard, nametags in the world) gets the
--    real name swapped for the fake one, 2) if the executor supports it, scripts that read your
--    Name / DisplayName get the fake values too.
local hookInstalled = false
local function installNameHook()
	if hookInstalled or not hookmetamethod then return end
	local cc = checkcaller or function() return false end
	local nc = newcclosure or function(f) return f end
	hookInstalled = pcall(function()
		local old
		old = hookmetamethod(game, "__index", nc(function(self, key)
			if enabledUserSpoof and self == LP and not cc() then
				if key == "Name" and spoofNames.name ~= "" then return spoofNames.name end
				if key == "DisplayName" and spoofNames.display ~= "" then return spoofNames.display end
			end
			return old(self, key)
		end))
	end)
end

local nameTexts, nameConn = {}, {}
local nameOrig, nameLast, nameSeen = {}, {}, {} -- per text: real text before our swap / text we wrote / text already checked
local nameTracked = false
local curPairs = {} -- {real, fake} pairs currently being swapped
local humOrig = nil -- { humanoid, original DisplayName } while we change your humanoid's display name
local function isTextObj(i) return i:IsA("TextLabel") or i:IsA("TextButton") or i:IsA("TextBox") end

local function namePairs()
	local list = {}
	local fn, fd = spoofNames.name, spoofNames.display
	if REAL_DISPLAY == REAL_NAME then
		local to = (fd ~= "" and fd) or fn
		if to ~= "" then table.insert(list, { REAL_NAME, to }) end
	else
		if fd ~= "" then table.insert(list, { REAL_DISPLAY, fd }) end
		if fn ~= "" then table.insert(list, { REAL_NAME, fn }) end
	end
	return list
end
local function refreshPairs()
	curPairs = namePairs()
	table.clear(nameSeen)
end

-- case-insensitive pattern for a plain string
local function ciPattern(str)
	return (esc(str):gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end))
end

-- swaps every real name in `str` for its fake in ONE pass (tokens in between, so a fake that
-- contains a real name never gets swapped twice); ALL CAPS matches give an ALL CAPS fake
local function computeNames(str, list)
	local new = str
	local low = str:lower()
	for i, p in ipairs(list) do
		if low:find(p[1]:lower(), 1, true) then
			new = new:gsub(ciPattern(p[1]), function(m)
				local caps = (m == m:upper() and m ~= m:lower()) and "U" or "N"
				return "\1" .. i .. caps .. "\2"
			end)
			low = new:lower()
		end
	end
	if new == str then return str end
	return (new:gsub("\1(%d+)([UN])\2", function(i, caps)
		local fake = list[tonumber(i)][2]
		return caps == "U" and fake:upper() or fake
	end))
end

-- swaps the names in one text right now. Always works from the REAL text, never from text we
-- already changed, so changing the fake name again can't get stuck
local function swapOne(inst)
	if not inst.Parent then return end
	if uiRoot and inst:IsDescendantOf(uiRoot) then return end
	if inst:IsA("TextBox") and inst:IsFocused() then return end
	local str = inst.Text
	if str == nameLast[inst] or str == nameSeen[inst] then return end -- our own write / already checked
	local new = (#curPairs > 0) and computeNames(str, curPairs) or str
	if new ~= str then
		nameOrig[inst], nameLast[inst], nameSeen[inst] = str, new, nil
		if not pcall(function() inst.Text = new end) then
			nameOrig[inst], nameLast[inst] = nil, nil
		end
	else
		nameOrig[inst], nameLast[inst], nameSeen[inst] = nil, nil, str
	end
end

-- every text gets swapped the moment it appears AND the moment its text changes,
-- so the real name never gets a frame on screen
local function addText(d)
	if nameTexts[d] then return end
	nameTexts[d] = true
	nameConn[d] = d:GetPropertyChangedSignal("Text"):Connect(function()
		if enabledUserSpoof then pcall(swapOne, d) end
	end)
	if enabledUserSpoof then pcall(swapOne, d) end
end
local function dropText(d)
	nameTexts[d] = nil
	nameOrig[d], nameLast[d], nameSeen[d] = nil, nil, nil
	local c = nameConn[d]
	if c then
		c:Disconnect()
		nameConn[d] = nil
	end
end
local function trackNameRoot(root)
	pcall(function()
		table.insert(miscConns, root.DescendantAdded:Connect(function(d)
			if isTextObj(d) then addText(d) end
		end))
		table.insert(miscConns, root.DescendantRemoving:Connect(function(d)
			if isTextObj(d) then dropText(d) end
		end))
		for _, d in ipairs(root:GetDescendants()) do
			if isTextObj(d) then addText(d) end
		end
	end)
end
local function trackNames()
	if nameTracked then return end
	nameTracked = true
	local roots = {}
	local function add(r)
		if r and not table.find(roots, r) then
			table.insert(roots, r)
			trackNameRoot(r)
		end
	end
	add(LP:FindFirstChild("PlayerGui"))
	add(workspace)
	local okC, cg = pcall(function() return game:GetService("CoreGui") end)
	if okC then add(cg) end
	local okH, hg = pcall(function() return gethui and gethui() end)
	if okH then add(hg) end
end

-- your own character's display name (the one above your head)
local function applyHumanoidName()
	local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local want = (spoofNames.display ~= "" and spoofNames.display) or spoofNames.name
	if want ~= "" then
		if not humOrig or humOrig[1] ~= hum then humOrig = { hum, hum.DisplayName } end
		if hum.DisplayName ~= want then hum.DisplayName = want end
	elseif humOrig and humOrig[1] == hum then
		hum.DisplayName = humOrig[2]
		humOrig = nil
	end
end

-- full pass over everything we know about (right after changes, plus as a safety net)
local function sweepNames()
	for inst in pairs(nameTexts) do
		if not inst.Parent then dropText(inst) else swapOne(inst) end
	end
	pcall(applyHumanoidName)
end

-- puts the real texts back (only where the text is still the one we wrote)
local function restoreNames()
	for inst, orig in pairs(nameOrig) do
		local last = nameLast[inst]
		nameOrig[inst], nameLast[inst] = nil, nil
		if inst.Parent and inst.Text == last then
			pcall(function() inst.Text = orig end)
		end
	end
	table.clear(nameSeen)
	if humOrig then
		local h, d = humOrig[1], humOrig[2]
		humOrig = nil
		pcall(function() if h.Parent then h.DisplayName = d end end)
	end
end

-- the fake names changed while the spoofer is on: rebuild every swapped text from its REAL text
local function reapplyNames()
	refreshPairs()
	for inst, orig in pairs(nameOrig) do
		if not inst.Parent then
			nameOrig[inst], nameLast[inst] = nil, nil
		elseif inst.Text == nameLast[inst] then
			local new = (#curPairs > 0) and computeNames(orig, curPairs) or orig
			if new ~= orig then
				nameLast[inst] = new -- set before writing so our own change event is ignored
			else
				nameLast[inst], nameOrig[inst] = nil, nil
			end
			pcall(function() inst.Text = new end)
		end
	end
	pcall(sweepNames)
end

---------------- background loop + cleanup
task.spawn(function()
	while miscAlive do
		if enabledUserSpoof then pcall(sweepNames) end -- safety net, the real swapping is event driven
		task.wait(0.4)
	end
end)

local function miscCleanup()
	miscAlive = false
	enabledUserSpoof = false
	pcall(restoreNames)
	for _, c in pairs(nameConn) do c:Disconnect() end
	table.clear(nameConn)
	for _, c in ipairs(miscConns) do c:Disconnect() end
end

------------------------------------------------------------------ UI
local conns = {}

local COL = {
	panel = Color3.fromRGB(16, 18, 25),
	header = Color3.fromRGB(23, 26, 36),
	card = Color3.fromRGB(26, 29, 40),
	field = Color3.fromRGB(35, 39, 53),
	stroke = Color3.fromRGB(46, 51, 68),
	text = Color3.fromRGB(235, 237, 245),
	dim = Color3.fromRGB(135, 141, 160),
	accent = Color3.fromRGB(99, 102, 241),
	accent2 = Color3.fromRGB(168, 85, 247),
	good = Color3.fromRGB(80, 200, 120),
	warn = Color3.fromRGB(235, 175, 70),
	bad = Color3.fromRGB(225, 90, 90),
	on = Color3.fromRGB(52, 199, 100),
	off = Color3.fromRGB(68, 73, 92),
}
local W, HEADER_H, CONTENT_H = 290, 48, 340
local UI_SCALE = 1.15 -- overall size of the panel
local viewH = (workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y) or 700
local H = math.min(HEADER_H + CONTENT_H, math.max(220, (viewH - 60) / UI_SCALE))
local QUICK = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function make(class, props, parent)
	local o = Instance.new(class)
	for k, v in pairs(props) do o[k] = v end
	o.Parent = parent
	return o
end
local function round(inst, r) return make("UICorner", { CornerRadius = UDim.new(0, r) }, inst) end
local function outline(inst, color) return make("UIStroke", { Color = color or COL.stroke, Thickness = 1 }, inst) end
local function gradient(inst, rot)
	return make("UIGradient", { Color = ColorSequence.new(COL.accent, COL.accent2), Rotation = rot or 0 }, inst)
end
local function text(parent, props)
	props.BackgroundTransparency = 1
	props.Font = props.Font or Enum.Font.GothamMedium
	props.TextSize = props.TextSize or 13
	props.TextColor3 = props.TextColor3 or COL.text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	return make("TextLabel", props, parent)
end
local function card(parent, y, h)
	local c = make("Frame", {
		Size = UDim2.new(1, -24, 0, h), Position = UDim2.fromOffset(12, y),
		BackgroundColor3 = COL.card, BorderSizePixel = 0,
	}, parent)
	round(c, 12)
	outline(c)
	return c
end
local function inputBox(parent, pos, w, placeholder, startText)
	local box = make("TextBox", {
		Size = UDim2.fromOffset(w, 30), AnchorPoint = Vector2.new(1, 0), Position = pos,
		BackgroundColor3 = COL.field, Font = Enum.Font.GothamMedium, TextSize = 13, TextColor3 = COL.text,
		PlaceholderText = placeholder, PlaceholderColor3 = COL.dim, ClearTextOnFocus = false, Text = startText,
	}, parent)
	round(box, 9)
	local s = outline(box)
	box.Focused:Connect(function() s.Color = COL.accent end)
	box.FocusLost:Connect(function() s.Color = COL.stroke end)
	return box
end
-- keeps a number box to digits only (max 7), shows the last valid value if left empty
local function bindNumber(box, key)
	box.FocusLost:Connect(function()
		local digits = box.Text:gsub("%D", ""):sub(1, 7)
		if digits ~= "" then state[key] = tostring(tonumber(digits)) end
		box.Text = state[key]
	end)
end

local sg = make("ScreenGui", { Name = "StatsSpoofUI", ResetOnSpawn = false, DisplayOrder = 999 }, guiParent)
uiRoot = sg

-- main panel
local panel = make("Frame", {
	Size = UDim2.fromOffset(W, H), Position = UDim2.fromOffset(20, 60),
	BackgroundColor3 = COL.panel, BorderSizePixel = 0,
}, sg)
round(panel, 16)
outline(panel)
local scale = make("UIScale", { Scale = UI_SCALE }, panel)

-- header
local titleBar = make("Frame", {
	Size = UDim2.new(1, 0, 0, HEADER_H), BackgroundColor3 = COL.header, BorderSizePixel = 0,
}, panel)
round(titleBar, 16)
make("Frame", { -- squares off the header's bottom corners
	Size = UDim2.new(1, 0, 0, 16), Position = UDim2.new(0, 0, 1, -16),
	BackgroundColor3 = COL.header, BorderSizePixel = 0,
}, titleBar)
local accentLine = make("Frame", {
	Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2),
	BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
}, titleBar)
gradient(accentLine, 0)

local logo = make("Frame", {
	Size = UDim2.fromOffset(30, 30), Position = UDim2.fromOffset(14, 9),
	BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
}, titleBar)
round(logo, 15)
gradient(logo, 45)
text(logo, {
	Size = UDim2.fromScale(1, 1), Text = "S", Font = Enum.Font.GothamBold, TextSize = 16,
	TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Center,
})
text(titleBar, {
	Size = UDim2.new(1, -130, 0, 18), Position = UDim2.fromOffset(52, 8), Text = "Stat Spoofer",
	Font = Enum.Font.GothamBold, TextSize = 15,
})
text(titleBar, {
	Size = UDim2.new(1, -130, 0, 14), Position = UDim2.fromOffset(52, 26), Text = "Made by 4gl",
	TextSize = 11, TextColor3 = COL.dim,
})

local function iconButton(txt, rightOffset, color)
	local b = make("TextButton", {
		Size = UDim2.fromOffset(28, 28), AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, rightOffset, 0.5, -1), BackgroundColor3 = COL.field,
		Font = Enum.Font.GothamBold, TextSize = 14, TextColor3 = color, Text = txt,
	}, titleBar)
	round(b, 9)
	return b
end
local minBtn = iconButton("-", -48, COL.text)
local closeBtn = iconButton("X", -12, Color3.fromRGB(240, 120, 120))

-- scrolling body
local body = make("ScrollingFrame", {
	Size = UDim2.new(1, 0, 1, -HEADER_H), Position = UDim2.fromOffset(0, HEADER_H),
	BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3, ScrollBarImageColor3 = COL.stroke,
	CanvasSize = UDim2.fromOffset(0, CONTENT_H), ScrollingDirection = Enum.ScrollingDirection.Y,
}, panel)

-- tab bar: Spoof Rank / Spoof Other / Misc
local tabBar = make("Frame", {
	Size = UDim2.new(1, -24, 0, 36), Position = UDim2.fromOffset(12, 12),
	BackgroundColor3 = COL.field, BorderSizePixel = 0,
}, body)
round(tabBar, 10)
local tabThumb = make("Frame", {
	Size = UDim2.new(1 / 3, -8, 1, -8), Position = UDim2.new(0, 4, 0, 4),
	BackgroundColor3 = COL.accent, BorderSizePixel = 0,
}, tabBar)
round(tabThumb, 8)
local function tabButton(label, index)
	return make("TextButton", {
		Size = UDim2.fromScale(1 / 3, 1), Position = UDim2.fromScale((index - 1) / 3, 0),
		BackgroundTransparency = 1, Text = label, Font = Enum.Font.GothamBold, TextSize = 11,
		TextColor3 = COL.dim, AutoButtonColor = false,
	}, tabBar)
end
local tabRank = tabButton("Spoof Rank", 1)
local tabOther = tabButton("Spoof Other", 2)
local tabMisc = tabButton("Misc", 3)

-- card A: master switch
local cardA = card(body, 58, 52)
local switchTitle = text(cardA, { Size = UDim2.fromOffset(170, 18), Position = UDim2.fromOffset(14, 8), Text = "Spoof Rank",
	Font = Enum.Font.GothamBold, TextSize = 14 })
text(cardA, { Size = UDim2.fromOffset(170, 14), Position = UDim2.fromOffset(14, 28), Text = "Only you can see these stats",
	TextSize = 11, TextColor3 = COL.dim })
local switch = make("TextButton", {
	Size = UDim2.fromOffset(50, 28), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0),
	Text = "", AutoButtonColor = false, BackgroundColor3 = COL.on,
}, cardA)
round(switch, 14)
local knob = make("Frame", {
	Size = UDim2.fromOffset(22, 22), Position = UDim2.new(1, -25, 0.5, -11),
	BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
}, switch)
round(knob, 11)

-- card B: rank + division / RP
local cardB = card(body, 120, 96)
text(cardB, { Size = UDim2.fromOffset(100, 30), Position = UDim2.fromOffset(14, 12), Text = "Rank" })
local ddBtn = make("TextButton", {
	Size = UDim2.fromOffset(150, 30), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 12),
	BackgroundColor3 = COL.field, AutoButtonColor = false, Text = "",
}, cardB)
round(ddBtn, 9)
outline(ddBtn)
local ddDot = make("Frame", {
	Size = UDim2.fromOffset(10, 10), Position = UDim2.fromOffset(10, 10), BorderSizePixel = 0,
	BackgroundColor3 = COL.accent,
}, ddBtn)
round(ddDot, 5)
local ddText = text(ddBtn, { Size = UDim2.new(1, -60, 1, 0), Position = UDim2.fromOffset(28, 0), Text = state.rank })
local ddArrow = text(ddBtn, {
	Size = UDim2.fromOffset(24, 30), Position = UDim2.new(1, -28, 0, 0), Text = "v", TextSize = 12,
	TextColor3 = COL.dim, TextXAlignment = Enum.TextXAlignment.Center,
})

-- division picker (hidden for Nightmare)
local divLabel = text(cardB, { Size = UDim2.fromOffset(100, 30), Position = UDim2.fromOffset(14, 54), Text = "Division" })
local divSeg = make("Frame", {
	Size = UDim2.fromOffset(136, 30), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 54),
	BackgroundColor3 = COL.field, BorderSizePixel = 0,
}, cardB)
round(divSeg, 9)
local thumb = make("Frame", {
	Size = UDim2.fromOffset(34, 30), BackgroundColor3 = COL.accent, BorderSizePixel = 0,
}, divSeg)
round(thumb, 9)
local divButtons = {}

-- RP input (Nightmare only, takes the division picker's place)
local rpLabel = text(cardB, { Size = UDim2.fromOffset(100, 30), Position = UDim2.fromOffset(14, 54), Text = "Current RP" })
local rpBox = inputBox(cardB, UDim2.new(1, -12, 0, 54), 136, "e.g. 1000", state.rp)
bindNumber(rpBox, "rp")

-- card C: leaderboard rank
local cardC = card(body, 226, 54)
text(cardC, { Size = UDim2.fromOffset(130, 30), Position = UDim2.fromOffset(14, 12), Text = "Leaderboard rank" })
local lbBox = inputBox(cardC, UDim2.new(1, -12, 0, 12), 100, "e.g. 1000", state.lb)
bindNumber(lbBox, "lb")

-- card D: RP for Emerald / Diamond (0-99), drives the RP bar fill (Nightmare has its own RP box)
local cardRP = card(body, 290, 54)
text(cardRP, { Size = UDim2.fromOffset(130, 30), Position = UDim2.fromOffset(14, 12), Text = "RP (0-99)" })
local rpTierBox = inputBox(cardRP, UDim2.new(1, -12, 0, 12), 100, "0-99", state.rpTier)
rpTierBox.FocusLost:Connect(function()
	local digits = rpTierBox.Text:gsub("%D", ""):sub(1, 3)
	local n = math.clamp(tonumber(digits) or tonumber(state.rpTier) or 0, 0, 99)
	state.rpTier = tostring(n)
	rpTierBox.Text = state.rpTier
end)

-- Spoof Other card
local cardOther = card(body, 120, 268)
cardOther.Visible = false
local OTHER_FIELDS = {
	{ "Wins", "wins" }, { "Bed Breaks", "bedBreaks" }, { "Final Kills", "finalKills" },
	{ "Honor", "honor" }, { "Level", "level", "e.g. 80" }, { "XP", "xp" },
	{ "Streak", "streak", "e.g. 5" },
}
for i, f in ipairs(OTHER_FIELDS) do
	local y = 12 + (i - 1) * 36
	if f[2] == "xp" then
		-- sub-row under Level: current XP / total XP
		text(cardOther, { Size = UDim2.fromOffset(60, 30), Position = UDim2.fromOffset(30, y), Text = "XP",
			TextColor3 = COL.dim })
		local curBox = inputBox(cardOther, UDim2.new(1, -98, 0, y), 70, "15000", state.xpCur)
		text(cardOther, { Size = UDim2.fromOffset(16, 30), Position = UDim2.new(1, -98, 0, y), Text = "/",
			Font = Enum.Font.GothamBold, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Center })
		local totBox = inputBox(cardOther, UDim2.new(1, -12, 0, y), 70, "52000", state.xpTotal)
		bindNumber(curBox, "xpCur")
		bindNumber(totBox, "xpTotal")
	else
		text(cardOther, { Size = UDim2.fromOffset(110, 30), Position = UDim2.fromOffset(14, y), Text = f[1] })
		local box = inputBox(cardOther, UDim2.new(1, -12, 0, y), 110, f[3] or "e.g. 1000", state[f[2]])
		bindNumber(box, f[2])
	end
end

-- Misc tab cards
local miscCards = {}
local function miscCard(y, h)
	local c = card(body, y, h)
	c.Visible = false
	table.insert(miscCards, c)
	return c
end
local function miscToggle(parent, title, desc, getOn, onFlip)
	text(parent, { Size = UDim2.fromOffset(180, 18), Position = UDim2.fromOffset(14, 8), Text = title,
		Font = Enum.Font.GothamBold, TextSize = 14 })
	text(parent, { Size = UDim2.fromOffset(180, 28), Position = UDim2.fromOffset(14, 28), Text = desc,
		TextSize = 11, TextColor3 = COL.dim, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top })
	local sw = make("TextButton", {
		Size = UDim2.fromOffset(50, 28), AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 19),
		Text = "", AutoButtonColor = false, BackgroundColor3 = COL.off,
	}, parent)
	round(sw, 14)
	local kn = make("Frame", {
		Size = UDim2.fromOffset(22, 22), Position = UDim2.new(0, 3, 0.5, -11),
		BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
	}, sw)
	round(kn, 11)
	local function refresh()
		local on = getOn()
		TweenService:Create(sw, QUICK, { BackgroundColor3 = on and COL.on or COL.off }):Play()
		TweenService:Create(kn, QUICK, {
			Position = on and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11),
		}):Play()
	end
	sw.Activated:Connect(function()
		onFlip()
		refresh()
	end)
end
-- label + text box; onCommit(text) runs when the box loses focus and returns the text to show
local function textRow(parent, y, label, placeholder, startText, indent, onCommit)
	text(parent, { Size = UDim2.fromOffset(110, 30), Position = UDim2.fromOffset(indent or 14, y), Text = label,
		TextColor3 = indent and COL.dim or COL.text })
	local box = inputBox(parent, UDim2.new(1, -12, 0, y), 130, placeholder, startText)
	box.FocusLost:Connect(function()
		box.Text = onCommit(trim(box.Text)) or box.Text
	end)
	return box
end

-- User Spoofer (+ Display Spoofer as the sub row)
local cardUser = miscCard(58, 138)
miscToggle(cardUser, "User Spoofer", "Spoofs your username everywhere",
	function() return enabledUserSpoof end,
	function()
		enabledUserSpoof = not enabledUserSpoof
		if enabledUserSpoof then
			refreshPairs()
			installNameHook()
			trackNames()
			pcall(sweepNames)
			local has = #curPairs > 0
			setMisc(has and "User Spoofer: active" or "User Spoofer: enter a username or display name",
				has and "good" or "warn")
		else
			restoreNames()
			setMisc("User Spoofer off", "dim")
		end
	end)
local function namesChanged()
	if enabledUserSpoof then
		reapplyNames()
	else
		refreshPairs()
	end
end
textRow(cardUser, 62, "Username", "fake username", spoofNames.name, nil, function(v)
	v = v:sub(1, 20)
	spoofNames.name = v
	namesChanged()
	return v
end)
textRow(cardUser, 98, "Display Spoofer", "fake display name", spoofNames.display, 22, function(v)
	v = v:sub(1, 20)
	spoofNames.display = v
	namesChanged()
	return v
end)

-- status text (plain text under the unload button)
local status = text(body, {
	Size = UDim2.new(1, -24, 0, 30), Position = UDim2.fromOffset(12, 330), TextSize = 11, TextWrapped = true,
	TextColor3 = COL.dim, Text = "Searching for board...", TextXAlignment = Enum.TextXAlignment.Center,
})

-- unload
local unloadBtn = make("TextButton", {
	Size = UDim2.new(1, -24, 0, 32), Position = UDim2.fromOffset(12, 294),
	BackgroundColor3 = Color3.fromRGB(46, 30, 36), Font = Enum.Font.GothamMedium, TextSize = 12,
	TextColor3 = Color3.fromRGB(240, 150, 150), Text = "Unload script (stops everything)",
}, body)
round(unloadBtn, 10)

-- Player Profile card (shared by the Rank and Other tabs)
local cardM = card(body, 290, 52)
text(cardM, { Size = UDim2.fromOffset(170, 18), Position = UDim2.fromOffset(14, 8), Text = "Player Profile",
	Font = Enum.Font.GothamBold, TextSize = 14 })
text(cardM, { Size = UDim2.fromOffset(170, 14), Position = UDim2.fromOffset(14, 28),
	Text = "Open Player Profile for it to work", TextSize = 11, TextColor3 = COL.dim })
local mSwitch = make("TextButton", {
	Size = UDim2.fromOffset(50, 28), AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0),
	Text = "", AutoButtonColor = false, BackgroundColor3 = COL.off,
}, cardM)
round(mSwitch, 14)
local mKnob = make("Frame", {
	Size = UDim2.fromOffset(22, 22), Position = UDim2.new(0, 3, 0.5, -11),
	BackgroundColor3 = Color3.new(1, 1, 1), BorderSizePixel = 0,
}, mSwitch)
round(mKnob, 11)


-- rank dropdown list (lives on the body so it draws above the cards)
local ddList = make("Frame", {
	Size = UDim2.fromOffset(150, 8 + #ORDER * 32 - 2), AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.fromOffset(W - 24 - 12 + 12, 120 + 12 + 30 + 4), BackgroundColor3 = COL.header,
	ZIndex = 20, Visible = false, BorderSizePixel = 0,
}, body)
round(ddList, 10)
outline(ddList)
local ddOptions = {}

-- minimised bubble
local bubble = make("TextButton", {
	Size = UDim2.fromOffset(50, 50), Position = panel.Position, BackgroundColor3 = Color3.new(1, 1, 1),
	Text = "", AutoButtonColor = false, Visible = false,
}, sg)
round(bubble, 25)
gradient(bubble, 45) -- a gradient also tints text, so the label is a separate child
text(bubble, {
	Size = UDim2.fromScale(1, 1), Text = "SS", Font = Enum.Font.GothamBold, TextSize = 16,
	TextColor3 = Color3.new(1, 1, 1), TextXAlignment = Enum.TextXAlignment.Center,
})
make("UIStroke", { Color = Color3.new(1, 1, 1), Transparency = 0.65, Thickness = 1.5 }, bubble)

------------------------------------------------------------------ UI behaviour
local function setStatus(msg, color)
	if status.Text ~= msg then status.Text = msg end
	if status.TextColor3 ~= color then status.TextColor3 = color end
end

local layoutHook = nil
local function refreshRankUI()
	local nm = state.rank == "Nightmare"
	ddText.Text = state.rank
	ddDot.BackgroundColor3 = RANKS[state.rank].dot

	divLabel.Visible = not nm -- Nightmare has no divisions, so no 1-4 picker
	divSeg.Visible = not nm
	rpLabel.Visible = nm -- the RP box takes that spot instead
	rpBox.Visible = nm

	if not nm then
		TweenService:Create(thumb, QUICK, { Position = UDim2.fromOffset((state.division - 1) * 34, 0) }):Play()
	end
	for i, b in ipairs(divButtons) do
		b.TextColor3 = (not nm and state.division == i) and Color3.new(1, 1, 1) or COL.dim
	end
	for name, o in pairs(ddOptions) do
		o.BackgroundColor3 = (name == state.rank) and COL.accent or COL.field
	end
	if layoutHook then layoutHook() end
end

for i = 1, 4 do
	local b = make("TextButton", {
		Size = UDim2.fromOffset(34, 30), Position = UDim2.fromOffset((i - 1) * 34, 0), BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold, TextSize = 13, Text = tostring(i), TextColor3 = COL.dim, AutoButtonColor = false,
	}, divSeg)
	b.Activated:Connect(function()
		if state.rank ~= "Nightmare" then
			state.division = i
			refreshRankUI()
		end
	end)
	divButtons[i] = b
end

local function setDropdown(open)
	ddList.Visible = open
	TweenService:Create(ddArrow, QUICK, { Rotation = open and 180 or 0 }):Play()
end
for idx, name in ipairs(ORDER) do
	local o = make("TextButton", {
		Size = UDim2.new(1, -8, 0, 30), Position = UDim2.fromOffset(4, 4 + (idx - 1) * 32),
		BackgroundColor3 = COL.field, AutoButtonColor = true, Text = "", ZIndex = 21,
	}, ddList)
	round(o, 8)
	local d = make("Frame", {
		Size = UDim2.fromOffset(10, 10), Position = UDim2.fromOffset(10, 10), BorderSizePixel = 0,
		BackgroundColor3 = RANKS[name].dot, ZIndex = 22,
	}, o)
	round(d, 5)
	text(o, { Size = UDim2.new(1, -30, 1, 0), Position = UDim2.fromOffset(28, 0), Text = name, ZIndex = 22 })
	o.Activated:Connect(function()
		state.rank = name
		setDropdown(false)
		refreshRankUI()
	end)
	ddOptions[name] = o
end
ddBtn.Activated:Connect(function() setDropdown(not ddList.Visible) end)
refreshRankUI()

local function refreshSwitch()
	if mode == "misc" then
		setStatus(miscMsg, COL[miscKind] or COL.dim)
		return
	end
	local on = (mode == "rank") and enabled or ((mode == "other") and enabledOther)
	TweenService:Create(switch, QUICK, { BackgroundColor3 = on and COL.on or COL.off }):Play()
	TweenService:Create(knob, QUICK, {
		Position = on and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11),
	}):Play()
	if mode == "other" then
		if enabledOther then
			setStatus("Searching for board...", COL.warn)
		else
			setStatus("Off - showing your real stats", COL.dim)
		end
	elseif not enabled then
		setStatus("Off - showing your real stats", COL.dim)
	end
end
switch.Activated:Connect(function()
	if mode == "rank" then
		enabled = not enabled
		if not enabled then restore() end
	else
		enabledOther = not enabledOther
		if not enabledOther then restore() end
	end
	refreshSwitch()
end)


local function refreshProfile()
	TweenService:Create(mSwitch, QUICK, { BackgroundColor3 = enabledProfile and COL.on or COL.off }):Play()
	TweenService:Create(mKnob, QUICK, {
		Position = enabledProfile and UDim2.new(1, -25, 0.5, -11) or UDim2.new(0, 3, 0.5, -11),
	}):Play()
end
mSwitch.Activated:Connect(function()
	enabledProfile = not enabledProfile
	if not enabledProfile then restore() end
	refreshProfile()
end)


local function layout()
	local isRank = (mode == "rank")
	local showRP = isRank and state.rank ~= "Nightmare"
	cardRP.Visible = showRP
	local mY = isRank and (showRP and 354 or 290) or 398
	cardM.Position = UDim2.fromOffset(12, mY)
	local unloadY = (mode == "misc") and 206 or (mY + 64)
	unloadBtn.Position = UDim2.fromOffset(12, unloadY)
	status.Position = UDim2.fromOffset(12, unloadY + 38)
	body.CanvasSize = UDim2.fromOffset(0, unloadY + 80)
end
layoutHook = layout

local function setMode(m)
	mode = m
	local isRank, isOther, isMisc = (m == "rank"), (m == "other"), (m == "misc")
	cardA.Visible = not isMisc
	cardB.Visible = isRank
	cardC.Visible = isRank
	cardOther.Visible = isOther
	cardM.Visible = not isMisc
	for _, c in ipairs(miscCards) do c.Visible = isMisc end
	setDropdown(false)
	switchTitle.Text = isRank and "Spoof Rank" or "Spoof Other"
	local idx = isRank and 1 or (isOther and 2 or 3)
	TweenService:Create(tabThumb, QUICK, {
		Position = UDim2.new((idx - 1) / 3, 4, 0, 4),
	}):Play()
	tabRank.TextColor3 = isRank and Color3.new(1, 1, 1) or COL.dim
	tabOther.TextColor3 = isOther and Color3.new(1, 1, 1) or COL.dim
	tabMisc.TextColor3 = isMisc and Color3.new(1, 1, 1) or COL.dim
	layout()
	refreshSwitch()
end
tabRank.Activated:Connect(function() setMode("rank") end)
tabOther.Activated:Connect(function() setMode("other") end)
tabMisc.Activated:Connect(function() setMode("misc") end)
setMode("rank") -- starts on Spoof Rank with the switch OFF

-- window modes: open panel / small bubble / hidden (edits keep running)
local function openPanel()
	panel.Position = bubble.Position
	panel.Visible = true
	bubble.Visible = false
	setDropdown(false)
	scale.Scale = UI_SCALE * 0.92
	TweenService:Create(scale, QUICK, { Scale = UI_SCALE }):Play()
end
local function minimise()
	bubble.Position = panel.Position
	panel.Visible = false
	bubble.Visible = true
end
local function hideUI()
	if panel.Visible then bubble.Position = panel.Position end
	panel.Visible = false
	bubble.Visible = false
end
env.StatsSpoofShow = openPanel

minBtn.Activated:Connect(minimise)
closeBtn.Activated:Connect(hideUI) -- edits keep running

local unloadToken, unloadArmed = 0, false
local UNLOAD_TEXT = "Unload script (stops everything)"

local function unload()
	unloadToken += 1
	enabled = false
	enabledOther = false
	pcall(miscCleanup)
	env.StatsSpoofShow = nil
	pcall(function() RunService:UnbindFromRenderStep("StatsSpoof") end)
	restore()
	for _, c in ipairs(conns) do c:Disconnect() end
	sg:Destroy()
end
unloadBtn.Activated:Connect(function()
	if unloadArmed then
		unload()
		return
	end
	-- first tap: arm for 5 seconds with a countdown, then reset
	unloadArmed = true
	unloadToken += 1
	local mine = unloadToken
	task.spawn(function()
		for t = 5, 1, -1 do
			if unloadToken ~= mine then return end
			unloadBtn.Text = "Double Tap To Confirm (" .. t .. ")"
			task.wait(1)
		end
		if unloadToken ~= mine then return end
		unloadArmed = false
		unloadBtn.Text = UNLOAD_TEXT
	end)
end)

-- dragging (header drags the panel, the bubble drags itself; a tap on the bubble opens)
local function isPointer(i)
	return i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseButton1
end
local function makeDraggable(handle, target, onTap)
	local dragging, moved, dragStart, startPos = false, false, nil, nil
	handle.InputBegan:Connect(function(i)
		if isPointer(i) then
			dragging, moved = true, false
			dragStart, startPos = i.Position, target.Position
		end
	end)
	table.insert(conns, UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.Touch or i.UserInputType == Enum.UserInputType.MouseMovement) then
			local d = i.Position - dragStart
			if d.Magnitude > 6 then moved = true end
			target.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end))
	table.insert(conns, UIS.InputEnded:Connect(function(i)
		if dragging and isPointer(i) then
			dragging = false
			if not moved and onTap then onTap() end
		end
	end))
end
makeDraggable(titleBar, panel, nil)
makeDraggable(bubble, bubble, openPanel)

------------------------------------------------------------------ loop
-- runs last every frame, so the game's own refresh can't stick for 3 seconds
RunService:BindToRenderStep("StatsSpoof", Enum.RenderPriority.Last.Value, function()
	if not enabled and not enabledOther then return end

	local ok, found
	if enabled then ok, found = pcall(apply) end

	if enabledProfile then pcall(applyProfile) end
	if enabledOther then pcall(applyLeaderstats) end

	local otherMsg, otherColor
	if enabledOther then
		local okB, boardOk = pcall(applyOtherBoard)
		local okT, lvlOk, streakOk = pcall(applyOtherNametag)
		if not (okB and boardOk) then
			otherMsg, otherColor = "Board not found - stand near the stats board", COL.warn
		elseif okT and lvlOk and streakOk then
			otherMsg, otherColor = "Active - stats applied", COL.good
		else
			local miss = {}
			if not (okT and lvlOk) then table.insert(miss, "level") end
			if not (okT and streakOk) then table.insert(miss, "streak") end
			otherMsg, otherColor = "Active - board done, nametag " .. table.concat(miss, " + ") .. " label not found", COL.warn
		end
	end

	if mode == "misc" then return end -- the Misc tab has its own status text

	if mode == "other" then
		if otherMsg then setStatus(otherMsg, otherColor) end
		return
	end
	if not enabled then return end

	if imgErrors[state.rank] then
		setStatus("Icon download failed: " .. imgErrors[state.rank], COL.bad)
	elseif not assets[state.rank] then
		setStatus("Downloading icons...", COL.warn)
	elseif not (ok and found) then
		setStatus("Board not found (nametag still active) - stand near the stats board", COL.warn)
	elseif rankImage and rankImage:IsA("ImageLabel") and not rankImage.IsLoaded then
		setStatus("Active - icon still loading", COL.warn)
	else
		setStatus("Active - " .. rankLabel() .. " applied", COL.good)
	end
end)

-- keeps the Misc tab's status line current while that tab is open
task.spawn(function()
	while miscAlive do
		if mode == "misc" then setStatus(miscMsg, COL[miscKind] or COL.dim) end
		task.wait(0.3)
	end
end)
