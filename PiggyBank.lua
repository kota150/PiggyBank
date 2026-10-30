-- Piggy Bank: a virtual savings jar for your gold.
-- WoW addons can't move or lock gold, so the piggy is a ledger: it remembers how much
-- of your gold is "savings", hides that part from the bag money display, and nags you
-- if you spend into it. Smashing the piggy releases the savings back to "spendable".

local MAX_RATE = 90
local MAX_GOALS = 5
local WHACKS_NEEDED = 3
local PIG_ICON = "Interface\\Icons\\Ability_Hunter_Pet_Boar"
local COPPER_PER_GOLD = 10000
local COIN_ICONS = {
    "Interface\\MoneyFrame\\UI-GoldIcon",
    "Interface\\MoneyFrame\\UI-SilverIcon",
    "Interface\\MoneyFrame\\UI-CopperIcon",
}

local CoinString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString

local DEFAULTS = {
    rate = 10,          -- % of income that goes into the piggy
    savings = 0,        -- copper currently in the piggy
    lifetime = 0,       -- copper ever saved
    broken = false,     -- smashed piggies don't save until you buy a new one
    hideReal = true,    -- replace the bag money display with spendable gold
    countMail = true,   -- count mailbox gold (auction sales etc.) as income
    scoldPopup = true,  -- pop the piggy up when you spend your savings
    vendorWarn = true,  -- flag vendor/trainer prices that would eat into savings
    sound = true,
    goals = {},         -- { name = "Mount", target = copper, reached = bool, everReached = bool }
    widget = { shown = false, locked = false, point = nil }, -- off by default; pops up to scold you anyway
    stats = {
        piggySince = nil,   -- time() the current piggy was bought
        incomeSeen = 0,     -- income the piggy took a cut of
        biggestDeposit = 0,
        smashes = 0,
        smashedOut = 0,
        raids = 0,          -- times you spent into your savings
        raided = 0,
        goalsCompleted = 0,
    },
}

-- One of these pops up (at random) when you spend into your savings. Cheese is mandatory.
local SCOLDS = {
    "Gold doesn't grow on Peacebloom, you know!",
    "You just rolled Need on your own savings. NINJA LOOTER!",
    "Your savings took more damage than a tank with no healer.",
    "Hogger is disappointed in you. And Hogger eats people.",
    "You are not prepared... for retirement!",
    "That gold was soulbound to the piggy! BoP = Bacon on Purpose!",
    "Pork chop? More like WALLET CHOP.",
    "Stop! HAM time. Put. It. Back.",
    "Your spending just pulled aggro from the whole bank.",
    "Bacon me crazy, you spent the savings!",
    "Swine and dine all you want, but not with MY gold.",
    "Even a murloc saves better. Mrglglgl... *disappointed gurgle*",
    "Zug zug? More like ZUG ZUG WHERE'D THE GOLD GO.",
    "Achievement unlocked: Broke-en Hero.",
    "Your piggy has been Sapped. Emotionally.",
    "That's not a cooldown, that's a MELTDOWN.",
    "Wipe on the budget raid! Everybody run back.",
    "Lok'tar ogar? More like Lok'tar BROKE-gar.",
    "Do you even know what 'savings' means, or are you just here for the loot?",
    "You've been hit by Mortal Strike: savings healing reduced by 100%.",
    "Oink oink means NO NO.",
    "Your financial advisor is a pig and even HE is judging you.",
    "This is why we can't have nice mounts.",
    "Hamstring! You've crippled your savings!",
    "The Lich King hoards better than you. And he's FROZEN.",
    "Ham-ateur move, champion. Ham-ateur move.",
}

local db
local lastMoney
local busy = {}         -- open UIs whose money changes aren't income (bank, trade...)
local overlays = {}     -- bag money frame -> our replacement display
local ui = {}
local whacks, whackToken = 0, 0
local scoldToken, lastScold = 0, nil

