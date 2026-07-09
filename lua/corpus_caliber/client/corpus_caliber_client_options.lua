-- corpus_caliber_client_options.lua — panel de ajustes (menú Q → Utilities → Corpus → Caliber)
-- Migrado desde ADS 2.0 (cl_ads.lua). Los 4 paneles de convars de ADS (Armor/Limbs/
-- Shields/Scavenger) se apilan en la entrada única que registra Corpus.UI.RegisterTab;
-- un botón abre el browser de configuración por-NPC (corpus_caliber_browser.lua).

local function BuildArmorPanel(p)
    p:Help("Armor")

    p:Help("System Toggles")
    p:CheckBox("Enable NPC armor system","caliber_enabled_npc")
    p:CheckBox("Enable Player armor system","caliber_enabled_ply")
    p:CheckBox("Engine hitgroup compensation (limb/head HP)","caliber_engine_hitgroup_compensation")

    p:Help("Global Armor Defaults (fallback when no override)")
    p:NumSlider("NPC Min Armor","caliber_min_arm",0,100,0)
    p:NumSlider("NPC Max Armor","caliber_max_arm",0,100,0)
    p:NumSlider("Player Spawn Armor","caliber_ply_arm",0,100,0)
    p:NumSlider("Min Reduction %","caliber_red_min",0,100,0)
    p:NumSlider("Max Reduction %","caliber_red_max",0,100,0)

    p:Help("Zonal Armor Effectiveness")
    p:NumSlider("Helmet Effectiveness","caliber_helmet_mult",0,1,2)
    p:NumSlider("Blast Effectiveness","caliber_blast_mult",0,1,2)
    p:NumSlider("Crush Effectiveness","caliber_crush_mult",0,1,2)

    p:Help("Global Damage Multipliers (override per classname via toolgun)")
    p:NumSlider("Head damage mult","caliber_limb_mult_head",0,5,2)
    p:NumSlider("Chest damage mult","caliber_limb_mult_chest",0,5,2)
    p:NumSlider("Arm damage mult","caliber_limb_mult_arm",0,5,2)
    p:NumSlider("Leg damage mult","caliber_limb_mult_leg",0,5,2)

    p:Help("Detection")
    p:CheckBox("Enable VJ auto-detect","caliber_vj_autodetect")

    p:Help("Effects")
    p:CheckBox("Enable Armor Hit Sound (metallic clang, hard plates)","caliber_sound_enabled")
    p:CheckBox("Enable Gunshot-Blocked Sound","caliber_gunshotblocked_enabled")
    p:CheckBox("Enable Headshot Sound","caliber_headshot_sound_enabled")
    p:CheckBox("Block FX: suppress blood when armor blocks","caliber_block_noblood_enabled")
    p:CheckBox("Block FX: metal spark on block","caliber_block_spark_enabled")
    p:CheckBox("Block FX: metal impact decal on block","caliber_block_decal_enabled")

    p:Help("Debug")
    p:CheckBox("Enable Debug Prints","caliber_debug")

    p:Help("Reset")
    p:Button("Reset Armor Settings to Default").DoClick = function()
        Derma_Query("Reset Armor Settings to defaults?","Caliber","Yes",function()
            RunConsoleCommand("caliber_enabled_npc","1")
            RunConsoleCommand("caliber_enabled_ply","1")
            RunConsoleCommand("caliber_engine_hitgroup_compensation","1")
            RunConsoleCommand("caliber_min_arm","0")
            RunConsoleCommand("caliber_max_arm","100")
            RunConsoleCommand("caliber_ply_arm","100")
            RunConsoleCommand("caliber_red_min","15")
            RunConsoleCommand("caliber_red_max","80")
            RunConsoleCommand("caliber_helmet_mult","0.5")
            RunConsoleCommand("caliber_blast_mult","0.5")
            RunConsoleCommand("caliber_crush_mult","0.5")
            RunConsoleCommand("caliber_limb_mult_head","1.0")
            RunConsoleCommand("caliber_limb_mult_chest","1.0")
            RunConsoleCommand("caliber_limb_mult_arm","1.0")
            RunConsoleCommand("caliber_limb_mult_leg","1.0")
            RunConsoleCommand("caliber_vj_autodetect","1")
            RunConsoleCommand("caliber_sound_enabled","1")
            RunConsoleCommand("caliber_gunshotblocked_enabled","1")
            RunConsoleCommand("caliber_headshot_sound_enabled","1")
            RunConsoleCommand("caliber_block_noblood_enabled","1")
            RunConsoleCommand("caliber_block_spark_enabled","1")
            RunConsoleCommand("caliber_block_decal_enabled","1")
            RunConsoleCommand("caliber_debug","0")
        end,"No")
    end
end

