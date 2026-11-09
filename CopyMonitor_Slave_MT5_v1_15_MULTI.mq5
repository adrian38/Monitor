//+------------------------------------------------------------------+
//| CopyMonitor_Slave_MT5_v1_15_MULTI.mq5                            |
//| Preserves GENERIC / PORTFOLIO46 / LUNA profiles.                 |
//| Optional MultiMaster layer by exact Slave comment ownership.      |
//| Open positions: monitor quantity + SL/TP, never auto-close.       |
//| Pending orders: normally ignored as copy expectations; optional   |
//| confirmed EXTRA pending in Slave can be deleted.                  |
//+------------------------------------------------------------------+
#property strict
#property version "1.15"
#property description "CopyMonitor Slave MT5 v1.15 MULTI"
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
input bool InpMonitorPendingOrders                    = false;
input bool InpExpectPendingCopies                     = false;
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
input bool   InpNotifyDeleteSuccess                   = true;
input bool   InpNotifyDeleteFailure                   = true;

input group "===== DIAGNOSTIC ====="
input bool   InpVerboseLog                            = false;

struct PosRec { ulong ticket; string symbol; int type; double vol; double price; double sl; double tp; };
struct OrdRec { ulong ticket; string symbol; int type; double vol; double price; double sl; double tp; };
struct Snap
{
   string channel,nick;
   long account,written;
   int open_total,pending_total;
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
struct AlertState { string key; bool active; datetime last; };
struct Candidate { ulong ticket; string channel; datetime first_seen; };

bool g_busy=false;
AlertState g_alerts[];
Candidate g_candidates[];

//---------------- utility ----------------
string SafeFile(string s)
{
   string bad=" /\\:*?\"<>";
   for(int i=0;i<StringLen(bad);i++) StringReplace(s,StringSubstr(bad,i,1),"_");
   return s;
}
string SnapFile(const string c){ return "CopyMonitorMulti\\CM_"+SafeFile(c)+".txt"; }

void SplitClean(string raw,const ushort sep,string &out[])
{
   ArrayResize(out,0);
   string p[]; int n=StringSplit(raw,sep,p);
   for(int i=0;i<n;i++)
   {
      string s=p[i]; StringTrimLeft(s); StringTrimRight(s);
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
string AlertHeader(const Snap &snap,const string level)
{
   return level+"\n\n"+
          "ID MASTER: "+AccountText(snap.account)+"\n"+
          "ID SLAVE: "+AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN));
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
bool LoadOwners(Owner &o[])
{
   ArrayResize(o,0);

   if(!InpMultiMaster)
   {
      Owner x;
      x.channel=InpMasterChannel;
      x.comment=InpSingleSlaveComment;
      x.profile=InpProfile;
      x.mult=InpLotMultiplier;
      if(x.channel=="" || x.mult<=0) return false;
      ArrayResize(o,1); o[0]=x;
      return true;
   }

   string ch[],co[],pr[],mu[];
   SplitClean(InpMasterChannels,';',ch);
   SplitClean(InpOwnerComments,';',co);
   SplitClean(InpMasterProfiles,';',pr);
   SplitClean(InpVolumeMultipliers,';',mu);

   int n=ArraySize(ch);
   if(n<1 || ArraySize(co)!=n || ArraySize(pr)!=n || ArraySize(mu)!=n) return false;

   ArrayResize(o,n);
   for(int i=0;i<n;i++)
   {
      o[i].channel=ch[i];
      o[i].comment=co[i];
      o[i].profile=ParseProfile(pr[i]);
      o[i].mult=StringToDouble(mu[i]);
      if(o[i].channel=="" || o[i].comment=="" || o[i].mult<=0) return false;
   }

   for(int i=0;i<n;i++)
      for(int j=i+1;j<n;j++)
         if(o[i].channel==o[j].channel || o[i].comment==o[j].comment) return false;

   return true;
}
bool IsPending(const ENUM_ORDER_TYPE t)
{
   return t==ORDER_TYPE_BUY_LIMIT || t==ORDER_TYPE_SELL_LIMIT ||
          t==ORDER_TYPE_BUY_STOP || t==ORDER_TYPE_SELL_STOP ||
          t==ORDER_TYPE_BUY_STOP_LIMIT || t==ORDER_TYPE_SELL_STOP_LIMIT;
}

bool MasterTicketIgnored(const string channel,const ulong ticket)
{
   if(InpIgnoreMasterTickets=="")
      return false;

   string list=InpIgnoreMasterTickets;
   StringReplace(list,",",";");

   string parts[];
   int n=StringSplit(list,';',parts);

   for(int i=0;i<n;i++)
   {
      string token=parts[i];
      StringTrimLeft(token);
      StringTrimRight(token);

      if(token=="")
         continue;

      // Optional scoped syntax: CHANNEL:TICKET
      int colon=StringFind(token,":");

      if(colon>=0)
      {
         string token_channel=StringSubstr(token,0,colon);
         string token_ticket=StringSubstr(token,colon+1);

         StringTrimLeft(token_channel);
         StringTrimRight(token_channel);
         StringTrimLeft(token_ticket);
         StringTrimRight(token_ticket);

         if(token_channel==channel &&
            (ulong)StringToInteger(token_ticket)==ticket)
            return true;
      }
      else
      {
         // Plain ticket: ignored for any configured Master channel.
         if((ulong)StringToInteger(token)==ticket)
            return true;
      }
   }

   return false;
}

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

bool SlaveSymbolAllowed(const string symbol)
{
   if(InpSlaveSymbolsIgnore!="" &&
      SymbolListContains(InpSlaveSymbolsIgnore,symbol))
      return false;

   if(InpSlaveSymbolsFilter=="")
      return true;

   return SymbolListContains(InpSlaveSymbolsFilter,symbol);
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
bool Tg(const string msg)
{
   if(!InpEnableTelegram || InpTelegramBotToken=="" || InpTelegramChatID=="") return false;
   string url="https://api.telegram.org/bot"+InpTelegramBotToken+
              "/sendMessage?chat_id="+UrlEncode(InpTelegramChatID)+"&text="+UrlEncode(msg);
   char post[],res[]; string hdr;
   ResetLastError();
   int http=WebRequest("GET",url,"","",InpTelegramTimeoutMs,post,0,res,hdr);
   if(http==200) return true;
   PrintFormat("[CM SLAVE] Telegram fail HTTP=%d Error=%d",http,GetLastError());
   return false;
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

//---------------- snapshot ----------------
void AddPos(PosRec &a[],const PosRec &x){ int n=ArraySize(a); ArrayResize(a,n+1); a[n]=x; }
void AddOrd(OrdRec &a[],const OrdRec &x){ int n=ArraySize(a); ArrayResize(a,n+1); a[n]=x; }

bool ReadSnap(const string channel,Snap &s)
{
   s.channel=channel;s.nick="";s.account=0;s.written=0;s.open_total=0;s.pending_total=0;s.valid=false;s.fresh=false;
   ArrayResize(s.pos,0); ArrayResize(s.ord,0);

   int h=FileOpen(SnapFile(channel),FILE_COMMON|FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h==INVALID_HANDLE) return false;
   bool meta=false,en=false;

   while(!FileIsEnding(h))
   {
      string line=FileReadString(h); if(line=="")continue;
      string p[]; int n=StringSplit(line,'|',p); if(n<=0)continue;
      if(p[0]=="META" && n>=8 && p[1]=="1" && !meta)
      {
         s.written=(long)StringToInteger(p[2]);s.channel=p[3];s.nick=p[4];s.account=(long)StringToInteger(p[5]);
         s.open_total=(int)StringToInteger(p[6]);s.pending_total=(int)StringToInteger(p[7]);meta=true;
      }
      else if(p[0]=="POS" && n>=8)
      {
         PosRec x; x.ticket=(ulong)StringToInteger(p[1]);x.symbol=p[2];x.type=(int)StringToInteger(p[3]);
         x.vol=StringToDouble(p[4]);x.price=StringToDouble(p[5]);x.sl=StringToDouble(p[6]);x.tp=StringToDouble(p[7]);AddPos(s.pos,x);
      }
      else if(p[0]=="ORD" && n>=8)
      {
         OrdRec x; x.ticket=(ulong)StringToInteger(p[1]);x.symbol=p[2];x.type=(int)StringToInteger(p[3]);
         x.vol=StringToDouble(p[4]);x.price=StringToDouble(p[5]);x.sl=StringToDouble(p[6]);x.tp=StringToDouble(p[7]);AddOrd(s.ord,x);
      }
      else if(p[0]=="END")
      {
         en=true;
         break;
      }
   }
   FileClose(h);
   s.valid=meta&&en&&s.channel==channel &&
           s.open_total==ArraySize(s.pos) &&
           s.pending_total==ArraySize(s.ord);
   if(!s.valid)return false;
   long age=(long)TimeLocal()-s.written;
   s.fresh=age>=0 && age<=InpSnapshotStaleSeconds;
   return true;
}

//---------------- symbol mapping ----------------
bool SymbolEq(const string channel,const string ms,const string ss)
{
   if(ms==ss) return true;
   if(InpSymbolMaps=="") return false;
   string e[]; SplitClean(InpSymbolMaps,';',e);
   for(int i=0;i<ArraySize(e);i++)
   {
      string f[]; int n=StringSplit(e[i],',',f); if(n<3)continue;
      for(int k=0;k<3;k++){StringTrimLeft(f[k]);StringTrimRight(f[k]);}
      if(f[0]==channel && f[1]==ms && f[2]==ss) return true;
   }
   return false;
}
string ExpectedSlaveSymbol(const string channel,const string master_symbol)
{
   if(InpSymbolMaps=="") return master_symbol;
   string e[]; SplitClean(InpSymbolMaps,';',e);
   for(int i=0;i<ArraySize(e);i++)
   {
      string f[]; int n=StringSplit(e[i],',',f); if(n<3)continue;
      for(int k=0;k<3;k++){StringTrimLeft(f[k]);StringTrimRight(f[k]);}
      if(f[0]==channel && f[1]==master_symbol) return f[2];
   }
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
   return
      "Estado: ORDEN PENDIENTE\n"+
      "Tipo: "+OrderTypeText(order.type)+"\n"+
      "Símbolo Master: "+order.symbol+"\n"+
      "Símbolo esperado Slave: "+slave_symbol+"\n"+
      "Ticket Master: "+StringFormat("%I64u",order.ticket)+"\n\n"+
      "Volumen Master: "+VolumeText(slave_symbol,order.vol)+"\n"+
      "Volumen que debe aparecer en Slave: "+VolumeText(slave_symbol,expected_volume)+"\n"+
      "Precio de entrada: "+PriceText(order.price)+"\n"+
      "Stop Loss: "+StopText(order.sl,"SIN SL")+"\n"+
      "Take Profit: "+StopText(order.tp,"SIN TP");
}
string SlavePendingDetails(const OrdRec &order)
{
   return
      "Estado: ORDEN PENDIENTE\n"+
      "Tipo: "+OrderTypeText(order.type)+"\n"+
      "Símbolo: "+order.symbol+"\n"+
      "Ticket Slave: "+StringFormat("%I64u",order.ticket)+"\n"+
      "Volumen Slave: "+VolumeText(order.symbol,order.vol)+"\n"+
      "Precio de entrada: "+PriceText(order.price)+"\n"+
      "Stop Loss: "+StopText(order.sl,"SIN SL")+"\n"+
      "Take Profit: "+StopText(order.tp,"SIN TP");
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
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong tk=PositionGetTicket(i); if(tk==0)continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
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
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong tk=OrderGetTicket(i);if(tk==0)continue;
      ENUM_ORDER_TYPE t=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);if(!IsPending(t))continue;
      string symbol=OrderGetString(ORDER_SYMBOL);
      if(!SlaveSymbolAllowed(symbol))continue;
      string c=OrderGetString(ORDER_COMMENT);if(!OwnerCommentMatch(o,c))continue;
      OrdRec x;x.ticket=tk;x.symbol=symbol;x.type=(int)t;x.vol=OrderGetDouble(ORDER_VOLUME_CURRENT);
      x.price=OrderGetDouble(ORDER_PRICE_OPEN);x.sl=OrderGetDouble(ORDER_SL);x.tp=OrderGetDouble(ORDER_TP);AddOrd(a,x);
   }
}
bool VolEq(const string ss,double actual,double expected)
{
   double step=SymbolInfoDouble(ss,SYMBOL_VOLUME_STEP);if(step<=0)step=0.01;
   double normalized=ExpectedSlaveVolume(ss,expected,1.0);
   return MathAbs(actual-normalized)<=MathMax(1,InpVolumeToleranceSteps)*step+1e-9;
}
double PointOf(const string s){ double p=SymbolInfoDouble(s,SYMBOL_POINT); return p>0?p:0.00001; }
bool StopEq(double a,double b,double tol)
{
   bool az=MathAbs(a)<1e-12,bz=MathAbs(b)<1e-12;
   if(az&&bz)return true; if(az!=bz)return false; return MathAbs(a-b)<=tol;
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
            "Volumen que debe aparecer en Slave: "+VolumeText(slave_symbol,expected_volume)+"\n"+
            "Precio de entrada: "+PriceText(snap.pos[i].price)+"\n"+
            "Stop Loss: "+StopText(snap.pos[i].sl,"SIN SL")+"\n"+
            "Take Profit: "+StopText(snap.pos[i].tp,"SIN TP");
         continue;
      }

      su[best]=true;

      double tol=InpSLTPTolerancePoints*PointOf(sp[best].symbol);

      bool sl_bad=InpCheckStopLoss && !StopEq(snap.pos[i].sl,sp[best].sl,tol);
      bool tp_bad=InpCheckTakeProfit && !StopEq(snap.pos[i].tp,sp[best].tp,tol);

      if(sl_bad || tp_bad)
      {
         problems=true;
         details+=
            "\n\nPROBLEMA:\nLa posición copiada tiene valores diferentes.\n\n"+
            "Estado: POSICIÓN ACTIVA\n"+
            "Tipo: "+PositionTypeText(snap.pos[i].type)+"\n"+
            "Símbolo: "+sp[best].symbol+"\n"+
            "Ticket Master: "+StringFormat("%I64u",snap.pos[i].ticket)+"\n"+
            "Ticket Slave: "+StringFormat("%I64u",sp[best].ticket)+"\n";

         if(sl_bad)
            details+=
               "\nSL Master: "+StopText(snap.pos[i].sl,"SIN SL")+
               "\nSL Slave: "+StopText(sp[best].sl,"SIN SL");

         if(tp_bad)
            details+=
               "\nTP Master: "+StopText(snap.pos[i].tp,"SIN TP")+
               "\nTP Slave: "+StopText(sp[best].tp,"SIN TP");
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
      msg+="\nCopyMonitor no modifica posiciones automáticamente.";

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
   if(MathAbs(m.price-s.price)>InpPendingPriceTolerancePoints*PointOf(s.symbol))return false;
   return true;
}
int CandIndex(ulong tk)
{
   for(int i=0;i<ArraySize(g_candidates);i++)if(g_candidates[i].ticket==tk)return i;
   return -1;
}
bool ConfirmExtra(ulong tk,const string ch)
{
   datetime now=TimeLocal();int i=CandIndex(tk);
   if(i<0){i=ArraySize(g_candidates);ArrayResize(g_candidates,i+1);g_candidates[i].ticket=tk;g_candidates[i].channel=ch;g_candidates[i].first_seen=now;return InpExtraPendingConfirmSeconds<=0;}
   if(g_candidates[i].channel!=ch){g_candidates[i].channel=ch;g_candidates[i].first_seen=now;return false;}
   return (now-g_candidates[i].first_seen)>=InpExtraPendingConfirmSeconds;
}
void RemoveCand(ulong tk)
{
   int i=CandIndex(tk);if(i<0)return;int n=ArraySize(g_candidates);
   for(int j=i;j<n-1;j++)g_candidates[j]=g_candidates[j+1];ArrayResize(g_candidates,n-1);
}
bool StillOwnedPending(const Owner &o,ulong tk,OrdRec &x)
{
   if(!OrderSelect(tk))return false;
   ENUM_ORDER_TYPE t=(ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);if(!IsPending(t))return false;
   string symbol=OrderGetString(ORDER_SYMBOL);
   if(!SlaveSymbolAllowed(symbol))return false;
   if(!OwnerCommentMatch(o,OrderGetString(ORDER_COMMENT)))return false;
   x.ticket=tk;x.symbol=symbol;x.type=(int)t;x.vol=OrderGetDouble(ORDER_VOLUME_CURRENT);
   x.price=OrderGetDouble(ORDER_PRICE_OPEN);x.sl=OrderGetDouble(ORDER_SL);x.tp=OrderGetDouble(ORDER_TP);return true;
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
         RemoveCand(so[best].ticket);
         ClearAlert("PEXTRA|"+o.channel+"|"+
                    StringFormat("%I64u",so[best].ticket));
         ClearAlert("PAMB|"+o.channel+"|"+
                    StringFormat("%I64u",so[best].ticket));
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
         RemoveCand(so[best].ticket);
         ClearAlert("PEXTRA|"+o.channel+"|"+
                    StringFormat("%I64u",so[best].ticket));
         ClearAlert("PAMB|"+o.channel+"|"+
                    StringFormat("%I64u",so[best].ticket));
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
         msg+="\n\nACCIÓN:\nCrear o revisar estas órdenes en la cuenta Slave "+
              AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN))+".";
         msg+="\nCopyMonitor no abre órdenes automáticamente.";
         PersistAlert(
            "PMISS|"+o.channel,
            msg);
      }
      else
      {
         ClearAlert("PMISS|"+o.channel);
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

      ClearAlert(
         "PAMB|"+o.channel+"|"+
         StringFormat("%I64u",so[s].ticket));

      if(!ConfirmExtra(so[s].ticket,o.channel))
         continue;

      string key=
         "PEXTRA|"+o.channel+"|"+
         StringFormat("%I64u",so[s].ticket);

      if(!InpAutoDeleteExtraPending)
      {
         string msg=AlertHeader(snap,"🟠 COPYMONITOR — ALERTA")+
            "\n\nPROBLEMA:\nExiste una orden pendiente extra en el Slave.\n\n"+
            SlavePendingDetails(so[s])+
            "\n\nACCIÓN:\nRevisar la cuenta Slave "+
            AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN))+"."+
            "\nEl borrado automático está desactivado.";
         PersistAlert(
            key,
            msg);

         continue;
      }

      // Final safety re-check.
      OrdRec live;

      if(!StillOwnedPending(o,so[s].ticket,live))
         continue;

      ResetLastError();
      bool ok=g_trade.OrderDelete(so[s].ticket);

      string detail=
         "\n\nPROBLEMA:\nSe encontró una orden pendiente extra en el Slave.\n\n"+
         SlavePendingDetails(live);

      if(ok)
      {
         string msg=AlertHeader(snap,"🟢 COPYMONITOR — RESUELTO")+detail+
            "\n\nACCIÓN:\nLa orden pendiente fue eliminada correctamente.";

         if(InpNotifyDeleteSuccess)
            Tg(msg);

         RemoveCand(so[s].ticket);
         ClearAlert(key);
      }
      else
      {
         string msg=AlertHeader(snap,"🔴 COPYMONITOR — CRÍTICO")+detail+
            "\n\nACCIÓN:\nNo se pudo eliminar la orden pendiente."+
            "\nRevisar manualmente la cuenta Slave "+
            AccountText((long)AccountInfoInteger(ACCOUNT_LOGIN))+"."+
            "\nRetcode: "+IntegerToString((int)g_trade.ResultRetcode())+
            "\nDetalle: "+g_trade.ResultRetcodeDescription()+
            "\nError MQL: "+IntegerToString(GetLastError());

         if(InpNotifyDeleteFailure)
            PersistAlert(key,msg);
      }
   }
}

