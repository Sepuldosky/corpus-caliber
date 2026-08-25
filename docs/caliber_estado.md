# Caliber — Estado de HOY

> **Foto del AHORA**, volátil. Es lo primero que se lee al retomar el módulo —
> **antes** que el doc de arquitectura. Se actualiza **en sitio** (no se agregan
> secciones ni historial). El historial vive en `git` + [`CHANGELOG.md`](CHANGELOG.md).
> Si crece de una pantalla, está mal redactado: recortar.

**Última actualización:** 2026-08-22 (paridad ADS verificada en juego el 2026-07-09 — Block 2 CERRADO, commiteado y publicado en GitHub, `main`; los docs pasaron la **pasada de veracidad del 2026-07-14**. El 2026-07-30 entra, se verifica en juego y se publica el primer fix de runtime post-Block 2. El 2026-08-17 entra, se verifica en juego y se publica un segundo fix de runtime — el árbol está **al día con `origin/main`**. El 2026-08-22 entran DOS sesiones. La primera, de **ORIENTACIÓN sin código**: releva el estado real del lado jugador contra el código y vota el alcance del módulo — orden y votos en [`caliber_roadmap.txt`](caliber_roadmap.txt) `[1]`. La segunda abre el **tramo 0 del Block 3**. El 2026-08-22 el autor **corre la planilla en juego** (12/13) y el 2026-08-23 el tramo 0 **CIERRA**: el número medido baja a los docs, el contrato Cargo↔Caliber se documenta en `Caliber_Architecture.md` §13, y una **ronda 2** de 4 filas (3/4, y la que falta no bloquea) cierra el paso 1 entero midiendo el escalado de hitgroup sobre las siete zonas. El **2026-08-25 se escribe el paso 2**: el autor vota la decisión abierta —`ply:Armor()` es el **ALMACÉN** del pool del escudo, **CAL-27**— y baja el código, la sección §13.9 y la planilla **K** de 16 filas. **NADA de eso corrió en juego todavía**)

---

## Qué existe hoy

- **Block 2 (migración ADS 2.0 → Caliber) cerrado y verificado en juego.** Los 10
  archivos Lua de ADS migrados a módulo de Corpus (rename mecánico + wiring sobre las
  6 primitivas, sin reescritura de dominio) y **confirmados funcionando por el autor
  el 2026-07-09**: cvars `caliber_*` presentes, tab en Q → Utilities → Corpus →
  Caliber, sin problemas. Todo el CHANGELOG en `[APLICADO]`. Mapa archivo → rol en
  [`../CLAUDE.md`](../CLAUDE.md).
- **Boot robusto al orden de carga:** autorun corre alfabético fusionado entre addons
  y el init ordena antes que el framework; el boot se difiere al hook `Initialize`
  cuando Corpus aún no existe (falla ruidoso si de verdad falta). **Patrón template
  para los otros cuatro módulos.**
- **Config real del autor migrada (one-time, fuera del repo):** `data/ads/ads_config.json`
  → `data/corpus/caliber/config.json` (278 wl / 284 armor / 65 bl / 9 curated). Sin
  importador en código: el contrato clean-slate sigue vigente.
- **Primitivas cableadas:** persistencia (keys `config` + `scav_weights`), net (24
  mensajes `corpus_caliber_*`), log, UI (tab único + browser por `caliber_browser`).
  Namespace = tabla única registrada; cero globals sueltos.

## Remanentes / deuda conocida

- **Deuda heredada de ADS, viaja SIN tocar** (§10 de la arquitectura): decal
  `Caliber_Ricochet` inerte, `DNumSlider` en tab Limbs/WL, doble mult de zona ARC9
  (Front 4, ~50% menos daño a miembros), cache de hitgroups por modelo.
- **Sin `addon.json` todavía** — no se puede empaquetar para Workshop. No bloquea el
  testeo local: los repos están montados por **junction** en `garrysmod/addons/`, así
  que editar el repo se refleja directo en el juego.
