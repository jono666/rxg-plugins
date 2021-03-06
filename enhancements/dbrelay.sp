
#include <sourcemod>
#include <sdktools>
#include <rxgcommon>

#undef REQUIRE_PLUGIN
#include <sourceirc>

#pragma semicolon 1

//-----------------------------------------------------------------------------
public Plugin myinfo = {
	name = "Database Relay",
	author = "WhiteThunder",
	description = "Relays database queries through a single connection",
	version = "1.2.0",
	url = "www.reflex-gamers.com"
};

Handle g_ConnectForward;
Handle g_db;

Handle sm_dbrelay_auto_reconnect;
Handle sm_dbrelay_retry_delay;
Handle sm_dbrelay_max_retries;
bool c_auto_reconnect;
float c_retry_delay;
int c_max_retries;

int g_last_connect;
int g_last_query;
int g_last_error;
int g_queries_since_up;

bool g_connecting;
bool g_connected;
int g_reconnect_tries;


bool use_irc;

public OnAllPluginsLoaded() {
	if (LibraryExists("sourceirc"))
		use_irc = true;
}
public OnLibraryAdded(const char[] name) {
	if (StrEqual(name, "sourceirc"))
		use_irc = true;
}
public OnLibraryRemoved(const char[] name) {
	if (StrEqual(name, "sourceirc"))
		use_irc = false;
}

//-----------------------------------------------------------------------------
public APLRes AskPluginLoad2( Handle myself, bool late, char[] error, err_max ) {
	CreateNative( "DBRELAY_IsConnected", Native_IsConnected );
	CreateNative( "DBRELAY_TQuery", Native_TQuery );
	RegPluginLibrary("dbrelay");
}

//-----------------------------------------------------------------------------
RecacheConvars() {
	c_auto_reconnect = GetConVarBool( sm_dbrelay_auto_reconnect );
	c_retry_delay = GetConVarFloat( sm_dbrelay_retry_delay );
	c_max_retries = GetConVarInt( sm_dbrelay_max_retries );
}

//-----------------------------------------------------------------------------
public OnConVarChanged( Handle cvar, const char[] oldval, const char[] newval ) {
	RecacheConvars();
}

//-----------------------------------------------------------------------------
public OnPluginStart() {

	sm_dbrelay_auto_reconnect = CreateConVar( "sm_dbrelay_auto_reconnect", "1", "Whether to automatically reconnect when there is a database connection problem.", FCVAR_PLUGIN );
	sm_dbrelay_retry_delay = CreateConVar( "sm_dbrelay_retry_delay", "30.0", "Seconds between attempts to retry when the database connection failed.", FCVAR_PLUGIN, true, 1.0 );
	sm_dbrelay_max_retries = CreateConVar( "sm_dbrelay_max_retries", "100", "Maximum number of times to try to reconnect to the database if connection fails. Set to -1 for no limit.", FCVAR_PLUGIN, true, -1.0 );
	
	HookConVarChange( sm_dbrelay_auto_reconnect, OnConVarChanged );
	HookConVarChange( sm_dbrelay_retry_delay, OnConVarChanged );
	HookConVarChange( sm_dbrelay_max_retries, OnConVarChanged );
	RecacheConvars();
	
	g_ConnectForward = CreateGlobalForward( "OnDBRelayConnected", ET_Ignore );
	
	DB_Open();
	
	RegServerCmd( "dbrelay_connect", Command_connect );
	RegServerCmd( "dbrelay_disconnect", Command_disonnect );
	RegServerCmd( "dbrelay_status", Command_status );
}

//-----------------------------------------------------------------------------
public Action Command_connect( args ) {
	
	if( g_connected ) {
		PrintToServer( "Already connected." );
	} else if( g_connecting ) {
		PrintToServer( "Already attempting to connect... Use dbrelay_status to check." );
	} else {
		PrintToServer( "Attempting to open connection... Use dbrelay_status to check." );
		DB_Open();
	}
}

//-----------------------------------------------------------------------------
public Action Command_disonnect( args ) {
	
	if( g_connected ) {
		PrintToServer( "[DBRELAY] Closing database connection." );
		DB_Close();
	} else if( g_connecting ) {
		PrintToServer( "[DBRELAY] ERROR: Currently attempting to connect." );
	} else {
		PrintToServer( "[DBRELAY] No connection found." );
	}
}

//-----------------------------------------------------------------------------
public Action Command_status( args ) {
	
	char reply[256];
	char status_content[128];
	
	char last_connect_str[13];
	char last_query_str[13];
	char last_error_str[13];
	
	
	if( g_last_connect != 0 ) {
		FormatTime( last_connect_str, 12, "%H:%M:%S", g_last_connect );
	}
	
	if( g_last_query != 0 ) {
		FormatTime( last_query_str, 12, "%H:%M:%S", g_last_query );
	}
	
	if( g_last_error != 0 ) {
		FormatTime( last_error_str, 12, "%H:%M:%S", g_last_error );
	}
	
	FormatEx( status_content, sizeof status_content, "Last query: %s. Last error: %s. Queries since up: %d. Auto reconnect: %s.",
		(g_last_query != 0) ? last_query_str : "N/A",
		(g_last_error != 0) ? last_error_str : "N/A",
		g_queries_since_up,
		(c_auto_reconnect) ? "ON" : "OFF"
	);
	
	if( g_connected ) {
		FormatEx( reply, sizeof reply, "[DBRELAY] STATUS: Connected since %s. %s",
			last_connect_str, status_content
		);
	} else if( g_connecting ) {
		FormatEx( reply, sizeof reply, "[DBRELAY] STATUS: Connecting... %d / %d tries. %s",
			g_reconnect_tries, c_max_retries, status_content
		);
	} else {
		FormatEx( reply, sizeof reply, "[DBRELAY] STATUS: Not connected! Last connect: %s. %s",
			(g_last_connect != 0) ? last_connect_str : "N/A",
			status_content
		);
	}
	
	PrintToServer( reply );
}

