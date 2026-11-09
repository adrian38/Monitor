//+------------------------------------------------------------------+
//| CopyMonitor_Watchdog_MT4_v1_00.mq4                               |
//| Vigila la conexion del terminal MT4 y avisa por Telegram.        |
//| OFFLINE confirmado: aviso inmediato y recordatorio periodico     |
//| hasta que la conexion vuelve, mas un aviso RESUELTO al volver.   |
//| Nunca opera la cuenta: solo observa y notifica.                  |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#property description "CopyMonitor Watchdog MT4 v1.00"

//--- ===== IDENTIFICACION =====
// Obligatorio: encabeza cada aviso de Telegram, igual que en el Slave MT5.
input string InpPortfolioAlias        = "";
// Opcional: distingue varios terminales que comparten numero de cuenta.
input string InpTerminalAlias         = "";
input bool   InpShowPanel             = true;

//--- ===== VIGILANCIA =====
// Cada cuantos segundos se comprueba la conexion.
input int    InpCheckSeconds          = 5;
// Segundos seguidos sin conexion antes de dar la caida por confirmada.
input int    InpOfflineConfirmSeconds = 60;
// Minutos entre recordatorios mientras el terminal siga offline.
input int    InpOfflineRepeatMinutes  = 5;
// Aviso de arranque: confirma que token y chat ID funcionan.
input bool   InpSendStartupNotice     = true;

//--- ===== TELEGRAM =====
input bool   InpEnableTelegram        = true;
input string InpTelegramBotToken      = "";
input string InpTelegramChatID        = "";
input int    InpTelegramTimeoutMs     = 1200;
input int    InpTelegramChunkChars    = 3000;
input int    InpTelegramQueueMax      = 20;
input int    InpTelegramSendsPerCycle = 2;

#define CM_WD_VERSION        "1.00"
#define CM_WD_KEY_OFFLINE    "OFFLINE"
#define CM_WD_KEY_ONLINE     "ONLINE"
#define CM_WD_KEY_STARTUP    "STARTUP"

// Estado de la vigilancia. Todos los instantes son de reloj local: con el
// terminal desconectado TimeCurrent() se queda congelado en la ultima
// cotizacion y no sirve para medir una caida.
bool     g_online           = true;
datetime g_offline_since    = 0;   // inicio real de la caida confirmada
datetime g_bad_since        = 0;   // primera comprobacion sin conexion
datetime g_last_report      = 0;   // ultimo aviso OFFLINE emitido
int      g_offline_notices  = 0;
bool     g_startup_pending  = false;

// Telegram: cola de reintento acotada y ultimo error visible en el panel.
string   g_tg_queue_text[];
string   g_tg_queue_key[];
int      g_tg_dropped       = 0;
string   g_tg_last_error    = "";