- **Limbs API NPC-only** (§9.b): `HealLimbs` y los pools asumen `npc.Caliber_HP_*` /
  `IsNPC()`. Se vuelve agnóstica recién con el pipeline de armadura de jugador.
- **El reparto de `ply:Armor()` está MEDIDO** (en juego, 2026-08-22, planilla
  `dev/checks/caliber-b3-tramo0.html`, sección **J**). La cita de HL2 que se venía usando
  era **correcta en su primera mitad y falsa en la segunda**: la vida se lleva el 0,2 del
  daño, pero el pool se lleva **0,8 y no 0,4** — `ARMOR_BONUS` acá es 1,0, o sea que **un
  punto de armadura absorbe exactamente un punto de daño**. Con el pool escaso absorbe
  punto por punto lo que le queda y la vida se lleva el resto. **`DMG_FALL` no toca el
  pool.** Y el **escalado de hitgroup** quedó medido en la ronda 2 sobre las siete zonas:
  cabeza **2,00**, torso y estómago 1,00, los cuatro miembros **0,25** — y es de
  `GM:ScalePlayerDamage` del gamemode base, **en Lua**, no del engine. Consecuencia para el paso 2: `ply:Armor()` y los puntos de escudo **ya están en
  la misma unidad**, y el `hev` de pool 50 contra el tope de 100 es una perilla de balance
  y no una contradicción de escalas.
- **El contrato de datos Cargo↔Caliber está DISEÑADO y votado** — `Caliber_Architecture.md`
  §13, sección autocontenida, con las cinco normas que acuña (CAL-24/25/26, CRG-77/78) ya
  en `corpus/docs/ids.yaml`. Las cinco nacen `INTENCION` **a propósito**: existen para que
  el paso 2 se escriba contra ellas.
- **Los dos controles muertos del panel Options salieron** (verificado en juego el
  2026-08-22, fila J1). `caliber_ply_arm` se retiró entera; `caliber_enabled_ply` sigue
  viva porque es la perilla real del tramo. ⚠ Las dos estaban **archivadas** en
  `cfg/server.vdf`, así que bajarles el default nunca las habría movido, y el
  `caliber_ply_arm 100` que quedó ahí **volvería solo** el día que alguien vuelva a
  declarar ese nombre.
- **El instrumento existe y tuvo un defecto que la corrida destapó:** `caliber_ply_probe`
  (+ `caliber_ply_probe_reset`) apuntaba al **origen del hueso**, que está en la
  articulación y cae dentro del hitbox del padre — pidiendo cabeza pegaba en pecho.
  Arreglado el 2026-08-23 (centro del hitbox + tiro radial desde afuera), **y ahora una
  medición con el hitgroup equivocado se DESCARTA sin imprimir cocientes**: antes imprimía
  el aviso y debajo el resultado completo, y el número le ganaba al aviso.
- **El paso 2 está ESCRITO y SIN CORRER EN JUEGO** (planilla `dev/checks/caliber-b3-paso2.html`,
  sección **K**, 16 filas). El módulo **ya tiene punto de entrada de daño para el jugador**: un
  hook `EntityTakeDamage` (`Caliber_Core_Player`) y **no** `ScalePlayerDamage` — aquél sólo cubre
  trace attacks, el hitgroup no hacía falta porque el escudo es un pool global, y no estando en
  esa cadena la trampa del `return` deja de ser una disciplina. ⚠ Se descubrió que
  **`EntityTakeDamage` tiene la MISMA trampa** (`GM:EntityTakeDamage` también es método del
  gamemode) y no estaba escrita en ningún lado. El ciclo de vida del escudo dejó de ser NPC-only
  (`ShieldEnts`, `PlayerSpawn`, `PlayerDeath`), y el pool vive en `ply:Armor()` vía
  `PoolGet`/`PoolSet` con `sh.onArmor` de discriminante — nunca `IsPlayer()`.
