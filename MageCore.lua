-- MageCore
-- Press-driven mage rotation and self-buff helper for Turtle WoW / Vanilla 1.12.

local _, playerClass = UnitClass("player")
if playerClass ~= "MAGE" then return end

-- The version lives only in MageCore.toc.
local VERSION = GetAddOnMetadata
    and GetAddOnMetadata("MageCore", "Version") or "?"
local ICON_PATH = "Interface\\Icons\\"
local DEFAULT_ICON = "Spell_Frost_FrostBolt02"
local ACCENT = "|cff69ccf0"

-- All mutable runtime state lives in one table. Vanilla Lua (5.0) allows
-- at most 200 locals in the main chunk and 32 upvalues per function; one
-- table keeps both limits far away as the addon grows.
local S = {
    spellBookSpells = { "None" },
    helpfulSpellBookSpells = { "None" },
    armorSpellBookSpells = { "None" },
    regularBuffSpellBookSpells = { "None" },
    knownWaterSpells = {},
    knownFoodSpells = {},
    conjureRestockActive = {},
    lastManaGemBagWarning = -10,
    lastManaGemSpellWarning = -10,
    lowManaWandFallbackUntil = 0,
    rangeBlockedSpells = {},
    fireThreatTargets = {},
    groupBlockedUnits = {},
    normalCastInProgress = false,
    channelInProgress = false,
    arcaneSurgeAvailableUntil = 0,
    spellManaCostCache = {},
    rotationBoxRows = {},
    updateElapsed = 0,
    frostNovaRangeElapsed = 0,
    frostNovaRangeDistanceIndex = 3,
    frostNovaRangeYards = 10,
    arcticReachRank = 0,
    frostNovaNameplateCount = 0,
    frostNovaNameplates = {},
    autoRepeatActive = false,
    auraCache = {},
    guidDispositions = {},
    guidDispositionCount = 0,
    menuRefreshers = {},
    buffElapsed = 0,
}


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

