-- CleanRolls: a floating window that tracks group loot rolls (Need/Greed/etc)
-- in real time, lets you roll from it, and fades out once the winner is announced.

local PLAYER_NAME = UnitName("player")

CleanRollsDB = CleanRollsDB or {}

-- Delayed one-shot callback. Used by /cr test to make fake rolls trickle
-- in one at a time instead of all appearing at once. Prefers ClassicAPI's
-- real C_Timer.After when present; falls back to a plain OnUpdate-driven
-- queue (checked against the same ticker below) so this doesn't hard-require
-- the DLL mod being installed.
local pendingTasks = {}
local function ScheduleTask(delay, fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, fn)
    else
        table.insert(pendingTasks, {time = GetTime() + delay, fn = fn})
    end
end

-- RollFor items that have been announced but not yet resolved, oldest
-- first - see the "RollFor integration" section below for the full
-- explanation. Declared up here (rather than down there with the rest of
-- that section) because DoRollForNeed, defined earlier in the file, needs
-- to reference it directly.
local rollforPending = {}

-- The one item RollFor's addon-comm broadcast says is currently open for
-- rolling, mirroring RollFor's own internal `currently_displayed_item` -
-- see the "RollFor addon-comm integration" section below. Declared here
-- for the same reason as rollforPending above: HandleSystemRollLine,
-- defined earlier in the file, needs to reference it directly.
local currentRollForItem = nil

-- ===================== Config =====================

local DISPLAY_HOLD_TIME = 5.5   -- seconds to keep a finished/won item visible before fading
local FADE_TIME = 1.0           -- seconds to fade out over
local STALE_TIMEOUT = 90        -- seconds of no activity before we give up on a roll with no winner line
local ROLL_TIMEOUT_GRACE = 3    -- extra seconds after a roll timer hits 0 before we start the fade
local WINNER_FLASH_DURATION = 1.0 -- seconds for the winning row's white-to-green flash

local PANEL_WIDTH = 230
local ICON_SIZE = 20
local ROW_HEIGHT = 14
local TIMERBAR_HEIGHT = 6
local PAD = 6
local ANCHOR_HEIGHT = 18

local ROLL_COLORS = {
    NEED       = {1.00, 0.55, 0.05},
    GREED      = {0.30, 0.70, 1.00},
    DISENCHANT = {0.65, 0.35, 0.90},
    PASS       = {0.55, 0.55, 0.55},
    OFFSPEC    = {0.40, 0.85, 0.55}, -- RollFor /roll 99
    TRANSMOG   = {0.85, 0.55, 0.90}, -- RollFor /roll 98
    ROLL       = {0.60, 0.85, 1.00}, -- unrecognized roll range, used as a fallback
}
local ROLL_PRIORITY = { NEED = 1, GREED = 2, DISENCHANT = 3, PASS = 4, OFFSPEC = 2, TRANSMOG = 3, ROLL = 1 }

-- RollFor convention: the roll RANGE itself is the priority - /roll (100) is
-- Need/main-spec, /roll 99 is off-spec, /roll 98 is transmog. Mapping the max
-- of the range to a kind means these sort and group the same way Need beats
-- Greed does (a Need-range roll of 10 correctly outranks an Offspec-range
-- roll of 95), not just by raw roll value.
local ROLL_RANGE_KIND = {
    [100] = "NEED",
    [99]  = "OFFSPEC",
    [98]  = "TRANSMOG",
}

local function RollColor(kind)
    return ROLL_COLORS[kind] or {0.8, 0.8, 0.8}
end

-- ===================== House style =====================
-- Matches the rest of this addon family (CombatLedger/LootLedger): a flat
-- near-black WHITE8X8 backdrop with a soft drop shadow and the Expressway
-- font, or pfUI's own skin directly when pfUI is loaded. The font/shadow/
-- bar textures are bundled from pfUI (fonts/Expressway.ttf, img/glow2.tga,
-- img/bar.tga), MIT-licensed - https://github.com/shagu/pfUI by Eric Mauser
-- (Shagu) - same assets CombatLedger already bundles, copied here so this
-- addon looks identical without depending on CombatLedger being installed.

local function HasPfui()
    return IsAddOnLoaded and IsAddOnLoaded("pfUI") and pfUI and pfUI.api
end

local FONT_PATH = "Interface\\AddOns\\CleanRolls\\fonts\\Expressway.ttf"
local function GetFontPath()
    if HasPfui() and pfUI.font_default then
        return pfUI.font_default
    end
    return FONT_PATH
end

local function ApplyFont(fontString, size)
    fontString:SetFont(GetFontPath(), size or 10, "OUTLINE")
end

local function GetBarTexture()
    if HasPfui() and pfUI.media and pfUI.media["img:bar"] then
        return pfUI.media["img:bar"]
    end
    return "Interface\\AddOns\\CleanRolls\\img\\bar"
end

