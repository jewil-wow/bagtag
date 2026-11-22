-- Bagmark: Alt-click a bag item to cycle its mark: Vendor -> Auction -> Mail -> Bank -> none.
-- Marks are per item ID and last only while the item is in your bags.
-- Vendor: offers to sell Vendor. Bank: offers to deposit Bank. Mailbox / Auction House: glows Mail / Auction.

local ADDON, ns = ...

local GetContainerItemID = C_Container.GetContainerItemID
local GetContainerItemInfo = C_Container.GetContainerItemInfo
local GetContainerItemLink = C_Container.GetContainerItemLink
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local UseContainerItem = C_Container.UseContainerItem
local GetItemInfo = C_Item.GetItemInfo

local FIRST_BAG = BACKPACK_CONTAINER or 0
local LAST_BAG = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
local OPEN_DELAY, STEP_DELAY, BATCH = 0.25, 0.3, 6
local SELL_PRICE = 11

local VENDOR, AUCTION, MAIL, BANK = 1, 2, 3, 4
local MARKS = {
    [VENDOR]  = { name = "Vendor",  letter = "V", r = 1.00, g = 0.82, b = 0.00 },
    [AUCTION] = { name = "Auction", letter = "A", r = 1.00, g = 0.45, b = 0.10 },
    [MAIL]    = { name = "Mail",    letter = "M", r = 0.35, g = 0.75, b = 1.00 },
    [BANK]    = { name = "Bank",    letter = "B", r = 0.40, g = 1.00, b = 0.40 },
}
local NUM_MARKS = #MARKS

local PREFIX = "|cff33ccffBagmark|r: "
-- Formats copper as gold/silver/copper with coin icons. Each number is glued to its icon
-- (no space between them) so wrapping can't split them apart.
local COINS = {
    { 10000, "Interface\\MoneyFrame\\UI-GoldIcon" },
    { 100, "Interface\\MoneyFrame\\UI-SilverIcon" },
    { 1, "Interface\\MoneyFrame\\UI-CopperIcon" },
}
local function Money(copper)
    copper = math.floor(copper or 0)
    local parts = {}
    for _, coin in ipairs(COINS) do
        local n = math.floor(copper / coin[1])
        copper = copper - n * coin[1]
        if n > 0 then parts[#parts + 1] = ("%d|T%s:0:0:2:0|t"):format(n, coin[2]) end
    end
    if #parts == 0 then return ("0|T%s:0:0:2:0|t"):format(COINS[3][2]) end
    return table.concat(parts, " ")
end

local function Print(msg) DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg) end

local marks           -- BagmarkDB.marks: [itemID] = mark, forgotten when the item leaves the bags
local permanent       -- BagmarkDB.permanent: [itemID] = mark, kept until changed or removed
local seen = {}       -- item IDs seen in the bags this session (only those can be pruned)
local glowMark        -- the mark that glows right now (MAIL at the mailbox, AUCTION at the AH)
local widgets = {}    -- [button] = widget, for the game's and EllesmereUI's buttons
local owners = {}     -- [widget] = button, for Baganator's corner widgets
local bagOf, slotOf, hooked = {}, {}, {}
local frames = {}     -- the game's container frames, once hooked
local baganator, ellesmere

-- Shared with the addon's other files (BaganatorSort.lua).
ns.Print = Print
ns.NUM_MARKS = NUM_MARKS
-- An item's mark: a permanent mark wins over a normal one.
local function MarkOf(id)
    if not id then return nil end
    return (permanent and permanent[id]) or (marks and marks[id])
end
ns.GetMark = MarkOf

-------------------------------------------------------------------------------
-- Marks
-------------------------------------------------------------------------------

local function InBagRange(bag)
    return bag and bag >= FIRST_BAG and bag <= LAST_BAG
end

local function ForEachBagSlot(fn)
    for bag = FIRST_BAG, LAST_BAG do
        for slot = 1, GetContainerNumSlots(bag) do
            if fn(bag, slot) then return end
        end
    end
end

local Repaint -- defined below

local RefreshList -- the permanent marks window, defined below

local function ColorName(mark)
    local m = MARKS[mark]
    return ("|cff%02x%02x%02x%s|r"):format(m.r * 255, m.g * 255, m.b * 255, m.name)
end

