//+------------------------------------------------------------------+
//| CopyMonitor_Slave_MT5_v1_17_MULTI.mq5                            |
//| Preserves GENERIC / PORTFOLIO46 / LUNA profiles.                 |
//| Optional MultiMaster layer by exact Slave comment ownership.      |
//| Open positions: monitor quantity + SL/TP, never auto-close.       |
//| Pending orders: normally ignored as copy expectations; optional   |
//| confirmed EXTRA pending in Slave can be deleted.                  |
//+------------------------------------------------------------------+
#property strict
#property version "1.17"
#property description "CopyMonitor Slave MT5 v1.17 MULTI"
#include <Trade/Trade.mqh>
CTrade g_trade;

enum ENUM_COPY_PROFILE
{
   PROFILE_GENERIC=0,
   PROFILE_PORTFOLIO46=1,
   PROFILE_LUNA=2
};

input group "===== MODE / PROFILE ====="
input ENUM_COPY_PROFILE InpProfile                    = PROFILE_GENERIC;
input bool              InpMultiMaster                = false;
input string            InpAccountNick                = "SLAVE";
// Obligatorio: alias del portafolio que encabeza cada aviso de Telegram.
input string            InpPortfolioAlias             = "";
input string            InpSlaveID                    = "SLAVE_A";
input int               InpMonitorSeconds             = 1;
input bool              InpShowPanel                  = true;

input group "===== SINGLE MASTER (MultiMaster=false) ====="
input string InpMasterChannel                         = "MASTER_A";
input string InpSingleSlaveComment                    = ""; // empty = no Slave comment filter
input double InpLotMultiplier                         = 1.0;

input group "===== MULTI MASTER (MultiMaster=true) ====="
// Positional lists. Example:
// MASTER_280;MASTER_687
// adrian_p_280;adrian_p
// PORTFOLIO46;GENERIC
// 0.60;1.00
input string InpMasterChannels                        = "MASTER_280;MASTER_687";
input string InpOwnerComments                         = "adrian_p_280;adrian_p";
input string InpMasterProfiles                        = "PORTFOLIO46;GENERIC";
input string InpVolumeMultipliers                     = "1.0;1.0";

input group "===== INSTANCE SCOPE / IGNORE ====="
// MASTER tickets to ignore. Examples:
// 123456;123457
// MASTER_280:123456;MASTER_687:998877
input string InpIgnoreMasterTickets                   = "";
// These filters apply to symbols in THIS Slave terminal.
// Empty include = all. Ignore always wins.
// Accepts comma or semicolon separated symbols.
input string InpSlaveSymbolsFilter                    = "";
input string InpSlaveSymbolsIgnore                    = "";

input group "===== SYMBOL EQUIVALENCE ====="
// CHANNEL,MASTER_SYMBOL,SLAVE_SYMBOL;...
// Example: MASTER_280,DE40,GER40;MASTER_687,US500,US500.cash
input string InpSymbolMaps                            = "";

input group "===== OPEN POSITION MATCH ====="
input bool InpMatchEntryPrice                         = true;
input int  InpEntryPriceTolerancePoints               = 100;
input bool InpCheckStopLoss                           = true;
input bool InpCheckTakeProfit                         = true;
input int  InpSLTPTolerancePoints                     = 10;
input int  InpVolumeToleranceSteps                    = 1;

input group "===== PENDING BEHAVIOR ====="
// For this Prop setup, copied pendings are NOT expected.
input bool InpMonitorPendingOrders                    = true;
input bool InpExpectPendingCopies                     = true;
input bool InpAutoFixPositionSLTP                     = true;
input bool InpAutoCreateMissingPending                = true;
input bool InpAutoModifyPending                       = true;
input int  InpAutoFixPersistSeconds                   = 5;
// But an owned pending that is confirmed EXTRA may be deleted.
input bool InpAutoDeleteExtraPending                  = true;
input int  InpExtraPendingConfirmSeconds              = 2;
input int  InpPendingPriceTolerancePoints             = 100;

input group "===== LUNA LEGACY SETTINGS ====="
input bool   InpLunaRequireComment                    = false;
input string InpLunaCommentContains                   = "LUNA";

input group "===== SNAPSHOT / TELEGRAM ====="
input int    InpSnapshotStaleSeconds                  = 5;
input bool   InpEnableTelegram                        = true;
input string InpTelegramBotToken                      = "";
input string InpTelegramChatID                        = "";
input int    InpTelegramTimeoutMs                     = 1200;
input int    InpMismatchReminderSeconds               = 15;
input bool   InpNotifySnapshotProblems                = false;
// ALERTA, RESUELTO y CRITICO de las correcciones automaticas son obligatorios:
// el usuario debe saber siempre que cambio el EA en la cuenta Slave.
// InpNotifySnapshotProblems solo gobierna la falta transitoria de datos. Un
// snapshot con el contrato roto se avisa siempre.

input group "===== DIAGNOSTIC ====="
input bool   InpVerboseLog                            = false;

struct PosRec { ulong ticket; string symbol; int type; double vol; double price; double sl; double tp; };
struct OrdRec { ulong ticket; string symbol; int type; double vol; double price; double sl; double tp; double stoplimit; };
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
struct IgnoreRec { string channel; ulong ticket; bool scoped; };
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

// Las claves de estado llevan ticket, asi que una sesion larga acumularia
// entradas muertas. Se descarta lo que nadie vuelve a tocar en este tiempo.
#define CM_STATE_TTL_SECONDS 3600
// Una lectura puede coincidir con la reescritura del Master. El contenido roto
// se detecta siempre, asi que basta con reintentar dentro del mismo ciclo.
#define CM_READ_ATTEMPTS     3
#define CM_READ_RETRY_MS     15
// Telegram rechaza mensajes de mas de 4096 caracteres: un aviso agrupado largo
// se perderia entero. Se trocea con margen y lo que falla espera en cola.
#define CM_TG_CHUNK_CHARS      3000
#define CM_TG_QUEUE_MAX        40
#define CM_TG_FLUSH_PER_CYCLE  2
#define CM_CHANNEL_MAX_LEN     32

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
string g_tg_queue[];
string g_tg_last_error="";
int    g_tg_dropped=0;

