#include <sourcemod>

#include <tf2>
#include <tf2_stocks>

#include <sdkhooks>
#include <sdktools>
#include <dhooks>

#include <stocksoup/tf/weapon>
#include <stocksoup/var_strings>
#include <tf_custom_attributes>
#include <tf2utils>
#include <tf2wearables>

#include <dynamic_attribs>

#include <intmap>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_NAME         "Custom Attribute - Damage Depends On Ammo"
#define PLUGIN_AUTHOR       "Zabaniya001"
#define PLUGIN_DESCRIPTION  "Custom attribute that uses nosoop's framework. The more ammo you have, the more damage you do. Only sniper rifles."
#define PLUGIN_VERSION      "1.1.0"
#define PLUGIN_URL          "https://alliedmods.net"

#define GAMECONF "tf2.suza"

public Plugin myinfo = {
    name        =   PLUGIN_NAME,
    author      =   PLUGIN_AUTHOR,
    description =   PLUGIN_DESCRIPTION,
    version     =   PLUGIN_VERSION,
    url         =   PLUGIN_URL
}

// ||==========================================================================||
// ||                              GLOBAL VARIABLES                            ||
// ||==========================================================================||

enum DetourMode
{
    DetourMode_Pre,
    DetourMode_Post
}

enum struct Attribute 
{
    float fDamage;
    int iMax;
    bool bResetOnMiss;

    void Initialize(char[] sAttribute)
    {
        this.fDamage = ReadFloatVar(sAttribute, "damage_per_ammo", 0.0);
        this.iMax = ReadIntVar(sAttribute, "max_ammo", 0);
        this.bResetOnMiss = !!ReadIntVar(sAttribute, "reset_on_miss", 0);
    }
}

int iNumShotsThisTick[36];
int iNumHitsThisTick[36];

bool bHasAttribute[2048];

IntMap WeaponHash;

// ||==========================================================================||
// ||                               SOURCEMOD API                              ||
// ||==========================================================================||

public void OnPluginStart() 
{
    GameData conf = new GameData(GAMECONF);

    if(!conf)
        SetFailState("Failed to get gamedata: " ... GAMECONF);

    RegDetour(conf, "FX_FireBullets()", FX_FireBullets, DetourMode_Post);

    delete conf;

    WeaponHash = new IntMap();

    HookEvent("post_inventory_application", Event_OnPostInventoryApplication);

    // In case of late load.
    for(int iClient = 1; iClient <= MaxClients; iClient++)
    {
        if(IsClientInGame(iClient))
            OnClientPutInServer(iClient);
    }
    
    return;
}

public void OnClientPutInServer(int iClient)
{
    SDKHook(iClient, SDKHook_OnTakeDamageAlive,     OnTakeDamageAlive);
    SDKHook(iClient, SDKHook_OnTakeDamageAlivePost, OnTakeDamageAlivePost);

    return;
}

public void OnClientDisconnect(int client)
{
    iNumShotsThisTick[client]   =   0;
    iNumHitsThisTick[client]    =   0;

    return;
}

stock Handle RegDetour(Handle gameconf, const char[] name, DHookCallback callback, DetourMode mode = DetourMode_Post)
{
    Handle hDetour = DHookCreateFromConf(gameconf, name);
    if (!hDetour)
        SetFailState("Failed to setup detour for %s", name);

    if (!DHookEnableDetour(hDetour, !!mode, callback))
        SetFailState("Failed to detour %s.", name);

    return hDetour;
}

// ||==========================================================================||
// ||                                EVENTS                                    ||
// ||==========================================================================||

