# Caliber — Estado de HOY

> **Foto del AHORA**, volátil. Es lo primero que se lee al retomar el módulo —
> **antes** que el doc de arquitectura. Se actualiza **en sitio** (no se agregan
> secciones ni historial). El historial vive en `git` + [`CHANGELOG.md`](CHANGELOG.md).
> Si crece de una pantalla, está mal redactado: recortar.

**Última actualización:** 2026-08-22 (paridad ADS verificada en juego el 2026-07-09 — Block 2 CERRADO, commiteado y publicado en GitHub, `main`; los docs pasaron la **pasada de veracidad del 2026-07-14**. El 2026-07-30 entra, se verifica en juego y se publica el primer fix de runtime post-Block 2. El 2026-08-17 entra, se verifica en juego y se publica un segundo fix de runtime — el árbol está **al día con `origin/main`**. El 2026-08-22 entran DOS sesiones. La primera, de **ORIENTACIÓN sin código**: releva el estado real del lado jugador contra el código y vota el alcance del módulo — orden y votos en [`caliber_roadmap.txt`](caliber_roadmap.txt) `[1]`. La segunda abre el **tramo 0 del Block 3**. El 2026-08-22 el autor **corre la planilla en juego** (12/13) y el 2026-08-23 el tramo 0 **CIERRA**: el número medido baja a los docs, el contrato Cargo↔Caliber se documenta en `Caliber_Architecture.md` §13, y una **ronda 2** de 4 filas (3/4, y la que falta no bloquea) cierra el paso 1 entero midiendo el escalado de hitgroup sobre las siete zonas)

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
- **El módulo sigue sin punto de entrada de daño para el jugador**: el único hook es
  `ScaleNPCDamage`, que el engine no dispara para jugadores. Eso es el paso 2.
- **Ruido de pasos recurrente en NPCs:** confirmado **externo a Corpus/Caliber** (se
  reproduce con el módulo inerte; locomoción paridad exacta con ADS). Fuera de scope.

## Próximo paso

1. **El paso 2 del tramo, y ya no falta nada para escribirlo.** Bajar el mapeo
   `ply:Armor()` = pool del escudo y anular el goteo del 0,2, replicando que `DMG_FALL` no
   toca el pool. Se escribe contra [`Caliber_Architecture.md`](Caliber_Architecture.md)
   §13, que tiene el contrato y los tres números.
2. **Ojo al escribirlo:** `caliber_engine_hitgroup_compensation` **no se le aplica al
   jugador** — el escalado de hitgroup ya viene aplicado desde `GM:ScalePlayerDamage` antes
   de que el pipeline lo vea, así que dividir otra vez lo contaría dos veces.
3. **Deuda chica del instrumento, `[PENDIENTE]` de una pasada corta:** los dos parches del
   2026-08-23 — un argumento no numérico corta, y el radial se aplana sólo hacia abajo. El
   segundo arregla un **sorteo**, así que su criterio es tres corridas seguidas, no una.

---

*Rumbo / qué sigue → [`caliber_roadmap.txt`](caliber_roadmap.txt). Diseño → [`Caliber_Architecture.md`](Caliber_Architecture.md).
Metodología → [`../../corpus/docs/corpus_flujo_trabajo.txt`](../../corpus/docs/corpus_flujo_trabajo.txt).*
