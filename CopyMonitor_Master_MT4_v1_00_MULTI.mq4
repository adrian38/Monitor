//+------------------------------------------------------------------+
//| CopyMonitor_Master_MT4_v1_00_MULTI.mq4                           |
//| Publishes open positions + pending orders for CopyMonitor Slave. |
//| No trading actions.                                               |
//| Port MT4 del Master MT5 v1.14 MULTI: mismo esquema, mismo        |
//| directorio comun y mismos codigos de tipo, de modo que un Master |
//| MT4 puede alimentar a un Slave MT4 o MT5 indistintamente.        |
//+------------------------------------------------------------------+
#property strict
#property version   "1.00"
#property description "CopyMonitor Master MT4 v1.00 MULTI"

// Esquema de snapshot publicado. El lector Slave acepta 1, 2 y 3.
//   META|3|written|channel|nick|account|open_total|pending_total|broker
//   POS|ticket|symbol|type|volume|open_price|sl|tp
//   ORD|ticket|symbol|type|volume|open_price|sl|tp|stoplimit
//   END
// El campo stoplimit del registro ORD aparece en el esquema 3; un lector de
// esquema 1 o 2 lo ignora porque los campos nuevos van siempre al final.
#define CM_SNAPSHOT_SCHEMA   3
#define CM_CHANNEL_MAX_LEN   32

// El campo type viaja como numero y lo interpreta un Slave que puede ser MT5.
// Los codigos de MT4 y de MT5 coinciden en el rango que este Master publica:
//   OP_BUY=0       ORDER_TYPE_BUY=0 / POSITION_TYPE_BUY=0
//   OP_SELL=1      ORDER_TYPE_SELL=1 / POSITION_TYPE_SELL=1
//   OP_BUYLIMIT=2  ORDER_TYPE_BUY_LIMIT=2
//   OP_SELLLIMIT=3 ORDER_TYPE_SELL_LIMIT=3
//   OP_BUYSTOP=4   ORDER_TYPE_BUY_STOP=4
//   OP_SELLSTOP=5  ORDER_TYPE_SELL_STOP=5
// Por eso el snapshot no traduce nada. MT4 no tiene STOP LIMIT (6 y 7), asi
// que este Master nunca publica esos tipos y el campo stoplimit es siempre 0.

//--- ===== MASTER IDENTITY =====
input string InpAccountNick         = "MASTER_280";
input string InpChannelID           = "MASTER_280";
input int    InpPublishSeconds      = 1;
input bool   InpShowPanel           = true;

//--- ===== OPTIONAL MASTER FILTER =====
input string InpFilterComment       = "";   // empty = all
// El numero magico de MT4 es un entero de 32 bits, no el long de MT5.
input int    InpFilterMagic         = -1;   // -1 = all
input string InpSymbolsFilter       = "";   // empty = all; comma/semicolon separated
input string InpSymbolsIgnore       = "";   // symbols to exclude; comma/semicolon separated

//--- ===== TIMERS =====
// Segundos entre avisos de fallo de publicacion en el log. Un fallo continuo no
// debe inundar el diario; el panel lo muestra siempre.
input int    InpPublishFailLogSeconds = 10;

//--- ===== DIAGNOSTIC =====
input bool   InpVerboseLog          = false;

bool     g_busy=false;
// Las listas de simbolos y el nombre de fichero no cambian en ejecucion: se
// resuelven una vez en OnInit para no reparsear cadenas en cada ciclo.
string   g_include_symbols[];
string   g_exclude_symbols[];
string   g_snapshot_path="";
string   g_snapshot_temp="";
// Cuerpo (registros POS y ORD) de la ultima publicacion correcta. MT4 no tiene
// OnTradeTransaction, asi que el disparo inmediato por cambio vive en OnTick y
// necesita saber si el estado publicado sigue siendo el mismo.
string   g_last_body="";
// Estado del ultimo intento de publicacion, mostrado en el panel.
bool     g_last_ok=false;
datetime g_last_ok_time=0;
int      g_last_open=0;
int      g_last_pending=0;
string   g_last_error="";
datetime g_last_log=0;