-- Brand accent - matches LootLedger's own epic-item-quality purple
-- (#A335EE), used for chrome text (the anchor title) - NOT for roll-type
-- colors or item-quality borders, which stay their own semantic colors.
local ACCENT_R, ACCENT_G, ACCENT_B = 0.64, 0.21, 0.93
local ACCENT_HEX = "a335ee"

local FLAT_BORDER = {0.059, 0.059, 0.059}

local WINDOW_BACKDROP = {
    bgFile = "Interface\\BUTTONS\\WHITE8X8", tile = false, tileSize = 0,
    edgeFile = "Interface\\BUTTONS\\WHITE8X8", edgeSize = 1,
    insets = {left = -1, right = -1, top = -1, bottom = -1},
}

local WINDOW_SHADOW = {
    edgeFile = "Interface\\AddOns\\CleanRolls\\img\\glow2", edgeSize = 8,
    insets = {left = 0, right = 0, top = 0, bottom = 0},
}

local STRATA_ORDER = {"BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "FULLSCREEN_DIALOG", "TOOLTIP"}
local function NextLowerStrata(strata)
    for i = 1, table.getn(STRATA_ORDER) do
        if STRATA_ORDER[i] == strata then
            return STRATA_ORDER[math.max(1, i - 1)]
        end
    end
    return "BACKGROUND"
end

-- Skins a window frame flat near-black (or pfUI's own skin, when pfUI is
-- loaded) with a soft drop shadow - mirrors CombatLedger's CL.ApplyWindowSkin.
local function ApplyWindowSkin(f, alpha)
    if HasPfui() then
        local ok = pcall(function()
            pfUI.api.CreateBackdrop(f)
            pfUI.api.CreateBackdropShadow(f)
        end)
        if ok and f.backdrop then
            f:SetBackdrop(nil)
            f.backdrop:Show()
            if f.backdrop_shadow then f.backdrop_shadow:Show() end
            return
        end
    end

    if f.backdrop then f.backdrop:Hide() end
    if f.backdrop_shadow then f.backdrop_shadow:Hide() end
    f:SetBackdrop(WINDOW_BACKDROP)
    f:SetBackdropColor(0, 0, 0, alpha or 0.8)
    f:SetBackdropBorderColor(FLAT_BORDER[1], FLAT_BORDER[2], FLAT_BORDER[3], 1)

    if not f.flatShadow then
        f.flatShadow = CreateFrame("Frame", nil, f)
        f.flatShadow:SetFrameStrata(NextLowerStrata(f:GetFrameStrata()))
        f.flatShadow:SetFrameLevel(1)
        f.flatShadow:SetPoint("TOPLEFT", f, "TOPLEFT", -5, 5)
        f.flatShadow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 5, -5)
        f.flatShadow:SetBackdrop(WINDOW_SHADOW)
        f.flatShadow:SetBackdropBorderColor(0, 0, 0, 0.35)
    end
    f.flatShadow:Show()
end

-- ===================== Item link helpers =====================

local function ExtractItemFromText(text)
    local _, _, itemID, suffixID = string.find(text, "item:(%d+):%d+:(%d+)")
    if not itemID then return nil end
    local _, _, name = string.find(text, "%[(.-)%]")
    return itemID, (suffixID or "0"), name
end

local function ItemKey(itemID, suffixID)
    return tostring(itemID) .. ":" .. tostring(suffixID or "0")
end

local function ItemStringForKey(key)
    local _, _, itemID, suffixID = string.find(key, "^(%d+):(%d+)$")
    return "item:" .. (itemID or key) .. ":0:" .. (suffixID or "0") .. ":0"
end

-- ===================== Data model =====================

local active = {}   -- itemKey -> data
local order = {}    -- ordered list of itemKeys currently displayed

local function NewItemData(itemKey, itemName, itemLink, texture, quality)
    return {
        itemKey = itemKey,
        itemName = itemName or "Unknown Item",
        itemLink = itemLink,
        icon = texture,
        quality = quality,
        rolls = {},        -- array of {name, kind, value, isSelf}
        rollsByName = {},  -- name -> index into rolls
        winner = nil,      -- {name, isSelf}
        rollID = nil,
        rollTime = nil,
        canRoll = false,
        hasRolled = false,
        createdAt = GetTime(),
        lastActivity = GetTime(),
        fading = false,
        fadeStart = nil,
        panel = nil,
    }
end

local function GetOrCreateItem(itemKey, itemName, itemLink)
    local data = active[itemKey]
    if data then
        data.lastActivity = GetTime()
        if data.fading then
            -- new activity on an item that was about to disappear: keep it
            data.fading = false
            data.fadeStart = nil
            if data.panel then data.panel:SetAlpha(1) end
        end
        return data
    end

    -- texture is the 9th return value on this client (name, link, quality,
    -- ilvl, itype, isub, stack, equip, texture, ...) - confirmed against
    -- LootLedger's own working GetItemInfo call, NOT the 10th like stock
    -- vanilla's documented signature. Getting this off by one silently
    -- grabs sellPrice (a number) as if it were a texture path, which
    -- SetTexture doesn't error on - it just renders as the red
    -- missing-texture placeholder instead of failing loudly.
    local texture, name, quality
    if GetItemInfo then
        local iName, iLink, iQuality, _, _, _, _, _, iTexture = GetItemInfo(ItemStringForKey(itemKey))
        texture, name, quality = iTexture, iName, iQuality
    end

    data = NewItemData(itemKey, name or itemName, itemLink, texture, quality)
    active[itemKey] = data
    table.insert(order, itemKey)
    return data
end

local function AddOrUpdateRoll(data, name, kind, value)
    local isSelf = (name == PLAYER_NAME or name == "You")
    if isSelf then name = PLAYER_NAME end

    local idx = data.rollsByName[name]
    if idx then
        data.rolls[idx].kind = kind
        if value ~= nil then
            data.rolls[idx].value = value -- never erase an already-known value with a later nil ("has selected...") update
        end
    else
        table.insert(data.rolls, {name = name, kind = kind, value = value, isSelf = isSelf})
        data.rollsByName[name] = table.getn(data.rolls)
    end

    if isSelf then
        data.hasRolled = true
    end
    data.lastActivity = GetTime()
end

-- ===================== UI: anchor =====================

local anchor = CreateFrame("Frame", "CleanRollsAnchor", UIParent)
anchor:SetWidth(PANEL_WIDTH)
anchor:SetHeight(ANCHOR_HEIGHT)
anchor:SetFrameStrata("MEDIUM")
anchor:SetMovable(true)
anchor:EnableMouse(true)
anchor:RegisterForDrag("LeftButton")
anchor:SetScript("OnDragStart", function() this:StartMoving() end)
anchor:SetScript("OnDragStop", function()
    this:StopMovingOrSizing()
    local point, _, relPoint, x, y = this:GetPoint()
    CleanRollsDB.point = point
    CleanRollsDB.relPoint = relPoint
    CleanRollsDB.x = x
    CleanRollsDB.y = y
end)

ApplyWindowSkin(anchor, 0.8)
anchor:SetAlpha(0.9)

anchor.text = anchor:CreateFontString(nil, "OVERLAY")
ApplyFont(anchor.text, 10)
anchor.text:SetPoint("CENTER", anchor, "CENTER", 0, 0)
anchor.text:SetText("|cff" .. ACCENT_HEX .. "Loot Rolls|r")

-- Just a safe default for right now - this client restores SavedVariables
-- from disk AFTER an addon's .lua files finish executing, wholesale
-- REPLACING the CleanRollsDB table the rest of this file has been reading
-- from, rather than merging into it (see the memory note on this). Reading
-- CleanRollsDB.point/.locked here at top-level file-exec time would only
-- ever see an empty table on every load after the first, so the real saved
-- position/lock state gets (re-)applied from ApplySavedAnchorState below,
-- called once PLAYER_LOGIN fires - well after that replacement has happened.
anchor:SetPoint("RIGHT", UIParent, "RIGHT", -20, 150)

local function ApplySavedAnchorState()
    if CleanRollsDB.point then
        anchor:ClearAllPoints()
        anchor:SetPoint(CleanRollsDB.point, UIParent, CleanRollsDB.relPoint, CleanRollsDB.x, CleanRollsDB.y)
    end
    if CleanRollsDB.locked then
        anchor:Hide()
    else
        anchor:Show()
    end
end

-- ===================== UI: panels =====================

local panelPool = {}
local WireButtons -- forward declaration; defined below, used at panel-creation time

local function AcquirePanel()
    for _, p in ipairs(panelPool) do
        if not p.inUse then
            p.inUse = true
            return p
        end
    end

    local p = CreateFrame("Frame", nil, UIParent)
    p:SetWidth(PANEL_WIDTH)
    p:SetFrameStrata("MEDIUM")
    ApplyWindowSkin(p, 0.8)

    -- Icon border/crop/highlight matches LootLedger's GetIconButton exactly:
    -- a 1px WHITE8X8 edge on the button's own backdrop (BACKGROUND layer),
    -- tinted to the item's quality color, with the icon texture (ARTWORK
    -- layer) inset 1px and cropped 8% to hide the faint bezel every
    -- Blizzard icon texture ships with.
    p.icon = CreateFrame("Button", nil, p)
    p.icon:SetWidth(ICON_SIZE)
    p.icon:SetHeight(ICON_SIZE)
    p.icon:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, -PAD)
    p.icon:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    p.icon:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)

    p.icon.tex = p.icon:CreateTexture(nil, "ARTWORK")
    p.icon.tex:SetPoint("TOPLEFT", p.icon, "TOPLEFT", 1, -1)
    p.icon.tex:SetPoint("BOTTOMRIGHT", p.icon, "BOTTOMRIGHT", -1, 1)
    p.icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    p.icon:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    p.icon:SetScript("OnEnter", function()
        if not this.itemLink then return end
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(this.itemLink)
        GameTooltip:Show()
    end)
    p.icon:SetScript("OnLeave", function() GameTooltip:Hide() end)

    p.rows = {}

    -- Roll buttons: the stock Blizzard group-loot dice/coin/pass icons
    -- (Interface\Buttons\UI-GroupLoot-*) - same ones pfUI's own roll
    -- module points at, but they ship in the base client itself, so using
    -- them doesn't require pfUI to be installed. Sit in the header row, to
    -- the right of the item name, instead of a separate button row.
    p.needBtn = CreateFrame("Button", nil, p)
    p.needBtn:SetWidth(ICON_SIZE)
    p.needBtn:SetHeight(ICON_SIZE)
    p.needBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Dice-Up")
    p.needBtn:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Dice-Down")
    p.needBtn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Dice-Highlight")

    p.greedBtn = CreateFrame("Button", nil, p)
    p.greedBtn:SetWidth(ICON_SIZE)
    p.greedBtn:SetHeight(ICON_SIZE)
    p.greedBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Coin-Up")
    p.greedBtn:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Coin-Down")
    p.greedBtn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Coin-Highlight")

    p.passBtn = CreateFrame("Button", nil, p)
    p.passBtn:SetWidth(ICON_SIZE)
    p.passBtn:SetHeight(ICON_SIZE)
    p.passBtn:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    p.passBtn:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
    p.passBtn:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Coin-Highlight")

    -- left-to-right reading order (Need, Greed, Pass) means anchoring from
    -- the right edge inward starting with Pass, not Need
    p.passBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, -PAD)
    p.greedBtn:SetPoint("RIGHT", p.passBtn, "LEFT", -2, 0)
    p.needBtn:SetPoint("RIGHT", p.greedBtn, "LEFT", -2, 0)

    local function RollTooltip(label)
        return function()
            GameTooltip:SetOwner(this, "ANCHOR_LEFT")
            GameTooltip:SetText(label)
            GameTooltip:Show()
        end
    end
    p.needBtn:SetScript("OnEnter", RollTooltip("Need"))
    p.greedBtn:SetScript("OnEnter", RollTooltip("Greed"))
    p.passBtn:SetScript("OnEnter", RollTooltip("Pass"))
    p.needBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p.greedBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    p.passBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    p.name = p:CreateFontString(nil, "OVERLAY")
    ApplyFont(p.name, 10)
    p.name:SetPoint("LEFT", p.icon, "RIGHT", 6, 0)
    p.name:SetPoint("RIGHT", p, "RIGHT", -PAD, 0) -- pulled in to p.passBtn per-refresh while buttons are shown
    p.name:SetJustifyH("LEFT")

    -- Real countdown (we hold a rollID - GetLootRollTimeLeft is authoritative)
    p.timerBar = CreateFrame("StatusBar", nil, p)
    p.timerBar:SetWidth(PANEL_WIDTH - PAD * 2)
    p.timerBar:SetHeight(TIMERBAR_HEIGHT)
    p.timerBar:SetStatusBarTexture(GetBarTexture())
    p.timerBar:SetStatusBarColor(0.9, 0.75, 0.2)
    p.timerBar:SetMinMaxValues(0, 1)

    -- Estimated status (we're only observing via chat, no rollID - so no real
    -- deadline to show) - counts elapsed time up instead of a fake countdown.
    p.statusText = p:CreateFontString(nil, "OVERLAY")
    ApplyFont(p.statusText, 9)
    p.statusText:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, 0) -- repositioned per-refresh
    p.statusText:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
    p.statusText:SetJustifyH("LEFT")
    p.statusText:SetTextColor(0.6, 0.6, 0.6)

    p.winnerText = p:CreateFontString(nil, "OVERLAY")
    ApplyFont(p.winnerText, 10)
    p.winnerText:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, 0) -- repositioned per-refresh
    p.winnerText:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
    p.winnerText:SetJustifyH("LEFT")

    -- SR/HR badge - only populated for items announced by RollFor
    p.srText = p:CreateFontString(nil, "OVERLAY")
    ApplyFont(p.srText, 9)
    p.srText:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, 0) -- repositioned per-refresh
    p.srText:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
    p.srText:SetJustifyH("LEFT")
    p.srText:SetJustifyV("TOP")

    p.inUse = true
    table.insert(panelPool, p)
    WireButtons(p)
    return p
end

local function ReleasePanel(p)
    p.inUse = false
    p:Hide()
    p:SetAlpha(1) -- otherwise a panel that faded out arrives pre-faded the next time it's reused
    p.itemKey = nil
    p.icon.itemLink = nil
end

