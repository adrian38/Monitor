//+------------------------------------------------------------------+
//| CopyMonitor_Slave_MT4_v1_00_MULTI.mq4                            |
//| Preserves GENERIC / PORTFOLIO46 / LUNA profiles.                 |
//| Optional MultiMaster layer by exact Slave comment ownership.      |
//| Open positions: monitor quantity + SL/TP, never auto-close.       |
//| Pending orders: normally ignored as copy expectations; optional   |
//| confirmed EXTRA pending in Slave can be deleted.                  |
//| Port MT4 del Slave MT5 v1.20 MULTI: mismo snapshot, mismas reglas |
//| de emparejamiento y los mismos limites de automatizacion.         |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "CopyMonitor Slave MT4 v1.00 MULTI"

// MT4 no tiene CTrade ni MqlTradeRequest: las correcciones se envian con
// OrderSend, OrderModify y OrderDelete, y el diagnostico sale de GetLastError.
// Tampoco tiene OnTradeTransaction, asi que el disparo inmediato por cambio de
// la cuenta Slave vive en OnTick comparando una firma del estado.

enum ENUM_COPY_PROFILE
{
   PROFILE_GENERIC=0,
   PROFILE_PORTFOLIO46=1,
   PROFILE_LUNA=2
};

//--- ===== MODE / PROFILE =====
input ENUM_COPY_PROFILE InpProfile                    = PROFILE_GENERIC;
input bool              InpMultiMaster                = false;
input string            InpAccountNick                = "SLAVE";
// Obligatorio: alias del portafolio que encabeza cada aviso de Telegram.
input string            InpPortfolioAlias             = "";
input string            InpSlaveID                    = "SLAVE_A";
input int               InpMonitorSeconds             = 1;
input bool              InpShowPanel                  = true;

//--- ===== SINGLE MASTER (MultiMaster=false) =====
input string InpMasterChannel                         = "MASTER_A";
input string InpSingleSlaveComment                    = ""; // empty = no Slave comment filter
input double InpLotMultiplier                         = 1.0;

//--- ===== MULTI MASTER (MultiMaster=true) =====
// Positional lists. Example:
// MASTER_280;MASTER_687
// adrian_p_280;adrian_p
// PORTFOLIO46;GENERIC
// 0.60;1.00
input string InpMasterChannels                        = "MASTER_280;MASTER_687";
input string InpOwnerComments                         = "adrian_p_280;adrian_p";
input string InpMasterProfiles                        = "PORTFOLIO46;GENERIC";
input string InpVolumeMultipliers                     = "1.0;1.0";

//--- ===== INSTANCE SCOPE / IGNORE =====
// MASTER tickets to ignore. Examples:
// 123456;123457
// MASTER_280:123456;MASTER_687:998877
input string InpIgnoreMasterTickets                   = "";
// These filters apply to symbols in THIS Slave terminal.
// Empty include = all. Ignore always wins.
// Accepts comma or semicolon separated symbols.
input string InpSlaveSymbolsFilter                    = "";
input string InpSlaveSymbolsIgnore                    = "";

//--- ===== SYMBOL EQUIVALENCE =====
// CHANNEL,MASTER_SYMBOL,SLAVE_SYMBOL;...
// Example: MASTER_280,DE40,GER40;MASTER_687,US500,US500.cash
input string InpSymbolMaps                            = "";

//--- ===== OPEN POSITION MATCH =====
input bool InpMatchEntryPrice                         = true;
input int  InpEntryPriceTolerancePoints               = 100;
input bool InpCheckStopLoss                           = true;
input bool InpCheckTakeProfit                         = true;
input int  InpSLTPTolerancePoints                     = 10;
input int  InpVolumeToleranceSteps                    = 1;

//--- ===== PENDING BEHAVIOR =====
// For this Prop setup, copied pendings are NOT expected.
input bool InpMonitorPendingOrders                    = true;
input bool InpExpectPendingCopies                     = true;
input bool InpAutoFixPositionSLTP                     = true;
input bool InpAutoFixPendingSLTP                      = true;
input bool InpAutoCreateMissingPending                = true;
input bool InpAutoModifyPending                       = true;
input int  InpAutoFixPersistSeconds                   = 5;
// But an owned pending that is confirmed EXTRA may be deleted.
input bool InpAutoDeleteExtraPending                  = true;
input int  InpExtraPendingConfirmSeconds              = 2;
input int  InpPendingPriceTolerancePoints             = 100;

//--- ===== LUNA LEGACY SETTINGS =====
input bool   InpLunaRequireComment                    = false;
input string InpLunaCommentContains                   = "LUNA";

//--- ===== SNAPSHOT / TELEGRAM =====
input int    InpSnapshotStaleSeconds                  = 5;
input bool   InpEnableTelegram                        = true;
input string InpTelegramBotToken                      = "";
input string InpTelegramChatID                        = "";
// Un POST con TLS a api.telegram.org no siempre cierra en poco mas de un
// segundo: un timeout corto convertia una respuesta lenta en un fallo y metia
// el aviso en la cola de reintentos sin necesidad.
input int    InpTelegramTimeoutMs                     = 5000;
input int    InpMismatchReminderSeconds               = 15;
input bool   InpNotifySnapshotProblems                = false;
// Estado de avisos en disco. Sin el, un reinicio olvida que un problema estaba
// avisado y el RESUELTO correspondiente no se envia nunca.
input bool   InpPersistAlertState                     = true;
// ALERTA, RESUELTO y CRITICO de las correcciones automaticas son obligatorios:
// el usuario debe saber siempre que cambio el EA en la cuenta Slave.
// InpNotifySnapshotProblems solo gobierna la falta transitoria de datos. Un
// snapshot con el contrato roto se avisa siempre.

//--- ===== TIMERS / LIMITES INTERNOS =====
// Valores por defecto: los mismos que usa el Slave MT5.
// Caducidad del estado interno (ventanas, avisos cerrados, bloqueos).
input int InpStateTTLSeconds                          = 3600;
// Lecturas del snapshot por ciclo y pausa entre ellas, para absorber una
// lectura que coincida con la reescritura del Master.
input int InpSnapshotReadAttempts                     = 3;
input int InpSnapshotReadRetryMs                      = 15;
// Reintento de una correccion mientras el mercado del simbolo este cerrado.
input int InpMarketClosedRetrySeconds                 = 60;
// Troceo, cola y ritmo de envio de Telegram.
input int InpTelegramChunkChars                       = 3000;
input int InpTelegramQueueMax                         = 40;
input int InpTelegramSendsPerCycle                    = 2;
// Espera tras un envio fallido. Telegram limita por token y en el lado del
// servidor: reintentar cada ciclo renueva la penalizacion en lugar de dejarla
// caducar, asi que la espera arranca en la base y se dobla hasta el tope.
input int InpTelegramRetryBaseSeconds                 = 5;
input int InpTelegramRetryMaxSeconds                  = 300;

//--- ===== DIAGNOSTIC =====
input bool   InpVerboseLog                            = false;

// Los tickets del snapshot pueden venir de un Master MT5 y no caben en el int
// de MT4, asi que viajan como long en todas las estructuras.
struct PosRec { long ticket; string symbol; int type; double vol; double price; double sl; double tp; };
struct OrdRec { long ticket; string symbol; int type; double vol; double price; double sl; double tp; double stoplimit; };
struct Snap
{
   string channel,nick,broker;
   long account,written;
   int open_total,pending_total;
   int schema,status;
   bool valid,fresh;
   PosRec pos[];
   OrdRec ord[];
};
struct Owner
{
   string channel,comment;
   ENUM_COPY_PROFILE profile;
   double mult;
};
struct SymbolMapRec { string channel,master_symbol,slave_symbol; };
struct IgnoreRec { string channel; long ticket; bool scoped; };
struct AlertState { string key; bool active; datetime last; };
struct Candidate { string key; datetime first_seen; datetime last_seen; };
struct Blocked { string key; datetime last_seen; };

// Resultado de un intento de creacion automatica de pendiente.
#define CM_CREATE_BLOCKED    (-1)
#define CM_CREATE_FAILED     0
#define CM_CREATE_DONE       1
#define CM_CREATE_UNVERIFIED 2

// Resultado de la lectura de un snapshot.
#define CM_SNAP_OK       0
#define CM_SNAP_MISSING  1
#define CM_SNAP_PARTIAL  2
#define CM_SNAP_SCHEMA   3
#define CM_SNAP_CHANNEL  4

// Longitud maxima del identificador de canal. No es un ajuste: forma parte del
// contrato compartido con el Master y los dos EAs deben declarar el mismo
// valor, asi que se queda como constante.
#define CM_CHANNEL_MAX_LEN     32

// Margen con el que dos costes de emparejamiento se consideran el mismo. Solo
// absorbe el ruido de coma flotante. Si dos candidatas quedan dentro del
// margen, no existe una identidad suficiente y el enlace se rechaza.
#define CM_MATCH_EPS           1e-6

// Codigos de tipo que viajan en el snapshot. Son los de MQL5 porque el Master
// puede ser MT5; los cuatro tipos pendientes de MT4 (OP_BUYLIMIT..OP_SELLSTOP)
// y los dos de mercado (OP_BUY, OP_SELL) tienen exactamente los mismos valores,
// asi que no hace falta traducir nada. Los dos ultimos solo existen en MT5.
#define CM_TYPE_BUY              0
#define CM_TYPE_SELL             1
#define CM_TYPE_BUY_LIMIT        2
#define CM_TYPE_SELL_LIMIT       3
#define CM_TYPE_BUY_STOP         4
#define CM_TYPE_SELL_STOP        5
#define CM_TYPE_BUY_STOP_LIMIT   6
#define CM_TYPE_SELL_STOP_LIMIT  7

// Errores del servidor de trading de MT4 que este EA interpreta. Se declaran
// aqui con nombre propio para no depender de los alias del terminal.
#define CM_ERR_NO_RESULT              1
#define CM_ERR_COMMON_ERROR           2
#define CM_ERR_INVALID_TRADE_PARAM    3
#define CM_ERR_SERVER_BUSY            4
#define CM_ERR_NO_CONNECTION          6
#define CM_ERR_TOO_FREQUENT           8
#define CM_ERR_ACCOUNT_DISABLED      64
#define CM_ERR_INVALID_ACCOUNT       65
#define CM_ERR_TRADE_TIMEOUT        128
#define CM_ERR_INVALID_PRICE        129
#define CM_ERR_INVALID_STOPS        130
#define CM_ERR_INVALID_VOLUME       131
#define CM_ERR_MARKET_CLOSED        132
#define CM_ERR_TRADE_DISABLED       133
#define CM_ERR_NOT_ENOUGH_MONEY     134
#define CM_ERR_PRICE_CHANGED        135
#define CM_ERR_OFF_QUOTES           136
#define CM_ERR_BROKER_BUSY          137
#define CM_ERR_REQUOTE              138
#define CM_ERR_ORDER_LOCKED         139
#define CM_ERR_LONG_ONLY            140
#define CM_ERR_TOO_MANY_REQUESTS    141
#define CM_ERR_TRADE_MODIFY_DENIED  145
#define CM_ERR_TRADE_CONTEXT_BUSY   146
#define CM_ERR_EXPIRATION_DENIED    147
#define CM_ERR_TOO_MANY_ORDERS      148
#define CM_ERR_HEDGE_PROHIBITED     149
#define CM_ERR_FIFO_PROHIBITED      150
#define CM_ERR_INVALID_TICKET      4108

// MT4 limita el comentario de una orden a 31 caracteres. Un comentario
// propietario mas largo no podria coincidir nunca con una orden real.
#define CM_MT4_COMMENT_MAX_LEN       31

bool g_busy=false;
AlertState g_alerts[];
Candidate g_candidates[];
Blocked g_create_blocked[];

// Configuracion resuelta una sola vez: los parametros input no cambian durante
// la ejecucion, y reparsearlos dentro de los bucles de emparejamiento costaba
// un split de cadena por simbolo y por ciclo.
Owner        g_owners[];
SymbolMapRec g_symbol_maps[];
IgnoreRec    g_ignored[];
string       g_include_symbols[];
string       g_exclude_symbols[];

// Telegram: cola de reintento y ultimo error visible en el panel.
string   g_tg_queue[];
string   g_tg_last_error="";
int      g_tg_dropped=0;
// Backoff: momento a partir del cual se puede volver a intentar un envio y
// racha de fallos consecutivos que determina cuanto se espera.
datetime g_tg_next_try=0;
int      g_tg_fail_streak=0;

// El conjunto de avisos activos cambio y hay que volcarlo a disco. Solo se
// marca al entrar o salir un aviso, no al refrescar su marca de tiempo: de lo
// contrario se reescribiria el fichero en cada ciclo.
bool     g_alerts_dirty=false;

// Permiso de trading evaluado al principio de cada ciclo. Sin el, una
// correccion fallaria con CRITICO en cada ventana en lugar de avisar una vez.
bool   g_trade_allowed=false;
string g_trade_block_reason="";
// El contexto de trading de MT4 es unico para todo el terminal. Si otro EA lo
// tiene ocupado no hay nada que avisar: se deja el candidato vivo y se
// reintenta en el ciclo siguiente.
bool   g_trade_busy=false;

// Codigo del ultimo error de trading. Sustituye al retcode de MqlTradeResult.
int    g_last_trade_error=0;

// Firma del estado de la cuenta Slave en el ultimo ciclo. MT4 no tiene
// OnTradeTransaction, asi que OnTick la compara para reaccionar al instante.
string g_last_state="";

//---------------- utility ----------------
string Trim(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
}

// Master y Slave derivan el nombre del fichero comun con la misma regla. Por
// eso ambos exigen el mismo juego de caracteres en el identificador de canal:
// sanear en silencio dejaria al Slave leyendo un fichero que nadie escribe, o
// a dos canales distintos compartiendo snapshot.
bool ChannelIdValid(const string id)
{
   int len=StringLen(id);

   if(len<1 || len>CM_CHANNEL_MAX_LEN)
      return false;

   for(int i=0;i<len;i++)
   {
      ushort c=StringGetCharacter(id,i);
      bool ok=(c>='A' && c<='Z') || (c>='a' && c<='z') ||
              (c>='0' && c<='9') || c=='_' || c=='-' || c=='.';
      if(!ok)
         return false;
   }
   return true;
}
string SnapFile(const string c){ return "CopyMonitorMulti\\CM_"+c+".txt"; }

// MT4 no admite %I64u en StringFormat de forma fiable: los tickets se escriben
// con IntegerToString, que ya acepta un long.
string TicketText(const long ticket)
{
   return IntegerToString(ticket);
}

void SplitClean(string raw,const ushort sep,string &out[])
{
   ArrayResize(out,0);
   string p[]; int n=StringSplit(raw,sep,p);
   for(int i=0;i<n;i++)
   {
      string s=Trim(p[i]);
      if(s=="") continue;
      int z=ArraySize(out); ArrayResize(out,z+1); out[z]=s;
   }
}
ENUM_COPY_PROFILE ParseProfile(string s)
{
   StringToUpper(s);
   if(s=="PORTFOLIO46" || s=="PORTAFOLIO46" || s=="PORTFOLIO 46" || s=="PORTAFOLIO 46")
      return PROFILE_PORTFOLIO46;
   if(s=="LUNA") return PROFILE_LUNA;
   return PROFILE_GENERIC;
}
bool ProfileNameValid(string s)
{
   StringToUpper(s);
   return s=="GENERIC" || s=="LUNA" ||
          s=="PORTFOLIO46" || s=="PORTAFOLIO46" ||
          s=="PORTFOLIO 46" || s=="PORTAFOLIO 46";
}
string ProfileText(ENUM_COPY_PROFILE p)
{
   if(p==PROFILE_PORTFOLIO46) return "PORTFOLIO46";
   if(p==PROFILE_LUNA) return "LUNA";
   return "GENERIC";
}
string AccountText(const long account)
{
   if(account<=0) return "NO DISPONIBLE";
   return IntegerToString(account);
}
string BrokerText(const string broker)
{
   string value=Trim(broker);
   if(value=="") return "NO DISPONIBLE";
   return value;
}
string AlertHeader(const Snap &snap,const string level)
{
   // La hora de deteccion es imprescindible: un aviso que esperó en la cola se
   // entrega tarde y sin ella es indistinguible de uno recien detectado.
   return level+"\n\n"+
          "DETECTADO: "+TimeToString(TimeLocal(),TIME_DATE|TIME_SECONDS)+"\n"+
          "PORTAFOLIO ALIAS: "+InpPortfolioAlias+"\n"+
          "ID MASTER: "+AccountText(snap.account)+"\n"+
          "BROKER MASTER: "+BrokerText(snap.broker)+"\n"+
          "ID SLAVE: "+AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN))+"\n"+
          "BROKER SLAVE: "+BrokerText(AccountInfoString(ACCOUNT_COMPANY));
}
string PositionTypeText(const int type)
{
   if(type==CM_TYPE_BUY) return "BUY";
   if(type==CM_TYPE_SELL) return "SELL";
   return "DESCONOCIDO";
}
string OrderTypeText(const int type)
{
   if(type==CM_TYPE_BUY_LIMIT) return "BUY LIMIT";
   if(type==CM_TYPE_SELL_LIMIT) return "SELL LIMIT";
   if(type==CM_TYPE_BUY_STOP) return "BUY STOP";
   if(type==CM_TYPE_SELL_STOP) return "SELL STOP";
   if(type==CM_TYPE_BUY_STOP_LIMIT) return "BUY STOP LIMIT";
   if(type==CM_TYPE_SELL_STOP_LIMIT) return "SELL STOP LIMIT";
   return "DESCONOCIDO";
}
string PriceText(const double value)
{
   return DoubleToString(value,8);
}
string StopText(const double value,const string empty_text)
{
   if(MathAbs(value)<1e-12) return empty_text;
   return PriceText(value);
}
// Incluye los dos tipos STOP LIMIT que solo existen en MT5: el snapshot puede
// venir de un Master MT5 y hay que saber leerlos aunque MT4 no pueda crearlos.
bool IsPendingType(const int t)
{
   return t==CM_TYPE_BUY_LIMIT || t==CM_TYPE_SELL_LIMIT ||
          t==CM_TYPE_BUY_STOP || t==CM_TYPE_SELL_STOP ||
          t==CM_TYPE_BUY_STOP_LIMIT || t==CM_TYPE_SELL_STOP_LIMIT;
}
bool IsPositionType(const int t)
{
   return t==CM_TYPE_BUY || t==CM_TYPE_SELL;
}
bool IsStopLimitType(const int t)
{
   return t==CM_TYPE_BUY_STOP_LIMIT || t==CM_TYPE_SELL_STOP_LIMIT;
}
bool IsBuyPendingType(const int t)
{
   return t==CM_TYPE_BUY_LIMIT || t==CM_TYPE_BUY_STOP ||
          t==CM_TYPE_BUY_STOP_LIMIT;
}

