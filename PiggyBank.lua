-- Piggy Bank: a virtual savings jar for your gold.
-- WoW addons can't move or lock gold, so the piggy is a ledger: it remembers how much
-- of your gold is "savings", hides that part from the bag money display, and nags you
-- if you spend into it. Smashing the piggy releases the savings back to "spendable".

local _, ns = ...
local L = ns.L

local MAX_RATE = 90
local MAX_GOALS = 5
local WHACKS_NEEDED = 3
local HISTORY_DAYS = 35
local DAY = 86400
local PIG_ICON = "Interface\\Icons\\Ability_Hunter_Pet_Boar"
local COPPER_PER_GOLD = 10000
local COIN_ICONS = {
    "Interface\\MoneyFrame\\UI-GoldIcon",
    "Interface\\MoneyFrame\\UI-SilverIcon",
    "Interface\\MoneyFrame\\UI-CopperIcon",
}

local CoinString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString

-- Piggy ranks, earned by lifetime savings (in gold), so smashing the piggy never demotes you.
local RANKS = {
    { 0,      L["Piglet in Training"] },
    { 1,      L["Copper Piglet"] },
    { 10,     L["Silver Sow"] },
    { 50,     L["Golden Hog"] },
    { 100,    L["Bacon Baron"] },
    { 250,    L["Lord of the Swine"] },
    { 500,    L["Ham-perial Treasurer"] },
    { 1000,   L["Gilded Boar"] },
    { 5000,   L["Hogger's Accountant"] },
    { 10000,  L["Legendary Swine of Azeroth"] },
    { 50000,  L["Trade Prince Porkington"] },
    { 100000, L["The Gold Cap Hog"] },
}

local DEFAULTS = {
    rate = 10,          -- % of income that goes into the piggy
    savings = 0,        -- copper currently in the piggy
    lifetime = 0,       -- copper ever saved
    broken = false,     -- smashed piggies don't save until you start a new one
    keepSpendable = 0,  -- copper; don't save while spendable gold is below this
    hideReal = true,    -- replace the bag money display with spendable gold
    scoldPopup = true,  -- pop the piggy up when you spend your savings
    vendorWarn = true,  -- flag vendor/trainer prices that would eat into savings
    loginMessage = true,
    sound = true,
    income = {          -- which kinds of gold gains count as income
        loot = true, quest = true, vendor = true, mail = true, other = true,
    },
    goals = {},         -- { name = "Mount", target = copper, reached = bool, everReached = bool }
    history = {},       -- ["2026-11-04"] = copper saved that day
    widget = { shown = false, locked = false, point = nil }, -- off by default; pops up to scold you anyway
    minimap = { shown = true, angle = 225 },                 -- degrees around the minimap edge
    stats = {
        piggySince = nil,   -- time() the current piggy was started
        incomeSeen = 0,     -- income the piggy took a cut of
        biggestDeposit = 0,
        smashes = 0,
        smashedOut = 0,
        raids = 0,          -- times you spent into your savings
        raided = 0,
        goalsCompleted = 0,
        goalsCashedOut = 0,
        cashedOut = 0,
    },
}

local db, account, charKey
local lastMoney
local windows = {}      -- open UIs: key -> true, or a GetTime() grace period after closing
local overlays = {}     -- bag money frame -> our replacement display
local ui = {}
local whacks, whackToken = 0, 0
local scoldToken, lastScold, lastHeadsUp = 0, nil, nil

local Refresh -- forward declaration

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Money(copper)
    return CoinString(math.max(0, math.floor(copper or 0)))
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff88cc" .. L["Piggy Bank"] .. ":|r " .. msg)
end

local function Sound(name)
    if db and not db.sound then return end
    local id = SOUNDKIT and SOUNDKIT[name]
    if id then PlaySound(id) end
end

local function GoldToCopper(text)
    local gold = tonumber(text)
    if not gold or gold < 0 then return nil end
    return math.floor(gold * COPPER_PER_GOLD)
end

local function SplitCoins(copper)
    copper = math.max(0, math.floor(copper or 0))
    return math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
end

local function Spendable()
    return math.max(0, GetMoney() - db.savings)
end

local function ApplyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            target[k] = type(v) == "table" and CopyTable(v) or v
        elseif type(v) == "table" and type(target[k]) == "table" then
            ApplyDefaults(target[k], v)
        end
    end
end

local function IsOpen(key)
    local v = windows[key]
    return v == true or (v and v > GetTime())
end

-- What kind of gold gain just happened, or nil if it isn't income at all
-- (moving gold out of a bank or getting it in a trade is shuffling, not earning).
local function IncomeSource()
    for _, key in ipairs({ "Banker", "GuildBanker", "AccountBanker", "TradePartner" }) do
        if IsOpen(key) then return nil end
    end
    for _, source in ipairs({ "mail", "vendor", "quest", "loot" }) do
        if IsOpen(source) then return source end
    end
    return "other"
end

---------------------------------------------------------------------------
-- Savings history and account-wide totals
---------------------------------------------------------------------------

local function DayKey(t)
    return date("%Y-%m-%d", t or time())
end

local function SavedOnDay(daysAgo)
    return db.history[DayKey(time() - daysAgo * DAY)] or 0
end

local function SavedThisWeek()
    local total = 0
    for i = 0, 6 do total = total + SavedOnDay(i) end
    return total
end

