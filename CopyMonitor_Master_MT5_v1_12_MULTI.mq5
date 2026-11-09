//+------------------------------------------------------------------+
//| CopyMonitor_Master_MT5_v1_12_MULTI.mq5                           |
//| Publishes open positions + pending orders for CopyMonitor Slave. |
//| No trading actions.                                               |
//+------------------------------------------------------------------+
#property strict
#property version   "1.12"
#property description "CopyMonitor Master MT5 v1.12 MULTI"

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

bool g_busy=false;

string Safe(string s)
{
   StringReplace(s,"|","_");
   StringReplace(s,"\r"," ");
   StringReplace(s,"\n"," ");
   return s;
}
string SafeFile(string s)
{
   s=Safe(s);
   string bad=" /\\:*?\"<>";
   for(int i=0;i<StringLen(bad);i++)
      StringReplace(s,StringSubstr(bad,i,1),"_");
   return s;
}
string SnapFile(){ return "CopyMonitorMulti\\CM_"+SafeFile(InpChannelID)+".txt"; }

bool SymbolListContains(string list,const string symbol)
{
   StringReplace(list,";",",");
   string parts[];
   int n=StringSplit(list,',',parts);

   for(int i=0;i<n;i++)
   {
      string s=parts[i];
      StringTrimLeft(s);
      StringTrimRight(s);
      if(s!="" && s==symbol)
         return true;
   }
   return false;
}

bool SymbolAllowed(const string symbol)
{
   if(InpSymbolsIgnore!="" && SymbolListContains(InpSymbolsIgnore,symbol))
      return false;

   if(InpSymbolsFilter=="")
      return true;

   return SymbolListContains(InpSymbolsFilter,symbol);
}

bool PassFilter(const string symbol,const string c,const long m)
{
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

int CountPos()
{
   int n=0;
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      if(PassFilter(PositionGetString(POSITION_SYMBOL),
                    PositionGetString(POSITION_COMMENT),
                    (long)PositionGetInteger(POSITION_MAGIC))) n++;
   }
   return n;
}
int CountPend()
{
   int n=0;
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong tk=OrderGetTicket(i); if(tk==0) continue;
      ENUM_ORDER_TYPE t=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(!IsPending(t)) continue;
      if(PassFilter(OrderGetString(ORDER_SYMBOL),
                    OrderGetString(ORDER_COMMENT),
                    (long)OrderGetInteger(ORDER_MAGIC))) n++;
   }
   return n;
}

bool Publish()
{
   int h=FileOpen(SnapFile(),FILE_COMMON|FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE)
   {
      PrintFormat("[CM MASTER] Snapshot write failed. err=%d",GetLastError());
      return false;
   }

   FileWriteString(h,
      "META|1|"+StringFormat("%I64d",(long)TimeLocal())+"|"+
      Safe(InpChannelID)+"|"+Safe(InpAccountNick)+"|"+
      StringFormat("%I64d",(long)AccountInfoInteger(ACCOUNT_LOGIN))+"|"+
      IntegerToString(CountPos())+"|"+IntegerToString(CountPend())+"\r\n");

   for(int i=0;i<PositionsTotal();i++)
   {
      ulong tk=PositionGetTicket(i); if(tk==0) continue;
      string c=PositionGetString(POSITION_COMMENT);
      long mg=(long)PositionGetInteger(POSITION_MAGIC);
      if(!PassFilter(PositionGetString(POSITION_SYMBOL),c,mg)) continue;

      FileWriteString(h,
         "POS|"+StringFormat("%I64u",tk)+"|"+
         Safe(PositionGetString(POSITION_SYMBOL))+"|"+
         IntegerToString((int)PositionGetInteger(POSITION_TYPE))+"|"+
         DoubleToString(PositionGetDouble(POSITION_VOLUME),8)+"|"+
         DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN),10)+"|"+
         DoubleToString(PositionGetDouble(POSITION_SL),10)+"|"+
         DoubleToString(PositionGetDouble(POSITION_TP),10)+"\r\n");
   }

   for(int i=0;i<OrdersTotal();i++)
   {
      ulong tk=OrderGetTicket(i); if(tk==0) continue;
      ENUM_ORDER_TYPE t=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(!IsPending(t)) continue;
      string c=OrderGetString(ORDER_COMMENT);
      long mg=(long)OrderGetInteger(ORDER_MAGIC);
      if(!PassFilter(OrderGetString(ORDER_SYMBOL),c,mg)) continue;

      FileWriteString(h,
         "ORD|"+StringFormat("%I64u",tk)+"|"+
         Safe(OrderGetString(ORDER_SYMBOL))+"|"+
         IntegerToString((int)t)+"|"+
         DoubleToString(OrderGetDouble(ORDER_VOLUME_CURRENT),8)+"|"+
         DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN),10)+"|"+
         DoubleToString(OrderGetDouble(ORDER_SL),10)+"|"+
         DoubleToString(OrderGetDouble(ORDER_TP),10)+"\r\n");
   }

   FileWriteString(h,"END\r\n");
   FileFlush(h); FileClose(h);
   return true;
}

void Panel()
{
   if(!InpShowPanel){ Comment(""); return; }
   string s="COPYMONITOR MASTER v1.12 MULTI\n";
   s+="Nick: "+InpAccountNick+"\nChannel: "+InpChannelID+"\n";
   s+="Open: "+IntegerToString(CountPos())+"\n";
   s+="Pending: "+IntegerToString(CountPend())+"\n";
   s+="Include symbols: "+(InpSymbolsFilter=="" ? "ALL" : InpSymbolsFilter)+"\n";
   s+="Ignore symbols: "+(InpSymbolsIgnore=="" ? "NONE" : InpSymbolsIgnore)+"\n";
   s+="Action: PUBLISH ONLY";
   Comment(s);
}
void Cycle(){ if(g_busy)return; g_busy=true; Publish(); Panel(); g_busy=false; }

int OnInit()
{
   if(InpChannelID=="" || InpPublishSeconds<1) return INIT_PARAMETERS_INCORRECT;
   Cycle();
   if(!EventSetTimer(InpPublishSeconds)) return INIT_FAILED;
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){ EventKillTimer(); Comment(""); }
void OnTimer(){ Cycle(); }
void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &r,const MqlTradeResult &x){ Cycle(); }
//+------------------------------------------------------------------+