local Refresh -- forward declaration

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function Money(copper)
    return CoinString(math.max(0, math.floor(copper or 0)))
end

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cffff88ccPiggy Bank:|r " .. msg)
end

local function Sound(name)
    if db and not db.sound then return end
    local id = SOUNDKIT and SOUNDKIT[name]
    if id then PlaySound(id) end
end

local function GoldToCopper(text)
    local gold = tonumber(text)
    if not gold or gold <= 0 then return nil end
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

local function IsBusy()
    local now = GetTime()
    for _, until_ in pairs(busy) do
        if until_ == true or until_ > now then return true end
    end
    return false
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
            Celebrate("Goal reached: |cffffd100" .. goal.name .. "|r (" .. Money(goal.target) .. ")!")
        elseif goal.reached and db.savings < goal.target then
            goal.reached = false
        end
    end
end

local function AddToPiggy(copper)
    db.savings = db.savings + copper
    db.lifetime = db.lifetime + copper
    db.stats.biggestDeposit = math.max(db.stats.biggestDeposit, copper)
    CheckGoals()
end

-- Pop the piggy up with a random pun; it goes away again unless it's set to always show.
local function Scold(remaining)
    local i
    repeat i = math.random(#SCOLDS) until i ~= lastScold or #SCOLDS == 1
    lastScold = i
    local msg = SCOLDS[i]
    Print("|cffff5555" .. msg .. "|r The piggy only holds " .. Money(remaining) .. " now.")
    Sound("IG_QUEST_FAILED")

    local f = ui.widget
    if not f or not db.scoldPopup then return end
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
end

local function OnMoneyChanged()
    local now = GetMoney()
    if not lastMoney then
        lastMoney = now
        return
    end
    local delta = now - lastMoney
    lastMoney = now

    if delta > 0 and not db.broken and db.rate > 0 and not IsBusy() then
        local cut = math.floor(delta * db.rate / 100)
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
    Print("|cffffd100*CRASH!*|r " .. Money(released) .. " spills across the floor. It's all spendable again.")
    Print("Lifetime saved: " .. Money(db.lifetime) .. ". Buy a new piggy to start saving again.")
    Refresh()
end

local function NewPiggy()
    db.broken = false
    db.stats.piggySince = time()
    Sound("IG_CHARACTER_INFO_OPEN")
    Print("A shiny new piggy! Saving " .. db.rate .. "% of everything you earn.")
    Refresh()
end

local function FeedPiggy(copper)
    if db.broken then Print("The piggy is broken. Buy a new one first.") return false end
    if copper > Spendable() then Print("You don't have that much spendable gold.") return false end
    AddToPiggy(copper)
    Sound("LOOT_WINDOW_COIN_SOUND")
    Print("Fed the piggy " .. Money(copper) .. ". Oink.")
    Refresh()
    return true
end

local function SetRate(rate)
    db.rate = math.max(0, math.min(MAX_RATE, math.floor(rate + 0.5)))
    Refresh()
end

local function AddGoal(name, copper)
    if #db.goals >= MAX_GOALS then Print("You can have up to " .. MAX_GOALS .. " goals.") return false end
    name = (name and name:match("^%s*(.-)%s*$")) or ""
    if name == "" then name = "Goal " .. (#db.goals + 1) end
    table.insert(db.goals, { name = name, target = copper, reached = db.savings >= copper, everReached = db.savings >= copper })
    Print("New goal: |cffffd100" .. name .. "|r - " .. Money(copper))
    Refresh()
    return true
end

local function RemoveGoal(index)
    local goal = table.remove(db.goals, index)
    if goal then Print("Removed goal: " .. goal.name) end
    Refresh()
end

StaticPopupDialogs["PIGGYBANK_BREAK"] = {
    text = "Smash the piggy bank?\n\n%s will become spendable again, and the piggy stops saving until you buy a new one.",
    button1 = "SMASH!",
    button2 = CANCEL,
    OnAccept = function() BreakPiggy() end,
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

local function ShowTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOPLEFT")
    GameTooltip:AddLine("Piggy Bank" .. (db.broken and " |cffff5555(broken)|r" or ""))
    GameTooltip:AddDoubleLine("Spendable", Money(Spendable()), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("In the piggy", Money(db.savings), 1, 0.53, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Saving", db.broken and "nothing" or (db.rate .. "% of income"), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
    for _, goal in ipairs(db.goals) do
        local pct = math.min(100, math.floor(db.savings / goal.target * 100))
        local r, g = goal.reached and 0.2 or 1, goal.reached and 1 or 0.82
        GameTooltip:AddDoubleLine(goal.name, pct .. "%", r, g, 0, r, g, 0)
    end
    GameTooltip:AddLine("Click to open the piggy.", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function HideTooltip() GameTooltip:Hide() end

---------------------------------------------------------------------------
-- Bag money display: hide the real total, show spendable instead
---------------------------------------------------------------------------

local function CreateOverlay(moneyFrame)
    if not moneyFrame or overlays[moneyFrame] then return end
    local o = CreateFrame("Button", nil, moneyFrame:GetParent())
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
    moneyFrame:HookScript("OnShow", function(self) self:SetAlpha(db.hideReal and 0 or 1) end)
    overlays[moneyFrame] = o
end

local function SetupBagOverlays()
    CreateOverlay(ContainerFrameCombinedBags and ContainerFrameCombinedBags.MoneyFrame)
    CreateOverlay(_G.ContainerFrame1MoneyFrame)
end

local function RefreshOverlays()
    local text = Money(Spendable())
    for moneyFrame, o in pairs(overlays) do
        moneyFrame:SetAlpha(db.hideReal and 0 or 1)
        o:SetShown(db.hideReal)
        o.text:SetText(text)
        o.icon:SetDesaturated(db.broken)
    end
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
    f.savings:SetText(db.broken and "|cffff5555Broken piggy|r" or Money(db.savings))
    f.spendable:SetText("Spendable: " .. Money(Spendable()))
    f:SetWidth(math.max(140, 50 + math.max(f.savings:GetStringWidth(), f.spendable:GetStringWidth())))
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
    return fs
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
    s:SetObeyStepOnDrag(true)
    s:EnableMouseWheel(true)
    s:SetScript("OnValueChanged", function(_, value) onChange(math.floor(value + 0.5)) end)
    s:SetScript("OnMouseWheel", function(self, delta) self:SetValue(self:GetValue() + delta) end)
    return s
end

---------------------------------------------------------------------------
-- Main window (tabs: Piggy / Goals / Stats / Settings)
---------------------------------------------------------------------------

local TAB_NAMES = { "Piggy", "Goals", "Stats", "Settings" }

local function BuildPiggyPage(f, page)
    Header(page, "In the Piggy", 0)
    f.savingsCoins = CoinDisplay(page, "GameFontHighlightLarge", 18)
    f.savingsCoins:SetPoint("TOPLEFT", 12, -24)
    f.status = Label(page, "GameFontHighlightSmall", "TOPLEFT", 12, -50)

    Label(page, "GameFontNormal", "TOPLEFT", 12, -74):SetText("Spendable:")
    f.spendableCoins = CoinDisplay(page, "GameFontHighlight", 13)
    f.spendableCoins:SetPoint("TOPLEFT", 100, -74)

    Header(page, "Savings Rate", -106)
    f.rateText = Label(page, "GameFontHighlightLarge", "TOPRIGHT", -8, -103)
    local minus = Button(page, "-", 24, function() SetRate(db.rate - (IsShiftKeyDown() and 5 or 1)) end)
    minus:SetPoint("TOPLEFT", 10, -132)
    f.rateSlider = Slider(page, 250, 0, MAX_RATE, function(v) if db and v ~= db.rate then SetRate(v) end end)
    f.rateSlider:SetPoint("LEFT", minus, "RIGHT", 10, 0)
    local plus = Button(page, "+", 24, function() SetRate(db.rate + (IsShiftKeyDown() and 5 or 1)) end)
    plus:SetPoint("LEFT", f.rateSlider, "RIGHT", 10, 0)
    Label(page, "GameFontDisableSmall", "TOPLEFT", f.rateSlider, "BOTTOMLEFT", 0, -2):SetText("0%")
    Label(page, "GameFontDisableSmall", "TOPRIGHT", f.rateSlider, "BOTTOMRIGHT", 0, -2):SetText(MAX_RATE .. "%")
    Label(page, "GameFontHighlightSmall", "TOP", f.rateSlider, "BOTTOM", 0, -2):SetText("of everything you earn")

    Header(page, "Feed the Piggy", -196)
    f.feedInput = CoinInput(page)
    f.feedInput:SetPoint("TOPLEFT", 10, -220)
    local function SubmitFeed()
        local copper = f.feedInput:GetCopper()
        if copper <= 0 then return end
        if FeedPiggy(copper) then f.feedInput:Clear() end
    end
    f.feedInput:OnEnter(SubmitFeed)
    Button(page, "Feed", 80, SubmitFeed):SetPoint("LEFT", f.feedInput, "RIGHT", 10, 0)
    Label(page, "GameFontDisableSmall", "TOPLEFT", 12, -248):SetText("Drop in spendable gold by hand. No take-backs!")

    Header(page, "Break the Piggy", -280)
    local breakHelp = Label(page, "GameFontHighlightSmall", "TOPLEFT", 12, -302)
    breakHelp:SetWidth(330)
    breakHelp:SetJustifyH("LEFT")
    breakHelp:SetText("Need your gold back? Whack the piggy " .. WHACKS_NEEDED ..
        " times to smash it open. It won't save anything until you buy a new one.")
    f.breakBtn = Button(page, "", 220, Whack)
    f.breakBtn:SetHeight(26)
    f.breakBtn:SetPoint("TOP", page, "TOP", 0, -334)
end

local function BuildGoalsPage(f, page)
    Header(page, "Savings Goals", 0)
    f.goalCount = Label(page, "GameFontHighlightSmall", "TOPRIGHT", -8, -2)
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
        f.rows[i] = row
    end
    f.noGoals = Label(page, "GameFontDisable", "TOPLEFT", 12, -30)
    f.noGoals:SetText("No goals yet. What are you saving up for?")

    Header(page, "New Goal", -222)
    Label(page, "GameFontHighlight", "TOPLEFT", 12, -250):SetText("Name")
    f.goalName = EditBox(page, 220)
    f.goalName:SetPoint("TOPLEFT", 80, -246)
    f.goalName:SetMaxLetters(40)
    Label(page, "GameFontHighlight", "TOPLEFT", 12, -280):SetText("Amount")
    f.goalInput = CoinInput(page)
    f.goalInput:SetPoint("TOPLEFT", 74, -276)
    local function SubmitGoal()
        local copper = f.goalInput:GetCopper()
        if copper <= 0 then Print("Enter how much the goal costs.") return end
        if AddGoal(f.goalName:GetText(), copper) then
            f.goalName:SetText("")
            f.goalName:ClearFocus()
            f.goalInput:Clear()
        end
    end
    f.goalInput:OnEnter(SubmitGoal)
    f.goalName:SetScript("OnEnterPressed", function() f.goalInput.boxes[1]:SetFocus() end)
    f.goalName:SetScript("OnTabPressed", function() f.goalInput.boxes[1]:SetFocus() end)
    f.addGoalBtn = Button(page, "Add Goal", 120, SubmitGoal)
    f.addGoalBtn:SetPoint("TOPLEFT", 80, -310)
end

local STAT_ROWS = {
    { "Current savings rate",       function() return db.broken and "|cffff5555broken|r" or (db.rate .. "%") end },
    { "Current piggy's age",        function()
        local since = db.stats.piggySince
        if db.broken or not since then return "-" end
        local age = time() - since
        return age < 60 and "brand new" or SecondsToTime(age)
    end },
    { "Lifetime saved",             function() return Money(db.lifetime) end },
    { "Income tracked",             function() return Money(db.stats.incomeSeen) end },
    { "Biggest single deposit",     function() return Money(db.stats.biggestDeposit) end },
    { "Goals completed",            function() return db.stats.goalsCompleted end },
    { "Piggies smashed",            function() return db.stats.smashes end },
    { "Gold released by smashing",  function() return Money(db.stats.smashedOut) end },
    { "Times caught raiding piggy", function() return db.stats.raids end },
    { "Gold raided from piggy",     function() return Money(db.stats.raided) end },
}

local function BuildStatsPage(f, page)
    Header(page, "Statistics", 0)
    f.statValues = {}
    for i, stat in ipairs(STAT_ROWS) do
        local y = -22 - (i - 1) * 24
        local stripe = page:CreateTexture(nil, "BACKGROUND")
        stripe:SetPoint("TOPLEFT", 4, y + 2)
        stripe:SetPoint("RIGHT", page, "RIGHT", -4, 0)
        stripe:SetHeight(22)
        stripe:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0.08)
        Label(page, "GameFontNormal", "TOPLEFT", 12, y - 2):SetText(stat[1])
        f.statValues[i] = Label(page, "GameFontHighlight", "TOPRIGHT", -12, y - 2)
    end
end

local function BuildSettingsPage(f, page)
    Header(page, "Display", 0)
    f.hideReal = CheckBox(page, "Show only spendable gold in my bags",
        "Your bag gold counter shows what you can spend. The piggy's share is hidden.",
        function(on) db.hideReal = on; Refresh() end, "TOPLEFT", 8, -20)
    f.showWidget = CheckBox(page, "Always show the floating piggy",
        "Keep the little piggy on screen. When off, it only pops up to scold you.",
        function(on) db.widget.shown = on; Refresh() end, "TOPLEFT", f.hideReal, "BOTTOMLEFT", 0, -2)
    f.lockWidget = CheckBox(page, "Lock the floating piggy in place",
        "Stops the floating piggy from being dragged around.",
        function(on) db.widget.locked = on end, "TOPLEFT", f.showWidget, "BOTTOMLEFT", 0, -2)
    Button(page, "Reset Piggy Position", 170, function()
        db.widget.point = nil
        PlaceWidget(ui.widget)
        Print("The floating piggy is back in the middle of your screen.")
    end):SetPoint("TOPLEFT", f.lockWidget, "BOTTOMLEFT", 4, -4)

    Header(page, "Saving", -142)
    f.countMail = CheckBox(page, "Count mailbox gold as income",
        "Auction sales and gold mailed to you count as earnings. Turn off if you mail gold between your own characters.",
        function(on) db.countMail = on end, "TOPLEFT", 8, -162)

    Header(page, "Nagging", -204)
    f.scoldPopup = CheckBox(page, "Scold me when I spend my savings",
        "The piggy pops up with a speech bubble. Chat messages always happen.",
        function(on) db.scoldPopup = on end, "TOPLEFT", 8, -224)
    f.soundToggle = CheckBox(page, "Play sounds",
        "Coin clinks, cheers and disappointed noises.",
        function(on) db.sound = on end, "TOPLEFT", f.scoldPopup, "BOTTOMLEFT", 0, -2)
    f.vendorWarn = CheckBox(page, "Warn me at vendors and trainers",
        "Shows a warning icon on anything that costs more than your spendable gold, with a tooltip saying you'd be dipping into savings.",
        function(on) db.vendorWarn = on end, "TOPLEFT", f.soundToggle, "BOTTOMLEFT", 0, -2)

    local help = Label(page, "GameFontDisableSmall", "TOPLEFT", 12, -320)
    help:SetWidth(330)
    help:SetJustifyH("LEFT")
    help:SetText("Prefer typing? /piggy opens this window. Also: /piggy rate 25, /piggy goal 500 Mount, /piggy feed 10, /piggy widget")
end

local function SelectTab(f, id)
    f.selectedTab = id
    for i, page in ipairs(f.pages) do page:SetShown(i == id) end
    if PanelTemplates_SetTab then PanelTemplates_SetTab(f, id) end
end

local function CreateWindow()
    local f = CreateFrame("Frame", "PiggyBankFrame", UIParent, "ButtonFrameTemplate")
    f:SetSize(384, 470)
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

    if f.SetTitle then f:SetTitle("Piggy Bank") elseif f.TitleText then f.TitleText:SetText("Piggy Bank") end
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
        local tab = CreateFrame("Button", "PiggyBankFrameTab" .. i, f, "PanelTabButtonTemplate")
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
        if PanelTemplates_TabResize then PanelTemplates_TabResize(tab, 0) end
        f.Tabs[i] = tab
    end
    if PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(f, #TAB_NAMES) end
    SelectTab(f, 1)

    f:SetScript("OnShow", function()
        Sound("IG_CHARACTER_INFO_OPEN")
        Refresh()
    end)
    f:SetScript("OnHide", function() Sound("IG_CHARACTER_INFO_CLOSE") end)
    ui.window = f
end

local function RefreshWindow()
    local f = ui.window
    if not f:IsShown() then return end

    -- Piggy tab
    f.savingsCoins:SetAmount(db.savings)
    f.spendableCoins:SetAmount(Spendable())
    if db.broken then
        f.status:SetText("|cffff5555This piggy is smashed.|r Buy a new one to start saving again.")
    else
        f.status:SetText("Saving |cffffd100" .. db.rate .. "%|r of everything you earn.")
    end
    f.rateText:SetText(db.rate .. "%")
    f.rateSlider:SetValue(db.rate)
    if db.broken then
        f.breakBtn:SetText("Buy a New Piggy")
    elseif whacks == 0 then
        f.breakBtn:SetText("Break the Piggy Bank")
    elseif whacks == WHACKS_NEEDED - 1 then
        f.breakBtn:SetText("|cffff5555CRACK!|r One more whack!")
    else
        f.breakBtn:SetText("Crack! (" .. (WHACKS_NEEDED - whacks) .. " more whacks)")
    end

    -- Goals tab
    for i, row in ipairs(f.rows) do
        local goal = db.goals[i]
        row:SetShown(goal ~= nil)
        if goal then
            local progress = math.min(1, db.savings / goal.target)
            row.name:SetText(goal.name)
            row.amount:SetText(Money(math.min(db.savings, goal.target)) .. " / " .. Money(goal.target))
            row.bar:SetValue(progress)
            row.pct:SetText(goal.reached and "Complete!" or (math.floor(progress * 100) .. "%"))
            if goal.reached then row.bar:SetStatusBarColor(0.1, 0.8, 0.1) else row.bar:SetStatusBarColor(1, 0.53, 0.8) end
        end
    end
    f.noGoals:SetShown(#db.goals == 0)
    f.goalCount:SetText(#db.goals .. " / " .. MAX_GOALS)
    f.addGoalBtn:SetEnabled(#db.goals < MAX_GOALS)

    -- Stats tab
    for i, stat in ipairs(STAT_ROWS) do f.statValues[i]:SetText(stat[2]()) end

    -- Settings tab
    f.hideReal:SetChecked(db.hideReal)
    f.showWidget:SetChecked(db.widget.shown)
    f.lockWidget:SetChecked(db.widget.locked)
    f.countMail:SetChecked(db.countMail)
    f.scoldPopup:SetChecked(db.scoldPopup)
    f.soundToggle:SetChecked(db.sound)
    f.vendorWarn:SetChecked(db.vendorWarn)
end

function ui.ToggleWindow()
    ui.window:SetShown(not ui.window:IsShown())
end

Refresh = function()
    if not db then return end
    RefreshOverlays()
    RefreshWidget()
    RefreshWindow()
end

-- Entry in Esc > Options > AddOns, so nobody has to remember a slash command.
local function RegisterOptionsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory) then return end
    local panel = CreateFrame("Frame")
    Label(panel, "GameFontNormalLarge", "TOPLEFT", 16, -16):SetText("Piggy Bank")
    local desc = Label(panel, "GameFontHighlight", "TOPLEFT", 16, -44)
    desc:SetText("All Piggy Bank settings live in the piggy's own window.")
    Button(panel, "Open Piggy Bank", 160, function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        ui.window:Show()
    end):SetPoint("TOPLEFT", 16, -72)
    local category = Settings.RegisterCanvasLayoutCategory(panel, "Piggy Bank")
    Settings.RegisterAddOnCategory(category)
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
    tooltip:AddLine("|cffff5555Oink! You'll spend savings on this.|r")
    tooltip:AddLine("Costs " .. Money(price) .. ", but you only have " .. Money(Spendable()) .. " spendable.", 1, 1, 1, true)
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
        GameTooltip:AddLine("Piggy Bank")
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

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- Money moving through these windows is shuffling, not earning.
local NOT_INCOME = {}
for _, key in ipairs({ "Banker", "GuildBanker", "AccountBanker", "TradePartner", "MailInfo" }) do
    local id = Enum.PlayerInteractionType and Enum.PlayerInteractionType[key]
    if id then NOT_INCOME[id] = key end
end
local TRAINER_INTERACTION = Enum.PlayerInteractionType and Enum.PlayerInteractionType.Trainer

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_MONEY")
events:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
events:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LOGIN" then
        PiggyBankDB = PiggyBankDB or {}
        db = PiggyBankDB
        ApplyDefaults(db, DEFAULTS)
        db.stats.piggySince = db.stats.piggySince or time()
        lastMoney = GetMoney()
        if db.savings > lastMoney then
            db.savings = lastMoney
            Print("Some savings were spent while the piggy wasn't looking. It now holds " .. Money(lastMoney) .. ".")
        end
        SetupBagOverlays()
        CreateWidget()
        CreateWindow()
        RegisterOptionsPanel()
        SetupMerchantWarnings()
        Refresh()
    elseif not db then
        return
    elseif event == "PLAYER_MONEY" then
        OnMoneyChanged()
        UpdateMerchantWarnings()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
        local key = NOT_INCOME[arg1]
        if key and not (key == "MailInfo" and db.countMail) then busy[key] = true end
        if arg1 == TRAINER_INTERACTION then StartTrainerWatch() end
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        local key = NOT_INCOME[arg1]
        -- money updates can land just after the window closes
        if key and busy[key] then busy[key] = GetTime() + 1 end
        if arg1 == TRAINER_INTERACTION then StopTrainerWatch() end
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
        Print("Now saving " .. db.rate .. "% of income.")
    elseif cmd == "goal" then
        local gold, name = rest:match("^(%S+)%s*(.*)$")
        local copper = GoldToCopper(gold)
        if copper then AddGoal(name, copper) else Print("Usage: /piggy goal <gold> <name>") end
    elseif cmd == "feed" and GoldToCopper(rest) then
        FeedPiggy(GoldToCopper(rest))
    elseif cmd == "widget" then
        db.widget.shown = not db.widget.shown
        Print("Floating piggy " .. (db.widget.shown and "always shown." or "hidden (it'll still pop up to scold you)."))
        Refresh()
    else
        Print("/piggy - open the piggy (every setting is in there)")
        Print("/piggy rate <0-" .. MAX_RATE .. "> - % of income to save")
        Print("/piggy goal <gold> <name> - add a savings goal (e.g. 12.5 = 12g 50s)")
        Print("/piggy feed <gold> - put gold in by hand")
        Print("/piggy widget - show/hide the floating piggy")
    end
end
