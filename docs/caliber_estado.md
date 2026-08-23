# Caliber — Estado de HOY

> **Foto del AHORA**, volátil. Es lo primero que se lee al retomar el módulo —
> **antes** que el doc de arquitectura. Se actualiza **en sitio** (no se agregan
> secciones ni historial). El historial vive en `git` + [`CHANGELOG.md`](CHANGELOG.md).
> Si crece de una pantalla, está mal redactado: recortar.

**Última actualización:** 2026-08-22 (paridad ADS verificada en juego el 2026-07-09 — Block 2 CERRADO, commiteado y publicado en GitHub, `main`; los docs pasaron la **pasada de veracidad del 2026-07-14**. El 2026-07-30 entra, se verifica en juego y se publica el primer fix de runtime post-Block 2. El 2026-08-17 entra, se verifica en juego y se publica un segundo fix de runtime — el árbol está **al día con `origin/main`**. El 2026-08-22 entra una sesión de **ORIENTACIÓN, sin código**: se releva el estado real del lado jugador contra el código y se vota el alcance del módulo — orden y votos en [`caliber_roadmap.txt`](caliber_roadmap.txt) `[1]`)

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
- **Dos controles del panel Options prometen un sistema que NO EXISTE** (relevado el
  2026-08-22): el checkbox *"Enable Player armor system"* y el slider *"Player Spawn
  Armor"*. `caliber_ply_arm` se crea en `corpus_caliber_core.lua:7` y **no se lee en
  ninguna parte del módulo**; `caliber_enabled_ply` sólo se lee en `IsArmored`/
  `GetArmorReason`, cuya rama de jugador es alcanzable **únicamente desde `InspectNPC`**
  (dump de debug). El único hook de daño del módulo es `ScaleNPCDamage`, que el engine
  no dispara para jugadores. **Se apagan o se marcan ANTES de medir nada sobre el
  jugador** — es la precondición del paso 1 del tramo (roadmap `[1]`).
- **Ruido de pasos recurrente en NPCs:** confirmado **externo a Corpus/Caliber** (se
  reproduce con el módulo inerte; locomoción paridad exacta con ADS). Fuera de scope.

## Próximo paso

1. **Block 3 de Caliber:** pipeline de armadura de jugador (alcance nuevo, NPC→agnóstico).
   El diseño **NO cerró**: el paso 1 es una **medición** —el reparto real de `ply:Armor()`
   en Gmod— y no código. Orden de los cuatro pasos y lo votado el 2026-08-22, en
   [`caliber_roadmap.txt`](caliber_roadmap.txt) `[1]`.

---

*Rumbo / qué sigue → [`caliber_roadmap.txt`](caliber_roadmap.txt). Diseño → [`Caliber_Architecture.md`](Caliber_Architecture.md).
Metodología → [`../../corpus/docs/corpus_flujo_trabajo.txt`](../../corpus/docs/corpus_flujo_trabajo.txt).*