local function BuildLimbsPanel(p)
    p:Help("Limb HP")

    p:Help("System Toggle")
    p:CheckBox("Enable Limb HP System","caliber_limbs_enabled")

    p:Help("HP Pool Fractions (per limb, fraction of NPC max HP)")
    p:NumSlider("Head HP fraction","caliber_limb_head_frac",0,2,2)
    p:NumSlider("Arms HP fraction (per arm)","caliber_limb_arms_frac",0,2,2)
    p:NumSlider("Legs HP fraction (per leg)","caliber_limb_legs_frac",0,2,2)

    p:Help("Damage Transfer (fraction of damage that drains the pool)")
    p:NumSlider("Head damage transfer","caliber_limb_damage_transfer_head",0,3,2)
    p:NumSlider("Arms damage transfer","caliber_limb_damage_transfer_arms",0,3,2)
    p:NumSlider("Legs damage transfer","caliber_limb_damage_transfer_legs",0,3,2)

    p:Help("Debuff Intensity")
    p:NumSlider("Max accuracy penalty per arm","caliber_limb_accuracy_max_penalty_per_arm",0,5,2)
    p:NumSlider("Max accuracy penalty from head","caliber_limb_accuracy_max_penalty_head",0,5,2)
    p:NumSlider("Min speed mult per leg","caliber_limb_min_speed_mult_per_leg",0,1,2)

    p:Help("Head Stun Durations")
    p:NumSlider("Head stun 50% duration (s)","caliber_limb_head_stun_50_duration",0,5,1)
    p:NumSlider("Head stun 25% duration (s)","caliber_limb_head_stun_25_duration",0,10,1)

    p:Help("Reset")
    p:Button("Reset Limb HP Settings to Default").DoClick = function()
        Derma_Query("Reset Limb HP Settings to defaults?","Caliber","Yes",function()
            RunConsoleCommand("caliber_limbs_enabled","1")
            RunConsoleCommand("caliber_limb_head_frac","0.5")
            RunConsoleCommand("caliber_limb_arms_frac","0.5")
            RunConsoleCommand("caliber_limb_legs_frac","0.5")
            RunConsoleCommand("caliber_limb_damage_transfer_head","1.5")
            RunConsoleCommand("caliber_limb_damage_transfer_arms","0.7")
            RunConsoleCommand("caliber_limb_damage_transfer_legs","0.7")
            RunConsoleCommand("caliber_limb_accuracy_max_penalty_per_arm","1.0")
            RunConsoleCommand("caliber_limb_accuracy_max_penalty_head","0.5")
            RunConsoleCommand("caliber_limb_min_speed_mult_per_leg","0.5")
            RunConsoleCommand("caliber_limb_head_stun_50_duration","1.0")
            RunConsoleCommand("caliber_limb_head_stun_25_duration","2.5")
        end,"No")
    end
end

local function BuildScavengerPanel(p)
    p:Help("Scavenger")

    p:Help("System Toggle")
    p:CheckBox("Enable Scavenger","caliber_scavenger_enabled")

    p:Help("Drop Lifetime and Cooldowns")
    p:NumSlider("Drop lifetime (seconds)","caliber_scavenger_drop_lifetime",0,600,0)
    p:NumSlider("Post-drop cooldown (seconds)","caliber_scavenger_post_drop_cooldown",0,60,0)
    p:NumSlider("Drop ownership time (seconds)","caliber_scavenger_drop_ownership_time",0,300,0)

    p:Help("Detection")
    p:NumSlider("Search radius","caliber_scavenger_search_radius",100,3000,0)
    p:NumSlider("Pickup distance","caliber_scavenger_pickup_distance",10,200,0)
    p:NumSlider("Think interval (seconds)","caliber_scavenger_think_interval",0.1,5,1)

    p:Help("Behavior Toggles")
    p:CheckBox("Allow combat interrupt for better weapons","caliber_scavenger_interrupt_combat")
    p:CheckBox("Allow world weapons (map-spawned)","caliber_scavenger_allow_world_weapons")
    p:CheckBox("Force all NPCs to scavenge (ignore detection)","caliber_scavenger_force_all_npcs")

    p:Help("Retrieve Own Weapon Mode")
    p:Help("Armed NPCs never swap weapons. A disarmed NPC first tries to recover its own dropped weapon; if it fails, it falls back to normal scavenging. Timeout counts from the moment of the drop.")
    p:CheckBox("Retrieve own weapon (no upgrades)","caliber_scavenger_retrieve_own")
    p:NumSlider("Retrieve delay (seconds)","caliber_scavenger_retrieve_delay",0,10,1)
    p:NumSlider("Retrieve timeout (seconds)","caliber_scavenger_retrieve_timeout",5,120,0)

    p:Help("Movement Mode")
    local modeCombo = vgui.Create("DComboBox", p)
    modeCombo:SetTall(22)
    local currentMode = GetConVar("caliber_scavenger_movement_mode") and GetConVar("caliber_scavenger_movement_mode"):GetString() or "run"
    modeCombo:AddChoice("Run", "run", currentMode == "run")
    modeCombo:AddChoice("Walk", "walk", currentMode == "walk")
    modeCombo.OnSelect = function(_, _, _, data)
        RunConsoleCommand("caliber_scavenger_movement_mode", data)
    end
    p:AddItem(modeCombo)

    p:Help("Debug")
    p:CheckBox("Scavenger debug prints","caliber_scavenger_debug")

    p:Help("Reset")
    p:Button("Reset Scavenger Settings to Default").DoClick = function()
        Derma_Query("Reset Scavenger Settings to defaults?","Caliber","Yes",function()
            RunConsoleCommand("caliber_scavenger_enabled","1")
            RunConsoleCommand("caliber_scavenger_drop_lifetime","60")
            RunConsoleCommand("caliber_scavenger_post_drop_cooldown","8")
            RunConsoleCommand("caliber_scavenger_drop_ownership_time","30")
            RunConsoleCommand("caliber_scavenger_search_radius","800")
            RunConsoleCommand("caliber_scavenger_pickup_distance","40")
            RunConsoleCommand("caliber_scavenger_think_interval","0.5")
            RunConsoleCommand("caliber_scavenger_interrupt_combat","0")
            RunConsoleCommand("caliber_scavenger_allow_world_weapons","0")
            RunConsoleCommand("caliber_scavenger_force_all_npcs","0")
            RunConsoleCommand("caliber_scavenger_retrieve_own","0")
            RunConsoleCommand("caliber_scavenger_retrieve_delay","2")
            RunConsoleCommand("caliber_scavenger_retrieve_timeout","20")
            RunConsoleCommand("caliber_scavenger_movement_mode","run")
            RunConsoleCommand("caliber_scavenger_debug","0")
        end,"No")
    end