-- Seconds left on this item's roll, or nil if we don't know a deadline at
-- all (we're only observing someone else's roll via chat, never got our
-- own START_LOOT_ROLL for it). A real rollID is authoritative
-- (GetLootRollTimeLeft); /cr test's simulated items use the same
-- rollTime/rollStart fields so they drive the exact same countdown bar,
-- not a separate fake-looking readout.
local function GetTimeLeft(data)
    if data.rollID then
        return GetLootRollTimeLeft and GetLootRollTimeLeft(data.rollID) or 0
    elseif data.simulatedTimer then
        local left = (data.rollTime or 60) - (GetTime() - data.rollStart)
        return left > 0 and left or 0
    end
    return nil
end

local function GetRow(p, index)
    local row = p.rows[index]
    if not row then
        row = p:CreateFontString(nil, "OVERLAY")
        ApplyFont(row, 10)
        row:SetPoint("LEFT", p, "TOPLEFT", PAD, 0) -- repositioned per-refresh
        row:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
        row:SetJustifyH("LEFT")
        row:SetJustifyV("TOP") -- keep wrapped lines pinned to the top of their (dynamically sized) box
        p.rows[index] = row
    end
    return row
end

-- ===================== Roll buttons =====================

local function DoRoll(itemKey, rollType, kindName)
    local data = active[itemKey]
    if not data then return end

    if data.rollID then
        -- RollOnLoot doesn't register the roll immediately for a Bind-on-
        -- Pickup item - it first pops WoW's own "Looting this item will
        -- bind to you" confirmation, and the roll only actually happens if
        -- that's accepted. Marking hasRolled here unconditionally used to
        -- hide the buttons before that popup was even answered, so
        -- declining it (or just not clicking Okay yet) left no way to
        -- actually roll. hasRolled is left for the real confirmation - the
        -- "has selected X for:"/"X Roll - N..." chat line for our own name
        -- - to set instead, via AddOrUpdateRoll's own isSelf check below.
        RollOnLoot(data.rollID, rollType)
    else
        -- test-mode item with no real rollID: simulate locally - no BoP
        -- popup involved, so AddOrUpdateRoll's isSelf check sets
        -- hasRolled immediately, same as it always has. Pass always has a
        -- value of 0 (real Pass clicks never carry a roll number at all,
        -- same as HandleHasPassedLine hardcodes for everyone else's Pass).
        local value = (kindName == "PASS") and 0 or math.random(1, 100)
        AddOrUpdateRoll(data, PLAYER_NAME, kindName, value)
    end

    data.lastActivity = GetTime()
end

-- A RollFor item has no rollID/RollOnLoot to hook - "rolling" for it just
-- means actually typing /roll 100 (RandomRoll is the same thing the slash
-- command runs). The result comes back through the normal CHAT_MSG_SYSTEM
-- path (HandleSystemRollLine) a moment later, same as anyone else's roll -
-- we don't fabricate the row here, just make sure our own roll attributes
-- to the right item by moving it to the front of the attribution queue
-- right before rolling (our own roll message is the very next one).
local function DoRollForNeed(itemKey)
    local data = active[itemKey]
    if not data then return end

    for i, k in ipairs(rollforPending) do
        if k == itemKey then
            table.remove(rollforPending, i)
            break
        end
    end
    table.insert(rollforPending, 1, itemKey)

    if RandomRoll then
        RandomRoll(1, 100)
    else
        -- no RandomRoll available (shouldn't happen on a real client) -
        -- fall back to a local simulated value so the button still does
        -- something visible rather than silently failing
        AddOrUpdateRoll(data, PLAYER_NAME, "NEED", math.random(1, 100))
    end

    data.hasRolled = true
    data.lastActivity = GetTime()
end

-- ===================== Layout / refresh =====================

-- U+00A0 non-breaking space, UTF-8 encoded - glues a name to its own roll
-- value so the line wrapper (which only breaks on a plain space) can't
-- split them across two lines; a normal breakable space/comma still
-- separates different people's entries from each other.
local NBSP = "\194\160"

-- This client's FontString has neither GetStringHeight() nor SetWordWrap()
-- (both error as nil methods), so there's no reliable way to ask "how many
-- lines did that wrap to" after the fact. Estimate it instead from visible
-- character count (stripping |cff.../|r color codes first, since those
-- don't render as characters) against a rough chars-per-line for this
-- panel width/font size - good enough to reserve the right amount of
-- vertical space without ever under-allocating and overlapping the row
-- below it.
local AVG_CHAR_WIDTH = 5.3 -- calibrated against a real in-game line: "Need:  Kaladin 92, Kobeni* 16, Jasnah 13" (40 visible chars) rendered on one line at this panel width
local ROW_TEXT_WIDTH = PANEL_WIDTH - PAD * 2
local function EstimateWrappedLines(text)
    local visible = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
    visible = string.gsub(visible, "|r", "")
    local charsPerLine = math.floor(ROW_TEXT_WIDTH / AVG_CHAR_WIDTH)
    if charsPerLine < 1 then charsPerLine = 1 end
    local lines = math.ceil(string.len(visible) / charsPerLine)
    if lines < 1 then lines = 1 end
    return lines
end

local function SortedRolls(data)
    local list = {}
    for _, r in ipairs(data.rolls) do table.insert(list, r) end
    table.sort(list, function(a, b)
        local pa = ROLL_PRIORITY[a.kind] or 9
        local pb = ROLL_PRIORITY[b.kind] or 9
        if pa ~= pb then return pa < pb end
        return (a.value or 0) > (b.value or 0)
    end)
    return list
end

-- One line per roll TYPE instead of one line per person - a 6-person greed
-- roll reads as one wrapped line ("Greed: A 74, B 51, C 26, ...") instead
-- of 6 separate rows, which is what was actually eating all the vertical
-- space with a full raid rolling. Kept as its own pass (SortedRolls above
-- still backs the auto-resolve winner pick, unrelated to display grouping).
local function GroupRollsByKind(data)
    local byKind, kindOrder = {}, {}
    for _, r in ipairs(data.rolls) do
        if not byKind[r.kind] then
            byKind[r.kind] = {}
            table.insert(kindOrder, r.kind)
        end
        table.insert(byKind[r.kind], r)
    end
    table.sort(kindOrder, function(a, b) return (ROLL_PRIORITY[a] or 9) < (ROLL_PRIORITY[b] or 9) end)
    for _, list in pairs(byKind) do
        table.sort(list, function(a, b) return (a.value or 0) > (b.value or 0) end)
    end
    local groups = {}
    for _, kind in ipairs(kindOrder) do
        table.insert(groups, {kind = kind, rolls = byKind[kind]})
    end
    return groups
end

local function RefreshPanel(itemKey)
    local data = active[itemKey]
    if not data then return end

    local p = data.panel
    if not p then
        p = AcquirePanel()
        data.panel = p
        p.itemKey = itemKey
    end

    p.icon.tex:SetTexture(data.icon)
    p.icon.itemLink = data.itemLink
    p.name:SetText(data.itemName)
    -- window chrome (the panel's own outer border) stays flat/pfUI-skinned
    -- regardless of item quality, matching the house style's "match pfUI
    -- means look like pfUI" rule - but the icon SLOT's own 1px border, like
    -- LootLedger's item-grid icons, does stay each item's real rarity
    -- color, and so does the name text.
    if data.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[data.quality] then
        local c = ITEM_QUALITY_COLORS[data.quality]
        p.name:SetTextColor(c.r, c.g, c.b)
        p.icon:SetBackdropBorderColor(c.r, c.g, c.b, 1)
    else
        p.name:SetTextColor(1, 1, 1)
        p.icon:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    end

    local y = -(PAD + ICON_SIZE + 4)

    -- SR/HR badge - only set on items RollFor announced (see HandleRollForItemLine)
    if data.isHR then
        p.srText:SetText("|cffff5555HR|r  (hard-reserved, no roll needed)")
        p.srText:ClearAllPoints()
        p.srText:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y)
        p.srText:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
        p.srText:SetHeight(ROW_HEIGHT)
        p.srText:Show()
        y = y - ROW_HEIGHT - 2
    elseif data.srList and table.getn(data.srList) > 0 then
        local badgeText = "|cff33ccffSR:|r " .. table.concat(data.srList, ", ")
        local lines = EstimateWrappedLines(badgeText)
        p.srText:SetText(badgeText)
        p.srText:ClearAllPoints()
        p.srText:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y)
        p.srText:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
        p.srText:SetHeight(lines * ROW_HEIGHT)
        p.srText:Show()
        y = y - (lines * ROW_HEIGHT) - 2
    else
        p.srText:Hide()
    end

    -- roll-now controls: shown whenever we're still eligible and haven't
    -- rolled/resolved yet, sitting in the header row itself (to the right
    -- of the name) rather than a separate row below it. Covers both a
    -- real live roll and /cr test's simulated one - only the timer/status
    -- row below tells them apart.
    local showButtons = data.canRoll and not data.hasRolled and not data.winner

    if showButtons and data.rollForSelfSR then
        -- you SR'd this and it's contested - the only real option is Need,
        -- so show just that button (moved to the panel edge, since it's
        -- not sitting next to Greed/Pass here)
        p.needBtn:ClearAllPoints()
        p.needBtn:SetPoint("TOPRIGHT", p, "TOPRIGHT", -PAD, -PAD)
        p.needBtn:Show()
        p.greedBtn:Hide()
        p.passBtn:Hide()
        p.name:SetPoint("RIGHT", p.needBtn, "LEFT", -6, 0)
    elseif showButtons then
        p.needBtn:ClearAllPoints()
        p.needBtn:SetPoint("RIGHT", p.greedBtn, "LEFT", -2, 0)
        p.needBtn:Show()
        p.greedBtn:Show()
        p.passBtn:Show()
        p.name:SetPoint("RIGHT", p.needBtn, "LEFT", -6, 0)
    else
        p.needBtn:Hide()
        p.greedBtn:Hide()
        p.passBtn:Hide()
        p.name:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
    end

    -- timer row: only while you still have a roll decision to make -
    -- disappears the moment you click Need/Greed/Pass (or once a winner
    -- shows up). Only falls back to a plain elapsed-time line for a true
    -- passive observer (someone else's roll seen via chat only, no rollID
    -- and no simulated timer - so no deadline to count down at all).
    local timeLeft = GetTimeLeft(data)
    if not showButtons then
        p.timerBar:Hide()
        p.statusText:Hide()
    elseif timeLeft then
        p.timerBar:ClearAllPoints()
        p.timerBar:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y)
        p.timerBar:SetMinMaxValues(0, data.rollTime or 60)
        p.timerBar:SetValue(timeLeft)
        p.timerBar:Show()
        p.statusText:Hide()
        y = y - TIMERBAR_HEIGHT - 4
    else
        p.timerBar:Hide()
        p.statusText:ClearAllPoints()
        p.statusText:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y)
        p.statusText:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
        p.statusText:SetText("Rolling... " .. math.floor(GetTime() - data.createdAt) .. "s (no timer available)")
        p.statusText:Show()
        y = y - ROW_HEIGHT
    end

    -- One wrapped line per roll TYPE (Need/Greed/Pass/...) rather than one
    -- line per person - each name+value is its own inline-colored segment,
    -- so the winner's segment can still flash gold-to-green independently
    -- of everyone else's on the same line.
    local groups = GroupRollsByKind(data)
    local rowIndex = 0
    for _, group in ipairs(groups) do
        rowIndex = rowIndex + 1
        local row = GetRow(p, rowIndex)
        local kindLabel = string.sub(group.kind, 1, 1) .. string.lower(string.sub(group.kind, 2))
        local kindColor = RollColor(group.kind)

        local segments = {}
        for _, r in ipairs(group.rolls) do
            local name = r.name .. (r.isSelf and "*" or "")
            local fr, fg, fb
            if data.winner and r.name == data.winner.name then
                local t = (GetTime() - (data.winnerFlashStart or 0)) / WINNER_FLASH_DURATION
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
                fr, fg, fb = 1 - t * 0.75, 0.85 + t * 0.15, 0.1 + t * 0.25 -- gold -> green
            elseif r.isSelf then
                fr, fg, fb = 1, 1, 0.6
            else
                fr, fg, fb = kindColor[1], kindColor[2], kindColor[3]
            end
            if r.kind == "PASS" then
                -- a pass has no meaningful value at all (always 0) - just
                -- the name, no number to show
                table.insert(segments, string.format("|cff%02x%02x%02x%s|r",
                    math.floor(fr * 255), math.floor(fg * 255), math.floor(fb * 255), name))
            else
                -- a plain space between name and value is a legal wrap
                -- point on this client, so a long line can split "Shallan"
                -- from its own "18" onto two different lines - a non-
                -- breaking space glues them into one atomic unit; wrapping
                -- can still happen at the breakable ", " between different
                -- people's entries
                local valueText = r.value and tostring(r.value) or "..." -- "has selected Greed for:" arrives before the roll number does
                table.insert(segments, string.format("|cff%02x%02x%02x%s" .. NBSP .. "%s|r",
                    math.floor(fr * 255), math.floor(fg * 255), math.floor(fb * 255), name, valueText))
            end
        end

        local prefix = string.format("|cff%02x%02x%02x%s:|r  ",
            math.floor(kindColor[1] * 255), math.floor(kindColor[2] * 255), math.floor(kindColor[3] * 255), kindLabel)
        local text = prefix .. table.concat(segments, ", ")
        local lines = EstimateWrappedLines(text)
        row:SetText(text)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y)
        row:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
        -- an unconstrained-height FontString on this client renders as a
        -- single clipped line (mid-word, with no wrap) rather than
        -- expanding to fit wrapped text - it only actually wraps once it
        -- has an explicit height tall enough to hold multiple lines, same
        -- as LootLedger's own nameText does it (SetHeight + width anchors).
        row:SetHeight(lines * ROW_HEIGHT)
        row:Show()
        y = y - (lines * ROW_HEIGHT) - 2
    end
    for i = rowIndex + 1, table.getn(p.rows) do
        p.rows[i]:Hide()
    end

    if data.winner then
        p.winnerText:ClearAllPoints()
        p.winnerText:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y - 2)
        p.winnerText:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
        local label = data.winner.isSelf and "You won it!" or (data.winner.name .. " won it!")
        p.winnerText:SetText("|cffffd200" .. label .. "|r")
        p.winnerText:Show()
        y = y - ROW_HEIGHT - 4
    elseif data.resolved and not data.isHR then
        -- "Everyone has passed"/"No one rolled for X." - resolved, but
        -- there's no winner to name. HR items skip this: their SR badge
        -- above already says "no roll needed", so this would be redundant.
        p.winnerText:ClearAllPoints()
        p.winnerText:SetPoint("TOPLEFT", p, "TOPLEFT", PAD, y - 2)
        p.winnerText:SetPoint("RIGHT", p, "RIGHT", -PAD, 0)
        p.winnerText:SetText("|cff999999Nobody wanted it|r")
        p.winnerText:Show()
        y = y - ROW_HEIGHT - 4
    else
        p.winnerText:Hide()
    end

    p:SetHeight(-y + PAD)
    p:Show()