local MAGE_ARMOR_NAMES = {
    ["Frost Armor"] = true,
    ["Ice Armor"] = true,
    ["Mage Armor"] = true,
    ["Molten Armor"] = true
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

local NAMEPLATE_VERTICAL_OFFSET = 24
local NON_TARGET_NAME_FONT_SCALE = 2

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

local function ScanSpellBookIndex(spellName)
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

-- Spellbook positions only change when spells are learned, so lookups are
-- cached until the next SPELLS_CHANGED/LEARNED_SPELL_IN_TAB refresh. Misses
-- are cached as false so unlearned spells do not trigger repeated scans.
local function GetSpellBookIndex(spellName)
    if not spellName or spellName == "None" then return nil end
    local cache = S.spellIndexCache
    if not cache then return ScanSpellBookIndex(spellName) end
    local cached = cache[spellName]
    if cached == nil then
        cached = ScanSpellBookIndex(spellName) or false
        cache[spellName] = cached
    end
    return cached or nil
end

local function RefreshSpellBook()
    S.spellManaCostCache = {}
    S.spellIndexCache = {}
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
    S.knownWaterSpells = waterRanks
    S.knownFoodSpells = foodRanks

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
                if S.pendingConjure and S.pendingConjure.kind == kind then S.pendingConjure = nil end
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
    S.spellBookSpells = { "None" }
    S.helpfulSpellBookSpells = { "None" }
    S.armorSpellBookSpells = { "None" }
    S.regularBuffSpellBookSpells = { "None" }
    for i = 1, table.getn(learned) do
        table.insert(S.spellBookSpells, learned[i])
    end
    for i = 1, table.getn(helpful) do
        local spellName = helpful[i]
        table.insert(S.helpfulSpellBookSpells, spellName)
        if MAGE_ARMOR_NAMES[spellName] then
            table.insert(S.armorSpellBookSpells, spellName)
        else
            table.insert(S.regularBuffSpellBookSpells, spellName)
        end
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
            elseif i == 1 and buff ~= "None"
                and not MAGE_ARMOR_NAMES[buff] then
                MageCore_Config["Buff" .. i] = "None"
            elseif i > 1 and MAGE_ARMOR_NAMES[buff] then
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
        S.arcticReachRank = math.max(1, math.min(2, tonumber(rankNumber) or 1))
        S.frostNovaRangeDistanceIndex = 2
        S.frostNovaRangeYards = 10 + S.arcticReachRank
    else
        S.arcticReachRank = 0
        S.frostNovaRangeDistanceIndex = 3
        S.frostNovaRangeYards = 10
    end
end

local function GetSpellTextureByName(spellName)
    local index = GetSpellBookIndex(spellName)
    if not index then return nil end
    return GetSpellTexture(index, BOOKTYPE_SPELL)
end

local function GetSpellManaCost(spellName)
    if not spellName or spellName == "None" then return nil end
    if S.spellManaCostCache[spellName] ~= nil then
        return S.spellManaCostCache[spellName] or nil
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
                    S.spellManaCostCache[spellName] = tonumber(cost)
                    return tonumber(cost)
                end
            end
        end
    end
    S.spellManaCostCache[spellName] = false
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

-- Aura lists are cached briefly per unit token. UNIT_AURA, target and roster
-- events invalidate them, so the cache mainly prevents the 0.4s display
-- update from tooltip-scanning a whole raid every tick.
local AURA_CACHE_SECONDS = 1.5

local function GetUnitAuras(unit)
    local now = GetTime()
    local cached = S.auraCache[unit]
    if cached and now - cached.time < AURA_CACHE_SECONDS then return cached end
    cached = { time = now }
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
        table.insert(cached, {
            name = auraName, texture = NormalizeTexture(texture)
        })
    end
    S.auraCache[unit] = cached
    return cached
end

local function InvalidateAuraCache(unit)
    if unit then S.auraCache[unit] = nil else S.auraCache = {} end
end

local function UnitHasBuff(unit, spellName)
    local wanted = NormalizeTexture(GetSpellTextureByName(spellName))
    if not wanted then return false end
    local auras = GetUnitAuras(unit)
    local i
    for i = 1, table.getn(auras) do
        local aura = auras[i]
        if aura.name then
            if aura.name == spellName then return true end
        elseif aura.texture == wanted then
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

local function GetTargetPvpFrostEffect()
    if not UnitExists("target") then return nil end

    local wantedNames = {
        ["frostbolt"] = "CHILLED",
        ["cone of cold"] = "CHILLED",
        ["frost nova"] = "FROZEN",
        ["frostbite"] = "FROZEN",
        ["freeze"] = "FROZEN"
    }
    local wantedTextures = {
        CHILLED = {},
        FROZEN = {}
    }
    local frostSpells = {
        { "Frostbolt", "CHILLED" },
        { "Cone of Cold", "CHILLED" },
        { "Frost Nova", "FROZEN" },
        { "Frostbite", "FROZEN" },
        { "Freeze", "FROZEN" }
    }
    local _, spellInfo
    for _, spellInfo in ipairs(frostSpells) do
        local texture = NormalizeTexture(GetSpellTextureByName(spellInfo[1]))
        if texture then wantedTextures[spellInfo[2]][texture] = true end
    end

    local foundChill = false
    local i
    for i = 1, 16 do
        local texture = UnitDebuff("target", i)
        if not texture then break end
        local normalizedTexture = NormalizeTexture(texture)
        local debuffName
        if spellScanTooltip.SetUnitDebuff then
            spellScanTooltip:ClearLines()
            local ok = pcall(
                spellScanTooltip.SetUnitDebuff,
                spellScanTooltip, "target", i)
            if ok then
                local nameLine = getglobal(
                    "MageCoreSpellScanTooltipTextLeft1")
                debuffName = nameLine and nameLine:GetText()
            end
        end
        if debuffName then
            local effect = wantedNames[string.lower(debuffName)]
            if effect == "FROZEN" then return effect end
            if effect == "CHILLED" then foundChill = true end
        elseif wantedTextures.FROZEN[normalizedTexture] then
            -- Stock-compatible fallback for clients that cannot expose aura
            -- names. All ranks of each spell share its debuff texture.
            return "FROZEN"
        elseif wantedTextures.CHILLED[normalizedTexture] then
            foundChill = true
        end
    end
    return foundChill and "CHILLED" or nil
end

local function HasLivingEnemyTarget()
    return UnitExists("target")
        and UnitCanAttack("player", "target")
        and not UnitIsDeadOrGhost("target")
end

-- Target buffs that stop Frost Nova, Frostbolt slows and Cone of Cold.
-- FREEDOM only removes movement effects; IMMUNE blocks every spell.
local SLOW_IMMUNITY_BUFFS = {
    ["blessing of freedom"] = "FREEDOM", ["hand of freedom"] = "FREEDOM",
    ["free action"] = "FREEDOM", ["living free action"] = "FREEDOM",
    ["divine shield"] = "IMMUNE", ["divine protection"] = "IMMUNE",
    ["ice block"] = "IMMUNE"
}

-- Returns the buff name, its icon path and "FREEDOM"/"IMMUNE" while the
-- current enemy target cannot be slowed or rooted.
local function GetTargetSlowImmunity()
    if not HasLivingEnemyTarget() then return nil end
    local auras = GetUnitAuras("target")
    local i
    for i = 1, table.getn(auras) do
        local aura = auras[i]
        local kind = aura.name and SLOW_IMMUNITY_BUFFS[string.lower(aura.name)]
        if kind then
            return aura.name,
                aura.texture and ("Interface\\Icons\\" .. aura.texture),
                kind
        end
    end
    return nil
end

-- Nameplate features (Nova Range, scaling, target border, team colors) live
-- in one table to stay under Vanilla Lua's 200-local limit for the file.
local NP = {}

-- Master switch: with "MageCore nameplate styling" off, MageCore leaves the
-- plates to the client, pfUI or ShaguTweaks and only draws Nova Range.
function NP.StylingEnabled()
    return MageCore_Config and MageCore_Config.NameplateFeatures
end

function NP.IsVanillaNameplate(frame)
    if not frame then return false end
    local objectType = frame:GetObjectType()
    if objectType ~= "Button" and objectType ~= "Frame" then return false end

    -- SuperWoW exposes the unit GUID through GetName(1). TankPlates uses this
    -- signature, and unlike the native border texture it remains available
    -- after another nameplate addon has hidden or replaced the stock regions.
    if frame.GetName and frame.GetChildren then
        local ok, guid = pcall(frame.GetName, frame, 1)
        local firstChild = frame:GetChildren()
        if ok and guid and guid ~= "0x0000000000000000"
            and firstChild and firstChild.GetObjectType
            and firstChild:GetObjectType() == "StatusBar" then
            return true
        end
    end

    -- ShaguTweaks identifies native plates, then reparents their regions into
    -- plate.new. Its cached fields remain the most reliable identifiers.
    if frame.healthbar and frame.name then return true end
    local _, region
    for _, region in pairs({ frame:GetRegions() }) do
        if region.GetObjectType and region.GetTexture
            and region:GetObjectType() == "Texture" then
            local texture = region:GetTexture()
            texture = texture and string.lower(string.gsub(texture, "/", "\\"))
            if texture and string.find(
                texture, "nameplate-border", 1, true) then return true end
        end
    end
    return false
end

function NP.AddFrostNovaNameplate(parent)
    if not parent or S.frostNovaNameplates[parent] then return end
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

    S.frostNovaNameplates[parent] = {
        border = border,
        borderTextures = { top, bottom, left, right },
        anchor = nil,
        borderThickness = nil,
        sharpBorder = sharpBorder,
        sharpAnchor = nil,
        targetBorder = targetBorder,
        targetBorderTextures = {
            targetTop, targetBottom, targetLeft, targetRight
        },
        targetAnchor = nil,
        originalHealth = originalHealth,
        scaleContainer = nil,
        containerBaseScale = nil,
        baseWidth = nil,
        baseHeight = nil,
        visibilityUpdateHook = nil,
        plateVisible = true
    }
end

function NP.DiscoverFrostNovaNameplates()
    local childCount = WorldFrame:GetNumChildren()
    if childCount <= S.frostNovaNameplateCount then return end
    local children = { WorldFrame:GetChildren() }
    local i
    -- WorldFrame:GetChildren() does not guarantee stable insertion order.
    -- Rescan the full list when it grows so a newly allocated nameplate cannot
    -- land before the previous child-count index and escape discovery.
    for i = 1, childCount do
        local child = children[i]
        if NP.IsVanillaNameplate(child) then NP.AddFrostNovaNameplate(child) end
    end
    S.frostNovaNameplateCount = childCount
end

function NP.FrameHasUnitName(frame, unitName, depth)
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
            if NP.FrameHasUnitName(child, unitName, depth + 1) then
                return true
            end
        end
    end
    return false
end

function NP.GetFrostNovaNameplateUnit(parent, entry)
    -- SuperWoW extends GetName(1) on nameplates to return the unit GUID.
    if parent.GetName then
        local ok, guid = pcall(parent.GetName, parent, 1)
        -- UnitExists(guid) becomes unreliable for distant nameplates even
        -- though SuperWoW's other unit functions still accept that GUID.
        if ok and guid and guid ~= "0x0000000000000000" then return guid end
    end
    -- Stock Vanilla cannot identify every nameplate. pfUI can still help find
    -- the current target, but some SuperWoW/UI combinations leave istarget set
    -- on more than one plate. Verify the displayed name before trusting it.
    if parent.nameplate and parent.nameplate.istarget
        and UnitExists("target") then
        local targetName = UnitName("target")
        if NP.FrameHasUnitName(parent, targetName)
            or NP.FrameHasUnitName(entry.scaleContainer, targetName) then
            return "target"
        end
    end
    -- On the native Vanilla nameplates, the selected plate has full alpha.
    -- Matching its text as well avoids confusing same-area friendly plates.
    if UnitExists("target") and parent:GetAlpha() == 1 then
        local targetName = UnitName("target")
        if parent.name and parent.name:GetText() == targetName then return "target" end
        if NP.FrameHasUnitName(parent, targetName)
            or NP.FrameHasUnitName(entry.scaleContainer, targetName) then return "target" end

        -- Some native/Shagu layouts do not expose their moved name region
        -- consistently. With a player targeted, the sole full-alpha plate is
        -- still the client's selected plate.
        local playerOK, isPlayer = pcall(UnitIsPlayer, "target")
        if playerOK and isPlayer then return "target" end
    end
    return nil
end

function NP.HideFrostNovaRangeIndicators()
    local _, entry
    for _, entry in pairs(S.frostNovaNameplates) do entry.border:Hide() end
end

function NP.MoveNameplateObjectToContainer(
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

function NP.MoveNameplateVisualsToContainer(parent, entry)
    local container = entry.scaleContainer
    if not container then return end
    local _, child
    for _, child in pairs({ parent:GetChildren() }) do
        NP.MoveNameplateObjectToContainer(
            child, parent, container, child ~= container)
    end
    local _, region
    for _, region in pairs({ parent:GetRegions() }) do
        NP.MoveNameplateObjectToContainer(
            region, parent, container, true)
    end

    -- ShaguTweaks may have moved these objects before MageCore discovered the
    -- plate. Replace any remaining explicit anchors to the world plate with
    -- anchors to the movable visual container.
    for _, child in pairs({ container:GetChildren() }) do
        NP.MoveNameplateObjectToContainer(
            child, parent, container, false)
    end
    for _, region in pairs({ container:GetRegions() }) do
        NP.MoveNameplateObjectToContainer(
            region, parent, container, false)
    end
end

function NP.CountRegions(frame)
    return table.getn({ frame:GetRegions() })
end

-- Re-anchoring walks every child and region with GetPoint/SetPoint. Only do
-- it when the plate's object counts change, plus a slow 2-second safety pass.
function NP.MoveNameplateVisualsToContainerIfChanged(parent, entry)
    local container = entry.scaleContainer
    if not container then return end
    local now = GetTime()
    local signature = parent:GetNumChildren() .. ":" .. NP.CountRegions(parent)
        .. ":" .. container:GetNumChildren() .. ":" .. NP.CountRegions(container)
    if signature == entry.layoutSignature
        and now < (entry.layoutCheckAt or 0) then
        return
    end
    NP.MoveNameplateVisualsToContainer(parent, entry)
    entry.layoutSignature = parent:GetNumChildren() .. ":"
        .. NP.CountRegions(parent) .. ":" .. container:GetNumChildren()
        .. ":" .. NP.CountRegions(container)
    entry.layoutCheckAt = now + 2
end

function NP.EnsureNameplateScaleContainer(parent, entry)
    -- pfUI's health-bar callbacks resolve their plate through
    -- this:GetParent().nameplate. Never reparent pfUI-owned children; scale
    -- and filter its overlay directly instead.
    if parent.nameplate then
        if entry.scaleContainer ~= parent.nameplate then
            entry.scaleContainer = parent.nameplate
            entry.containerBaseScale = parent.nameplate:GetScale() or 1
            entry.baseWidth = nil
            entry.baseHeight = nil
        end
        return
    end

    if parent.new then
        if entry.scaleContainer ~= parent.new then
            entry.scaleContainer = parent.new
            -- ShaguTweaks can vary this container's scale as a plate moves.
            -- MageCore's slider is the authoritative fixed visual scale.
            entry.containerBaseScale = 1
            entry.baseWidth = parent:GetWidth()
            entry.baseHeight = parent:GetHeight()
        end
        NP.MoveNameplateVisualsToContainerIfChanged(parent, entry)
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
    NP.MoveNameplateVisualsToContainerIfChanged(parent, entry)
end

-- Applies size and raise to one plate. It runs on every frame after pfUI and
-- ShaguTweaks have updated the plate, so their own scaling cannot make it
-- jump, and it only touches anchors and sizes that actually differ.
function NP.ApplyEntryScale(parent, entry)
    local percent = tonumber(MageCore_Config.NameplateScale) or 100
    percent = math.max(50, math.min(150, percent))
    local ratio = percent / 100
    local verticalOffset = MageCore_Config.RaisedNameplates
        and NAMEPLATE_VERTICAL_OFFSET or 0

    -- pfUI draws the visible plate in this inner frame. Position and scale
    -- that overlay without changing the ownership of any pfUI objects.
    local target
    if parent.nameplate then
        target = parent.nameplate
        local point, relativeTo, _, _, y = target:GetPoint(1)
        if point ~= "TOP" or relativeTo ~= parent or y ~= verticalOffset
            or target:GetNumPoints() ~= 1 then
            target:ClearAllPoints()
            target:SetPoint("TOP", parent, "TOP", 0, verticalOffset)
        end
    elseif entry.scaleContainer and entry.containerBaseScale then
        target = entry.scaleContainer
        if entry.appliedOffset ~= verticalOffset then
            target:ClearAllPoints()
            target:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", 0, verticalOffset)
            target:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, verticalOffset)
            entry.appliedOffset = verticalOffset
        end
        -- Keep the parent's positional scale untouched, but resize its
        -- layout box with the visuals so the above-head anchor stays valid.
        if entry.baseWidth and entry.baseWidth > 0 then
            local width = entry.baseWidth * ratio
            if math.abs((parent:GetWidth() or 0) - width) > 0.5 then
                parent:SetWidth(width)
            end
        end
        if entry.baseHeight and entry.baseHeight > 0 then
            local height = entry.baseHeight * ratio
            if math.abs((parent:GetHeight() or 0) - height) > 0.5 then
                parent:SetHeight(height)
            end
        end
    end
    if target then
        local scale = (entry.containerBaseScale or 1) * ratio
        if math.abs((target:GetScale() or 1) - scale) > 0.001 then
            target:SetScale(scale)
        end
    end
end

function NP.ApplyNameplateScale()
    if not MageCore_Config or not MageCore_Config.NameplateFeatures then return end
    local parent, entry
    for parent, entry in pairs(S.frostNovaNameplates) do
        NP.EnsureNameplateScaleContainer(parent, entry)
        NP.ApplyEntryScale(parent, entry)
    end
end

function NP.GetNameplateHealthBar(parent, entry)
    return parent.nameplate and parent.nameplate.health
        or parent.healthbar or entry.originalHealth
end

function NP.GetNameplateDisplayedName(parent)
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

function NP.GetKnownNameplatePlayer(parent)
    local name = NP.GetNameplateDisplayedName(parent)
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

function NP.UpdateSharpNameplateEdges()
    local styling = NP.StylingEnabled()
    local parent, entry
    for parent, entry in pairs(S.frostNovaNameplates) do
        local anchor = NP.GetNameplateHealthBar(parent, entry)
        if anchor and anchor ~= entry.sharpAnchor then
            entry.sharpBorder:ClearAllPoints()
            entry.sharpBorder:SetPoint(
                "TOPLEFT", anchor, "TOPLEFT", -2, 2)
            entry.sharpBorder:SetPoint(
                "BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 2, -2)
            entry.sharpAnchor = anchor
        end
        if styling and MageCore_Config.SharpNameplateEdges
            and entry.plateVisible and parent:IsShown() then
            entry.sharpBorder:Show()
        else
            entry.sharpBorder:Hide()
        end
    end
end

function NP.IsCurrentTargetNameplate(parent, entry, unit)
    if not UnitExists("target") then return false end
    if unit == "target" then return true end

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

function NP.ApplyPfUINameColor(plate)
    if not NP.StylingEnabled() then return end
    if not plate or not plate.parent or not plate.name then return end
    local entry = S.frostNovaNameplates[plate.parent]
    if not entry then return end
    local unit = entry.unit
    if not entry.stateKnown then
        unit = NP.GetFrostNovaNameplateUnit(plate.parent, entry)
    end
    if not unit then return end
    local colorUnit = unit == "target" and "target" or unit

    local red, green, blue
    if colorUnit == "target" then
        local colorOK
        colorOK, red, green, blue = pcall(
            UnitSelectionColor, "target")
        if not colorOK then red, green, blue = nil, nil, nil end
    else
        -- UnitSelectionColor returns white for many untargeted SuperWoW GUIDs.
        -- UnitReaction retains the actual faction relationship at that range.
        local reactionOK, reaction = pcall(
            UnitReaction, "player", colorUnit)
        if reactionOK and reaction then
            if reaction <= 3 then
                red, green, blue = 1, 0.2, 0.2
            elseif reaction == 4 then
                red, green, blue = 1, 1, 0
            else
                red, green, blue = 0, 1, 0
            end
        end
    end
    if not red or not green or not blue then
        local health = plate.original and plate.original.healthbar
            or plate.health
        if health and health.GetStatusBarColor then
            red, green, blue = health:GetStatusBarColor()
        end
    end
    if red and green and blue then
        plate.name:SetTextColor(red, green, blue, 1)
    end
end

function NP.EnsurePfUINameColorHook()
    if not pfUI or not pfUI.nameplates
        or not pfUI.nameplates.OnDataChanged then return end
    local current = pfUI.nameplates.OnDataChanged
    if current == S.pfUINameplateColorHook then return end
    local previous = current
    local wrapper = function(self, plate)
        previous(self, plate)
        NP.ApplyPfUINameColor(plate)
    end
    S.pfUINameplateColorHook = wrapper
    pfUI.nameplates.OnDataChanged = wrapper
end

function NP.UpdateTargetNameplateBorder()
    local styling = NP.StylingEnabled()
    local parent, entry
    for parent, entry in pairs(S.frostNovaNameplates) do
        local anchor = NP.GetNameplateHealthBar(parent, entry)
        if anchor and anchor ~= entry.targetAnchor then
            entry.targetBorder:ClearAllPoints()
            entry.targetBorder:SetPoint(
                "TOPLEFT", anchor, "TOPLEFT", -3, 3)
            entry.targetBorder:SetPoint(
                "BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 3, -3)
            entry.targetAnchor = anchor
        end

        local unit = parent:IsShown() and entry.unit
        if styling and MageCore_Config.HighlightTargetNameplate
            and parent:IsShown()
            and NP.IsCurrentTargetNameplate(parent, entry, unit) then
            local colorOK, red, green, blue = pcall(
                UnitSelectionColor, "target")
            if colorOK and red and green and blue then
                local _, texture
                for _, texture in pairs(entry.targetBorderTextures) do
                    texture:SetTexture(red, green, blue, 1)
                end
            end
            entry.targetBorder:Show()
        else
            entry.targetBorder:Hide()
        end
    end
end

-- Far-away GUIDs sometimes answer unit queries and sometimes do not. Keep
-- the last known answer per GUID so a plate does not flip colors or switch
-- between full and name-only mode while the unit is far away.
function NP.RememberDisposition(unit, disposition)
    if type(unit) ~= "string" or string.sub(unit, 1, 2) ~= "0x" then
        return disposition
    end
    if disposition then
        if not S.guidDispositions[unit] then
            S.guidDispositionCount = S.guidDispositionCount + 1
            if S.guidDispositionCount > 1000 then
                S.guidDispositions = {}
                S.guidDispositionCount = 1
            end
        end
        S.guidDispositions[unit] = disposition
        return disposition
    end
    return S.guidDispositions[unit]
end

function NP.GetNameplateDisposition(parent, entry, unit)
    local health = NP.GetNameplateHealthBar(parent, entry)
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
                or NP.GetNameplateDisplayedName(parent)
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

        -- Friendly players can use a blue selection circle, and distant
        -- SuperWoW GUIDs often report a white circle, so fall back to the
        -- faction reaction, which stays available at long range.
        if not disposition then
            local reactionOK, reaction = pcall(
                UnitReaction, "player", unit)
            if reactionOK and reaction then
                if reaction <= 3 then
                    disposition = "HOSTILE"
                elseif reaction >= 5 then
                    disposition = "FRIENDLY"
                else
                    -- Neutral creatures turn red once they are in combat.
                    local combatOK, inCombat = pcall(UnitAffectingCombat, unit)
                    disposition = (combatOK and inCombat)
                        and "HOSTILE" or "NEUTRAL"
                end
            end
        end
        disposition = NP.RememberDisposition(unit, disposition)
    elseif health.GetStatusBarColor then
        local knownPlayer, plateName =
            NP.GetKnownNameplatePlayer(parent)
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

function NP.UpdateNameplateTeamColor(parent, entry)
    local health = NP.GetNameplateHealthBar(parent, entry)
    if not health or not health.SetStatusBarColor then return end
    local disposition = entry.disposition

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

function NP.ApplyNameplateVisibility()
    if not NP.StylingEnabled() then return end

    -- Vanilla 1.12 exposes nameplate visibility through functions rather than
    -- the newer nameplateShowEnemies/nameplateShowFriends CVars. Keep both
    -- types allocated in target-only mode even without a target: MageCore
    -- turns non-target pfUI plates into scalable name-only displays.
    if MageCore_Config.AlwaysShowNameplates
        or MageCore_Config.HighlightTargetNameplate then
        if ShowNameplates then ShowNameplates() end
    elseif HideNameplates then
        HideNameplates()
    end

    if MageCore_Config.ShowFriendlyNameplates
        or MageCore_Config.HighlightTargetNameplate then
        if ShowFriendNameplates then ShowFriendNameplates() end
    elseif HideFriendNameplates then
        HideFriendNameplates()
    end
end

function NP.SetPfFont(entry, fontString, key, enlarged)
    if not fontString or not fontString.GetFont
        or not fontString.SetFont then return end
    if not entry[key] then
        local path, size, flags = fontString:GetFont()
        if path and size then entry[key] = { path, size, flags } end
    end
    local font = entry[key]
    if font then
        local wanted = font[2]
            * (enlarged and NON_TARGET_NAME_FONT_SCALE or 1)
        -- SetFont rebuilds the glyph cache, so only call it on a change.
        local _, currentSize = fontString:GetFont()
        if not currentSize or math.abs(currentSize - wanted) > 0.01 then
            fontString:SetFont(font[1], wanted, font[3])
        end
    end
end

function NP.ComputeNameplateVisibility(parent, entry)
    local visible = false
    local currentTarget = false
    if not NP.StylingEnabled() then
        visible = parent:IsShown()
    elseif parent:IsShown() then
        if MageCore_Config.HighlightTargetNameplate
            and NP.IsCurrentTargetNameplate(parent, entry, entry.unit) then
            visible = true
            currentTarget = true
        elseif entry.disposition == "FRIENDLY" then
            visible = MageCore_Config.ShowFriendlyNameplates
        else
            -- Hostile, neutral, and unidentified native plates are
            -- controlled by the enemy-nameplate setting.
            visible = MageCore_Config.AlwaysShowNameplates
        end
    end
    entry.plateVisible = visible and true or false
    entry.isCurrentTarget = currentTarget
end

-- Unit identification is the expensive part of nameplate handling. It runs
-- on the 0.1s tick, on target changes, and immediately when a recycled
-- plate starts showing a different name; per-frame code reuses the result.
function NP.RefreshNameplateEntry(parent, entry)
    if parent:IsShown() then
        entry.unit = NP.GetFrostNovaNameplateUnit(parent, entry)
        entry.disposition = NP.GetNameplateDisposition(parent, entry, entry.unit)
    else
        entry.unit = nil
        entry.disposition = nil
    end
    entry.stateName = NP.GetNameplateDisplayedName(parent)
    entry.stateKnown = true
    NP.ComputeNameplateVisibility(parent, entry)
end

function NP.RefreshNameplateStates()
    local parent, entry
    for parent, entry in pairs(S.frostNovaNameplates) do
        NP.RefreshNameplateEntry(parent, entry)
    end
end

function NP.RenderNameplateVisibility(parent, entry)
    -- Other addons can chain this plate's OnUpdate more than once; one
    -- render per frame is enough.
    local now = GetTime()
    if entry.renderedAt == now then return end
    entry.renderedAt = now
    if not NP.StylingEnabled() then return end
    if parent:IsShown()
        and NP.GetNameplateDisplayedName(parent) ~= entry.stateName then
        NP.RefreshNameplateEntry(parent, entry)
    end
    NP.ApplyEntryScale(parent, entry)

    -- pfUI redraws and explicitly shows its nameplate child on every
    -- update. For non-targets, retain its ordinary floating name while
    -- hiding the actual plate instead of hiding the complete overlay.
    local pfPlate = parent.nameplate
    if entry.plateVisible then
        if pfPlate then
            NP.SetPfFont(entry, pfPlate.name, "pfNameFont", false)
            NP.SetPfFont(entry, pfPlate.level, "pfLevelFont", false)
            -- Restore the normal pfUI hierarchy after this recycled plate
            -- previously spent time in MageCore's name-only mode.
            if pfPlate.health then
                if pfPlate.name then
                    pfPlate.name:SetParent(pfPlate.health)
                    if entry.isCurrentTarget then
                        NP.ApplyPfUINameColor(pfPlate)
                    end
                    pfPlate.name:Show()
                end
                if pfPlate.level then
                    pfPlate.level:ClearAllPoints()
                    pfPlate.level:SetPoint(
                        "RIGHT", pfPlate.health, "LEFT", -5, 0)
                    pfPlate.level:Show()
                end
                pfPlate.health:Show()
            end
        end
        if entry.scaleContainer then entry.scaleContainer:Show() end
        if pfPlate then pfPlate:Show() end
    elseif pfPlate then
        pfPlate:Show()
        if pfPlate.name then
            NP.SetPfFont(entry, pfPlate.name, "pfNameFont", true)
            pfPlate.name:SetParent(pfPlate)
            NP.ApplyPfUINameColor(pfPlate)
            pfPlate.name:Show()
        end
        if pfPlate.level then
            NP.SetPfFont(entry, pfPlate.level, "pfLevelFont", true)
            pfPlate.level:ClearAllPoints()
            pfPlate.level:SetPoint(
                "RIGHT", pfPlate.name, "LEFT", -3, 0)
            pfPlate.level:Show()
        end
        if pfPlate.health then pfPlate.health:Hide() end
        if pfPlate.glow then pfPlate.glow:Hide() end
        if pfPlate.totem then pfPlate.totem:Hide() end
        if pfPlate.castbar then pfPlate.castbar:Hide() end
        local _, debuff
        for _, debuff in pairs(pfPlate.debuffs or {}) do
            debuff:Hide()
        end
        local _, combo
        for _, combo in pairs(pfPlate.combopoints or {}) do
            combo:Hide()
        end
        entry.border:Hide()
        entry.sharpBorder:Hide()
        entry.targetBorder:Hide()
    else
        if entry.scaleContainer then entry.scaleContainer:Hide() end
    end
end

function NP.ApplyTargetOnlyNameplateVisibility(refreshUnits)
    if not MageCore_Config then return end
    if refreshUnits then NP.RefreshNameplateStates() end

    local parent, entry
    for parent, entry in pairs(S.frostNovaNameplates) do
        if parent.GetScript and parent.SetScript then
            local currentUpdate = parent:GetScript("OnUpdate")
            if currentUpdate ~= entry.visibilityUpdateHook then
                local previousUpdate = currentUpdate
                local hookedParent = parent
                local hookedEntry = entry
                local wrapper = function()
                    if previousUpdate then previousUpdate() end
                    NP.RenderNameplateVisibility(hookedParent, hookedEntry)
                end
                entry.visibilityUpdateHook = wrapper
                parent:SetScript("OnUpdate", wrapper)
            end
        end
        if not entry.stateKnown then NP.RefreshNameplateEntry(parent, entry) end
        NP.ComputeNameplateVisibility(parent, entry)
        entry.renderedAt = nil
        NP.RenderNameplateVisibility(parent, entry)
    end
end

function NP.PrintNameplateDebug()
    NP.DiscoverFrostNovaNameplates()
    local tracked, shown, targets, containers, pfPlates = 0, 0, 0, 0, 0
    local parent, entry
    for parent, entry in pairs(S.frostNovaNameplates) do
        tracked = tracked + 1
        if parent:IsShown() then shown = shown + 1 end
        if entry.scaleContainer then containers = containers + 1 end
        if parent.nameplate then pfPlates = pfPlates + 1 end
        local unit = NP.GetFrostNovaNameplateUnit(parent, entry)
        if NP.IsCurrentTargetNameplate(parent, entry, unit) then
            targets = targets + 1
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage(
        ACCENT .. "[MageCore]|r plates: world="
            .. WorldFrame:GetNumChildren() .. ", tracked=" .. tracked
            .. ", shown=" .. shown .. ", targets=" .. targets
            .. ", containers=" .. containers .. ", pfUI=" .. pfPlates)
end

function NP.IsUnitInFrostNovaRange(unit)
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
                <= S.frostNovaRangeYards * S.frostNovaRangeYards then
                return true
            end
            -- Coordinates measure center to center. Do not reject the spell
            -- yet: Cone of Cold can still reach the edge of a large unit's
            -- combat hitbox, which the client range check accounts for.
        end
    end

    -- Indices 3 and 2 are approximately 9.9 and 11.1 yards respectively.
    local rangeOK, inRange = pcall(CheckInteractDistance, unit, S.frostNovaRangeDistanceIndex)
    return rangeOK and inRange
end

function NP.SetFrostNovaBorderColor(entry, red, green, blue)
    local _, texture
    for _, texture in pairs(entry.borderTextures) do
        texture:SetTexture(red, green, blue, 1)
    end
end

function NP.SetFrostNovaBorderThickness(entry, anchor, thickness)
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

function NP.UpdateFrostNovaRangeIndicators()
    NP.DiscoverFrostNovaNameplates()
    if not MageCore_Config then return end
    NP.EnsurePfUINameColorHook()
    -- Identify every plate's unit once; all passes below reuse it.
    NP.RefreshNameplateStates()
    NP.ApplyNameplateScale()
    NP.UpdateSharpNameplateEdges()
    NP.UpdateTargetNameplateBorder()

    local parent, entry
    if NP.StylingEnabled() and MageCore_Config.TeamNameplateColors then
        for parent, entry in pairs(S.frostNovaNameplates) do
            if parent:IsShown() then NP.UpdateNameplateTeamColor(parent, entry) end
        end
    end
    NP.ApplyTargetOnlyNameplateVisibility(false)

    if not MageCore_Config.FrostNovaRange then
        NP.HideFrostNovaRangeIndicators()
        return
    end

    for parent, entry in pairs(S.frostNovaNameplates) do
        local anchor = NP.GetNameplateHealthBar(parent, entry)
        local unit = parent:IsShown() and entry.unit
        -- Only enemies you can actually reach with Frost Nova are marked;
        -- an outline on every distant enemy was noise, not information.
        if entry.plateVisible and parent:IsShown()
            and entry.disposition == "HOSTILE"
            and unit and NP.IsUnitInFrostNovaRange(unit) then
            NP.SetFrostNovaBorderThickness(entry, anchor, 2)
            NP.SetFrostNovaBorderColor(entry, 0.2, 1, 0.2)
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
    if IsInInstance then
        local _, instanceType = IsInInstance()
        if instanceType == "pvp" then return true end
    end
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
        S.fireThreatTargets[targetKey] =
            GetTime() + FIRE_THREAT_MEMORY_SECONDS
    end

    local isFireThreat = false
    local rememberedUntil = S.fireThreatTargets[targetKey]
    if rememberedUntil and rememberedUntil > GetTime() then
        isFireThreat = true
    elseif rememberedUntil then
        S.fireThreatTargets[targetKey] = nil
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

-- Action-bar contents rarely change. Index the 120 slots by icon once and
-- reuse it until ACTIONBAR_SLOT_CHANGED (or a 5-second safety refresh).
local function GetActionSlotsForTexture(texture, includeMacros)
    local wanted = NormalizeTexture(texture)
    if not wanted then return {} end
    local now = GetTime()
    if not S.actionSlotIndex or now >= (S.actionSlotIndexExpires or 0) then
        local index = {}
        local slot
        for slot = 1, 120 do
            local slotTexture = GetActionTexture(slot)
            if slotTexture then
                local key = NormalizeTexture(slotTexture)
                index[key] = index[key] or {}
                table.insert(index[key], {
                    slot = slot, macro = GetActionText(slot) ~= nil
                })
            end
        end
        S.actionSlotIndex = index
        S.actionSlotIndexExpires = now + 5
    end
    local result = {}
    local _, entry
    for _, entry in ipairs(S.actionSlotIndex[wanted] or {}) do
        -- Macros (including MageRot itself) can share a spell's icon but do
        -- not report that spell's range or reactive state.
        if includeMacros or not entry.macro then
            table.insert(result, entry.slot)
        end
    end
    return result
end

local function GetSpellRangeState(spellName)
    if not spellName or not HasLivingEnemyTarget() then return nil end

    -- Some Turtle clients expose the later helper even though stock 1.12 does
    -- not. Use it when present, then fall back to matching action-bar spells.
    if IsSpellInRange then
        local state = IsSpellInRange(spellName, "target")
        if state == 0 then return false end
        if state == 1 then return true end
    end

    if IsActionInRange then
        local foundInRange = false
        local _, slot
        for _, slot in ipairs(GetActionSlotsForTexture(
            GetSpellTextureByName(spellName))) do
            local state = IsActionInRange(slot)
            if state == 0 then return false end
            if state == 1 then foundInRange = true end
        end
        if foundInRange then return true end
    end
    return nil
end

local function IsRangeBlocked(spellName)
    local blocked = S.rangeBlockedSpells[spellName]
    if not blocked then return false end
    if blocked.target ~= GetTargetKey() or GetTime() >= blocked.expires then
        S.rangeBlockedSpells[spellName] = nil
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
        return HasLivingEnemyTarget() and NP.IsUnitInFrostNovaRange("target")
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
    if S.autoRepeatActive then return true end
    local _, slot
    for _, slot in ipairs(GetActionSlotsForTexture(
        GetSpellTextureByName(spellName), true)) do
        if IsCurrentAction(slot) then return true end
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
    -- v1.6: the Mana Agate option now covers every mana gem.
    if MageCore_Config.AutoManaGems == nil then
        MageCore_Config.AutoManaGems =
            MageCore_Config.AutoConjureManaAgate and true or false
    end
    if MageCore_Config.ManaGemManaThreshold == nil then
        MageCore_Config.ManaGemManaThreshold =
            MageCore_Config.ManaAgateManaThreshold or 500
    end
    MageCore_Config.AutoConjureManaAgate = nil
    MageCore_Config.ManaAgateManaThreshold = nil
    MageCore_Config.ManaGemManaThreshold = math.max(
        0, math.min(9999,
            tonumber(MageCore_Config.ManaGemManaThreshold) or 500))
    if MageCore_Config.AutoDefilersTalisman == nil then
        MageCore_Config.AutoDefilersTalisman = false
    end
    if MageCore_Config.DefilersTalismanHealthLostPercent == nil then
        MageCore_Config.DefilersTalismanHealthLostPercent = 20
    end
    -- v1.6: renamed; the value always meant "current health %".
    if MageCore_Config.HealingPotionHealthPercent == nil then
        MageCore_Config.HealingPotionHealthPercent =
            MageCore_Config.HealingPotionHealthLostPercent or 0
    end
    MageCore_Config.HealingPotionHealthLostPercent = nil
    if MageCore_Config.AutoTargetEnemy == nil then
        MageCore_Config.AutoTargetEnemy = true
    end
    if MageCore_Config.PvPBurst == nil then MageCore_Config.PvPBurst = true end
    if MageCore_Config.PvPReslow == nil then MageCore_Config.PvPReslow = true end
    if MageCore_Config.PvPTargetPlayersOnly == nil then
        MageCore_Config.PvPTargetPlayersOnly = true
    end
    if MageCore_Config.PvPTrinket == nil then MageCore_Config.PvPTrinket = true end
    if MageCore_Config.AutoArcaneSurge == nil then
        MageCore_Config.AutoArcaneSurge = true
    end
    if MageCore_Config.AutoEvocation == nil then
        MageCore_Config.AutoEvocation = false
    end
    if MageCore_Config.EvocationManaPercent == nil then
        MageCore_Config.EvocationManaPercent = 10
    end
    if MageCore_Config.AutoDefensiveShield == nil then
        MageCore_Config.AutoDefensiveShield = false
    end
    if MageCore_Config.DefensiveShieldHealthPercent == nil then
        MageCore_Config.DefensiveShieldHealthPercent = 40
    end
    if MageCore_Config.Profiles == nil then MageCore_Config.Profiles = {} end
    if MageCore_Config.XPBarShown == nil then MageCore_Config.XPBarShown = false end
    if MageCore_Config.NameplateFeatures == nil then
        MageCore_Config.NameplateFeatures = true
    end
    if MageCore_Config.XPBarLocked == nil then MageCore_Config.XPBarLocked = false end
    if MageCore_Config.XPBarX == nil then MageCore_Config.XPBarX = 0 end
    if MageCore_Config.XPBarY == nil then MageCore_Config.XPBarY = -200 end
    if MageCore_Config.XPBarScale == nil then MageCore_Config.XPBarScale = 100 end
    if MageCore_Config.CastBarShown == nil then MageCore_Config.CastBarShown = false end
    if MageCore_Config.CastBarLocked == nil then MageCore_Config.CastBarLocked = false end
    if MageCore_Config.CastBarX == nil then MageCore_Config.CastBarX = 0 end
    if MageCore_Config.CastBarY == nil then MageCore_Config.CastBarY = -150 end
    if MageCore_Config.CastBarScale == nil then MageCore_Config.CastBarScale = 100 end
    if MageCore_Config.TargetCastBarShown == nil then
        MageCore_Config.TargetCastBarShown = true
    end
    if MageCore_Config.TargetCastBarLocked == nil then
        MageCore_Config.TargetCastBarLocked = true
    end
    if MageCore_Config.TargetCastBarX == nil then MageCore_Config.TargetCastBarX = 0 end
    if MageCore_Config.TargetCastBarY == nil then MageCore_Config.TargetCastBarY = -100 end
    if MageCore_Config.TargetCastBarScale == nil then
        MageCore_Config.TargetCastBarScale = 100
    end
    if MageCore_Config.NoSlowAlert == nil then MageCore_Config.NoSlowAlert = true end
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
    if MageCore_Config.BuffArmorLayoutVersion ~= 1 then
        local armor = "None"
        local regular = {}
        for i = 1, 6 do
            local spellName = MageCore_Config["Buff" .. i]
            if MAGE_ARMOR_NAMES[spellName] then
                if armor == "None" then armor = spellName end
            elseif spellName and spellName ~= "None" then
                table.insert(regular, {
                    spell = spellName,
                    group = MageCore_Config["Buff" .. i .. "Group"]
                })
            end
        end
        MageCore_Config.Buff1 = armor
        MageCore_Config.Buff1Group = false
        for i = 2, 6 do
            local entry = regular[i - 1]
            MageCore_Config["Buff" .. i] = entry and entry.spell or "None"
            MageCore_Config["Buff" .. i .. "Group"] =
                entry and entry.group or false
        end
        MageCore_Config.BuffArmorLayoutVersion = 1
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
    S.configTable = MageCore_Config
end

-- Defaults and migrations run once when saved variables load. Hot paths only
-- need this cheap guard instead of re-running every migration on each press.
local function EnsureConfig()
    -- Comparing the table itself also catches saved variables replacing the
    -- table after an early call, and /mc reset installing a new one.
    if not MageCore_Config or S.configTable ~= MageCore_Config then
        LoadDefaults()
    end
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
    local blockedUntil = S.groupBlockedUnits[key]
    if blockedUntil and GetTime() < blockedUntil then return false end
    if blockedUntil then S.groupBlockedUnits[key] = nil end
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
    EnsureConfig()
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

-- With "Surge on proc" enabled (the default), Rotation casts Arcane Surge as
-- soon as a resist proc is available, without it occupying a Rotation slot.
-- When disabled, Rotation only uses it if a slot is set to Arcane Surge.
-- The Arcane Explosion button always uses a Surge proc.
local function IsArcaneSurgeConfigured()
    if MageCore_Config.AutoArcaneSurge then return true end
    local i
    for i = 1, 6 do
        if MageCore_Config["Rotation" .. i] == "Arcane Surge" then
            return true
        end
    end
    return false
end

-- Only a real cooldown blocks Surge here, not the shared global cooldown:
-- the proc itself must be recognised the moment it appears.
local function IsOnRealCooldown(start, duration)
    return start and duration and start > 0 and duration > 1.5
        and start + duration > GetTime()
end

local function GetArcaneSurgeActionSlotState()
    local slot = GetActionSlotsForTexture(
        GetSpellTextureByName("Arcane Surge"))[1]
    if not slot then return nil, nil end
    local usable, notEnoughMana = IsUsableAction(slot)
    local start, duration = GetActionCooldown(slot)
    return usable == 1 and not notEnoughMana
        and not IsOnRealCooldown(start, duration), slot
end

-- requireCastableNow is only set while Arcane Missiles is channeling: then
-- the channel is cancelled only when Surge can be cast at once. Otherwise a
-- proc is chosen even during the global cooldown, so the next press (or the
-- client's spell queue) casts Surge instead of another rotation spell.
local function GetArcaneSurgeAction(ignoreRotationConfiguration, requireCastableNow)
    if not ignoreRotationConfiguration and not IsArcaneSurgeConfigured() then
        return nil
    end
    if not HasLivingEnemyTarget() then return nil end
    -- Vanilla exposes reactive conditions most reliably through an actual
    -- action-bar spell slot. Combat-log tracking covers characters that keep
    -- Arcane Surge only in MageCore's rotation. GetSpellCooldown alone says
    -- Arcane Surge is ready even before a resist enables it.
    local usable = GetArcaneSurgeActionSlotState()
        or S.arcaneSurgeAvailableUntil > GetTime()
    if not usable then return nil end
    local start, duration, enabled = GetSpellCooldownInfo("Arcane Surge")
    if start == nil or enabled == 0 then return nil end
    if requireCastableNow then
        if start > 0 and duration > 0 and start + duration > GetTime() then
            return nil
        end
    elseif IsOnRealCooldown(start, duration) then
        return nil
    end
    local manaCost = GetSpellManaCost("Arcane Surge")
    if (manaCost and UnitMana("player") < manaCost)
        or not SpellCanReachTarget("Arcane Surge") then
        return nil
    end
    return "Arcane Surge"
end

local function GetArcaneExplosionButtonAction()
    local arcaneSurge = GetArcaneSurgeAction(true)
    if arcaneSurge then return arcaneSurge end
    if GetSpellBookIndex("Arcane Explosion") then
        return "Arcane Explosion"
    end
    return nil
end

local function TrackArcaneSurgeFromCombatMessage(message)
    local lowerMessage = string.lower(message or "")
    if not string.find(lowerMessage, "resist", 1, true) then return end
    local _, spellName
    for _, spellName in ipairs(ARCANE_SURGE_TRIGGER_SPELLS) do
        if string.find(
            lowerMessage, string.lower(spellName), 1, true) then
            S.arcaneSurgeAvailableUntil = GetTime() + 4
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

local function SpellIsManaBlocked(spellName)
    local index = GetSpellBookIndex(spellName)
    if index and IsUsableSpell then
        local usable, notEnoughMana =
            IsUsableSpell(index, BOOKTYPE_SPELL)
        if notEnoughMana and notEnoughMana ~= 0 then return true end
    end
    local manaCost = GetSpellManaCost(spellName)
    return manaCost and UnitMana("player") < manaCost or false
end

local function HasEnoughManaForSpell(spellName)
    return not SpellIsManaBlocked(spellName)
end

local function AllConfiguredRotationSpellsNeedMana()
    local foundSpell = false
    local i
    for i = 1, 6 do
        local spellName = MageCore_Config["Rotation" .. i]
        if spellName and spellName ~= "None" and spellName ~= "Shoot"
            and GetSpellBookIndex(spellName) then
            foundSpell = true
            if not SpellIsManaBlocked(spellName) then return false end
        end
    end
    return foundSpell
end

local function GetLowManaWandAction()
    if not HasLivingEnemyTarget() then return nil end
    if not AllConfiguredRotationSpellsNeedMana()
        and GetTime() >= S.lowManaWandFallbackUntil then
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
    local slot = GetActionSlotsForTexture(GetSpellTextureByName("Shoot"))[1]
    if slot then
        UseAction(slot)
        return true
    end

    CastSpellByName("Shoot")
    return true
end

local function GetNextCombatSpell()
    EnsureConfig()
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

-- Vanilla has no facing API. When a spell fails with "Target needs to be in
-- front of you", remember that for this target for a moment so the PvP burst
-- does not waste Cone of Cold (which never reports that error itself).
local function IsTargetBehindUs()
    local blocked = S.facingBlocked
    if not blocked then return false end
    if blocked.target ~= GetTargetKey() or GetTime() >= blocked.expires then
        S.facingBlocked = nil
        return false
    end
    return true
end

-- PvP burst: with PvP Mode on and a living enemy targeted, fire Cone of Cold
-- when the target is inside its (Arctic Reach adjusted) range, then Fire
-- Blast, before the normal PvP Frostbolt logic. Arcane Surge already has a
-- higher priority whenever its proc is up.
local PVP_BURST_SPELLS = { "Cone of Cold", "Fire Blast" }

local function GetPvpBurstSpell()
    if not MageCore_Config.PvPMode or not MageCore_Config.PvPBurst
        or not HasLivingEnemyTarget() or IsTargetBehindUs() then
        return nil
    end
    local _, spellName
    for _, spellName in ipairs(PVP_BURST_SPELLS) do
        if GetSpellBookIndex(spellName) and IsSpellReady(spellName)
            and HasEnoughManaForSpell(spellName)
            and SpellCanReachTarget(spellName) then
            return spellName
        end
    end
    return nil
end

-- Last step of the PvP burst: Arcane Explosion while the target stands
-- inside its fixed 10-yard radius (Arctic Reach does not change it). It runs
-- after the PvP Frostbolt logic so a Rank 1 slow or a shatter Frostbolt on a
-- frozen target still comes first. No facing is needed.
local function GetPvpArcaneExplosionSpell()
    local spellName = "Arcane Explosion"
    if not MageCore_Config.PvPMode or not MageCore_Config.PvPBurst
        or not HasLivingEnemyTarget()
        or not GetSpellBookIndex(spellName) or not IsSpellReady(spellName)
        or not HasEnoughManaForSpell(spellName) then
        return nil
    end
    if UnitPosition then
        local playerOK, playerX, playerY = pcall(UnitPosition, "player")
        local unitOK, unitX, unitY = pcall(UnitPosition, "target")
        if playerOK and unitOK and playerX and playerY and unitX and unitY then
            local deltaX, deltaY = playerX - unitX, playerY - unitY
            if deltaX * deltaX + deltaY * deltaY <= 100 then return spellName end
        end
    end
    -- Index 3 is the ~10-yard duel distance.
    local ok, inRange = pcall(CheckInteractDistance, "target", 3)
    if ok and inRange then return spellName end
    return nil
end

local RESLOW_SECONDS = 4

local function GetPvpFrostboltSpell()
    local rankOne = "Frostbolt(Rank 1)"
    if not MageCore_Config.PvPMode
        or not HasLivingEnemyTarget() then return nil end
    -- Don't use up the single Rank 1 attempt while the target is behind us.
    if IsTargetBehindUs() then return nil end

    local frostEffect = GetTargetPvpFrostEffect()
    local spellName
    if frostEffect == "FROZEN" then
        -- A real freeze is a short damage window. Give the strongest learned
        -- Frostbolt priority over the configured Fire rotation.
        spellName = "Frostbolt"
    elseif not frostEffect then
        -- Freedom, Divine Shield or Ice Block: a Rank 1 slow is wasted.
        if GetTargetSlowImmunity() then return nil end
        -- After the first Rank 1 on this target, "Re-slow" lets Rotation cast
        -- it again once the chill has worn off (at most every 4 seconds, so
        -- an immune or resisting target is not spammed).
        if S.pvpFrostboltUsedForTarget == GetTargetKey()
            and (not MageCore_Config.PvPReslow
                or GetTime() - (S.lastRankOneFrostbolt or 0) < RESLOW_SECONDS) then
            return nil
        end
        spellName = rankOne
    else
        -- An ordinary Frostbolt/Cone of Cold chill needs no PvP override.
        return nil
    end

    if not GetSpellBookIndex(spellName)
        or not IsSpellReady(spellName)
        or not HasEnoughManaForSpell(spellName)
        or not SpellCanReachTarget(spellName) then return nil end
    return spellName
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
    if S.openerUsedForTarget == GetTargetKey() then return nil end
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
        -- This temporary retarget (and the restore below) is not a real
        -- target change; keep the per-target opener/PvP/range state.
        S.suppressTargetResetUntil = GetTime() + 0.5
        TargetUnit(unit)
        -- Do not cast unless target acquisition actually succeeded. This is a
        -- final guard against auto-self-cast when a group member phases,
        -- zones, or enters another instance between selection and the cast.
        if not UnitExists("target")
            or not UnitIsUnit("target", unit) then
            return false
        end
    end
    S.lastGroupBuffAttempt = {
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

-- One pass over the bags, cached until the next BAG_UPDATE. Conjure,
-- mana gem and food-status checks all read from this snapshot.
local function GetBagSnapshot()
    if S.bagSnapshot then return S.bagSnapshot end
    local snapshot = { counts = {}, names = {}, positions = {}, free = 0 }
    local bag, slot
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, itemID = string.find(link, "item:(%d+)")
                local _, _, itemName = string.find(link, "%[(.-)%]")
                local _, count = GetContainerItemInfo(bag, slot)
                if itemID then
                    snapshot.counts[itemID] =
                        (snapshot.counts[itemID] or 0) + (count or 1)
                    snapshot.names[itemID] = itemName
                end
                if itemName then
                    local key = string.lower(itemName)
                    if not snapshot.positions[key] then
                        snapshot.positions[key] = { bag, slot }
                    end
                end
            else
                snapshot.free = snapshot.free + 1
            end
        end
    end
    S.bagSnapshot = snapshot
    return snapshot
end

local function GetBagItemCounts()
    local snapshot = GetBagSnapshot()
    return snapshot.counts, snapshot.names
end

local function GetItemCountByID(itemID)
    if not itemID then return 0 end
    return GetBagSnapshot().counts[tostring(itemID)] or 0
end

local function FindBagItemByName(itemName)
    local position = GetBagSnapshot().positions[string.lower(itemName or "")]
    if position then return position[1], position[2] end
    return nil, nil
end

local function HasFreeBagSlot()
    return GetBagSnapshot().free > 0
end

local function ShowManaGemWarning(message)
    DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "[MageCore]|r |cffff0000Mana gem warning:|r " .. message)
    if UIErrorsFrame then UIErrorsFrame:AddMessage("Mana gem: " .. message, 1, 0.1, 0.1, 1) end
end

-- Out of combat, conjure every learned mana gem that is missing from the
-- bags (strongest first). Returns the conjure spell and its item, or "WAIT"
-- while a recent conjure is still landing in the bags.
-- Strongest first. Vanilla mages can carry one of each gem.
local MANA_GEM_CONJURES = {
    { item = "Mana Ruby", spell = "Conjure Mana Ruby" },
    { item = "Mana Citrine", spell = "Conjure Mana Citrine" },
    { item = "Mana Jade", spell = "Conjure Mana Jade" },
    { item = "Mana Agate", spell = "Conjure Mana Agate" }
}

local function GetManaGemMaintenanceAction(showWarnings)
    if not MageCore_Config.AutoManaGems or UnitAffectingCombat("player") then
        return nil
    end
    local pending = S.pendingManaGem
    if pending then
        if FindBagItemByName(pending.item) then
            S.pendingManaGem = nil
        elseif GetTime() - pending.time <= 5 then
            return "WAIT", pending.spell
        else
            S.pendingManaGem = nil
        end
    end

    local learnedAny = false
    local _, gem
    for _, gem in ipairs(MANA_GEM_CONJURES) do
        if GetSpellBookIndex(gem.spell) then
            learnedAny = true
            if not FindBagItemByName(gem.item) then
                if not HasFreeBagSlot() then
                    if showWarnings
                        and GetTime() - S.lastManaGemBagWarning >= 10 then
                        ShowManaGemWarning("Your bags are full.")
                        S.lastManaGemBagWarning = GetTime()
                    end
                    return nil
                end
                local manaCost = GetSpellManaCost(gem.spell)
                if IsSpellReady(gem.spell)
                    and (not manaCost or UnitMana("player") >= manaCost) then
                    return gem.spell, gem.item
                end
            end
        end
    end
    if not learnedAny and showWarnings
        and GetTime() - S.lastManaGemSpellWarning >= 10 then
        ShowManaGemWarning("No Conjure Mana gem spell was found.")
        S.lastManaGemSpellWarning = GetTime()
    end
    return nil
end

local function LearnPendingConjureItem()
    if not S.pendingConjure then return end
    if GetTime() - S.pendingConjure.started > 5 then
        S.pendingConjure = nil
        return
    end
    local current, names = GetBagItemCounts()
    local itemID, count
    for itemID, count in pairs(current) do
        -- Only conjured items qualify, so loot that arrives during the cast
        -- cannot be learned as the water or food item by mistake.
        local name = names[itemID] or ""
        if count > (S.pendingConjure.before[itemID] or 0)
            and string.find(name, "^Conjured") then
            MageCore_Config[S.pendingConjure.kind .. "ItemID"] = itemID
            S.pendingConjure = nil
            return
        end
    end
end

local function GetNextConjureAction()
    if UnitAffectingCombat("player") then return nil end
    if S.pendingConjure then
        if GetTime() - S.pendingConjure.started <= 5 then return "WAIT" end
        S.pendingConjure = nil
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
                S.conjureRestockActive[kind] = true
                return spellName, kind
            end
            local count = GetItemCountByID(itemID)
            if count <= minimum then S.conjureRestockActive[kind] = true end
            if S.conjureRestockActive[kind] then
                if count >= maximum then
                    S.conjureRestockActive[kind] = nil
                else
                    return spellName, kind
                end
            end
        else
            S.conjureRestockActive[kind] = nil
        end
    end
    return nil
end

local function CastConjureSpell(spellName, kind)
    S.pendingConjure = {
        spell = spellName,
        kind = kind,
        before = GetBagItemCounts(),
        started = GetTime()
    }
    CastSpellByName(spellName)
end

local function CastOnSelf(spellName)
    if not spellName then return end
    -- The second argument casts on the player without changing target, so
    -- self-buffs and wards no longer fire PLAYER_TARGET_CHANGED and reset the
    -- once-per-target opener and PvP Rank 1 Frostbolt state.
    CastSpellByName(spellName, 1)
    if SpellIsTargeting() then SpellTargetUnit("player") end
end

local function IsBagItemReady(bag, slot)
    local _, _, locked = GetContainerItemInfo(bag, slot)
    local start, duration, enabled = GetContainerItemCooldown(bag, slot)
    return (not locked or locked == 0)
        and (enabled == nil or enabled ~= 0)
        and (not start or not duration
            or start == 0 or duration == 0
            or start + duration <= GetTime())
end

local function FindReadyManaGem()
    local _, gem
    for _, gem in ipairs(MANA_GEM_CONJURES) do
        local bag, slot = FindBagItemByName(gem.item)
        if bag and IsBagItemReady(bag, slot) then return bag, slot, gem.item end
    end
    return nil
end

local function FindUsableManaGem()
    if not MageCore_Config.AutoManaGems then return nil end
    local threshold = tonumber(MageCore_Config.ManaGemManaThreshold) or 500
    if UnitMana("player") > threshold then return nil end
    return FindReadyManaGem()
end

-- 1.12's GetItemInfo accepts an itemID or "item:1234" string, not a full
-- link, and its fourth return value is the required level. That level is a
-- good strength ranking for potions; the names are a fallback on the same scale.
local HEALING_ITEM_NAME_LEVELS = {
    { "major", 45 }, { "superior", 35 }, { "greater", 21 },
    { "lesser", 3 }, { "minor", 1 }
}

local function GetHealingItemStrength(link, lowerName)
    local _, _, itemString = string.find(link or "", "(item:%d+)")
    if itemString and GetItemInfo then
        local _, _, _, minLevel = GetItemInfo(itemString)
        minLevel = tonumber(minLevel)
        if minLevel and minLevel > 0 then return minLevel end
    end
    local _, entry
    for _, entry in ipairs(HEALING_ITEM_NAME_LEVELS) do
        if string.find(lowerName, entry[1], 1, true) then return entry[2] end
    end
    return 12
end

local function FindBestHealingPotion()
    local thresholdPercent = tonumber(
        MageCore_Config.HealingPotionHealthPercent) or 0
    local maximumHealth = UnitHealthMax("player")
    if thresholdPercent <= 0 or maximumHealth <= 0
        or UnitHealth("player") * 100 > maximumHealth * thresholdPercent then
        return nil
    end

    local inBattleground = IsInBattleground()
    local bestBag, bestSlot, bestStrength
    local bag, slot
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            local _, _, itemName = string.find(link or "", "%[(.-)%]")
            local lowerName = itemName and string.lower(itemName)
            local isHealingPotion = lowerName and string.find(
                lowerName, "healing potion", 1, true)
            -- Battleground-only draughts cannot be used elsewhere.
            local isHealingDraught = lowerName and inBattleground
                and string.find(lowerName, "healing draught", 1, true)
            if (isHealingPotion or isHealingDraught)
                and IsBagItemReady(bag, slot) then
                local strength = GetHealingItemStrength(link, lowerName)
                if not bestBag or strength > bestStrength then
                    bestBag, bestSlot, bestStrength = bag, slot, strength
                end
            end
        end
    end
    return bestBag, bestSlot
end

local function FindReadyDefilersTalisman()
    if not MageCore_Config.AutoDefilersTalisman then return nil end
    local maximumHealth = UnitHealthMax("player")
    local healthLost = maximumHealth - UnitHealth("player")
    local thresholdPercent = tonumber(
        MageCore_Config.DefilersTalismanHealthLostPercent) or 20
    if maximumHealth <= 0
        or healthLost * 100 < maximumHealth * thresholdPercent then
        return nil
    end
    local slot
    for slot = 13, 14 do
        local link = GetInventoryItemLink("player", slot)
        if link and string.find(link, "Defiler's Talisman", 1, true) then
            local start, duration, enabled =
                GetInventoryItemCooldown("player", slot)
            local ready = not start or not duration
                or start == 0 or duration == 0
                or start + duration <= GetTime()
            if ready and (enabled == nil or enabled ~= 0) then return slot end
        end
    end
    return nil
end

-- Loss-of-control debuffs a PvP Insignia/Medallion can break: stuns, fears,
-- horrors, polymorphs, charms and incapacitates. Slows and roots are left
-- out on purpose so the 5-minute trinket is not spent on a Frostbolt chill.
local LOSS_OF_CONTROL_DEBUFFS = {
    ["hammer of justice"] = true, ["cheap shot"] = true,
    ["kidney shot"] = true, ["bash"] = true, ["pounce"] = true,
    ["charge stun"] = true, ["intercept stun"] = true,
    ["concussion blow"] = true, ["war stomp"] = true, ["blackout"] = true,
    ["impact"] = true, ["mace stun effect"] = true, ["stun"] = true,
    ["intimidation"] = true, ["revenge stun"] = true,
    ["starfire stun"] = true, ["improved concussive shot"] = true,
    ["fear"] = true, ["psychic scream"] = true, ["howl of terror"] = true,
    ["intimidating shout"] = true, ["death coil"] = true,
    ["terrify"] = true, ["seduction"] = true, ["mind control"] = true,
    ["polymorph"] = true, ["polymorph: pig"] = true,
    ["polymorph: turtle"] = true, ["polymorph: cow"] = true,
    ["sap"] = true, ["gouge"] = true, ["blind"] = true,
    ["scatter shot"] = true, ["wyvern sting"] = true,
    ["freezing trap effect"] = true, ["repentance"] = true,
    ["hibernate"] = true
}

-- Equipped and ready PvP trinket slot while PvP Mode is on and the player is
-- under a loss-of-control effect.
local function FindPvpTrinketAction()
    if not (MageCore_Config.PvPMode and MageCore_Config.PvPTrinket) then
        return nil
    end
    local trinketSlot, slot
    for slot = 13, 14 do
        local link = GetInventoryItemLink("player", slot)
        if link and (string.find(link, "Insignia of the", 1, true)
            or string.find(link, "Medallion of the", 1, true)) then
            local start, duration, enabled =
                GetInventoryItemCooldown("player", slot)
            local ready = not start or not duration
                or start == 0 or duration == 0
                or start + duration <= GetTime()
            if ready and (enabled == nil or enabled ~= 0) then
                trinketSlot = slot
                break
            end
        end
    end
    if not trinketSlot or not spellScanTooltip.SetUnitDebuff then return nil end

    local i
    for i = 1, 16 do
        if not UnitDebuff("player", i) then break end
        spellScanTooltip:ClearLines()
        local ok = pcall(spellScanTooltip.SetUnitDebuff,
            spellScanTooltip, "player", i)
        local nameLine = ok and getglobal("MageCoreSpellScanTooltipTextLeft1")
        local debuffName = nameLine and nameLine:GetText()
        if debuffName and LOSS_OF_CONTROL_DEBUFFS[string.lower(debuffName)] then
            return trinketSlot
        end
    end
    return nil
end

local function GetDefensiveShieldAction()
    if not MageCore_Config.AutoDefensiveShield
        or not UnitAffectingCombat("player") then return nil end
    local maximumHealth = UnitHealthMax("player")
    local percent = tonumber(MageCore_Config.DefensiveShieldHealthPercent) or 40
    if maximumHealth <= 0
        or UnitHealth("player") * 100 > maximumHealth * percent then
        return nil
    end
    -- One absorb shield at a time; Ice Barrier is preferred when learned.
    if PlayerHasBuff("Ice Barrier") or PlayerHasBuff("Mana Shield") then
        return nil
    end
    local _, spellName
    for _, spellName in ipairs({ "Ice Barrier", "Mana Shield" }) do
        if GetSpellBookIndex(spellName) and IsSpellReady(spellName)
            and HasEnoughManaForSpell(spellName) then
            return spellName
        end
    end
    return nil
end

local function GetEvocationAction()
    if not MageCore_Config.AutoEvocation then return nil end
    local maximumMana = UnitManaMax("player")
    local percent = tonumber(MageCore_Config.EvocationManaPercent) or 10
    if maximumMana <= 0
        or UnitMana("player") * 100 > maximumMana * percent then
        return nil
    end
    if not GetSpellBookIndex("Evocation") or not IsSpellReady("Evocation") then
        return nil
    end
    -- A ready mana gem is cheaper than an 8-second channel.
    if MageCore_Config.AutoManaGems and FindReadyManaGem() then return nil end
    return "Evocation"
end

-- ---------------------------------------------------------------------------
-- Decisions. Every button press and every icon/tooltip/monitor preview goes
-- through the same functions, so what the button shows is what it casts.
-- An action is a small table:
--   kind  = "SPELL", "SELF", "GROUP", "SHOOT", "POTION", "ITEM",
--           "INVENTORY", "SURGE_INTERRUPT", "WAIT" or "PREVIEW"
--   spell, unit, bag, slot, tag (SPELL detail), conjureKind
-- ---------------------------------------------------------------------------
local function SpellAction(spellName, tag)
    return { kind = "SPELL", spell = spellName, tag = tag }
end

local function BuffAction(spellName, unit)
    if unit == "player" then return { kind = "SELF", spell = spellName } end
    return { kind = "GROUP", spell = spellName, unit = unit }
end

-- Shared by Rotation and the Arcane Explosion button: emergency healing,
-- PvP trinket, channel protection, mana gem and Defiler's Talisman, in that
-- order. Breaking a stun or fear comes first: nothing else can be used.
local function DecideEmergencyAndChannel(surgeIgnoresRotation)
    local trinketSlot = FindPvpTrinketAction()
    if trinketSlot then return { kind = "INVENTORY", slot = trinketSlot } end

    local bag, slot = FindBestHealingPotion()
    if bag then return { kind = "POTION", bag = bag, slot = slot } end

    -- Protect Blizzard, Evocation and every other channel, but allow a Surge
    -- proc that appears during Arcane Missiles to be consumed.
    if S.channelInProgress then
        local surge = S.channelSpellName == "Arcane Missiles"
            and GetArcaneSurgeAction(surgeIgnoresRotation, true)
        if surge then return { kind = "SURGE_INTERRUPT", spell = surge } end
        return { kind = "WAIT", spell = S.channelSpellName }
    end

    bag, slot = FindUsableManaGem()
    if bag then return { kind = "ITEM", bag = bag, slot = slot } end
    local talismanSlot = FindReadyDefilersTalisman()
    if talismanSlot then return { kind = "INVENTORY", slot = talismanSlot } end
    return nil
end

-- Auto Target. In PvP Mode with "Players only" on, cycle through nearby
-- enemies (like Tab) and stop at the first living player, skipping NPCs, pets
-- and totems. If no enemy player is found, the target is cleared.
local function AcquireEnemyTarget()
    if not MageCore_Config.AutoTargetEnemy then return end
    TargetNearestEnemy()
    if not (MageCore_Config.PvPMode and MageCore_Config.PvPTargetPlayersOnly) then
        return
    end
    local firstKey
    local i
    for i = 1, 12 do
        if not UnitExists("target") then break end
        if HasLivingEnemyTarget() and UnitIsPlayer("target") then return end
        local _, guid = UnitExists("target")
        local key = guid or GetTargetKey()
        if not firstKey then
            firstKey = key
        elseif key == firstKey then
            break -- cycled through every nearby enemy
        end
        TargetNearestEnemy()
    end
    if not (HasLivingEnemyTarget() and UnitIsPlayer("target")) then
        ClearTarget()
    end
end

local function DecideRotation(execute)
    EnsureConfig()
    local action = DecideEmergencyAndChannel(false)
    if action then return action end

    -- Evaluate both wards first: the Fire check also learns that this enemy
    -- is a Fire threat even when Counterspell wins this press.
    local frostWard = GetFrostWardAction()
    local fireWard = GetFireWardAction()
    local ward = frostWard or fireWard
    local counterspell = GetCounterspellAction()
    if counterspell then return SpellAction(counterspell, "COMBAT") end
    local shield = GetDefensiveShieldAction()
    if shield then return { kind = "SELF", spell = shield } end
    local arcaneSurge = GetArcaneSurgeAction()
    if arcaneSurge then return SpellAction(arcaneSurge, "SURGE") end
    if ward then return { kind = "SELF", spell = ward } end

    -- Amplify Magic belongs to the main rotation, in and out of combat.
    local targetedSpell, targetedUnit = GetNextTargetedMagicAction()
    if targetedSpell then return BuffAction(targetedSpell, targetedUnit) end

    if not ShouldGoDirectToPvpRotation() then
        local trackingSpell = GetFindMineralsAction()
        if trackingSpell then return SpellAction(trackingSpell, "TRACKING") end

        local gemSpell, gemItem = GetManaGemMaintenanceAction(execute)
        if gemSpell == "WAIT" then return { kind = "WAIT", spell = gemItem } end
        if gemSpell then
            local gemAction = SpellAction(gemSpell, "CONJURE_GEM")
            gemAction.item = gemItem
            return gemAction
        end

        local conjureSpell, conjureKind = GetNextConjureAction()
        if conjureSpell == "WAIT" then
            return { kind = "WAIT",
                spell = S.pendingConjure and S.pendingConjure.spell }
        end
        if conjureSpell then
            local conjureAction = SpellAction(conjureSpell, "CONJURE")
            conjureAction.conjureKind = conjureKind
            return conjureAction
        end

        if ShouldAutoBuffFromRotation() then
            local buff, unit = GetNextBuffAction()
            if buff then return BuffAction(buff, unit) end
        end
    end

    if not HasLivingEnemyTarget() then
        if execute then
            AcquireEnemyTarget()
            if not HasLivingEnemyTarget() then return nil end
        elseif not UnitAffectingCombat("player")
            and MageCore_Config.Opener ~= "None"
            and MageCore_Config.Opener ~= "Arcane Surge" then
            -- With no enemy selected, preview the opener that Rotation will
            -- use after acquiring a target instead of Rotation Slot 1.
            return { kind = "PREVIEW", spell = MageCore_Config.Opener }
        end
    end

    local pvpBurst = GetPvpBurstSpell()
    if pvpBurst then return SpellAction(pvpBurst, "COMBAT") end
    local pvpFrostbolt = GetPvpFrostboltSpell()
    if pvpFrostbolt then return SpellAction(pvpFrostbolt, "PVP") end
    local pvpExplosion = GetPvpArcaneExplosionSpell()
    if pvpExplosion then return SpellAction(pvpExplosion, "COMBAT") end
    local opener = GetOpenerSpell()
    if opener then return SpellAction(opener, "OPENER") end
    local evocation = GetEvocationAction()
    if evocation then return SpellAction(evocation, "COMBAT") end
    local combatSpell = GetNextCombatSpell()
    if combatSpell == "Shoot" then return { kind = "SHOOT", spell = "Shoot" } end
    if combatSpell then return SpellAction(combatSpell, "COMBAT") end
    if execute then return nil end

    -- Nothing is castable right now. Keep a meaningful icon: the spell that
    -- comes off cooldown first, then the opener, then the first slot.
    local preview = GetSoonestCooldownSpell()
    if not preview and MageCore_Config.Opener ~= "None"
        and MageCore_Config.Opener ~= "Arcane Surge"
        and GetSpellBookIndex(MageCore_Config.Opener) then
        preview = MageCore_Config.Opener
    end
    if not preview then
        local i
        for i = 1, 6 do
            local spellName = MageCore_Config["Rotation" .. i]
            if spellName and spellName ~= "None"
                and spellName ~= "Arcane Surge"
                and GetSpellBookIndex(spellName) then
                preview = spellName
                break
            end
        end
    end
    if preview then return { kind = "PREVIEW", spell = preview } end
    return nil
end

local function DecideArcaneExplosion()
    EnsureConfig()
    local action = DecideEmergencyAndChannel(true)
    if action then return action end
    local spellName = GetArcaneExplosionButtonAction()
    if spellName == "Arcane Surge" then return SpellAction(spellName, "SURGE") end
    if spellName then return SpellAction(spellName, "COMBAT") end
    return nil
end

local function GetDecisionTexture(action)
    if not action then return nil end
    if (action.kind == "POTION" or action.kind == "ITEM") and action.bag then
        return (GetContainerItemInfo(action.bag, action.slot))
    end
    if action.kind == "INVENTORY" and GetInventoryItemTexture then
        return GetInventoryItemTexture("player", action.slot)
    end
    return GetSpellTextureByName(action.spell)
end

local function RecordCombatAttempt(spellName, isOpener)
    S.lastCombatSpellAttempt = {
        spell = spellName,
        target = GetTargetKey(),
        time = GetTime(),
        opener = isOpener
    }
end

local function ExecuteAction(action)
    if not action then return end
    local kind = action.kind
    if kind == "POTION" then
        -- A potion cannot be used while casting. The player pressed a combat
        -- button below the emergency threshold, so cancel the cast first.
        if S.normalCastInProgress or S.channelInProgress then
            SpellStopCasting()
        end
        UseContainerItem(action.bag, action.slot, 1)
    elseif kind == "SURGE_INTERRUPT" then
        SpellStopCasting()
        S.arcaneSurgeAvailableUntil = 0
        RecordCombatAttempt(action.spell)
        CastSpellByName(action.spell)
    elseif kind == "ITEM" then
        UseContainerItem(action.bag, action.slot)
    elseif kind == "INVENTORY" then
        UseInventoryItem(action.slot)
    elseif kind == "SELF" then
        CastOnSelf(action.spell)
    elseif kind == "GROUP" then
        CastGroupBuff(action.spell, action.unit)
    elseif kind == "SHOOT" then
        -- Shoot is an auto-repeat toggle. Once the wand is firing, another
        -- press must leave it active instead of toggling it off.
        if IsConfiguredAutoRepeatActive("Shoot") then return end
        RecordCombatAttempt("Shoot")
        StartWandAttack()
    elseif kind == "SPELL" then
        local tag = action.tag
        if tag == "TRACKING" then
            CastSpellByName(action.spell)
        elseif tag == "CONJURE_GEM" then
            S.pendingManaGem = {
                time = GetTime(), item = action.item, spell = action.spell
            }
            CastSpellByName(action.spell)
        elseif tag == "CONJURE" then
            CastConjureSpell(action.spell, action.conjureKind)
        else
            if tag == "SURGE" then S.arcaneSurgeAvailableUntil = 0 end
            if tag == "OPENER" then S.openerUsedForTarget = GetTargetKey() end
            if action.spell == "Frostbolt(Rank 1)" then
                -- Consume the single Rank 1 attempt for this target now. It
                -- becomes available again only after a real target change.
                S.pvpFrostboltUsedForTarget = GetTargetKey()
                S.lastRankOneFrostbolt = GetTime()
                DEFAULT_CHAT_FRAME:AddMessage(
                    "MageCore: Using Rank 1 Frostbolt", 1, 1, 0)
            end
            RecordCombatAttempt(action.spell, tag == "OPENER")
            CastSpellByName(action.spell)
        end
    end
    -- WAIT and PREVIEW intentionally do nothing.
end

-- Returns the spell (or item) the Rotation button would use now, plus the
-- full decision for callers that need the item details or the texture.
local function GetNextAction()
    local action = DecideRotation(false)
    return action and action.spell, action
end

function MageCore_Rotate()
    ExecuteAction(DecideRotation(true))
end

function MageCore_ArcaneExplosion()
    ExecuteAction(DecideArcaneExplosion())
end

-- Dedicated "R1 Frostbolt" button: always casts Rank 1 Frostbolt on the
-- current target. It shares Rotation's bookkeeping, so Rotation will not
-- immediately repeat it.
function MageCore_SlowFrostbolt()
    EnsureConfig()
    local spellName = "Frostbolt(Rank 1)"
    if not GetSpellBookIndex(spellName) then
        UIErrorsFrame:AddMessage("Rank 1 Frostbolt is not in your spellbook.", 1, 0.1, 0.1, 1)
        return
    end
    if not HasLivingEnemyTarget() then AcquireEnemyTarget() end
    if not HasLivingEnemyTarget() then return end
    S.pvpFrostboltUsedForTarget = GetTargetKey()
    S.lastRankOneFrostbolt = GetTime()
    RecordCombatAttempt(spellName)
    CastSpellByName(spellName)
end

-- Kept as globals for macros written against earlier versions.
function MageCore_TryHealingPotion()
    EnsureConfig()
    local bag, slot = FindBestHealingPotion()
    if not bag then return false end
    ExecuteAction({ kind = "POTION", bag = bag, slot = slot })
    return true
end

function MageCore_TryManaAgate()
    EnsureConfig()
    local bag, slot = FindUsableManaGem()
    if not bag then return false end
    UseContainerItem(bag, slot)
    return true
end

function MageCore_TryDefilersTalisman()
    EnsureConfig()
    local slot = FindReadyDefilersTalisman()
    if not slot then return false end
    UseInventoryItem(slot)
    return true
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
        if not S.iceBlockGuardStartedAt then
            S.iceBlockGuardStartedAt = now
        end
        if now - S.iceBlockGuardStartedAt < 1 then return end
        CancelPlayerBuff(buffIndex)
        S.iceBlockGuardStartedAt = nil
        return
    end

    S.iceBlockGuardStartedAt = now
    CastSpellByName("Ice Block")
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
    if S.actionButtons then return S.actionButtons end
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
    if table.getn(buttons) > 0 then S.actionButtons = buttons end
    return buttons
end

-- Find the placed MageRot/MageAoE/MageIceBlock buttons once per frame instead
-- of walking every action button separately for icon, cooldown and mana.
local EMPTY_LIST = {}
local function GetMacroButtons(macroName)
    local now = GetTime()
    if not S.macroButtons or S.macroButtonsTime ~= now then
        local map = {}
        local _, button
        for _, button in ipairs(GetActionButtons()) do
            local actionSlot = ActionButton_GetPagedID(button)
            local text = actionSlot and GetActionText(actionSlot)
            if text == "MageRot" or text == "MageAoE"
                or text == "MageIceBlock" then
                map[text] = map[text] or {}
                table.insert(map[text], button)
            end
        end
        S.macroButtons = map
        S.macroButtonsTime = now
    end
    return S.macroButtons[macroName] or EMPTY_LIST
end

local function ShowRotationButtonTooltip(button)
    local spellName, action = GetNextAction()
    local spellIndex = spellName and GetSpellBookIndex(spellName)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    if action and (action.kind == "POTION" or action.kind == "ITEM") then
        GameTooltip:SetBagItem(action.bag, action.slot)
    elseif action and action.kind == "INVENTORY" then
        GameTooltip:SetInventoryItem("player", action.slot)
    elseif spellIndex then
        GameTooltip:SetSpell(spellIndex, BOOKTYPE_SPELL)
    else
        GameTooltip:AddLine("MageCore Rotation")
        if spellName then
            GameTooltip:AddLine("Next: " .. spellName, 0.8, 0.8, 0.8)
        end
    end
    GameTooltip:Show()
end

local function ShowArcaneExplosionButtonTooltip(button)
    local spellName = GetArcaneExplosionButtonAction()
    local spellIndex = spellName and GetSpellBookIndex(spellName)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    if spellIndex then
        GameTooltip:SetSpell(spellIndex, BOOKTYPE_SPELL)
    else
        GameTooltip:AddLine("MageCore Arcane Explosion")
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
        elseif actionSlot and GetActionText(actionSlot) == "MageAoE" then
            ShowArcaneExplosionButtonTooltip(this)
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
    for _, button in ipairs(GetMacroButtons("MageRot")) do
        local cooldown = GetActionButtonCooldown(button)
        if cooldown then CooldownFrame_SetTimer(cooldown, start, duration, enabled) end
    end
end

local function SetRotationIconTexture(texture)
    if S.rotationIconTexture then
        S.rotationIconTexture:SetTexture(texture)
    end

    -- Editing a macro's icon does not reliably redraw an action button on
    -- every Vanilla client/UI replacement, so update placed MageRot buttons
    -- directly as well.
    local _, button
    for _, button in ipairs(GetMacroButtons("MageRot")) do
        local icon = getglobal(button:GetName() .. "Icon")
        if icon then icon:SetTexture(texture) end
    end
end

local function UpdateIceBlockCooldown()
    local start, duration, enabled =
        GetSpellCooldownInfo("Ice Block")
    if start == nil then start, duration, enabled = 0, 0, 0 end

    local _, button
    for _, button in ipairs(GetMacroButtons("MageIceBlock")) do
        local cooldown = GetActionButtonCooldown(button)
        if cooldown then
            CooldownFrame_SetTimer(
                cooldown, start, duration, enabled)
        end
    end
end

local function UpdateArcaneExplosionCooldown(spellName)
    local start, duration, enabled = 0, 0, 0
    if spellName then
        start, duration, enabled = GetSpellCooldownInfo(spellName)
        if start == nil then start, duration, enabled = 0, 0, 0 end
    end

    local _, button
    for _, button in ipairs(GetMacroButtons("MageAoE")) do
        local cooldown = GetActionButtonCooldown(button)
        if cooldown then
            CooldownFrame_SetTimer(cooldown, start, duration, enabled)
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

    if S.rotationIconTexture then S.rotationIconTexture:SetVertexColor(red, green, blue) end
    local _, button
    for _, button in ipairs(GetMacroButtons("MageRot")) do
        local icon = getglobal(button:GetName() .. "Icon")
        if icon then icon:SetVertexColor(red, green, blue) end
    end
end

local function UpdateArcaneExplosionManaState(spellName)
    local manaCost = GetSpellManaCost(spellName)
    local insufficient = manaCost and UnitMana("player") < manaCost
    local red, green, blue = 1, 1, 1
    if insufficient then red, green, blue = 0.4, 0.4, 0.4 end

    if S.arcaneExplosionIconTexture then
        S.arcaneExplosionIconTexture:SetVertexColor(red, green, blue)
    end
    local _, button
    for _, button in ipairs(GetMacroButtons("MageAoE")) do
        local icon = getglobal(button:GetName() .. "Icon")
        if icon then icon:SetVertexColor(red, green, blue) end
    end
end

-- This remains outside the main OnUpdate closure for Vanilla Lua's 32-upvalue
-- limit. The event handler calls it as a global and captures no new locals.
function MageCore_UpdateArcaneExplosionButton()
    local spellName = GetArcaneExplosionButtonAction()
    local texture = GetSpellTextureByName(spellName)
        or ICON_PATH .. "Spell_Nature_WispSplode"
    if S.arcaneExplosionIconTexture then
        S.arcaneExplosionIconTexture:SetTexture(texture)
    end

    local macroIcon = TextureName(texture) or "Spell_Nature_WispSplode"
    if macroIcon ~= S.lastArcaneExplosionIcon then
        local index = GetMacroIndex("MageAoE", false)
        if index > 0 then
            EditMacro(
                index, "MageAoE", macroIcon,
                "/script MageCore_ArcaneExplosion()", nil, nil)
        end
        S.lastArcaneExplosionIcon = macroIcon
    end
    UpdateArcaneExplosionCooldown(spellName)
    UpdateArcaneExplosionManaState(spellName)
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

-- Keep this builder outside MageCore_CreateMenu. Vanilla Lua limits each
-- function to 32 upvalues, and that large menu function is already at the
-- client limit.
function MageCore_CreateArcaneExplosionDragButton(rotationPanel)
    local dragArcaneExplosion = CreateFrame("Button", nil, rotationPanel)
    dragArcaneExplosion:SetWidth(48)
    dragArcaneExplosion:SetHeight(48)
    dragArcaneExplosion:SetPoint("TOPLEFT", 160, -272)
    StyleButton(dragArcaneExplosion)
    S.arcaneExplosionIconTexture =
        dragArcaneExplosion:CreateTexture(nil, "OVERLAY")
    S.arcaneExplosionIconTexture:SetPoint("TOPLEFT", 4, -4)
    S.arcaneExplosionIconTexture:SetPoint("BOTTOMRIGHT", -4, 4)
    S.arcaneExplosionIconTexture:SetTexture(
        GetSpellTextureByName(GetArcaneExplosionButtonAction())
            or ICON_PATH .. "Spell_Nature_WispSplode")
    dragArcaneExplosion:RegisterForDrag("LeftButton")
    dragArcaneExplosion:SetScript("OnDragStart", function()
        local index = CreateOrUpdateMacro(
            "MageAoE", "/script MageCore_ArcaneExplosion()",
            GetArcaneExplosionButtonAction())
        if index and index > 0 then PickupMacro(index) end
    end)
    dragArcaneExplosion:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Arcane Explosion / Surge")
        GameTooltip:AddLine(
            "Casts Arcane Explosion normally.", 0.8, 0.8, 0.8)
        GameTooltip:AddLine(
            "When Arcane Surge procs, this same button casts Surge instead.",
            0.8, 0.8, 0.8, 1, true)
        GameTooltip:AddLine(
            "Drag onto an action bar.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    dragArcaneExplosion:SetScript(
        "OnLeave", function() GameTooltip:Hide() end)
    local arcaneExplosionLabel = rotationPanel:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    arcaneExplosionLabel:SetPoint(
        "BOTTOM", dragArcaneExplosion, "TOP", 0, 2)
    arcaneExplosionLabel:SetText("Arcane Explosion")
end

-- Menu builders live in one table to stay under Vanilla Lua's limit of 200
-- locals in the main chunk.
local UI = {}

-- ---------------------------------------------------------------------------
-- Shared placement for movable bars. Positions are stored as the bar's centre
-- in UIParent units, so changing a bar's scale keeps it where it was.
-- ---------------------------------------------------------------------------
local BARS = {}

function BARS.Scale(prefix)
    local percent = tonumber(MageCore_Config[prefix .. "Scale"]) or 100
    return math.max(50, math.min(200, percent)) / 100
end

function BARS.Apply(frame, prefix, defaultY)
    if not frame then return end
    local scale = BARS.Scale(prefix)
    frame:SetScale(scale)
    local relative = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    if relative <= 0 then relative = 1 end
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER",
        (MageCore_Config[prefix .. "X"] or 0) / relative,
        (MageCore_Config[prefix .. "Y"] or defaultY) / relative)
end

function BARS.Save(frame, prefix)
    local x, y = frame:GetCenter()
    local parentX, parentY = UIParent:GetCenter()
    if not (x and y and parentX and parentY) then return end
    local relative = frame:GetEffectiveScale() / UIParent:GetEffectiveScale()
    MageCore_Config[prefix .. "X"] = x * relative - parentX
    MageCore_Config[prefix .. "Y"] = y * relative - parentY
end

function BARS.MakeMovable(frame, prefix, lockKey)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function()
        if not MageCore_Config[lockKey] then this:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        BARS.Save(this, prefix)
    end)
end

-- ---------------------------------------------------------------------------
-- Player cast bar. Gold while casting, green while channeling, a short
-- flash on success and red on interrupt. While unlocked it stays visible as
-- a preview so it can be dragged into place.
-- ---------------------------------------------------------------------------
local CB = {}
local CAST_BAR_EVENTS = {
    "SPELLCAST_START", "SPELLCAST_STOP", "SPELLCAST_FAILED",
    "SPELLCAST_INTERRUPTED", "SPELLCAST_DELAYED",
    "SPELLCAST_CHANNEL_START", "SPELLCAST_CHANNEL_UPDATE",
    "SPELLCAST_CHANNEL_STOP"
}

-- The default bar is switched off while MageCore's bar is enabled and given
-- back its events when it is disabled again.
function CB.SetBlizzardBarEnabled(enabled)
    if not CastingBarFrame then return end
    local _, eventName
    if enabled then
        if not S.blizzardCastBarDisabled then return end
        for _, eventName in ipairs(CAST_BAR_EVENTS) do
            CastingBarFrame:RegisterEvent(eventName)
        end
        S.blizzardCastBarDisabled = nil
    else
        for _, eventName in ipairs(CAST_BAR_EVENTS) do
            CastingBarFrame:UnregisterEvent(eventName)
        end
        CastingBarFrame:Hide()
        S.blizzardCastBarDisabled = true
    end
end

function CB.ShowState()
    local frame = S.castBarFrame
    local cast = S.castState
    if cast then
        frame:SetAlpha(1)
        frame:Show()
        return
    end
    if not MageCore_Config.CastBarLocked then
        -- Unlocked preview for positioning.
        frame.bar:SetMinMaxValues(0, 1)
        frame.bar:SetValue(0.6)
        frame.bar:SetStatusBarColor(1, 0.7, 0)
        frame.icon:SetTexture(ICON_PATH .. DEFAULT_ICON)
        frame.name:SetText("MageCore cast bar - drag to move")
        frame.time:SetText("")
        frame.spark:Hide()
        frame:SetAlpha(1)
        frame:Show()
    else
        frame:Hide()
    end
end

function CB.Start(spellName, seconds, channel)
    local frame = S.castBarFrame
    if not frame or not MageCore_Config.CastBarShown then return end
    local now = GetTime()
    S.castState = {
        name = spellName or "",
        startTime = now,
        endTime = now + math.max(0.1, seconds or 0),
        channel = channel
    }
    frame.bar:SetMinMaxValues(0, math.max(0.1, seconds or 0))
    frame.bar:SetStatusBarColor(channel and 0.2 or 1, channel and 0.9 or 0.7,
        channel and 0.3 or 0)
    frame.icon:SetTexture(GetSpellTextureByName(spellName)
        or ICON_PATH .. "INV_Misc_QuestionMark")
    frame.name:SetText(spellName or "")
    frame.spark:Show()
    CB.ShowState()
end

function CB.Finish(success, label)
    local frame = S.castBarFrame
    local cast = S.castState
    if not frame or not cast or cast.fading then return end
    cast.fading = GetTime()
    frame.spark:Hide()
    if success then
        local _, maximum = frame.bar:GetMinMaxValues()
        frame.bar:SetValue(cast.channel and 0 or maximum)
        if not cast.channel then frame.bar:SetStatusBarColor(0.2, 1, 0.2) end
        frame.time:SetText("")
    else
        frame.bar:SetStatusBarColor(1, 0.15, 0.15)
        frame.name:SetText(label or "Interrupted")
        frame.time:SetText("")
    end
end

function CB.OnUpdate()
    local frame = S.castBarFrame
    local cast = S.castState
    if not cast then return end
    local now = GetTime()
    if cast.fading then
        local alpha = 1 - (now - cast.fading) / 0.5
        if alpha <= 0 then
            S.castState = nil
            CB.ShowState()
        else
            frame:SetAlpha(alpha)
        end
        return
    end
    local duration = cast.endTime - cast.startTime
    local value
    if cast.channel then
        value = math.max(0, cast.endTime - now)
    else
        value = math.min(duration, now - cast.startTime)
    end
    frame.bar:SetValue(value)
    frame.time:SetText(string.format("%.1f", math.max(0, cast.endTime - now)))
    local width = frame.bar:GetWidth() or 0
    if duration > 0 then
        frame.spark:SetPoint("CENTER", frame.bar, "LEFT",
            width * value / duration, 0)
    end
    -- Safety net in case a stop event is missed.
    if now > cast.endTime + 0.5 then CB.Finish(true) end
end

function CB.OnEvent()
    if not MageCore_Config or not MageCore_Config.CastBarShown then return end
    local cast = S.castState
    if event == "SPELLCAST_START" then
        CB.Start(arg1, (tonumber(arg2) or 0) / 1000, false)
    elseif event == "SPELLCAST_CHANNEL_START" then
        CB.Start(arg2 or (cast and cast.name), (tonumber(arg1) or 0) / 1000, true)
    elseif event == "SPELLCAST_DELAYED" then
        if cast and not cast.channel and not cast.fading then
            local delay = (tonumber(arg1) or 0) / 1000
            cast.startTime = cast.startTime + delay
            cast.endTime = cast.endTime + delay
        end
    elseif event == "SPELLCAST_CHANNEL_UPDATE" then
        if cast and cast.channel and not cast.fading then
            local remaining = (tonumber(arg1) or 0) / 1000
            if remaining <= 0 then
                CB.Finish(true)
            else
                cast.endTime = GetTime() + remaining
            end
        end
    elseif event == "SPELLCAST_STOP" then
        -- A stop during a channel belongs to the channel's own start.
        if cast and not cast.channel then CB.Finish(true) end
    elseif event == "SPELLCAST_CHANNEL_STOP" then
        if cast and cast.channel then CB.Finish(true) end
    elseif event == "SPELLCAST_INTERRUPTED" then
        if cast then CB.Finish(false, "Interrupted") end
    elseif event == "SPELLCAST_FAILED" then
        if cast then CB.Finish(false, "Failed") end
    end
end

function CB.Create()
    if S.castBarFrame then return end
    local frame = CreateFrame("Frame", "MageCoreCastBar", UIParent)
    S.castBarFrame = frame
    frame:SetWidth(240)
    frame:SetHeight(20)
    frame:SetFrameStrata("HIGH")
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = false, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    frame:SetBackdropColor(0, 0, 0, 0.6)
    frame:SetBackdropBorderColor(0, 0, 0, 1)
    BARS.MakeMovable(frame, "CastBar", "CastBarLocked")

    frame.icon = frame:CreateTexture(nil, "ARTWORK")
    frame.icon:SetWidth(20)
    frame.icon:SetHeight(20)
    frame.icon:SetPoint("RIGHT", frame, "LEFT", -2, 0)
    frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    frame.bar = CreateFrame("StatusBar", nil, frame)
    frame.bar:SetPoint("TOPLEFT", 1, -1)
    frame.bar:SetPoint("BOTTOMRIGHT", -1, 1)
    frame.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")

    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    overlay:SetFrameLevel(frame.bar:GetFrameLevel() + 1)
    frame.spark = overlay:CreateTexture(nil, "OVERLAY")
    frame.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    frame.spark:SetBlendMode("ADD")
    frame.spark:SetWidth(20)
    frame.spark:SetHeight(36)
    frame.name = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.name:SetPoint("LEFT", 5, 0)
    frame.time = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.time:SetPoint("RIGHT", -5, 0)

    local _, eventName
    for _, eventName in ipairs(CAST_BAR_EVENTS) do
        frame:RegisterEvent(eventName)
    end
    frame:SetScript("OnEvent", CB.OnEvent)
    frame:SetScript("OnUpdate", CB.OnUpdate)
    frame:Hide()
end

function CB.ApplyConfig()
    if not MageCore_Config.CastBarShown then
        S.castState = nil
        if S.castBarFrame then S.castBarFrame:Hide() end
        CB.SetBlizzardBarEnabled(true)
        return
    end
    CB.Create()
    CB.SetBlizzardBarEnabled(false)
    BARS.Apply(S.castBarFrame, "CastBar", -150)
    CB.ShowState()
end

function CB.Command(argument)
    EnsureConfig()
    local message
    if argument == "" then
        MageCore_Config.CastBarShown = not MageCore_Config.CastBarShown
    elseif argument == "on" then
        MageCore_Config.CastBarShown = true
    elseif argument == "off" then
        MageCore_Config.CastBarShown = false
    elseif argument == "lock" then
        MageCore_Config.CastBarLocked = true
        message = "Cast bar locked."
    elseif argument == "unlock" then
        MageCore_Config.CastBarLocked = false
        message = "Cast bar unlocked. Drag it to move it."
    elseif argument == "reset" then
        MageCore_Config.CastBarX = 0
        MageCore_Config.CastBarY = -150
        MageCore_Config.CastBarScale = 100
        message = "Cast bar position and size reset."
    else
        message = "Use |cffffffff/mc cast on|r, |cffffffffoff|r, |cfffffffflock|r, |cffffffffunlock|r or |cffffffffreset|r."
    end
    CB.ApplyConfig()
    if UI.RefreshMenuControls then UI.RefreshMenuControls() end
    message = message or ("Cast bar " .. (MageCore_Config.CastBarShown
        and "|cff00ff00shown|r" or "|cffff4444hidden|r") .. ".")
    DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "[MageCore]|r " .. message)
end

-- ---------------------------------------------------------------------------
-- Target cast bar and no-slow alert, moved together as one frame. The bar
-- shows what the current target is casting; the alert above it names a buff
-- that makes the target immune to slows and roots. SuperWoW's UNIT_CASTEVENT
-- gives exact casts per GUID; without it the UnitCastingInfo providers used
-- for Counterspell are asked instead.
-- ---------------------------------------------------------------------------
local TGT = { casts = {}, pruneTime = 0 }

function TGT.OnCastEvent()
    -- arg1 caster GUID, arg3 START/CHANNEL/CAST/FAIL, arg4 spell id, arg5 ms.
    local guid, kind = arg1, arg3
    if not guid then return end
    local now = GetTime()
    if kind == "START" or kind == "CHANNEL" then
        local name, texture
        if SpellInfo then
            local ok, spellName, _, spellTexture = pcall(SpellInfo, arg4)
            if ok then name, texture = spellName, spellTexture end
        end
        TGT.casts[guid] = {
            name = name or "", texture = texture,
            startTime = now,
            endTime = now + math.max(0.1, (tonumber(arg5) or 0) / 1000),
            channel = kind == "CHANNEL"
        }
    elseif kind == "CAST" or kind == "FAIL" then
        local cast = TGT.casts[guid]
        -- A channel can report CAST once it starts ticking; keep it running.
        if cast and not cast.finished
            and not (cast.channel and kind == "CAST") then
            cast.finished = kind
            cast.finishTime = now
        end
    end
    if now > TGT.pruneTime then
        TGT.pruneTime = now + 10
        local key, cast
        for key, cast in pairs(TGT.casts) do
            if now > cast.endTime + 2 then TGT.casts[key] = nil end
        end
    end
end

function TGT.QueryProviders()
    local providers = {}
    if UnitCastingInfo then
        table.insert(providers, { UnitCastingInfo, false })
    end
    if ShaguTweaks and ShaguTweaks.UnitCastingInfo
        and ShaguTweaks.UnitCastingInfo ~= UnitCastingInfo then
        table.insert(providers, { ShaguTweaks.UnitCastingInfo, false })
    end
    if UnitChannelInfo then
        table.insert(providers, { UnitChannelInfo, true })
    end
    if ShaguTweaks and ShaguTweaks.UnitChannelInfo
        and ShaguTweaks.UnitChannelInfo ~= UnitChannelInfo then
        table.insert(providers, { ShaguTweaks.UnitChannelInfo, true })
    end
    local _, entry
    for _, entry in ipairs(providers) do
        local ok, name, _, _, texture, startMs, endMs = pcall(entry[1], "target")
        if ok and name and tonumber(startMs) and tonumber(endMs) then
            return {
                name = name, texture = texture,
                startTime = startMs / 1000, endTime = endMs / 1000,
                channel = entry[2]
            }
        end
    end
    return nil
end

function TGT.GetTargetCast()
    if not UnitExists("target") or UnitIsDeadOrGhost("target") then
        return nil
    end
    local _, guid = UnitExists("target")
    local cast = guid and TGT.casts[guid]
    if cast then
        local now = GetTime()
        if cast.finished then
            if now - cast.finishTime < 0.5 then return cast end
        elseif now <= cast.endTime + 0.2 then
            return cast
        end
    end
    return TGT.QueryProviders()
end

function TGT.UpdateCastBar(unlocked)
    local box = S.targetBarFrame.cast
    local cast = MageCore_Config.TargetCastBarShown and TGT.GetTargetCast()
    if not cast then
        if MageCore_Config.TargetCastBarShown and unlocked then
            box.bar:SetMinMaxValues(0, 1)
            box.bar:SetValue(0.6)
            box.bar:SetStatusBarColor(1, 0.7, 0)
            box.icon:SetTexture(ICON_PATH .. "Spell_Holy_FlashHeal")
            box.name:SetText("Target cast bar - drag to move")
            box.time:SetText("")
            box.spark:Hide()
            box:SetAlpha(1)
            box:Show()
        else
            box:Hide()
        end
        return
    end

    local now = GetTime()
    local duration = math.max(0.1, cast.endTime - cast.startTime)
    box.bar:SetMinMaxValues(0, duration)
    box.icon:SetTexture(cast.texture or GetSpellTextureByName(cast.name)
        or ICON_PATH .. "INV_Misc_QuestionMark")
    box:SetAlpha(1)
    if cast.finished then
        box.spark:Hide()
        box.time:SetText("")
        if cast.finished == "FAIL" then
            box.bar:SetStatusBarColor(1, 0.15, 0.15)
            box.name:SetText("Interrupted")
        else
            box.bar:SetValue(duration)
            box.bar:SetStatusBarColor(0.2, 1, 0.2)
            box.name:SetText(cast.name)
        end
        box:SetAlpha(math.max(0, 1 - (now - cast.finishTime) / 0.5))
        box:Show()
        return
    end
    local value
    if cast.channel then
        value = math.max(0, cast.endTime - now)
        box.bar:SetStatusBarColor(0.2, 0.9, 0.3)
    else
        value = math.min(duration, math.max(0, now - cast.startTime))
        box.bar:SetStatusBarColor(1, 0.7, 0)
    end
    box.bar:SetValue(value)
    box.name:SetText(cast.name)
    box.time:SetText(string.format("%.1f", math.max(0, cast.endTime - now)))
    box.spark:SetPoint("CENTER", box.bar, "LEFT",
        (box.bar:GetWidth() or 0) * value / duration, 0)
    box.spark:Show()
    box:Show()
end

function TGT.UpdateAlert(unlocked)
    local alert = S.targetBarFrame.alert
    if not MageCore_Config.NoSlowAlert then
        alert:Hide()
        return
    end
    local name, texture, kind = GetTargetSlowImmunity()
    if not name and unlocked then
        name, texture, kind = "Blessing of Freedom",
            ICON_PATH .. "Spell_Holy_SealOfValor", "FREEDOM"
    end
    if not name then
        alert:Hide()
        return
    end
    alert.icon:SetTexture(texture or ICON_PATH .. "INV_Misc_QuestionMark")
    if kind == "IMMUNE" then
        alert.text:SetText("|cffff4444IMMUNE|r  " .. name)
    else
        alert.text:SetText("|cffff4444NO SLOW|r  " .. name)
    end
    alert:Show()
end

function TGT.OnUpdate()
    local unlocked = not MageCore_Config.TargetCastBarLocked
    TGT.UpdateCastBar(unlocked)
    -- Aura lists are cached, but there is no need to look every frame.
    local now = GetTime()
    if now >= (TGT.nextAlertCheck or 0) then
        TGT.nextAlertCheck = now + 0.1
        TGT.UpdateAlert(unlocked)
    end
end

function TGT.Create()
    if S.targetBarFrame then return end
    local frame = CreateFrame("Frame", "MageCoreTargetCastBar", UIParent)
    S.targetBarFrame = frame
    frame:SetWidth(260)
    frame:SetHeight(22)
    frame:SetFrameStrata("HIGH")
    BARS.MakeMovable(frame, "TargetCastBar", "TargetCastBarLocked")

    local box = CreateFrame("Frame", nil, frame)
    frame.cast = box
    box:SetAllPoints(frame)
    box:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = false, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    box:SetBackdropColor(0, 0, 0, 0.6)
    box:SetBackdropBorderColor(0, 0, 0, 1)
    box.icon = box:CreateTexture(nil, "ARTWORK")
    box.icon:SetWidth(22)
    box.icon:SetHeight(22)
    box.icon:SetPoint("RIGHT", box, "LEFT", -2, 0)
    box.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    box.bar = CreateFrame("StatusBar", nil, box)
    box.bar:SetPoint("TOPLEFT", 1, -1)
    box.bar:SetPoint("BOTTOMRIGHT", -1, 1)
    box.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    local overlay = CreateFrame("Frame", nil, box)
    overlay:SetAllPoints(box)
    overlay:SetFrameLevel(box.bar:GetFrameLevel() + 1)
    box.spark = overlay:CreateTexture(nil, "OVERLAY")
    box.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    box.spark:SetBlendMode("ADD")
    box.spark:SetWidth(20)
    box.spark:SetHeight(38)
    box.name = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    box.name:SetPoint("LEFT", 5, 0)
    box.time = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    box.time:SetPoint("RIGHT", -5, 0)

    local alert = CreateFrame("Frame", nil, frame)
    frame.alert = alert
    alert:SetWidth(260)
    alert:SetHeight(24)
    alert:SetPoint("BOTTOM", frame, "TOP", 0, 4)
    alert.icon = alert:CreateTexture(nil, "ARTWORK")
    alert.icon:SetWidth(24)
    alert.icon:SetHeight(24)
    alert.icon:SetPoint("LEFT", 0, 0)
    alert.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    alert.text = alert:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    alert.text:SetPoint("LEFT", alert.icon, "RIGHT", 6, 0)

    -- SuperWoW only; a plain client has no such event.
    pcall(frame.RegisterEvent, frame, "UNIT_CASTEVENT")
    frame:SetScript("OnEvent", TGT.OnCastEvent)
    frame:SetScript("OnUpdate", TGT.OnUpdate)
    frame:Hide()
end

function TGT.ApplyConfig()
    local enabled = MageCore_Config.TargetCastBarShown
        or MageCore_Config.NoSlowAlert
    if not enabled then
        if S.targetBarFrame then S.targetBarFrame:Hide() end
        return
    end
    TGT.Create()
    BARS.Apply(S.targetBarFrame, "TargetCastBar", -100)
    -- The frame stays shown for its OnUpdate; it only catches the mouse
    -- while unlocked so a locked, empty bar never blocks clicks.
    S.targetBarFrame:EnableMouse(not MageCore_Config.TargetCastBarLocked)
    S.targetBarFrame:Show()
    TGT.OnUpdate()
end

function TGT.Command(argument)
    EnsureConfig()
    local message
    if argument == "" then
        MageCore_Config.TargetCastBarShown = not MageCore_Config.TargetCastBarShown
    elseif argument == "on" then
        MageCore_Config.TargetCastBarShown = true
    elseif argument == "off" then
        MageCore_Config.TargetCastBarShown = false
    elseif argument == "lock" then
        MageCore_Config.TargetCastBarLocked = true
        message = "Target cast bar locked."
    elseif argument == "unlock" then
        MageCore_Config.TargetCastBarLocked = false
        message = "Target cast bar unlocked. Drag it to move it."
    elseif argument == "reset" then
        MageCore_Config.TargetCastBarX = 0
        MageCore_Config.TargetCastBarY = -100
        MageCore_Config.TargetCastBarScale = 100
        message = "Target cast bar position and size reset."
    else
        message = "Use |cffffffff/mc tcast on|r, |cffffffffoff|r, |cfffffffflock|r, |cffffffffunlock|r or |cffffffffreset|r."
    end
    TGT.ApplyConfig()
    if UI.RefreshMenuControls then UI.RefreshMenuControls() end
    message = message or ("Target cast bar " .. (MageCore_Config.TargetCastBarShown
        and "|cff00ff00shown|r" or "|cffff4444hidden|r") .. ".")
    DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "[MageCore]|r " .. message)