//---------------- panel/cycle ----------------
void ProcessOwner(const Owner &o,const Snap &s)
{
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
   CheckOpen(o,s);
   CheckPending(o,s);
}
void Panel(const Owner &o[],const Snap &s[])
{
   if(!InpShowPanel){Comment("");return;}
   string p="COPYMONITOR SLAVE v1.15 MULTI\n";
   p+="MultiMaster: "+(InpMultiMaster?"ON":"OFF")+"\nSlave: "+InpAccountNick+"\n\n";
   for(int i=0;i<ArraySize(o);i++)
   {
      PosRec sp[];SlavePosForOwner(o[i],sp);
      p+=o[i].channel+" | "+ProfileText(o[i].profile);
      if(InpMultiMaster)p+=" | "+o[i].comment;
      p+=" | "+(!s[i].valid?"NO DATA":(!s[i].fresh?"STALE":"ONLINE"))+"\n";
      p+="  Open M/S: "+IntegerToString(s[i].open_total)+"/"+IntegerToString(ArraySize(sp))+"\n";
   }
   p+="\nIgnored MASTER tickets: "+(InpIgnoreMasterTickets=="" ? "NONE" : InpIgnoreMasterTickets)+"\n";
   p+="Slave include symbols: "+(InpSlaveSymbolsFilter=="" ? "ALL" : InpSlaveSymbolsFilter)+"\n";
   p+="Slave ignore symbols: "+(InpSlaveSymbolsIgnore=="" ? "NONE" : InpSlaveSymbolsIgnore)+"\n";
   p+="Open positions: monitor only (SL/TP included)\n";
   p+="Pending copies expected: "+(InpExpectPendingCopies?"YES":"NO")+"\n";
   p+="Extra pending auto-delete: "+(InpAutoDeleteExtraPending?"YES":"NO");
   Comment(p);
}
void Cycle()
{
   if(g_busy)return;g_busy=true;
   Owner o[];if(!LoadOwners(o)){g_busy=false;return;}
   Snap s[];ArrayResize(s,ArraySize(o));
   for(int i=0;i<ArraySize(o);i++){ReadSnap(o[i].channel,s[i]);ProcessOwner(o[i],s[i]);}
   Panel(o,s);g_busy=false;
}
bool Validate()
{
   if(InpSlaveID=="" || InpMonitorSeconds<1 ||
      InpSnapshotStaleSeconds<InpMonitorSeconds ||
      InpMismatchReminderSeconds<1 || InpTelegramTimeoutMs<1 ||
      InpEntryPriceTolerancePoints<0 || InpSLTPTolerancePoints<0 ||
      InpVolumeToleranceSteps<0 || InpPendingPriceTolerancePoints<0 ||
      InpExtraPendingConfirmSeconds<0)
      return false;
   Owner o[];return LoadOwners(o);
}
int OnInit()
{
   if(!Validate())return INIT_PARAMETERS_INCORRECT;
   g_trade.SetAsyncMode(false);
   Cycle();
   if(!EventSetTimer(InpMonitorSeconds))return INIT_FAILED;
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason){EventKillTimer();Comment("");}
void OnTimer(){Cycle();}
void OnTradeTransaction(const MqlTradeTransaction &t,const MqlTradeRequest &r,const MqlTradeResult &x){Cycle();}
//+------------------------------------------------------------------+
