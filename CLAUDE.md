# CLAUDE.md

Guía para trabajar en **Caliber** — el módulo de combate del ecosistema Corpus (addon GLua para Garry's Mod). Léela antes de tocar código o docs de este repo.

## Qué es

Caliber es el módulo de **combate** del ecosistema Corpus: armadura zonal, escudos de energía, HP de extremidades y penetración balística — para NPCs (y, a futuro, jugador). Es un addon Gmod independiente con su propio git, que **hard-depende** de Corpus (la única dependencia dura del ecosistema) y de nadie más. Detecta a otros módulos en runtime vía `Corpus.GetModule`/`Corpus.HasModule`, nunca los asume.

Este repo nació de la **migración de ADS 2.0** (`AdvancedDamageSystem 2.0`, tag `v1.0`, congelado en `dev/legacy/`) a un módulo de Corpus: rename mecánico de namespace + wiring sobre las 6 primitivas de Corpus, **sin reescritura de dominio**. El diseño de la migración → [`docs/Caliber_Architecture.md`](docs/Caliber_Architecture.md) (Block 2). El framework y el grafo de dependencias → `../corpus/docs/CORPUS_Architecture.md`.

**Regla cardinal:** los principios de dominio ya fijados en ADS se preservan intactos — EFT gana la jerarquía del extractor, resolver puro, armadura como pre-filtro delante de limbs, escudo como pre-filtro delante de la armadura. Un fix a partir de ahora se hace sobre Caliber, nunca se retro-porta al legacy congelado.

**Regla cardinal:** nada de lógica de dominio sube a Corpus. El pool de HP de extremidades, la math de armadura, los hitgroups, las curvas — todo vive **acá** (su dueño), y otros módulos lo consumen vía el registro de Corpus. Ver §3-4 de `CORPUS_Architecture.md`.

## Docs del proyecto — jerarquía de lectura

Antes de tocar código o diseño, lee en este orden (los tres primeros son **docs vivos**):

1. **Estado de HOY** → [`docs/caliber_estado.md`](docs/caliber_estado.md). Foto del AHORA, ≤1 pantalla. **Léelo ANTES** que la arquitectura.
2. **Rumbo** → [`docs/caliber_roadmap.txt`](docs/caliber_roadmap.txt). Qué sigue y en qué orden.
3. **Historial de parches** → [`docs/CHANGELOG.md`](docs/CHANGELOG.md). `[PENDIENTE]`/`[APLICADO YYYY-MM-DD]`, nunca se borra ni renumera.
4. **Metodología de trabajo** → [`../corpus/docs/corpus_flujo_trabajo.txt`](../corpus/docs/corpus_flujo_trabajo.txt). **Doc canónico compartido** por todo el ecosistema — no se duplica acá.
5. **Arquitectura del módulo** → [`docs/Caliber_Architecture.md`](docs/Caliber_Architecture.md) (Block 2: la migración). Doc particular autocontenido; la sección resumen + link vive en `CORPUS_Architecture.md` §7/§9.
6. **Arquitectura del subsistema de escudos** → [`docs/Caliber_EnergyShields_Arquitectura.md`](docs/Caliber_EnergyShields_Arquitectura.md). Doc particular, **reconciliado contra el código real** (no copiado del diseño original de ADS).
7. **Convenciones de commit** → [`docs/caliber_convenciones_commits.txt`](docs/caliber_convenciones_commits.txt). Alcances específicos de **este** repo.

## Idioma

Comentarios y mensajes de commit en **español**; los `<tipo>` de commit van en inglés (ver convenciones). Si el código existente mezcla estilos (herencia de ADS), iguala el del archivo que estás editando — no impongas uno nuevo.

## El workspace multi-repo

Este repo (`corpus-caliber/`) es una de las **siete** raíces git del workspace `corpus.code-workspace`. La raíz `corpus/` es el framework del que todos hard-dependen; otras cuatro (`corpus-cortex/`, `corpus-coagulant/`, `corpus-craving/`, `corpus-cargo/`) son módulos hermanos. La séptima, `corpus-stalker/`, no es un módulo sino el **addon de contenido** de S.T.A.L.K.E.R. (anomalías, artefactos, PDA, detectores, defs de NPC e ítems): consumidor puro — detecta a los módulos en runtime y nada de su contenido sube acá.

Hay además una carpeta `dev/` en el workspace que **no es un repo** (fuera de todos los git, nunca se publica). Ahí vive la fuente de la migración: `dev/legacy/AdvancedDamageSystem 2.0/` (tag `v1.0`, congelado — nunca se le retro-porta nada).

## Mapa de archivos

Un **manifest de carga explícito** (`corpus_caliber_init.lua`, único archivo en `lua/autorun/`) reemplaza el orden alfabético implícito de autorun que usaba ADS. El init registra el módulo, declara el contrato público, y hace `include()` de los sub-archivos en orden determinista — por eso viven **fuera** de `lua/autorun/` (en `lua/corpus_caliber/<realm>/`): si estuvieran en `autorun/server|client` se auto-ejecutarían y duplicarían la carga rompiendo el orden. El toolgun vive en `stools/` (lo carga el sistema de gmod_tool, no el manifest). Ver §3-§5 de la arquitectura.

| Archivo | Realm | Rol |
|---|---|---|
| [`lua/autorun/corpus_caliber_init.lua`](lua/autorun/corpus_caliber_init.lua) | shared | Entry + registro del módulo (`caliber`) + **bloque CONTRACT** + manifest de `include()` |
| [`lua/corpus_caliber/shared/corpus_caliber_shared.lua`](lua/corpus_caliber/shared/corpus_caliber_shared.lua) | shared | Decal `Caliber_Ricochet` (inerte, deuda §10) + partículas de escudo (assets Halo) |
| [`lua/corpus_caliber/server/corpus_caliber_armor.lua`](lua/corpus_caliber/server/corpus_caliber_armor.lua) | server | **Resolver puro**: `ExtractBulletData` (EFT-tuple) + `ResolveArmor` + perfiles/NWvars. Sin hooks |
| [`lua/corpus_caliber/server/corpus_caliber_core.lua`](lua/corpus_caliber/server/corpus_caliber_core.lua) | server | Pipeline `ScaleNPCDamage`, config (`Corpus.Data`), whitelist, net (`Corpus.Net`), Block FX, compat ARC9/VJ/Visceral |
| [`lua/corpus_caliber/server/corpus_caliber_limbs.lua`](lua/corpus_caliber/server/corpus_caliber_limbs.lua) | server | Pools de HP por extremidad, debuffs (accuracy/speed/stun/drop), `HealLimbs` (**contrato público**) |
| [`lua/corpus_caliber/server/corpus_caliber_shields.lua`](lua/corpus_caliber/server/corpus_caliber_shields.lua) | server | Escudos: **pool global por NPC**, registry de tipos, motor de daño + regen (un solo Think) |
| [`lua/corpus_caliber/server/corpus_caliber_scavenger.lua`](lua/corpus_caliber/server/corpus_caliber_scavenger.lua) | server | Recolección de armas por NPC (acoplada al drop de limbs) |
| [`lua/corpus_caliber/client/corpus_caliber_shields_cl.lua`](lua/corpus_caliber/client/corpus_caliber_shields_cl.lua) | client | FX de escudo (burbuja bonemerge + partículas) vía NWVars + net PVS |
| [`lua/corpus_caliber/client/corpus_caliber_browser.lua`](lua/corpus_caliber/client/corpus_caliber_browser.lua) | client | DFrame de configuración por-NPC (6 sub-tabs); se abre por `caliber_browser` |
| [`lua/corpus_caliber/client/corpus_caliber_client_options.lua`](lua/corpus_caliber/client/corpus_caliber_client_options.lua) | client | Tab único `Corpus.UI.RegisterTab("caliber","Caliber",…)` (ajustes convar apilados + botón al browser) |
| [`lua/weapons/gmod_tool/stools/corpus_caliber_config.lua`](lua/weapons/gmod_tool/stools/corpus_caliber_config.lua) | toolgun | Debug: M1 aplicar armadura/limbs efímeros, M2 copiar, R inspect |

## Contratos que no debes romper

1. **Namespace: tabla única registrada.** Cada archivo abre con `local CALIBER = Corpus.GetModule("caliber")` (el init la registró antes vía `Corpus.RegisterModule`). **Ningún archivo declara un global `ADS`, `Caliber` ni `CALIBER` suelto** — ni tablas auxiliares globales (el browser y los FX de escudo usan file-locals, no globals). Depende del invariante by-ref del registro de Corpus (§3, §11 de la arquitectura).
2. **Detección, nunca asunción.** Ningún archivo asume orden de mount; el hard-dep (Corpus) se detecta en el init (falla ruidoso si falta). Los cruces entre subsistemas van en hooks/timers con guarda de existencia (`if CALIBER.X then`).
3. **Persistencia namespaced.** `Corpus.Data.Save/Load("caliber", key, tbl)` → `data/corpus/caliber/<key>.json`. Dos keys: `config` (whitelist/blacklist/armor/curated_weapons/ammo_fallback) y `scav_weights`. **Clean-slate**: sin importador del JSON viejo de ADS.
4. **Net namespaced.** Todos los mensajes se registran con `Corpus.Net.Register("caliber", msg)` → `"corpus_caliber_<msg>"` (en `core`). `net.Start`/`net.Receive` usan ese nombre completo.
5. **UI vía la primitiva.** Una sola entrada en el menú Q: `Corpus.UI.RegisterTab("caliber", "Caliber", fn)` (Utilities → Corpus → Caliber). El browser por-NPC se abre por botón/concommand, no como menú propio.
6. **Log vía la primitiva.** Toda salida de consola va por `Corpus.Log("caliber", ...)` → prefijo `[Corpus:caliber]`.
7. **Contrato público mínimo.** Solo `CALIBER.HealLimbs` (y a futuro `CALIBER.Limbs.*` + eventos de daño/limb) es superficie pública. El resto cuelga de la tabla pero es off-contract **por convención**, documentado en el bloque CONTRACT de `corpus_caliber_init.lua` (§8).
8. **Prefijo de archivo por módulo:** `corpus_caliber_*.lua` — evita colisión cuando los siete addons están montados a la vez.

## Deuda heredada — viaja sin tocar (§10 de la arquitectura)

No se aborda en este bloque; migra con el **mismo comportamiento (bugueado)** que tenía en ADS:
- Decal `Caliber_Ricochet` **inerte** (Block FX) — requiere trabajo del pipeline de decals del engine HL2 (C++), fuera de alcance de un rename Lua.
- `DNumSlider` en tab Limbs/WL del browser — no migrado al patrón de fila manual que usan los otros tabs.
- **Front 4 — doble mult de zona ARC9**: ARC9 aplica `BodyDamageMults` antes de `ScaleNPCDamage` y el mult de Caliber los re-escala → miembros reciben ~50% menos daño del esperado.
- **Cache de hitgroups por modelo**: silueta con template humano fijo de 7 zonas, sin auto-grisado de zonas imposibles.

## Verificación

No hay test runner automatizado (es un addon GMod) — el patrón es el de ADS/Kontrol: cargar el mapa, confirmar en consola/juego, no asumir. Ver `../corpus/docs/corpus_flujo_trabajo.txt` §1 (Paso 4). El criterio de aceptación de la migración es **paridad de comportamiento** contra ADS 2.0 `v1.0` (VJ Base + ARC9 Darsu): armor zonal, limbs, scavenger, escudos, sound/Block FX, tab Weapons, toolgun M1/M2/Reload. Cualquier diferencia es bug de la migración, no de diseño. Comandos de consola de debug (`caliber_shield_give/clear/status`, `caliber_scavenger_*`, `caliber_debug_pick`) y el toolgun de debug quedan como en ADS.

Al cerrar un cambio con superficie de runtime: refresca [`docs/caliber_estado.md`](docs/caliber_estado.md) en sitio y actualiza [`docs/CHANGELOG.md`](docs/CHANGELOG.md) (`[PENDIENTE]` → `[APLICADO YYYY-MM-DD]`, sin borrar ni renumerar).

## Git / commits

Sigue [`docs/caliber_convenciones_commits.txt`](docs/caliber_convenciones_commits.txt): `<tipo>(<alcance>): <descripción>` — tipo en inglés, descripción en español, minúscula inicial, sin punto final, imperativo. **Tipos** (§2): `feat`, `fix`, `refactor`, `docs`, `chore`, `test`. **Alcances** de este repo (§3, el doc manda): `armor`, `core`, `limbs`, `shields`, `scavenger`, `browser`, `config`, `docs`. Ojo: `chore` **no** es un alcance sino un tipo — el ejemplo §4.2 del doc es `chore(config): añade el manifest de carga`.

**Este repo está publicado en GitHub** (`github.com/Sepuldosky/corpus-caliber`, público, remote `origin` cableado). Ya lleva commits — la migración del Block 2 está pusheada y el repo está **al día con `origin/main`**. No hagas commit ni push salvo que se pida explícitamente.

**No agregues el trailer `Co-Authored-By: Claude` (ni ninguna atribución de co-autoría a Claude/Anthropic) en los mensajes de commit.** Esto sobreescribe el comportamiento por defecto del harness.