-- Alt-click: the next mark, as a normal mark (and any permanent mark is dropped).
-- Alt+Shift-click: the next mark, saved as permanent.
local function Cycle(id, bag, slot, makePermanent)
    local wasPermanent = permanent[id] ~= nil
    local nextMark = (MarkOf(id) or 0) + 1
    if nextMark > NUM_MARKS then nextMark = nil end
    if makePermanent then
        permanent[id], marks[id] = nextMark, nil
    else
        permanent[id], marks[id] = nil, nextMark
    end
    seen[id] = true
    local link = GetContainerItemLink(bag, slot) or ("item " .. id)
    if nextMark then
        local note = makePermanent and " (permanent)" or (wasPermanent and " (no longer permanent)" or "")
        Print(("%s marked %s%s."):format(link, ColorName(nextMark), note))
    else
        Print(link .. " unmarked." .. ((makePermanent or wasPermanent) and " Its permanent mark was removed." or ""))
    end
    Repaint()
    RefreshList()
end

-- Drop the marks of items that have left the bags. Only items seen in the bags this
-- session are dropped, so a half-loaded inventory at login can't wipe the marks.
local present = {}
local function Prune(full)
    wipe(present)
    local any = false
    ForEachBagSlot(function(bag, slot)
        local id = GetContainerItemID(bag, slot)
        if id then present[id], any = true, true end
    end)
    if full and not any then return end
    local dropped = false
    for id in pairs(marks) do
        if present[id] then
            seen[id] = true
        elseif seen[id] or full then
            marks[id], seen[id], dropped = nil, nil, true
        end
    end
    if dropped then Repaint() end
end

-------------------------------------------------------------------------------
-- Bag button widgets: a corner letter for the mark, and a glow when it's relevant
-------------------------------------------------------------------------------

local allWidgets = {} -- every widget we've made, so the glow can be turned off even in closed bags

local GLOW_TEXTURE = "Interface\\Buttons\\UI-ActionButton-Border"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local EDGE = 2           -- solid border thickness, in pixels
local HALO_SCALE = 1.9   -- outer halo size relative to the slot
local LETTER_FONT = (GameFontNormal and GameFontNormal:GetFont()) or "Fonts\\FRIZQT__.TTF"
local LETTER_SCALE = 0.75 -- letter height relative to the slot
local LETTER_ALPHA = 0.9

