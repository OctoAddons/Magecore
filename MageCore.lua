-- MageCore v1.5.34
-- Press-driven mage rotation and self-buff helper for Turtle WoW / Vanilla 1.12.

local _, playerClass = UnitClass("player")
if playerClass ~= "MAGE" then return end

local VERSION = "1.5.35"
local ICON_PATH = "Interface\\Icons\\"
local DEFAULT_ICON = "Spell_Frost_FrostBolt02"
local ACCENT = "|cff69ccf0"

local spellBookSpells = { "None" }
local helpfulSpellBookSpells = { "None" }
local knownWaterSpells = {}
local knownFoodSpells = {}
local pendingConjure
local conjureRestockActive = {}
local lastCombatSpellAttempt
local rangeBlockedSpells = {}
local openerUsedForTarget
local pvpFrostboltUsedForTarget
local lastGroupBuffAttempt
local groupBlockedUnits = {}
local normalCastInProgress = false
local channelInProgress = false
local spellManaCostCache = {}

-- Vanilla 1.12 has no IsHelpfulSpell/IsHarmfulSpell API. These category
-- hints are applied only to spells actually found in the player's spellbook.
local MAGE_BUFF_NAMES = {
    ["Arcane Intellect"] = true, ["Arcane Brilliance"] = true,
    ["Amplify Magic"] = true, ["Dampen Magic"] = true,
    ["Frost Armor"] = true, ["Ice Armor"] = true,
    ["Mage Armor"] = true, ["Molten Armor"] = true,
    ["Mana Shield"] = true, ["Ice Barrier"] = true,
    ["Fire Ward"] = true, ["Frost Ward"] = true
}

local MAGE_ATTACK_NAMES = {
    ["Fireball"] = true, ["Frostbolt"] = true,
    ["Arcane Missiles"] = true, ["Fire Blast"] = true,
    ["Scorch"] = true, ["Pyroblast"] = true,
    ["Flamestrike"] = true, ["Blizzard"] = true,
    ["Arcane Explosion"] = true, ["Cone of Cold"] = true,
    ["Frost Nova"] = true, ["Blast Wave"] = true,
    ["Polymorph"] = true, ["Counterspell"] = true,
    ["Detect Magic"] = true, ["Arcane Surge"] = true,
    ["Ice Lance"] = true, ["Living Bomb"] = true
}

local FROST_SLOW_NAMES = {
    ["frostbolt"] = true, ["cone of cold"] = true, ["blizzard"] = true,
    ["frost armor"] = true, ["ice armor"] = true, ["frostbite"] = true,
    ["freeze"] = true, ["chilled"] = true
}

local HEALING_SPELL_NAMES = {
    ["healing touch"] = true, ["regrowth"] = true, ["tranquility"] = true,
    ["rejuvenation"] = true, ["renew"] = true, ["restoration"] = true,
    ["holy light"] = true, ["flash of light"] = true,
    ["healing wave"] = true, ["lesser healing wave"] = true,
    ["chain heal"] = true, ["heal"] = true, ["greater heal"] = true,
    ["flash heal"] = true, ["prayer of healing"] = true,
    ["dark mending"] = true
}

local spellScanTooltip = CreateFrame("GameTooltip", "MageCoreSpellScanTooltip", UIParent, "GameTooltipTemplate")
spellScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
local BUFF_TEXT_HINTS = {
    "increases the target's", "increases your", "increases armor",
    "dampens magic", "amplifies magic", "absorbs", "shields you",
    "shields the caster", "protects the caster"
}
local ATTACK_TEXT_HINTS = {
    " damage", "damages ", " enemy", "enemies", "incapacitates",
    "freezes", "slows", "silences"
}

local rotationIconTexture
local buffIconTexture
local foodStatusText
local updateElapsed = 0
local frostNovaRangeElapsed = 0
local frostNovaRangeDistanceIndex = 3
local frostNovaRangeYards = 10
local arcticReachRank = 0
local frostNovaNameplateCount = 0
local frostNovaNameplates = {}
local autoRepeatActive = false
local lastRotationIcon
local lastBuffIcon

local function TextureName(texture)
    if not texture then return nil end
    local _, _, name = string.find(texture, "([^\\/]+)$")
    return name or texture
end

local function NormalizeTexture(texture)
    local name = TextureName(texture)
    return name and string.lower(name) or nil
end

local function TooltipHasAny(spellIndex, hints)
    spellScanTooltip:ClearLines()
    spellScanTooltip:SetSpell(spellIndex, BOOKTYPE_SPELL)
    local text = ""
    local i
    for i = 2, 10 do
        local left = getglobal("MageCoreSpellScanTooltipTextLeft" .. i)
        local right = getglobal("MageCoreSpellScanTooltipTextRight" .. i)
        if left and left:GetText() then text = text .. " " .. string.lower(left:GetText()) end
        if right and right:GetText() then text = text .. " " .. string.lower(right:GetText()) end
    end
    local _, hint
    for _, hint in ipairs(hints) do
        if string.find(text, hint, 1, true) then return true end
    end
    return false
end

local function GetSpellBookIndex(spellName)
    if not spellName or spellName == "None" then return nil end
    local _, _, baseName, wantedRank = string.find(spellName, "^(.+)%((.+)%)$")
    baseName = baseName or spellName
    local i
    local highestIndex
    for i = 1, 300 do
        local name, rank = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if name == baseName then
            if wantedRank and rank == wantedRank then return i end
            if not wantedRank then highestIndex = i end
        end
    end
    return highestIndex
end

local function RefreshSpellBook()
    spellManaCostCache = {}
    local learned = {}
    local helpful = {}
    local seen = {}
    local helpfulSeen = {}
    local waterRanks = {}
    local foodRanks = {}
    local function AddSpell(spellIndex)
        local spellName = GetSpellName(spellIndex, BOOKTYPE_SPELL)
        if not spellName then return end
        local passiveValue = IsPassiveSpell and IsPassiveSpell(spellIndex, BOOKTYPE_SPELL)
        local passive = passiveValue and passiveValue ~= 0
        local isHelpful = MAGE_BUFF_NAMES[spellName]
        local isAttack = MAGE_ATTACK_NAMES[spellName]
        if not isHelpful and not isAttack then
            isHelpful = TooltipHasAny(spellIndex, BUFF_TEXT_HINTS)
            if not isHelpful then isAttack = TooltipHasAny(spellIndex, ATTACK_TEXT_HINTS) end
        end
        if not passive and isAttack and not seen[spellName] then
            seen[spellName] = true
            table.insert(learned, spellName)
        end
        if not passive and isHelpful and not helpfulSeen[spellName] then
            helpfulSeen[spellName] = true
            table.insert(helpful, spellName)
        end
    end

    -- The first spellbook tab is General. It contains racial, profession and
    -- basic actions rather than mage spells, so only read the class tabs.
    local tabCount = GetNumSpellTabs and GetNumSpellTabs()
    local i
    if tabCount and tabCount > 1 and GetSpellTabInfo then
        local tab
        for tab = 2, tabCount do
            local _, _, offset, spellCount = GetSpellTabInfo(tab)
            if offset and spellCount then
                for i = offset + 1, offset + spellCount do AddSpell(i) end
            end
        end
    else
        -- Compatibility fallback for clients without the spell-tab API.
        for i = 1, 300 do
            if not GetSpellName(i, BOOKTYPE_SPELL) then break end
            AddSpell(i)
        end
    end

    -- Guaranteed Vanilla/Turtle fallback: cross-check the entire book by
    -- name. This does not add unlearned spells; it only avoids unreliable tab
    -- and tooltip classification for standard mage abilities.
    for i = 1, 300 do
        local spellName, spellRank = GetSpellName(i, BOOKTYPE_SPELL)
        if not spellName then break end
        if MAGE_BUFF_NAMES[spellName] and not helpfulSeen[spellName] then
            helpfulSeen[spellName] = true
            table.insert(helpful, spellName)
        end
        if MAGE_ATTACK_NAMES[spellName] and not seen[spellName] then
            seen[spellName] = true
            table.insert(learned, spellName)
        end
        if spellName == "Conjure Water" or spellName == "Conjure Food" then
            local display = spellName
            local castName = spellName
            local rankNumber
            if spellRank and spellRank ~= "" then
                display = spellName .. " (" .. spellRank .. ")"
                castName = spellName .. "(" .. spellRank .. ")"
                local _, _, number = string.find(spellRank, "(%d+)")
                rankNumber = tonumber(number)
            end
            local entry = {
                display = display,
                cast = castName,
                rank = rankNumber,
                rankText = spellRank,
                spellIndex = i
            }
            if spellName == "Conjure Water" then
                table.insert(waterRanks, entry)
            else
                table.insert(foodRanks, entry)
            end
        end
    end
    local function HighestRankFirst(left, right)
        if left.rank and right.rank and left.rank ~= right.rank then
            return left.rank > right.rank
        end
        return left.spellIndex > right.spellIndex
    end
    table.sort(waterRanks, HighestRankFirst)
    table.sort(foodRanks, HighestRankFirst)
    knownWaterSpells = waterRanks
    knownFoodSpells = foodRanks

    -- Existing conjure selections migrate to automatic highest-rank mode.
    -- Choosing an exact rank from the menu disables this behavior.
    if MageCore_Config then
        local kinds = { "Water", "Food" }
        local _, kind
        for _, kind in ipairs(kinds) do
            local ranks = kind == "Water" and waterRanks or foodRanks
            local highest = ranks[1]
            if MageCore_Config[kind .. "AutoRank"]
                and MageCore_Config[kind .. "Spell"] ~= "None" and highest
                and MageCore_Config[kind .. "Spell"] ~= highest.cast then
                MageCore_Config[kind .. "Spell"] = highest.cast
                MageCore_Config[kind .. "ItemID"] = nil
                if pendingConjure and pendingConjure.kind == kind then pendingConjure = nil end
            end
            local dropdown = getglobal("MC_ConjureDrop_" .. kind)
            if dropdown and MageCore_Config[kind .. "AutoRank"] and highest then
                local highestText = highest.rankText and "Highest (" .. highest.rankText .. ")" or "Highest learned"
                UIDropDownMenu_SetSelectedValue(dropdown, "AUTO")
                UIDropDownMenu_SetText(highestText, dropdown)
            end
        end
    end

    table.sort(learned)
    table.sort(helpful)
    spellBookSpells = { "None" }
    helpfulSpellBookSpells = { "None" }
    for i = 1, table.getn(learned) do
        table.insert(spellBookSpells, learned[i])
    end
    for i = 1, table.getn(helpful) do
        table.insert(helpfulSpellBookSpells, helpful[i])
    end

    -- Remove old selections that came from General before this filter existed.
    if MageCore_Config then
        for i = 1, 6 do
            local rotation = MageCore_Config["Rotation" .. i]
            local buff = MageCore_Config["Buff" .. i]
            if rotation and rotation ~= "None" and not seen[rotation] then
                MageCore_Config["Rotation" .. i] = "None"
            end
            -- Never erase a learned buff merely because classification failed;
            -- that caused the v1.1.8 settings loss on the Vanilla client.
            if buff and buff ~= "None" and not GetSpellBookIndex(buff) then
                MageCore_Config["Buff" .. i] = "None"
            end
        end
        if MageCore_Config.Opener and MageCore_Config.Opener ~= "None"
            and not seen[MageCore_Config.Opener] then
            MageCore_Config.Opener = "None"
        end
    end

    -- Arctic Reach appears as a ranked passive spellbook entry when learned.
    local arcticReachIndex = GetSpellBookIndex("Arctic Reach")
    if arcticReachIndex then
        local _, rankText = GetSpellName(arcticReachIndex, BOOKTYPE_SPELL)
        local _, _, rankNumber = string.find(rankText or "", "(%d+)")
        arcticReachRank = math.max(1, math.min(2, tonumber(rankNumber) or 1))
        frostNovaRangeDistanceIndex = 2
        frostNovaRangeYards = 10 + arcticReachRank
    else
        arcticReachRank = 0
        frostNovaRangeDistanceIndex = 3
        frostNovaRangeYards = 10
    end
