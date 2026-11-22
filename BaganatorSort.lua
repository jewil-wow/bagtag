-- BaganatorSort.lua: adds a "BagTag" sort method to Baganator's sort dropdown.
-- It sorts the bags like Baganator's Type sort, but puts marked items at the end,
-- grouped by mark (Vendor, Auction, Mail, Bank). The bank is handed to the game's
-- own bank sort, since marks only apply to the bags.

local _, ns = ...

local api = _G.Baganator and _G.Baganator.API
if not (C_AddOns.IsAddOnLoaded("Baganator") and api and api.RegisterContainerSort) then return end

local GetContainerItemInfo = C_Container.GetContainerItemInfo
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local PickupContainerItem = C_Container.PickupContainerItem
local GetItemInfo = C_Item.GetItemInfo
local GetItemInfoInstant = C_Item.GetItemInfoInstant

local SORT_ID, SORT_LABEL = "bagtag", "BagTag"
local STEP_DELAY = 0.15  -- seconds between rounds of moves
local MOVES_PER_STEP = 8
local MAX_STEPS = 400    -- hard stop (about a minute)
local MAX_STALLS = 20    -- rounds in a row with nothing movable and nothing locked
local LOAD_RETRIES = 10  -- rounds to wait for uncached item info before sorting anyway

local HEARTHSTONE = 6948
local PRIORITY_FIRST, PRIORITY_NORMAL, PRIORITY_MARKED = 1, 1000, 2000

-------------------------------------------------------------------------------
-- Sort order: a copy of Baganator's Type sort (Sorting/ItemFields.lua, Order.lua)
-------------------------------------------------------------------------------

local ORDER = {
    classID = { 18, 0, 5, 6, 2, 4, 11, 3, 8, 16, 1, 7, 19, 9, 10, 12, 13, 14, 15, 17 },
    weapon = { 0, 4, 7, 9, 15, 13, 11, 12, 19, 1, 5, 8, 6, 10, 2, 18, 3, 16, 17, 14, 20 },
    armor = { 6, 7, 8, 9, 10, 11, 4, 3, 2, 1, 0, 5 },
    invSlot = { 17, 13, 21, 14, 23, 26, 22, 15, 25, 24, 27, 28, 1, 3, 16, 5, 20, 9, 10, 6, 7, 8, 2, 11,
        12, 4, 19, 29, 30, 18, 31, 32, 33, 34, 0 },
    tradegoods = { 18, 1, 4, 7, 6, 5, 12, 16, 10, 9, 8, 11, 0, 2, 3, 13, 14, 15, 17 },
}
local RANK = {}
for key, list in pairs(ORDER) do
    RANK[key] = {}
    for i, v in ipairs(list) do RANK[key][v] = i end
end

local WEAPON, ARMOR, TRADEGOODS = 2, 4, 7

local function SubRank(classID, sub)
    if classID == WEAPON then return RANK.weapon[sub] or sub + 200 end
    if classID == ARMOR then return RANK.armor[sub] or sub + 200 end
    if classID == TRADEGOODS then return RANK.tradegoods[sub] or sub + 200 end
    return sub
end

-- Builds the sort keys for one bag item. Returns nil while the game is still loading its info.
local function Describe(info)
    local id, link = info.itemID, info.hyperlink
    local _, _, _, _, _, classID, subClassID = GetItemInfoInstant(id)
    classID, subClassID = classID or -1, subClassID or -1
    local cached = C_Item.IsItemDataCachedByID(id)
    if not cached then C_Item.RequestLoadItemDataByID(id) end
    local mark = ns.GetMark(id)
    local priority = (id == HEARTHSTONE and PRIORITY_FIRST)
        or (mark and PRIORITY_MARKED + mark) or PRIORITY_NORMAL
    local invSlot = C_Item.GetItemInventoryTypeByID(id) or -1
    return {
        id = id,
        cached = cached,
        maxStack = cached and select(8, GetItemInfo(id)) or nil,
        keys = {
            priority,
            RANK.classID[classID] or classID + 200,
            RANK.invSlot[invSlot] or invSlot + 200,
            SubRank(classID, subClassID),
            -((cached and link and C_Item.GetDetailedItemLevelInfo(link)) or 0),
            -(info.quality or 0),
            (cached and C_Item.GetItemNameByID(id)) or "",
            -id,
            -(info.stackCount or 1),
            link or "",
        },
    }
end

local function Before(a, b)
    local ka, kb = a.keys, b.keys
    for i = 1, #ka do
        if ka[i] ~= kb[i] then return ka[i] < kb[i] end
    end
    return a.pos < b.pos
end

-------------------------------------------------------------------------------
-- Reading the bags
-------------------------------------------------------------------------------

local function ReagentBag()
    return Enum.BagIndex and Enum.BagIndex.ReagentBag
end

