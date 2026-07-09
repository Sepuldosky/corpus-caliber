# Caliber — CHANGELOG de parches (repo: corpus-caliber/)

> Registro de parches al código y a la documentación, por sesión de trabajo.
> **Disciplina (heredada de Kontrol vía ADS 2.0 y Corpus):**
> - Un parche nace `[PENDIENTE]` y pasa a `[APLICADO YYYY-MM-DD]` cuando se aplica y
>   verifica. Para código de addon GMod, "verificado" = confirmado en juego (ver
>   [`../../corpus/docs/corpus_flujo_trabajo.txt`](../../corpus/docs/corpus_flujo_trabajo.txt)).
> - **Nunca** se borra una entrada. **Nunca** se renumera un parche existente.
> - Cada sesión abre su **propia subsección**, con numeración independiente.
> - Estado vivo del proyecto → [`caliber_estado.md`](caliber_estado.md). Lo
>   `[PENDIENTE]` acá debe coincidir con lo pendiente allá.
> - Este CHANGELOG es de **este repo** (`corpus-caliber/`). El framework tiene el suyo
>   en `corpus/docs/CHANGELOG.md`.

---

## PARCHES DE sesión Migración ADS 2.0 → Caliber (Block 2) — 2026-07-09

Primera vez que este repo recibe contenido real. Migración mecánica de ADS 2.0
(`dev/legacy/AdvancedDamageSystem 2.0/`, tag `v1.0`, congelado y verificado en juego
por el autor el 2026-07-08) a un módulo de Corpus: rename de namespace + wiring sobre
las 6 primitivas del framework, **sin reescritura de dominio**. Consume las primitivas
de CC Prompt #1 (`corpus/docs/CHANGELOG.md`, sesión 2026-07-09), que figuran
`[APLICADO]` salvo el check visual de UI — que este mismo tab de Caliber cierra en la
verificación en juego. Diseño de referencia: [`Caliber_Architecture.md`](Caliber_Architecture.md).

Los parches de código nacen `[PENDIENTE]` hasta la **verificación de paridad en juego**
del autor (PASO 6 del flujo): mismo test que ya hizo sobre ADS v1.0 (VJ Base + ARC9
Darsu), repetido sobre Caliber — mismo comportamiento, otro nombre. La verificación
estática (PASO 5, greps de rename) ya pasó: `ADS.`/`ADS_`/`"ads_`/`data/ads/` en 0, cero
globals sueltos. **La verificación en juego pasó el 2026-07-09** (tras el fix de
arranque de la sesión siguiente): cvars presentes, tab en Q → Utilities → Corpus →
Caliber, sin problemas reportados — parches 2-6 flipeados a `[APLICADO]`.

- PARCHE 1 — Bootstrap de docs: `CLAUDE.md` + `docs/{caliber_estado.md,
  caliber_roadmap.txt, CHANGELOG.md, caliber_convenciones_commits.txt}` + traslado de
  `Caliber_Architecture.md` desde `corpus/docs/` (donde estaba sin commitear) a este
  repo. Mismo template que `corpus/`, apuntando al `corpus_flujo_trabajo.txt`
  compartido en vez de duplicarlo. **[APLICADO 2026-07-09]**

- PARCHE 2 — feat(config): manifest de carga `lua/autorun/corpus_caliber_init.lua`
  (Caliber_Architecture.md §4). Registra el módulo (`Corpus.RegisterModule("caliber",
  C)`), declara el bloque CONTRACT (§8, `HealLimbs` como única función pública), y hace
  `include()` de los sub-archivos en orden determinista validado contra dependencias
  reales (armor antes que core; §5). Los sub-archivos viven en `lua/corpus_caliber/
  <realm>/` (fuera de autorun, para que el manifest sea el único loader y no se dupliquen
  por auto-run). El toolgun queda en `stools/`. **[APLICADO 2026-07-09]**

- PARCHE 3 — refactor: rename mecánico de las 4 clases (§7). (a) identificadores
  `ADS.` → `CALIBER.` vía `local CALIBER = Corpus.GetModule("caliber")` por archivo;
  (b) campos de entidad `ADS_*` → `Caliber_*` (NWvars, pools de limbs, stashes, tokens
  de FX, decal); (c) convars `"ads_*"` → `"caliber_*"` (clean-slate, sin puente); (d)
  hook/timer tags `"ADS_*"` → `"Caliber_*"` y eventos `hook.Run` (`Caliber_LimbsUpdated`,
  `Caliber_ListsUpdated`). Namespace convertido a tabla única registrada; los globals
  auxiliares de ADS (`ADS_Browser`, `ADS_ShieldFX`) pasan a file-locals. **[APLICADO 2026-07-09]**

- PARCHE 4 — feat(core): rewire de primitivas (§6). `util.AddNetworkString` → bucle
  `Corpus.Net.Register("caliber", msg)` (24 mensajes → `corpus_caliber_<msg>`); el JSON
  propio (`data/ads/ads_config.json`) → `Corpus.Data.Save/Load("caliber", "config", …)`
  y los overrides de scavenger (`ads/scavenger_weight_overrides.json`) →
  `Corpus.Data.Save/Load("caliber", "scav_weights", …)`, **clean-slate** sin importador;
  todo `print("[ADS]…")` → `Corpus.Log("caliber", …)`. **[APLICADO 2026-07-09]**

