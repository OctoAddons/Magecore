# MageCore

MageCore is a press-driven mage rotation and self-buff helper for Turtle WoW / Vanilla 1.12.

## Use

- Enable the addon and log in on a mage.
- Left-click the blue Frostbolt icon by the minimap, or type `/mc`.
- Hover over the minimap icon to see your current rested XP percentage.
- Use the **Info** tab for addon details, the **Counterspell**, **Healing Only**, **PvP Mode**, and **Nova Range** toggles, and a **Reload UI** button. The Rotation tab contains the automatic elemental ward controls.
- The **Food** tab scans every learned Conjure Water/Food rank. **Highest** automatically follows newly learned ranks, while exact lower ranks remain selectable. Set a minimum and maximum for each item: Rotation starts restocking at or below the minimum, then continues on later presses until it reaches or exceeds the maximum.
- The **Consumable** tab can maintain one **Mana Agate** in your bags. When enabled, an out-of-combat Rotation press casts Conjure Mana Agate if the gem is missing, and either combat button uses a ready gem at 200 current mana or below. Both the Rotation and Arcane Explosion/Surge buttons can use an equipped **Defiler's Talisman** after you lose a configurable percentage of your maximum health (20% by default). A separate 0%–60% slider controls automatic use of the strongest ready **Healing Potion** or **Healing Draught** in your bags at or below that current-health percentage from either combat button; 0% disables healing-item use. Battleground-only draughts are skipped outside an active battleground.
- Rotation maintains **Find Minerals** outside battlegrounds but skips it while you are inside an active battleground.
- Type `/mc debug` to print the attack and buff spells detected in the spellbook.
- Configure the **Rotation** and **Buffs** tabs. Both lists are read from your character's current spellbook.
- On the **Buffs** tab, the dedicated **Armor** selector contains learned Frost Armor, Ice Armor, Mage Armor, and Molten Armor spells. Five separately numbered buff selectors contain the other learned mage buffs. Check **Cast in group** beneath Intellect buffs you want applied to nearby party or raid members. This works through both the Buff button and Rotation's **Auto Buff OOC** mode.
- **Amplify Magic** is maintained automatically by the main Rotation when learned; it does not need to occupy a Buff slot. Use its persistent target preference on the **Buffs** tab to choose your current friendly target, self, a class, or a group member saved with **Save selected player**. This works both in and out of combat, independently of **Auto Buff OOC**. A class preference cycles through nearby members of that class, and Amplify never spreads outside the chosen preference.
- Amplify Magic skips configured players who are offline, dead, phased, or in another instance. MageCore verifies the intended group target before casting, preventing a failed remote target from being redirected to you by auto-self-cast.
- Drag the Rotation icon from the window to an action bar.
- Drag **Guarded Ice Block** from the Rotation tab to an action bar for a one-button Ice Block that cannot be cancelled during its first second. After that guard expires, another press cancels Ice Block normally. Its script macro displays Ice Block's real cooldown sweep on supported default, pfUI, and Bartender-style action buttons.
- Drag **Arcane Explosion** from the Rotation tab to an action bar for a dedicated AoE button. It casts Arcane Explosion normally, but the same button immediately switches to and casts Arcane Surge whenever its reactive proc is available. Arcane Surge does not need to occupy one of the six Rotation slots for this button.
- Press that action button repeatedly to apply missing buffs and cast the first ready rotation spell.
- With the **Counterspell** toggle enabled, Rotation prioritizes Counterspell when your current enemy target is casting an interruptible spell.
- Enable **Healing Only** to ignore non-healing casts and reserve Counterspell for recognized healing spells.
- Enemy cast detection supports stock-compatible cast libraries and SuperWoW GUID-based casts used by pfUI and ShaguTweaks.
- Confirmed interrupts clear matching LunaUnitFrames castbars so Luna's cached enemy cast does not continue visually after Counterspell lands.
- **Auto Wards** enables or disables the complete feature with one click and works independently of PvP Mode. Rotation proactively maintains Frost Ward against hostile Shamans. It maintains Fire Ward against Warlocks and remembered Fire threats; **Mage/Warlock** mode additionally pre-wards against every hostile Mage. A ward must be learned, ready, affordable, and missing. Counterspell remains the higher priority.
- Enable **Nova Range** to give hostile nameplates a 3-pixel steady-red border at longer range and a double-thickness 6-pixel bright-green border inside Frost Nova range. MageCore reads the **Arctic Reach** spellbook rank and selects 10 yards at 0/2, 11 yards at 1/2, or 12 yards at 2/2. Exact coordinates are used when SuperWoW supplies them; otherwise the closest conservative Vanilla interaction-distance threshold is used. SuperWoW supports range detection for every visible nameplate; without it, the current target can change to the green state.
- Use **Nameplate Size** on the Info tab to give native and ShaguTweaks nameplates a fixed scale from 50% to 150% at every distance. Enable **Raised nameplates** to move the complete plate a little farther above the unit while keeping castbars and the Nova Range outline aligned.
- Enable **Sharp nameplate edges** to draw a thin, crisp outline around health bars. The thicker Nova Range outline appears over it when active.
- Enable **White target border** to draw a thin white outer border around the currently selected nameplate. A small gap keeps it visually separate from the Nova Range indicator.
- Enable **Red enemies / green team** on the Info tab to normalize hostile nameplate health bars to red and friendly/team health bars to green. Neutral creatures stay yellow when merely targeted and turn red once they are engaged in combat. Opposite-faction players stay yellow unless their actual PvP flag is enabled and the client allows you to attack them. MageCore uses pfUI/ShaguTweaks player identification so a newly seen unflagged player also becomes and remains yellow while untargeted.
- Use the separate **Show enemy nameplates** and **Show friendly nameplates** toggles on the Info tab to control each group independently. MageCore preserves and enforces both choices.
- Use **`/mc box on`** to show the draggable Rotation Monitor and **`/mc box off`** to hide it. All six configured rotation spells appear side by side with live cooldown/GCD sweeps and compact readiness labels. A bright-green bar marks the spell MageCore will choose next. Hover an icon for its mana cost, target range, reactive-proc state, and full monitor status. The monitor's visibility and position persist across reloads.