//---------------- utility ----------------
string Trim(string s)
{
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
}

string Safe(string s)
{
   StringReplace(s,"|","_");
   StringReplace(s,"\r"," ");
   StringReplace(s,"\n"," ");
   StringReplace(s,"\t"," ");
   return Trim(s);
}

// El identificador de canal forma parte del nombre de fichero comun y viaja en
// el META. Master y Slave deben derivar exactamente el mismo nombre, asi que
// ambos exigen el mismo juego de caracteres en lugar de sanear en silencio:
// un saneo divergente deja al Slave leyendo un fichero que nadie escribe.
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

// MT4 no admite %I64u en StringFormat de forma fiable: los tickets se escriben
// con IntegerToString, que ya acepta un long.
string TicketText(const long ticket)
{
   return IntegerToString(ticket);
}

void SplitClean(string raw,const ushort sep,string &out[])
{
   ArrayResize(out,0);
   string parts[];
   int n=StringSplit(raw,sep,parts);

   for(int i=0;i<n;i++)
   {
      string s=Trim(parts[i]);
      if(s=="")
         continue;
      int z=ArraySize(out);
      ArrayResize(out,z+1);
      out[z]=s;
   }
}

void LoadSymbolList(string raw,string &out[])
{
   StringReplace(raw,";",",");
   SplitClean(raw,(ushort)',',out);
}

bool SymbolListContains(const string &list[],const string symbol)
{
   for(int i=0;i<ArraySize(list);i++)
      if(list[i]==symbol)
         return true;
   return false;
}

bool SymbolAllowed(const string symbol)
{
   if(SymbolListContains(g_exclude_symbols,symbol))
      return false;

   if(ArraySize(g_include_symbols)==0)
      return true;

   return SymbolListContains(g_include_symbols,symbol);
}

bool PassFilter(const string symbol,const string c,const int m)
{
   if(symbol=="") return false;
   if(!SymbolAllowed(symbol)) return false;
   if(InpFilterComment!="" && c!=InpFilterComment) return false;
   if(InpFilterMagic>=0 && m!=InpFilterMagic) return false;
   return true;
}

// MT4 guarda posiciones y pendientes en la misma lista de operaciones, asi que
// el tipo es lo unico que las separa.
bool IsPendingType(const int t)
{
   return t==OP_BUYLIMIT || t==OP_SELLLIMIT ||
          t==OP_BUYSTOP  || t==OP_SELLSTOP;
}

bool IsPositionType(const int t)
{
   return t==OP_BUY || t==OP_SELL;
}

void AddRow(string &rows[],const string row)
{
   int n=ArraySize(rows);
   ArrayResize(rows,n+1);
   rows[n]=row;
}

//---------------- snapshot ----------------
// Una sola pasada sobre la lista de operaciones: en MT4 posiciones y pendientes
// comparten coleccion, y recorrerla dos veces podria mezclar dos fotos del
// terminal. Se recorre hacia atras: si el terminal retira una entrada durante
// el recorrido, los indices ya visitados no se desplazan.
void CollectRows(string &pos_rows[],string &ord_rows[])
{
   ArrayResize(pos_rows,0);
   ArrayResize(ord_rows,0);

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      if(!OrderSelect(i,SELECT_BY_POS,MODE_TRADES))
         continue;

      int type=OrderType();
      if(!IsPositionType(type) && !IsPendingType(type))
         continue;

      string symbol=OrderSymbol();

      if(!PassFilter(symbol,OrderComment(),OrderMagicNumber()))
         continue;

      string row=
         TicketText((long)OrderTicket())+"|"+
         Safe(symbol)+"|"+
         IntegerToString(type)+"|"+
         DoubleToString(OrderLots(),8)+"|"+
         DoubleToString(OrderOpenPrice(),10)+"|"+
         DoubleToString(OrderStopLoss(),10)+"|"+
         DoubleToString(OrderTakeProfit(),10);

      if(IsPositionType(type))
         AddRow(pos_rows,"POS|"+row+"\r\n");
      else
         // MT4 no tiene ordenes STOP LIMIT, asi que el precio limite del
         // esquema 3 se publica siempre como 0 para mantener fijo el numero
         // de campos del registro.
         AddRow(ord_rows,"ORD|"+row+"|"+DoubleToString(0.0,10)+"\r\n");
   }
}