// Permiso de trading evaluado al principio de cada ciclo. Sin el, una
// correccion fallaria con CRITICO en cada ventana en lugar de avisar una vez.
bool   g_trade_allowed=false;
string g_trade_block_reason="";

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
   return StringFormat("%I64d",account);
}
string BrokerText(const string broker)
{
   string value=Trim(broker);
   if(value=="") return "NO DISPONIBLE";
   return value;
}
string AlertHeader(const Snap &snap,const string level)
{
   return level+"\n\n"+
          "PORTAFOLIO ALIAS: "+InpPortfolioAlias+"\n"+
          "ID MASTER: "+AccountText(snap.account)+"\n"+
          "BROKER MASTER: "+BrokerText(snap.broker)+"\n"+
          "ID SLAVE: "+AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN))+"\n"+
          "BROKER SLAVE: "+BrokerText(AccountInfoString(ACCOUNT_COMPANY));
}
string PositionTypeText(const int type)
{
   if(type==POSITION_TYPE_BUY) return "BUY";
   if(type==POSITION_TYPE_SELL) return "SELL";
   return "DESCONOCIDO";
}
string OrderTypeText(const int type)
{
   if(type==ORDER_TYPE_BUY_LIMIT) return "BUY LIMIT";
   if(type==ORDER_TYPE_SELL_LIMIT) return "SELL LIMIT";
   if(type==ORDER_TYPE_BUY_STOP) return "BUY STOP";
   if(type==ORDER_TYPE_SELL_STOP) return "SELL STOP";
   if(type==ORDER_TYPE_BUY_STOP_LIMIT) return "BUY STOP LIMIT";
   if(type==ORDER_TYPE_SELL_STOP_LIMIT) return "SELL STOP LIMIT";
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
bool IsPending(const ENUM_ORDER_TYPE t)
{
   return t==ORDER_TYPE_BUY_LIMIT || t==ORDER_TYPE_SELL_LIMIT ||
          t==ORDER_TYPE_BUY_STOP || t==ORDER_TYPE_SELL_STOP ||
          t==ORDER_TYPE_BUY_STOP_LIMIT || t==ORDER_TYPE_SELL_STOP_LIMIT;
}
bool IsStopLimitType(const int t)
{
   return t==ORDER_TYPE_BUY_STOP_LIMIT || t==ORDER_TYPE_SELL_STOP_LIMIT;
}
bool IsBuyPendingType(const int t)
{
   return t==ORDER_TYPE_BUY_LIMIT || t==ORDER_TYPE_BUY_STOP ||
          t==ORDER_TYPE_BUY_STOP_LIMIT;
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

      ArrayResize(o,1); o[0]=x;
      return true;
   }

   string ch[],co[],pr[],mu[];
   SplitClean(InpMasterChannels,';',ch);
   SplitClean(InpOwnerComments,';',co);
   SplitClean(InpMasterProfiles,';',pr);
   SplitClean(InpVolumeMultipliers,';',mu);

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
   SplitClean(InpSymbolMaps,';',entries);

   for(int i=0;i<ArraySize(entries);i++)
   {
      string f[];
      int n=StringSplit(entries[i],',',f);

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
   SplitClean(list,';',tokens);

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
      rec.ticket=(ulong)StringToInteger(digits);
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
   SplitClean(raw,',',out);
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

bool MasterTicketIgnored(const string channel,const ulong ticket)
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
   return InpEnableTelegram && InpTelegramBotToken!="" && InpTelegramChatID!="";
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
   if(http==200)
   {
      g_tg_last_error="";
      return true;
   }

   g_tg_last_error=StringFormat("HTTP=%d err=%d",http,GetLastError());
   PrintFormat("[CM SLAVE] Telegram fail %s",g_tg_last_error);
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
   int n=StringSplit(msg,'\n',lines);
   string current="";

   for(int i=0;i<n;i++)
   {
      string candidate=(current=="") ? lines[i] : current+"\n"+lines[i];

      if(StringLen(candidate)<=CM_TG_CHUNK_CHARS)
      {
         current=candidate;
         continue;
      }

      TgAddChunk(chunks,current);
      current=lines[i];

      while(StringLen(current)>CM_TG_CHUNK_CHARS)
      {
         TgAddChunk(chunks,StringSubstr(current,0,CM_TG_CHUNK_CHARS));
         current=StringSubstr(current,CM_TG_CHUNK_CHARS);
      }
   }

   TgAddChunk(chunks,current);

   if(ArraySize(chunks)==0)
      TgAddChunk(chunks,msg);
}
void TgEnqueue(const string chunk)
{
   int n=ArraySize(g_tg_queue);

   if(n>=CM_TG_QUEUE_MAX)
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

   bool queued=(ArraySize(g_tg_queue)>0);

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

   for(int sent=0;sent<CM_TG_FLUSH_PER_CYCLE && ArraySize(g_tg_queue)>0;sent++)
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
   g_alerts[i].active=true;
   if(due)
   {
      // Throttle attempts as well as successful deliveries. Otherwise a
      // Telegram outage causes one WebRequest per monitor cycle.
      g_alerts[i].last=now;
      Tg(msg);
   }
}
void ClearAlert(const string k){ int i=AlertIndex(k); if(i>=0) g_alerts[i].active=false; }
void ResolveAlert(const string k,const string msg)
{
   int i=AlertIndex(k);
   if(i>=0 && g_alerts[i].active) Tg(msg);
   if(i>=0) g_alerts[i].active=false;
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
      string p[]; int n=StringSplit(line,'|',p); if(n<=0)continue;
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
         PosRec x; x.ticket=(ulong)StringToInteger(p[1]);x.symbol=p[2];x.type=(int)StringToInteger(p[3]);
         x.vol=StringToDouble(p[4]);x.price=StringToDouble(p[5]);x.sl=StringToDouble(p[6]);x.tp=StringToDouble(p[7]);AddPos(s.pos,x);
      }
      else if(p[0]=="ORD" && n>=8)
      {
         OrdRec x; x.ticket=(ulong)StringToInteger(p[1]);x.symbol=p[2];x.type=(int)StringToInteger(p[3]);
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

   for(int attempt=0;attempt<CM_READ_ATTEMPTS;attempt++)
   {
      status=ReadSnapOnce(channel,s);

      if(status==CM_SNAP_OK || status==CM_SNAP_SCHEMA || status==CM_SNAP_CHANNEL)
         break;

      if(attempt+1<CM_READ_ATTEMPTS)
         Sleep(CM_READ_RETRY_MS);
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
   double step=SymbolInfoDouble(slave_symbol,SYMBOL_VOLUME_STEP);
   double minimum=SymbolInfoDouble(slave_symbol,SYMBOL_VOLUME_MIN);
   double maximum=SymbolInfoDouble(slave_symbol,SYMBOL_VOLUME_MAX);
   if(step<=0) return raw;

   double normalized=MathRound(raw/step)*step;
   if(minimum>0) normalized=MathMax(minimum,normalized);
   if(maximum>0) normalized=MathMin(maximum,normalized);
   return NormalizeDouble(normalized,VolumeDigits(step));
}
string VolumeText(const string symbol,const double volume)
{
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
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
      "Ticket Master: "+StringFormat("%I64u",order.ticket)+"\n\n"+
      "Volumen Master: "+VolumeText(slave_symbol,order.vol)+"\n"+
      "Volumen Slave: "+VolumeText(slave_symbol,expected_volume)+"\n"+
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
      "Ticket Slave: "+StringFormat("%I64u",order.ticket)+"\n"+
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
void SlavePosForOwner(const Owner &o,PosRec &a[])
{
   ArrayResize(a,0);
   // Hacia atras: si el terminal retira una posicion mientras se recorre la
   // coleccion, los indices ya visitados no se desplazan.
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i); if(tk==0)continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      if(symbol=="")continue;
      if(!SlaveSymbolAllowed(symbol))continue;

      string c=PositionGetString(POSITION_COMMENT);
      if(!OwnerCommentMatch(o,c))continue;

      PosRec x; x.ticket=tk;x.symbol=symbol;x.type=(int)PositionGetInteger(POSITION_TYPE);
      x.vol=PositionGetDouble(POSITION_VOLUME);x.price=PositionGetDouble(POSITION_PRICE_OPEN);
      x.sl=PositionGetDouble(POSITION_SL);x.tp=PositionGetDouble(POSITION_TP);AddPos(a,x);
   }
}
void SlaveOrdForOwner(const Owner &o,OrdRec &a[])
{
   ArrayResize(a,0);
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong tk=OrderGetTicket(i);if(tk==0)continue;
      ENUM_ORDER_TYPE t=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);if(!IsPending(t))continue;
      string symbol=OrderGetString(ORDER_SYMBOL);
      if(symbol=="")continue;
      if(!SlaveSymbolAllowed(symbol))continue;
      string c=OrderGetString(ORDER_COMMENT);if(!OwnerCommentMatch(o,c))continue;
      OrdRec x;x.ticket=tk;x.symbol=symbol;x.type=(int)t;x.vol=OrderGetDouble(ORDER_VOLUME_CURRENT);
      x.price=OrderGetDouble(ORDER_PRICE_OPEN);x.sl=OrderGetDouble(ORDER_SL);x.tp=OrderGetDouble(ORDER_TP);
      x.stoplimit=OrderGetDouble(ORDER_PRICE_STOPLIMIT);AddOrd(a,x);
   }
}
bool VolEq(const string ss,double actual,double expected)
{
   double step=SymbolInfoDouble(ss,SYMBOL_VOLUME_STEP);if(step<=0)step=0.01;
   double normalized=ExpectedSlaveVolume(ss,expected,1.0);
   // La tolerancia se expresa en pasos de volumen; el epsilon solo absorbe el
   // ruido de coma flotante cuando la tolerancia configurada es cero.
   double tolerance=MathMax(0,InpVolumeToleranceSteps)*step;
   return MathAbs(actual-normalized)<=tolerance+1e-9;
}
double PointOf(const string s){ double p=SymbolInfoDouble(s,SYMBOL_POINT); return p>0?p:0.00001; }
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

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      reason="El terminal Slave tiene el trading automático desactivado.";
      return false;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
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
bool SymbolAcceptsNewOrders(const string symbol,const int type,string &reason)
{
   long mode=SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE);

   if(mode==SYMBOL_TRADE_MODE_DISABLED)
   {
      reason="El símbolo tiene el trading deshabilitado en el terminal Slave.";
      return false;
   }
   if(mode==SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      reason="El símbolo sólo admite cierres en el terminal Slave.";
      return false;
   }
   if(IsBuyPendingType(type) && mode==SYMBOL_TRADE_MODE_SHORTONLY)
   {
      reason="El símbolo sólo admite operaciones de venta.";
      return false;
   }
   if(!IsBuyPendingType(type) && mode==SYMBOL_TRADE_MODE_LONGONLY)
   {
      reason="El símbolo sólo admite operaciones de compra.";
      return false;
   }
   return true;
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

   MqlTick tick;
   if(!SymbolInfoTick(symbol,tick) || tick.ask<=0 || tick.bid<=0)
   {
      reason="No hay precios actuales del símbolo en el terminal Slave.";
      return false;
   }

   double point=PointOf(symbol);
   double stops=(double)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL)*point;
   double eps=point*0.5;
   bool ok=true;

   if(type==ORDER_TYPE_BUY_LIMIT)
      ok=(price<=tick.ask-stops+eps);
   else if(type==ORDER_TYPE_SELL_LIMIT)
      ok=(price>=tick.bid+stops-eps);
   else if(type==ORDER_TYPE_BUY_STOP || type==ORDER_TYPE_BUY_STOP_LIMIT)
      ok=(price>=tick.ask+stops-eps);
   else
      ok=(price<=tick.bid-stops+eps);

   if(!ok)
   {
      reason=StringFormat("El precio de entrada no respeta la distancia mínima del broker (%d puntos).",
                          (int)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL));
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
bool PositionStopsAcceptable(const string symbol,const int type,
                             const double sl,const double tp,string &reason)
{
   reason="";

   MqlTick tick;
   if(!SymbolInfoTick(symbol,tick) || tick.ask<=0 || tick.bid<=0)
   {
      reason="No hay precios actuales del símbolo en el terminal Slave.";
      return false;
   }

   double point=PointOf(symbol);
   double stops=(double)SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL)*point;
   double eps=point*0.5;
   bool is_buy=(type==POSITION_TYPE_BUY);

   if(MathAbs(sl)>1e-12)
   {
      bool sl_ok=is_buy ? (sl<=tick.bid-stops+eps) : (sl>=tick.ask+stops-eps);
      if(!sl_ok)
      {
         reason="El Stop Loss del Master queda dentro de la distancia mínima del broker.";
         return false;
      }
   }
   if(MathAbs(tp)>1e-12)
   {
      bool tp_ok=is_buy ? (tp>=tick.ask+stops-eps) : (tp<=tick.bid-stops+eps);
      if(!tp_ok)
      {
         reason="El Take Profit del Master queda dentro de la distancia mínima del broker.";
         return false;
      }
   }
   return true;
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
void CheckOpen(const Owner &o,const Snap &snap)
{
   PosRec sp[];
   SlavePosForOwner(o,sp);

   bool su[];
   ArrayResize(su,ArraySize(sp));
   ArrayInitialize(su,false);

   bool problems=false;
   string details="";

   // 1) Protect the Slave copy corresponding to every ignored MASTER ticket.
   //    The ignored pair is removed from all later mismatch / SL / TP logic.
   for(int i=0;i<ArraySize(snap.pos);i++)
   {
      if(!MasterTicketIgnored(o.channel,snap.pos[i].ticket))
         continue;

      int best=-1;
      double cost=1e100;

      for(int j=0;j<ArraySize(sp);j++)
      {
         if(su[j] || !PosCompatible(o,snap.pos[i],sp[j]))
            continue;

         double c=PosCost(snap.pos[i],sp[j]);

         if(c<cost)
         {
            cost=c;
            best=j;
         }
      }

      if(best>=0)
         su[best]=true;
   }

   // 2) Monitor only non-ignored MASTER positions.
   for(int i=0;i<ArraySize(snap.pos);i++)
   {
      if(MasterTicketIgnored(o.channel,snap.pos[i].ticket))
         continue;

      int best=-1;
      double cost=1e100;

      for(int j=0;j<ArraySize(sp);j++)
      {
         if(su[j] || !PosCompatible(o,snap.pos[i],sp[j]))
            continue;

         double c=PosCost(snap.pos[i],sp[j]);

         if(c<cost)
         {
            cost=c;
            best=j;
         }
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
            "Ticket Master: "+StringFormat("%I64u",snap.pos[i].ticket)+"\n\n"+
            "Volumen Master: "+VolumeText(slave_symbol,snap.pos[i].vol)+"\n"+
            "Volumen Slave: "+VolumeText(slave_symbol,expected_volume)+"\n"+
            "Precio de entrada: "+PriceText(snap.pos[i].price)+"\n"+
            "Stop Loss: "+StopText(snap.pos[i].sl,"SIN SL")+"\n"+
            "Take Profit: "+StopText(snap.pos[i].tp,"SIN TP");
         continue;
      }

      su[best]=true;

      double tol=InpSLTPTolerancePoints*PointOf(sp[best].symbol);

      bool sl_bad=InpCheckStopLoss && !StopEq(snap.pos[i].sl,sp[best].sl,tol);
      bool tp_bad=InpCheckTakeProfit && !StopEq(snap.pos[i].tp,sp[best].tp,tol);

      string suffix=o.channel+"|"+StringFormat("%I64u",snap.pos[i].ticket)+
                    "|"+StringFormat("%I64u",sp[best].ticket);
      string alert_key="SLTP|"+suffix;
      string fix_key="FIXSLTP|"+suffix;

      if(sl_bad || tp_bad)
      {
         string problem_detail=
            "\n\nPROBLEMA:\nLa posición copiada tiene valores diferentes.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Tipo: "+PositionTypeText(snap.pos[i].type)+"\n"+
            "Símbolo: "+sp[best].symbol+"\n"+
            "Ticket Master: "+StringFormat("%I64u",snap.pos[i].ticket)+"\n"+
            "Ticket Slave: "+StringFormat("%I64u",sp[best].ticket)+"\n";

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
         PersistAlert(alert_key,alert);

         if(InpAutoFixPositionSLTP &&
            ConfirmProblem(fix_key,InpAutoFixPersistSeconds))
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
         ResolveAlert(alert_key,
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nLos valores SL y TP de la posición ya coinciden."+
            "\n\nEstado: POSICIÓN ACTIVA\nTipo: "+PositionTypeText(snap.pos[i].type)+
            "\nSímbolo: "+sp[best].symbol+
            "\nTicket Master: "+StringFormat("%I64u",snap.pos[i].ticket)+
            "\nTicket Slave: "+StringFormat("%I64u",sp[best].ticket));
         ClearAlert("FAIL|"+alert_key);
         ClearAlert("PBLOCK|"+fix_key);
         RemoveProblem(fix_key);
      }
   }

   // Anything still unused is genuinely unmatched after protecting ignored
   // Master-ticket copies.
   for(int j=0;j<ArraySize(sp);j++)
   {
      if(su[j] || o.profile!=PROFILE_PORTFOLIO46)
         continue;

      problems=true;
      details+=
         "\n\nPROBLEMA:\nExiste una posición activa extra en el Slave.\n\n"+
         "Estado: POSICIÓN ACTIVA\n"+
         "Tipo: "+PositionTypeText(sp[j].type)+"\n"+
         "Símbolo: "+sp[j].symbol+"\n"+
         "Ticket Slave: "+StringFormat("%I64u",sp[j].ticket)+"\n"+
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
bool StillOwnedPending(const Owner &o,ulong tk,OrdRec &x)
{
   if(!OrderSelect(tk))return false;
   ENUM_ORDER_TYPE t=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);if(!IsPending(t))return false;
   string symbol=OrderGetString(ORDER_SYMBOL);
   if(!SlaveSymbolAllowed(symbol))return false;
   if(!OwnerCommentMatch(o,OrderGetString(ORDER_COMMENT)))return false;
   x.ticket=tk;x.symbol=symbol;x.type=(int)t;x.vol=OrderGetDouble(ORDER_VOLUME_CURRENT);
   x.price=OrderGetDouble(ORDER_PRICE_OPEN);x.sl=OrderGetDouble(ORDER_SL);x.tp=OrderGetDouble(ORDER_TP);
   x.stoplimit=OrderGetDouble(ORDER_PRICE_STOPLIMIT);return true;
}
bool TradeRequestSucceeded(const bool sent)
{
   if(!sent) return false;
   uint code=g_trade.ResultRetcode();
   return code==TRADE_RETCODE_DONE || code==TRADE_RETCODE_PLACED ||
          code==TRADE_RETCODE_DONE_PARTIAL || code==TRADE_RETCODE_NO_CHANGES;
}
string TradeFailureDetails()
{
   return "\nRetcode: "+IntegerToString((int)g_trade.ResultRetcode())+
          "\nDetalle: "+g_trade.ResultRetcodeDescription()+
          "\nError MQL: "+IntegerToString(GetLastError());
}
bool FixPositionStops(const ulong ticket,const double sl,const double tp)
{
   ResetLastError();
   if(!TradeRequestSucceeded(g_trade.PositionModify(ticket,sl,tp))) return false;
   if(!PositionSelectByTicket(ticket)) return false;
   string symbol=PositionGetString(POSITION_SYMBOL);
   double tol=InpSLTPTolerancePoints*PointOf(symbol);
   return StopEq(PositionGetDouble(POSITION_SL),sl,tol) &&
          StopEq(PositionGetDouble(POSITION_TP),tp,tol);
}
bool CreatablePendingType(const int type)
{
   return type==ORDER_TYPE_BUY_LIMIT || type==ORDER_TYPE_SELL_LIMIT ||
          type==ORDER_TYPE_BUY_STOP  || type==ORDER_TYPE_SELL_STOP ||
          type==ORDER_TYPE_BUY_STOP_LIMIT || type==ORDER_TYPE_SELL_STOP_LIMIT;
}
bool SendPendingOrder(const Owner &o,const OrdRec &master,const string symbol,
                      const double volume)
{
   if(master.type==ORDER_TYPE_BUY_LIMIT)
      return g_trade.BuyLimit(volume,master.price,symbol,master.sl,master.tp,ORDER_TIME_GTC,0,o.comment);
   if(master.type==ORDER_TYPE_SELL_LIMIT)
      return g_trade.SellLimit(volume,master.price,symbol,master.sl,master.tp,ORDER_TIME_GTC,0,o.comment);
   if(master.type==ORDER_TYPE_BUY_STOP)
      return g_trade.BuyStop(volume,master.price,symbol,master.sl,master.tp,ORDER_TIME_GTC,0,o.comment);
   if(master.type==ORDER_TYPE_SELL_STOP)
      return g_trade.SellStop(volume,master.price,symbol,master.sl,master.tp,ORDER_TIME_GTC,0,o.comment);
   // STOP LIMIT: el esquema 3 transporta el precio limite, asi que la copia ya
   // se puede reproducir con los dos precios.
   return g_trade.OrderOpen(symbol,(ENUM_ORDER_TYPE)master.type,volume,
                            master.stoplimit,master.price,master.sl,master.tp,
                            ORDER_TIME_GTC,0,o.comment);
}
int CreatePendingCopy(const Owner &o,const OrdRec &master,ulong &created_ticket,string &blocked_reason)
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
   if(!SymbolSelect(symbol,true))
   {
      blocked_reason="El símbolo esperado no está disponible en el terminal Slave.";
      return CM_CREATE_BLOCKED;
   }
   if(!CreatablePendingType(master.type))
   {
      blocked_reason="El tipo de orden pendiente del Master no se crea automáticamente.";
      return CM_CREATE_BLOCKED;
   }
   if(!SymbolAcceptsNewOrders(symbol,master.type,blocked_reason))
      return CM_CREATE_BLOCKED;

   // El volumen se compara con el clamp del broker, pero crear fuera de rango
   // significaria copiar un tamaño distinto del pedido por el Master.
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   double vmin=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
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

   g_trade.SetTypeFillingBySymbol(symbol);
   ResetLastError();

   bool sent=SendPendingOrder(o,master,symbol,volume);

   // Algunos brokers rechazan el modo de llenado deducido del simbolo para las
   // pendientes. Se reintenta una sola vez con ORDER_FILLING_RETURN.
   if(!TradeRequestSucceeded(sent) &&
      g_trade.ResultRetcode()==TRADE_RETCODE_INVALID_FILL)
   {
      g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
      ResetLastError();
      sent=SendPendingOrder(o,master,symbol,volume);
   }

   created_ticket=g_trade.ResultOrder();
   if(!TradeRequestSucceeded(sent) || created_ticket==0)
      return CM_CREATE_FAILED;

   OrdRec live;
   if(!StillOwnedPending(o,created_ticket,live))
      return CM_CREATE_UNVERIFIED;

   // La copia debe quedar ademas emparejable: si no lo es, el proximo ciclo
   // seguiria viendo la pendiente Master sin copia y crearia otra.
   if(!OrdCompatible(o,master,live))
      return CM_CREATE_UNVERIFIED;

   return CM_CREATE_DONE;
}
bool ModifyPendingCopy(const Owner &o,const OrdRec &master,const ulong slave_ticket)
{
   OrdRec live;
   if(!StillOwnedPending(o,slave_ticket,live)) return false;
   ENUM_ORDER_TYPE_TIME time_type=(ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
   datetime expiration=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
   // El precio stop-limit del Master sólo se conoce desde el esquema 3; con un
   // Master antiguo se conserva el valor de la copia.
   double stoplimit=live.stoplimit;
   if(IsStopLimitType(live.type) && master.stoplimit>0)
      stoplimit=master.stoplimit;
   ResetLastError();
   bool sent=g_trade.OrderModify(slave_ticket,master.price,master.sl,master.tp,
                                 time_type,expiration,stoplimit);
   if(!TradeRequestSucceeded(sent) || !OrderSelect(slave_ticket)) return false;
   double point=PointOf(live.symbol);
   double tol=InpSLTPTolerancePoints*point;
   return PriceEq(OrderGetDouble(ORDER_PRICE_OPEN),master.price,
                  InpPendingPriceTolerancePoints*point) &&
          StopEq(OrderGetDouble(ORDER_SL),master.sl,tol) &&
          StopEq(OrderGetDouble(ORDER_TP),master.tp,tol);
}

//---------------- stale alert cleanup ----------------
bool MasterOrderPresent(const Snap &snap,const ulong ticket)
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
      int n=StringSplit(key,'|',f);
      if(n<3)
         continue;

      // SLTP|canal|master|slave y FAIL|SLTP|canal|master|slave
      if(f[0]=="SLTP" && n==4 && f[1]==o.channel)
      {
         ulong ticket=(ulong)StringToInteger(f[3]);
         if(ticket>0 && PositionSelectByTicket(ticket)) continue;
         ResolveVanished(key,snap,"La posición avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[3]);
         ClearAlert("FAIL|"+key);
         ClearAlert("PBLOCK|FIXSLTP|"+f[1]+"|"+f[2]+"|"+f[3]);
         RemoveProblem("FIXSLTP|"+f[1]+"|"+f[2]+"|"+f[3]);
         continue;
      }
      if(f[0]=="FAIL" && f[1]=="SLTP" && n==5 && f[2]==o.channel)
      {
         ulong ticket=(ulong)StringToInteger(f[4]);
         if(ticket>0 && PositionSelectByTicket(ticket)) continue;
         ResolveVanished(key,snap,"La posición avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[4]);
         continue;
      }

      // PVALUES|canal|master|slave y FAIL|PVALUES|canal|master|slave
      if(f[0]=="PVALUES" && n==4 && f[1]==o.channel)
      {
         ulong ticket=(ulong)StringToInteger(f[3]);
         if(ticket>0 && OrderSelect(ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[3]);
         ClearAlert("FAIL|"+key);
         ClearAlert("PBLOCK|FIXPEND|"+f[1]+"|"+f[2]+"|"+f[3]);
         RemoveProblem("FIXPEND|"+f[1]+"|"+f[2]+"|"+f[3]);
         continue;
      }
      if(f[0]=="FAIL" && f[1]=="PVALUES" && n==5 && f[2]==o.channel)
      {
         ulong ticket=(ulong)StringToInteger(f[4]);
         if(ticket>0 && OrderSelect(ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[4]);
         continue;
      }

      // PEXTRA|canal|slave y PAMB|canal|slave
      if((f[0]=="PEXTRA" || f[0]=="PAMB") && n==3 && f[1]==o.channel)
      {
         ulong ticket=(ulong)StringToInteger(f[2]);
         if(ticket>0 && OrderSelect(ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[2]);
         ClearAlert("FAIL|PEXTRA|"+f[1]+"|"+f[2]);
         ClearAlert("PBLOCK|DELETE|"+f[1]+"|"+f[2]);
         RemoveProblem("DELETE|"+f[1]+"|"+f[2]);
         continue;
      }
      if(f[0]=="FAIL" && f[1]=="PEXTRA" && n==4 && f[2]==o.channel)
      {
         ulong ticket=(ulong)StringToInteger(f[3]);
         if(ticket>0 && OrderSelect(ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente avisada ya no existe en la cuenta Slave."+
                                  "\nTicket Slave: "+f[3]);
         continue;
      }

      // FAIL|CREATE|canal|master y PBLOCK|CREATE|canal|master
      if((f[0]=="FAIL" || f[0]=="PBLOCK") && f[1]=="CREATE" && n==4 && f[2]==o.channel)
      {
         ulong ticket=(ulong)StringToInteger(f[3]);
         if(ticket>0 && MasterOrderPresent(snap,ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente del Master que no se pudo copiar ya no existe."+
                                  "\nTicket Master: "+f[3]);
         UnblockCreate("CREATE|"+f[2]+"|"+f[3]);
         RemoveProblem("CREATE|"+f[2]+"|"+f[3]);
         continue;
      }
   }
}

void CheckPending(const Owner &o,const Snap &snap)
{
   OrdRec so[];
   SlaveOrdForOwner(o,so);

   bool slave_protected[];
   ArrayResize(slave_protected,ArraySize(so));
   ArrayInitialize(slave_protected,false);

   // First protect any Slave pending that corresponds to an ignored MASTER
   // pending ticket. It must never be reported or auto-deleted because the
   // user deliberately excluded that MASTER ticket from monitoring.
   for(int m=0;m<ArraySize(snap.ord);m++)
   {
      if(!MasterTicketIgnored(o.channel,snap.ord[m].ticket))
         continue;

      int best=-1;
      double best_delta=1e100;

      for(int s=0;s<ArraySize(so);s++)
      {
         if(slave_protected[s])
            continue;

         if(!OrdCompatible(o,snap.ord[m],so[s]))
            continue;

         double delta=MathAbs(snap.ord[m].price-so[s].price);

         if(delta<best_delta)
         {
            best_delta=delta;
            best=s;
         }
      }

      if(best>=0)
      {
         slave_protected[best]=true;
         RemoveProblem("DELETE|"+o.channel+"|"+StringFormat("%I64u",so[best].ticket));
         ClearAlert("PEXTRA|"+o.channel+"|"+
                    StringFormat("%I64u",so[best].ticket));
         ClearAlert("FAIL|PEXTRA|"+o.channel+"|"+
                    StringFormat("%I64u",so[best].ticket));
         ResolveAlert("PAMB|"+o.channel+"|"+
                      StringFormat("%I64u",so[best].ticket),
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nLa orden pendiente del Slave corresponde a un ticket Master ignorado."+
            "\nTicket Slave: "+StringFormat("%I64u",so[best].ticket));
      }
   }

   // Pair each monitored Master pending with at most one Slave pending.
   // Count-only comparison is insufficient: a wrong order can hide a missing
   // order, and two Slave orders must not reuse the same Master order.
   bool master_matched[];
   ArrayResize(master_matched,ArraySize(snap.ord));
   ArrayInitialize(master_matched,false);

   for(int m=0;m<ArraySize(snap.ord);m++)
   {
      if(MasterTicketIgnored(o.channel,snap.ord[m].ticket))
      {
         master_matched[m]=true;
         continue;
      }

      int best=-1;
      double best_delta=1e100;

      for(int s=0;s<ArraySize(so);s++)
      {
         if(slave_protected[s] || !OrdCompatible(o,snap.ord[m],so[s]))
            continue;

         double delta=MathAbs(snap.ord[m].price-so[s].price);
         if(delta<best_delta)
         {
            best_delta=delta;
            best=s;
         }
      }

      if(best>=0)
      {
         master_matched[m]=true;
         slave_protected[best]=true;
         string matched_create="CREATE|"+o.channel+"|"+StringFormat("%I64u",snap.ord[m].ticket);
         RemoveProblem(matched_create);
         UnblockCreate(matched_create);
         ClearAlert("FAIL|"+matched_create);
         ClearAlert("PBLOCK|"+matched_create);
         RemoveProblem("DELETE|"+o.channel+"|"+StringFormat("%I64u",so[best].ticket));
         ClearAlert("PEXTRA|"+o.channel+"|"+
                    StringFormat("%I64u",so[best].ticket));
         ClearAlert("FAIL|PEXTRA|"+o.channel+"|"+
                    StringFormat("%I64u",so[best].ticket));
         ResolveAlert("PAMB|"+o.channel+"|"+
                      StringFormat("%I64u",so[best].ticket),
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nLa orden pendiente del Slave ya se empareja con una orden Master."+
            "\nTicket Master: "+StringFormat("%I64u",snap.ord[m].ticket)+
            "\nTicket Slave: "+StringFormat("%I64u",so[best].ticket));

         double point=PointOf(so[best].symbol);
         double stop_tol=InpSLTPTolerancePoints*point;
         bool price_bad=!PriceEq(snap.ord[m].price,so[best].price,
                                 InpPendingPriceTolerancePoints*point);
         bool sl_bad=InpCheckStopLoss && !StopEq(snap.ord[m].sl,so[best].sl,stop_tol);
         bool tp_bad=InpCheckTakeProfit && !StopEq(snap.ord[m].tp,so[best].tp,stop_tol);
         // El precio límite sólo se compara cuando el Master lo publica.
         bool limit_bad=IsStopLimitType(snap.ord[m].type) && snap.ord[m].stoplimit>0 &&
                        !PriceEq(snap.ord[m].stoplimit,so[best].stoplimit,
                                 InpPendingPriceTolerancePoints*point);
         string suffix=o.channel+"|"+StringFormat("%I64u",snap.ord[m].ticket)+
                       "|"+StringFormat("%I64u",so[best].ticket);
         string alert_key="PVALUES|"+suffix;
         string fix_key="FIXPEND|"+suffix;

         if(InpMonitorPendingOrders && (price_bad || sl_bad || tp_bad || limit_bad))
         {
            string detail=
               "\n\nPROBLEMA:\nLa orden pendiente copiada tiene valores diferentes.\n\n"+
               "Estado: ORDEN PENDIENTE\n"+
               "Tipo: "+OrderTypeText(snap.ord[m].type)+"\n"+
               "Símbolo: "+so[best].symbol+"\n"+
               "Ticket Master: "+StringFormat("%I64u",snap.ord[m].ticket)+"\n"+
               "Ticket Slave: "+StringFormat("%I64u",so[best].ticket);
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

            PersistAlert(alert_key,
               AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+detail+
               "\n\nACCIÓN:\nEsperando que el problema persista antes de corregirlo automáticamente.");

            if(InpAutoModifyPending && ConfirmProblem(fix_key,InpAutoFixPersistSeconds))
            {
               string blocked_reason="";

               if(!g_trade_allowed)
               {
                  PersistAlert("PBLOCK|"+fix_key,
                     AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
                     "\n\nACCIÓN:\nNo se puede modificar automáticamente.\n"+g_trade_block_reason);
               }
               else if(!PendingPriceAcceptable(so[best].symbol,so[best].type,snap.ord[m].price,
                                               snap.ord[m].sl,snap.ord[m].tp,
                                               IsStopLimitType(so[best].type)
                                                  ? (snap.ord[m].stoplimit>0 ? snap.ord[m].stoplimit : so[best].stoplimit)
                                                  : 0.0,
                                               blocked_reason))
               {
                  PersistAlert("PBLOCK|"+fix_key,
                     AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
                     "\n\nACCIÓN:\nNo se puede modificar automáticamente.\n"+blocked_reason);
               }
               else if(ModifyPendingCopy(o,snap.ord[m],so[best].ticket))
               {
                  Tg(AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+detail+
                     "\n\nACCIÓN AUTOMÁTICA:\nPrecio, SL y TP corregidos correctamente.");
                  ClearAlert(alert_key);
                  ClearAlert("PBLOCK|"+fix_key);
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
            ResolveAlert(alert_key,
               AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
               "\n\nPROBLEMA RESUELTO:\nLa orden pendiente ya tiene el precio, SL y TP correctos."+
               "\n\nEstado: ORDEN PENDIENTE\nTipo: "+OrderTypeText(snap.ord[m].type)+
               "\nSímbolo: "+so[best].symbol+
               "\nTicket Master: "+StringFormat("%I64u",snap.ord[m].ticket)+
               "\nTicket Slave: "+StringFormat("%I64u",so[best].ticket));
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
         PersistAlert(
            "PMISS|"+o.channel,
            msg);

         bool created_any=false;
         for(int m=0;m<ArraySize(snap.ord);m++)
         {
            if(master_matched[m]) continue;
            string create_key="CREATE|"+o.channel+"|"+
                              StringFormat("%I64u",snap.ord[m].ticket);
            if(!InpAutoCreateMissingPending || IsCreateBlocked(create_key) ||
               !ConfirmProblem(create_key,InpAutoFixPersistSeconds))
               continue;

            ulong created_ticket=0;
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

            int created=CreatePendingCopy(o,snap.ord[m],created_ticket,blocked_reason);
            RemoveProblem(create_key);

            if(created==CM_CREATE_DONE)
            {
               Tg(AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+detail+
                  "\nTicket Slave creado: "+StringFormat("%I64u",created_ticket)+
                  "\n\nACCIÓN AUTOMÁTICA:\nLa orden pendiente fue creada correctamente.");
               ClearAlert("FAIL|"+create_key);
               ClearAlert("PBLOCK|"+create_key);
               created_any=true;
            }
            else if(created==CM_CREATE_UNVERIFIED)
            {
               // La orden existe pero el monitor no la reconoce como copia
               // propia. Reintentar duplicaria la pendiente en cada ventana.
               BlockCreate(create_key);
               PersistAlert("FAIL|"+create_key,
                  AlertHeader(snap,"🔴 COPYMONITOR — CRÍTICO")+detail+
                  "\nTicket Slave creado: "+StringFormat("%I64u",created_ticket)+
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
      if(slave_protected[s])
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

         PersistAlert(
            "PAMB|"+o.channel+"|"+
            StringFormat("%I64u",so[s].ticket),
            msg);

         continue;
      }

      ResolveAlert(
         "PAMB|"+o.channel+"|"+
         StringFormat("%I64u",so[s].ticket),
         AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nLa orden pendiente del Slave ya se puede evaluar: el Master no tiene pendientes."+
         "\nTicket Slave: "+StringFormat("%I64u",so[s].ticket));

      string delete_problem="DELETE|"+o.channel+"|"+StringFormat("%I64u",so[s].ticket);
      string key=
         "PEXTRA|"+o.channel+"|"+
         StringFormat("%I64u",so[s].ticket);
      string detail=
         "\n\nPROBLEMA:\nSe encontró una orden pendiente extra en el Slave.\n\n"+
         SlavePendingDetails(so[s]);
      string alert=AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+detail+
         "\n\nACCIÓN:\nEsperando que el problema persista antes de eliminarla automáticamente.";
      PersistAlert(key,alert);

      if(!InpAutoDeleteExtraPending)
         continue;

      if(!ConfirmProblem(delete_problem,InpExtraPendingConfirmSeconds))
         continue;

      if(!g_trade_allowed)
      {
         PersistAlert("PBLOCK|"+delete_problem,
            AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
            "\n\nACCIÓN:\nNo se puede eliminar automáticamente.\n"+g_trade_block_reason);
         continue;
      }

      // Final safety re-check.
      OrdRec live;

      if(!StillOwnedPending(o,so[s].ticket,live))
         continue;

      ResetLastError();
      bool ok=TradeRequestSucceeded(g_trade.OrderDelete(so[s].ticket));

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
   string p="COPYMONITOR SLAVE v1.17 MULTI\n";
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
   p+="Auto corrections: "+(g_trade_allowed ? "READY" : "BLOCKED: "+g_trade_block_reason)+"\n";
   if(!TgConfigured())
      p+="Telegram: OFF";
   else
   {
      p+="Telegram: ON";
      if(ArraySize(g_tg_queue)>0)
         p+=" | en cola: "+IntegerToString(ArraySize(g_tg_queue));
      if(g_tg_dropped>0)
         p+=" | descartados: "+IntegerToString(g_tg_dropped);
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
      if((now-g_candidates[i].last_seen)>CM_STATE_TTL_SECONDS)
         RemoveProblem(g_candidates[i].key);

   for(int i=ArraySize(g_create_blocked)-1;i>=0;i--)
      if((now-g_create_blocked[i].last_seen)>CM_STATE_TTL_SECONDS)
         UnblockCreate(g_create_blocked[i].key);

   for(int i=ArraySize(g_alerts)-1;i>=0;i--)
   {
      if(g_alerts[i].active || (now-g_alerts[i].last)<=CM_STATE_TTL_SECONDS)
         continue;
      int n=ArraySize(g_alerts);
      for(int j=i;j<n-1;j++)g_alerts[j]=g_alerts[j+1];
      ArrayResize(g_alerts,n-1);
   }
}
void Cycle()
{
   if(g_busy)return;
   g_busy=true;

   g_trade_allowed=TradingPermitted(g_trade_block_reason);

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
   return BuildConfig();
}
// Cada cierre genera varias transacciones y muchas no cambian el estado que se
// compara. Reaccionar solo a las relevantes evita releer los snapshots decenas
// de veces por segundo en una cuenta activa.
bool TransactionMatters(const ENUM_TRADE_TRANSACTION_TYPE type)
{
   return type==TRADE_TRANSACTION_ORDER_ADD ||
          type==TRADE_TRANSACTION_ORDER_UPDATE ||
          type==TRADE_TRANSACTION_ORDER_DELETE ||
          type==TRADE_TRANSACTION_DEAL_ADD ||
          type==TRADE_TRANSACTION_POSITION;
}
int OnInit()
{
   if(!Validate())return INIT_PARAMETERS_INCORRECT;
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   Cycle();
   if(!EventSetTimer(InpMonitorSeconds))
   {
      PrintFormat("[CM SLAVE] EventSetTimer fallo. err=%d",GetLastError());
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){EventKillTimer();Comment("");}
void OnTimer(){Cycle();}
void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &r,const MqlTradeResult &x)
{
   if(!TransactionMatters(t.type))
      return;
   Cycle();
}
//+------------------------------------------------------------------+