end

-- ---------------------------------------------------------------------------
-- Movable XP bar. Purple while rested XP is available, blue otherwise; the
-- lighter overlay shows how far the rested bonus reaches. Hidden at max level.
-- ---------------------------------------------------------------------------
local XP = {}
local XP_BAR_WIDTH = 400
local XP_BAR_HEIGHT = 14

function XP.IsMaxLevel()
    local maximum = UnitXPMax("player") or 0
    return maximum <= 0 or (UnitLevel("player") or 0) >= 60
end

function XP.Update()
    local frame = S.xpBarFrame
    if not frame or not frame:IsShown() then return end
    local current = UnitXP("player") or 0
    local maximum = UnitXPMax("player") or 0
    if maximum <= 0 then maximum = 1 end
    local rested = GetXPExhaustion() or 0
    frame.bar:SetMinMaxValues(0, maximum)
    frame.bar:SetValue(current)
    frame.rested:SetMinMaxValues(0, maximum)
    frame.rested:SetValue(math.min(maximum, current + rested))
    if rested > 0 then
        frame.bar:SetStatusBarColor(0.58, 0.0, 0.55)
        frame.rested:SetStatusBarColor(0.25, 0.25, 1.0, 0.6)
    else
        frame.bar:SetStatusBarColor(0.0, 0.39, 0.88)
        frame.rested:SetStatusBarColor(0, 0, 0, 0)
    end
    local text = "Level " .. (UnitLevel("player") or 0) .. "   "
        .. current .. " / " .. maximum
        .. " (" .. math.floor(100 * current / maximum) .. "%)"
    if rested > 0 then
        text = text .. "   Rested " .. math.floor(100 * rested / maximum) .. "%"
    end
    frame.text:SetText(text)