// Los totales del META se derivan de los registros ya construidos. Contarlos
// en una pasada aparte permitia publicar un META incoherente si la coleccion
// cambiaba entre el recuento y la escritura, y el Slave invalidaba todo.
string BuildBody(int &open_count,int &pending_count)
{
   string pos_rows[],ord_rows[];
   CollectRows(pos_rows,ord_rows);

   open_count=ArraySize(pos_rows);
   pending_count=ArraySize(ord_rows);

   string body="";
   for(int i=0;i<open_count;i++)
      body+=pos_rows[i];
   for(int i=0;i<pending_count;i++)
      body+=ord_rows[i];

   return body;
}

string BuildSnapshot(const string body,const int open_count,const int pending_count)
{
   string text=
      "META|"+IntegerToString(CM_SNAPSHOT_SCHEMA)+"|"+
      IntegerToString((long)TimeLocal())+"|"+
      Safe(InpChannelID)+"|"+Safe(InpAccountNick)+"|"+
      IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN))+"|"+
      IntegerToString(open_count)+"|"+IntegerToString(pending_count)+"|"+
      Safe(AccountInfoString(ACCOUNT_COMPANY))+"\r\n";

   text+=body;
   text+="END\r\n";
   return text;
}

// FILE_SHARE_READ evita que el Slave reciba un fallo de apertura mientras el
// Master mantiene el fichero abierto.
bool WriteWholeFile(const string path,const string text)
{
   ResetLastError();
   int h=FileOpen(path,FILE_COMMON|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);

   if(h==INVALID_HANDLE)
   {
      g_last_error=StringFormat("apertura de %s err=%d",path,GetLastError());
      return false;
   }

   uint written=FileWriteString(h,text);
   FileFlush(h);
   FileClose(h);

   if(written==0 && StringLen(text)>0)
   {
      g_last_error=StringFormat("escritura de %s err=%d",path,GetLastError());
      return false;
   }
   return true;
}

bool Publish(const string body,const int open_count,const int pending_count)
{
   string text=BuildSnapshot(body,open_count,pending_count);

   g_last_error="";

   // Publicacion en dos pasos: el fichero temporal se renombra sobre el
   // definitivo, asi el Slave nunca ve un snapshot a medio escribir. Si el
   // renombrado falla porque el lector tiene el fichero abierto, se escribe
   // directamente: perder la publicacion seria peor que un lectura rota, que
   // el Slave ya detecta por contadores y por la marca END.
   bool ok=false;

   if(WriteWholeFile(g_snapshot_temp,text))
   {
      ResetLastError();
      if(FileMove(g_snapshot_temp,FILE_COMMON,g_snapshot_path,FILE_COMMON|FILE_REWRITE))
         ok=true;
      else
      {
         g_last_error=StringFormat("renombrado err=%d",GetLastError());
         ok=WriteWholeFile(g_snapshot_path,text);
         FileDelete(g_snapshot_temp,FILE_COMMON);
      }
   }
   else
      ok=WriteWholeFile(g_snapshot_path,text);

   g_last_ok=ok;
   g_last_open=open_count;
   g_last_pending=pending_count;

   if(ok)
   {
      g_last_ok_time=TimeLocal();
      g_last_body=body;
      if(InpVerboseLog)
         PrintFormat("[CM MASTER] Snapshot publicado. open=%d pending=%d",
                     open_count,pending_count);
      return true;
   }

   // Un fallo persistente no debe inundar el log: se informa como mucho una vez
   // cada InpPublishFailLogSeconds, pero siempre queda visible en el panel.
   datetime now=TimeLocal();
   if((now-g_last_log)>=InpPublishFailLogSeconds)
   {
      g_last_log=now;
      PrintFormat("[CM MASTER] Snapshot write failed. %s",g_last_error);
   }
   return false;
}