//---------------- utilidades ----------------
string Trim(const string s)
{
   string v=s;
   StringTrimLeft(v);
   StringTrimRight(v);
   return v;
}
string AccountText(const int account)
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
string TimeText(const datetime t)
{
   if(t<=0) return "NO DISPONIBLE";
   return TimeToString(t,TIME_DATE|TIME_SECONDS);
}
// Una caida puede durar horas: se muestra HH:MM:SS acumulando las horas.
string DurationText(const int seconds)
{
   int total=(seconds>0)?seconds:0;
   int hours=total/3600;
   int minutes=(total%3600)/60;
   int rest=total%60;
   return StringFormat("%02d:%02d:%02d",hours,minutes,rest);
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
   // WebRequest no existe en el probador: alli la vigilancia no puede avisar.
   if(IsTesting() || IsOptimization()) return false;
   return InpEnableTelegram && Trim(InpTelegramBotToken)!="" && Trim(InpTelegramChatID)!="";
}
// POST en lugar de GET: el texto viaja en el cuerpo y no depende del limite de
// longitud de una URL.
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
   PrintFormat("[CM WATCHDOG] Telegram fail %s",g_tg_last_error);
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
   int n=StringSplit(msg,(ushort)10,lines);
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
int TgQueueIndex(const string key)
{
   if(key=="") return -1;
   for(int i=0;i<ArraySize(g_tg_queue_key);i++)
      if(g_tg_queue_key[i]==key) return i;
   return -1;
}
void TgQueueRemoveFirst()
{
   int n=ArraySize(g_tg_queue_text);
   if(n<=0) return;
   for(int i=0;i<n-1;i++)
   {
      g_tg_queue_text[i]=g_tg_queue_text[i+1];
      g_tg_queue_key[i]=g_tg_queue_key[i+1];
   }
   ArrayResize(g_tg_queue_text,n-1);
   ArrayResize(g_tg_queue_key,n-1);
}
// Un recordatorio OFFLINE que no logro salir se sustituye por el siguiente en
// lugar de acumularse: si lo caido es la linea de Internet, al recuperarla el
// usuario recibe el estado vigente y no una avalancha de copias viejas.
void TgEnqueue(const string key,const string chunk)
{
   int same=TgQueueIndex(key);
   if(same>=0)
   {
      g_tg_queue_text[same]=chunk;
      return;
   }

   int n=ArraySize(g_tg_queue_text);
   if(n>=InpTelegramQueueMax)
   {
      // Cola llena: se descarta lo mas antiguo y se deja constancia.
      TgQueueRemoveFirst();
      g_tg_dropped++;
      n--;
   }

   ArrayResize(g_tg_queue_text,n+1);
   ArrayResize(g_tg_queue_key,n+1);
   g_tg_queue_text[n]=chunk;
   g_tg_queue_key[n]=key;
}
// Mientras haya cola, lo nuevo se encola tambien para no adelantar mensajes y
// romper el orden de los avisos.
bool Tg(const string key,const string msg)
{
   if(!TgConfigured()) return false;

   string chunks[];
   TgSplit(msg,chunks);

   // La sustitucion por clave solo es segura si el aviso cabe en un envio.
   string collapse_key=(ArraySize(chunks)==1)?key:"";

   bool queued=(ArraySize(g_tg_queue_text)>0);

   for(int i=0;i<ArraySize(chunks);i++)
   {
      if(queued || !TgPost(chunks[i]))
      {
         TgEnqueue((i==0)?collapse_key:"",chunks[i]);
         queued=true;
      }
   }
   return !queued;
}
void TgFlush()
{
   if(!TgConfigured()) return;

   for(int sent=0;sent<InpTelegramSendsPerCycle && ArraySize(g_tg_queue_text)>0;sent++)
   {
      if(!TgPost(g_tg_queue_text[0]))
         return;
      TgQueueRemoveFirst();
   }
}

//---------------- mensajes ----------------
string AlertHeader(const string level)
{
   string header=level+"\n\n"+
                 "PORTAFOLIO ALIAS: "+InpPortfolioAlias+"\n";
   if(Trim(InpTerminalAlias)!="")
      header+="TERMINAL: "+Trim(InpTerminalAlias)+"\n";
   header+="ID TERMINAL: "+AccountText(AccountNumber())+"\n"+
           "BROKER TERMINAL: "+BrokerText(AccountCompany())+"\n"+
           "SERVIDOR: "+BrokerText(AccountServer());
   return header;
}
string OfflineMessage(const datetime now)
{
   return AlertHeader("🔴 COPYMONITOR — CRÍTICO")+"\n\n"+
          "PROBLEMA\n"+
          "Estado: TERMINAL OFFLINE\n"+
          "Sin conexión desde: "+TimeText(g_offline_since)+"\n"+
          "Tiempo sin conexión: "+DurationText((int)(now-g_offline_since))+"\n"+
          "Hora de este aviso: "+TimeText(now)+"\n"+
          "Aviso número: "+IntegerToString(g_offline_notices)+
          "\n\nACCIÓN:\nRevisar el terminal, la conexión a Internet y el servidor "+
          BrokerText(AccountServer())+". Mientras el terminal siga offline no hay "+
          "vigilancia de copia en esta cuenta y este aviso se repite cada "+
          IntegerToString(InpOfflineRepeatMinutes)+" minutos.";
}
string OnlineMessage(const datetime now)
{
   return AlertHeader("🟢 COPYMONITOR — RESUELTO")+"\n\n"+
          "PROBLEMA\n"+
          "Estado: TERMINAL ONLINE\n"+
          "Sin conexión desde: "+TimeText(g_offline_since)+"\n"+
          "Conexión recuperada: "+TimeText(now)+"\n"+
          "Duración de la caída: "+DurationText((int)(now-g_offline_since))+"\n"+
          "Avisos enviados: "+IntegerToString(g_offline_notices)+
          "\n\nACCIÓN:\nNinguna. El terminal volvió a conectar con el servidor. "+
          "Revisar las operaciones abiertas durante la caída.";
}
string StartupMessage(const datetime now)
{
   return AlertHeader("🔵 COPYMONITOR — VIGILANCIA ACTIVA")+"\n\n"+
          "PROBLEMA\n"+
          "Estado: "+(IsConnected()?"TERMINAL ONLINE":"TERMINAL OFFLINE")+"\n"+
          "Inicio de la vigilancia: "+TimeText(now)+"\n"+
          "Confirmación de caída: "+IntegerToString(InpOfflineConfirmSeconds)+" segundos\n"+
          "Recordatorio mientras siga offline: cada "+
          IntegerToString(InpOfflineRepeatMinutes)+" minutos"+
          "\n\nACCIÓN:\nNinguna. Este aviso sólo confirma que el terminal puede avisar por Telegram.";
}