end

function XP.SavePosition()
    BARS.Save(S.xpBarFrame, "XPBar")
end

function XP.ApplyPosition()
    BARS.Apply(S.xpBarFrame, "XPBar", -200)
end

function XP.Create()
    if S.xpBarFrame then return end
    local frame = CreateFrame("Frame", "MageCoreXPBar", UIParent)
    S.xpBarFrame = frame
    frame:SetWidth(XP_BAR_WIDTH)
    frame:SetHeight(XP_BAR_HEIGHT)
    frame:SetFrameStrata("MEDIUM")
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = false, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    frame:SetBackdropColor(0, 0, 0, 0.6)
    frame:SetBackdropBorderColor(0, 0, 0, 1)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function()
        if not MageCore_Config.XPBarLocked then this:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function()
        this:StopMovingOrSizing()
        XP.SavePosition()
    end)

    frame.rested = CreateFrame("StatusBar", nil, frame)
    frame.rested:SetPoint("TOPLEFT", 1, -1)
    frame.rested:SetPoint("BOTTOMRIGHT", -1, 1)
    frame.rested:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")

    frame.bar = CreateFrame("StatusBar", nil, frame)
    frame.bar:SetPoint("TOPLEFT", 1, -1)
    frame.bar:SetPoint("BOTTOMRIGHT", -1, 1)
    frame.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    frame.bar:SetFrameLevel(frame.rested:GetFrameLevel() + 1)

    -- The text sits on its own frame above both bars.
    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    overlay:SetFrameLevel(frame.bar:GetFrameLevel() + 1)
    frame.text = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.text:SetPoint("CENTER", 0, 0)

    frame:SetScript("OnEnter", function()
        local current = UnitXP("player") or 0
        local maximum = UnitXPMax("player") or 0
        local rested = GetXPExhaustion() or 0
        GameTooltip:SetOwner(this, "ANCHOR_TOP")
        GameTooltip:AddLine(ACCENT .. "Experience|r")
        GameTooltip:AddLine("Current: " .. current .. " / " .. maximum, 1, 1, 1)
        GameTooltip:AddLine("To level: " .. math.max(0, maximum - current), 1, 1, 1)
        GameTooltip:AddLine("Rested: " .. rested, 0.5, 0.5, 1)
        GameTooltip:AddLine(MageCore_Config.XPBarLocked
            and "Locked (/mc xp unlock)" or "Drag to move (/mc xp lock)",
            0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)

    frame:RegisterEvent("PLAYER_XP_UPDATE")
    frame:RegisterEvent("UPDATE_EXHAUSTION")
    frame:RegisterEvent("PLAYER_LEVEL_UP")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:SetScript("OnEvent", function()
        if event == "PLAYER_LEVEL_UP" and (tonumber(arg1) or 0) >= 60 then
            -- UnitLevel can still report the old level during this event.
            this:Hide()
        elseif event == "PLAYER_LEVEL_UP" or event == "PLAYER_ENTERING_WORLD" then
            XP.ApplyConfig()
        else
            XP.Update()
        end
    end)
    XP.ApplyPosition()
    frame:Hide()
end

-- Show or hide the bar to match the saved settings.
function XP.ApplyConfig()
    if not MageCore_Config.XPBarShown then
        if S.xpBarFrame then S.xpBarFrame:Hide() end
        return
    end
    XP.Create()
    XP.ApplyPosition()
    if XP.IsMaxLevel() then
        S.xpBarFrame:Hide()
    else
        S.xpBarFrame:Show()
        XP.Update()
    end
end

function XP.Command(argument)
    EnsureConfig()
    local message
    if argument == "" then
        MageCore_Config.XPBarShown = not MageCore_Config.XPBarShown
    elseif argument == "on" then
        MageCore_Config.XPBarShown = true
    elseif argument == "off" then
        MageCore_Config.XPBarShown = false
    elseif argument == "lock" then
        MageCore_Config.XPBarLocked = true
        message = "XP bar locked."
    elseif argument == "unlock" then
        MageCore_Config.XPBarLocked = false
        message = "XP bar unlocked. Drag it to move it."
    elseif argument == "reset" then
        MageCore_Config.XPBarX = 0
        MageCore_Config.XPBarY = -200
        MageCore_Config.XPBarScale = 100
        message = "XP bar position and size reset."
    else
        message = "Use |cffffffff/mc xp on|r, |cffffffffoff|r, |cfffffffflock|r, |cffffffffunlock|r or |cffffffffreset|r."
    end
    XP.ApplyConfig()
    if UI.RefreshMenuControls then UI.RefreshMenuControls() end
    if not message then
        message = "XP bar " .. (MageCore_Config.XPBarShown
            and "|cff00ff00shown|r" or "|cffff4444hidden|r") .. "."
        if MageCore_Config.XPBarShown and XP.IsMaxLevel() then
            message = message .. " It stays hidden at max level."
        end
    end
    DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "[MageCore]|r " .. message)
