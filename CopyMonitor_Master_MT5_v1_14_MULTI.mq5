//+------------------------------------------------------------------+
//| CopyMonitor_Master_MT5_v1_14_MULTI.mq5                           |
//| Publishes open positions + pending orders for CopyMonitor Slave. |
//| No trading actions.                                               |
//+------------------------------------------------------------------+
#property strict
#property version   "1.14"
#property description "CopyMonitor Master MT5 v1.14 MULTI"

// Esquema de snapshot publicado. El lector Slave acepta 1, 2 y 3.
//   META|3|written|channel|nick|account|open_total|pending_total|broker
//   POS|ticket|symbol|type|volume|open_price|sl|tp
//   ORD|ticket|symbol|type|volume|open_price|sl|tp|stoplimit
//   END
// El campo stoplimit del registro ORD aparece en el esquema 3; un lector de
// esquema 1 o 2 lo ignora porque los campos nuevos van siempre al final.
#define CM_SNAPSHOT_SCHEMA   3
#define CM_CHANNEL_MAX_LEN   32

input group "===== MASTER IDENTITY ====="
input string InpAccountNick         = "MASTER_280";
input string InpChannelID           = "MASTER_280";
input int    InpPublishSeconds      = 1;
input bool   InpShowPanel           = true;

input group "===== OPTIONAL MASTER FILTER ====="
input string InpFilterComment       = "";   // empty = all
input long   InpFilterMagic         = -1;   // -1 = all
input string InpSymbolsFilter       = "";   // empty = all; comma/semicolon separated
input string InpSymbolsIgnore       = "";   // symbols to exclude; comma/semicolon separated

input group "===== DIAGNOSTIC ====="
input bool   InpVerboseLog          = false;

bool     g_busy=false;
// Las listas de simbolos y el nombre de fichero no cambian en ejecucion: se
// resuelven una vez en OnInit para no reparsear cadenas en cada ciclo.
string   g_include_symbols[];
string   g_exclude_symbols[];
string   g_snapshot_path="";
string   g_snapshot_temp="";
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
   SplitClean(raw,',',out);
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

bool PassFilter(const string symbol,const string c,const long m)
{
   if(symbol=="") return false;
   if(!SymbolAllowed(symbol)) return false;
   if(InpFilterComment!="" && c!=InpFilterComment) return false;
   if(InpFilterMagic>=0 && m!=InpFilterMagic) return false;
   return true;
}

bool IsPending(const ENUM_ORDER_TYPE t)
{
   return t==ORDER_TYPE_BUY_LIMIT || t==ORDER_TYPE_SELL_LIMIT ||
          t==ORDER_TYPE_BUY_STOP  || t==ORDER_TYPE_SELL_STOP ||
          t==ORDER_TYPE_BUY_STOP_LIMIT || t==ORDER_TYPE_SELL_STOP_LIMIT;
}

bool IsStopLimit(const ENUM_ORDER_TYPE t)
{
   return t==ORDER_TYPE_BUY_STOP_LIMIT || t==ORDER_TYPE_SELL_STOP_LIMIT;
}

void AddRow(string &rows[],const string row)
{
   int n=ArraySize(rows);
   ArrayResize(rows,n+1);
   rows[n]=row;
}

//---------------- snapshot ----------------
// Las colecciones se recorren hacia atras: si el terminal retira una entrada
// mientras se construye el snapshot, los indices ya visitados no se desplazan.
void CollectPositions(string &rows[])
{
   ArrayResize(rows,0);

   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong tk=PositionGetTicket(i);
      if(tk==0)
         continue;

      string symbol=PositionGetString(POSITION_SYMBOL);
      string comment=PositionGetString(POSITION_COMMENT);
      long magic=(long)PositionGetInteger(POSITION_MAGIC);

      if(!PassFilter(symbol,comment,magic))
         continue;

      AddRow(rows,
         "POS|"+StringFormat("%I64u",tk)+"|"+
         Safe(symbol)+"|"+
         IntegerToString((int)PositionGetInteger(POSITION_TYPE))+"|"+
         DoubleToString(PositionGetDouble(POSITION_VOLUME),8)+"|"+
         DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN),10)+"|"+
         DoubleToString(PositionGetDouble(POSITION_SL),10)+"|"+
         DoubleToString(PositionGetDouble(POSITION_TP),10)+"\r\n");
   }
}

