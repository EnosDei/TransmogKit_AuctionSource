--[[
AuctionSource.lua

An "Expansions" tab next to Buy/Sell/Auctions. It opens a panel that
covers the whole window interior (search bar and bottom bar included, like
a real tab does) with categories on the left, expansion + name filters on
top, and Price/Name/Available results below.

  * Categories come from Enum.ItemClass / Enum.ItemArmorSubclass and fire
    a real C_AuctionHouse.SendBrowseQuery.
  * Expansion filtering reads the `expansionID` GetItemInfo() returns for
    every item and filters the loaded results client-side (Blizzard's own
    "Current Expansion Only" only supports the newest expansion).
  * Hover = item tooltip. Ctrl-click = dressing room preview, shift-click
    = link to chat (Blizzard's own HandleModifiedItemClick).
  * Plain click = AuctionHouseFrame:SelectBrowseResult(), the exact call
    Blizzard's own browse rows make. That opens the real buy page (bid /
    buyout list + Buyout button) for that item. Buying is done by
    Blizzard's own secure Buyout button, not by any purchase code here.
]]--

TransmogKit = TransmogKit or {}
TransmogKit.AuctionSource = TransmogKit.AuctionSource or {}
local TKAS = TransmogKit.AuctionSource

-- 12.1.5 removed the old global item functions; use the C_Item versions.
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemSubClassInfo = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo
local GetCoinTextureString = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString

-- -----------------------------------------------------------------------
-- Saved state / enable-disable
-- -----------------------------------------------------------------------
local function IsEnabled()
    if not TransmogKitAuctionSourceDB then return true end
    return TransmogKitAuctionSourceDB.auctionSourceEnabled ~= false
end

local function SetEnabled(enabled)
    TransmogKitAuctionSourceDB = TransmogKitAuctionSourceDB or {}
    TransmogKitAuctionSourceDB.auctionSourceEnabled = enabled
    if enabled then
        TKAS.InjectPanel()
    else
        if TKAS.tabButton then TKAS.tabButton:Hide() end
        if TKAS.panel then TKAS.panel:Hide() end
    end
end
TKAS.SetEnabled = SetEnabled
TKAS.IsEnabled = IsEnabled

-- "Open the Expansions tab first when the Auction House opens" (default ON).
local function OpenFirstEnabled()
    if not TransmogKitAuctionSourceDB then return true end
    return TransmogKitAuctionSourceDB.auctionSourceOpenFirst ~= false
end
function TKAS.SetOpenFirst(value)
    TransmogKitAuctionSourceDB = TransmogKitAuctionSourceDB or {}
    TransmogKitAuctionSourceDB.auctionSourceOpenFirst = value and true or false
end
TKAS.OpenFirstEnabled = OpenFirstEnabled

-- "Start on the current expansion" (default ON): each time the tab opens,
-- the expansion filter starts on the current expansion instead of "All".
local function StartOnCurrentEnabled()
    if not TransmogKitAuctionSourceDB then return true end
    return TransmogKitAuctionSourceDB.auctionSourceStartCurrent ~= false
end
function TKAS.SetStartOnCurrent(value)
    TransmogKitAuctionSourceDB = TransmogKitAuctionSourceDB or {}
    TransmogKitAuctionSourceDB.auctionSourceStartCurrent = value and true or false
end
TKAS.StartOnCurrentEnabled = StartOnCurrentEnabled

-- "Back returns to the Expansions tab": when you opened an item's buy page
-- from the Expansions tab, Blizzard's Back button brings you back here
-- instead of to Blizzard's own Browse view (default ON).
local function BackReturnEnabled()
    if not TransmogKitAuctionSourceDB then return true end
    return TransmogKitAuctionSourceDB.auctionSourceBackReturn ~= false
end
function TKAS.SetBackReturn(value)
    TransmogKitAuctionSourceDB = TransmogKitAuctionSourceDB or {}
    TransmogKitAuctionSourceDB.auctionSourceBackReturn = value and true or false
end
TKAS.BackReturnEnabled = BackReturnEnabled

local function Log(msg)
    print("|cff33ccffTransmogKit AuctionSource:|r " .. tostring(msg))
end
local function LogError(msg)
    print("|cffff5555TransmogKit AuctionSource ERROR:|r " .. tostring(msg))
end

-- -----------------------------------------------------------------------
-- Flat, dark, thin-bordered widgets to match the AH's look (instead of
-- Blizzard's red UIPanelButtonTemplate, which clashed).
-- -----------------------------------------------------------------------
local function MakeFlatButton(parent, w, h, leftAlign, fontObject)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(w, h)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.10, 0.10, 0.10, 1)

    local function line(p1, p2, horizontal)
        local t = b:CreateTexture(nil, "BORDER")
        t:SetColorTexture(0.30, 0.30, 0.30, 1)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if horizontal then t:SetHeight(1) else t:SetWidth(1) end
    end
    line("TOPLEFT", "TOPRIGHT", true)
    line("BOTTOMLEFT", "BOTTOMRIGHT", true)
    line("TOPLEFT", "BOTTOMLEFT", false)
    line("TOPRIGHT", "BOTTOMRIGHT", false)

    b.label = b:CreateFontString(nil, "OVERLAY", fontObject or "GameFontHighlightSmall")
    if leftAlign then
        b.label:SetPoint("LEFT", 6, 0)
        b.label:SetJustifyH("LEFT")
    else
        b.label:SetPoint("CENTER")
    end

    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)

    function b:SetLabel(text) self.label:SetText(text) end
    function b:SetSelected(selected)
        if selected then
            self.bg:SetColorTexture(0.22, 0.17, 0.04, 1)
            self.label:SetTextColor(1, 0.82, 0, 1)
        else
            self.bg:SetColorTexture(0.10, 0.10, 0.10, 1)
            self.label:SetTextColor(1, 1, 1, 1)
        end
    end
    return b
end

