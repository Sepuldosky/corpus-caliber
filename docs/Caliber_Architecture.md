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
13. [Block 3 — el contrato de datos Cargo ↔ Caliber](#13-block-3--el-contrato-de-datos-cargo--caliber)

---

## 1. Alcance de este bloque

**Es.** Rename mecánico de ADS 2.0 → Caliber: namespace, rutas de persistencia, convención de archivos, wiring sobre las 6 primitivas de Corpus. Se verifica por **paridad de comportamiento** contra el snapshot congelado (§2), no por revisión de diseño — el diseño de dominio (armor, limbs, shields, scavenger) ya está cerrado y probado en ADS.

**No es.**
- Reescritura ni mejora de ningún subsistema. Los principios de dominio ya fijados en ADS (EFT gana la jerarquía del extractor, resolver puro, y la cadena completa del pipeline: **escudo como pre-filtro delante de la armadura — CAL-13 —, armadura delante de limbs**: Hit → escudo → armadura → limbs) se preservan intactos.
- El pipeline de armadura de jugador — backend nuevo, Block 3 propio.
- Fix de ninguna deuda conocida (§10) — viaja tal cual.
- Diseño de la superficie de eventos daño/limb hacia Cortex/Coagulant — deferred, ver §9.a.

---

## 2. Snapshot congelado — fuente de la migración

Fuente: **ADS 2.0, tag `v1.0`**, verificado en juego por el autor (2026-07-08). Único punto no cerrado, aceptado como deuda consciente: el decal `ADS_Ricochet` inerte (Block FX) — no se resuelve en este bloque (ver §10).

Superficie a migrar (server): `ads_core.lua`, `ads_armor.lua`, `ads_limbs.lua`, `ads_scavenger.lua`, `ads_shields.lua`, `ads_shared.lua`. Client: `cl_ads.lua` (panel Options del spawnmenu Q legacy — convars globales), `cl_ads_shields.lua`, `cl_ads_browser.lua` (browser "ADS Configuration", 6 tabs). Toolgun: `ads_config.lua`.

Doc satélite: **`ADS_EnergyShields_Arquitectura.md` NO es autoritario al 100%** — es el diseño original, y el propio `ADS_2_0_Architecture_updated.md` §19 admite que se **elevó durante la implementación** ("zona-escudo que se resuelve antes de la placa física" → pool global por NPC, no zonal). El archivo satélite no estuvo disponible para re-chequear en el espacio de diseño donde se escribió esta sección (hoy sí se puede consultar: vive en `dev/legacy/AdvancedDamageSystem 2.0/docs/` — sigue sin ser autoritario, pero es legible). Confirmado en `ads_shields.lua` (`ShieldNPCs[npc]`, una entrada por NPC) que §19 sí quedó al día en ese punto puntual — pero no se asume que el resto de §19 esté igual de sincronizado con el código sin re-chequear.

**Consecuencia para la migración:** `Caliber_EnergyShields_Arquitectura.md` no se copia ciego de ningún doc existente (ni el satélite viejo, ni §19 tal cual). Se **reconcilia** contra el código real (`ads_shields.lua` + `cl_ads_shields.lua`) al momento de la migración — mismo principio "el código manda" ya establecido en `corpus_flujo_trabajo.txt` PASO 2 (precedente citado ahí: un doc que decía "pendiente" cuando el código ya estaba aplicado). Acá es el caso inverso — un doc de diseño que quedó atrás de un código que evolucionó — pero la regla es la misma.

**CAL-11 — El legacy ADS queda intacto, congelado en `dev/legacy/AdvancedDamageSystem 2.0/`** — carpeta fuera de todos los repos git del workspace (no es un repo propio), con su nombre y namespace original (`ADS`), tag `v1.0`. Ningún fix futuro se retro-porta ahí; todo fix a partir de ahora es sobre Caliber.

---

## 3. Namespace: tabla única registrada

Choque de reglas a resolver: `CORPUS_Architecture.md` §6 exige un único global (`Corpus`), nada de globals sueltos por módulo — pero ADS usa `ADS.*` como global interno en todos sus archivos. Y §4 exige que Caliber exponga una superficie **angosta** (Limbs + eventos), no todo su interior.

**Solución:** una tabla registrada temprano, poblada por side-effect en cada archivo posterior. Todos los archivos cachean la misma referencia — en Lua las tablas son tipos por referencia, no hay copia.

**Cuándo se registra (CAL-1) — el init NO aborta con `error()`.** Gmod ejecuta `lua/autorun/` en orden alfabético **fusionado entre addons**: `corpus_caliber_init.lua` ordena ANTES que `corpus_data.lua`/`corpus_registry.lua`, así que en una carga de mapa normal **`Corpus` todavía no existe** cuando corre el init. Un `error()` en file-scope no protege de nada — solo consigue que el módulo no arranque nunca (falla silenciosa de módulo, no crash del server). De ahí el patrón real: **sonda + boot diferido**. **(CAL-2)** `AddCSLuaFile` queda en file-scope (no depende de Corpus); el registro y el manifest viven en `Boot()`, que corre inmediato si la sonda `CorpusListo()` pasa (lua refresh, carga tardía) o se difiere al hook `"Initialize"` — que corre en **ambos realms**, después de TODO `autorun` y antes de `InitPostEntity`, conservando las garantías: los tabs de UI llegan antes de `PopulateToolMenu`, los net strings antes de que conecte un cliente, y los hooks `InitPostEntity` de `core` antes de que la barrera dispare. **(CAL-4)** Si tras `Initialize` sigue sin haber framework: **falla ruidosa por `MsgN`** — no `Corpus.Log`, porque Corpus no existe.

```lua
-- corpus_caliber_init.lua — único archivo en lua/autorun/ (ver §4)

-- AddCSLuaFile no depende de Corpus: se hace siempre en la carga de autorun, para
-- que el cliente reciba los archivos aunque el boot quede diferido (ver abajo).
if SERVER then
    for _, f in ipairs(SHARED)       do cs(f) end
    for _, f in ipairs(CLIENT_FILES) do cs(f) end
end

-- Hard-dep: Caliber depende de Corpus. No se asume que ya cargó; se detecta. (CAL-3) La
-- sonda cubre las primitivas que los sub-archivos usan en file-scope (Data/Net/Log en
-- server, UI en client), no solo el registro.
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

**CAL-5 —** La iface **nunca** va inline en el `RegisterModule`: se registra una tabla vacía y los sub-archivos la pueblan por side-effect. **Este es el patrón template para los otros cuatro módulos del ecosistema** — lo pagó Caliber en juego (ver `CHANGELOG.md`, sesión «Fix de arranque», 2026-07-09).

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

**CAL-7 —** Se reemplaza por un **manifest explícito** de `include()` en el init, en orden estricto y documentado:

**CAL-6 —** Los sub-archivos viven **fuera** de `lua/autorun/`, en `lua/corpus_caliber/<realm>/`: si estuvieran en `autorun/server|client` se auto-ejecutarían y duplicarían la carga, rompiendo el orden que este manifest existe para fijar. El init es el único loader; el toolgun queda en `stools/` (lo carga el sistema de `gmod_tool`, no el manifest).

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

Con manifest síncrono ordenado, un archivo puede invocar funciones de archivos **anteriores** en file-scope (ya poblados). La regla real es más angosta (CAL-8): **nunca invocar hacia adelante** en file-scope.

ADS ya respeta esto en la práctica: los cruces entre subsistemas van dentro de hooks/timers con guarda de existencia —

```lua
if ADS.MarkWeaponAsDroppedBy then
    ADS.MarkWeaponAsDroppedBy(dropped, npc)
end
```

Ese guard sobrevive el rename intacto (`CALIBER.MarkWeaponAsDroppedBy`). **(CAL-9)** No es solo protección de orden de carga — cubre también el caso de instalación parcial (subsistema deshabilitado o archivo ausente), así que se mantiene aun con el manifest ya fijo.

---

## 6. Mapeo primitiva por primitiva

| Subsistema ADS | Antes | Primitiva Corpus | Después |
|---|---|---|---|
| Net strings | `util.AddNetworkString("ads_x")` | `Corpus.Net.Register` | `Corpus.Net.Register("caliber", "x")` → `"corpus_caliber_x"` |
| Persistencia | `data/ads/ads_config.json` (`whitelist`, `blacklist`, `armor`, `curated_weapons`, `ammo_fallback`) | `Corpus.Data.Save/Load` | `Corpus.Data.Save("caliber", "config", tbl)` → `data/corpus/caliber/config.json`. Segunda key: `scav_weights` (pesos del scavenger; net `corpus_caliber_save_scav_weight` / `request_scav_weights`). **Clean-slate**: sin importador desde el JSON viejo, el usuario reconfigura. No vale la pena un migrador one-time para un addon que recién nace. |
| Log | `print("[ADS] ...")` | `Corpus.Log` | `Corpus.Log("caliber", ...)` → `"[Corpus:caliber] ..."` |
| UI shell | Menú Q propio "ADS Configuration" (6 tabs: Armor / Limbs-WL / Weapons / Energy Shield / Scavenger / General) | `Corpus.UI.RegisterTab` | `Corpus.UI.RegisterTab("caliber", "Caliber", fn)` — la entrada del menú Q apila los 4 paneles de convars (Armor/Limbs/Shields/Scavenger) + el botón que abre el **browser por-NPC** (concommand `caliber_browser`), y es en ese browser donde viven los 6 sub-tabs |
| Ready barrier | N/A — ADS era autocontenido, no lo necesitaba | `Corpus.OnReady` | No se usa en este bloque. Caliber es hoja en el grafo (§2 de `CORPUS_Architecture.md`). El primer consumo real lo pagó **Cargo en el Block 1**, y hoy lo usan también **Coagulant** y **Craving**; Caliber lo tomará cuando deje de ser hoja en el grafo |
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

**Residual declarado (5.ª clase, fuera del alcance del rename):** los **paths de assets** conservan la carpeta `ads/` — `sound/ads/*.wav` (`core`, `shields`) y `materials/ads/mat_*` (`browser`). Renombrarlos exige mover los assets y re-referenciar cada ruta, no un find-replace de Lua; queda anotado como residual conocido, no como rename pendiente.

---

## 8. Contrato público

Superficie mínima expuesta de `CALIBER` (subconjunto documentado, el resto off-contract por convención): **solo `HealLimbs`** — lo único bajo contrato hoy (CAL-12). Los pools de limbs (`npc.Caliber_HP_*`) son el dominio sobre el que `HealLimbs` opera, NO una superficie de lectura contratada: son campos NPC-only internos que pueden renombrarse sin romper contrato. `CALIBER.Limbs.*` está **vacío en Block 2** (sin superficie de contrato). Eventos de daño/limb: **sin superficie de contrato** en este bloque — existe un `hook.Run("Caliber_LimbsUpdated", npc, reason)` heredado de ADS, **off-contract y sin consumidor** (ver §9.a).

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

**(CAL-22)** `CORPUS_Architecture.md` §4 describe la `Limbs API` como agnóstica a si la entidad es NPC o jugador. Eso es **aspiracional** en este bloque: `HealLimbs` hoy es NPC-only (`npc.Caliber_HP_*`, chequeo `IsNPC()`). Se vuelve agnóstica recién cuando el pipeline de armadura de jugador (Block siguiente de Caliber) aterrice el lado jugador. Se anota para que §4 no se lea como cumplida post-migración — se cumple por diseño, NPC-only en práctica hasta entonces.

### 9.c — Boundary-debt: scavenger + FX

Ambos se quedan en Caliber en este bloque: scavenger está acoplado al drop de `Limbs`, FX al daño, y §7 de `CORPUS_Architecture.md` (migración mecánica, no reescritura) prohíbe re-homear nada en un pase de rename. Pero el comportamiento de scavenger-pickup (elegir target, animación de recogida, timing) huele a comportamiento NPC — territorio de Cortex.

**No se decide acá.** Queda flageado para revisar cuando se diseñe el scope de comportamiento de Cortex. Si en ese momento se confirma que es behavior, se re-homea entonces — no ahora.

---

## 10. Deuda heredada — viaja sin tocar

**CAL-21 —** Ninguno de estos ítems se aborda en este bloque. Se re-registran en el debt de Caliber, exactamente como estaban en ADS:

- **Decal `Caliber_Ricochet` inerte** (Block FX) — aceptado por el autor. Requiere trabajo a nivel del pipeline de decals del engine HL2 (C++), fuera de alcance de un rename Lua.
- **`DNumSlider` en tab Limbs/WL** (post-rename: `corpus_caliber_browser.lua` ~L1360, en `BuildWLTab`) — no migrado al patrón de fila manual (`DPanel`+`DLabel`+`DSlider`+`DTextEntry`) que ya usan Armor tab, toolgun y Weapons tab. Viaja tal cual; se corrige si se vuelve a tocar esa parte del browser, no durante el rename.
- **Front 4 — doble mult de zona ARC9**: ARC9 aplica sus `BodyDamageMults` antes de `ScaleNPCDamage`, y el multiplicador de ADS los vuelve a escalar → miembros reciben ~50% menos daño del esperado. Diferido a Fase 2 en ADS; se hereda igual en Caliber.
- **Cache de hitgroups por modelo** — la silueta usa template humano fijo de 7 zonas, sin auto-grisado de zonas imposibles. Diferido a Fase 2 en ADS; se hereda igual.

---

## 11. Adición a `CORPUS_Architecture.md` §3 — pedida y aplicada

Este documento (Caliber) depende de un invariante del **framework**, no del módulo. Se pidió desde acá porque quien implementara las 6 primitivas de Corpus lo necesitaba explícito **antes** de escribir código, no como descubrimiento posterior al integrar Caliber:

> (cita COR-7 — su sede es `CORPUS_Architecture.md` §3) `Corpus.RegisterModule(name, iface)` y `Corpus.GetModule(name)` deben guardar y devolver la **misma tabla por referencia**, sin copia ni normalización. Todo el patrón de namespace de §3 de este documento depende de que sea así — si el registro alguna vez introduce un deep-copy defensivo, el patrón "tabla única poblada por side-effect" se cae en silencio.

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

## 13. Block 3 — el contrato de datos Cargo ↔ Caliber

Sección **autocontenida**: el diseño del pipeline de armadura de jugador, votado por el
autor el 2026-08-22 y bajado acá el 2026-08-23. Reemplaza al bloque *"LO VOTADO EL
2026-08-22"* de [`caliber_roadmap.txt`](caliber_roadmap.txt) `[1]`, que se borró al
escribir esto — el roadmap es intención, la sede es este documento.

**Lo que esta sección NO es:** la implementación. El paso 2 del tramo (el mapeo del pool)
y el paso 3 (la indirección hitgroup → slot) todavía no están escritos. Acá está el
contrato que los dos tienen que respetar.

### 13.0 La constante medida — y por qué cambia el diseño

Todo lo que sigue cuelga de un número que **se midió en juego el 2026-08-22** (planilla
`dev/checks/caliber-b3-tramo0.html`, sección **J**) y que hasta ese día era una cita del
engine de HL2 y no una medición sobre este juego. La cita era **correcta en su primera
mitad y falsa en la segunda**:

| daño 100, vía bala | vida | pool |
|---|---:|---:|
| con pool de sobra (100 de armadura) | −20 | **−80** |
| con pool escaso (10 de armadura) | −90 | −10 (a cero) |
| sin pool | −100 | 0 |

`ARMOR_RATIO` sigue en 0,2, pero **`ARMOR_BONUS` acá es 1,0 y no 0,5**: un punto de
armadura absorbe **exactamente un punto de daño**. La fila del medio cae en la *otra*
rama del `if` del engine y da el número que el álgebra predice, que es lo que la vuelve
una medición y no una coincidencia.

**Por qué importa para el diseño, y no sólo para el balance:** `ply:Armor()` y los puntos
de escudo de Caliber **ya están en la misma unidad**. No hay factor de conversión que
inventar entre el pool del engine y `CALIBER.ShieldTypes`. Lo que parecía una
contradicción de escalas —el tipo `hev` con `max_hp = 50` contra un `ply:Armor()` que
topa en 100— **no lo es**: son 50 puntos de daño absorbidos contra 100, o sea una perilla
de balance, no un problema de unidades.

**Y el reparto NO es indiferente al tipo de daño:** bala, melee y explosión dan los tres
0,8 al pool; **`DMG_FALL` no lo toca** — la caída se lleva la vida entera con la armadura
intacta. Es el gemelo exacto de lo que `BYPASS_TYPES` ya marca para el melee del lado
escudo, y el paso 2 tiene que replicarlo: si no, la caída pega distinto según cuánto
escudo tengas, que es el mismo defecto que `BYPASS_TYPES` existe para evitar.

> **Lo que sigue sin medirse:** el escalado de hitgroup sobre el jugador. Se sabe por
> lectura del árbol que en el jugador el 2,0× de cabeza y el 0,25× de miembros **no son
> del engine** — los aplica `GM:ScalePlayerDamage` del gamemode base, en Lua
> (`gamemodes/base/gamemode/player.lua`). Es un caso **distinto** del lado NPC, donde
> `caliber_engine_hitgroup_compensation` cancela un escalado nativo que corre *después*
> del hook. Si la medición lo confirma, **esa compensación no se le aplica al jugador**.
> Fila `J4` de la planilla, pendiente de re-corrida.

### 13.1 Quién inicia — **CAL-24**

**El proveedor del perfil lo decide la PRESENCIA de Cargo, no el inventario del jugador.**
Con Cargo montado, **Cargo empuja** el perfil a Caliber al equipar y al desequipar; la
vía SUIT queda **apagada** aunque el jugador ande desnudo. Sin Cargo, el SUIT de HL2
habilita el sistema completo. **Un solo proveedor, por construcción.**

Si el proveedor se colgara del *inventario* en vez de la *presencia*, desnudarse
regalaría la armadura del traje, y el flip-flop sería **silencioso** porque las dos vías
escriben las mismas NWvars. Un bug que no imprime nada y que sólo se nota perdiendo una
pelea.

**El empuje, no la pregunta.** Cargo ya difunde `Corpus_Cargo_EquipChanged`
(`Cargo_Architecture.md` §4, **CRG-62**) y esa señal ya tiene la puerta que este contrato
necesita: **`slotId = nil` significa "se re-aplicó el set entero"** (`Inventory.RegiveEquipped`),
que es **la puerta del respawn**. Existe precisamente para que un oyente con estado de
jugador no tenga que enganchar `PlayerLoadout` y apostar al orden de hooks — el bug que
Quick Loadouts ya le costó a Cargo. Caliber es exactamente ese oyente, así que **no se
inventa señal nueva**: se consume la que ya está.

⚠ **Las puertas son CINCO, no cuatro** (`Cargo_Architecture.md` §4): `Equip`, `Unequip`,
`SubSlotAttach`, `SubSlotDetach` y **`DropEquipped`, que NO pasa por `Unequip`**. Un
oyente que cubra cuatro se ve idéntico a uno que cubre cinco.

### 13.2 Qué cruza — **CAL-25**

**Cargo manda el ÍTEM; Caliber traduce.** No al revés.

La razón es de dominio y no de comodidad: el perfil que Caliber consume hoy es
`{ zones = { ["1".."7"] = { class, dur_max, material } }, fallback_generic }`, y `class`,
`dur_max` y la tabla de materiales (que fija `coefDestruc` y el blunt) **son de Caliber**.
Si Cargo armara el perfil, tendría que conocerlos, y la tabla de materiales pasaría a
tener dos lectores que se desincronizan.

**`dur_max` y `condition` no colisionan porque son tipos distintos:**

- **`condition`** (0–100) es **ESTADO**, y es **de Cargo** — precio, split de stacks,
  reparación, desarme.
- **`dur_max`** es la **ESCALA en puntos** contra la que resta el `armorDamage` de la
  munición, y es **dominio de Caliber** (misma tabla que ya fija `coefDestruc` y blunt
  por material).
- **Puente:** `durActual = dur_max × condition / 100`.

⚠ **Una trampa que el árbol ya tiene puesta:** `InitArmorNWvars`
(`corpus_caliber_armor.lua`) escribe hoy `Caliber_Armor_Dur_<hg> = z.dur_max` —
*"durActual arranca en max"*. Con un perfil que viene de Cargo eso está **mal por
defecto**: una armadura usada al 40 % entraría al mundo como nueva, sin un solo error.
El traductor tiene que aplicar el puente **antes** de escribir las NWvars.

### 13.3 El claim de hitgroups — sede en CARGO (**CRG-77**)

**Un hitgroup tiene UN SOLO DUEÑO.** Cada ítem declara qué hitgroups reclama; el **slot
da el default** (Head → 1, Body → 2..7) y el chequeo **al equipar** rechaza un segundo
ítem que reclame uno ya tomado.

La sede es **Cargo** y no Caliber porque es el único lado que puede *rechazar* la acción:
el claim se valida en el equip, que es un flujo de inventario. Caliber recibe un perfil ya
consistente y no arbitra nada.

Un traje cerrado que reclame la cabeza es **LEGAL**, y bloquea el slot Head mientras esté
puesto: la trampa se vuelve **mecánica** en vez de una regla escrita que alguien tiene que
recordar. En la UI, **grisar las zonas que el slot no permite** — es el mismo mecanismo
que la deuda heredada de §10 (*"sin auto-grisado de zonas imposibles"*): **una pieza paga
las dos**, y se paga en el paso 4, no antes.

**Depende del paso 3.** Hoy la durabilidad de Caliber vive **por hitgroup**
(`Caliber_Armor_Dur_<hg>`, 8 slots independientes 0–7) y las `condition_zones` de Cargo
son **cuatro** (`{ torso, stomach, arms, legs }` en el chaleco dev). Un chaleco tiene UN
panel de brazos, no dos. La indirección **hitgroup → slot de zona** es el único cambio
estructural del tramo, y sin ella Cargo no puede expresar sus `condition_zones`.

⚠ **Y el vocabulario de Cargo todavía no cierra:** sus `condition_zones` usan `"torso"`,
que **COA-8/COA-7 mataron**, y colapsan izquierda y derecha. El vocabulario compartido son
**los hitgroups del engine** — Coagulant también los consume. Todo lo demás son etiquetas
de presentación.

### 13.4 La escritura de vuelta de `condition` — sede en CARGO (**CRG-78**)

**El punto más frágil del contrato, porque hay una carrera.** Caliber descuenta
durabilidad en el hit; Cargo es el dueño del número.

**`condition` es la ÚNICA fuente de verdad ALMACENADA.** `durActual` es **derivado y
volátil**: vive en NWvars mientras el ítem está puesto y **no se persiste jamás**. Un
escritor por campo, sin doble estado que se desincronice.

**Cuándo se escribe de vuelta: al DESEQUIPAR, y en un tick perezoso mientras está puesto.
Nunca por hit.**

- **Por hit** es lo que la carrera prohíbe: un hit escribe `rec`, el mismo tick puede
  traer un `SubSlotDetach` o un `DropEquipped`, y las dos escrituras pisan el mismo
  campo. Es exactamente la forma del defecto que Cargo ya pagó en el espejo del pool de
  munición.
- **Sólo al desequipar** pierde el estado si el jugador se desconecta o muere con el
  chaleco puesto — la persistencia de Cargo guarda el `rec`, y el `rec` tendría el
  `condition` de hace media hora.
- **El tick perezoso resuelve las dos**: el desgaste acumulado baja a `condition`
  cada N segundos *y* en el desequipar, y el valor persistido nunca está más viejo que N.

⚠ **La eyección obligatoria manda igual** (**CRG-9**): al destruir o reemplazar un
contenedor con sub-slots ocupados, las placas y el exoshield se eyectan **antes**. Un
generador de escudo no se pierde como efecto colateral de cambiarse el chaleco.

### 13.5 El exoshield — **CAL-26**

El sub-slot `accessory` del chaleco ya existe con filtro `category:exoshield`
(`corpus_cargo_dev.lua`), comentado en el código de Cargo como *"the Caliber Block 3
attachment point"*. **No se inventa un sistema: se le enchufa el que ya está.**

**Un exoshield NOMBRA un tipo del registry de Caliber, y opcionalmente lo escala.** El
registry (`CALIBER.ShieldTypes`) es de Caliber; el def de Cargo declara `shield_type` (una
clave del registry — `hev` ya existe, con `items/suitcharge1.wav` y
`items/suitchargeok1.wav`, todo built-in del engine) y, si quiere, overrides numéricos
sobre los `defaults` de ese tipo (`max_hp`, `recharge_delay`, `recharge_rate`).

Que sea **una clave y no una tabla suelta** es lo que evita que cada ítem de Cargo
invente su propio escudo: los sonidos, el color y los FX viven en el registry, y un
exoshield nuevo hereda todo sin tocar Caliber.

**La escala ya no es un problema** (§13.0): pool y `ply:Armor()` están en la misma unidad.
`hev` a 50 significa *absorbe 50 puntos de daño*, contra los 100 que el pool del engine
tolera. Es una decisión de balance y se calibra en juego.

⚠ **El escudo de Caliber es NO-OVERFLOW** — `ProcessShield` hace `di:SetDamage(0)` cuando
absorbe **y también cuando revienta** — y el pool del engine hace lo contrario: gotea
siempre el 0,2 y, al agotarse, deja pasar el resto. **Dos filosofías opuestas sobre el
mismo número**, y reconciliarlas es el paso 2.

**El charger y las baterías recargan el ESCUDO, no la armadura**, cuando Cargo está
montado. Cargo ya tiene **dos** dominios de reparación cerrados y sin solapamiento
(`Workbench_Arquitectura.md` §4, **CRG-54**: banco = mantenimiento profundo, placa =
parche rápido de campo). Un charger gratis e ilimitado sobre la armadura sería un
**tercer** canal encima del parche de campo y devaluaría los dos. Sin Cargo (vía SUIT) sí
repara las dos cosas.

> **Y esto ya está construido a medias sin que ningún doc lo registrara:** el ítem
> `cargo_hl2_battery` (`corpus_cargo_supplies.lua`) hace `SetArmor(min(Armor() + 15, 100))`
> en su `onUse` — verificado en juego el 2026-08-22: 49 → 64 → 79 → 94 → 100 → *"Suit
> energy is already full"*. Con el mapeo del paso 2, **ese ítem queda correcto por
> construcción y Cargo no cambia una línea**. Lo único que hay que mover es su tope: hoy
> es un `100` literal y tiene que pasar a ser el `max_hp` del escudo activo, o una batería
> sobre un `hev` de 50 cargaría hasta el doble de lo que el escudo puede tener.

### 13.6 La barra de protección en el StatusPanel

Caliber registra **UNA** barra y dibuja **la PEOR zona** — el mínimo de `condition` entre
las zonas cubiertas.

**CRG-68** manda: *el panel dibuja MAGNITUD, jamás significado*. "La peor zona" es un
número (`min` sobre un conjunto), no un juicio: el panel no sabe qué significa. El
promedio se descartó porque **miente justo cuando importa** — tres zonas al 100 y una rota
promedian 75, y el jugador lee "bien" mientras tiene un agujero. El escudo se descartó
porque no es la armadura y ya tiene su propio FX.

⚠ **Ya hay una barra dibujando este número, y no es de Caliber:** `corpus_cargo_dev.lua`
registra una barra *"HL2 Armor"* que lee `ply:Armor()`, con `cargo_dev_bars` en `1` por
default — verificada en juego el 2026-08-22 (se mueve con el probe). La barra de Caliber
**la reemplaza**, no se suma: dos barras del mismo número es exactamente el ruido que
CRG-68 evita del otro lado.

Y **CRG-44**: si Caliber no está montado, la barra simplemente no se registra —
degradación honesta, el mismo principio que gobierna todo soft-dep del ecosistema.

### 13.7 La vía sin Cargo — el SUIT de HL2

**Perfil FIJO del traje HEV**, no el indexado por playermodel.

El indexado por playermodel es el **paso 4** del tramo (la pestaña *Armor (Player)* del
Configurator), y atar la vía de degradación a un tramo que todavía no existe la deja sin
poder existir tampoco. Un perfil fijo se puede escribir hoy.

La vía SUIT **no es "lo mismo pero peor"**: es un traje concreto con cobertura pareja y
sin zonas, y con el charger reparando armadura *y* escudo (§13.5), que es justamente lo
que Cargo le quita. Cuando el paso 4 exista, el perfil por playermodel **se suma** como
override y el fijo queda de fallback.

### 13.8 Lo que Coagulant recibe gratis

**Cero líneas.** Coagulant crea la herida en `PostEntityTakeDamage` con el daño **FINAL**
y **nunca re-escala** (`corpus_coagulant_core.lua`); su `ScalePlayerDamage` sólo captura
el hitgroup. Consecuencia: **lo que mitigue Caliber se le descuenta a la herida sin que
Coagulant cambie una línea** — y eso ya se ve en la corrida del 2026-08-22, donde cada
disparo del probe dejó su `herida: bala sev 3 en chest` en el log.

⚠ **Pero hay una dependencia frágil y conviene dejarla escrita:** hoy hay **cuatro**
listeners de `ScalePlayerDamage` montados —uno de Coagulant y tres de artagdoll— y los
cuatro cierran **sin `return` con valor**. `hook.Call` **aborta la cadena** cuando un hook
devuelve algo: el día que uno devuelva un valor, `GM:ScalePlayerDamage` deja de correr, el
escalado de hitgroup del jugador desaparece **entero y en silencio**, y el síntoma va a
parecer un bug de Caliber. Cualquier hook que Caliber agregue a ese evento cierra **sin
`return`**, y el motivo va escrito arriba de la línea.

---

*Rumbo / qué sigue → `corpus_roadmap.txt`. Metodología → `corpus_flujo_trabajo.txt`. Framework → `CORPUS_Architecture.md`.*
