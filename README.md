# MageCore

MageCore is a press-driven mage rotation and self-buff helper for Turtle WoW / Vanilla 1.12.

## Use

- Enable the addon and log in on a mage.
- Left-click the blue Frostbolt icon by the minimap, or type `/mc`.
- Hover over the minimap icon to see your current rested XP percentage.
- Use the **Info** tab for addon details, the **Counterspell**, **Healing Only**, **PvP Mode**, and **Nova Range** toggles, and a **Reload UI** button.
- The **Food** tab scans every learned Conjure Water/Food rank. **Highest** automatically follows newly learned ranks, while exact lower ranks remain selectable. Set a minimum and maximum for each item: Rotation starts restocking at or below the minimum, then continues on later presses until it reaches or exceeds the maximum.
- Type `/mc debug` to print the attack and buff spells detected in the spellbook.
- Configure the **Rotation** and **Buffs** tabs. Both lists are read from your character's current spellbook.
- Drag the Rotation icon from the window to an action bar.
- Press that action button repeatedly to apply missing buffs and cast the first ready rotation spell.
- With the **Counterspell** toggle enabled, Rotation prioritizes Counterspell when your current enemy target is casting an interruptible spell.
- Enable **Healing Only** to ignore non-healing casts and reserve Counterspell for recognized healing spells.
- Enemy cast detection supports stock-compatible cast libraries and SuperWoW GUID-based casts used by pfUI and ShaguTweaks.
- Enable **Nova Range** to give hostile nameplates a flashing red and yellow border inside Frost Nova range. MageCore reads the **Arctic Reach** spellbook rank and selects 10 yards at 0/2, 11 yards at 1/2, or 12 yards at 2/2. Exact coordinates are used when SuperWoW supplies them; otherwise the closest conservative Vanilla interaction-distance threshold is used. SuperWoW supports every visible nameplate; the current target remains supported without it.
- Use **Nameplate Size** on the Info tab to scale native and ShaguTweaks nameplates from 50% to 150% while preserving their above-head position; the setting also scales castbars and the Nova Range outline.

Put cooldown abilities (for example, Fire Blast) above your filler spell (for example, Frostbolt). The separate Buff icon creates a buff-only action button. The minimap icon can be dragged around the minimap.

The Rotation action-bar button displays the normal spell tooltip for the action MageCore currently plans to cast.

If the character knows **Find Minerals**, an out-of-combat Rotation press restores it whenever no tracking or a different tracking type is active.

The optional **Opener** is cast once against a new target while you are out of combat, after buff/group/food maintenance and before the normal rotation slots.

When **PvP Mode** is enabled and a living enemy is already targeted, Rotation skips buff, group, and conjured food/water maintenance. It goes directly to combat, using Rank 1 Frostbolt once after acquiring a new target when that enemy is not already slowed by a frost effect.

When the PvP override uses Rank 1 Frostbolt, MageCore displays a yellow notice in your local chat frame. This message is visible only to you.

While idle and out of combat with no enemy target, the action-bar icon previews the configured opener rather than Rotation Slot 1.

MageCore never uses a stopwatch fallback icon. Rotation retains the next ready, soonest-cooldown, opener, or configured rotation spell; Buff retains a configured buff icon.

Rotation presses do nothing while a channel such as Arcane Missiles, Blizzard, or Evocation is active, preventing the channel from being cancelled early.

The MageRot icon dims whenever the currently displayed spell costs more mana than the mage currently has.

The MageRot icon is tinted red when its currently displayed spell is out of range, matching a native spell action button.

When **Cone of Cold** is configured in the rotation, MageCore casts it only while the current hostile target is within its Arctic Reach-adjusted range. Otherwise, Rotation skips it and uses the next ready spell.

The dynamic Rotation icon remains locked to the active spell while casting or channeling, then changes to the next action when the cast ends.

When no configured rotation spell is ready, the macro keeps the soonest-ready spell visible and displays its real cooldown sweep/countdown on Bartender2 or Blizzard action buttons.

Rotation skips configured spells known to be out of range. On clients that cannot query a spell's range directly, an out-of-range failure is remembered briefly so the next press proceeds to the following rotation slot.

When **Auto Buff OOC** is enabled, each press of the Rotation button applies the next missing configured buff while out of combat. During combat it skips buffs and uses attack spells. Turn Auto Buff off to make Rotation ignore buffs; the separate Buff button remains available for manual buffing.

Enable **Group Intellect** to make out-of-combat Rotation presses apply Arcane Intellect to living, connected party or raid members who are missing it, one member per press.

Buff selection follows learned spell and active aura state rather than the legacy spellbook cooldown flag, which can incorrectly reject beneficial mage spells.

The spell lists refresh automatically after learning or training a spell. MageCore reads only the mage class tabs, leaving out General-tab actions, racial abilities, professions, passive abilities, and duplicate ranks. Because the Vanilla 1.12 client has no helpful/harmful spell classification API, MageCore separates learned mage spells using mage categories and spell-tooltip text. Select only one armor spell at a time because mage armors replace each other.

MageCore does not cast automatically; one key press performs one action, as required by the Vanilla/Turtle WoW client.