//---------------- MT4 order selection ----------------
// OrderSelect por ticket encuentra tambien operaciones del historial, asi que
// comprobar el ticket no basta: sin mirar OrderCloseTime un aviso sobre una
// orden ya borrada no se resolveria nunca.
bool SelectLiveOrder(const long ticket)
{
   if(ticket<=0 || ticket>INT_MAX) return false;
   if(!OrderSelect((int)ticket,SELECT_BY_TICKET)) return false;
   return OrderCloseTime()==0;
}
bool SelectLivePending(const long ticket)
{
   if(!SelectLiveOrder(ticket)) return false;
   return IsPendingType(OrderType());
}
bool SelectLivePosition(const long ticket)
{
   if(!SelectLiveOrder(ticket)) return false;
   return IsPositionType(OrderType());
}

//---------------- configuration ----------------
bool LoadOwners(Owner &o[])
{
   ArrayResize(o,0);

   if(!InpMultiMaster)
   {
      Owner x;
      x.channel=Trim(InpMasterChannel);
      x.comment=InpSingleSlaveComment;
      x.profile=InpProfile;
      x.mult=InpLotMultiplier;

      if(!ChannelIdValid(x.channel))
      {
         PrintFormat("[CM SLAVE] InpMasterChannel invalido: use 1-%d caracteres A-Z a-z 0-9 _ - .",
                     CM_CHANNEL_MAX_LEN);
         return false;
      }
      if(x.mult<=0)
      {
         Print("[CM SLAVE] InpLotMultiplier debe ser mayor que cero.");
         return false;
      }
      // Un comentario mas largo del limite de MT4 no coincidiria con ninguna
      // orden del terminal: la vigilancia quedaria vacia sin avisar.
      if(StringLen(x.comment)>CM_MT4_COMMENT_MAX_LEN)
      {
         PrintFormat("[CM SLAVE] InpSingleSlaveComment supera los %d caracteres que admite MT4.",
                     CM_MT4_COMMENT_MAX_LEN);
         return false;
      }

      ArrayResize(o,1); o[0]=x;
      return true;
   }

   string ch[],co[],pr[],mu[];
   SplitClean(InpMasterChannels,(ushort)';',ch);
   SplitClean(InpOwnerComments,(ushort)';',co);
   SplitClean(InpMasterProfiles,(ushort)';',pr);
   SplitClean(InpVolumeMultipliers,(ushort)';',mu);

   int n=ArraySize(ch);
   if(n<1 || ArraySize(co)!=n || ArraySize(pr)!=n || ArraySize(mu)!=n)
   {
      PrintFormat("[CM SLAVE] Las cuatro listas multi-master deben tener la misma longitud. "
                  "canales=%d comentarios=%d perfiles=%d multiplicadores=%d",
                  n,ArraySize(co),ArraySize(pr),ArraySize(mu));
      return false;
   }

   ArrayResize(o,n);
   for(int i=0;i<n;i++)
   {
      o[i].channel=ch[i];
      o[i].comment=co[i];
      o[i].profile=ParseProfile(pr[i]);
      o[i].mult=StringToDouble(mu[i]);

      if(!ChannelIdValid(o[i].channel))
      {
         PrintFormat("[CM SLAVE] Canal invalido en la posicion %d: %s",i+1,ch[i]);
         return false;
      }
      // Un perfil mal escrito caia en GENERIC sin avisar y cambiaba en
      // silencio las comprobaciones de la instancia.
      if(!ProfileNameValid(pr[i]))
      {
         PrintFormat("[CM SLAVE] Perfil desconocido en la posicion %d: %s",i+1,pr[i]);
         return false;
      }
      if(o[i].comment=="")
      {
         PrintFormat("[CM SLAVE] El comentario propietario %d no puede estar vacio.",i+1);
         return false;
      }
      if(StringLen(o[i].comment)>CM_MT4_COMMENT_MAX_LEN)
      {
         PrintFormat("[CM SLAVE] El comentario propietario %d supera los %d caracteres que admite MT4: %s",
                     i+1,CM_MT4_COMMENT_MAX_LEN,o[i].comment);
         return false;
      }
      if(o[i].mult<=0)
      {
         PrintFormat("[CM SLAVE] Multiplicador invalido en la posicion %d: %s",i+1,mu[i]);
         return false;
      }
   }

   for(int i=0;i<n;i++)
      for(int j=i+1;j<n;j++)
         if(o[i].channel==o[j].channel || o[i].comment==o[j].comment)
         {
            PrintFormat("[CM SLAVE] Canal o comentario propietario repetido: %s / %s",
                        o[i].channel,o[i].comment);
            return false;
         }

   return true;
}

bool OwnerChannelConfigured(const string channel)
{
   for(int i=0;i<ArraySize(g_owners);i++)
      if(g_owners[i].channel==channel)
         return true;
   return false;
}

// Una entrada mal formada se descartaba en silencio y el Slave denunciaba para
// siempre copias "que faltan" sobre el simbolo sin mapear.
bool LoadSymbolMaps()
{
   ArrayResize(g_symbol_maps,0);

   if(Trim(InpSymbolMaps)=="")
      return true;

   string entries[];
   SplitClean(InpSymbolMaps,(ushort)';',entries);

   for(int i=0;i<ArraySize(entries);i++)
   {
      string f[];
      int n=StringSplit(entries[i],(ushort)',',f);

      if(n!=3)
      {
         PrintFormat("[CM SLAVE] Equivalencia de simbolo invalida: %s "
                     "(formato CANAL,SIMBOLO_MASTER,SIMBOLO_SLAVE)",entries[i]);
         return false;
      }

      SymbolMapRec rec;
      rec.channel=Trim(f[0]);
      rec.master_symbol=Trim(f[1]);
      rec.slave_symbol=Trim(f[2]);

      if(rec.channel=="" || rec.master_symbol=="" || rec.slave_symbol=="")
      {
         PrintFormat("[CM SLAVE] Equivalencia de simbolo incompleta: %s",entries[i]);
         return false;
      }

      for(int j=0;j<ArraySize(g_symbol_maps);j++)
         if(g_symbol_maps[j].channel==rec.channel &&
            g_symbol_maps[j].master_symbol==rec.master_symbol &&
            g_symbol_maps[j].slave_symbol!=rec.slave_symbol)
         {
            PrintFormat("[CM SLAVE] Equivalencia ambigua para %s/%s",
                        rec.channel,rec.master_symbol);
            return false;
         }

      int z=ArraySize(g_symbol_maps);
      ArrayResize(g_symbol_maps,z+1);
      g_symbol_maps[z]=rec;

      if(!OwnerChannelConfigured(rec.channel))
         PrintFormat("[CM SLAVE] Aviso: la equivalencia %s no corresponde a ningun canal configurado.",
                     entries[i]);
   }
   return true;
}

// Un ticket no numerico valia cero y no coincidia con nada: el usuario creia
// haber excluido una operacion que se seguia vigilando.
bool LoadIgnoredTickets()
{
   ArrayResize(g_ignored,0);

   if(Trim(InpIgnoreMasterTickets)=="")
      return true;

   string list=InpIgnoreMasterTickets;
   StringReplace(list,",",";");

   string tokens[];
   SplitClean(list,(ushort)';',tokens);

   for(int i=0;i<ArraySize(tokens);i++)
   {
      string token=tokens[i];
      string channel="";
      string digits=token;

      int colon=StringFind(token,":");
      if(colon>=0)
      {
         channel=Trim(StringSubstr(token,0,colon));
         digits=Trim(StringSubstr(token,colon+1));

         if(!ChannelIdValid(channel))
         {
            PrintFormat("[CM SLAVE] Canal invalido en InpIgnoreMasterTickets: %s",token);
            return false;
         }
      }

      if(StringLen(digits)<1)
      {
         PrintFormat("[CM SLAVE] Ticket vacio en InpIgnoreMasterTickets: %s",token);
         return false;
      }
      for(int k=0;k<StringLen(digits);k++)
      {
         ushort c=StringGetCharacter(digits,k);
         if(c<'0' || c>'9')
         {
            PrintFormat("[CM SLAVE] Ticket no numerico en InpIgnoreMasterTickets: %s",token);
            return false;
         }
      }

      IgnoreRec rec;
      rec.channel=channel;
      rec.ticket=(long)StringToInteger(digits);
      rec.scoped=(colon>=0);

      if(rec.ticket==0)
      {
         PrintFormat("[CM SLAVE] Ticket cero en InpIgnoreMasterTickets: %s",token);
         return false;
      }

      int z=ArraySize(g_ignored);
      ArrayResize(g_ignored,z+1);
      g_ignored[z]=rec;

      if(rec.scoped && !OwnerChannelConfigured(rec.channel))
         PrintFormat("[CM SLAVE] Aviso: el ticket ignorado %s no corresponde a ningun canal configurado.",
                     token);
   }
   return true;
}

void LoadSymbolList(string raw,string &out[])
{
   StringReplace(raw,";",",");
   SplitClean(raw,(ushort)',',out);
}

bool BuildConfig()
{
   if(!LoadOwners(g_owners))
      return false;
   if(!LoadSymbolMaps())
      return false;
   if(!LoadIgnoredTickets())
      return false;

   LoadSymbolList(InpSlaveSymbolsFilter,g_include_symbols);
   LoadSymbolList(InpSlaveSymbolsIgnore,g_exclude_symbols);
   return true;
}

bool MasterTicketIgnored(const string channel,const long ticket)
{
   for(int i=0;i<ArraySize(g_ignored);i++)
   {
      if(g_ignored[i].ticket!=ticket)
         continue;
      // Sin canal explicito el ticket se ignora en cualquier canal configurado.
      if(!g_ignored[i].scoped || g_ignored[i].channel==channel)
         return true;
   }
   return false;
}

bool SymbolListContains(const string &list[],const string symbol)
{
   for(int i=0;i<ArraySize(list);i++)
      if(list[i]==symbol)
         return true;
   return false;
}

bool SlaveSymbolAllowed(const string symbol)
{
   if(SymbolListContains(g_exclude_symbols,symbol))
      return false;

   if(ArraySize(g_include_symbols)==0)
      return true;

   return SymbolListContains(g_include_symbols,symbol);
}

