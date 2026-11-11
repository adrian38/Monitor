//+------------------------------------------------------------------+
//| CopyMonitor_Slave_MT5_v1_33_MULTI.mq5                            |
//| Preserves GENERIC / PORTFOLIO46 / LUNA profiles.                 |
//| Optional MultiMaster layer by exact Slave comment ownership.      |
//| Open positions: monitor quantity + SL/TP, never auto-close.       |
//| Pending orders: normally ignored as copy expectations; optional   |
//| confirmed EXTRA pending in Slave can be deleted.                  |
//+------------------------------------------------------------------+
#property strict
#property version "1.33"
#property description "CopyMonitor Slave MT5 v1.33 MULTI"
#include <Trade/Trade.mqh>
CTrade g_trade;

enum ENUM_COPY_PROFILE
{
   PROFILE_GENERIC=0,
   PROFILE_PORTFOLIO46=1,
   PROFILE_LUNA=2
};

// Como se reconoce que una operacion del Slave pertenece a un owner. La
// comparacion exacta es la regla historica y sigue siendo la recomendada;
// los otros dos modos existen porque hay brokers que reescriben o recortan el
// comentario al activarse una pendiente o tras un cierre parcial, y entonces
// la copia deja de reconocerse como propia y se denuncia a la vez como copia
// faltante y como operacion de ningun canal.
enum ENUM_OWNER_MATCH
{
   OWNER_MATCH_EXACT=0,
   OWNER_MATCH_PREFIX=1,
   OWNER_MATCH_CONTAINS=2
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

input group "===== OWNERSHIP / IDENTITY ====="
// Comparacion exacta por defecto. PREFIX y CONTAINS sirven para brokers que
// anaden o recortan texto en el comentario de la operacion copiada.
input ENUM_OWNER_MATCH InpOwnerMatchMode              = OWNER_MATCH_EXACT;
// Cuentas Master esperadas, en el mismo orden que los canales. Vacio = no se
// comprueba. Sin esto, cambiar el login del terminal Master conservando el
// canal dejaba al Slave vigilando otra cuenta sin decir una palabra.
input string InpExpectedMasterAccounts                = "";
// El emparejamiento supone una copia por posicion Master, es decir cuenta de
// cobertura. En una cuenta de compensacion dos copias del mismo simbolo se
// funden en una posicion con el volumen sumado y el modelo entero se cae.
input bool   InpAllowNettingAccount                   = false;

input group "===== INSTANCE SCOPE / IGNORE ====="
// MASTER tickets to ignore. Examples:
// 123456;123457
// MASTER_280:123456;MASTER_687:998877
input string InpIgnoreMasterTickets                   = "";
// Comentarios exactos de operaciones Slave que quedan totalmente fuera de la
// vigilancia. Acepta coma o punto y coma; distingue mayusculas/minusculas.
input string InpIgnoreSlaveComments                   = "";
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
// Avisar de una posicion Slave sin pareja Master. Hasta la v1.24 esto estaba
// cableado al perfil PORTFOLIO46, asi que el caso mas caro de todos -el Master
// cerro y la copia sigue abierta- no tenia aviso por ticket en GENERIC ni en
// LUNA: sólo aparecia dentro del recuento agregado, sin ticket ni volumen.
input bool InpAlertExtraPositions                     = true;
// Tolerancias por simbolo, para cuando oro, indices y divisas conviven en la
// misma cuenta y un unico valor en puntos es o muchisimo o nada.
// Acepta el nombre Master o Slave de InpSymbolMaps; el Slave tiene prioridad.
// SIMBOLO,entrada,sltp,pendiente;... Ejemplo: XAUUSD,500,100,500;US500,200,50,200
input string InpSymbolTolerances                      = "";

input group "===== PENDING BEHAVIOR ====="
// For this Prop setup, copied pendings are NOT expected.
input bool InpMonitorPendingOrders                    = true;
input bool InpExpectPendingCopies                     = true;
input bool InpAutoFixPositionSLTP                     = true;
input bool InpAutoFixPendingSLTP                      = true;
input bool InpAutoCreateMissingPending                = true;
// Retardo propio antes de crear una copia pendiente que falta. Crear una
// orden nueva no es lo mismo que ajustar SL/TP de algo que ya existe: la
// copiadora suele necesitar mas margen y, si se queda corto, el Slave abre
// una orden que la copiadora iba a abrir de todos modos.
input int  InpMissingPendingConfirmSeconds            = 5;
input bool InpAutoModifyPending                       = true;
// Retardo de las correcciones de valores: SL/TP de posiciones y de
// pendientes, precio de entrada y precio limite.
input int  InpAutoFixPersistSeconds                   = 5;
// But an owned pending that is confirmed EXTRA may be deleted.
input bool InpAutoDeleteExtraPending                  = true;
// Sube de 2 a 10 segundos en la v1.25. El borrado es la unica accion
// destructiva del EA y dos segundos no dan tiempo a nadie a intervenir.
input int  InpExtraPendingConfirmSeconds              = 10;
// Tiempo sin el ticket Master enlazado ni otra pendiente que pueda explicar
// esa copia. Se conserva el nombre del parámetro para reutilizar los presets.
input int  InpEmptyMasterConfirmSeconds               = 30;
input int  InpPendingPriceTolerancePoints             = 100;
// Tope de acciones automaticas por hora y canal. Si la copiadora y el monitor
// se contradicen -una borra lo que la otra crea- se produce un ping-pong de
// ordenes que una prop firm penaliza. 0 = sin limite.
input int  InpMaxAutoActionsPerHour                   = 20;
// Guarda de escala de precios: desvio maximo admitido entre el precio que
// publica el Master y el precio actual del simbolo Slave antes de crear,
// modificar o corregir. No es una guarda de deslizamiento, sino de
// equivalencia equivocada: un mapeo que apunta a otro instrumento produce
// diferencias de orden de magnitud. 0 = desactivada.
input double InpMaxPriceDeviationPercent              = 50.0;

input group "===== LUNA LEGACY SETTINGS ====="
input bool   InpLunaRequireComment                    = false;
input string InpLunaCommentContains                   = "LUNA";

input group "===== SNAPSHOT / TELEGRAM ====="
input int    InpSnapshotStaleSeconds                  = 5;
input bool   InpEnableTelegram                        = true;
input string InpTelegramBotToken                      = "";
input string InpTelegramChatID                        = "";
// Un POST con TLS a api.telegram.org no siempre cierra en poco mas de un
// segundo: un timeout corto convertia una respuesta lenta en un fallo y metia
// el aviso en la cola de reintentos sin necesidad.
input int    InpTelegramTimeoutMs                     = 5000;
input int    InpMismatchReminderSeconds               = 15;
// Gobierna solo la ausencia TRANSITORIA de datos. Una ausencia sostenida se
// avisa siempre: ver InpStaleAlertSeconds.
input bool   InpNotifySnapshotProblems                = false;
// Segundos sin datos validos y recientes a partir de los cuales el aviso es
// obligatorio, con independencia de InpNotifySnapshotProblems. Un Master
// muerto, un VPS reiniciado o un disco lleno dejaban al Slave suspendiendo
// todas las comparaciones en silencio, que es justo cuando hay que gritar.
input int    InpStaleAlertSeconds                     = 30;
// Segundos que el Master debe llevar declarandose sin conexion antes de
// avisar. Una microdesconexion no es una caida.
input int    InpMasterOfflineConfirmSeconds           = 30;
// Lo mismo para el propio terminal Slave: desconectado, sus colecciones son
// una foto cacheada y no se puede comparar nada contra ellas.
input int    InpSlaveOfflineConfirmSeconds            = 30;
// Tras recuperar un enlace se esperan snapshots estables antes de volver a
// comparar o corregir. TERMINAL_CONNECTED no garantiza por si solo que todas
// las colecciones ya esten sincronizadas.
input int    InpLinkRecoverySeconds                    = 3;
// Nivel de margen minimo de la cuenta Slave antes de avisar, en porcentaje.
// 0 = desactivado.
input double InpMinMarginLevelPercent                 = 0.0;
// Aviso de arranque y latido periodico. Sin ellos no hay forma de saber que
// el monitor sigue vivo ni que su Telegram funciona: el que deberia avisar de
// que el EA ha muerto es precisamente el EA que ha muerto.
input bool   InpSendStartupNotice                     = true;
input int    InpHeartbeatHours                        = 12;   // 0 = sin latido
// Respaldo por notificacion push de MetaQuotes para los avisos CRITICO.
// SendNotification no necesita que api.telegram.org este en la whitelist de
// WebRequest, asi que sobrevive al fallo que deja mudo a Telegram.
input bool   InpEnablePushFallback                    = true;
// Estado de avisos en disco. Sin el, un reinicio olvida que un problema estaba
// avisado y el RESUELTO correspondiente no se envia nunca.
input bool   InpPersistAlertState                     = true;
// ALERTA, RESUELTO y CRITICO de las correcciones automaticas son obligatorios:
// el usuario debe saber siempre que cambio el EA en la cuenta Slave.
// InpNotifySnapshotProblems solo gobierna la falta transitoria de datos. Un
// snapshot con el contrato roto se avisa siempre.

input group "===== TIMERS / LIMITES INTERNOS ====="
// Valores por defecto: los que el EA usaba fijos hasta la v1.17.
// Caducidad del estado interno (ventanas, avisos cerrados, bloqueos).
input int InpStateTTLSeconds                          = 3600;
// Lecturas del snapshot por ciclo y pausa entre ellas, para absorber una
// lectura que coincida con la reescritura del Master.
input int InpSnapshotReadAttempts                     = 3;
input int InpSnapshotReadRetryMs                      = 15;
// Reintento de una correccion mientras el mercado del simbolo este cerrado.
input int InpMarketClosedRetrySeconds                 = 60;
// Adelanto del reloj admitido al calcular la frescura del snapshot. Master y
// Slave escriben y leen TimeLocal(), asi que en la misma maquina basta un
// segundo; una sincronizacion NTP o dos maquinas distintas necesitan mas.
input int InpClockSkewToleranceSeconds                = 1;
// Troceo, cola y ritmo de envio de Telegram.
input int InpTelegramChunkChars                       = 3000;
input int InpTelegramQueueMax                         = 40;
input int InpTelegramSendsPerCycle                    = 2;
// Espera tras un envio fallido. Telegram limita por token y en el lado del
// servidor: reintentar cada ciclo renueva la penalizacion en lugar de dejarla
// caducar, asi que la espera arranca en la base y se dobla hasta el tope.
input int InpTelegramRetryBaseSeconds                 = 5;
input int InpTelegramRetryMaxSeconds                  = 300;

input group "===== DIAGNOSTIC ====="
input bool   InpVerboseLog                            = false;
input bool   InpUseCopiixLogMatches                   = false;

struct PosRec { ulong ticket; string symbol; int type; double vol; double price; double sl; double tp; };
struct CopiixPosLink { ulong master,slave; };
struct OrdRec { ulong ticket; string symbol; int type; double vol; double price; double sl; double tp; double stoplimit; };
struct Snap
{
   string channel,nick,broker,session;
   long account,written;
   int open_total,pending_total;
   int schema,status;
   // Conexion del terminal Master con su servidor, publicada desde el
   // esquema 4. CM_LINK_UNKNOWN con un Master anterior, que no la declara.
   int connected;
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
// Tolerancias propias de un simbolo. Lo que no se declara usa el valor global.
struct SymbolTolRec { string symbol; int entry,sltp,pending; };
struct PendingLink
{
   ulong master,slave;
   datetime absent_since;
};
// Estado vivo de un canal entre ciclos. No se persiste: tras un reinicio toda
// cuenta atras vuelve a empezar, que es el comportamiento prudente.
struct ChannelState
{
   string   channel;
   // Desde cuando el Master se declara sin conexion, y desde cuando no llegan
   // datos validos y recientes. Cero significa que no hay caida en curso.
   datetime offline_since;
   datetime unfresh_since;
   // Desde cuando todos los requisitos de confianza vuelven a cumplirse.
   datetime trusted_since;
   // Vínculos demostrados durante la sesión y el enlace de confianza actuales.
   PendingLink pending_links[];
   long     last_written;
   string   last_session;
   // Ventana del cortacircuitos de acciones automaticas.
   datetime actions_since;
   int      actions_count;
};
// note guarda la firma del contenido de un aviso que solo se reenvia
// cuando esa firma cambia. Es estado vivo, no se persiste.
struct AlertState { string key; bool active; datetime last; string note; };
struct Candidate { string key; datetime first_seen; datetime last_seen; };
struct Blocked { string key; datetime last_seen; };

// Resultado de un intento de creacion automatica de pendiente.
#define CM_CREATE_BLOCKED    (-1)
#define CM_CREATE_FAILED     0
#define CM_CREATE_DONE       1
#define CM_CREATE_UNVERIFIED 2
#define CM_CREATE_UNCERTAIN  3
#define CM_CREATE_PRESENT    4

// Resultado de la lectura de un snapshot.
#define CM_SNAP_OK       0
#define CM_SNAP_MISSING  1
#define CM_SNAP_PARTIAL  2
#define CM_SNAP_SCHEMA   3
#define CM_SNAP_CHANNEL  4

// Estado del enlace del Master con su servidor, tal como llega en el META.
#define CM_LINK_UNKNOWN  (-1)
#define CM_LINK_DOWN     0
#define CM_LINK_UP       1

// Limite de SendNotification. El respaldo push no sustituye al aviso
// completo: solo tiene que bastar para mirar el terminal.
#define CM_PUSH_MAX_CHARS      200

// Un comentario mas largo no sobrevive al terminal, asi que una copia creada
// con el nunca volveria a reconocerse como propia.
#define CM_COMMENT_MAX_LEN     31

// Longitud maxima del identificador de canal. No es un ajuste: forma parte del
// contrato compartido con el Master y los dos EAs deben declarar el mismo
// valor, asi que se queda como constante.
#define CM_CHANNEL_MAX_LEN     32

// Margen con el que dos costes de emparejamiento se consideran el mismo. Solo
// absorbe el ruido de coma flotante. Si dos candidatas quedan dentro del
// margen, no existe una identidad suficiente y el enlace se rechaza.
#define CM_MATCH_EPS           1e-6

bool g_busy=false;
AlertState g_alerts[];
Candidate g_candidates[];
Blocked g_create_blocked[];
bool    g_create_blocks_dirty=false;

// Posiciones Slave de este owner que no corresponden a ninguna posicion
// Master. CheckOpen las deja aqui y CheckPending las consulta: una de ellas
// puede ser la copia de una pendiente Master que se activo antes de tiempo.
PosRec g_unpaired_pos[];

// Configuracion resuelta una sola vez: los parametros input no cambian durante
// la ejecucion, y reparsearlos dentro de los bucles de emparejamiento costaba
// un split de cadena por simbolo y por ciclo.
Owner        g_owners[];
SymbolMapRec g_symbol_maps[];
IgnoreRec    g_ignored[];
string       g_ignored_comments[];
string       g_include_symbols[];
string       g_exclude_symbols[];
SymbolTolRec g_symbol_tols[];
// Cuentas Master esperadas, posicional con g_owners. Cero = sin comprobacion.
long         g_expected_accounts[];

// Estado vivo por canal, en el mismo orden que g_owners.
ChannelState g_channel_state[];

// Conexion del propio terminal Slave. Desconectado, PositionsTotal() devuelve
// la foto cacheada: comparar contra ella es comparar contra el pasado.
datetime g_slave_offline_since=0;
bool     g_slave_link_down=false;
datetime g_slave_trusted_since=0;

// Latido: proximo instante en que toca confirmar que el monitor sigue vivo.
datetime g_next_heartbeat=0;
// El aviso de arranque se envia en el primer ciclo, cuando ya hay snapshots
// que resumir.
bool     g_send_startup=false;

// El bloqueo de instancia se adquiere con compare-and-set. Solo quien conserva
// este token puede refrescarlo o liberarlo; un OnInit fallido nunca borra el de
// otra instancia.
double   g_instance_lock_token=0.0;
bool     g_instance_lock_owned=false;
int      g_instance_file_lock=INVALID_HANDLE;
bool     g_instance_state_loaded=false;

// Telegram: cola de reintento y ultimo error visible en el panel.
string   g_tg_queue[];
string   g_tg_last_error="";
int      g_tg_dropped=0;
// Backoff: momento a partir del cual se puede volver a intentar un envio y
// racha de fallos consecutivos que determina cuanto se espera.
datetime g_tg_next_try=0;
int      g_tg_fail_streak=0;
// Descartes ya contados al usuario y ultimo push de descarte, para que una
// tormenta no genere una notificacion por mensaje perdido.
int      g_tg_dropped_seen=0;
datetime g_tg_drop_push=0;
bool     g_tg_queue_dirty=false;

// El conjunto de avisos activos cambio y hay que volcarlo a disco. Solo se
// marca al entrar o salir un aviso, no al refrescar su marca de tiempo: de lo
// contrario se reescribiria el fichero en cada ciclo.
bool     g_alerts_dirty=false;

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

bool InstanceIdValid(const string id)
{
   int len=StringLen(id);
   if(len<1 || len>CM_CHANNEL_MAX_LEN) return false;

   for(int i=0;i<len;i++)
   {
      ushort c=StringGetCharacter(id,i);
      bool ok=(c>='A' && c<='Z') || (c>='a' && c<='z') ||
              (c>='0' && c<='9') || c=='_' || c=='-';
      if(!ok) return false;
   }
   return true;
}

bool AutomaticCorrectionsEnabled()
{
   return InpAutoFixPositionSLTP || InpAutoFixPendingSLTP ||
          InpAutoCreateMissingPending || InpAutoModifyPending ||
          InpAutoDeleteExtraPending;
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
// Cabecera de los avisos que no hablan de un canal concreto -el propio
// terminal Slave, el latido, los avisos perdidos-. No hay cuenta Master que
// identificar, asi que no se inventa ninguna.
string LocalHeader(const string level)
{
   return level+"\n\n"+
          "DETECTADO: "+TimeToString(TimeLocal(),TIME_DATE|TIME_SECONDS)+"\n"+
          "PORTAFOLIO ALIAS: "+InpPortfolioAlias+"\n"+
          "ID SLAVE: "+AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN))+"\n"+
          "BROKER SLAVE: "+BrokerText(AccountInfoString(ACCOUNT_COMPANY));
}
// Pie comun de los avisos de posiciones: el Slave nunca abre ni cierra una
// posicion, asi que todos piden la misma revision manual.
string PositionReviewAction()
{
   return "\n\nACCIÓN:\nRevisar la cuenta Slave "+
          AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN))+"."+
          "\nCopyMonitor no abre ni cierra posiciones automáticamente.";
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
      // Un comentario que el terminal recorta no podria coincidir con ninguna
      // operacion, y una copia creada con el nunca se reconoceria como propia.
      if(StringLen(x.comment)>CM_COMMENT_MAX_LEN)
      {
         PrintFormat("[CM SLAVE] InpSingleSlaveComment supera %d caracteres.",
                     CM_COMMENT_MAX_LEN);
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
      if(StringLen(o[i].comment)>CM_COMMENT_MAX_LEN)
      {
         PrintFormat("[CM SLAVE] El comentario propietario %d supera %d caracteres: %s",
                     i+1,CM_COMMENT_MAX_LEN,o[i].comment);
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

   // Con PREFIX o CONTAINS dos comentarios distintos pueden reclamar la misma
   // operacion, y entonces la propiedad deja de decidirse: se para el arranque
   // en lugar de repartir las copias segun el orden de la lista.
   if(InpOwnerMatchMode!=OWNER_MATCH_EXACT)
      for(int i=0;i<n;i++)
         for(int j=0;j<n;j++)
         {
            if(i==j) continue;
            bool overlaps=(InpOwnerMatchMode==OWNER_MATCH_PREFIX)
               ? (StringFind(o[j].comment,o[i].comment)==0)
               : (StringFind(o[j].comment,o[i].comment)>=0);
            if(overlaps)
            {
               PrintFormat("[CM SLAVE] Con este modo de propiedad el comentario %s "
                           "tambien reclamaria las copias de %s.",
                           o[i].comment,o[j].comment);
               return false;
            }
         }

   return true;
}

// Cuentas Master esperadas, posicionales con los canales. Vacio desactiva la
// comprobacion; una lista parcial no vale, porque el usuario creeria estar
// vigilando lo que no esta.
bool LoadExpectedAccounts()
{
   ArrayResize(g_expected_accounts,ArraySize(g_owners));
   ArrayInitialize(g_expected_accounts,0);

   if(Trim(InpExpectedMasterAccounts)=="")
      return true;

   string list=InpExpectedMasterAccounts;
   StringReplace(list,",",";");

   string tokens[];
   SplitClean(list,';',tokens);

   if(ArraySize(tokens)!=ArraySize(g_owners))
   {
      PrintFormat("[CM SLAVE] InpExpectedMasterAccounts debe tener una cuenta por canal: "
                  "canales=%d cuentas=%d",ArraySize(g_owners),ArraySize(tokens));
      return false;
   }

   for(int i=0;i<ArraySize(tokens);i++)
   {
      for(int k=0;k<StringLen(tokens[i]);k++)
      {
         ushort c=StringGetCharacter(tokens[i],k);
         if(c<'0' || c>'9')
         {
            PrintFormat("[CM SLAVE] Cuenta Master no numerica en la posicion %d: %s",
                        i+1,tokens[i]);
            return false;
         }
      }
      g_expected_accounts[i]=(long)StringToInteger(tokens[i]);
      if(g_expected_accounts[i]<=0)
      {
         PrintFormat("[CM SLAVE] Cuenta Master invalida en la posicion %d: %s",
                     i+1,tokens[i]);
         return false;
      }
   }
   return true;
}

// Sin comentario propietario el modo single-master ve como propias todas las
// operaciones de la cuenta. Sin cuenta esperada, un publicador equivocado con
// el mismo canal tambien podria autorizar cambios. Ambas configuraciones son
// validas para monitorizar, pero no para tocar la cuenta.
bool ValidateAutomationIdentity()
{
   if(!AutomaticCorrectionsEnabled()) return true;

   for(int i=0;i<ArraySize(g_owners);i++)
   {
      if(Trim(g_owners[i].comment)=="")
      {
         PrintFormat("[CM SLAVE] El canal %s necesita comentario propietario para activar correcciones automáticas.",
                     g_owners[i].channel);
         return false;
      }
      if(i>=ArraySize(g_expected_accounts) || g_expected_accounts[i]<=0)
      {
         PrintFormat("[CM SLAVE] El canal %s necesita InpExpectedMasterAccounts para activar correcciones automáticas.",
                     g_owners[i].channel);
         return false;
      }
   }
   return true;
}

// Tolerancias por simbolo: SIMBOLO,entrada,sltp,pendiente. Lo que no aparece
// usa el valor global, asi que la lista solo declara las excepciones.
bool LoadSymbolTolerances()
{
   ArrayResize(g_symbol_tols,0);

   if(Trim(InpSymbolTolerances)=="")
      return true;

   string entries[];
   SplitClean(InpSymbolTolerances,';',entries);

   for(int i=0;i<ArraySize(entries);i++)
   {
      string f[];
      int n=StringSplit(entries[i],',',f);

      if(n!=4)
      {
         PrintFormat("[CM SLAVE] Tolerancia de simbolo invalida: %s "
                     "(formato SIMBOLO,entrada,sltp,pendiente)",entries[i]);
         return false;
      }

      SymbolTolRec rec;
      rec.symbol=Trim(f[0]);
      rec.entry=(int)StringToInteger(Trim(f[1]));
      rec.sltp=(int)StringToInteger(Trim(f[2]));
      rec.pending=(int)StringToInteger(Trim(f[3]));

      if(rec.symbol=="" || rec.entry<0 || rec.sltp<0 || rec.pending<0)
      {
         PrintFormat("[CM SLAVE] Tolerancia de simbolo incompleta o negativa: %s",entries[i]);
         return false;
      }

      for(int j=0;j<ArraySize(g_symbol_tols);j++)
         if(g_symbol_tols[j].symbol==rec.symbol)
         {
            PrintFormat("[CM SLAVE] Tolerancia repetida para %s",rec.symbol);
            return false;
         }

      int z=ArraySize(g_symbol_tols);
      ArrayResize(g_symbol_tols,z+1);
      g_symbol_tols[z]=rec;
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

void LoadDelimitedList(string raw,string &out[])
{
   StringReplace(raw,";",",");
   SplitClean(raw,',',out);
}

// Estado vivo por canal, creado una vez con la configuracion: todas las
// cuentas atras arrancan a cero y se llenan en el primer ciclo.
void BuildChannelState()
{
   ArrayResize(g_channel_state,ArraySize(g_owners));
   for(int i=0;i<ArraySize(g_owners);i++)
   {
      g_channel_state[i].channel=g_owners[i].channel;
      g_channel_state[i].offline_since=0;
      g_channel_state[i].unfresh_since=0;
      g_channel_state[i].trusted_since=0;
      ArrayFree(g_channel_state[i].pending_links);
      g_channel_state[i].last_written=0;
      g_channel_state[i].last_session="";
      g_channel_state[i].actions_since=0;
      g_channel_state[i].actions_count=0;
   }
}
int ChannelStateIndex(const string channel)
{
   for(int i=0;i<ArraySize(g_channel_state);i++)
      if(g_channel_state[i].channel==channel)
         return i;
   return -1;
}

bool BuildConfig()
{
   if(!LoadOwners(g_owners))
      return false;
   if(!LoadSymbolMaps())
      return false;
   if(!LoadIgnoredTickets())
      return false;
   if(!LoadExpectedAccounts())
      return false;
   if(!ValidateAutomationIdentity())
      return false;
   if(!LoadSymbolTolerances())
      return false;
   if(!ValidateSymbolToleranceAliases())
      return false;

   LoadDelimitedList(InpSlaveSymbolsFilter,g_include_symbols);
   LoadDelimitedList(InpSlaveSymbolsIgnore,g_exclude_symbols);
   LoadDelimitedList(InpIgnoreSlaveComments,g_ignored_comments);
   BuildChannelState();
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

bool SlaveCommentIgnored(const string comment)
{
   for(int i=0;i<ArraySize(g_ignored_comments);i++)
      if(comment==g_ignored_comments[i])
         return true;
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
// Respaldo por notificacion push de MetaQuotes. No sustituye al aviso: lo que
// hace es sobrevivir al fallo que deja mudo a Telegram, porque no depende de
// la whitelist de WebRequest. Como el limite es corto, solo viaja la cabecera
// util del mensaje.
void PushFallback(const string text)
{
   if(!InpEnablePushFallback) return;

   string body=text;
   StringReplace(body,"\n"," | ");
   if(StringLen(body)>CM_PUSH_MAX_CHARS)
      body=StringSubstr(body,0,CM_PUSH_MAX_CHARS);

   ResetLastError();
   if(!SendNotification(body))
      PrintFormat("[CM SLAVE] SendNotification fallo. err=%d",GetLastError());
}
// Primeras lineas de un aviso, para el respaldo push y para el log.
string AlertDigest(const string msg)
{
   string lines[];
   int n=StringSplit(msg,'\n',lines);
   string digest="";

   for(int i=0;i<n && StringLen(digest)<CM_PUSH_MAX_CHARS;i++)
   {
      if(lines[i]=="") continue;
      digest+=(digest=="" ? "" : " | ")+lines[i];
   }
   return digest;
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
   int n=StringSplit(msg,'\n',lines);
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
      // Cola llena: se descarta lo mas antiguo y se deja constancia. Lo que
      // se pierde aqui no vuelve, porque AlertOnce, AlertOnChange y los
      // RESUELTO se envian una sola vez, asi que ademas sale por push. Una
      // tormenta no debe producir una notificacion por mensaje perdido.
      if((TimeLocal()-g_tg_drop_push)>=InpMismatchReminderSeconds)
      {
         g_tg_drop_push=TimeLocal();
         PushFallback("COPYMONITOR: aviso descartado por cola llena | "+
                      AlertDigest(g_tg_queue[0]));
      }
      for(int i=0;i<n-1;i++) g_tg_queue[i]=g_tg_queue[i+1];
      ArrayResize(g_tg_queue,n-1);
      g_tg_dropped++;
      n--;
   }

   ArrayResize(g_tg_queue,n+1);
   g_tg_queue[n]=chunk;
   g_tg_queue_dirty=true;
}
// Todo aviso entra en la cola y sale en TgFlush. Publicar en linea ataba la
// duracion del ciclo al tiempo de respuesta de api.telegram.org: con un
// timeout de 5 s y una tormenta de avisos, el monitor tardaba en detectar
// justo cuando mas rapido habia que hacerlo. La cola sigue siendo FIFO
// estricta, asi que el orden ALERTA -> RESUELTO se conserva.
bool Tg(const string msg)
{
   if(!TgConfigured()) return false;

   string chunks[];
   TgSplit(msg,chunks);

   for(int i=0;i<ArraySize(chunks);i++)
      TgEnqueue(chunks[i]);

   // Un CRITICO que no va a salir pronto -porque hay cola o porque el backoff
   // esta en curso- se duplica por push: es el unico canal que no depende de
   // que WebRequest funcione.
   if(StringFind(msg,"CRÍTICO")>=0 &&
      (!TgSendDue() || ArraySize(g_tg_queue)>InpTelegramSendsPerCycle))
      PushFallback(AlertDigest(msg));

   return false;
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
      g_tg_queue_dirty=true;
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
   if(i<0)
   {
      i=ArraySize(g_alerts); ArrayResize(g_alerts,i+1);
      g_alerts[i].key=k; g_alerts[i].active=false; g_alerts[i].last=0;
      g_alerts[i].note="";
   }
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
// Retira sin aviso toda una familia de claves. Solo para cuando el usuario
// desactiva una vigilancia: sin comparacion no puede llegar ningun RESUELTO.
void ClearAlertsWithPrefix(const string prefix)
{
   for(int i=0;i<ArraySize(g_alerts);i++)
   {
      if(!g_alerts[i].active || StringFind(g_alerts[i].key,prefix)!=0) continue;
      g_alerts[i].active=false;
      g_alerts_dirty=true;
   }
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
      g_alerts[i].note="";
   }
   bool first=!g_alerts[i].active;
   if(first) g_alerts_dirty=true;
   g_alerts[i].active=true;
   g_alerts[i].last=TimeLocal();
   if(first) Tg(msg);
}
// Un aviso que no debe repetirse cada ciclo pero si reflejar un cambio de
// situacion: se reenvia solo cuando su contenido deja de ser el mismo. La
// firma no se guarda en disco, asi que tras un reinicio el primer ciclo
// vuelve a contar el panorama actual, que es lo que el usuario necesita.
void AlertOnChange(const string k,const string signature,const string msg)
{
   int i=AlertIndex(k);
   if(i<0)
   {
      i=ArraySize(g_alerts); ArrayResize(g_alerts,i+1);
      g_alerts[i].key=k; g_alerts[i].active=false; g_alerts[i].last=0;
      g_alerts[i].note="";
   }
   bool changed=(!g_alerts[i].active || g_alerts[i].note!=signature);
   if(!g_alerts[i].active) g_alerts_dirty=true;
   g_alerts[i].active=true;
   g_alerts[i].last=TimeLocal();
   g_alerts[i].note=signature;
   if(changed) Tg(msg);
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
string AlertStateTemp()
{
   return "CopyMonitorMulti\\CM_ALERTS_"+SafeFileToken(InpSlaveID)+".tmp";
}
// Solo se guardan los avisos activos: son los unicos que deben sobrevivir a un
// reinicio para que su RESUELTO llegue a emitirse.
void SaveAlertState()
{
   if(!InpPersistAlertState || !g_alerts_dirty) return;

   FolderCreate("CopyMonitorMulti");

   // Se escribe aparte y se renombra sobre el definitivo, igual que el
   // snapshot: truncar el fichero bueno y morir a mitad dejaba un estado de
   // avisos incoherente, y con el los RESUELTO de lo que quedara dentro.
   ResetLastError();
   int h=FileOpen(AlertStateTemp(),FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
   {
      PrintFormat("[CM SLAVE] No se pudo guardar el estado de avisos en %s. err=%d",
                  AlertStateTemp(),GetLastError());
      return;
   }

   for(int i=0;i<ArraySize(g_alerts);i++)
   {
      if(!g_alerts[i].active) continue;
      // Tabulador como separador: las claves llevan '|' pero nunca tabuladores.
      FileWrite(h,StringFormat("%I64d\t%s",(long)g_alerts[i].last,g_alerts[i].key));
   }

   FileFlush(h);
   FileClose(h);

   ResetLastError();
   if(!FileMove(AlertStateTemp(),0,AlertStateFile(),FILE_REWRITE))
   {
      PrintFormat("[CM SLAVE] No se pudo renombrar el estado de avisos. err=%d",
                  GetLastError());
      FileDelete(AlertStateTemp());
      return;
   }

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
      g_alerts[n].note="";
      restored++;
   }

   FileClose(h);

   if(restored>0 || discarded>0)
      PrintFormat("[CM SLAVE] Estado de avisos recuperado: %d activos, %d caducados.",
                  restored,discarded);

   // El fichero en disco ya no refleja lo que hay en memoria si se descarto algo.
   if(discarded>0) g_alerts_dirty=true;
}

string TgQueueFile()
{
   return "CopyMonitorMulti\\CM_TGQUEUE_"+SafeFileToken(InpSlaveID)+".txt";
}
string TgQueueTemp()
{
   return "CopyMonitorMulti\\CM_TGQUEUE_"+SafeFileToken(InpSlaveID)+".tmp";
}
string QueueEncode(string value)
{
   StringReplace(value,"\\","\\\\");
   StringReplace(value,"\r","\\r");
   StringReplace(value,"\n","\\n");
   StringReplace(value,"\t","\\t");
   return value;
}
string QueueDecode(const string value)
{
   string out="";
   for(int i=0;i<StringLen(value);i++)
   {
      ushort c=StringGetCharacter(value,i);
      if(c!='\\' || i+1>=StringLen(value))
      {
         out+=ShortToString(c);
         continue;
      }

      ushort next=StringGetCharacter(value,++i);
      if(next=='n') out+="\n";
      else if(next=='r') out+="\r";
      else if(next=='t') out+="\t";
      else out+=ShortToString(next);
   }
   return out;
}
void SaveTgQueue()
{
   if(!InpPersistAlertState || !g_tg_queue_dirty) return;

   FolderCreate("CopyMonitorMulti");
   int h=FileOpen(TgQueueTemp(),FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
   {
      PrintFormat("[CM SLAVE] No se pudo guardar la cola de Telegram. err=%d",GetLastError());
      return;
   }

   for(int i=0;i<ArraySize(g_tg_queue);i++)
      FileWrite(h,QueueEncode(g_tg_queue[i]));
   FileFlush(h);
   FileClose(h);

   if(!FileMove(TgQueueTemp(),0,TgQueueFile(),FILE_REWRITE))
   {
      PrintFormat("[CM SLAVE] No se pudo publicar la cola de Telegram. err=%d",GetLastError());
      FileDelete(TgQueueTemp());
      return;
   }
   g_tg_queue_dirty=false;
}
void LoadTgQueue()
{
   if(!InpPersistAlertState) return;
   int h=FileOpen(TgQueueFile(),FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h==INVALID_HANDLE) return;

   ArrayResize(g_tg_queue,0);
   while(!FileIsEnding(h))
   {
      string line=FileReadString(h);
      if(line=="") continue;
      if(ArraySize(g_tg_queue)>=InpTelegramQueueMax)
      {
         g_tg_dropped++;
         continue;
      }
      int n=ArraySize(g_tg_queue);
      ArrayResize(g_tg_queue,n+1);
      g_tg_queue[n]=QueueDecode(line);
   }
   FileClose(h);
   g_tg_queue_dirty=(g_tg_dropped>0);
}

string CreateBlocksFile()
{
   return "CopyMonitorMulti\\CM_CREATEBLOCKS_"+SafeFileToken(InpSlaveID)+".txt";
}
string CreateBlocksTemp()
{
   return "CopyMonitorMulti\\CM_CREATEBLOCKS_"+SafeFileToken(InpSlaveID)+".tmp";
}
void SaveCreateBlocks()
{
   // Es estado de seguridad, no una preferencia de avisos: desactivar la
   // persistencia de alertas no puede habilitar un reenvio incierto.
   if(!g_create_blocks_dirty) return;

   FolderCreate("CopyMonitorMulti");
   int h=FileOpen(CreateBlocksTemp(),FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
   {
      PrintFormat("[CM SLAVE] No se pudieron guardar los bloqueos de creación. err=%d",GetLastError());
      return;
   }
   for(int i=0;i<ArraySize(g_create_blocked);i++)
      FileWrite(h,StringFormat("%I64d\t%s",(long)g_create_blocked[i].last_seen,
                              g_create_blocked[i].key));
   FileFlush(h);
   FileClose(h);

   if(!FileMove(CreateBlocksTemp(),0,CreateBlocksFile(),FILE_REWRITE))
   {
      PrintFormat("[CM SLAVE] No se pudieron publicar los bloqueos de creación. err=%d",GetLastError());
      FileDelete(CreateBlocksTemp());
      return;
   }
   g_create_blocks_dirty=false;
}
void LoadCreateBlocks()
{
   int h=FileOpen(CreateBlocksFile(),FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h==INVALID_HANDLE) return;

   ArrayResize(g_create_blocked,0);
   while(!FileIsEnding(h))
   {
      string line=FileReadString(h);
      int tab=StringFind(line,"\t");
      if(tab<=0) continue;
      string key=StringSubstr(line,tab+1);
      if(key=="" || BlockedIndex(key)>=0) continue;
      int n=ArraySize(g_create_blocked);
      ArrayResize(g_create_blocked,n+1);
      g_create_blocked[n].key=key;
      g_create_blocked[n].last_seen=(datetime)StringToInteger(StringSubstr(line,0,tab));
   }
   FileClose(h);
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
   if(token=="4") return 4;
   if(token=="5") return 5;
   return 0;
}

int ReadSnapOnce(const string channel,Snap &s)
{
   s.channel=channel;s.nick="";s.broker="";s.session="";s.account=0;s.written=0;
   s.open_total=0;s.pending_total=0;s.schema=0;s.valid=false;s.fresh=false;
   s.connected=CM_LINK_UNKNOWN;
   ArrayResize(s.pos,0); ArrayResize(s.ord,0);

   int h=FileOpen(SnapFile(channel),FILE_COMMON|FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h==INVALID_HANDLE) return CM_SNAP_MISSING;

   bool meta=false,en=false,malformed=false;
   int phase=0; // 0=META, 1=POS, 2=ORD, 3=END
   int schema=0;
   string meta_channel="";

   while(!FileIsEnding(h))
   {
      string line=FileReadString(h); if(line=="")continue;
      string p[]; int n=StringSplit(line,'|',p); if(n<=0)continue;
      if(p[0]=="META" && n>=8 && !meta && phase==0)
      {
         schema=SnapshotSchema(p[1]);
         if(schema==0)
         {
            FileClose(h);
            s.schema=0;
            return CM_SNAP_SCHEMA;
         }
         // Un META de esquema 4/5 sin sus diez/once campos esta cortado: es
         // una lectura parcial, no un contrato distinto.
         if((schema>=4 && n<10) || (schema>=5 && n<11))
         {
            FileClose(h);
            return CM_SNAP_PARTIAL;
         }
         s.written=(long)StringToInteger(p[2]);meta_channel=p[3];s.nick=p[4];s.account=(long)StringToInteger(p[5]);
         s.open_total=(int)StringToInteger(p[6]);s.pending_total=(int)StringToInteger(p[7]);
         // El broker solo viaja desde el esquema 2; un Master antiguo lo deja vacio.
         s.broker=(n>=9)?p[8]:"";
         // La conexion del Master solo viaja desde el esquema 4. Con un Master
         // anterior queda desconocida y no se puede avisar de lo que no se sabe.
         s.connected=(schema>=4 && n>=10)
            ? ((StringToInteger(p[9])!=0) ? CM_LINK_UP : CM_LINK_DOWN)
            : CM_LINK_UNKNOWN;
         s.session=(schema>=5 && n>=11) ? p[10] : "";
         if(s.written<=0 || meta_channel=="" || s.account<=0 ||
            s.open_total<0 || s.pending_total<0 ||
            (schema>=4 && p[9]!="0" && p[9]!="1") ||
            (schema>=5 && s.session==""))
         {
            malformed=true;
            break;
         }
         s.schema=schema;
         meta=true;
         phase=1;
      }
      else if(p[0]=="POS" && n>=8 && meta && phase<=1)
      {
         PosRec x; x.ticket=(ulong)StringToInteger(p[1]);x.symbol=p[2];x.type=(int)StringToInteger(p[3]);
         x.vol=StringToDouble(p[4]);x.price=StringToDouble(p[5]);x.sl=StringToDouble(p[6]);x.tp=StringToDouble(p[7]);
         if(x.ticket==0 || x.symbol=="" ||
            (x.type!=POSITION_TYPE_BUY && x.type!=POSITION_TYPE_SELL) ||
            x.vol<=0.0 || x.price<=0.0 || x.sl<0.0 || x.tp<0.0)
         {
            malformed=true;
            break;
         }
         AddPos(s.pos,x);
         phase=1;
      }
      else if(p[0]=="ORD" && n>=8 && meta && phase<=2)
      {
         OrdRec x; x.ticket=(ulong)StringToInteger(p[1]);x.symbol=p[2];x.type=(int)StringToInteger(p[3]);
         x.vol=StringToDouble(p[4]);x.price=StringToDouble(p[5]);x.sl=StringToDouble(p[6]);x.tp=StringToDouble(p[7]);
         // El precio stop-limit solo viaja desde el esquema 3.
         x.stoplimit=(n>=9)?StringToDouble(p[8]):0.0;
         if(x.ticket==0 || x.symbol=="" || !IsPending((ENUM_ORDER_TYPE)x.type) ||
            x.vol<=0.0 || x.price<=0.0 || x.sl<0.0 || x.tp<0.0 || x.stoplimit<0.0 ||
            (schema>=3 && IsStopLimitType(x.type) && x.stoplimit<=0.0))
         {
            malformed=true;
            break;
         }
         AddOrd(s.ord,x);
         phase=2;
      }
      else if(p[0]=="END" && n==1 && meta && !en)
      {
         en=true;
         phase=3;
      }
      else
      {
         malformed=true;
         break;
      }
   }
   FileClose(h);

   if(malformed || !meta || !en ||
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
   // El adelanto admitido es configurable: Master y Slave escriben y leen
   // TimeLocal(), asi que una sincronizacion NTP o dos maquinas distintas
   // pueden dejar el snapshot permanentemente "en el futuro" y, con el,
   // la vigilancia parada.
   s.fresh=age>=-(long)InpClockSkewToleranceSeconds && age<=InpSnapshotStaleSeconds;
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
// Comparacion del comentario segun el modo configurado. EXACT es la regla
// historica; los otros dos existen porque hay brokers que anaden o recortan
// texto al activarse una pendiente o tras un cierre parcial, y entonces la
// copia deja de reconocerse como propia.
bool CommentOwnedBy(const string comment,const string owner_comment)
{
   if(InpOwnerMatchMode==OWNER_MATCH_PREFIX)
      return StringFind(comment,owner_comment)==0;
   if(InpOwnerMatchMode==OWNER_MATCH_CONTAINS)
      return StringFind(comment,owner_comment)>=0;
   return comment==owner_comment;
}
bool OwnerCommentMatch(const Owner &o,const string comment)
{
   if(InpMultiMaster) return CommentOwnedBy(comment,o.comment);
   if(o.comment!="") return CommentOwnedBy(comment,o.comment);

   if(o.profile==PROFILE_LUNA && InpLunaRequireComment)
      return StringFind(comment,InpLunaCommentContains)>=0;

   return true;
}
// Avisar de una posicion Slave sin pareja Master. El perfil PORTFOLIO46 lo
// hacia siempre; ahora es un ajuste, porque "el Master cerro y la copia sigue
// abierta" es el problema mas caro y no puede depender del perfil.
bool AlertExtraPositions(const Owner &o)
{
   return InpAlertExtraPositions || o.profile==PROFILE_PORTFOLIO46;
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
      if(SlaveCommentIgnored(c))continue;
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
      string c=OrderGetString(ORDER_COMMENT);
      if(SlaveCommentIgnored(c))continue;
      if(!OwnerCommentMatch(o,c))continue;
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
// Tolerancias efectivas de un simbolo, ya convertidas a distancia de precio.
// Un unico valor en puntos para toda la cuenta es o muchisimo o nada cuando
// conviven oro, indices y divisas, y una tolerancia demasiado estrecha no
// relaja nada: rompe el emparejamiento y convierte una copia correcta en una
// copia faltante permanente.
int SymbolTolIndexExact(const string symbol)
{
   for(int i=0;i<ArraySize(g_symbol_tols);i++)
      if(g_symbol_tols[i].symbol==symbol)
         return i;
   return -1;
}
bool SameSymbolTolerance(const int a,const int b)
{
   return g_symbol_tols[a].entry==g_symbol_tols[b].entry &&
          g_symbol_tols[a].sltp==g_symbol_tols[b].sltp &&
          g_symbol_tols[a].pending==g_symbol_tols[b].pending;
}
// La comparación siempre conoce el nombre Slave. Si la excepción se declaró
// con el nombre Master, se resuelve a través del mismo mapa que usa el matching.
// Una entrada explícita para el símbolo Slave prevalece sobre cualquier alias.
int SymbolTolIndex(const string symbol)
{
   int exact=SymbolTolIndexExact(symbol);
   if(exact>=0)
      return exact;

   for(int i=0;i<ArraySize(g_symbol_maps);i++)
   {
      if(g_symbol_maps[i].slave_symbol!=symbol)
         continue;
      int mapped=SymbolTolIndexExact(g_symbol_maps[i].master_symbol);
      if(mapped>=0)
         return mapped;
   }
   return -1;
}
bool ValidateSymbolToleranceAliases()
{
   for(int i=0;i<ArraySize(g_symbol_maps);i++)
   {
      string slave_symbol=g_symbol_maps[i].slave_symbol;
      if(SymbolTolIndexExact(slave_symbol)>=0)
         continue;

      int selected=-1;
      for(int j=0;j<ArraySize(g_symbol_maps);j++)
      {
         if(g_symbol_maps[j].slave_symbol!=slave_symbol)
            continue;
         int mapped=SymbolTolIndexExact(g_symbol_maps[j].master_symbol);
         if(mapped<0)
            continue;
         if(selected<0)
            selected=mapped;
         else if(!SameSymbolTolerance(selected,mapped))
         {
            PrintFormat("[CM SLAVE] Tolerancias contradictorias para aliases del simbolo Slave %s.",
                        slave_symbol);
            return false;
         }
      }
   }
   return true;
}
double EntryTolPrice(const string symbol)
{
   int i=SymbolTolIndex(symbol);
   int points=(i<0) ? InpEntryPriceTolerancePoints : g_symbol_tols[i].entry;
   return points*PointOf(symbol);
}
double StopTolPrice(const string symbol)
{
   int i=SymbolTolIndex(symbol);
   int points=(i<0) ? InpSLTPTolerancePoints : g_symbol_tols[i].sltp;
   return points*PointOf(symbol);
}
double PendingTolPrice(const string symbol)
{
   int i=SymbolTolIndex(symbol);
   int points=(i<0) ? InpPendingPriceTolerancePoints : g_symbol_tols[i].pending;
   return points*PointOf(symbol);
}
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
// Distancia de congelacion del broker. Dentro de ella un modify o un delete
// se rechazan aunque el precio sea valido. El port MT4 ya lo comprobaba con
// MODE_FREEZELEVEL; sin el equivalente en MT5, lo que el broker iba a
// rechazar de todos modos salia como CRITICO en cada ventana en lugar de
// como BLOQUEADO con su motivo.
double FreezeDistance(const string symbol)
{
   return (double)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL)*PointOf(symbol);
}
bool PendingNotFrozen(const string symbol,const int type,const double price,string &reason)
{
   reason="";

   if(!SymbolIsSynchronized(symbol))
   {
      reason="Los datos del símbolo aún no están sincronizados con el servidor.";
      return false;
   }

   double freeze=FreezeDistance(symbol);
   if(freeze<=0) return true;

   MqlTick tick;
   if(!SymbolInfoTick(symbol,tick) || tick.ask<=0 || tick.bid<=0)
   {
      reason="No hay precios actuales del símbolo en el terminal Slave.";
      return false;
   }

   double reference=IsBuyPendingType(type) ? tick.ask : tick.bid;

   if(MathAbs(price-reference)<freeze)
   {
      reason=StringFormat("La orden está dentro de la distancia de congelación del bróker (%d puntos).",
                          (int)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL));
      return false;
   }
   return true;
}
bool PositionNotFrozen(const string symbol,const int type,
                       const double sl,const double tp,string &reason)
{
   reason="";

   if(!SymbolIsSynchronized(symbol))
   {
      reason="Los datos del símbolo aún no están sincronizados con el servidor.";
      return false;
   }

   double freeze=FreezeDistance(symbol);
   if(freeze<=0) return true;

   MqlTick tick;
   if(!SymbolInfoTick(symbol,tick) || tick.ask<=0 || tick.bid<=0)
   {
      reason="No hay precios actuales del símbolo en el terminal Slave.";
      return false;
   }

   double reference=(type==POSITION_TYPE_BUY) ? tick.bid : tick.ask;

   if((MathAbs(sl)>1e-12 && MathAbs(sl-reference)<freeze) ||
      (MathAbs(tp)>1e-12 && MathAbs(tp-reference)<freeze))
   {
      reason=StringFormat("El nivel queda dentro de la distancia de congelación del bróker (%d puntos).",
                          (int)SymbolInfoInteger(symbol,SYMBOL_TRADE_FREEZE_LEVEL));
      return false;
   }
   return true;
}
// Guarda de escala, no de deslizamiento. Una equivalencia de simbolo que
// apunta a otro instrumento produce diferencias de orden de magnitud, y sin
// esta comprobacion el EA copiaria literalmente un SL de otro mercado sobre
// una cuenta real: la distancia minima del broker no lo detecta porque el
// valor puede ser perfectamente valido en el simbolo equivocado.
bool PriceScaleSane(const string symbol,const double master_price,string &reason)
{
   reason="";

   if(InpMaxPriceDeviationPercent<=0 || master_price<=0)
      return true;

   MqlTick tick;
   if(!SymbolInfoTick(symbol,tick) || tick.ask<=0 || tick.bid<=0)
   {
      reason="No hay precios actuales del símbolo en el terminal Slave.";
      return false;
   }

   double mid=(tick.ask+tick.bid)/2.0;
   if(mid<=0) return true;

   double deviation=MathAbs(master_price-mid)/mid*100.0;

   if(deviation>InpMaxPriceDeviationPercent)
   {
      reason=StringFormat("El precio del Master (%s) se aleja un %.1f%% del precio actual de %s (%s): "
                          "revisar la equivalencia de símbolos.",
                          PriceText(master_price),deviation,symbol,PriceText(mid));
      return false;
   }
   return true;
}
// Cortacircuitos: si la copiadora y el monitor se contradicen, cada uno
// deshaciendo lo que hace el otro, el resultado es un ping-pong de ordenes
// que ninguna cuenta deberia ver. El limite es por canal y por hora.
bool AutoActionAllowed(const string channel,string &reason)
{
   reason="";

   if(InpMaxAutoActionsPerHour<=0)
      return true;

   int i=ChannelStateIndex(channel);
   if(i<0) return true;

   datetime now=TimeLocal();

   if(g_channel_state[i].actions_since==0 ||
      (now-g_channel_state[i].actions_since)>=3600)
   {
      g_channel_state[i].actions_since=now;
      g_channel_state[i].actions_count=0;
   }

   if(g_channel_state[i].actions_count>=InpMaxAutoActionsPerHour)
   {
      reason=StringFormat("Se alcanzó el límite de %d acciones automáticas por hora en este canal. "
                          "Revisar si la copiadora y CopyMonitor se están contradiciendo.",
                          InpMaxAutoActionsPerHour);
      return false;
   }
   return true;
}
void RegisterAutoAction(const string channel)
{
   if(InpMaxAutoActionsPerHour<=0) return;

   int i=ChannelStateIndex(channel);
   if(i<0) return;

   if(g_channel_state[i].actions_since==0)
      g_channel_state[i].actions_since=TimeLocal();
   g_channel_state[i].actions_count++;
}
// Anota la accion que se acaba de enviar y devuelve su resultado sin tocarlo.
// Se cuentan los intentos, no los aciertos: un ping-pong con la copiadora
// falla tanto como acierta, y es justo lo que hay que frenar.
bool RegisterAutoActionAnd(const string channel,const bool result)
{
   RegisterAutoAction(channel);
   return result;
}

void InvalidateChannelTrust(const string channel)
{
   int i=ChannelStateIndex(channel);
   if(i<0) return;
   g_channel_state[i].trusted_since=0;
   ArrayFree(g_channel_state[i].pending_links);
   g_channel_state[i].last_written=0;
   g_channel_state[i].last_session="";
}

void InvalidateAllChannelTrust()
{
   for(int i=0;i<ArraySize(g_channel_state);i++)
   {
      InvalidateChannelTrust(g_channel_state[i].channel);
   }
}

bool ChannelRecoveryConfirmed(const string channel)
{
   int i=ChannelStateIndex(channel);
   if(i<0) return false;

   datetime now=TimeLocal();
   if(g_channel_state[i].trusted_since==0)
      g_channel_state[i].trusted_since=now;

   return (now-g_channel_state[i].trusted_since)>=InpLinkRecoverySeconds;
}

bool ReadTrustedSnapshotNow(const Owner &o,Snap &latest,string &reason)
{
   reason="";
   if(!ReadSnap(o.channel,latest) || latest.status!=CM_SNAP_OK ||
      !latest.valid || !latest.fresh)
   {
      InvalidateChannelTrust(o.channel);
      reason="El snapshot dejó de ser válido o reciente antes de actuar.";
      return false;
   }

   int ci=ChannelStateIndex(o.channel);
   if(ci<0)
   {
      reason="No existe estado interno para el canal.";
      return false;
   }
   if(g_expected_accounts[ci]>0 && latest.account!=g_expected_accounts[ci])
   {
      InvalidateChannelTrust(o.channel);
      reason="La cuenta Master cambió antes de actuar.";
      return false;
   }
   // Las acciones automáticas exigen schema 5: además de confirmar el enlace,
   // la identidad de sesión permite detectar cualquier reinicio del Master.
   // Los esquemas antiguos siguen sirviendo para monitorizar, no para actuar.
   if(latest.session=="")
   {
      InvalidateChannelTrust(o.channel);
      reason="El Master no publica identidad de sesión (schema 5).";
      return false;
   }
   if(latest.connected!=CM_LINK_UP)
   {
      InvalidateChannelTrust(o.channel);
      reason="El Master no confirma una conexión activa con su servidor.";
      return false;
   }

   if(latest.session!=g_channel_state[ci].last_session)
   {
      InvalidateChannelTrust(o.channel);
      reason="El Master se reinició; debe recuperar de nuevo la ventana de confianza.";
      return false;
   }
   if(g_channel_state[ci].trusted_since==0 ||
      (TimeLocal()-g_channel_state[ci].trusted_since)<InpLinkRecoverySeconds)
   {
      reason="El canal aún no ha recuperado la ventana de confianza.";
      return false;
   }
   return true;
}

bool CurrentMasterOrder(const Owner &o,const ulong ticket,OrdRec &order,string &reason)
{
   Snap latest;
   if(!ReadTrustedSnapshotNow(o,latest,reason)) return false;
   TrackChannelSnapshot(o.channel,latest);
   for(int i=0;i<ArraySize(latest.ord);i++)
      if(latest.ord[i].ticket==ticket)
      {
         order=latest.ord[i];
         return true;
      }
   reason="La pendiente Master ya no existe en el snapshot más reciente.";
   return false;
}

bool CurrentMasterPosition(const Owner &o,const ulong ticket,PosRec &position,string &reason)
{
   Snap latest;
   if(!ReadTrustedSnapshotNow(o,latest,reason)) return false;
   TrackChannelSnapshot(o.channel,latest);
   for(int i=0;i<ArraySize(latest.pos);i++)
      if(latest.pos[i].ticket==ticket)
      {
         position=latest.pos[i];
         return true;
      }
   reason="La posición Master ya no existe en el snapshot más reciente.";
   return false;
}

// Refresca el estado del canal con el snapshot recien leido. Schema 5 cambia
// session en cada arranque; written hacia atras queda como fallback de lectura
// para Masters antiguos. Un cambio de fuente invalida los vínculos observados.
void TrackChannelSnapshot(const string channel,const Snap &snap)
{
   int i=ChannelStateIndex(channel);
   if(i<0) return;

   bool restarted=(snap.session!=g_channel_state[i].last_session) ||
                  (snap.session=="" && snap.written<g_channel_state[i].last_written);
   if(restarted)
      InvalidateChannelTrust(channel);

   g_channel_state[i].last_written=snap.written;
   g_channel_state[i].last_session=snap.session;

}
bool SymbolAcceptsNewOrders(const string symbol,const int type,string &reason)
{
   if(!SymbolIsSynchronized(symbol))
   {
      reason="Los datos del símbolo aún no están sincronizados con el servidor.";
      return false;
   }

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
   // Antes que ninguna distancia: que el precio pertenezca a este mercado.
   if(!PriceScaleSane(symbol,price,reason))
      return false;

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

   // Un SL o un TP de otro mercado puede respetar la distancia mínima y aun
   // así ser absurdo en este símbolo: la escala se comprueba primero.
   if(MathAbs(sl)>1e-12 && !PriceScaleSane(symbol,sl,reason))
      return false;
   if(MathAbs(tp)>1e-12 && !PriceScaleSane(symbol,tp,reason))
      return false;

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
bool TradeRetcodeIsMarketClosed(const uint code)
{
   return code==TRADE_RETCODE_MARKET_CLOSED ||
          code==TRADE_RETCODE_TRADE_DISABLED ||
          code==TRADE_RETCODE_PRICE_OFF;
}
// Las sesiones se declaran por día del servidor. Un símbolo sin sesiones
// declaradas se da por abierto y se delega en el retcode del bróker: bloquear
// por una heurística de cotizaciones dejaría sin corregir un instrumento poco
// líquido durante su propia sesión.
bool SymbolSessionOpen(const string symbol)
{
   MqlDateTime st;
   TimeToStruct(TimeTradeServer(),st);

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

//---------------- open matching ----------------
bool PosCompatible(const Owner &o,const PosRec &m,const PosRec &s)
{
   if(!SymbolEq(o.channel,m.symbol,s.symbol))return false;
   if(m.type!=s.type)return false;
   if(!VolEq(s.symbol,s.vol,m.vol*o.mult))return false;
   if(InpMatchEntryPrice && MathAbs(m.price-s.price)>EntryTolPrice(s.symbol))return false;
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

   double tol=StopTolPrice(s.symbol);

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
// Compatibilidad sin mirar el volumen. Existe para diagnosticar, no para
// emparejar de verdad: un cierre parcial en el Master, un llenado parcial de
// la copia o un redondeo distinto del copiador rompen VolEq, y entonces el
// Slave denunciaba "falta la copia de una posición activa" mientras la copia
// estaba delante, con otro tamaño. Lo que el usuario necesita leer es cuál es
// cada volumen.
bool PosCompatibleIgnoringVolume(const Owner &o,const PosRec &m,const PosRec &s)
{
   if(!SymbolEq(o.channel,m.symbol,s.symbol))return false;
   if(m.type!=s.type)return false;
   if(InpMatchEntryPrice && MathAbs(m.price-s.price)>EntryTolPrice(s.symbol))return false;
   return true;
}
// Como MatchPosByPrice, pero sobre las candidatas que solo difieren en el
// volumen. El llamador solo puede aceptar el resultado cuando tied==1: dos
// candidatas igual de buenas siguen sin aportar identidad.
int MatchPosIgnoringVolume(const Owner &o,const PosRec &m,const PosRec &sp[],
                           const bool &su[],int &tied)
{
   int best=-1;
   double cost=1e100;
   tied=0;

   for(int j=0;j<ArraySize(sp);j++)
   {
      if(su[j] || !PosCompatibleIgnoringVolume(o,m,sp[j]))
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
void MarkPosVolumeTies(const Owner &o,const PosRec &m,const PosRec &sp[],
                       const bool &used[],bool &marked[])
{
   double best_cost=1e100;
   for(int j=0;j<ArraySize(sp);j++)
      if(!used[j] && PosCompatibleIgnoringVolume(o,m,sp[j]))
         best_cost=MathMin(best_cost,PosCost(m,sp[j]));
   for(int j=0;j<ArraySize(sp);j++)
      if(!used[j] && PosCompatibleIgnoringVolume(o,m,sp[j]) &&
         PosCost(m,sp[j])<=best_cost+CM_MATCH_EPS)
         marked[j]=true;
}
// La unicidad debe cumplirse en los dos sentidos. Una unica copia compatible
// con dos tickets Master no identifica a ninguno de ellos por el mero hecho de
// que uno tenga el ticket menor. Los niveles solo desempatan si señalan de
// forma unica al Master actual.
bool PosSlaveIdentifiesMaster(const Owner &o,const Snap &snap,const int current,
                              const PosRec &slave,const int &assign[],
                              const bool ignore_volume)
{
   int compatible=0,agreeing=0;
   bool current_agrees=false;
   for(int i=0;i<ArraySize(snap.pos);i++)
   {
      if(i!=current && assign[i]>=0) continue;
      bool fits=ignore_volume
         ? PosCompatibleIgnoringVolume(o,snap.pos[i],slave)
         : PosCompatible(o,snap.pos[i],slave);
      if(!fits) continue;
      compatible++;
      if(PosStopsAgree(snap.pos[i],slave))
      {
         agreeing++;
         if(i==current) current_agrees=true;
      }
   }
   return compatible<=1 || (current_agrees && agreeing==1);
}
long CopiixIndexNumber(const string field)
{
   long value=StringToInteger(field);
   if(value<=0 || IntegerToString(value)!=field)
      return 0;
   return value;
}

bool ReadCopiixPositionLinks(const Snap &snap,CopiixPosLink &links[])
{
   if(snap.schema!=5 || snap.connected!=CM_LINK_UP)
      return false;

   string slave_account=IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN));
   string path="CopyMonitorMulti\\CM_COPIIX_"+snap.channel+"_"+slave_account+".txt";
   // El auxiliar Python publica por reemplazo atomico. SHARE_WRITE evita que
   // esta lectura breve le niegue innecesariamente el acceso al indice; si
   // Windows mantiene ocupado el nombre, el publicador reintenta el rename.
   int file=FileOpen(path,FILE_COMMON|FILE_READ|FILE_TXT|FILE_ANSI|
                     FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(file==INVALID_HANDLE)
      return false;

   string fields[];
   bool valid=false;
   if(FileSize(file)<=200000 && StringSplit(FileReadString(file),'|',fields)==6)
   {
      long written=CopiixIndexNumber(fields[5]);
      long age=(long)TimeGMT()-written;
      valid=fields[0]=="META" && fields[1]=="1" && fields[2]==snap.channel &&
            fields[3]==IntegerToString(snap.account) && fields[4]==slave_account &&
            written>0 && age>=-1 && age<=120;
   }

   ulong slave_tickets[];
   bool complete=false;
   while(valid && !FileIsEnding(file))
   {
      string line=FileReadString(file);
      if(line=="END")
      {
         complete=FileIsEnding(file);
         break;
      }
      int count=ArraySize(links);
      if(count>=4096 || StringSplit(line,'|',fields)!=3 || fields[0]!="POS")
         break;
      ulong master=(ulong)CopiixIndexNumber(fields[1]);
      ulong slave=(ulong)CopiixIndexNumber(fields[2]);
      if(master==0 || slave==0 || (count>0 && links[count-1].master>=master))
         break;
      ArrayResize(links,count+1,128);
      ArrayResize(slave_tickets,count+1,128);
      links[count].master=master;
      links[count].slave=slave;
      slave_tickets[count]=slave;
   }
   FileClose(file);
   if(!complete)
      return false;

   ArraySort(slave_tickets);
   for(int i=1;i<ArraySize(slave_tickets);i++)
      if(slave_tickets[i]==slave_tickets[i-1])
         return false;
   return true;
}

int CopiixPositionCandidate(const Owner &o,const PosRec &master,const PosRec &slaves[],
                            const bool &used[],const CopiixPosLink &links[])
{
   for(int i=0;i<ArraySize(links);i++)
   {
      if(links[i].master!=master.ticket)
         continue;
      for(int j=0;j<ArraySize(slaves);j++)
         if(!used[j] && slaves[j].ticket==links[i].slave && PosCompatible(o,master,slaves[j]))
            return j;
      break;
   }
   return -1;
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

   // Posiciones Master sin copia exacta, resueltas en una segunda pasada.
   bool deferred[];
   ArrayResize(deferred,ArraySize(snap.pos));
   ArrayInitialize(deferred,false);
   CopiixPosLink log_links[];
   bool read_log_links=false;
   bool log_links_valid=false;

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
      if(!PosSlaveIdentifiesMaster(o,snap,i,sp[paired],assign,false))
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

      if(paired>=0 && ignored_tied==1 &&
         !PosSlaveIdentifiesMaster(o,snap,i,sp[paired],assign,false))
         ignored_tied=2;

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
      {
         // El usuario dejó de vigilar este ticket: ningún RESUELTO sería
         // cierto, así que los avisos se retiran en silencio.
         ClearAlert("POSMISS|"+o.channel+"|"+StringFormat("%I64u",snap.pos[i].ticket));
         ClearAlert("POSAMB|"+o.channel+"|"+StringFormat("%I64u",snap.pos[i].ticket));
         continue;
      }

      int best=assign[i];
      int tied=0;
      bool reverse_ambiguous=false;

      if(best<0)
         best=MatchPosByPrice(o,snap.pos[i],sp,su,tied);
      if(best>=0 && tied==1 &&
         !PosSlaveIdentifiesMaster(o,snap,i,sp[best],assign,false))
      {
         tied=2;
         reverse_ambiguous=true;
      }

      // Cada problema de una posición Master lleva su propia clave de aviso.
      // Con una sola clave agrupada por canal el RESUELTO sólo podía salir
      // cuando desaparecían todos los problemas a la vez, así que la copia
      // que llegaba tarde se avisaba y su RESUELTO no se enviaba nunca.
      string pos_suffix=o.channel+"|"+StringFormat("%I64u",snap.pos[i].ticket);
      string miss_key="POSMISS|"+pos_suffix;
      string amb_key="POSAMB|"+pos_suffix;
      string master_line="Ticket Master: "+StringFormat("%I64u",snap.pos[i].ticket);
      string slave_symbol_expected=ExpectedSlaveSymbol(o.channel,snap.pos[i].symbol);

      if(tied>1)
      {
         if(InpUseCopiixLogMatches && !read_log_links)
         {
            read_log_links=true;
            log_links_valid=ReadCopiixPositionLinks(snap,log_links);
         }
         int log_candidate=-1;
         if(log_links_valid)
            log_candidate=CopiixPositionCandidate(o,snap.pos[i],sp,su,log_links);

         string log_detail="";
         if(log_candidate>=0)
            log_detail="\nTicket Slave sugerido por los logs de Copiix: "+
                       StringFormat("%I64u",sp[log_candidate].ticket);

         if(log_candidate>=0 && PosStopsAgree(snap.pos[i],sp[log_candidate]))
            ResolveAlert(amb_key,
               AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
               "\n\nLos logs de Copiix señalan una copia compatible y sus niveles coinciden."+
               "\nSímbolo: "+sp[log_candidate].symbol+"\n"+master_line+log_detail);
         else
            PersistAlert(amb_key,
            AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
            "\n\nPROBLEMA:\nNo se puede enlazar de forma fiable una posición Master con su copia Slave.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Símbolo Master: "+snap.pos[i].symbol+"\n"+
            master_line+"\n"+
            (reverse_ambiguous
               ? "Una misma copia Slave encaja con varios tickets Master libres."
               : "Copias Slave igualmente compatibles: "+IntegerToString(tied))+log_detail+
            "\n\nACCIÓN:\nRevisar manualmente. No se enlaza ninguna copia y no se hará ninguna corrección automática.");
         ResolveAlert(miss_key,
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nYa existen copias compatibles de la posición activa en la cuenta Slave.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Símbolo Master: "+snap.pos[i].symbol+"\n"+
            master_line);
         MarkPosPriceTies(o,snap.pos[i],sp,su,ambiguous_slave);
         continue;
      }

      // Sin copia exacta, la decision se aplaza. Una copia con otro volumen
      // no puede reclamarse hasta que todas las posiciones Master hayan
      // tomado la suya: el recorrido es por ticket, no por prioridad, y
      // reclamarla antes le robaria la copia a la posicion que si encaja.
      if(best<0)
      {
         deferred[i]=true;
         continue;
      }

      su[best]=true;
      assign[i]=best;

      // El volumen vuelve a ser el esperado: si se avisó de lo contrario, eso
      // se cierra aquí, con la misma pareja de tickets con la que se abrió.
      ResolveAlert("POSVOL|"+pos_suffix+"|"+StringFormat("%I64u",sp[best].ticket),
         AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nEl volumen de la copia vuelve a ser el esperado.\n\n"+
         "Estado: POSICIÓN ACTIVA\n"+
         "Símbolo: "+sp[best].symbol+"\n"+
         master_line+"\n"+
         "Ticket Slave: "+StringFormat("%I64u",sp[best].ticket)+"\n"+
         "Volumen Slave: "+VolumeText(sp[best].symbol,sp[best].vol));

      // La copia existe y es la única compatible: eso cierra tanto el aviso
      // de copia faltante como el de enlace ambiguo.
      ResolveAlert(miss_key,
         AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nLa copia de la posición activa ya existe en la cuenta Slave.\n\n"+
         "Estado: POSICIÓN ACTIVA\n"+
         "Tipo: "+PositionTypeText(snap.pos[i].type)+"\n"+
         "Símbolo Master: "+snap.pos[i].symbol+"\n"+
         "Símbolo Slave: "+sp[best].symbol+"\n"+
         master_line+"\n"+
         "Ticket Slave: "+StringFormat("%I64u",sp[best].ticket)+"\n\n"+
         "Volumen Slave: "+VolumeText(sp[best].symbol,sp[best].vol)+"\n"+
         "Precio de entrada: "+PriceText(sp[best].price));
      ResolveAlert(amb_key,
         AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nLa posición Master ya se enlaza con una única copia Slave.\n\n"+
         "Estado: POSICIÓN ACTIVA\n"+
         "Símbolo Master: "+snap.pos[i].symbol+"\n"+
         master_line+"\n"+
         "Ticket Slave: "+StringFormat("%I64u",sp[best].ticket));

      double tol=StopTolPrice(sp[best].symbol);

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
         // Mientras se espera a que abra el mercado no se repite el
         // recordatorio: el aviso BLOQUEADO ya dice que no hay nada que hacer.
         if(MarketWaiting(fix_key))
            KeepAlert(alert_key);
         else
            PersistAlert(alert_key,alert);

         if(InpAutoFixPositionSLTP &&
            ConfirmProblem(fix_key,InpAutoFixPersistSeconds) &&
            MarketWaitDue(fix_key))
         {
            double target_sl=InpCheckStopLoss ? snap.pos[i].sl : sp[best].sl;
            double target_tp=InpCheckTakeProfit ? snap.pos[i].tp : sp[best].tp;
            string blocked_reason="";
            PosRec latest_master_position;

            if(!g_trade_allowed)
            {
               PersistAlert("PBLOCK|"+fix_key,
                  AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+problem_detail+
                  "\n\nACCIÓN:\nNo se puede corregir automáticamente.\n"+g_trade_block_reason);
            }
            else if(!CurrentMasterPosition(o,snap.pos[i].ticket,
                                           latest_master_position,blocked_reason) ||
                    !SameMasterPositionValues(snap.pos[i],latest_master_position))
            {
               if(blocked_reason=="")
                  blocked_reason="La posición Master cambió durante la revalidación; se evaluará de nuevo.";
               PersistAlert("PBLOCK|"+fix_key,
                  AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+problem_detail+
                  "\n\nACCIÓN:\nNo se puede corregir automáticamente.\n"+blocked_reason);
            }
            else if(!SymbolSessionOpen(sp[best].symbol))
            {
               MarketClosedNotice(snap,fix_key,problem_detail,sp[best].symbol);
            }
            else if(!PositionStopsAcceptable(sp[best].symbol,sp[best].type,
                                             target_sl,target_tp,blocked_reason) ||
                    !PositionNotFrozen(sp[best].symbol,sp[best].type,
                                       target_sl,target_tp,blocked_reason) ||
                    !AutoActionAllowed(o.channel,blocked_reason))
            {
               PersistAlert("PBLOCK|"+fix_key,
                  AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+problem_detail+
                  "\n\nACCIÓN:\nNo se puede corregir automáticamente.\n"+blocked_reason);
            }
            else if(RegisterAutoActionAnd(o.channel,
                       FixPositionStops(sp[best].ticket,target_sl,target_tp)))
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
            else if(TradeRetcodeIsMarketClosed(g_trade.ResultRetcode()))
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
            "\nTicket Master: "+StringFormat("%I64u",snap.pos[i].ticket)+
            "\nTicket Slave: "+StringFormat("%I64u",sp[best].ticket));
         ClearAlert("FAIL|"+alert_key);
         ClearAlert("PBLOCK|"+fix_key);
         RemoveProblem(fix_key);
      }
   }


   // Segunda pasada: lo que se quedo sin copia exacta. Se hace cuando todas
   // las posiciones Master ya han tomado la suya, asi que una copia con otro
   // volumen solo se reclama si de verdad no la encaja nadie mas.
   for(int k=0;k<ArraySize(order);k++)
   {
      int i=order[k];
      if(!deferred[i])
         continue;

      string pos_suffix=o.channel+"|"+StringFormat("%I64u",snap.pos[i].ticket);
      string miss_key="POSMISS|"+pos_suffix;
      string amb_key="POSAMB|"+pos_suffix;
      string master_line="Ticket Master: "+StringFormat("%I64u",snap.pos[i].ticket);
      string slave_symbol_expected=ExpectedSlaveSymbol(o.channel,snap.pos[i].symbol);

      int vol_tied=0;
      int vol_match=MatchPosIgnoringVolume(o,snap.pos[i],sp,su,vol_tied);

      if(vol_match>=0 && vol_tied==1 &&
         !PosSlaveIdentifiesMaster(o,snap,i,sp[vol_match],assign,true))
         vol_tied=2;

      if(vol_tied>1)
      {
         PersistAlert(amb_key,
            AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
            "\n\nPROBLEMA:\nNo se puede decidir qué posición Slave corresponde a este ticket Master, ni siquiera ignorando el volumen.\n\n"+
            "Estado: POSICIÓN ACTIVA\nSímbolo Master: "+snap.pos[i].symbol+"\n"+
            master_line+
            "\n\nACCIÓN:\nRevisar manualmente. No se enlaza ni se corrige ninguna candidata.");
         ResolveAlert(miss_key,
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nExisten candidatas Slave, pero el enlace es ambiguo.");
         MarkPosVolumeTies(o,snap.pos[i],sp,su,ambiguous_slave);
         continue;
      }

      if(vol_match>=0 && vol_tied==1)
      {
         double expected_volume=ExpectedSlaveVolume(sp[vol_match].symbol,
                                                    snap.pos[i].vol,o.mult);
         su[vol_match]=true;
         assign[i]=vol_match;

         PersistAlert("POSVOL|"+pos_suffix+"|"+
                      StringFormat("%I64u",sp[vol_match].ticket),
            AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
            "\n\nPROBLEMA:\nLa copia de una posición activa tiene un volumen distinto.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Tipo: "+PositionTypeText(snap.pos[i].type)+"\n"+
            "Símbolo Master: "+snap.pos[i].symbol+"\n"+
            "Símbolo Slave: "+sp[vol_match].symbol+"\n"+
            master_line+"\n"+
            "Ticket Slave: "+StringFormat("%I64u",sp[vol_match].ticket)+"\n\n"+
            "Volumen Master: "+VolumeText(sp[vol_match].symbol,snap.pos[i].vol)+"\n"+
            "Volumen Slave esperado: "+VolumeText(sp[vol_match].symbol,expected_volume)+"\n"+
            "Volumen Slave real: "+VolumeText(sp[vol_match].symbol,sp[vol_match].vol)+"\n"+
            "Precio de entrada Master: "+PriceText(snap.pos[i].price)+"\n"+
            "Precio de entrada Slave: "+PriceText(sp[vol_match].price)+
            PositionReviewAction());

         ResolveAlert(miss_key,
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nLa copia de la posición activa existe; lo que no coincide es el volumen.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Símbolo Master: "+snap.pos[i].symbol+"\n"+
            master_line);
         ResolveAlert(amb_key,
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nLa posición Master ya no presenta un enlace ambiguo.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Símbolo Master: "+snap.pos[i].symbol+"\n"+
            master_line);
         continue;
      }

      string slave_symbol=slave_symbol_expected;
      double expected_volume=ExpectedSlaveVolume(slave_symbol,snap.pos[i].vol,o.mult);
      PersistAlert(miss_key,
         AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
         "\n\nPROBLEMA:\nFalta la copia de una posición activa.\n\n"+
         "Estado: POSICIÓN ACTIVA\n"+
         "Tipo: "+PositionTypeText(snap.pos[i].type)+"\n"+
         "Símbolo Master: "+snap.pos[i].symbol+"\n"+
         "Símbolo esperado Slave: "+slave_symbol+"\n"+
         master_line+"\n\n"+
         "Volumen Master: "+VolumeText(slave_symbol,snap.pos[i].vol)+"\n"+
         "Volumen Slave esperado: "+VolumeText(slave_symbol,expected_volume)+"\n"+
         "Precio de entrada: "+PriceText(snap.pos[i].price)+"\n"+
         "Stop Loss: "+StopText(snap.pos[i].sl,"SIN SL")+"\n"+
         "Take Profit: "+StopText(snap.pos[i].tp,"SIN TP")+
         PositionReviewAction());
      ResolveAlert(amb_key,
         AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nLa posición Master ya no presenta un enlace ambiguo.\n\n"+
         "Estado: POSICIÓN ACTIVA\n"+
         "Símbolo Master: "+snap.pos[i].symbol+"\n"+
         master_line);
      continue;
   }

   ArrayResize(g_unpaired_pos,0);

   // Anything still unused is genuinely unmatched after protecting ignored
   // Master-ticket copies.
   for(int j=0;j<ArraySize(sp);j++)
   {
      string extra_key="POSEXTRA|"+o.channel+"|"+StringFormat("%I64u",sp[j].ticket);
      bool unpaired=(!su[j] && !ambiguous_slave[j]);

      // CheckPending las necesita aunque el perfil no avise de posiciones
      // extra: una de ellas puede ser una pendiente activada antes de tiempo.
      if(unpaired)
      {
         int n=ArraySize(g_unpaired_pos);
         ArrayResize(g_unpaired_pos,n+1);
         g_unpaired_pos[n]=sp[j];
      }

      if(!unpaired || !AlertExtraPositions(o))
      {
         ResolveAlert(extra_key,
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nLa posición activa del Slave ya no sobra.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Tipo: "+PositionTypeText(sp[j].type)+"\n"+
            "Símbolo: "+sp[j].symbol+"\n"+
            "Ticket Slave: "+StringFormat("%I64u",sp[j].ticket));
         continue;
      }

      PersistAlert(extra_key,
         AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
         "\n\nPROBLEMA:\nExiste una posición activa extra en el Slave.\n\n"+
         "Estado: POSICIÓN ACTIVA\n"+
         "Tipo: "+PositionTypeText(sp[j].type)+"\n"+
         "Símbolo: "+sp[j].symbol+"\n"+
         "Ticket Slave: "+StringFormat("%I64u",sp[j].ticket)+"\n"+
         "Volumen Slave: "+VolumeText(sp[j].symbol,sp[j].vol)+"\n"+
         "Precio de entrada: "+PriceText(sp[j].price)+"\n"+
         "Stop Loss: "+StopText(sp[j].sl,"SIN SL")+"\n"+
         "Take Profit: "+StopText(sp[j].tp,"SIN TP")+
         PositionReviewAction());
   }

   // Clave agrupada de las versiones anteriores a la v1.21: se retira en
   // silencio para que un estado persistido no quede activo para siempre.
   ClearAlert("OPEN|"+o.channel);
}

//---------------- pending extra cleanup ----------------
bool OrdCompatible(const Owner &o,const OrdRec &m,const OrdRec &s)
{
   if(!SymbolEq(o.channel,m.symbol,s.symbol))return false;
   if(m.type!=s.type)return false;
   if(!VolEq(s.symbol,s.vol,m.vol*o.mult))return false;
   return true;
}
bool IsSellPendingType(const int t)
{
   return t==ORDER_TYPE_SELL_LIMIT || t==ORDER_TYPE_SELL_STOP ||
          t==ORDER_TYPE_SELL_STOP_LIMIT;
}
// Una copia que se activa antes que su Master deja de ser pendiente en el
// Slave y pasa a ser posicion. El Master sigue publicando la pendiente, asi
// que sin esta comprobacion el Slave la daria por faltante, crearia otra, y
// la nueva podria volver a activarse antes: la operacion se duplicaria sin
// fin. El precio no entra en la comparacion a proposito: una activacion
// llena a precio de mercado y exigir el precio de la pendiente dejaria pasar
// justo el caso que hay que frenar.
bool PendingCouldBePosition(const Owner &o,const OrdRec &m,const PosRec &s,
                            const bool strict_volume)
{
   bool buy=IsBuyPendingType(m.type);
   if(!buy && !IsSellPendingType(m.type)) return false;
   if(s.type!=(buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL)) return false;
   if(!SymbolEq(o.channel,m.symbol,s.symbol)) return false;
   // El volumen deja de exigirse en la segunda pasada: una activacion que se
   // llena parcialmente, o una copia abierta con otro tamaño, sigue siendo
   // esa pendiente ya ejecutada. Bloquear de mas cuesta un aviso; bloquear de
   // menos duplica la operacion.
   if(strict_volume && !VolEq(s.symbol,s.vol,m.vol*o.mult)) return false;
   return true;
}
// Indice en g_unpaired_pos de la posicion Slave que podria ser esta
// pendiente ya activada, o -1. Una posicion que ya corresponde a una
// posicion Master no cuenta: CheckOpen solo deja aqui las que no.
// exact_volume dice si la candidata encontrada coincide ademas en volumen,
// para que el aviso lo pueda contar.
int EarlyActivatedCopy(const Owner &o,const OrdRec &m,bool &exact_volume)
{
   exact_volume=true;

   for(int i=0;i<ArraySize(g_unpaired_pos);i++)
      if(PendingCouldBePosition(o,m,g_unpaired_pos[i],true))
         return i;

   exact_volume=false;

   for(int i=0;i<ArraySize(g_unpaired_pos);i++)
      if(PendingCouldBePosition(o,m,g_unpaired_pos[i],false))
         return i;

   return -1;
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
   double stop_tol=StopTolPrice(s.symbol);
   double price_tol=PendingTolPrice(s.symbol);

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
// Un único Slave también puede ser candidato de varios tickets Master.
int MatchOrdByValues(const Owner &o,const OrdRec &m,const OrdRec &so[],const bool &used[])
{
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
// Compatibilidad sin mirar el volumen. Sin esto, una copia con otro tamaño
// -llenado parcial, redondeo distinto, mínimo del bróker receptor, o un
// copiador que dimensiona por riesgo en vez de por multiplicador fijo- dejaba
// de ser compatible, la orden Master contaba como no emparejada y la creación
// automática añadía una SEGUNDA pendiente mientras la primera seguía viva.
// Dos órdenes donde debía haber una, creadas por el propio monitor.
bool OrdCompatibleIgnoringVolume(const Owner &o,const OrdRec &m,const OrdRec &s)
{
   if(!SymbolEq(o.channel,m.symbol,s.symbol))return false;
   if(m.type!=s.type)return false;
   return true;
}
int MatchOrdIgnoringVolume(const Owner &o,const OrdRec &m,const OrdRec &so[],
                           const bool &used[],int &tied)
{
   int best=-1;
   double best_delta=1e100;
   tied=0;

   for(int s=0;s<ArraySize(so);s++)
   {
      if(used[s] || !OrdCompatibleIgnoringVolume(o,m,so[s]))
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
void MarkOrdVolumeTies(const Owner &o,const OrdRec &m,const OrdRec &so[],
                       const bool &used[],bool &marked[])
{
   double best_delta=1e100;
   for(int s=0;s<ArraySize(so);s++)
      if(!used[s] && OrdCompatibleIgnoringVolume(o,m,so[s]))
         best_delta=MathMin(best_delta,MathAbs(m.price-so[s].price));
   for(int s=0;s<ArraySize(so);s++)
      if(!used[s] && OrdCompatibleIgnoringVolume(o,m,so[s]) &&
         MathAbs(m.price-so[s].price)<=best_delta+CM_MATCH_EPS)
         marked[s]=true;
}
bool OrdSlaveIdentifiesMaster(const Owner &o,const Snap &snap,const int current,
                              const OrdRec &slave,const int &assign[],
                              const bool ignore_volume)
{
   int compatible=0,agreeing=0;
   bool current_agrees=false;
   for(int m=0;m<ArraySize(snap.ord);m++)
   {
      if(m!=current && assign[m]>=0) continue;
      bool fits=ignore_volume
         ? OrdCompatibleIgnoringVolume(o,snap.ord[m],slave)
         : OrdCompatible(o,snap.ord[m],slave);
      if(!fits) continue;
      compatible++;
      if(OrdValuesAgree(snap.ord[m],slave))
      {
         agreeing++;
         if(m==current) current_agrees=true;
      }
   }
   return compatible<=1 || (current_agrees && agreeing==1);
}
void AssignPendingByValues(const Owner &o,const Snap &snap,const int &order[],
                           const OrdRec &slave[],int &assign[],bool &used[])
{
   ArrayResize(assign,ArraySize(snap.ord));
   ArrayInitialize(assign,-1);
   ArrayResize(used,ArraySize(slave));
   ArrayInitialize(used,false);

   for(int k=0;k<ArraySize(order);k++)
   {
      int m=order[k];
      int s=MatchOrdByValues(o,snap.ord[m],slave,used);
      if(s<0 || !OrdSlaveIdentifiesMaster(o,snap,m,slave[s],assign,false))
         continue;

      assign[m]=s;
      used[s]=true;
   }
}
int PendingOrderIndex(const OrdRec &orders[],const ulong ticket)
{
   for(int i=0;i<ArraySize(orders);i++)
      if(orders[i].ticket==ticket)
         return i;
   return -1;
}
int PendingLinkIndex(const PendingLink &links[],const ulong slave_ticket)
{
   for(int i=0;i<ArraySize(links);i++)
      if(links[i].slave==slave_ticket)
         return i;
   return -1;
}
// Para habilitar un borrado posterior, el vínculo debe seguir siendo único
// aun si el copiador usa un volumen distinto en alguna de las órdenes.
bool UniquePendingDeletePair(const Owner &o,const OrdRec &master[],const int m,
                             const OrdRec &slave[],const int s)
{
   if(!OrdCompatible(o,master[m],slave[s]))
      return false;
   for(int i=0;i<ArraySize(master);i++)
      if(i!=m && OrdCompatibleIgnoringVolume(o,master[i],slave[s]))
         return false;
   for(int i=0;i<ArraySize(slave);i++)
      if(i!=s && OrdCompatibleIgnoringVolume(o,master[m],slave[i]))
         return false;
   return true;
}
void RefreshPendingLinks(const Owner &o,const Snap &snap,const OrdRec &so[],
                         const int &assign[],const bool &protected_slave[],
                         const bool &ambiguous_slave[],PendingLink &links[])
{
   for(int i=ArraySize(links)-1;i>=0;i--)
   {
      int s=PendingOrderIndex(so,links[i].slave);
      int m=PendingOrderIndex(snap.ord,links[i].master);
      if(s<0 || ambiguous_slave[s] || (m<0 && protected_slave[s]) ||
         (m>=0 && (assign[m]!=s || !UniquePendingDeletePair(o,snap.ord,m,so,s))))
         ArrayRemove(links,i,1);
      else if(m>=0)
         links[i].absent_since=0;
   }
   for(int m=0;m<ArraySize(assign);m++)
   {
      int s=assign[m];
      if(s<0 || ambiguous_slave[s] || MasterTicketIgnored(o.channel,snap.ord[m].ticket) ||
         PendingLinkIndex(links,so[s].ticket)>=0 ||
         !UniquePendingDeletePair(o,snap.ord,m,so,s))
         continue;

      int i=ArraySize(links);
      if(ArrayResize(links,i+1)!=i+1)
         return;
      links[i].master=snap.ord[m].ticket;
      links[i].slave=so[s].ticket;
      links[i].absent_since=0;
   }
}
string PendingDeleteBlock(const Owner &o,const Snap &snap,const ulong master_ticket,
                          const OrdRec &slave)
{
   if(PendingOrderIndex(snap.ord,master_ticket)>=0)
      return "El ticket Master vinculado sigue pendiente.";

   for(int i=0;i<ArraySize(snap.ord);i++)
      if(OrdCompatibleIgnoringVolume(o,snap.ord[i],slave))
         return "Otra pendiente Master del mismo símbolo equivalente y tipo podría corresponder a esta copia.";
   return "";
}
bool MasterStillAbsentBeforeDelete(const Owner &o,const PendingLink &link,
                                   const OrdRec &slave,string &reason)
{
   Snap latest;
   if(!ReadTrustedSnapshotNow(o,latest,reason))
      return false;
   TrackChannelSnapshot(o.channel,latest);
   reason=PendingDeleteBlock(o,latest,link.master,slave);
   return reason=="";
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
   g_create_blocks_dirty=true;
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
   g_create_blocks_dirty=true;
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
bool TradeRetcodeIndeterminate(const uint code)
{
   return code==TRADE_RETCODE_TIMEOUT ||
          code==TRADE_RETCODE_CONNECTION ||
          code==TRADE_RETCODE_ERROR;
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
   double tol=StopTolPrice(symbol);
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
// Una copia asignada por sus valores a otro ticket Master no cuenta para este
// ticket. Una candidata restante sin enlace inequívoco impide crear otra.
bool ReconcilePendingCreation(const Owner &o,const Snap &snap,const int m,
                              ulong &ticket,string &reason)
{
   ticket=0;
   OrdRec slave[];
   SlaveOrdForOwner(o,slave);
   SortOrdByTicket(slave);
   int order[],assign[];
   bool used[];
   MasterOrdOrder(snap,order);
   AssignPendingByValues(o,snap,order,slave,assign,used);

   if(assign[m]>=0)
   {
      ticket=slave[assign[m]].ticket;
      return true;
   }

   for(int s=0;s<ArraySize(slave);s++)
   {
      if(used[s] || !OrdCompatibleIgnoringVolume(o,snap.ord[m],slave[s]))
         continue;

      reason="Hay una pendiente propia que podría corresponder a este ticket Master. Se requiere un enlace inequívoco.";
      return false;
   }
   return true;
}
bool SameMasterOrderValues(const OrdRec &a,const OrdRec &b)
{
   return a.ticket==b.ticket && a.symbol==b.symbol && a.type==b.type &&
          MathAbs(a.vol-b.vol)<=1e-9 && MathAbs(a.price-b.price)<=1e-9 &&
          MathAbs(a.sl-b.sl)<=1e-9 && MathAbs(a.tp-b.tp)<=1e-9 &&
          MathAbs(a.stoplimit-b.stoplimit)<=1e-9;
}
bool SameMasterPositionValues(const PosRec &a,const PosRec &b)
{
   return a.ticket==b.ticket && a.symbol==b.symbol && a.type==b.type &&
          MathAbs(a.vol-b.vol)<=1e-9 && MathAbs(a.price-b.price)<=1e-9 &&
          MathAbs(a.sl-b.sl)<=1e-9 && MathAbs(a.tp-b.tp)<=1e-9;
}
int CreatePendingCopy(const Owner &o,const OrdRec &requested_master,ulong &created_ticket,string &blocked_reason)
{
   created_ticket=0;
   blocked_reason="";
   OrdRec master;
   if(!CurrentMasterOrder(o,requested_master.ticket,master,blocked_reason))
      return CM_CREATE_BLOCKED;
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

   // Reconciliar contra todo el snapshot actual: otra orden del mismo
   // símbolo, tipo y volumen puede tener su propia copia.
   Snap latest;
   if(!ReadTrustedSnapshotNow(o,latest,blocked_reason))
      return CM_CREATE_BLOCKED;
   int m=PendingOrderIndex(latest.ord,master.ticket);
   if(m<0 || !SameMasterOrderValues(master,latest.ord[m]))
   {
      blocked_reason="La pendiente Master cambió durante la revalidación; se evaluará de nuevo.";
      return CM_CREATE_BLOCKED;
   }
   if(!ReconcilePendingCreation(o,latest,m,created_ticket,blocked_reason))
      return CM_CREATE_BLOCKED;
   if(created_ticket>0)
      return CM_CREATE_PRESENT;

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
   {
      // TIMEOUT/CONNECTION puede significar que el servidor acepto la orden y
      // se perdio la respuesta. Reconciliar primero; si sigue sin saberse, no
      // reintentar automaticamente porque podria duplicarla.
      bool uncertain=TradeRetcodeIndeterminate(g_trade.ResultRetcode()) ||
                     (TradeRequestSucceeded(sent) && created_ticket==0);
      if(ReadTrustedSnapshotNow(o,latest,blocked_reason))
      {
         m=PendingOrderIndex(latest.ord,master.ticket);
         if(m>=0 && SameMasterOrderValues(master,latest.ord[m]) &&
            ReconcilePendingCreation(o,latest,m,created_ticket,blocked_reason) &&
            created_ticket>0)
            return CM_CREATE_DONE;
      }
      if(uncertain)
         return CM_CREATE_UNCERTAIN;

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
bool ModifyPendingCopy(const Owner &o,const OrdRec &master,const ulong slave_ticket,
                       const bool change_price,const bool change_stops)
{
   OrdRec live;
   if(!StillOwnedPending(o,slave_ticket,live)) return false;
   ENUM_ORDER_TYPE_TIME time_type=(ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME);
   datetime expiration=(datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
   double target_price=change_price ? master.price : live.price;
   double target_sl=change_stops ? master.sl : live.sl;
   double target_tp=change_stops ? master.tp : live.tp;
   // El precio stop-limit del Master sólo se conoce desde el esquema 3; con un
   // Master antiguo se conserva el valor de la copia.
   double stoplimit=live.stoplimit;
   if(change_price && IsStopLimitType(live.type) && master.stoplimit>0)
      stoplimit=master.stoplimit;
   ResetLastError();
   bool sent=g_trade.OrderModify(slave_ticket,target_price,target_sl,target_tp,
                                 time_type,expiration,stoplimit);
   if(!TradeRequestSucceeded(sent) || !OrderSelect(slave_ticket)) return false;
   double tol=StopTolPrice(live.symbol);
   return PriceEq(OrderGetDouble(ORDER_PRICE_OPEN),target_price,
                  PendingTolPrice(live.symbol)) &&
          StopEq(OrderGetDouble(ORDER_SL),target_sl,tol) &&
          StopEq(OrderGetDouble(ORDER_TP),target_tp,tol);
}

//---------------- stale alert cleanup ----------------
bool MasterOrderPresent(const Snap &snap,const ulong ticket)
{
   for(int i=0;i<ArraySize(snap.ord);i++)
      if(snap.ord[i].ticket==ticket)
         return true;
   return false;
}
bool MasterPositionPresent(const Snap &snap,const ulong ticket)
{
   for(int i=0;i<ArraySize(snap.pos);i++)
      if(snap.pos[i].ticket==ticket)
         return true;
   return false;
}
void ResolveVanished(const string key,const Snap &snap,const string problem_text)
{
   ResolveAlert(key,
      AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
      "\n\nPROBLEMA RESUELTO:\n"+problem_text);
}
void PruneVanishedCreateBlocks(const Owner &o,const Snap &snap)
{
   for(int i=ArraySize(g_create_blocked)-1;i>=0;i--)
   {
      string fields[];
      if(StringSplit(g_create_blocked[i].key,'|',fields)!=3 ||
         fields[0]!="CREATE" || fields[1]!=o.channel)
         continue;
      ulong ticket=(ulong)StringToInteger(fields[2]);
      if(ticket==0 || !MasterOrderPresent(snap,ticket))
         UnblockCreate(g_create_blocked[i].key);
   }
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
         ClearMarketWait("FIXSLTP|"+f[1]+"|"+f[2]+"|"+f[3]);
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

      // POSVOL|canal|master|slave: se cierra cuando desaparece cualquiera de
      // los dos lados, porque el problema es la pareja, no un ticket suelto.
      if(f[0]=="POSVOL" && n==4 && f[1]==o.channel)
      {
         ulong slave_ticket=(ulong)StringToInteger(f[3]);
         ulong master_ticket=(ulong)StringToInteger(f[2]);
         if(slave_ticket>0 && PositionSelectByTicket(slave_ticket) &&
            master_ticket>0 && MasterPositionPresent(snap,master_ticket)) continue;
         ResolveVanished(key,snap,"La posición con volumen distinto ya no existe en alguna de las dos cuentas."+
                                  "\nTicket Master: "+f[2]+
                                  "\nTicket Slave: "+f[3]);
         continue;
      }

      // PVOL|canal|master|slave: igual que POSVOL, para pendientes.
      if(f[0]=="PVOL" && n==4 && f[1]==o.channel)
      {
         ulong slave_ticket=(ulong)StringToInteger(f[3]);
         ulong master_ticket=(ulong)StringToInteger(f[2]);
         if(slave_ticket>0 && OrderSelect(slave_ticket) &&
            master_ticket>0 && MasterOrderPresent(snap,master_ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente con volumen distinto ya no existe en alguna de las dos cuentas."+
                                  "\nTicket Master: "+f[2]+
                                  "\nTicket Slave: "+f[3]);
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
         ClearMarketWait("FIXPEND|"+f[1]+"|"+f[2]+"|"+f[3]);
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
         ClearMarketWait("DELETE|"+f[1]+"|"+f[2]);
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
         ClearMarketWait("CREATE|"+f[2]+"|"+f[3]);
         RemoveProblem("CREATE|"+f[2]+"|"+f[3]);
         continue;
      }

      // POSMISS|canal|master y POSAMB|canal|master
      if((f[0]=="POSMISS" || f[0]=="POSAMB") && n==3 && f[1]==o.channel)
      {
         ulong ticket=(ulong)StringToInteger(f[2]);
         if(ticket>0 && MasterPositionPresent(snap,ticket)) continue;
         ResolveVanished(key,snap,"La posición Master avisada ya no existe."+
                                  "\nTicket Master: "+f[2]);
         continue;
      }

      // POSEXTRA|canal|slave
      if(f[0]=="POSEXTRA" && n==3 && f[1]==o.channel)
      {
         ulong ticket=(ulong)StringToInteger(f[2]);
         if(ticket>0 && PositionSelectByTicket(ticket)) continue;
         ResolveVanished(key,snap,"La posición activa extra del Slave ya no existe."+
                                  "\nTicket Slave: "+f[2]);
         continue;
      }

      // Avisos de pendientes ligados al ticket Master.
      if((f[0]=="ORDMISS" || f[0]=="PEARLY" || f[0]=="PAMBMASTER") &&
         n==3 && f[1]==o.channel)
      {
         ulong ticket=(ulong)StringToInteger(f[2]);
         if(ticket>0 && MasterOrderPresent(snap,ticket)) continue;
         ResolveVanished(key,snap,"La orden pendiente del Master avisada ya no existe."+
                                  "\nTicket Master: "+f[2]);
         UnblockCreate("CREATE|"+f[1]+"|"+f[2]);
         ClearMarketWait("CREATE|"+f[1]+"|"+f[2]);
         RemoveProblem("CREATE|"+f[1]+"|"+f[2]);
         continue;
      }
   }
   // El bloqueo de seguridad no depende de que la persistencia opcional de
   // avisos este activa: tambien se limpia directamente contra el snapshot.
   PruneVanishedCreateBlocks(o,snap);
}

void CheckPending(const Owner &o,const Snap &snap)
{
   OrdRec so[];
   SlaveOrdForOwner(o,so);
   SortOrdByTicket(so);

   int order[];
   MasterOrdOrder(snap,order);

   int assign[];
   bool slave_protected[];
   AssignPendingByValues(o,snap,order,so,assign,slave_protected);

   bool ambiguous_slave[];
   ArrayResize(ambiguous_slave,ArraySize(so));
   ArrayInitialize(ambiguous_slave,false);

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

      if(best>=0 && ignored_tied==1 &&
         !OrdSlaveIdentifiesMaster(o,snap,m,so[best],assign,false))
         ignored_tied=2;

      if(ignored_tied>1)
         MarkOrdPriceTies(o,snap.ord[m],so,slave_protected,slave_protected);
      else if(best>=0)
      {
         assign[m]=best;
         slave_protected[best]=true;
         RemoveProblem("DELETE|"+o.channel+"|"+StringFormat("%I64u",so[best].ticket));
         ClearMarketWait("DELETE|"+o.channel+"|"+StringFormat("%I64u",so[best].ticket));
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

   // Ordenes Master sin copia exacta, resueltas en una segunda pasada.
   bool deferred[];
   ArrayResize(deferred,ArraySize(snap.ord));
   ArrayInitialize(deferred,false);

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
      bool reverse_ambiguous=false;

      if(best<0)
         best=MatchOrdByPrice(o,snap.ord[m],so,slave_protected,tied);
      if(best>=0 && tied==1 &&
         !OrdSlaveIdentifiesMaster(o,snap,m,so[best],assign,false))
      {
         tied=2;
         reverse_ambiguous=true;
      }

      string ambiguity_key="PAMBMASTER|"+o.channel+"|"+
                           StringFormat("%I64u",snap.ord[m].ticket);

      if(tied>1)
      {
         // Hay copias, pero ninguna identidad permite decidir cual corresponde
         // a este ticket. Se considera presente para no crear un duplicado y no
         // se modifica ninguna de las candidatas.
         master_matched[m]=true;
         string ambiguity=
            "\n\nPROBLEMA:\nNo se puede enlazar de forma fiable una orden pendiente Master con su copia Slave.\n\n"+
            "Estado: ORDEN PENDIENTE\n"+
            "Símbolo Master: "+snap.ord[m].symbol+"\n"+
            "Ticket Master: "+StringFormat("%I64u",snap.ord[m].ticket)+"\n"+
            (reverse_ambiguous
               ? "Una misma copia Slave encaja con varios tickets Master libres."
               : "Copias Slave igualmente compatibles: "+IntegerToString(tied))+
            "\n\nACCIÓN:\nRevisar manualmente. No se enlaza ninguna copia y no se hará ninguna modificación automática.";
         PersistAlert(ambiguity_key,AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+ambiguity);
         MarkOrdPriceTies(o,snap.ord[m],so,slave_protected,ambiguous_slave);
         continue;
      }

      // Sin copia exacta, la decision se aplaza a una segunda pasada: una
      // copia con otro volumen no puede reclamarse hasta que todas las
      // ordenes Master hayan tomado la suya, o se le robaria la copia a la
      // que si encaja. El recorrido es por ticket, no por prioridad.
      if(best<0)
      {
         deferred[m]=true;
         continue;
      }

      if(best>=0)
      {
         assign[m]=best;
         master_matched[m]=true;
         slave_protected[best]=true;

         ResolveAlert(ambiguity_key,
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nSe identificó la copia de la orden pendiente."+
            "\nTicket Master: "+StringFormat("%I64u",snap.ord[m].ticket)+
            "\nTicket Slave: "+StringFormat("%I64u",so[best].ticket));

         // El volumen vuelve a ser el esperado: se cierra con la misma pareja
         // de tickets con la que se abrió el aviso.
         ResolveAlert("PVOL|"+o.channel+"|"+
                      StringFormat("%I64u",snap.ord[m].ticket)+"|"+
                      StringFormat("%I64u",so[best].ticket),
            AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nEl volumen de la orden pendiente copiada vuelve a ser el esperado."+
            "\nTicket Master: "+StringFormat("%I64u",snap.ord[m].ticket)+
            "\nTicket Slave: "+StringFormat("%I64u",so[best].ticket)+
            "\nVolumen Slave: "+VolumeText(so[best].symbol,so[best].vol));
         string matched_create="CREATE|"+o.channel+"|"+StringFormat("%I64u",snap.ord[m].ticket);
         RemoveProblem(matched_create);
         UnblockCreate(matched_create);
         ClearMarketWait(matched_create);
         ClearAlert("FAIL|"+matched_create);
         ClearAlert("PBLOCK|"+matched_create);
         RemoveProblem("DELETE|"+o.channel+"|"+StringFormat("%I64u",so[best].ticket));
         ClearMarketWait("DELETE|"+o.channel+"|"+StringFormat("%I64u",so[best].ticket));
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

         double stop_tol=StopTolPrice(so[best].symbol);
         bool price_bad=!PriceEq(snap.ord[m].price,so[best].price,
                                 PendingTolPrice(so[best].symbol));
         bool sl_bad=InpCheckStopLoss && !StopEq(snap.ord[m].sl,so[best].sl,stop_tol);
         bool tp_bad=InpCheckTakeProfit && !StopEq(snap.ord[m].tp,so[best].tp,stop_tol);
         // El precio límite sólo se compara cuando el Master lo publica.
         bool limit_bad=IsStopLimitType(snap.ord[m].type) && snap.ord[m].stoplimit>0 &&
                        !PriceEq(snap.ord[m].stoplimit,so[best].stoplimit,
                                 PendingTolPrice(so[best].symbol));
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

            bool change_price=InpAutoModifyPending && (price_bad || limit_bad);
            bool change_stops=InpAutoFixPendingSLTP && (sl_bad || tp_bad);
            string pending_action=(change_price || change_stops)
               ? "\n\nACCIÓN:\nEsperando que el problema persista antes de corregir los valores habilitados automáticamente."
               : "\n\nACCIÓN:\nSe ha avisado, pero la corrección automática de los valores afectados está desactivada.";

            if(MarketWaiting(fix_key))
               KeepAlert(alert_key);
            else
               PersistAlert(alert_key,
                  AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+detail+pending_action);

            if((change_price || change_stops) &&
               ConfirmProblem(fix_key,InpAutoFixPersistSeconds) &&
               MarketWaitDue(fix_key))
            {
               string blocked_reason="";
               OrdRec latest_master_order;
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
               else if(!CurrentMasterOrder(o,snap.ord[m].ticket,
                                           latest_master_order,blocked_reason) ||
                       !SameMasterOrderValues(snap.ord[m],latest_master_order))
               {
                  if(blocked_reason=="")
                     blocked_reason="La pendiente Master cambió durante la revalidación; se evaluará de nuevo.";
                  PersistAlert("PBLOCK|"+fix_key,
                     AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
                     "\n\nACCIÓN:\nNo se puede modificar automáticamente.\n"+blocked_reason);
               }
               else if(!SymbolSessionOpen(so[best].symbol))
               {
                  MarketClosedNotice(snap,fix_key,detail,so[best].symbol);
               }
               else if(!PendingPriceAcceptable(so[best].symbol,so[best].type,target_price,
                                               target_sl,target_tp,
                                               IsStopLimitType(so[best].type) ? target_stoplimit : 0.0,
                                               blocked_reason) ||
                       !PendingNotFrozen(so[best].symbol,so[best].type,
                                         so[best].price,blocked_reason) ||
                       !AutoActionAllowed(o.channel,blocked_reason))
               {
                  PersistAlert("PBLOCK|"+fix_key,
                     AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
                     "\n\nACCIÓN:\nNo se puede modificar automáticamente.\n"+blocked_reason);
               }
               else if(RegisterAutoActionAnd(o.channel,
                          ModifyPendingCopy(o,snap.ord[m],so[best].ticket,
                                            change_price,change_stops)))
               {
                  Tg(AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+detail+
                     "\n\nACCIÓN AUTOMÁTICA:\nLos valores habilitados de la orden pendiente se corrigieron correctamente.");
                  ClearAlert(alert_key);
                  ClearAlert("PBLOCK|"+fix_key);
                  ClearMarketWait(fix_key);
                  RemoveProblem(fix_key);
               }
               else if(TradeRetcodeIsMarketClosed(g_trade.ResultRetcode()))
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
               "\nTicket Master: "+StringFormat("%I64u",snap.ord[m].ticket)+
               "\nTicket Slave: "+StringFormat("%I64u",so[best].ticket));
            ClearAlert("FAIL|"+alert_key);
            ClearAlert("PBLOCK|"+fix_key);
            RemoveProblem(fix_key);
         }
      }
   }


   // Segunda pasada: las ordenes Master que se quedaron sin copia exacta.
   // Ahora ya nadie mas puede reclamar una copia, asi que si queda una sola
   // compatible salvo por el volumen, es esta.
   for(int k=0;k<ArraySize(order);k++)
   {
      int m=order[k];
      if(!deferred[m])
         continue;

      int vol_tied=0;
      int vol_match=MatchOrdIgnoringVolume(o,snap.ord[m],so,slave_protected,vol_tied);

      if(vol_match>=0 && vol_tied==1 &&
         !OrdSlaveIdentifiesMaster(o,snap,m,so[vol_match],assign,true))
         vol_tied=2;

      string ambiguity_key="PAMBMASTER|"+o.channel+"|"+
                           StringFormat("%I64u",snap.ord[m].ticket);
      if(vol_tied>1)
      {
         master_matched[m]=true;
         PersistAlert(ambiguity_key,
            AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
            "\n\nPROBLEMA:\nNo se puede decidir qué pendiente Slave corresponde a este ticket Master, ni siquiera ignorando el volumen.\n\n"+
            MasterPendingDetails(o,snap.ord[m])+
            "\n\nACCIÓN:\nNo se crea, modifica ni elimina ninguna candidata.");
         MarkOrdVolumeTies(o,snap.ord[m],so,slave_protected,ambiguous_slave);
         continue;
      }

      if(vol_match>=0 && vol_tied==1)
      {
         string vol_symbol=so[vol_match].symbol;
         double expected_volume=ExpectedSlaveVolume(vol_symbol,snap.ord[m].vol,o.mult);

         master_matched[m]=true;
         slave_protected[vol_match]=true;
         assign[m]=vol_match;
         // PVOL toma el relevo y explica qué copia se encontró.
         ClearAlert(ambiguity_key);

         string vol_create="CREATE|"+o.channel+"|"+StringFormat("%I64u",snap.ord[m].ticket);
         RemoveProblem(vol_create);
         ClearMarketWait(vol_create);

         PersistAlert("PVOL|"+o.channel+"|"+
                      StringFormat("%I64u",snap.ord[m].ticket)+"|"+
                      StringFormat("%I64u",so[vol_match].ticket),
            AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
            "\n\nPROBLEMA:\nLa copia de una orden pendiente tiene un volumen distinto.\n\n"+
            "Estado: ORDEN PENDIENTE\n"+
            "Tipo: "+OrderTypeText(snap.ord[m].type)+"\n"+
            "Símbolo Master: "+snap.ord[m].symbol+"\n"+
            "Símbolo Slave: "+vol_symbol+"\n"+
            "Ticket Master: "+StringFormat("%I64u",snap.ord[m].ticket)+"\n"+
            "Ticket Slave: "+StringFormat("%I64u",so[vol_match].ticket)+"\n\n"+
            "Volumen Master: "+VolumeText(vol_symbol,snap.ord[m].vol)+"\n"+
            "Volumen Slave esperado: "+VolumeText(vol_symbol,expected_volume)+"\n"+
            "Volumen Slave real: "+VolumeText(vol_symbol,so[vol_match].vol)+"\n"+
            "Precio de entrada Master: "+PriceText(snap.ord[m].price)+"\n"+
            "Precio de entrada Slave: "+PriceText(so[vol_match].price)+
            "\n\nACCIÓN:\nRevisar manualmente la orden del Slave."+
            "\nNo se crea otra copia ni se corrigen sus valores: el tamaño no es el pedido"+
            " por el Master y crear una segunda pendiente duplicaría la operación.");

         continue;
      }
      // Si la copia sigue faltando, ORDMISS toma el relevo.
      ClearAlert(ambiguity_key);
   }

   // Missing-pending monitoring, when explicitly enabled, reports actual
   // unmatched orders rather than comparing collection sizes.
   if(InpMonitorPendingOrders && InpExpectPendingCopies)
   {
      int missing_pending=0;

      bool early_blocked[];
      ArrayResize(early_blocked,ArraySize(snap.ord));
      ArrayInitialize(early_blocked,false);

      // Cada orden Master lleva su propia clave de aviso. El aviso agrupado
      // por canal sólo podía resolverse cuando aparecían todas las copias a
      // la vez, así que la que llegaba tarde se avisaba y no se resolvía.
      for(int m=0;m<ArraySize(snap.ord);m++)
      {
         string suffix=o.channel+"|"+StringFormat("%I64u",snap.ord[m].ticket);
         string miss_key="ORDMISS|"+suffix;
         string early_key="PEARLY|"+suffix;

         if(MasterTicketIgnored(o.channel,snap.ord[m].ticket))
         {
            // El usuario dejó de vigilar este ticket: ningún RESUELTO sería
            // cierto, así que el aviso se retira en silencio.
            ClearAlert(miss_key);
            ClearAlert(early_key);
            continue;
         }

         // La ambigüedad evita crear duplicados, pero no demuestra una copia.
         if(master_matched[m] && assign[m]<0)
         {
            ClearAlert(miss_key);
            continue;
         }

         bool early_exact_volume=true;
         int early=(master_matched[m]
                    ? -1
                    : EarlyActivatedCopy(o,snap.ord[m],early_exact_volume));

         if(early<0)
            ResolveAlert(early_key,
               AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
               "\n\nPROBLEMA RESUELTO:\nYa no hay ninguna posición activa del Slave que pueda ser esa orden pendiente activada antes de tiempo.\n\n"+
               MasterPendingDetails(o,snap.ord[m]));

         if(assign[m]>=0)
         {
            ResolveAlert(miss_key,
               AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
               "\n\nPROBLEMA RESUELTO:\nLa copia de la orden pendiente ya existe en la cuenta Slave.\n\n"+
               MasterPendingDetails(o,snap.ord[m])+
               "\nTicket Slave: "+StringFormat("%I64u",so[assign[m]].ticket));
            continue;
         }

         missing_pending++;

         // La copia se activó antes que su Master: ya no es una pendiente,
         // es una posición. Recrearla duplicaría la operación, y la copia
         // nueva podría volver a activarse antes, así indefinidamente.
         if(early>=0)
         {
            early_blocked[m]=true;
            // El candidato de creacion se cancela: cuando el bloqueo se
            // levante, la espera debe empezar de nuevo y no darse por
            // cumplida con el tiempo pasado dentro del bloqueo.
            RemoveProblem("CREATE|"+suffix);
            AlertOnce(early_key,
               AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+
               "\n\nPROBLEMA:\nLa copia de una orden pendiente parece haberse activado antes que el Master.\n\n"+
               MasterPendingDetails(o,snap.ord[m])+
               "\n\nPosición activa del Slave que coincide"+
               (early_exact_volume ? "" : " (con otro volumen)")+":\n"+
               "Tipo: "+PositionTypeText(g_unpaired_pos[early].type)+"\n"+
               "Símbolo: "+g_unpaired_pos[early].symbol+"\n"+
               "Ticket Slave: "+StringFormat("%I64u",g_unpaired_pos[early].ticket)+"\n"+
               "Volumen Slave: "+VolumeText(g_unpaired_pos[early].symbol,g_unpaired_pos[early].vol)+"\n"+
               "Precio de entrada: "+PriceText(g_unpaired_pos[early].price)+
               "\n\nACCIÓN:\nNo se crea ninguna copia mientras esa posición exista:"+
               " volver a crearla duplicaría la operación cada vez que la copia nueva"+
               " se activara antes que el Master."+
               PositionReviewAction());
            KeepAlert(miss_key);
            continue;
         }

         // Mientras se espera a que abra el mercado el recordatorio no aporta
         // nada nuevo: el aviso BLOQUEADO ya dice que no hay nada que hacer.
         if(MarketWaiting("CREATE|"+suffix))
            KeepAlert(miss_key);
         else
         {
            string action=InpAutoCreateMissingPending
               ? "Esperando que el problema persista antes de crear la orden automáticamente."
               : "CopyMonitor tiene desactivada la creación automática de pendientes. Este aviso es informativo.";
            PersistAlert(miss_key,
               AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
               "\n\nPROBLEMA:\nFalta la copia de una orden pendiente.\n\n"+
               MasterPendingDetails(o,snap.ord[m])+
               "\n\nACCIÓN:\n"+action);
         }
      }

      if(missing_pending>0)
      {
         for(int m=0;m<ArraySize(snap.ord);m++)
         {
            if(master_matched[m] || early_blocked[m]) continue;
            string create_key="CREATE|"+o.channel+"|"+
                              StringFormat("%I64u",snap.ord[m].ticket);
            if(!InpAutoCreateMissingPending || IsCreateBlocked(create_key) ||
               !ConfirmProblem(create_key,InpMissingPendingConfirmSeconds) ||
               !MarketWaitDue(create_key))
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

            string create_symbol=ExpectedSlaveSymbol(o.channel,snap.ord[m].symbol);

            if(!SymbolSessionOpen(create_symbol))
            {
               MarketClosedNotice(snap,create_key,detail,create_symbol);
               continue;
            }

            if(!AutoActionAllowed(o.channel,blocked_reason))
            {
               PersistAlert("PBLOCK|"+create_key,
                  AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
                  "\n\nACCIÓN:\nNo se puede crear la copia automáticamente.\n"+blocked_reason);
               continue;
            }

            int created=CreatePendingCopy(o,snap.ord[m],created_ticket,blocked_reason);
            // Un BLOQUEADO no llegó a tocar la cuenta, así que no gasta cupo.
            if(created!=CM_CREATE_BLOCKED && created!=CM_CREATE_PRESENT)
               RegisterAutoAction(o.channel);
            RemoveProblem(create_key);

            if(created==CM_CREATE_DONE)
            {
               Tg(AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+detail+
                  "\nTicket Slave creado: "+StringFormat("%I64u",created_ticket)+
                  "\n\nACCIÓN AUTOMÁTICA:\nLa orden pendiente fue creada correctamente.");
               ClearAlert("FAIL|"+create_key);
               ClearAlert("PBLOCK|"+create_key);
               ClearMarketWait(create_key);
               // El RESUELTO ya salió con el mensaje de la creación.
               ClearAlert("ORDMISS|"+o.channel+"|"+
                          StringFormat("%I64u",snap.ord[m].ticket));
            }
            else if(created==CM_CREATE_PRESENT)
            {
               Tg(AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+detail+
                  "\nTicket Slave encontrado: "+StringFormat("%I64u",created_ticket)+
                  "\n\nACCIÓN AUTOMÁTICA:\nNinguna. La copia apareció durante la revalidación previa al envío.");
               ClearAlert("FAIL|"+create_key);
               ClearAlert("PBLOCK|"+create_key);
               ClearMarketWait(create_key);
               ClearAlert("ORDMISS|"+o.channel+"|"+
                          StringFormat("%I64u",snap.ord[m].ticket));
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
            else if(created==CM_CREATE_UNCERTAIN)
            {
               BlockCreate(create_key);
               PersistAlert("FAIL|"+create_key,
                  AlertHeader(snap,"🔴 COPYMONITOR — CRÍTICO")+detail+
                  "\n\nACCIÓN AUTOMÁTICA:\nEl servidor no confirmó si la orden fue aceptada."+
                  "\nLa creación automática queda bloqueada para evitar una copia duplicada."+
                  "\nRevisar manualmente las órdenes de la cuenta Slave."+
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
            else if(TradeRetcodeIsMarketClosed(g_trade.ResultRetcode()))
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
      }

      // Clave agrupada de las versiones anteriores a la v1.21: se retira en
      // silencio para que un estado persistido no quede activo para siempre.
      ClearAlert("PMISS|"+o.channel);
   }
   else
   {
      // Vigilancia desactivada: un aviso por ticket que siguiera activo no
      // podría resolverse nunca, porque ya no hay comparación que lo cierre.
      ClearAlertsWithPrefix("ORDMISS|"+o.channel+"|");
      ClearAlert("PMISS|"+o.channel);
   }

   int ci=ChannelStateIndex(o.channel);
   if(ci<0 || g_channel_state[ci].last_session!=snap.session ||
      g_channel_state[ci].trusted_since==0)
      return;
   if(snap.session!="")
      RefreshPendingLinks(o,snap,so,assign,slave_protected,ambiguous_slave,
                          g_channel_state[ci].pending_links);

   // Extra Slave pending cleanup.
   for(int s=0;s<ArraySize(so);s++)
   {
      if(slave_protected[s] || ambiguous_slave[s])
         continue;

      string ticket=StringFormat("%I64u",so[s].ticket);
      string delete_problem="DELETE|"+o.channel+"|"+ticket;
      string ambiguous_key="PAMB|"+o.channel+"|"+ticket;
      int li=PendingLinkIndex(g_channel_state[ci].pending_links,so[s].ticket);
      string blocked="La copia necesita un vínculo inequívoco observado con su pendiente Master.";
      string master_detail="";
      if(li>=0)
      {
         ulong master_ticket=g_channel_state[ci].pending_links[li].master;
         master_detail="\nTicket Master vinculado: "+StringFormat("%I64u",master_ticket);
         blocked=PendingDeleteBlock(o,snap,master_ticket,so[s]);
         if(blocked!="")
            g_channel_state[ci].pending_links[li].absent_since=0;
         else
         {
            datetime now=TimeLocal();
            if(g_channel_state[ci].pending_links[li].absent_since==0)
               g_channel_state[ci].pending_links[li].absent_since=now;
            int elapsed=(int)(now-g_channel_state[ci].pending_links[li].absent_since);
            if(elapsed<InpEmptyMasterConfirmSeconds)
               blocked="Aún se está confirmando la ausencia de la pendiente Master vinculada.";
         }
      }

      if(blocked!="")
      {
         RemoveProblem(delete_problem);
         ClearMarketWait(delete_problem);
         ClearAlert("PEXTRA|"+o.channel+"|"+ticket);
         ClearAlert("PBLOCK|"+delete_problem);
         PersistAlert(ambiguous_key,
            AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+
            "\n\nPROBLEMA:\nExiste una orden pendiente en el Slave que no se puede emparejar.\n\n"+
            SlavePendingDetails(so[s])+master_detail+
            "\n\nACCIÓN:\n"+blocked);
         continue;
      }

      // PEXTRA toma el relevo del bloqueo hasta que la orden desaparezca.
      ClearAlert(ambiguous_key);

      string key="PEXTRA|"+o.channel+"|"+ticket;
      string detail=
         "\n\nPROBLEMA:\nSe encontró una orden pendiente extra en el Slave.\n\n"+
         SlavePendingDetails(so[s])+master_detail;
      string alert=AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+detail+
         "\n\nACCIÓN:\nEsperando que el problema persista antes de eliminarla automáticamente.";
      if(MarketWaiting(delete_problem))
         KeepAlert(key);
      else
         PersistAlert(key,alert);

      if(!InpAutoDeleteExtraPending)
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

      // Final safety re-check.
      OrdRec live;
      if(!StillOwnedPending(o,so[s].ticket,live) ||
         live.symbol!=so[s].symbol || live.type!=so[s].type)
         continue;

      string delete_blocked="";
      if(!PendingNotFrozen(live.symbol,live.type,live.price,delete_blocked) ||
         !AutoActionAllowed(o.channel,delete_blocked))
      {
         PersistAlert("PBLOCK|"+delete_problem,
            AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
            "\n\nACCIÓN:\nNo se puede eliminar automáticamente.\n"+delete_blocked);
         continue;
      }

      PendingLink link=g_channel_state[ci].pending_links[li];
      if(!MasterStillAbsentBeforeDelete(o,link,live,delete_blocked))
      {
         int current=PendingLinkIndex(g_channel_state[ci].pending_links,live.ticket);
         if(current>=0)
            g_channel_state[ci].pending_links[current].absent_since=0;
         PersistAlert("PBLOCK|"+delete_problem,
            AlertHeader(snap,"🟡 COPYMONITOR — BLOQUEADO")+detail+
            "\n\nACCIÓN:\nNo se puede eliminar automáticamente.\n"+delete_blocked);
         RemoveProblem(delete_problem);
         continue;
      }

      ResetLastError();
      bool ok=RegisterAutoActionAnd(o.channel,
                 TradeRequestSucceeded(g_trade.OrderDelete(so[s].ticket)));

      detail=
         "\n\nPROBLEMA:\nSe encontró una orden pendiente extra en el Slave.\n\n"+
         SlavePendingDetails(live)+master_detail;

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
      else if(TradeRetcodeIsMarketClosed(g_trade.ResultRetcode()))
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

//---------------- count reconciliation ----------------
// Operaciones del terminal Slave que este canal no llega a ver. El EA las
// descarta en silencio al construir sus listas -por filtro de simbolo o
// por comentario de otro duenno-, asi que una diferencia de cantidades
// entre Master y Slave se quedaba sin ninguna explicacion.
bool AnyOwnerMatches(const string comment,const Owner &except)
{
   for(int i=0;i<ArraySize(g_owners);i++)
   {
      if(g_owners[i].channel==except.channel && g_owners[i].comment==except.comment)
         continue;
      if(OwnerCommentMatch(g_owners[i],comment))
         return true;
   }
   return false;
}
// Una operacion de otro canal configurado esta explicada y no cuenta. Solo
// cuentan la que no pertenece a ningun canal conocido y la que es de este
// canal pero con el simbolo fuera del filtro.
void ClassifyHidden(const Owner &o,const string symbol,const string comment,
                    int &filtered,int &unknown)
{
   if(symbol=="") return;
   // La exclusion explicita gana al ownership y al filtro de simbolos: estas
   // operaciones no deben provocar tampoco el aviso agregado COUNT.
   if(SlaveCommentIgnored(comment)) return;
   if(OwnerCommentMatch(o,comment))
   {
      if(!SlaveSymbolAllowed(symbol)) filtered++;
      return;
   }
   if(AnyOwnerMatches(comment,o)) return;
   unknown++;
}
// Una operacion Master cuyo simbolo Slave esta fuera del filtro no puede
// tener copia visible nunca: su aviso de copia faltante no se explica solo.
bool MasterReachable(const Owner &o,const string master_symbol)
{
   return SlaveSymbolAllowed(ExpectedSlaveSymbol(o.channel,master_symbol));
}
string CountLine(const string label,const int value)
{
   return "\n"+label+": "+IntegerToString(value);
}
void CheckCounts(const Owner &o,const Snap &snap)
{
   PosRec sp[]; SlavePosForOwner(o,sp);
   OrdRec so[]; SlaveOrdForOwner(o,so);

   int master_pos_ignored=0,master_ord_ignored=0;
   int master_pos_unreachable=0,master_ord_unreachable=0;

   for(int i=0;i<ArraySize(snap.pos);i++)
   {
      if(MasterTicketIgnored(o.channel,snap.pos[i].ticket)) { master_pos_ignored++; continue; }
      if(!MasterReachable(o,snap.pos[i].symbol)) master_pos_unreachable++;
   }
   for(int i=0;i<ArraySize(snap.ord);i++)
   {
      if(MasterTicketIgnored(o.channel,snap.ord[i].ticket)) { master_ord_ignored++; continue; }
      if(!MasterReachable(o,snap.ord[i].symbol)) master_ord_unreachable++;
   }

   int filtered_pos=0,unknown_pos=0,filtered_ord=0,unknown_ord=0;

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      if(PositionGetTicket(i)==0) continue;
      ClassifyHidden(o,PositionGetString(POSITION_SYMBOL),
                     PositionGetString(POSITION_COMMENT),filtered_pos,unknown_pos);
   }
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(OrderGetTicket(i)==0) continue;
      if(!IsPending((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE))) continue;
      ClassifyHidden(o,OrderGetString(ORDER_SYMBOL),OrderGetString(ORDER_COMMENT),
                     filtered_ord,unknown_ord);
   }

   // Una posicion Slave sin pareja solo entra aqui cuando no genera aviso
   // propio; con InpAlertExtraPositions activo cada una tiene el suyo.
   int silent_extra_pos=(AlertExtraPositions(o) ? 0 : ArraySize(g_unpaired_pos));

   bool unexplained=(filtered_pos>0 || unknown_pos>0 ||
                     filtered_ord>0 || unknown_ord>0 ||
                     master_pos_unreachable>0 || master_ord_unreachable>0 ||
                     silent_extra_pos>0);

   // La firma decide si el aviso se reenvia: mientras los numeros no
   // cambien, el usuario ya sabe lo que hay.
   string signature=
      IntegerToString(ArraySize(snap.pos))+"/"+
      IntegerToString(master_pos_ignored)+"/"+
      IntegerToString(master_pos_unreachable)+"/"+
      IntegerToString(ArraySize(sp))+"/"+
      IntegerToString(filtered_pos)+"/"+
      IntegerToString(silent_extra_pos)+"/"+
      IntegerToString(unknown_pos)+"/"+
      IntegerToString(ArraySize(snap.ord))+"/"+
      IntegerToString(master_ord_ignored)+"/"+
      IntegerToString(master_ord_unreachable)+"/"+
      IntegerToString(ArraySize(so))+"/"+
      IntegerToString(filtered_ord)+"/"+
      IntegerToString(unknown_ord);

   string key="COUNT|"+o.channel;

   if(!unexplained)
   {
      ResolveAlert(key,
         AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nLas cantidades de Master y Slave vuelven a explicarse por completo.");
      return;
   }

   // Sin recordatorio por ciclo, que seria ruido, pero con reenvio cuando
   // los numeros cambian: el panorama de un descuadre no es el mismo aviso.
   AlertOnChange(key,signature,
      AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
      "\n\nPROBLEMA:\nLas cantidades de Master y Slave no cuadran por motivos que no generan aviso propio.\n"+
      CountLine("Posiciones Master",ArraySize(snap.pos))+
      CountLine("  con ticket ignorado",master_pos_ignored)+
      CountLine("  con símbolo Slave filtrado",master_pos_unreachable)+
      CountLine("Posiciones Slave visibles para este canal",ArraySize(sp))+
      CountLine("  de este canal ocultas por el filtro de símbolos",filtered_pos)+
      CountLine("  sin pareja Master y sin aviso propio",silent_extra_pos)+
      CountLine("Posiciones Slave de ningún canal configurado",unknown_pos)+
      "\n"+
      CountLine("Órdenes pendientes Master",ArraySize(snap.ord))+
      CountLine("  con ticket ignorado",master_ord_ignored)+
      CountLine("  con símbolo Slave filtrado",master_ord_unreachable)+
      CountLine("Pendientes Slave visibles para este canal",ArraySize(so))+
      CountLine("  de este canal ocultas por el filtro de símbolos",filtered_ord)+
      CountLine("Pendientes Slave de ningún canal configurado",unknown_ord)+
      "\n\nACCIÓN:\nEsas operaciones quedan fuera de la comparación: CopyMonitor no las"+
      " empareja ni avisa de ellas una a una."+
      "\nRevisar el filtro de símbolos, los comentarios de propiedad y la cuenta Slave "+
      AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN))+".");
}

//---------------- panel/cycle ----------------
void ProcessOwner(const Owner &o,const Snap &s)
{
   // Un esquema desconocido o un canal cruzado significan que el contrato con
   // el Master esta roto: eso se avisa siempre, no depende del interruptor de
   // avisos de snapshot, porque si no el monitor quedaria mudo para siempre.
   if(s.status==CM_SNAP_SCHEMA || s.status==CM_SNAP_CHANNEL)
   {
      InvalidateChannelTrust(o.channel);
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
   // El encabezado puede quedarse sin ID Master si el snapshot sigue sin
   // leerse: lo que importa es que el contrato roto deja de estarlo.
   ResolveAlert("SCHEMA|"+o.channel,
      AlertHeader(s,"🟢 COPYMONITOR — RESUELTO")+
      "\n\nPROBLEMA RESUELTO:\nEl snapshot del Master vuelve a usar un esquema compatible de este canal."+
      "\n\nACCIÓN:\nLa comparación y las correcciones automáticas se reanudan.");

   int ci=ChannelStateIndex(o.channel);
   datetime now=TimeLocal();

   // Una ausencia de datos puede ser transitoria -una lectura que coincide
   // con la reescritura- o puede ser el Master muerto, el VPS reiniciado o el
   // disco lleno. La primera la gobierna InpNotifySnapshotProblems; la
   // segunda se avisa SIEMPRE, porque suspender todas las comparaciones en
   // silencio es exactamente lo contrario de lo que debe hacer un monitor.
   if(!s.valid || !s.fresh)
   {
      InvalidateChannelTrust(o.channel);
      if(ci>=0 && g_channel_state[ci].unfresh_since==0)
         g_channel_state[ci].unfresh_since=now;

      int elapsed=(ci>=0) ? (int)(now-g_channel_state[ci].unfresh_since) : 0;
      bool sustained=(elapsed>=InpStaleAlertSeconds);

      if(InpNotifySnapshotProblems || sustained)
      {
         string msg=AlertHeader(s,"🔴 COPYMONITOR — CRÍTICO")+
            "\n\nPROBLEMA:\nNo se reciben datos válidos y recientes de la cuenta Master."+
            "\nSin datos desde hace "+IntegerToString(elapsed)+" s."+
            "\n\nACCIÓN:\nComprobar que el terminal Master y su EA siguen funcionando."+
            "\nLa comparación y toda corrección automática están suspendidas.";
         PersistAlert("STALE|"+o.channel,msg);
      }
      return;
   }
   if(ci>=0)
      g_channel_state[ci].unfresh_since=0;
   ResolveAlert("STALE|"+o.channel,
      AlertHeader(s,"🟢 COPYMONITOR — RESUELTO")+
      "\n\nPROBLEMA RESUELTO:\nVuelven a recibirse datos válidos y recientes de la cuenta Master."+
      "\n\nACCIÓN:\nLa comparación y el borrado de pendientes se reanudan.");

   // La cuenta que publica el snapshot tiene que ser la que se espera. Sin
   // esto, cambiar el login del terminal Master conservando el canal dejaba
   // al Slave vigilando otra cuenta sin decir una palabra.
   if(ci>=0 && g_expected_accounts[ci]>0 && s.account!=g_expected_accounts[ci])
   {
      InvalidateChannelTrust(o.channel);
      PersistAlert("MACCOUNT|"+o.channel,
         AlertHeader(s,"🔴 COPYMONITOR — CRÍTICO")+
         "\n\nPROBLEMA:\nEl snapshot lo publica una cuenta Master distinta de la esperada."+
         "\nCuenta esperada: "+AccountText(g_expected_accounts[ci])+
         "\nCuenta recibida: "+AccountText(s.account)+
         "\n\nACCIÓN:\nRevisar en qué cuenta está el EA Master de este canal."+
         "\nLa comparación y toda corrección automática están suspendidas.");
      return;
   }
   ResolveAlert("MACCOUNT|"+o.channel,
      AlertHeader(s,"🟢 COPYMONITOR — RESUELTO")+
      "\n\nPROBLEMA RESUELTO:\nEl snapshot vuelve a publicarlo la cuenta Master esperada.");

   // Un Master desconectado de su servidor conserva las colecciones tal como
   // estaban y las sigue publicando cada segundo: el snapshot es fresco, el
   // contenido es pasado. Es el único fallo que se confunde con el
   // funcionamiento normal, así que mientras dure no se compara ni se corrige
   // nada: actuar sobre datos congelados es peor que no actuar.
   if(s.connected==CM_LINK_DOWN)
   {
      InvalidateChannelTrust(o.channel);
      if(ci>=0 && g_channel_state[ci].offline_since==0)
         g_channel_state[ci].offline_since=now;

      int offline=(ci>=0) ? (int)(now-g_channel_state[ci].offline_since) : 0;

      if(offline>=InpMasterOfflineConfirmSeconds)
      {
         PersistAlert("MOFF|"+o.channel,
            AlertHeader(s,"🔴 COPYMONITOR — CRÍTICO")+
            "\n\nPROBLEMA:\nEl terminal Master ha perdido la conexión con su servidor."+
            "\nSin conexión desde hace "+IntegerToString(offline)+" s."+
            "\nEl snapshot sigue llegando, pero su contenido es la última foto"+
            " conocida: las posiciones pueden haber cambiado sin que se vea."+
            "\n\nACCIÓN:\nRevisar el terminal Master."+
            "\nLa comparación y toda corrección automática están suspendidas.");
      }
      // La confirmacion solo evita alertas por microcortes. Desde el primer
      // DOWN conocido no se compara ni se actua sobre colecciones congeladas.
      return;
   }
   else
   {
      if(ci>=0)
         g_channel_state[ci].offline_since=0;

      TrackChannelSnapshot(o.channel,s);

      // Tras una caida, o al arrancar, se exige una ventana corta de datos
      // estables antes de reanudar matching y correcciones.
      if(!ChannelRecoveryConfirmed(o.channel))
         return;

      ResolveAlert("MOFF|"+o.channel,
         AlertHeader(s,"🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nEl terminal Master ha recuperado la conexión con su servidor."+
         "\n\nACCIÓN:\nLa comparación y las correcciones automáticas se reanudan.");
   }

   // La falta de permiso de trading no se avisa por si sola: queda en el panel
   // y se informa como BLOQUEADO sobre el problema concreto que no se pudo
   // corregir. Avisar sin discrepancias convertiria un monitor en modo solo
   // lectura en una fuente de ruido permanente.
   CheckOpen(o,s);
   CheckPending(o,s);
   // Despues de las dos: necesita el emparejamiento ya hecho para saber
   // que parte de la diferencia de cantidades no tiene aviso propio.
   CheckCounts(o,s);
   ResolveVanishedAlerts(o,s);
}
//---------------- instance level checks ----------------
// El propio terminal Slave desconectado devuelve la foto cacheada de sus
// colecciones: comparar contra ella es comparar contra el pasado, y corregir
// sobre ella es actuar a ciegas. Mientras dure, se suspende todo.
// Devuelve true si se puede seguir trabajando.
bool SlaveLinkOk()
{
   if(TerminalInfoInteger(TERMINAL_CONNECTED))
   {
      g_slave_offline_since=0;
      if(g_slave_trusted_since==0)
         g_slave_trusted_since=TimeLocal();

      if((TimeLocal()-g_slave_trusted_since)<InpLinkRecoverySeconds)
         return false;

      if(g_slave_link_down)
      {
         g_slave_link_down=false;
         ResolveAlert("SOFF|"+InpSlaveID,
            LocalHeader("🟢 COPYMONITOR — RESUELTO")+
            "\n\nPROBLEMA RESUELTO:\nEl terminal Slave ha recuperado la conexión con su servidor."+
            "\n\nACCIÓN:\nLa comparación y las correcciones automáticas se reanudan.");
      }
      return true;
   }

   g_slave_trusted_since=0;
   InvalidateAllChannelTrust();

   if(g_slave_offline_since==0)
      g_slave_offline_since=TimeLocal();

   int offline=(int)(TimeLocal()-g_slave_offline_since);

   // Una microdesconexion no genera alerta, pero tampoco autoriza a comparar
   // ni corregir sobre las colecciones cacheadas.
   if(offline<InpSlaveOfflineConfirmSeconds)
      return false;

   g_slave_link_down=true;
   PersistAlert("SOFF|"+InpSlaveID,
      LocalHeader("🔴 COPYMONITOR — CRÍTICO")+
      "\n\nPROBLEMA:\nEl terminal Slave ha perdido la conexión con su servidor."+
      "\nSin conexión desde hace "+IntegerToString(offline)+" s."+
      "\nSus posiciones y órdenes son la última foto conocida."+
      "\n\nACCIÓN:\nRevisar el terminal Slave."+
      "\nLa comparación y toda corrección automática están suspendidas.");
   return false;
}
// Nivel de margen de la cuenta Slave. Una copia que no entra por falta de
// margen se denunciaba como copia faltante, sin decir cuál era el problema.
void CheckMarginLevel()
{
   string key="MARGIN|"+InpSlaveID;

   if(InpMinMarginLevelPercent<=0)
   {
      ClearAlert(key);
      return;
   }

   double used=AccountInfoDouble(ACCOUNT_MARGIN);
   double level=AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);

   // Sin margen ocupado no hay nivel que comparar: no es un problema.
   if(used<=0 || level<=0)
   {
      ResolveAlert(key,
         LocalHeader("🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nEl nivel de margen de la cuenta Slave vuelve a estar por encima del mínimo.");
      return;
   }

   if(level>=InpMinMarginLevelPercent)
   {
      ResolveAlert(key,
         LocalHeader("🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nEl nivel de margen de la cuenta Slave vuelve a estar por encima del mínimo."+
         "\nNivel actual: "+DoubleToString(level,2)+" %");
      return;
   }

   PersistAlert(key,
      LocalHeader("🟠 COPYMONITOR — ALERTA")+
      "\n\nPROBLEMA:\nEl nivel de margen de la cuenta Slave está por debajo del mínimo configurado.\n\n"+
      "Nivel actual: "+DoubleToString(level,2)+" %\n"+
      "Nivel mínimo: "+DoubleToString(InpMinMarginLevelPercent,2)+" %\n"+
      "Margen usado: "+DoubleToString(used,2)+"\n"+
      "Capital: "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2)+
      "\n\nACCIÓN:\nRevisar la exposición de la cuenta Slave."+
      "\nUna copia que no entre por falta de margen se verá como copia faltante.");
}
// Lo que se perdió por cola llena no vuelve: AlertOnce, AlertOnChange y los
// RESUELTO se envían una sola vez. Al menos el usuario tiene que saber que
// hubo avisos que no llegaron.
void CheckDroppedAlerts()
{
   string key="TGDROP|"+InpSlaveID;

   if(g_tg_dropped>g_tg_dropped_seen)
   {
      g_tg_dropped_seen=g_tg_dropped;
      PersistAlert(key,
         LocalHeader("🔴 COPYMONITOR — CRÍTICO")+
         "\n\nPROBLEMA:\nLa cola de Telegram se llenó y hubo avisos que no llegaron."+
         "\nAvisos descartados: "+IntegerToString(g_tg_dropped)+
         "\n\nACCIÓN:\nRevisar el panel del EA y la cuenta Slave: puede haber problemas"+
         " abiertos de los que no se avisó, o resoluciones que no se entregaron.");
      return;
   }

   if(ArraySize(g_tg_queue)==0)
      ResolveAlert(key,
         LocalHeader("🟢 COPYMONITOR — RESUELTO")+
         "\n\nPROBLEMA RESUELTO:\nLa cola de Telegram vuelve a estar vacía y los avisos se entregan."+
         "\nTotal descartado durante el incidente: "+IntegerToString(g_tg_dropped));
}
// Un latido que depende de Telegram no sirve cuando Telegram es justo lo que
// ha fallado: si no está configurado, al menos sale por push.
void TgOrPush(const string msg)
{
   if(TgConfigured())
   {
      Tg(msg);
      return;
   }
   PushFallback(AlertDigest(msg));
}
// Resumen del estado vigilado, para el aviso de arranque y el latido.
string MonitorStateText(const Owner &o[],const Snap &s[])
{
   string text="";

   for(int i=0;i<ArraySize(o);i++)
   {
      PosRec sp[]; SlavePosForOwner(o[i],sp);
      OrdRec sord[]; SlaveOrdForOwner(o[i],sord);

      text+="\nCanal "+o[i].channel+": "+SnapshotStateText(s[i])+
            "\n  Posiciones Master/Slave: "+IntegerToString(s[i].open_total)+
            "/"+IntegerToString(ArraySize(sp))+
            "\n  Pendientes Master/Slave: "+IntegerToString(s[i].pending_total)+
            "/"+IntegerToString(ArraySize(sord))+"\n";
   }
   return text;
}
// El vigilante que debería avisar de que el EA ha muerto es precisamente el
// EA que ha muerto. Un latido periódico es la única forma de que el silencio
// deje de ser ambiguo, y el aviso de arranque es la única forma de saber que
// Telegram funciona antes de que haya un incidente real.
void SendStartupNotice(const Owner &o[],const Snap &s[])
{
   if(!InpSendStartupNotice) return;

   TgOrPush(LocalHeader("🔵 COPYMONITOR — VIGILANCIA ACTIVA")+
      "\n\nCopyMonitor Slave v1.33 ha arrancado y vigila "+
      IntegerToString(ArraySize(o))+" canal(es)."+
      MonitorStateText(o,s)+
      "\nACCIÓN:\nNinguna. Este aviso sólo confirma que el monitor está vivo"+
      " y que puede avisar.");
}
void Heartbeat(const Owner &o[],const Snap &s[])
{
   if(InpHeartbeatHours<=0) return;

   datetime now=TimeLocal();

   if(g_next_heartbeat==0)
   {
      g_next_heartbeat=now+(datetime)InpHeartbeatHours*3600;
      return;
   }
   if(now<g_next_heartbeat) return;

   g_next_heartbeat=now+(datetime)InpHeartbeatHours*3600;

   TgOrPush(LocalHeader("🔵 COPYMONITOR — VIGILANCIA ACTIVA")+
      "\n\nCopyMonitor Slave sigue vigilando."+
      MonitorStateText(o,s)+
      "\nACCIÓN:\nNinguna. Este latido sólo confirma que el monitor está vivo.");
}

string SnapshotStateText(const Snap &s)
{
   if(s.status==CM_SNAP_SCHEMA) return "ESQUEMA INCOMPATIBLE";
   if(s.status==CM_SNAP_CHANNEL) return "CANAL CRUZADO";
   if(!s.valid) return "NO DATA";
   if(!s.fresh) return "STALE";
   if(s.connected==CM_LINK_DOWN) return "MASTER SIN CONEXIÓN";
   return "ONLINE";
}
// Un Master de esquema anterior al 4 no declara su enlace: no se puede
// afirmar ni que lo tenga ni que lo haya perdido.
string MasterLinkText(const Snap &s)
{
   if(s.connected==CM_LINK_UP) return "CONECTADO";
   if(s.connected==CM_LINK_DOWN) return "SIN CONEXIÓN";
   return "NO DISPONIBLE (Master anterior al esquema 4)";
}
int ChannelActionCount(const string channel)
{
   int i=ChannelStateIndex(channel);
   if(i<0) return 0;
   if(g_channel_state[i].actions_since==0 ||
      (TimeLocal()-g_channel_state[i].actions_since)>=3600)
      return 0;
   return g_channel_state[i].actions_count;
}
void Panel(const Owner &o[],const Snap &s[])
{
   if(!InpShowPanel){Comment("");return;}
   string p="COPYMONITOR SLAVE v1.33 MULTI\n";
   p+="MultiMaster: "+(InpMultiMaster?"ON":"OFF")+"\nSlave: "+InpAccountNick+"\n";
   p+="Portafolio: "+InpPortfolioAlias+"\n";
   p+="Broker Slave: "+BrokerText(AccountInfoString(ACCOUNT_COMPANY))+"\n";
   p+="Terminal Slave: "+(TerminalInfoInteger(TERMINAL_CONNECTED)
                          ? "CONECTADO" : "SIN CONEXIÓN")+"\n\n";
   for(int i=0;i<ArraySize(o);i++)
   {
      PosRec sp[];SlavePosForOwner(o[i],sp);
      OrdRec sord[];SlaveOrdForOwner(o[i],sord);
      p+=o[i].channel+" | "+ProfileText(o[i].profile);
      if(InpMultiMaster)p+=" | "+o[i].comment;
      p+=" | "+SnapshotStateText(s[i])+"\n";
      p+="  Broker Master: "+BrokerText(s[i].broker)+"\n";
      p+="  Snapshot schema: "+(s[i].schema>0 ? IntegerToString(s[i].schema) : "-")+"\n";
      p+="  Enlace Master: "+MasterLinkText(s[i])+"\n";
      p+="  Open M/S: "+IntegerToString(s[i].open_total)+"/"+IntegerToString(ArraySize(sp))+"\n";
      p+="  Pending M/S: "+IntegerToString(s[i].pending_total)+"/"+IntegerToString(ArraySize(sord))+"\n";
      p+="  Acciones automáticas esta hora: "+IntegerToString(ChannelActionCount(o[i].channel));
      if(InpMaxAutoActionsPerHour>0)
         p+="/"+IntegerToString(InpMaxAutoActionsPerHour);
      p+="\n";
   }
   p+="\nIgnored MASTER tickets: "+(InpIgnoreMasterTickets=="" ? "NONE" : InpIgnoreMasterTickets)+"\n";
   p+="Ignored SLAVE comments: "+(ArraySize(g_ignored_comments)==0 ? "NONE" : InpIgnoreSlaveComments)+"\n";
   p+="Slave include symbols: "+(ArraySize(g_include_symbols)==0 ? "ALL" : InpSlaveSymbolsFilter)+"\n";
   p+="Slave ignore symbols: "+(ArraySize(g_exclude_symbols)==0 ? "NONE" : InpSlaveSymbolsIgnore)+"\n";
   p+="Open positions: monitor only (SL/TP included)\n";
   p+="Pending copies expected: "+(InpExpectPendingCopies?"YES":"NO")+"\n";
   p+="Extra pending auto-delete: "+(InpAutoDeleteExtraPending?"YES":"NO")+"\n";
   p+="Missing pending auto-create: "+(InpAutoCreateMissingPending?"YES":"NO")+
      " after "+IntegerToString(InpMissingPendingConfirmSeconds)+"s\n";
   p+="Auto corrections: "+(g_trade_allowed ? "READY" : "BLOCKED: "+g_trade_block_reason)+"\n";
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
void Cycle()
{
   if(g_busy)return;

   // Verificar propiedad antes de leer o tocar la cuenta. Si una instancia
   // realmente colgada fue sustituida y luego revive, se retira sin ejecutar
   // un ciclo concurrente.
   if(g_instance_lock_owned && !RefreshInstanceLock())
   {
      Print("[CM SLAVE] Se perdió el bloqueo exclusivo de la instancia. El EA se retira.");
      ExpertRemove();
      return;
   }

   g_busy=true;

   g_trade_allowed=TradingPermitted(g_trade_block_reason);

   // Con el terminal Slave desconectado sus colecciones son una foto vieja:
   // se leen los snapshots para que el panel siga informando, pero no se
   // compara ni se corrige nada contra datos que no son los de ahora.
   bool slave_ok=SlaveLinkOk();

   Snap s[];ArrayResize(s,ArraySize(g_owners));
   for(int i=0;i<ArraySize(g_owners);i++)
   {
      ReadSnap(g_owners[i].channel,s[i]);
      if(slave_ok)
         ProcessOwner(g_owners[i],s[i]);
   }

   if(slave_ok)
      CheckMarginLevel();

   if(g_send_startup)
   {
      SendStartupNotice(g_owners,s);
      g_send_startup=false;
   }
   Heartbeat(g_owners,s);

   PruneState();
   Panel(g_owners,s);
   // Lo que no pudo salir en este ciclo se reintenta sin bloquear el aviso.
   TgFlush();
   // Despues de vaciar: si algo se perdio por cola llena, hay que decirlo.
   CheckDroppedAlerts();
   SaveAlertState();
   SaveTgQueue();
   SaveCreateBlocks();
   // El testigo se refresca cada ciclo: lo que no se refresca esta muerto.
   if(!RefreshInstanceLock())
      Print("[CM SLAVE] No se pudo refrescar el bloqueo exclusivo de la instancia.");

   g_busy=false;
}
// Dos instancias con el mismo InpSlaveID comparten el fichero de estado. El
// lock FILE_COMMON excluye tambien otros terminales MT4/MT5; el token atomico
// evita carreras entre graficos dentro de este terminal.
string InstanceLockName()
{
   return "CM_SLAVE_"+SafeFileToken(InpSlaveID)+"_OWNER";
}
string InstanceHeartbeatName()
{
   return "CM_SLAVE_"+SafeFileToken(InpSlaveID)+"_HEARTBEAT";
}
string InstanceFileLockPath()
{
   return "CopyMonitorMulti\\CM_SLAVE_"+InpSlaveID+".lock";
}
int InstanceLockTTL()
{
   int read_ms=(InpSnapshotReadAttempts-1)*InpSnapshotReadRetryMs*ArraySize(g_owners);
   int network_ms=InpTelegramSendsPerCycle*InpTelegramTimeoutMs;
   int blocking_seconds=(read_ms+network_ms+999)/1000;
   return 3*InpMonitorSeconds+blocking_seconds+10;
}
bool ClaimInstanceLock()
{
   FolderCreate("CopyMonitorMulti",FILE_COMMON);
   g_instance_file_lock=FileOpen(InstanceFileLockPath(),
                                 FILE_COMMON|FILE_READ|FILE_WRITE|FILE_BIN);
   if(g_instance_file_lock==INVALID_HANDLE)
      return false;

   string owner_name=InstanceLockName();
   string heartbeat_name=InstanceHeartbeatName();

   // GlobalVariableTemp crea el cero inicial una sola vez por terminal. El
   // compare-and-set posterior decide atomicamente quien captura el lock.
   GlobalVariableTemp(owner_name);
   GlobalVariableTemp(heartbeat_name);

   double current=GlobalVariableGet(owner_name);
   datetime heartbeat=(datetime)GlobalVariableGet(heartbeat_name);
   if(heartbeat<=0) heartbeat=GlobalVariableTime(owner_name);
   if(current!=0.0 && heartbeat>0 &&
      (TimeLocal()-heartbeat)<=InstanceLockTTL())
   {
      FileClose(g_instance_file_lock);
      g_instance_file_lock=INVALID_HANDLE;
      return false;
   }

   double token=(double)ChartID();
   if(token==0.0) token=(double)GetTickCount()+1.0;

   if(!GlobalVariableSetOnCondition(owner_name,token,current))
   {
      FileClose(g_instance_file_lock);
      g_instance_file_lock=INVALID_HANDLE;
      return false;
   }

   g_instance_lock_token=token;
   g_instance_lock_owned=true;
   GlobalVariableSet(heartbeat_name,(double)TimeLocal());
   return true;
}
bool RefreshInstanceLock()
{
   if(!g_instance_lock_owned) return false;
   if(!GlobalVariableSetOnCondition(InstanceLockName(),
                                    g_instance_lock_token,
                                    g_instance_lock_token))
   {
      g_instance_lock_owned=false;
      return false;
   }
   GlobalVariableSet(InstanceHeartbeatName(),(double)TimeLocal());
   return true;
}
void ReleaseInstanceLock()
{
   if(g_instance_lock_owned &&
      GlobalVariableSetOnCondition(InstanceLockName(),0.0,g_instance_lock_token))
      GlobalVariableSet(InstanceHeartbeatName(),0.0);
   g_instance_lock_owned=false;
   g_instance_lock_token=0.0;
   if(g_instance_file_lock!=INVALID_HANDLE)
   {
      FileClose(g_instance_file_lock);
      g_instance_file_lock=INVALID_HANDLE;
   }
}

bool Validate()
{
   if(!InstanceIdValid(Trim(InpSlaveID)))
   {
      PrintFormat("[CM SLAVE] InpSlaveID debe usar 1-%d caracteres A-Z a-z 0-9 _ -.",
                  CM_CHANNEL_MAX_LEN);
      return false;
   }
   // El emparejamiento supone una copia por posicion Master. En una cuenta de
   // compensacion dos copias del mismo simbolo se funden en una posicion con
   // el volumen sumado, y entonces no hay nada que emparejar: el EA avisaria
   // de copias faltantes y de ambiguedades para siempre.
   if(!InpAllowNettingAccount &&
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
         !=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("[CM SLAVE] La cuenta Slave no es de cobertura: el emparejamiento una copia "
            "por posicion no es valido en compensacion. Use InpAllowNettingAccount "
            "si aun asi quiere arrancar.");
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
      InpExtraPendingConfirmSeconds<0 || InpAutoFixPersistSeconds<0 ||
      InpMissingPendingConfirmSeconds<0)
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
   // Cada envio bloquea hasta InpTelegramTimeoutMs. El tope sube respecto a la
   // v1.17 porque el timeout corto convertia una respuesta lenta en un fallo;
   // con el backoff, un ciclo largo deja de repetirse cada segundo.
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
   // Una ausencia de datos sostenida se avisa siempre, asi que su umbral no
   // puede ser menor que el que declara el snapshot caducado.
   if(InpStaleAlertSeconds<InpSnapshotStaleSeconds)
   {
      Print("[CM SLAVE] InpStaleAlertSeconds no puede ser menor que InpSnapshotStaleSeconds.");
      return false;
   }
   if(InpMasterOfflineConfirmSeconds<0 || InpSlaveOfflineConfirmSeconds<0)
   {
      Print("[CM SLAVE] Los tiempos de confirmacion de desconexion no pueden ser negativos.");
      return false;
   }
   if(InpLinkRecoverySeconds<0 || InpLinkRecoverySeconds>300)
   {
      Print("[CM SLAVE] InpLinkRecoverySeconds debe estar entre 0 y 300.");
      return false;
   }
   if(InpEmptyMasterConfirmSeconds<0)
   {
      Print("[CM SLAVE] InpEmptyMasterConfirmSeconds no puede ser negativo.");
      return false;
   }
   if(InpClockSkewToleranceSeconds<0 || InpClockSkewToleranceSeconds>3600)
   {
      Print("[CM SLAVE] InpClockSkewToleranceSeconds debe estar entre 0 y 3600.");
      return false;
   }
   if(InpMaxAutoActionsPerHour<0)
   {
      Print("[CM SLAVE] InpMaxAutoActionsPerHour no puede ser negativo.");
      return false;
   }
   if(InpMaxPriceDeviationPercent<0)
   {
      Print("[CM SLAVE] InpMaxPriceDeviationPercent no puede ser negativo.");
      return false;
   }
   if(InpMinMarginLevelPercent<0)
   {
      Print("[CM SLAVE] InpMinMarginLevelPercent no puede ser negativo.");
      return false;
   }
   if(InpHeartbeatHours<0 || InpHeartbeatHours>168)
   {
      Print("[CM SLAVE] InpHeartbeatHours debe estar entre 0 y 168.");
      return false;
   }
   // Un latido o un aviso de arranque sin canal de salida no sirven de nada.
   if((InpHeartbeatHours>0 || InpSendStartupNotice) && !TgConfigured() &&
      !InpEnablePushFallback)
   {
      Print("[CM SLAVE] El latido y el aviso de arranque necesitan Telegram o el respaldo push.");
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
   // Dos instancias con el mismo identificador se pisarian el fichero de
   // estado de avisos, y con el los RESUELTO de lo que quedara dentro.
   if(!ClaimInstanceLock())
   {
      PrintFormat("[CM SLAVE] Ya hay una instancia viva con InpSlaveID=%s. "
                  "Use un identificador distinto por grafico.",InpSlaveID);
      return INIT_PARAMETERS_INCORRECT;
   }
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);
   // Antes del primer ciclo: si un problema seguia avisado al apagar, hay que
   // reconocerlo para poder darlo por resuelto en vez de avisarlo de nuevo.
   LoadAlertState();
   LoadTgQueue();
   LoadCreateBlocks();
   g_instance_state_loaded=true;
   // El aviso de arranque sale en el primer ciclo, cuando ya hay snapshots
   // leidos que resumir.
   g_send_startup=InpSendStartupNotice;
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
   // Un OnInit fallido tambien genera OnDeinit. Solo la instancia que adquirio
   // el lock y llego a cargar su estado puede publicar persistencia: una copia
   // rechazada nunca debe vaciar los ficheros de la instancia activa.
   if(g_instance_lock_owned && g_instance_state_loaded)
   {
      g_alerts_dirty=true;
      SaveAlertState();
      g_tg_queue_dirty=true;
      SaveTgQueue();
      g_create_blocks_dirty=true;
      SaveCreateBlocks();
   }
   // El testigo se suelta en el acto: una recompilacion vuelve a OnInit de
   // inmediato y no debe encontrarse a si misma.
   ReleaseInstanceLock();
   g_instance_state_loaded=false;
   Comment("");
}
void OnTimer(){Cycle();}
void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &r,const MqlTradeResult &x)
{
   if(!TransactionMatters(t.type))
      return;
   Cycle();
}
//+------------------------------------------------------------------+
