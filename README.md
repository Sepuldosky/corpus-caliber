# Caliber

Módulo de **combate** del ecosistema [Corpus](https://github.com/Sepuldosky/corpus) para
**Garry's Mod**: armadura zonal estilo Escape from Tarkov, escudos de energía, HP por extremidad y
penetración balística — para NPCs (y, a futuro, jugador). Addon independiente que **hard-depende** de
Corpus (la única dependencia dura del ecosistema) y detecta a los demás módulos en runtime, nunca los
asume.

Nació de la migración de **Advanced Damage System 2.0** (`v1.0`, congelado) a un módulo de Corpus:
rename de namespace + wiring sobre las 6 primitivas del framework, sin reescritura de dominio.

## Características

- **Blindaje por zona (hitgroup)**, no por entidad entera; cobertura asimétrica y durabilidad de placa.
- **Penetración estilo EFT** modulada por durabilidad y clase de armadura; daño romo al bloquear, daño
  reducido al perforar.
- **HP por extremidad** (head/arms/legs) con debuffs, stun y drop de arma.
- **Escudos de energía** por NPC (pool global recargable delante de la armadura zonal).
- **Scavenger**: los NPCs recogen armas del suelo.
- **Browser visual de configuración** por-NPC + tab en el menú Q (Utilities → Corpus → Caliber).

## Requisitos

- **Corpus** (dependencia dura — sin él, Caliber no arranca).
- Opcional: **ARC9** (datos EFT en vivo vía `GetProcessedValue`), **VJ Base**, **TFA Base**. Caliber
  degrada con gracia si no están.

## Documentación

- [`docs/Caliber_Architecture.md`](docs/Caliber_Architecture.md) — arquitectura del módulo (la migración).
- [`docs/Caliber_EnergyShields_Arquitectura.md`](docs/Caliber_EnergyShields_Arquitectura.md) — subsistema de escudos.
- [`docs/caliber_estado.md`](docs/caliber_estado.md) · [`docs/caliber_roadmap.txt`](docs/caliber_roadmap.txt) · [`docs/CHANGELOG.md`](docs/CHANGELOG.md) — docs vivos.
- [`CLAUDE.md`](CLAUDE.md) — guía para asistencia con Claude Code.

## Créditos

El subsistema de **Escudos de energía** reutiliza concepto, efectos y sonidos de dos mods deprecados
(2022), **con permiso de sus autores**. El wiring de red se reescribió (los originales eran
single-target sobre la armadura HL2 del jugador; Caliber es multi-NPC):

- **Speedy Von Gofast** — [*Halo Energy Shield*](https://steamcommunity.com/sharedfiles/filedetails/?id=2804418818):
  burbuja de energía, partículas (`spdy_*`, set colorable `spdy_halo_3_custom_*`) y sonidos de
  hit/colapso/recarga. Los nombres de sistema y rutas están horneados en los `.pcf`, por eso los
  archivos conservan sus nombres/rutas originales.
- **sora1d** — [*Goofy Armor Effect*](https://steamcommunity.com/sharedfiles/filedetails/?id=3305537845):
  base del **HEV Charge Shield** (FX y sonidos de negación de daño que escalan con la carga, chispazo
  cerca de agotarse, FX de depleción — built-in del engine).
