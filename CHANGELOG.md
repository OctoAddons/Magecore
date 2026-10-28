# Changelog

## 1.10.0
- New **Target cast bar** (Bars tab, on by default): a large movable bar showing what your current target is casting, with spell icon, name and remaining time. Gold while casting, green while channeling, red when interrupted. Uses SuperWoW for exact cast times and falls back to pfUI/ShaguTweaks cast data. Unlock it on the Bars tab to drag it, with a size slider (50–200%). `/mc tcast on/off/lock/unlock/reset`.
- New **No-slow alert** (PvP tab, on by default): a large warning with the buff icon above the target cast bar while your enemy target cannot be slowed or rooted. **NO SLOW** for Blessing of Freedom and Free Action potions, **IMMUNE** for Divine Shield, Divine Protection and Ice Block. Wait for it to disappear before using Frost Nova.
- PvP Mode no longer spends its Rank 1 Frostbolt slow on a target with Freedom or an immunity.
- **PvP Burst** is now called **Burst Mode**, because it overrides your normal Rotation slots. Your setting is kept. New `/mc burst` (and `/mc burst on/off`) switches it from a macro.
- Burst Mode now ends with **Arcane Explosion** while the target is within 10 yards. It comes after the PvP Frostbolt logic, so a Rank 1 slow or a Frostbolt on a frozen target is still cast first. It does not need a Rotation slot.

## 1.9.3
- **PvP Trinket** (PvP tab, on by default): in PvP Mode, a Rotation or Arcane Explosion press uses your equipped Insignia or Medallion first whenever you are stunned, feared, polymorphed, charmed, sapped, blinded or otherwise lose control and the trinket is ready. Slows and roots do not use it, so the 5-minute cooldown is saved for real crowd control.

## 1.9.2
- **Players only** (PvP tab, on by default): in PvP Mode, Auto Target cycles through nearby enemies and only picks a living player, skipping NPCs, pets and totems. With no enemy player nearby, the target is cleared and nothing is cast. Applies to the Rotation and R1 Frostbolt buttons.

## 1.9.1
- New **PvP** tab that gathers all PvP settings: PvP Mode, PvP Burst, Re-slow, Counterspell, Healing Only, Auto Wards, Ward Mode and the R1 Frostbolt drag button. They moved there from the Info, Extra and Rotation tabs; your settings are unchanged.
- The settings window is slightly wider to fit eight tabs.

## 1.9.0
- **Re-slow** (Extra tab, on by default): in PvP Mode, Rotation casts Rank 1 Frostbolt again on the same target once its chill has worn off, at most every 4 seconds. Turn it off for the old once-per-target behavior.
- New **R1 Frostbolt** drag button on the Rotation tab (macro `MageSlow`): one press always casts Rank 1 Frostbolt on your target. Rotation knows about it and will not repeat it right away.

## 1.8.0
- New **PvP Burst** (Extra tab, on by default): with PvP Mode on and an enemy targeted, Rotation casts Cone of Cold when the target is within its Arctic Reach-adjusted range, then Fire Blast when it is in range, before the PvP Frostbolt logic. Neither spell has to be in a Rotation slot. Arcane Surge still comes first whenever it procs.
- After a "Target needs to be in front of you" error, the burst and the PvP Rank 1 Frostbolt pause for 1.5 seconds on that target, so Cone of Cold and the single Rank 1 attempt are not wasted while the target is behind you.

## 1.7.0
- New movable **cast bar** with spell icon, name and remaining time: gold while casting, green while channeling, a short green flash on success and red on interrupt or failure. It follows pushback and channel updates. While it is on, the default cast bar is hidden; turning it off gives the default bar back.
- New **Bars** tab with the XP bar and cast bar: on/off, lock and a size slider (50–200%) for each. While unlocked, the cast bar shows a preview so it can be dragged into place.
- The XP bar can now be resized as well. Its settings moved from the Extra tab to the Bars tab.
- `/mc cast on/off/lock/unlock/reset`; `/mc xp reset` also restores 100% size.

## 1.6.4
- **Nova Range** is much quieter: only enemies inside Frost Nova range get a thin green outline. The thick red outline around every other enemy is gone.
- New **MageCore nameplate styling** switch on the Info tab. Turn it off (then /reload) to let pfUI, ShaguTweaks or the default UI draw the nameplates on their own; Nova Range still works.
- Distant nameplates keep the right color: neutral units at long range are now yellow (red once in combat), and the last known color of each SuperWoW GUID is remembered when the client briefly stops answering for far-away units. This also stops plates flipping between full and name-only mode.
- Plate size and raise are applied every frame after pfUI/ShaguTweaks and only when something differs, so plates no longer jump while those addons rescale them.

## 1.6.3
- Arcane Surge is chosen the moment its proc appears, also while the global cooldown from the resisted spell is still running. Before, Rotation and the Arcane Explosion button fell through to another spell during the global cooldown, so with a spell queue that spell was cast first and Surge only came on the following press. Arcane Missiles is still only cancelled once Surge can be cast immediately, and a real Surge cooldown still blocks it.

## 1.6.2
- New movable **XP bar** with rested XP (purple while rested, with a lighter overlay showing how far the bonus reaches). Turn it on with the **XP Bar** toggle on the Extra tab or `/mc xp on`, drag it where you want it, and lock it with the checkbox or `/mc xp lock`. `/mc xp reset` moves it back to the default position. It hides automatically at max level.

## 1.6.1
- New **Surge on proc** toggle on the Extra tab (on by default): the Rotation button casts Arcane Surge as soon as a resist proc is available, also during Arcane Missiles, without Arcane Surge occupying a Rotation slot. Turn it off to use Surge in Rotation only when a slot is set to Arcane Surge. The Arcane Explosion button always uses a Surge proc.

## 1.6.0

### Fixes
- Self-buffs and elemental wards are cast on yourself without changing target. Previously the temporary target swap reset the once-per-target Opener and PvP Rank 1 Frostbolt state, so Rank 1 could be cast again on the same enemy after a ward or Amplify Magic.
- Temporary target swaps for group buffs no longer reset per-target state either.
- Conjured water/food learning only accepts items whose name starts with "Conjured", so loot received during the cast can no longer be learned by mistake.
- Healing potion selection now actually picks the strongest potion (1.12's GetItemInfo needs `item:ID`, not a full link).
- The Rotation Monitor's NEXT marker now matches what the Rotation button will really cast.

### Performance
- Spellbook positions, buffs per unit, action-bar slots, placed MageCore buttons and bag contents are cached and refreshed by events instead of being rescanned several times per update.
- Nameplates identify each unit once per update instead of on every frame for every plate, and only re-anchor plate visuals when they change.
- Default settings and migrations run once instead of on every button press.
- Food status and the Buff button icon are only computed when visible or in use.

### Structure
- The button press, action-bar icon, tooltip and monitor all use one shared decision function.
- Runtime state, nameplate code and menu builders are grouped in tables to stay clear of Vanilla Lua's 200-local and 32-upvalue limits.
- The version number lives only in `MageCore.toc`.

### New
- Mana gems: Ruby, Citrine, Jade and Agate (existing Mana Agate settings are migrated).
- Extra tab: Auto Target toggle, Evocation at low mana, Ice Barrier / Mana Shield at low health.
- Profiles: `/mc profile save|load|delete <name>`, `/mc profile list`.
- `/mc reset` (with confirmation) and `/mc help`.
- The Rotation button icon and tooltip show a healing potion, mana gem or Defiler's Talisman when that is what the next press will use.
