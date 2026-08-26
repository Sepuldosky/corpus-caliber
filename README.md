<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/caliber_lockup_dark.svg">
    <img src="assets/caliber_lockup_light.svg" width="200" alt="Caliber">
  </picture>
</p>

# Caliber

**Combat** module of the [Corpus](https://github.com/Sepuldosky/corpus) ecosystem for
**Garry's Mod**: Escape from Tarkov-style zonal armor, energy shields, per-limb HP and
ballistic penetration — for NPCs (and, in the future, the player). Independent addon that
**hard-depends** on Corpus (the ecosystem's only hard dependency) and detects the other
modules at runtime, never assumes them.

Born from the migration of **Advanced Damage System 2.0** (`v1.0`, frozen) into a Corpus
module: namespace rename + wiring over the framework's 6 primitives, with no domain rewrite.

## Features

- **Zonal armor (hitgroup)**, not whole-entity; asymmetric coverage and plate durability.
- **EFT-style penetration** modulated by durability and armor class; blunt damage on block,
  reduced damage on penetration.
- **Per-limb HP** (head/arms/legs) with debuffs, stun, and weapon drop.
- **Energy shields** per NPC (rechargeable global pool in front of the zonal armor).
- **Scavenger**: NPCs pick up weapons from the ground.
- **Visual configuration browser** per-NPC + tab in the Q menu (Utilities → Corpus → Caliber).

## Requirements

- **Corpus** (hard dependency — without it, Caliber won't start).
- Optional: **ARC9** (live EFT data via `GetProcessedValue`), **VJ Base**, **TFA Base**. Caliber
  degrades gracefully if they're absent.

## Documentation

- [`docs/Caliber_Architecture.md`](docs/Caliber_Architecture.md) — module architecture (the migration).
- [`docs/Caliber_EnergyShields_Arquitectura.md`](docs/Caliber_EnergyShields_Arquitectura.md) — shields subsystem.
- [`docs/caliber_estado.md`](docs/caliber_estado.md) · [`docs/caliber_roadmap.txt`](docs/caliber_roadmap.txt) · [`docs/CHANGELOG.md`](docs/CHANGELOG.md) — living docs.
- [`CLAUDE.md`](CLAUDE.md) — guide for assistance with Claude Code.

## Credits

The **Energy Shields** subsystem reuses the concept, effects and sounds of two deprecated mods
(2022), **with permission from their authors**. The network wiring was rewritten (the originals
were single-target over the player's HL2 armor; Caliber is multi-NPC):

- **Speedy Von Gofast** — [*Halo Energy Shield*](https://steamcommunity.com/sharedfiles/filedetails/?id=2804418818):
  energy bubble, particles (`spdy_*`, colorable set `spdy_halo_3_custom_*`) and hit/collapse/recharge
  sounds. The system names and paths are baked into the `.pcf` files, so the files keep their
  original names/paths.
- **sora1d** — [*Goofy Armor Effect*](https://steamcommunity.com/sharedfiles/filedetails/?id=3305537845):
  base of the **HEV Charge Shield** (damage-negation FX and sounds that scale with charge, a spark
  near depletion, depletion FX — built into the engine).