//---------------- panel/cycle ----------------
void Panel()
{
   if(!InpShowPanel)
   {
      Comment("");
      return;
   }

   string s="COPYMONITOR MASTER MT4 v1.00 MULTI\n";
   s+="Nick: "+InpAccountNick+"\nChannel: "+InpChannelID+"\n";
   s+="Broker: "+AccountInfoString(ACCOUNT_COMPANY)+"\n";
   s+="Snapshot schema: "+IntegerToString(CM_SNAPSHOT_SCHEMA)+"\n";
   s+="Open: "+IntegerToString(g_last_open)+"\n";
   s+="Pending: "+IntegerToString(g_last_pending)+"\n";
   s+="Include symbols: "+(ArraySize(g_include_symbols)==0 ? "ALL" : InpSymbolsFilter)+"\n";
   s+="Ignore symbols: "+(ArraySize(g_exclude_symbols)==0 ? "NONE" : InpSymbolsIgnore)+"\n";

   if(g_last_ok)
      s+="Publish: OK "+TimeToString(g_last_ok_time,TIME_MINUTES|TIME_SECONDS)+"\n";
   else
      s+="Publish: FAIL "+g_last_error+"\n";

   s+="Action: PUBLISH ONLY";
   Comment(s);
}

// force=true republica aunque nada haya cambiado, para refrescar la marca de
// tiempo del META de la que depende la frescura en el Slave. force=false es el
// disparo por tick: solo escribe si el estado publicado dejo de ser valido.
void Cycle(const bool force)
{
   if(g_busy)
      return;
   g_busy=true;

   int open_count=0,pending_count=0;
   string body=BuildBody(open_count,pending_count);

   if(force || !g_last_ok || body!=g_last_body)
      Publish(body,open_count,pending_count);

   Panel();
   g_busy=false;
}

int OnInit()
{
   string channel=Trim(InpChannelID);

   if(!ChannelIdValid(channel))
   {
      PrintFormat("[CM MASTER] InpChannelID invalido: use 1-%d caracteres A-Z a-z 0-9 _ - .",
                  CM_CHANNEL_MAX_LEN);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpPublishSeconds<1)
   {
      Print("[CM MASTER] InpPublishSeconds debe ser 1 o mayor.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(Trim(InpAccountNick)=="")
   {
      Print("[CM MASTER] InpAccountNick no puede estar vacio.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpPublishFailLogSeconds<1)
   {
      Print("[CM MASTER] InpPublishFailLogSeconds debe ser 1 o mayor.");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_snapshot_path="CopyMonitorMulti\\CM_"+channel+".txt";
   g_snapshot_temp="CopyMonitorMulti\\CM_"+channel+".tmp";
   g_last_body="";

   // En MT4 conviene crear la carpeta del directorio comun antes de abrir el
   // primer fichero: no todas las compilaciones la generan al vuelo.
   FolderCreate("CopyMonitorMulti",FILE_COMMON);

   LoadSymbolList(InpSymbolsFilter,g_include_symbols);
   LoadSymbolList(InpSymbolsIgnore,g_exclude_symbols);

   Cycle(true);

   if(!EventSetTimer(InpPublishSeconds))
   {
      PrintFormat("[CM MASTER] EventSetTimer fallo. err=%d",GetLastError());
      return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   // El temporal solo existe entre la escritura y el renombrado; si el EA se
   // descarga justo en medio no debe quedar basura en el directorio comun.
   if(g_snapshot_temp!="")
      FileDelete(g_snapshot_temp,FILE_COMMON);
   Comment("");
}

void OnTimer()
{
   Cycle(true);
}

// MT4 no tiene OnTradeTransaction. El equivalente es reaccionar al tick cuando
// el estado que se publica dejo de coincidir con el ultimo snapshot: un cierre
// o una pendiente nueva sale al instante sin reescribir el fichero comun en
// cada tick de una cuenta sin cambios.
void OnTick()
{
   Cycle(false);
}
//+------------------------------------------------------------------+
