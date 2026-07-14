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
11. [Adición a CORPUS_Architecture.md §3 — pedida y aplicada](#11-adición-a-corpus_architecturemd-3--pedida-y-aplicada)
12. [Checklist de cierre de bloque — completo](#12-checklist-de-cierre-de-bloque--completo)

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

Superficie a migrar (server): `ads_core.lua`, `ads_armor.lua`, `ads_limbs.lua`, `ads_scavenger.lua`, `ads_shields.lua`, `ads_shared.lua`. Client: `cl_ads.lua` (panel Options del spawnmenu Q legacy — convars globales), `cl_ads_shields.lua`, `cl_ads_browser.lua` (browser "ADS Configuration", 6 tabs). Toolgun: `ads_config.lua`.

Doc satélite: **`ADS_EnergyShields_Arquitectura.md` NO es autoritario al 100%** — es el diseño original, y el propio `ADS_2_0_Architecture_updated.md` §19 admite que se **elevó durante la implementación** ("zona-escudo que se resuelve antes de la placa física" → pool global por NPC, no zonal). El archivo satélite no estuvo disponible para re-chequear en el espacio de diseño donde se escribió esta sección (hoy sí se puede consultar: vive en `dev/legacy/AdvancedDamageSystem 2.0/docs/` — sigue sin ser autoritario, pero es legible). Confirmado en `ads_shields.lua` (`ShieldNPCs[npc]`, una entrada por NPC) que §19 sí quedó al día en ese punto puntual — pero no se asume que el resto de §19 esté igual de sincronizado con el código sin re-chequear.

**Consecuencia para la migración:** `Caliber_EnergyShields_Arquitectura.md` no se copia ciego de ningún doc existente (ni el satélite viejo, ni §19 tal cual). Se **reconcilia** contra el código real (`ads_shields.lua` + `cl_ads_shields.lua`) al momento de la migración — mismo principio "el código manda" ya establecido en `corpus_flujo_trabajo.txt` PASO 2 (precedente citado ahí: un doc que decía "pendiente" cuando el código ya estaba aplicado). Acá es el caso inverso — un doc de diseño que quedó atrás de un código que evolucionó — pero la regla es la misma.

**El legacy ADS queda intacto, congelado en `dev/legacy/AdvancedDamageSystem 2.0/`** — carpeta fuera de todos los repos git del workspace (no es un repo propio), con su nombre y namespace original (`ADS`), tag `v1.0`. Ningún fix futuro se retro-porta ahí; todo fix a partir de ahora es sobre Caliber.

---

## 3. Namespace: tabla única registrada

Choque de reglas a resolver: `CORPUS_Architecture.md` §6 exige un único global (`Corpus`), nada de globals sueltos por módulo — pero ADS usa `ADS.*` como global interno en todos sus archivos. Y §4 exige que Caliber exponga una superficie **angosta** (Limbs + eventos), no todo su interior.

**Solución:** una tabla registrada temprano, poblada por side-effect en cada archivo posterior. Todos los archivos cachean la misma referencia — en Lua las tablas son tipos por referencia, no hay copia.

**Cuándo se registra — el init NO aborta con `error()`.** Gmod ejecuta `lua/autorun/` en orden alfabético **fusionado entre addons**: `corpus_caliber_init.lua` ordena ANTES que `corpus_data.lua`/`corpus_registry.lua`, así que en una carga de mapa normal **`Corpus` todavía no existe** cuando corre el init. Un `error()` en file-scope no protege de nada — solo consigue que el módulo no arranque nunca (falla silenciosa de módulo, no crash del server). De ahí el patrón real: **sonda + boot diferido**. `AddCSLuaFile` queda en file-scope (no depende de Corpus); el registro y el manifest viven en `Boot()`, que corre inmediato si la sonda `CorpusListo()` pasa (lua refresh, carga tardía) o se difiere al hook `"Initialize"` — que corre en **ambos realms**, después de TODO `autorun` y antes de `InitPostEntity`, conservando las garantías: los tabs de UI llegan antes de `PopulateToolMenu`, los net strings antes de que conecte un cliente, y los hooks `InitPostEntity` de `core` antes de que la barrera dispare. Si tras `Initialize` sigue sin haber framework: **falla ruidosa por `MsgN`** — no `Corpus.Log`, porque Corpus no existe.

```lua
-- corpus_caliber_init.lua — único archivo en lua/autorun/ (ver §4)

-- AddCSLuaFile no depende de Corpus: se hace siempre en la carga de autorun, para
-- que el cliente reciba los archivos aunque el boot quede diferido (ver abajo).
if SERVER then
    for _, f in ipairs(SHARED)       do cs(f) end
    for _, f in ipairs(CLIENT_FILES) do cs(f) end
end

-- Hard-dep: Caliber depende de Corpus. No se asume que ya cargó; se detecta. La sonda
-- cubre las primitivas que los sub-archivos usan en file-scope (Data/Net/Log en server,
-- UI en client), no solo el registro.
local function CorpusListo()
    return Corpus ~= nil and Corpus.RegisterModule ~= nil and Corpus.Data ~= nil
        and Corpus.Net ~= nil and Corpus.Log ~= nil and (SERVER or Corpus.UI ~= nil)
end

local function Boot()
    Corpus.RegisterModule("caliber", {})   -- tabla VACÍA: la pueblan los sub-archivos by-ref
    -- ... include() del manifest, en orden explícito (§4) ...
    Corpus.Log("caliber", "cargado (" .. (SERVER and "server" or "client") .. ")")
end

if CorpusListo() then
    Boot()   -- lua refresh o carga tardía: el framework ya está
else
    hook.Add("Initialize", "corpus_caliber_boot", function()
        hook.Remove("Initialize", "corpus_caliber_boot")
        if CorpusListo() then
            Boot()
        else
            -- Sin el framework, el módulo no arranca (falla ruidoso, no silencioso).
            -- No se usa Corpus.Log aquí: Corpus no existe.
            MsgN("[Caliber] Corpus framework no encontrado. Verificar que el addon corpus/ esté instalado y montado.")
        end
    end)
end
```

La iface **nunca** va inline en el `RegisterModule`: se registra una tabla vacía y los sub-archivos la pueblan por side-effect. **Este es el patrón template para los otros cuatro módulos del ecosistema** — lo pagó Caliber en juego (ver `CHANGELOG.md`, sesión «Fix de arranque», 2026-07-09).

```lua
-- cualquier archivo posterior del módulo, ej. corpus_caliber_armor.lua
local CALIBER = Corpus.GetModule("caliber")

function CALIBER.SomeArmorFunction(...)
    -- ...
end
```

La superficie pública (§8) no es una tabla aparte — es el **subconjunto documentado** de la tabla registrada. El resto cuelga de la misma tabla pero queda off-contract por convención (ver §8), no por barrera técnica. Este patrón depende de un invariante del lado Corpus (el registro devuelve la **misma tabla por referencia**), hoy ya escrito como contrato duro en `CORPUS_Architecture.md` §3 y cumplido por `corpus_registry.lua` — ver §11.

---

## 4. Manifest de carga

ADS depende hoy de **orden alfabético implícito** — cita textual del propio código: `ads_limbs.lua` L2, *"Loaded after ads_core.lua (alphabetical: ads_core < ads_limbs)"*. Es frágil por diseño: se rompe en silencio el día que se agrega un archivo sin respetar la convención, y falla en runtime con `nil`, no en parse.

Se reemplaza por un **manifest explícito** de `include()` en el init, en orden estricto y documentado:

Los sub-archivos viven **fuera** de `lua/autorun/`, en `lua/corpus_caliber/<realm>/`: si estuvieran en `autorun/server|client` se auto-ejecutarían y duplicarían la carga, rompiendo el orden que este manifest existe para fijar. El init es el único loader; el toolgun queda en `stools/` (lo carga el sistema de `gmod_tool`, no el manifest).

```lua
-- corpus_caliber_init.lua
local SHARED = {
    "shared/corpus_caliber_shared.lua",
}
local SERVER_FILES = {
    "server/corpus_caliber_armor.lua",   -- antes que core: core.LoadConfig llama a
    "server/corpus_caliber_core.lua",    -- armor.LoadArmorData en file-scope
    "server/corpus_caliber_limbs.lua",
    "server/corpus_caliber_shields.lua",
    "server/corpus_caliber_scavenger.lua",
}
local CLIENT_FILES = {
    "client/corpus_caliber_shields_cl.lua",
    "client/corpus_caliber_browser.lua",
    "client/corpus_caliber_client_options.lua",
}

local function inc(rel) include("corpus_caliber/" .. rel) end
local function cs(rel)  AddCSLuaFile("corpus_caliber/" .. rel) end

-- ... dentro de Boot() (§3), después del RegisterModule:
if SERVER then
    for _, f in ipairs(SHARED)       do inc(f) end
    for _, f in ipairs(SERVER_FILES) do inc(f) end
else
    for _, f in ipairs(SHARED)       do inc(f) end
    for _, f in ipairs(CLIENT_FILES) do inc(f) end
end
```

El snippet es **ilustrativo del mecanismo**, no una transcripción literal del init — el archivo real intercala el `AddCSLuaFile` en file-scope y la sonda de Corpus (§3). Las rutas y el orden, en cambio, sí son los definitivos: se validaron contra las dependencias reales entre archivos, no se asumió ciego el orden alfabético anterior. La única dependencia dura de file-scope es `armor` antes que `core`; el resto solo se cruza en runtime con guardas (§5), así que su orden es el lógico (`core` → `limbs` → `shields` → `scavenger`).

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
| UI shell | Menú Q propio "ADS Configuration" (6 tabs: Armor / Limbs-WL / Weapons / Energy Shield / Scavenger / General) | `Corpus.UI.RegisterTab` | `Corpus.UI.RegisterTab("caliber", "Caliber", fn)` — los 6 tabs quedan como sub-tabs internos de esa entrada |
| Ready barrier | N/A — ADS era autocontenido, no lo necesitaba | `Corpus.OnReady` | No se usa en este bloque. Caliber es hoja en el grafo (§2 de `CORPUS_Architecture.md`). Primer consumo real: Block de Cortex, para wiring de soft-dep |
| Registro | Global `ADS.*` | `Corpus.RegisterModule` / `Corpus.GetModule` | Ver §3 |

---

## 7. Las 4 clases de rename

No es un solo find-replace. Son cuatro clases de literal/identificador con riesgo muy distinto:

**1. Identificadores Lua** — `ADS.` → `CALIBER.` (vía `local CALIBER = Corpus.GetModule("caliber")` por archivo). Mecánico, find-replace directo, bajo riesgo.

**2. Campos de entidad `ADS_*`** (underscore, no dot) — `npc.ADS_HP_Head`, `npc.ADS_VJ_Limping`, `npc.ADS_LastLimbHit`, `owner.ADS_ArmL_Dropped`, etc. → `Caliber_*`. **Riesgo alto.** No es lo mismo que la clase 1: un regex de `ADS.` no toca estos campos porque no hay punto sobre el global, son propiedades ad-hoc colgadas de la entidad. Son los más numerosos y cross-subsystem: si `core` queda leyendo `ent.Caliber_HP_Head` y `limbs` todavía escribe `ent.ADS_HP_Head`, el síntoma es `nil` silencioso — no un error de parse. Auditar aparte de la clase 1.

**3. Convar names** — `"ads_*"` (consola, user-facing) → `"caliber_*"`. Clean-slate ya decidido en §6 (persistencia): sin puente de compatibilidad con nombres viejos.

**4. Hook/timer tags** — strings únicos tipo `hook.Add(..., "ADS_Limbs_Spawn", ...)` → `"Caliber_Limbs_Spawn"`. Evita colisión de tag con otro módulo del ecosistema Corpus que use convención similar.

### Checklist de verificación (post-rename) — corrido y en verde

Las cuatro clases quedaron migradas; los greps se corrieron sobre `lua/` y dan **0**:

- [x] `grep -rn "ADS\."` → 0 resultados en código vivo
- [x] `grep -rn "ADS_"` → 0 resultados fuera de comentarios históricos explícitos ("migrado desde ADS 2.0")
- [x] `grep -rn "\"ads_"` → 0 resultados (convars, net strings, data paths)
- [x] Ningún archivo del repo referencia `data/ads/` (path viejo)

---

## 8. Contrato público

Superficie mínima expuesta de `CALIBER` (subconjunto documentado, el resto off-contract por convención): `HealLimbs` + lectura de pools de limbs. Eventos de daño/limb: **sin superficie de contrato** en este bloque — existe un `hook.Run("Caliber_LimbsUpdated", npc, reason)` heredado de ADS, **off-contract y sin consumidor** (ver §9.a).

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
--   CALIBER.Limbs.*                          -- vacío en Block 2: sin superficie de
--                                                contrato para eventos de daño/limb.
--                                                Existe hook.Run("Caliber_LimbsUpdated",
--                                                npc, reason), heredado de ADS, pero es
--                                                off-contract y sin consumidor (§9.a)
-- ============================================================
```

---

## 9. Deferrals explícitos

### 9.a — Eventos de daño/limb

No se diseñan a ciegas en este bloque, pero el choke point único **ya existe y YA EMITE**: `ApplyLimbDebuffs(npc, reason, dmginfo)` corre tanto en el path de daño (post-decremento de pool) como en **todos** los paths de heal, y cierra con `hook.Run("Caliber_LimbsUpdated", npc, reason or "damage")` (`corpus_caliber_limbs.lua:298`, heredado verbatim de `ads_limbs.lua:297`). Dispara con `reason ∈ spawn|damage|heal` y hoy **no tiene consumidor** en el ecosistema.

El trabajo pendiente, entonces, **no es agregar el emit** sino **enriquecer su payload** —hoy es `(npc, reason)`: sin zona, sin daño al pool, sin `dmginfo`— y recién ahí elevarlo a contrato (§8). Tal como está es un **aviso de refresh, no un evento de daño**.

`npc.Caliber_LastLimbHit` es un proto-evento pero **no es un bus**: es un stash one-shot, consumido y limpiado por `ScaleNPCDamage` en el mismo tick (hand-off a core). El punto de hook para eventos futuros es `ApplyLimbDebuffs`, no el stash.

### 9.b — Agnosticismo NPC/jugador de `Limbs`

`CORPUS_Architecture.md` §4 describe la `Limbs API` como agnóstica a si la entidad es NPC o jugador. Eso es **aspiracional** en este bloque: `HealLimbs` hoy es NPC-only (`npc.Caliber_HP_*`, chequeo `IsNPC()`). Se vuelve agnóstica recién cuando el pipeline de armadura de jugador (Block siguiente de Caliber) aterrice el lado jugador. Se anota para que §4 no se lea como cumplida post-migración — se cumple por diseño, NPC-only en práctica hasta entonces.

### 9.c — Boundary-debt: scavenger + FX

Ambos se quedan en Caliber en este bloque: scavenger está acoplado al drop de `Limbs`, FX al daño, y §7 de `CORPUS_Architecture.md` (migración mecánica, no reescritura) prohíbe re-homear nada en un pase de rename. Pero el comportamiento de scavenger-pickup (elegir target, animación de recogida, timing) huele a comportamiento NPC — territorio de Cortex.

**No se decide acá.** Queda flageado para revisar cuando se diseñe el scope de comportamiento de Cortex. Si en ese momento se confirma que es behavior, se re-homea entonces — no ahora.

---

## 10. Deuda heredada — viaja sin tocar

Ninguno de estos ítems se aborda en este bloque. Se re-registran en el debt de Caliber, exactamente como estaban en ADS:

- **Decal `Caliber_Ricochet` inerte** (Block FX) — aceptado por el autor. Requiere trabajo a nivel del pipeline de decals del engine HL2 (C++), fuera de alcance de un rename Lua.
- **`DNumSlider` en tab Limbs/WL** (post-rename: `corpus_caliber_browser.lua` ~L1360, en `BuildWLTab`) — no migrado al patrón de fila manual (`DPanel`+`DLabel`+`DSlider`+`DTextEntry`) que ya usan Armor tab, toolgun y Weapons tab. Viaja tal cual; se corrige si se vuelve a tocar esa parte del browser, no durante el rename.
- **Front 4 — doble mult de zona ARC9**: ARC9 aplica sus `BodyDamageMults` antes de `ScaleNPCDamage`, y el multiplicador de ADS los vuelve a escalar → miembros reciben ~50% menos daño del esperado. Diferido a Fase 2 en ADS; se hereda igual en Caliber.
- **Cache de hitgroups por modelo** — la silueta usa template humano fijo de 7 zonas, sin auto-grisado de zonas imposibles. Diferido a Fase 2 en ADS; se hereda igual.

---

## 11. Adición a `CORPUS_Architecture.md` §3 — pedida y aplicada

Este documento (Caliber) depende de un invariante del **framework**, no del módulo. Se pidió desde acá porque quien implementara las 6 primitivas de Corpus lo necesitaba explícito **antes** de escribir código, no como descubrimiento posterior al integrar Caliber:

> `Corpus.RegisterModule(name, iface)` y `Corpus.GetModule(name)` deben guardar y devolver la **misma tabla por referencia**, sin copia ni normalización. Todo el patrón de namespace de §3 de este documento depende de que sea así — si el registro alguna vez introduce un deep-copy defensivo, el patrón "tabla única poblada por side-effect" se cae en silencio.

**Ya está aplicado.** Las 6 primitivas están implementadas y el invariante quedó escrito como contrato duro en `CORPUS_Architecture.md` §3 —nota «Invariante del registro (contrato duro)», que cita de vuelta a §3 y §11 de este documento— y repetido en el comentario de cabecera de `corpus_registry.lua`, que lo cumple: `RegisterModule` guarda `iface` tal cual y `GetModule` la devuelve sin tocar.

Sigue siendo un invariante **distinto** del de `Corpus.Data.Save/Load` — esa primitiva sí normaliza el JSON al persistir (claves numéricas ↔ string): es otra primitiva con otro contrato, no se confunden.

---

## 12. Checklist de cierre de bloque — completo

**Block 2 cerrado.** Los nueve ítems se cumplieron; la verificación en juego (paridad vs. ADS 2.0 `v1.0`) la corrió el autor el **2026-07-09** y todo el `CHANGELOG.md` del repo quedó en `[APLICADO]`.

- [x] Corpus: 6 primitivas implementadas; invariante by-ref de §11 confirmado en `Corpus.RegisterModule`/`GetModule` (y escrito en `CORPUS_Architecture.md` §3)
- [x] Caliber: manifest de carga aplicado (§4); namespace convertido a tabla única registrada (§3)
- [x] Las 4 clases de rename verificadas — checklist de greps de §7 en 0
- [x] Contrato público documentado en el sitio de registro (§8) — bloque CONTRACT de `corpus_caliber_init.lua`
- [x] Deuda heredada re-registrada tal cual, sin tocar (§10)
- [x] `Caliber_EnergyShields_Arquitectura.md` publicado — reconciliado contra `ads_shields.lua`/`cl_ads_shields.lua`, no copiado ciego del satélite viejo ni de §19 sin re-chequear (§2)
- [x] Verificación en juego: paridad de comportamiento vs. ADS 2.0 `v1.0` — corrida por el autor el 2026-07-09 (cvars `caliber_*`, tab en el menú Q, sin problemas)
- [x] `CHANGELOG.md` de `corpus/` y `corpus-caliber/` actualizados
- [x] `caliber_estado.md` creado (primera vez que el repo recibe contenido real) y `corpus_estado.md` actualizado — Block 2 cerrado, próximo: pipeline de armadura de jugador (Block 3, §9.b)

---

*Rumbo / qué sigue → `corpus_roadmap.txt`. Metodología → `corpus_flujo_trabajo.txt`. Framework → `CORPUS_Architecture.md`.*
