# Party Companions

Play WotLK with a party of your own characters. Summon up to four other
characters from your account as companions. They level with you, wear the gear
you hand them from your bags, fight with you using simple tactics, and can be
dressed at a Transmogrifier from a retail-style wardrobe.

Two parts:

- `mod-party-companions/`: an AzerothCore module (C++).
- `addon/PartyCompanions/`: a WoW 3.3.5a client addon for the interface.

## Requirements

- AzerothCore WotLK with the Playerbots fork of the core.
- [mod-playerbots](https://github.com/mod-playerbots/mod-playerbots). Companions are playerbot altbots, so
  `Playerbots.AllowAccountBots = 1` is required.
- [mod-transmog](https://github.com/azerothcore/mod-transmog) with `Transmogrification.UseCollectionSystem = 1`.
  The wardrobe uses its account-wide collection and its Transmogrifier NPC (entry 190010).

Recommended playerbots settings for companions:

```
Playerbots.AutoPickTalentsForPlayerControlledBots = 1
Playerbots.AutoEquipUpgradeLoot = 0
```

## Install

Server:

1. Copy `mod-party-companions` into `modules/`, then re-run CMake and rebuild the worldserver.
2. Copy `mod-party-companions/conf/party_companions.conf.dist` to `etc/modules/party_companions.conf` in your server installation and adjust the settings.
3. Restart the worldserver after installing the rebuilt binary and configuration.

Client:

1. Copy `addon/PartyCompanions` into `World of Warcraft/Interface/AddOns/`.
2. Restart the game.

## Features

- **Summon and dismiss:** your own same-faction characters (main plus up to four).
- **Level lock:** companions are raised to your level and earn no XP of their own. You keep full solo kill XP.
- **Shared bags and purse:** loot and gold your companions receive come to you. Their own quest drops stay with them.
- **Gear:** drag items from your bags onto a companion's slots to equip them. Right-click a slot to take the item back.
- **Character sheet integration:** the Party tab opens inside the Character window. It has the same slot layout, model and stat dropdowns (Base Stats, Melee, Ranged, Spell, Defenses) as your own sheet.
- **Tactics:**
  - Stances: Assist (default), Defend, Aggressive and Passive.
  - Orders: Follow, Hold, Attack, Tank, Come and Rebuff, for the whole party or one companion.
- **Role-aware engagement:** the tank opens a fight, healers keep healing, and damage dealers focus your target.
- **Simple life:** companions drop quest chatter, spread out naturally, and sit down while you idle. They catch up when left behind, and get back up after a short timer once a fight ends.
- **Wardrobe:**
  - Every look that fits a slot is shown as a 3D preview; looks you have not collected yet appear locked.
  - Shows how many looks you have collected for the slot.
  - Five outfits per character, wearable anywhere.
  - Looks remembered per slot are applied automatically to new gear.
  - New looks can only be applied at a Transmogrifier.
- **Repair party:** a button at repair merchants repairs every companion's gear.

## Configuration (`party_companions.conf`)

| Setting | Default | Meaning |
|---|---|---|
| `PartyManager.Enable` | 1 | Turn the module on or off. |
| `PartyManager.MaxCompanions` | 4 | Companions at once (1 to 4). |
| `PartyManager.LevelLock` | 1 | Companions follow your level and earn no XP. |
| `PartyManager.FullSoloXP` | 1 | Kills give you solo XP while companions are grouped with you. |
| `PartyManager.SharedBags` | 1 | Companion loot goes to your bags. |
| `PartyManager.SharedPurse` | 1 | Companion gold goes to you. |
| `PartyManager.TransmogRange` | 15 | Yards to a Transmogrifier needed to apply looks. |
| `PartyManager.ReviveDelay` | 30 | Seconds a fallen companion stays down. |

## Notes

- **Addon messaging:** the addon talks to the server through addon whispers to yourself (prefix `PMGR`), so
  `AddonChannel` must stay enabled in `worldserver.conf`.
- **Transmog after moving gear:** mod-transmog clears an item's appearance when it changes owner. Re-apply looks after moving gear between characters.

## License

- **Server module:** GNU GPL v2, matching the core and mod-playerbots it builds against.
- **Client addon:** MIT.

## Compatibility and support

- Requires the **Playerbots fork** of AzerothCore; stock AzerothCore alone is not supported.
- Keep this release's server module and client addon together: their `PMGR` message protocol must match.
- The repository root is a release bundle. Copy only its `mod-party-companions` directory into the server's `modules/`; do not place the entire bundle there.
- If upgrading from the development addon named `PartyManager`, disable that older addon before enabling `PartyCompanions` so both interfaces do not load together.
- This module requires no separate SQL migration. Existing character settings and mod-transmog collection storage are used.
- This first public release is version **1.0.0**. Back up character databases and test on your own server before production use.

Report issues at https://github.com/walsin98/party-companions/issues. Include your core, mod-playerbots and mod-transmog commit hashes, the addon version, reproduction steps and relevant errors. Remove credentials and personal information from reports.
