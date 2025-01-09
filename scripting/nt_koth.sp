#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <neotokyo>

#define DEBUG false
#define PRNT_SRVR (1<<0)
#define PRNT_CNSL (1<<1)
#define PRNT_CHT (1<<2)
#define PRNT_CNT (1<<3)
#define PRNT_THREE 7
#define PRNT_ALL 15

#define GAMEHUD_TIE 3
#define GAMEHUD_JINRAI 4
#define GAMEHUD_NSF 5

#define BOTH_TEAMS 5

public Plugin myinfo = {
	name = "NT King of the hill mode",
	description = "Enables KoTH mode",
	author = "bauxite",
	version = "0.3.0",
	url = "",
};

DynamicDetour ddWin;

Handle g_hillTimer;
Handle g_winTimer;
Handle g_stateTimer;
Handle g_godTimer[NEO_MAXPLAYERS+1];

bool g_lateLoad;
bool g_kothMap;
bool g_hillActive;
bool g_hillHasNSF;
bool g_hillHasJin;
bool g_jinStart;
bool g_nsfStart;

int g_nsfOnHill;
int g_jinOnHill;
int g_inacSprite;
int g_noneSprite;
int g_jinSprite;
int g_nsfSprite;
int g_lastSprite;
int red;
int green;
int blue;
int alpha;

float g_startTime;
float g_jinTime;
float g_nsfTime;
float curTime;
float roundTimeLeft;


stock int GetOpposingTeam(int team)
{
    return team == TEAM_JINRAI ? TEAM_NSF : TEAM_JINRAI;
}

int FindEntityByTargetname(const char[] classname, const char[] targetname)
{
	int ent = -1;
	char buffer[64];
	
	while ((ent = FindEntityByClassname(ent, classname)) != -1)
	{
		GetEntPropString(ent, Prop_Data, "m_iName", buffer, sizeof(buffer));

		if (StrEqual(buffer, targetname))
		{
			return ent;
		}
	}

	return -1;
}

stock bool IsPlayerDead(int client) // Agiel: None of the normal ways seemed to handle the case when players are still selecting weapon.
{
    Address player = GetEntityAddress(client);
    int isAlive = LoadFromAddress(player + view_as<Address>(0xDC4), NumberType_Int32);
    return isAlive == 0;
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_lateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	if(g_lateLoad)
	{
		OnMapInit();
	}
}

// ISSUE: at the moment if nt_wincond is called something else, everything will break

public void OnMapInit()
{	
	static bool deathHook;
	static bool roundHook;
	
	char mapName[32];
	GetCurrentMap(mapName, sizeof(mapName));
	
	if(StrContains(mapName, "_koth", false) != -1)
	{
		g_kothMap = true;
		
		// we do our own win checks
		ServerCommand("sm plugins unload nt_wincond");
		
		// these dont work well with "respawns"
		ServerCommand("sm plugins unload nt_assist");
		ServerCommand("sm plugins unload nt_damage");
		
		if(HookEventEx("player_death", OnPlayerDeathPre, EventHookMode_Pre))
		{
			deathHook = true;
		}
		
		if(HookEvent("game_round_start", OnRoundStartPost, EventHookMode_Post))
		{
			roundHook = true;
		}
		
		HookEvent("player_spawn", OnPlayerSpawnPost, EventHookMode_Post);

		CreateDetour();
	}
	else
	{
		g_kothMap = false;
		
		if(deathHook && roundHook)
		{
			UnhookEvent("player_death", OnPlayerDeathPre, EventHookMode_Pre);
			UnhookEvent("game_round_start", OnRoundStartPost, EventHookMode_Post);
			UnhookEvent("player_spawn", OnPlayerSpawnPost, EventHookMode_Post);
			
			deathHook = false;
			roundHook = false;
		}

		DisableDetour();		
	}
}

//hook weapon drop and remove them after 30s?
//make sure players cant spawn earlier than intended like rejoining

public void OnClientPutInServer(int client)
{
	if(!g_kothMap)
	{
		return;
	}
	
	if(IsFakeClient(client))
	{
		return;
	}
	
	SDKHook(client, SDKHook_WeaponDrop, OnWeaponDrop);
}

public Action OnWeaponDrop(int client, int weapon)
{
	if(!g_kothMap)
	{
		return Plugin_Continue;
	}
	
	if(!IsPlayerAlive(client))
	{
		return Plugin_Handled;
	}
	
	return Plugin_Continue;
}

