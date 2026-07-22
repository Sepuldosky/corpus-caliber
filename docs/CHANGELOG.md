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

---

## PARCHES DE sesión Pasada de veracidad de docs — 2026-07-14

Auditoría de veracidad del ecosistema: dónde el doc afirma hoy algo que el código
desmiente. `Caliber_Architecture.md` es el doc de diseño **previo** a la bajada, y
nunca se refrescó con lo que la implementación (y la verificación en juego) le
enseñó: seguía publicando el patrón de boot con `error()` en file-scope —
**exactamente el que dejó el módulo inerte** en la sesión del 2026-07-09— mientras
`caliber_estado.md` declara el boot diferido «patrón template para los otros cuatro
módulos». Misma deriva, más chica, en los deferrals (§9.a) y en el conteo de tabs del
browser. Solo docs y comentarios: sin superficie de runtime.

- PARCHE 1 — docs(docs): reescribe el snippet del init en §3 con el patrón real
  —sonda `CorpusListo()` + `Boot()` diferido al hook `"Initialize"`, `AddCSLuaFile` en
  file-scope, `MsgN` si tras `Initialize` no hay framework— y lo anota como contrato:
  el init **NO aborta con `error()`**, porque `corpus_caliber_init.lua` ordena antes
  que `corpus_registry.lua` en el `autorun` fusionado entre addons y abortar solo
  consigue que el módulo no arranque nunca. Queda explícito que la iface se registra
  como **tabla vacía** (se puebla by-ref, §11) y que este es el patrón **template** del
  ecosistema. **[APLICADO 2026-07-14]**

- PARCHE 2 — docs(docs): §9.a — el choke point de limbs no «espera consumidor»: **ya
  emite**. `ApplyLimbDebuffs` cierra con `hook.Run("Caliber_LimbsUpdated", npc, reason)`
  (`corpus_caliber_limbs.lua:298`, `reason ∈ spawn|damage|heal`), heredado verbatim de
  ADS y hoy sin consumidor. El pendiente no es agregar el emit sino **enriquecer el
  payload** —hoy `(npc, reason)`: sin zona, sin daño al pool, sin `dmginfo`— y elevarlo
  a contrato. Tal como está es un aviso de refresh, no un evento de daño.
  **[APLICADO 2026-07-14]**

- PARCHE 3 — docs(docs): §8 — «Eventos de daño/limb: vacío en este bloque» se leía como
  cero emits. Pasa a «**sin superficie de contrato**: existe un `Caliber_LimbsUpdated`
  off-contract y sin consumidor». Mismo matiz en el bloque CONTRACT de
  `corpus_caliber_init.lua` (solo comentario). **[APLICADO 2026-07-14]**

- PARCHE 4 — docs(docs): §2 y §6 — el browser tiene **6** sub-tabs, no 5: falta **Energy
  Shield** en la lista (Armor / Limbs-WL / Weapons / Energy Shield / Scavenger /
  General). Ya eran 6 en el snapshot de ADS (`cl_ads_browser.lua`) y sobreviven en
  Caliber (`corpus_caliber_browser.lua:2459-2464`). El doc se contradecía con su
  hermano: `Caliber_EnergyShields_Arquitectura.md` §10 manda a editar los `shield_*`
  «en el tab Energy Shield del browser». **[APLICADO 2026-07-14]**

Segunda pasada (misma sesión): una revisión independiente encontró resto que sobrevivió
**dentro de los archivos ya corregidos** — el caso peor, porque el doc quedaba
contradiciéndose consigo mismo. Se cierran acá. Solo docs: sin superficie de runtime.

- PARCHE 5 — docs(docs): §2 — «el legacy ADS queda intacto **en su propio repo**» es
  falso: no es un repo. Quedó congelado en `dev/legacy/AdvancedDamageSystem 2.0/`,
  carpeta fuera de **todos** los git del workspace (tag `v1.0`). Es la versión local de
  la misma falsedad ya corregida en `CORPUS_Architecture.md` §7; se alinea con esa
  redacción. **[APLICADO 2026-07-14]**