end

local function GetSpellTextureByName(spellName)
    local index = GetSpellBookIndex(spellName)
    if not index then return nil end
    return GetSpellTexture(index, BOOKTYPE_SPELL)
end

local function GetSpellManaCost(spellName)
    if not spellName or spellName == "None" then return nil end
    if spellManaCostCache[spellName] ~= nil then
        return spellManaCostCache[spellName] or nil
    end
    local index = GetSpellBookIndex(spellName)
    if not index then return nil end
    spellScanTooltip:ClearLines()
    spellScanTooltip:SetSpell(index, BOOKTYPE_SPELL)
    local line
    for line = 1, spellScanTooltip:NumLines() do
        local left = getglobal("MageCoreSpellScanTooltipTextLeft" .. line)
        local right = getglobal("MageCoreSpellScanTooltipTextRight" .. line)
        local texts = { left and left:GetText(), right and right:GetText() }
        local _, value
        for _, value in ipairs(texts) do
            if value then
                local clean = string.gsub(value, ",", "")
                local _, _, cost = string.find(clean, "(%d+)%s+[Mm]ana")
                if cost then
                    spellManaCostCache[spellName] = tonumber(cost)
                    return tonumber(cost)
                end
            end
        end
    end
    spellManaCostCache[spellName] = false
    return nil
end

local function IsSpellReady(spellName)
    local index = GetSpellBookIndex(spellName)
    if not index then return false end
    local start, duration, enabled = GetSpellCooldown(index, BOOKTYPE_SPELL)
    if enabled == 0 then return false end
    if not start or not duration or start == 0 or duration == 0 then return true end
    -- Ignore the shared global cooldown; longer cooldowns must finish.
    return duration <= 1.5
end

local function GetSpellCooldownInfo(spellName)
    local index = GetSpellBookIndex(spellName)
    if not index then return nil, nil, nil end
    local start, duration, enabled = GetSpellCooldown(index, BOOKTYPE_SPELL)
    return start or 0, duration or 0, enabled or 0
end

local function GetSpellCooldownRemaining(spellName)
    local start, duration, enabled = GetSpellCooldownInfo(spellName)
    if start == nil or enabled == 0 then return nil end
    if start == 0 or duration == 0 then return 0 end
    return math.max(0, start + duration - GetTime())
end

local function UnitHasBuff(unit, spellName)
    local wanted = NormalizeTexture(GetSpellTextureByName(spellName))
    if not wanted then return false end
    local i
    for i = 1, 32 do
        local texture = UnitBuff(unit, i)
        if not texture then break end
        if NormalizeTexture(texture) == wanted then return true end
    end
    return false
end

local function PlayerHasBuff(spellName)
    return UnitHasBuff("player", spellName)
end

local function TargetHasFrostSlow()
    if not UnitExists("target") then return false end

    local slowTextures = {}
    local slowSpells = { "Frostbolt", "Cone of Cold", "Blizzard", "Frost Armor", "Ice Armor" }
    local _, spellName
    for _, spellName in ipairs(slowSpells) do
        local texture = NormalizeTexture(GetSpellTextureByName(spellName))
        if texture then slowTextures[texture] = true end
    end

    local i
    for i = 1, 16 do
        local texture = UnitDebuff("target", i)
        if not texture then break end
        local normalizedTexture = NormalizeTexture(texture)
        if slowTextures[normalizedTexture] then return true end

        if spellScanTooltip.SetUnitDebuff then
            spellScanTooltip:ClearLines()
            spellScanTooltip:SetUnitDebuff("target", i)
            local nameLine = getglobal("MageCoreSpellScanTooltipTextLeft1")
            local debuffName = nameLine and nameLine:GetText()
            if debuffName and FROST_SLOW_NAMES[string.lower(debuffName)] then return true end

            -- Catch custom Turtle frost slows whose names are not in the known
            -- list, while avoiding non-frost movement impairing effects.
            if normalizedTexture and string.find(normalizedTexture, "spell_frost", 1, true) then
                local line
                for line = 2, 10 do
                    local textLine = getglobal("MageCoreSpellScanTooltipTextLeft" .. line)
                    local text = textLine and textLine:GetText()
                    text = text and string.lower(text)
                    if text and (string.find(text, "movement speed", 1, true)
                        or string.find(text, "slowed", 1, true)) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function HasLivingEnemyTarget()
    return UnitExists("target")
        and UnitCanAttack("player", "target")
        and not UnitIsDeadOrGhost("target")
end

local function IsVanillaNameplate(frame)
    if not frame then return false end
    local objectType = frame:GetObjectType()
    if objectType ~= "Button" and objectType ~= "Frame" then return false end
    -- ShaguTweaks identifies native plates, then reparents their regions into
    -- plate.new. Its cached fields remain the most reliable identifiers.
    if frame.healthbar and frame.name then return true end
    local _, region
    for _, region in pairs({ frame:GetRegions() }) do
        if region.GetObjectType and region.GetTexture
            and region:GetObjectType() == "Texture" then
            local texture = region:GetTexture()
            texture = texture and string.lower(string.gsub(texture, "/", "\\"))
            if texture == "interface\\tooltips\\nameplate-border" then return true end
        end
    end
    return false
end

local function AddFrostNovaNameplate(parent)
    if not parent or frostNovaNameplates[parent] then return end
    local originalHealth = parent.healthbar or parent:GetChildren()
    if not originalHealth then return end

    local border = CreateFrame("Frame", nil, parent)
    border:SetFrameStrata("HIGH")
    border:SetFrameLevel(100)
    local top = border:CreateTexture(nil, "OVERLAY")
    top:SetTexture(1, 0, 0, 1)
    top:SetPoint("TOPLEFT", 0, 0); top:SetPoint("TOPRIGHT", 0, 0); top:SetHeight(3)
    local bottom = border:CreateTexture(nil, "OVERLAY")
    bottom:SetTexture(1, 0, 0, 1)
    bottom:SetPoint("BOTTOMLEFT", 0, 0); bottom:SetPoint("BOTTOMRIGHT", 0, 0); bottom:SetHeight(3)
    local left = border:CreateTexture(nil, "OVERLAY")
    left:SetTexture(1, 0, 0, 1)
    left:SetPoint("TOPLEFT", 0, 0); left:SetPoint("BOTTOMLEFT", 0, 0); left:SetWidth(3)
    local right = border:CreateTexture(nil, "OVERLAY")
    right:SetTexture(1, 0, 0, 1)
    right:SetPoint("TOPRIGHT", 0, 0); right:SetPoint("BOTTOMRIGHT", 0, 0); right:SetWidth(3)
    border:Hide()

    frostNovaNameplates[parent] = {
        border = border,
        borderTextures = { top, bottom, left, right },
        anchor = nil,
        originalHealth = originalHealth,
        scaleContainer = nil,
        containerBaseScale = nil,
        baseWidth = nil,
        baseHeight = nil
    }
end

local function DiscoverFrostNovaNameplates()
    local childCount = WorldFrame:GetNumChildren()
    if childCount <= frostNovaNameplateCount then return end
    local children = { WorldFrame:GetChildren() }
    local i
    for i = frostNovaNameplateCount + 1, childCount do
        local child = children[i]
        if IsVanillaNameplate(child) then AddFrostNovaNameplate(child) end
    end
    frostNovaNameplateCount = childCount
end