//---------------- telegram ----------------
string UrlEncode(const string src)
{
   uchar b[]; int n=StringToCharArray(src,b,0,WHOLE_ARRAY,CP_UTF8); string o="";
   for(int i=0;i<n-1;i++)
   {
      int c=(int)b[i];
      bool safe=(c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'||c=='~';
      if(safe)o+=CharToString((uchar)c); else if(c==' ')o+="%20"; else o+="%"+StringFormat("%02X",c);
   }
   return o;
}
bool TgConfigured()
{
   // WebRequest no existe en el probador de MT4: alli no se puede avisar.
   if(IsTesting() || IsOptimization()) return false;
   return InpEnableTelegram && InpTelegramBotToken!="" && InpTelegramChatID!="";
}
// Telegram responde a un 429 con el numero de segundos que falta para poder
// volver a escribir. Viene en el cuerpo JSON y es el unico dato fiable para
// saber cuanto esperar: ignorarlo obliga a adivinar.
int TgRetryAfterFromBody(const string body)
{
   int at=StringFind(body,"\"retry_after\"");
   if(at<0) return 0;

   int colon=StringFind(body,":",at);
   if(colon<0) return 0;

   return (int)StringToInteger(StringSubstr(body,colon+1,12));
}
// Un fallo no se reintenta en el ciclo siguiente. El limite de Telegram es por
// token y vive en su servidor, asi que un reintento por segundo lo renueva sin
// descanso y la penalizacion no caduca nunca.
void TgBackoff(const int retry_after_seconds)
{
   g_tg_fail_streak++;

   int wait;
   if(retry_after_seconds>0)
   {
      // Lo que diga Telegram se respeta entero, aunque pase del tope local:
      // volver antes de tiempo es justo lo que mantiene vivo el bloqueo.
      wait=retry_after_seconds;
   }
   else
   {
      wait=InpTelegramRetryBaseSeconds;
      for(int i=1;i<g_tg_fail_streak && wait<InpTelegramRetryMaxSeconds;i++)
         wait*=2;
      if(wait>InpTelegramRetryMaxSeconds) wait=InpTelegramRetryMaxSeconds;
   }

   if(wait<1) wait=1;
   g_tg_next_try=TimeLocal()+wait;
}
// Mientras dure la espera no se toca la red: ni la cola ni un aviso nuevo.
bool TgSendDue()
{
   return TimeLocal()>=g_tg_next_try;
}
int TgPendingSeconds()
{
   if(TgSendDue()) return 0;
   return (int)(g_tg_next_try-TimeLocal());
}
// POST en lugar de GET: el texto viaja en el cuerpo y un aviso largo no depende
// del limite de longitud de una URL.
bool TgPost(const string msg)
{
   if(!TgConfigured()) return false;

   string url="https://api.telegram.org/bot"+InpTelegramBotToken+"/sendMessage";
   string body="chat_id="+UrlEncode(InpTelegramChatID)+"&text="+UrlEncode(msg);

   char data[],res[];
   string hdr;
   int len=StringToCharArray(body,data,0,WHOLE_ARRAY,CP_UTF8)-1;
   if(len<0) len=0;
   ArrayResize(data,len);

   ResetLastError();
   int http=WebRequest("POST",url,
                       "Content-Type: application/x-www-form-urlencoded\r\n",
                       InpTelegramTimeoutMs,data,res,hdr);
   int err=GetLastError();

   if(http==200)
   {
      g_tg_last_error="";
      g_tg_fail_streak=0;
      g_tg_next_try=0;
      return true;
   }

   g_tg_last_error=StringFormat("HTTP=%d err=%d",http,err);

   // Solo el 429 trae retry_after. En los demas fallos el cuerpo no sirve y la
   // espera la decide el backoff.
   int retry_after=0;
   if(http==429)
      retry_after=TgRetryAfterFromBody(CharArrayToString(res,0,WHOLE_ARRAY,CP_UTF8));

   TgBackoff(retry_after);
   PrintFormat("[CM SLAVE] Telegram fail %s. Proximo intento en %d s. En cola: %d.",
               g_tg_last_error,TgPendingSeconds(),ArraySize(g_tg_queue));
   return false;
}
void TgAddChunk(string &chunks[],const string chunk)
{
   if(chunk=="") return;
   int n=ArraySize(chunks);
   ArrayResize(chunks,n+1);
   chunks[n]=chunk;
}
// Se corta por lineas para que cada trozo siga siendo legible.
void TgSplit(const string msg,string &chunks[])
{
   ArrayResize(chunks,0);

   string lines[];
   int n=StringSplit(msg,(ushort)'\n',lines);
   string current="";

   for(int i=0;i<n;i++)
   {
      string candidate=(current=="") ? lines[i] : current+"\n"+lines[i];

      if(StringLen(candidate)<=InpTelegramChunkChars)
      {
         current=candidate;
         continue;
      }

      TgAddChunk(chunks,current);
      current=lines[i];

      while(StringLen(current)>InpTelegramChunkChars)
      {
         TgAddChunk(chunks,StringSubstr(current,0,InpTelegramChunkChars));
         current=StringSubstr(current,InpTelegramChunkChars);
      }
   }

   TgAddChunk(chunks,current);

   if(ArraySize(chunks)==0)
      TgAddChunk(chunks,msg);
}
void TgEnqueue(const string chunk)
{
   int n=ArraySize(g_tg_queue);

   if(n>=InpTelegramQueueMax)
   {
      // Cola llena: se descarta lo mas antiguo y se deja constancia.
      for(int i=0;i<n-1;i++) g_tg_queue[i]=g_tg_queue[i+1];
      ArrayResize(g_tg_queue,n-1);
      g_tg_dropped++;
      n--;
   }

   ArrayResize(g_tg_queue,n+1);
   g_tg_queue[n]=chunk;
}
// Un aviso que no sale no debe perderse: espera en cola y se reintenta en los
// ciclos siguientes. Mientras haya cola, lo nuevo se encola tambien para no
// adelantar mensajes y romper el orden de los avisos.
bool Tg(const string msg)
{
   if(!TgConfigured()) return false;

   string chunks[];
   TgSplit(msg,chunks);

   // Con una espera en curso tampoco se intenta un aviso nuevo: iria directo a
   // otro fallo y alargaria la penalizacion.
   bool queued=(ArraySize(g_tg_queue)>0) || !TgSendDue();

   for(int i=0;i<ArraySize(chunks);i++)
   {
      if(queued || !TgPost(chunks[i]))
      {
         TgEnqueue(chunks[i]);
         queued=true;
      }
   }
   return !queued;
}
void TgFlush()
{
   if(!TgConfigured()) return;
   if(!TgSendDue()) return;

   for(int sent=0;sent<InpTelegramSendsPerCycle && ArraySize(g_tg_queue)>0;sent++)
   {
      if(!TgPost(g_tg_queue[0]))
         return;

      int n=ArraySize(g_tg_queue);
      for(int i=0;i<n-1;i++) g_tg_queue[i]=g_tg_queue[i+1];
      ArrayResize(g_tg_queue,n-1);
   }
}
int AlertIndex(const string k)
{
   for(int i=0;i<ArraySize(g_alerts);i++) if(g_alerts[i].key==k) return i;
   return -1;
}
void PersistAlert(const string k,const string msg)
{
   datetime now=TimeLocal(); int i=AlertIndex(k);
   if(i<0){ i=ArraySize(g_alerts); ArrayResize(g_alerts,i+1); g_alerts[i].key=k; g_alerts[i].active=false; g_alerts[i].last=0; }
   bool due=!g_alerts[i].active || (now-g_alerts[i].last)>=InpMismatchReminderSeconds;
   if(!g_alerts[i].active) g_alerts_dirty=true;
   g_alerts[i].active=true;
   if(due)
   {
      // Throttle attempts as well as successful deliveries. Otherwise a
      // Telegram outage causes one WebRequest per monitor cycle.
      g_alerts[i].last=now;
      Tg(msg);
   }
}
void ClearAlert(const string k)
{
   int i=AlertIndex(k);
   if(i<0) return;
   if(g_alerts[i].active) g_alerts_dirty=true;
   g_alerts[i].active=false;
}
// Un aviso de espera no se repite: hasta que el mercado abra no hay nada nuevo
// que contar y el recordatorio solo generaria ruido.
void AlertOnce(const string k,const string msg)
{
   int i=AlertIndex(k);
   if(i<0)
   {
      i=ArraySize(g_alerts); ArrayResize(g_alerts,i+1);
      g_alerts[i].key=k; g_alerts[i].active=false; g_alerts[i].last=0;
   }
   bool first=!g_alerts[i].active;
   if(first) g_alerts_dirty=true;
   g_alerts[i].active=true;
   g_alerts[i].last=TimeLocal();
   if(first) Tg(msg);
}
// Mantiene vivo un aviso ya emitido sin reenviarlo, para que siga pudiendo
// resolverse y no caduque mientras el problema continua.
void KeepAlert(const string k)
{
   int i=AlertIndex(k);
   if(i<0) return;
   g_alerts[i].active=true;
   g_alerts[i].last=TimeLocal();
}
void ResolveAlert(const string k,const string msg)
{
   int i=AlertIndex(k);
   if(i<0) return;
   if(g_alerts[i].active)
   {
      Tg(msg);
      g_alerts_dirty=true;
   }
   g_alerts[i].active=false;
}

//---------------- alert state on disk ----------------
// El identificador de la instancia es libre, pero acaba siendo un nombre de
// fichero: se queda solo con lo que cualquier sistema acepta.
string SafeFileToken(const string raw)
{
   string out="";
   for(int i=0;i<StringLen(raw);i++)
   {
      ushort c=StringGetCharacter(raw,i);
      bool ok=(c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-';
      out+=ok ? ShortToString(c) : "_";
   }
   return out=="" ? "SLAVE" : out;
}
// Local al terminal, no en la carpeta comun: el estado es de esta instancia y
// dos Slave distintos no deben pisarse el fichero.
string AlertStateFile()
{
   return "CopyMonitorMulti\\CM_ALERTS_"+SafeFileToken(InpSlaveID)+".txt";
}
// Solo se guardan los avisos activos: son los unicos que deben sobrevivir a un
// reinicio para que su RESUELTO llegue a emitirse.
void SaveAlertState()
{
   if(!InpPersistAlertState || !g_alerts_dirty) return;

   FolderCreate("CopyMonitorMulti");

   int h=FileOpen(AlertStateFile(),FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
   {
      PrintFormat("[CM SLAVE] No se pudo guardar el estado de avisos en %s. err=%d",
                  AlertStateFile(),GetLastError());
      return;
   }

   for(int i=0;i<ArraySize(g_alerts);i++)
   {
      if(!g_alerts[i].active) continue;
      // Tabulador como separador: las claves llevan '|' pero nunca tabuladores.
      FileWrite(h,IntegerToString((long)g_alerts[i].last)+"\t"+g_alerts[i].key);
   }

   FileClose(h);
   g_alerts_dirty=false;
}
void LoadAlertState()
{
   if(!InpPersistAlertState) return;

   int h=FileOpen(AlertStateFile(),FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h==INVALID_HANDLE) return;

   datetime now=TimeLocal();
   int restored=0,discarded=0;

   while(!FileIsEnding(h))
   {
      string line=FileReadString(h);
      if(line=="") continue;

      int tab=StringFind(line,"\t");
      if(tab<=0) continue;

      string key=StringSubstr(line,tab+1);
      if(key=="" || AlertIndex(key)>=0) continue;

      datetime last=(datetime)StringToInteger(StringSubstr(line,0,tab));

      // Un aviso activo que nadie vuelve a tocar no caduca nunca: PruneState
      // solo descarta los inactivos. Si la clave ya no corresponde a ningun
      // canal configurado, revivirla la dejaria en el fichero para siempre,
      // asi que se aplica la misma caducidad que al resto del estado.
      if(now-last>InpStateTTLSeconds)
      {
         discarded++;
         continue;
      }

      int n=ArraySize(g_alerts);
      ArrayResize(g_alerts,n+1);
      g_alerts[n].key=key;
      g_alerts[n].active=true;
      g_alerts[n].last=last;
      restored++;
   }

   FileClose(h);

   if(restored>0 || discarded>0)
      PrintFormat("[CM SLAVE] Estado de avisos recuperado: %d activos, %d caducados.",
                  restored,discarded);

   // El fichero en disco ya no refleja lo que hay en memoria si se descarto algo.
   if(discarded>0) g_alerts_dirty=true;
}

//---------------- snapshot ----------------
void AddPos(PosRec &a[],const PosRec &x){ int n=ArraySize(a); ArrayResize(a,n+1); a[n]=x; }
void AddOrd(OrdRec &a[],const OrdRec &x){ int n=ArraySize(a); ArrayResize(a,n+1); a[n]=x; }

// Version del esquema entendida por este lector. Una version desconocida no se
// interpreta: significa que el Master es mas nuevo y publica otro contrato.
int SnapshotSchema(const string token)
{
   if(token=="1") return 1;
   if(token=="2") return 2;
   if(token=="3") return 3;
   return 0;
}

int ReadSnapOnce(const string channel,Snap &s)
{
   s.channel=channel;s.nick="";s.broker="";s.account=0;s.written=0;
   s.open_total=0;s.pending_total=0;s.schema=0;s.valid=false;s.fresh=false;
   ArrayResize(s.pos,0); ArrayResize(s.ord,0);

   int h=FileOpen(SnapFile(channel),FILE_COMMON|FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE) return CM_SNAP_MISSING;

   bool meta=false,en=false;
   int schema=0;
   string meta_channel="";

   while(!FileIsEnding(h))
   {
      string line=FileReadString(h); if(line=="")continue;
      string p[]; int n=StringSplit(line,(ushort)'|',p); if(n<=0)continue;
      if(p[0]=="META" && n>=8 && !meta)
      {
         schema=SnapshotSchema(p[1]);
         if(schema==0)
         {
            FileClose(h);
            s.schema=0;
            return CM_SNAP_SCHEMA;
         }
         s.written=(long)StringToInteger(p[2]);meta_channel=p[3];s.nick=p[4];s.account=(long)StringToInteger(p[5]);
         s.open_total=(int)StringToInteger(p[6]);s.pending_total=(int)StringToInteger(p[7]);
         // El broker solo viaja desde el esquema 2; un Master antiguo lo deja vacio.
         s.broker=(n>=9)?p[8]:"";
         s.schema=schema;
         meta=true;
      }
      else if(p[0]=="POS" && n>=8)
      {
         PosRec x; x.ticket=(long)StringToInteger(p[1]);x.symbol=p[2];x.type=(int)StringToInteger(p[3]);
         x.vol=StringToDouble(p[4]);x.price=StringToDouble(p[5]);x.sl=StringToDouble(p[6]);x.tp=StringToDouble(p[7]);AddPos(s.pos,x);
      }
      else if(p[0]=="ORD" && n>=8)
      {
         OrdRec x; x.ticket=(long)StringToInteger(p[1]);x.symbol=p[2];x.type=(int)StringToInteger(p[3]);
         x.vol=StringToDouble(p[4]);x.price=StringToDouble(p[5]);x.sl=StringToDouble(p[6]);x.tp=StringToDouble(p[7]);
         // El precio stop-limit solo viaja desde el esquema 3.
         x.stoplimit=(n>=9)?StringToDouble(p[8]):0.0;
         AddOrd(s.ord,x);
      }
      else if(p[0]=="END")
      {
         en=true;
         break;
      }
   }
   FileClose(h);

   if(!meta || !en ||
      s.open_total!=ArraySize(s.pos) ||
      s.pending_total!=ArraySize(s.ord))
      return CM_SNAP_PARTIAL;

   if(meta_channel!=channel)
   {
      s.channel=meta_channel;
      return CM_SNAP_CHANNEL;
   }

   s.channel=meta_channel;
   s.valid=true;
   long age=(long)TimeLocal()-s.written;
   // Se admite un segundo de adelanto por el redondeo del reloj local.
   s.fresh=age>=-1 && age<=InpSnapshotStaleSeconds;
   return CM_SNAP_OK;
}

// Una lectura puede coincidir con la reescritura del Master. El contenido roto
// se detecta por contadores y por la marca END, asi que se reintenta antes de
// declarar que no hay datos.
bool ReadSnap(const string channel,Snap &s)
{
   int status=CM_SNAP_MISSING;

   for(int attempt=0;attempt<InpSnapshotReadAttempts;attempt++)
   {
      status=ReadSnapOnce(channel,s);

      if(status==CM_SNAP_OK || status==CM_SNAP_SCHEMA || status==CM_SNAP_CHANNEL)
         break;

      if(attempt+1<InpSnapshotReadAttempts)
         Sleep(InpSnapshotReadRetryMs);
   }

   s.status=status;

   if(status!=CM_SNAP_OK && InpVerboseLog)
      PrintFormat("[CM SLAVE] Snapshot %s no utilizable. status=%d",channel,status);

   return status==CM_SNAP_OK;
}

//---------------- symbol mapping ----------------
bool SymbolEq(const string channel,const string ms,const string ss)
{
   if(ms==ss) return true;
   for(int i=0;i<ArraySize(g_symbol_maps);i++)
      if(g_symbol_maps[i].channel==channel &&
         g_symbol_maps[i].master_symbol==ms &&
         g_symbol_maps[i].slave_symbol==ss)
         return true;
   return false;
}
string ExpectedSlaveSymbol(const string channel,const string master_symbol)
{
   for(int i=0;i<ArraySize(g_symbol_maps);i++)
      if(g_symbol_maps[i].channel==channel &&
         g_symbol_maps[i].master_symbol==master_symbol)
         return g_symbol_maps[i].slave_symbol;
   return master_symbol;
}
// MT4 no tiene SymbolInfoDouble para volumen ni stops: todo sale de MarketInfo.
double VolumeStepOf(const string s){ return MarketInfo(s,MODE_LOTSTEP); }
double VolumeMinOf(const string s){ return MarketInfo(s,MODE_MINLOT); }
double VolumeMaxOf(const string s){ return MarketInfo(s,MODE_MAXLOT); }
int    DigitsOf(const string s)
{
   int digits=(int)MarketInfo(s,MODE_DIGITS);
   return (digits>=0 && digits<=8) ? digits : 5;
}
double NormPrice(const string s,const double price)
{
   return NormalizeDouble(price,DigitsOf(s));
}
int VolumeDigits(const double step)
{
   for(int digits=0;digits<=8;digits++)
      if(MathAbs(NormalizeDouble(step,digits)-step)<1e-9)
         return digits;
   return 8;
}
double ExpectedSlaveVolume(const string slave_symbol,const double master_volume,const double multiplier)
{
   double raw=master_volume*multiplier;
   double step=VolumeStepOf(slave_symbol);
   double minimum=VolumeMinOf(slave_symbol);
   double maximum=VolumeMaxOf(slave_symbol);
   if(step<=0) return raw;

   double normalized=MathRound(raw/step)*step;
   if(minimum>0) normalized=MathMax(minimum,normalized);
   if(maximum>0) normalized=MathMin(maximum,normalized);
   return NormalizeDouble(normalized,VolumeDigits(step));
}
string VolumeText(const string symbol,const double volume)
{
   double step=VolumeStepOf(symbol);
   return DoubleToString(volume,step>0 ? VolumeDigits(step) : 4);
}
string MasterPendingDetails(const Owner &o,const OrdRec &order)
{
   string slave_symbol=ExpectedSlaveSymbol(o.channel,order.symbol);
   double expected_volume=ExpectedSlaveVolume(slave_symbol,order.vol,o.mult);
   string text=
      "Estado: ORDEN PENDIENTE\n"+
      "Tipo: "+OrderTypeText(order.type)+"\n"+
      "Símbolo Master: "+order.symbol+"\n"+
      "Símbolo esperado Slave: "+slave_symbol+"\n"+
      "Ticket Master: "+TicketText(order.ticket)+"\n\n"+
      "Volumen Master: "+VolumeText(slave_symbol,order.vol)+"\n"+
      "Volumen Slave esperado: "+VolumeText(slave_symbol,expected_volume)+"\n"+
      "Precio de entrada: "+PriceText(order.price);
   if(IsStopLimitType(order.type))
      text+="\nPrecio límite: "+StopText(order.stoplimit,"NO DISPONIBLE");
   text+=
      "\nStop Loss: "+StopText(order.sl,"SIN SL")+"\n"+
      "Take Profit: "+StopText(order.tp,"SIN TP");
   return text;
}
string SlavePendingDetails(const OrdRec &order)
{
   string text=
      "Estado: ORDEN PENDIENTE\n"+
      "Tipo: "+OrderTypeText(order.type)+"\n"+
      "Símbolo: "+order.symbol+"\n"+
      "Ticket Slave: "+TicketText(order.ticket)+"\n"+
      "Volumen Slave: "+VolumeText(order.symbol,order.vol)+"\n"+
      "Precio de entrada: "+PriceText(order.price);
   if(IsStopLimitType(order.type))
      text+="\nPrecio límite: "+StopText(order.stoplimit,"SIN LÍMITE");
   text+=
      "\nStop Loss: "+StopText(order.sl,"SIN SL")+"\n"+
      "Take Profit: "+StopText(order.tp,"SIN TP");
   return text;
}

//---------------- slave collections ----------------
bool OwnerCommentMatch(const Owner &o,const string comment)
{
   if(InpMultiMaster) return comment==o.comment;
   if(o.comment!="") return comment==o.comment;

   if(o.profile==PROFILE_LUNA && InpLunaRequireComment)
      return StringFind(comment,InpLunaCommentContains)>=0;

   return true;
}
// En MT4 posiciones y pendientes comparten la lista de operaciones, asi que las
// dos colecciones se filtran por tipo. Hacia atras: si el terminal retira una
// entrada mientras se recorre, los indices ya visitados no se desplazan.
void SlavePosForOwner(const Owner &o,PosRec &a[])
{
   ArrayResize(a,0);
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES))continue;
      if(!IsPositionType(OrderType()))continue;
      string symbol=OrderSymbol();
      if(symbol=="")continue;
      if(!SlaveSymbolAllowed(symbol))continue;
      if(!OwnerCommentMatch(o,OrderComment()))continue;

      PosRec x; x.ticket=(long)OrderTicket();x.symbol=symbol;x.type=OrderType();
      x.vol=OrderLots();x.price=OrderOpenPrice();
      x.sl=OrderStopLoss();x.tp=OrderTakeProfit();AddPos(a,x);
   }
}
void SlaveOrdForOwner(const Owner &o,OrdRec &a[])
{
   ArrayResize(a,0);
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES))continue;
      if(!IsPendingType(OrderType()))continue;
      string symbol=OrderSymbol();
      if(symbol=="")continue;
      if(!SlaveSymbolAllowed(symbol))continue;
      if(!OwnerCommentMatch(o,OrderComment()))continue;
      OrdRec x;x.ticket=(long)OrderTicket();x.symbol=symbol;x.type=OrderType();x.vol=OrderLots();
      x.price=OrderOpenPrice();x.sl=OrderStopLoss();x.tp=OrderTakeProfit();
      // MT4 no tiene ordenes STOP LIMIT: no hay segundo precio que comparar.
      x.stoplimit=0.0;AddOrd(a,x);
   }
}
bool VolEq(const string ss,double actual,double expected)
{
   double step=VolumeStepOf(ss);if(step<=0)step=0.01;
   double normalized=ExpectedSlaveVolume(ss,expected,1.0);
   // La tolerancia se expresa en pasos de volumen; el epsilon solo absorbe el
   // ruido de coma flotante cuando la tolerancia configurada es cero.
   double tolerance=MathMax(0,InpVolumeToleranceSteps)*step;
   return MathAbs(actual-normalized)<=tolerance+1e-9;
}
double PointOf(const string s){ double p=MarketInfo(s,MODE_POINT); return p>0?p:0.00001; }
bool StopEq(double a,double b,double tol)
{
   bool az=MathAbs(a)<1e-12,bz=MathAbs(b)<1e-12;
   // El epsilon evita que una tolerancia de cero falle por el redondeo del
   // texto del snapshot frente al valor del terminal.
   if(az&&bz)return true; if(az!=bz)return false; return MathAbs(a-b)<=tol+1e-9;
}
bool PriceEq(double a,double b,double tol)
{
   return MathAbs(a-b)<=tol+1e-9;
}