//---------------- vigilancia ----------------
void CheckConnection()
{
   datetime now=TimeLocal();

   // Un reloj que retrocede (cambio de hora, sincronizacion NTP) no debe
   // congelar los recordatorios ni inventar caidas de duracion negativa.
   if(g_bad_since>now)     g_bad_since=now;
   if(g_last_report>now)   g_last_report=now;
   if(g_offline_since>now) g_offline_since=now;

   bool connected=IsConnected();

   if(connected)
   {
      g_bad_since=0;
      if(!g_online)
      {
         string resolved=OnlineMessage(now);
         g_online=true;
         Tg(CM_WD_KEY_ONLINE,resolved);
         PrintFormat("[CM WATCHDOG] Conexión recuperada tras %s",
                     DurationText((int)(now-g_offline_since)));
         g_offline_since=0;
         g_last_report=0;
         g_offline_notices=0;
      }
      return;
   }

   if(g_bad_since==0) g_bad_since=now;

   // Caida aun no confirmada: una microdesconexion no genera aviso.
   if(g_online)
   {
      if((int)(now-g_bad_since)<InpOfflineConfirmSeconds) return;

      g_online=false;
      g_offline_since=g_bad_since;
      g_offline_notices=1;
      g_last_report=now;
      Tg(CM_WD_KEY_OFFLINE,OfflineMessage(now));
      PrintFormat("[CM WATCHDOG] Terminal OFFLINE desde %s",TimeText(g_offline_since));
      return;
   }

   if((int)(now-g_last_report)<InpOfflineRepeatMinutes*60) return;

   g_offline_notices++;
   g_last_report=now;
   Tg(CM_WD_KEY_OFFLINE,OfflineMessage(now));
}

//---------------- panel ----------------
void Panel()
{
   if(!InpShowPanel) return;

   string p="CopyMonitor Watchdog MT4 v"+CM_WD_VERSION+"\n";
   p+="Portafolio: "+InpPortfolioAlias+"\n";
   if(Trim(InpTerminalAlias)!="")
      p+="Terminal: "+Trim(InpTerminalAlias)+"\n";
   p+="Cuenta: "+AccountText(AccountNumber())+"  "+BrokerText(AccountCompany())+"\n";
   p+="Servidor: "+BrokerText(AccountServer())+"\n";
   p+="Estado: "+(g_online?"ONLINE":"OFFLINE")+"\n";

   if(!g_online)
   {
      datetime now=TimeLocal();
      p+="Sin conexión desde: "+TimeText(g_offline_since)+"\n";
      p+="Tiempo sin conexión: "+DurationText((int)(now-g_offline_since))+"\n";
      p+="Avisos enviados: "+IntegerToString(g_offline_notices)+"\n";
   }
   else if(g_bad_since>0)
      p+="Sin conexión sin confirmar desde: "+TimeText(g_bad_since)+"\n";

   p+=(TgConfigured()?"Telegram: ON":"Telegram: OFF");
   p+="  En cola: "+IntegerToString(ArraySize(g_tg_queue_text));
   p+="  Descartados: "+IntegerToString(g_tg_dropped)+"\n";
   if(g_tg_last_error!="")
      p+="Último error: "+g_tg_last_error+"\n";

   Comment(p);
}