local function FrameHasUnitName(frame, unitName)
    if not frame or not unitName then return false end
    local _, region
    for _, region in pairs({ frame:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "FontString"
            and region:GetText() == unitName then
            return true
        end
    end
    return false
end

local function GetFrostNovaNameplateUnit(parent, entry)
    -- SuperWoW extends GetName(1) on nameplates to return the unit GUID.
    if parent.GetName then
        local ok, guid = pcall(parent.GetName, parent, 1)
        if ok and guid and UnitExists(guid) then return guid end
    end
    -- Stock Vanilla cannot identify every nameplate. pfUI can still tell us
    -- which plate is the current target, for which the normal token is exact.
    if parent.nameplate and parent.nameplate.istarget and UnitExists("target") then
        return "target"
    end
    -- On the native Vanilla nameplates, the selected plate has full alpha.
    -- Matching its text as well avoids confusing same-area friendly plates.
    if UnitExists("target") and parent:GetAlpha() == 1 then
        local targetName = UnitName("target")
        if parent.name and parent.name:GetText() == targetName then return "target" end
        if FrameHasUnitName(parent, targetName)
            or FrameHasUnitName(entry.scaleContainer, targetName) then return "target" end
    end
    return nil
end

local function HideFrostNovaRangeIndicators()
    local _, entry
    for _, entry in pairs(frostNovaNameplates) do entry.border:Hide() end
end

local function MoveNameplateVisualsToContainer(parent, entry)
    local container = entry.scaleContainer
    if not container then return end
    local _, child
    for _, child in pairs({ parent:GetChildren() }) do
        if child ~= container then child:SetParent(container) end
    end
    local _, region
    for _, region in pairs({ parent:GetRegions() }) do region:SetParent(container) end
end

local function EnsureNameplateScaleContainer(parent, entry)
    if parent.new then
        if entry.scaleContainer ~= parent.new then
            entry.scaleContainer = parent.new
            entry.containerBaseScale = parent.new:GetScale() or 1
            entry.baseWidth = parent:GetWidth()
            entry.baseHeight = parent:GetHeight()
        end
        MoveNameplateVisualsToContainer(parent, entry)
        return
    end

    -- When ShaguTweaks' Nameplate Scale module is enabled, it creates its own
    -- visual container during the plate's first update. Wait for that frame so
    -- both addons do not reparent the same regions at once.
    local shaguScaleKey = ShaguTweaks and ShaguTweaks.T
        and ShaguTweaks.T["Nameplate Scale"] or "Nameplate Scale"
    if ShaguTweaks and ShaguTweaks_config
        and tonumber(ShaguTweaks_config[shaguScaleKey]) == 1 then return end

    if not entry.scaleContainer then
        local container = CreateFrame("Frame", nil, parent)
        container:SetAllPoints(parent)
        entry.scaleContainer = container
        entry.containerBaseScale = 1
        entry.baseWidth = parent:GetWidth()
        entry.baseHeight = parent:GetHeight()
    end
    MoveNameplateVisualsToContainer(parent, entry)
end

local function ApplyNameplateScale()
    if not MageCore_Config then return end
    local percent = tonumber(MageCore_Config.NameplateScale) or 100
    percent = math.max(50, math.min(150, percent))
    local parent, entry
    for parent, entry in pairs(frostNovaNameplates) do
        EnsureNameplateScaleContainer(parent, entry)
        if entry.scaleContainer and entry.containerBaseScale then
            local ratio = percent / 100
            -- Keep the parent's positional scale untouched, but resize its
            -- layout box with the visuals so the above-head anchor stays valid.
            if entry.baseWidth and entry.baseWidth > 0 then
                parent:SetWidth(entry.baseWidth * ratio)
            end
            if entry.baseHeight and entry.baseHeight > 0 then
                parent:SetHeight(entry.baseHeight * ratio)
            end
            entry.scaleContainer:SetScale(entry.containerBaseScale * percent / 100)
        end
    end
end

local function IsUnitInFrostNovaRange(unit)
    local hostileOK, hostile = pcall(UnitCanAttack, "player", unit)
    local deadOK, dead = pcall(UnitIsDeadOrGhost, unit)
    if not hostileOK or not hostile or not deadOK or dead then return false end

    -- SuperWoW may expose coordinates for the nameplate GUID. When available,
    -- this gives Arctic Reach rank 2 its full 12-yard check.
    if UnitPosition then
        local playerOK, playerX, playerY = pcall(UnitPosition, "player")
        local unitOK, unitX, unitY = pcall(UnitPosition, unit)
        if playerOK and unitOK and playerX and playerY and unitX and unitY then
            local deltaX = playerX - unitX
            local deltaY = playerY - unitY
            return deltaX * deltaX + deltaY * deltaY
                <= frostNovaRangeYards * frostNovaRangeYards
        end
    end

    -- Indices 3 and 2 are approximately 9.9 and 11.1 yards respectively.
    local rangeOK, inRange = pcall(CheckInteractDistance, unit, frostNovaRangeDistanceIndex)
    return rangeOK and inRange
end

local function SetFrostNovaBorderColor(entry, red, green, blue)
    local _, texture
    for _, texture in pairs(entry.borderTextures) do
        texture:SetTexture(red, green, blue, 1)
    end
end

local function UpdateFrostNovaRangeIndicators()
    DiscoverFrostNovaNameplates()
    ApplyNameplateScale()
    if not MageCore_Config or not MageCore_Config.FrostNovaRange then
        HideFrostNovaRangeIndicators()
        return
    end

    local parent, entry
    for parent, entry in pairs(frostNovaNameplates) do
        local anchor = parent.nameplate and parent.nameplate.health
            or parent.healthbar or entry.originalHealth
        if anchor and anchor ~= entry.anchor then
            entry.border:ClearAllPoints()
            entry.border:SetPoint("TOPLEFT", anchor, "TOPLEFT", -3, 3)
            entry.border:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 3, -3)
            entry.anchor = anchor
        end

        local unit = parent:IsShown() and GetFrostNovaNameplateUnit(parent, entry)
        if unit and IsUnitInFrostNovaRange(unit) then
            -- Alternate four times per second for a strong red/yellow warning.
            if math.mod(math.floor(GetTime() * 4), 2) == 0 then
                SetFrostNovaBorderColor(entry, 1, 0, 0)
            else
                SetFrostNovaBorderColor(entry, 1, 1, 0)
            end
            entry.border:Show()
        else
            entry.border:Hide()
        end
    end
end

local function IsHealingSpellName(spellName)
    if not spellName or spellName == "" then return false end
    local lowerName = string.lower(spellName)
    if HEALING_SPELL_NAMES[lowerName] then return true end
    -- Covers ranked/custom NPC heals while keeping non-healing holy and
    -- nature casts out of the healing-only mode.
    return string.find(lowerName, "heal", 1, true) ~= nil
        or string.find(lowerName, "mending", 1, true) ~= nil
end

local function GetTargetInterruptibleSpellName()
    if not HasLivingEnemyTarget() then return nil end

    -- SuperWoW stores enemy cast data by GUID, while stock-compatible cast
    -- libraries commonly accept a unit token or unit name. Try all three so
    -- Counterspell works with the native API, pfUI, and ShaguTweaks.
    local queries = {}
    local _, targetGUID = UnitExists("target")
    if targetGUID then table.insert(queries, targetGUID) end
    table.insert(queries, "target")
    local targetName = UnitName("target")
    if targetName then table.insert(queries, targetName) end

    local castingProviders = {}
    if UnitCastingInfo then table.insert(castingProviders, UnitCastingInfo) end
    if ShaguTweaks and ShaguTweaks.UnitCastingInfo
        and ShaguTweaks.UnitCastingInfo ~= UnitCastingInfo then
        table.insert(castingProviders, ShaguTweaks.UnitCastingInfo)
    end

    local _, provider
    for _, provider in ipairs(castingProviders) do
        local _, query
        for _, query in ipairs(queries) do
            local ok, name, _, _, _, _, _, _, _, notInterruptible = pcall(provider, query)
            if ok and name then
                if notInterruptible == true or notInterruptible == 1 then return nil end
                return name
            end
        end
    end

    local channelProviders = {}
    if UnitChannelInfo then table.insert(channelProviders, UnitChannelInfo) end
    if ShaguTweaks and ShaguTweaks.UnitChannelInfo
        and ShaguTweaks.UnitChannelInfo ~= UnitChannelInfo then
        table.insert(channelProviders, ShaguTweaks.UnitChannelInfo)
    end

    for _, provider in ipairs(channelProviders) do
        local _, query
        for _, query in ipairs(queries) do
            local ok, name, _, _, _, _, _, _, notInterruptible = pcall(provider, query)
            if ok and name then
                if notInterruptible == true or notInterruptible == 1 then return nil end
                return name
            end
        end
    end

    -- Compatibility fallback for legacy target-castbar addons.
    local spellBar = TargetFrameSpellBar
    if spellBar and spellBar:IsShown()
        and (not spellBar.unit or spellBar.unit == "target")
        and (spellBar.casting or spellBar.channeling) then
        local textRegion = spellBar.Text or spellBar.text
        if not textRegion and spellBar.GetName then
            local barName = spellBar:GetName()
            if barName then textRegion = getglobal(barName .. "Text") end
        end
        local spellName
        if type(textRegion) == "string" then
            spellName = textRegion
        elseif textRegion and textRegion.GetText then
            spellName = textRegion:GetText()
        end
        -- An empty string still signals a cast for normal Counterspell mode,
        -- but safely fails the healing-name check in healing-only mode.
        return spellName or ""
    end
    return nil
end

local function ShouldGoDirectToPvpRotation()
    return MageCore_Config and MageCore_Config.PvPMode and HasLivingEnemyTarget()
end

local function GetFindMineralsAction()
    if UnitAffectingCombat("player") or not GetTrackingTexture then return nil end
    local spellTexture = NormalizeTexture(GetSpellTextureByName("Find Minerals"))
    if not spellTexture then return nil end
    local trackingTexture = NormalizeTexture(GetTrackingTexture())
    if trackingTexture ~= spellTexture then return "Find Minerals" end
    return nil
end

local function GetTargetKey()
    if not UnitExists("target") then return "" end
    return (UnitName("target") or "") .. ":" .. (UnitLevel("target") or 0)
end

local function GetSpellRangeState(spellName)
    if not HasLivingEnemyTarget() then return nil end

    -- Some Turtle clients expose the later helper even though stock 1.12 does
    -- not. Use it when present, then fall back to matching action-bar spells.
    if IsSpellInRange then
        local state = IsSpellInRange(spellName, "target")
        if state == 0 then return false end
        if state == 1 then return true end
    end

    if IsActionInRange then
        local wantedTexture = NormalizeTexture(GetSpellTextureByName(spellName))
        local foundInRange = false
        local slot
        for slot = 1, 120 do
            local texture = GetActionTexture(slot)
            -- Ignore macros (including MageRot itself) that merely share the
            -- dynamic spell icon; only native spell actions report useful range.
            if texture and not GetActionText(slot) and NormalizeTexture(texture) == wantedTexture then
                local state = IsActionInRange(slot)
                if state == 0 then return false end
                if state == 1 then foundInRange = true end
            end
        end
        if foundInRange then return true end
    end
    return nil
end

local function IsRangeBlocked(spellName)
    local blocked = rangeBlockedSpells[spellName]
    if not blocked then return false end
    if blocked.target ~= GetTargetKey() or GetTime() >= blocked.expires then
        rangeBlockedSpells[spellName] = nil
        return false
    end
    return true
end

local function SpellCanReachTarget(spellName)
    if IsRangeBlocked(spellName) then return false end
    -- Cone of Cold is a player-centered area spell, so the normal targeted
    -- spell range APIs commonly return no result. Arctic Reach modifies it by
    -- the same amount as Frost Nova, allowing both to share this range check.
    if spellName == "Cone of Cold" then
        return HasLivingEnemyTarget() and IsUnitInFrostNovaRange("target")
    end
    return GetSpellRangeState(spellName) ~= false
end

local function GetCounterspellAction()
    if not MageCore_Config or not MageCore_Config.AutoCounterspell then return nil end
    if not GetSpellBookIndex("Counterspell") then return nil end
    if not IsSpellReady("Counterspell") or not SpellCanReachTarget("Counterspell") then return nil end
    local targetSpell = GetTargetInterruptibleSpellName()
    if not targetSpell then return nil end
    if MageCore_Config.CounterspellHealingOnly and not IsHealingSpellName(targetSpell) then return nil end
    return "Counterspell"
end

local function ConfiguredSpellIsAutoRepeat(spellName)
    local index = GetSpellBookIndex(spellName)
    if not index then return false end
    if IsAutoRepeatSpell then return IsAutoRepeatSpell(index, BOOKTYPE_SPELL) end
    return false
end

local function IsConfiguredAutoRepeatActive(spellName)
    if autoRepeatActive then return true end
    local repeatTexture = NormalizeTexture(GetSpellTextureByName(spellName))
    if not repeatTexture then return false end
    local slot
    for slot = 1, 120 do
        local texture = GetActionTexture(slot)
        if texture and NormalizeTexture(texture) == repeatTexture and IsCurrentAction(slot) then
            return true
        end
    end
    return false
end

local function LoadDefaults()
    MageCore_Config = MageCore_Config or {}
    local i
    for i = 1, 6 do
        if MageCore_Config["Rotation" .. i] == nil then
            MageCore_Config["Rotation" .. i] = "None"
        end
        if MageCore_Config["Buff" .. i] == nil then
            MageCore_Config["Buff" .. i] = "None"
        end
    end
    if MageCore_Config.Opener == nil then MageCore_Config.Opener = "None" end
    if MageCore_Config.AutoBuff == nil then MageCore_Config.AutoBuff = true end
    if MageCore_Config.MinimapPos == nil then MageCore_Config.MinimapPos = 120 end
    if MageCore_Config.WaterSpell == nil then MageCore_Config.WaterSpell = "None" end
    if MageCore_Config.FoodSpell == nil then MageCore_Config.FoodSpell = "None" end
    if MageCore_Config.WaterAutoRank == nil then
        MageCore_Config.WaterAutoRank = MageCore_Config.WaterSpell ~= "None"
    end
    if MageCore_Config.FoodAutoRank == nil then
        MageCore_Config.FoodAutoRank = MageCore_Config.FoodSpell ~= "None"
    end
    if MageCore_Config.WaterMinimum == nil then MageCore_Config.WaterMinimum = 20 end
    if MageCore_Config.FoodMinimum == nil then MageCore_Config.FoodMinimum = 20 end
    if MageCore_Config.WaterMaximum == nil then
        MageCore_Config.WaterMaximum = math.max(80, tonumber(MageCore_Config.WaterMinimum) or 0)
    end
    if MageCore_Config.FoodMaximum == nil then
        MageCore_Config.FoodMaximum = math.max(80, tonumber(MageCore_Config.FoodMinimum) or 0)
    end
    MageCore_Config.WaterMaximum = math.max(
        tonumber(MageCore_Config.WaterMinimum) or 0,
        tonumber(MageCore_Config.WaterMaximum) or 0
    )
    MageCore_Config.FoodMaximum = math.max(
        tonumber(MageCore_Config.FoodMinimum) or 0,
        tonumber(MageCore_Config.FoodMaximum) or 0
    )
    if MageCore_Config.GroupIntellect == nil then MageCore_Config.GroupIntellect = false end
    if MageCore_Config.PvPMode == nil then MageCore_Config.PvPMode = false end
    if MageCore_Config.FrostNovaRange == nil then MageCore_Config.FrostNovaRange = false end
    if MageCore_Config.NameplateScale == nil then MageCore_Config.NameplateScale = 100 end
    MageCore_Config.NameplateScale = math.max(
        50, math.min(150, tonumber(MageCore_Config.NameplateScale) or 100)
    )
    if MageCore_Config.AutoCounterspell == nil then MageCore_Config.AutoCounterspell = false end
    if MageCore_Config.CounterspellHealingOnly == nil then MageCore_Config.CounterspellHealingOnly = false end
end

local function GetNextBuff()
    LoadDefaults()
    local seen = {}
    local i
    for i = 1, 6 do
        local spellName = MageCore_Config["Buff" .. i]
        if spellName and spellName ~= "None" and not seen[spellName] then
            seen[spellName] = true
            local learned = GetSpellBookIndex(spellName)
            -- Do not gate buffs through GetSpellCooldown. On the legacy client
            -- beneficial and self-only spells can report a disabled spellbook
            -- state even though CastSpellByName can cast them. WarlockCore's
            -- working buff queue also selects buffs solely by learned/aura state.
            if learned and not PlayerHasBuff(spellName) then
                return spellName
            end
        end
    end
    return nil
end

local function GetBuffDisplaySpell()
    local nextBuff = GetNextBuff()
    if nextBuff then return nextBuff end
    local i
    for i = 1, 6 do
        local spellName = MageCore_Config["Buff" .. i]
        if spellName and spellName ~= "None" and GetSpellBookIndex(spellName) then
            return spellName
        end
    end
    return nil
end

local function GetNextCombatSpell()
    LoadDefaults()
    local i
    for i = 1, 6 do
        local spellName = MageCore_Config["Rotation" .. i]
        if spellName and spellName ~= "None" and IsSpellReady(spellName) and SpellCanReachTarget(spellName) then
            if not ConfiguredSpellIsAutoRepeat(spellName) or not IsConfiguredAutoRepeatActive(spellName) then
                return spellName
            end
        end
    end
    return nil
end

local function GetPvpFrostboltSpell()
    local rankOne = "Frostbolt(Rank 1)"
    if not MageCore_Config.PvPMode or not HasLivingEnemyTarget() or TargetHasFrostSlow() then return nil end
    if pvpFrostboltUsedForTarget == GetTargetKey() then return nil end
    if not GetSpellBookIndex(rankOne) or not IsSpellReady(rankOne) or not SpellCanReachTarget(rankOne) then return nil end
    return rankOne
end

local function GetSoonestCooldownSpell()
    local bestSpell
    local bestRemaining
    local i
    for i = 1, 6 do
        local spellName = MageCore_Config["Rotation" .. i]
        if spellName and spellName ~= "None" and SpellCanReachTarget(spellName) then
            local remaining = GetSpellCooldownRemaining(spellName)
            if remaining and remaining > 0
                and (not bestRemaining or remaining < bestRemaining) then
                bestSpell = spellName
                bestRemaining = remaining
            end
        end
    end
    return bestSpell
end

local function GetOpenerSpell()
    if UnitAffectingCombat("player") or not HasLivingEnemyTarget() then return nil end
    local opener = MageCore_Config.Opener
    if not opener or opener == "None" then return nil end
    if openerUsedForTarget == GetTargetKey() then return nil end
    if not IsSpellReady(opener) or not SpellCanReachTarget(opener) then return nil end
    return opener
end

local function ShouldAutoBuffFromRotation()
    return MageCore_Config
        and MageCore_Config.AutoBuff
        and not UnitAffectingCombat("player")
end

local function GetGroupUnitKey(unit)
    return (UnitName(unit) or unit) .. ":" .. (UnitLevel(unit) or 0)
end

local function GroupUnitCanReceiveIntellect(unit)
    if not UnitExists(unit) or UnitIsDeadOrGhost(unit) then return false end
    if UnitIsConnected then
        local connected = UnitIsConnected(unit)
        if connected == nil or connected == false or connected == 0 then return false end
    end
    if UnitIsFriend then
        local friendly = UnitIsFriend("player", unit)
        if friendly == nil or friendly == false or friendly == 0 then return false end
    end
    local key = GetGroupUnitKey(unit)
    local blockedUntil = groupBlockedUnits[key]
    if blockedUntil and GetTime() < blockedUntil then return false end
    if blockedUntil then groupBlockedUnits[key] = nil end
    return not UnitHasBuff(unit, "Arcane Intellect")
end

local function GetNextGroupIntellectUnit()
    if not MageCore_Config.GroupIntellect or UnitAffectingCombat("player") then return nil end
    if not GetSpellBookIndex("Arcane Intellect") then return nil end

    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
    local i, unit
    if raidCount > 0 then
        for i = 1, raidCount do
            unit = "raid" .. i
            if GroupUnitCanReceiveIntellect(unit) then return unit end
        end
    elseif partyCount > 0 then
        if GroupUnitCanReceiveIntellect("player") then return "player" end
        for i = 1, partyCount do
            unit = "party" .. i
            if GroupUnitCanReceiveIntellect(unit) then return unit end
        end
    end
    return nil
end

local function CastGroupIntellect(unit)
    local hadTarget = UnitExists("target")
    local targetWasUnit = hadTarget and UnitIsUnit("target", unit)
    if not targetWasUnit then TargetUnit(unit) end
    lastGroupBuffAttempt = {
        unit = unit,
        key = GetGroupUnitKey(unit),
        time = GetTime()
    }
    CastSpellByName("Arcane Intellect")
    if SpellIsTargeting() then SpellTargetUnit(unit) end
    if not targetWasUnit then
        if hadTarget then TargetLastTarget() else ClearTarget() end
    end
end

local function GetBagItemCounts()
    local counts = {}
    local bag, slot
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, itemID = string.find(link, "item:(%d+)")
                local _, count = GetContainerItemInfo(bag, slot)
                if itemID then counts[itemID] = (counts[itemID] or 0) + (count or 1) end
            end
        end
    end
    return counts
end

local function GetItemCountByID(itemID)
    if not itemID then return 0 end
    return GetBagItemCounts()[tostring(itemID)] or 0
end

local function LearnPendingConjureItem()
    if not pendingConjure then return end
    if GetTime() - pendingConjure.started > 5 then
        pendingConjure = nil
        return
    end
    local current = GetBagItemCounts()
    local itemID, count
    for itemID, count in pairs(current) do
        if count > (pendingConjure.before[itemID] or 0) then
            MageCore_Config[pendingConjure.kind .. "ItemID"] = itemID
            pendingConjure = nil
            return
        end
    end
end

local function GetNextConjureAction()
    if UnitAffectingCombat("player") then return nil end
    if pendingConjure then
        if GetTime() - pendingConjure.started <= 5 then return "WAIT" end
        pendingConjure = nil
    end

    local kinds = { "Water", "Food" }
    local _, kind
    for _, kind in ipairs(kinds) do
        local spellName = MageCore_Config[kind .. "Spell"]
        local minimum = tonumber(MageCore_Config[kind .. "Minimum"]) or 0
        local maximum = math.max(minimum, tonumber(MageCore_Config[kind .. "Maximum"]) or minimum)
        if spellName and spellName ~= "None" and GetSpellBookIndex(spellName) and minimum > 0 then
            local itemID = MageCore_Config[kind .. "ItemID"]
            if not itemID then
                conjureRestockActive[kind] = true
                return spellName, kind
            end
            local count = GetItemCountByID(itemID)
            if count <= minimum then conjureRestockActive[kind] = true end
            if conjureRestockActive[kind] then
                if count >= maximum then
                    conjureRestockActive[kind] = nil
                else
                    return spellName, kind
                end
            end
        else
            conjureRestockActive[kind] = nil
        end
    end
    return nil
end

local function CastConjureSpell(spellName, kind)
    pendingConjure = {
        kind = kind,
        before = GetBagItemCounts(),
        started = GetTime()
    }
    CastSpellByName(spellName)
end

local function GetNextAction()
    local counterspell = GetCounterspellAction()
    if counterspell then return counterspell end
    local directPvp = ShouldGoDirectToPvpRotation()
    if not directPvp then
        local trackingSpell = GetFindMineralsAction()
        if trackingSpell then return trackingSpell end
        local conjureSpell = GetNextConjureAction()
        if conjureSpell and conjureSpell ~= "WAIT" then return conjureSpell end
        if ShouldAutoBuffFromRotation() then
            local buff = GetNextBuff()
            if buff then return buff end
        end
        if GetNextGroupIntellectUnit() then return "Arcane Intellect" end
    end
    -- With no enemy selected, preview the opener that Rotation will use after
    -- acquiring a target instead of falling through to Rotation Slot 1.
    if not UnitAffectingCombat("player") and not HasLivingEnemyTarget()
        and MageCore_Config.Opener and MageCore_Config.Opener ~= "None" then
        return MageCore_Config.Opener
    end
    local pvpFrostbolt = GetPvpFrostboltSpell()
    if pvpFrostbolt then return pvpFrostbolt end
    local opener = GetOpenerSpell()
    if opener then return opener end
    local combatSpell = GetNextCombatSpell()
    if combatSpell then return combatSpell end
    local cooldownSpell = GetSoonestCooldownSpell()
    if cooldownSpell then return cooldownSpell end
    if MageCore_Config.Opener and MageCore_Config.Opener ~= "None"
        and GetSpellBookIndex(MageCore_Config.Opener) then
        return MageCore_Config.Opener
    end
    local i
    for i = 1, 6 do
        local spellName = MageCore_Config["Rotation" .. i]
        if spellName and spellName ~= "None" and GetSpellBookIndex(spellName) then
            return spellName
        end
    end
    return nil
end

local function CastOnSelf(spellName)
    if not spellName then return end
    local hadTarget = UnitExists("target")
    local targetWasSelf = hadTarget and UnitIsUnit("target", "player")
    if not targetWasSelf then TargetUnit("player") end
    CastSpellByName(spellName)
    if SpellIsTargeting() then SpellTargetUnit("player") end
    if not targetWasSelf then
        if hadTarget then TargetLastTarget() else ClearTarget() end
    end
end

function MageCore_Buff()
    local buff = GetNextBuff()
    if buff then CastOnSelf(buff) end
end

function MageCore_Rotate()
    -- Repeated Rotation presses must not cancel Arcane Missiles, Blizzard,
    -- Evocation, or any other active channel.
    if channelInProgress then return end
    LoadDefaults()
    local counterspell = GetCounterspellAction()
    if counterspell then
        lastCombatSpellAttempt = {
            spell = counterspell,
            target = GetTargetKey(),
            time = GetTime()
        }
        CastSpellByName(counterspell)
        return
    end
    local directPvp = ShouldGoDirectToPvpRotation()
    if not directPvp then
        local trackingSpell = GetFindMineralsAction()
        if trackingSpell then
            CastSpellByName(trackingSpell)
            return
        end

        local conjureSpell, conjureKind = GetNextConjureAction()
        if conjureSpell == "WAIT" then return end
        if conjureSpell then
            CastConjureSpell(conjureSpell, conjureKind)
            return
        end

        if ShouldAutoBuffFromRotation() then
            local buff = GetNextBuff()
            if buff then
                CastOnSelf(buff)
                return
            end
        end

        local groupUnit = GetNextGroupIntellectUnit()
        if groupUnit then
            CastGroupIntellect(groupUnit)
            return
        end
    end

    if not HasLivingEnemyTarget() then TargetNearestEnemy() end
    if not HasLivingEnemyTarget() then return end

    local spellName = GetPvpFrostboltSpell()
    local isOpener = false
    if not spellName then
        spellName = GetOpenerSpell()
        isOpener = spellName ~= nil
    end
    if not spellName then spellName = GetNextCombatSpell() end
    if spellName then
        if isOpener then openerUsedForTarget = GetTargetKey() end
        if spellName == "Frostbolt(Rank 1)" then
            pvpFrostboltUsedForTarget = GetTargetKey()
        end
        lastCombatSpellAttempt = {
            spell = spellName,
            target = GetTargetKey(),
            time = GetTime(),
            opener = isOpener
        }
        if spellName == "Frostbolt(Rank 1)" then
            DEFAULT_CHAT_FRAME:AddMessage("MageCore: Using Rank 1 Frostbolt", 1, 1, 0)
        end
        CastSpellByName(spellName)
    end
end

local function GetMacroIndex(name, characterOnly)
    local generalCount, characterCount = GetNumMacros()
    local i
    if not characterOnly then
        for i = 1, generalCount do
            if GetMacroInfo(i) == name then return i end
        end
    end
    local first = (MAX_ACCOUNT_MACROS or 18) + 1
    for i = first, first + characterCount - 1 do
        if GetMacroInfo(i) == name then return i end
    end
    return 0
end

local function CreateOrUpdateMacro(name, body, spellName)
    local icon = TextureName(GetSpellTextureByName(spellName)) or DEFAULT_ICON
    local index = GetMacroIndex(name, true)
    if index == 0 then index = GetMacroIndex(name, false) end
    if index == 0 then
        index = CreateMacro(name, icon, body, nil, 1)
    else
        EditMacro(index, name, icon, body, nil, 1)
    end
    local characterIndex = GetMacroIndex(name, true)
    return characterIndex > 0 and characterIndex or index
end

local function GetActionButtons()
    if AllActionButtons then return AllActionButtons end
    local buttons = {}
    local prefixes = {
        "ActionButton", "MultiBarBottomLeftButton", "MultiBarBottomRightButton",
        "MultiBarRightButton", "MultiBarLeftButton"
    }
    local _, prefix
    for _, prefix in ipairs(prefixes) do
        local i
        for i = 1, 12 do
            local button = getglobal(prefix .. i)
            if button then table.insert(buttons, button) end
        end
    end
    return buttons
end

local function ShowRotationButtonTooltip(button)
    local spellName = GetNextAction()
    local spellIndex = spellName and GetSpellBookIndex(spellName)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    if spellIndex then
        GameTooltip:SetSpell(spellIndex, BOOKTYPE_SPELL)
    else
        GameTooltip:AddLine("MageCore Rotation")
        if spellName then
            GameTooltip:AddLine("Next: " .. spellName, 0.8, 0.8, 0.8)
        end
    end
    GameTooltip:Show()
end

local function HookRotationButtonTooltip(button)
    if button.mageCoreTooltipHooked then return end
    button.mageCoreTooltipHooked = true
    local originalOnEnter = button:GetScript("OnEnter")
    button:SetScript("OnEnter", function()
        if originalOnEnter then originalOnEnter() end
        local actionSlot = ActionButton_GetPagedID(this)
        if actionSlot and GetActionText(actionSlot) == "MageRot" then
            ShowRotationButtonTooltip(this)
        end
    end)
end

local function SetupRotationButtonTooltips()
    local _, button
    for _, button in ipairs(GetActionButtons()) do
        HookRotationButtonTooltip(button)
    end
end

local function UpdateRotationCooldown(spellName)
    local start, duration, enabled = 0, 0, 0
    if spellName and spellName ~= "None" then
        start, duration, enabled = GetSpellCooldownInfo(spellName)
        if start == nil then start, duration, enabled = 0, 0, 0 end
    end

    local _, button
    for _, button in ipairs(GetActionButtons()) do
        local actionSlot = ActionButton_GetPagedID(button)
        if actionSlot and GetActionText(actionSlot) == "MageRot" then
            local cooldown = getglobal(button:GetName() .. "Cooldown")
            if cooldown then CooldownFrame_SetTimer(cooldown, start, duration, enabled) end
        end
    end
end

local function UpdateRotationManaState(spellName)
    local manaCost = GetSpellManaCost(spellName)
    local insufficient = manaCost and UnitMana("player") < manaCost
    local outOfRange = GetSpellRangeState(spellName) == false
    local red, green, blue = 1, 1, 1
    if outOfRange then
        red, green, blue = 1, 0.1, 0.1
    elseif insufficient then
        red, green, blue = 0.4, 0.4, 0.4
    end

    if rotationIconTexture then rotationIconTexture:SetVertexColor(red, green, blue) end
    local _, button
    for _, button in ipairs(GetActionButtons()) do
        local actionSlot = ActionButton_GetPagedID(button)
        if actionSlot and GetActionText(actionSlot) == "MageRot" then
            local icon = getglobal(button:GetName() .. "Icon")
            if icon then icon:SetVertexColor(red, green, blue) end
        end
    end
end

local function StyleButton(button)
    button:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    button:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
    button:SetBackdropBorderColor(0.25, 0.65, 0.9, 1)
end

local function ToggleMenu()
    if not MageCoreMenuFrame then MageCore_CreateMenu() end
    if MageCoreMenuFrame:IsShown() then MageCoreMenuFrame:Hide() else MageCoreMenuFrame:Show() end
end

local function PrintSpellBookDebug()
    RefreshSpellBook()
    local rotationNames = ""
    local buffNames = ""
    local i
    for i = 2, table.getn(spellBookSpells) do
        rotationNames = rotationNames .. (rotationNames == "" and "" or ", ") .. spellBookSpells[i]
    end
    for i = 2, table.getn(helpfulSpellBookSpells) do
        buffNames = buffNames .. (buffNames == "" and "" or ", ") .. helpfulSpellBookSpells[i]
    end
    DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "MageCore spellbook debug:|r")
    DEFAULT_CHAT_FRAME:AddMessage("Rotation (" .. (table.getn(spellBookSpells) - 1) .. "): " .. (rotationNames ~= "" and rotationNames or "NONE FOUND"))
    DEFAULT_CHAT_FRAME:AddMessage("Buffs (" .. (table.getn(helpfulSpellBookSpells) - 1) .. "): " .. (buffNames ~= "" and buffNames or "NONE FOUND"))