//---------------- trading guards ----------------
// Sin permiso de trading toda correccion fallaria con CRITICO en cada ventana.
// Se comprueba una vez por ciclo y se avisa como BLOQUEADO.
bool TradingPermitted(string &reason)
{
   reason="";

   // IsExpertEnabled es el boton de AutoTrading del terminal; IsTradeAllowed
   // anade el permiso del propio grafico.
   if(!IsExpertEnabled() || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      reason="El terminal Slave tiene el trading automático desactivado.";
      return false;
   }
   if(!IsTradeAllowed())
   {
      reason="Este EA no tiene permiso para operar en el gráfico.";
      return false;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      reason="La cuenta Slave no permite operar.";
      return false;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      reason="La cuenta Slave no permite operar con Expert Advisors.";
      return false;
   }
   return true;
}
// MT4 no distingue los modos LONGONLY / SHORTONLY / CLOSEONLY de MT5: solo
// expone si el simbolo admite operaciones. El resto de casos los rechaza el
// broker y se informan con el codigo de error.
bool SymbolAcceptsNewOrders(const string symbol,const int type,string &reason)
{
   if(MarketInfo(symbol,MODE_TRADEALLOWED)==0)
   {
      reason="El símbolo tiene el trading deshabilitado en el terminal Slave.";
      return false;
   }
   return true;
}
double StopsDistance(const string symbol)
{
   return MarketInfo(symbol,MODE_STOPLEVEL)*PointOf(symbol);
}
// La distancia de congelacion es propia de MT4: dentro de ella el broker
// rechaza modificar o borrar una pendiente aunque el precio sea valido.
double FreezeDistance(const string symbol)
{
   return MarketInfo(symbol,MODE_FREEZELEVEL)*PointOf(symbol);
}
bool CurrentPrices(const string symbol,double &bid,double &ask)
{
   bid=MarketInfo(symbol,MODE_BID);
   ask=MarketInfo(symbol,MODE_ASK);
   return bid>0 && ask>0;
}
// Un precio que el broker no puede aceptar produciria un fallo en cada ventana
// de persistencia. Se detecta antes de enviar nada y se informa como BLOQUEADO.
bool PendingPriceAcceptable(const string symbol,const int type,const double price,
                            const double sl,const double tp,const double stoplimit,
                            string &reason)
{
   reason="";

   if(price<=0)
   {
      reason="El precio de entrada del Master no es válido.";
      return false;
   }
   if(IsStopLimitType(type) && stoplimit<=0)
   {
      reason="El snapshot del Master no transporta el precio límite de la orden STOP LIMIT.";
      return false;
   }

   double bid=0,ask=0;
   if(!CurrentPrices(symbol,bid,ask))
   {
      reason="No hay precios actuales del símbolo en el terminal Slave.";
      return false;
   }

   double point=PointOf(symbol);
   double stops=StopsDistance(symbol);
   double eps=point*0.5;
   bool ok=true;

   if(type==CM_TYPE_BUY_LIMIT)
      ok=(price<=ask-stops+eps);
   else if(type==CM_TYPE_SELL_LIMIT)
      ok=(price>=bid+stops-eps);
   else if(type==CM_TYPE_BUY_STOP || type==CM_TYPE_BUY_STOP_LIMIT)
      ok=(price>=ask+stops-eps);
   else
      ok=(price<=bid-stops+eps);

   if(!ok)
   {
      reason=StringFormat("El precio de entrada no respeta la distancia mínima del broker (%d puntos).",
                          (int)MarketInfo(symbol,MODE_STOPLEVEL));
      return false;
   }

   bool is_buy=IsBuyPendingType(type);

   if(MathAbs(sl)>1e-12)
   {
      bool sl_ok=is_buy ? (sl<=price-stops+eps) : (sl>=price+stops-eps);
      if(!sl_ok)
      {
         reason="El Stop Loss del Master queda demasiado cerca del precio de entrada.";
         return false;
      }
   }
   if(MathAbs(tp)>1e-12)
   {
      bool tp_ok=is_buy ? (tp>=price+stops-eps) : (tp<=price-stops+eps);
      if(!tp_ok)
      {
         reason="El Take Profit del Master queda demasiado cerca del precio de entrada.";
         return false;
      }
   }
   return true;
}
// Antes de modificar o borrar una pendiente hay que comprobar la distancia de
// congelacion sobre el precio que la orden tiene ahora: dentro de ella el
// broker rechaza la peticion y reintentarla solo produce ruido.
bool PendingNotFrozen(const string symbol,const int type,const double current_price,
                      string &reason)
{
   reason="";

   double freeze=FreezeDistance(symbol);
   if(freeze<=0) return true;

   double bid=0,ask=0;
   if(!CurrentPrices(symbol,bid,ask))
   {
      reason="No hay precios actuales del símbolo en el terminal Slave.";
      return false;
   }

   double reference=IsBuyPendingType(type) ? ask : bid;

   if(MathAbs(current_price-reference)<freeze)
   {
      reason=StringFormat("La orden pendiente está dentro de la distancia de congelación del broker (%d puntos).",
                          (int)MarketInfo(symbol,MODE_FREEZELEVEL));
      return false;
   }
   return true;
}
bool PositionStopsAcceptable(const string symbol,const int type,
                             const double sl,const double tp,string &reason)
{
   reason="";

   double bid=0,ask=0;
   if(!CurrentPrices(symbol,bid,ask))
   {
      reason="No hay precios actuales del símbolo en el terminal Slave.";
      return false;
   }

   double point=PointOf(symbol);
   double stops=StopsDistance(symbol);
   double eps=point*0.5;
   bool is_buy=(type==CM_TYPE_BUY);

   if(MathAbs(sl)>1e-12)
   {
      bool sl_ok=is_buy ? (sl<=bid-stops+eps) : (sl>=ask+stops-eps);
      if(!sl_ok)
      {
         reason="El Stop Loss del Master queda dentro de la distancia mínima del broker.";
         return false;
      }
   }
   if(MathAbs(tp)>1e-12)
   {
      bool tp_ok=is_buy ? (tp>=ask+stops-eps) : (tp<=bid-stops+eps);
      if(!tp_ok)
      {
         reason="El Take Profit del Master queda dentro de la distancia mínima del broker.";
         return false;
      }
   }
   return true;
}

//---------------- market session guards ----------------
// Un mercado cerrado no es un fallo de la copia: el bróker rechaza la orden y
// no hay nada que decidir hasta que abra la sesión. Con dos brókers distintos
// los horarios no tienen por qué coincidir, así que se trata como espera: un
// único aviso, reintentos espaciados y la corrección en cuanto abra.
struct MarketWait { string key; datetime last_try; };
MarketWait g_market_wait[];

int MarketWaitIndex(const string key)
{
   for(int i=0;i<ArraySize(g_market_wait);i++)
      if(g_market_wait[i].key==key)
         return i;
   return -1;
}
bool MarketWaiting(const string key)
{
   return MarketWaitIndex(key)>=0;
}
// Sin entrada se intenta de inmediato; con entrada se respeta el intervalo.
bool MarketWaitDue(const string key)
{
   int i=MarketWaitIndex(key);
   if(i<0) return true;
   return (TimeLocal()-g_market_wait[i].last_try)>=InpMarketClosedRetrySeconds;
}
void MarketWaitMark(const string key)
{
   int i=MarketWaitIndex(key);
   if(i<0)
   {
      i=ArraySize(g_market_wait);
      ArrayResize(g_market_wait,i+1);
      g_market_wait[i].key=key;
   }
   g_market_wait[i].last_try=TimeLocal();
}
void MarketWaitRemove(const string key)
{
   int i=MarketWaitIndex(key);
   if(i<0) return;
   int n=ArraySize(g_market_wait);
   for(int j=i;j<n-1;j++) g_market_wait[j]=g_market_wait[j+1];
   ArrayResize(g_market_wait,n-1);
}
// Cierra la espera y su aviso cuando el problema se corrige o desaparece.
void ClearMarketWait(const string problem_key)
{
   MarketWaitRemove(problem_key);
   ClearAlert("PWAIT|"+problem_key);
}
// Equivalente MT4 de TRADE_RETCODE_MARKET_CLOSED, TRADE_DISABLED y PRICE_OFF.
bool TradeErrorIsMarketClosed(const int code)
{
   return code==CM_ERR_MARKET_CLOSED ||
          code==CM_ERR_TRADE_DISABLED ||
          code==CM_ERR_OFF_QUOTES;
}
bool LastTradeWasMarketClosed()
{
   return TradeErrorIsMarketClosed(g_last_trade_error);
}
// Las sesiones se declaran por día del servidor. Un símbolo sin sesiones
// declaradas se da por abierto y se delega en el error del bróker: bloquear
// por una heurística de cotizaciones dejaría sin corregir un instrumento poco
// líquido durante su propia sesión. MT4 no tiene TimeTradeServer, así que la
// referencia es TimeCurrent(), la hora del servidor de la última cotización.
bool SymbolSessionOpen(const string symbol)
{
   MqlDateTime st;
   TimeToStruct(TimeCurrent(),st);

   ENUM_DAY_OF_WEEK day=(ENUM_DAY_OF_WEEK)st.day_of_week;
   int now_seconds=st.hour*3600+st.min*60+st.sec;
   bool declared=false;

   for(uint index=0;;index++)
   {
      datetime from=0,to=0;
      if(!SymbolInfoSessionTrade(symbol,day,index,from,to))
         break;
      declared=true;
      if(now_seconds>=(int)from && now_seconds<=(int)to)
         return true;
   }
   return !declared;
}
void MarketClosedNotice(const Snap &snap,const string problem_key,
                        const string detail,const string symbol)
{
   MarketWaitMark(problem_key);
   AlertOnce("PWAIT|"+problem_key,
      AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
      "\n\nACCIÓN:\nEl mercado de "+symbol+" está cerrado en la cuenta Slave."+
      "\nCopyMonitor reintentará la corrección cuando abra la sesión.");
}

//---------------- trade result helpers ----------------
string TradeErrorText(const int code)
{
   switch(code)
   {
      case 0:                          return "sin error";
      case CM_ERR_NO_RESULT:           return "sin cambios: los valores pedidos ya estaban puestos";
      case CM_ERR_COMMON_ERROR:        return "error común";
      case CM_ERR_INVALID_TRADE_PARAM: return "parámetros de la operación no válidos";
      case CM_ERR_SERVER_BUSY:         return "servidor de trading ocupado";
      case CM_ERR_NO_CONNECTION:       return "sin conexión con el servidor";
      case CM_ERR_TOO_FREQUENT:        return "peticiones demasiado frecuentes";
      case CM_ERR_ACCOUNT_DISABLED:    return "cuenta deshabilitada";
      case CM_ERR_INVALID_ACCOUNT:     return "número de cuenta no válido";
      case CM_ERR_TRADE_TIMEOUT:       return "tiempo de espera de la operación agotado";
      case CM_ERR_INVALID_PRICE:       return "precio no válido";
      case CM_ERR_INVALID_STOPS:       return "stops no válidos para este símbolo";
      case CM_ERR_INVALID_VOLUME:      return "volumen no válido";
      case CM_ERR_MARKET_CLOSED:       return "mercado cerrado";
      case CM_ERR_TRADE_DISABLED:      return "trading deshabilitado";
      case CM_ERR_NOT_ENOUGH_MONEY:    return "margen insuficiente";
      case CM_ERR_PRICE_CHANGED:       return "el precio cambió";
      case CM_ERR_OFF_QUOTES:          return "sin cotizaciones";
      case CM_ERR_BROKER_BUSY:         return "bróker ocupado";
      case CM_ERR_REQUOTE:             return "recotización";
      case CM_ERR_ORDER_LOCKED:        return "orden bloqueada";
      case CM_ERR_LONG_ONLY:           return "el símbolo sólo admite posiciones largas";
      case CM_ERR_TOO_MANY_REQUESTS:   return "demasiadas peticiones";
      case CM_ERR_TRADE_MODIFY_DENIED: return "modificación denegada: la orden está demasiado cerca del mercado";
      case CM_ERR_TRADE_CONTEXT_BUSY:  return "contexto de trading ocupado";
      case CM_ERR_EXPIRATION_DENIED:   return "el bróker no admite caducidad en las órdenes";
      case CM_ERR_TOO_MANY_ORDERS:     return "demasiadas órdenes abiertas";
      case CM_ERR_HEDGE_PROHIBITED:    return "la cobertura está prohibida en esta cuenta";
      case CM_ERR_FIFO_PROHIBITED:     return "la regla FIFO prohíbe la operación";
      case CM_ERR_INVALID_TICKET:      return "ticket no válido";
   }
   return "error "+IntegerToString(code)+" del terminal";
}
string TradeFailureDetails()
{
   return "\nError MT4: "+IntegerToString(g_last_trade_error)+
          "\nDetalle: "+TradeErrorText(g_last_trade_error);
}
// OrderModify devuelve false con ERR_NO_RESULT cuando los valores pedidos ya
// son los que tiene la orden. Eso es el equivalente de TRADE_RETCODE_NO_CHANGES
// de MT5 y cuenta como exito.
bool TradeOk(const bool sent)
{
   if(sent)
   {
      g_last_trade_error=0;
      return true;
   }
   g_last_trade_error=GetLastError();
   return g_last_trade_error==CM_ERR_NO_RESULT;
}