- PARCHE 6 — docs(docs): §4 — el snippet del manifest seguía mostrando rutas planas
  (`include("corpus_caliber_shared.lua")`) cuando el init real carga
  `lua/corpus_caliber/<realm>/…` vía los helpers `inc()`/`cs()`. Con §3 ya publicando el
  patrón real (PARCHE 1), los dos snippets del mismo doc no parecían el mismo archivo.
  Se alinea con el init: tablas `SHARED`/`SERVER_FILES`/`CLIENT_FILES`, helpers, e
  includes dentro de `Boot()`. Se conserva el matiz «ilustrativo del mecanismo» (el
  archivo real intercala `AddCSLuaFile` y la sonda), pero se retira «no la secuencia
  final»: las rutas y el orden **son** los definitivos, validados contra dependencias
  reales (`armor` antes que `core`). **[APLICADO 2026-07-14]**

- PARCHE 7 — docs(docs): `CLAUDE.md` — tres falsedades de cardinalidad/estado, gemelas
  de las ya corregidas en el repo del framework. (a) «una de **seis** raíces» → son
  **siete** repos (`corpus` + los cinco módulos + `corpus-stalker`, el addon de
  contenido de la Zona), más `dev/` que no es repo (verificado en
  `corpus.code-workspace`). (b) Contrato 8: «los **seis** addons montados a la vez» →
  siete. (c) «remote `origin` cableado localmente, **sin commits todavía**» → falso: el
  repo tiene commits y está al día con `origin/main` (`git rev-list --left-right
  --count origin/main...HEAD` → `0 0`). **[APLICADO 2026-07-14]**

Tercera pasada (misma sesión): los verificadores destaparon una capa más profunda. Parte
cayó **dentro** del doc de arquitectura (el invariante by-ref que ya estaba escrito y este
doc seguía pidiendo, los identificadores `ADS_*` de un código que ya no existe, y los
checklists de §7 y §12 con todas las casillas vacías de cosas hechas) y parte **fuera**:
el roadmap, que es lo que un lector consulta para saber qué falta, seguía presentando como
inmediata una verificación en juego cerrada el 2026-07-09. Solo docs: sin superficie de
runtime.

- PARCHE 8 — docs(docs): `caliber_roadmap.txt` §1 — el INMEDIATO era «cerrar la
  verificación en juego de la migración» y «flipear el parche a `[APLICADO]`». Falso
  desde el 2026-07-09: el autor corrió la paridad y **todo** el CHANGELOG está en
  `[APLICADO]` (ver `caliber_estado.md`). El INMEDIATO real de hoy es el **Block 3**
  (pipeline de armadura de jugador), que estaba enterrado como `[2]` en §2. Se promueve
  a `[1]` y se renumera §2. **[APLICADO 2026-07-14]**

- PARCHE 9 — docs(docs): `caliber_roadmap.txt` §2 — «El emit se cuelga ahí cuando el
  módulo consumidor lo necesite»: es **la misma falsedad** que esta sesión ya mató en
  §9.a de la arquitectura (PARCHE 2), sobreviviendo en el roadmap. El emit **ya existe**
  (`corpus_caliber_limbs.lua:298`); el pendiente es **enriquecer el payload** y elevarlo
  a contrato, no agregar el emit. **[APLICADO 2026-07-14]**

- PARCHE 10 — docs(docs): `caliber_roadmap.txt` §0 — «doc canónico compartido por los
  **seis** repos del ecosistema» → **siete** repos git (`corpus` + los cinco módulos +
  `corpus-stalker`), más `dev/` que no es repo. Gemela de la ya corregida en `CLAUDE.md`
  (PARCHE 7). **[APLICADO 2026-07-14]**