-- The bags, split into groups that are each sorted on their own: the general-purpose
-- bags together, the reagent bag, and special bags (soul, quiver, profession) grouped
-- by type. Items only move within their group, so nothing is put in a bag that can't
-- hold it.
local function SlotGroups()
    local groups, byKey = {}, {}
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS
    for bag = BACKPACK_CONTAINER, last do
        local n = GetContainerNumSlots(bag)
        if n > 0 then
            local _, family = C_Container.GetContainerNumFreeSlots(bag)
            local key = (bag == ReagentBag() and "reagent") or ((family or 0) == 0 and "general") or family
            local group = byKey[key]
            if not group then
                group = {}
                byKey[key] = group
                groups[#groups + 1] = group
            end
            for slot = 1, n do group[#group + 1] = { bag = bag, slot = slot } end
        end
    end
    return groups
end

-- Fills each slot entry with what's in it now. Returns whether every item's info is loaded.
local function ReadSlots(slots)
    local allCached = true
    for pos, s in ipairs(slots) do
        local info = GetContainerItemInfo(s.bag, s.slot)
        s.locked = info and info.isLocked or false
        s.item = info and Describe(info) or nil
        if s.item then
            s.item.pos, s.item.count = pos, info.stackCount or 1
            if not s.item.cached then allCached = false end
        end
    end
    return allCached
end

-------------------------------------------------------------------------------
-- Moving items
-------------------------------------------------------------------------------

local function Move(from, to)
    PickupContainerItem(from.bag, from.slot)
    PickupContainerItem(to.bag, to.slot)
    ClearCursor()
end

-- Merges partial stacks of the same item, smallest onto largest (as Baganator does).
-- Returns "moved", "waiting" (a stack is locked) or nil when nothing needs merging.
local function CombineStacks(slots)
    local partials = {}
    for _, s in ipairs(slots) do
        local item = s.item
        if item and item.maxStack and item.maxStack > 1 and item.count < item.maxStack then
            partials[item.id] = partials[item.id] or {}
            table.insert(partials[item.id], s)
        end
    end
    local moved, waiting = false, false
    for _, list in pairs(partials) do
        if #list > 1 then
            table.sort(list, function(a, b) return a.item.count < b.item.count end)
            local from, to = list[1], list[#list]
            if from.locked or to.locked then
                waiting = true
            else
                Move(from, to)
                moved = true
            end
        end
    end
    return moved and "moved" or (waiting and "waiting") or nil
end

-- One round of swaps toward the sorted order. Returns the number of moves made and
-- whether everything is already in place.
local function SortRound(slots, reverse)
    local items = {}
    for _, s in ipairs(slots) do
        if s.item then items[#items + 1] = s.item end
    end
    table.sort(items, Before)

    -- target[pos] = the item ID that belongs in that slot (nil = empty)
    local target, offset = {}, reverse and (#slots - #items) or 0
    for i, item in ipairs(items) do target[i + offset] = item.id end

    local function Current(pos)
        local item = slots[pos].item
        return item and item.id
    end

    local done, moves, touched = true, 0, {}
    for pos = 1, #slots do
        local want = target[pos]
        if Current(pos) ~= want then
            done = false
            if want and not slots[pos].locked and not touched[pos] then
                -- Find the wanted item somewhere it doesn't already belong; prefer a
                -- straight swap where our current item belongs over there.
                local from
                for other = 1, #slots do
                    local s = slots[other]
                    if other ~= pos and not touched[other] and not s.locked and Current(other) == want
                        and Current(other) ~= target[other] then
                        if target[other] == Current(pos) then from = other; break end
                        from = from or other
                    end
                end
                if from then
                    Move(slots[from], slots[pos])
                    touched[pos], touched[from] = true, true
                    slots[pos].item, slots[from].item = slots[from].item, slots[pos].item
                    moves = moves + 1
                    if moves >= MOVES_PER_STEP then break end
                end
            end
        end
    end
    return moves, done
end

-------------------------------------------------------------------------------
-- The sort run
-------------------------------------------------------------------------------

local running, reverse, steps, stalls, loadTries = false, false, 0, 0, 0

local function Stop(msg)
    running = false
    if msg then ns.Print(msg) end
end

local function Step()
    if not running then return end
    steps = steps + 1
    if InCombatLockdown() then return Stop("Sort stopped: you entered combat.") end
    if steps > MAX_STEPS then return Stop("Sort stopped: it was taking too long. Try sorting again.") end
    if GetCursorInfo() then return Stop("Sort stopped: you're holding an item.") end

    local groups = SlotGroups()
    local allCached = true
    for _, slots in ipairs(groups) do
        if not ReadSlots(slots) then allCached = false end
    end
    -- Give the game a moment to load item names and levels so the order is right.
    if not allCached and loadTries < LOAD_RETRIES then
        loadTries = loadTries + 1
        C_Timer.After(STEP_DELAY, Step)
        return
    end

    local combining = false
    for _, slots in ipairs(groups) do
        if CombineStacks(slots) then combining = true end
    end
    if combining then
        C_Timer.After(STEP_DELAY, Step)
        return
    end

    local moves, allDone, anyLocked = 0, true, false
    for _, slots in ipairs(groups) do
        local groupMoves, done = SortRound(slots, reverse)
        moves = moves + groupMoves
        if not done then allDone = false end
        for _, s in ipairs(slots) do
            if s.locked then anyLocked = true; break end
        end
    end
    if allDone then return Stop() end
    if moves == 0 then
        if not anyLocked then
            stalls = stalls + 1
            if stalls >= MAX_STALLS then return Stop("Sort stopped: couldn't finish moving items.") end
        end
    else
        stalls = 0
    end
    C_Timer.After(STEP_DELAY, Step)
end

local function SortBags(isReverse)
    if running or InCombatLockdown() then return end
    running, reverse, steps, stalls, loadTries = true, isReverse and true or false, 0, 0, 0
    Step()
end

-- The bank isn't marked, so it uses the game's own bank sort (as Baganator's "Blizzard" option does).
local function SortBank(isReverse, containerType)
    local types = api.Constants.ContainerType
    local bankType = containerType == types.WarbandBank and Enum.BankType.Account or Enum.BankType.Character
    if C_Container.SetSortBagsRightToLeft then C_Container.SetSortBagsRightToLeft(not isReverse) end
    if C_Container.SortBank then C_Container.SortBank(bankType) end
end

api.RegisterContainerSort(SORT_LABEL, SORT_ID, function(isReverse, containerType)
    if containerType == api.Constants.ContainerType.Backpack then
        SortBags(isReverse)
    else
        SortBank(isReverse, containerType)
    end
end)