//spawn event is called when players join server as well

public void OnPlayerSpawnPost(Event event, const char[] name, bool dontBroadcast)
{
	int userid = GetEventInt(event, "userid");
	int client = GetClientOfUserId(userid);
	
	if(client <= 0 || client > MaxClients)
	{
		return;
	}
	
	SetEntityFlags(client, GetEntityFlags(client) | FL_GODMODE);
	PrintCenterText(client, "2s spawn protection");
	
	if(IsValidHandle(g_godTimer[client]))
	{
		CloseHandle(g_godTimer[client]);
		
		#if DEBUG
		PrintToServer("deleting god timer");
		#endif
	}
	
	g_godTimer[client] = CreateTimer(2.0, RemoveGod, userid, TIMER_FLAG_NO_MAPCHANGE);
		
	#if DEBUG
	PrintToServer("spawned");
	PrintToServer("creating god timer");
	#endif
}

public Action RemoveGod(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	
	if(client <= 0 || client > MaxClients)
	{
		return Plugin_Stop;
	}
	
	if(!IsClientInGame(client))
	{
		return Plugin_Stop;
	}
	
	SetEntityFlags(client, GetEntityFlags(client) & ~FL_GODMODE);
	
	#if DEBUG
	PrintToServer("removed god");
	#endif
	
	return Plugin_Stop;
}

public Action OnPlayerDeathPre(Event event, const char[] name, bool dontBroadcast)
{
	if(!g_kothMap)
	{
		return Plugin_Continue;
	}

	return Plugin_Continue;
}

public void OnMapStart()
{
	if(!g_kothMap)
	{
		return;
	}
	
	StoreToAddress(view_as<Address>(0x2245556E), 'K', NumberType_Int8);
	StoreToAddress(view_as<Address>(0x2245556F), 'T', NumberType_Int8);
	StoreToAddress(view_as<Address>(0x22455570), 'H', NumberType_Int8);
	
	g_inacSprite = FindEntityByTargetname("env_sprite", "point_sprite_inactive");
	g_noneSprite = FindEntityByTargetname("env_sprite", "point_sprite_none");
	g_jinSprite = FindEntityByTargetname("env_sprite", "point_sprite_jin");
	g_nsfSprite = FindEntityByTargetname("env_sprite", "point_sprite_nsf");
	
	ResetSprites();
	
	CreateTimer(0.31, HudTimer, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void ResetSprites()
{
	AcceptEntityInput(g_inacSprite, "ShowSprite", -1, -1);
	AcceptEntityInput(g_noneSprite, "HideSprite", -1, -1);
	AcceptEntityInput(g_jinSprite, "HideSprite", -1, -1);
	AcceptEntityInput(g_nsfSprite, "HideSprite", -1, -1);
	
	g_lastSprite = g_inacSprite;
}

public Action HudTimer(Handle timer)
{
	// dont need complicated logic checks for setting the right sprite as only one is ever active
	// store last active sprite and disable that one whenever a new one is set etc
	// they revert their state on a new round so they have to be reset to desired starting state
	//(float x, float y, float holdTime, int r, int g, int b, int a, int effect, float fxTime, float fadeIn, float fadeOut)
	
	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i))
		{
			continue;
		}
		
		if(g_jinStart)
		{
			if(g_lastSprite != g_jinSprite)
			{
				AcceptEntityInput(g_lastSprite, "HideSprite", -1, -1);
				AcceptEntityInput(g_jinSprite, "ShowSprite", -1, -1);
				g_lastSprite = g_jinSprite;
			}
			
			red = 25;
			green = 255;
			blue = 0;
			alpha = 0;
		}
		else if(g_nsfStart)
		{
			if(g_lastSprite != g_nsfSprite)
			{
				AcceptEntityInput(g_lastSprite, "HideSprite", -1, -1);
				AcceptEntityInput(g_nsfSprite, "ShowSprite", -1, -1);
				g_lastSprite = g_nsfSprite;
			}
			
			red = 0;
			green = 100;
			blue = 255;
			alpha = 0;
		}
		else if(g_hillActive)
		{
			if(g_lastSprite != g_noneSprite)
			{
				AcceptEntityInput(g_lastSprite, "HideSprite", -1, -1);
				AcceptEntityInput(g_noneSprite, "ShowSprite", -1, -1);
				g_lastSprite = g_noneSprite;
			}
			
			red = 250;
			green = 250;
			blue = 250;
			alpha = 0;
		}
		else
		{
			if(g_lastSprite != g_inacSprite)
			{
				AcceptEntityInput(g_lastSprite, "HideSprite", -1, -1);
				AcceptEntityInput(g_inacSprite, "ShowSprite", -1, -1);
				g_lastSprite = g_inacSprite;
			}
			
			red = 250;
			green = 0;
			blue = 0;
			alpha = 0;
		}
		
		SetHudTextParams(0.36, 0.0, 1.0, 25, 225, 0, 0, 1, 0.0, 0.0, 0.0); 
		ShowHudText(i, 5, "Jin: %.2f", g_jinTime);
		
		SetHudTextParams(0.48, 0.0, 1.0, red, green, blue, alpha, 1, 0.0, 0.0, 0.0); 
		ShowHudText(i, 4, "KoTH");
	
		SetHudTextParams(0.56, 0.0, 1.0, 0, 100, 255, 0, 1, 0.0, 0.0, 0.0);
		ShowHudText(i, 6, "  NSF: %.2f", g_nsfTime);
	}
	
	return Plugin_Continue;
}