//-----------------------------------------------------------------------------
bool DB_Open( bool first = true ) {

	if( first && !SQL_CheckConfig("reflex") ) {
		IRCMessage( "\x030,4[DBRELAY] Could not find Database conf \"reflex\"." );
		PrintToServer( "[DBRELAY] Could not find Database conf \"reflex\"." );
		SetFailState("Database failure: Could not find Database conf \"reflex\"");
		return false;
	}
	
	// returns true if connected
	if( g_connecting ) return false;
	if( g_connected ) return true;
	
	SQL_TConnect( DB_OnConnect, "reflex" );
	
	g_connecting = true;
	
	if( first ) g_reconnect_tries = 0;
	
	return false;
}

//-----------------------------------------------------------------------------
public DB_OnConnect( Handle owner, Handle hndl, const char[] error, any data ) {
	
	if( hndl == INVALID_HANDLE ) {
		LogError( "sql connection error: %s", error );
		if( c_max_retries >= 0 && g_reconnect_tries >= c_max_retries ) {
			IRCMessage( "\x030,4[DBRELAY] Unable to connect to database. No longer retrying." );
			PrintToServer( "[DBRELAY] Unable to connect to database. No longer retrying." );
			g_connecting = false;
			return;
		} else if( c_auto_reconnect ) {
			g_reconnect_tries++;
			CreateTimer( c_retry_delay, DB_ReconnectTimer );
			return;
		}
	}
	
	g_connected = true;
	g_last_connect = GetTime();
	g_db = hndl;
	
	IRCMessage( "\x031,9[DBRELAY] Database connection established." );
	PrintToServer( "[DBRELAY] Database connection established." );
	
	Call_StartForward( g_ConnectForward );
	Call_Finish();
}

//-----------------------------------------------------------------------------
public Action DB_ReconnectTimer( Handle timer ) {
	g_connecting = false;
	DB_Open( false );
	return Plugin_Handled;
}

//-----------------------------------------------------------------------------
public DB_Close() {
	IRCMessage( "\x030,4[DBRELAY] Database connection closed." );
	PrintToServer( "[DBRELAY] Database connection closed." );
	if( !g_connected ) return;
	CloseHandle( g_db );
	g_db = INVALID_HANDLE;
	g_connected = false;
	g_connecting = false;
}

//-----------------------------------------------------------------------------
public DB_Fault() {
	DB_Close();
	g_last_error = GetTime();
	if( c_auto_reconnect ) {
		DB_Open();
	}
}

//-----------------------------------------------------------------------------
public Native_IsConnected( Handle plugin, numParams ) {
	return g_connected;
}

//-----------------------------------------------------------------------------
public Native_TQuery( Handle plugin, numParams ) {
	
	SQLTCallback callback = GetNativeCell(1);
	
	int len;
	GetNativeStringLength( 2, len );
	
	char[] query = new char[len + 1];
	GetNativeString( 2, query, len + 1 );
	
	Handle inner_pack = GetNativeCell(3);
	
	Handle pack = CreateDataPack();
	WritePackHandle( pack, plugin );
	WritePackFunction( pack, callback );
	WritePackHandle( pack, inner_pack );
	
	SQL_TQuery( g_db, OnQueryResult, query, pack );
	
	g_queries_since_up++;
	g_last_query = GetTime();
}

//-----------------------------------------------------------------------------
public OnQueryResult( Handle owner, Handle hndl, const char[] error, any data ) {
	
	ResetPack(data);
	Handle plugin = ReadPackHandle(data);
	SQLTCallback callback = view_as<SQLTCallback>ReadPackFunction(data);
	Handle inner_data = ReadPackHandle(data);
	CloseHandle(data);
	
	if( !hndl ) {
		IRCMessage( "\x030,4[DBRELAY] SQL Error: See log." );
		PrintToServer( "[DBRELAY] SQL Error: See log." );
		LogError( "SQL Error ::: %s", error ); 
		DB_Fault();
	}
	
	Call_StartFunction( plugin, callback );
	Call_PushCell( owner );
	Call_PushCell( hndl );
	Call_PushString( error );
	Call_PushCell( inner_data );
	Call_Finish();
}

//-----------------------------------------------------------------------------
public IRCMessage( const char[] msg ) {
	if( use_irc ) {
		IRC_MsgFlaggedChannels( "relay", msg );
	}
}