Put cooldown abilities (for example, Fire Blast) above your filler spell (for example, Frostbolt). The separate Buff icon creates a buff-only action button. The minimap icon can be dragged around the minimap.

The Rotation action-bar button displays the normal spell tooltip for the action MageCore currently plans to cast.

If the character knows **Find Minerals**, an out-of-combat Rotation press restores it whenever no tracking or a different tracking type is active.

The optional **Opener** is cast once against a new target while you are out of combat, after buff/group/food maintenance and before the normal rotation slots.

When **PvP Mode** is enabled and a living enemy is already targeted, Rotation skips buff, group, and conjured food/water maintenance. It goes directly to combat, using Rank 1 Frostbolt once after acquiring a new target when that enemy is not already slowed by a frost effect.

When the PvP override uses Rank 1 Frostbolt, MageCore displays a yellow notice in your local chat frame. This message is visible only to you.

While idle and out of combat with no enemy target, the action-bar icon previews the configured opener rather than Rotation Slot 1.

MageCore never uses a stopwatch fallback icon. Rotation retains the next ready, soonest-cooldown, opener, or configured rotation spell; Buff retains a configured buff icon.

Rotation presses do nothing while Blizzard, Evocation, or another protected channel is active. When **Arcane Surge** is configured in any Rotation slot, MageCore checks an Arcane Surge spell placed anywhere on the action bars for its reactive usability. If it is not on an action bar, MageCore falls back to tracking full and partial resists in the combat log. Surge receives priority only after a resist enables it, and a Rotation press can interrupt Arcane Missiles to consume the proc once the global cooldown permits the cast.

The MageRot icon dims whenever the currently displayed spell costs more mana than the mage currently has.

The MageRot icon is tinted red when its currently displayed spell is out of range, matching a native spell action button.

When **Cone of Cold** is configured in the rotation, MageCore casts it only while the current hostile target is within its Arctic Reach-adjusted range. Its range check allows for large creature hitboxes instead of relying only on center-to-center distance. Otherwise, Rotation skips it and uses the next ready spell.

The dynamic Rotation icon remains locked to the active spell while casting or channeling, then changes to the next action when the cast ends.

When no configured rotation spell is ready, the macro keeps the soonest-ready spell visible and displays its real cooldown sweep/countdown on Bartender2 or Blizzard action buttons.

Rotation skips configured spells known to be out of range. On clients that cannot query a spell's range directly, an out-of-range failure is remembered briefly so the next press proceeds to the following rotation slot.

Combat priority is mana-aware: unaffordable rotation spells are skipped using both the client power-availability flag and parsed spell costs. When none of the learned spells configured in the six Rotation slots can be afforded, MageCore falls back to **Shoot** with an equipped wand. It starts the wand through a native Shoot action slot when available and otherwise casts Shoot from the spellbook. A client "not enough mana" rejection also forces Shoot on the next press. Further Rotation presses do not toggle off an already-active wand attack.

When **Auto Buff OOC** is enabled, each press of the Rotation button applies the next missing configured buff while out of combat. During combat it skips buffs and uses attack spells. Turn Auto Buff off to make Rotation ignore buffs; the separate Buff button remains available for manual buffing.

Each configured group buff is applied to one eligible nearby party or raid member per press before MageCore moves on to the next missing buff.

Buff selection follows learned spell and active aura state rather than the legacy spellbook cooldown flag, which can incorrectly reject beneficial mage spells.

The spell lists refresh automatically after learning or training a spell. MageCore reads only the mage class tabs, leaving out General-tab actions, racial abilities, professions, passive abilities, and duplicate ranks. Because the Vanilla 1.12 client has no helpful/harmful spell classification API, MageCore separates learned mage spells using mage categories and spell-tooltip text. Select only one armor spell at a time because mage armors replace each other.

MageCore does not cast automatically; one key press performs one action, as required by the Vanilla/Turtle WoW client.
