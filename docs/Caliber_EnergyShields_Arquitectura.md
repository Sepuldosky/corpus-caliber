# Caliber — Escudos de Energía · Documento de Arquitectura (particular)

> **Uso de este documento:** Referencia autocontenida del subsistema de escudos de
> energía de Caliber. Es un doc **particular** (desprendido del general, ver
> `Caliber_Architecture.md` §2 y el patrón de `corpus_flujo_trabajo.txt`): cubre solo
> este subsistema, en detalle.
>
> **Reconciliado, no copiado.** Este doc NO se copió del satélite original de ADS
> (`ADS_EnergyShields_Arquitectura.md`, el diseño *previo* a la implementación) ni de
> `ADS_2_0_Architecture_updated.md` §19 sin re-chequear. Se escribió leyendo el código
> real migrado (`corpus_caliber_shields.lua` + `corpus_caliber_shields_cl.lua`) y
> contrastando sección por sección — principio "el código manda". Donde el diseño
> original divergía, este doc refleja el **comportamiento verificado en juego** (ADS
> v1.0, 2026-07-08), no la intención original.
>
> **Divergencia principal reconciliada:** el diseño original planteaba una *zona-escudo
> que se resolvía antes de la placa física* (escudo zonal). La implementación lo
> **elevó a un pool GLOBAL por NPC** — una sola entrada `npc.Caliber_Shield` por
> entidad, un solo pool que se drena, sin zonas. El código manda: es global.
>
> **Estado vigente (foto de HOY)** → `caliber_estado.md`. **Módulo** → `Caliber_Architecture.md`.

---

## Índice