public void OnMapEnd()
{
	if(!g_kothMap)
	{
		return;
	}
	
	StoreToAddress(view_as<Address>(0x2245556E), 'C', NumberType_Int8);
	StoreToAddress(view_as<Address>(0x2245556F), 'T', NumberType_Int8);
	StoreToAddress(view_as<Address>(0x22455570), 'G', NumberType_Int8);
}

public void OnConfigsExecuted()
{
	if(!g_kothMap)
	{
		return;
	}
	
	FindConVar("neo_round_timelimit").FloatValue = 6.52;
	
	ConVar roundStyle = FindConVar("sm_competitive_round_style");
	ConVar roundLimit = FindConVar("sm_competitive_round_limit");
	
	if(roundStyle != null && roundLimit != null)
	{
		roundStyle.IntValue = 2;
		roundLimit.IntValue = 4;
	}
	else
	{
		FindConVar("neo_score_limit").IntValue = 4;
	}
}

void DisableDetour() 
{
	if(!IsValidHandle(ddWin))
	{
		return;
	}
	
	if(!ddWin.Disable(Hook_Pre, CheckWinCondition))	
	{
		return;
	}
	
	delete ddWin;
}

void CreateDetour() 
{
	Handle gd = LoadGameConfigFile("neotokyo/wincond");

	if (gd == INVALID_HANDLE) 
	{
		SetFailState("Failed to load GameData");
	}

	ddWin = DynamicDetour.FromConf(gd, "Fn_CheckWinCondition");
	
	if(!ddWin) 
	{
		SetFailState("Failed to create dynamic detour");
	}
	
	if(!ddWin.Enable(Hook_Pre, CheckWinCondition))	
	{
		SetFailState("Failed to detour");
	}

	CloseHandle(gd);
}

MRESReturn CheckWinCondition(Address pThis, DHookReturn hReturn)
{
	#if DEBUG
	PrintToChatAll("Checking for win");
	#endif
	
	if(CheckingForWin())
	{
		return MRES_Supercede;
	}
	
	return MRES_Supercede;
}

bool CheckingForWin() 
{
	roundTimeLeft = GameRules_GetPropFloat("m_fRoundTimeLeft");
	
	if (roundTimeLeft == 0.0)
	{
		ResetWin();
		EndRoundAndShowWinner(BOTH_TEAMS);
		PrintMsg("[KoTH] Tie", PRNT_CHT | PRNT_CNSL);
		return true;
	}
	
	return false;
}

void ResetWin()
{
	if(IsValidHandle(g_winTimer))
	{
		CloseHandle(g_winTimer);
		g_winTimer = null;
		
		#if DEBUG
		PrintToServer("deleting win timer");
		#endif
	}
	
	if(IsValidHandle(g_hillTimer))
	{
		CloseHandle(g_hillTimer);
		g_hillTimer = null;
		
		#if DEBUG
		PrintToServer("deleting hill timer");
		#endif
	}
	
	if(IsValidHandle(g_stateTimer))
	{
		CloseHandle(g_stateTimer);
		g_hillTimer = null;
		
		#if DEBUG
		PrintToServer("deleting state timer");
		#endif
	}
	
	g_hillActive = false;
	
	g_jinOnHill = 0;
	g_nsfOnHill = 0;
	g_hillHasJin = false;
	g_hillHasNSF = false;
	
	g_startTime = 0.0;
	g_jinTime = 0.0;
	g_nsfTime = 0.0;
	
	g_jinStart = false;
	g_nsfStart = false;
	
	for(int client = 1; client <= MaxClients; client++)
	{
		if(!IsClientInGame(client) || IsFakeClient(client))
		{
			continue;
		}
		
		SetPlayerXP(client, 0);
		SetPlayerDeaths(client, 0);
		SetPlayerRank(client, RANK_PRIVATE);
	}
}