end

local function Reflow()
    -- a hidden (locked) anchor still works fine as a position reference for
    -- SetPoint below - Hide() only stops it from rendering/being clickable,
    -- it doesn't lose its coordinates - but its own height shouldn't be
    -- reserved as blank space above the first panel when it's not shown
    local y = CleanRollsDB.locked and -4 or -(ANCHOR_HEIGHT + 4)
    for _, itemKey in ipairs(order) do
        local data = active[itemKey]
        if data and data.panel then
            data.panel:ClearAllPoints()
            data.panel:SetPoint("TOP", anchor, "TOP", 0, y)
            y = y - data.panel:GetHeight() - 4
        end
    end
end

local function RemoveItem(itemKey)
    local data = active[itemKey]
    if not data then return end
    if data.panel then ReleasePanel(data.panel) end
    active[itemKey] = nil
    for i, k in ipairs(order) do
        if k == itemKey then
            table.remove(order, i)
            break
        end
    end
    Reflow()
end

-- ===================== Buttons wiring (shared across pooled panels) =====================

WireButtons = function(p)
    p.needBtn:SetScript("OnClick", function()
        if not p.itemKey then return end
        local data = active[p.itemKey]
        if data and data.rollForSelfSR then
            DoRollForNeed(p.itemKey)
        else
            DoRoll(p.itemKey, 1, "NEED")
        end
        RefreshPanel(p.itemKey)
        Reflow()
    end)
    p.greedBtn:SetScript("OnClick", function()
        if p.itemKey then DoRoll(p.itemKey, 2, "GREED"); RefreshPanel(p.itemKey); Reflow() end
    end)
    p.passBtn:SetScript("OnClick", function()
        if p.itemKey then DoRoll(p.itemKey, 0, "PASS"); RefreshPanel(p.itemKey); Reflow() end
    end)
end

-- ===================== Event handling =====================