local function NewWidget(parent, button)
    local w = CreateFrame("Frame", nil, parent)
    w:SetSize(14, 14)
    w:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
    w:SetFrameLevel(parent:GetFrameLevel() + 6)
    w.button = button

    -- The big letter, centered on the whole slot (even when the widget itself sits in a
    -- corner, as Baganator's do). Its size is set in Paint to match the slot.
    local tag = w:CreateFontString(nil, "OVERLAY", "NumberFontNormal", 7)
    tag:SetPoint("CENTER", button, "CENTER", 1, 0)
    w.tag = tag

    -- The glow: a child of the widget (so it hides with it) covering the whole slot.
    local g = CreateFrame("Frame", nil, w)
    g:SetAllPoints(button)
    g:SetFrameLevel(w:GetFrameLevel())
    g.parts = {}
    local function Part(layer, sub, texture, blend)
        local t = g:CreateTexture(nil, layer, nil, sub)
        t:SetTexture(texture)
        if blend then t:SetBlendMode(blend) end
        g.parts[#g.parts + 1] = t
        return t
    end
    -- Outer halo, doubled up for brightness.
    for _ = 1, 2 do
        local halo = Part("OVERLAY", 1, GLOW_TEXTURE, "ADD")
        halo:SetPoint("CENTER")
        halo.halo = true
    end
    -- A tint over the icon.
    local wash = Part("OVERLAY", 2, WHITE, "ADD")
    wash:SetAllPoints()
    wash.alpha = 0.18
    -- A solid border just inside the slot edge.
    local top = Part("OVERLAY", 3, WHITE)
    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(EDGE)
    local bottom = Part("OVERLAY", 3, WHITE)
    bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT"); bottom:SetHeight(EDGE)
    local left = Part("OVERLAY", 3, WHITE)
    left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT"); left:SetWidth(EDGE)
    local right = Part("OVERLAY", 3, WHITE)
    right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT"); right:SetWidth(EDGE)
    g:Hide()
    w.glow = g

    local pulse = g:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.55)
    fade:SetDuration(0.5)
    w.pulse = pulse

    w:Hide()
    allWidgets[#allWidgets + 1] = w
    return w
end

-- Turns the widget's glow on or off to match its mark and the open window.
local function ApplyGlow(w)
    local mark = w:IsShown() and w.mark
    if not mark or mark ~= glowMark then
        w.pulse:Stop()
        w.glow:Hide()
        return
    end
    local m = MARKS[mark]
    local size = math.max(w.button:GetWidth(), w.button:GetHeight()) * HALO_SCALE
    for _, t in ipairs(w.glow.parts) do
        t:SetVertexColor(m.r, m.g, m.b, t.alpha or 1)
        if t.halo then t:SetSize(size, size) end
    end
    w.glow:Show()
    if not w.pulse:IsPlaying() then w.pulse:Play() end
end

-- Returns true when the widget is shown.
local function Paint(w, button, id)
    w.button = button
    local mark = MarkOf(id)
    w.mark = mark
    if not mark then
        w.pulse:Stop()
        w.glow:Hide()
        w:Hide()
        return false
    end
    local m = MARKS[mark]
    local size = math.floor(math.min(button:GetWidth(), button:GetHeight()) * LETTER_SCALE + 0.5)
    if size > 0 and size ~= w.tagSize then
        w.tag:SetFont(LETTER_FONT, size, "THICKOUTLINE")
        w.tagSize = size
    end
    w.tag:SetText(m.letter)
    w.tag:SetTextColor(m.r, m.g, m.b, LETTER_ALPHA)
    w:Show()
    ApplyGlow(w)
    return true
end

local function OnClick(button, mouse)
    if mouse ~= "LeftButton" or not IsAltKeyDown() or IsControlKeyDown() then return end
    if GetCursorInfo() then return end
    local bag, slot = bagOf[button], slotOf[button]
    if not InBagRange(bag) then return end
    local id = GetContainerItemID(bag, slot)
    if id then Cycle(id, bag, slot, IsShiftKeyDown()) end
end

local function HookClick(button, handler)
    if hooked[button] or InCombatLockdown() then return end
    hooked[button] = true
    button:HookScript("OnClick", handler)
end

local function Slot(button, parent, bag, slot, id)
    bagOf[button], slotOf[button] = bag, slot
    HookClick(button, OnClick)
    local w = widgets[button]
    if not w then
        if not MarkOf(id) then return end
        w = NewWidget(parent, button)
        widgets[button] = w
    end
    Paint(w, button, id)
end

-- The game's own bags
local function PaintGameFrame(frame)
    if not frame.EnumerateValidItems then return end
    for _, button in frame:EnumerateValidItems() do
        local bag, slot = button:GetBagID(), button:GetID()
        Slot(button, button, bag, slot, GetContainerItemID(bag, slot))
    end
end

local function HookGameBags()
    local list = ContainerFrameContainer and ContainerFrameContainer.ContainerFrames
    for i = 1, list and #list or 0 do frames[#frames + 1] = list[i] end
    if ContainerFrameCombinedBags then frames[#frames + 1] = ContainerFrameCombinedBags end
    for _, frame in ipairs(frames) do
        if frame.UpdateItems then hooksecurefunc(frame, "UpdateItems", PaintGameFrame) end
    end
end

-- EllesmereUI Bags: btn is its secure item button; our frames go on btn._textOverlay.
local function EllesmereSlot(button, data)
    local info = data.info
    local id = info and info.itemID
    if not id or not InBagRange(data.bag) or data.slot == 0 then
        local w = widgets[button]
        if w then Paint(w, button, nil) end
        return
    end
    Slot(button, button._textOverlay or button, data.bag, data.slot, id)
end

-- Baganator: our widget is a corner widget it places and hides.
local function BaganatorClick(button, mouse)
    if button.GetBagID then bagOf[button], slotOf[button] = button:GetBagID(), button:GetID() end
    OnClick(button, mouse)
end

local function BaganatorInit(button)
    local w = NewWidget(button, button)
    owners[w] = button
    return w
end

local function BaganatorPaint(w, details)
    local button = owners[w]
    if not (button and button.GetBagID and InBagRange(button:GetBagID())) then return false end
    HookClick(button, BaganatorClick)
    return Paint(w, button, details.itemID)
end

function Repaint()
    for _, frame in ipairs(frames) do
        if frame:IsShown() then PaintGameFrame(frame) end
    end
    if ellesmere then
        for _, name in ipairs({ "EUI_Bags", "EUI_BagsReagent" }) do
            local frame = _G[name]
            -- Called securely, as EllesmereUI's own bridge code does, so its secure buttons stay untainted.
            if frame and frame.RefreshInventory and frame:IsVisible() then
                securecallfunction(frame.RefreshInventory, frame)
            end
        end
    end
    if baganator then baganator.RequestItemButtonsRefresh() end
end

-------------------------------------------------------------------------------
-- Confirmation panel (shared by the vendor and the bank)
-------------------------------------------------------------------------------

local panel

local PANEL_WIDTH, PANEL_PAD, BUTTON_AREA = 270, 10, 40
local ROW_H, ROW_GAP, MAX_ROWS = 18, 6, 20

local function GetPanel()
    if panel then return panel end
    panel = CreateFrame("Frame", "BagmarkConfirm", UIParent, "BackdropTemplate")
    panel:SetSize(PANEL_WIDTH, 78)
    panel:SetFrameStrata("HIGH")
    panel:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    panel:SetBackdropColor(0, 0, 0, 0.85)
    panel:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    panel:Hide()

    local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    -- A fixed width (one anchor, no height) lets the text wrap onto as many lines as it needs.
    text:SetPoint("TOPLEFT", PANEL_PAD, -PANEL_PAD)
    text:SetWidth(PANEL_WIDTH - PANEL_PAD * 2)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    text:SetWordWrap(true)
    if text.SetMaxLines then text:SetMaxLines(0) end
    panel.text = text

    local yes = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    yes:SetSize(100, 22)
    yes:SetPoint("BOTTOMLEFT", 8, 8)
    yes:SetScript("OnClick", function()
        panel:Hide()
        if panel.onYes then panel.onYes() end
    end)
    panel.yes = yes

    local no = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    no:SetSize(100, 22)
    no:SetPoint("BOTTOMRIGHT", -8, 8)
    no:SetText("Not Now")
    no:SetScript("OnClick", function() panel:Hide() end)

    panel.rows = {}
    return panel
end

-- One line of the item list: icon, name (cut short with "..." if too long) and a right-hand value.
local function GetRow(p, i)
    local row = p.rows[i]
    if row then return row end
    row = CreateFrame("Frame", nil, p)
    row:SetSize(PANEL_WIDTH - PANEL_PAD * 2, ROW_H)
    if i == 1 then
        row:SetPoint("TOPLEFT", p.text, "BOTTOMLEFT", 0, -ROW_GAP)
    else
        row:SetPoint("TOPLEFT", p.rows[i - 1], "BOTTOMLEFT", 0, 0)
    end

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(ROW_H - 2, ROW_H - 2)
    icon:SetPoint("LEFT")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    local right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    right:SetPoint("RIGHT")
    right:SetJustifyH("RIGHT")
    row.right = right

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    name:SetPoint("RIGHT", right, "LEFT", -6, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row.name = name

    -- Hover a row for the item's tooltip.
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not self.link then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.link)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    p.rows[i] = row
    return row
end

-- items: { { link, icon, count, right }, ... }
local function FillRows(p, items)
    local shown = math.min(#items, MAX_ROWS)
    if #items > MAX_ROWS then shown = MAX_ROWS - 1 end
    for i = 1, shown do
        local item, row = items[i], GetRow(p, i)
        row.link = item.link
        row.icon:SetTexture(item.icon)
        row.icon:Show()
        local label = item.link and item.link:gsub("[%[%]]", "") or "?"
        if item.count > 1 then label = label .. " |cffaaaaaax" .. item.count .. "|r" end
        row.name:SetText(label)
        row.right:SetText(item.right or "")
        row:Show()
    end
    local used = shown
    if #items > shown then
        used = shown + 1
        local row = GetRow(p, used)
        row.link = nil
        row.icon:Hide()
        row.name:SetText(("|cffaaaaaa...and %d more|r"):format(#items - shown))
        row.right:SetText("")
        row:Show()
    end
    for i = used + 1, #p.rows do p.rows[i]:Hide() end
    return used
end

-- Groups the bag stacks with the given mark by item. keep(info) can leave stacks out.
-- Returns the list, sorted by name, ready for FillRows (minus the right-hand text).
local function MarkedItems(mark, keep)
    local list, byID = {}, {}
    ForEachBagSlot(function(bag, slot)
        local info = GetContainerItemInfo(bag, slot)
        if info and MarkOf(info.itemID) == mark and (not keep or keep(info)) then
            local item = byID[info.itemID]
            if not item then
                item = { id = info.itemID, link = info.hyperlink, icon = info.iconFileID, count = 0, stacks = 0 }
                byID[info.itemID] = item
                list[#list + 1] = item
            end
            item.count = item.count + (info.stackCount or 1)
            item.stacks = item.stacks + 1
        end
    end)
    for _, item in ipairs(list) do item.sortName = item.link and item.link:match("%[(.-)%]") or "" end
    table.sort(list, function(x, y) return x.sortName < y.sortName end)
    return list
end

local function ShowPanel(owner, message, yesText, onYes, items)
    local p = GetPanel()
    p.text:SetText(message)
    local rows = FillRows(p, items or {})
    p.yes:SetText(yesText)
    p.onYes = onYes
    p.owner = owner
    -- Grow downward to fit the wrapped text; refit next frame once the text has laid out.
    local function Fit()
        local list = rows > 0 and (ROW_GAP + rows * ROW_H) or 0
        p:SetHeight(math.max(78, math.ceil(p.text:GetStringHeight()) + list + PANEL_PAD * 2 + BUTTON_AREA))
    end
    Fit()
    C_Timer.After(0, Fit)
    p:ClearAllPoints()
    if owner then
        p:SetPoint("TOPLEFT", owner, "TOPRIGHT", 4, 0)
    else
        p:SetPoint("CENTER")
    end
    p:Show()
end

local function HidePanel(owner)
    if panel and (owner == nil or panel.owner == owner) then panel:Hide() end
end

local function Shown(frame)
    return frame and frame:IsShown() and frame or nil
end

-------------------------------------------------------------------------------
-- Vendor: sell items marked Vendor
-------------------------------------------------------------------------------

local atMerchant, offered, selling, sold, earned = false, false, false, 0, 0

local function SellPrice(id)
    return select(SELL_PRICE, GetItemInfo(id))
end

-- The item's sell price decides when it is known; the slot's hasNoValue flag only when it isn't cached yet.
local function Sellable(info)
    local price = SellPrice(info.itemID)
    if price then return price > 0 end
    return not info.hasNoValue
end

local function CollectVendor()
    local unsellable = 0
    local items = MarkedItems(VENDOR, function(info)
        if Sellable(info) then return true end
        unsellable = unsellable + 1
        return false
    end)
    local stacks, value = 0, 0
    for _, item in ipairs(items) do
        item.value = (SellPrice(item.id) or 0) * item.count
        item.right = item.value > 0 and Money(item.value) or ""
        stacks, value = stacks + item.stacks, value + item.value
    end
    return items, stacks, value, unsellable
end

local function FinishSelling()
    if selling and sold > 0 then
        Print(("Sold %d item%s for %s."):format(sold, sold == 1 and "" or "s", Money(earned)))
    end
    selling, sold, earned = false, 0, 0
end

local function SellStep()
    if not selling then return end
    if not atMerchant or InCombatLockdown() then return FinishSelling() end
    local used = 0
    ForEachBagSlot(function(bag, slot)
        local info = GetContainerItemInfo(bag, slot)
        if info and MarkOf(info.itemID) == VENDOR and not info.isLocked and Sellable(info) then
            UseContainerItem(bag, slot)
            used, sold = used + 1, sold + 1
            earned = earned + (SellPrice(info.itemID) or 0) * (info.stackCount or 1)
            return used >= BATCH
        end
    end)
    if used == 0 then return FinishSelling() end
    C_Timer.After(STEP_DELAY, SellStep)
end

local function SellVendor()
    if selling or not atMerchant then return end
    selling, sold, earned = true, 0, 0
    SellStep()
end

-- Waits (briefly) for the vendor window to be on screen, then offers once per visit.
local function OfferVendor(tries)
    if not atMerchant or offered then return end
    tries = tries or 0
    local owner = Shown(MerchantFrame)
    if not owner and tries < 8 then
        C_Timer.After(OPEN_DELAY, function() OfferVendor(tries + 1) end)
        return
    end
    offered = true
    local items, count, value, unsellable = CollectVendor()
    if unsellable > 0 then
        Print(("%d item%s marked Vendor can't be sold to vendors."):format(unsellable, unsellable == 1 and "" or "s"))
    end
    if count == 0 then return end
    local msg = ("Sell %d item%s"):format(count, count == 1 and "" or "s")
    if value > 0 then msg = msg .. " for " .. Money(value) end
    ShowPanel(owner, msg .. "?", "Sell", SellVendor, items)
end

-------------------------------------------------------------------------------
-- Bank: deposit Bank
-------------------------------------------------------------------------------

local atBank, depositing, deposited, stalls, lastLeft = false, false, 0, 0, nil
local BANK_TYPE = Enum.BankType and Enum.BankType.Character

local function CanUseBank()
    if not atBank or InCombatLockdown() or GetCursorInfo() then return false end
    if C_Bank and C_Bank.CanUseBank and BANK_TYPE then return C_Bank.CanUseBank(BANK_TYPE) end
    return true
end

local function CountBankMarked()
    local count = 0
    ForEachBagSlot(function(bag, slot)
        local id = GetContainerItemID(bag, slot)
        if id and MarkOf(id) == BANK then count = count + 1 end
    end)
    return count
end

local function FinishDeposit(msg)
    if depositing then
        if deposited > 0 then
            Print(("Deposited %d stack%s in the bank."):format(deposited, deposited == 1 and "" or "s"))
        end
        if msg then Print(msg) end
    end
    depositing, deposited, stalls, lastLeft = false, 0, 0, nil
end

local function DepositStep()
    if not depositing then return end
    if not CanUseBank() then return FinishDeposit() end
    local left = CountBankMarked()
    if lastLeft and left < lastLeft then deposited = deposited + (lastLeft - left) end
    if left == 0 then return FinishDeposit() end
    -- Items that stay put after a deposit attempt mean the bank is full.
    if lastLeft and left >= lastLeft then
        stalls = stalls + 1
        if stalls >= 3 then
            return FinishDeposit(("Your bank looks full; %d marked stack%s left in your bags.")
                :format(left, left == 1 and "" or "s"))
        end
    else
        stalls = 0
    end
    lastLeft = left
    local used = 0
    ForEachBagSlot(function(bag, slot)
        local info = GetContainerItemInfo(bag, slot)
        if info and MarkOf(info.itemID) == BANK and not info.isLocked then
            UseContainerItem(bag, slot, nil, BANK_TYPE)
            used = used + 1
            return used >= BATCH
        end
    end)
    C_Timer.After(STEP_DELAY, DepositStep)
end

local function DepositBank()
    if depositing or not CanUseBank() then return end
    depositing, deposited, stalls, lastLeft = true, 0, 0, nil
    DepositStep()
end

-- The bank window on screen: EllesmereUI's, Baganator's or the game's own.
-- Baganator names its bank windows "Baganator_<Single|Category>ViewBankViewFrame<skin>"
-- and adds them to UISpecialFrames (so Escape closes them), which is where we look.
local function BankWindow()
    local eui = Shown(_G.EUI_BankFrame)
    if eui then return eui end
    for _, name in ipairs(UISpecialFrames or {}) do
        if type(name) == "string" and name:find("^Baganator_") and name:find("BankViewFrame") then
            local frame = Shown(_G[name])
            if frame then return frame end
        end
    end
    return Shown(BankFrame)
end

-- Waits (briefly) for the bank window to be on screen, then offers once per visit.
local bankOffered = false
local function OfferBank(tries)
    if not atBank or bankOffered then return end
    tries = tries or 0
    local owner = BankWindow()
    if not owner and tries < 8 then
        C_Timer.After(OPEN_DELAY, function() OfferBank(tries + 1) end)
        return
    end
    bankOffered = true
    local count = CountBankMarked()
    if count == 0 then return end
    local m = MARKS[BANK]
    ShowPanel(owner, ("Deposit %d stack%s marked |cff%02x%02x%02x%s|r?"):format(count, count == 1 and "" or "s",
        m.r * 255, m.g * 255, m.b * 255, m.name), "Deposit", DepositBank, MarkedItems(BANK))
end

-------------------------------------------------------------------------------
-- Tooltip
-------------------------------------------------------------------------------

local function OnTooltip(tooltip, data)
    local id = data and data.id
    if not id or (issecretvalue and issecretvalue(id)) then return end
    local mark = MarkOf(id)
    if not mark then return end
    local m = MARKS[mark]
    local perm = permanent and permanent[id] and " (permanent)" or ""
    tooltip:AddLine("Bagmark: " .. m.name .. perm, m.r, m.g, m.b)
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local function SetGlow(mark)
    if glowMark == mark then return end
    glowMark = mark
    -- Update every widget directly: bags that are closed right now won't be repainted,
    -- and would otherwise keep their old glow until the next time they redraw.
    for _, w in ipairs(allWidgets) do ApplyGlow(w) end
    Repaint()
end

local events = CreateFrame("Frame")

-- Runs one optional setup step. A failure is still reported (BugSack sees it) but can't
-- stop the rest of Bagmark from starting.
local function Safely(fn)
    local ok, err = pcall(fn)
    if not ok then geterrorhandler()(err) end
end

local function Init()
    BagmarkDB = BagmarkDB or {}
    BagmarkDB.marks = BagmarkDB.marks or {}
    BagmarkDB.permanent = BagmarkDB.permanent or {}
    marks, permanent = BagmarkDB.marks, BagmarkDB.permanent

    -- Core events first, so the vendor/bank/mail/AH features work whatever happens below.
    for _, event in ipairs({
        "BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
        "MERCHANT_SHOW", "MERCHANT_CLOSED",
        "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
        "MAIL_SHOW", "MAIL_CLOSED",
        "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
    }) do
        events:RegisterEvent(event)
    end

    Safely(HookGameBags)

    Safely(function()
        local eui = _G.EUI_Bags
        if C_AddOns.IsAddOnLoaded("EllesmereUIBags") and eui and eui.RegisterItemOverlayIcon then
            ellesmere = eui
            eui.RegisterItemOverlayIcon(ADDON, EllesmereSlot)
        end
    end)

    Safely(function()
        local api = _G.Baganator and _G.Baganator.API
        if C_AddOns.IsAddOnLoaded("Baganator") and api and api.RegisterCornerWidget then
            baganator = api
            api.RegisterCornerWidget("Bagmark", ADDON, BaganatorPaint, BaganatorInit,
                { corner = "top_left", priority = 1 }, true)
        end
    end)

    -- Backups for the window events, in case one of them doesn't fire.
    Safely(function()
        if MailFrame then
            MailFrame:HookScript("OnHide", function() if glowMark == MAIL then SetGlow(nil) end end)
        end
        if MerchantFrame then
            MerchantFrame:HookScript("OnShow", function()
                if not atMerchant then
                    atMerchant, offered = true, false
                    C_Timer.After(OPEN_DELAY, OfferVendor)
                end
            end)
        end
    end)

    Safely(function()
        if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnTooltip)
        end
    end)
end

local fullPruneDone, ahHooked = false, false

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON then
            events:UnregisterEvent("ADDON_LOADED")
            events:RegisterEvent("PLAYER_LOGIN")
        end
    elseif event == "PLAYER_LOGIN" then
        Init()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Once per session, after the bags have loaded, forget marks for items no longer carried.
        if not fullPruneDone then
            C_Timer.After(5, function()
                fullPruneDone = true
                Prune(true)
            end)
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        Prune(false)
    elseif event == "MERCHANT_SHOW" then
        atMerchant, offered = true, false
        C_Timer.After(OPEN_DELAY, OfferVendor)
    elseif event == "MERCHANT_CLOSED" then
        atMerchant, offered = false, false
        HidePanel()
        FinishSelling()
    elseif event == "BANKFRAME_OPENED" then
        atBank, bankOffered = true, false
        C_Timer.After(OPEN_DELAY, OfferBank)
    elseif event == "BANKFRAME_CLOSED" then
        atBank, bankOffered = false, false
        HidePanel()
        FinishDeposit()
    elseif event == "PLAYER_REGEN_DISABLED" then
        HidePanel()
        FinishSelling()
        FinishDeposit()
    elseif event == "MAIL_SHOW" then
        SetGlow(MAIL)
    elseif event == "AUCTION_HOUSE_SHOW" then
        SetGlow(AUCTION)
        -- The AH window loads on demand, so its backup hook goes in on first open.
        local ah = _G.AuctionHouseFrame or _G.AuctionFrame
        if ah and not ahHooked then
            ahHooked = true
            ah:HookScript("OnHide", function() if glowMark == AUCTION then SetGlow(nil) end end)
        end
    elseif event == "MAIL_CLOSED" then
        if glowMark == MAIL then SetGlow(nil) end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        if glowMark == AUCTION then SetGlow(nil) end
    end
end)
events:RegisterEvent("ADDON_LOADED")

-------------------------------------------------------------------------------
-- Slash command
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
-- Permanent marks window (/bagmark list)
-------------------------------------------------------------------------------

local LIST_W, LIST_H, LIST_ROW_H, LIST_PAD = 320, 360, 22, 10
local listFrame

local function BuildList()
    local f = CreateFrame("Frame", "BagmarkListFrame", UIParent, "BackdropTemplate")
    f:SetSize(LIST_W, LIST_H)
    f:SetPoint("CENTER")
    f:SetFrameStrata("DIALOG")
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    f:SetBackdropColor(0, 0, 0, 0.85)
    f:SetBackdropBorderColor(0.5, 0.5, 0.5, 1)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)
    f:Hide()
    table.insert(UISpecialFrames, "BagmarkListFrame") -- Escape closes it

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", LIST_PAD, -LIST_PAD)
    title:SetText("Bagmark: Permanent Marks")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)

    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", LIST_PAD, -34)
    scroll:SetPoint("BOTTOMRIGHT", -30, LIST_PAD)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(LIST_W - LIST_PAD - 30, 1)
    scroll:SetScrollChild(content)
    f.content = content

    local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("TOPLEFT", 0, -4)
    empty:SetWidth(content:GetWidth())
    empty:SetJustifyH("LEFT")
    empty:SetText("No permanent marks. Alt+Shift-click a bag item to give it one.")
    f.empty = empty

    f.rows = {}
    -- Item names arrive from the server a moment later when they aren't cached.
    f:SetScript("OnEvent", function() RefreshList() end)
    f:SetScript("OnShow", function(self) self:RegisterEvent("GET_ITEM_INFO_RECEIVED") end)
    f:SetScript("OnHide", function(self) self:UnregisterEvent("GET_ITEM_INFO_RECEIVED") end)
    return f
end

local function ListRow(i)
    local row = listFrame.rows[i]
    if row then return row end
    local content = listFrame.content
    row = CreateFrame("Frame", nil, content)
    row:SetSize(content:GetWidth(), LIST_ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * LIST_ROW_H)
    row:EnableMouse(true)

    local remove = CreateFrame("Button", nil, row, "UIPanelCloseButton")
    remove:SetSize(LIST_ROW_H, LIST_ROW_H)
    remove:SetPoint("RIGHT")
    remove:SetScript("OnClick", function()
        if row.id and permanent[row.id] then
            local _, link = GetItemInfo(row.id)
            permanent[row.id] = nil
            Print((link or ("item " .. row.id)) .. "'s permanent mark was removed.")
            Repaint()
            RefreshList()
        end
    end)
    remove:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Remove permanent mark")
        GameTooltip:Show()
    end)
    remove:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(LIST_ROW_H - 4, LIST_ROW_H - 4)
    icon:SetPoint("LEFT")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon = icon

    local mark = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mark:SetPoint("RIGHT", remove, "LEFT", -4, 0)
    row.mark = mark

    local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    name:SetPoint("LEFT", icon, "RIGHT", 5, 0)
    name:SetPoint("RIGHT", mark, "LEFT", -6, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    row.name = name

    row:SetScript("OnEnter", function(self)
        if not self.id then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetItemByID(self.id)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)

    listFrame.rows[i] = row
    return row
end

function RefreshList()
    if not (listFrame and listFrame:IsShown()) then return end
    local entries = {}
    for id, mark in pairs(permanent) do
        local name, link = GetItemInfo(id)
        if not name then C_Item.RequestLoadItemDataByID(id) end
        entries[#entries + 1] = { id = id, mark = mark, name = name or ("item " .. id), link = link }
    end
    table.sort(entries, function(a, b)
        if a.mark ~= b.mark then return a.mark < b.mark end
        return a.name < b.name
    end)
    for i, e in ipairs(entries) do
        local row = ListRow(i)
        row.id = e.id
        row.icon:SetTexture(C_Item.GetItemIconByID(e.id))
        row.name:SetText(e.link and e.link:gsub("[%[%]]", "") or e.name)
        row.mark:SetText(ColorName(e.mark))
        row:Show()
    end
    for i = #entries + 1, #listFrame.rows do listFrame.rows[i]:Hide() end
    listFrame.empty:SetShown(#entries == 0)
    listFrame.content:SetHeight(math.max(1, #entries * LIST_ROW_H))
end

local function ToggleList()
    listFrame = listFrame or BuildList()
    if listFrame:IsShown() then
        listFrame:Hide()
    else
        listFrame:Show()
        RefreshList()
    end
end

-------------------------------------------------------------------------------
-- Slash command
-------------------------------------------------------------------------------

SLASH_BAGMARK1 = "/bagmark"
SlashCmdList.BAGMARK = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "list" then
        ToggleList()
    elseif msg == "clear" then
        wipe(marks)
        Repaint()
        Print("Normal marks cleared. Permanent marks were kept (/bagmark clear all removes those too).")
    elseif msg == "clear all" then
        wipe(marks)
        wipe(permanent)
        Repaint()
        RefreshList()
        Print("All marks cleared, including permanent ones.")
    else
        Print("Alt-click a bag item to cycle Vendor > Auction > Mail > Bank > none.")
        Print("Alt+Shift-click does the same but makes the mark permanent.")
        Print("/bagmark list - permanent marks;  /bagmark clear - normal marks;  /bagmark clear all - every mark.")
    end
end
