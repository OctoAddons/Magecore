-- MageCore v1.5.83
-- Press-driven mage rotation and self-buff helper for Turtle WoW / Vanilla 1.12.

local _, playerClass = UnitClass("player")
if playerClass ~= "MAGE" then return end

local VERSION = "1.5.83"
local ICON_PATH = "Interface\\Icons\\"
local DEFAULT_ICON = "Spell_Frost_FrostBolt02"
local ACCENT = "|cff69ccf0"

local spellBookSpells = { "None" }
local helpfulSpellBookSpells = { "None" }
local knownWaterSpells = {}
local knownFoodSpells = {}
local pendingConjure
local pendingManaAgate
local conjureRestockActive = {}
local lastManaAgateBagWarning = -10
local lastManaAgateSpellWarning = -10
local lastCombatSpellAttempt
local rangeBlockedSpells = {}
local openerUsedForTarget
local pvpFrostboltUsedForTarget
local fireThreatTargets = {}
local lastGroupBuffAttempt
local groupBlockedUnits = {}
local normalCastInProgress = false
local channelInProgress = false
local channelSpellName
local arcaneSurgeAvailableUntil = 0
local pendingLunaInterruptMessage
local iceBlockGuardStartedAt
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

-- These beneficial spells can be cast on another friendly player. Self-only
-- buffs remain available on the Buff button, but are skipped for group members.
local MAGE_GROUP_BUFF_NAMES = {
    ["Arcane Intellect"] = true,
    ["Arcane Brilliance"] = true,
    ["Amplify Magic"] = true,
    ["Dampen Magic"] = true
}

-- These situational buffs should never be spread across the whole group.
-- When a friendly group member is selected, that player is handled first.
local MAGE_TARGETED_GROUP_BUFF_NAMES = {
    ["Amplify Magic"] = true
}