void CollectOrders(string &rows[])
{
   ArrayResize(rows,0);

   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong tk=OrderGetTicket(i);
      if(tk==0)
         continue;

      ENUM_ORDER_TYPE t=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(!IsPending(t))
         continue;

      string symbol=OrderGetString(ORDER_SYMBOL);
      string comment=OrderGetString(ORDER_COMMENT);
      long magic=(long)OrderGetInteger(ORDER_MAGIC);

      if(!PassFilter(symbol,comment,magic))
         continue;

      // Solo las STOP LIMIT tienen precio limite propio; el resto publica 0
      // para mantener fijo el numero de campos del registro.
      double stoplimit=IsStopLimit(t) ? OrderGetDouble(ORDER_PRICE_STOPLIMIT) : 0.0;

      AddRow(rows,
         "ORD|"+StringFormat("%I64u",tk)+"|"+
         Safe(symbol)+"|"+
         IntegerToString((int)t)+"|"+
         DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT),8)+"|"+
         DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN),10)+"|"+
         DoubleToString(OrderGetDouble(ORDER_SL),10)+"|"+
         DoubleToString(OrderGetDouble(ORDER_TP),10)+"|"+
         DoubleToString(stoplimit,10)+"\r\n");
   }
}

// Los totales del META se derivan de los registros ya construidos. Contarlos
// en una pasada aparte permitia publicar un META incoherente si la coleccion
// cambiaba entre el recuento y la escritura, y el Slave invalidaba todo.
string BuildSnapshot(int &open_count,int &pending_count)
{
   string pos_rows[],ord_rows[];
   CollectPositions(pos_rows);
   CollectOrders(ord_rows);

   open_count=ArraySize(pos_rows);
   pending_count=ArraySize(ord_rows);

   string text=
      "META|"+IntegerToString(CM_SNAPSHOT_SCHEMA)+"|"+
      StringFormat("%I64d",(long)TimeLocal())+"|"+
      Safe(InpChannelID)+"|"+Safe(InpAccountNick)+"|"+
      StringFormat("%I64d",(long)AccountInfoInteger(ACCOUNT_LOGIN))+"|"+
      IntegerToString(open_count)+"|"+IntegerToString(pending_count)+"|"+
      Safe(AccountInfoString(ACCOUNT_COMPANY))+"\r\n";

   for(int i=0;i<open_count;i++)
      text+=pos_rows[i];
   for(int i=0;i<pending_count;i++)
      text+=ord_rows[i];

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

bool Publish()
{
   int open_count=0,pending_count=0;
   string text=BuildSnapshot(open_count,pending_count);

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
      if(InpVerboseLog)
         PrintFormat("[CM MASTER] Snapshot publicado. open=%d pending=%d",
                     open_count,pending_count);
      return true;
   }

   // Un fallo persistente no debe inundar el log: se informa como mucho una
   // vez cada diez segundos, pero siempre queda visible en el panel.
   datetime now=TimeLocal();
   if((now-g_last_log)>=10)
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

   string s="COPYMONITOR MASTER v1.14 MULTI\n";
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

void Cycle()
{
   if(g_busy)
      return;
   g_busy=true;
   Publish();
   Panel();
   g_busy=false;
}

// Cada cierre genera varias transacciones y algunas no cambian el estado
// publicado. Republicar solo en las relevantes evita reescrituras inutiles
// del fichero comun sin perder latencia.
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

   g_snapshot_path="CopyMonitorMulti\\CM_"+channel+".txt";
   g_snapshot_temp="CopyMonitorMulti\\CM_"+channel+".tmp";

   LoadSymbolList(InpSymbolsFilter,g_include_symbols);
   LoadSymbolList(InpSymbolsIgnore,g_exclude_symbols);

   Cycle();

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
   Cycle();
}

void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &r,const MqlTradeResult &x)
{
   if(!TransactionMatters(t.type))
      return;
   Cycle();
}
//+------------------------------------------------------------------+
