#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>
#include <neotokyo>

#define DEBUG true
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
	version = "0.1.3",
	url = "",
};

DynamicDetour ddWin;

Handle g_hillTimer = null;
Handle g_winTimer = null;
Handle g_hudTimer = null;

bool g_lateLoad;
bool g_kothMap;

bool g_hillActive;

int red;
int green;
int blue;
int alpha;

int g_nsfOnHill;
int g_jinOnHill;

bool g_hillHasNSF;
bool g_hillHasJin;

bool g_jinStart;
bool g_nsfStart;

float curTime;
float g_startTime;

float g_jinTime;
float g_nsfTime;

float roundTimeLeft;

int GetOpposingTeam(int team)
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

bool IsPlayerDead(int client) // Agiel: None of the normal ways seemed to handle the case when players are still selecting weapon.
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
		ServerCommand("sm plugins unload nt_wincond"); 
		
		if(HookEventEx("player_death", Event_PlayerDeathPre, EventHookMode_Pre))
		{
			deathHook = true;
		}
		
		if(HookEvent("game_round_start", OnRoundStartPost, EventHookMode_Post))
		{
			roundHook = true;
		}
		
		CreateDetour();
	}
	else
	{
		g_kothMap = false;
		
		if(deathHook && roundHook)
		{
			UnhookEvent("player_death", Event_PlayerDeathPre, EventHookMode_Pre);
			UnhookEvent("game_round_start", OnRoundStartPost, EventHookMode_Post);
			deathHook = false;
			roundHook = false;
		}

		DisableDetour();		
	}
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
	
	FindConVar("neo_score_limit").IntValue = 5;
	FindConVar("neo_round_timelimit").FloatValue = 6.26;
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
	if(CheckingForWin())
	{
		return MRES_Supercede;
	}
	
	//return MRES_Supercede;
	return MRES_Ignored;
}

bool CheckingForWin() 
{
	roundTimeLeft = GameRules_GetPropFloat("m_fRoundTimeLeft");
	
	if (roundTimeLeft == 0.0)
	{
		PrintMsg("[KoTH] Tie", PRNT_CHT | PRNT_CNSL);
		EndRoundAndShowWinner(BOTH_TEAMS);
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
		PrintToServer("deleting win timer");
	}
	
	if(IsValidHandle(g_hudTimer))
	{
		CloseHandle(g_hudTimer);
		g_hudTimer = null;
		PrintToServer("deleting hud timer");
	}
	
	if(IsValidHandle(g_hillTimer))
	{
		CloseHandle(g_hillTimer);
		g_hillTimer = null;
		PrintToServer("deleting hill timer");
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
}

// if standing on trigger before hill activates nothing happens

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
	else
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
	else
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
	
	if(g_jinTime >= 15.0)
	{
		g_winTimer = null;
		
		ResetWin();
		EndRoundAndShowWinner(TEAM_JINRAI);
		PrintMsg("[KoTH] Jinrai claims the hill!", PRNT_ALL);
		
		return Plugin_Stop;
	}
	else if(g_nsfTime >= 15.0)
	{
		g_winTimer = null;

		ResetWin();
		EndRoundAndShowWinner(TEAM_NSF)
		PrintMsg("[KoTH] NSF claims the hill!", PRNT_ALL);
		
		return Plugin_Stop;
	}
	
	return Plugin_Continue;
}

public Action HudTimer(Handle timer)
{
	//(float x, float y, float holdTime, int r, int g, int b, int a, int effect, float fxTime, float fadeIn, float fadeOut)
	
	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i))
		{
			continue;
		}
		
		if(g_jinStart)
		{
			red = 25;
			green = 255;
			blue = 0;
			alpha = 0;
		}
		else if(g_nsfStart)
		{
			red = 0;
			green = 100;
			blue = 255;
			alpha = 0;
		}
		else if(g_hillActive)
		{
			red = 250;
			green = 250;
			blue = 250;
			alpha = 0;
		}
		else
		{
			red = 250;
			green = 0;
			blue = 0;
			alpha = 0;
		}
		
		SetHudTextParams(1.0, 0.79, 1.0, red, green, blue, alpha, 1, 0.0, 0.0, 0.0); 
		ShowHudText(i, 4, "KoTH");
		
		
		SetHudTextParams(1.0, 0.83, 1.0, 25, 225, 0, 0, 1, 0.0, 0.0, 0.0); 
		ShowHudText(i, 5, "%.2f: JIN", g_jinTime);
	
		SetHudTextParams(1.0, 0.87, 1.0, 0, 100, 255, 0, 1, 0.0, 0.0, 0.0);
		ShowHudText(i, 6, "%.2f: NSF", g_nsfTime);
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
	
	if(!IsValidHandle(g_hudTimer))
	{
		g_hudTimer = CreateTimer(0.3, HudTimer, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		PrintToServer("creating hud timer");
	}
	
	if(!IsValidHandle(g_hillTimer))
	{
		g_hillTimer = CreateTimer(30.0, HillTimer, _, TIMER_FLAG_NO_MAPCHANGE);
		PrintToServer("creating hill timer");
	}
}

public Action HillTimer(Handle timer)
{
	g_hillActive = true;
	
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
	else
	{
		g_nsfStart = false;
		g_jinStart = false;
	}
	
	if(!IsValidHandle(g_winTimer))
	{
		g_winTimer = CreateTimer(0.1, WinTimer, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		PrintToServer("creating win timer");
	}
	
	return Plugin_Stop;
}

void RespawnNewClass(int client)
{
	if(!IsClientInGame(client))
	{
		return;
	}

	SetNewClassProps(client);
	static Handle call = INVALID_HANDLE;
	
	if (call == INVALID_HANDLE)
	{
		StartPrepSDKCall(SDKCall_Player);
		PrepSDKCall_SetSignature(SDKLibrary_Server, "\x56\x8B\xF1\x8B\x06\x8B\x90\xBC\x04\x00\x00\x57\xFF\xD2\x8B\x06", 16);
		call = EndPrepSDKCall();
		if (call == INVALID_HANDLE)
		{
			SetFailState("Failed to prepare SDK call");
		}
	}
	
	SDKCall(call, client);
}

void SetNewClassProps(int client)
{
	FakeClientCommand(client, "setclass 2");
	FakeClientCommand(client, "setvariant 2");
	FakeClientCommand(client, "loadout 0");
	SetEntProp(client, Prop_Send, "m_iLives", 1);
	SetEntProp(client, Prop_Data, "m_iObserverMode", 0);
	SetEntProp(client, Prop_Data, "m_iHealth", 100);
	SetEntProp(client, Prop_Data, "m_lifeState", 0);
	SetEntProp(client, Prop_Data, "m_fInitHUD", 1);
	SetEntProp(client, Prop_Data, "m_takedamage", 2);
	SetEntProp(client, Prop_Send, "deadflag", 0);
	SetEntPropFloat(client, Prop_Send, "m_flDeathTime", 0.0);
	SetEntPropEnt(client, Prop_Data, "m_hObserverTarget", -1, 0);
}

public void OnClientDisconnect_Post(int client)
{
	if(!g_kothMap)
	{
		return;
	}
}

public Action Event_PlayerDeathPre(Event event, const char[] name, bool dontBroadcast)
{
	if(!g_kothMap)
	{
		return Plugin_Continue;
	}
	
	int victim = GetClientOfUserId(GetEventInt(event, "userid"));
	int attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	int GameState = GameRules_GetProp("m_iGameState");
	
	if(GameState == GAMESTATE_WAITING_FOR_PLAYERS)
	{
		return Plugin_Continue;
	}
	
	return Plugin_Continue;
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