end


-- Every control registers a refresher, so /mc reset and profile loads can
-- update an already-open window without a /reload.
function UI.RefreshMenuControls()
    local _, refresh
    for _, refresh in ipairs(S.menuRefreshers) do refresh() end
end

function UI.AddSimpleTooltip(frame, title, text)
    if not title then return end
    frame:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title)
        if text then GameTooltip:AddLine(text, 0.8, 0.8, 0.8, 1, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function UI.MakeToggleButton(parent, width, x, y, label, key,
                                tooltipTitle, tooltipText, onChange)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(width)
    button:SetHeight(32)
    button:SetPoint("TOPLEFT", x, y)
    StyleButton(button)
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("CENTER", 0, 0)
    local function Refresh()
        text:SetText(label .. ": " .. (MageCore_Config[key]
            and "|cff00ff00ON|r" or "|cffff4444OFF|r"))
    end
    Refresh()
    table.insert(S.menuRefreshers, Refresh)
    button:SetScript("OnClick", function()
        MageCore_Config[key] = not MageCore_Config[key]
        Refresh()
        if onChange then onChange() end
    end)
    UI.AddSimpleTooltip(button, tooltipTitle, tooltipText)
    return button
end

function UI.MakeCheckBox(parent, name, x, y, label, key,
                            onChange, tooltipTitle, tooltipText)
    local check = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
    check:SetWidth(24)
    check:SetHeight(24)
    check:SetPoint("TOPLEFT", x, y)
    local function Refresh()
        check:SetChecked(MageCore_Config[key] and 1 or nil)
    end
    Refresh()
    table.insert(S.menuRefreshers, Refresh)
    check:SetScript("OnClick", function()
        MageCore_Config[key] = this:GetChecked() and true or false
        if onChange then onChange() end
    end)
    UI.AddSimpleTooltip(check, tooltipTitle, tooltipText)
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", check, "RIGHT", 4, 0)
    text:SetText(ACCENT .. label .. "|r")
    return check
end

function UI.MakeNumberBox(parent, name, x, y, width, label, key,
                             minimum, maximum, default, onSave)
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("TOPLEFT", x, y)
    text:SetText(ACCENT .. label .. "|r")
    local box = CreateFrame("EditBox", name, parent)
    box:SetWidth(width)
    box:SetHeight(28)
    box:SetPoint("TOPLEFT", x, y - 17)
    box:SetNumeric(true)
    box:SetMaxLetters(string.len(tostring(maximum)))
    box:SetAutoFocus(false)
    box:SetFontObject("GameFontHighlightSmall")
    box:SetTextInsets(8, 8, 0, 0)
    StyleButton(box)
    local function Refresh()
        box:SetText(tonumber(MageCore_Config[key]) or default)
    end
    local function Save()
        local value = tonumber(box:GetText()) or default
        value = math.max(minimum, math.min(maximum, math.floor(value)))
        MageCore_Config[key] = value
        if onSave then onSave(value) end
        Refresh()
    end
    Refresh()
    table.insert(S.menuRefreshers, Refresh)
    box:SetScript("OnEnterPressed", function() Save(); this:ClearFocus() end)
    box:SetScript("OnEditFocusLost", Save)
    box:SetScript("OnEscapePressed", function() this:ClearFocus() end)
    return box
end

function UI.MakeSlider(parent, name, x, y, minimum, maximum, step,
                          key, default, lowText, highText, FormatText)
    local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
    slider:SetWidth(250)
    slider:SetHeight(16)
    slider:SetPoint("TOPLEFT", x, y)
    slider:SetMinMaxValues(minimum, maximum)
    slider:SetValueStep(step)
    local label = getglobal(name .. "Text")
    local low = getglobal(name .. "Low")
    local high = getglobal(name .. "High")
    if low then low:SetText(lowText) end
    if high then high:SetText(highText) end
    slider:SetScript("OnValueChanged", function()
        local value = math.floor(this:GetValue() + 0.5)
        MageCore_Config[key] = value
        if label then label:SetText(FormatText(value)) end
    end)
    local function Refresh()
        local value = tonumber(MageCore_Config[key]) or default
        value = math.max(minimum, math.min(maximum, value))
        MageCore_Config[key] = value
        slider:SetValue(value)
        if label then label:SetText(FormatText(value)) end
    end
    Refresh()
    table.insert(S.menuRefreshers, Refresh)
    return slider
end

-- Kept outside MageCore_CreateMenu so each builder stays well below Vanilla
-- Lua's 32-upvalue limit.
function MageCore_CreateManaGemControls(consumablePanel)
    UI.MakeToggleButton(consumablePanel, 190, 18, -105, "Mana Gems",
        "AutoManaGems", "Mana Gems",
        "Out of combat, Rotation conjures every learned mana gem that is missing (Ruby, Citrine, Jade, Agate). Both combat buttons use the strongest ready gem at or below the configured mana value.",
        function() S.pendingManaGem = nil end)
    UI.MakeNumberBox(consumablePanel, "MageCoreManaGemManaThreshold",
        230, -99, 75, "Use at mana:", "ManaGemManaThreshold", 0, 9999, 500)
end

function MageCore_CreateDefilersTalismanButton(consumablePanel)
    UI.MakeToggleButton(consumablePanel, 190, 18, -160, "Defiler's Talisman",
        "AutoDefilersTalisman", "Defiler's Talisman",
        "Rotation uses the equipped trinket after you have lost the selected percentage of your maximum health. It must be equipped in either trinket slot and off cooldown.")

    UI.MakeSlider(consumablePanel, "MageCoreDefilersHealthSlider", 28, -225,
        5, 95, 5, "DefilersTalismanHealthLostPercent", 20, "5%", "95%",
        function(value) return "Use after " .. value .. "% health lost" end)

    local potionSlider = UI.MakeSlider(consumablePanel,
        "MageCoreHealingPotionSlider", 28, -305, 0, 60, 5,
        "HealingPotionHealthPercent", 0, "Off", "60%",
        function(value)
            if value <= 0 then return "Healing potion/draught: OFF" end
            return "Rotation press: use at " .. value .. "% health"
        end)
    UI.AddSimpleTooltip(potionSlider, "Healing Potion / Draught",
        "A Rotation or Arcane Explosion button press uses the strongest ready Healing Potion or Healing Draught in your bags at or below the selected health percentage. Battleground-only draughts are used only inside an active battleground. Set the slider to Off to disable automatic potion use.")
end

function MageCore_CreateSpellDrop(parent, label, key, x, y, listKind)
    local labelText = parent:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    labelText:SetPoint("TOPLEFT", x + 15, y)
    labelText:SetText(ACCENT .. label .. "|r")

    local dropdown = CreateFrame(
        "Frame", "MC_Drop_" .. key, parent, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", x, y - 15)
    UIDropDownMenu_SetWidth(145, dropdown)
    UIDropDownMenu_Initialize(dropdown, function()
        local list = S.spellBookSpells
        if listKind == "armor" then
            list = S.armorSpellBookSpells
        elseif listKind == "buff" then
            list = S.regularBuffSpellBookSpells
        end
        local _, value
        for _, value in ipairs(list) do
            local selected = value
            local info = {}
            info.text = value
            info.value = value
            info.func = function()
                MageCore_Config[key] = selected
                UIDropDownMenu_SetSelectedValue(dropdown, selected)
                UIDropDownMenu_SetText(selected, dropdown)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    local function Refresh()
        local current = MageCore_Config[key] or "None"
        UIDropDownMenu_SetSelectedValue(dropdown, current)
        UIDropDownMenu_SetText(current, dropdown)
    end
    Refresh()
    table.insert(S.menuRefreshers, Refresh)
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
    elseif SpellIsManaBlocked(spellName) then
        state, red, green, blue =
            (manaCost and ("MANA " .. mana .. "/" .. manaCost) or "MANA"),
            0.35, 0.55, 1
    elseif IsRangeBlocked(spellName)
        or (spellName == "Cone of Cold"
            and HasLivingEnemyTarget()
            and not SpellCanReachTarget(spellName))
        or GetSpellRangeState(spellName) == false then
        state, red, green, blue = "OUT OF RANGE", 1, 0.15, 0.15
    elseif spellName == "Arcane Surge" then
        local actionUsable = GetArcaneSurgeActionSlotState()
        local procActive = actionUsable
            or S.arcaneSurgeAvailableUntil > GetTime()
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
    if not S.rotationBoxFrame or not S.rotationBoxFrame:IsShown()
        or not MageCore_Config then return end

    -- Mark the slot the Rotation button will actually cast next, using the
    -- same decision as the action-bar icon.
    local decision = S.lastDecision
    local nextSpell = decision
        and (decision.kind == "SPELL" or decision.kind == "SHOOT")
        and decision.spell
    local i
    for i = 1, 6 do
        local row = S.rotationBoxRows[i]
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
    if S.rotationBoxFrame then return end
    EnsureConfig()

    local frame = CreateFrame(
        "Frame", "MageCoreRotationBox", UIParent)
    S.rotationBoxFrame = frame
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
        S.rotationBoxRows[i] = row
    end

    frame:Hide()
end

local function SetRotationBoxShown(shown)
    EnsureConfig()
    MageCore_Config.RotationBoxShown = shown and true or false
    if shown then
        CreateRotationBox()
        S.rotationBoxFrame:Show()
        UpdateRotationBox()
    elseif S.rotationBoxFrame then
        S.rotationBoxFrame:Hide()
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
    for i = 2, table.getn(S.spellBookSpells) do
        rotationNames = rotationNames .. (rotationNames == "" and "" or ", ") .. S.spellBookSpells[i]
    end
    for i = 2, table.getn(S.helpfulSpellBookSpells) do
        buffNames = buffNames .. (buffNames == "" and "" or ", ") .. S.helpfulSpellBookSpells[i]
    end
    DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "MageCore spellbook debug:|r")
    DEFAULT_CHAT_FRAME:AddMessage("Rotation (" .. (table.getn(S.spellBookSpells) - 1) .. "): " .. (rotationNames ~= "" and rotationNames or "NONE FOUND"))
    DEFAULT_CHAT_FRAME:AddMessage("Buffs (" .. (table.getn(S.helpfulSpellBookSpells) - 1) .. "): " .. (buffNames ~= "" and buffNames or "NONE FOUND"))
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
                .. (S.arcaneSurgeAvailableUntil > GetTime()
                    and "yes" or "no")
                .. ", no mana=" .. (noMana and "yes" or "no")
                .. ", selected="
                .. (GetArcaneSurgeAction() and "yes" or "no"))
    end
end

local function PrintAmplifyDebug()
    EnsureConfig()
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
    EnsureConfig()
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

local function Chat(message)
    DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "[MageCore]|r " .. message)