//---------------- validacion ----------------
bool Validate()
{
   if(Trim(InpPortfolioAlias)=="")
   {
      Print("[CM WATCHDOG] InpPortfolioAlias es obligatorio: encabeza cada aviso de Telegram.");
      return false;
   }
   if(InpCheckSeconds<1 || InpCheckSeconds>60)
   {
      Print("[CM WATCHDOG] InpCheckSeconds debe estar entre 1 y 60.");
      return false;
   }
   if(InpOfflineConfirmSeconds<InpCheckSeconds || InpOfflineConfirmSeconds>3600)
   {
      Print("[CM WATCHDOG] InpOfflineConfirmSeconds debe estar entre InpCheckSeconds y 3600.");
      return false;
   }
   if(InpOfflineRepeatMinutes<1 || InpOfflineRepeatMinutes>180)
   {
      Print("[CM WATCHDOG] InpOfflineRepeatMinutes debe estar entre 1 y 180.");
      return false;
   }
   if(InpTelegramTimeoutMs<1)
   {
      Print("[CM WATCHDOG] InpTelegramTimeoutMs debe ser mayor que cero.");
      return false;
   }
   // Telegram activado sin credenciales dejaria al usuario sin ningun aviso y
   // sin saberlo: es un fallo de configuracion, no un modo de trabajo.
   if(InpEnableTelegram && (Trim(InpTelegramBotToken)=="" || Trim(InpTelegramChatID)==""))
   {
      Print("[CM WATCHDOG] Telegram activado sin token o sin chat ID: "
            "complete ambos o desactive InpEnableTelegram.");
      return false;
   }
   // Telegram rechaza mensajes de mas de 4096 caracteres.
   if(InpTelegramChunkChars<200 || InpTelegramChunkChars>4000)
   {
      Print("[CM WATCHDOG] InpTelegramChunkChars debe estar entre 200 y 4000.");
      return false;
   }
   if(InpTelegramQueueMax<1 || InpTelegramQueueMax>500)
   {
      Print("[CM WATCHDOG] InpTelegramQueueMax debe estar entre 1 y 500.");
      return false;
   }
   if(InpTelegramSendsPerCycle<1 || InpTelegramSendsPerCycle>10)
   {
      Print("[CM WATCHDOG] InpTelegramSendsPerCycle debe estar entre 1 y 10.");
      return false;
   }
   // Cada envio bloquea hasta InpTelegramTimeoutMs: el ciclo no puede gastar
   // mas tiempo del que tarda en volver a comprobar la conexion.
   if(InpTelegramSendsPerCycle*InpTelegramTimeoutMs>5000)
   {
      Print("[CM WATCHDOG] InpTelegramSendsPerCycle por InpTelegramTimeoutMs no puede pasar de 5000 ms.");
      return false;
   }
   // La vigilancia tampoco puede retrasarse por sus propios envios: en el peor
   // ciclo se intenta un aviso nuevo ademas de la cola pendiente.
   if((InpTelegramSendsPerCycle+1)*InpTelegramTimeoutMs>InpCheckSeconds*1000)
   {
      Print("[CM WATCHDOG] Los envios de un ciclo pueden durar mas que InpCheckSeconds: "
            "baje InpTelegramSendsPerCycle o InpTelegramTimeoutMs, o suba InpCheckSeconds.");
      return false;
   }
   return true;
}

//---------------- ciclo de vida ----------------
int OnInit()
{
   if(!Validate()) return INIT_FAILED;

   // Se arranca suponiendo conexion: si el terminal ya esta offline, la caida
   // se confirma y se avisa igual al cumplirse InpOfflineConfirmSeconds.
   g_online=true;
   g_bad_since=0;
   g_offline_since=0;
   g_last_report=0;
   g_offline_notices=0;
   ArrayResize(g_tg_queue_text,0);
   ArrayResize(g_tg_queue_key,0);
   g_tg_dropped=0;
   g_tg_last_error="";

   // El aviso de arranque se envia en el primer ciclo: una llamada de red en
   // OnInit bloquearia la carga del terminal.
   g_startup_pending=InpSendStartupNotice;

   if(!EventSetTimer(InpCheckSeconds))
   {
      Print("[CM WATCHDOG] No se pudo crear el temporizador de vigilancia.");
      return INIT_FAILED;
   }

   PrintFormat("[CM WATCHDOG] v%s activo. Comprobación cada %d s, caída confirmada a los %d s, recordatorio cada %d min.",
               CM_WD_VERSION,InpCheckSeconds,InpOfflineConfirmSeconds,InpOfflineRepeatMinutes);
   Panel();
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}
// El temporizador es el unico motor fiable: sin conexion no llegan ticks y
// OnTick dejaria de ejecutarse justo cuando hay que avisar.
void OnTimer()
{
   if(g_startup_pending)
   {
      g_startup_pending=false;
      Tg(CM_WD_KEY_STARTUP,StartupMessage(TimeLocal()));
   }

   CheckConnection();
   TgFlush();
   Panel();
}
void OnTick()
{
   // Sin acciones: la vigilancia vive en OnTimer y este EA nunca opera.
}
