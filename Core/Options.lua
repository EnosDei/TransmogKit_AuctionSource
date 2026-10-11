--[[
Options.lua

Adds a checkbox to Settings > AddOns > TransmogKit (or its own category if
TransmogKit's main options panel isn't detected) so the Auction Source
module can be toggled without typing a slash command. Falls back to a
standalone category if TransmogKit's own panel category isn't found --
this file is written so it works whether or not you've wired TransmogKit's
existing options code to know about this module yet.
]]--

TransmogKit = TransmogKit or {}
TransmogKit.AuctionSource = TransmogKit.AuctionSource or {}
local TKAS = TransmogKit.AuctionSource

local function BuildOptionsPanel()
    local panel = CreateFrame("Frame")
    panel.name = "Auction Source Finder"

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("TransmogKit - Auction Source Finder")

    local desc = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetWidth(500)
    desc:SetJustifyH("LEFT")
    desc:SetText("Filter the Auction House Browse results by expansion (and Bind-on-Equip) instead of level and rarity. Reads Blizzard's own item data live -- no database, nothing to rebuild.")

    local enableCheck = CreateFrame("CheckButton", "TKAS_EnableCheck", panel, "UICheckButtonTemplate")
    enableCheck:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", -2, -16)
    _G[enableCheck:GetName() .. "Text"]:SetText("Enable Auction Source Finder")
    enableCheck:SetScript("OnClick", function(self)
        TKAS.SetEnabled(self:GetChecked())
    end)

    local firstCheck = CreateFrame("CheckButton", "TKAS_OpenFirstCheck", panel, "UICheckButtonTemplate")
    firstCheck:SetPoint("TOPLEFT", enableCheck, "BOTTOMLEFT", 0, -4)
    _G[firstCheck:GetName() .. "Text"]:SetText("Open the Expansions tab first when the Auction House opens")
    firstCheck:SetScript("OnClick", function(self)
        TKAS.SetOpenFirst(self:GetChecked())
    end)

    local startCheck = CreateFrame("CheckButton", "TKAS_StartCurrentCheck", panel, "UICheckButtonTemplate")
    startCheck:SetPoint("TOPLEFT", firstCheck, "BOTTOMLEFT", 0, -4)
    _G[startCheck:GetName() .. "Text"]:SetText("Start on the current expansion (instead of All)")
    startCheck:SetScript("OnClick", function(self)
        TKAS.SetStartOnCurrent(self:GetChecked())
    end)

    local backCheck = CreateFrame("CheckButton", "TKAS_BackReturnCheck", panel, "UICheckButtonTemplate")
    backCheck:SetPoint("TOPLEFT", startCheck, "BOTTOMLEFT", 0, -4)
    _G[backCheck:GetName() .. "Text"]:SetText("Blizzard's Back button on the buy page returns to the Expansions tab")
    backCheck:SetScript("OnClick", function(self)
        TKAS.SetBackReturn(self:GetChecked())
    end)

    panel.refresh = function()
        enableCheck:SetChecked(TKAS.IsEnabled())
        backCheck:SetChecked(TKAS.BackReturnEnabled())
        firstCheck:SetChecked(TKAS.OpenFirstEnabled())
        startCheck:SetChecked(TKAS.StartOnCurrentEnabled())
    end

    panel:SetScript("OnShow", function()
        panel.refresh()
    end)

    if Settings and Settings.RegisterCanvasLayoutCategory then
        -- Modern Settings API (Dragonflight+)
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        -- Legacy fallback for older clients
        InterfaceOptions_AddCategory(panel)
    end
end

local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, addonName)
    if addonName == "TransmogKit_AuctionSource" then
        BuildOptionsPanel()
        self:UnregisterEvent("ADDON_LOADED")
    end
end)