public void OnClientThink(int iClient)
{
    if(!IsClientInGame(iClient))
        return;

    int iWeapon = GetActiveWeapon(iClient);

    if(!IsValidEntity(iWeapon) || !bHasAttribute[iWeapon])
        return;

    if(iNumShotsThisTick[iClient] != iNumHitsThisTick[iClient])
    {
        TF2_SetWeaponClip(iWeapon, 1);

        if(HasEntProp(iClient, Prop_Send, "m_iDecapitations"))
            SetEntProp(iClient, Prop_Send, "m_iDecapitations", 0);
    }

    iNumShotsThisTick[iClient]  =   0;
    iNumHitsThisTick[iClient]   =   0;

    return;
}
/*
public void OnGameFrame()
{
    for(int iClient = 1; iClient <= MaxClients; iClient++)
    {
        if(!IsClientInGame(iClient))
            continue;

        int iWeapon = GetActiveWeapon(iClient);

        if(!IsValidEntity(iWeapon) || !bHasAttribute[iWeapon])
            continue;

        if(iNumShotsThisTick[iClient] != iNumHitsThisTick[iClient])
        {
            TF2_SetWeaponClip(iWeapon, 1);

            if(HasEntProp(iClient, Prop_Send, "m_iDecapitations"))
                SetEntProp(iClient, Prop_Send, "m_iDecapitations", 0);
        }

        iNumShotsThisTick[iClient]  =   0;
        iNumHitsThisTick[iClient]   =   0;
    }

    return;
}
*/
public void OnMapEnd()
{
    WeaponHash.Clear();

    return;
}

public void DynamicAttributes_ConfigReloaded()
{
    WeaponHash.Clear();

    return;
}

public void Event_OnPostInventoryApplication(Event event, const char[] name, bool dontBroadcast)
{
    int iClient = GetClientOfUserId(event.GetInt("userid"));

    if(!IsValidClient(iClient))
        return;

    SDKUnhook(iClient, SDKHook_PostThink, OnClientThink);

    for(eTF2LoadoutSlot eSlot = TF2LoadoutSlot_Primary; eSlot < TF2LoadoutSlot_Misc3; eSlot++)
    {
        int iWeapon = TF2_GetPlayerLoadoutSlot(iClient, eSlot);

        if(!IsValidEntity(iWeapon))
            continue;

        char sBuffer[100]; // We don't really care about it, we just want to see if the attribute exists
        if(!TF2CustAttr_GetString(iWeapon, "ammo dependent weapon", sBuffer, sizeof(sBuffer)))
            continue;

        SDKHook(iClient, SDKHook_PostThink, OnClientThink);

        HookWeapon(iClient, iWeapon);
    }

    return;
}

public void OnEntityDestroyed(int entity)
{
    if(entity <= 0)
        EntRefToEntIndex(entity);

    if(0 < entity < 2048)
        bHasAttribute[entity] = false;

    return;
}