-- Average saved per day over the last week (or since this piggy started, if that's sooner).
local function DailyPace()
    local since = db.stats.piggySince or time()
    local days = math.max(1, math.min(7, math.ceil((time() - since) / DAY)))
    return SavedThisWeek() / days
end

-- Roughly how long until a goal is reached at the current pace.
local function GoalETA(goal)
    if db.broken then return L["paused"] end
    local pace = DailyPace()
    if pace <= 0 then return L["save a bit to see an ETA"] end
    local days = math.ceil((goal.target - db.savings) / pace)
    if days <= 1 then return L["~1 day"] end
    if days > 365 then return L["over a year"] end
    if days > 60 then return L["~%d months"]:format(math.floor(days / 30 + 0.5)) end
    return L["~%d days"]:format(days)
end

local function PruneHistory()
    local cutoff = DayKey(time() - HISTORY_DAYS * DAY)
    for key in pairs(db.history) do
        if key < cutoff then db.history[key] = nil end
    end
end

local function UpdateAccount()
    if not account then return end
    local c = account.chars[charKey] or {}
    account.chars[charKey] = c
    c.savings = db.savings
    c.class = select(2, UnitClass("player"))
    c.updated = time()
end

local function AccountTotal()
    local total, count = 0, 0
    for _, c in pairs(account.chars) do
        total = total + (c.savings or 0)
        count = count + 1
    end
    return total, count
end

local function AddAccountLines(tooltip)
    local list = {}
    for name, c in pairs(account.chars) do table.insert(list, { name = name, c = c }) end
    table.sort(list, function(a, b) return (a.c.savings or 0) > (b.c.savings or 0) end)
    for _, entry in ipairs(list) do
        local color = RAID_CLASS_COLORS and entry.c.class and RAID_CLASS_COLORS[entry.c.class]
        local r, g, b = 1, 1, 1
        if color then r, g, b = color.r, color.g, color.b end
        tooltip:AddDoubleLine(entry.name, Money(entry.c.savings), r, g, b, 1, 1, 1)
    end
end

---------------------------------------------------------------------------
-- Piggy logic
---------------------------------------------------------------------------

local function Celebrate(msg)
    Print(msg)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"])
    end
    Sound("READY_CHECK")
end

local function CheckGoals()
    for _, goal in ipairs(db.goals) do
        if not goal.reached and db.savings >= goal.target then
            goal.reached = true
            if not goal.everReached then
                goal.everReached = true
                db.stats.goalsCompleted = db.stats.goalsCompleted + 1
            end
            Celebrate(L["Goal reached: |cffffd100%s|r (%s)! Cash it out on the Goals tab."]:format(goal.name, Money(goal.target)))
        elseif goal.reached and db.savings < goal.target then
            goal.reached = false
        end
    end
end

local function RankFor(lifetime)
    local rank = 1
    for i, r in ipairs(RANKS) do
        if lifetime >= r[1] * COPPER_PER_GOLD then rank = i end
    end
    return rank
end

local function CheckRank()
    local rank = RankFor(db.lifetime)
    if rank > db.rank then
        db.rank = rank
        Celebrate(L["Piggy rank up! You're now a |cffffd100%s|r. Oink!"]:format(RANKS[rank][2]))
    end
end

local function AddToPiggy(copper)
    db.savings = db.savings + copper
    db.lifetime = db.lifetime + copper
    db.stats.biggestDeposit = math.max(db.stats.biggestDeposit, copper)
    local today = DayKey()
    db.history[today] = (db.history[today] or 0) + copper
    CheckGoals()
    CheckRank()
end

local function PickRandom(list, last)
    local i
    repeat i = math.random(#list) until i ~= last or #list == 1
    return list[i], i
end

-- Pop the piggy up with a speech bubble; it goes away again unless it's set to always show.
local function PopBubble(msg, r, g, b)
    local f = ui.widget
    if not f or not db.scoldPopup then return end
    f.bubble:SetBackdropBorderColor(r, g, b)
    f.bubble.text:SetText(msg)
    f.bubble:SetHeight(f.bubble.text:GetStringHeight() + 20)
    f.bubble:Show()
    f.scolding = true
    f.wiggle:Stop()
    f.wiggle:Play()
    scoldToken = scoldToken + 1
    local token = scoldToken
    C_Timer.After(8, function()
        if token ~= scoldToken then return end
        f.scolding = false
        f.bubble:Hide()
        Refresh()
    end)
    Refresh()
end

local function Scold(remaining)
    local msg
    msg, lastScold = PickRandom(ns.SCOLDS, lastScold)
    msg = L[msg]
    Print("|cffff5555" .. msg .. "|r " .. L["The piggy only holds %s now."]:format(Money(remaining)))
    Sound("IG_QUEST_FAILED")
    PopBubble(msg, 1, 0.3, 0.3)
end

-- A heads-up *before* you spend (auction house purchases).
local function HeadsUp(price)
    local msg
    msg, lastHeadsUp = PickRandom(ns.HEADS_UPS, lastHeadsUp)
    msg = L[msg]
    Print("|cffffa500" .. msg .. "|r " .. L["That's %s, and you only have %s spendable."]:format(Money(price), Money(Spendable())))
    Sound("RAID_WARNING")
    PopBubble(msg, 1, 0.65, 0)
end

local function OnMoneyChanged()
    local now = GetMoney()
    if not lastMoney then
        lastMoney = now
        return
    end
    local delta = now - lastMoney
    lastMoney = now

    local source = delta > 0 and IncomeSource()
    if source and db.income[source] and not db.broken and db.rate > 0 then
        local cut = math.floor(delta * db.rate / 100)
        -- Never save the gold you said you always want to keep spendable
        local room = now - db.savings - db.keepSpendable
        cut = math.min(cut, math.max(0, room))
        if cut > 0 then
            db.stats.incomeSeen = db.stats.incomeSeen + delta
            AddToPiggy(cut)
        end
    end

    if db.savings > now then
        db.stats.raids = db.stats.raids + 1
        db.stats.raided = db.stats.raided + (db.savings - now)
        db.savings = now
        CheckGoals()
        Scold(now)
    end
    Refresh()
end

local function BreakPiggy()
    local released = db.savings
    db.savings = 0
    db.broken = true
    db.stats.smashes = db.stats.smashes + 1
    db.stats.smashedOut = db.stats.smashedOut + released
    for _, goal in ipairs(db.goals) do goal.reached = false end
    Sound("LOOT_WINDOW_COIN_SOUND")
    Print(L["|cffffd100*CRASH!*|r %s spills across the floor. It's all spendable again."]:format(Money(released)))
    Print(L["Lifetime saved: %s."]:format(Money(db.lifetime)))
    Print(L["Want to keep saving? Open /piggy and click |cffffd100Start a New Piggy|r. No gold needed, it's free!"])
    Refresh()
end

local function NewPiggy()
    db.broken = false
    db.stats.piggySince = time()
    Sound("IG_CHARACTER_INFO_OPEN")
    Print(L["A shiny new piggy! Saving %d%% of everything you earn."]:format(db.rate))
    Refresh()
end

local function FeedPiggy(copper)
    if db.broken then Print(L["The piggy is smashed. Open /piggy and click |cffffd100Start a New Piggy|r first. It's free!"]) return false end
    if copper > Spendable() then Print(L["You don't have that much spendable gold."]) return false end
    AddToPiggy(copper)
    Sound("LOOT_WINDOW_COIN_SOUND")
    Print(L["Fed the piggy %s. Oink."]:format(Money(copper)))
    Refresh()
    return true
end

local function SetRate(rate)
    db.rate = math.max(0, math.min(MAX_RATE, math.floor(rate + 0.5)))
    Refresh()
end

local function SetKeepSpendable(copper)
    db.keepSpendable = math.max(0, copper)
    if db.keepSpendable > 0 then
        Print(L["The piggy will always leave you at least %s spendable."]:format(Money(db.keepSpendable)))
    else
        Print(L["Keep-spendable amount turned off."])
    end
    Refresh()
end

local function AddGoal(name, copper)
    if #db.goals >= MAX_GOALS then Print(L["You can have up to %d goals."]:format(MAX_GOALS)) return false end
    name = (name and name:match("^%s*(.-)%s*$")) or ""
    if name == "" then name = L["Goal %d"]:format(#db.goals + 1) end
    table.insert(db.goals, { name = name, target = copper, reached = db.savings >= copper, everReached = db.savings >= copper })
    Print(L["New goal: |cffffd100%s|r - %s"]:format(name, Money(copper)))
    Refresh()
    return true
end

local function RemoveGoal(index)
    local goal = table.remove(db.goals, index)
    if goal then Print(L["Removed goal: %s"]:format(goal.name)) end
    Refresh()
end

-- Spend a reached goal: release exactly its amount without smashing the whole piggy.
local function CashOutGoal(goal)
    for i, g in ipairs(db.goals) do
        if g == goal then
            local amount = math.min(goal.target, db.savings)
            db.savings = db.savings - amount
            db.stats.goalsCashedOut = db.stats.goalsCashedOut + 1
            db.stats.cashedOut = db.stats.cashedOut + amount
            table.remove(db.goals, i)
            CheckGoals()
            Sound("LOOT_WINDOW_COIN_SOUND")
            Print(L["Cashed out %s for |cffffd100%s|r. It's spendable now. Go treat yourself!"]:format(Money(amount), goal.name))
            Refresh()
            return
        end
    end
end

StaticPopupDialogs["PIGGYBANK_BREAK"] = {
    text = L["Smash the piggy bank?\n\n%s will become spendable again, and the piggy stops saving.\n\nYou can start a new piggy any time with one click. It doesn't cost anything."],
    button1 = L["SMASH!"],
    button2 = CANCEL,
    OnAccept = function() BreakPiggy() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["PIGGYBANK_CASHOUT"] = {
    text = L["Cash out %s for \"%s\"?\n\nThat amount leaves the piggy and becomes spendable, and the goal is done. The rest of your savings stay in the piggy."],
    button1 = L["Cash Out"],
    button2 = CANCEL,
    OnAccept = function(_, goal) CashOutGoal(goal) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function Whack()
    if db.broken then NewPiggy() return end
    whacks = whacks + 1
    whackToken = whackToken + 1
    if whacks >= WHACKS_NEEDED then
        whacks = 0
        StaticPopup_Show("PIGGYBANK_BREAK", Money(db.savings))
    else
        Sound("IG_ABILITY_ICON_DROP")
        local token = whackToken
        C_Timer.After(4, function()
            if token == whackToken then whacks = 0; Refresh() end
        end)
    end
    Refresh()
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------

local function FillTooltip(tooltip)
    tooltip:AddLine(L["Piggy Bank"] .. (db.broken and (" |cffff5555(" .. L["smashed"] .. ")|r") or ""))
    tooltip:AddLine(RANKS[db.rank][2], 1, 0.82, 0)
    tooltip:AddDoubleLine(L["Spendable"], Money(Spendable()), 1, 1, 1, 1, 1, 1)
    tooltip:AddDoubleLine(L["In the piggy"], Money(db.savings), 1, 0.53, 0.8, 1, 1, 1)
    if db.broken then
        tooltip:AddLine(L["Not saving. Open the piggy and click Start a New Piggy (free)."], 1, 0.82, 0, true)
    else
        tooltip:AddDoubleLine(L["Saving"], L["%d%% of income"]:format(db.rate), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
    end
    local total, count = AccountTotal()
    if count > 1 then
        tooltip:AddDoubleLine(L["All characters"], Money(total), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
    end
    for _, goal in ipairs(db.goals) do
        local pct = math.min(100, math.floor(db.savings / goal.target * 100))
        local r, g = goal.reached and 0.2 or 1, goal.reached and 1 or 0.82
        local right = goal.reached and (pct .. "%") or (pct .. "% (" .. GoalETA(goal) .. ")")
        tooltip:AddDoubleLine(goal.name, right, r, g, 0, r, g, 0)
    end
    tooltip:AddLine(L["Click to open the piggy."], 0.5, 0.5, 0.5)
end

local function ShowTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOPLEFT")
    FillTooltip(GameTooltip)
    GameTooltip:Show()
end

local function HideTooltip() GameTooltip:Hide() end

---------------------------------------------------------------------------
-- Bag money display: hide the real total, show spendable instead
---------------------------------------------------------------------------

-- Bag addons whose money frames we cover too. They can show other characters' bags,
-- so those overlays only apply when the frame is showing *your* gold.
-- Each entry is a bag window name; its money display is the window's .MoneyFrame.
local BAG_ADDON_WINDOWS = {
    "BagnonInventory%d",
    "BagnonBank%d",
}

local function ShouldHide(moneyFrame, o)
    if not db.hideReal then return false end
    if o.checkOwner and o.shownMoney and o.shownMoney ~= GetMoney() then return false end
    return true
end

-- Baganator draws gold as plain text in a "currency widget" (backpack and character bank).
-- Every widget is updated through one mixin method, so we hook that and rewrite the text
-- after Baganator does, but only while it's showing the character you're playing.
local baganatorWidgets = {}

local function IsBaganatorShowingMe(widget)
    local current = Syndicator and Syndicator.API and Syndicator.API.GetCurrentCharacter and Syndicator.API.GetCurrentCharacter()
    return current and widget.lastCharacter == current
end

local function ApplyBaganator(widget)
    if not (widget.Money and widget:IsVisible() and IsBaganatorShowingMe(widget)) then return end
    if db.hideReal then
        local icon = "|T" .. PIG_ICON .. ":0|t "
        widget.Money:SetText(icon .. GetMoneyString(Spendable(), true):gsub("|T", " |T"))
        widget.piggyApplied = true
    elseif widget.piggyApplied then
        widget.piggyApplied = nil
        widget:UpdateCurrencies(widget.lastCharacter) -- let Baganator put the real total back
        return
    else
        return
    end
    if widget.UpdateCurrencyTextPositions and widget.allowedWidth then
        widget:UpdateCurrencyTextPositions(widget.allowedWidth, widget.nextRowWidth)
    end
end

local baganatorHooked = false
local function HookBaganator()
    if baganatorHooked or not (BaganatorCurrencyWidgetMixin and BaganatorCurrencyWidgetMixin.UpdateCurrencies) then return end
    baganatorHooked = true
    hooksecurefunc(BaganatorCurrencyWidgetMixin, "UpdateCurrencies", function(widget)
        if not baganatorWidgets[widget] then
            baganatorWidgets[widget] = true
            -- Add the piggy's numbers under Baganator's own gold tooltip
            if widget.Money and widget.Money.HookScript then
                widget.Money:HookScript("OnEnter", function()
                    if not (db and IsBaganatorShowingMe(widget)) then return end
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddDoubleLine(L["Piggy Bank"], "", 1, 0.53, 0.8)
                    GameTooltip:AddDoubleLine(L["In the piggy"], Money(db.savings), 1, 1, 1, 1, 1, 1)
                    GameTooltip:AddDoubleLine(L["Spendable"], Money(Spendable()), 1, 1, 1, 1, 1, 1)
                    GameTooltip:Show()
                end)
            end
        end
        if db then ApplyBaganator(widget) end
    end)
end

local function RefreshOverlays()
    local text = Money(Spendable())
    for moneyFrame, o in pairs(overlays) do
        local hide = ShouldHide(moneyFrame, o)
        moneyFrame:SetAlpha(hide and 0 or 1)
        o:SetShown(hide)
        o.text:SetText(text)
        o.icon:SetDesaturated(db.broken)
    end
    for widget in pairs(baganatorWidgets) do ApplyBaganator(widget) end
end

local function CreateOverlay(moneyFrame, checkOwner)
    if not moneyFrame or overlays[moneyFrame] or not moneyFrame:GetParent() then return end
    local o = CreateFrame("Button", nil, moneyFrame:GetParent())
    o.checkOwner = checkOwner
    o:SetAllPoints(moneyFrame)
    o:SetFrameLevel(moneyFrame:GetFrameLevel() + 5)

    o.text = o:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    o.text:SetPoint("RIGHT", o, "RIGHT", -4, 0)
    o.icon = o:CreateTexture(nil, "OVERLAY")
    o.icon:SetSize(14, 14)
    o.icon:SetTexture(PIG_ICON)
    o.icon:SetPoint("RIGHT", o.text, "LEFT", -4, 0)

    o:SetScript("OnEnter", ShowTooltip)
    o:SetScript("OnLeave", HideTooltip)
    o:SetScript("OnClick", function() ui.ToggleWindow() end)
    moneyFrame:HookScript("OnShow", RefreshOverlays)
    overlays[moneyFrame] = o
    RefreshOverlays()
end

-- Bag addons create their frames the first time you open your bags.
local function ScanBagAddons()
    for _, pattern in ipairs(BAG_ADDON_WINDOWS) do
        for i = 1, 10 do
            local window = _G[pattern:format(i)]
            if window and window.MoneyFrame then CreateOverlay(window.MoneyFrame, true) end
        end
    end
end

local function SetupBagOverlays()
    CreateOverlay(ContainerFrameCombinedBags and ContainerFrameCombinedBags.MoneyFrame)
    CreateOverlay(_G.ContainerFrame1MoneyFrame)

    -- Remember what each money frame is showing, to tell your bags from an alt's
    hooksecurefunc("MoneyFrame_Update", function(frame, money)
        if type(frame) == "string" then frame = _G[frame] end
        local o = frame and overlays[frame]
        if o then
            o.shownMoney = money
            RefreshOverlays()
        end
    end)

    local function OnBagsToggled()
        C_Timer.After(0.05, function()
            ScanBagAddons()
            RefreshOverlays()
        end)
    end
    for _, name in ipairs({ "ToggleAllBags", "OpenAllBags", "ToggleBackpack", "OpenBackpack", "ToggleBag" }) do
        if _G[name] then hooksecurefunc(name, OnBagsToggled) end
    end
    ScanBagAddons()
end

---------------------------------------------------------------------------
-- Floating widget
---------------------------------------------------------------------------

local function PlaceWidget(f)
    f:ClearAllPoints()
    local p = db.widget.point
    if p then f:SetPoint(p[1], UIParent, p[2], p[3], p[4]) else f:SetPoint("CENTER", UIParent, "CENTER", 0, -200) end
end

local function CreateWidget()
    local f = CreateFrame("Button", "PiggyBankWidget", UIParent, "BackdropTemplate")
    f:SetSize(180, 42)
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f:SetBackdropColor(0, 0, 0, 0.75)
    f:SetBackdropBorderColor(1, 0.53, 0.8)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:RegisterForClicks("AnyUp")
    PlaceWidget(f)

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(32, 32)
    f.icon:SetPoint("LEFT", 6, 0)
    f.icon:SetTexture(PIG_ICON)

    f.savings = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.savings:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 6, -1)
    f.spendable = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.spendable:SetPoint("BOTTOMLEFT", f.icon, "BOTTOMRIGHT", 6, 1)

    -- Speech bubble for scolding
    f.bubble = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.bubble:SetWidth(260)
    f.bubble:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 4)
    f.bubble:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f.bubble:SetBackdropColor(1, 1, 1, 0.95)
    f.bubble:SetBackdropBorderColor(1, 0.3, 0.3)
    f.bubble.text = f.bubble:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.bubble.text:SetPoint("TOPLEFT", 10, -10)
    f.bubble.text:SetWidth(240)
    f.bubble.text:SetJustifyH("LEFT")
    f.bubble.text:SetTextColor(0.15, 0.05, 0.05)
    f.bubble:Hide()

    -- Angry little pig wiggle
    f.wiggle = f.icon:CreateAnimationGroup()
    for order, x in ipairs({ -4, 8, -8, 8, -8, 4 }) do
        local a = f.wiggle:CreateAnimation("Translation")
        a:SetOffset(x, 0)
        a:SetDuration(0.05)
        a:SetOrder(order)
    end

    f:SetScript("OnDragStart", function(self)
        if db.widget.locked then return end
        self.moved = true
        self:StartMoving()
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        db.widget.point = { point, relPoint, x, y }
    end)
    f:SetScript("OnClick", function(self)
        if self.moved then self.moved = nil return end
        ui.ToggleWindow()
    end)
    f:SetScript("OnEnter", ShowTooltip)
    f:SetScript("OnLeave", HideTooltip)
    ui.widget = f
end

local function RefreshWidget()
    local f = ui.widget
    f:SetShown(db.widget.shown or f.scolding)
    f.icon:SetDesaturated(db.broken)
    f.savings:SetText(db.broken and ("|cffff5555" .. L["Smashed!"] .. "|r " .. L["Click for a new one"]) or Money(db.savings))
    f.spendable:SetText(L["Spendable: %s"]:format(Money(Spendable())))
    f:SetWidth(math.max(140, 50 + math.max(f.savings:GetStringWidth(), f.spendable:GetStringWidth())))
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------

-- When another addon has loaded LibDBIcon (most minimap-button addons do), the piggy joins
-- it, so it lines up with everyone else's buttons and works with button-bag and minimap
-- skin addons. Otherwise we draw our own button using the same ring LibDBIcon uses.
local ICON_NAME = "Piggy Bank"

local function GetDBIcon()
    return ui.broker and LibStub and LibStub("LibDBIcon-1.0", true)
end

-- Which quarters of the minimap are round, per minimap shape (LibDBIcon's table).
local MINIMAP_SHAPES = {
    ["ROUND"] = { true, true, true, true },
    ["SQUARE"] = { false, false, false, false },
    ["CORNER-TOPLEFT"] = { false, false, false, true },
    ["CORNER-TOPRIGHT"] = { false, false, true, false },
    ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
    ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
    ["SIDE-LEFT"] = { false, true, false, true },
    ["SIDE-RIGHT"] = { true, false, true, false },
    ["SIDE-TOP"] = { false, false, true, true },
    ["SIDE-BOTTOM"] = { true, true, false, false },
    ["TRICORNER-TOPLEFT"] = { false, true, true, true },
    ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
    ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
    ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local function PlaceMinimapButton(b)
    local angle = math.rad(db.minimap.angle or 225)
    local x, y = math.cos(angle), math.sin(angle)
    local q = 1
    if x < 0 then q = q + 1 end
    if y > 0 then q = q + 2 end
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local quadTable = MINIMAP_SHAPES[shape] or MINIMAP_SHAPES.ROUND
    local w = Minimap:GetWidth() / 2 + 5
    local h = Minimap:GetHeight() / 2 + 5
    if quadTable[q] then
        x, y = x * w, y * h
    else
        local diagW = math.sqrt(2 * w * w) - 10
        local diagH = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(x * diagW, w))
        y = math.max(-h, math.min(y * diagH, h))
    end
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    local DBIcon = GetDBIcon()
    if DBIcon then
        -- LibDBIcon saves its own keys (hide, minimapPos) in this table.
        db.minimap.minimapPos = db.minimap.minimapPos or db.minimap.angle
        db.minimap.hide = not db.minimap.shown
        DBIcon:Register(ICON_NAME, ui.broker, db.minimap)
        ui.minimapButton = DBIcon:GetMinimapButton(ICON_NAME)
        ui.usingDBIcon = true
        return
    end

    local b = CreateFrame("Button", "PiggyBankMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("AnyUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(50, 50)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(24, 24)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("CENTER")
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(18, 18)
    b.icon:SetTexture(PIG_ICON)
    b.icon:SetPoint("CENTER")

    -- Drag around the edge of the minimap
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            PlaceMinimapButton(self)
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnClick", function() ui.ToggleWindow() end)
    b:SetScript("OnEnter", ShowTooltip)
    b:SetScript("OnLeave", HideTooltip)

    PlaceMinimapButton(b)
    ui.minimapButton = b
end

local function RefreshMinimapButton()
    if ui.usingDBIcon then
        local DBIcon = GetDBIcon()
        db.minimap.hide = not db.minimap.shown
        if db.minimap.shown then DBIcon:Show(ICON_NAME) else DBIcon:Hide(ICON_NAME) end
    else
        ui.minimapButton:SetShown(db.minimap.shown)
    end
    local b = ui.minimapButton
    if b and b.icon then b.icon:SetDesaturated(db.broken) end
end

---------------------------------------------------------------------------
-- Data broker (Titan Panel, ElvUI DataTexts, Bazooka, ChocolateBar...)
---------------------------------------------------------------------------

-- Only used when another addon has loaded LibDataBroker; we don't ship it ourselves.
local function SetupDataBroker()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    if not LDB then return end
    ui.broker = LDB:NewDataObject("Piggy Bank", {
        type = "data source",
        label = L["Piggy Bank"],
        icon = PIG_ICON,
        text = "",
        OnClick = function() ui.ToggleWindow() end,
        OnTooltipShow = function(tooltip) FillTooltip(tooltip) end,
    })
end

local function RefreshDataBroker()
    if not ui.broker then return end
    ui.broker.text = db.broken and ("|cffff5555" .. L["Smashed!"] .. "|r") or Money(db.savings)
end

---------------------------------------------------------------------------
-- Widgets for the main window
---------------------------------------------------------------------------

local function Label(parent, template, ...)
    local fs = parent:CreateFontString(nil, "OVERLAY", template)
    fs:SetPoint(...)
    return fs
end

local function Header(parent, text, y)
    local fs = Label(parent, "GameFontNormal", "TOPLEFT", 4, y)
    fs:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", fs, "RIGHT", 8, 0)
    line:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
    line:SetColorTexture(1, 0.82, 0, 0.25)
    return fs, line
end

local function Button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function EditBox(parent, width)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    e:SetScript("OnEscapePressed", e.ClearFocus)
    return e
end

local function CheckBox(parent, label, tooltip, onClick, ...)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint(...)
    cb.label = Label(parent, "GameFontHighlight", "LEFT", cb, "RIGHT", 2, 1)
    cb.label:SetText(label)
    cb:SetScript("OnClick", function(self)
        Sound(self:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
        onClick(self:GetChecked())
    end)
    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(label, 1, 1, 1)
            GameTooltip:AddLine(tooltip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", HideTooltip)
    end
    return cb
end

-- Big gold / silver / copper readout with coin icons.
local function CoinDisplay(parent, font, iconSize)
    local d = CreateFrame("Frame", nil, parent)
    d:SetSize(200, iconSize)
    d.parts = {}
    local prev
    for i, tex in ipairs(COIN_ICONS) do
        local fs = d:CreateFontString(nil, "OVERLAY", font)
        if prev then fs:SetPoint("LEFT", prev, "RIGHT", 8, 0) else fs:SetPoint("LEFT", d, "LEFT", 0, 0) end
        local icon = d:CreateTexture(nil, "ARTWORK")
        icon:SetSize(iconSize, iconSize)
        icon:SetTexture(tex)
        icon:SetPoint("LEFT", fs, "RIGHT", 3, 0)
        d.parts[i] = fs
        prev = icon
    end
    function d:SetAmount(copper)
        local g, s, c = SplitCoins(copper)
        self.parts[1]:SetText(BreakUpLargeNumbers and BreakUpLargeNumbers(g) or g)
        self.parts[2]:SetText(s)
        self.parts[3]:SetText(c)
    end
    return d
end

-- Three boxes for gold / silver / copper. Tab moves between them.
local function CoinInput(parent)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(190, 20)
    local boxes = {}
    local specs = { { 70, 7 }, { 28, 2 }, { 28, 2 } }
    local prev
    for i, spec in ipairs(specs) do
        local e = EditBox(holder, spec[1])
        e:SetNumeric(true)
        e:SetMaxLetters(spec[2])
        e:SetJustifyH("RIGHT")
        if prev then e:SetPoint("LEFT", prev, "RIGHT", 12, 0) else e:SetPoint("LEFT", holder, "LEFT", 6, 0) end
        local icon = holder:CreateTexture(nil, "ARTWORK")
        icon:SetSize(13, 13)
        icon:SetTexture(COIN_ICONS[i])
        icon:SetPoint("LEFT", e, "RIGHT", 2, 0)
        e:SetScript("OnTabPressed", function()
            boxes[IsShiftKeyDown() and ((i + 1) % 3 + 1) or (i % 3 + 1)]:SetFocus()
        end)
        boxes[i] = e
        prev = icon
    end
    function holder:GetCopper()
        local g = tonumber(boxes[1]:GetText()) or 0
        local s = math.min(99, tonumber(boxes[2]:GetText()) or 0)
        local c = math.min(99, tonumber(boxes[3]:GetText()) or 0)
        return g * COPPER_PER_GOLD + s * 100 + c
    end
    function holder:Clear()
        for _, e in ipairs(boxes) do e:SetText(""); e:ClearFocus() end
    end
    function holder:OnEnter(fn)
        for _, e in ipairs(boxes) do e:SetScript("OnEnterPressed", fn) end
    end
    holder.boxes = boxes
    return holder
end

-- Classic Blizzard-style horizontal slider.
local function Slider(parent, width, minV, maxV, onChange)
    local s = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    s:SetOrientation("HORIZONTAL")
    s:SetSize(width, 17)
    s:SetHitRectInsets(0, 0, -10, -10)
    s:SetBackdrop({
        bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
        edgeFile = "Interface\\Buttons\\UI-SliderBar-Border",
        tile = true, tileSize = 8, edgeSize = 8,
        insets = { left = 3, right = 3, top = 6, bottom = 6 },
    })
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(1)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s:EnableMouseWheel(true)
    s:SetScript("OnValueChanged", function(_, value) onChange(math.floor(value + 0.5)) end)
    s:SetScript("OnMouseWheel", function(self, delta) self:SetValue(self:GetValue() + delta) end)
    return s
end

-- Classic clients don't have every modern template, so use the first one that exists.
local function HasTemplate(template)
    if not (C_XMLUtil and C_XMLUtil.GetTemplateInfo) then return true end
    return C_XMLUtil.GetTemplateInfo(template) ~= nil
end

local function CreateFromFirst(frameType, name, parent, templates)
    for _, template in ipairs(templates) do
        if HasTemplate(template) then
            local ok, frame = pcall(CreateFrame, frameType, name, parent, template)
            if ok and frame then return frame, template end
        end
    end
    return CreateFrame(frameType, name, parent), nil
end

---------------------------------------------------------------------------
-- Main window (tabs: Piggy / Goals / Stats / Settings)
---------------------------------------------------------------------------

local TAB_NAMES = { L["Piggy"], L["Goals"], L["Stats"], L["Settings"] }

local function BuildPiggyPage(f, page)
    local _, piggyLine = Header(page, L["In the Piggy"], 0)
    f.rankText = Label(page, "GameFontNormal", "TOPRIGHT", -8, 0)
    piggyLine:SetPoint("RIGHT", f.rankText, "LEFT", -8, 0)
    f.savingsCoins = CoinDisplay(page, "GameFontHighlightLarge", 18)
    f.savingsCoins:SetPoint("TOPLEFT", 12, -24)
    f.status = Label(page, "GameFontHighlightSmall", "TOPLEFT", 12, -50)
    f.status:SetWidth(330)
    f.status:SetJustifyH("LEFT")

    Label(page, "GameFontNormal", "TOPLEFT", 12, -74):SetText(L["Spendable:"])
    f.spendableCoins = CoinDisplay(page, "GameFontHighlight", 13)
    f.spendableCoins:SetPoint("TOPLEFT", 100, -74)

    local _, rateLine = Header(page, L["Savings Rate"], -106)
    f.rateText = Label(page, "GameFontHighlightLarge", "TOPRIGHT", -8, -103)
    rateLine:SetPoint("RIGHT", f.rateText, "LEFT", -8, 0)
    local minus = Button(page, "-", 24, function() SetRate(db.rate - (IsShiftKeyDown() and 5 or 1)) end)
    minus:SetPoint("TOPLEFT", 10, -132)
    f.rateSlider = Slider(page, 234, 0, MAX_RATE, function(v) if db and v ~= db.rate then SetRate(v) end end)
    f.rateSlider:SetPoint("LEFT", minus, "RIGHT", 18, 0)
    local plus = Button(page, "+", 24, function() SetRate(db.rate + (IsShiftKeyDown() and 5 or 1)) end)
    plus:SetPoint("LEFT", f.rateSlider, "RIGHT", 18, 0)
    Label(page, "GameFontDisableSmall", "TOPLEFT", f.rateSlider, "BOTTOMLEFT", 0, -2):SetText("0%")
    Label(page, "GameFontDisableSmall", "TOPRIGHT", f.rateSlider, "BOTTOMRIGHT", 0, -2):SetText(MAX_RATE .. "%")
    Label(page, "GameFontHighlightSmall", "TOP", f.rateSlider, "BOTTOM", 0, -2):SetText(L["of everything you earn"])

    Header(page, L["Feed the Piggy"], -196)
    f.feedInput = CoinInput(page)
    f.feedInput:SetPoint("TOPLEFT", 10, -220)
    local function SubmitFeed()
        local copper = f.feedInput:GetCopper()
        if copper <= 0 then return end
        if FeedPiggy(copper) then f.feedInput:Clear() end
    end
    f.feedInput:OnEnter(SubmitFeed)
    Button(page, L["Feed"], 80, SubmitFeed):SetPoint("LEFT", f.feedInput, "RIGHT", 10, 0)
    Label(page, "GameFontDisableSmall", "TOPLEFT", 12, -248):SetText(L["Drop in spendable gold by hand. No take-backs!"])

    Header(page, L["Break the Piggy"], -280)
    local breakHelp = Label(page, "GameFontHighlightSmall", "TOPLEFT", 12, -302)
    breakHelp:SetWidth(330)
    breakHelp:SetJustifyH("LEFT")
    breakHelp:SetText(L["Need your gold back? Whack the piggy %d times to smash it open. It won't save again until you start a new one (free)."]:format(WHACKS_NEEDED))
    f.breakBtn = Button(page, "", 220, Whack)
    f.breakBtn:SetHeight(26)
    f.breakBtn:SetPoint("TOP", page, "TOP", 0, -334)
end

local function BuildGoalsPage(f, page)
    local _, goalsLine = Header(page, L["Savings Goals"], 0)
    f.goalCount = Label(page, "GameFontHighlightSmall", "TOPRIGHT", -8, -2)
    goalsLine:SetPoint("RIGHT", f.goalCount, "LEFT", -8, 0)
    f.rows = {}
    for i = 1, MAX_GOALS do
        local row = CreateFrame("Frame", nil, page)
        row:SetSize(340, 34)
        row:SetPoint("TOPLEFT", 8, -22 - (i - 1) * 38)
        row.name = Label(row, "GameFontNormal", "TOPLEFT", 0, 0)
        row.amount = Label(row, "GameFontHighlightSmall", "TOPRIGHT", -26, 0)
        row.bar = CreateFrame("StatusBar", nil, row, "BackdropTemplate")
        row.bar:SetPoint("TOPLEFT", 0, -16)
        row.bar:SetSize(312, 14)
        row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        row.bar:SetMinMaxValues(0, 1)
        row.bar:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 8, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        row.bar:SetBackdropColor(0, 0, 0, 0.6)
        row.pct = Label(row.bar, "GameFontHighlightSmall", "CENTER", 0, 0)
        local remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
        remove:SetSize(24, 24)
        remove:SetPoint("LEFT", row.bar, "RIGHT", 0, 0)
        remove:SetScript("OnClick", function() RemoveGoal(i) end)
        -- Shown in place of the amount once a goal is reached
        row.cashOut = Button(row, L["Cash Out"], 90, function()
            local goal = db.goals[i]
            if goal then StaticPopup_Show("PIGGYBANK_CASHOUT", Money(goal.target), goal.name, goal) end
        end)
        row.cashOut:SetHeight(18)
        row.cashOut:SetPoint("TOPRIGHT", -26, 3)
        f.rows[i] = row
    end
    f.noGoals = Label(page, "GameFontDisable", "TOPLEFT", 12, -30)
    f.noGoals:SetText(L["No goals yet. What are you saving up for?"])

    Header(page, L["New Goal"], -222)
    Label(page, "GameFontHighlight", "TOPLEFT", 12, -250):SetText(L["Name"])
    f.goalName = EditBox(page, 220)
    f.goalName:SetPoint("TOPLEFT", 80, -246)
    f.goalName:SetMaxLetters(40)
    Label(page, "GameFontHighlight", "TOPLEFT", 12, -280):SetText(L["Amount"])
    f.goalInput = CoinInput(page)
    f.goalInput:SetPoint("TOPLEFT", 74, -276)
    local function SubmitGoal()
        local copper = f.goalInput:GetCopper()
        if copper <= 0 then Print(L["Enter how much the goal costs."]) return end
        if AddGoal(f.goalName:GetText(), copper) then
            f.goalName:SetText("")
            f.goalName:ClearFocus()
            f.goalInput:Clear()
        end
    end
    f.goalInput:OnEnter(SubmitGoal)
    f.goalName:SetScript("OnEnterPressed", function() f.goalInput.boxes[1]:SetFocus() end)
    f.goalName:SetScript("OnTabPressed", function() f.goalInput.boxes[1]:SetFocus() end)
    f.addGoalBtn = Button(page, L["Add Goal"], 120, SubmitGoal)
    f.addGoalBtn:SetPoint("TOPLEFT", 80, -310)
    Label(page, "GameFontDisableSmall", "TOPLEFT", 12, -344):SetText(L["Reached a goal? Click Cash Out to spend just that amount."])
end

local function NextRankText()
    local next = RANKS[db.rank + 1]
    if not next then return L["Top rank!"] end
    return L["Next: %s in %s"]:format(next[2], Money(next[1] * COPPER_PER_GOLD - db.lifetime))
end

local function AddRankLines(tooltip)
    tooltip:AddLine(NextRankText(), 1, 1, 1)
    tooltip:AddLine(" ")
    for i, r in ipairs(RANKS) do
        local reached = i <= db.rank
        local color = reached and 1 or 0.5
        tooltip:AddDoubleLine((reached and "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t " or "    ") .. r[2],
            Money(r[1] * COPPER_PER_GOLD), color, color * 0.82, reached and 0 or color, color, color, color)
    end
    tooltip:AddLine(L["Ranks come from lifetime savings, so smashing the piggy never costs you one."], 0.6, 0.6, 0.6, true)
end

-- { label, value function, optional tooltip function }
local STAT_ROWS = {
    { "Piggy rank",                 function() return RANKS[db.rank][2] end, AddRankLines },
    { "Current savings rate", function()
        return db.broken and ("|cffff5555" .. L["smashed (start a new one)"] .. "|r") or (db.rate .. "%")
    end },
    { "Current piggy's age", function()
        local since = db.stats.piggySince
        if db.broken or not since then return "-" end
        local age = time() - since
        return age < 60 and L["brand new"] or SecondsToTime(age)
    end },
    { "Saved this week",            function() return Money(SavedThisWeek()) end },
    { "Lifetime saved",             function() return Money(db.lifetime) end },
    { "Income tracked",             function() return Money(db.stats.incomeSeen) end },
    { "Biggest single deposit",     function() return Money(db.stats.biggestDeposit) end },
    { "All characters",             function() return Money((AccountTotal())) end, AddAccountLines },
    { "Goals completed",            function() return db.stats.goalsCompleted end },
    { "Goals cashed out",           function() return db.stats.goalsCashedOut end },
    { "Piggies smashed",            function() return db.stats.smashes end },
    { "Gold released by smashing",  function() return Money(db.stats.smashedOut) end },
    { "Times caught raiding piggy", function() return db.stats.raids end },
    { "Gold raided from piggy",     function() return Money(db.stats.raided) end },
}

local function BuildStatsPage(f, page)
    Header(page, L["Statistics"], 0)
    f.statValues = {}
    for i, stat in ipairs(STAT_ROWS) do
        local y = -22 - (i - 1) * 21
        local row = CreateFrame("Frame", nil, page)
        row:SetPoint("TOPLEFT", 4, y + 2)
        row:SetPoint("RIGHT", page, "RIGHT", -4, 0)
        row:SetHeight(20)
        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0.08)
        Label(row, "GameFontNormal", "LEFT", 8, 0):SetText(L[stat[1]])
        f.statValues[i] = Label(row, "GameFontHighlight", "RIGHT", -8, 0)
        if stat[3] then
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(L[stat[1]])
                stat[3](GameTooltip)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", HideTooltip)
        end
    end

    -- Last 7 days bar chart
    local top = -22 - #STAT_ROWS * 21 - 8
    Header(page, L["Last 7 Days"], top)
    local baseline = top - 62
    f.chart = {}
    local slot = 330 / 7
    for i = 1, 7 do
        local x = 14 + (i - 1) * slot
        local bar = page:CreateTexture(nil, "ARTWORK")
        bar:SetWidth(26)
        bar:SetPoint("BOTTOMLEFT", page, "TOPLEFT", x + (slot - 26) / 2, baseline)
        local day = Label(page, "GameFontDisableSmall", "TOP", bar, "BOTTOM", 0, -2)
        local hover = CreateFrame("Frame", nil, page)
        hover:SetSize(slot, 60)
        hover:SetPoint("BOTTOMLEFT", page, "TOPLEFT", x, baseline - 14)
        hover:EnableMouse(true)
        hover:SetScript("OnEnter", function(self)
            -- Below the bars, so it doesn't cover the "Last 7 Days" heading
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddDoubleLine(self.dayName or "", Money(self.amount or 0), 1, 0.82, 0, 1, 1, 1)
            GameTooltip:Show()
        end)
        hover:SetScript("OnLeave", HideTooltip)
        f.chart[i] = { bar = bar, day = day, hover = hover }
    end
end

local function BuildSettingsPage(f, page)
    -- The settings list is longer than the window, so it scrolls
    local scroll, template = CreateFromFirst("ScrollFrame", "PiggyBankSettingsScroll", page,
        { "UIPanelScrollFrameTemplate", "ScrollFrameTemplate" })
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)
    if not template then
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            local max = self:GetVerticalScrollRange()
            self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 30)))
        end)
    end
    -- Give the scroll bar a dark track, so the thumb doesn't float on its own
    local bar = scroll.ScrollBar or _G["PiggyBankSettingsScrollScrollBar"]
    if bar then
        local track = bar:CreateTexture(nil, "BACKGROUND")
        track:SetPoint("TOPLEFT", 0, 16)
        track:SetPoint("BOTTOMRIGHT", 0, -16)
        track:SetColorTexture(0, 0, 0, 0.4)
        local thumb = bar.GetThumbTexture and bar:GetThumbTexture()
        if thumb then -- crop the knob art's empty edges, like Blizzard's own scroll bars
            thumb:SetTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
            thumb:SetTexCoord(0.2, 0.8, 0.125, 0.875)
            thumb:SetSize(18, 24)
        end
    end
    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(326)
    scroll:SetScrollChild(child)

    f.settingChecks = {}
    local y = 0
    local function Section(title)
        Header(child, title, y)
        y = y - 22
    end
    local function Check(label, tooltip, get, set)
        local cb = CheckBox(child, label, tooltip, function(on) set(on); Refresh() end, "TOPLEFT", 8, y)
        cb.get = get
        table.insert(f.settingChecks, cb)
        y = y - 26
    end
    local function Text(template, text)
        local fs = Label(child, template, "TOPLEFT", 12, y)
        fs:SetWidth(300)
        fs:SetJustifyH("LEFT")
        fs:SetText(text or "")
        return fs
    end

    Section(L["Display"])
    Check(L["Show only spendable gold in my bags"],
        L["Your bag gold counter shows what you can spend. The piggy's share is hidden."],
        function() return db.hideReal end, function(on) db.hideReal = on end)
    Check(L["Show the minimap button"],
        L["A little piggy on the edge of your minimap. Click it to open this window, drag it to move it."],
        function() return db.minimap.shown end, function(on) db.minimap.shown = on end)
    Check(L["Always show the floating piggy"],
        L["Keep the little piggy on screen. When off, it only pops up to scold you."],
        function() return db.widget.shown end, function(on) db.widget.shown = on end)
    Check(L["Lock the floating piggy in place"],
        L["Stops the floating piggy from being dragged around."],
        function() return db.widget.locked end, function(on) db.widget.locked = on end)
    Button(child, L["Reset Piggy Position"], 170, function()
        db.widget.point = nil
        PlaceWidget(ui.widget)
        Print(L["The floating piggy is back in the middle of your screen."])
    end):SetPoint("TOPLEFT", 12, y - 2)
    y = y - 34

    Section(L["Saving"])
    Text("GameFontHighlight", L["Always keep at least this much spendable:"])
    y = y - 20
    f.keepInput = CoinInput(child)
    f.keepInput:SetPoint("TOPLEFT", 10, y)
    local function SubmitKeep()
        SetKeepSpendable(f.keepInput:GetCopper())
        f.keepInput:Clear()
    end
    f.keepInput:OnEnter(SubmitKeep)
    Button(child, L["Set"], 60, SubmitKeep):SetPoint("LEFT", f.keepInput, "RIGHT", 10, 0)
    y = y - 26
    f.keepText = Text("GameFontDisableSmall")
    y = y - 30

    Text("GameFontHighlight", L["Count these as income:"])
    y = y - 20
    Check(L["Looted gold"], L["Gold from mobs, chests and containers."],
        function() return db.income.loot end, function(on) db.income.loot = on end)
    Check(L["Quest rewards"], L["Gold handed out when you turn in a quest."],
        function() return db.income.quest end, function(on) db.income.quest = on end)
    Check(L["Selling to vendors"], L["Gold from selling items to a merchant."],
        function() return db.income.vendor end, function(on) db.income.vendor = on end)
    Check(L["Mailbox gold (auction sales)"],
        L["Auction sales and gold mailed to you. Turn off if you mail gold between your own characters."],
        function() return db.income.mail end, function(on) db.income.mail = on end)
    Check(L["Everything else"], L["Any other gold you gain, like world quests and other rewards."],
        function() return db.income.other end, function(on) db.income.other = on end)
    y = y - 6

    Section(L["Nagging"])
    Check(L["Scold me when I spend my savings"],
        L["The piggy pops up with a speech bubble. Chat messages always happen."],
        function() return db.scoldPopup end, function(on) db.scoldPopup = on end)
    Check(L["Play sounds"], L["Coin clinks, cheers and disappointed noises."],
        function() return db.sound end, function(on) db.sound = on end)
    Check(L["Warn me before I spend savings"],
        L["Flags anything that costs more than your spendable gold at vendors, trainers, flight masters and the auction house."],
        function() return db.vendorWarn end, function(on) db.vendorWarn = on end)
    Check(L["Show the login message"], L["A reminder in chat each time you log in."],
        function() return db.loginMessage end, function(on) db.loginMessage = on end)
    y = y - 8

    local help = Text("GameFontDisableSmall",
        L["Prefer typing? /piggy opens this window.\nAlso: /piggy rate 25,  /piggy goal 500 Mount,\n/piggy feed 10,  /piggy keep 5,  /piggy widget"])
    y = y - help:GetStringHeight() - 16
    child:SetHeight(-y)
end

-- Size tabs to fit their text. If they don't fit under the window (Classic's tab art has
-- wide see-through edges), overlap them like Blizzard's Classic frames do, and widen the
-- window if they still don't fit.
local function LayoutTabs(f)
    if not f.realTabs then return end
    local total = 0
    for _, tab in ipairs(f.Tabs) do
        if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end
        total = total + tab:GetWidth()
    end
    local gap = 3
    if total + gap * (#f.Tabs - 1) + 11 > f:GetWidth() then gap = -16 end
    for i = 2, #f.Tabs do
        f.Tabs[i]:ClearAllPoints()
        f.Tabs[i]:SetPoint("TOPLEFT", f.Tabs[i - 1], "TOPRIGHT", gap, 0)
    end
    local needed = total + gap * (#f.Tabs - 1) + 11 + 8
    if needed > f:GetWidth() then f:SetWidth(needed) end
end

local function SelectTab(f, id)
    f.selectedTab = id
    for i, page in ipairs(f.pages) do page:SetShown(i == id) end
    if f.realTabs and PanelTemplates_SetTab then
        PanelTemplates_SetTab(f, id)
        LayoutTabs(f)
    elseif f.Tabs then
        -- plain-button fallback: grey out the current tab
        for i, tab in ipairs(f.Tabs) do tab:SetEnabled(i ~= id) end
    end
end

local function CreateMainFrame()
    local f, template = CreateFromFirst("Frame", "PiggyBankFrame", UIParent,
        { "ButtonFrameTemplate", "BasicFrameTemplateWithInset", "BackdropTemplate" })
    if template == "BackdropTemplate" then
        -- Bare-bones fallback: classic dialog border, title and close button
        f:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
            tile = true, tileSize = 32, edgeSize = 32,
            insets = { left = 11, right = 12, top = 12, bottom = 11 },
        })
        f.TitleText = Label(f, "GameFontNormal", "TOP", 0, -16)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -4, -4)
    end
    return f
end

local function CreateWindow()
    local f = CreateMainFrame()
    f:SetSize(384, 520)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:Hide()
    tinsert(UISpecialFrames, "PiggyBankFrame") -- close with Escape

    if f.SetTitle then f:SetTitle(L["Piggy Bank"]) elseif f.TitleText then f.TitleText:SetText(L["Piggy Bank"]) end
    if f.SetPortraitToAsset then
        f:SetPortraitToAsset(PIG_ICON)
    else
        local portrait = f.portrait or (f.PortraitContainer and f.PortraitContainer.portrait)
        if portrait then SetPortraitToTexture(portrait, PIG_ICON) end
    end

    f.pages = {}
    local builders = { BuildPiggyPage, BuildGoalsPage, BuildStatsPage, BuildSettingsPage }
    for i, build in ipairs(builders) do
        local page = CreateFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", 14, -68)
        page:SetPoint("BOTTOMRIGHT", -14, 32)
        build(f, page)
        f.pages[i] = page
    end

    -- Bottom tabs, like the character sheet
    f.Tabs = {}
    for i, name in ipairs(TAB_NAMES) do
        local tab, template = CreateFromFirst("Button", "PiggyBankFrameTab" .. i, f,
            { "PanelTabButtonTemplate", "CharacterFrameTabButtonTemplate", "UIPanelButtonTemplate" })
        f.realTabs = template == "PanelTabButtonTemplate" or template == "CharacterFrameTabButtonTemplate"
        if not f.realTabs then tab:SetSize(80, 22) end
        tab:SetID(i)
        tab:SetText(name)
        if i == 1 then
            tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 11, 2)
        else
            tab:SetPoint("TOPLEFT", f.Tabs[i - 1], "TOPRIGHT", 3, 0)
        end
        tab:SetScript("OnClick", function(self)
            Sound("IG_CHARACTER_INFO_TAB")
            SelectTab(f, self:GetID())
        end)
        f.Tabs[i] = tab
    end
    if f.realTabs and PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(f, #TAB_NAMES) end
    SelectTab(f, 1)

    f:SetScript("OnShow", function()
        Sound("IG_CHARACTER_INFO_OPEN")
        C_Timer.After(0, function() LayoutTabs(f) end) -- after the tabs' own OnShow resize
        Refresh()
    end)
    f:SetScript("OnHide", function() Sound("IG_CHARACTER_INFO_CLOSE") end)
    ui.window = f
end

local function RefreshChart(f)
    local amounts, max = {}, 0
    for i = 1, 7 do
        amounts[i] = SavedOnDay(7 - i)
        max = math.max(max, amounts[i])
    end
    for i, col in ipairs(f.chart) do
        local daysAgo = 7 - i
        local t = time() - daysAgo * DAY
        col.bar:SetHeight(max > 0 and math.max(1, 44 * amounts[i] / max) or 1)
        col.bar:SetColorTexture(1, 0.53, 0.8, daysAgo == 0 and 1 or 0.6)
        col.day:SetText(date("%a", t))
        col.hover.dayName = daysAgo == 0 and L["Today"] or date("%A", t)
        col.hover.amount = amounts[i]
    end
end

local function RefreshWindow()
    local f = ui.window
    if not f:IsShown() then return end

    -- Piggy tab
    f.rankText:SetText(RANKS[db.rank][2])
    f.savingsCoins:SetAmount(db.savings)
    f.spendableCoins:SetAmount(Spendable())
    if db.broken then
        f.status:SetText("|cffff5555" .. L["Smashed!"] .. "|r " .. L["Click |cffffd100Start a New Piggy|r below. It's free!"])
    else
        f.status:SetText(L["Saving |cffffd100%d%%|r of everything you earn."]:format(db.rate))
    end
    f.rateText:SetText(db.rate .. "%")
    f.rateSlider:SetValue(db.rate)
    if db.broken then
        f.breakBtn:SetText(L["Start a New Piggy"])
    elseif whacks == 0 then
        f.breakBtn:SetText(L["Break the Piggy Bank"])
    elseif whacks == WHACKS_NEEDED - 1 then
        f.breakBtn:SetText("|cffff5555" .. L["CRACK!"] .. "|r " .. L["One more whack!"])
    else
        f.breakBtn:SetText(L["Crack! (%d more whacks)"]:format(WHACKS_NEEDED - whacks))
    end

    -- Goals tab
    for i, row in ipairs(f.rows) do
        local goal = db.goals[i]
        row:SetShown(goal ~= nil)
        if goal then
            local progress = math.min(1, db.savings / goal.target)
            row.name:SetText(goal.name)
            row.amount:SetText(Money(math.min(db.savings, goal.target)) .. " / " .. Money(goal.target))
            row.amount:SetShown(not goal.reached)
            row.cashOut:SetShown(goal.reached)
            row.bar:SetValue(progress)
            row.pct:SetText(goal.reached and L["Complete!"] or (math.floor(progress * 100) .. "%  ·  " .. GoalETA(goal)))
            if goal.reached then row.bar:SetStatusBarColor(0.1, 0.8, 0.1) else row.bar:SetStatusBarColor(1, 0.53, 0.8) end
        end
    end
    f.noGoals:SetShown(#db.goals == 0)
    f.goalCount:SetText(#db.goals .. " / " .. MAX_GOALS)
    f.addGoalBtn:SetEnabled(#db.goals < MAX_GOALS)

    -- Stats tab
    for i, stat in ipairs(STAT_ROWS) do f.statValues[i]:SetText(stat[2]()) end
    RefreshChart(f)

    -- Settings tab
    for _, cb in ipairs(f.settingChecks) do cb:SetChecked(cb.get()) end
    if db.keepSpendable > 0 then
        f.keepText:SetText(L["Currently %s. The piggy won't save while you have less than this spendable."]:format(Money(db.keepSpendable)))
    else
        f.keepText:SetText(L["Currently off. Handy for keeping repair money. Leave the boxes empty and click Set to turn it off."])
    end
end

function ui.ToggleWindow()
    ui.window:SetShown(not ui.window:IsShown())
end

Refresh = function()
    if not db then return end
    UpdateAccount()
    RefreshOverlays()
    RefreshWidget()
    RefreshMinimapButton()
    RefreshDataBroker()
    RefreshWindow()
end

-- Entry in Esc > Options > AddOns, so nobody has to remember a slash command.
local function RegisterOptionsPanel()
    local panel = CreateFrame("Frame")
    panel.name = L["Piggy Bank"]
    Label(panel, "GameFontNormalLarge", "TOPLEFT", 16, -16):SetText(L["Piggy Bank"])
    local desc = Label(panel, "GameFontHighlight", "TOPLEFT", 16, -44)
    desc:SetText(L["All Piggy Bank settings live in the piggy's own window."])
    Button(panel, L["Open Piggy Bank"], 160, function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        if InterfaceOptionsFrame and InterfaceOptionsFrame:IsShown() then HideUIPanel(InterfaceOptionsFrame) end
        ui.window:Show()
    end):SetPoint("TOPLEFT", 16, -72)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, L["Piggy Bank"])
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel) -- older clients
    end
end

-- Click handler for the addon compartment button by the minimap (set in the TOC).
function PiggyBank_OnCompartmentClick()
    if ui.window then ui.ToggleWindow() end
end

---------------------------------------------------------------------------
-- Vendor / trainer warnings: flag prices you can only pay by raiding the piggy
---------------------------------------------------------------------------

local WARN_ICON = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"
local merchantWarnings = {}
local repairWarning, trainerWarning, trainerTicker

local function WouldDip(price)
    return db and db.vendorWarn and price and price > 0 and db.savings > 0 and price > Spendable()
end

local function AddWarningLines(tooltip, price)
    tooltip:AddLine(" ")
    tooltip:AddLine("|cffff5555" .. L["Oink! You'll spend savings on this."] .. "|r")
    tooltip:AddLine(L["Costs %s, but you only have %s spendable."]:format(Money(price), Money(Spendable())), 1, 1, 1, true)
end

local function WarningIcon(parent, getPrice)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(18, 18)
    b:SetFrameLevel(parent:GetFrameLevel() + 10)
    b.tex = b:CreateTexture(nil, "OVERLAY")
    b.tex:SetAllPoints()
    b.tex:SetTexture(WARN_ICON)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(L["Piggy Bank"])
        AddWarningLines(GameTooltip, getPrice())
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", HideTooltip)
    b:Hide()
    return b
end

local function MerchantPrice(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(index)
        return info and info.price or 0
    end
    local _, _, price = GetMerchantItemInfo(index)
    return price or 0
end

local function UpdateMerchantWarnings()
    if not db or not MerchantFrame or not MerchantFrame:IsShown() then return end
    local perPage = MERCHANT_ITEMS_PER_PAGE or 10
    local buying = (MerchantFrame.selectedTab or 1) == 1
    for i = 1, perPage do
        local item = _G["MerchantItem" .. i]
        if item then
            local warn = merchantWarnings[i]
            if not warn then
                warn = WarningIcon(item, function() return warn.price end)
                local money = _G["MerchantItem" .. i .. "MoneyFrame"]
                if money then warn:SetPoint("LEFT", money, "RIGHT", 2, 0) else warn:SetPoint("TOPRIGHT", item, "TOPRIGHT", 0, 0) end
                merchantWarnings[i] = warn
            end
            local index = ((MerchantFrame.page or 1) - 1) * perPage + i
            warn.price = buying and item:IsShown() and MerchantPrice(index) or 0
            warn:SetShown(WouldDip(warn.price))
        end
    end

    local repair = _G.MerchantRepairAllButton
    if repair then
        if not repairWarning then
            repairWarning = WarningIcon(repair, function() return (GetRepairAllCost()) end)
            repairWarning:SetSize(14, 14)
            repairWarning:SetPoint("TOPRIGHT", repair, "TOPRIGHT", 4, 4)
            repair:HookScript("OnEnter", function()
                local cost, canRepair = GetRepairAllCost()
                if canRepair and WouldDip(cost) then
                    AddWarningLines(GameTooltip, cost)
                    GameTooltip:Show()
                end
            end)
        end
        local cost, canRepair = GetRepairAllCost()
        repairWarning:SetShown(repair:IsShown() and canRepair and WouldDip(cost))
    end
end

local function SetupMerchantWarnings()
    if MerchantFrame_UpdateMerchantInfo then hooksecurefunc("MerchantFrame_UpdateMerchantInfo", UpdateMerchantWarnings) end
    if MerchantFrame_UpdateBuybackInfo then hooksecurefunc("MerchantFrame_UpdateBuybackInfo", UpdateMerchantWarnings) end
    if MerchantFrame_UpdateRepairButtons then hooksecurefunc("MerchantFrame_UpdateRepairButtons", UpdateMerchantWarnings) end
    -- Extra line on the item tooltip itself
    if GameTooltip.SetMerchantItem then
        hooksecurefunc(GameTooltip, "SetMerchantItem", function(tooltip, index)
            local price = MerchantPrice(index)
            if WouldDip(price) then
                AddWarningLines(tooltip, price)
                tooltip:Show()
            end
        end)
    end
end

-- The trainer UI loads on demand and its layout has changed across versions,
-- so while a trainer is open we just watch the selected skill's cost.
local function TrainerTick()
    local frame = _G.ClassTrainerFrame
    local button = frame and (frame.TrainButton or _G.ClassTrainerTrainButton)
    if not button then return end
    if not trainerWarning then
        trainerWarning = WarningIcon(button, function() return trainerWarning.price end)
        trainerWarning:SetPoint("RIGHT", button, "LEFT", -4, 0)
        button:HookScript("OnEnter", function(self)
            if not WouldDip(trainerWarning.price) then return end
            if GameTooltip:GetOwner() ~= self then GameTooltip:SetOwner(self, "ANCHOR_RIGHT") end
            AddWarningLines(GameTooltip, trainerWarning.price)
            GameTooltip:Show()
        end)
    end
    local index = GetTrainerSelectionIndex and GetTrainerSelectionIndex()
    trainerWarning.price = (index and index > 0 and GetTrainerServiceCost(index)) or 0
    trainerWarning:SetShown(button:IsShown() and WouldDip(trainerWarning.price))
end

local function StartTrainerWatch()
    if trainerTicker then trainerTicker:Cancel() end
    trainerTicker = C_Timer.NewTicker(0.25, TrainerTick)
end

local function StopTrainerWatch()
    if trainerTicker then trainerTicker:Cancel(); trainerTicker = nil end
    if trainerWarning then trainerWarning:Hide() end
end

-- Flight paths: add the warning to the destination tooltip, which already shows the cost.
local hooked = {}

local function AddFlightWarning(slot)
    local cost = slot and TaxiNodeCost and TaxiNodeCost(slot)
    if WouldDip(cost) then
        AddWarningLines(GameTooltip, cost)
        GameTooltip:Show()
    end
end

local function HookFlightPaths()
    -- Old flat taxi map
    if not hooked.taxi and TaxiNodeOnButtonEnter then
        hooksecurefunc("TaxiNodeOnButtonEnter", function(button) AddFlightWarning(button:GetID()) end)
        hooked.taxi = true
    end
    -- Modern flight map (loads on demand)
    if not hooked.flightMap and FlightMap_FlightPointPinMixin then
        hooksecurefunc(FlightMap_FlightPointPinMixin, "OnMouseEnter", function(pin)
            AddFlightWarning(pin.taxiNodeData and pin.taxiNodeData.slotIndex)
        end)
        hooked.flightMap = true
    end
end

-- Auction house items: watch the buyout price of the selected listing.
local auctionWarning

local function HookAuctionHouse()
    if hooked.auction then return end
    local buyout = AuctionHouseFrame and AuctionHouseFrame.ItemBuyFrame and AuctionHouseFrame.ItemBuyFrame.BuyoutFrame
    if not (buyout and buyout.SetPrice) then return end
    hooked.auction = true

    local button = buyout.BuyoutButton or buyout
    auctionWarning = WarningIcon(button, function() return auctionWarning.price end)
    auctionWarning:SetPoint("RIGHT", button, "LEFT", -4, 0)
    auctionWarning.price = 0
    hooksecurefunc(buyout, "SetPrice", function(_, price)
        auctionWarning.price = price or 0
        auctionWarning:SetShown(WouldDip(auctionWarning.price))
    end)
    if button ~= buyout then
        button:HookScript("OnEnter", function(self)
            if not WouldDip(auctionWarning.price) then return end
            if GameTooltip:GetOwner() ~= self then GameTooltip:SetOwner(self, "ANCHOR_RIGHT") end
            AddWarningLines(GameTooltip, auctionWarning.price)
            GameTooltip:Show()
        end)
    end
end

-- Classic auction house (old AuctionFrame): warn on the Browse tab's Bid and Buyout buttons.
local function HookClassicAuctionHouse()
    if hooked.classicAuction then return end
    if not (AuctionFrameBrowse_Update and BrowseBuyoutButton and GetSelectedAuctionItem) then return end
    hooked.classicAuction = true

    local function SelectedBuyout()
        local index = GetSelectedAuctionItem("list")
        if not index or index == 0 then return 0 end
        return select(10, GetAuctionItemInfo("list", index)) or 0
    end
    local function BidAmount()
        if not (BrowseBidPrice and MoneyInputFrame_GetCopper) then return 0 end
        return MoneyInputFrame_GetCopper(BrowseBidPrice) or 0
    end

    local watched = { { BrowseBuyoutButton, SelectedBuyout } }
    if BrowseBidButton then table.insert(watched, { BrowseBidButton, BidAmount }) end
    for _, entry in ipairs(watched) do
        local button, getPrice = entry[1], entry[2]
        local warn = WarningIcon(button, getPrice)
        warn:SetPoint("BOTTOM", button, "TOP", 0, 2)
        entry[3] = warn
        button:HookScript("OnEnter", function(self)
            local price = getPrice()
            if not WouldDip(price) then return end
            if GameTooltip:GetOwner() ~= self then GameTooltip:SetOwner(self, "ANCHOR_RIGHT") end
            AddWarningLines(GameTooltip, price)
            GameTooltip:Show()
        end)
        -- Blizzard shows its own confirmation after this click; the piggy chimes in too
        button:HookScript("OnClick", function()
            local price = getPrice()
            if WouldDip(price) then HeadsUp(price) end
        end)
    end
    hooksecurefunc("AuctionFrameBrowse_Update", function()
        for _, entry in ipairs(watched) do
            entry[3]:SetShown(entry[1]:IsShown() and WouldDip(entry[2]()))
        end
    end)
end

-- Auction house commodities: the game confirms the total price before you finalize.
local function OnCommodityPrice(totalPrice)
    if WouldDip(totalPrice) then HeadsUp(totalPrice) end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- Windows reported through the newer interaction events. Bank and trade gold isn't
-- income; mail is one of the income sources you can switch off.
local INTERACTIONS = {}
for key, name in pairs({ Banker = "Banker", GuildBanker = "GuildBanker", AccountBanker = "AccountBanker",
    TradePartner = "TradePartner", MailInfo = "mail", Trainer = "Trainer" }) do
    local id = Enum.PlayerInteractionType and Enum.PlayerInteractionType[key]
    if id then INTERACTIONS[id] = name end
end

-- Per-window events. Classic relies on these; Retail fires most of them too.
local WINDOW_EVENTS = {
    BANKFRAME_OPENED = { "Banker", true },          BANKFRAME_CLOSED = { "Banker", false },
    GUILDBANKFRAME_OPENED = { "GuildBanker", true }, GUILDBANKFRAME_CLOSED = { "GuildBanker", false },
    TRADE_SHOW = { "TradePartner", true },          TRADE_CLOSED = { "TradePartner", false },
    MAIL_SHOW = { "mail", true },                   MAIL_CLOSED = { "mail", false },
    MERCHANT_SHOW = { "vendor", true },             MERCHANT_CLOSED = { "vendor", false },
    LOOT_OPENED = { "loot", true },                 LOOT_CLOSED = { "loot", false },
    QUEST_COMPLETE = { "quest", true },             QUEST_FINISHED = { "quest", false },
    TRAINER_SHOW = { "Trainer", true },             TRAINER_CLOSED = { "Trainer", false },
}

local function WindowOpened(key)
    if key == "Trainer" then StartTrainerWatch() return end
    if key then windows[key] = true end
end

local function WindowClosed(key)
    if key == "Trainer" then StopTrainerWatch() return end
    -- money updates can land just after the window closes
    if key and windows[key] then windows[key] = GetTime() + (key == "quest" and 2 or 1) end
end

local events = CreateFrame("Frame")
local function Register(event)
    pcall(events.RegisterEvent, events, event) -- not every event exists in every game version
end
for _, event in ipairs({ "PLAYER_LOGIN", "PLAYER_MONEY", "ADDON_LOADED", "COMMODITY_PRICE_UPDATED", "QUEST_TURNED_IN",
    "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
    Register(event)
end
for event in pairs(WINDOW_EVENTS) do Register(event) end

-- Baganator builds its bag windows at login, after this file loads. Its widgets copy the
-- mixin's methods when they're created, so the hook has to be in place before then.
HookBaganator()

events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "ADDON_LOADED" and arg1 == "Baganator" then HookBaganator() end
    if event == "PLAYER_LOGIN" then
        PiggyBankDB = PiggyBankDB or {}
        db = PiggyBankDB
        ApplyDefaults(db, DEFAULTS)
        if db.countMail ~= nil then -- setting from before income filters existed
            db.income.mail = db.countMail
            db.countMail = nil
        end
        db.stats.piggySince = db.stats.piggySince or time()
        db.rank = db.rank or RankFor(db.lifetime) -- existing piggies start at the rank they've earned, no toast
        PruneHistory()

        PiggyBankAccountDB = PiggyBankAccountDB or {}
        account = PiggyBankAccountDB
        account.chars = account.chars or {}
        charKey = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?")

        lastMoney = GetMoney()
        if db.savings > lastMoney then
            db.savings = lastMoney
            Print(L["Some savings were spent while the piggy wasn't looking. It now holds %s."]:format(Money(lastMoney)))
        end
        if db.loginMessage then
            Print(L["OINK!! Use /Piggy to open your piggy bank, OINK!! You can also click the gold in your bag OINK OINK!"])
        end
        SetupBagOverlays()
        CreateWidget()
        SetupDataBroker() -- before the minimap button, which can use its data object
        CreateMinimapButton()
        CreateWindow()
        RegisterOptionsPanel()
        SetupMerchantWarnings()
        HookFlightPaths()
        HookAuctionHouse()
        HookClassicAuctionHouse()
        Refresh()
    elseif not db then
        return
    elseif event == "ADDON_LOADED" then
        -- Blizzard's flight map and auction house UIs load on demand
        HookFlightPaths()
        HookAuctionHouse()
        HookClassicAuctionHouse()
    elseif event == "COMMODITY_PRICE_UPDATED" then
        OnCommodityPrice(arg2)
    elseif event == "PLAYER_MONEY" then
        OnMoneyChanged()
        UpdateMerchantWarnings()
    elseif event == "QUEST_TURNED_IN" then
        -- Quests that finish without a reward window (bonus objectives, world quests)
        windows.quest = GetTime() + 2
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        WindowOpened(INTERACTIONS[arg1])
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        WindowClosed(INTERACTIONS[arg1])
    elseif WINDOW_EVENTS[event] then
        local key, opened = WINDOW_EVENTS[event][1], WINDOW_EVENTS[event][2]
        if opened then WindowOpened(key) else WindowClosed(key) end
    end
end)

---------------------------------------------------------------------------
-- Slash commands (optional - everything is also in the window)
---------------------------------------------------------------------------

SLASH_PIGGYBANK1 = "/piggy"
SLASH_PIGGYBANK2 = "/piggybank"
SlashCmdList.PIGGYBANK = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then
        ui.ToggleWindow()
    elseif cmd == "rate" and tonumber(rest) then
        SetRate(tonumber(rest))
        Print(L["Now saving %d%% of income."]:format(db.rate))
    elseif cmd == "goal" then
        local gold, name = rest:match("^(%S+)%s*(.*)$")
        local copper = GoldToCopper(gold)
        if copper and copper > 0 then AddGoal(name, copper) else Print(L["Usage: /piggy goal <gold> <name>"]) end
    elseif cmd == "feed" and (GoldToCopper(rest) or 0) > 0 then
        FeedPiggy(GoldToCopper(rest))
    elseif cmd == "keep" and GoldToCopper(rest) then
        SetKeepSpendable(GoldToCopper(rest))
    elseif cmd == "widget" then
        db.widget.shown = not db.widget.shown
        Print(db.widget.shown and L["Floating piggy always shown."] or L["Floating piggy hidden (it'll still pop up to scold you)."])
        Refresh()
    else
        Print(L["/piggy - open the piggy (every setting is in there)"])
        Print(L["/piggy rate <0-%d> - %% of income to save"]:format(MAX_RATE))
        Print(L["/piggy goal <gold> <name> - add a savings goal (e.g. 12.5 = 12g 50s)"])
        Print(L["/piggy feed <gold> - put gold in by hand"])
        Print(L["/piggy keep <gold> - always keep this much spendable (0 = off)"])
        Print(L["/piggy widget - show/hide the floating piggy"])
    end
end