//---------------- open matching ----------------
bool PosCompatible(const Owner &o,const PosRec &m,const PosRec &s)
{
   if(!SymbolEq(o.channel,m.symbol,s.symbol))return false;
   if(m.type!=s.type)return false;
   if(!VolEq(s.symbol,s.vol,m.vol*o.mult))return false;
   if(InpMatchEntryPrice && MathAbs(m.price-s.price)>InpEntryPriceTolerancePoints*PointOf(s.symbol))return false;
   return true;
}
double PosCost(const PosRec &m,const PosRec &s)
{
   return MathAbs(m.price-s.price)/PointOf(s.symbol);
}
// El recorrido por ticket hace reproducible la evaluacion y los avisos, pero
// nunca se usa como identidad: un empate entre candidatas bloquea el enlace.
void SortPosByTicket(PosRec &a[])
{
   int n=ArraySize(a);

   for(int i=1;i<n;i++)
   {
      PosRec key=a[i];
      int j=i-1;

      while(j>=0 && a[j].ticket>key.ticket)
      {
         a[j+1]=a[j];
         j--;
      }
      a[j+1]=key;
   }
}
void MasterPosOrder(const Snap &snap,int &idx[])
{
   int n=ArraySize(snap.pos);
   ArrayResize(idx,n);

   for(int i=0;i<n;i++)
      idx[i]=i;

   for(int i=1;i<n;i++)
   {
      int key=idx[i];
      int j=i-1;

      while(j>=0 && snap.pos[idx[j]].ticket>snap.pos[key].ticket)
      {
         idx[j+1]=idx[j];
         j--;
      }
      idx[j+1]=key;
   }
}
// Dos posiciones del mismo simbolo, tipo, volumen y precio de entrada son
// indistinguibles con los campos que publica el snapshot. Cuando el Master
// cambia el SL o el TP de una de ellas, lo unico que sigue identificando a la
// otra es que sus niveles ya coinciden con los del Master.
bool PosStopsAgree(const PosRec &m,const PosRec &s)
{
   // Sin ninguna comprobacion de niveles activa no hay identidad que leer.
   if(!InpCheckStopLoss && !InpCheckTakeProfit)
      return false;

   double tol=InpSLTPTolerancePoints*PointOf(s.symbol);

   if(InpCheckStopLoss && !StopEq(m.sl,s.sl,tol))
      return false;
   if(InpCheckTakeProfit && !StopEq(m.tp,s.tp,tol))
      return false;

   return true;
}
int PosCandidateCount(const Owner &o,const PosRec &m,const PosRec &sp[],const bool &su[])
{
   int n=0;
   for(int j=0;j<ArraySize(sp);j++)
      if(!su[j] && PosCompatible(o,m,sp[j]))
         n++;
   return n;
}
// Desempate por niveles. Solo interviene cuando la posicion Master admite mas
// de una copia libre: con una sola candidata el precio ya decide y el
// desempate no debe alterar ese resultado.
int MatchPosByStops(const Owner &o,const PosRec &m,const PosRec &sp[],const bool &su[])
{
   if(PosCandidateCount(o,m,sp,su)<2)
      return -1;

   int best=-1;
   double cost=1e100;
   int tied=0;

   for(int j=0;j<ArraySize(sp);j++)
   {
      if(su[j] || !PosCompatible(o,m,sp[j]))
         continue;
      if(!PosStopsAgree(m,sp[j]))
         continue;

      double c=PosCost(m,sp[j]);

      if(c<cost-CM_MATCH_EPS)
      {
         cost=c;
         best=j;
         tied=1;
      }
      else if(best>=0 && c<=cost+CM_MATCH_EPS)
         tied++;
   }
   // Dos candidatas igualmente buenas siguen sin aportar una identidad. No se
   // permite que el orden del array decida cual se modifica.
   return (tied==1 ? best : -1);
}
// Devuelve ademas cuantas copias empatan en el coste minimo. El llamador solo
// puede aceptar el resultado cuando tied==1.
int MatchPosByPrice(const Owner &o,const PosRec &m,const PosRec &sp[],const bool &su[],int &tied)
{
   int best=-1;
   double cost=1e100;
   tied=0;

   for(int j=0;j<ArraySize(sp);j++)
   {
      if(su[j] || !PosCompatible(o,m,sp[j]))
         continue;

      double c=PosCost(m,sp[j]);

      if(c<cost-CM_MATCH_EPS)
      {
         cost=c;
         best=j;
         tied=1;
      }
      else if(best>=0 && c<=cost+CM_MATCH_EPS)
         tied++;
   }
   return best;
}
void MarkPosPriceTies(const Owner &o,const PosRec &m,const PosRec &sp[],
                      const bool &used[],bool &marked[])
{
   double best_cost=1e100;
   for(int j=0;j<ArraySize(sp);j++)
      if(!used[j] && PosCompatible(o,m,sp[j]))
         best_cost=MathMin(best_cost,PosCost(m,sp[j]));

   for(int j=0;j<ArraySize(sp);j++)
      if(!used[j] && PosCompatible(o,m,sp[j]) &&
         PosCost(m,sp[j])<=best_cost+CM_MATCH_EPS)
         marked[j]=true;
}
int CandIndex(const string key)
{
   for(int i=0;i<ArraySize(g_candidates);i++)if(g_candidates[i].key==key)return i;
   return -1;
}
bool ConfirmProblem(const string key,const int seconds)
{
   datetime now=TimeLocal();int i=CandIndex(key);
   if(i<0)
   {
      i=ArraySize(g_candidates);ArrayResize(g_candidates,i+1);
      g_candidates[i].key=key;g_candidates[i].first_seen=now;g_candidates[i].last_seen=now;
      return seconds<=0;
   }
   g_candidates[i].last_seen=now;
   return (now-g_candidates[i].first_seen)>=seconds;
}
void RemoveProblem(const string key)
{
   int i=CandIndex(key);if(i<0)return;int n=ArraySize(g_candidates);
   for(int j=i;j<n-1;j++)g_candidates[j]=g_candidates[j+1];ArrayResize(g_candidates,n-1);
}
// MT4 exige repetir el precio de apertura al modificar una posicion, y la
// caducidad debe ir a cero o el broker rechaza la peticion.
bool FixPositionStops(const long ticket,const double sl,const double tp)
{
   // Un abandono antes de enviar nada no puede dejar en pie el codigo de error
   // de una correccion anterior: la rama de mercado cerrado lo leeria como si
   // fuera de este intento.
   g_last_trade_error=0;

   if(!SelectLivePosition(ticket)) return false;

   string symbol=OrderSymbol();
   double open_price=OrderOpenPrice();

   ResetLastError();
   if(!TradeOk(OrderModify((int)ticket,open_price,NormPrice(symbol,sl),
                           NormPrice(symbol,tp),0,clrNONE)))
      return false;

   if(!SelectLivePosition(ticket)) return false;
   double tol=InpSLTPTolerancePoints*PointOf(symbol);
   return StopEq(OrderStopLoss(),sl,tol) &&
          StopEq(OrderTakeProfit(),tp,tol);
}
void CheckOpen(const Owner &o,const Snap &snap)
{
   PosRec sp[];
   SlavePosForOwner(o,sp);
   SortPosByTicket(sp);

   int order[];
   MasterPosOrder(snap,order);

   bool su[];
   ArrayResize(su,ArraySize(sp));
   ArrayInitialize(su,false);

   bool ambiguous_slave[];
   ArrayResize(ambiguous_slave,ArraySize(sp));
   ArrayInitialize(ambiguous_slave,false);

   int assign[];
   ArrayResize(assign,ArraySize(snap.pos));
   ArrayInitialize(assign,-1);

   bool problems=false;
   string details="";

   // 1) Resolver primero la ambiguedad: cuando varias copias libres encajan
   //    con la misma posicion Master, la suya es la que ya lleva su SL y su
   //    TP. Atarlas antes que nada evita corregir la posicion equivocada
   //    cuando el Master mueve los niveles de una de dos posiciones gemelas.
   for(int k=0;k<ArraySize(order);k++)
   {
      int i=order[k];
      int paired=MatchPosByStops(o,snap.pos[i],sp,su);

      if(paired<0)
         continue;

      assign[i]=paired;
      su[paired]=true;
   }

   // 2) Protect the Slave copy corresponding to every ignored MASTER ticket.
   //    The ignored pair is removed from all later mismatch / SL / TP logic.
   for(int k=0;k<ArraySize(order);k++)
   {
      int i=order[k];

      if(assign[i]>=0 || !MasterTicketIgnored(o.channel,snap.pos[i].ticket))
         continue;

      int ignored_tied=0;
      int paired=MatchPosByPrice(o,snap.pos[i],sp,su,ignored_tied);

      if(ignored_tied>1)
         MarkPosPriceTies(o,snap.pos[i],sp,su,su);
      else if(paired>=0)
      {
         assign[i]=paired;
         su[paired]=true;
      }
   }

   // 3) Monitor only non-ignored MASTER positions.
   for(int k=0;k<ArraySize(order);k++)
   {
      int i=order[k];

      if(MasterTicketIgnored(o.channel,snap.pos[i].ticket))
         continue;

      int best=assign[i];
      int tied=0;

      if(best<0)
         best=MatchPosByPrice(o,snap.pos[i],sp,su,tied);

      if(tied>1)
      {
         problems=true;
         string ambiguity=
            "\n\nPROBLEMA:\nNo se puede enlazar de forma fiable una posición Master con su copia Slave.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Símbolo Master: "+snap.pos[i].symbol+"\n"+
            "Ticket Master: "+TicketText(snap.pos[i].ticket)+"\n"+
            "Copias Slave igualmente compatibles: "+IntegerToString(tied)+
            "\n\nACCIÓN:\nRevisar manualmente. No se enlaza ninguna copia y no se hará ninguna corrección automática.";
         details+=ambiguity;
         MarkPosPriceTies(o,snap.pos[i],sp,su,ambiguous_slave);
         continue;
      }

      if(best<0)
      {
         string slave_symbol=ExpectedSlaveSymbol(o.channel,snap.pos[i].symbol);
         double expected_volume=ExpectedSlaveVolume(slave_symbol,snap.pos[i].vol,o.mult);
         problems=true;
         details+=
            "\n\nPROBLEMA:\nFalta la copia de una posición activa.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Tipo: "+PositionTypeText(snap.pos[i].type)+"\n"+
            "Símbolo Master: "+snap.pos[i].symbol+"\n"+
            "Símbolo esperado Slave: "+slave_symbol+"\n"+
            "Ticket Master: "+TicketText(snap.pos[i].ticket)+"\n\n"+
            "Volumen Master: "+VolumeText(slave_symbol,snap.pos[i].vol)+"\n"+
            "Volumen Slave esperado: "+VolumeText(slave_symbol,expected_volume)+"\n"+
            "Precio de entrada: "+PriceText(snap.pos[i].price)+"\n"+
            "Stop Loss: "+StopText(snap.pos[i].sl,"SIN SL")+"\n"+
            "Take Profit: "+StopText(snap.pos[i].tp,"SIN TP");
         continue;
      }

      su[best]=true;

      double tol=InpSLTPTolerancePoints*PointOf(sp[best].symbol);

      bool sl_bad=InpCheckStopLoss && !StopEq(snap.pos[i].sl,sp[best].sl,tol);
      bool tp_bad=InpCheckTakeProfit && !StopEq(snap.pos[i].tp,sp[best].tp,tol);

      string suffix=o.channel+"|"+TicketText(snap.pos[i].ticket)+
                    "|"+TicketText(sp[best].ticket);
      string alert_key="SLTP|"+suffix;
      string fix_key="FIXSLTP|"+suffix;

      if(sl_bad || tp_bad)
      {
         string problem_detail=
            "\n\nPROBLEMA:\nLa posición copiada tiene valores diferentes.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Tipo: "+PositionTypeText(snap.pos[i].type)+"\n"+
            "Símbolo: "+sp[best].symbol+"\n"+
            "Ticket Master: "+TicketText(snap.pos[i].ticket)+"\n"+
            "Ticket Slave: "+TicketText(sp[best].ticket)+"\n";

         if(sl_bad)
            problem_detail+=
               "\nSL Master: "+StopText(snap.pos[i].sl,"SIN SL")+
               "\nSL Slave: "+StopText(sp[best].sl,"SIN SL");

         if(tp_bad)
            problem_detail+=
               "\nTP Master: "+StopText(snap.pos[i].tp,"SIN TP")+
               "\nTP Slave: "+StopText(sp[best].tp,"SIN TP");

         string alert=AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+problem_detail+
            "\n\nACCIÓN:\nEsperando que el problema persista antes de corregirlo automáticamente.";
         // Mientras se espera a que abra el mercado no se repite el
         // recordatorio: el aviso BLOQUEADO ya dice que no hay nada que hacer.
         if(MarketWaiting(fix_key))
            KeepAlert(alert_key);
         else
            PersistAlert(alert_key,alert);

         if(InpAutoFixPositionSLTP && !g_trade_busy &&
            ConfirmProblem(fix_key,InpAutoFixPersistSeconds) &&
            MarketWaitDue(fix_key))
         {
            double target_sl=InpCheckStopLoss ? snap.pos[i].sl : sp[best].sl;
            double target_tp=InpCheckTakeProfit ? snap.pos[i].tp : sp[best].tp;
            string blocked_reason="";

            if(!g_trade_allowed)
            {
               PersistAlert("PBLOCK|"+fix_key,
                  AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+problem_detail+
                  "\n\nACCIÓN:\nNo se puede corregir automáticamente.\n"+g_trade_block_reason);
            }
            else if(!SymbolSessionOpen(sp[best].symbol))
            {
               MarketClosedNotice(snap,fix_key,problem_detail,sp[best].symbol);
            }
            else if(!PositionStopsAcceptable(sp[best].symbol,sp[best].type,
                                             target_sl,target_tp,blocked_reason))
            {
               PersistAlert("PBLOCK|"+fix_key,
                  AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+problem_detail+
                  "\n\nACCIÓN:\nNo se puede corregir automáticamente.\n"+blocked_reason);
            }
            else if(FixPositionStops(sp[best].ticket,target_sl,target_tp))
            {
               Tg(AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+problem_detail+
                  "\n\nACCIÓN AUTOMÁTICA:\nSL y TP corregidos correctamente en la cuenta Slave.");
               ClearAlert(alert_key);
               ClearAlert("PBLOCK|"+fix_key);
               ClearMarketWait(fix_key);
               RemoveProblem(fix_key);
            }
            // El bróker puede rechazar por sesión cerrada aunque el calendario
            // la declare abierta, por ejemplo en un festivo.
            else if(LastTradeWasMarketClosed())
            {
               MarketClosedNotice(snap,fix_key,problem_detail,sp[best].symbol);
               RemoveProblem(fix_key);
            }
            else
            {
               PersistAlert("FAIL|"+alert_key,
                  AlertHeader(snap,"🔴 COPYMONITOR — CRÍTICO")+problem_detail+
                  "\n\nACCIÓN AUTOMÁTICA:\nNo se pudieron corregir SL y TP."+
                  TradeFailureDetails());
               RemoveProblem(fix_key);
            }
         }
      }
      else
      {
         ClearMarketWait(fix_key);
         ResolveAlert(alert_key,
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nLos valores SL y TP de la posición ya coinciden."+
            "\n\nEstado: POSICIÓN ACTIVA\nTipo: "+PositionTypeText(snap.pos[i].type)+
            "\nSímbolo: "+sp[best].symbol+
            "\nTicket Master: "+TicketText(snap.pos[i].ticket)+
            "\nTicket Slave: "+TicketText(sp[best].ticket));
         ClearAlert("FAIL|"+alert_key);
         ClearAlert("PBLOCK|"+fix_key);
         RemoveProblem(fix_key);
      }
   }

   // Anything still unused is genuinely unmatched after protecting ignored
   // Master-ticket copies.
   for(int j=0;j<ArraySize(sp);j++)
   {
      if(su[j] || ambiguous_slave[j] || o.profile!=PROFILE_PORTFOLIO46)
         continue;

      problems=true;
      details+=
         "\n\nPROBLEMA:\nExiste una posición activa extra en el Slave.\n\n"+
         "Estado: POSICIÓN ACTIVA\n"+
         "Tipo: "+PositionTypeText(sp[j].type)+"\n"+
         "Símbolo: "+sp[j].symbol+"\n"+
         "Ticket Slave: "+TicketText(sp[j].ticket)+"\n"+
         "Volumen Slave: "+VolumeText(sp[j].symbol,sp[j].vol)+"\n"+
         "Precio de entrada: "+PriceText(sp[j].price)+"\n"+
         "Stop Loss: "+StopText(sp[j].sl,"SIN SL")+"\n"+
         "Take Profit: "+StopText(sp[j].tp,"SIN TP");
   }

   string key="OPEN|"+o.channel;

   if(problems)
   {
      string msg=AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+details;
      msg+="\n\nACCIÓN:\nRevisar la cuenta Slave "+
           AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN))+".";
      msg+="\nCopyMonitor no abre ni cierra posiciones automáticamente.";

      PersistAlert(key,msg);
   }
   else
   {
      ClearAlert(key);
   }
}