end

local function BuildShieldPanel(p)
    p:Help("Energy Shields")

    p:Help("System Toggle")
    p:CheckBox("Enable Energy Shield system","caliber_shield_enabled")

    p:Help("Global Shield Tuning (per-NPC setup lives in the Caliber Configuration browser, Energy Shield tab)")
    p:NumSlider("Shield damage mult","caliber_shield_damage_mult",0,10,2)
    p:NumSlider("Plasma drain mult","caliber_shield_plasma_mult",1,10,2)
    p:NumSlider("EMP recharge lockout (s)","caliber_shield_emp_lockout",0,60,1)
    p:NumSlider("Recharge think interval (s)","caliber_shield_think_interval",0.05,1,2)

    p:Help("Effects")
    p:CheckBox("Shield sounds (hits / collapse / charge)","caliber_shield_sounds")
    p:CheckBox("Shield bubble (client)","caliber_shield_fx_bubble")
    p:CheckBox("Shield particles (client)","caliber_shield_fx_particles")

    p:Help("Weapon plasma/EMP flags live in the Weapons tab of the browser (hand-curated).")

    p:Help("Reset")
    p:Button("Reset Energy Shield Settings to Default").DoClick = function()
        Derma_Query("Reset Energy Shield Settings to defaults?","Caliber","Yes",function()
            RunConsoleCommand("caliber_shield_enabled","1")
            RunConsoleCommand("caliber_shield_damage_mult","1.0")
            RunConsoleCommand("caliber_shield_plasma_mult","2.0")
            RunConsoleCommand("caliber_shield_emp_lockout","8.0")
            RunConsoleCommand("caliber_shield_think_interval","0.1")
            RunConsoleCommand("caliber_shield_sounds","1")
            RunConsoleCommand("caliber_shield_fx_bubble","1")
            RunConsoleCommand("caliber_shield_fx_particles","1")
        end,"No")
    end
end

-- Entrada única en el menú Q vía la primitiva Corpus.UI.RegisterTab
-- (Caliber_Architecture.md §6): Utilities → Corpus → Caliber. Los cuatro paneles de
-- ADS (Armor/Limbs/Shields/Scavenger) quedan apilados como secciones del panel; el
-- botón abre el browser de configuración por-NPC (browser, 6 sub-tabs internos).
local function BuildCaliberTab(p)
    p:Help("Caliber — combate: armadura zonal, escudos de energía, HP de extremidades, penetración balística.")
    p:Button("Open Caliber Configuration (per-NPC browser)").DoClick = function()
        RunConsoleCommand("caliber_browser")
    end
    BuildArmorPanel(p)
    BuildLimbsPanel(p)
    BuildShieldPanel(p)
    BuildScavengerPanel(p)
end

Corpus.UI.RegisterTab("caliber", "Caliber", BuildCaliberTab)