- **La anulación del goteo tiene DOS casos y sólo uno hubo que pelearlo.** En tres de los cuatro
  desenlaces no hay nada que anular: al absorber y al reventar el daño queda en cero (no-overflow,
  CAL-15) y **con daño cero los dos lados del reparto son cero**; con el escudo caído el pool ya
  es cero. El único que pelea es el **bypass con pool arriba**, donde se le **esconde el pool** al
  engine — apoyado en la fila 3 de §13.0, medida, no citada.
- **⚠ DOS AFIRMACIONES DE ESTE PASO ESTÁN LEÍDAS Y NO MEDIDAS, y tienen fila propia.** (a) que el
  techo de `ply:Armor()` se pueda mover por encima de 100 — es `PLAYER.MaxArmor` del gamemode
  base, no del engine, **el mismo hallazgo de forma que §13.0 hizo con el hitgroup**, pero que
  `SetArmor` no clampee igual **no se comprobó** (fila **K4**); (b) en qué orden corren el reparto
  del engine y `PostEntityTakeDamage` (fila **K16**). En las dos, **un FALLA es el hallazgo**.
- **⚠ El argumento `armor` de `caliber_ply_probe` es ahora el POOL DEL ESCUDO** — consecuencia de
  CAL-27 sobre el instrumento. Y en las filas con escudo **no se leen sus cocientes**: el probe
  observa en `EntityTakeDamage` y el punto de entrada vive en ese mismo evento, así que el orden
  no está determinado. Se lee `perdido hp=… armor=…`, que no depende del orden de los hooks.
- **Lo que se declaró y NO se arregló:** el tope literal `100` de `cargo_hl2_battery` (§13.5)
  **sigue en pie y es de Cargo** — una batería sobre un `hev` de 50 cargaría el doble de lo que el
  escudo puede tener. Y `DMG_DROWN`/`DMG_POISON`/`DMG_RADIATION` **drenan** el escudo del jugador:
  HL2 los excluye del reparto, pero en este build **no se midieron** y por eso no entraron a la
  lista de bypass.
- **Ruido de pasos recurrente en NPCs:** confirmado **externo a Corpus/Caliber** (se
  reproduce con el módulo inerte; locomoción paridad exacta con ADS). Fuera de scope.

## Próximo paso

1. **CORRER LA PLANILLA K EN JUEGO.** `dev/checks/caliber-b3-paso2.html`, 16 filas. Hasta que
   corra, **los parches 1-7 del CHANGELOG del 2026-08-25 son `[PENDIENTE]`** y el paso 2 no está
   cerrado. Las filas que más importan no son las que prueban que anduvo: son los **controles
   negativos** (K13, K14, K15, K9) y las **dos que miden lo que se escribió sin medir** (K4, K16).
2. **Recién después, el paso 3 del tramo:** la indirección **hitgroup → SLOT DE ZONA** en el
   perfil de armadura — el único cambio estructural del tramo, y lo que CRG-77 necesita para que
   Cargo pueda expresar sus `condition_zones`. ⚠ Ese día el punto de entrada del jugador
   **tiene que resolver el hitgroup por su cuenta** (`ply:LastHitGroup()`): `EntityTakeDamage` no
   lo trae, y hoy no hacía falta porque el escudo es un pool global. Está declarado en §13.9.
3. **Y el paso 4, el último:** la pestaña *Armor (Player)* del Configurator, indexada por
   playermodel. Hoy la identidad del jugador es el classname `"player"` y nada más.

---

*Rumbo / qué sigue → [`caliber_roadmap.txt`](caliber_roadmap.txt). Diseño → [`Caliber_Architecture.md`](Caliber_Architecture.md).
Metodología → [`../../corpus/docs/corpus_flujo_trabajo.txt`](../../corpus/docs/corpus_flujo_trabajo.txt).*