void Trigger_OnStartTouch(const char[] output, int caller, int activator, float delay)
{
	int team = GetClientTeam(activator)
	
	if(team == TEAM_JINRAI)
	{
		g_jinOnHill += 1;
		g_hillHasJin = true;
	}
	else if(team == TEAM_NSF)
	{
		g_nsfOnHill += 1;
		g_hillHasNSF = true;
	}
	else
	{
		PrintToChatAll("[KoTH] Error: Uknown/Invalid team on hill");
	}
	
	if(!g_hillActive)
	{
		return;
	}
	
	if(g_hillHasJin && !g_hillHasNSF && !g_jinStart)
	{
		g_startTime = GetGameTime();
		g_jinStart = true;
		g_nsfStart = false;
	}
	else if(g_hillHasNSF && !g_hillHasJin && !g_nsfStart)
	{
		g_startTime = GetGameTime();
		g_nsfStart = true;
		g_jinStart = false;
	}
	else if(g_hillHasJin && g_hillHasNSF)
	{
		g_nsfStart = false;
		g_jinStart = false;
	}
	else if(!g_hillHasJin && !g_hillHasNSF)
	{
		g_nsfStart = false;
		g_jinStart = false;
	}
}

void Trigger_OnEndTouch(const char[] output, int caller, int activator, float delay)
{
	int team = GetClientTeam(activator)
	
	if(team == TEAM_JINRAI)
	{
		g_jinOnHill -= 1;
		
		if(g_jinOnHill == 0)
		{
			g_hillHasJin = false;
		}
	}
	else if(team == TEAM_NSF)
	{
		g_nsfOnHill -= 1;
		
		if(g_nsfOnHill == 0)
		{
			g_hillHasNSF = false;
		}
	}
	else
	{
		PrintToChatAll("[KoTH] Error: Uknown/Invalid team left hill");
	}
	
	if(!g_hillActive)
	{
		return;
	}
	
	if(g_hillHasJin && !g_hillHasNSF && !g_jinStart)
	{
		g_startTime = GetGameTime();
		g_jinStart = true;
		g_nsfStart = false;
	}
	else if(g_hillHasNSF && !g_hillHasJin && !g_nsfStart)
	{
		g_startTime = GetGameTime();
		g_nsfStart = true;
		g_jinStart = false;
	}
	else if(!g_hillHasJin && !g_hillHasNSF)
	{
		g_nsfStart = false;
		g_jinStart = false;
	}
	else if(g_hillHasJin && g_hillHasNSF)
	{
		g_nsfStart = false;
		g_jinStart = false;
	}
}

public Action WinTimer(Handle timer)
{
	if(!g_hillActive)
	{
		#if DEBUG
		PrintMsg("[KoTH Debug] Error: Trying to do win timer when not live round or active hill", PRNT_CNT);
		#endif
		return Plugin_Continue;
	}
	
	roundTimeLeft = GameRules_GetPropFloat("m_fRoundTimeLeft");
	
	if(roundTimeLeft <= 15.0)
	{
		GameRules_SetProp("m_iGameState", GAMESTATE_ROUND_ACTIVE);
	}
		
	curTime = GetGameTime();
	
	if(g_jinStart)
	{
		g_jinTime += curTime - g_startTime;
		g_startTime = curTime;
	}
	else if(g_nsfStart)
	{
		g_nsfTime += curTime - g_startTime;
		g_startTime = curTime;
	}
	
	if(g_jinTime >= 60.0)
	{
		g_winTimer = null;
		
		ResetWin();
		GameRules_SetProp("m_iGameState", GAMESTATE_ROUND_ACTIVE);
		EndRoundAndShowWinner(TEAM_JINRAI);
		PrintMsg("[KoTH] Jinrai claims the hill!", PRNT_ALL);
		
		return Plugin_Stop;
	}
	else if(g_nsfTime >= 60.0)
	{
		g_winTimer = null;

		ResetWin();
		GameRules_SetProp("m_iGameState", GAMESTATE_ROUND_ACTIVE);
		EndRoundAndShowWinner(TEAM_NSF)
		PrintMsg("[KoTH] NSF claims the hill!", PRNT_ALL);
		
		return Plugin_Stop;
	}
	
	return Plugin_Continue;
}