local ROLL_LINE_PATTERN = "^(%a+) Roll %- (%d+) for (.-) by (.+)$"
local WIN_LINE_PATTERN = "^(.-) won: (.+)$"
-- Fires the instant someone clicks a Need/Greed/Pass button - this server
-- batches the actual numeric "Greed Roll - N for [Item] by Name" lines
-- together right before the winner is announced, so without this the
-- window shows nothing at all during the entire time people are actually
-- selecting, then jumps straight to fully-resolved. This is the standard
-- vanilla LOOT_ROLL_GREED/NEED/PASSED wording, so "You" needs the same
-- self-name mapping as elsewhere.
local HAS_SELECTED_PATTERN = "^(.+) has selected (%a+) for: (.+)$"
-- Pass uses different wording than Need/Greed ("has passed on:", not "has
-- selected Pass for:") so it needs its own pattern, same live-signal idea.
local HAS_PASSED_PATTERN = "^(.+) has passed on: (.+)$"
-- Fires instead of a "won:" line when literally nobody wants the item -
-- there's no winner to report, but it's just as definitive a resolution.
local EVERYONE_PASSED_PATTERN = "^Everyone has passed on: (.+)$"

local function HandleRollLine(kindWord, valueStr, itemText, playerName)
    local itemID, suffixID, name = ExtractItemFromText(itemText)
    if not itemID then return end
    local itemKey = ItemKey(itemID, suffixID)
    local data = GetOrCreateItem(itemKey, name, itemText)
    AddOrUpdateRoll(data, playerName, string.upper(kindWord), tonumber(valueStr))
    RefreshPanel(itemKey)
    Reflow()
end

local function HandleHasSelectedLine(playerName, kindWord, itemText)
    local itemID, suffixID, name = ExtractItemFromText(itemText)
    if not itemID then return end
    local itemKey = ItemKey(itemID, suffixID)
    local data = GetOrCreateItem(itemKey, name, itemText)
    -- no roll number yet (AddOrUpdateRoll dedupes by name, so the later
    -- "Greed Roll - N ... by Name" line just fills this same row in)
    AddOrUpdateRoll(data, playerName, string.upper(kindWord), nil)
    RefreshPanel(itemKey)
    Reflow()
end

local function HandleWinLine(winnerName, itemText)
    local itemID, suffixID, name = ExtractItemFromText(itemText)
    if not itemID then return end
    local itemKey = ItemKey(itemID, suffixID)
    local data = active[itemKey]
    if not data then
        -- winner line with no prior roll lines seen (e.g. only one eligible roller)
        data = GetOrCreateItem(itemKey, name, itemText)
    end

    local isSelf = (winnerName == PLAYER_NAME or winnerName == "You")
    data.winner = {name = isSelf and PLAYER_NAME or winnerName, isSelf = isSelf}
    data.winnerFlashStart = GetTime()
    data.canRoll = false
    data.lastActivity = GetTime()
    RefreshPanel(itemKey)
    Reflow()
end

local function HandleHasPassedLine(playerName, itemText)
    local itemID, suffixID, name = ExtractItemFromText(itemText)
    if not itemID then return end
    local itemKey = ItemKey(itemID, suffixID)
    local data = GetOrCreateItem(itemKey, name, itemText)
    AddOrUpdateRoll(data, playerName, "PASS", 0)
    RefreshPanel(itemKey)
    Reflow()
end

local function HandleEveryonePassedLine(itemText)
    local itemID, suffixID, name = ExtractItemFromText(itemText)
    if not itemID then return end
    local itemKey = ItemKey(itemID, suffixID)
    local data = active[itemKey]
    if not data then
        data = GetOrCreateItem(itemKey, name, itemText)
    end

    -- no winner to report, but just as resolved as one - see `resolved`
    -- flag's own comment for why this needs to fade on the normal timer
    -- instead of falling back to the 90s stale-timeout
    data.resolved = true
    data.canRoll = false
    data.lastActivity = GetTime()
    RefreshPanel(itemKey)
    Reflow()
end

-- ===================== RollFor integration =====================
-- RollFor (https://github.com/sica42/RollFor) is a separate, widely-used
-- soft-reserve addon the raid leader/loot master runs. We don't require it
-- to be installed and never touch its saved data or API - we just read the
-- same public raid/party chat text everyone else already sees, plus the
-- standard Blizzard "/roll" system message (RollFor rolls are just plain
-- /roll under the hood, not a custom roll type), the same way a human
-- reads the raid chat. If RollFor's own wording ever changes, these
-- patterns simply stop matching (silently - nothing to break).
--
-- Verified against RollFor's actual source (src/DroppedLootAnnounce.lua,
-- src/RollResultAnnouncer.lua) as of 2026-08 - not tested live in-game yet.
--
-- Item announcement lines (posted once per item when loot opens), exact
-- format strings from DroppedLootAnnounce.lua's `stringify`:
--   "%s. %s (HR)"                      -- hard-reserved, no roll happens
--   "%s. %s%s (SR by %s)"              -- soft-reserved by the listed names
--   "%s. %s%s"                         -- free-roll (nobody reserved it)
-- (%s. is a 1-based index; the optional "%sx" prefix before the item link
-- is a stack-count multiplier, e.g. "2x", when more than one dropped)
--
-- Resolution lines, from RollResultAnnouncer.lua:
--   "%s %srolled the %shighest (%s) for %s%s."   -- normal/tie/re-roll winner
--   "%s soft-ressed %s."                          -- single SR'er, auto-awarded, no roll
--   "%s wins %s (raid-roll)."                     -- raid-roll mode
--   "No one rolled for %s."                       -- nobody rolled at all

-- "A, B and C" / "A and B" / "A" -> {"A","B","C"} - matches RollFor's own
-- `commify`/`prettify_table` Oxford-comma joining used in both the SR
-- list and the winner-rollers list. Also strips the optional " [N rolls]"
-- / " (+N)" per-name suffixes RollFor's SR-plus feature can add - we only
-- want the bare name.
local function SplitNameList(text)
    text = string.gsub(text, " and ", ", ")
    local names = {}
    local start = 1
    while true do
        local s, e = string.find(text, ", ", start, true)
        if not s then
            table.insert(names, string.sub(text, start))
            break
        end
        table.insert(names, string.sub(text, start, s - 1))
        start = e + 1
    end
    for i, n in ipairs(names) do
        n = string.gsub(n, " %[.-%]", "")
        n = string.gsub(n, " %(.-%)", "")
        names[i] = n
    end
    return names
end

-- Items RollFor has announced but not yet resolved, oldest first. A plain
-- "/roll" system message has no idea which item it's for - RollFor rolls
-- items one at a time in practice, so we attribute any observed roll to
-- the OLDEST still-open RollFor item. If more than one item is ever open
-- at once this can misattribute a stray roll - a known, accepted limit of
-- reading chat text rather than RollFor's own internal state.
-- (rollforPending itself is declared near the top of the file, above
-- DoRollForNeed, which needs to reference it directly.)
local function RollForPushPending(itemKey)
    for _, k in ipairs(rollforPending) do
        if k == itemKey then return end -- already queued (e.g. both the chat-text and broadcast paths saw it)
    end
    table.insert(rollforPending, itemKey)
end
local function RollForResolvePending(itemKey)
    for i, k in ipairs(rollforPending) do
        if k == itemKey then
            table.remove(rollforPending, i)
            return
        end
    end
end

local function HandleRollForItemLine(text)
    local _, _, hrItemText = string.find(text, "^%d+%.%s*(.-)%s*%(HR%)$")
    if hrItemText then
        local itemID, suffixID, name = ExtractItemFromText(hrItemText)
        if not itemID then return end
        local itemKey = ItemKey(itemID, suffixID)
        local data = GetOrCreateItem(itemKey, name, hrItemText)
        data.isHR = true
        data.canRoll = false
        data.resolved = true -- no real "awarded" chat line ever comes for HR - the badge itself is the resolution
        -- deliberately NOT pushed to rollforPending: HR items never have a
        -- /roll happen for them at all, so if they sat in that queue
        -- they'd become a permanent (never-resolved) FIFO target once
        -- whatever was ahead of them resolved, silently stealing later
        -- rolls meant for a genuinely-open item
        RefreshPanel(itemKey)
        Reflow()
        return
    end

    local _, _, srItemText, srListText = string.find(text, "^%d+%.%s*(.-)%s*%(SR by (.+)%)$")
    if srItemText then
        local itemID, suffixID, name = ExtractItemFromText(srItemText)
        if not itemID then return end
        local itemKey = ItemKey(itemID, suffixID)
        local data = GetOrCreateItem(itemKey, name, srItemText)
        data.srList = SplitNameList(srListText)

        if table.getn(data.srList) > 1 then
            -- contested: someone still has to actually /roll 100 for it -
            -- give THEM a Need button if they're one of the reservers
            RollForPushPending(itemKey)
            for _, n in ipairs(data.srList) do
                if n == PLAYER_NAME then
                    data.canRoll = true
                    data.rollForSelfSR = true
                    break
                end
            end
        end
        -- a solo SR ("(SR by OnlyOnePerson)") never has a /roll at all -
        -- RollFor auto-awards it straight off the "X soft-ressed [Item]."
        -- line, so (like HR above) it's deliberately not pushed to
        -- rollforPending, and gets no button either

        RefreshPanel(itemKey)
        Reflow()
        return
    end

    local _, _, freeItemText = string.find(text, "^%d+%.%s*(.+)$")
    if freeItemText then
        local itemID, suffixID, name = ExtractItemFromText(freeItemText)
        if not itemID then return end -- not actually an item line (e.g. unrelated raid chat starting with a number)
        local itemKey = ItemKey(itemID, suffixID)
        local data = GetOrCreateItem(itemKey, name, freeItemText)
        RollForPushPending(itemKey)
        RefreshPanel(itemKey)
        Reflow()
    end
end

local function ResolveRollForItem(itemText, winnerName, value)
    local itemID, suffixID = ExtractItemFromText(itemText)
    if not itemID then return end
    local itemKey = ItemKey(itemID, suffixID)
    local data = active[itemKey]
    if not data then return end -- never saw the announce line for this one

    RollForResolvePending(itemKey)
    data.canRoll = false

    if winnerName then
        local isSelf = (winnerName == PLAYER_NAME or winnerName == "You")
        if isSelf then winnerName = PLAYER_NAME end
        if value then
            -- in case we never saw their own /roll line (e.g. addon just loaded)
            AddOrUpdateRoll(data, winnerName, "ROLL", value)
        end
        data.winner = {name = winnerName, isSelf = isSelf}
        data.winnerFlashStart = GetTime()
    else
        -- "No one rolled for X." - no winner to report, but just as
        -- resolved as one; see `resolved` flag's own comment for why this
        -- needs the normal fade timer instead of the 90s stale-timeout
        data.resolved = true
    end

    data.lastActivity = GetTime()
    RefreshPanel(itemKey)
    Reflow()
end

local function HandleRollForWinnerLine(text)
    local _, _, rollersText, valueStr, itemText = string.find(text, "^(.+) .-rolled the .-highest %((%d+)%) for (.+)%.$")
    if rollersText then
        ResolveRollForItem(itemText, SplitNameList(rollersText)[1], tonumber(valueStr))
        return true
    end

    local _, _, srWinner, itemText2 = string.find(text, "^(.+) soft%-ressed (.+)%.$")
    if srWinner then
        ResolveRollForItem(itemText2, SplitNameList(srWinner)[1], nil)
        return true
    end

    local _, _, rrWinner, itemText3 = string.find(text, "^(.+) wins (.+) %(raid%-roll%)%.$")
    if rrWinner then
        ResolveRollForItem(itemText3, rrWinner, nil)
        return true
    end

    local _, _, itemText4 = string.find(text, "^No one rolled for (.+)%.$")
    if itemText4 then
        ResolveRollForItem(itemText4, nil, nil)
        return true
    end

    return false
end

-- Which pending RollFor item a roller's "/roll" actually belongs to. Pure
-- FIFO ("whichever item is oldest") breaks badly the moment one item sits
-- open longer than expected while others get rolled on - every roll for
-- the newer item lands on the stale one instead. A contested SR item
-- already tells us exactly who's expected to roll on it, so check that
-- first; only fall back to "oldest still-open item with no SR list at
-- all" (i.e. a free-roll item) when the roller doesn't match any SR list.
local function FindPendingRollForItem(rollerName)
    for _, itemKey in ipairs(rollforPending) do
        local data = active[itemKey]
        if data and data.srList then
            for _, srName in ipairs(data.srList) do
                if srName == rollerName then return itemKey end
            end
        end
    end
    for _, itemKey in ipairs(rollforPending) do
        local data = active[itemKey]
        if data and not data.srList then return itemKey end
    end
    return rollforPending[1]
end

local function HandleSystemRollLine(text)
    local _, _, name, valueStr, _, maxStr = string.find(text, "^(.+) rolls (%d+) %((%d+)%-(%d+)%)$")
    if not name then return end

    local itemKey = currentRollForItem or FindPendingRollForItem(name)
    if not itemKey then return end -- no RollFor item currently pending
    local data = active[itemKey]
    if not data then return end

    -- prefer this item's own broadcast-derived thresholds (the raid's
    -- actual configured ms/os/tmog ranges) over the generic 100/99/98 guess
    local kind = (data.rollThresholds and data.rollThresholds[tonumber(maxStr)])
        or ROLL_RANGE_KIND[tonumber(maxStr)] or "ROLL"
    AddOrUpdateRoll(data, name, kind, tonumber(valueStr))
    RefreshPanel(itemKey)
    Reflow()