end

local function SlashCommand(message)
    local command = string.lower(message or "")
    command = string.gsub(command, "^%s+", "")
    command = string.gsub(command, "%s+$", "")
    if command == "debug" then
        PrintSpellBookDebug()
    else
        ToggleMenu()
    end
end

function MageCore_CreateMenu()
    if MageCoreMenuFrame then return end
    LoadDefaults()
    -- Re-scan here as well as at login; some Turtle clients populate class
    -- spellbook tabs after PLAYER_LOGIN has already fired.
    RefreshSpellBook()

    local frame = CreateFrame("Frame", "MageCoreMenuFrame", UIParent)
    MageCoreMenuFrame = frame
    frame:SetWidth(430)
    frame:SetHeight(440)
    frame:SetPoint("CENTER", 0, 0)
    frame:SetFrameStrata("HIGH")
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    frame:SetBackdropColor(0, 0.03, 0.08, 0.97)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() this:StartMoving() end)
    frame:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText(ACCENT .. "MageCore v" .. VERSION .. "|r")

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)
    close:SetScript("OnClick", function() frame:Hide() end)

    local rotationPanel = CreateFrame("Frame", nil, frame)
    rotationPanel:SetWidth(400); rotationPanel:SetHeight(330)
    rotationPanel:SetPoint("TOPLEFT", 15, -90)
    local buffPanel = CreateFrame("Frame", nil, frame)
    buffPanel:SetWidth(400); buffPanel:SetHeight(330)
    buffPanel:SetPoint("TOPLEFT", 15, -90)
    buffPanel:Hide()
    local foodPanel = CreateFrame("Frame", nil, frame)
    foodPanel:SetWidth(400); foodPanel:SetHeight(330)
    foodPanel:SetPoint("TOPLEFT", 15, -90)
    foodPanel:Hide()
    local infoPanel = CreateFrame("Frame", nil, frame)
    infoPanel:SetWidth(400); infoPanel:SetHeight(330)
    infoPanel:SetPoint("TOPLEFT", 15, -90)
    infoPanel:Hide()

    local rotationTab, buffTab, foodTab, infoTab
    local function ShowTab(tab)
        rotationPanel:Hide(); buffPanel:Hide(); foodPanel:Hide(); infoPanel:Hide()
        rotationTab:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
        buffTab:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
        foodTab:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
        infoTab:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
        if tab == 1 then
            rotationPanel:Show(); rotationTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)
        elseif tab == 2 then
            buffPanel:Show(); buffTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)
        elseif tab == 3 then
            foodPanel:Show(); foodTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)
        else
            infoPanel:Show(); infoTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)
        end
    end

    local function MakeTab(text, x, tab)
        local button = CreateFrame("Button", nil, frame)
        button:SetWidth(95); button:SetHeight(26); button:SetPoint("TOPLEFT", x, -50)
        StyleButton(button)
        local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER", 0, 0); label:SetText(text)
        button:SetScript("OnClick", function() ShowTab(tab) end)
        return button
    end

    rotationTab = MakeTab("Rotation", 20, 1)
    buffTab = MakeTab("Buffs", 120, 2)
    foodTab = MakeTab("Food", 220, 3)
    infoTab = MakeTab("Info", 320, 4)
    rotationTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)

    local rotationHelp = rotationPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rotationHelp:SetPoint("TOPLEFT", 10, 0); rotationHelp:SetWidth(375); rotationHelp:SetJustifyH("LEFT")
    rotationHelp:SetText("After out-of-combat maintenance, Opener is cast once on a new target. Later presses use the first ready rotation spell.")

    local buffHelp = buffPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    buffHelp:SetPoint("TOPLEFT", 10, 0); buffHelp:SetWidth(375); buffHelp:SetJustifyH("LEFT")
    buffHelp:SetText("Choose learned mage buffs. Auto Buff ON applies these through Rotation while out of combat; OFF uses the separate Buff button.")

    local foodTitle = foodPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    foodTitle:SetPoint("TOPLEFT", 18, -8)
    foodTitle:SetText(ACCENT .. "Food|r")

    local foodHelp = foodPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    foodHelp:SetPoint("TOPLEFT", 18, -48)
    foodHelp:SetWidth(350)
    foodHelp:SetJustifyH("LEFT")
    foodHelp:SetText("Choose Highest or an exact rank. At the minimum, Rotation restocks out of combat until the maximum.")

    local function FindConjureDisplay(options, castName)
        local _, entry
        for _, entry in ipairs(options) do
            if entry.cast == castName then return entry.display end
        end
        return "None"
    end

    local function MakeConjureDrop(label, kind, options, x, y)
        local labelText = foodPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        labelText:SetPoint("TOPLEFT", x + 15, y)
        labelText:SetText(ACCENT .. label .. "|r")
        local dropdown = CreateFrame("Frame", "MC_ConjureDrop_" .. kind, foodPanel, "UIDropDownMenuTemplate")
        dropdown:SetPoint("TOPLEFT", x, y - 16)
        UIDropDownMenu_SetWidth(155, dropdown)
        UIDropDownMenu_Initialize(dropdown, function()
            local menuOptions = kind == "Water" and knownWaterSpells or knownFoodSpells
            local noneInfo = {}
            noneInfo.text = "None"; noneInfo.value = "None"
            noneInfo.func = function()
                MageCore_Config[kind .. "Spell"] = "None"
                MageCore_Config[kind .. "AutoRank"] = false
                MageCore_Config[kind .. "ItemID"] = nil
                conjureRestockActive[kind] = nil
                pendingConjure = nil
                UIDropDownMenu_SetSelectedValue(dropdown, "None")
                UIDropDownMenu_SetText("None", dropdown)
            end
            UIDropDownMenu_AddButton(noneInfo)
            local highest = menuOptions[1]
            if highest then
                local autoInfo = {}
                autoInfo.text = highest.rankText and "Highest (" .. highest.rankText .. ")" or "Highest learned"
                autoInfo.value = "AUTO"
                autoInfo.func = function()
                    MageCore_Config[kind .. "Spell"] = highest.cast
                    MageCore_Config[kind .. "AutoRank"] = true
                    MageCore_Config[kind .. "ItemID"] = nil
                    conjureRestockActive[kind] = nil
                    pendingConjure = nil
                    UIDropDownMenu_SetSelectedValue(dropdown, "AUTO")
                    UIDropDownMenu_SetText(autoInfo.text, dropdown)
                end
                UIDropDownMenu_AddButton(autoInfo)
            end
            local _, entry
            for _, entry in ipairs(menuOptions) do
                local selected = entry
                local info = {}
                info.text = selected.display; info.value = selected.cast
                info.func = function()
                    MageCore_Config[kind .. "Spell"] = selected.cast
                    MageCore_Config[kind .. "AutoRank"] = false
                    MageCore_Config[kind .. "ItemID"] = nil
                    conjureRestockActive[kind] = nil
                    pendingConjure = nil
                    UIDropDownMenu_SetSelectedValue(dropdown, selected.cast)
                    UIDropDownMenu_SetText(selected.display, dropdown)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        local current = MageCore_Config[kind .. "Spell"] or "None"
        if MageCore_Config[kind .. "AutoRank"] and options[1] then
            local highestText = options[1].rankText and "Highest (" .. options[1].rankText .. ")" or "Highest learned"
            UIDropDownMenu_SetSelectedValue(dropdown, "AUTO")
            UIDropDownMenu_SetText(highestText, dropdown)
        else
            UIDropDownMenu_SetSelectedValue(dropdown, current)
            UIDropDownMenu_SetText(FindConjureDisplay(options, current), dropdown)
        end
    end

    local function MakeThresholdBox(label, kind, threshold, x, y)
        local labelText = foodPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        labelText:SetPoint("TOPLEFT", x, y)
        labelText:SetText(ACCENT .. label .. "|r")
        local box = CreateFrame("EditBox", "MC_" .. kind .. threshold, foodPanel)
        box:SetWidth(65); box:SetHeight(28); box:SetPoint("TOPLEFT", x, y - 20)
        box:SetNumeric(true); box:SetMaxLetters(3); box:SetAutoFocus(false)
        box:SetFontObject("GameFontHighlightSmall")
        StyleButton(box)
        box:SetText(MageCore_Config[kind .. threshold] or (threshold == "Minimum" and 20 or 80))
        box:SetTextInsets(8, 8, 0, 0)
        local function SaveThreshold()
            local value = tonumber(box:GetText()) or 0
            value = math.max(0, math.min(999, math.floor(value)))
            if threshold == "Maximum" then
                value = math.max(value, tonumber(MageCore_Config[kind .. "Minimum"]) or 0)
            end
            MageCore_Config[kind .. threshold] = value
            if threshold == "Minimum" then
                local maximum = tonumber(MageCore_Config[kind .. "Maximum"]) or 0
                if maximum < value then
                    MageCore_Config[kind .. "Maximum"] = value
                    local maximumBox = getglobal("MC_" .. kind .. "Maximum")
                    if maximumBox then maximumBox:SetText(value) end
                end
            end
            box:SetText(value)
        end
        box:SetScript("OnEnterPressed", function() SaveThreshold(); this:ClearFocus() end)
        box:SetScript("OnEditFocusLost", SaveThreshold)
        box:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    end

    MakeConjureDrop("Water spell:", "Water", knownWaterSpells, 0, -92)
    MakeConjureDrop("Food spell:", "Food", knownFoodSpells, 200, -92)
    MakeThresholdBox("Minimum water:", "Water", "Minimum", 18, -174)
    MakeThresholdBox("Minimum food:", "Food", "Minimum", 218, -174)
    MakeThresholdBox("Maximum water:", "Water", "Maximum", 18, -220)
    MakeThresholdBox("Maximum food:", "Food", "Maximum", 218, -220)

    foodStatusText = foodPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    foodStatusText:SetPoint("TOPLEFT", 18, -285)
    foodStatusText:SetWidth(350); foodStatusText:SetJustifyH("LEFT")
    foodStatusText:SetText("Select a spell to begin tracking its conjured item.")

    local function MakeDrop(parent, label, key, x, y, helpfulOnly)
        local labelText = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        labelText:SetPoint("TOPLEFT", x + 15, y); labelText:SetText(ACCENT .. label .. "|r")
        local dropdown = CreateFrame("Frame", "MC_Drop_" .. key, parent, "UIDropDownMenuTemplate")
        dropdown:SetPoint("TOPLEFT", x, y - 15)
        UIDropDownMenu_SetWidth(145, dropdown)
        UIDropDownMenu_Initialize(dropdown, function()
            local list = helpfulOnly and helpfulSpellBookSpells or spellBookSpells
            local _, value
            for _, value in ipairs(list) do
                local selected = value
                local info = {}
                info.text = value; info.value = value
                info.func = function()
                    MageCore_Config[key] = selected
                    UIDropDownMenu_SetSelectedValue(dropdown, selected)
                    UIDropDownMenu_SetText(selected, dropdown)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        local current = MageCore_Config[key] or "None"
        UIDropDownMenu_SetSelectedValue(dropdown, current)
        UIDropDownMenu_SetText(current, dropdown)
    end

    MakeDrop(rotationPanel, "Opener:", "Opener", 100, -45)

    local positions = {
        { 0, -102 }, { 200, -102 }, { 0, -158 },
        { 200, -158 }, { 0, -214 }, { 200, -214 }
    }
    local i
    for i = 1, 6 do
        MakeDrop(rotationPanel, "Rotation Slot " .. i .. ":", "Rotation" .. i, positions[i][1], positions[i][2])
        MakeDrop(buffPanel, "Buff Slot " .. i .. ":", "Buff" .. i, positions[i][1], positions[i][2], true)
    end

    local dragRotation = CreateFrame("Button", nil, rotationPanel)
    dragRotation:SetWidth(48); dragRotation:SetHeight(48); dragRotation:SetPoint("TOPLEFT", 18, -272)
    StyleButton(dragRotation)
    rotationIconTexture = dragRotation:CreateTexture(nil, "OVERLAY")
    rotationIconTexture:SetPoint("TOPLEFT", 4, -4); rotationIconTexture:SetPoint("BOTTOMRIGHT", -4, 4)
    rotationIconTexture:SetTexture(ICON_PATH .. DEFAULT_ICON)
    dragRotation:RegisterForDrag("LeftButton")
    dragRotation:SetScript("OnDragStart", function()
        local index = CreateOrUpdateMacro("MageRot", "/script MageCore_Rotate()", GetNextAction())
        if index and index > 0 then PickupMacro(index) end
    end)
    dragRotation:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("MageCore Rotation")
        GameTooltip:AddLine("Out of combat: applies configured buffs.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("In combat: uses attack rotation.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag onto an action bar.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    dragRotation:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local rotationLabel = rotationPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rotationLabel:SetPoint("LEFT", dragRotation, "RIGHT", 10, 0)
    rotationLabel:SetText("Drag Rotation to your action bar")

    local autoButton = CreateFrame("Button", nil, buffPanel)
    autoButton:SetWidth(150); autoButton:SetHeight(32); autoButton:SetPoint("TOPLEFT", 8, -286)
    StyleButton(autoButton)
    local autoText = autoButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoText:SetPoint("CENTER", 0, 0)
    local function UpdateAutoText()
        autoText:SetText("Auto Buff OOC: " .. (MageCore_Config.AutoBuff and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    end
    UpdateAutoText()
    autoButton:SetScript("OnClick", function()
        MageCore_Config.AutoBuff = not MageCore_Config.AutoBuff
        UpdateAutoText()
    end)

    local groupButton = CreateFrame("Button", nil, buffPanel)
    groupButton:SetWidth(150); groupButton:SetHeight(32); groupButton:SetPoint("TOPLEFT", 242, -286)
    StyleButton(groupButton)
    local groupText = groupButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    groupText:SetPoint("CENTER", 0, 0)
    local function UpdateGroupText()
        groupText:SetText("Group Intellect: " .. (MageCore_Config.GroupIntellect and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    end
    UpdateGroupText()
    groupButton:SetScript("OnClick", function()
        MageCore_Config.GroupIntellect = not MageCore_Config.GroupIntellect
        groupBlockedUnits = {}
        UpdateGroupText()
    end)
    groupButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Group Intellect")
        GameTooltip:AddLine("Out of combat, Rotation buffs party and raid members missing Arcane Intellect.", 0.8, 0.8, 0.8, 1, true)
        GameTooltip:Show()
    end)
    groupButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local dragBuff = CreateFrame("Button", nil, buffPanel)
    dragBuff:SetWidth(48); dragBuff:SetHeight(48); dragBuff:SetPoint("TOPLEFT", 176, -278)
    StyleButton(dragBuff)
    buffIconTexture = dragBuff:CreateTexture(nil, "OVERLAY")
    buffIconTexture:SetPoint("TOPLEFT", 4, -4); buffIconTexture:SetPoint("BOTTOMRIGHT", -4, 4)
    buffIconTexture:SetTexture(ICON_PATH .. "Spell_Holy_MagicalSentry")
    dragBuff:RegisterForDrag("LeftButton")
    dragBuff:SetScript("OnDragStart", function()
        local index = CreateOrUpdateMacro("MageBuff", "/script MageCore_Buff()", GetNextBuff())
        if index and index > 0 then PickupMacro(index) end
    end)
    dragBuff:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("MageCore Buff")
        GameTooltip:AddLine("Drag onto an action bar for a buff-only button.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    dragBuff:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local buffLabel = buffPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    buffLabel:SetPoint("BOTTOM", dragBuff, "TOP", 0, 2); buffLabel:SetText("Buff only")

    local infoTitle = infoPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    infoTitle:SetPoint("TOPLEFT", 18, -8)
    infoTitle:SetText(ACCENT .. "MageCore v" .. VERSION .. "|r")

    local infoText = infoPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    infoText:SetPoint("TOPLEFT", 18, -48)
    infoText:SetWidth(350)
    infoText:SetJustifyH("LEFT")
    infoText:SetText("Mage rotation and buff helper for Turtle WoW.\n\nOpen the window with |cffffffff/mc|r or |cffffffff/magecore|r.\n\nSpell choices are read automatically from your mage spellbook.")

    local reloadButton = CreateFrame("Button", nil, infoPanel)
    reloadButton:SetWidth(160); reloadButton:SetHeight(32)
    reloadButton:SetPoint("TOPLEFT", 18, -225)
    StyleButton(reloadButton)
    local reloadText = reloadButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    reloadText:SetPoint("CENTER", 0, 0); reloadText:SetText("Reload UI")
    reloadButton:SetScript("OnClick", function() ReloadUI() end)

    local nameplateSlider = CreateFrame("Slider", "MageCoreNameplateScaleSlider", infoPanel, "OptionsSliderTemplate")
    nameplateSlider:SetWidth(160); nameplateSlider:SetHeight(16)
    nameplateSlider:SetPoint("TOPLEFT", 205, -230)
    nameplateSlider:SetMinMaxValues(50, 150)
    nameplateSlider:SetValueStep(5)
    nameplateSlider:SetValue(MageCore_Config.NameplateScale or 100)
    local nameplateSliderLow = getglobal("MageCoreNameplateScaleSliderLow")
    local nameplateSliderHigh = getglobal("MageCoreNameplateScaleSliderHigh")
    local nameplateSliderText = getglobal("MageCoreNameplateScaleSliderText")
    if nameplateSliderLow then nameplateSliderLow:SetText("50%") end
    if nameplateSliderHigh then nameplateSliderHigh:SetText("150%") end
    local function UpdateNameplateSliderText()
        if nameplateSliderText then
            nameplateSliderText:SetText("Nameplate Size: " .. (MageCore_Config.NameplateScale or 100) .. "%")
        end
    end
    UpdateNameplateSliderText()
    nameplateSlider:SetScript("OnValueChanged", function()
        local value = math.floor(this:GetValue() + 0.5)
        MageCore_Config.NameplateScale = value
        UpdateNameplateSliderText()
        ApplyNameplateScale()
    end)

    local pvpButton = CreateFrame("Button", nil, infoPanel)
    pvpButton:SetWidth(160); pvpButton:SetHeight(32)
    pvpButton:SetPoint("TOPLEFT", 18, -170)
    StyleButton(pvpButton)
    local pvpText = pvpButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pvpText:SetPoint("CENTER", 0, 0)
    local function UpdatePvpText()
        pvpText:SetText("PvP Mode: " .. (MageCore_Config.PvPMode and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    end
    UpdatePvpText()
    pvpButton:SetScript("OnClick", function()
        MageCore_Config.PvPMode = not MageCore_Config.PvPMode
        UpdatePvpText()
    end)
    pvpButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("PvP Mode")
        GameTooltip:AddLine("With an enemy targeted, skips maintenance and uses Rank 1 Frostbolt once per newly acquired target when the enemy is not already slowed by a frost effect.", 0.8, 0.8, 0.8, 1, true)
        GameTooltip:Show()
    end)
    pvpButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local novaRangeButton = CreateFrame("Button", nil, infoPanel)
    novaRangeButton:SetWidth(160); novaRangeButton:SetHeight(32)
    novaRangeButton:SetPoint("TOPLEFT", 205, -170)
    StyleButton(novaRangeButton)
    local novaRangeText = novaRangeButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    novaRangeText:SetPoint("CENTER", 0, 0)
    local function UpdateNovaRangeText()
        novaRangeText:SetText("Nova Range: " .. (MageCore_Config.FrostNovaRange and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    end
    UpdateNovaRangeText()
    novaRangeButton:SetScript("OnClick", function()
        MageCore_Config.FrostNovaRange = not MageCore_Config.FrostNovaRange
        if not MageCore_Config.FrostNovaRange then HideFrostNovaRangeIndicators() end
        UpdateNovaRangeText()
    end)
    novaRangeButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Frost Nova Range")
        GameTooltip:AddLine("Shows a flashing red and yellow border around hostile nameplates within Frost Nova's detected " .. frostNovaRangeYards .. "-yard range. Arctic Reach rank " .. arcticReachRank .. "/2 is detected from your spellbook. SuperWoW enables detection for every nameplate; without it, the current target is supported.", 0.8, 0.8, 0.8, 1, true)
        GameTooltip:Show()
    end)
    novaRangeButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local counterspellButton = CreateFrame("Button", nil, infoPanel)
    counterspellButton:SetWidth(160); counterspellButton:SetHeight(32)
    counterspellButton:SetPoint("TOPLEFT", 18, -115)
    StyleButton(counterspellButton)
    local counterspellText = counterspellButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    counterspellText:SetPoint("CENTER", 0, 0)
    local function UpdateCounterspellText()
        counterspellText:SetText("Counterspell: " .. (MageCore_Config.AutoCounterspell and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    end
    UpdateCounterspellText()
    counterspellButton:SetScript("OnClick", function()
        MageCore_Config.AutoCounterspell = not MageCore_Config.AutoCounterspell
        UpdateCounterspellText()
    end)
    counterspellButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Counterspell")
        GameTooltip:AddLine("When your current enemy target is casting an interruptible spell, Rotation uses Counterspell before all other actions.", 0.8, 0.8, 0.8, 1, true)
        GameTooltip:Show()
    end)
    counterspellButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local healingOnlyButton = CreateFrame("Button", nil, infoPanel)
    healingOnlyButton:SetWidth(160); healingOnlyButton:SetHeight(32)
    healingOnlyButton:SetPoint("TOPLEFT", 205, -115)
    StyleButton(healingOnlyButton)
    local healingOnlyText = healingOnlyButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    healingOnlyText:SetPoint("CENTER", 0, 0)
    local function UpdateHealingOnlyText()
        healingOnlyText:SetText("Healing Only: " .. (MageCore_Config.CounterspellHealingOnly and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    end
    UpdateHealingOnlyText()
    healingOnlyButton:SetScript("OnClick", function()
        MageCore_Config.CounterspellHealingOnly = not MageCore_Config.CounterspellHealingOnly
        UpdateHealingOnlyText()
    end)
    healingOnlyButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Healing Only")
        GameTooltip:AddLine("When Counterspell is enabled, Rotation interrupts recognized healing spells and ignores other casts.", 0.8, 0.8, 0.8, 1, true)
        GameTooltip:Show()
    end)
    healingOnlyButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame:Show()
end

local function GetMinimapRadius()
    local size = Minimap:GetWidth() or 140
    return math.max(70, math.min(90, size / 2 + 8))
end

local function GetRestedXPString()
    local restedXP = GetXPExhaustion() or 0
    local levelXP = UnitXPMax("player") or 0
    if levelXP <= 0 then return "0%" end
    local percent = math.floor(100 * restedXP / levelXP)
    if percent >= 112 then return "MAX" end
    return percent .. "%"
end

function MageCore_Minimap_UpdatePosition()
    if not MageCoreMinimapButton or not MageCore_Config then return end
    local angle = math.rad(MageCore_Config.MinimapPos or 120)
    local radius = GetMinimapRadius()
    MageCoreMinimapButton:ClearAllPoints()
    MageCoreMinimapButton:SetPoint("CENTER", "Minimap", "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

function MageCore_Minimap_OnUpdate()
    local x, y = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    x = x / scale; y = y / scale
    local centerX = Minimap:GetLeft() + Minimap:GetWidth() / 2
    local centerY = Minimap:GetBottom() + Minimap:GetHeight() / 2
    local dx, dy = x - centerX, y - centerY
    MageCore_Config.MinimapPos = math.deg(math.atan2(dy, dx))
    MageCore_Minimap_UpdatePosition()
end

local function CreateMinimapButton()
    if MageCoreMinimapButton then return end
    local button = CreateFrame("Button", "MageCoreMinimapButton", Minimap)
    button:SetWidth(32); button:SetHeight(32)
    button:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    button:EnableMouse(true); button:SetMovable(true); button:RegisterForDrag("LeftButton")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON_PATH .. DEFAULT_ICON); icon:SetPoint("CENTER", 0, 0)
    icon:SetWidth(20); icon:SetHeight(20); icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(52); border:SetHeight(52); border:SetPoint("TOPLEFT", 0, 0)
    button:SetScript("OnClick", ToggleMenu)
    button:SetScript("OnDragStart", function()
        this:StartMoving(); this:SetScript("OnUpdate", MageCore_Minimap_OnUpdate)
    end)
    button:SetScript("OnDragStop", function()
        this:StopMovingOrSizing(); this:SetScript("OnUpdate", nil); MageCore_Minimap_UpdatePosition()
    end)
    button:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:AddLine(ACCENT .. "MageCore v" .. VERSION .. "|r")
        GameTooltip:AddLine("Currently |cff00ff00" .. GetRestedXPString() .. "|r Rested", 1, 1, 1)
        GameTooltip:AddLine("Left-click to open", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag to move", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    MageCore_Minimap_UpdatePosition()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("VARIABLES_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")
eventFrame:RegisterEvent("START_AUTOREPEAT_SPELL")
eventFrame:RegisterEvent("STOP_AUTOREPEAT_SPELL")
eventFrame:RegisterEvent("BAG_UPDATE")
eventFrame:RegisterEvent("SPELLCAST_FAILED")
eventFrame:RegisterEvent("SPELLCAST_INTERRUPTED")
eventFrame:RegisterEvent("SPELLCAST_START")
eventFrame:RegisterEvent("SPELLCAST_STOP")
eventFrame:RegisterEvent("SPELLCAST_CHANNEL_START")
eventFrame:RegisterEvent("SPELLCAST_CHANNEL_STOP")
eventFrame:RegisterEvent("UI_ERROR_MESSAGE")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        LoadDefaults()
    elseif event == "PLAYER_LOGIN" then
        LoadDefaults(); RefreshSpellBook(); CreateMinimapButton(); SetupRotationButtonTooltips()
        SLASH_MAGECORE1 = "/mc"
        SLASH_MAGECORE2 = "/magecore"
        SlashCmdList["MAGECORE"] = SlashCommand
        DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "MageCore v" .. VERSION .. "|r loaded. Type |cffffffff/mc|r to open.")
    elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
        RefreshSpellBook()
    elseif event == "START_AUTOREPEAT_SPELL" then
        autoRepeatActive = true
    elseif event == "STOP_AUTOREPEAT_SPELL" then
        autoRepeatActive = false
    elseif event == "BAG_UPDATE" then
        LearnPendingConjureItem()
    elseif event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
        normalCastInProgress = false
        channelInProgress = false
        pendingConjure = nil
        if lastCombatSpellAttempt and lastCombatSpellAttempt.opener
            and GetTime() - lastCombatSpellAttempt.time < 1.5 then
            openerUsedForTarget = nil
        end
    elseif event == "SPELLCAST_START" then
        normalCastInProgress = true
    elseif event == "SPELLCAST_STOP" then
        normalCastInProgress = false
    elseif event == "SPELLCAST_CHANNEL_START" then
        channelInProgress = true
    elseif event == "SPELLCAST_CHANNEL_STOP" then
        channelInProgress = false
    elseif event == "UI_ERROR_MESSAGE" then
        local message = string.lower(arg1 or "")
        local outOfRange = (SPELL_FAILED_OUT_OF_RANGE and arg1 == SPELL_FAILED_OUT_OF_RANGE)
            or string.find(message, "out of range", 1, true)
            or string.find(message, "too far away", 1, true)
            or string.find(message, "line of sight", 1, true)
        if outOfRange and lastGroupBuffAttempt
            and GetTime() - lastGroupBuffAttempt.time < 1.5 then
            groupBlockedUnits[lastGroupBuffAttempt.key] = GetTime() + 5
            lastGroupBuffAttempt = nil
        elseif outOfRange and lastCombatSpellAttempt
            and GetTime() - lastCombatSpellAttempt.time < 1.5 then
            if lastCombatSpellAttempt.opener then openerUsedForTarget = nil end
            rangeBlockedSpells[lastCombatSpellAttempt.spell] = {
                target = lastCombatSpellAttempt.target,
                expires = GetTime() + 2.5
            }
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        rangeBlockedSpells = {}
        lastCombatSpellAttempt = nil
        openerUsedForTarget = nil
        pvpFrostboltUsedForTarget = nil
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        groupBlockedUnits = {}
        lastGroupBuffAttempt = nil
    end
end)

eventFrame:SetScript("OnUpdate", function()
    frostNovaRangeElapsed = frostNovaRangeElapsed + (arg1 or 0)
    if frostNovaRangeElapsed >= 0.1 then
        frostNovaRangeElapsed = 0
        UpdateFrostNovaRangeIndicators()
    end

    updateElapsed = updateElapsed + (arg1 or 0)
    if updateElapsed < 0.4 then return end
    updateElapsed = 0
    if not MageCore_Config then return end
    if pendingConjure then LearnPendingConjureItem() end

    if foodStatusText then
        local waterSpell = MageCore_Config.WaterSpell or "None"
        local foodSpell = MageCore_Config.FoodSpell or "None"
        local waterState = "disabled"
        local foodState = "disabled"
        if waterSpell ~= "None" then
            if MageCore_Config.WaterItemID then
                waterState = GetItemCountByID(MageCore_Config.WaterItemID)
                    .. " (min " .. (MageCore_Config.WaterMinimum or 0)
                    .. ", max " .. (MageCore_Config.WaterMaximum or 0) .. ")"
            else
                waterState = "learns item on first conjure"
            end
        end
        if foodSpell ~= "None" then
            if MageCore_Config.FoodItemID then
                foodState = GetItemCountByID(MageCore_Config.FoodItemID)
                    .. " (min " .. (MageCore_Config.FoodMinimum or 0)
                    .. ", max " .. (MageCore_Config.FoodMaximum or 0) .. ")"
            else
                foodState = "learns item on first conjure"
            end
        end
        foodStatusText:SetText("Water: " .. waterState .. "\nFood: " .. foodState)
    end

    if not normalCastInProgress and not channelInProgress then
        local nextAction = GetNextAction()
        local rotationTexture = GetSpellTextureByName(nextAction) or ICON_PATH .. DEFAULT_ICON
        if rotationIconTexture then rotationIconTexture:SetTexture(rotationTexture) end
        local rotationMacroIcon = TextureName(rotationTexture) or DEFAULT_ICON
        if rotationMacroIcon ~= lastRotationIcon then
            local index = GetMacroIndex("MageRot", false)
            if index > 0 then EditMacro(index, "MageRot", rotationMacroIcon, "/script MageCore_Rotate()", nil, nil) end
            lastRotationIcon = rotationMacroIcon
        end
        UpdateRotationCooldown(nextAction)
        UpdateRotationManaState(nextAction)
    end

    local nextBuff = GetBuffDisplaySpell()
    local buffTexture = GetSpellTextureByName(nextBuff) or ICON_PATH .. "Spell_Holy_MagicalSentry"
    if buffIconTexture then buffIconTexture:SetTexture(buffTexture) end
    local buffMacroIcon = TextureName(buffTexture) or "Spell_Holy_MagicalSentry"
    if buffMacroIcon ~= lastBuffIcon then
        local index = GetMacroIndex("MageBuff", false)
        if index > 0 then EditMacro(index, "MageBuff", buffMacroIcon, "/script MageCore_Buff()", nil, nil) end
        lastBuffIcon = buffMacroIcon
    end
end)