//---------------- pending extra cleanup ----------------
bool OrdCompatible(const Owner &o,const OrdRec &m,const OrdRec &s)
{
   if(!SymbolEq(o.channel,m.symbol,s.symbol))return false;
   if(m.type!=s.type)return false;
   if(!VolEq(s.symbol,s.vol,m.vol*o.mult))return false;
   return true;
}
void SortOrdByTicket(OrdRec &a[])
{
   int n=ArraySize(a);

   for(int i=1;i<n;i++)
   {
      OrdRec key=a[i];
      int j=i-1;

      while(j>=0 && a[j].ticket>key.ticket)
      {
         a[j+1]=a[j];
         j--;
      }
      a[j+1]=key;
   }
}
void MasterOrdOrder(const Snap &snap,int &idx[])
{
   int n=ArraySize(snap.ord);
   ArrayResize(idx,n);

   for(int i=0;i<n;i++)
      idx[i]=i;

   for(int i=1;i<n;i++)
   {
      int key=idx[i];
      int j=i-1;

      while(j>=0 && snap.ord[idx[j]].ticket>snap.ord[key].ticket)
      {
         idx[j+1]=idx[j];
         j--;
      }
      idx[j+1]=key;
   }
}
// El precio no entra en la compatibilidad de pendientes, asi que dos ordenes
// gemelas solo se distinguen por los valores que el Slave compara. La copia
// que ya coincide en todos ellos es la que esta en orden; la que queda libre
// es la que el Master ha movido.
bool OrdValuesAgree(const OrdRec &m,const OrdRec &s)
{
   double point=PointOf(s.symbol);
   double stop_tol=InpSLTPTolerancePoints*point;
   double price_tol=InpPendingPriceTolerancePoints*point;

   if(!PriceEq(m.price,s.price,price_tol))
      return false;
   if(InpCheckStopLoss && !StopEq(m.sl,s.sl,stop_tol))
      return false;
   if(InpCheckTakeProfit && !StopEq(m.tp,s.tp,stop_tol))
      return false;
   // El precio limite solo se compara cuando el Master lo publica.
   if(IsStopLimitType(m.type) && m.stoplimit>0 &&
      !PriceEq(m.stoplimit,s.stoplimit,price_tol))
      return false;

   return true;
}
int OrdCandidateCount(const Owner &o,const OrdRec &m,const OrdRec &so[],const bool &used[])
{
   int n=0;
   for(int s=0;s<ArraySize(so);s++)
      if(!used[s] && OrdCompatible(o,m,so[s]))
         n++;
   return n;
}
// Desempate por valores. Solo interviene cuando la orden Master admite mas de
// una copia libre: con una sola candidata el precio ya decide.
int MatchOrdByValues(const Owner &o,const OrdRec &m,const OrdRec &so[],const bool &used[])
{
   if(OrdCandidateCount(o,m,so,used)<2)
      return -1;

   int best=-1;
   double best_delta=1e100;
   int tied=0;

   for(int s=0;s<ArraySize(so);s++)
   {
      if(used[s] || !OrdCompatible(o,m,so[s]))
         continue;
      if(!OrdValuesAgree(m,so[s]))
         continue;

      double delta=MathAbs(m.price-so[s].price);

      if(delta<best_delta-CM_MATCH_EPS)
      {
         best_delta=delta;
         best=s;
         tied=1;
      }
      else if(best>=0 && delta<=best_delta+CM_MATCH_EPS)
         tied++;
   }
   return (tied==1 ? best : -1);
}
// Devuelve ademas cuantas copias empatan en la distancia minima. El llamador
// solo puede aceptar el resultado cuando tied==1.
int MatchOrdByPrice(const Owner &o,const OrdRec &m,const OrdRec &so[],const bool &used[],int &tied)
{
   int best=-1;
   double best_delta=1e100;
   tied=0;

   for(int s=0;s<ArraySize(so);s++)
   {
      if(used[s] || !OrdCompatible(o,m,so[s]))
         continue;

      double delta=MathAbs(m.price-so[s].price);

      if(delta<best_delta-CM_MATCH_EPS)
      {
         best_delta=delta;
         best=s;
         tied=1;
      }
      else if(best>=0 && delta<=best_delta+CM_MATCH_EPS)
         tied++;
   }
   return best;
}
void MarkOrdPriceTies(const Owner &o,const OrdRec &m,const OrdRec &so[],
                      const bool &used[],bool &marked[])
{
   double best_delta=1e100;
   for(int s=0;s<ArraySize(so);s++)
      if(!used[s] && OrdCompatible(o,m,so[s]))
         best_delta=MathMin(best_delta,MathAbs(m.price-so[s].price));

   for(int s=0;s<ArraySize(so);s++)
      if(!used[s] && OrdCompatible(o,m,so[s]) &&
         MathAbs(m.price-so[s].price)<=best_delta+CM_MATCH_EPS)
         marked[s]=true;
}
int BlockedIndex(const string key)
{
   for(int i=0;i<ArraySize(g_create_blocked);i++)if(g_create_blocked[i].key==key)return i;
   return -1;
}
// Una orden enviada que el monitor no reconoce como copia propia no se puede
// volver a intentar: cada ventana crearia otra pendiente duplicada.
void BlockCreate(const string key)
{
   int i=BlockedIndex(key);
   if(i<0){i=ArraySize(g_create_blocked);ArrayResize(g_create_blocked,i+1);g_create_blocked[i].key=key;}
   g_create_blocked[i].last_seen=TimeLocal();
}
bool IsCreateBlocked(const string key)
{
   int i=BlockedIndex(key);
   if(i<0)return false;
   g_create_blocked[i].last_seen=TimeLocal();
   return true;
}
void UnblockCreate(const string key)
{
   int i=BlockedIndex(key);if(i<0)return;int n=ArraySize(g_create_blocked);
   for(int j=i;j<n-1;j++)g_create_blocked[j]=g_create_blocked[j+1];ArrayResize(g_create_blocked,n-1);
}
bool StillOwnedPending(const Owner &o,const long tk,OrdRec &x)
{
   if(!SelectLivePending(tk))return false;
   string symbol=OrderSymbol();
   if(!SlaveSymbolAllowed(symbol))return false;
   if(!OwnerCommentMatch(o,OrderComment()))return false;
   x.ticket=tk;x.symbol=symbol;x.type=OrderType();x.vol=OrderLots();
   x.price=OrderOpenPrice();x.sl=OrderStopLoss();x.tp=OrderTakeProfit();
   x.stoplimit=0.0;return true;
}
// MT4 sólo tiene los cuatro tipos pendientes clásicos. Una STOP LIMIT publicada
// por un Master MT5 no se puede reproducir aquí y queda BLOQUEADO.
bool CreatablePendingType(const int type)
{
   return type==CM_TYPE_BUY_LIMIT || type==CM_TYPE_SELL_LIMIT ||
          type==CM_TYPE_BUY_STOP  || type==CM_TYPE_SELL_STOP;
}
// El ticket devuelto por OrderSend, o -1. El magic queda en cero: la propiedad
// de una copia se decide por el comentario, igual que en el Slave MT5.
long SendPendingOrder(const Owner &o,const OrdRec &master,const string symbol,
                      const double volume)
{
   ResetLastError();
   int ticket=OrderSend(symbol,master.type,volume,NormPrice(symbol,master.price),0,
                        NormPrice(symbol,master.sl),NormPrice(symbol,master.tp),
                        o.comment,0,0,clrNONE);

   g_last_trade_error=(ticket>0)?0:GetLastError();
   return (long)ticket;
}
int CreatePendingCopy(const Owner &o,const OrdRec &master,long &created_ticket,string &blocked_reason)
{
   created_ticket=0;
   blocked_reason="";
   string symbol=ExpectedSlaveSymbol(o.channel,master.symbol);

   // Crear algo que esta instancia no volveria a ver como propio produciria una
   // copia nueva en cada ventana de persistencia.
   if(!SlaveSymbolAllowed(symbol))
   {
      blocked_reason="El símbolo esperado está excluido por los filtros de esta instancia.";
      return CM_CREATE_BLOCKED;
   }
   if(!SymbolSelect(symbol,true) || MarketInfo(symbol,MODE_POINT)<=0)
   {
      blocked_reason="El símbolo esperado no está disponible en el terminal Slave.";
      return CM_CREATE_BLOCKED;
   }
   if(!CreatablePendingType(master.type))
   {
      blocked_reason="El tipo de orden pendiente del Master no se crea automáticamente en MT4.";
      return CM_CREATE_BLOCKED;
   }
   if(!SymbolAcceptsNewOrders(symbol,master.type,blocked_reason))
      return CM_CREATE_BLOCKED;

   // El volumen se compara con el clamp del broker, pero crear fuera de rango
   // significaria copiar un tamaño distinto del pedido por el Master.
   double step=VolumeStepOf(symbol);
   double vmin=VolumeMinOf(symbol);
   double vmax=VolumeMaxOf(symbol);
   double volume=ExpectedSlaveVolume(symbol,master.vol,o.mult);

   if(volume<=0 || step<=0)
   {
      blocked_reason="El volumen Slave calculado no es válido para este símbolo.";
      return CM_CREATE_BLOCKED;
   }

   double requested=MathRound((master.vol*o.mult)/step)*step;

   if(vmin>0 && requested<vmin-1e-9)
   {
      blocked_reason=StringFormat("El volumen Slave calculado (%s) queda por debajo del mínimo del símbolo (%s).",
                                  VolumeText(symbol,requested),VolumeText(symbol,vmin));
      return CM_CREATE_BLOCKED;
   }
   if(vmax>0 && requested>vmax+1e-9)
   {
      blocked_reason=StringFormat("El volumen Slave calculado (%s) supera el máximo del símbolo (%s).",
                                  VolumeText(symbol,requested),VolumeText(symbol,vmax));
      return CM_CREATE_BLOCKED;
   }
   if(!PendingPriceAcceptable(symbol,master.type,master.price,master.sl,master.tp,
                              master.stoplimit,blocked_reason))
      return CM_CREATE_BLOCKED;

   created_ticket=SendPendingOrder(o,master,symbol,volume);

   if(created_ticket<=0)
   {
      created_ticket=0;
      return CM_CREATE_FAILED;
   }

   OrdRec live;
   if(!StillOwnedPending(o,created_ticket,live))
      return CM_CREATE_UNVERIFIED;

   // La copia debe quedar ademas emparejable: si no lo es, el proximo ciclo
   // seguiria viendo la pendiente Master sin copia y crearia otra.
   if(!OrdCompatible(o,master,live))
      return CM_CREATE_UNVERIFIED;

   return CM_CREATE_DONE;
}
bool ModifyPendingCopy(const Owner &o,const OrdRec &master,const long slave_ticket,
                       const bool change_price,const bool change_stops)
{
   // Igual que en FixPositionStops: sin enviar nada no hay error de trading
   // que interpretar.
   g_last_trade_error=0;

   OrdRec live;
   if(!StillOwnedPending(o,slave_ticket,live)) return false;

   // La caducidad de la copia se conserva: OrderModify de MT4 reescribe ese
   // campo en cada llamada y pasar cero convertiria en GTC una pendiente que
   // tenia fecha de caducidad.
   datetime expiration=OrderExpiration();
   string symbol=live.symbol;
   double target_price=change_price ? master.price : live.price;
   double target_sl=change_stops ? master.sl : live.sl;
   double target_tp=change_stops ? master.tp : live.tp;

   ResetLastError();
   bool sent=OrderModify((int)slave_ticket,NormPrice(symbol,target_price),
                         NormPrice(symbol,target_sl),NormPrice(symbol,target_tp),
                         expiration,clrNONE);
   if(!TradeOk(sent)) return false;
   if(!SelectLivePending(slave_ticket)) return false;

   double point=PointOf(symbol);
   double tol=InpSLTPTolerancePoints*point;
   return PriceEq(OrderOpenPrice(),target_price,
                  InpPendingPriceTolerancePoints*point) &&
          StopEq(OrderStopLoss(),target_sl,tol) &&
          StopEq(OrderTakeProfit(),target_tp,tol);
}