end

-- ===================== RollFor addon-comm integration =====================
-- RollFor also syncs its live roll state to every RollFor-running player
-- (not just the master looter) over the addon message channel (prefix
-- "RollFor"), so each of them can show their own popup. This is entirely
-- passive on our end - RollFor doesn't need to change anything, and
-- CHAT_MSG_ADDON already delivers these to any addon that's listening for
-- that prefix. When present, it's authoritative and takes priority over
-- the chat-text guesswork above: exact roll thresholds instead of an
-- assumed 100/99/98, an exact "roll is open now" signal instead of
-- inferring one from the drop announcement, and a precise winner/cancel
-- signal instead of regexing the announcer's sentence. The chat-text
-- parsing above keeps running unconditionally as a fallback for anyone
-- who joined after a broadcast was missed.
--
-- Verified against RollFor's actual source (src/ClientBroadcast.lua,
-- src/modules.lua's M.dump, src/Types.lua's RollType) as of 2026-08 - same
-- "not tested live in-game yet" caveat as the chat-text parsing above.

local ROLLFOR_ADDON_PREFIX = "RollFor"
local ROLLFOR_TYPE_KIND = {
    MainSpec = "NEED",
    SoftRes  = "NEED",
    OffSpec  = "OFFSPEC",
    Transmog = "TRANSMOG",
}

-- (currentRollForItem itself is declared near the top of the file,
-- alongside rollforPending, since HandleSystemRollLine above needs to
-- reference it directly.)

-- RollFor's own serializer (src/modules.lua M.dump) emits plain Lua
-- table-constructor syntax - e.g. {["i"]={["id"]=19019,...},["s"]=60} -
-- so it's directly loadable as Lua code instead of needing a hand-written
-- parser for their custom format.
local function DecodeRollForPayload(dataStr)
    if not dataStr or dataStr == "" or dataStr == "nil" then return nil end
    if not loadstring then return nil end
    local chunk = loadstring("return " .. dataStr)
    if not chunk then return nil end
    local ok, result = pcall(chunk)
    if not ok then return nil end
    return result
end

-- "COMMAND::DATA" -> "COMMAND", "DATA" (data half may be empty)
local function SplitRollForCommand(rest)
    local s, e = string.find(rest, "::", 1, true)
    if not s then return rest, "" end
    return string.sub(rest, 1, s - 1), string.sub(rest, e + 1)
end

-- Messages over 220 chars arrive pre-split as "CHUNK::i::total::piece" -
-- buffered per sender until every piece has arrived, then reassembled
-- back into the "COMMAND::DATA" shape SplitRollForCommand expects.
local rollforChunkBuffers = {}
local function HandleRollForChunk(sender, rest)
    local _, _, idxStr, totalStr, piece = string.find(rest, "^CHUNK::(%d+)::(%d+)::(.*)$")
    if not idxStr then return nil end
    local idx, total = tonumber(idxStr), tonumber(totalStr)

    local buf = rollforChunkBuffers[sender]
    if not buf or buf.total ~= total then
        buf = {total = total, pieces = {}, count = 0}
        rollforChunkBuffers[sender] = buf
    end
    if not buf.pieces[idx] then
        buf.pieces[idx] = piece
        buf.count = buf.count + 1
    end
    if buf.count < total then return nil end -- still waiting on more pieces

    rollforChunkBuffers[sender] = nil
    return SplitRollForCommand(table.concat(buf.pieces, "", 1, total))
end

local function HandleRollForStart(payload)
    if not payload or not payload.i or not payload.i.id then return end
    local itemID = payload.i.id
    local itemKey = ItemKey(itemID, "0")
    local rawName = payload.i.n and string.gsub(payload.i.n, "_", " ") or nil
    local itemLink = "item:" .. itemID .. ":0:0:0"

    local data = GetOrCreateItem(itemKey, rawName, itemLink)
    if rawName then data.itemName = rawName end
    if payload.i.tx and payload.i.tx ~= "" then
        data.icon = "Interface\\Icons\\" .. payload.i.tx
    end
    if payload.i.q then data.quality = payload.i.q end
    data.rollTime = payload.s or data.rollTime

    if payload.th then
        data.rollThresholds = {}
        if payload.th.ms then data.rollThresholds[payload.th.ms] = "NEED" end
        if payload.th.os then data.rollThresholds[payload.th.os] = "OFFSPEC" end
        if payload.th.tm then data.rollThresholds[payload.th.tm] = "TRANSMOG" end
    end

    if payload.sr and table.getn(payload.sr) > 0 then
        data.srList = {}
        for _, p in ipairs(payload.sr) do
            table.insert(data.srList, p.n)
        end
        if table.getn(data.srList) > 1 then
            RollForPushPending(itemKey)
            for _, n in ipairs(data.srList) do
                if n == PLAYER_NAME then
                    data.canRoll = true
                    data.rollForSelfSR = true
                    break
                end
            end
        end
    else
        RollForPushPending(itemKey) -- free-roll item
    end

    currentRollForItem = itemKey
    RefreshPanel(itemKey)
    Reflow()
end

local function HandleRollForRoll(payload)
    if not payload or not currentRollForItem then return end
    local data = active[currentRollForItem]
    if not data then return end

    local kind = ROLLFOR_TYPE_KIND[payload.rt] or "ROLL"
    AddOrUpdateRoll(data, payload.pn, kind, payload.r)
    RefreshPanel(currentRollForItem)
    Reflow()
end

local function HandleRollForFinish(payload)
    if not currentRollForItem then return end
    local itemKey = currentRollForItem
    currentRollForItem = nil
    RollForResolvePending(itemKey)

    local data = active[itemKey]
    if not data then return end

    data.canRoll = false
    if payload and table.getn(payload) > 0 then
        local winner = payload[1]
        data.winner = {name = winner.n, isSelf = (winner.n == PLAYER_NAME)}
        data.winnerFlashStart = GetTime()
    else
        -- an empty winners payload means nobody rolled - no winner, but
        -- just as resolved as one; same as the chat-text "No one rolled
        -- for X." case
        data.resolved = true
    end
    data.lastActivity = GetTime()
    RefreshPanel(itemKey)
    Reflow()
end

local function HandleRollForCancel()
    if not currentRollForItem then return end
    local itemKey = currentRollForItem
    currentRollForItem = nil
    RollForResolvePending(itemKey)

    local data = active[itemKey]
    if data then
        data.canRoll = false
        data.lastActivity = GetTime()
        RefreshPanel(itemKey)
        Reflow()
    end
end

local function HandleRollForAwarded(payload)
    if not payload or not payload.id then return end
    local itemKey = ItemKey(payload.id, "0")
    local data = active[itemKey]
    if not data then return end -- an item we never saw START_ROLL/an announce line for

    if not data.winner then
        data.winner = {name = payload.pn, isSelf = (payload.pn == PLAYER_NAME)}
        data.winnerFlashStart = GetTime()
    end
    data.canRoll = false
    data.lastActivity = GetTime()
    if currentRollForItem == itemKey then currentRollForItem = nil end
    RollForResolvePending(itemKey)
    RefreshPanel(itemKey)
    Reflow()
end

local function HandleRollForBroadcast(msg, sender)
    local _, _, rest = string.find(msg, "^ROLL::(.+)$")
    if not rest then return end

    local command, dataStr
    if string.find(rest, "^CHUNK::") then
        command, dataStr = HandleRollForChunk(sender, rest)
        if not command then return end -- still waiting on more chunks
    else
        command, dataStr = SplitRollForCommand(rest)
    end

    local payload = DecodeRollForPayload(dataStr)
    if command == "START_ROLL" then
        HandleRollForStart(payload)
    elseif command == "ROLL" then
        HandleRollForRoll(payload)
    elseif command == "FINISH" then
        HandleRollForFinish(payload)
    elseif command == "CANCEL_ROLL" then
        HandleRollForCancel()
    elseif command == "AWARDED" then
        HandleRollForAwarded(payload)
    end
    -- TIE/TIESTART/TICK/ENABLE_ROLL_POPUP not handled separately - a
    -- tie-break roll just lands on the same currentRollForItem via the
    -- ROLL handler above (AddOrUpdateRoll overwrites that player's row
    -- with their new value), and the countdown is already derived locally
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("START_LOOT_ROLL")
eventFrame:RegisterEvent("CANCEL_LOOT_ROLL")
eventFrame:RegisterEvent("CHAT_MSG_RAID")
eventFrame:RegisterEvent("CHAT_MSG_RAID_WARNING")
eventFrame:RegisterEvent("CHAT_MSG_PARTY")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_LOGIN")