- PARCHE 11 — docs(docs): §3 y §11 — el doc decía que el invariante by-ref «hoy no está
  escrito en ningún doc» y titulaba §11 «Adición **requerida** a `CORPUS_Architecture.md`
  §3 … cuando se implemente esa primitiva». Falso por partida doble: las 6 primitivas
  están implementadas y el invariante ya está escrito allá como contrato duro (nota
  «Invariante del registro», que además cita de vuelta a §3/§11 de este doc) y repetido
  en la cabecera de `corpus_registry.lua`, que lo cumple (`RegisterModule` guarda `iface`
  tal cual, `GetModule` la devuelve sin tocar). §11 pasa a pasado: se pidió y **se
  aplicó**. **[APLICADO 2026-07-14]**

- PARCHE 12 — docs(docs): §9 y §10 — identificadores de código que **ya no existen**:
  `npc.ADS_HP_*`, `ADS_LastLimbHit`, decal `ADS_Ricochet`. El rename está aplicado
  (`grep -rn "ADS[._]" lua/` → 0): hoy son `npc.Caliber_HP_*`, `npc.Caliber_LastLimbHit`
  y `Caliber_Ricochet`. El hecho de fondo (Limbs NPC-only, decal inerte) es cierto y se
  mantiene — se corrigen **solo** los nombres. Misma clase: el puntero de la deuda del
  `DNumSlider` apuntaba a `cl_ads_browser.lua`; hoy es `corpus_caliber_browser.lua`
  ~L1360 (`BuildWLTab`), donde el slider sigue vivo. **[APLICADO 2026-07-14]**

- PARCHE 13 — docs(docs): §7 y §12 — los dos checklists tenían **todas** las casillas en
  `[ ]`, afirmando que no se hizo nada. Se verificó punto por punto contra el código y el
  repo (greps de ADS en 0; 6 primitivas presentes; manifest y tabla única aplicados;
  bloque CONTRACT en el init; `Caliber_EnergyShields_Arquitectura.md` publicado;
  verificación en juego del 2026-07-09; `caliber_estado.md` y `corpus_estado.md` al día):
  los 4 + 9 ítems se cumplieron. Ambos pasan a `[x]` y a voz de pasado. **[APLICADO
  2026-07-14]**

- PARCHE 14 — docs(docs): §2 — «el archivo satélite [`ADS_EnergyShields_Arquitectura.md`]
  **ni siquiera está disponible** en este espacio de diseño para re-chequear» se lee hoy
  como que no es consultable. Existe: `dev/legacy/AdvancedDamageSystem 2.0/docs/`. Se
  acota al chat de diseño original (donde era cierto) y se aclara que hoy sí se puede
  leer — sin autoridad, pero legible. **[APLICADO 2026-07-14]**

- PARCHE 15 — docs(docs): `caliber_estado.md` — mentira **accionable**: «las carpetas en
  `garrysmod/addons/` son **copias**, no junctions — re-copiar (o `mklink /J`) tras editar
  el repo». Son junctions: `Get-Item …\addons\corpus-caliber` → `LinkType: Junction`,
  `Target: …\VSCode\corpus-caliber` (los siete repos, igual). Seguir la instrucción sería
  trabajo inútil y, peor, re-copiar encima rompería el montaje. Los repos hermanos ya lo
  decían bien (`corpus-cargo/docs/CHANGELOG.md`, `corpus-craving/docs/Craving_Architecture.md`
  §6). Fix quirúrgico: la cláusula vecina —«Sin `addon.json` todavía»— **es cierta** (no hay
  `addon.json` ni trackeado ni en disco) y se conserva; se reemplaza solo la de las copias
  por «montados por junction — editar el repo se refleja directo en el juego».
  **[APLICADO 2026-07-14]**