-- -----------------------------------------------------------------------
-- Category tree. The AH's left-hand menu is a nested tree: each node has a
-- name, a list of filters ({classID, subClassID, inventoryType}) and
-- sub-categories. Blizzard keeps that tree in the global AuctionCategories
-- table once the AH UI is loaded, so the primary path MIRRORS it live --
-- every submenu, exactly as the native tab shows it, and it follows future
-- patches automatically. If that table isn't there, a built-in
-- approximation (from Blizzard's own Enum tables) is used instead.
-- -----------------------------------------------------------------------
local function CopyFilters(filters)
    local out = {}
    if type(filters) == "table" then
        for _, f in ipairs(filters) do
            if type(f) == "table" and f.classID ~= nil then
                table.insert(out, { classID = f.classID, subClassID = f.subClassID, inventoryType = f.inventoryType })
            end
        end
    end
    return out
end

local function ConvertNativeCategory(cat, level, parent)
    if type(cat) ~= "table" then return nil end
    -- The WoW Token entry uses a different query, not itemClassFilters.
    if cat.HasFlag then
        local okFlag, isToken = pcall(cat.HasFlag, cat, "WOW_TOKEN_FLAG")
        if okFlag and isToken then return nil end
    end
    local name = cat.name
    if type(name) == "function" then
        local okName, v = pcall(name, cat)
        name = okName and v or nil
    end
    if type(name) ~= "string" or name == "" then return nil end

    local node = { name = name, level = level, parent = parent, filters = CopyFilters(cat.filters), children = {}, expanded = false }
    if type(cat.subCategories) == "table" then
        for _, sub in ipairs(cat.subCategories) do
            local child = ConvertNativeCategory(sub, level + 1, node)
            if child then table.insert(node.children, child) end
        end
    end
    if #node.filters == 0 and #node.children == 0 then return nil end
    return node
end

local function BuildNativeTree()
    local src = _G.AuctionCategories
    if type(src) ~= "table" then return nil end
    local roots = {}
    for _, cat in ipairs(src) do
        local node = ConvertNativeCategory(cat, 0, nil)
        if node then table.insert(roots, node) end
    end
    if #roots == 0 then return nil end
    return roots
end

local function BuildFallbackTree()
    local IC, IAS, IWS, IT = Enum.ItemClass, Enum.ItemArmorSubclass, Enum.ItemWeaponSubclass, Enum.InventoryType
    local roots = {}

    local function mk(name, level, parent, filters)
        return { name = name, level = level, parent = parent, filters = filters or {}, children = {}, expanded = false }
    end
    local function addChild(parent, child)
        table.insert(parent.children, child)
        return child
    end
    local function flt(classID, sub, inv)
        return { classID = classID, subClassID = sub, inventoryType = inv }
    end
    local function slotLabel(inv, fallback)
        if inv ~= nil and C_Item and C_Item.GetItemInventorySlotInfo then
            local okSlot, n = pcall(C_Item.GetItemInventorySlotInfo, inv)
            if okSlot and type(n) == "string" and n ~= "" then return n end
        end
        return fallback
    end

    -- Weapons, grouped like the native menu.
    if IC and IC.Weapon and IWS then
        local w = mk("Weapons", 0, nil, {})
        table.insert(roots, w)
        local groups = {
            { "One-Handed", { "Axe1H", "Mace1H", "Sword1H", "Warglaive", "Dagger", "Unarmed" } },
            { "Two-Handed", { "Axe2H", "Mace2H", "Sword2H", "Polearm", "Staff" } },
            { "Ranged", { "Bows", "Guns", "Crossbow", "Wand", "Thrown" } },
            { "Miscellaneous", { "Generic", "Fishingpole" } },
        }
        for _, g in ipairs(groups) do
            local gn = mk(g[1], 1, w, {})
            for _, key in ipairs(g[2]) do
                if IWS[key] ~= nil then table.insert(gn.filters, flt(IC.Weapon, IWS[key])) end
            end
            if #gn.filters > 0 then addChild(w, gn) end
        end
    end

    -- Armor: type -> slot.
    if IC and IC.Armor and IAS then
        local a = mk("Armor", 0, nil, {})
        table.insert(roots, a)
        local slots = {
            { "IndexHeadType", "Head" }, { "IndexShoulderType", "Shoulder" },
            { "IndexChestType", "Chest", "IndexRobeType" }, { "IndexWaistType", "Waist" },
            { "IndexLegsType", "Legs" }, { "IndexFeetType", "Feet" },
            { "IndexWristType", "Wrist" }, { "IndexHandType", "Hands" },
        }
        local function addArmorType(label, sub, withCloak)
            if sub == nil then return end
            local t = addChild(a, mk(label, 1, a, { flt(IC.Armor, sub) }))
            for _, s in ipairs(slots) do
                local inv = IT and IT[s[1]]
                if inv ~= nil then
                    local f = { flt(IC.Armor, sub, inv) }
                    if s[3] and IT[s[3]] ~= nil then table.insert(f, flt(IC.Armor, sub, IT[s[3]])) end
                    addChild(t, mk(slotLabel(inv, s[2]), 2, t, f))
                end
            end
            if withCloak and IT and IT.IndexCloakType ~= nil then
                addChild(t, mk(slotLabel(IT.IndexCloakType, "Back"), 2, t, { flt(IC.Armor, sub, IT.IndexCloakType) }))
            end
        end
        addArmorType("Plate", IAS.Plate)
        addArmorType("Mail", IAS.Mail)
        addArmorType("Leather", IAS.Leather)
        addArmorType("Cloth", IAS.Cloth, true)
        if IAS.Generic ~= nil then
            local m = addChild(a, mk("Miscellaneous", 1, a, { flt(IC.Armor, IAS.Generic) }))
            for _, key in ipairs({ "IndexHeadType", "IndexNeckType", "IndexBodyType", "IndexFingerType", "IndexTrinketType", "IndexHoldableType" }) do
                local inv = IT and IT[key]
                if inv ~= nil then addChild(m, mk(slotLabel(inv, key), 2, m, { flt(IC.Armor, IAS.Generic, inv) })) end
            end
        end
        if IAS.Shield ~= nil then addChild(a, mk("Shields", 1, a, { flt(IC.Armor, IAS.Shield) })) end
        if IAS.Cosmetic ~= nil then addChild(a, mk("Cosmetic", 1, a, { flt(IC.Armor, IAS.Cosmetic) })) end
    end

    -- Everything else: one node per item class, with sub-classes as children
    -- (names via Blizzard's GetItemSubClassInfo).
    local function addClassNode(label, ...)
        local classID
        for _, key in ipairs({ ... }) do
            if IC and IC[key] ~= nil then classID = IC[key]; break end
        end
        if classID == nil then return end
        local n = mk(label, 0, nil, { flt(classID) })
        if C_AuctionHouse and C_AuctionHouse.GetAuctionItemSubClasses then
            local okSubs, subs = pcall(C_AuctionHouse.GetAuctionItemSubClasses, classID)
            if okSubs and type(subs) == "table" then
                for _, sub in ipairs(subs) do
                    local nm = GetItemSubClassInfo and GetItemSubClassInfo(classID, sub)
                    if type(nm) == "string" and nm ~= "" then
                        addChild(n, mk(nm, 1, n, { flt(classID, sub) }))
                    end
                end
            end
        end
        table.insert(roots, n)
    end
    addClassNode("Containers", "Container")
    addClassNode("Gems", "Gem")
    addClassNode("Item Enhancements", "ItemEnhancement")
    addClassNode("Consumables", "Consumable")
    addClassNode("Glyphs", "Glyph")
    addClassNode("Trade Goods", "Tradegoods", "TradeGoods")
    addClassNode("Recipes", "Recipe")
    addClassNode("Miscellaneous", "Miscellaneous")
    return roots
end

local function BuildCategoryTree()
    local roots = BuildNativeTree()
    if roots then return roots, "mirrored from Blizzard's own AuctionCategories table" end
    return BuildFallbackTree(), "built-in approximation (Blizzard's AuctionCategories table wasn't found)"
end

-- The filters to actually query for a node: its own if it has any,
-- otherwise the union of its children's.
local function CollectFilters(node, out)
    out = out or {}
    if #node.filters > 0 then
        for _, f in ipairs(node.filters) do table.insert(out, f) end
    else
        for _, c in ipairs(node.children) do CollectFilters(c, out) end
    end
    return out
end

local function NodePath(node)
    local parts = {}
    while node do
        table.insert(parts, 1, node.name)
        node = node.parent
    end
    return table.concat(parts, " > ")
end

-- -----------------------------------------------------------------------
-- Expansions: Blizzard's own localized EXPANSION_NAME<n> globals. The
-- unreleased "Expansion N" placeholders are skipped.
-- -----------------------------------------------------------------------
local function GetExpansionList()
    local list = {}
    local i = 0
    while _G["EXPANSION_NAME" .. i] do
        local name = _G["EXPANSION_NAME" .. i]
        if not name:match("^Expansion %d+$") then
            table.insert(list, { id = i, name = name })
        end
        i = i + 1
    end
    return list
end

-- The current expansion, as Blizzard's own "Current Expansion Only" defines
-- it: the server's live expansion level. GetServerExpansionLevel() returns
-- 0 briefly right after login, so 0 is skipped in favour of the next
-- source; each candidate must also be a real entry in the expansion list.
local function GetCurrentExpansionID()
    local list = GetExpansionList()
    local valid = {}
    for _, e in ipairs(list) do valid[e.id] = true end
    local function usable(v) return type(v) == "number" and v > 0 and valid[v] and v or nil end

    local id
    if GetServerExpansionLevel then id = usable(GetServerExpansionLevel()) end
    if not id then id = usable(_G.LE_EXPANSION_LEVEL_CURRENT) end
    if not id and GetExpansionLevel then id = usable(GetExpansionLevel()) end
    if not id and #list > 0 then id = list[#list].id end
    return id
end
TKAS.GetCurrentExpansionID = GetCurrentExpansionID

-- -----------------------------------------------------------------------
-- Reading browse-result entries without assuming exact field names.
-- -----------------------------------------------------------------------
local function GetItemIDFromEntry(entry)
    if type(entry) ~= "table" then return nil end
    if type(entry.itemID) == "number" then return entry.itemID end
    for _, v in pairs(entry) do
        if type(v) == "table" and type(v.itemID) == "number" then
            return v.itemID
        end
    end
    return nil
end

local function GetItemKeyFromEntry(entry, itemID)
    if type(entry) ~= "table" then return { itemID = itemID } end
    for _, v in pairs(entry) do
        if type(v) == "table" and v.itemID == itemID then
            return v
        end
    end
    return { itemID = itemID }
end

-- -----------------------------------------------------------------------
-- Item data loading. A browse result only carries an item ID; the name,
-- expansion and quality need the client to have the item's data. Rows are
-- HELD BACK until that's ready (so you never see "item 12345"), all
-- requested in one batch, and refreshed the moment data arrives
-- (GET_ITEM_INFO_RECEIVED / ITEM_DATA_LOAD_RESULT / ITEM_KEY_ITEM_INFO_RECEIVED).
-- Some IDs never load (the server returns success=false), so an item is
-- given up on after a failure report or ITEM_LOAD_TIMEOUT seconds and shown
-- with a fallback name instead of hiding forever.
-- -----------------------------------------------------------------------
local ITEM_LOAD_TIMEOUT = 6
local itemWaiting = {} -- itemID -> time it was first seen without data
local itemFailed = {}  -- itemID -> true once the server says it has no data

local pendingRefresh = false
local function RequestRefreshSoon()
    if pendingRefresh then return end
    pendingRefresh = true
    C_Timer.After(0.1, function()
        pendingRefresh = false
        if TKAS.panel and TKAS.panel:IsShown() then
            TKAS.panel.RefreshResults()
        end
    end)
end

local function RequestItemLoad(itemID)
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
    pcall(GetItemInfo, itemID) -- also queries the server for uncached items
end

local function NoteWaiting(itemID)
    if itemWaiting[itemID] == nil then
        itemWaiting[itemID] = GetTime()
        RequestItemLoad(itemID)
    end
end

local function GaveUpOn(itemID)
    if itemFailed[itemID] then return true end
    local since = itemWaiting[itemID]
    return since ~= nil and (GetTime() - since) > ITEM_LOAD_TIMEOUT
end

-- Called from the load events. Returns true if we were waiting on this item.
function TKAS.NoteItemData(itemID, success)
    if itemWaiting[itemID] == nil then return false end
    if success == false then itemFailed[itemID] = true else itemWaiting[itemID] = nil end
    RequestRefreshSoon()
    return true
end

-- -----------------------------------------------------------------------
-- Query + filter
-- -----------------------------------------------------------------------
-- Rarity + "Uncollected Only" are SERVER-side filters: they go in the
-- `filters` list of the browse query, exactly like Blizzard's own Filter
-- dropdown (Enum.AuctionHouseFilter.*). Changing one re-sends the query.
local RARITY_DEFS = {
    { key = "PoorQuality", label = "Poor", q = 0 },
    { key = "CommonQuality", label = "Common", q = 1 },
    { key = "UncommonQuality", label = "Uncommon", q = 2 },
    { key = "RareQuality", label = "Rare", q = 3 },
    { key = "EpicQuality", label = "Epic", q = 4 },
    { key = "LegendaryQuality", label = "Legendary", q = 5 },
    { key = "ArtifactQuality", label = "Artifact", q = 6 },
}

-- Persisted in SavedVariables so your choices survive relogs.
local function FilterState()
    TransmogKitAuctionSourceDB = TransmogKitAuctionSourceDB or {}
    local st = TransmogKitAuctionSourceDB.tkasFilters
    if type(st) ~= "table" then
        st = { uncollected = false, rarities = {} }
        TransmogKitAuctionSourceDB.tkasFilters = st
    end
    st.rarities = st.rarities or {}
    return st
end

-- Sorting. "rarity": Epic first by default (asc=false means high -> low),
-- ties broken cheapest-first. "price": cheapest first by default (asc=true).
-- "ilvl": highest item level first by default (asc=false); items with no item
-- level (consumables, mats...) always sort last. Items whose rarity isn't
-- known yet also sort last. Persisted.
local function SortState()
    TransmogKitAuctionSourceDB = TransmogKitAuctionSourceDB or {}
    local st = TransmogKitAuctionSourceDB.tkasSort
    if type(st) ~= "table" or (st.key ~= "rarity" and st.key ~= "price" and st.key ~= "ilvl") then
        st = { key = "rarity", asc = false }
        TransmogKitAuctionSourceDB.tkasSort = st
    end
    if type(st.asc) ~= "boolean" then st.asc = false end
    return st
end

local function SortEntries(list, key, asc)
    table.sort(list, function(a, b)
        local pa, pb = a.price or math.huge, b.price or math.huge
        local qa, qb = a.quality, b.quality
        if key == "rarity" then
            if qa ~= qb then
                if qa == nil then return false end -- unknown rarity: always last
                if qb == nil then return true end
                if asc then return qa < qb end
                return qa > qb
            end
            if pa ~= pb then return pa < pb end
        elseif key == "ilvl" then
            local la, lb = a.itemLevel, b.itemLevel
            if la ~= lb then
                if la == nil then return false end -- no item level: always last
                if lb == nil then return true end
                if asc then return la < lb end
                return la > lb
            end
            if qa ~= qb then                         -- same level: better rarity first
                if qa == nil then return false end
                if qb == nil then return true end
                return qa > qb
            end
            if pa ~= pb then return pa < pb end      -- then cheapest
        else
            if pa ~= pb then
                if asc then return pa < pb end
                return pa > pb
            end
            if qa ~= qb then
                if qa == nil then return false end
                if qb == nil then return true end
                return qa > qb
            end
        end
        -- Final tie-breaks keep the order fully deterministic (table.sort isn't
        -- stable), so rows never jitter between refreshes. Same item at
        -- different item levels (separate Auction House rows) stay distinct.
        if (a.itemID or 0) ~= (b.itemID or 0) then return (a.itemID or 0) < (b.itemID or 0) end
        return (a.itemLevel or 0) > (b.itemLevel or 0)
    end)
end

function TKAS.WantServerCurrentOnly()
    return TKAS.selectedExpansion ~= nil and TKAS.selectedExpansion == GetCurrentExpansionID()
end

-- No rarity ticked = all rarities (same as Blizzard's default).
local function BuildQueryFilters()
    local F = Enum.AuctionHouseFilter or {}
    local st = FilterState()
    local anyTicked = next(st.rarities) ~= nil
    local list = {}
    for _, def in ipairs(RARITY_DEFS) do
        local v = F[def.key]
        if v ~= nil and (not anyTicked or st.rarities[def.key]) then table.insert(list, v) end
    end
    if st.uncollected and F.UncollectedOnly ~= nil then table.insert(list, F.UncollectedOnly) end
    -- Efficiency: when the current expansion is selected, let the server do
    -- the narrowing (same filter as Blizzard's own "Current Expansion Only"),
    -- so far fewer results have to be downloaded. Other expansions are
    -- filtered on this side.
    if TKAS.WantServerCurrentOnly() and F.CurrentExpansionOnly ~= nil then
        table.insert(list, F.CurrentExpansionOnly)
    end
    return list
end

-- Trim whitespace from typed text.
local function Trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Sends a real browse query: a category (itemClassFilters), a name search
-- (searchString), or both, with the current rarity / uncollected /
-- current-expansion filters. A name search with no category covers every
-- category, same as Blizzard's own search bar.
function TKAS.RunCategoryQuery(itemClassFilters, searchString)
    TKAS.hasQuery = true
    TKAS.lastItemClassFilters = itemClassFilters -- nil for a name-only search
    TKAS.lastSearchString = searchString or ""
    TKAS.lastQueryCurrentOnly = TKAS.WantServerCurrentOnly()
    local query = {
        searchString = TKAS.lastSearchString,
        minLevel = 0,
        maxLevel = 0,
        filters = BuildQueryFilters(),
        itemClassFilters = itemClassFilters or {},
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
    }
    local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, query)
    if not ok then
        LogError("SendBrowseQuery failed: " .. tostring(err))
        return false
    end
    return true
end

-- -----------------------------------------------------------------------
-- Crafting-quality tier icon (Midnight shows silver and gold for the two
-- sellable qualities; older expansions used bronze/silver/gold).
--
-- The tier NUMBER comes from Blizzard's own crafting-quality functions
-- (C_TradeSkillUI.GetItemReagentQualityByItemInfo / ...CraftedQuality...).
-- But which ICON goes with that number differs by expansion and by how many
-- tiers an item has, so it's NOT mapped by number here. Instead, per item,
-- the addon asks Blizzard what it shows, in this order:
--   1. the icon markup Blizzard puts in the item's own link,
--   2. the icon in the item's tooltip data,
--   3. Blizzard's Professions.GetIconForQuality helper,
--   4. last resort: guessed atlas names (Midnight-style first).
-- Every atlas is checked with C_Texture.GetAtlasInfo before use, and if
-- nothing resolves the row gets a small text tag instead of a wrong icon.
-- -----------------------------------------------------------------------
local function GetCraftingQuality(itemID)
    local T = C_TradeSkillUI
    if not T then return nil end
    for _, fnName in ipairs({ "GetItemReagentQualityByItemInfo", "GetItemCraftedQualityByItemInfo" }) do
        local fn = T[fnName]
        if fn then
            local okQ, q = pcall(fn, itemID)
            if okQ and type(q) == "number" and q > 0 then return q end
        end
    end
    return nil
end

local function AtlasExists(name)
    if type(name) ~= "string" or name == "" then return false end
    if C_Texture and C_Texture.GetAtlasInfo then return C_Texture.GetAtlasInfo(name) ~= nil end
    return true
end

-- Pull a crafting-quality atlas name out of text that contains |A:name:w:h|a markup.
local function FindQualityAtlasInText(text)
    if type(text) ~= "string" then return nil end
    for atlas in text:gmatch("|A:([^:|]+):") do
        if atlas:lower():find("quality", 1, true) and AtlasExists(atlas) then return atlas end
    end
    return nil
end

local function AtlasFromItemLink(itemID)
    local okI, link = pcall(function() return (select(2, GetItemInfo(itemID))) end)
    if okI then return FindQualityAtlasInText(link) end
end

local function AtlasFromTooltip(itemID)
    if not (C_TooltipInfo and C_TooltipInfo.GetItemByID) then return nil end
    local okT, data = pcall(C_TooltipInfo.GetItemByID, itemID)
    if not okT or type(data) ~= "table" or type(data.lines) ~= "table" then return nil end
    for _, line in ipairs(data.lines) do
        local a = FindQualityAtlasInText(line.leftText) or FindQualityAtlasInText(line.rightText)
        if a then return a end
    end
end

local professionsLoadTried = false
local function AtlasFromProfessionsHelper(quality)
    if not (Professions and Professions.GetIconForQuality) and not professionsLoadTried then
        professionsLoadTried = true
        local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if load then pcall(load, "Blizzard_Professions") end
    end
    if Professions and Professions.GetIconForQuality then
        local okP, atlas = pcall(Professions.GetIconForQuality, quality, true)
        if okP and AtlasExists(atlas) then return atlas end
    end
end

local function AtlasFromGuess(quality)
    local candidates = {
        "Professions-Icon-Quality-12-Tier" .. quality .. "-Small",
        "Professions-ChatIcon-Quality-12-Tier" .. quality,
        "Professions-Icon-Quality-12-Tier" .. quality,
        "Professions-Icon-Quality-Tier" .. quality .. "-Small",
        "Professions-ChatIcon-Quality-Tier" .. quality,
    }
    for _, name in ipairs(candidates) do
        if AtlasExists(name) then return name end
    end
end

-- Positive results are cached per item; misses are retried after a while
-- (item/tooltip data may simply not have loaded yet).
local qualityIconCache = {}
local function ResolveQualityAtlas(itemID, quality)
    local cached = qualityIconCache[itemID]
    if cached then
        if cached.atlas then return cached.atlas, cached.source end
        if GetTime() < cached.retryAt then return nil end
    end
    local stages = {
        { "item link", function() return AtlasFromItemLink(itemID) end },
        { "tooltip", function() return AtlasFromTooltip(itemID) end },
        { "Blizzard Professions helper", function() return AtlasFromProfessionsHelper(quality) end },
        { "guessed name", function() return AtlasFromGuess(quality) end },
    }
    for _, stage in ipairs(stages) do
        local atlas = stage[2]()
        if atlas then
            qualityIconCache[itemID] = { atlas = atlas, source = stage[1] }
            return atlas, stage[1]
        end
    end
    qualityIconCache[itemID] = { retryAt = GetTime() + 10 }
    return nil
end

local function CraftingQualityMarkup(quality, atlas)
    if not quality then return "" end
    if atlas then
        if CreateAtlasMarkup then return " " .. CreateAtlasMarkup(atlas, 16, 16) end
        return (" |A:%s:16:16|a"):format(atlas)
    end
    return " |cffaaaaaa[T" .. quality .. "]|r"
end

local function GetFilteredBrowseResults(selectedExpansion, nameFilter)
    local ok, browseResults = pcall(C_AuctionHouse.GetBrowseResults)
    if not ok or not browseResults then
        return {}, "Couldn't read Browse results (" .. tostring(browseResults) .. ")", 0
    end

    local needle = nameFilter and nameFilter ~= "" and nameFilter:lower() or nil
    local needExpansion = selectedExpansion ~= nil
    local out, pending = {}, 0
    for _, entry in ipairs(browseResults) do
        local itemID = GetItemIDFromEntry(entry)
        if itemID then
            local itemName, _, itemQuality, _, _, _, _, _, _, _, _, _, _, _, expansionID = GetItemInfo(itemID)
            local itemKey = GetItemKeyFromEntry(entry, itemID)
            local name = itemName
            local quality = itemQuality
            if name then
                itemWaiting[itemID] = nil -- loaded
            else
                -- The AH's own item-key info also carries the name (and
                -- asking for it starts that load too).
                local okKey, keyInfo = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
                if okKey and type(keyInfo) == "table" then name = keyInfo.itemName; quality = keyInfo.quality end
                NoteWaiting(itemID)
            end

            local gaveUp = GaveUpOn(itemID)
            -- Filtering by expansion needs the full item data; otherwise a
            -- name from either source is enough to show the row.
            local ready
            if needExpansion then ready = (itemName ~= nil) or gaveUp else ready = (name ~= nil) or gaveUp end

            if not ready then
                pending = pending + 1
            elseif not needExpansion or expansionID == selectedExpansion then
                local displayName = name or entry.name or ("item " .. itemID)
                if not needle or displayName:lower():find(needle, 1, true) then
                    -- Blizzard groups gear by item ID *and* item level, so each browse
                    -- row's item key already says which level it is (0 = not gear).
                    local itemLevel = type(itemKey) == "table" and itemKey.itemLevel or nil
                    if type(itemLevel) ~= "number" or itemLevel <= 0 then itemLevel = nil end
                    table.insert(out, {
                        itemID = itemID,
                        itemLevel = itemLevel,
                        itemKey = itemKey,
                        raw = entry, -- the untouched entry Blizzard's own SelectBrowseResult expects
                        name = displayName,
                        price = entry.minPrice or entry.unitPrice or entry.buyoutAmount,
                        quantity = entry.totalQuantity or entry.quantity or 1,
                        expansionID = expansionID,
                        quality = quality,
                    })
                end
            end
        end
    end
    local sortState = SortState()
    SortEntries(out, sortState.key, sortState.asc)
    return out, nil, pending
end

-- Open the real buy page for an entry, exactly as Blizzard's own browse
-- rows do. Falls back to the search box if that method is missing/errors.
function TKAS.OpenBuyPage(entry)
    if entry.raw and AuctionHouseFrame and AuctionHouseFrame.SelectBrowseResult then
        local ok, err = pcall(AuctionHouseFrame.SelectBrowseResult, AuctionHouseFrame, entry.raw)
        if ok then
            -- Remember we came from the Expansions tab so Blizzard's Back
            -- button can return here (see TKAS.OnNativeBack).
            TKAS.returnToPanel = BackReturnEnabled()
            if TKAS.panel then TKAS.panel:Hide() end
            -- The buy-page frames may not have existed when the panel was
            -- built, so (re)hook their Back buttons now.
            C_Timer.After(0, function() TKAS.HookNativeBackButtons() end)
            return true
        end
        LogError("Opening the buy page failed (" .. tostring(err) .. "); falling back to a name search.")
    end
    local searchBar = AuctionHouseFrame and AuctionHouseFrame.SearchBar
    if searchBar and searchBar.SearchBox then
        searchBar.SearchBox:SetText(entry.name or "")
        if searchBar.SearchButton then searchBar.SearchButton:Click() end
        if TKAS.panel then TKAS.panel:Hide() end
        return true
    end
    LogError("Couldn't open the buy page or find the AH search box.")
    return false
end

-- -----------------------------------------------------------------------
-- Finding Blizzard's real "Auctions" tab so ours sits right after it.
-- -----------------------------------------------------------------------
local function GetFrameText(f)
    if f.GetText then
        local ok, t = pcall(f.GetText, f)
        if ok and type(t) == "string" and t ~= "" then return t end
    end
    -- Some frames keep their label in a .Text child. Guarded end to end: a
    -- frame whose .Text isn't a text object must be skipped, never error.
    local textObj = f.Text
    if textObj then
        local okT, t = pcall(function() return textObj:GetText() end)
        if okT and type(t) == "string" and t ~= "" then return t end
    end
    return nil
end

local function CollectFramesByText(root, wanted, out, depth, seen)
    if depth > 5 or seen[root] then return end
    seen[root] = true
    if root ~= AuctionHouseFrame then
        local t = GetFrameText(root)
        if t and wanted[t] then table.insert(out, root) end
    end
    if root.GetChildren then
        for _, child in ipairs({ root:GetChildren() }) do
            CollectFramesByText(child, wanted, out, depth + 1, seen)
        end
    end
end

local function FindAuctionsTab()
    -- Blizzard exposes it directly as AuctionHouseFrame.AuctionsTab.
    if AuctionHouseFrame.AuctionsTab then return AuctionHouseFrame.AuctionsTab end
    local wanted = { ["Auctions"] = true }
    if type(_G.AUCTIONS) == "string" then wanted[_G.AUCTIONS] = true end
    local matches = {}
    CollectFramesByText(AuctionHouseFrame, wanted, matches, 0, {})
    local best, bestBottom
    for _, f in ipairs(matches) do
        local b = f.GetBottom and f:GetBottom()
        if b and (not bestBottom or b < bestBottom) then best, bestBottom = f, b end
    end
    return best
end

-- -----------------------------------------------------------------------
-- Blizzard's own "Back" button on the buy page. It's hooked (HookScript, so
-- Blizzard's own handler still runs first); if the buy page was opened from
-- our tab, we then bring our tab back over the Browse view. Found by its
-- label, plus the ItemBuyFrame / CommoditiesBuyFrame BackButton keys.
-- -----------------------------------------------------------------------
local hookedBackButtons = {}
function TKAS.HookNativeBackButtons()
    if not AuctionHouseFrame then return end
    local wanted = { ["Back"] = true }
    if type(_G.BACK) == "string" then wanted[_G.BACK] = true end
    local found = {}
    CollectFramesByText(AuctionHouseFrame, wanted, found, 0, {})
    for _, key in ipairs({ "ItemBuyFrame", "CommoditiesBuyFrame" }) do
        local f = AuctionHouseFrame[key]
        if type(f) == "table" and f.BackButton then table.insert(found, f.BackButton) end
    end
    for _, btn in ipairs(found) do
        if not hookedBackButtons[btn] and btn.HookScript and btn.GetObjectType and btn:GetObjectType() == "Button" then
            hookedBackButtons[btn] = true
            pcall(btn.HookScript, btn, "OnClick", function() TKAS.OnNativeBack() end)
        end
    end
end

function TKAS.OnNativeBack()
    if not TKAS.returnToPanel then return end -- opened some other way: leave Back alone
    TKAS.returnToPanel = false
    C_Timer.After(0, function()
        if not (IsEnabled() and AuctionHouseFrame and AuctionHouseFrame:IsShown() and TKAS.panel) then return end
        TKAS.panel:Show() -- category, filters and scroll position are still as you left them
        -- Safety net: if Blizzard cleared its browse results on the way
        -- back, re-send our last query so the list isn't empty.
        C_Timer.After(0.5, function()
            if not (TKAS.panel and TKAS.panel:IsShown() and TKAS.hasQuery) then return end
            local okR, res = pcall(C_AuctionHouse.GetBrowseResults)
            if okR and type(res) == "table" and #res == 0 then
                TKAS.RunCategoryQuery(TKAS.lastItemClassFilters, TKAS.lastSearchString)
            end
        end)
    end)
end

-- -----------------------------------------------------------------------
-- UI
-- -----------------------------------------------------------------------
function TKAS.InjectPanel()
    if not IsEnabled() then return end
    if TKAS.tabButton then
        TKAS.tabButton:Show()
        return
    end
    if not AuctionHouseFrame then return end

    ---------------------------------------------------------------- tab
    local auctionsTab = FindAuctionsTab()
    local tabW = auctionsTab and auctionsTab.GetWidth and auctionsTab:GetWidth() or 0
    local tabH = auctionsTab and auctionsTab.GetHeight and auctionsTab:GetHeight() or 0
    local tabButton = MakeFlatButton(AuctionHouseFrame, math.max(tabW, 90), math.max(tabH, 26), false, "GameFontHighlight")
    tabButton:SetLabel("Expansions")
    if auctionsTab then
        tabButton:SetPoint("LEFT", auctionsTab, "RIGHT", 4, 0)
    else
        tabButton:SetPoint("TOPLEFT", AuctionHouseFrame, "BOTTOMLEFT", 300, 2)
        Log("Couldn't find Blizzard's Auctions tab -- run /tkauction tabs and send me what prints.")
    end

    ---------------------------------------------------------------- panel
    -- Covers the whole interior (below the title bar), including the
    -- native search bar and bottom bar, so nothing of the Buy tab shows.
    local panel = CreateFrame("Frame", "TransmogKitExpansionPanel", AuctionHouseFrame)
    panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", 6, -32)
    panel:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -6, 6)
    panel:SetFrameStrata("DIALOG")
    panel:EnableMouse(true)
    local panelBg = panel:CreateTexture(nil, "BACKGROUND")
    panelBg:SetAllPoints()
    panelBg:SetColorTexture(0.05, 0.05, 0.05, 1)
    panel:Hide()

    tabButton:SetScript("OnClick", function()
        panel:SetShown(not panel:IsShown())
    end)

    -- Clicking any of Blizzard's own tabs switches away from ours.
    if auctionsTab and auctionsTab.GetParent then
        local tabParent = auctionsTab:GetParent()
        if tabParent and tabParent.GetChildren then
            for _, sibling in ipairs({ tabParent:GetChildren() }) do
                if sibling ~= tabButton and sibling.HookScript and sibling.GetObjectType
                    and sibling:GetObjectType() == "Button" then
                    pcall(sibling.HookScript, sibling, "OnClick", function() panel:Hide(); TKAS.returnToPanel = false end)
                end
            end
        end
    end

    ---------------------------------------------------------------- bottom bar
    local bottomBar = CreateFrame("Frame", nil, panel)
    bottomBar:SetPoint("BOTTOMLEFT", 0, 0)
    bottomBar:SetPoint("BOTTOMRIGHT", 0, 0)
    bottomBar:SetHeight(32)
    local barBg = bottomBar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0.08, 0.08, 0.08, 1)

    local moneyText = bottomBar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    moneyText:SetPoint("LEFT", 14, 0)
    function panel.UpdateMoney()
        moneyText:SetText(GetCoinTextureString(GetMoney() or 0))
    end

    local hintText = bottomBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintText:SetPoint("RIGHT", -14, 0)
    hintText:SetText("Click: open buy page   |   Ctrl-click: preview   |   Shift-click: link to chat")

    ---------------------------------------------------------------- categories
    local catPanel = CreateFrame("Frame", nil, panel)
    catPanel:SetPoint("TOPLEFT", 8, -8)
    catPanel:SetPoint("BOTTOMLEFT", 8, 40)
    catPanel:SetWidth(170)
    local catScroll = CreateFrame("ScrollFrame", nil, catPanel, "UIPanelScrollFrameTemplate")
    catScroll:SetPoint("TOPLEFT")
    catScroll:SetPoint("BOTTOMRIGHT", -22, 0)
    local catContent = CreateFrame("Frame", nil, catScroll)
    catContent:SetSize(146, 1)
    catScroll:SetScrollChild(catContent)

    ---------------------------------------------------------------- right area
    local right = CreateFrame("Frame", nil, panel)
    right:SetPoint("TOPLEFT", catPanel, "TOPRIGHT", 10, 0)
    right:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 40)

    local nameLabel = right:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameLabel:SetPoint("LEFT", right, "TOPLEFT", 2, -15) -- same vertical centre as the buttons
    nameLabel:SetText("Name:")

    local nameBox = CreateFrame("EditBox", nil, right, "InputBoxTemplate")
    nameBox:SetSize(150, 20)
    nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 12, 0)
    nameBox:SetAutoFocus(false)
    nameBox:SetScript("OnEscapePressed", nameBox.ClearFocus)
    nameBox:SetScript("OnEnterPressed", nameBox.ClearFocus)

    local expStrip = CreateFrame("Frame", nil, right)
    expStrip:SetPoint("TOPLEFT", 0, -34)
    expStrip:SetPoint("TOPRIGHT", 0, -34)
    expStrip:SetHeight(1) -- spacer only; the expansion picker is now a dropdown in the top row

    local statusText = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    statusText:SetPoint("TOPLEFT", expStrip, "BOTTOMLEFT", 2, -6)
    statusText:SetPoint("RIGHT", 0, 0)
    statusText:SetJustifyH("LEFT")
    statusText:SetText("Pick a category on the left, or type a name and press Enter.")

    -- Column geometry shared by the header and the rows, so they can't drift
    -- apart. The rows live inside the scroll list, which stops RESULTS_GUTTER
    -- short of the header bar's right edge (room for the scrollbar), so the
    -- header has to add that gutter back to land on the same spot as the rows.
    local RESULTS_GUTTER = 22
    local RARITY_COLUMN_X = 198 -- distance from the list's right edge to where the rarity text starts
    local ILVL_COLUMN_X = 122   -- same, for the item-level text (sits between Rarity and Available)

    local headerRow = CreateFrame("Frame", nil, right)
    headerRow:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", -2, -6)
    headerRow:SetPoint("TOPRIGHT", 0, 0)
    headerRow:SetHeight(22)
    local headerBg = headerRow:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetColorTexture(0.10, 0.10, 0.10, 1)
    -- Price, Rarity and iLvl headers are buttons: click to sort by that column,
    -- click again to flip the order. The active one shows ^ (ascending) or
    -- v (descending). Name and Available are plain labels.
    local function MakeHeaderButton(label, sortKey, relPoint, x)
        local btn = CreateFrame("Button", nil, headerRow)
        btn:SetHeight(22)
        btn:SetNormalFontObject("GameFontNormalSmall")
        btn:SetHighlightFontObject("GameFontHighlightSmall")
        btn.label = label
        btn.sortKey = sortKey
        btn:SetPoint("LEFT", headerRow, relPoint, x, 0)
        btn:SetText(label)
        local fs = btn:GetFontString()
        if fs then
            fs:ClearAllPoints()
            fs:SetPoint("LEFT", btn, "LEFT", 0, 0)
            fs:SetJustifyH("LEFT")
        end
        return btn
    end
    local priceHeader = MakeHeaderButton("Price", "price", "LEFT", 8)
    local nameHeader = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameHeader:SetPoint("LEFT", 118, 0)
    nameHeader:SetText("Name")
    local rarityHeader = MakeHeaderButton("Rarity", "rarity", "RIGHT", -(RARITY_COLUMN_X + RESULTS_GUTTER))
    local ilvlHeader = MakeHeaderButton("iLvl", "ilvl", "RIGHT", -(ILVL_COLUMN_X + RESULTS_GUTTER))
    local availHeader = headerRow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    availHeader:SetPoint("RIGHT", -36, 0)
    availHeader:SetText("Available")

    local function RefreshSortHeaders()
        local st = SortState()
        for _, btn in ipairs({ priceHeader, rarityHeader, ilvlHeader }) do
            local text = btn.label
            if st.key == btn.sortKey then text = text .. (st.asc and " ^" or " v") end
            btn:SetText(text)
            local w = btn:GetTextWidth()
            btn:SetWidth(math.max(44, (type(w) == "number" and w or 40) + 10))
        end
    end
    panel.RefreshSortHeaders = RefreshSortHeaders
    RefreshSortHeaders()

    local resultsScroll = CreateFrame("ScrollFrame", nil, right, "UIPanelScrollFrameTemplate")
    resultsScroll:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -2)
    resultsScroll:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", -RESULTS_GUTTER, 0)
    local resultsContent = CreateFrame("Frame", nil, resultsScroll)
    -- IMPORTANT: this must track the scroll frame's real width. Rows
    -- stretch to this frame's width; it was previously left at 1px, which
    -- made every row a 1px-wide click target.
    resultsContent:SetSize(math.max(1, AuctionHouseFrame:GetWidth() - 260), 1)
    resultsScroll:SetScrollChild(resultsContent)
    resultsScroll:SetScript("OnSizeChanged", function(_, w)
        if w and w > 1 then resultsContent:SetWidth(w) end
        if panel.UpdateVisibleRows then panel.UpdateVisibleRows() end
    end)
    panel.resultRows = {}

    local function DefaultExpansion()
        if StartOnCurrentEnabled() then return GetCurrentExpansionID() end
        return nil
    end
    panel.selectedExpansion = DefaultExpansion()
    TKAS.selectedExpansion = panel.selectedExpansion
    panel.selectedCategory = nil
    panel.nameFilter = ""

    panel.serverSearchText = "" -- the text the Auction House itself last searched for

    nameBox:SetScript("OnTextChanged", function(self)
        panel.nameFilter = self:GetText() or ""
        panel.RefreshResults()
    end)

    -- Enter = a real search. Typing alone only narrows results that are
    -- already loaded (there's nothing loaded until a category or a search
    -- has been sent, which is why Enter used to appear to do nothing).
    function panel.RunNameSearch()
        local text = Trim(panel.nameFilter)
        panel.serverSearchText = text
        local filters = panel.selectedNode and CollectFilters(panel.selectedNode) or nil
        if filters and #filters == 0 then filters = nil end

        panel.lastSig = nil
        panel.entries = {}
        resultsScroll:SetVerticalScroll(0)
        if panel.HidePopups then panel.HidePopups() end
        for _, row in ipairs(panel.resultRows) do row:Hide() end

        if text == "" and not filters then
            -- nothing to search for
            TKAS.hasQuery = false
            TKAS.lastItemClassFilters = nil
            TKAS.lastSearchString = ""
            resultsContent:SetHeight(1)
            statusText:SetText("Pick a category on the left, or type a name and press Enter.")
            return
        end
        if text ~= "" then
            statusText:SetText(("Searching for '%s'%s..."):format(text,
                panel.selectedCategoryName and (" in '" .. panel.selectedCategoryName .. "'") or ""))
        else
            statusText:SetText(("Loading '%s'..."):format(panel.selectedCategoryName or ""))
        end
        TKAS.RunCategoryQuery(filters, text)
    end
    nameBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        panel.RunNameSearch()
    end)

    ---------------------------------------------------------------- uncollected + rarity
    local function ReloadForFilterChange()
        panel.lastSig = nil
        panel.entries = {}
        resultsScroll:SetVerticalScroll(0)
        if panel.HidePopups then panel.HidePopups() end
        if TKAS.hasQuery then
            for _, row in ipairs(panel.resultRows) do row:Hide() end
            statusText:SetText("Reloading with the new filters...")
            TKAS.RunCategoryQuery(TKAS.lastItemClassFilters, TKAS.lastSearchString)
        else
            statusText:SetText("Filters set -- pick a category, or type a name and press Enter.")
        end
    end

    local function AddBorder(frame)
        local function line(p1, p2, horizontal)
            local t = frame:CreateTexture(nil, "BORDER")
            t:SetColorTexture(0.30, 0.30, 0.30, 1)
            t:SetPoint(p1)
            t:SetPoint(p2)
            if horizontal then t:SetHeight(1) else t:SetWidth(1) end
        end
        line("TOPLEFT", "TOPRIGHT", true)
        line("BOTTOMLEFT", "BOTTOMRIGHT", true)
        line("TOPLEFT", "BOTTOMLEFT", false)
        line("TOPRIGHT", "BOTTOMRIGHT", false)
    end

    panel.ReloadForFilterChange = ReloadForFilterChange

    -- Uncollected Only: a toggle button.
    local uncollectedBtn = MakeFlatButton(right, 118, 22) -- anchored below, once the buttons to its right exist
    uncollectedBtn:SetLabel("Uncollected Only")
    uncollectedBtn:SetSelected(FilterState().uncollected and true or false)
    uncollectedBtn:SetScript("OnClick", function()
        local F = Enum.AuctionHouseFilter
        if not (F and F.UncollectedOnly ~= nil) then
            LogError("This client has no Enum.AuctionHouseFilter.UncollectedOnly -- run /tkauction filters to see what it does have.")
            return
        end
        local st = FilterState()
        st.uncollected = not st.uncollected
        uncollectedBtn:SetSelected(st.uncollected)
        ReloadForFilterChange()
    end)

    -- Rarity: a collapsing multi-select menu.
    local F = Enum.AuctionHouseFilter or {}
    local rarityDefs = {}
    for _, def in ipairs(RARITY_DEFS) do
        if F[def.key] ~= nil then table.insert(rarityDefs, def) end
    end

    local rarityBtn = MakeFlatButton(right, 130, 22)

    local rarityPopup = CreateFrame("Frame", nil, panel)
    rarityPopup:SetFrameStrata("DIALOG")
    rarityPopup:SetFrameLevel(panel:GetFrameLevel() + 30)
    rarityPopup:SetSize(170, (#rarityDefs + 1) * 24 + 8)
    rarityPopup:SetPoint("TOPLEFT", rarityBtn, "BOTTOMLEFT", 0, -2)
    rarityPopup:EnableMouse(true)
    local rarityBg = rarityPopup:CreateTexture(nil, "BACKGROUND")
    rarityBg:SetAllPoints()
    rarityBg:SetColorTexture(0.07, 0.07, 0.07, 1)
    AddBorder(rarityPopup)
    rarityPopup:Hide()
    panel.rarityPopup = rarityPopup
    function panel.HidePopups() rarityPopup:Hide() end -- widened below once the expansion dropdown exists

    local rarityRows = {}
    local function RefreshRarityUI()
        local st = FilterState()
        local names = {}
        for i, def in ipairs(rarityDefs) do
            local on = st.rarities[def.key] and true or false
            if on then table.insert(names, def.label) end
            local hex = (ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[def.q] and ITEM_QUALITY_COLORS[def.q].hex) or "|cffffffff"
            rarityRows[i]:SetLabel((on and "[x] " or "[ ] ") .. hex .. def.label .. "|r")
            rarityRows[i]:SetSelected(on)
        end
        local summary
        if #names == 0 then summary = "All"
        elseif #names == 1 then summary = names[1]
        else summary = #names .. " selected" end
        rarityBtn:SetLabel("Rarity: " .. summary .. "  v")
    end

    for i, def in ipairs(rarityDefs) do
        local row = MakeFlatButton(rarityPopup, 158, 22, true)
        row:SetPoint("TOPLEFT", 6, -4 - (i - 1) * 24)
        row:SetScript("OnClick", function()
            local st = FilterState()
            if st.rarities[def.key] then st.rarities[def.key] = nil else st.rarities[def.key] = true end
            RefreshRarityUI()
            ReloadForFilterChange() -- keeps the menu open so you can tick several
            rarityPopup:Show()
        end)
        rarityRows[i] = row
    end
    local clearRow = MakeFlatButton(rarityPopup, 158, 22, true)
    clearRow:SetPoint("TOPLEFT", 6, -4 - #rarityDefs * 24)
    clearRow:SetLabel("Clear (all rarities)")
    clearRow:SetScript("OnClick", function()
        FilterState().rarities = {}
        RefreshRarityUI()
        ReloadForFilterChange()
        rarityPopup:Show()
    end)

    rarityBtn:SetScript("OnClick", function()
        if panel.expansionPopup then panel.expansionPopup:Hide() end -- one dropdown open at a time
        rarityPopup:SetShown(not rarityPopup:IsShown())
    end)
    RefreshRarityUI()

    -- Expansion: a single-choice collapsing menu. Unlike Rarity it closes as
    -- soon as you pick one. The current expansion is tagged "(current)".
    local expBtn = MakeFlatButton(right, 160, 22)

    -- Top row is anchored from the RIGHT edge inwards, so it always fits:
    -- the Name box is the flexible one and absorbs whatever room is left.
    expBtn:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, -4)
    rarityBtn:SetPoint("RIGHT", expBtn, "LEFT", -6, 0)
    uncollectedBtn:SetPoint("RIGHT", rarityBtn, "LEFT", -6, 0)
    nameBox:SetPoint("RIGHT", uncollectedBtn, "LEFT", -14, 0)

    local expEntries = { { id = nil, name = "All expansions" } }
    for _, e in ipairs(GetExpansionList()) do table.insert(expEntries, e) end

    local expPopup = CreateFrame("Frame", nil, panel)
    expPopup:SetFrameStrata("DIALOG")
    expPopup:SetFrameLevel(panel:GetFrameLevel() + 30)
    expPopup:SetSize(220, #expEntries * 24 + 8)
    -- anchored to the button's right edge so it can't run off the panel
    expPopup:SetPoint("TOPRIGHT", expBtn, "BOTTOMRIGHT", 0, -2)
    expPopup:EnableMouse(true)
    local expBg = expPopup:CreateTexture(nil, "BACKGROUND")
    expBg:SetAllPoints()
    expBg:SetColorTexture(0.07, 0.07, 0.07, 1)
    AddBorder(expPopup)
    expPopup:Hide()
    panel.expansionPopup = expPopup
    function panel.HidePopups() rarityPopup:Hide(); expPopup:Hide() end

    local expRows = {}
    local function RefreshExpansionUI()
        local currentID = GetCurrentExpansionID()
        local buttonName = "All"
        for i, entry in ipairs(expEntries) do
            local selected = (entry.id == panel.selectedExpansion)
            local text = (selected and "> " or "  ") .. entry.name
            if entry.id ~= nil and entry.id == currentID then text = text .. "  |cff888888(current)|r" end
            expRows[i]:SetLabel(text)
            expRows[i]:SetSelected(selected)
            if selected then buttonName = (entry.id == nil) and "All" or entry.name end
        end
        expBtn:SetLabel("Expansion: " .. buttonName .. "  v")
        expBtn:SetWidth(math.min(200, math.max(130, expBtn.label:GetStringWidth() + 24)))
    end

    for i, entry in ipairs(expEntries) do
        local row = MakeFlatButton(expPopup, 208, 22, true)
        row:SetPoint("TOPLEFT", 6, -4 - (i - 1) * 24)
        row:SetScript("OnClick", function()
            expPopup:Hide()
            panel.selectedExpansion = entry.id
            TKAS.selectedExpansion = entry.id
            RefreshExpansionUI()
            -- Moving to/from the current expansion changes what the server
            -- should send, so reload; otherwise just re-filter what's loaded.
            if TKAS.hasQuery and TKAS.WantServerCurrentOnly() ~= TKAS.lastQueryCurrentOnly
                and panel.ReloadForFilterChange then
                panel.ReloadForFilterChange()
            else
                panel.RefreshResults()
            end
        end)
        expRows[i] = row
    end

    expBtn:SetScript("OnClick", function()
        rarityPopup:Hide() -- one dropdown open at a time
        expPopup:SetShown(not expPopup:IsShown())
    end)
    RefreshExpansionUI()

    ---------------------------------------------------------------- category tree
    -- Collapsible, like the native menu: clicking a node selects it (loads
    -- its whole category) and expands its sub-menu; clicking the selected,
    -- expanded node again collapses it. Opening one node closes its siblings.
    local catRows = {}
    local roots, treeSource = BuildCategoryTree()
    Log("Categories: " .. treeSource .. ".")
    local RenderCategoryTree

    local function OnCategoryClick(node)
        if panel.HidePopups then panel.HidePopups() end
        if #node.children > 0 then
            if node.expanded and panel.selectedNode == node then
                node.expanded = false
            else
                local siblings = node.parent and node.parent.children or roots
                for _, sib in ipairs(siblings) do
                    if sib ~= node then sib.expanded = false end
                end
                node.expanded = true
            end
        end
        panel.selectedNode = node
        panel.selectedCategoryName = NodePath(node)
        panel.lastSig = nil
        panel.entries = {}
        resultsScroll:SetVerticalScroll(0)
        RenderCategoryTree()

        local filters = CollectFilters(node)
        if #filters == 0 then
            statusText:SetText(("Nothing to load for '%s'."):format(node.name))
            return
        end
        for _, row in ipairs(panel.resultRows) do row:Hide() end
        statusText:SetText(("Loading '%s'..."):format(panel.selectedCategoryName))
        TKAS.RunCategoryQuery(filters, panel.serverSearchText)
    end

    RenderCategoryTree = function()
        local visible = {}
        local function walk(nodes)
            for _, n in ipairs(nodes) do
                table.insert(visible, n)
                if n.expanded and #n.children > 0 then walk(n.children) end
            end
        end
        walk(roots)

        for i, node in ipairs(visible) do
            local row = catRows[i]
            if not row then
                row = MakeFlatButton(catContent, 146, 22, true)
                catRows[i] = row
            end
            local indent = node.level * 12
            row:SetWidth(146 - indent)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", indent, -(i - 1) * 24)
            local marker = ""
            if #node.children > 0 then marker = node.expanded and "- " or "+ " end
            row:SetLabel(marker .. node.name)
            local selected = (panel.selectedNode == node)
            row:SetSelected(selected)
            if not selected and node.level >= 2 then row.label:SetTextColor(0.75, 0.75, 0.75, 1) end
            row.node = node
            row:SetScript("OnClick", function(self) OnCategoryClick(self.node) end)
            row:Show()
        end
        for i = #visible + 1, #catRows do catRows[i]:Hide() end
        catContent:SetHeight(math.max(1, #visible * 24))
    end
    RenderCategoryTree()

    -- Fresh start for a new AH visit: Blizzard clears its browse results
    -- when the AH closes, so drop the stale selection instead of showing
    -- "0 items in <last category>".
    function panel.ResetSelection()
        panel.selectedNode = nil
        panel.selectedCategoryName = nil
        panel.lastSig = nil
        TKAS.lastItemClassFilters = nil
        TKAS.hasQuery = false
        TKAS.lastSearchString = ""
        panel.serverSearchText = ""
        panel.nameFilter = ""
        nameBox:SetText("")
        panel.selectedExpansion = DefaultExpansion()
        TKAS.selectedExpansion = panel.selectedExpansion
        RefreshExpansionUI()
        panel.entries = {}
        resultsScroll:SetVerticalScroll(0)
        resultsContent:SetHeight(1)
        for _, row in ipairs(panel.resultRows) do row:Hide() end
        RenderCategoryTree()
        statusText:SetText("Pick a category on the left, or type a name and press Enter.")
    end

    ---------------------------------------------------------------- results
    -- Virtualized: only the rows that fit on screen exist. Scrolling just
    -- re-fills that small pool, so a category with thousands of items stays
    -- fast instead of creating thousands of frames.
    local GetInstantInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local ROW_H = 24
    panel.entries = {}

    local function CreateRow()
        local row = CreateFrame("Button", nil, resultsContent)
        row:SetHeight(ROW_H)
        row:RegisterForClicks("LeftButtonUp")

        row.hl = row:CreateTexture(nil, "HIGHLIGHT")
        row.hl:SetAllPoints()
        row.hl:SetColorTexture(1, 1, 1, 0.08)

        row.price = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.price:SetPoint("LEFT", 8, 0)
        row.price:SetWidth(104)
        row.price:SetJustifyH("LEFT")

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", 118, 0)

        row.ilvl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.ilvl:SetPoint("LEFT", row, "RIGHT", -ILVL_COLUMN_X, 0)
        row.ilvl:SetWidth(40)
        row.ilvl:SetJustifyH("LEFT")

        row.rarity = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.rarity:SetPoint("LEFT", row, "RIGHT", -RARITY_COLUMN_X, 0)
        row.rarity:SetWidth(66)
        row.rarity:SetJustifyH("LEFT")

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
        row.name:SetPoint("RIGHT", row.rarity, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false) -- long names are cut off rather than running into the Rarity column

        row.avail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.avail:SetPoint("RIGHT", -44, 0)

        row:SetScript("OnEnter", function(self)
            if not self.link then return end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
            GameTooltip:SetHyperlink(self.link)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cff888888Click: open buy page  |  Ctrl-click: preview|r")
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row:SetScript("OnClick", function(self)
            local link = self.link
            -- Blizzard's own modified-click handler: ctrl = dressing room,
            -- shift = chat link, etc. Returns true if it handled the click.
            if link and HandleModifiedItemClick and HandleModifiedItemClick(link) then
                return
            end
            -- Fallback for ctrl-click preview if that handler is missing.
            if link and IsControlKeyDown() then
                local dress = DressUpItemLink or DressUpLink
                if dress then dress(link); return end
            end
            if self.entry then TKAS.OpenBuyPage(self.entry) end
        end)
        return row
    end

    -- Fill one row from its entry. Runs for visible rows only, and re-runs
    -- on every refresh, so late-arriving data (expansion tag, tier icon,
    -- quality colour) shows up without any "did anything change" guesswork.
    local function PopulateRow(row, entry)
        row.entry = entry
        local itemID = entry.itemID
        local _, link, quality, _, _, _, _, _, _, _, _, _, _, _, expansionID = GetItemInfo(itemID)
        row.link = link or ("item:" .. itemID)
        local icon = GetInstantInfo and select(5, GetInstantInfo(itemID))
        row.icon:SetTexture(icon or 134400)

        quality = quality or entry.quality
        local colorHex = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
            and ITEM_QUALITY_COLORS[quality].hex or "|cffffffff"
        local rarityName = quality and _G["ITEM_QUALITY" .. quality .. "_DESC"]
        row.rarity:SetText(rarityName and (colorHex .. rarityName .. "|r") or "")
        row.ilvl:SetText(entry.itemLevel and tostring(entry.itemLevel) or "")
        local tag = ""
        -- The expansion tag is redundant (and takes room) once one expansion is selected.
        if expansionID ~= nil and panel.selectedExpansion == nil then
            tag = "  |cff888888(" .. (_G["EXPANSION_NAME" .. expansionID] or ("Exp " .. expansionID)) .. ")|r"
        end
        local craftQuality = GetCraftingQuality(itemID)
        local qualityAtlas = craftQuality and ResolveQualityAtlas(itemID, craftQuality) or nil

        row.price:SetText(entry.price and GetCoinTextureString(entry.price) or "no listings")
        row.name:SetText(colorHex .. entry.name .. "|r" .. CraftingQualityMarkup(craftQuality, qualityAtlas) .. tag)
        row.avail:SetText(tostring(entry.quantity or 1))
    end

    local function UpdateVisibleRows()
        local entries = panel.entries or {}
        local viewH = resultsScroll:GetHeight()
        if type(viewH) ~= "number" or viewH < 1 then viewH = 500 end
        local offset = resultsScroll:GetVerticalScroll()
        if type(offset) ~= "number" then offset = 0 end
        local first = math.floor(offset / ROW_H) + 1
        local needed = math.ceil(viewH / ROW_H) + 2

        for i = 1, needed do
            local idx = first + i - 1
            local entry = entries[idx]
            local row = panel.resultRows[i]
            if entry then
                if not row then
                    row = CreateRow()
                    panel.resultRows[i] = row
                end
                PopulateRow(row, entry)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", resultsContent, "TOPLEFT", 0, -(idx - 1) * ROW_H)
                row:SetPoint("TOPRIGHT", resultsContent, "TOPRIGHT", 0, -(idx - 1) * ROW_H)
                row:Show()
            elseif row then
                row:Hide()
            end
        end
        for i = needed + 1, #panel.resultRows do panel.resultRows[i]:Hide() end
    end
    panel.UpdateVisibleRows = UpdateVisibleRows
    -- HookScript (not SetScript) so the template's own scrollbar handler still runs.
    resultsScroll:HookScript("OnVerticalScroll", function() UpdateVisibleRows() end)

    local function SetSort(key)
        local st = SortState()
        if st.key == key then
            st.asc = not st.asc
        else
            st.key = key
            st.asc = (key == "price") -- Price starts cheapest-first; Rarity starts Epic-first
        end
        panel.RefreshSortHeaders()
        resultsScroll:SetVerticalScroll(0)
        panel.RefreshResults()
    end
    for _, btn in ipairs({ priceHeader, rarityHeader, ilvlHeader }) do
        btn:SetScript("OnClick", function(self) SetSort(self.sortKey) end)
    end

    function panel.RefreshResults()
        -- Typing narrows what's loaded, but not for text the Auction House has
        -- already searched for: it matched those names its own way (partial
        -- words, etc.), and a stricter substring test here would hide results.
        local typed = Trim(panel.nameFilter)
        local clientNeedle = typed
        if typed == (panel.serverSearchText or "") then clientNeedle = "" end
        local ok, filtered, errMsg, pending = pcall(GetFilteredBrowseResults, panel.selectedExpansion, clientNeedle)
        if not ok then LogError(filtered); return end
        pending = pending or 0

        -- Browse results arrive in batches; keep asking Blizzard for more
        -- (same call its own list makes on scroll) until it says it has all.
        panel.loadingMore = false
        if (TKAS.hasQuery or panel.selectedNode) and C_AuctionHouse.HasFullBrowseResults then
            local okFull, full = pcall(C_AuctionHouse.HasFullBrowseResults)
            if okFull and full == false then panel.loadingMore = true end
        end
        local notes = ""
        if panel.loadingMore then notes = notes .. "  |cff888888(loading more...)|r" end
        if pending > 0 then notes = notes .. ("  |cff888888(%d item(s) still loading names...)|r"):format(pending) end

        if errMsg then
            statusText:SetText("|cffff5555" .. errMsg .. "|r")
        elseif not TKAS.hasQuery and #filtered == 0 then
            -- Nothing has been asked of the Auction House yet: say how to.
            if typed ~= "" then
                statusText:SetText(("Press Enter to search the Auction House for '%s'."):format(typed))
            else
                statusText:SetText("Pick a category on the left, or type a name and press Enter.")
            end
        else
            local scope = ""
            local searched = TKAS.lastSearchString or ""
            if searched ~= "" then scope = scope .. (" for '%s'"):format(searched) end
            if panel.selectedCategoryName then scope = scope .. (" in '%s'"):format(panel.selectedCategoryName) end
            statusText:SetText(("Showing %d matching item(s)%s.%s"):format(#filtered, scope, notes))
        end

        panel.entries = filtered
        resultsContent:SetHeight(math.max(1, #filtered * ROW_H))
        UpdateVisibleRows()
    end

    panel:SetScript("OnShow", function()
        TKAS.returnToPanel = false -- we're here; nothing left to return to
        tabButton:SetSelected(true)
        resultsContent:SetWidth(math.max(1, resultsScroll:GetWidth() > 1 and resultsScroll:GetWidth() or (AuctionHouseFrame:GetWidth() - 260)))
        RefreshExpansionUI()
        panel.UpdateMoney()
        panel.lastSig = nil
        panel.RefreshResults()
    end)
    panel:SetScript("OnHide", function()
        if panel.HidePopups then panel.HidePopups() end
        tabButton:SetSelected(false)
        GameTooltip:Hide()
    end)

    TKAS.tabButton = tabButton
    TKAS.panel = panel
    tabButton:Show()
    TKAS.HookNativeBackButtons()
end

-- -----------------------------------------------------------------------
-- Keep it live
-- -----------------------------------------------------------------------
local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
hookFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")
hookFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
hookFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
hookFrame:RegisterEvent("PLAYER_MONEY")
-- Item-data load signals. Registered defensively: an unknown event name
-- must never take the whole addon down.
for _, ev in ipairs({ "GET_ITEM_INFO_RECEIVED", "ITEM_DATA_LOAD_RESULT", "ITEM_KEY_ITEM_INFO_RECEIVED" }) do
    pcall(hookFrame.RegisterEvent, hookFrame, ev)
end
hookFrame:SetScript("OnEvent", function(self, event, arg1, arg2)
    if event == "AUCTION_HOUSE_SHOW" and IsEnabled() then
        local ok, err = pcall(TKAS.InjectPanel)
        if not ok then LogError(err) end
        if ok and TKAS.panel then
            if TKAS.panel.ResetSelection then pcall(TKAS.panel.ResetSelection) end
            if OpenFirstEnabled() then
                -- Next frame, so it lands after Blizzard finishes setting up
                -- its own default (Buy) tab.
                C_Timer.After(0, function()
                    if IsEnabled() and AuctionHouseFrame and AuctionHouseFrame:IsShown() and TKAS.panel then
                        TKAS.panel:Show()
                    end
                end)
            end
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        TKAS.returnToPanel = false
        if TKAS.panel then TKAS.panel:Hide() end
    elseif (event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED") and TKAS.panel and TKAS.panel:IsShown() then
        TKAS.panel.RefreshResults()
        -- Ask for the next batch straight away instead of waiting for the tick.
        if TKAS.panel.loadingMore and C_AuctionHouse.RequestMoreBrowseResults then
            pcall(C_AuctionHouse.RequestMoreBrowseResults)
        end
    elseif (event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_DATA_LOAD_RESULT" or event == "ITEM_KEY_ITEM_INFO_RECEIVED") then
        if TKAS.panel and TKAS.panel:IsShown() and type(arg1) == "number" then
            TKAS.NoteItemData(arg1, arg2)
        end
    elseif event == "PLAYER_MONEY" and TKAS.panel and TKAS.panel:IsShown() then
        TKAS.panel.UpdateMoney()
    end
end)

local ticker
hookFrame:HookScript("OnEvent", function(self, event)
    if event == "AUCTION_HOUSE_SHOW" and not ticker then
        ticker = C_Timer.NewTicker(1, function()
            if TKAS.panel and TKAS.panel:IsShown() then
                if TKAS.panel.loadingMore and C_AuctionHouse.RequestMoreBrowseResults then
                    pcall(C_AuctionHouse.RequestMoreBrowseResults)
                end
                local ok, err = pcall(TKAS.panel.RefreshResults)
                if not ok then LogError(err) end
            end
        end)
    elseif event == "AUCTION_HOUSE_CLOSED" and ticker then
        ticker:Cancel()
        ticker = nil
    end
end)

-- -----------------------------------------------------------------------
-- Diagnostic + slash command
-- -----------------------------------------------------------------------
local function RunTabsDiagnostic()
    if not AuctionHouseFrame then Log("Open the Auction House first."); return end
    Log("AuctionHouseFrame.AuctionsTab = " .. tostring(AuctionHouseFrame.AuctionsTab))
    Log("AuctionHouseFrame.SelectBrowseResult = " .. tostring(AuctionHouseFrame.SelectBrowseResult))
    TKAS.HookNativeBackButtons()
    local hookedCount = 0
    for _ in pairs(hookedBackButtons) do hookedCount = hookedCount + 1 end
    Log("Blizzard Back buttons found and hooked: " .. hookedCount)
    local out = {}
    local function walk(f, path, depth, seen)
        if depth > 5 or seen[f] then return end
        seen[f] = true
        local t = GetFrameText(f)
        if t and f:GetObjectType() == "Button" then
            table.insert(out, ("%s  text='%s'  bottom=%s"):format(
                (f.GetName and f:GetName()) or path, t, tostring(f.GetBottom and f:GetBottom())))
        end
        for _, c in ipairs({ f:GetChildren() }) do
            walk(c, path .. "/" .. ((c.GetName and c:GetName()) or "?"), depth + 1, seen)
        end
    end
    walk(AuctionHouseFrame, "AuctionHouseFrame", 0, {})
    Log(("Found %d labelled buttons under AuctionHouseFrame:"):format(#out))
    for i, line in ipairs(out) do
        if i > 30 then print("  ...(more)"); break end
        print("  " .. line)
    end
end

local function RunCatsDiagnostic()
    local native = _G.AuctionCategories
    Log("AuctionCategories global: " .. tostring(native) .. (type(native) == "table" and (" (" .. #native .. " entries)") or ""))
    local roots, source = BuildCategoryTree()
    Log("Using: " .. source)
    for _, r in ipairs(roots) do
        print(("  %s  (%d filter(s), %d sub-menu item(s))"):format(r.name, #r.filters, #r.children))
    end
end

local function RunFiltersDiagnostic()
    local F = Enum.AuctionHouseFilter
    if not F then Log("Enum.AuctionHouseFilter doesn't exist on this client."); return end
    local names = {}
    for k in pairs(F) do table.insert(names, k) end
    table.sort(names)
    Log("Enum.AuctionHouseFilter has: " .. table.concat(names, ", "))
end

local function Esc(text) return (tostring(text):gsub("|", "||")) end

local function RunQualityDiagnostic(itemID)
    local T = C_TradeSkillUI
    local function q(fnName)
        local fn = T and T[fnName]
        if not fn then return "n/a" end
        local okQ, v = pcall(fn, itemID)
        return okQ and tostring(v) or ("error: " .. tostring(v))
    end
    Log(("Item %d -- reagent quality: %s, crafted quality: %s"):format(itemID, q("GetItemReagentQualityByItemInfo"), q("GetItemCraftedQualityByItemInfo")))
    local quality = GetCraftingQuality(itemID)
    if not quality then Log("No crafting tier detected for this item, so no icon is shown."); return end

    local okI, link = pcall(function() return (select(2, GetItemInfo(itemID))) end)
    Log("Item link text: " .. (okI and Esc(link) or "unavailable"))
    Log("  stage 1 (item link):    " .. tostring((AtlasFromItemLink(itemID))))
    Log("  stage 2 (tooltip):      " .. tostring((AtlasFromTooltip(itemID))))
    Log("  stage 3 (Professions):  " .. tostring((AtlasFromProfessionsHelper(quality))))
    Log("  stage 4 (guess):        " .. tostring((AtlasFromGuess(quality))))
    qualityIconCache[itemID] = nil
    local atlas, source = ResolveQualityAtlas(itemID, quality)
    Log(("Using: %s  (from %s)"):format(tostring(atlas), tostring(source)))
end

local function RunExpansionDiagnostic()
    local function show(v) return tostring(v) end
    Log("GetServerExpansionLevel: " .. show(GetServerExpansionLevel and GetServerExpansionLevel()))
    Log("LE_EXPANSION_LEVEL_CURRENT: " .. show(_G.LE_EXPANSION_LEVEL_CURRENT))
    Log("GetExpansionLevel: " .. show(GetExpansionLevel and GetExpansionLevel()))
    local id = GetCurrentExpansionID()
    Log(("Current expansion used: %s (%s)"):format(show(id), show(id and _G["EXPANSION_NAME" .. id])))
    Log("Enum.AuctionHouseFilter.CurrentExpansionOnly: " .. show(Enum.AuctionHouseFilter and Enum.AuctionHouseFilter.CurrentExpansionOnly))
end

SLASH_TKAUCTION1 = "/tkauction"
SlashCmdList["TKAUCTION"] = function(msg)
    msg = (msg or ""):lower():trim()
    if msg == "on" then
        SetEnabled(true); Log("enabled.")
    elseif msg == "off" then
        SetEnabled(false); Log("disabled.")
    elseif msg:match("^quality%s+%d+") then
        local ok, err = pcall(RunQualityDiagnostic, tonumber(msg:match("^quality%s+(%d+)")))
        if not ok then LogError(err) end
    elseif msg == "back on" or msg == "back off" then
        TKAS.SetBackReturn(msg == "back on")
        Log("Back button returns to the Expansions tab: " .. (BackReturnEnabled() and "ON" or "OFF"))
    elseif msg == "start current" or msg == "start all" then
        TKAS.SetStartOnCurrent(msg == "start current")
        Log("start on the current expansion: " .. (StartOnCurrentEnabled() and "ON" or "OFF (starts on All)"))
    elseif msg == "expansion" then
        local ok, err = pcall(RunExpansionDiagnostic)
        if not ok then LogError(err) end
    elseif msg == "filters" then
        local ok, err = pcall(RunFiltersDiagnostic)
        if not ok then LogError(err) end
    elseif msg == "first on" or msg == "first off" then
        TKAS.SetOpenFirst(msg == "first on")
        Log("open Expansions tab first: " .. (OpenFirstEnabled() and "ON" or "OFF"))
    elseif msg == "cats" then
        local ok, err = pcall(RunCatsDiagnostic)
        if not ok then LogError(err) end
    elseif msg == "tabs" then
        local ok, err = pcall(RunTabsDiagnostic)
        if not ok then LogError(err) end
    else
        Log("usage: /tkauction on|off|first on|first off|back on|back off|start current|start all|tabs|cats|filters|expansion|quality <id>  (module is currently " .. (IsEnabled() and "ON" or "OFF") .. ")")
    end
end