- PARCHE 5 — feat(browser): UI vía la primitiva (§6). El menú Q propio de ADS
  (spawnmenu Options "Advanced Damage System") → una sola entrada
  `Corpus.UI.RegisterTab("caliber", "Caliber", fn)` (Utilities → Corpus → Caliber) con
  los 4 paneles de ajustes apilados como secciones y un botón que abre el browser de
  configuración por-NPC (DFrame con 6 sub-tabs internos: Armor / Limbs-WL / Weapons /
  Energy Shield / Scavenger / General), reachable por el concommand `caliber_browser`.
  **[APLICADO 2026-07-09]**

- PARCHE 6 — feat(config): toolgun `stools/corpus_caliber_config.lua` — modo de
  toolgun `corpus_caliber_config` (sus ClientConVars quedan `corpus_caliber_config_*`);
  refs al módulo vía `Corpus.GetModule("caliber")` lazy (no global). `TOOL.Category` =
  "Caliber". **[APLICADO 2026-07-09]**

- PARCHE 7 — assets: copiados verbatim desde ADS (`materials/`, `sound/`, `particles/`)
  conservando las rutas internas `ads/…` y `models/shield/…` que el código referencia
  (no se renombran: no aparecen en los greps de rename y renombrarlas rompería los FX).
  **[APLICADO 2026-07-09]**

- PARCHE 8 — docs(docs): `Caliber_EnergyShields_Arquitectura.md` — doc particular
  autocontenido **reconciliado contra el código real** (`corpus_caliber_shields.lua` +
  `corpus_caliber_shields_cl.lua`), NO copiado del satélite original de ADS ni de §19 sin
  re-chequear (§2 de la arquitectura). Refleja el comportamiento verificado: pool global
  por NPC (no zonal), registry de tipos, no-overflow, bypass por damage type, NWVars,
  convars, contrato UI. **[APLICADO 2026-07-09]**

Nota — deuda heredada re-registrada SIN tocar (§10), viaja con el mismo comportamiento
(bugueado) que tenía en ADS: decal `Caliber_Ricochet` inerte, `DNumSlider` en tab
Limbs/WL, doble mult de zona ARC9 (Front 4), cache de hitgroups por modelo.

---

## PARCHES DE sesión Fix de arranque + migración de config — 2026-07-09

Resultado del primer intento de verificación de paridad en juego (PASO 6): el módulo
**no cargaba en absoluto** (ni un cvar `caliber_*`, browser inaccesible). Causa raíz:
Gmod ejecuta `lua/autorun/` en orden alfabético del nombre de archivo **fusionado entre
todos los addons**, y `corpus_caliber_init.lua` ordena ANTES que `corpus_data.lua`/
`corpus_registry.lua` — el init corría con `Corpus == nil`, tomaba el early-return de
"framework no encontrado" y el módulo quedaba apagado para toda la sesión. El diseño
detectaba la ausencia pero no la esperaba (violaba en la práctica el contrato
"detección, nunca asunción" de `CORPUS_Architecture.md` §6). Los ruidos de pasos
reportados en esa misma prueba NO pueden venir de Caliber (estaba inerte; además el
código de locomoción —traductor de cojera VJ, `m_flGroundSpeed`— es paridad exacta con
ADS v1.0 ya verificado): re-testear tras este fix.

- PARCHE 1 — fix(config): boot diferido en `corpus_caliber_init.lua`. `AddCSLuaFile`
  queda en file-scope (no depende de Corpus); el registro + manifest de `include()` se
  mueven a `Boot()`, que corre inmediato si el framework ya está (lua refresh) o se
  difiere al hook `"Initialize"` (ambos realms, después de TODO autorun y antes de
  `InitPostEntity`: los tabs de UI llegan antes de `PopulateToolMenu`, los net strings
  antes de que conecte un cliente, y los hooks `InitPostEntity` de core antes de la
  barrera). Sonda `CorpusListo()` sobre las primitivas usadas en file-scope
  (`RegisterModule`/`Data`/`Net`/`Log` + `UI` en client), no solo el global. Si tras
  `Initialize` sigue sin framework: falla ruidoso por `MsgN`, como antes. Este patrón
  es el template para los otros cuatro módulos del ecosistema. **[APLICADO 2026-07-09]**

- PARCHE 2 — chore(data): migración one-time de la config del autor, **fuera del repo**
  (data del juego): `data/ads/ads_config.json` → `data/corpus/caliber/config.json`
  (copia verbatim; mismo shape `whitelist/blacklist/armor/curated_weapons/ammo_fallback`
  que `SaveConfig` escribe y `LoadConfig`/`LoadArmorData` leen — validado contra el
  código). 278 clases en whitelist, 284 perfiles de armadura, 65 en blacklist, 9 armas
  curadas. El contrato clean-slate se mantiene: **sin importador en código**; fue una
  copia manual de datos. **[APLICADO 2026-07-09]** (el pickup en runtime se confirma en
  la misma verificación de paridad).

Nota — cierre de la verificación (2026-07-09): el autor confirmó en juego cvars
`caliber_*`, tab en el menú Q y funcionamiento sin problemas. El ruido de pasos
recurrente reportado en el primer intento **no viene de Corpus/Caliber** (se reprodujo
con el módulo inerte y el código de locomoción es paridad exacta con ADS): queda fuera
de scope, a investigar en el stack de addons externo (VJ/otros).