- PARCHE 16 — docs(docs): **regresión de esta misma pasada.** `Caliber_Architecture.md` §Índice
  — el PARCHE 13 retituló el encabezado de §12 a «Checklist de cierre de bloque — **completo**»
  (slug `#12-checklist-de-cierre-de-bloque--completo`, doble guion por el em-dash) pero dejó la
  entrada del TOC apuntando al ancla vieja `#12-checklist-de-cierre-de-bloque`, que ya no existe:
  el link del índice no salta a ningún lado. Que fue olvido y no criterio lo prueba el mismo
  diff, donde la entrada 11 **sí** se actualizó al slug nuevo. Se repasaron las 12 anclas del
  TOC contra los 12 encabezados `##`: las otras 11 resuelven. **[APLICADO 2026-07-14]**

- PARCHE 17 — docs(docs): `Caliber_EnergyShields_Arquitectura.md` §11 — estado rancio en el
  único doc que esta pasada no había tocado. El bullet 1 registraba como deuda de limpieza que
  «los comentarios del código **aún mencionan** que el consumidor de FX llega en el Bloque B»:
  falso contra el árbol. La migración ya los reescribió — `corpus_caliber_shields.lua:10-11`
  nombra a `corpus_caliber_shields_cl.lua` como consumidor y `:197` dice que emitir sin él es
  inocuo. `grep -rni "bloque b" lua/` devuelve **un** hit (`shields.lua:452`) y es otra cosa: la
  nota histórica del bug del sonido de carga heredado por índice de entidad. El bullet pasa a
  «deuda SALDADA» con el detalle de qué sobrevive y por qué no cuenta. **[APLICADO 2026-07-14]**

- PARCHE 18 — docs(docs): `CLAUDE.md` §Git/commits — «Alcances de este repo: … `config` (+ `docs`,
  `chore`)» tergiversa al doc que cita. `caliber_convenciones_commits.txt` define `chore` en §2
  como **tipo** de commit (junto a feat/fix/refactor/docs/test) y su §3 enumera exactamente 8
  alcances, sin él: armor, core, limbs, shields, scavenger, browser, config, docs. El propio
  ejemplo §4.2 del doc lo zanja: `chore(config): añade el manifest de carga` — chore = tipo,
  config = alcance. Se separan tipos de alcances (como ya lo redacta bien `corpus-cargo/CLAUDE.md`)
  y se anota la trampa en una línea. **[APLICADO 2026-07-14]**

- PARCHE 19 — docs(docs): `caliber_estado.md` — la cabecera declaraba «Última actualización:
  2026-07-11» cuando el archivo se editó **hoy**, en esta misma pasada (el fix de junction del
  PARCHE 15). Los cuatro estado docs hermanos ya llevaban 2026-07-14. Se corrige la fecha y se
  anota que lo de hoy fue la pasada de veracidad — solo docs y comentarios, sin superficie de
  runtime, para que la foto no se lea como si el Block 2 se hubiera movido. **[APLICADO
  2026-07-14]**

---

## PARCHES DE sesión Etiquetado de IDs normativos (deuda D-7) — 2026-07-19

Tanda multi-repo del ecosistema, guiada por `dev/PROMPT_d7_etiquetado_ids.txt` (§8 del flujo).
Solo prosa: **ninguna norma cambió**. Cada sede que el registro
(`../corpus/docs/ids.yaml`) declara ahora lleva su ID visible, para que un lector que
aterriza en el doc vea de qué norma se trata sin abrir el registro, y para que el gate de
coherencia (§7.8) pueda contrastar el título del yaml contra la prosa de su sede.

- PARCHE 1 — **22 de 22 IDs de la familia `CAL` etiquetados en su sede.**
  Los 3 restantes NO se etiquetaron a propósito: sus sedes viven en archivos `.lua`,
  en el CHANGELOG, en el estado o en el roadmap. Etiquetar ahí volvería **definitorio** un
  comentario, que es lo que **FLU-26** prohíbe, o tocaría un doc que no se reescribe
  (**FLU-14**). Son deuda **D-3** del registro y se cierran moviendo la sede a un doc —
  decisión de diseño, no mecánica. **[APLICADO 2026-07-19]**

