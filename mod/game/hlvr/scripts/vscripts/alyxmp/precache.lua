-- Spawned as a logic_script so the engine runs Precache() before we spawn avatars.
function Precache(context)
    PrecacheModel("models/characters/alyx/alyx.vmdl", context)
    PrecacheModel("models/characters/combine_grunt/combine_grunt.vmdl", context)
    PrecacheModel("models/weapons/vr_alyxgun/vr_alyxgun.vmdl", context)
    PrecacheModel("models/weapons/vr_shotgun/vr_flip_shotgun_body.vmdl", context)
    PrecacheModel("models/weapons/vr_ipistol/vr_ipistol.vmdl", context)
    PrecacheResource("particle", "particles/weapon_fx/muzzleflash_pistol.vpcf", context)
    PrecacheResource("particle", "particles/weapon_fx/muzzleflash_heavy_shotgun.vpcf", context)
    PrecacheResource("particle", "particles/weapon_fx/muzzleflash_player_rapidfire.vpcf", context)
    PrecacheResource("particle", "particles/tracer_fx/pistol_tracer.vpcf", context)
    PrecacheResource("particle", "particles/tracer_fx/smg_tracer.vpcf", context)
    PrecacheResource("particle", "particles/impact_fx/impact_concrete.vpcf", context)
end
