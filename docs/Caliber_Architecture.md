# Caliber — Documento de Arquitectura

> **Uso de este documento:** Referencia autocontenida para sesiones futuras de planificación (Opus) e implementación (Claude Code). No se requiere el chat de diseño original.
>
> **Estado:** Block 2 de N (ver tabla de bloques en `CORPUS_Architecture.md` §9). Cubre la migración ADS 2.0 → Caliber. El pipeline de armadura de jugador (alcance nuevo, no cubierto por ADS) se documenta en Block 3, como sección nueva de este mismo archivo. Cortex queda fuera de este bloque — depende de la superficie de eventos daño/limb que Block 3 todavía no cierra (ver §9.a).
>
> **Estado vigente (foto de HOY)** → `caliber_estado.md` — léelo antes que este documento. **Metodología** → `corpus_flujo_trabajo.txt` (compartido, no se duplica acá). Índice operativo → `CLAUDE.md` de este repo.

---

## Índice

1. [Alcance de este bloque](#1-alcance-de-este-bloque)
2. [Snapshot congelado — fuente de la migración](#2-snapshot-congelado--fuente-de-la-migración)
3. [Namespace: tabla única registrada](#3-namespace-tabla-única-registrada)
4. [Manifest de carga](#4-manifest-de-carga)
5. [Ventana de carga — regla de invocación](#5-ventana-de-carga--regla-de-invocación)
6. [Mapeo primitiva por primitiva](#6-mapeo-primitiva-por-primitiva)
7. [Las 4 clases de rename](#7-las-4-clases-de-rename)
8. [Contrato público](#8-contrato-público)
9. [Deferrals explícitos](#9-deferrals-explícitos)
10. [Deuda heredada — viaja sin tocar](#10-deuda-heredada--viaja-sin-tocar)
11. [Adición requerida a CORPUS_Architecture.md §3](#11-adición-requerida-a-corpus_architecturemd-3)
12. [Checklist de cierre de bloque](#12-checklist-de-cierre-de-bloque)

---

## 1. Alcance de este bloque

**Es.** Rename mecánico de ADS 2.0 → Caliber: namespace, rutas de persistencia, convención de archivos, wiring sobre las 6 primitivas de Corpus. Se verifica por **paridad de comportamiento** contra el snapshot congelado (§2), no por revisión de diseño — el diseño de dominio (armor, limbs, shields, scavenger) ya está cerrado y probado en ADS.

**No es.**
- Reescritura ni mejora de ningún subsistema. Los principios de dominio ya fijados en ADS (EFT gana la jerarquía del extractor, resolver puro, armadura como pre-filtro delante de limbs) se preservan intactos.
- El pipeline de armadura de jugador — backend nuevo, Block 3 propio.
- Fix de ninguna deuda conocida (§10) — viaja tal cual.
- Diseño de la superficie de eventos daño/limb hacia Cortex/Coagulant — deferred, ver §9.a.

---

## 2. Snapshot congelado — fuente de la migración

Fuente: **ADS 2.0, tag `v1.0`**, verificado en juego por el autor (2026-07-08). Único punto no cerrado, aceptado como deuda consciente: el decal `ADS_Ricochet` inerte (Block FX) — no se resuelve en este bloque (ver §10).

Superficie a migrar (server): `ads_core.lua`, `ads_armor.lua`, `ads_limbs.lua`, `ads_scavenger.lua`, `ads_shields.lua`, `ads_shared.lua`. Client: `cl_ads.lua` (panel Options del spawnmenu Q legacy — convars globales), `cl_ads_shields.lua`, `cl_ads_browser.lua` (browser "ADS Configuration", 5 tabs). Toolgun: `ads_config.lua`.

Doc satélite: **`ADS_EnergyShields_Arquitectura.md` NO es autoritario al 100%** — es el diseño original, y el propio `ADS_2_0_Architecture_updated.md` §19 admite que se **elevó durante la implementación** ("zona-escudo que se resuelve antes de la placa física" → pool global por NPC, no zonal). El archivo satélite ni siquiera está disponible en este espacio de diseño para re-chequear. Confirmado en `ads_shields.lua` (`ShieldNPCs[npc]`, una entrada por NPC) que §19 sí quedó al día en ese punto puntual — pero no se asume que el resto de §19 esté igual de sincronizado con el código sin re-chequear.

**Consecuencia para la migración:** `Caliber_EnergyShields_Arquitectura.md` no se copia ciego de ningún doc existente (ni el satélite viejo, ni §19 tal cual). Se **reconcilia** contra el código real (`ads_shields.lua` + `cl_ads_shields.lua`) al momento de la migración — mismo principio "el código manda" ya establecido en `corpus_flujo_trabajo.txt` PASO 2 (precedente citado ahí: un doc que decía "pendiente" cuando el código ya estaba aplicado). Acá es el caso inverso — un doc de diseño que quedó atrás de un código que evolucionó — pero la regla es la misma.

**El legacy ADS queda intacto en su propio repo, congelado en `v1.0`.** Ningún fix futuro se retro-porta ahí; todo fix a partir de ahora es sobre Caliber.

---

## 3. Namespace: tabla única registrada

Choque de reglas a resolver: `CORPUS_Architecture.md` §6 exige un único global (`Corpus`), nada de globals sueltos por módulo — pero ADS usa `ADS.*` como global interno en todos sus archivos. Y §4 exige que Caliber exponga una superficie **angosta** (Limbs + eventos), no todo su interior.

**Solución:** una tabla registrada temprano, poblada por side-effect en cada archivo posterior. Todos los archivos cachean la misma referencia — en Lua las tablas son tipos por referencia, no hay copia.

```lua
-- corpus_caliber_init.lua — primer archivo del manifest (ver §4)
if not Corpus then
    error("[Caliber] Corpus framework no encontrado. Verificar orden de carga o instalación.")
    return
end

local C = {}
Corpus.RegisterModule("caliber", C)
```

```lua
-- cualquier archivo posterior del módulo, ej. corpus_caliber_armor.lua
local CALIBER = Corpus.GetModule("caliber")

function CALIBER.SomeArmorFunction(...)
    -- ...
end
```

La superficie pública (§8) no es una tabla aparte — es el **subconjunto documentado** de `C`. El resto cuelga de la misma tabla pero queda off-contract por convención (ver §8), no por barrera técnica. Este patrón depende de un invariante del lado Corpus que hoy no está escrito en ningún doc — ver §11.

---

## 4. Manifest de carga

ADS depende hoy de **orden alfabético implícito** — cita textual del propio código: `ads_limbs.lua` L2, *"Loaded after ads_core.lua (alphabetical: ads_core < ads_limbs)"*. Es frágil por diseño: se rompe en silencio el día que se agrega un archivo sin respetar la convención, y falla en runtime con `nil`, no en parse.

Se reemplaza por un **manifest explícito** de `include()` en el init, en orden estricto y documentado:

```lua
-- corpus_caliber_init.lua
if SERVER then
    include("corpus_caliber_shared.lua")
    include("corpus_caliber_armor.lua")
    include("corpus_caliber_core.lua")
    include("corpus_caliber_limbs.lua")
    include("corpus_caliber_shields.lua")
    include("corpus_caliber_scavenger.lua")
end
```

El orden exacto de este manifest lo confirma quien ejecuta la migración (Claude Code) contra las dependencias reales entre archivos — no se asume ciego el orden alfabético anterior, se valida función por función qué archivo necesita qué. El ejemplo de arriba es ilustrativo del mecanismo, no la secuencia final.

---

## 5. Ventana de carga — regla de invocación

Con manifest síncrono ordenado, un archivo puede invocar funciones de archivos **anteriores** en file-scope (ya poblados). La regla real es más angosta: **nunca invocar hacia adelante** en file-scope.

ADS ya respeta esto en la práctica: los cruces entre subsistemas van dentro de hooks/timers con guarda de existencia —

```lua
if ADS.MarkWeaponAsDroppedBy then
    ADS.MarkWeaponAsDroppedBy(dropped, npc)
end
```

Ese guard sobrevive el rename intacto (`CALIBER.MarkWeaponAsDroppedBy`). No es solo protección de orden de carga — cubre también el caso de instalación parcial (subsistema deshabilitado o archivo ausente), así que se mantiene aun con el manifest ya fijo.

---

## 6. Mapeo primitiva por primitiva

| Subsistema ADS | Antes | Primitiva Corpus | Después |
|---|---|---|---|
| Net strings | `util.AddNetworkString("ads_x")` | `Corpus.Net.Register` | `Corpus.Net.Register("caliber", "x")` → `"corpus_caliber_x"` |
| Persistencia | `data/ads/ads_config.json` (`whitelist`, `blacklist`, `armor`, `curated_weapons`, `ammo_fallback`) | `Corpus.Data.Save/Load` | `Corpus.Data.Save("caliber", "config", tbl)` → `data/corpus/caliber/config.json`. **Clean-slate**: sin importador desde el JSON viejo, el usuario reconfigura. No vale la pena un migrador one-time para un addon que recién nace. |
| Log | `print("[ADS] ...")` | `Corpus.Log` | `Corpus.Log("caliber", ...)` → `"[Corpus:caliber] ..."` |
| UI shell | Menú Q propio "ADS Configuration" (5 tabs: Armor / Limbs-WL / Weapons / Scavenger / General) | `Corpus.UI.RegisterTab` | `Corpus.UI.RegisterTab("caliber", "Caliber", fn)` — los 5 tabs quedan como sub-tabs internos de esa entrada |
| Ready barrier | N/A — ADS era autocontenido, no lo necesitaba | `Corpus.OnReady` | No se usa en este bloque. Caliber es hoja en el grafo (§2 de `CORPUS_Architecture.md`). Primer consumo real: Block de Cortex, para wiring de soft-dep |
| Registro | Global `ADS.*` | `Corpus.RegisterModule` / `Corpus.GetModule` | Ver §3 |

---

## 7. Las 4 clases de rename

No es un solo find-replace. Son cuatro clases de literal/identificador con riesgo muy distinto:

**1. Identificadores Lua** — `ADS.` → `CALIBER.` (vía `local CALIBER = Corpus.GetModule("caliber")` por archivo). Mecánico, find-replace directo, bajo riesgo.

**2. Campos de entidad `ADS_*`** (underscore, no dot) — `npc.ADS_HP_Head`, `npc.ADS_VJ_Limping`, `npc.ADS_LastLimbHit`, `owner.ADS_ArmL_Dropped`, etc. → `Caliber_*`. **Riesgo alto.** No es lo mismo que la clase 1: un regex de `ADS.` no toca estos campos porque no hay punto sobre el global, son propiedades ad-hoc colgadas de la entidad. Son los más numerosos y cross-subsystem: si `core` queda leyendo `ent.Caliber_HP_Head` y `limbs` todavía escribe `ent.ADS_HP_Head`, el síntoma es `nil` silencioso — no un error de parse. Auditar aparte de la clase 1.

**3. Convar names** — `"ads_*"` (consola, user-facing) → `"caliber_*"`. Clean-slate ya decidido en §6 (persistencia): sin puente de compatibilidad con nombres viejos.

**4. Hook/timer tags** — strings únicos tipo `hook.Add(..., "ADS_Limbs_Spawn", ...)` → `"Caliber_Limbs_Spawn"`. Evita colisión de tag con otro módulo del ecosistema Corpus que use convención similar.

### Checklist de verificación (post-rename, antes de dar el bloque por cerrado)

- [ ] `grep -rn "ADS\."` → 0 resultados en código vivo
- [ ] `grep -rn "ADS_"` → 0 resultados fuera de comentarios históricos explícitos ("migrado desde ADS 2.0")
- [ ] `grep -rn "\"ads_"` → 0 resultados (convars, net strings, data paths)
- [ ] Ningún archivo del repo referencia `data/ads/` (path viejo)

---

## 8. Contrato público

Superficie mínima expuesta de `CALIBER` (subconjunto documentado, el resto off-contract por convención): `HealLimbs` + lectura de pools de limbs. Eventos de daño/limb: vacío en este bloque (ver §9.a).

Se documenta con un bloque de comentario en el sitio de registro — **no** con prefijo `_` en campos internos. El prefijo obligaría a clasificar cada campo público/interno *dentro* de un pase que tiene que ser mecánico, y rompería la uniformidad del find-replace de la clase 1 (§7).

```lua
-- corpus_caliber_init.lua
-- ============================================================
-- CONTRATO PÚBLICO DE CALIBER (consumido por otros módulos vía
-- Corpus.GetModule("caliber")). Todo lo demás colgado de esta
-- tabla es interno — no se consume desde fuera de este repo por
-- convención, no por barrera técnica.
--
--   CALIBER.HealLimbs(npc, amount, target)   -- medic mods, etc.
--   CALIBER.Limbs.*                          -- vacío en Block 2; eventos
--                                                daño/limb aterrizan cuando
--                                                Cortex/Coagulant lo consuman
-- ============================================================
```

---

## 9. Deferrals explícitos

### 9.a — Eventos de daño/limb

No se diseñan a ciegas en este bloque. Confirmado leyendo `ads_limbs.lua`: ya existe un **choke point único** — `ApplyLimbDebuffs(npc, reason, dmginfo)`, invocado tanto en el path de daño (post-decremento de pool) como en **todos** los paths de heal. Ahí cuelga el emit cuando el módulo consumidor (Cortex/Coagulant) lo necesite — es una función nueva colgando de un punto ya aislado, no un refactor.

`ADS_LastLimbHit` es un proto-evento pero **no es un bus**: es un stash one-shot, consumido y limpiado por `ScaleNPCDamage` en el mismo tick (hand-off a core). El punto de hook para eventos futuros es `ApplyLimbDebuffs`, no el stash.

### 9.b — Agnosticismo NPC/jugador de `Limbs`

`CORPUS_Architecture.md` §4 describe la `Limbs API` como agnóstica a si la entidad es NPC o jugador. Eso es **aspiracional** en este bloque: `HealLimbs` hoy es NPC-only (`npc.ADS_HP_*`, chequeo `IsNPC()`). Se vuelve agnóstica recién cuando el pipeline de armadura de jugador (Block siguiente de Caliber) aterrice el lado jugador. Se anota para que §4 no se lea como cumplida post-migración — se cumple por diseño, NPC-only en práctica hasta entonces.

### 9.c — Boundary-debt: scavenger + FX

Ambos se quedan en Caliber en este bloque: scavenger está acoplado al drop de `Limbs`, FX al daño, y §7 de `CORPUS_Architecture.md` (migración mecánica, no reescritura) prohíbe re-homear nada en un pase de rename. Pero el comportamiento de scavenger-pickup (elegir target, animación de recogida, timing) huele a comportamiento NPC — territorio de Cortex.

**No se decide acá.** Queda flageado para revisar cuando se diseñe el scope de comportamiento de Cortex. Si en ese momento se confirma que es behavior, se re-homea entonces — no ahora.

---

## 10. Deuda heredada — viaja sin tocar

Ninguno de estos ítems se aborda en este bloque. Se re-registran en el debt de Caliber, exactamente como estaban en ADS:

- **Decal `ADS_Ricochet` inerte** (Block FX) — aceptado por el autor. Requiere trabajo a nivel del pipeline de decals del engine HL2 (C++), fuera de alcance de un rename Lua.
- **`DNumSlider` en tab Limbs/WL** (`cl_ads_browser.lua` ~L1246) — no migrado al patrón de fila manual (`DPanel`+`DLabel`+`DSlider`+`DTextEntry`) que ya usan Armor tab, toolgun y Weapons tab. Viaja tal cual; se corrige si se vuelve a tocar esa parte del browser, no durante el rename.
- **Front 4 — doble mult de zona ARC9**: ARC9 aplica sus `BodyDamageMults` antes de `ScaleNPCDamage`, y el multiplicador de ADS los vuelve a escalar → miembros reciben ~50% menos daño del esperado. Diferido a Fase 2 en ADS; se hereda igual en Caliber.
- **Cache de hitgroups por modelo** — la silueta usa template humano fijo de 7 zonas, sin auto-grisado de zonas imposibles. Diferido a Fase 2 en ADS; se hereda igual.

---

## 11. Adición requerida a `CORPUS_Architecture.md` §3

Este documento (Caliber) depende de un invariante del **framework**, no del módulo — corresponde anotarlo acá porque quien implemente las 6 primitivas de Corpus (mismo Block, ver CC prompt #1) lo necesita explícito antes de escribir código, no como descubrimiento posterior al integrar Caliber:

> `Corpus.RegisterModule(name, iface)` y `Corpus.GetModule(name)` deben guardar y devolver la **misma tabla por referencia**, sin copia ni normalización. Todo el patrón de namespace de §3 de este documento depende de que sea así — si el registro alguna vez introduce un deep-copy defensivo, el patrón "tabla única poblada por side-effect" se cae en silencio.

Este invariante se agrega como nota a `CORPUS_Architecture.md` §3 cuando se implemente esa primitiva, distinto del invariante de `Corpus.Data.Save/Load` — ese sí normaliza el JSON al persistir (claves numéricas ↔ string), y esa es una primitiva distinta con un contrato distinto.

---

## 12. Checklist de cierre de bloque

- [ ] Corpus: 6 primitivas implementadas; invariante by-ref de §11 confirmado en `Corpus.RegisterModule`/`GetModule`
- [ ] Caliber: manifest de carga aplicado (§4); namespace convertido a tabla única registrada (§3)
- [ ] Las 4 clases de rename verificadas — checklist de greps de §7 en 0
- [ ] Contrato público documentado en el sitio de registro (§8)
- [ ] Deuda heredada re-registrada tal cual, sin tocar (§10)
- [ ] `Caliber_EnergyShields_Arquitectura.md` publicado — reconciliado contra `ads_shields.lua`/`cl_ads_shields.lua`, no copiado ciego del satélite viejo ni de §19 sin re-chequear (§2)
- [ ] Verificación en juego: paridad de comportamiento vs. ADS 2.0 `v1.0` — mismo test que ya hizo el autor sobre ADS, repetido sobre Caliber
- [ ] `CHANGELOG.md` de `corpus/` y `corpus-caliber/` actualizados
- [ ] `caliber_estado.md` creado (primera vez que el repo recibe contenido real) y `corpus_estado.md` actualizado — Block 2 cerrado, próximo: pipeline de armadura de jugador

---

*Rumbo / qué sigue → `corpus_roadmap.txt`. Metodología → `corpus_flujo_trabajo.txt`. Framework → `CORPUS_Architecture.md`.*