- PARCHE 2 — **Contratos que eran copias, ahora CITAN por ID.** Los contratos 1-4 y 8 del
  `CLAUDE.md` re-enunciaban normas del framework: pasan a citar `COR-2`, `COR-5`,
  `COR-3`, `COR-4` y `COR-6`. Las reglas cardinales citan `COR-10`/`COR-1` y
  `COR-11`. **[APLICADO 2026-07-19]**

Hallazgo anotado, NO reparado: `Caliber_Architecture.md` §1 enuncia los principios de
dominio **sin el escudo**, mientras `CAL-18` (CLAUDE.md) y `CAL-13` (doc de escudos §2)
sí lo incluyen. Deliberadamente NO se le puso cita: hacerlo haría pasar por `CAL-18` una
versión mutilada de la norma. Es la deuda **D-4**, pendiente de decisión del autor.

Verificación: `corpus/.claude/check-ids/corpus_check_ids.ps1` en verde (una etiqueta mal
tipeada habría salido como `HUERFANO_DOC`). Sin superficie de runtime: nada que cargar en
un mapa, y **ningún check de planilla nace de esta tanda** (FLU-37).

---

## PARCHES DE sesión Anti-drift: cierre de votos — 2026-07-19

Tanda multi-repo guiada por `dev/PROMPT_cierre_antidrift.txt`: el autor votó las deudas
abiertas del registro y acá se aplica lo que toca a este repo.

- PARCHE 1 — **D-4 cerrada.** `Caliber_Architecture.md` §1 enuncia la cadena completa del
  pipeline (Hit → **escudo** → armadura → limbs) citando **`CAL-13`** — el escudo como
  pre-filtro ya no falta en los principios de dominio. **[APLICADO 2026-07-19]**
- PARCHE 2 — **Reconciliación del doc contra el código**, pedida por el autor (sospechaba
  drift de la era ADS). El barrido dio el **§3 (boot diferido) CORRECTO** — el doc no quedó
  viejo en el arranque. Los tres ajustes reales, aplicados: **(a)** la fila UI del §6
  confundía el tab del menú Q con el browser — los 6 sub-tabs viven en el **browser
  por-NPC** (concommand `caliber_browser`); la entrada del menú Q apila los 4 paneles de
  convars + el botón que lo abre; **(b)** la fila Persistencia del §6 omitía la segunda key
  `scav_weights`; **(c)** el §7 no declaraba los paths de assets `sound/ads/` y
  `materials/ads/` — quedan anotados como **residual de 5.ª clase**, fuera del alcance del
  rename (mover assets, no find-replace de Lua). Los deferrals de §9 están fielmente
  descritos y no se tocaron (sin árbitro). **[APLICADO 2026-07-19]**
- PARCHE 3 — **Los contratos 5 y 6 del `CLAUDE.md` pasan de definir a CITAR** los nuevos
  **`COR-15`** (UI shell) y **`COR-16`** (log), acuñados en el framework — cierre de la
  deuda D-11, que este repo destapó. **[APLICADO 2026-07-19]**

Verificación: `corpus/.claude/check-ids/corpus_check_ids.ps1` en verde sobre 197 IDs. Sin
superficie de runtime, y **ningún check de planilla nace de esta tanda** (FLU-37).

---

## PARCHES DE sesión Anti-drift: reparación del COMPLETO — 2026-07-19

- PARCHE 1 — **Hallazgo 2.20 del acta `corpus/docs/auditorias/2026-07-19_coherencia_docs.md`:**
  la fila «Ready barrier» del §6 deja de atribuir a Cortex el primer consumo de
  `Corpus.OnReady` — lo pagó **Cargo en su Block 1**, y hoy lo usan también Coagulant y
  Craving; Caliber lo tomará cuando deje de ser hoja en el grafo. **[APLICADO 2026-07-19]**

Verificación: checker en verde + suite 12/12. Sin superficie de runtime.

---