//---------------- stale alert cleanup ----------------
bool MasterOrderPresent(const Snap &snap,const long ticket)
{
   for(int i=0;i<ArraySize(snap.ord);i++)
      if(snap.ord[i].ticket==ticket)
         return true;
   return false;
}
void ResolveVanished(const string key,const Snap &snap,const string problem_text)
{
   ResolveAlert(key,
      AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
      "\n\nPROBLEMA RESUELTO:\n"+problem_text);
}
// Un aviso sobre un ticket que ya no existe nunca volveria a tocarse: se
// quedaba activo para siempre, sin RESUELTO y sin poder caducar.
void ResolveVanishedAlerts(const Owner &o,const Snap &snap)
{
   for(int i=ArraySize(g_alerts)-1;i>=0;i--)
   {
      if(!g_alerts[i].active)
         continue;

      string key=g_alerts[i].key;
      string f[];
      int n=StringSplit(key,(ushort)'|',f);
      if(n<3)
         continue;

      // SLTP|canal|master|slave y FAIL|SLTP|canal|master|slave
      if(f[0]=="SLTP" && n==4 && f[1]==o.channel)
      {
         long ticket=(long)StringToInteger(f[3]);
         if(ticket>0 && SelectLivePosition(ticket)) continue;
         ResolveVanished(key,snap,"La posición avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[3]);
         ClearAlert("FAIL|"+key);
         ClearAlert("PBLOCK|FIXSLTP|"+f[1]+"|"+f[2]+"|"+f[3]);
         ClearMarketWait("FIXSLTP|"+f[1]+"|"+f[2]+"|"+f[3]);
         RemoveProblem("FIXSLTP|"+f[1]+"|"+f[2]+"|"+f[3]);
         continue;
      }
      if(f[0]=="FAIL" && f[1]=="SLTP" && n==5 && f[2]==o.channel)
      {
         long ticket=(long)StringToInteger(f[4]);
         if(ticket>0 && SelectLivePosition(ticket)) continue;
         ResolveVanished(key,snap,"La posición avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[4]);
         continue;
      }

      // PVALUES|canal|master|slave y FAIL|PVALUES|canal|master|slave
      if(f[0]=="PVALUES" && n==4 && f[1]==o.channel)
      {
         long ticket=(long)StringToInteger(f[3]);
         if(ticket>0 && SelectLivePending(ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[3]);
         ClearAlert("FAIL|"+key);
         ClearAlert("PBLOCK|FIXPEND|"+f[1]+"|"+f[2]+"|"+f[3]);
         ClearMarketWait("FIXPEND|"+f[1]+"|"+f[2]+"|"+f[3]);
         RemoveProblem("FIXPEND|"+f[1]+"|"+f[2]+"|"+f[3]);
         continue;
      }
      if(f[0]=="FAIL" && f[1]=="PVALUES" && n==5 && f[2]==o.channel)
      {
         long ticket=(long)StringToInteger(f[4]);
         if(ticket>0 && SelectLivePending(ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[4]);
         continue;
      }

      // PEXTRA|canal|slave y PAMB|canal|slave
      if((f[0]=="PEXTRA" || f[0]=="PAMB") && n==3 && f[1]==o.channel)
      {
         long ticket=(long)StringToInteger(f[2]);
         if(ticket>0 && SelectLivePending(ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[2]);
         ClearAlert("FAIL|PEXTRA|"+f[1]+"|"+f[2]);
         ClearAlert("PBLOCK|DELETE|"+f[1]+"|"+f[2]);
         ClearMarketWait("DELETE|"+f[1]+"|"+f[2]);
         RemoveProblem("DELETE|"+f[1]+"|"+f[2]);
         continue;
      }
      if(f[0]=="FAIL" && f[1]=="PEXTRA" && n==4 && f[2]==o.channel)
      {
         long ticket=(long)StringToInteger(f[3]);
         if(ticket>0 && SelectLivePending(ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[3]);
         continue;
      }

      // FAIL|CREATE|canal|master y PBLOCK|CREATE|canal|master
      if((f[0]=="FAIL" || f[0]=="PBLOCK") && f[1]=="CREATE" && n==4 && f[2]==o.channel)
      {
         long ticket=(long)StringToInteger(f[3]);
         if(ticket>0 && MasterOrderPresent(snap,ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente del Master que no se pudo copiar ya no existe."+
                                  "\nTicket Master: "+f[3]);
         UnblockCreate("CREATE|"+f[2]+"|"+f[3]);
         ClearMarketWait("CREATE|"+f[2]+"|"+f[3]);
         RemoveProblem("CREATE|"+f[2]+"|"+f[3]);
         continue;
      }
   }
}

void CheckPending(const Owner &o,const Snap &snap)
{
   OrdRec so[];
   SlaveOrdForOwner(o,so);
   SortOrdByTicket(so);

   int order[];
   MasterOrdOrder(snap,order);

   bool slave_protected[];
   ArrayResize(slave_protected,ArraySize(so));
   ArrayInitialize(slave_protected,false);

   bool ambiguous_slave[];
   ArrayResize(ambiguous_slave,ArraySize(so));
   ArrayInitialize(ambiguous_slave,false);

   int assign[];
   ArrayResize(assign,ArraySize(snap.ord));
   ArrayInitialize(assign,-1);

   // Resolver primero la ambiguedad: cuando varias copias libres encajan con
   // la misma orden Master, la suya es la que ya coincide en todos los valores
   // comparados. Atarlas antes que nada evita modificar la orden equivocada
   // cuando el Master mueve una de dos pendientes gemelas.
   for(int k=0;k<ArraySize(order);k++)
   {
      int m=order[k];
      int paired=MatchOrdByValues(o,snap.ord[m],so,slave_protected);

      if(paired<0)
         continue;

      assign[m]=paired;
      slave_protected[paired]=true;
   }

   // First protect any Slave pending that corresponds to an ignored MASTER
   // pending ticket. It must never be reported or auto-deleted because the
   // user deliberately excluded that MASTER ticket from monitoring.
   for(int k=0;k<ArraySize(order);k++)
   {
      int m=order[k];

      if(!MasterTicketIgnored(o.channel,snap.ord[m].ticket))
         continue;

      int best=assign[m];
      int ignored_tied=0;

      if(best<0)
         best=MatchOrdByPrice(o,snap.ord[m],so,slave_protected,ignored_tied);

      if(ignored_tied>1)
         MarkOrdPriceTies(o,snap.ord[m],so,slave_protected,slave_protected);
      else if(best>=0)
      {
         assign[m]=best;
         slave_protected[best]=true;
         RemoveProblem("DELETE|"+o.channel+"|"+TicketText(so[best].ticket));
         ClearMarketWait("DELETE|"+o.channel+"|"+TicketText(so[best].ticket));
         ClearAlert("PEXTRA|"+o.channel+"|"+TicketText(so[best].ticket));
         ClearAlert("FAIL|PEXTRA|"+o.channel+"|"+TicketText(so[best].ticket));
         ResolveAlert("PAMB|"+o.channel+"|"+TicketText(so[best].ticket),
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nLa orden pendiente del Slave corresponde a un ticket Master ignorado."+
            "\nTicket Slave: "+TicketText(so[best].ticket));
      }
   }

   // Pair each monitored Master pending with at most one Slave pending.
   // Count-only comparison is insufficient: a wrong order can hide a missing
   // order, and two Slave orders must not reuse the same Master order.
   bool master_matched[];
   ArrayResize(master_matched,ArraySize(snap.ord));
   ArrayInitialize(master_matched,false);

   for(int k=0;k<ArraySize(order);k++)
   {
      int m=order[k];

      if(MasterTicketIgnored(o.channel,snap.ord[m].ticket))
      {
         master_matched[m]=true;
         continue;
      }

      int best=assign[m];
      int tied=0;

      if(best<0)
         best=MatchOrdByPrice(o,snap.ord[m],so,slave_protected,tied);

      string ambiguity_key="PAMBMASTER|"+o.channel+"|"+TicketText(snap.ord[m].ticket);

      if(tied>1)
      {
         master_matched[m]=true;
         string ambiguity=
            "\n\nPROBLEMA:\nNo se puede enlazar de forma fiable una orden pendiente Master con su copia Slave.\n\n"+
            "Estado: ORDEN PENDIENTE\n"+
            "Símbolo Master: "+snap.ord[m].symbol+"\n"+
            "Ticket Master: "+TicketText(snap.ord[m].ticket)+"\n"+
            "Copias Slave igualmente compatibles: "+IntegerToString(tied)+
            "\n\nACCIÓN:\nRevisar manualmente. No se enlaza ninguna copia y no se hará ninguna modificación automática.";
         PersistAlert(ambiguity_key,AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+ambiguity);
         MarkOrdPriceTies(o,snap.ord[m],so,slave_protected,ambiguous_slave);
         continue;
      }

      ResolveAlert(ambiguity_key,
         AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nLa orden Master ya no presenta un enlace ambiguo."+
         "\nTicket Master: "+TicketText(snap.ord[m].ticket));

      if(best>=0)
      {
         assign[m]=best;
         master_matched[m]=true;
         slave_protected[best]=true;
         string matched_create="CREATE|"+o.channel+"|"+TicketText(snap.ord[m].ticket);
         RemoveProblem(matched_create);
         UnblockCreate(matched_create);
         ClearMarketWait(matched_create);
         ClearAlert("FAIL|"+matched_create);
         ClearAlert("PBLOCK|"+matched_create);
         RemoveProblem("DELETE|"+o.channel+"|"+TicketText(so[best].ticket));
         ClearMarketWait("DELETE|"+o.channel+"|"+TicketText(so[best].ticket));
         ClearAlert("PEXTRA|"+o.channel+"|"+TicketText(so[best].ticket));
         ClearAlert("FAIL|PEXTRA|"+o.channel+"|"+TicketText(so[best].ticket));
         ResolveAlert("PAMB|"+o.channel+"|"+TicketText(so[best].ticket),
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nLa orden pendiente del Slave ya se empareja con una orden Master."+
            "\nTicket Master: "+TicketText(snap.ord[m].ticket)+
            "\nTicket Slave: "+TicketText(so[best].ticket));

         double point=PointOf(so[best].symbol);
         double stop_tol=InpSLTPTolerancePoints*point;
         bool price_bad=!PriceEq(snap.ord[m].price,so[best].price,
                                 InpPendingPriceTolerancePoints*point);
         bool sl_bad=InpCheckStopLoss && !StopEq(snap.ord[m].sl,so[best].sl,stop_tol);
         bool tp_bad=InpCheckTakeProfit && !StopEq(snap.ord[m].tp,so[best].tp,stop_tol);
         // El precio límite sólo se compara cuando el Master lo publica. En un
         // Slave MT4 nunca hay copia STOP LIMIT, así que esto sólo se activa
         // con un Master MT5 y una copia que no puede existir aquí.
         bool limit_bad=IsStopLimitType(snap.ord[m].type) && snap.ord[m].stoplimit>0 &&
                        !PriceEq(snap.ord[m].stoplimit,so[best].stoplimit,
                                 InpPendingPriceTolerancePoints*point);
         string suffix=o.channel+"|"+TicketText(snap.ord[m].ticket)+
                       "|"+TicketText(so[best].ticket);
         string alert_key="PVALUES|"+suffix;
         string fix_key="FIXPEND|"+suffix;

         if(InpMonitorPendingOrders && (price_bad || sl_bad || tp_bad || limit_bad))
         {
            string detail=
               "\n\nPROBLEMA:\nLa orden pendiente copiada tiene valores diferentes.\n\n"+
               "Estado: ORDEN PENDIENTE\n"+
               "Tipo: "+OrderTypeText(snap.ord[m].type)+"\n"+
               "Símbolo: "+so[best].symbol+"\n"+
               "Ticket Master: "+TicketText(snap.ord[m].ticket)+"\n"+
               "Ticket Slave: "+TicketText(so[best].ticket);
            if(price_bad)
               detail+="\n\nEntrada Master: "+PriceText(snap.ord[m].price)+
                       "\nEntrada Slave: "+PriceText(so[best].price);
            if(limit_bad)
               detail+="\nPrecio límite Master: "+StopText(snap.ord[m].stoplimit,"SIN LÍMITE")+
                       "\nPrecio límite Slave: "+StopText(so[best].stoplimit,"SIN LÍMITE");
            if(sl_bad)
               detail+="\nSL Master: "+StopText(snap.ord[m].sl,"SIN SL")+
                       "\nSL Slave: "+StopText(so[best].sl,"SIN SL");
            if(tp_bad)
               detail+="\nTP Master: "+StopText(snap.ord[m].tp,"SIN TP")+
                       "\nTP Slave: "+StopText(so[best].tp,"SIN TP");

            bool change_price=InpAutoModifyPending && (price_bad || limit_bad);
            bool change_stops=InpAutoFixPendingSLTP && (sl_bad || tp_bad);
            string pending_action=(change_price || change_stops)
               ? "\n\nACCIÓN:\nEsperando que el problema persista antes de corregir los valores habilitados automáticamente."
               : "\n\nACCIÓN:\nSe ha avisado, pero la corrección automática de los valores afectados está desactivada.";

            if(MarketWaiting(fix_key))
               KeepAlert(alert_key);
            else
               PersistAlert(alert_key,AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
                                         detail+pending_action);

            if((change_price || change_stops) && !g_trade_busy &&
               ConfirmProblem(fix_key,InpAutoFixPersistSeconds) &&
               MarketWaitDue(fix_key))
            {
               string blocked_reason="";
               double target_price=change_price ? snap.ord[m].price : so[best].price;
               double target_sl=change_stops ? snap.ord[m].sl : so[best].sl;
               double target_tp=change_stops ? snap.ord[m].tp : so[best].tp;
               double target_stoplimit=so[best].stoplimit;
               if(change_price && IsStopLimitType(so[best].type) && snap.ord[m].stoplimit>0)
                  target_stoplimit=snap.ord[m].stoplimit;

               if(!g_trade_allowed)
               {
                  PersistAlert("PBLOCK|"+fix_key,
                     AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
                     "\n\nACCIÓN:\nNo se puede modificar automáticamente.\n"+g_trade_block_reason);
               }
               else if(!SymbolSessionOpen(so[best].symbol))
               {
                  MarketClosedNotice(snap,fix_key,detail,so[best].symbol);
               }
               else if(!PendingNotFrozen(so[best].symbol,so[best].type,so[best].price,
                                         blocked_reason))
               {
                  PersistAlert("PBLOCK|"+fix_key,
                     AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
                     "\n\nACCIÓN:\nNo se puede modificar automáticamente.\n"+blocked_reason);
               }
               else if(!PendingPriceAcceptable(so[best].symbol,so[best].type,target_price,
                                               target_sl,target_tp,
                                               IsStopLimitType(so[best].type) ? target_stoplimit : 0.0,
                                               blocked_reason))
               {
                  PersistAlert("PBLOCK|"+fix_key,
                     AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
                     "\n\nACCIÓN:\nNo se puede modificar automáticamente.\n"+blocked_reason);
               }
               else if(ModifyPendingCopy(o,snap.ord[m],so[best].ticket,
                                         change_price,change_stops))
               {
                  Tg(AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+detail+
                     "\n\nACCIÓN AUTOMÁTICA:\nLos valores habilitados de la orden pendiente se corrigieron correctamente.");
                  ClearAlert(alert_key);
                  ClearAlert("PBLOCK|"+fix_key);
                  ClearMarketWait(fix_key);
                  RemoveProblem(fix_key);
               }
               else if(LastTradeWasMarketClosed())
               {
                  MarketClosedNotice(snap,fix_key,detail,so[best].symbol);
                  RemoveProblem(fix_key);
               }
               else
               {
                  PersistAlert("FAIL|"+alert_key,
                     AlertHeader(snap,"🔴 COPYMONITOR — CRÍTICO")+detail+
                     "\n\nACCIÓN AUTOMÁTICA:\nNo se pudo modificar la orden pendiente."+
                     TradeFailureDetails());
                  RemoveProblem(fix_key);
               }
            }
         }
         else
         {
            ClearMarketWait(fix_key);
            ResolveAlert(alert_key,
               AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
               "\n\nPROBLEMA RESUELTO:\nLa orden pendiente ya tiene el precio, SL y TP correctos."+
               "\n\nEstado: ORDEN PENDIENTE\nTipo: "+OrderTypeText(snap.ord[m].type)+
               "\nSímbolo: "+so[best].symbol+
               "\nTicket Master: "+TicketText(snap.ord[m].ticket)+
               "\nTicket Slave: "+TicketText(so[best].ticket));
            ClearAlert("FAIL|"+alert_key);
            ClearAlert("PBLOCK|"+fix_key);
            RemoveProblem(fix_key);
         }
      }
   }

   // Missing-pending monitoring, when explicitly enabled, reports actual
   // unmatched orders rather than comparing collection sizes.
   if(InpMonitorPendingOrders && InpExpectPendingCopies)
   {
      int missing_pending=0;
      string missing_details="";
      for(int m=0;m<ArraySize(snap.ord);m++)
      {
         if(!master_matched[m])
         {
            missing_pending++;
            missing_details+=
               "\n\nPROBLEMA:\nFalta la copia de una orden pendiente.\n\n"+
               MasterPendingDetails(o,snap.ord[m]);
         }
      }

      if(missing_pending>0)
      {
         string msg=AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+missing_details;
         msg+="\n\nACCIÓN:\nEsperando que el problema persista antes de crear la orden automáticamente.";

         // Si toda copia pendiente está esperando a que abra el mercado, el
         // recordatorio agrupado no aporta nada nuevo.
         bool all_waiting=(missing_pending>0);
         for(int m=0;m<ArraySize(snap.ord) && all_waiting;m++)
            if(!master_matched[m] &&
               !MarketWaiting("CREATE|"+o.channel+"|"+TicketText(snap.ord[m].ticket)))
               all_waiting=false;

         if(all_waiting)
            KeepAlert("PMISS|"+o.channel);
         else
            PersistAlert(
               "PMISS|"+o.channel,
               msg);

         bool created_any=false;
         for(int m=0;m<ArraySize(snap.ord);m++)
         {
            if(master_matched[m]) continue;
            string create_key="CREATE|"+o.channel+"|"+TicketText(snap.ord[m].ticket);
            if(!InpAutoCreateMissingPending || g_trade_busy || IsCreateBlocked(create_key) ||
               !ConfirmProblem(create_key,InpAutoFixPersistSeconds) ||
               !MarketWaitDue(create_key))
               continue;

            long created_ticket=0;
            string blocked_reason="";
            string detail="\n\nPROBLEMA:\nFaltaba la copia de una orden pendiente.\n\n"+
                          MasterPendingDetails(o,snap.ord[m]);

            // Sin permiso de trading no se envia nada: el candidato sigue vivo
            // y se actuara en cuanto el terminal vuelva a permitirlo.
            if(!g_trade_allowed)
            {
               PersistAlert("PBLOCK|"+create_key,
                  AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
                  "\n\nACCIÓN:\nNo se puede crear la copia automáticamente.\n"+g_trade_block_reason);
               continue;
            }

            string create_symbol=ExpectedSlaveSymbol(o.channel,snap.ord[m].symbol);

            if(!SymbolSessionOpen(create_symbol))
            {
               MarketClosedNotice(snap,create_key,detail,create_symbol);
               continue;
            }

            int created=CreatePendingCopy(o,snap.ord[m],created_ticket,blocked_reason);
            RemoveProblem(create_key);

            if(created==CM_CREATE_DONE)
            {
               Tg(AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+detail+
                  "\nTicket Slave creado: "+TicketText(created_ticket)+
                  "\n\nACCIÓN AUTOMÁTICA:\nLa orden pendiente fue creada correctamente.");
               ClearAlert("FAIL|"+create_key);
               ClearAlert("PBLOCK|"+create_key);
               ClearMarketWait(create_key);
               created_any=true;
            }
            else if(created==CM_CREATE_UNVERIFIED)
            {
               // La orden existe pero el monitor no la reconoce como copia
               // propia. Reintentar duplicaria la pendiente en cada ventana.
               // En MT4 la causa habitual es un broker que reescribe el
               // comentario de la orden.
               BlockCreate(create_key);
               PersistAlert("FAIL|"+create_key,
                  AlertHeader(snap,"🔴 COPYMONITOR — CRÍTICO")+detail+
                  "\nTicket Slave creado: "+TicketText(created_ticket)+
                  "\n\nACCIÓN AUTOMÁTICA:\nLa orden se envió pero no se reconoce como"+
                  " copia de este canal.\nRevisarla manualmente: la creación automática de"+
                  " este ticket Master queda bloqueada para no duplicarla."+
                  TradeFailureDetails());
            }
            else if(created==CM_CREATE_BLOCKED)
            {
               PersistAlert("PBLOCK|"+create_key,
                  AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
                  "\n\nACCIÓN:\nNo se puede crear la copia automáticamente.\n"+blocked_reason);
            }
            // El bróker puede rechazar por sesión cerrada aunque el calendario
            // la declare abierta, por ejemplo en un festivo.
            else if(LastTradeWasMarketClosed())
            {
               MarketClosedNotice(snap,create_key,detail,create_symbol);
            }
            else
            {
               PersistAlert("FAIL|"+create_key,
                  AlertHeader(snap,"🔴 COPYMONITOR — CRÍTICO")+detail+
                  "\n\nACCIÓN AUTOMÁTICA:\nNo se pudo crear la orden pendiente."+
                  TradeFailureDetails());
            }
         }

         // El aviso agrupado ya se resolvio con el mensaje de cada creacion.
         if(created_any)
            ClearAlert("PMISS|"+o.channel);
      }
      else
      {
         ResolveAlert("PMISS|"+o.channel,
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nLas órdenes pendientes esperadas ya aparecen en la cuenta Slave.");
      }
   }
   else
   {
      ClearAlert("PMISS|"+o.channel);
   }

   // Extra Slave pending cleanup.
   for(int s=0;s<ArraySize(so);s++)
   {
      if(slave_protected[s] || ambiguous_slave[s])
         continue;

      // Conservative deletion rule:
      // if ANY Master pending exists (including ignored tickets), deletion
      // is blocked because the unmatched Slave pending could belong to one
      // of those Master orders if symbol/price mapping is imperfect.
      bool safe_orphan=(ArraySize(snap.ord)==0);

      if(!safe_orphan)
      {
         string msg=AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+
            "\n\nPROBLEMA:\nExiste una orden pendiente en el Slave que no se puede emparejar.\n\n"+
            SlavePendingDetails(so[s])+
            "\n\nACCIÓN:\nRevisar las órdenes pendientes de ambas cuentas."+
            "\nEl borrado automático está bloqueado mientras el Master tenga pendientes.";

         PersistAlert("PAMB|"+o.channel+"|"+TicketText(so[s].ticket),msg);

         continue;
      }

      ResolveAlert(
         "PAMB|"+o.channel+"|"+TicketText(so[s].ticket),
         AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nLa orden pendiente del Slave ya se puede evaluar: el Master no tiene pendientes."+
         "\nTicket Slave: "+TicketText(so[s].ticket));

      string delete_problem="DELETE|"+o.channel+"|"+TicketText(so[s].ticket);
      string key="PEXTRA|"+o.channel+"|"+TicketText(so[s].ticket);
      string detail=
         "\n\nPROBLEMA:\nSe encontró una orden pendiente extra en el Slave.\n\n"+
         SlavePendingDetails(so[s]);
      string alert=AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+detail+
         "\n\nACCIÓN:\nEsperando que el problema persista antes de eliminarla automáticamente.";
      if(MarketWaiting(delete_problem))
         KeepAlert(key);
      else
         PersistAlert(key,alert);

      if(!InpAutoDeleteExtraPending)
         continue;

      if(g_trade_busy)
         continue;

      if(!ConfirmProblem(delete_problem,InpExtraPendingConfirmSeconds))
         continue;

      if(!MarketWaitDue(delete_problem))
         continue;

      if(!g_trade_allowed)
      {
         PersistAlert("PBLOCK|"+delete_problem,
            AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
            "\n\nACCIÓN:\nNo se puede eliminar automáticamente.\n"+g_trade_block_reason);
         continue;
      }

      if(!SymbolSessionOpen(so[s].symbol))
      {
         MarketClosedNotice(snap,delete_problem,detail,so[s].symbol);
         continue;
      }

      string frozen_reason="";
      if(!PendingNotFrozen(so[s].symbol,so[s].type,so[s].price,frozen_reason))
      {
         PersistAlert("PBLOCK|"+delete_problem,
            AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
            "\n\nACCIÓN:\nNo se puede eliminar automáticamente.\n"+frozen_reason);
         continue;
      }

      // Final safety re-check.
      OrdRec live;

      if(!StillOwnedPending(o,so[s].ticket,live))
         continue;

      ResetLastError();
      bool ok=TradeOk(OrderDelete((int)so[s].ticket,clrNONE));

      detail=
         "\n\nPROBLEMA:\nSe encontró una orden pendiente extra en el Slave.\n\n"+
         SlavePendingDetails(live);

      if(ok)
      {
         string msg=AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+detail+
            "\n\nACCIÓN:\nLa orden pendiente fue eliminada correctamente.";

         Tg(msg);

         RemoveProblem(delete_problem);
         ClearAlert(key);
         ClearAlert("PBLOCK|"+delete_problem);
         ClearMarketWait(delete_problem);
      }
      else if(LastTradeWasMarketClosed())
      {
         MarketClosedNotice(snap,delete_problem,detail,live.symbol);
         RemoveProblem(delete_problem);
      }
      else
      {
         string msg=AlertHeader(snap,"🔴 COPYMONITOR — CRÍTICO")+detail+
            "\n\nACCIÓN:\nNo se pudo eliminar la orden pendiente."+
            "\nRevisar manualmente la cuenta Slave "+
            AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN))+"."+
            TradeFailureDetails();

         PersistAlert("FAIL|"+key,msg);
         RemoveProblem(delete_problem);
      }
   }
}

//---------------- panel/cycle ----------------
void ProcessOwner(const Owner &o,const Snap &s)
{
   // Un esquema desconocido o un canal cruzado significan que el contrato con
   // el Master esta roto: eso se avisa siempre, no depende del interruptor de
   // avisos de snapshot, porque si no el monitor quedaria mudo para siempre.
   if(s.status==CM_SNAP_SCHEMA || s.status==CM_SNAP_CHANNEL)
   {
      string cause=(s.status==CM_SNAP_SCHEMA)
         ? "El snapshot del Master usa un esquema que este Slave no entiende."
         : "El snapshot encontrado pertenece a otro canal Master.";

      PersistAlert("SCHEMA|"+o.channel,
         AlertHeader(s,"🔴 COPYMONITOR — CRÍTICO")+
         "\n\nPROBLEMA:\n"+cause+
         "\n\nACCIÓN:\nActualizar el EA Master y el EA Slave a la misma versión."+
         "\nLa comparación y toda corrección automática están suspendidas.");
      return;
   }
   ClearAlert("SCHEMA|"+o.channel);

   if(!s.valid || !s.fresh)
   {
      if(InpNotifySnapshotProblems)
      {
         string msg=AlertHeader(s,"🔴 COPYMONITOR — CRÍTICO")+
            "\n\nPROBLEMA:\nNo se reciben datos válidos y recientes de la cuenta Master."+
            "\n\nACCIÓN:\nComprobar el EA Master."+
            "\nLa comparación y el borrado de pendientes están suspendidos.";
         PersistAlert("STALE|"+o.channel,msg);
      }
      return;
   }
   ClearAlert("STALE|"+o.channel);

   // La falta de permiso de trading no se avisa por si sola: queda en el panel
   // y se informa como BLOQUEADO sobre el problema concreto que no se pudo
   // corregir. Avisar sin discrepancias convertiria un monitor en modo solo
   // lectura en una fuente de ruido permanente.
   CheckOpen(o,s);
   CheckPending(o,s);
   ResolveVanishedAlerts(o,s);
}
string SnapshotStateText(const Snap &s)
{
   if(s.status==CM_SNAP_SCHEMA) return "ESQUEMA INCOMPATIBLE";
   if(s.status==CM_SNAP_CHANNEL) return "CANAL CRUZADO";
   if(!s.valid) return "NO DATA";
   if(!s.fresh) return "STALE";
   return "ONLINE";
}
void Panel(const Owner &o[],const Snap &s[])
{
   if(!InpShowPanel){Comment("");return;}
   string p="COPYMONITOR SLAVE MT4 v1.00 MULTI\n";
   p+="MultiMaster: "+(InpMultiMaster?"ON":"OFF")+"\nSlave: "+InpAccountNick+"\n";
   p+="Portafolio: "+InpPortfolioAlias+"\n";
   p+="Broker Slave: "+BrokerText(AccountInfoString(ACCOUNT_COMPANY))+"\n\n";
   for(int i=0;i<ArraySize(o);i++)
   {
      PosRec sp[];SlavePosForOwner(o[i],sp);
      OrdRec sord[];SlaveOrdForOwner(o[i],sord);
      p+=o[i].channel+" | "+ProfileText(o[i].profile);
      if(InpMultiMaster)p+=" | "+o[i].comment;
      p+=" | "+SnapshotStateText(s[i])+"\n";
      p+="  Broker Master: "+BrokerText(s[i].broker)+"\n";
      p+="  Snapshot schema: "+(s[i].schema>0 ? IntegerToString(s[i].schema) : "-")+"\n";
      p+="  Open M/S: "+IntegerToString(s[i].open_total)+"/"+IntegerToString(ArraySize(sp))+"\n";
      p+="  Pending M/S: "+IntegerToString(s[i].pending_total)+"/"+IntegerToString(ArraySize(sord))+"\n";
   }
   p+="\nIgnored MASTER tickets: "+(InpIgnoreMasterTickets=="" ? "NONE" : InpIgnoreMasterTickets)+"\n";
   p+="Slave include symbols: "+(ArraySize(g_include_symbols)==0 ? "ALL" : InpSlaveSymbolsFilter)+"\n";
   p+="Slave ignore symbols: "+(ArraySize(g_exclude_symbols)==0 ? "NONE" : InpSlaveSymbolsIgnore)+"\n";
   p+="Open positions: monitor only (SL/TP included)\n";
   p+="Pending copies expected: "+(InpExpectPendingCopies?"YES":"NO")+"\n";
   p+="Extra pending auto-delete: "+(InpAutoDeleteExtraPending?"YES":"NO")+"\n";
   if(!g_trade_allowed)
      p+="Auto corrections: BLOCKED: "+g_trade_block_reason+"\n";
   else if(g_trade_busy)
      p+="Auto corrections: WAITING: contexto de trading ocupado\n";
   else
      p+="Auto corrections: READY\n";
   if(ArraySize(g_market_wait)>0)
      p+="Esperando apertura de mercado: "+IntegerToString(ArraySize(g_market_wait))+"\n";
   if(!TgConfigured())
      p+="Telegram: OFF";
   else
   {
      p+="Telegram: ON";
      if(ArraySize(g_tg_queue)>0)
         p+=" | en cola: "+IntegerToString(ArraySize(g_tg_queue));
      if(g_tg_dropped>0)
         p+=" | descartados: "+IntegerToString(g_tg_dropped);
      if(!TgSendDue())
         p+=" | esperando "+IntegerToString(TgPendingSeconds())+" s";
      if(g_tg_last_error!="")
         p+=" | "+g_tg_last_error;
   }
   Comment(p);
}
// Descarta claves de tickets que ya nadie evalua. Un aviso activo y un problema
// en cuenta atras se tocan en cada ciclo, asi que nunca se pierden.
void PruneState()
{
   datetime now=TimeLocal();

   for(int i=ArraySize(g_candidates)-1;i>=0;i--)
      if((now-g_candidates[i].last_seen)>InpStateTTLSeconds)
         RemoveProblem(g_candidates[i].key);

   for(int i=ArraySize(g_create_blocked)-1;i>=0;i--)
      if((now-g_create_blocked[i].last_seen)>InpStateTTLSeconds)
         UnblockCreate(g_create_blocked[i].key);

   for(int i=ArraySize(g_market_wait)-1;i>=0;i--)
      if((now-g_market_wait[i].last_try)>InpStateTTLSeconds)
         MarketWaitRemove(g_market_wait[i].key);

   for(int i=ArraySize(g_alerts)-1;i>=0;i--)
   {
      if(g_alerts[i].active || (now-g_alerts[i].last)<=InpStateTTLSeconds)
         continue;
      int n=ArraySize(g_alerts);
      for(int j=i;j<n-1;j++)g_alerts[j]=g_alerts[j+1];
      ArrayResize(g_alerts,n-1);
   }
}
// MT4 no tiene OnTradeTransaction. Esta firma resume el estado de la cuenta
// Slave para que OnTick detecte un cambio real sin repetir el ciclo completo
// en cada cotizacion.
string SlaveStateSignature()
{
   string sig=IntegerToString(OrdersTotal());
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES))
         continue;
      sig+="|"+IntegerToString(OrderTicket())+","+
           IntegerToString(OrderType())+","+
           DoubleToString(OrderLots(),4)+","+
           DoubleToString(OrderOpenPrice(),8)+","+
           DoubleToString(OrderStopLoss(),8)+","+
           DoubleToString(OrderTakeProfit(),8);
   }
   return sig;
}
void Cycle()
{
   if(g_busy)return;
   g_busy=true;

   g_trade_allowed=TradingPermitted(g_trade_block_reason);
   // El contexto de trading es unico en MT4: si otro EA lo tiene ocupado no hay
   // nada que avisar, solo que esperar al ciclo siguiente.
   g_trade_busy=IsTradeContextBusy();

   Snap s[];ArrayResize(s,ArraySize(g_owners));
   for(int i=0;i<ArraySize(g_owners);i++)
   {
      ReadSnap(g_owners[i].channel,s[i]);
      ProcessOwner(g_owners[i],s[i]);
   }
   PruneState();
   Panel(g_owners,s);
   // Lo que no pudo salir en este ciclo se reintenta sin bloquear el aviso.
   TgFlush();
   SaveAlertState();

   // Despues de las correcciones, para que lo que acaba de hacer este EA no
   // dispare otro ciclo inmediato desde OnTick.
   g_last_state=SlaveStateSignature();

   g_busy=false;
}
bool Validate()
{
   if(Trim(InpSlaveID)=="")
   {
      Print("[CM SLAVE] InpSlaveID no puede estar vacio.");
      return false;
   }
   if(Trim(InpPortfolioAlias)=="")
   {
      Print("[CM SLAVE] InpPortfolioAlias es obligatorio: encabeza cada aviso de Telegram.");
      return false;
   }
   if(InpMonitorSeconds<1)
   {
      Print("[CM SLAVE] InpMonitorSeconds debe ser 1 o mayor.");
      return false;
   }
   if(InpSnapshotStaleSeconds<InpMonitorSeconds)
   {
      Print("[CM SLAVE] InpSnapshotStaleSeconds no puede ser menor que InpMonitorSeconds.");
      return false;
   }
   if(InpMismatchReminderSeconds<1 || InpTelegramTimeoutMs<1)
   {
      Print("[CM SLAVE] InpMismatchReminderSeconds e InpTelegramTimeoutMs deben ser mayores que cero.");
      return false;
   }
   if(InpEntryPriceTolerancePoints<0 || InpSLTPTolerancePoints<0 ||
      InpVolumeToleranceSteps<0 || InpPendingPriceTolerancePoints<0 ||
      InpExtraPendingConfirmSeconds<0 || InpAutoFixPersistSeconds<0)
   {
      Print("[CM SLAVE] Las tolerancias y los tiempos de confirmacion no pueden ser negativos.");
      return false;
   }
   // Telegram activado sin credenciales dejaria al usuario sin ningun aviso y
   // sin saberlo: es una configuracion incompleta, no un modo de trabajo.
   if(InpEnableTelegram && (Trim(InpTelegramBotToken)=="" || Trim(InpTelegramChatID)==""))
   {
      Print("[CM SLAVE] Telegram activado sin token o sin chat ID: "
            "complete ambos o desactive InpEnableTelegram.");
      return false;
   }
   if(InpStateTTLSeconds<60)
   {
      Print("[CM SLAVE] InpStateTTLSeconds debe ser 60 o mayor.");
      return false;
   }
   if(InpSnapshotReadAttempts<1 || InpSnapshotReadAttempts>10)
   {
      Print("[CM SLAVE] InpSnapshotReadAttempts debe estar entre 1 y 10.");
      return false;
   }
   if(InpSnapshotReadRetryMs<0 || InpSnapshotReadRetryMs>200)
   {
      Print("[CM SLAVE] InpSnapshotReadRetryMs debe estar entre 0 y 200.");
      return false;
   }
   // La pausa entre lecturas bloquea el hilo del EA, asi que el presupuesto
   // total de reintentos por canal se mantiene por debajo de medio segundo.
   if((InpSnapshotReadAttempts-1)*InpSnapshotReadRetryMs>500)
   {
      Print("[CM SLAVE] Los reintentos de lectura no pueden sumar mas de 500 ms por canal.");
      return false;
   }
   if(InpMarketClosedRetrySeconds<5)
   {
      Print("[CM SLAVE] InpMarketClosedRetrySeconds debe ser 5 o mayor.");
      return false;
   }
   // Telegram rechaza mensajes de mas de 4096 caracteres.
   if(InpTelegramChunkChars<200 || InpTelegramChunkChars>4000)
   {
      Print("[CM SLAVE] InpTelegramChunkChars debe estar entre 200 y 4000.");
      return false;
   }
   if(InpTelegramQueueMax<1 || InpTelegramQueueMax>500)
   {
      Print("[CM SLAVE] InpTelegramQueueMax debe estar entre 1 y 500.");
      return false;
   }
   if(InpTelegramSendsPerCycle<1 || InpTelegramSendsPerCycle>10)
   {
      Print("[CM SLAVE] InpTelegramSendsPerCycle debe estar entre 1 y 10.");
      return false;
   }
   // Cada envio bloquea hasta InpTelegramTimeoutMs. Con el backoff tras fallo,
   // un ciclo largo deja de repetirse cada segundo.
   if(InpTelegramSendsPerCycle*InpTelegramTimeoutMs>15000)
   {
      Print("[CM SLAVE] InpTelegramSendsPerCycle por InpTelegramTimeoutMs no puede pasar de 15000 ms.");
      return false;
   }
   if(InpTelegramRetryBaseSeconds<1 || InpTelegramRetryBaseSeconds>3600)
   {
      Print("[CM SLAVE] InpTelegramRetryBaseSeconds debe estar entre 1 y 3600.");
      return false;
   }
   if(InpTelegramRetryMaxSeconds<InpTelegramRetryBaseSeconds || InpTelegramRetryMaxSeconds>86400)
   {
      Print("[CM SLAVE] InpTelegramRetryMaxSeconds debe estar entre InpTelegramRetryBaseSeconds y 86400.");
      return false;
   }
   return BuildConfig();
}
int OnInit()
{
   if(!Validate())return INIT_PARAMETERS_INCORRECT;
   // Antes del primer ciclo: si un problema seguia avisado al apagar, hay que
   // reconocerlo para poder darlo por resuelto en vez de avisarlo de nuevo.
   LoadAlertState();
   Cycle();
   if(!EventSetTimer(InpMonitorSeconds))
   {
      PrintFormat("[CM SLAVE] EventSetTimer fallo. err=%d",GetLastError());
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   // Un apagado limpio guarda siempre, aunque el conjunto activo no haya
   // cambiado en este ciclo: las marcas de tiempo si lo han hecho.
   g_alerts_dirty=true;
   SaveAlertState();
   Comment("");
}
void OnTimer(){Cycle();}
// Sustituto de OnTradeTransaction: un cambio real en la cuenta Slave se evalua
// al instante, y una cotizacion que no cambia nada no cuesta mas que una
// pasada por la lista de operaciones.
void OnTick()
{
   if(SlaveStateSignature()==g_last_state)
      return;
   Cycle();
}
//+------------------------------------------------------------------+