end

-- Profiles store the rotation, buffs and combat behavior, but not window
-- positions, nameplate looks or consumable thresholds.
local function GetProfileKeys()
    local keys = {
        "Opener", "AutoBuff", "PvPMode", "AutoCounterspell",
        "CounterspellHealingOnly", "AutoFireWard", "FireWardMode",
        "TargetedMagicMode", "TargetedMagicValue", "TargetedMagicSavedName",
        "AutoTargetEnemy", "AutoArcaneSurge", "PvPBurst", "PvPReslow",
        "PvPTargetPlayersOnly", "PvPTrinket",
        "AutoEvocation", "EvocationManaPercent",
        "AutoDefensiveShield", "DefensiveShieldHealthPercent"
    }
    local i
    for i = 1, 6 do
        table.insert(keys, "Rotation" .. i)
        table.insert(keys, "Buff" .. i)
        if i > 1 then table.insert(keys, "Buff" .. i .. "Group") end
    end
    return keys
end

local function FindProfileName(name)
    local wanted = string.lower(name or "")
    local existing
    for existing in pairs(MageCore_Config.Profiles) do
        if string.lower(existing) == wanted then return existing end
    end
    return nil
end

local function AfterSettingsChanged()
    LoadDefaults()
    RefreshSpellBook()
    S.groupBlockedUnits = {}
    S.conjureRestockActive = {}
    S.pendingConjure = nil
    S.pendingManaGem = nil
    S.openerUsedForTarget = nil
    UI.RefreshMenuControls()
    NP.ApplyNameplateVisibility()
    XP.ApplyConfig()
    CB.ApplyConfig()
    TGT.ApplyConfig()
end

local function ProfileCommand(subcommand, name)
    EnsureConfig()
    if subcommand == "list" or subcommand == "" then
        Chat("Profiles: " .. UI.GetProfileNamesText())
        return
    end
    if name == "" then
        Chat("Usage: |cffffffff/mc profile save/load/delete <name>|r or |cffffffff/mc profile list|r")
        return
    end
    local existing = FindProfileName(name)
    if subcommand == "save" then
        local profile = {}
        local _, key
        for _, key in ipairs(GetProfileKeys()) do
            profile[key] = MageCore_Config[key]
        end
        MageCore_Config.Profiles[existing or name] = profile
        UI.RefreshMenuControls()
        Chat("Profile saved: |cffffffff" .. (existing or name) .. "|r")
    elseif subcommand == "load" then
        if not existing then
            Chat("No profile named |cffffffff" .. name .. "|r.")
            return
        end
        local profile = MageCore_Config.Profiles[existing]
        local _, key
        for _, key in ipairs(GetProfileKeys()) do
            MageCore_Config[key] = profile[key]
        end
        AfterSettingsChanged()
        Chat("Profile loaded: |cffffffff" .. existing .. "|r")
    elseif subcommand == "delete" then
        if not existing then
            Chat("No profile named |cffffffff" .. name .. "|r.")
            return
        end
        MageCore_Config.Profiles[existing] = nil
        UI.RefreshMenuControls()
        Chat("Profile deleted: |cffffffff" .. existing .. "|r")
    else
        Chat("Usage: |cffffffff/mc profile save/load/delete <name>|r or |cffffffff/mc profile list|r")
    end
end