eventFrame:SetScript("OnEvent", function()
    if event == "CHAT_MSG_LOOT" then
        local _, _, kindWord, valueStr, itemText, playerName = string.find(arg1, ROLL_LINE_PATTERN)
        if kindWord then
            HandleRollLine(kindWord, valueStr, itemText, playerName)
            return
        end

        local _, _, winnerName, itemText2 = string.find(arg1, WIN_LINE_PATTERN)
        if winnerName then
            HandleWinLine(winnerName, itemText2)
            return
        end

        local _, _, selectedName, selectedKind, itemText3 = string.find(arg1, HAS_SELECTED_PATTERN)
        if selectedName then
            HandleHasSelectedLine(selectedName, selectedKind, itemText3)
            return
        end

        -- checked before the general "X has passed on:" pattern below,
        -- since "Everyone" would otherwise match that pattern's own name
        -- capture and get treated as a player named "Everyone"
        local _, _, itemText5 = string.find(arg1, EVERYONE_PASSED_PATTERN)
        if itemText5 then
            HandleEveryonePassedLine(itemText5)
            return
        end

        local _, _, passedName, itemText4 = string.find(arg1, HAS_PASSED_PATTERN)
        if passedName then
            HandleHasPassedLine(passedName, itemText4)
            return
        end
    elseif event == "START_LOOT_ROLL" then
        local rollID, rollTime = arg1, arg2
        local itemLink = GetLootRollItemLink and GetLootRollItemLink(rollID)
        if not itemLink then return end
        local itemID, suffixID, name = ExtractItemFromText(itemLink)
        if not itemID then return end
        local itemKey = ItemKey(itemID, suffixID)

        local data = GetOrCreateItem(itemKey, name, itemLink)
        data.rollID = rollID
        data.rollTime = rollTime or 60
        data.canRoll = true
        data.rollStart = GetTime()

        RefreshPanel(itemKey)
        Reflow()
    elseif event == "CANCEL_LOOT_ROLL" then
        for itemKey, data in pairs(active) do
            if data.rollID == arg1 then
                data.canRoll = false
                data.rollID = nil
                RefreshPanel(itemKey)
                Reflow()
            end
        end
    elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_WARNING" or event == "CHAT_MSG_PARTY" then
        if not HandleRollForWinnerLine(arg1) then
            HandleRollForItemLine(arg1)
        end
    elseif event == "CHAT_MSG_SYSTEM" then
        HandleSystemRollLine(arg1)
    elseif event == "CHAT_MSG_ADDON" then
        if arg1 == ROLLFOR_ADDON_PREFIX then
            HandleRollForBroadcast(arg2, arg4)
        end
    elseif event == "PLAYER_LOGIN" then
        ApplySavedAnchorState()
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CleanRolls|r loaded. Type /cleanrolls for options.")
    end
end)

-- ===================== Ticker: timers / fade / scheduled tasks / cleanup =====================

local tickAccum = 0
eventFrame:SetScript("OnUpdate", function()
    tickAccum = tickAccum + arg1
    if tickAccum < 0.1 then return end
    tickAccum = 0

    local now = GetTime()
    local toRemove = nil -- collected, not removed in-loop: table.remove-ing from `order`
                          -- while ipairs is still walking it corrupts the iteration and
                          -- silently skips later entries (some panels never got their
                          -- fade re-checked again, freezing them mid-fade)

    if table.getn(pendingTasks) > 0 then
        local ready, remaining = nil, {}
        for _, task in ipairs(pendingTasks) do
            if now >= task.time then
                ready = ready or {}
                table.insert(ready, task)
            else
                table.insert(remaining, task)
            end
        end
        if ready then
            pendingTasks = remaining
            for _, task in ipairs(ready) do
                task.fn()
            end
        end
    end

    for _, itemKey in ipairs(order) do
        local data = active[itemKey]
        if data then
            -- roll countdown bar (real or simulated timer) or elapsed-time
            -- status (no deadline known at all - see RefreshPanel/GetTimeLeft)
            if data.panel and data.panel.timerBar:IsShown() then
                local left = GetTimeLeft(data) or 0
                data.panel.timerBar:SetMinMaxValues(0, data.rollTime or 60)
                data.panel.timerBar:SetValue(left)
            elseif data.panel and data.panel.statusText:IsShown() then
                data.panel.statusText:SetText("Rolling... " .. math.floor(now - data.createdAt) .. "s (no timer available)")
            end

            -- animate the winner's row flash while it's still running -
            -- RefreshPanel only otherwise runs on discrete roll/win events
            if data.winner and data.winnerFlashStart and (now - data.winnerFlashStart) < WINNER_FLASH_DURATION then
                RefreshPanel(itemKey)
            end

            -- /cr test items: there's no real server to announce a winner,
            -- so once the simulated timer runs out, pick one ourselves from
            -- whoever's rolled so far (same priority/value ranking the
            -- window already displays) - otherwise these would just sit
            -- forever (or eventually stale-timeout away with no winner
            -- ever shown at all).
            if data.simulatedTimer and not data.winner then
                local left = GetTimeLeft(data) or 0
                if left <= 0 then
                    local top = SortedRolls(data)[1]
                    if top then
                        data.winner = {name = top.name, isSelf = top.isSelf}
                        data.winnerFlashStart = now
                        data.canRoll = false
                    else
                        data.fading = true
                        data.fadeStart = now
                    end
                    data.lastActivity = now
                    RefreshPanel(itemKey)
                    Reflow()
                end
            end

            if not data.fading then
                local shouldFade = false
                if (data.winner or data.resolved) and (now - data.lastActivity) > DISPLAY_HOLD_TIME then
                    -- `resolved` covers anything we know for certain is
                    -- done even without a winner to show - "Everyone has
                    -- passed", "No one rolled for X.", an empty RollFor
                    -- FINISH payload, or an HR item (never gets a real
                    -- "awarded" chat line - RollFor's master-loot
                    -- auto-award is silent, so its badge alone counts as
                    -- resolved). All of these hold for the normal amount
                    -- of time instead of sitting for the full 90s
                    -- stale-timeout fallback below, which is for when we
                    -- genuinely don't know what happened, not when we do.
                    shouldFade = true
                elseif (not data.winner) and (not data.resolved) and (now - data.lastActivity) > STALE_TIMEOUT then
                    shouldFade = true
                elseif data.canRoll and data.rollID and not data.hasRolled then
                    local left = GetTimeLeft(data) or 0
                    if left <= 0 and (now - data.rollStart) > (data.rollTime or 60) + ROLL_TIMEOUT_GRACE then
                        shouldFade = true
                    end
                end

                if shouldFade then
                    data.fading = true
                    data.fadeStart = now
                end
            end

            if data.fading and data.panel then
                local alpha = 1 - ((now - data.fadeStart) / FADE_TIME)
                if alpha <= 0 then
                    toRemove = toRemove or {}
                    table.insert(toRemove, itemKey)
                else
                    data.panel:SetAlpha(alpha)
                end
            end
        end
    end

    if toRemove then
        for _, itemKey in ipairs(toRemove) do
            RemoveItem(itemKey) -- removes from `order` and calls Reflow() itself
        end
    end
end)

-- ===================== Slash commands =====================

