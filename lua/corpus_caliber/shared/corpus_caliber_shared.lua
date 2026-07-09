-- corpus_caliber_shared.lua — registro compartido de decal/partículas (server Y cliente)
-- Migrado desde ADS 2.0 (ads_shared.lua).
-- game.AddDecal debe existir en ambos realms: el server emite el decal vía
-- util.Decal (networked) y el cliente lo pinta. Este archivo es la única
-- fuente de verdad del nombre y los materiales (si divergen entre realms,
-- el decal no se pinta o pinta otra cosa).
AddCSLuaFile()

-- Decal de impacto metálico para bloqueos de armadura (Block FX): se pinta
-- ENCIMA del gunshot de flesh que aplica el efecto Impact del cliente.
-- Materiales del grupo "Metal.Shot" de HL2; con tabla, el engine elige uno
-- al azar por aplicación. Elección final sujeta a verificación in-game
-- (alternativa: decal built-in "Impact.Metal").
game.AddDecal("Caliber_Ricochet", {
    "decals/metal/shot1_subrect",
    "decals/metal/shot2_subrect",
    "decals/metal/shot3_subrect",
    "decals/metal/shot4_subrect",
    "decals/metal/shot5_subrect",
})

-- Partículas del escudo de energía (Energy Shields), rescatadas de "Halo Energy
-- Shield" de Speedy Von Gofast — créditos en README. Los nombres de sistema
-- (spdy_*) y las rutas de materiales están HORNEADOS dentro de los .pcf, por eso
-- los archivos conservan sus nombres/rutas originales. El set colorable
-- (spdy_halo_3_custom_*) existía en el mod pero nunca se usó: Caliber lo intenta
-- para shield_color custom (tintado por control point 4), con fallback al tipo.
game.AddParticles("particles/speedy_energy_shield_pfx.pcf")
game.AddParticles("particles/speedy_energy_shield_colorable_pfx.pcf")

PrecacheParticleSystem("spdy_halo_3_spartan_shield_impact_effect")
PrecacheParticleSystem("spdy_halo_3_spartan_shield_deplete")
PrecacheParticleSystem("spdy_halo_3_spartan_shield_deplete_arcs")
PrecacheParticleSystem("spdy_halo_3_spartan_shield_recharge")
PrecacheParticleSystem("spdy_halo_3_elite_shield_impact_effect")
PrecacheParticleSystem("spdy_halo_3_elite_shield_deplete")
PrecacheParticleSystem("spdy_halo_3_elite_shield_deplete_arcs")
PrecacheParticleSystem("spdy_halo_3_elite_shield_recharge")
PrecacheParticleSystem("spdy_halo_3_custom_shield_impact_effect")
PrecacheParticleSystem("spdy_halo_3_custom_shield_deplete")
PrecacheParticleSystem("spdy_halo_3_custom_shield_deplete_arcs")
PrecacheParticleSystem("spdy_halo_3_custom_shield_recharge")