local function ResetSettings()
    EnsureConfig()
    -- Keep saved profiles and the minimap icon position.
    MageCore_Config = {
        Profiles = MageCore_Config.Profiles,
        MinimapPos = MageCore_Config.MinimapPos
    }
    AfterSettingsChanged()
    if S.rotationBoxFrame and not MageCore_Config.RotationBoxShown then
        S.rotationBoxFrame:Hide()
    end
    Chat("Settings restored to defaults. Saved profiles were kept.")
end

local function PrintHelp()
    Chat("commands:")
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/mc|r  open or close the window")
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/mc box on/off|r  rotation monitor")
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/mc profile save/load/delete <name>|r, |cffffffff/mc profile list|r")
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/mc xp on/off/lock/unlock/reset|r  movable XP bar")
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/mc cast on/off/lock/unlock/reset|r  movable cast bar")
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/mc tcast on/off/lock/unlock/reset|r  target cast bar and no-slow alert")
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/mc burst [on/off]|r  switch Burst Mode (PvP Mode)")
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/mc reset|r  restore default settings")
    DEFAULT_CHAT_FRAME:AddMessage("  |cffffffff/mc debug|r, |cffffffff/mc ampdebug|r, |cffffffff/mc amptest|r, |cffffffff/mc platedebug|r")
end

local function SlashCommand(message)
    local raw = string.gsub(message or "", "^%s+", "")
    raw = string.gsub(raw, "%s+$", "")
    local command = string.lower(raw)
    local _, _, profileSub, profileName =
        string.find(raw, "^[Pp][Rr][Oo][Ff][Ii][Ll][Ee][Ss]?%s*(%a*)%s*(.*)$")
    if profileSub then
        ProfileCommand(string.lower(profileSub), profileName or "")
    elseif command == "reset" then
        Chat("Type |cffffffff/mc reset confirm|r to restore default settings. Saved profiles are kept.")
    elseif command == "reset confirm" then
        ResetSettings()
    elseif command == "cast" or string.find(command, "^cast%s") then
        CB.Command((string.gsub(command, "^cast%s*", "")))
    elseif command == "tcast" or string.find(command, "^tcast%s") then
        TGT.Command((string.gsub(command, "^tcast%s*", "")))
    elseif command == "xp" or string.find(command, "^xp%s") then
        XP.Command((string.gsub(command, "^xp%s*", "")))
    elseif command == "burst" or command == "burst on" or command == "burst off" then
        -- Quick switch for a macro: /mc burst toggles, on/off set it.
        EnsureConfig()
        if command == "burst" then
            MageCore_Config.PvPBurst = not MageCore_Config.PvPBurst
        else
            MageCore_Config.PvPBurst = command == "burst on"
        end
        UI.RefreshMenuControls()
        Chat("Burst Mode " .. (MageCore_Config.PvPBurst
            and "|cff00ff00on|r" or "|cffff4444off|r")
            .. (MageCore_Config.PvPMode and "" or " (PvP Mode is off)") .. ".")
    elseif command == "help" then
        PrintHelp()
    elseif command == "box on" then
        SetRotationBoxShown(true)
    elseif command == "box off" then
        SetRotationBoxShown(false)
    elseif command == "box" then
        EnsureConfig()
        SetRotationBoxShown(not MageCore_Config.RotationBoxShown)
    elseif string.find(command, "^box%s") then
        Chat("Use |cffffffff/mc box on|r or |cffffffff/mc box off|r.")
    elseif command == "debug" then
        PrintSpellBookDebug()
    elseif command == "platedebug" then
        NP.PrintNameplateDebug()
    elseif command == "ampdebug" then
        PrintAmplifyDebug()
    elseif command == "amptest" then
        TestAmplifyCast()
    else
        ToggleMenu()
    end
end

function UI.MakeDragButton(parent, x, y, label, texture, OnDrag,
                              tooltipTitle, tooltipLines)
    local button = CreateFrame("Button", nil, parent)
    button:SetWidth(48)
    button:SetHeight(48)
    button:SetPoint("TOPLEFT", x, y)
    StyleButton(button)
    local icon = button:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("TOPLEFT", 4, -4)
    icon:SetPoint("BOTTOMRIGHT", -4, 4)
    icon:SetTexture(texture)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", OnDrag)
    button:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine(tooltipTitle)
        local _, line
        for _, line in ipairs(tooltipLines) do
            GameTooltip:AddLine(line, 0.8, 0.8, 0.8, 1, true)
        end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("BOTTOM", button, "TOP", 0, 2)
    text:SetText(label)
    return icon
end

function UI.AddHelpText(panel, x, y, text, fontObject)
    local help = panel:CreateFontString(
        nil, "OVERLAY", fontObject or "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", x, y)
    help:SetWidth(370)
    help:SetJustifyH("LEFT")
    help:SetText(text)
    return help
end

function UI.BuildRotationPanel(panel)
    UI.AddHelpText(panel, 10, 0, "After out-of-combat maintenance, Opener is cast once on a new target. Counterspell and smart elemental wards can take priority.")
    MageCore_CreateSpellDrop(panel, "Opener:", "Opener", 100, -45)
    local positions = {
        { 0, -102 }, { 200, -102 }, { 0, -158 },
        { 200, -158 }, { 0, -214 }, { 200, -214 }
    }
    local i
    for i = 1, 6 do
        MageCore_CreateSpellDrop(panel, "Rotation Slot " .. i .. ":",
            "Rotation" .. i, positions[i][1], positions[i][2])
    end

    S.rotationIconTexture = UI.MakeDragButton(panel, 18, -272, "Rotation",
        ICON_PATH .. DEFAULT_ICON,
        function()
            local index = CreateOrUpdateMacro(
                "MageRot", "/script MageCore_Rotate()", GetNextAction())
            if index and index > 0 then PickupMacro(index) end
        end,
        "MageCore Rotation", {
            "Out of combat: applies configured buffs.",
            "Maintains targeted Amplify Magic in and out of combat.",
            "Otherwise, combat presses use the attack rotation.",
            "Drag onto an action bar."
        })
    MageCore_CreateArcaneExplosionDragButton(panel)
    UI.MakeDragButton(panel, 300, -272, "Guarded Ice Block",
        GetSpellTextureByName("Ice Block") or ICON_PATH .. "Spell_Frost_Frost",
        function()
            local index = CreateOrUpdateMacro(
                "MageIceBlock", "/script MageCore_IceBlock()", "Ice Block")
            if index and index > 0 then PickupMacro(index) end
        end,
        "Guarded Ice Block", {
            "Casts Ice Block, then ignores cancellation presses for one second.",
            "After the guard expires, press the same button to cancel it.",
            "Drag onto an action bar."
        })
end

function UI.BuildBuffPanel(panel)
    UI.AddHelpText(panel, 10, 0, "Choose one learned armor and up to five other mage buffs. Group Intellect cycles through the roster. Main Rotation maintains Amplify Magic below.")
    local positions = {
        { 0, -55 }, { 200, -55 }, { 0, -125 },
        { 200, -125 }, { 0, -195 }, { 200, -195 }
    }
    local i
    for i = 1, 6 do
        MageCore_CreateSpellDrop(panel,
            i == 1 and "Armor:" or "Buff Slot " .. (i - 1) .. ":",
            "Buff" .. i, positions[i][1], positions[i][2],
            i == 1 and "armor" or "buff")
        if i > 1 then
            UI.MakeCheckBox(panel, "MageCoreBuff" .. i .. "GroupCheck",
                positions[i][1] + 15, positions[i][2] - 45,
                "Cast in group", "Buff" .. i .. "Group",
                function() S.groupBlockedUnits = {} end)
        end
    end

    local targetedLabel = panel:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    targetedLabel:SetPoint("TOPLEFT", 15, -263)
    targetedLabel:SetText(ACCENT .. "Amplify Magic target:|r")

    local drop = CreateFrame(
        "Frame", "MC_TargetedMagicDrop", panel, "UIDropDownMenuTemplate")
    drop:SetPoint("TOPLEFT", 0, -278)
    UIDropDownMenu_SetWidth(185, drop)
    local function RefreshDrop()
        UIDropDownMenu_SetSelectedValue(drop,
            (MageCore_Config.TargetedMagicMode or "TARGET") .. ":"
                .. (MageCore_Config.TargetedMagicValue or ""))
        UIDropDownMenu_SetText(GetTargetedMagicDisplay(), drop)
    end
    local function Select(mode, value)
        MageCore_Config.TargetedMagicMode = mode
        MageCore_Config.TargetedMagicValue = value
        if mode == "NAME" then MageCore_Config.TargetedMagicSavedName = value end
        RefreshDrop()
    end
    UIDropDownMenu_Initialize(drop, function()
        local function AddOption(text, mode, value)
            local info = {}
            info.text = text
            info.value = mode .. ":" .. (value or "")
            info.func = function() Select(mode, value) end
            UIDropDownMenu_AddButton(info)
        end
        AddOption("Current friendly target", "TARGET", nil)
        AddOption("Self", "SELF", nil)
        if MageCore_Config.TargetedMagicSavedName then
            AddOption("Player: " .. MageCore_Config.TargetedMagicSavedName,
                "NAME", MageCore_Config.TargetedMagicSavedName)
        end
        local _, option
        for _, option in ipairs(MAGE_TARGET_CLASS_OPTIONS) do
            AddOption("Class: " .. option[2], "CLASS", option[1])
        end
    end)
    RefreshDrop()
    table.insert(S.menuRefreshers, RefreshDrop)

    local saveButton = CreateFrame("Button", nil, panel)
    saveButton:SetWidth(165)
    saveButton:SetHeight(30)
    saveButton:SetPoint("TOPLEFT", 225, -287)
    StyleButton(saveButton)
    local saveText = saveButton:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    saveText:SetPoint("CENTER", 0, 0)
    saveText:SetText("Save selected player")
    saveButton:SetScript("OnClick", function()
        if not IsOtherGroupMember("target") then
            if UIErrorsFrame then
                UIErrorsFrame:AddMessage(
                    "Select a party or raid member first.", 1, 0.1, 0.1, 1)
            end
            return
        end
        local name = UnitName("target")
        if not name then return end
        Select("NAME", name)
        DEFAULT_CHAT_FRAME:AddMessage(
            ACCENT .. "[MageCore]|r Amplify Magic target saved: " .. name)
    end)
    UI.AddSimpleTooltip(saveButton, "Save selected player",
        "Remembers the currently selected party or raid member by name.")

    UI.MakeToggleButton(panel, 150, 8, -346, "Auto Buff OOC", "AutoBuff")
    S.buffIconTexture = UI.MakeDragButton(panel, 176, -338, "Buff only",
        ICON_PATH .. "Spell_Holy_MagicalSentry",
        function()
            local index = CreateOrUpdateMacro(
                "MageBuff", "/script MageCore_Buff()", GetBuffDisplaySpell())
            if index and index > 0 then PickupMacro(index) end
        end,
        "MageCore Buff", {
            "Casts the first configured buff that is missing.",
            "Slots marked Cast in group also check party or raid members.",
            "Amplify Magic uses your saved player, class, self, or current-target preference.",
            "Drag onto an action bar for a buff-only button."
        })
end

function UI.BuildFoodPanel(panel)
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -8)
    title:SetText(ACCENT .. "Food|r")
    UI.AddHelpText(panel, 18, -48, "Choose Highest or an exact rank. At the minimum, Rotation restocks out of combat until the maximum.")

    local function HighestText(options)
        local highest = options[1]
        return highest and highest.rankText
            and "Highest (" .. highest.rankText .. ")" or "Highest learned"
    end

    local function MakeConjureDrop(label, kind, x, y)
        local labelText = panel:CreateFontString(
            nil, "OVERLAY", "GameFontNormalSmall")
        labelText:SetPoint("TOPLEFT", x + 15, y)
        labelText:SetText(ACCENT .. label .. "|r")
        local dropdown = CreateFrame("Frame", "MC_ConjureDrop_" .. kind,
            panel, "UIDropDownMenuTemplate")
        dropdown:SetPoint("TOPLEFT", x, y - 16)
        UIDropDownMenu_SetWidth(155, dropdown)
        local function Options()
            return kind == "Water" and S.knownWaterSpells or S.knownFoodSpells
        end
        local function Choose(castName, autoRank, value, text)
            MageCore_Config[kind .. "Spell"] = castName
            MageCore_Config[kind .. "AutoRank"] = autoRank
            MageCore_Config[kind .. "ItemID"] = nil
            S.conjureRestockActive[kind] = nil
            S.pendingConjure = nil
            UIDropDownMenu_SetSelectedValue(dropdown, value)
            UIDropDownMenu_SetText(text, dropdown)
        end
        UIDropDownMenu_Initialize(dropdown, function()
            local options = Options()
            local info = {}
            info.text = "None"
            info.value = "None"
            info.func = function() Choose("None", false, "None", "None") end
            UIDropDownMenu_AddButton(info)
            local highest = options[1]
            if highest then
                local text = HighestText(options)
                info = {}
                info.text = text
                info.value = "AUTO"
                info.func = function() Choose(highest.cast, true, "AUTO", text) end
                UIDropDownMenu_AddButton(info)
            end
            local _, entry
            for _, entry in ipairs(options) do
                local selected = entry
                info = {}
                info.text = selected.display
                info.value = selected.cast
                info.func = function()
                    Choose(selected.cast, false, selected.cast, selected.display)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        local function Refresh()
            local options = Options()
            local current = MageCore_Config[kind .. "Spell"] or "None"
            if MageCore_Config[kind .. "AutoRank"] and options[1] then
                UIDropDownMenu_SetSelectedValue(dropdown, "AUTO")
                UIDropDownMenu_SetText(HighestText(options), dropdown)
                return
            end
            local display = "None"
            local _, entry
            for _, entry in ipairs(options) do
                if entry.cast == current then display = entry.display end
            end
            UIDropDownMenu_SetSelectedValue(dropdown, current)
            UIDropDownMenu_SetText(display, dropdown)
        end
        Refresh()
        table.insert(S.menuRefreshers, Refresh)
    end

    local function MakeThreshold(label, kind, threshold, x, y)
        UI.MakeNumberBox(panel, "MC_" .. kind .. threshold, x, y - 3, 65, label,
            kind .. threshold, 0, 999, threshold == "Minimum" and 20 or 80,
            function(value)
                -- Keep minimum <= maximum whichever box was edited.
                local minimum = tonumber(MageCore_Config[kind .. "Minimum"]) or 0
                local maximum = tonumber(MageCore_Config[kind .. "Maximum"]) or 0
                if maximum < minimum then
                    if threshold == "Maximum" then
                        MageCore_Config[kind .. "Maximum"] = minimum
                    else
                        MageCore_Config[kind .. "Maximum"] = value
                        local other = getglobal("MC_" .. kind .. "Maximum")
                        if other then other:SetText(value) end
                    end
                end
            end)
    end

    MakeConjureDrop("Water spell:", "Water", 0, -92)
    MakeConjureDrop("Food spell:", "Food", 200, -92)
    MakeThreshold("Minimum water:", "Water", "Minimum", 18, -174)
    MakeThreshold("Minimum food:", "Food", "Minimum", 218, -174)
    MakeThreshold("Maximum water:", "Water", "Maximum", 18, -220)
    MakeThreshold("Maximum food:", "Food", "Maximum", 218, -220)

    S.foodStatusText = UI.AddHelpText(panel, 18, -285,
        "Select a spell to begin tracking its conjured item.")
end

function UI.BuildConsumablePanel(panel)
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -8)
    title:SetText(ACCENT .. "Consumable|r")
    UI.AddHelpText(panel, 18, -48, "Rotation keeps your learned mana gems stocked out of combat and uses the strongest ready gem at or below your configured mana value.")
    MageCore_CreateManaGemControls(panel)
    MageCore_CreateDefilersTalismanButton(panel)
end

function UI.BuildPvPPanel(panel)
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -8)
    title:SetText(ACCENT .. "PvP|r")
    UI.AddHelpText(panel, 18, -40, "Burst Mode and Re-slow only act while PvP Mode is on. Counterspell and Auto Wards work in every fight.")

    UI.MakeToggleButton(panel, 180, 18, -75, "PvP Mode", "PvPMode", "PvP Mode",
        "With an enemy targeted, skips maintenance, prioritizes your strongest Frostbolt while the target is frozen by Frost Nova, Frostbite, or Freeze, and uses Rank 1 Frostbolt to slow a target that has no chill or freeze (see Re-slow).")
    UI.MakeToggleButton(panel, 180, 210, -75, "Burst Mode", "PvPBurst",
        "Burst Mode",
        "Overrides your normal Rotation slots. With PvP Mode on and an enemy targeted, Rotation casts Cone of Cold when the target is close enough, then Fire Blast when it is in range, before the PvP Frostbolt logic. After that logic, Arcane Explosion is used while the target is within 10 yards. Arcane Surge still comes first whenever it procs. After a \"target needs to be in front of you\" error, the burst pauses briefly so Cone of Cold is not wasted while the target is behind you. Turn it off to keep PvP Mode's Frostbolt slows but use your own Rotation slots. |cffffffff/mc burst|r switches it from a macro.")
    UI.MakeToggleButton(panel, 180, 18, -120, "Re-slow", "PvPReslow",
        "Re-slow",
        "In PvP Mode, Rotation casts Rank 1 Frostbolt again on the same target once its chill has worn off, at most every 4 seconds. Turn it off to use Rank 1 only once per target.")

    UI.MakeToggleButton(panel, 180, 210, -120, "Players only",
        "PvPTargetPlayersOnly", "Auto Target: players only",
        "In PvP Mode, Auto Target cycles through nearby enemies and only picks a living player, skipping NPCs, pets and totems. If no enemy player is near, the target is cleared and nothing is cast. Outside PvP Mode, Auto Target picks the nearest enemy as usual. Auto Target itself is switched on or off on the Extra tab.")
    UI.MakeToggleButton(panel, 180, 18, -165, "Counterspell", "AutoCounterspell",
        "Counterspell",
        "When your current enemy target is casting an interruptible spell, Rotation uses Counterspell before all other actions.")
    UI.MakeToggleButton(panel, 180, 210, -165, "Healing Only",
        "CounterspellHealingOnly", "Healing Only",
        "When Counterspell is enabled, Rotation interrupts recognized healing spells and ignores other casts.")

    UI.MakeToggleButton(panel, 180, 18, -210, "Auto Wards", "AutoFireWard",
        "Auto Wards",
        "Enables Fire Ward against configured Fire threats and Frost Ward against hostile Shamans. This works independently of PvP Mode and preserves your selected Fire Ward mode while disabled.")

    local modeButton = CreateFrame("Button", nil, panel)
    modeButton:SetWidth(180)
    modeButton:SetHeight(32)
    modeButton:SetPoint("TOPLEFT", 210, -210)
    StyleButton(modeButton)
    local modeText = modeButton:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    modeText:SetPoint("CENTER", 0, 0)
    local function RefreshMode()
        modeText:SetText("Ward Mode: "
            .. (MageCore_Config.FireWardMode == "CLASS"
                and "Mage/Warlock" or "Smart"))
    end
    RefreshMode()
    table.insert(S.menuRefreshers, RefreshMode)
    modeButton:SetScript("OnClick", function()
        if MageCore_Config.FireWardMode == "SMART" then
            MageCore_Config.FireWardMode = "CLASS"
        else
            MageCore_Config.FireWardMode = "SMART"
        end
        RefreshMode()
    end)
    UI.AddSimpleTooltip(modeButton, "Fire Ward Mode",
        "Smart uses Fire Ward proactively against Warlocks and remembers enemy Fire casts for two minutes. Mage/Warlock additionally pre-wards against all Mages. Frost Ward is always used against Shamans while Auto Wards is enabled. Counterspell remains the higher priority.")

    UI.MakeToggleButton(panel, 180, 18, -255, "PvP Trinket", "PvPTrinket",
        "PvP Trinket",
        "In PvP Mode, a Rotation or Arcane Explosion press uses your equipped Insignia or Medallion first while you are stunned, feared, polymorphed, charmed, sapped or otherwise lose control, if the trinket is ready. Slows and roots do not trigger it.")
    UI.MakeToggleButton(panel, 180, 210, -255, "No-slow alert", "NoSlowAlert",
        "No-slow alert",
        "Shows a large warning with the buff icon while your enemy target cannot be slowed or rooted: NO SLOW for Blessing of Freedom and Free Action, IMMUNE for Divine Shield, Divine Protection and Ice Block. Wait for it to disappear before you use Frost Nova. PvP Mode also skips its Rank 1 Frostbolt slow meanwhile. The alert sits above the target cast bar; unlock that bar on the Bars tab to move both.",
        TGT.ApplyConfig)

    UI.MakeDragButton(panel, 18, -305, "R1 Frostbolt",
        GetSpellTextureByName("Frostbolt") or ICON_PATH .. DEFAULT_ICON,
        function()
            local index = CreateOrUpdateMacro("MageSlow",
                "/script MageCore_SlowFrostbolt()", "Frostbolt")
            if index and index > 0 then PickupMacro(index) end
        end,
        "R1 Frostbolt", {
            "Always casts Rank 1 Frostbolt on your target - a cheap slow when you chase someone.",
            "Rotation's PvP logic knows about it and will not repeat it right away.",
            "Drag onto an action bar."
        })
    UI.AddHelpText(panel, 80, -310, "Drag |cffffffffR1 Frostbolt|r to an action bar for a button that always casts Rank 1 Frostbolt on your target.")
end