local MAGE_TARGET_CLASS_OPTIONS = {
    { "WARRIOR", "Warrior" },
    { "PALADIN", "Paladin" },
    { "HUNTER", "Hunter" },
    { "ROGUE", "Rogue" },
    { "PRIEST", "Priest" },
    { "SHAMAN", "Shaman" },
    { "MAGE", "Mage" },
    { "WARLOCK", "Warlock" },
    { "DRUID", "Druid" }
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

local ARCANE_SURGE_TRIGGER_SPELLS = {
    "Arcane Missiles", "Arcane Rupture", "Arcane Surge",
    "Fireball", "Fire Blast", "Scorch", "Pyroblast",
    "Flamestrike", "Blast Wave", "Living Bomb",
    "Frostbolt", "Ice Lance", "Cone of Cold", "Frost Nova",
    "Blizzard", "Arcane Explosion"
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

local FIRE_THREAT_SPELL_HINTS = {
    "fireball", "fire blast", "scorch", "pyroblast", "blast wave",
    "flamestrike", "living bomb", "frostfire bolt",
    "immolate", "conflagrate", "searing pain", "soul fire",
    "hellfire", "rain of fire", "shadowflame",
    "flame shock", "fire nova", "magma totem", "searing totem",
    "immolation trap", "explosive trap", "flame breath"
}
local FIRE_THREAT_MEMORY_SECONDS = 120

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
local rotationBoxFrame
local rotationBoxRows = {}
local updateElapsed = 0
local frostNovaRangeElapsed = 0
local frostNovaRangeDistanceIndex = 3
local frostNovaRangeYards = 10
local arcticReachRank = 0
local frostNovaNameplateCount = 0
local frostNovaNameplates = {}
local NAMEPLATE_VERTICAL_OFFSET = 24
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
        local auraName
        if spellScanTooltip.SetUnitBuff then
            spellScanTooltip:ClearLines()
            local ok = pcall(
                spellScanTooltip.SetUnitBuff, spellScanTooltip, unit, i)
            if ok then
                local nameLine = getglobal(
                    "MageCoreSpellScanTooltipTextLeft1")
                auraName = nameLine and nameLine:GetText()
            end
        end
        if auraName then
            if auraName == spellName then return true end
        elseif NormalizeTexture(texture) == wanted then
            -- Stock-compatible fallback for clients that cannot expose aura
            -- names. Name matching above avoids false positives from shared
            -- icons such as Amplify Magic's Flash Heal artwork.
            return true
        end
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

    local sharpBorder = CreateFrame("Frame", nil, parent)
    sharpBorder:SetFrameStrata("HIGH")
    sharpBorder:SetFrameLevel(99)
    local sharpTop = sharpBorder:CreateTexture(nil, "OVERLAY")
    sharpTop:SetTexture(0, 0, 0, 1)
    sharpTop:SetPoint("TOPLEFT", 0, 0)
    sharpTop:SetPoint("TOPRIGHT", 0, 0)
    sharpTop:SetHeight(2)
    local sharpBottom = sharpBorder:CreateTexture(nil, "OVERLAY")
    sharpBottom:SetTexture(0, 0, 0, 1)
    sharpBottom:SetPoint("BOTTOMLEFT", 0, 0)
    sharpBottom:SetPoint("BOTTOMRIGHT", 0, 0)
    sharpBottom:SetHeight(2)
    local sharpLeft = sharpBorder:CreateTexture(nil, "OVERLAY")
    sharpLeft:SetTexture(0, 0, 0, 1)
    sharpLeft:SetPoint("TOPLEFT", 0, 0)
    sharpLeft:SetPoint("BOTTOMLEFT", 0, 0)
    sharpLeft:SetWidth(2)
    local sharpRight = sharpBorder:CreateTexture(nil, "OVERLAY")
    sharpRight:SetTexture(0, 0, 0, 1)
    sharpRight:SetPoint("TOPRIGHT", 0, 0)
    sharpRight:SetPoint("BOTTOMRIGHT", 0, 0)
    sharpRight:SetWidth(2)
    sharpBorder:Hide()

    local targetBorder = CreateFrame("Frame", nil, parent)
    targetBorder:SetFrameStrata("HIGH")
    targetBorder:SetFrameLevel(101)
    local targetTop = targetBorder:CreateTexture(nil, "OVERLAY")
    targetTop:SetTexture(1, 1, 1, 1)
    targetTop:SetPoint("TOPLEFT", 0, 0)
    targetTop:SetPoint("TOPRIGHT", 0, 0)
    targetTop:SetHeight(2)
    local targetBottom = targetBorder:CreateTexture(nil, "OVERLAY")
    targetBottom:SetTexture(1, 1, 1, 1)
    targetBottom:SetPoint("BOTTOMLEFT", 0, 0)
    targetBottom:SetPoint("BOTTOMRIGHT", 0, 0)
    targetBottom:SetHeight(2)
    local targetLeft = targetBorder:CreateTexture(nil, "OVERLAY")
    targetLeft:SetTexture(1, 1, 1, 1)
    targetLeft:SetPoint("TOPLEFT", 0, 0)
    targetLeft:SetPoint("BOTTOMLEFT", 0, 0)
    targetLeft:SetWidth(2)
    local targetRight = targetBorder:CreateTexture(nil, "OVERLAY")
    targetRight:SetTexture(1, 1, 1, 1)
    targetRight:SetPoint("TOPRIGHT", 0, 0)
    targetRight:SetPoint("BOTTOMRIGHT", 0, 0)
    targetRight:SetWidth(2)
    targetBorder:Hide()

    frostNovaNameplates[parent] = {
        border = border,
        borderTextures = { top, bottom, left, right },
        anchor = nil,
        borderThickness = nil,
        sharpBorder = sharpBorder,
        sharpAnchor = nil,
        targetBorder = targetBorder,
        targetAnchor = nil,
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

local function FrameHasUnitName(frame, unitName, depth)
    if not frame or not unitName then return false end
    local _, region
    for _, region in pairs({ frame:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "FontString"
            and region:GetText() == unitName then
            return true
        end
    end
    depth = depth or 0
    if depth < 2 then
        local _, child
        for _, child in pairs({ frame:GetChildren() }) do
            if FrameHasUnitName(child, unitName, depth + 1) then
                return true
            end
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

        -- Some native/Shagu layouts do not expose their moved name region
        -- consistently. With a player targeted, the sole full-alpha plate is
        -- still the client's selected plate.
        local playerOK, isPlayer = pcall(UnitIsPlayer, "target")
        if playerOK and isPlayer then return "target" end
    end
    return nil
end

local function HideFrostNovaRangeIndicators()
    local _, entry
    for _, entry in pairs(frostNovaNameplates) do entry.border:Hide() end
end

local function MoveNameplateObjectToContainer(
    object, parent, container, moveParent)
    if not object or object == container then return end

    local points = {}
    local pointCount = object.GetNumPoints and object:GetNumPoints() or 1
    local i
    for i = 1, pointCount do
        local point, relativeTo, relativePoint, x, y = object:GetPoint(i)
        if point then
            table.insert(points, {
                point, relativeTo, relativePoint, x or 0, y or 0
            })
        end
    end

    if moveParent then object:SetParent(container) end

    local needsReanchor = false
    local _, anchor
    for _, anchor in ipairs(points) do
        if anchor[2] == parent then
            anchor[2] = container
            needsReanchor = true
        end
    end
    if needsReanchor then
        object:ClearAllPoints()
        for _, anchor in ipairs(points) do
            object:SetPoint(
                anchor[1], anchor[2], anchor[3], anchor[4], anchor[5])
        end
    end
end

local function MoveNameplateVisualsToContainer(parent, entry)
    local container = entry.scaleContainer
    if not container then return end
    local _, child
    for _, child in pairs({ parent:GetChildren() }) do
        MoveNameplateObjectToContainer(
            child, parent, container, child ~= container)
    end
    local _, region
    for _, region in pairs({ parent:GetRegions() }) do
        MoveNameplateObjectToContainer(
            region, parent, container, true)
    end

    -- ShaguTweaks may have moved these objects before MageCore discovered the
    -- plate. Replace any remaining explicit anchors to the world plate with
    -- anchors to the movable visual container.
    for _, child in pairs({ container:GetChildren() }) do
        MoveNameplateObjectToContainer(
            child, parent, container, false)
    end
    for _, region in pairs({ container:GetRegions() }) do
        MoveNameplateObjectToContainer(
            region, parent, container, false)
    end
end

local function EnsureNameplateScaleContainer(parent, entry)
    if parent.new then
        if entry.scaleContainer ~= parent.new then
            entry.scaleContainer = parent.new
            -- ShaguTweaks can vary this container's scale as a plate moves.
            -- MageCore's slider is the authoritative fixed visual scale.
            entry.containerBaseScale = 1
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
        local verticalOffset = MageCore_Config.RaisedNameplates
            and NAMEPLATE_VERTICAL_OFFSET or 0

        -- pfUI draws the visible plate in this inner frame. Move that frame
        -- directly, matching pfUI's own vertical-offset mechanism.
        if parent.nameplate then
            parent.nameplate:ClearAllPoints()
            parent.nameplate:SetPoint(
                "TOP", parent, "TOP", 0, verticalOffset)
        end

        if entry.scaleContainer and entry.containerBaseScale then
            local ratio = percent / 100
            -- Native/ShaguTweaks plates use the visual container itself.
            local containerOffset = parent.nameplate and 0 or verticalOffset
            entry.scaleContainer:ClearAllPoints()
            entry.scaleContainer:SetPoint(
                "BOTTOMLEFT", parent, "BOTTOMLEFT", 0, containerOffset)
            entry.scaleContainer:SetPoint(
                "TOPRIGHT", parent, "TOPRIGHT", 0, containerOffset)
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

local function GetNameplateHealthBar(parent, entry)
    return parent.nameplate and parent.nameplate.health
        or parent.healthbar or entry.originalHealth
end

local function GetNameplateDisplayedName(parent)
    local nameRegion = parent.name
    if parent.nameplate then
        nameRegion = parent.nameplate.original
            and parent.nameplate.original.name
            or parent.nameplate.name
            or nameRegion
    end
    return nameRegion and nameRegion.GetText
        and nameRegion:GetText() or nil
end

local function GetKnownNameplatePlayer(parent)
    local name = GetNameplateDisplayedName(parent)
    if not name then return false, nil end

    -- pfUI remembers whether a scanned nameplate belongs to a player.
    if parent.nameplate and parent.nameplate.cache
        and parent.nameplate.cache.player then
        return parent.nameplate.cache.player == "PLAYER", name
    end

    -- ShaguTweaks keeps the same information in its unit-scan cache. Request
    -- an active lookup for a newly seen name so an untargeted neutral player
    -- can be identified without first requiring a manual target.
    if ShaguTweaks and ShaguTweaks.GetUnitData then
        local ok, cachedClass, cachedLevel, cachedElite, isPlayer = pcall(
            ShaguTweaks.GetUnitData, name, true)
        if ok and isPlayer then return true, name end
    end
    return false, name
end

local function UpdateSharpNameplateEdges()
    local parent, entry
    for parent, entry in pairs(frostNovaNameplates) do
        local anchor = GetNameplateHealthBar(parent, entry)
        if anchor and anchor ~= entry.sharpAnchor then
            entry.sharpBorder:ClearAllPoints()
            entry.sharpBorder:SetPoint(
                "TOPLEFT", anchor, "TOPLEFT", -2, 2)
            entry.sharpBorder:SetPoint(
                "BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 2, -2)
            entry.sharpAnchor = anchor
        end
        if MageCore_Config.SharpNameplateEdges and parent:IsShown() then
            entry.sharpBorder:Show()
        else
            entry.sharpBorder:Hide()
        end
    end
end

local function IsCurrentTargetNameplate(parent, entry, unit)
    if not UnitExists("target") then return false end
    if unit == "target" then return true end
    if parent.nameplate and parent.nameplate.istarget then return true end

    if unit then
        local _, targetGUID = UnitExists("target")
        if targetGUID and unit == targetGUID then return true end
        if UnitIsUnit then
            local ok, matches = pcall(UnitIsUnit, unit, "target")
            if ok and matches then return true end
        end
    end
    return false
end

local function UpdateTargetNameplateBorder()
    local parent, entry
    for parent, entry in pairs(frostNovaNameplates) do
        local anchor = GetNameplateHealthBar(parent, entry)
        if anchor and anchor ~= entry.targetAnchor then
            entry.targetBorder:ClearAllPoints()
            entry.targetBorder:SetPoint(
                "TOPLEFT", anchor, "TOPLEFT", -10, 10)
            entry.targetBorder:SetPoint(
                "BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 10, -10)
            entry.targetAnchor = anchor
        end

        local unit = parent:IsShown()
            and GetFrostNovaNameplateUnit(parent, entry)
        if MageCore_Config.HighlightTargetNameplate
            and parent:IsShown()
            and IsCurrentTargetNameplate(parent, entry, unit) then
            entry.targetBorder:Show()
        else
            entry.targetBorder:Hide()
        end
    end
end

local function GetNameplateDisposition(parent, entry, unit)
    local health = GetNameplateHealthBar(parent, entry)
    if not health then return nil end

    local disposition
    if unit then
        -- Opposite-faction players can have a hostile reaction while remaining
        -- unattackable because they are not PvP-enabled. Treat player units as
        -- hostile only when the client says we can actually attack them.
        local playerOK, isPlayer = pcall(UnitIsPlayer, unit)
        if playerOK and isPlayer then
            local playerDisposition = "NEUTRAL"
            local friendOK, isFriend = pcall(
                UnitIsFriend, "player", unit)
            if friendOK and isFriend then
                playerDisposition = "FRIENDLY"
            else
                -- Turtle can report an opposite-faction player as attackable
                -- from faction reaction alone. Require the target's actual PvP
                -- flag before allowing hostile-red player coloring.
                local pvpOK, isPvP = pcall(UnitIsPVP, unit)
                local attackOK, canAttack = pcall(
                    UnitCanAttack, "player", unit)
                if (not pvpOK or isPvP)
                    and attackOK and canAttack then
                    playerDisposition = "HOSTILE"
                end
            end

            entry.playerName = UnitName(unit)
                or GetNameplateDisplayedName(parent)
            entry.playerDisposition = playerDisposition
            return playerDisposition
        end

        -- This is the exact color used by the circle beneath the selected
        -- unit: yellow while neutral and red once that unit becomes hostile.
        local selectionOK, red, green, blue = pcall(
            UnitSelectionColor, unit)
        if selectionOK and red and green then
            if red >= 0.5 and green < 0.45 then
                disposition = "HOSTILE"
            elseif green >= 0.5 and red < 0.45 then
                disposition = "FRIENDLY"
            elseif red >= 0.5 and green >= 0.45
                and (not blue or blue < 0.45) then
                disposition = "NEUTRAL"
            end
        end

        -- Friendly players can use a blue selection circle, so keep reaction
        -- as a fallback for colors that were not identified above.
        if not disposition then
            local reactionOK, reaction = pcall(
                UnitReaction, "player", unit)
            if reactionOK and reaction then
                if reaction <= 3 then
                    disposition = "HOSTILE"
                elseif reaction >= 5 then
                    disposition = "FRIENDLY"
                end
            end
        end
    elseif health.GetStatusBarColor then
        local knownPlayer, plateName =
            GetKnownNameplatePlayer(parent)
        if entry.playerName and entry.playerName ~= plateName then
            entry.playerName = nil
            entry.playerDisposition = nil
        end
        if knownPlayer then
            if entry.playerDisposition then
                return entry.playerDisposition
            end
            local playerRed, playerGreen =
                health:GetStatusBarColor()
            if playerRed and playerGreen
                and playerGreen >= 0.5 and playerRed < 0.45 then
                return "FRIENDLY"
            end
            -- Without a live token the safe default for a known opposing
            -- player is neutral. Targeting it will cache HOSTILE if PvP is on.
            return "NEUTRAL"
        end

        -- Stock nameplates already expose reaction through their bar color,
        -- so plates without a usable unit token can still be normalized.
        local red, green = health:GetStatusBarColor()
        if red and green then
            if red >= 0.5 and green < 0.45 then
                disposition = "HOSTILE"
            elseif green >= 0.5 and red < 0.45 then
                disposition = "FRIENDLY"
            elseif red >= 0.5 and green >= 0.45 then
                disposition = "NEUTRAL"
            end
        end
    end
    return disposition
end

local function UpdateNameplateTeamColor(parent, entry, unit)
    local health = GetNameplateHealthBar(parent, entry)
    if not health or not health.SetStatusBarColor then return end
    local disposition = GetNameplateDisposition(parent, entry, unit)

    if disposition == "HOSTILE" then
        health:SetStatusBarColor(1, 0, 0)
    elseif disposition == "FRIENDLY" then
        health:SetStatusBarColor(0, 1, 0)
    elseif disposition == "NEUTRAL" then
        -- Explicitly restore yellow in case a recycled nameplate or a previous
        -- update briefly classified this unit as hostile.
        health:SetStatusBarColor(1, 1, 0)
    end
end

local function ApplyNameplateVisibility()
    if not MageCore_Config then return end

    -- Vanilla 1.12 exposes nameplate visibility through functions rather than
    -- the newer nameplateShowEnemies/nameplateShowFriends CVars.
    if MageCore_Config.AlwaysShowNameplates then
        if ShowNameplates then ShowNameplates() end
    elseif HideNameplates then
        HideNameplates()
    end

    if MageCore_Config.ShowFriendlyNameplates then
        if ShowFriendNameplates then ShowFriendNameplates() end
    elseif HideFriendNameplates then
        HideFriendNameplates()
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
            if deltaX * deltaX + deltaY * deltaY
                <= frostNovaRangeYards * frostNovaRangeYards then
                return true
            end
            -- Coordinates measure center to center. Do not reject the spell
            -- yet: Cone of Cold can still reach the edge of a large unit's
            -- combat hitbox, which the client range check accounts for.
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

local function SetFrostNovaBorderThickness(entry, anchor, thickness)
    if not anchor then return end
    if anchor ~= entry.anchor or thickness ~= entry.borderThickness then
        entry.border:ClearAllPoints()
        entry.border:SetPoint(
            "TOPLEFT", anchor, "TOPLEFT", -thickness, thickness)
        entry.border:SetPoint(
            "BOTTOMRIGHT", anchor, "BOTTOMRIGHT",
            thickness, -thickness)
        entry.borderTextures[1]:SetHeight(thickness)
        entry.borderTextures[2]:SetHeight(thickness)
        entry.borderTextures[3]:SetWidth(thickness)
        entry.borderTextures[4]:SetWidth(thickness)
        entry.anchor = anchor
        entry.borderThickness = thickness
    end
end

local function UpdateFrostNovaRangeIndicators()
    DiscoverFrostNovaNameplates()
    if not MageCore_Config then return end
    ApplyNameplateScale()
    UpdateSharpNameplateEdges()
    UpdateTargetNameplateBorder()

    local parent, entry
    for parent, entry in pairs(frostNovaNameplates) do
        if parent:IsShown() and MageCore_Config.TeamNameplateColors then
            UpdateNameplateTeamColor(
                parent, entry, GetFrostNovaNameplateUnit(parent, entry))
        end
    end

    if not MageCore_Config.FrostNovaRange then
        HideFrostNovaRangeIndicators()
        return
    end

    for parent, entry in pairs(frostNovaNameplates) do
        local anchor = GetNameplateHealthBar(parent, entry)

        local unit = parent:IsShown() and GetFrostNovaNameplateUnit(parent, entry)
        local disposition = parent:IsShown()
            and GetNameplateDisposition(parent, entry, unit)
        if disposition == "HOSTILE" then
            if unit and IsUnitInFrostNovaRange(unit) then
                -- A steady green state is immediately distinguishable from
                -- the steady-red longer-range state.
                SetFrostNovaBorderThickness(entry, anchor, 6)
                SetFrostNovaBorderColor(entry, 0, 1, 0)
            else
                -- Use the same strong outline in steady red at longer range.
                SetFrostNovaBorderThickness(entry, anchor, 3)
                SetFrostNovaBorderColor(entry, 1, 0, 0)
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

local function GetTargetCastingSpellInfo()
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
                return name,
                    not (notInterruptible == true or notInterruptible == 1)
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
                return name,
                    not (notInterruptible == true or notInterruptible == 1)
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
        return spellName or "", true
    end
    return nil
end

local function GetTargetInterruptibleSpellName()
    local spellName, interruptible = GetTargetCastingSpellInfo()
    if not spellName or not interruptible then return nil end
    return spellName
end

local function IsFireThreatSpellName(spellName)
    if not spellName or spellName == "" then return false end
    local lowerName = string.lower(spellName)
    local _, hint
    for _, hint in ipairs(FIRE_THREAT_SPELL_HINTS) do
        if string.find(lowerName, hint, 1, true) then return true end
    end
    return false
end

local function ShouldGoDirectToPvpRotation()
    return MageCore_Config and MageCore_Config.PvPMode and HasLivingEnemyTarget()
end

local function IsInBattleground()
    if not GetBattlefieldStatus then return false end
    local i
    for i = 1, 3 do
        if GetBattlefieldStatus(i) == "active" then return true end
    end
    return false
end

local function GetFindMineralsAction()
    if IsInBattleground()
        or UnitAffectingCombat("player")
        or not GetTrackingTexture then
        return nil
    end
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

local function GetTargetClassToken()
    local localizedClass, classToken = UnitClass("target")
    return string.upper(classToken or localizedClass or "")
end

local function GetReadyWardAction(spellName)
    if not GetSpellBookIndex(spellName)
        or not IsSpellReady(spellName)
        or PlayerHasBuff(spellName) then
        return nil
    end
    local manaCost = GetSpellManaCost(spellName)
    if manaCost and UnitMana("player") < manaCost then return nil end
    return spellName
end

local function GetFrostWardAction()
    if not MageCore_Config
        or not MageCore_Config.AutoFireWard
        or not HasLivingEnemyTarget()
        or GetTargetClassToken() ~= "SHAMAN" then
        return nil
    end
    return GetReadyWardAction("Frost Ward")
end

local function GetFireWardAction()
    if not MageCore_Config
        or not MageCore_Config.AutoFireWard
        or not HasLivingEnemyTarget() then
        return nil
    end

    local targetKey = GetTargetKey()
    local targetSpell = GetTargetCastingSpellInfo()
    if IsFireThreatSpellName(targetSpell) then
        fireThreatTargets[targetKey] =
            GetTime() + FIRE_THREAT_MEMORY_SECONDS
    end

    local isFireThreat = false
    local rememberedUntil = fireThreatTargets[targetKey]
    if rememberedUntil and rememberedUntil > GetTime() then
        isFireThreat = true
    elseif rememberedUntil then
        fireThreatTargets[targetKey] = nil
    end

    local classToken = GetTargetClassToken()
    -- Shamans use the parallel Frost Ward rule instead of Fire Ward.
    if classToken == "SHAMAN" then return nil end
    -- Warlocks are always a practical Fire threat because much of their
    -- pressure can be instant or otherwise missed by legacy cast providers.
    if classToken == "WARLOCK" then
        isFireThreat = true
    elseif MageCore_Config.FireWardMode == "CLASS"
        and classToken == "MAGE" then
        isFireThreat = true
    end

    if not isFireThreat then return nil end
    return GetReadyWardAction("Fire Ward")
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
    if MageCore_Config.AutoConjureManaAgate == nil then
        MageCore_Config.AutoConjureManaAgate = false
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
    for i = 1, 6 do
        local groupKey = "Buff" .. i .. "Group"
        if MageCore_Config[groupKey] == nil then
            MageCore_Config[groupKey] = MageCore_Config.GroupIntellect
                and MageCore_Config["Buff" .. i] == "Arcane Intellect"
                or false
        end
    end
    if MageCore_Config.PvPMode == nil then MageCore_Config.PvPMode = false end
    if MageCore_Config.AutoFireWard == nil then
        MageCore_Config.AutoFireWard =
            MageCore_Config.FireWardMode ~= "OFF"
    end
    if MageCore_Config.FireWardMode ~= "SMART"
        and MageCore_Config.FireWardMode ~= "CLASS" then
        MageCore_Config.FireWardMode = "SMART"
    end
    if MageCore_Config.FrostNovaRange == nil then MageCore_Config.FrostNovaRange = false end
    if MageCore_Config.AlwaysShowNameplates == nil then
        MageCore_Config.AlwaysShowNameplates = true
    end
    if MageCore_Config.ShowFriendlyNameplates == nil then
        MageCore_Config.ShowFriendlyNameplates =
            FRIENDNAMEPLATES_ON and true or false
    end
    if MageCore_Config.TeamNameplateColors == nil then
        MageCore_Config.TeamNameplateColors = true
    end
    if MageCore_Config.RaisedNameplates == nil then
        MageCore_Config.RaisedNameplates = true
    end
    if MageCore_Config.SharpNameplateEdges == nil then
        MageCore_Config.SharpNameplateEdges = true
    end
    if MageCore_Config.HighlightTargetNameplate == nil then
        MageCore_Config.HighlightTargetNameplate = true
    end
    if MageCore_Config.RotationBoxShown == nil then
        MageCore_Config.RotationBoxShown = false
    end
    if MageCore_Config.RotationBoxX == nil then
        MageCore_Config.RotationBoxX = 280
    end
    if MageCore_Config.RotationBoxY == nil then
        MageCore_Config.RotationBoxY = 0
    end
    if MageCore_Config.TargetedMagicMode == nil then
        MageCore_Config.TargetedMagicMode = "TARGET"
    end
    if MageCore_Config.TargetedMagicMode == "NAME"
        and MageCore_Config.TargetedMagicValue
        and MageCore_Config.TargetedMagicSavedName == nil then
        MageCore_Config.TargetedMagicSavedName =
            MageCore_Config.TargetedMagicValue
    end
    if MageCore_Config.NameplateScale == nil then MageCore_Config.NameplateScale = 100 end
    MageCore_Config.NameplateScale = math.max(
        50, math.min(150, tonumber(MageCore_Config.NameplateScale) or 100)
    )
    if MageCore_Config.AutoCounterspell == nil then MageCore_Config.AutoCounterspell = false end
    if MageCore_Config.CounterspellHealingOnly == nil then MageCore_Config.CounterspellHealingOnly = false end
end

local function GetGroupUnitKey(unit)
    return (UnitName(unit) or unit) .. ":" .. (UnitLevel(unit) or 0)
end

local function IsFriendlyBuffTarget(unit, skipRangeCheck)
    if not UnitExists(unit) or UnitIsDeadOrGhost(unit) then return false end
    if UnitIsConnected then
        local connected = UnitIsConnected(unit)
        if connected == nil or connected == false or connected == 0 then return false end
    end
    -- Roster tokens continue to exist for members in another instance. They
    -- cannot be targeted there and must never enter a helpful-spell queue,
    -- because auto-self-cast could otherwise redirect the failed cast.
    if UnitIsVisible then
        local visible = UnitIsVisible(unit)
        if visible == nil or visible == false or visible == 0 then return false end
    end
    if UnitIsFriend then
        local friendly = UnitIsFriend("player", unit)
        if friendly == nil or friendly == false or friendly == 0 then return false end
    end
    if not skipRangeCheck and CheckInteractDistance
        and not CheckInteractDistance(unit, 4) then return false end
    local key = GetGroupUnitKey(unit)
    local blockedUntil = groupBlockedUnits[key]
    if blockedUntil and GetTime() < blockedUntil then return false end
    if blockedUntil then groupBlockedUnits[key] = nil end
    return true
end

local function GetGroupBuffUnits(skipRangeCheck)
    local units = {}
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
    local i

    if raidCount > 0 then
        for i = 1, raidCount do
            local unit = "raid" .. i
            if IsFriendlyBuffTarget(unit, skipRangeCheck)
                and (not UnitIsUnit or not UnitIsUnit(unit, "player")) then
                table.insert(units, unit)
            end
        end
    elseif partyCount > 0 then
        for i = 1, partyCount do
            local unit = "party" .. i
            if IsFriendlyBuffTarget(unit, skipRangeCheck) then
                table.insert(units, unit)
            end
        end
    end
    table.insert(units, "player")
    return units
end

local function IsOtherGroupMember(unit)
    if not UnitExists(unit) then return false end
    if unit == "player" or (UnitIsUnit and UnitIsUnit(unit, "player")) then
        return false
    end
    local raidCount = GetNumRaidMembers and GetNumRaidMembers() or 0
    local partyCount = GetNumPartyMembers and GetNumPartyMembers() or 0
    local i
    if raidCount > 0 then
        for i = 1, raidCount do
            if UnitIsUnit and UnitIsUnit(unit, "raid" .. i) then
                return true
            end
        end
    else
        for i = 1, partyCount do
            if UnitIsUnit and UnitIsUnit(unit, "party" .. i) then
                return true
            end
        end
    end
    return false
end

local function GetSelectedGroupBuffUnit()
    if IsOtherGroupMember("target")
        and IsFriendlyBuffTarget("target", true) then
        return "target"
    end
    return nil
end

local function GetTargetClassDisplay(classToken)
    local _, option
    for _, option in ipairs(MAGE_TARGET_CLASS_OPTIONS) do
        if option[1] == classToken then return option[2] end
    end
    return classToken or "Unknown"
end

local function GetTargetedMagicDisplay()
    local mode = MageCore_Config.TargetedMagicMode or "TARGET"
    local value = MageCore_Config.TargetedMagicValue
    if mode == "SELF" then return "Self" end
    if mode == "NAME" then
        local savedName = MageCore_Config.TargetedMagicSavedName or value
        return savedName and ("Player: " .. savedName) or "Saved player missing"
    end
    if mode == "CLASS" then return "Class: " .. GetTargetClassDisplay(value) end
    return "Current friendly target"
end

local function GetTargetedGroupBuffUnits()
    local mode = MageCore_Config.TargetedMagicMode or "TARGET"
    if mode == "SELF" then return { "player" } end
    if mode == "TARGET" then
        local selected = GetSelectedGroupBuffUnit()
        return selected and { selected } or {}
    end

    local matches = {}
    -- Do not reject the configured member using CheckInteractDistance. Its
    -- coarse Vanilla thresholds are shorter than some buff ranges; let the
    -- spell cast itself provide the authoritative out-of-range result.
    local units = GetGroupBuffUnits(true)
    local savedName = MageCore_Config.TargetedMagicSavedName
        or MageCore_Config.TargetedMagicValue
    local _, unit
    for _, unit in ipairs(units) do
        local isPlayer = unit == "player"
            or (UnitIsUnit and UnitIsUnit(unit, "player"))
        if not isPlayer then
            if mode == "NAME" and UnitName(unit) == savedName then
                table.insert(matches, unit)
            elseif mode == "CLASS" then
                local localizedClass, classToken = UnitClass(unit)
                local wantedClass = MageCore_Config.TargetedMagicValue
                if classToken == wantedClass
                    or (localizedClass
                        and string.upper(localizedClass) == wantedClass) then
                    table.insert(matches, unit)
                end
            end
        end
    end
    return matches
end

local function GetNextTargetedMagicAction()
    local targetedUnits = GetTargetedGroupBuffUnits()
    local spellName = "Amplify Magic"
    if not GetSpellBookIndex(spellName) then return nil, nil end
    local i

    -- Amplify Magic is serviced only for the configured player, class, self,
    -- or current target. It never enters the roster-wide queue.
    for i = 1, table.getn(targetedUnits) do
        if not UnitHasBuff(targetedUnits[i], spellName) then
            return spellName, targetedUnits[i]
        end
    end
    return nil, nil
end

local function GetNextBuffAction()
    LoadDefaults()
    local targetedSpell, targetedUnit = GetNextTargetedMagicAction()
    if targetedSpell then return targetedSpell, targetedUnit end

    local units = GetGroupBuffUnits()
    local seen = {}
    local i, j
    for i = 1, 6 do
        local spellName = MageCore_Config["Buff" .. i]
        if spellName and spellName ~= "None" and not seen[spellName] then
            seen[spellName] = true
            local learned = GetSpellBookIndex(spellName)
            -- Do not gate buffs through GetSpellCooldown. On the legacy client
            -- beneficial and self-only spells can report a disabled spellbook
            -- state even though CastSpellByName can cast them. WarlockCore's
            -- working buff queue also selects buffs solely by learned/aura state.
            if learned then
                for j = 1, table.getn(units) do
                    local unit = units[j]
                    local castInGroup = MageCore_Config["Buff" .. i .. "Group"]
                    if not MAGE_TARGETED_GROUP_BUFF_NAMES[spellName]
                        and (unit == "player"
                            or (castInGroup and MAGE_GROUP_BUFF_NAMES[spellName]))
                        and not UnitHasBuff(unit, spellName) then
                        return spellName, unit
                    end
                end
            end
        end
    end
    return nil, nil
end

local function GetBuffDisplaySpell()
    local nextBuff = GetNextBuffAction()
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

local function IsArcaneSurgeConfigured()
    local i
    for i = 1, 6 do
        if MageCore_Config["Rotation" .. i] == "Arcane Surge" then
            return true
        end
    end
    return false
end

local function GetArcaneSurgeActionSlotState()
    local wantedTexture = NormalizeTexture(
        GetSpellTextureByName("Arcane Surge"))
    if not wantedTexture then return nil, nil end

    local slot
    for slot = 1, 120 do
        local texture = GetActionTexture(slot)
        if texture and not GetActionText(slot)
            and NormalizeTexture(texture) == wantedTexture then
            local usable, notEnoughMana = IsUsableAction(slot)
            local start, duration = GetActionCooldown(slot)
            local offCooldown = not start or not duration
                or start == 0 or duration == 0
                or start + duration <= GetTime()
            return usable == 1 and not notEnoughMana and offCooldown, slot
        end
    end
    return nil, nil
end

local function GetArcaneSurgeAction()
    local usable = GetArcaneSurgeActionSlotState()
    -- Vanilla exposes reactive conditions most reliably through an actual
    -- action-bar spell slot. Combat-log tracking covers characters that keep
    -- Arcane Surge only in MageCore's rotation.
    usable = usable or arcaneSurgeAvailableUntil > GetTime()
    local cooldownRemaining = GetSpellCooldownRemaining("Arcane Surge")
    local manaCost = GetSpellManaCost("Arcane Surge")
    if not IsArcaneSurgeConfigured()
        or not HasLivingEnemyTarget()
        -- GetSpellCooldown alone says Arcane Surge is ready even before a
        -- resist enables it.
        or not usable
        -- Never cancel Arcane Missiles while the global cooldown still blocks
        -- the Surge cast.
        or not cooldownRemaining
        or cooldownRemaining > 0
        or (manaCost and UnitMana("player") < manaCost)
        or not SpellCanReachTarget("Arcane Surge") then
        return nil
    end
    return "Arcane Surge"
end

local function TrackArcaneSurgeFromCombatMessage(message)
    local lowerMessage = string.lower(message or "")
    if not string.find(lowerMessage, "resist", 1, true) then return end
    local _, spellName
    for _, spellName in ipairs(ARCANE_SURGE_TRIGGER_SPELLS) do
        if string.find(
            lowerMessage, string.lower(spellName), 1, true) then
            arcaneSurgeAvailableUntil = GetTime() + 4
            return
        end
    end
end

local function ClearConfirmedLunaInterrupt(message)
    if not message or not string.find(message, "^You interrupt ", 1) then
        return
    end
    if not LunaUF or not LunaUF.Units or not LunaUF.Units.frameList then
        return
    end

    local _, _, interruptedName = string.find(
        message, "^You interrupt (.-)%s*'s .-%.$")
    interruptedName = interruptedName or UnitName("target")
    if not interruptedName then return end

    local _, frame
    for _, frame in pairs(LunaUF.Units.frameList) do
        if frame.unit and frame.castBar
            and UnitName(frame.unit) == interruptedName then
            local castBar = frame.castBar
            castBar.casting = false
            castBar.channeling = false
            castBar:SetScript("OnUpdate", nil)
            if castBar.bar then
                castBar.bar:SetMinMaxValues(0, 1)
                castBar.bar:SetValue(0)
            end
            if castBar.Text then castBar.Text:Hide() end
            if castBar.Time then castBar.Time:Hide() end

            local unitConfig = LunaUF.db and LunaUF.db.profile
                and LunaUF.db.profile.units
                and LunaUF.db.profile.units[frame.unitGroup]
            if unitConfig and unitConfig.castBar
                and unitConfig.castBar.hide and not castBar.hidden then
                castBar.hidden = true
                if LunaUF.Units.PositionWidgets then
                    LunaUF.Units:PositionWidgets(frame)
                end
            end
        end
    end
end

local function HasEnoughManaForSpell(spellName)
    local manaCost = GetSpellManaCost(spellName)
    return not manaCost or UnitMana("player") >= manaCost
end

local function GetLowestRotationManaCost()
    local lowest
    local i
    for i = 1, 6 do
        local spellName = MageCore_Config["Rotation" .. i]
        if spellName and spellName ~= "None" and spellName ~= "Shoot"
            and GetSpellBookIndex(spellName) then
            local manaCost = GetSpellManaCost(spellName)
            if manaCost and manaCost > 0
                and (not lowest or manaCost < lowest) then
                lowest = manaCost
            end
        end
    end
    return lowest
end

local function GetLowManaWandAction()
    if not HasLivingEnemyTarget() then return nil end
    local lowestManaCost = GetLowestRotationManaCost()
    if not lowestManaCost
        or UnitMana("player") >= lowestManaCost then
        return nil
    end

    local shootIndex = GetSpellBookIndex("Shoot")
    if not shootIndex then return nil end
    if GetInventoryItemLink
        and not GetInventoryItemLink("player", 18) then
        return nil
    end
    if IsConfiguredAutoRepeatActive("Shoot") then return "Shoot" end

    -- Legacy clients commonly report Shoot as unusable or out of range until
    -- its auto-repeat actually starts. The low-mana decision is authoritative;
    -- let the native action/cast produce any real equipment or range error.
    return "Shoot"
end

local function StartWandAttack()
    if IsConfiguredAutoRepeatActive("Shoot") then return true end

    -- Prefer a native Shoot action because Vanilla clients handle the
    -- auto-repeat toggle most reliably through UseAction. Ignore macros that
    -- happen to share MageCore's current dynamic Shoot icon.
    local wantedTexture = NormalizeTexture(
        GetSpellTextureByName("Shoot"))
    if wantedTexture then
        local slot
        for slot = 1, 120 do
            local texture = GetActionTexture(slot)
            if texture and not GetActionText(slot)
                and NormalizeTexture(texture) == wantedTexture then
                UseAction(slot)
                return true
            end
        end
    end

    CastSpellByName("Shoot")
    return true
end

local function GetNextCombatSpell()
    LoadDefaults()
    local wandAction = GetLowManaWandAction()
    if wandAction then return wandAction end
    local arcaneSurge = GetArcaneSurgeAction()
    if arcaneSurge then return arcaneSurge end
    local i
    for i = 1, 6 do
        local spellName = MageCore_Config["Rotation" .. i]
        -- Arcane Surge is reactive: its cooldown looks ready even when no
        -- resist proc exists. It must only enter through GetArcaneSurgeAction.
        if spellName and spellName ~= "None"
            and spellName ~= "Arcane Surge"
            and IsSpellReady(spellName)
            and HasEnoughManaForSpell(spellName)
            and SpellCanReachTarget(spellName) then
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
    if not GetSpellBookIndex(rankOne)
        or not IsSpellReady(rankOne)
        or not HasEnoughManaForSpell(rankOne)
        or not SpellCanReachTarget(rankOne) then return nil end
    return rankOne
end

local function GetSoonestCooldownSpell()
    local bestSpell
    local bestRemaining
    local i
    for i = 1, 6 do
        local spellName = MageCore_Config["Rotation" .. i]
        if spellName and spellName ~= "None"
            and spellName ~= "Arcane Surge"
            and SpellCanReachTarget(spellName) then
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
    if opener == "Arcane Surge" then return GetArcaneSurgeAction() end
    if not IsSpellReady(opener)
        or not HasEnoughManaForSpell(opener)
        or not SpellCanReachTarget(opener) then return nil end
    return opener
end

local function ShouldAutoBuffFromRotation()
    return MageCore_Config
        and MageCore_Config.AutoBuff
        and not UnitAffectingCombat("player")
end

local function CastGroupBuff(spellName, unit)
    local hadTarget = UnitExists("target")
    local targetWasUnit = hadTarget and UnitIsUnit("target", unit)
    if not targetWasUnit then
        TargetUnit(unit)
        -- Do not cast unless target acquisition actually succeeded. This is a
        -- final guard against auto-self-cast when a group member phases,
        -- zones, or enters another instance between selection and the cast.
        if not UnitExists("target")
            or not UnitIsUnit("target", unit) then
            return false
        end
    end
    lastGroupBuffAttempt = {
        unit = unit,
        key = GetGroupUnitKey(unit),
        spell = spellName,
        time = GetTime()
    }
    CastSpellByName(spellName)
    if SpellIsTargeting() then SpellTargetUnit(unit) end
    if not targetWasUnit then
        if hadTarget then TargetLastTarget() else ClearTarget() end
    end
    return true
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

local function FindBagItemByName(itemName)
    local wanted = string.lower(itemName or "")
    local bag, slot
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link and string.find(string.lower(link), wanted, 1, true) then
                return bag, slot
            end
        end
    end
    return nil, nil
end

local function HasFreeBagSlot()
    local bag, slot
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            if not GetContainerItemLink(bag, slot) then return true end
        end
    end
    return false
end

local function ShowManaAgateWarning(message)
    DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "[MageCore]|r |cffff0000Mana Agate warning:|r " .. message)
    if UIErrorsFrame then UIErrorsFrame:AddMessage("Mana Agate: " .. message, 1, 0.1, 0.1, 1) end
end

local function GetManaAgateMaintenanceAction(showWarnings)
    if not MageCore_Config.AutoConjureManaAgate or UnitAffectingCombat("player") then return nil end
    if FindBagItemByName("Mana Agate") then
        pendingManaAgate = nil
        return nil
    end
    if pendingManaAgate then
        if GetTime() - pendingManaAgate <= 5 then return "WAIT" end
        pendingManaAgate = nil
    end
    if not HasFreeBagSlot() then
        if showWarnings and GetTime() - lastManaAgateBagWarning >= 10 then
            ShowManaAgateWarning("Your bags are full.")
            lastManaAgateBagWarning = GetTime()
        end
        return nil
    end
    local spellName = "Conjure Mana Agate"
    if not GetSpellBookIndex(spellName) or not IsSpellReady(spellName) then
        if showWarnings and GetTime() - lastManaAgateSpellWarning >= 10 then
            ShowManaAgateWarning("Conjure Mana Agate is not ready or was not found.")
            lastManaAgateSpellWarning = GetTime()
        end
        return nil
    end
    local manaCost = GetSpellManaCost(spellName)
    if manaCost and UnitMana("player") < manaCost then return nil end
    return spellName
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
    -- Observe the cast before resolving priority so an interrupted Fire spell
    -- still teaches Smart mode that this enemy is a Fire threat.
    local frostWard = GetFrostWardAction()
    local fireWard = GetFireWardAction()
    local ward = frostWard or fireWard
    local counterspell = GetCounterspellAction()
    if counterspell then return counterspell end
    local arcaneSurge = GetArcaneSurgeAction()
    if arcaneSurge then return arcaneSurge end
    if ward then return ward end
    local targetedSpell = GetNextTargetedMagicAction()
    if targetedSpell then return targetedSpell end
    local directPvp = ShouldGoDirectToPvpRotation()
    if not directPvp then
        local trackingSpell = GetFindMineralsAction()
        if trackingSpell then return trackingSpell end
        local manaAgateSpell = GetManaAgateMaintenanceAction(false)
        if manaAgateSpell and manaAgateSpell ~= "WAIT" then return manaAgateSpell end
        local conjureSpell = GetNextConjureAction()
        if conjureSpell and conjureSpell ~= "WAIT" then return conjureSpell end
        if ShouldAutoBuffFromRotation() then
            local buff = GetNextBuffAction()
            if buff then return buff end
        end
    end
    -- With no enemy selected, preview the opener that Rotation will use after
    -- acquiring a target instead of falling through to Rotation Slot 1.
    if not UnitAffectingCombat("player") and not HasLivingEnemyTarget()
        and MageCore_Config.Opener and MageCore_Config.Opener ~= "None"
        and MageCore_Config.Opener ~= "Arcane Surge" then
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
        and MageCore_Config.Opener ~= "Arcane Surge"
        and GetSpellBookIndex(MageCore_Config.Opener) then
        return MageCore_Config.Opener
    end
    local i
    for i = 1, 6 do
        local spellName = MageCore_Config["Rotation" .. i]
        if spellName and spellName ~= "None"
            and spellName ~= "Arcane Surge"
            and GetSpellBookIndex(spellName) then
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
    local buff, unit = GetNextBuffAction()
    if not buff or not unit then return end
    if unit == "player" then
        CastOnSelf(buff)
    else
        CastGroupBuff(buff, unit)
    end
end

local function GetIceBlockPlayerBuffIndex()
    if not GetPlayerBuff or not GetPlayerBuffTexture then return nil end
    local wanted = NormalizeTexture(GetSpellTextureByName("Ice Block"))
    if not wanted then return nil end

    local i
    for i = 0, 31 do
        local buffIndex = GetPlayerBuff(i, "HELPFUL")
        if not buffIndex or buffIndex < 0 then break end
        if NormalizeTexture(GetPlayerBuffTexture(buffIndex)) == wanted then
            return buffIndex
        end
    end
    return nil
end

function MageCore_IceBlock()
    if not GetSpellBookIndex("Ice Block") then return end

    local now = GetTime()
    local buffIndex = GetIceBlockPlayerBuffIndex()
    if buffIndex then
        -- If Ice Block was activated outside this button, begin a conservative
        -- one-second guard on the first attempted cancellation.
        if not iceBlockGuardStartedAt then
            iceBlockGuardStartedAt = now
        end
        if now - iceBlockGuardStartedAt < 1 then return end
        CancelPlayerBuff(buffIndex)
        iceBlockGuardStartedAt = nil
        return
    end

    iceBlockGuardStartedAt = now
    CastSpellByName("Ice Block")
end

function MageCore_Rotate()
    LoadDefaults()
    -- A short Arcane Surge proc may appear during an Arcane Missiles tick.
    -- Let a Rotation press consume it immediately, while continuing to protect
    -- Blizzard, Evocation, and every other channel from accidental cancellation.
    if channelInProgress then
        local arcaneSurge = channelSpellName == "Arcane Missiles"
            and GetArcaneSurgeAction()
        if arcaneSurge then
            SpellStopCasting()
            arcaneSurgeAvailableUntil = 0
            lastCombatSpellAttempt = {
                spell = arcaneSurge,
                target = GetTargetKey(),
                time = GetTime()
            }
            CastSpellByName(arcaneSurge)
        end
        return
    end
    -- Learn the enemy's Fire threat even when Counterspell wins this press.
    local frostWard = GetFrostWardAction()
    local fireWard = GetFireWardAction()
    local ward = frostWard or fireWard
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
    local arcaneSurge = GetArcaneSurgeAction()
    if arcaneSurge then
        arcaneSurgeAvailableUntil = 0
        lastCombatSpellAttempt = {
            spell = arcaneSurge,
            target = GetTargetKey(),
            time = GetTime()
        }
        CastSpellByName(arcaneSurge)
        return
    end
    if ward then
        CastOnSelf(ward)
        return
    end
    -- Amplify Magic maintenance belongs to the main rotation. It is allowed
    -- in combat and does not depend on the separate Auto Buff OOC toggle.
    local targetedSpell, targetedUnit = GetNextTargetedMagicAction()
    if targetedSpell then
        if targetedUnit == "player" then
            CastOnSelf(targetedSpell)
        else
            CastGroupBuff(targetedSpell, targetedUnit)
        end
        return
    end
    local directPvp = ShouldGoDirectToPvpRotation()
    if not directPvp then
        local trackingSpell = GetFindMineralsAction()
        if trackingSpell then
            CastSpellByName(trackingSpell)
            return
        end

        local manaAgateSpell = GetManaAgateMaintenanceAction(true)
        if manaAgateSpell == "WAIT" then return end
        if manaAgateSpell then
            pendingManaAgate = GetTime()
            CastSpellByName(manaAgateSpell)
            return
        end

        local conjureSpell, conjureKind = GetNextConjureAction()
        if conjureSpell == "WAIT" then return end
        if conjureSpell then
            CastConjureSpell(conjureSpell, conjureKind)
            return
        end

        if ShouldAutoBuffFromRotation() then
            local buff, unit = GetNextBuffAction()
            if buff then
                if unit == "player" then
                    CastOnSelf(buff)
                else
                    CastGroupBuff(buff, unit)
                end
                return
            end
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
        -- Shoot is an auto-repeat toggle. Once the wand is firing, another
        -- Rotation press must leave it active instead of toggling it off.
        if spellName == "Shoot"
            and IsConfiguredAutoRepeatActive("Shoot") then
            return
        end
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
        if spellName == "Shoot" then
            StartWandAttack()
        else
            CastSpellByName(spellName)
        end
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

local function GetActionButtonCooldown(button)
    if not button then return nil end
    return button.cd or button.cooldown
        or (button.GetName
            and button:GetName()
            and getglobal(button:GetName() .. "Cooldown"))
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
            local cooldown = GetActionButtonCooldown(button)
            if cooldown then CooldownFrame_SetTimer(cooldown, start, duration, enabled) end
        end
    end
end

local function UpdateIceBlockCooldown()
    local start, duration, enabled =
        GetSpellCooldownInfo("Ice Block")
    if start == nil then start, duration, enabled = 0, 0, 0 end

    local _, button
    for _, button in ipairs(GetActionButtons()) do
        local actionSlot = ActionButton_GetPagedID(button)
        if actionSlot
            and GetActionText(actionSlot) == "MageIceBlock" then
            local cooldown = GetActionButtonCooldown(button)
            if cooldown then
                CooldownFrame_SetTimer(
                    cooldown, start, duration, enabled)
            end
        end
    end
end

local function UpdateRotationManaState(spellName)
    local manaCost = GetSpellManaCost(spellName)
    local insufficient = manaCost and UnitMana("player") < manaCost
    local outOfRange = spellName ~= "Fire Ward"
        and spellName ~= "Frost Ward"
        and GetSpellRangeState(spellName) == false
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

local function FormatRotationBoxCooldown(seconds)
    if seconds >= 10 then return math.ceil(seconds) .. "s" end
    return string.format("%.1fs", seconds)
end

local function GetRotationBoxSpellState(spellName, isNext)
    if not spellName or spellName == "None" then
        return "Empty", 0.45, 0.45, 0.45
    end
    if not GetSpellBookIndex(spellName) then
        return "MISSING FROM SPELLBOOK", 1, 0.2, 0.2
    end

    local manaCost = GetSpellManaCost(spellName)
    local mana = UnitMana("player") or 0
    local start, duration, enabled = GetSpellCooldownInfo(spellName)
    local remaining = start and duration
        and math.max(0, start + duration - GetTime()) or 0
    local state
    local red, green, blue

    if enabled == 0 then
        state, red, green, blue = "DISABLED", 0.55, 0.55, 0.55
    elseif duration and duration > 1.5 and remaining > 0 then
        state, red, green, blue =
            "CD " .. FormatRotationBoxCooldown(remaining), 1, 0.55, 0.1
    elseif manaCost and mana < manaCost then
        state, red, green, blue =
            "MANA " .. mana .. "/" .. manaCost, 0.35, 0.55, 1
    elseif IsRangeBlocked(spellName)
        or (spellName == "Cone of Cold"
            and HasLivingEnemyTarget()
            and not SpellCanReachTarget(spellName))
        or GetSpellRangeState(spellName) == false then
        state, red, green, blue = "OUT OF RANGE", 1, 0.15, 0.15
    elseif spellName == "Arcane Surge" then
        local actionUsable = GetArcaneSurgeActionSlotState()
        local procActive = actionUsable
            or arcaneSurgeAvailableUntil > GetTime()
        if not procActive then
            state, red, green, blue = "NO RESIST PROC", 0.75, 0.45, 1
        end
    elseif ConfiguredSpellIsAutoRepeat(spellName)
        and IsConfiguredAutoRepeatActive(spellName) then
        state, red, green, blue = "ACTIVE", 0.2, 1, 0.35
    end

    if not state then
        if duration and duration > 0 and remaining > 0 then
            state, red, green, blue =
                "GCD " .. FormatRotationBoxCooldown(remaining), 1, 0.85, 0.2
        elseif isNext then
            state, red, green, blue = "NEXT", 0.2, 1, 0.35
        else
            state, red, green, blue = "READY", 0.65, 1, 0.65
        end
    end

    local details = manaCost and ("mana " .. manaCost) or "mana -"
    if HasLivingEnemyTarget() then
        local rangeState = GetSpellRangeState(spellName)
        if spellName == "Cone of Cold" then
            rangeState = SpellCanReachTarget(spellName)
        end
        if rangeState == true then
            details = details .. "  |  range yes"
        elseif rangeState == false then
            details = details .. "  |  range no"
        else
            details = details .. "  |  range ?"
        end
    else
        details = details .. "  |  no target"
    end
    return state .. "\n" .. details, red, green, blue
end

local function UpdateRotationBox()
    if not rotationBoxFrame or not rotationBoxFrame:IsShown()
        or not MageCore_Config then return end

    local nextSpell = GetNextCombatSpell()
    local i
    for i = 1, 6 do
        local row = rotationBoxRows[i]
        local spellName = MageCore_Config["Rotation" .. i] or "None"
        row.spellName = spellName ~= "None" and spellName or nil
        row.name:SetText(i)
        row.icon:SetTexture(
            GetSpellTextureByName(spellName)
                or ICON_PATH .. "INV_Misc_QuestionMark")

        local state, red, green, blue =
            GetRotationBoxSpellState(spellName, spellName == nextSpell)
        if spellName ~= "None" and spellName == nextSpell then
            row.nextBar:Show()
        else
            row.nextBar:Hide()
        end
        local lineBreak = string.find(state, "\n", 1, true)
        local detail
        if lineBreak then
            detail = string.sub(state, lineBreak + 1)
            state = string.sub(state, 1, lineBreak - 1)
        end
        row.monitorState = state
        row.monitorDetail = detail
        local compactState = state
        if state == "MISSING FROM SPELLBOOK" then
            compactState = "MISSING"
        elseif state == "NO RESIST PROC" then
            compactState = "NO PROC"
        elseif state == "OUT OF RANGE" then
            compactState = "RANGE"
        elseif string.find(state, "^MANA ") then
            compactState = "MANA"
        end
        row.state:SetText(compactState)
        row.state:SetTextColor(red, green, blue)
        row.icon:SetVertexColor(
            red == 1 and green <= 0.2 and blue <= 0.2 and 0.45 or 1,
            red == 1 and green <= 0.2 and blue <= 0.2 and 0.45 or 1,
            red == 1 and green <= 0.2 and blue <= 0.2 and 0.45 or 1)

        local start, duration, enabled =
            GetSpellCooldownInfo(spellName)
        if not start then start, duration, enabled = 0, 0, 0 end
        CooldownFrame_SetTimer(row.cooldown, start, duration, enabled)
    end
end

local function CreateRotationBox()
    if rotationBoxFrame then return end
    LoadDefaults()

    local frame = CreateFrame(
        "Frame", "MageCoreRotationBox", UIParent)
    rotationBoxFrame = frame
    frame:SetWidth(330)
    frame:SetHeight(103)
    frame:SetPoint(
        "CENTER", UIParent, "CENTER",
        MageCore_Config.RotationBoxX, MageCore_Config.RotationBoxY)
    frame:SetFrameStrata("HIGH")
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 8, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    frame:SetBackdropColor(0.02, 0.05, 0.08, 0.94)
    frame:SetBackdropBorderColor(0.25, 0.65, 0.9, 1)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function() this:StartMoving() end)
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        local x, y = this:GetCenter()
        local parentX, parentY = UIParent:GetCenter()
        if x and y and parentX and parentY then
            MageCore_Config.RotationBoxX = x - parentX
            MageCore_Config.RotationBoxY = y - parentY
        end
    end)

    local title = frame:CreateFontString(
        nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 10, -8)
    title:SetText(ACCENT .. "MageCore Rotation Monitor|r")

    local hint = frame:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    hint:SetPoint("TOPRIGHT", -26, -9)
    hint:SetText("|cff888888drag|r")

    local close = CreateFrame(
        "Button", nil, frame, "UIPanelCloseButton")
    close:SetWidth(24)
    close:SetHeight(24)
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function()
        MageCore_Config.RotationBoxShown = false
        frame:Hide()
    end)

    for i = 1, 6 do
        local row = CreateFrame("Button", nil, frame)
        row:SetWidth(48)
        row:SetHeight(62)
        row:SetPoint("TOPLEFT", 10 + ((i - 1) * 52), -30)
        row:EnableMouse(true)

        local background = row:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints(row)
        background:SetTexture(0.08, 0.12, 0.16, 0.9)

        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetWidth(40)
        row.icon:SetHeight(40)
        row.icon:SetPoint("TOP", 0, -2)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        row.cooldown = CreateFrame(
            "Model", "MageCoreRotationBoxCooldown" .. i,
            row, "CooldownFrameTemplate")
        row.cooldown:SetWidth(40)
        row.cooldown:SetHeight(40)
        row.cooldown:SetPoint("CENTER", row.icon, "CENTER", 0, 0)

        -- Use a child frame above the legacy cooldown model so the marker
        -- remains bright and visible while a radial cooldown sweep is active.
        row.nextBar = CreateFrame("Frame", nil, row)
        row.nextBar:SetWidth(40)
        row.nextBar:SetHeight(4)
        row.nextBar:SetPoint("TOP", row.icon, "TOP", 0, 1)
        row.nextBar:SetFrameLevel(row:GetFrameLevel() + 5)
        local nextBarTexture =
            row.nextBar:CreateTexture(nil, "OVERLAY")
        nextBarTexture:SetAllPoints(row.nextBar)
        nextBarTexture:SetTexture(0.1, 1, 0.2, 1)
        row.nextBar:Hide()

        row.name = row:CreateFontString(
            nil, "OVERLAY", "GameFontNormalSmall")
        row.name:SetWidth(16)
        row.name:SetPoint("TOPLEFT", row.icon, "TOPLEFT", 2, -2)
        row.name:SetJustifyH("LEFT")

        row.state = row:CreateFontString(
            nil, "OVERLAY", "GameFontNormalSmall")
        row.state:SetWidth(48)
        row.state:SetPoint("TOP", row.icon, "BOTTOM", 0, -3)
        row.state:SetJustifyH("CENTER")

        row:SetScript("OnEnter", function()
            if not this.spellName then return end
            local index = GetSpellBookIndex(this.spellName)
            GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
            if index then
                GameTooltip:SetSpell(index, BOOKTYPE_SPELL)
            else
                GameTooltip:AddLine(this.spellName)
            end
            if this.monitorState then
                GameTooltip:AddLine(
                    "Monitor: " .. this.monitorState, 1, 0.82, 0)
            end
            if this.monitorDetail then
                GameTooltip:AddLine(
                    this.monitorDetail, 0.8, 0.8, 0.8)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rotationBoxRows[i] = row
    end

    frame:Hide()
end

local function SetRotationBoxShown(shown)
    LoadDefaults()
    MageCore_Config.RotationBoxShown = shown and true or false
    if shown then
        CreateRotationBox()
        rotationBoxFrame:Show()
        UpdateRotationBox()
    elseif rotationBoxFrame then
        rotationBoxFrame:Hide()
    end
    DEFAULT_CHAT_FRAME:AddMessage(
        ACCENT .. "[MageCore]|r Rotation monitor "
            .. (shown and "|cff00ff00shown|r" or "|cffff4444hidden|r")
            .. ".")
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
    if GetSpellBookIndex("Arcane Surge") then
        local index = GetSpellBookIndex("Arcane Surge")
        local usable, noMana
        if IsUsableSpell then
            usable, noMana = IsUsableSpell(index, BOOKTYPE_SPELL)
        end
        local actionUsable, actionSlot = GetArcaneSurgeActionSlotState()
        DEFAULT_CHAT_FRAME:AddMessage(
            "Arcane Surge: configured="
                .. (IsArcaneSurgeConfigured() and "yes" or "no")
                .. ", spell usable=" .. (usable and "yes" or "no")
                .. ", action slot=" .. (actionSlot or "none")
                .. ", action usable="
                .. (actionUsable and "yes" or "no")
                .. ", resist tracked="
                .. (arcaneSurgeAvailableUntil > GetTime()
                    and "yes" or "no")
                .. ", no mana=" .. (noMana and "yes" or "no")
                .. ", selected="
                .. (GetArcaneSurgeAction() and "yes" or "no"))
    end
end

local function PrintAmplifyDebug()
    LoadDefaults()
    local units = GetTargetedGroupBuffUnits()
    local resolved = {}
    local _, unit
    for _, unit in ipairs(units) do
        table.insert(
            resolved,
            (UnitName(unit) or unit)
                .. " [" .. unit .. ", aura="
                .. (UnitHasBuff(unit, "Amplify Magic") and "yes" or "no")
                .. "]")
    end
    local nextSpell, nextUnit = GetNextTargetedMagicAction()
    DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "[MageCore] Amplify debug|r")
    DEFAULT_CHAT_FRAME:AddMessage(
        "Learned: " .. (GetSpellBookIndex("Amplify Magic") and "yes" or "no")
            .. "; main Rotation maintenance: automatic")
    DEFAULT_CHAT_FRAME:AddMessage(
        "Preference: " .. GetTargetedMagicDisplay()
            .. "; resolved: "
            .. (table.getn(resolved) > 0
                and table.concat(resolved, ", ") or "none"))
    DEFAULT_CHAT_FRAME:AddMessage(
        "Next action: "
            .. (nextSpell
                and (nextSpell .. " -> " .. (UnitName(nextUnit) or nextUnit))
                or "none"))
end

local function TestAmplifyCast()
    LoadDefaults()
    if not GetSpellBookIndex("Amplify Magic") then
        DEFAULT_CHAT_FRAME:AddMessage(
            ACCENT .. "[MageCore]|r Amplify Magic was not found in the spellbook.")
        return
    end
    local units = GetTargetedGroupBuffUnits()
    local unit = units[1]
    if not unit then
        DEFAULT_CHAT_FRAME:AddMessage(
            ACCENT .. "[MageCore]|r No Amplify target matched the preference.")
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage(
        ACCENT .. "[MageCore]|r Direct Amplify test -> "
            .. (UnitName(unit) or unit))
    CastGroupBuff("Amplify Magic", unit)
end

local function SlashCommand(message)
    local command = string.lower(message or "")
    command = string.gsub(command, "^%s+", "")
    command = string.gsub(command, "%s+$", "")
    if command == "box on" then
        SetRotationBoxShown(true)
    elseif command == "box off" then
        SetRotationBoxShown(false)
    elseif command == "box" then
        LoadDefaults()
        SetRotationBoxShown(not MageCore_Config.RotationBoxShown)
    elseif string.find(command, "^box%s") then
        DEFAULT_CHAT_FRAME:AddMessage(
            ACCENT .. "[MageCore]|r Use |cffffffff/mc box on|r or "
                .. "|cffffffff/mc box off|r.")
    elseif command == "debug" then
        PrintSpellBookDebug()
    elseif command == "ampdebug" then
        PrintAmplifyDebug()
    elseif command == "amptest" then
        TestAmplifyCast()
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
    frame:SetHeight(500)
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
    rotationPanel:SetWidth(400); rotationPanel:SetHeight(390)
    rotationPanel:SetPoint("TOPLEFT", 15, -90)
    local buffPanel = CreateFrame("Frame", nil, frame)
    buffPanel:SetWidth(400); buffPanel:SetHeight(390)
    buffPanel:SetPoint("TOPLEFT", 15, -90)
    buffPanel:Hide()
    local foodPanel = CreateFrame("Frame", nil, frame)
    foodPanel:SetWidth(400); foodPanel:SetHeight(390)
    foodPanel:SetPoint("TOPLEFT", 15, -90)
    foodPanel:Hide()
    local consumablePanel = CreateFrame("Frame", nil, frame)
    consumablePanel:SetWidth(400); consumablePanel:SetHeight(390)
    consumablePanel:SetPoint("TOPLEFT", 15, -90)
    consumablePanel:Hide()
    local infoPanel = CreateFrame("Frame", nil, frame)
    infoPanel:SetWidth(400); infoPanel:SetHeight(390)
    infoPanel:SetPoint("TOPLEFT", 15, -90)
    infoPanel:Hide()

    local rotationTab, buffTab, foodTab, consumableTab, infoTab
    local function ShowTab(tab)
        rotationPanel:Hide(); buffPanel:Hide(); foodPanel:Hide(); consumablePanel:Hide(); infoPanel:Hide()
        rotationTab:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
        buffTab:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
        foodTab:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
        consumableTab:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
        infoTab:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
        if tab == 1 then
            rotationPanel:Show(); rotationTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)
        elseif tab == 2 then
            buffPanel:Show(); buffTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)
        elseif tab == 3 then
            foodPanel:Show(); foodTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)
        elseif tab == 4 then
            consumablePanel:Show(); consumableTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)
        else
            infoPanel:Show(); infoTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)
        end
    end

    local function MakeTab(text, x, tab)
        local button = CreateFrame("Button", nil, frame)
        button:SetWidth(79); button:SetHeight(26); button:SetPoint("TOPLEFT", x, -50)
        StyleButton(button)
        local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER", 0, 0); label:SetText(text)
        button:SetScript("OnClick", function() ShowTab(tab) end)
        return button
    end

    rotationTab = MakeTab("Rotation", 10, 1)
    buffTab = MakeTab("Buffs", 92, 2)
    foodTab = MakeTab("Food", 174, 3)
    consumableTab = MakeTab("Consumable", 256, 4)
    infoTab = MakeTab("Info", 338, 5)
    rotationTab:SetBackdropColor(0.08, 0.3, 0.48, 0.96)

    local rotationHelp = rotationPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    rotationHelp:SetPoint("TOPLEFT", 10, 0); rotationHelp:SetWidth(375); rotationHelp:SetJustifyH("LEFT")
    rotationHelp:SetText("After out-of-combat maintenance, Opener is cast once on a new target. Counterspell and smart elemental wards can take priority.")

    local buffHelp = buffPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    buffHelp:SetPoint("TOPLEFT", 10, 0); buffHelp:SetWidth(375); buffHelp:SetJustifyH("LEFT")
    buffHelp:SetText("Choose learned mage buffs. Group Intellect cycles through the roster. Main Rotation always maintains Amplify Magic on the preference below.")

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

    local consumableTitle = consumablePanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    consumableTitle:SetPoint("TOPLEFT", 18, -8)
    consumableTitle:SetText(ACCENT .. "Consumable|r")

    local consumableHelp = consumablePanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    consumableHelp:SetPoint("TOPLEFT", 18, -48)
    consumableHelp:SetWidth(350)
    consumableHelp:SetJustifyH("LEFT")
    consumableHelp:SetText("Out of combat, Rotation can maintain one Mana Agate in your bags. It never consumes the gem.")

    local manaAgateButton = CreateFrame("Button", nil, consumablePanel)
    manaAgateButton:SetWidth(190); manaAgateButton:SetHeight(32)
    manaAgateButton:SetPoint("TOPLEFT", 18, -105)
    StyleButton(manaAgateButton)
    local manaAgateText = manaAgateButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    manaAgateText:SetPoint("CENTER", 0, 0)
    local function UpdateManaAgateText()
        manaAgateText:SetText("Mana Agate: " .. (MageCore_Config.AutoConjureManaAgate
            and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    end
    UpdateManaAgateText()
    manaAgateButton:SetScript("OnClick", function()
        MageCore_Config.AutoConjureManaAgate = not MageCore_Config.AutoConjureManaAgate
        pendingManaAgate = nil
        UpdateManaAgateText()
    end)
    manaAgateButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Mana Agate")
        GameTooltip:AddLine("Conjures one when none is in your bags.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Only runs out of combat through Rotation.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("The created Mana Agate is never consumed automatically.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    manaAgateButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

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

    local rotationPositions = {
        { 0, -102 }, { 200, -102 }, { 0, -158 },
        { 200, -158 }, { 0, -214 }, { 200, -214 }
    }
    local buffPositions = {
        { 0, -55 }, { 200, -55 }, { 0, -125 },
        { 200, -125 }, { 0, -195 }, { 200, -195 }
    }
    local i
    for i = 1, 6 do
        MakeDrop(rotationPanel, "Rotation Slot " .. i .. ":", "Rotation" .. i,
            rotationPositions[i][1], rotationPositions[i][2])
        MakeDrop(buffPanel, "Buff Slot " .. i .. ":", "Buff" .. i,
            buffPositions[i][1], buffPositions[i][2], true)

        local groupCheck = CreateFrame(
            "CheckButton", "MageCoreBuff" .. i .. "GroupCheck",
            buffPanel, "UICheckButtonTemplate")
        groupCheck:SetWidth(20)
        groupCheck:SetHeight(20)
        groupCheck:SetPoint(
            "TOPLEFT", buffPositions[i][1] + 15, buffPositions[i][2] - 47)
        groupCheck:SetChecked(MageCore_Config["Buff" .. i .. "Group"] and 1 or nil)
        local slot = i
        groupCheck:SetScript("OnClick", function()
            MageCore_Config["Buff" .. slot .. "Group"] =
                this:GetChecked() and true or false
            groupBlockedUnits = {}
        end)

        local groupCheckLabel = buffPanel:CreateFontString(
            nil, "OVERLAY", "GameFontNormalSmall")
        groupCheckLabel:SetPoint("LEFT", groupCheck, "RIGHT", 2, 0)
        groupCheckLabel:SetText("Cast in group")
    end

    local targetedMagicLabel = buffPanel:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    targetedMagicLabel:SetPoint("TOPLEFT", 15, -263)
    targetedMagicLabel:SetText(ACCENT .. "Amplify Magic target:|r")

    local targetedMagicDrop = CreateFrame(
        "Frame", "MC_TargetedMagicDrop", buffPanel, "UIDropDownMenuTemplate")
    targetedMagicDrop:SetPoint("TOPLEFT", 0, -278)
    UIDropDownMenu_SetWidth(185, targetedMagicDrop)
    local function SetTargetedMagicSelection(mode, value)
        MageCore_Config.TargetedMagicMode = mode
        MageCore_Config.TargetedMagicValue = value
        if mode == "NAME" then
            MageCore_Config.TargetedMagicSavedName = value
        end
        UIDropDownMenu_SetSelectedValue(
            targetedMagicDrop, mode .. ":" .. (value or ""))
        UIDropDownMenu_SetText(GetTargetedMagicDisplay(), targetedMagicDrop)
    end
    UIDropDownMenu_Initialize(targetedMagicDrop, function()
        local function AddTargetOption(text, mode, value)
            local selectedMode, selectedValue = mode, value
            local info = {}
            info.text = text
            info.value = mode .. ":" .. (value or "")
            info.func = function()
                SetTargetedMagicSelection(selectedMode, selectedValue)
            end
            UIDropDownMenu_AddButton(info)
        end
        AddTargetOption("Current friendly target", "TARGET", nil)
        AddTargetOption("Self", "SELF", nil)
        if MageCore_Config.TargetedMagicSavedName then
            AddTargetOption(
                "Player: " .. MageCore_Config.TargetedMagicSavedName,
                "NAME", MageCore_Config.TargetedMagicSavedName)
        end
        local _, option
        for _, option in ipairs(MAGE_TARGET_CLASS_OPTIONS) do
            AddTargetOption("Class: " .. option[2], "CLASS", option[1])
        end
    end)
    UIDropDownMenu_SetSelectedValue(
        targetedMagicDrop,
        MageCore_Config.TargetedMagicMode .. ":"
            .. (MageCore_Config.TargetedMagicValue or ""))
    UIDropDownMenu_SetText(GetTargetedMagicDisplay(), targetedMagicDrop)

    local saveTargetButton = CreateFrame("Button", nil, buffPanel)
    saveTargetButton:SetWidth(165)
    saveTargetButton:SetHeight(30)
    saveTargetButton:SetPoint("TOPLEFT", 225, -287)
    StyleButton(saveTargetButton)
    local saveTargetText = saveTargetButton:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    saveTargetText:SetPoint("CENTER", 0, 0)
    saveTargetText:SetText("Save selected player")
    saveTargetButton:SetScript("OnClick", function()
        if not IsOtherGroupMember("target") then
            if UIErrorsFrame then
                UIErrorsFrame:AddMessage(
                    "Select a party or raid member first.", 1, 0.1, 0.1, 1)
            end
            return
        end
        local name = UnitName("target")
        if not name then return end
        SetTargetedMagicSelection("NAME", name)
        DEFAULT_CHAT_FRAME:AddMessage(
            ACCENT .. "[MageCore]|r Amplify Magic target saved: "
                .. name)
    end)
    saveTargetButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Save selected player")
        GameTooltip:AddLine(
            "Remembers the currently selected party or raid member by name.",
            0.8, 0.8, 0.8, 1, true)
        GameTooltip:Show()
    end)
    saveTargetButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

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
        GameTooltip:AddLine("Maintains targeted Amplify Magic in and out of combat.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Otherwise, combat presses use the attack rotation.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Drag onto an action bar.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    dragRotation:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local rotationLabel = rotationPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    rotationLabel:SetPoint("LEFT", dragRotation, "RIGHT", 10, 0)
    rotationLabel:SetText("Drag Rotation to your action bar")

    local dragIceBlock = CreateFrame("Button", nil, rotationPanel)
    dragIceBlock:SetWidth(48)
    dragIceBlock:SetHeight(48)
    dragIceBlock:SetPoint("TOPLEFT", 300, -272)
    StyleButton(dragIceBlock)
    local iceBlockTexture = dragIceBlock:CreateTexture(nil, "OVERLAY")
    iceBlockTexture:SetPoint("TOPLEFT", 4, -4)
    iceBlockTexture:SetPoint("BOTTOMRIGHT", -4, 4)
    iceBlockTexture:SetTexture(
        GetSpellTextureByName("Ice Block")
            or ICON_PATH .. "Spell_Frost_Frost")
    dragIceBlock:RegisterForDrag("LeftButton")
    dragIceBlock:SetScript("OnDragStart", function()
        local index = CreateOrUpdateMacro(
            "MageIceBlock", "/script MageCore_IceBlock()", "Ice Block")
        if index and index > 0 then PickupMacro(index) end
    end)
    dragIceBlock:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Guarded Ice Block")
        GameTooltip:AddLine(
            "Casts Ice Block, then ignores cancellation presses for one second.",
            0.8, 0.8, 0.8, 1, true)
        GameTooltip:AddLine(
            "After the guard expires, press the same button to cancel it.",
            0.8, 0.8, 0.8, 1, true)
        GameTooltip:AddLine(
            "Drag onto an action bar.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    dragIceBlock:SetScript(
        "OnLeave", function() GameTooltip:Hide() end)
    local iceBlockLabel = rotationPanel:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    iceBlockLabel:SetPoint("BOTTOM", dragIceBlock, "TOP", 0, 2)
    iceBlockLabel:SetText("Guarded Ice Block")

    local autoFireWardButton = CreateFrame("Button", nil, rotationPanel)
    autoFireWardButton:SetWidth(180)
    autoFireWardButton:SetHeight(32)
    autoFireWardButton:SetPoint("TOPLEFT", 10, -340)
    StyleButton(autoFireWardButton)
    local autoFireWardText = autoFireWardButton:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    autoFireWardText:SetPoint("CENTER", 0, 0)
    local function UpdateAutoFireWardText()
        autoFireWardText:SetText(
            "Auto Wards: "
                .. (MageCore_Config.AutoFireWard
                    and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    end
    UpdateAutoFireWardText()
    autoFireWardButton:SetScript("OnClick", function()
        MageCore_Config.AutoFireWard =
            not MageCore_Config.AutoFireWard
        UpdateAutoFireWardText()
    end)
    autoFireWardButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Auto Wards")
        GameTooltip:AddLine(
            "Enables Fire Ward against configured Fire threats and Frost Ward against hostile Shamans. This works independently of PvP Mode and preserves your selected Fire Ward mode while disabled.",
            0.8, 0.8, 0.8, 1, true)
        GameTooltip:Show()
    end)
    autoFireWardButton:SetScript(
        "OnLeave", function() GameTooltip:Hide() end)

    local fireWardModeButton = CreateFrame("Button", nil, rotationPanel)
    fireWardModeButton:SetWidth(180)
    fireWardModeButton:SetHeight(32)
    fireWardModeButton:SetPoint("TOPLEFT", 205, -340)
    StyleButton(fireWardModeButton)
    local fireWardModeText = fireWardModeButton:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    fireWardModeText:SetPoint("CENTER", 0, 0)
    local function UpdateFireWardModeText()
        fireWardModeText:SetText(
            "Ward Mode: "
                .. (MageCore_Config.FireWardMode == "CLASS"
                    and "Mage/Warlock" or "Smart"))
    end
    UpdateFireWardModeText()
    fireWardModeButton:SetScript("OnClick", function()
        if MageCore_Config.FireWardMode == "SMART" then
            MageCore_Config.FireWardMode = "CLASS"
        else
            MageCore_Config.FireWardMode = "SMART"
        end
        UpdateFireWardModeText()
    end)
    fireWardModeButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Fire Ward Mode")
        GameTooltip:AddLine(
            "Smart uses Fire Ward proactively against Warlocks and remembers enemy Fire casts for two minutes. Mage/Warlock additionally pre-wards against all Mages. Frost Ward is always used against Shamans while Auto Wards is enabled. Counterspell remains the higher priority.",
            0.8, 0.8, 0.8, 1, true)
        GameTooltip:Show()
    end)
    fireWardModeButton:SetScript(
        "OnLeave", function() GameTooltip:Hide() end)

    local autoButton = CreateFrame("Button", nil, buffPanel)
    autoButton:SetWidth(150); autoButton:SetHeight(32); autoButton:SetPoint("TOPLEFT", 8, -346)
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

    local dragBuff = CreateFrame("Button", nil, buffPanel)
    dragBuff:SetWidth(48); dragBuff:SetHeight(48); dragBuff:SetPoint("TOPLEFT", 176, -338)
    StyleButton(dragBuff)
    buffIconTexture = dragBuff:CreateTexture(nil, "OVERLAY")
    buffIconTexture:SetPoint("TOPLEFT", 4, -4); buffIconTexture:SetPoint("BOTTOMRIGHT", -4, 4)
    buffIconTexture:SetTexture(ICON_PATH .. "Spell_Holy_MagicalSentry")
    dragBuff:RegisterForDrag("LeftButton")
    dragBuff:SetScript("OnDragStart", function()
        local index = CreateOrUpdateMacro("MageBuff", "/script MageCore_Buff()", GetBuffDisplaySpell())
        if index and index > 0 then PickupMacro(index) end
    end)
    dragBuff:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("MageCore Buff")
        GameTooltip:AddLine("Casts the first configured buff that is missing.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Slots marked Cast in group also check party or raid members.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine("Amplify Magic uses your saved player, class, self, or current-target preference.", 0.8, 0.8, 0.8, 1, true)
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

    local alwaysShowNameplates = CreateFrame(
        "CheckButton", "MageCoreAlwaysShowNameplatesCheck",
        infoPanel, "UICheckButtonTemplate")
    alwaysShowNameplates:SetWidth(24)
    alwaysShowNameplates:SetHeight(24)
    alwaysShowNameplates:SetPoint("TOPLEFT", 205, -275)
    alwaysShowNameplates:SetChecked(
        MageCore_Config.AlwaysShowNameplates and 1 or nil)
    alwaysShowNameplates:SetScript("OnClick", function()
        MageCore_Config.AlwaysShowNameplates =
            this:GetChecked() and true or false
        ApplyNameplateVisibility()
    end)

    local alwaysShowNameplatesLabel = infoPanel:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    alwaysShowNameplatesLabel:SetPoint(
        "LEFT", alwaysShowNameplates, "RIGHT", 4, 0)
    alwaysShowNameplatesLabel:SetText(
        ACCENT .. "Show enemy nameplates|r")

    local showFriendlyNameplates = CreateFrame(
        "CheckButton", "MageCoreShowFriendlyNameplatesCheck",
        infoPanel, "UICheckButtonTemplate")
    showFriendlyNameplates:SetWidth(24)
    showFriendlyNameplates:SetHeight(24)
    showFriendlyNameplates:SetPoint("TOPLEFT", 18, -305)
    showFriendlyNameplates:SetChecked(
        MageCore_Config.ShowFriendlyNameplates and 1 or nil)
    showFriendlyNameplates:SetScript("OnClick", function()
        MageCore_Config.ShowFriendlyNameplates =
            this:GetChecked() and true or false
        ApplyNameplateVisibility()
    end)

    local showFriendlyNameplatesLabel = infoPanel:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    showFriendlyNameplatesLabel:SetPoint(
        "LEFT", showFriendlyNameplates, "RIGHT", 4, 0)
    showFriendlyNameplatesLabel:SetText(
        ACCENT .. "Show friendly nameplates|r")

    local teamNameplateColors = CreateFrame(
        "CheckButton", "MageCoreTeamNameplateColorsCheck",
        infoPanel, "UICheckButtonTemplate")
    teamNameplateColors:SetWidth(24)
    teamNameplateColors:SetHeight(24)
    teamNameplateColors:SetPoint("TOPLEFT", 205, -305)
    teamNameplateColors:SetChecked(
        MageCore_Config.TeamNameplateColors and 1 or nil)
    teamNameplateColors:SetScript("OnClick", function()
        MageCore_Config.TeamNameplateColors =
            this:GetChecked() and true or false
    end)

    local teamNameplateColorsLabel = infoPanel:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    teamNameplateColorsLabel:SetPoint(
        "LEFT", teamNameplateColors, "RIGHT", 4, 0)
    teamNameplateColorsLabel:SetText(
        ACCENT .. "Red enemies / green team|r")

    local raisedNameplates = CreateFrame(
        "CheckButton", "MageCoreRaisedNameplatesCheck",
        infoPanel, "UICheckButtonTemplate")
    raisedNameplates:SetWidth(24)
    raisedNameplates:SetHeight(24)
    raisedNameplates:SetPoint("TOPLEFT", 205, -335)
    raisedNameplates:SetChecked(
        MageCore_Config.RaisedNameplates and 1 or nil)
    raisedNameplates:SetScript("OnClick", function()
        MageCore_Config.RaisedNameplates =
            this:GetChecked() and true or false
        ApplyNameplateScale()
    end)

    local raisedNameplatesLabel = infoPanel:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    raisedNameplatesLabel:SetPoint(
        "LEFT", raisedNameplates, "RIGHT", 4, 0)
    raisedNameplatesLabel:SetText(
        ACCENT .. "Raised nameplates|r")

    local sharpNameplateEdges = CreateFrame(
        "CheckButton", "MageCoreSharpNameplateEdgesCheck",
        infoPanel, "UICheckButtonTemplate")
    sharpNameplateEdges:SetWidth(24)
    sharpNameplateEdges:SetHeight(24)
    sharpNameplateEdges:SetPoint("TOPLEFT", 205, -365)
    sharpNameplateEdges:SetChecked(
        MageCore_Config.SharpNameplateEdges and 1 or nil)
    sharpNameplateEdges:SetScript("OnClick", function()
        MageCore_Config.SharpNameplateEdges =
            this:GetChecked() and true or false
        UpdateSharpNameplateEdges()
    end)

    local sharpNameplateEdgesLabel = infoPanel:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    sharpNameplateEdgesLabel:SetPoint(
        "LEFT", sharpNameplateEdges, "RIGHT", 4, 0)
    sharpNameplateEdgesLabel:SetText(
        ACCENT .. "Sharp nameplate edges|r")

    local highlightTargetNameplate = CreateFrame(
        "CheckButton", "MageCoreHighlightTargetNameplateCheck",
        infoPanel, "UICheckButtonTemplate")
    highlightTargetNameplate:SetWidth(24)
    highlightTargetNameplate:SetHeight(24)
    highlightTargetNameplate:SetPoint("TOPLEFT", 18, -275)
    highlightTargetNameplate:SetChecked(
        MageCore_Config.HighlightTargetNameplate and 1 or nil)
    highlightTargetNameplate:SetScript("OnClick", function()
        MageCore_Config.HighlightTargetNameplate =
            this:GetChecked() and true or false
        UpdateTargetNameplateBorder()
    end)

    local highlightTargetNameplateLabel = infoPanel:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    highlightTargetNameplateLabel:SetPoint(
        "LEFT", highlightTargetNameplate, "RIGHT", 4, 0)
    highlightTargetNameplateLabel:SetText(
        ACCENT .. "White target border|r")

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
        GameTooltip:AddLine("Shows a steady red border around hostile nameplates at longer range, then changes to a double-thickness bright green border inside Frost Nova's detected " .. frostNovaRangeYards .. "-yard range. Arctic Reach rank " .. arcticReachRank .. "/2 is detected from your spellbook. SuperWoW enables range detection for every nameplate; without it, the current target can change to the green state.", 0.8, 0.8, 0.8, 1, true)
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
eventFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
eventFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_BUFF")
eventFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PARTY_MEMBERS_CHANGED")
eventFrame:RegisterEvent("RAID_ROSTER_UPDATE")
eventFrame:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        LoadDefaults()
    elseif event == "PLAYER_LOGIN" then
        LoadDefaults(); RefreshSpellBook(); CreateMinimapButton(); SetupRotationButtonTooltips()
        if MageCore_Config.RotationBoxShown then
            CreateRotationBox()
            rotationBoxFrame:Show()
            UpdateRotationBox()
        end
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
        if pendingManaAgate and FindBagItemByName("Mana Agate") then pendingManaAgate = nil end
    elseif event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
        normalCastInProgress = false
        channelInProgress = false
        channelSpellName = nil
        pendingConjure = nil
        pendingManaAgate = nil
        if lastCombatSpellAttempt and lastCombatSpellAttempt.opener
            and GetTime() - lastCombatSpellAttempt.time < 1.5 then
            openerUsedForTarget = nil
        end
    elseif event == "SPELLCAST_START" then
        normalCastInProgress = true
    elseif event == "SPELLCAST_STOP" then
        normalCastInProgress = false
    elseif event == "SPELLCAST_CHANNEL_START" then
        normalCastInProgress = false
        channelInProgress = true
        channelSpellName = arg2
        if not channelSpellName and lastCombatSpellAttempt
            and GetTime() - lastCombatSpellAttempt.time < 1.5 then
            channelSpellName = lastCombatSpellAttempt.spell
        end
    elseif event == "SPELLCAST_CHANNEL_STOP" then
        normalCastInProgress = false
        channelInProgress = false
        channelSpellName = nil
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
    elseif event == "CHAT_MSG_SPELL_SELF_DAMAGE"
        or event == "CHAT_MSG_SPELL_SELF_BUFF"
        or event == "CHAT_MSG_COMBAT_SELF_HITS" then
        ClearConfirmedLunaInterrupt(arg1)
        if string.find(arg1 or "", "^You interrupt ", 1) then
            -- Repeat once on the next update in case Luna's event handler runs
            -- after MageCore's handler and redraws its cached cast.
            pendingLunaInterruptMessage = arg1
        end
        if event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
            TrackArcaneSurgeFromCombatMessage(arg1)
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
    if pendingLunaInterruptMessage then
        ClearConfirmedLunaInterrupt(pendingLunaInterruptMessage)
        pendingLunaInterruptMessage = nil
    end

    frostNovaRangeElapsed = frostNovaRangeElapsed + (arg1 or 0)
    if frostNovaRangeElapsed >= 0.1 then
        frostNovaRangeElapsed = 0
        UpdateFrostNovaRangeIndicators()
    end

    updateElapsed = updateElapsed + (arg1 or 0)
    if updateElapsed < 0.4 then return end
    updateElapsed = 0
    if not MageCore_Config then return end
    ApplyNameplateVisibility()
    UpdateRotationBox()
    UpdateIceBlockCooldown()
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

    local channelAction = channelInProgress
        and channelSpellName == "Arcane Missiles"
        and GetArcaneSurgeAction()
    if not normalCastInProgress and (not channelInProgress or channelAction) then
        local nextAction = channelAction or GetNextAction()
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