## PARCHES DE sesión D-13: pre-2.º COMPLETO — 2026-07-19

Parte de la tanda multi-repo guiada por `dev/PROMPT_d12_d13_segundo_completo.txt`, que cerró
las deudas **D-12** y **D-13** del registro. Acá lo que toca a este repo. Solo prosa: **ninguna
norma cambió de contenido**.

- PARCHE 1 — **`CAL-23` acuñado: la tabla de alcances de `caliber_convenciones_commits.txt`
  §3 es norma y ahora tiene ID.** Ese doc era uno de los **10 docs ciegos** del hueco H1 del
  COMPLETO: 144 líneas sin una sola etiqueta, sobre las que un gate que cruza IDs no salía
  limpio — salía **ciego**. La §3 es por-repo y jamás se hereda del framework (cita GIT-6);
  el `CLAUDE.md` la resume y **el doc manda**. Los 8 alcances (`armor`, `core`, `limbs`,
  `shields`, `scavenger`, `browser`, `config`, `docs`) se derivaron del propio doc, no del
  resumen. **[APLICADO 2026-07-19]**
- PARCHE 2 — **`caliber_roadmap.txt` pasa de ciego a citante**, sin acuñar nada: por voto del
  autor un roadmap es **intención pura** y no puede ser sede. Lleva ahora una NOTA DE LECTURA
  que lo declara NO-AUDITABLE POR DISEÑO para el cruce de IDs, y cita las normas que ya
  gobiernan sus tramos: el Block 3 cita **CAL-22** (la Limbs API es agnóstica por diseño pero
  NPC-only en la práctica — esa norma existe justamente para que este tramo no se lea como
  servido) y **COA-7**; el boundary-debt de scavenger cita **CRG-47** (el dueño de una
  frontera se decide EN DISEÑO); la deuda heredada cita **CAL-21**. **[APLICADO 2026-07-19]**

Verificación: checker en verde sobre 207 IDs + suite 12/12. Sin superficie de runtime.

---

## PARCHES DE sesión Reparación del gate de coherencia (acta 2026-07-22) — 2026-07-22

Tanda de reparación documental propuesta por el gate de coherencia en su corrida COMPLETO del
2026-07-22 (`../../corpus/docs/auditorias/2026-07-22_coherencia_docs.md`; el gate propone, el
autor dispone). Acá lo que toca a este repo. Solo prosa; **ninguna norma cambió de contenido**.

- PARCHE 1 — **Hallazgo 2.2 [MEDIA] del acta:** `docs/Caliber_Architecture.md` §8 metía «lectura
  de pools de limbs» DENTRO del subconjunto contratado, contradiciendo a **CAL-12**, al Lua y a
  `CORPUS_Architecture.md:133` («lo único bajo contrato hoy es `HealLimbs`»). Se reemplaza por
  «solo `HealLimbs`»; los pools `npc.Caliber_HP_*` se aclaran como dominio interno NPC-only —no
  superficie de lectura contratada, renombrables sin romper contrato— y `CALIBER.Limbs.*` vacío
  en Block 2. Alinea el texto con su propio code-block (que ya mostraba `Limbs.*` vacío).
  **[APLICADO 2026-07-22]**
- PARCHE 2 — **Contrato-vs-árbol PARCIAL 1 del acta:** el contrato #1 del `CLAUDE.md`
  generalizaba «Cada archivo abre con `local CALIBER=…`», falsado por `shared.lua` y
  `client_options.lua` (no consumen la tabla) y por el stool (la resuelve lazy dentro de
  funciones). Se acota el alcance a «cada archivo **que consume la tabla del módulo** la
  cachea…»; la protección no-globals (COR-2) queda intacta. **[APLICADO 2026-07-22]**

Verificación: sin superficie de runtime (solo docs). El checker de IDs corre en cada commit que
toca superficie normativa. Cambios trazables al acta (§7.1: el código manda). No commiteado ni
pusheado (GIT-7).