function UI.BuildInfoPanel(panel)
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -8)
    title:SetText(ACCENT .. "MageCore v" .. VERSION .. "|r")
    UI.AddHelpText(panel, 18, -48, "Mage rotation and buff helper for Turtle WoW. Open with |cffffffff/mc|r. Spells are read from your mage spellbook.")

    local novaButton = UI.MakeToggleButton(panel, 160, 18, -115, "Nova Range",
        "FrostNovaRange", nil, nil,
        function()
            if not MageCore_Config.FrostNovaRange then
                NP.HideFrostNovaRangeIndicators()
            end
        end)
    -- This tooltip shows the detected Arctic Reach rank, so build it on hover.
    novaButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Frost Nova Range")
        GameTooltip:AddLine("Shows a steady red border around hostile nameplates at longer range, then changes to a double-thickness bright green border inside Frost Nova's detected " .. S.frostNovaRangeYards .. "-yard range. Arctic Reach rank " .. S.arcticReachRank .. "/2 is detected from your spellbook. SuperWoW enables range detection for every nameplate; without it, the current target can change to the green state.", 0.8, 0.8, 0.8, 1, true)
        GameTooltip:Show()
    end)
    novaButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local reload = CreateFrame("Button", nil, panel)
    reload:SetWidth(160)
    reload:SetHeight(32)
    reload:SetPoint("TOPLEFT", 18, -225)
    StyleButton(reload)
    local reloadText = reload:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    reloadText:SetPoint("CENTER", 0, 0)
    reloadText:SetText("Reload UI")
    reload:SetScript("OnClick", function() ReloadUI() end)

    UI.MakeSlider(panel, "MageCoreNameplateScaleSlider", 205, -230, 50, 150, 5,
        "NameplateScale", 100, "50%", "150%",
        function(value)
            NP.ApplyNameplateScale()
            return "Nameplate Size: " .. value .. "%"
        end):SetWidth(160)

    UI.MakeCheckBox(panel, "MageCoreHighlightTargetNameplateCheck", 18, -275,
        "Target border", "HighlightTargetNameplate",
        function()
            NP.ApplyNameplateVisibility()
            NP.ApplyTargetOnlyNameplateVisibility(true)
            NP.UpdateTargetNameplateBorder()
        end,
        "Target border",
        "Keeps non-target units in a larger name-only mode and always shows the current target's complete nameplate.")
    UI.MakeCheckBox(panel, "MageCoreAlwaysShowNameplatesCheck", 205, -275,
        "Show enemy nameplates", "AlwaysShowNameplates",
        NP.ApplyNameplateVisibility)
    UI.MakeCheckBox(panel, "MageCoreShowFriendlyNameplatesCheck", 18, -305,
        "Show friendly nameplates", "ShowFriendlyNameplates",
        NP.ApplyNameplateVisibility)
    UI.MakeCheckBox(panel, "MageCoreTeamNameplateColorsCheck", 205, -305,
        "Red enemies / green team", "TeamNameplateColors")
    UI.MakeCheckBox(panel, "MageCoreRaisedNameplatesCheck", 205, -335,
        "Raised nameplates", "RaisedNameplates", NP.ApplyNameplateScale)
    UI.MakeCheckBox(panel, "MageCoreNameplateFeaturesCheck", 18, -335,
        "MageCore nameplate styling", "NameplateFeatures",
        function()
            NP.ApplyNameplateVisibility()
            if not MageCore_Config.NameplateFeatures then
                NP.UpdateSharpNameplateEdges()
                NP.UpdateTargetNameplateBorder()
                DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "[MageCore]|r Nameplate styling off. Type |cffffffff/reload|r to give the plates fully back to pfUI/ShaguTweaks.")
            end
        end,
        "MageCore nameplate styling",
        "Size, raise, team colors, edges, target border and name-only mode. Turn it off to let pfUI, ShaguTweaks or the default UI draw the plates on their own (then /reload). Nova Range keeps working either way.")
    UI.MakeCheckBox(panel, "MageCoreSharpNameplateEdgesCheck", 205, -365,
        "Sharp nameplate edges", "SharpNameplateEdges",
        NP.UpdateSharpNameplateEdges)
end

function UI.GetProfileNamesText()
    local names = {}
    local name
    for name in pairs(MageCore_Config.Profiles or {}) do
        table.insert(names, name)
    end
    table.sort(names)
    if table.getn(names) == 0 then return "none" end
    return table.concat(names, ", ")
end

function UI.BuildBarsPanel(panel)
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -8)
    title:SetText(ACCENT .. "Bars|r")
    UI.AddHelpText(panel, 18, -40, "Drag a bar to move it while it is unlocked, then lock it once it sits where you want it.")

    UI.MakeToggleButton(panel, 150, 18, -75, "XP Bar", "XPBarShown",
        "XP Bar",
        "Shows a movable experience bar with rested XP. It is hidden automatically at max level.",
        XP.ApplyConfig)
    UI.MakeCheckBox(panel, "MageCoreXPBarLockCheck", 185, -79,
        "Lock XP bar", "XPBarLocked")
    UI.MakeSlider(panel, "MageCoreXPBarScaleSlider", 28, -130, 50, 200, 5,
        "XPBarScale", 100, "50%", "200%",
        function(value)
            if S.xpBarFrame then BARS.Apply(S.xpBarFrame, "XPBar", -200) end
            return "XP bar size: " .. value .. "%"
        end)

    UI.MakeToggleButton(panel, 150, 18, -180, "Cast Bar", "CastBarShown",
        "Cast Bar",
        "Shows a movable cast bar with spell icon, name and remaining time. The default cast bar is hidden while this one is on.",
        CB.ApplyConfig)
    UI.MakeCheckBox(panel, "MageCoreCastBarLockCheck", 185, -184,
        "Lock cast bar", "CastBarLocked",
        function()
            if S.castBarFrame and MageCore_Config.CastBarShown then
                CB.ShowState()
            end
        end,
        "Lock cast bar",
        "While unlocked, the cast bar stays visible as a preview so you can drag it into place.")
    UI.MakeSlider(panel, "MageCoreCastBarScaleSlider", 28, -235, 50, 200, 5,
        "CastBarScale", 100, "50%", "200%",
        function(value)
            if S.castBarFrame then BARS.Apply(S.castBarFrame, "CastBar", -150) end
            return "Cast bar size: " .. value .. "%"
        end)

    UI.MakeToggleButton(panel, 150, 18, -280, "Target Cast", "TargetCastBarShown",
        "Target Cast Bar",
        "Shows a large movable bar with what your current target is casting: spell icon, name and remaining time. Gold while casting, green while channeling, red when interrupted. The PvP tab's No-slow alert sits just above it and moves with it.",
        TGT.ApplyConfig)
    UI.MakeCheckBox(panel, "MageCoreTargetCastBarLockCheck", 185, -284,
        "Lock target cast bar", "TargetCastBarLocked",
        TGT.ApplyConfig,
        "Lock target cast bar",
        "While unlocked, the target cast bar and the no-slow alert show a preview so you can drag them into place.")
    UI.MakeSlider(panel, "MageCoreTargetCastBarScaleSlider", 28, -335, 50, 200, 5,
        "TargetCastBarScale", 100, "50%", "200%",
        function(value)
            if S.targetBarFrame then
                BARS.Apply(S.targetBarFrame, "TargetCastBar", -100)
            end
            return "Target cast bar size: " .. value .. "%"
        end)

    UI.AddHelpText(panel, 18, -372,
        "|cffffffff/mc xp|r, |cffffffff/mc cast|r, |cffffffff/mc tcast|r: on/off/lock/unlock/reset")
end

function UI.BuildExtraPanel(panel)
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -8)
    title:SetText(ACCENT .. "Extra|r")
    UI.AddHelpText(panel, 18, -40, "Optional automation for the Rotation button. Each option is off by default except Auto Target.")

    UI.MakeToggleButton(panel, 150, 225, -75, "Surge on proc",
        "AutoArcaneSurge", "Arcane Surge on proc",
        "When enabled, the Rotation button casts Arcane Surge as soon as a resist proc is available (also during Arcane Missiles), even if Arcane Surge is not in a Rotation slot. When disabled, Rotation only uses it if a Rotation slot is set to Arcane Surge. The Arcane Explosion button always uses a Surge proc.")
    UI.MakeToggleButton(panel, 200, 18, -75, "Auto Target", "AutoTargetEnemy",
        "Auto Target",
        "When enabled, a Rotation press without a living enemy target selects the nearest enemy. Turn it off to avoid pulling mobs by accident.")

    UI.MakeToggleButton(panel, 200, 18, -125, "Evocation", "AutoEvocation",
        "Evocation",
        "In a fight, Rotation channels Evocation when your mana is at or below the selected percentage and no mana gem is ready.")
    UI.MakeNumberBox(panel, "MageCoreEvocationManaPercent", 240, -119, 60,
        "At mana %:", "EvocationManaPercent", 1, 100, 10)

    UI.MakeToggleButton(panel, 200, 18, -175, "Low-health Shield",
        "AutoDefensiveShield", "Low-health Shield",
        "In combat, Rotation casts Ice Barrier (or Mana Shield when Ice Barrier is unavailable) at or below the selected health percentage. Only one shield is kept at a time.")
    UI.MakeNumberBox(panel, "MageCoreShieldHealthPercent", 240, -169, 60,
        "At health %:", "DefensiveShieldHealthPercent", 1, 100, 40)

    local profileTitle = panel:CreateFontString(
        nil, "OVERLAY", "GameFontNormal")
    profileTitle:SetPoint("TOPLEFT", 18, -232)
    profileTitle:SetText(ACCENT .. "Profiles|r")
    UI.AddHelpText(panel, 18, -252,
        "|cffffffff/mc profile save <name>|r  saves rotation, buffs and combat toggles\n"
        .. "|cffffffff/mc profile load <name>|r  restores them\n"
        .. "|cffffffff/mc profile delete <name>|r,  |cffffffff/mc profile list|r\n"
        .. "|cffffffff/mc reset|r  restores default settings (profiles are kept)")
    local saved = UI.AddHelpText(panel, 18, -330, "")
    local function RefreshSaved()
        saved:SetText("Saved profiles: |cffffffff" .. UI.GetProfileNamesText() .. "|r")
    end
    RefreshSaved()
    table.insert(S.menuRefreshers, RefreshSaved)
end

function MageCore_CreateMenu()
    if MageCoreMenuFrame then return end
    EnsureConfig()
    -- Re-scan here as well as at login; some Turtle clients populate class
    -- spellbook tabs after PLAYER_LOGIN has already fired.
    RefreshSpellBook()

    local frame = CreateFrame("Frame", "MageCoreMenuFrame", UIParent)
    frame:SetWidth(520)
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

    local tabs = {
        { "Rotation", UI.BuildRotationPanel },
        { "Buffs", UI.BuildBuffPanel },
        { "Food", UI.BuildFoodPanel },
        { "Consumable", UI.BuildConsumablePanel },
        { "PvP", UI.BuildPvPPanel },
        { "Info", UI.BuildInfoPanel },
        { "Bars", UI.BuildBarsPanel },
        { "Extra", UI.BuildExtraPanel }
    }
    local panels = {}
    local buttons = {}
    local function ShowTab(index)
        local i
        for i = 1, table.getn(panels) do
            if i == index then
                panels[i]:Show()
                buttons[i]:SetBackdropColor(0.08, 0.3, 0.48, 0.96)
            else
                panels[i]:Hide()
                buttons[i]:SetBackdropColor(0.03, 0.09, 0.14, 0.96)
            end
        end
    end
    local i
    for i = 1, table.getn(tabs) do
        local panel = CreateFrame("Frame", nil, frame)
        panel:SetWidth(400)
        panel:SetHeight(390)
        panel:SetPoint("TOPLEFT", 15, -90)
        panels[i] = panel

        local tabIndex = i
        local button = CreateFrame("Button", nil, frame)
        button:SetWidth(60)
        button:SetHeight(26)
        button:SetPoint("TOPLEFT", 14 + (i - 1) * 62, -50)
        StyleButton(button)
        local label = button:CreateFontString(
            nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("CENTER", 0, 0)
        label:SetText(tabs[i][1])
        button:SetScript("OnClick", function() ShowTab(tabIndex) end)
        buttons[i] = button

        tabs[i][2](panel)
    end
    ShowTab(1)
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

local function GetCurrentXPString()
    local currentXP = UnitXP("player") or 0
    local levelXP = UnitXPMax("player") or 0
    if levelXP <= 0 then return currentXP end
    local percent = math.floor(100 * currentXP / levelXP)
    return currentXP .. " / " .. levelXP .. " (" .. percent .. "%)"
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
        GameTooltip:AddLine("Current XP: |cff00ff00" .. GetCurrentXPString() .. "|r", 1, 1, 1)
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
eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("PLAYER_AURAS_CHANGED")
eventFrame:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
eventFrame:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        LoadDefaults()
    elseif event == "PLAYER_LOGIN" then
        LoadDefaults(); RefreshSpellBook(); CreateMinimapButton(); SetupRotationButtonTooltips()
        XP.ApplyConfig()
        CB.ApplyConfig()
        TGT.ApplyConfig()
        if MageCore_Config.RotationBoxShown then
            CreateRotationBox()
            S.rotationBoxFrame:Show()
            UpdateRotationBox()
        end
        SLASH_MAGECORE1 = "/mc"
        SLASH_MAGECORE2 = "/magecore"
        SlashCmdList["MAGECORE"] = SlashCommand
        DEFAULT_CHAT_FRAME:AddMessage(ACCENT .. "MageCore v" .. VERSION .. "|r loaded. Type |cffffffff/mc|r to open.")
    elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" then
        RefreshSpellBook()
    elseif event == "START_AUTOREPEAT_SPELL" then
        S.autoRepeatActive = true
    elseif event == "STOP_AUTOREPEAT_SPELL" then
        S.autoRepeatActive = false
    elseif event == "BAG_UPDATE" then
        S.bagSnapshot = nil
        LearnPendingConjureItem()
        if S.pendingManaGem and FindBagItemByName(S.pendingManaGem.item) then
            S.pendingManaGem = nil
        end
    elseif event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
        S.normalCastInProgress = false
        S.channelInProgress = false
        S.channelSpellName = nil
        S.pendingConjure = nil
        S.pendingManaGem = nil
        if S.lastCombatSpellAttempt and S.lastCombatSpellAttempt.opener
            and GetTime() - S.lastCombatSpellAttempt.time < 1.5 then
            S.openerUsedForTarget = nil
        end
    elseif event == "SPELLCAST_START" then
        S.normalCastInProgress = true
    elseif event == "SPELLCAST_STOP" then
        S.normalCastInProgress = false
    elseif event == "SPELLCAST_CHANNEL_START" then
        S.normalCastInProgress = false
        S.channelInProgress = true
        S.channelSpellName = arg2
        if not S.channelSpellName and S.lastCombatSpellAttempt
            and GetTime() - S.lastCombatSpellAttempt.time < 1.5 then
            S.channelSpellName = S.lastCombatSpellAttempt.spell
        end
    elseif event == "SPELLCAST_CHANNEL_STOP" then
        S.normalCastInProgress = false
        S.channelInProgress = false
        S.channelSpellName = nil
    elseif event == "UI_ERROR_MESSAGE" then
        local message = string.lower(arg1 or "")
        local notEnoughMana =
            (SPELL_FAILED_NO_POWER and arg1 == SPELL_FAILED_NO_POWER)
            or string.find(message, "not enough mana", 1, true)
        if notEnoughMana and S.lastCombatSpellAttempt
            and GetTime() - S.lastCombatSpellAttempt.time < 1.5 then
            -- Some Vanilla clients fail to expose mana costs or the
            -- IsUsableSpell power flag for particular Turtle spells. Force
            -- the next Rotation press through the wand fallback.
            S.lowManaWandFallbackUntil = GetTime() + 3
        end
        local notInFront = (SPELL_FAILED_UNIT_NOT_INFRONT
                and arg1 == SPELL_FAILED_UNIT_NOT_INFRONT)
            or string.find(message, "in front of you", 1, true)
        if notInFront and S.lastCombatSpellAttempt
            and GetTime() - S.lastCombatSpellAttempt.time < 1.5 then
            S.facingBlocked = {
                target = S.lastCombatSpellAttempt.target,
                expires = GetTime() + 1.5
            }
        end
        local outOfRange = (SPELL_FAILED_OUT_OF_RANGE and arg1 == SPELL_FAILED_OUT_OF_RANGE)
            or string.find(message, "out of range", 1, true)
            or string.find(message, "too far away", 1, true)
            or string.find(message, "line of sight", 1, true)
        if outOfRange and S.lastGroupBuffAttempt
            and GetTime() - S.lastGroupBuffAttempt.time < 1.5 then
            S.groupBlockedUnits[S.lastGroupBuffAttempt.key] = GetTime() + 5
            S.lastGroupBuffAttempt = nil
        elseif outOfRange and S.lastCombatSpellAttempt
            and GetTime() - S.lastCombatSpellAttempt.time < 1.5 then
            if S.lastCombatSpellAttempt.opener then S.openerUsedForTarget = nil end
            S.rangeBlockedSpells[S.lastCombatSpellAttempt.spell] = {
                target = S.lastCombatSpellAttempt.target,
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
            S.pendingLunaInterruptMessage = arg1
        end
        if event == "CHAT_MSG_SPELL_SELF_DAMAGE" then
            TrackArcaneSurgeFromCombatMessage(arg1)
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        InvalidateAuraCache("target")
        if GetTime() > (S.suppressTargetResetUntil or 0) then
            S.rangeBlockedSpells = {}
            S.lastCombatSpellAttempt = nil
            S.openerUsedForTarget = nil
            S.pvpFrostboltUsedForTarget = nil
            S.facingBlocked = nil
        end
        NP.ApplyNameplateVisibility()
        NP.ApplyTargetOnlyNameplateVisibility(true)
    elseif event == "PARTY_MEMBERS_CHANGED" or event == "RAID_ROSTER_UPDATE" then
        S.groupBlockedUnits = {}
        S.lastGroupBuffAttempt = nil
        InvalidateAuraCache()
    elseif event == "UNIT_AURA" then
        InvalidateAuraCache(arg1)
    elseif event == "PLAYER_AURAS_CHANGED" then
        InvalidateAuraCache("player")
    elseif event == "ACTIONBAR_SLOT_CHANGED" then
        S.actionSlotIndex = nil
    end
end)

local function UpdateFoodStatus()
    -- Counting bag contents is only needed while the Food tab is visible.
    if not S.foodStatusText or not S.foodStatusText:IsVisible() then return end
    local lines = {}
    local _, kind
    for _, kind in ipairs({ "Water", "Food" }) do
        local state = "disabled"
        if (MageCore_Config[kind .. "Spell"] or "None") ~= "None" then
            local itemID = MageCore_Config[kind .. "ItemID"]
            if itemID then
                state = GetItemCountByID(itemID)
                    .. " (min " .. (MageCore_Config[kind .. "Minimum"] or 0)
                    .. ", max " .. (MageCore_Config[kind .. "Maximum"] or 0) .. ")"
            else
                state = "learns item on first conjure"
            end
        end
        table.insert(lines, kind .. ": " .. state)
    end
    S.foodStatusText:SetText(table.concat(lines, "\n"))
end

local function UpdateRotationButton()
    local decision = DecideRotation(false)
    S.lastDecision = decision
    -- The icon stays locked to the active cast or channel, unless the next
    -- press would interrupt it (emergency potion or Arcane Surge).
    if S.normalCastInProgress or S.channelInProgress then
        local urgent = decision and (decision.kind == "POTION"
            or decision.kind == "SURGE_INTERRUPT" or decision.tag == "SURGE")
        if not urgent then return end
    end
    local spellName = decision and decision.spell
    local texture = GetDecisionTexture(decision) or ICON_PATH .. DEFAULT_ICON
    SetRotationIconTexture(texture)
    local macroIcon = TextureName(texture) or DEFAULT_ICON
    if macroIcon ~= S.lastRotationIcon then
        local index = GetMacroIndex("MageRot", false)
        if index > 0 then
            EditMacro(index, "MageRot", macroIcon,
                "/script MageCore_Rotate()", nil, nil)
        end
        S.lastRotationIcon = macroIcon
    end
    UpdateRotationCooldown(spellName)
    UpdateRotationManaState(spellName)
end

local function UpdateBuffButton()
    -- Checking buffs walks the whole party or raid, so skip it when neither
    -- the Buff tab icon nor a placed MageBuff macro would show the result.
    local iconVisible = S.buffIconTexture and S.buffIconTexture:IsVisible()
    local macroIndex = GetMacroIndex("MageBuff", false)
    if not iconVisible and macroIndex == 0 then return end
    local buffTexture = GetSpellTextureByName(GetBuffDisplaySpell())
        or ICON_PATH .. "Spell_Holy_MagicalSentry"
    if S.buffIconTexture then S.buffIconTexture:SetTexture(buffTexture) end
    local buffMacroIcon = TextureName(buffTexture) or "Spell_Holy_MagicalSentry"
    if buffMacroIcon ~= S.lastBuffIcon and macroIndex > 0 then
        EditMacro(macroIndex, "MageBuff", buffMacroIcon,
            "/script MageCore_Buff()", nil, nil)
        S.lastBuffIcon = buffMacroIcon
    end
end

eventFrame:SetScript("OnUpdate", function()
    if S.pendingLunaInterruptMessage then
        ClearConfirmedLunaInterrupt(S.pendingLunaInterruptMessage)
        S.pendingLunaInterruptMessage = nil
    end

    local elapsed = arg1 or 0
    S.frostNovaRangeElapsed = S.frostNovaRangeElapsed + elapsed
    if S.frostNovaRangeElapsed >= 0.1 then
        S.frostNovaRangeElapsed = 0
        NP.UpdateFrostNovaRangeIndicators()
    end

    S.buffElapsed = S.buffElapsed + elapsed
    S.updateElapsed = S.updateElapsed + elapsed
    if S.updateElapsed < 0.4 then return end
    S.updateElapsed = 0
    if not MageCore_Config then return end
    EnsureConfig()
    NP.ApplyNameplateVisibility()
    UpdateIceBlockCooldown()
    if S.pendingConjure then LearnPendingConjureItem() end
    UpdateFoodStatus()
    UpdateRotationButton()
    UpdateRotationBox()
    MageCore_UpdateArcaneExplosionButton()
    if S.buffElapsed >= 1 then
        S.buffElapsed = 0
        UpdateBuffButton()
    end
end)