void EndRoundAndShowWinner(int team) //what about during comp pause
{
	int GameState = GameRules_GetProp("m_iGameState");
	
	if(GameState == GAMESTATE_ROUND_OVER || GameState == GAMESTATE_WAITING_FOR_PLAYERS)
	{
		#if DEBUG
		PrintMsg("[KoTH Debug] Error: Awarding win when round is over", PRNT_THREE);
		#endif
		return;
	}
	
	if(team != TEAM_JINRAI && team != TEAM_NSF && team != BOTH_TEAMS)
	{
		#if DEBUG
		PrintMsg("[KoTH Debug] Error: Awarding win to unknown team: %d", PRNT_THREE, team);
		#endif
		return;
	}
	
	GameRules_SetProp("m_iGameState", GAMESTATE_ROUND_OVER);
	GameRules_SetPropFloat( "m_fRoundTimeLeft", 15.0 );
	
	if(team == BOTH_TEAMS)
	{
		GameRules_SetProp("m_iGameHud", GAMEHUD_TIE);
	}
	else
	{
		GameRules_SetProp("m_iGameHud", team + 2);
		
		int score = GetTeamScore(team);
		SetTeamScore(team, score + 1);
	}
}

public void OnRoundStartPost(Event event, const char[] name, bool dontBroadcast)
{
	if(!g_kothMap)
	{
		return;
	}
	
	ResetWin();
	
	int trigger = FindEntityByTargetname("trigger_multiple", "koth_point");
	HookSingleEntityOutput(trigger, "OnStartTouch", Trigger_OnStartTouch);
	HookSingleEntityOutput(trigger, "OnEndTouch", Trigger_OnEndTouch);
	
	if(!IsValidHandle(g_hillTimer))
	{
		g_hillTimer = CreateTimer(31.0, HillTimer, _, TIMER_FLAG_NO_MAPCHANGE);
		
		#if DEBUG
		PrintToServer("creating hill timer");
		#endif
	}
	
	if(!IsValidHandle(g_stateTimer))
	{
		g_hillTimer = CreateTimer(24.0, GameStateTimer, _, TIMER_FLAG_NO_MAPCHANGE);
		
		#if DEBUG
		PrintToServer("creating state timer");
		#endif
	}
	
	ResetSprites();
}

public Action GameStateTimer(Handle timer)
{
	GameRules_SetProp("m_iGameState", GAMESTATE_WAITING_FOR_PLAYERS);
	return Plugin_Stop;
}

public Action HillTimer(Handle timer)
{
	if(g_hillHasJin && !g_hillHasNSF && !g_jinStart)
	{
		g_startTime = GetGameTime();
		g_jinStart = true;
		g_nsfStart = false;
	}
	else if(g_hillHasNSF && !g_hillHasJin && !g_nsfStart)
	{
		g_startTime = GetGameTime();
		g_nsfStart = true;
		g_jinStart = false;
	}
	else if(g_hillHasJin && g_hillHasNSF)
	{
		g_nsfStart = false;
		g_jinStart = false;
	}
	
	// problem?
	/*
	else 
	{
		g_nsfStart = false;
		g_jinStart = false;
	}
	*/
	
	g_hillActive = true;
	
	if(!IsValidHandle(g_winTimer))
	{
		g_winTimer = CreateTimer(0.1, WinTimer, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		
		#if DEBUG
		PrintToServer("creating win timer");
		#endif
	}
	
	return Plugin_Stop;
}

public void OnClientDisconnect_Post(int client)
{
	if(!g_kothMap)
	{
		return;
	}
}

void PrintMsg(const char[] msg, int flags, any ...)
{
	char debugMsg[128];
	
	VFormat(debugMsg, sizeof(debugMsg), msg, 3);
	
	if (flags & PRNT_SRVR)
	{
		PrintToServer(debugMsg);
	}

	if (flags & PRNT_CHT)
	{
		PrintToChatAll(debugMsg);
	}

	if (flags & PRNT_CNSL)
	{
		PrintToConsoleAll(debugMsg);
	}
	
	if (flags & PRNT_CNT)
	{
		PrintCenterTextAll(debugMsg);
	}
}