1. [Alcance y modelo](#1-alcance-y-modelo)
2. [Pipeline: dónde entra el escudo](#2-pipeline-dónde-entra-el-escudo)
3. [Registry de tipos](#3-registry-de-tipos)
4. [Motor mecánico (server)](#4-motor-mecánico-server)
5. [No-overflow y bypass por damage type](#5-no-overflow-y-bypass-por-damage-type)
6. [Recarga: un solo Think](#6-recarga-un-solo-think)
7. [Estado en red: NWVars + one-shots](#7-estado-en-red-nwvars--one-shots)
8. [FX cliente](#8-fx-cliente)
9. [Convars](#9-convars)
10. [Contrato de configuración por-NPC](#10-contrato-de-configuración-por-npc)
11. [Deuda y deferrals](#11-deuda-y-deferrals)

---

## 1. Alcance y modelo

Escudo de energía **por NPC**, estilo Halo: un pool que absorbe daño, colapsa al
agotarse, y se recarga tras un delay si no recibe hits. **CAL-14 — No es zonal**: es un único
pool global por entidad (`npc.Caliber_Shield`, una tabla por NPC). Assets y concepto
rescatados de "Halo Energy Shield" (Speedy Von Gofast) y "Goofy Armor Effect" (sora1d);
el wiring de red original era single-player y se reescribió multi-NPC en ADS.

Estructura de estado (server-only, `corpus_caliber_shields.lua`):

```lua
npc.Caliber_Shield = {
    hp, max,               -- pool actual / máximo
    type,                  -- clave del registry ("spartan"|"elite"|"hev")
    canRegen,              -- bool
    rechargeDelay,         -- s sin hits antes de empezar a cargar
    rechargeRate,          -- HP/s de carga
    regenAt, lockoutUntil, -- timestamps (delay normal / lockout EMP)
    state, nextThink,      -- estado actual / throttle del Think
    chargeSnd, lastRegenTick,
}
```

El registro server de NPCs con escudo es `ShieldNPCs[npc] = true` (una sola tabla; el
Think itera SOLO los registrados — la recarga completa produce cero paquetes de red).

---

## 2. Pipeline: dónde entra el escudo

**CAL-13 —** El escudo es un **pre-filtro global delante de la armadura**, que a su vez está delante
de limbs:

```
Hit → ESCUDO → ARMADURA → LIMBS → (engine hitgroup compensation)
```

Lo invoca `ScaleNPCDamage` en `corpus_caliber_core.lua`, ANTES de resolver armadura:

```lua
if CALIBER.ProcessShield then
    local absorbed, sTrace = CALIBER.ProcessShield(npc, hg, di)
    if absorbed then
        CALIBER.ApplyBlockedHitFX(npc, di, hg, nil, nil, true)  -- solo supresión de sangre
        npc.Caliber_ArmorStash = nil                             -- la placa no participa
        return                                                   -- corta el hook
    end
    ...
end
```

Guardado (`if CALIBER.ProcessShield`): shields carga vía el manifest; el guard cubre
además instalación parcial.

---

## 3. Registry de tipos

**CAL-19 —** Agregar un escudo nuevo = una entrada en `CALIBER.ShieldTypes` (server, mecánica +
defaults + sonidos) **y** la entrada espejo en `Caliber_ShieldFX.Types`
(`corpus_caliber_shields_cl.lua`, visuales). **MISMAS KEYS en ambas tablas.** La
mecánica NO cambia entre tipos: solo assets y defaults.

| Tipo | max_hp | delay | rate | regen | color (r,g,b) | Visual |
|---|---|---|---|---|---|---|
| `spartan` | 70 | 4.0 | 15 | sí | 218,185,40 | burbuja + pcf Halo (impact/deplete/arcs/recharge) |
| `elite` | 70 | 4.0 | 15 | sí | 51,105,219 | burbuja + pcf Halo |
| `hev` | 50 | 6.0 | 10 | sí | 255,160,40 | **built-in** (selection_ring, TeslaHitBoxes), sin burbuja/pcf |

Sonidos server por tipo (`sounds`): `hit_light`/`hit_medium`/`hit_heavy` (arrays, tier
por drain), `brk` (colapso), `brk_extra` (2ª capa del colapso, solo hev), `charge`
(sonido incremental de carga con loop embebido, se corta con `StopSound`), `restore`
(ding de carga completa, solo hev). Spartan/elite usan los sets Halo
(`ads/shield/<dir>/hit1-7.wav`, `ads/shield/break1-3.wav`, `ads/shield/recharge_*.wav`);
hev usa sonidos built-in del engine (physics/energy/suitcharge).

Los sets colorables `spdy_halo_3_custom_*` (cliente) se intentan cuando el NPC trae
`shield_color` custom (tintado por control point 4 del pcf); fallback automático al set
horneado del tipo.

---

## 4. Motor mecánico (server)

`CALIBER.ProcessShield(npc, hg, di) → absorbed (bool), trace (tabla|nil)`. Lo llama
`ScaleNPCDamage` antes de la armadura. Ramas, en orden:

1. **Gates de salida rápida** — `caliber_shield_enabled` off, sin tabla de escudo, o
   `dmg <= 0` → `false, nil`. (El `dmg<=0` no genera trace: el call site no debe
   descartar un stash ARC9 legítimo por un hit vacío.)
2. **Bypass melee** (`DMG_SLASH | DMG_CLUB`) — el hit pasa entero pero SÍ frena la regen.
   `false, {reason="bypass"}`.
3. **CAL-17 — Flags de arma:** `plasma`/`emp` se leen de `CALIBER.CuratedWeapons[wep:GetClass()]`
   (tabla curada, NO del extractor: el arma EFT conserva su tuple balístico intacto).
4. **Escudo caído** (`hp<=0`) — el hit pasa entero; `emp` extiende el lockout igual.
   `false, {reason="down"}`.
5. **EMP con escudo arriba** — colapso total instantáneo (`hp=0`) + lockout, `SetDamage(0)`.
   `true, {reason="emp"}`.
6. **Drain normal** — `drain = dmg * shield_damage_mult * (plasma and plasma_mult or 1)`.
   **La penetración NO participa** (un solo knob global). Si el pool llega a 0 → colapso
   (`reason="break"`); si no → absorbido (`reason="absorbed"`). En ambos `SetDamage(0)`.

`CALIBER.ShieldWillAbsorb(npc, di)` es la consulta **pura** (sin side effects) que usa
el detour ARC9 para cortar `penleft` a 0 (SHIELD-STOP) cuando el round se va a detener
en el escudo — así la placa no participa. Entre detour y hook nada regenera (la regen es
Think), por eso la predicción coincide con lo que hace `ProcessShield`.

---

## 5. No-overflow y bypass por damage type

**No-overflow (canon; cita CAL-15 — su sede es `corpus_caliber_shields.lua:323`):** cuando el escudo absorbe, consume el hit **COMPLETO** — hace
`di:SetDamage(0)` y el caller DEBE early-return del hook. El exceso de daño sobre el
pool NO pasa a la armadura. Consecuencia: con escudo arriba, la armadura no gasta
durabilidad y `ProcessLimbHit` no corre → **cero debuffs de extremidad con escudo
arriba**. El hit absorbido recibe supresión de sangre (rama 1 de `ApplyBlockedHitFX`
con `bloodOnly=true`: sin chispa ni ricochet metálicos — el escudo tiene su propio flash
de energía).

**CAL-16 — Bypass por damage type (§4 del diseño):** SOLO melee (`DMG_SLASH`, `DMG_CLUB`) salta el
pool. Blast/fuego/etc. drenan normal vía `shield_damage_mult`. El bypass igual **frena
la regen** (cualquier hit que afecte al escudo resetea el timer de recarga).

---

## 6. Recarga: un solo Think

Un único `hook.Add("Think", "Caliber_Shields_Think", …)` itera `ShieldNPCs`. Cero
tráfico de red durante la recarga; lo único que cruza al completar es el flip de NWVar
`CHARGING→UP` + un one-shot de restauración. Throttle per-NPC (`nextThink`,
`caliber_shield_think_interval`). Estados (`Caliber_Shield_State`, NWInt; 0=sin escudo):

- `STATE_UP = 1`, `STATE_DOWN = 2`, `STATE_CHARGING = 3`.
- CHARGING: acumula `hp += rechargeRate * elapsed` (elapsed real, no el intervalo
  nominal); al llegar a `max` → `STATE_UP` + sonido/FX de restore.
- Arranca a cargar cuando `canRegen and hp<max and now>=regenAt and now>=lockoutUntil`.

`SetState` centraliza el sonido de carga: TODA salida de CHARGING lo corta (completar,
hit que interrumpe, EMP, colapso) y toda entrada lo arranca. El corte del sonido con la
entidad AÚN válida (en `OnNPCKilled`/`EntityRemoved`) es necesario: Source reutiliza el
índice de entidad y el loop quedaría pegado al próximo NPC spawneado.

---

## 7. Estado en red: NWVars + one-shots

Dos canales, distinto propósito:

**Persistente (NWVars, on-change, sobrevive late-joiners):**
- `Caliber_Shield_State` (NWInt) — 0/1/2/3.
- `Caliber_Shield_Type` (NWString) — clave del tipo, o "".
- `Caliber_Shield_Color` (NWVector) — color resuelto (override del NPC o default del tipo).

**Transitorio (net one-shots con filtro PVS):** `corpus_caliber_shield_fx`
(server→client, registrado en core vía `Corpus.Net.Register`). `ev`: 1=hit_flash (+pos),
2=collapse, 3=restore. Throttle: máx 1 flash de hit por NPC por frame (ráfagas/perdigones);
collapse y restore nunca se throttlean. Emitir sin consumidor es inocuo.

---

## 8. FX cliente

`corpus_caliber_shields_cl.lua`: el cliente **NO simula nada**. Lee estado de las NWVars y
efectos transitorios del net. `Caliber_ShieldFX.Types` (file-local, no global) es el
espejo visual del registry server (mismas keys). Estado FX per-NPC (`ActiveFX[npc]`)
creado lazy al primer evento.

- **Burbuja** (spartan/elite): `ClientsideModel` del modelo del NPC, bonemergeada,
  material aditivo (`RENDERMODE_GLOW`), alpha que decae desde el último evento, swell al
  colapsar. Se re-afirma parent/pos/bonemerge cada frame (con lag/dormancy el parent se
  rompe y la copia queda en T-pose). Gated por `caliber_shield_fx_bubble`.
- **Partículas** (gated por `caliber_shield_fx_particles`): impacto/colapso/recarga; arcos
  eléctricos persistentes mientras `STATE_DOWN`; loop de recarga re-attach cada 0.7s en
  `STATE_CHARGING`. Con `shield_color` custom se usa el set colorable (tintado por control
  point); si no, el horneado del tipo.
- **HEV** (`builtin=true`): sin burbuja ni pcf — anillo `selection_ring` orientado al hit,
  `TeslaHitBoxes` al colapsar (efectos "Goofy Armor" built-in del engine).

---

## 9. Convars

Server (replicadas, para que los controles de UI funcionen):

| Convar | Default | Rol |
|---|---|---|
| `caliber_shield_enabled` | 1 | master toggle del subsistema |
| `caliber_shield_damage_mult` | 1.0 | drain de un hit genérico al pool (knob global único, sin penetración) |
| `caliber_shield_plasma_mult` | 2.0 | factor extra de drain para armas con flag `plasma` |
| `caliber_shield_emp_lockout` | 8.0 | s de lockout de recarga tras un hit `emp` |
| `caliber_shield_sounds` | 1 | sonidos (hits/colapso/restauración) |
| `caliber_shield_think_interval` | 0.1 | throttle per-NPC del Think de recarga |

Cliente: `caliber_shield_fx_bubble` (1), `caliber_shield_fx_particles` (1).

Concommands de debug (efímeros, sin tocar whitelist/JSON): `caliber_shield_give [tipo]
[max_hp]`, `caliber_shield_clear`, `caliber_shield_status`.

---

## 10. Contrato de configuración por-NPC

La autoridad de un escudo es el **whitelist entry** del NPC (`InitShield` lo resuelve vía
`GetOverrideForEnt`, key de spawnmenu > classname — cita CAL-20, su sede es
`corpus_caliber_core.lua:339`). Sin entry o sin `shield_type` válido
→ sin escudo. `InitShield` es idempotente (re-init resetea el pool a full).

Campos del entry (saneados en `Sanitize` de `corpus_caliber_core.lua`; **gate maestro =
`shield_type` válido contra el registry** — sin tipo válido se descartan TODOS los campos
`shield_*`):

| Campo | Rango / tipo | Nota |
|---|---|---|
| `shield_type` | key de `ShieldTypes` | gate maestro |
| `shield_max_hp` | 1..5000 (int) | opcional, cae al default del tipo |
| `shield_color` | {r,g,b} 0..255 | opcional |
| `shield_recharge_delay` | 0..60 | opcional |
| `shield_recharge_rate` | 0.1..1000 | opcional |
| `shield_can_regen` | bool | `false` es valor legítimo (se resuelve con `~= nil`) |

Se editan en el **tab Energy Shield del browser** (`corpus_caliber_browser.lua`). Los
flags `plasma`/`emp` de arma son **manuales**, viven solo en `curated_weapons` (tab
Weapons), y `ProcessShield` los lee directo de `CALIBER.CuratedWeapons` — independientes
del tuple balístico (EFT sigue ganando el extractor).

Al editar el whitelist en vivo, `core` llama `CALIBER.RefreshShieldsForClass(class)` /
`RefreshAllShields()` → `InitShield` re-sincroniza los escudos vivos con el entry vigente
(dar/quitar según corresponda).

---

## 11. Deuda y deferrals

- **Consumidor cliente ("Bloque B" en ADS) — deuda SALDADA, no queda nada que limpiar.**
  Los dos comentarios del legacy que anunciaban que el consumidor de FX "llega en el
  Bloque B" (`ads_shields.lua:10` y `:196`) se reescribieron en la migración:
  `corpus_caliber_shields.lua:10-11` ya dice «consumidos por `corpus_caliber_shields_cl.lua`,
  migrado junto con el resto de este bloque» y `:197`, «el consumidor es
  `corpus_caliber_shields_cl.lua`; emitir sin él (instalación parcial) es inocuo».
  El único «Bloque B» que sobrevive en `lua/` es `corpus_caliber_shields.lua:452`, y es
  otra cosa: una nota histórica sobre el bug del sonido de carga heredado por índice de
  entidad, no sobre el consumidor.
- **Sonidos `recharge_spartan.wav` / `recharge_elite.wav`:** referenciados por el
  registry; migran verbatim con los assets. Si algún wav falta en el paquete original,
  el `EmitSound` es no-op (paridad con ADS, no bug de migración).
- La migración NO tocó la mecánica de escudos: es rename + wiring de primitivas. Cualquier
  ajuste de balance o de diseño es trabajo futuro sobre Caliber, no sobre el legacy.

---

*Módulo → `Caliber_Architecture.md`. Framework → `../../corpus/docs/CORPUS_Architecture.md`.
Metodología → `../../corpus/docs/corpus_flujo_trabajo.txt`.*