public Action OnTakeDamageAlive(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
{
    if(!IsValidClient(victim) || !IsValidClient(attacker) || !IsValidEntity(weapon) || weapon <= 0 || attacker == victim)
        return Plugin_Continue;

    char sBuffer[32];

    if(!TF2CustAttr_GetString(weapon, "ammo dependent weapon", sBuffer, sizeof(sBuffer)))  // If the weapon doesn't have that attribute, it'll return 0 ( zero bytes written ).
    {
        bHasAttribute[weapon] = false;

        return Plugin_Continue;
    }

    bHasAttribute[weapon] = true; // Doing this so I don't have to call TF2CustAttr_GetString twice ( one here and one in OnTakeDamageAlivePost ). No performance hit this way.

    damage *= 1.0 + CalculateDamage(weapon);

    iNumHitsThisTick[attacker]++;

    return Plugin_Changed;
}

public void OnTakeDamageAlivePost(int victim, int attacker, int inflictor, float damage, int damagetype, int iWeapon, const float damageForce[3], const float damagePosition[3])
{
    if(!IsValidClient(victim) || !IsValidClient(attacker) || !IsValidEntity(iWeapon) || iWeapon <= 0 || attacker == victim)
        return;

    if(!bHasAttribute[iWeapon])
        return;

    int iDefinitionIndex = TF2_GetDefIndex(iWeapon);

    Attribute attribute;

    WeaponHash.GetArray(iDefinitionIndex, attribute, sizeof(attribute));

    if(!IsInvuln(victim) && TF2_GetWeaponClip(iWeapon) < attribute.iMax)
        TF2_GiveWeaponClip(iWeapon, 1);

    return;
}

// void FX_FireBullets( CTFWeaponBase *pWpn, int iPlayer, const Vector &vecOrigin, const QAngle &vecAngles, int iWeapon, int iMode, int iSeed, float flSpread, float flDamage /* = -1.0f */, bool bCritical /* = false*/ )

public MRESReturn FX_FireBullets(DHookParam hParams)
{
    int iWeapon = DHookGetParam(hParams, 1); // I'm sorry methodmap Gods, but the server I uploaded it on doesn't like it so i have to do this :pepega:
    int iPlayer = DHookGetParam(hParams, 2);

    if(!IsValidEntity(iWeapon) || !bHasAttribute[iWeapon])
        return MRES_Ignored;

    TF2_GiveWeaponClip(iWeapon, 1);

    iNumShotsThisTick[iPlayer]++;

    int iTarget = GetClientAimTarget(iPlayer);

    if(!IsValidClient(iTarget))
        return MRES_Ignored;

    if(TF2_GetClientTeam(iPlayer) == TF2_GetClientTeam(iTarget))
        iNumShotsThisTick[iPlayer] = 0;

    return MRES_Ignored;
}

// ||==========================================================================||
// ||                             Functions                                    ||
// ||==========================================================================||

public void HookWeapon(int iClient, int iWeapon)
{
    char sAttribute[128];

    bHasAttribute[iWeapon] = false;

    int iDefinitionIndex = TF2_GetDefIndex(iWeapon);

    Attribute attribute; // We don't need it, however most of the servers still run on SM 1.10 so we can't use ContainsKey. Unfortunate.

    if(!TF2CustAttr_GetString(iWeapon, "ammo dependent weapon", sAttribute, sizeof(sAttribute)))    // If the weapon doesn't have that attribute, it'll return 0 ( zero bytes written ).
        return;

    if(!WeaponHash.GetArray(iDefinitionIndex, attribute, sizeof(attribute)))
    {
        attribute.Initialize(sAttribute);

        WeaponHash.SetArray(iDefinitionIndex, attribute, sizeof(attribute));
    }

    SDKHook(iClient, SDKHook_PostThink, OnClientThink);

    bHasAttribute[iWeapon] = true;

    TF2_SetWeaponClip(iWeapon, 1);

    return;
}

float CalculateDamage(int iWeapon)
{
    Attribute attribute;

    int iDefinitionIndex = TF2_GetDefIndex(iWeapon);

    WeaponHash.GetArray(iDefinitionIndex, attribute, sizeof(attribute));

    if(attribute.fDamage <= 0.0)
        return 0.0;

    if(TF2_GetWeaponClip(iWeapon) > attribute.iMax + 1)
        TF2_SetWeaponAmmo(iWeapon, 2);

    return TF2_GetWeaponClip(iWeapon) * attribute.fDamage;
}

// ||==========================================================================||
// ||                           Internal Functions                             ||
// ||==========================================================================||

stock bool IsValidClient(int iClient)
{
    if(iClient <= 0 || iClient > MaxClients)
        return false;

    if(!IsClientInGame(iClient))
        return false;

    if(GetEntProp(iClient, Prop_Send, "m_bIsCoaching"))
        return false;
    
    return true;
}

stock bool IsInvuln(int client)
{
    return (TF2_IsPlayerInCondition(client, TFCond_Ubercharged) 
        || TF2_IsPlayerInCondition(client, TFCond_UberchargedCanteen) 
        || TF2_IsPlayerInCondition(client, TFCond_UberchargedHidden) 
        || TF2_IsPlayerInCondition(client, TFCond_UberchargedOnTakeDamage));
}

stock int TF2_GetDefIndex(int iWeapon)
{
    return GetEntProp(iWeapon, Prop_Send, "m_iItemDefinitionIndex");
}

stock void TF2_SetWeaponClip(int weapon, int amount)
{
    SetEntProp(weapon, Prop_Data, "m_iClip1", amount);

    return;
}

stock void TF2_GiveWeaponClip(int iWeapon, int iAmount)
{
    SetEntProp(iWeapon, Prop_Data, "m_iClip1", TF2_GetWeaponClip(iWeapon) + iAmount);

    return;
}

stock int TF2_GetWeaponClip(int weapon)
{
    return GetEntProp(weapon, Prop_Data, "m_iClip1");
}

stock int GetActiveWeapon(int iClient)
{
    return GetEntPropEnt(iClient, Prop_Send, "m_hActiveWeapon");
}