SLASH_CLEANROLLS1 = "/cleanrolls"
SLASH_CLEANROLLS2 = "/cr"
SlashCmdList["CLEANROLLS"] = function(msg)
    msg = string.lower(msg or "")
    if msg == "reset" then
        CleanRollsDB.point = nil
        anchor:ClearAllPoints()
        anchor:SetPoint("RIGHT", UIParent, "RIGHT", -20, 150)
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CleanRolls|r: position reset.")
    elseif msg == "lock" then
        CleanRollsDB.locked = true
        anchor:Hide()
        Reflow()
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CleanRolls|r: header hidden. /cr unlock to bring it back and reposition.")
    elseif msg == "unlock" then
        CleanRollsDB.locked = false
        anchor:Show()
        Reflow()
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CleanRolls|r: header back - drag it to reposition.")
    elseif msg == "test" then
        local stamp = tostring(GetTime())

        -- Every item starts nearly empty (like a real roll) and other
        -- players' rolls trickle in one at a time over the next several
        -- seconds via ScheduleTask, instead of all appearing instantly.
        -- Each one still has to resolve itself the same way a real roll
        -- would: the auto-resolve-on-timeout ticker logic picks a winner
        -- once the simulated timer runs out.
        local function AddLater(itemKey, delay, name, kind, value)
            ScheduleTask(delay, function()
                local data = active[itemKey]
                if not data then return end -- panel already faded/removed
                AddOrUpdateRoll(data, name, kind, value)
                RefreshPanel(itemKey)
                Reflow()
            end)
        end

        -- item 1: still live, you can roll on it (buttons shown) - mostly
        -- Greed, to stress-test one long wrapped Greed line
        local id1 = "999901:0:" .. stamp
        local d1 = NewItemData(id1, "Warmaster Legguards", nil, "Interface\\Icons\\INV_Pants_04", 4)
        active[id1] = d1
        table.insert(order, id1)
        d1.canRoll = true
        d1.simulatedTimer = true
        d1.rollTime = 20
        d1.rollStart = GetTime()
        AddLater(id1, 1.0, "Kaladin", "NEED", 92)
        AddLater(id1, 2.5, "Szeth", "GREED", 51)
        AddLater(id1, 4.0, "Dalinar", "GREED", 8)
        AddLater(id1, 5.5, "Shallan", "GREED", 26)
        AddLater(id1, 7.0, "Jasnah", "NEED", 13)
        AddLater(id1, 8.5, "Adolin", "GREED", 74)
        AddLater(id1, 10.0, "Teft", "GREED", 37)
        AddLater(id1, 11.5, "Renarin", "PASS", 0)
        AddLater(id1, 13.0, "Navani", "GREED", 60)
        AddLater(id1, 14.5, "Hoid", "GREED", 99)

        -- item 2: also live - mostly Need, to stress-test the other kind's
        -- long wrapped line; resolves and shows the winner flash + fade
        -- countdown once its timer runs out
        local id2 = "999902:0:" .. stamp
        local d2 = NewItemData(id2, "Devilsaur Leggings", nil, "Interface\\Icons\\INV_Pants_03", 4)
        active[id2] = d2
        table.insert(order, id2)
        d2.canRoll = true
        d2.simulatedTimer = true
        d2.rollTime = 18
        d2.rollStart = GetTime()
        AddLater(id2, 1.5, "Teft", "NEED", 88)
        AddLater(id2, 3.0, "Kaladin", "NEED", 44)
        AddLater(id2, 4.5, "Dalinar", "NEED", 71)
        AddLater(id2, 6.0, "Renarin", "GREED", 95)
        AddLater(id2, 7.5, "Navani", "PASS", 0)
        AddLater(id2, 9.0, "Szeth", "NEED", 19)
        AddLater(id2, 10.5, "Shallan", "NEED", 63)
        AddLater(id2, 12.0, "Jasnah", "NEED", 5)
        AddLater(id2, 13.5, "Adolin", "PASS", 0)
        AddLater(id2, 15.0, "Hoid", "NEED", 100)

        -- item 3: also live - an even three-way mix, to stress-test
        -- multiple long wrapped groups on the same panel at once
        local id3 = "999903:0:" .. stamp
        local d3 = NewItemData(id3, "Insulated Leather Boots", nil, "Interface\\Icons\\INV_Boots_05", 3)
        active[id3] = d3
        table.insert(order, id3)
        d3.canRoll = true
        d3.simulatedTimer = true
        d3.rollTime = 16
        d3.rollStart = GetTime()
        AddLater(id3, 1.0, "Navani", "GREED", 63)
        AddLater(id3, 2.5, "Renarin", "NEED", 45)
        AddLater(id3, 4.0, "Adolin", "PASS", 0)
        AddLater(id3, 5.5, "Kaladin", "GREED", 30)
        AddLater(id3, 7.0, "Szeth", "NEED", 77)
        AddLater(id3, 8.5, "Dalinar", "PASS", 0)
        AddLater(id3, 10.0, "Shallan", "GREED", 18)
        AddLater(id3, 11.5, "Jasnah", "NEED", 52)
        AddLater(id3, 13.0, "Teft", "GREED", 41)
        AddLater(id3, 14.0, "Hoid", "PASS", 0)

        RefreshPanel(id1)
        RefreshPanel(id2)
        RefreshPanel(id3)
        Reflow()
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CleanRolls|r: spawned 3 test rolls - names will trickle in over the next several seconds, then resolve on their own, just like a real roll.")
    elseif msg == "rftest" then
        -- Feeds fake lines through the REAL RollFor parsing functions (not
        -- just synthetic display data, unlike /cr test) - exercises the
        -- actual regexes end-to-end. Item icon/quality may not resolve if
        -- the client has never cached these specific items - that's fine,
        -- the point is checking the chat-text parsing, not the icon art.
        local function FeedRoll(delay, text)
            ScheduleTask(delay, function() HandleSystemRollLine(text) end)
        end
        local function FeedWin(delay, text)
            ScheduleTask(delay, function()
                if not HandleRollForWinnerLine(text) then
                    DEFAULT_CHAT_FRAME:AddMessage("|cffff5555CleanRolls|r: rftest winner line failed to match - " .. text)
                end
            end)
        end

        -- item 1: SR'd by all four, including you - everyone who reserved
        -- it rolls Need (100), never Offspec/Transmog, since you only SR
        -- what you actually want. You should see a Need button here -
        -- click it to test the real /roll (goes out via RandomRoll, so
        -- it'll actually show in your chat too). Given a 15s simulated
        -- timer (same auto-resolve mechanism /cr test uses) so it actually
        -- picks a winner - whoever's highest by then, including you if you
        -- clicked - instead of sitting unresolved until the 90s stale-
        -- timeout fallback, which felt like it was stuck forever.
        local link = "|cffa335ee|Hitem:19019:0:0:0|h[Thunderfury, Blessed Blade of the Windseeker]|h|r"
        HandleRollForItemLine("1. " .. link .. " (SR by Kaladin, Szeth, Dalinar and " .. PLAYER_NAME .. ")")
        FeedRoll(1.0, "Kaladin rolls 87 (1-100)")
        FeedRoll(2.0, "Szeth rolls 95 (1-100)")
        FeedRoll(3.0, "Dalinar rolls 42 (1-100)")

        local d1 = active[ItemKey(19019, "0")]
        if d1 then
            d1.simulatedTimer = true
            d1.rollTime = 15
            d1.rollStart = GetTime()
        end

        -- item 2: hard-reserved, auto-awarded, no rolling
        local link2 = "|cffa335ee|Hitem:17182:0:0:0|h[Brutality Blade]|h|r"
        HandleRollForItemLine("2. " .. link2 .. " (HR)")

        -- item 3: nobody soft-reserved it (no "(SR by ...)"/"(HR)" suffix at
        -- all - just "3. [Item]"), so it's open for anyone in the raid to
        -- roll on at whichever priority actually applies to them. Navani's
        -- Offspec 95 is numerically higher than either Need roll but still
        -- loses to both, same range-beats-raw-value check as before.
        local link3 = "|cffa335ee|Hitem:18563:0:0:0|h[Choker of the Fire Lord]|h|r"
        HandleRollForItemLine("3. " .. link3)
        FeedRoll(1.5, "Renarin rolls 60 (1-100)")
        FeedRoll(3.0, "Navani rolls 95 (1-99)")
        FeedRoll(4.5, "Teft rolls 70 (1-98)")
        FeedRoll(6.0, "Adolin rolls 88 (1-100)")
        FeedWin(7.5, "Adolin rolled the highest (88) for " .. link3 .. ".")

        -- item 4: SR'd by exactly one person - auto-awarded instantly, no
        -- roll happens at all, straight to the "X soft-ressed [Item]." line
        local link4 = "|cffa335ee|Hitem:17204:0:0:0|h[Eskhandar's Right Claw]|h|r"
        HandleRollForItemLine("4. " .. link4 .. " (SR by Jasnah)")
        FeedWin(1.0, "Jasnah soft-ressed " .. link4 .. ".")

        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CleanRolls|r: fed 4 fake RollFor lines through the real chat parser - SR'd with you in it (click the Need button!), solo-SR (instant auto-award), HR (no roll), and a free-roll item mixing Need/Offspec/Transmog.")
    elseif msg == "rfbtest" then
        -- Feeds fake addon messages through HandleRollForBroadcast itself -
        -- exercises the loadstring decode path against strings hand-built
        -- to match RollFor's actual M.dump() output syntax exactly
        -- (["key"]=value pairs), not just the higher-level display logic.
        local function FeedBroadcast(delay, msg)
            ScheduleTask(delay, function() HandleRollForBroadcast(msg, "TestSender") end)
        end

        local startPayload =
            '{["i"]={["t"]="Weapon",["id"]=19019,["n"]="Thunderfury_Blessed_Blade_of_the_Windseeker",' ..
            '["tx"]="INV_Sword_39",["q"]=4},["ic"]=1,["s"]=15,["st"]="NormalRoll",' ..
            '["sr"]={[1]={["t"]="SoftRes",["n"]="Kaladin",["c"]="Warrior",["ro"]=1},' ..
            '[2]={["t"]="SoftRes",["n"]="Szeth",["c"]="Rogue",["ro"]=1}},' ..
            '["th"]={["ms"]=100,["os"]=99,["tm"]=98}}'
        HandleRollForBroadcast("ROLL::START_ROLL::" .. startPayload, "TestSender")

        FeedBroadcast(1.0, 'ROLL::ROLL::{["pn"]="Kaladin",["pc"]="Warrior",["rt"]="MainSpec",["r"]=87,["pl"]=0}')
        FeedBroadcast(2.0, 'ROLL::ROLL::{["pn"]="Szeth",["pc"]="Rogue",["rt"]="MainSpec",["r"]=54,["pl"]=0}')
        FeedBroadcast(3.5, 'ROLL::FINISH::{[1]={["n"]="Kaladin",["c"]="Warrior",["rt"]="MainSpec",["r"]=87}}')

        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CleanRolls|r: fed 4 fake RollFor addon-comm messages (START_ROLL/ROLL/ROLL/FINISH) through the real broadcast decoder - if this looks right, the loadstring deserialization is working.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99CleanRolls|r commands: (/cleanrolls or /cr)")
        DEFAULT_CHAT_FRAME:AddMessage("  /cr test    - preview the window with fake rolls")
        DEFAULT_CHAT_FRAME:AddMessage("  /cr rftest  - preview RollFor chat-text SR/HR parsing with fake chat lines")
        DEFAULT_CHAT_FRAME:AddMessage("  /cr rfbtest - preview RollFor addon-comm broadcast parsing with fake messages")
        DEFAULT_CHAT_FRAME:AddMessage("  /cr reset   - reset window position")
        DEFAULT_CHAT_FRAME:AddMessage("  /cr lock    - hide the \"Loot Rolls\" header to save space")
        DEFAULT_CHAT_FRAME:AddMessage("  /cr unlock  - bring the header back so you can drag it")
    end
end
