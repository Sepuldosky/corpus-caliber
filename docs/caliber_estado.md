# Caliber — Estado de HOY

> **Foto del AHORA**, volátil. Es lo primero que se lee al retomar el módulo —
> **antes** que el doc de arquitectura. Se actualiza **en sitio** (no se agregan
> secciones ni historial). El historial vive en `git` + [`CHANGELOG.md`](CHANGELOG.md).
> Si crece de una pantalla, está mal redactado: recortar.

**Última actualización:** 2026-08-22 (paridad ADS verificada en juego el 2026-07-09 — Block 2 CERRADO, commiteado y publicado en GitHub, `main`; los docs pasaron la **pasada de veracidad del 2026-07-14**. El 2026-07-30 entra, se verifica en juego y se publica el primer fix de runtime post-Block 2. El 2026-08-17 entra, se verifica en juego y se publica un segundo fix de runtime — el árbol está **al día con `origin/main`**. El 2026-08-22 entran DOS sesiones. La primera, de **ORIENTACIÓN sin código**: releva el estado real del lado jugador contra el código y vota el alcance del módulo — orden y votos en [`caliber_roadmap.txt`](caliber_roadmap.txt) `[1]`. La segunda abre el **tramo 0 del Block 3**: retira los dos controles muertos y deja escrito el instrumento de medición. **Sin verificar en juego todavía** — el CHANGELOG está en `[PENDIENTE]`)

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
- **Los dos controles muertos del panel Options ya no prometen nada** (retirados el
  2026-08-22, `[PENDIENTE]` de pasada en juego): el checkbox *"Enable Player armor system"*
  y el slider *"Player Spawn Armor"* salieron de la UI. `caliber_ply_arm` se retiró entera
  —no la leía nadie en los 11 archivos del módulo—; `caliber_enabled_ply` **sigue viva**,
  porque la leen `IsArmored`/`GetArmorReason` y va a ser la perilla real del tramo: lo que
  se sacó es la promesa visible, no el mecanismo. ⚠ Las dos estaban **archivadas** en
  `cfg/server.vdf` con valor, así que bajarles el default nunca las habría movido, y el
  `caliber_ply_arm 100` que quedó ahí **volvería solo** el día que alguien vuelva a declarar
  ese nombre — el motivo está escrito en el sitio donde se creaba.
- **El instrumento de medición está escrito y sin correr:** `caliber_ply_probe` (+ su
  `caliber_ply_probe_reset`), admin-only, aplica daño conocido al jugador y observa en tres
  puntos —`ScalePlayerDamage`, `EntityTakeDamage`, y después del golpe— imprimiendo la
  armadura además del daño. La planilla es `dev/checks/caliber-b3-tramo0.html`, 12 filas, la
  primera de Caliber. **El módulo sigue sin punto de entrada de daño para el jugador**: el
  único hook es `ScaleNPCDamage`, que el engine no dispara para jugadores. Eso es el paso 2
  y no se escribe antes del dato.
- **Ruido de pasos recurrente en NPCs:** confirmado **externo a Corpus/Caliber** (se
  reproduce con el módulo inerte; locomoción paridad exacta con ADS). Fuera de scope.

## Próximo paso

1. **Correr `dev/checks/caliber-b3-tramo0.html` en juego.** Es el paso 1 del tramo `[1]`: una
   **medición**, no código. Sale de ahí el reparto real de `ply:Armor()` —cuánto del daño va
   a la vida y cuánto al pool— y la respuesta a si el paso 2 puede vivir en
   `ScalePlayerDamage` o hay que irse a `EntityTakeDamage`. Un FALLA en una fila de medición
   **es el hallazgo, no un defecto**. El número baja al roadmap `[1]`, donde hoy dice *"es una
   cita del engine, no una medición sobre este juego"*.
2. **Con el dato en mano, el paso 2:** bajar el mapeo `ply:Armor()` = pool del escudo y anular
   el goteo del engine para el evento de daño.
3. **La parte B del tramo, en paralelo y sin código:** el contrato de datos Cargo↔Caliber
   (siete decisiones, B1–B7). Es una sesión de diseño que termina en **votos del autor** y baja
   a `Caliber_Architecture.md` recién al cerrar. Dos piezas de Cargo aparecieron ya
   construidas y sin que ningún doc lo registrara: la batería `cargo_hl2_battery`, que escribe
   `ply:Armor()`, y la barra *"HL2 Armor"* del StatusPanel, que ya lo dibuja.

---

*Rumbo / qué sigue → [`caliber_roadmap.txt`](caliber_roadmap.txt). Diseño → [`Caliber_Architecture.md`](Caliber_Architecture.md).
Metodología → [`../../corpus/docs/corpus_flujo_trabajo.txt`](../../corpus/docs/corpus_flujo_trabajo.txt).*
