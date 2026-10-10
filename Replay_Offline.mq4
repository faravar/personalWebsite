//+------------------------------------------------------------------+
//|                                                Replay_Offline.mq4 |
//|  Soft4FX-style market replay for MT4 using an OFFLINE CHART.      |
//|                                                                  |
//|  How it works                                                    |
//|   1) Attach to a normal chart (e.g. USDCHF): the EA writes        |
//|      history files for a replay symbol "USDCHF_R" (all TFs).      |
//|   2) File > Open Offline > USDCHF_R > M1 > Open.                  |
//|   3) Apply your template + attach this EA to the offline chart.   |
//|  The offline chart's last bar IS the replay bar: no future bars   |
//|  exist, so candles AND indicators are 100% leak-free, and the     |
//|  chart shift margin / TF buttons work natively.                   |
//|                                                                  |
//|  REQUIRES: "Allow DLL imports" (only user32.dll PostMessage is    |
//|  used, to refresh the offline chart).                             |
//+------------------------------------------------------------------+
#property copyright "Farhad Karimzadeh"
#property version   "3.00"
#property strict

#import "user32.dll"
int PostMessageA(int hWnd, int Msg, int wParam, int lParam);
int RegisterWindowMessageW(string lpString);
int GetParent(int hWnd);
int GetAncestor(int hWnd, int gaFlags);
#import
#import "shell32.dll"
int ShellExecuteW(int hwnd, string lpOperation, string lpFile, string lpParameters, string lpDirectory, int nShowCmd);
#import

//--- inputs
input string InpSuffix       = "_R";   // Replay symbol suffix
input string InpStartDate    = "";     // Start "YYYY.MM.DD HH:MM" (empty = auto)
input bool   InpForceStart   = false;  // Setup: ignore saved position, use start date
input double InpDeposit      = 10000;  // Virtual deposit
input double InpLot          = 0.10;   // Default lot
input double InpRiskPct      = 1.0;    // Default risk % (Risk mode)
input int    InpSL           = 20;     // Default SL (pips, 0 = none)
input int    InpTP           = 40;     // Default TP (pips, 0 = none)
input int    InpSpreadPts    = 15;     // Spread (points)
input double InpCommission   = 0.0;    // Commission per lot (round turn)
input bool   InpPauseOnClose = true;   // Pause when SL/TP is hit
input int    InpHistoryBars  = 3000;   // Bars of history per timeframe
input bool   InpDebugAlerts  = false;  // Show diagnostic pop-up alerts (leave off)
input int    InpTrailPips    = 15;     // Default trailing distance (pips)
input int    InpTicksPerBar  = 12;     // Simulated ticks per M1 bar (moves the candle like live, min 4)
input int    InpPanelX       = 10;     // Panel X
input int    InpPanelY       = 20;     // Panel Y

//--- virtual trade
struct VTrade
{
   int      id;
   int      type;
   double   lots;
   double   open;
   double   sl;
   double   tp;
   datetime topen;
   bool     closed;
   double   close;
   datetime tclose;
   double   profit;
   bool     pend;      // pending order, not filled yet
   int      kind;      // 2 buy limit, 3 sell limit, 4 buy stop, 5 sell stop
   bool     hidden;    // hide arrow / line marks
   bool     marked;    // marks already drawn
};

//--- state
string   g_src = "", g_rsym = "";
bool     g_replayChart = false;
bool     g_ready = false;
int      g_tf = 0;
double   g_pt = 0;
int      g_dg = 0;
int      g_tfs[9] = {1, 5, 15, 30, 60, 240, 1440, 10080, 43200};

int      g_h = -1;                 // (unused: file is opened only while writing)
bool     g_dirty = false;
datetime g_lastBo[9];
bool     g_tfOpen[9];
double   g_slPrice = 0, g_tpPrice = 0;      // SL/TP typed as price (one-shot)
string   g_txtLot = "", g_txtSL = "", g_txtTP = "", g_txtGo = "", g_txtTrail = "";
int      g_trailPips = 15;
bool     g_visual = true;               // draw SL/TP lines before opening an order
int      g_visMode = 0, g_visDir = 0;   // 0 none, 1 market order, 2 pending order
double   g_visEntry = 0;
bool     g_orderEvent = false, g_stopRun = false, g_syncNeeded = false;
long     g_ch[];
int      g_nCh = 0;
int      pN = 0;                   // finished bars not yet written
datetime pBo[];
double   pO[], pH[], pL[], pC[];
long     pV[];
datetime g_bo = 0;                 // running bar
double   g_bOpen = 0, g_bHigh = 0, g_bLow = 0, g_bClose = 0;
long     g_bVol = 0;
int      g_hwnd = 0, g_hwndP = 0, g_hwndR = 0, g_msg4 = 0;

VTrade   g_tr[];
int      g_nextId = 1;
double   g_balance = 0;
datetime g_t = 0;                  // replay clock = open time of last revealed M1 bar
bool     g_play = false;
double   g_speeds[10] = {0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 100, 300};  // M1 bars per second
int      g_sub = 0;                // ticks already revealed in the M1 bar after g_t
int      g_speedIdx = 3;
void SyncTradeObjects(bool full);
double   g_acc = 0;
double   g_lot, g_risk;
int      g_sl, g_tp;
bool     g_riskMode = false;
bool     g_trail = false;
bool     g_pauseClose = true;
bool     g_minimized = false;
bool     g_resetArmed = false;
string   g_dbg = "", g_msg = "";
int      g_diagCount = 0;
datetime g_msgTime = 0;

//--- colors
color C_BG     = C'24,26,32';
color C_BORDER = C'60,64,75';
color C_TEXT   = C'220,224,232';
color C_MUTED  = C'140,146,160';
color C_BTN    = C'45,49,60';
color C_BUY    = C'22,163,74';
color C_SELL   = C'220,38,38';
color C_ACCENT = C'59,130,246';

#define PNL      "BTP_"
#define PANEL_W  260
#define PANEL_H  620

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
void Diag(string t)
{
   Print(t);
   if(InpDebugAlerts && g_diagCount < 12) { g_diagCount++; Alert(t); }
}

double PipSize() { return (g_dg == 3 || g_dg == 5) ? g_pt * 10.0 : g_pt; }
double Spr()     { return InpSpreadPts * g_pt; }
string FmtTime(datetime t) { return TimeToString(t, TIME_DATE | TIME_MINUTES); }

double NormLot(double lots)
{
   double step = MarketInfo(g_src, MODE_LOTSTEP);
   double minL = MarketInfo(g_src, MODE_MINLOT);
   double maxL = MarketInfo(g_src, MODE_MAXLOT);
   if(step <= 0) step = 0.01;
   lots = MathFloor(lots / step + 1e-8) * step;
   lots = MathMax(minL, MathMin(maxL, lots));
   return NormalizeDouble(lots, 2);
}

int M1() { return iBarShift(g_src, PERIOD_M1, g_t, false); }

int KT() { return MathMax(4, InpTicksPerBar); }

// synthetic intra-bar price path: O -> first extreme -> second extreme -> C (bullish bars dip first)
double TickPrice(int nm, int j)
{
   int K = KT();
   double O = iOpen(g_src, PERIOD_M1, nm);
   double C = iClose(g_src, PERIOD_M1, nm);
   if(j <= 0) return O;
   if(j >= K) return C;
   double H = iHigh(g_src, PERIOD_M1, nm);
   double L = iLow(g_src, PERIOD_M1, nm);
   bool bull = (C >= O);
   double a1 = bull ? L : H;
   double a2 = bull ? H : L;
   int j1 = MathMax(1, (int)MathRound(K * 0.3));
   int j2 = MathMax(j1 + 1, (int)MathRound(K * 0.7));
   if(j2 >= K) j2 = K - 1;
   double p;
   if(j <= j1)      p = O + (a1 - O) * j / j1;
   else if(j <= j2) p = a1 + (a2 - a1) * (double)(j - j1) / (j2 - j1);
   else             p = a2 + (C - a2) * (double)(j - j2) / (K - j2);
   if(j != j1 && j != j2)
   {
      double x = MathSin((double)iTime(g_src, PERIOD_M1, nm) * 0.00123 + j * 12.9898) * 43758.5453;
      double r = x - MathFloor(x);
      p += (r - 0.5) * (H - L) * 0.2;
      p = MathMax(L, MathMin(H, p));
   }
   return NormalizeDouble(p, g_dg);
}

// forming M1 bar after j revealed ticks
void SubBar(int nm, int j, double &o, double &h, double &l, double &c)
{
   o = iOpen(g_src, PERIOD_M1, nm);
   h = o; l = o; c = o;
   for(int k = 1; k <= j; k++)
   {
      double p = TickPrice(nm, k);
      if(p > h) h = p;
      if(p < l) l = p;
      c = p;
   }
}

// time of the M1 bar the replay is currently inside
datetime CurClock()
{
   if(g_sub > 0)
   {
      int m = M1();
      if(m > 0) return iTime(g_src, PERIOD_M1, m - 1);
   }
   return g_t;
}

double CurBid()
{
   int m = M1();
   if(m < 0) return 0;
   if(g_sub > 0 && m > 0) return TickPrice(m - 1, g_sub);
   return iClose(g_src, PERIOD_M1, m);
}

double CalcProfit(int type, double lots, double open, double close, bool withComm)
{
   double diff = (type == OP_BUY) ? (close - open) : (open - close);
   double ts = MarketInfo(g_src, MODE_TICKSIZE);
   double tv = MarketInfo(g_src, MODE_TICKVALUE);
   if(ts <= 0) return 0;
   double p = diff / ts * tv * lots;
   if(withComm) p -= InpCommission * lots;
   return p;
}

double CalcLotDist(double slDist)
{
   if(g_riskMode && slDist > 0)
   {
      double ts = MarketInfo(g_src, MODE_TICKSIZE);
      double tv = MarketInfo(g_src, MODE_TICKVALUE);
      if(ts > 0 && tv > 0)
      {
         double riskMoney = g_balance * g_risk / 100.0;
         double slMoney   = (slDist / ts) * tv;
         if(slMoney > 0) return NormLot(riskMoney / slMoney);
      }
   }
   return NormLot(g_lot);
}

double CalcLot()
{
   double d = g_sl * PipSize();
   if(g_slPrice > 0) d = MathAbs(CurBid() + Spr() - g_slPrice);
   return CalcLotDist(d);
}

//+------------------------------------------------------------------+
//| History file (.hst v401) writer                                  |
//+------------------------------------------------------------------+
void WriteFixedStr(int h, string s, int len)
{
   for(int i = 0; i < len; i++)
   {
      int ch = (i < StringLen(s)) ? StringGetChar(s, i) : 0;
      FileWriteInteger(h, ch, CHAR_VALUE);
   }
}

void WriteHeader(int h, int tf)
{
   FileWriteInteger(h, 401, LONG_VALUE);
   WriteFixedStr(h, "(C)opyright", 64);
   WriteFixedStr(h, g_rsym, 12);
   FileWriteInteger(h, tf, LONG_VALUE);
   FileWriteInteger(h, g_dg, LONG_VALUE);
   FileWriteInteger(h, 0, LONG_VALUE);     // timesign
   FileWriteInteger(h, 0, LONG_VALUE);     // last sync
   for(int i = 0; i < 13; i++) FileWriteInteger(h, 0, LONG_VALUE);
}

void WriteBar(int h, datetime t, double o, double hi, double lo, double c, long v)
{
   FileWriteLong(h, (long)t);
   FileWriteDouble(h, NormalizeDouble(o, g_dg));
   FileWriteDouble(h, NormalizeDouble(hi, g_dg));
   FileWriteDouble(h, NormalizeDouble(lo, g_dg));
   FileWriteDouble(h, NormalizeDouble(c, g_dg));
   FileWriteLong(h, v);
   FileWriteInteger(h, 0, LONG_VALUE);     // spread
   FileWriteLong(h, 0);                    // real volume
}

// bar of timeframe tf that contains the replay clock, built from M1 data
bool PartialBar(int tf, datetime &bo, double &o, double &h, double &l, double &c, long &v)
{
   int m = M1();                       // last completed M1 bar
   if(m < 0) return false;
   int nm = -1;                        // M1 bar being formed (tick mode)
   double po = 0, ph = 0, pl = 0, pc = 0;
   datetime tcur = g_t;
   if(g_sub > 0 && m > 0)
   {
      nm = m - 1;
      tcur = iTime(g_src, PERIOD_M1, nm);
      SubBar(nm, g_sub, po, ph, pl, pc);
   }
   int st = iBarShift(g_src, tf, tcur, false);
   if(st < 0) return false;
   bo = iTime(g_src, tf, st);
   int newest = (nm >= 0) ? nm : m;
   int s = iBarShift(g_src, PERIOD_M1, bo, false);
   if(s < 0) return false;
   if(iTime(g_src, PERIOD_M1, s) < bo && s > newest) s--;
   if(s < newest) s = newest;
   if(nm >= 0 && s <= nm)
   {
      o = po; h = ph; l = pl; c = pc; v = 1;      // this TF bar starts with the forming M1 bar
      return true;
   }
   int cnt = s - m + 1;
   o = iOpen(g_src, PERIOD_M1, s);
   c = (nm >= 0) ? pc : iClose(g_src, PERIOD_M1, m);
   h = iHigh(g_src, PERIOD_M1, iHighest(g_src, PERIOD_M1, MODE_HIGH, cnt, m));
   l = iLow(g_src, PERIOD_M1, iLowest(g_src, PERIOD_M1, MODE_LOW, cnt, m));
   if(nm >= 0) { h = MathMax(h, ph); l = MathMin(l, pl); }
   v = cnt;
   return true;
}

int TfIdx(int tf)
{
   for(int i = 0; i < 9; i++) if(g_tfs[i] == tf) return i;
   return -1;
}

bool IsOpenTf(int idx)
{
   return (g_tfs[idx] == g_tf || WindowHandle(g_rsym, g_tfs[idx]) != 0);
}

datetime CurBarOpen(int tf)
{
   int st = iBarShift(g_src, tf, CurClock(), false);
   if(st < 0) return 0;
   return iTime(g_src, tf, st);
}

// rebuild the history file of one timeframe up to the replay clock
bool BuildHistory(int tf, bool keepOpen)
{
   datetime bo; double o, h, l, c; long v;
   if(!PartialBar(tf, bo, o, h, l, c, v)) return false;
   int sNow = iBarShift(g_src, tf, bo, false);
   if(sNow < 0) return false;
   int total = iBars(g_src, tf);
   int cnt = MathMin(InpHistoryBars, total - 1 - sNow);
   if(cnt < 0) cnt = 0;

   string name = g_rsym + IntegerToString(tf) + ".hst";
   int fh = FileOpenHistory(name, FILE_BIN | FILE_WRITE | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh < 0) { Diag("Replay: cannot open " + name + " err=" + IntegerToString(GetLastError())); return false; }
   WriteHeader(fh, tf);
   for(int s = sNow + cnt; s > sNow; s--)
      WriteBar(fh, iTime(g_src, tf, s), iOpen(g_src, tf, s), iHigh(g_src, tf, s),
               iLow(g_src, tf, s), iClose(g_src, tf, s), iVolume(g_src, tf, s));
   WriteBar(fh, bo, o, h, l, c, v);
   FileClose(fh);
   int ix = TfIdx(tf);
   if(ix >= 0) g_lastBo[ix] = bo;
   return true;
}

// (re)build the files of every timeframe that has an open replay chart
void BuildAllOpen()
{
   for(int i = 0; i < 9; i++)
   {
      if(IsOpenTf(i)) { BuildHistory(g_tfs[i], true); g_tfOpen[i] = true; }
      else g_tfOpen[i] = false;
   }
}

void PostRefresh(int hw)
{
   if(hw == 0) return;
   PostMessageA(hw, 0x0111, 0x822C, 0);                 // WM_COMMAND / Charts > Refresh
   if(g_msg4 != 0) PostMessageA(hw, g_msg4, 2, 1);      // MT4 internal refresh
}

void RefreshChart()
{
   for(int i = 0; i < 9; i++)
   {
      int hw = WindowHandle(g_rsym, g_tfs[i]);
      if(hw == 0) continue;
      PostRefresh(hw);
      PostRefresh(GetParent(hw));
      PostRefresh(GetAncestor(hw, 2));
   }
}

// bring the file of one timeframe up to the replay clock (file is open only while writing)
void WriteTfUpdate(int idx)
{
   int tf = g_tfs[idx];
   datetime bo; double o, h, l, c; long v;
   if(!PartialBar(tf, bo, o, h, l, c, v)) return;
   int sLast = (g_lastBo[idx] > 0) ? iBarShift(g_src, tf, g_lastBo[idx], true) : -1;
   int stNow = iBarShift(g_src, tf, bo, false);
   if(bo != g_lastBo[idx] && (sLast < 0 || stNow < 0)) { BuildHistory(tf, true); return; }

   string name = g_rsym + IntegerToString(tf) + ".hst";
   int fh = FileOpenHistory(name, FILE_BIN | FILE_READ | FILE_WRITE | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh < 0) { Diag("Replay: flush cannot open " + name + " err=" + IntegerToString(GetLastError())); return; }
   FileSeek(fh, -60, SEEK_END);
   if(bo != g_lastBo[idx])
   {
      // finish the bar that was last in the file, then append the following ones
      for(int s = sLast; s > stNow; s--)
         WriteBar(fh, iTime(g_src, tf, s), iOpen(g_src, tf, s), iHigh(g_src, tf, s),
                  iLow(g_src, tf, s), iClose(g_src, tf, s), iVolume(g_src, tf, s));
   }
   WriteBar(fh, bo, o, h, l, c, v);
   FileClose(fh);
   g_lastBo[idx] = bo;
}

void FlushHistory()
{
   if(!g_dirty) return;
   g_dirty = false;
   for(int i = 0; i < 9; i++)
   {
      if(!IsOpenTf(i)) { g_tfOpen[i] = false; continue; }
      if(!g_tfOpen[i]) { BuildHistory(g_tfs[i], true); g_tfOpen[i] = true; continue; }
      WriteTfUpdate(i);
   }
}

void FlushRefresh()
{
   FlushHistory();
   if(g_syncNeeded) { SyncTradeObjects(false); g_syncNeeded = false; }
   RefreshChart();
}

//+------------------------------------------------------------------+
//| Persistence                                                      |
//+------------------------------------------------------------------+
string FN() { return "ReplayBT_" + g_src + ".csv"; }

void SaveState()
{
   int h = FileOpen(FN(), FILE_WRITE | FILE_CSV | FILE_ANSI, ';');
   if(h == INVALID_HANDLE) return;
   FileWrite(h, "H2", DoubleToString(g_balance, 2), g_nextId, (long)g_t,
             DoubleToString(g_lot, 2), DoubleToString(g_risk, 2), g_sl, g_tp,
             (int)g_riskMode, (int)g_trail, g_speedIdx, g_trailPips, (int)g_visual);
   for(int i = 0; i < ArraySize(g_tr); i++)
      FileWrite(h, "T2", g_tr[i].id, g_tr[i].type, DoubleToString(g_tr[i].lots, 2),
                DoubleToString(g_tr[i].open, 8), DoubleToString(g_tr[i].sl, 8),
                DoubleToString(g_tr[i].tp, 8), (long)g_tr[i].topen, (int)g_tr[i].closed,
                DoubleToString(g_tr[i].close, 8), (long)g_tr[i].tclose,
                DoubleToString(g_tr[i].profit, 2), (int)g_tr[i].pend, g_tr[i].kind, (int)g_tr[i].hidden);
   FileClose(h);
}

void LoadState()
{
   g_lot = InpLot; g_risk = InpRiskPct; g_sl = InpSL; g_tp = InpTP;
   g_trailPips = InpTrailPips; g_visual = true;
   g_balance = InpDeposit; g_nextId = 1; g_t = 0;
   ArrayResize(g_tr, 0);

   int h = FileOpen(FN(), FILE_READ | FILE_CSV | FILE_ANSI, ';');
   if(h == INVALID_HANDLE) return;
   while(!FileIsEnding(h))
   {
      string tag = FileReadString(h);
      if(tag == "H" || tag == "H2")
      {
         g_balance  = StrToDouble(FileReadString(h));
         g_nextId   = (int)StrToInteger(FileReadString(h));
         g_t        = (datetime)StrToInteger(FileReadString(h));
         g_lot      = StrToDouble(FileReadString(h));
         g_risk     = StrToDouble(FileReadString(h));
         g_sl       = (int)StrToInteger(FileReadString(h));
         g_tp       = (int)StrToInteger(FileReadString(h));
         g_riskMode = (StrToInteger(FileReadString(h)) != 0);
         g_trail    = (StrToInteger(FileReadString(h)) != 0);
         g_speedIdx = (int)StrToInteger(FileReadString(h));
         if(g_speedIdx < 0 || g_speedIdx > 9) g_speedIdx = 3;
         if(tag == "H2")
         {
            g_trailPips = (int)StrToInteger(FileReadString(h));
            g_visual    = (StrToInteger(FileReadString(h)) != 0);
            if(g_trailPips < 1) g_trailPips = InpTrailPips;
         }
      }
      else if(tag == "T" || tag == "T2")
      {
         int n = ArraySize(g_tr);
         ArrayResize(g_tr, n + 1);
         g_tr[n].id     = (int)StrToInteger(FileReadString(h));
         g_tr[n].type   = (int)StrToInteger(FileReadString(h));
         g_tr[n].lots   = StrToDouble(FileReadString(h));
         g_tr[n].open   = StrToDouble(FileReadString(h));
         g_tr[n].sl     = StrToDouble(FileReadString(h));
         g_tr[n].tp     = StrToDouble(FileReadString(h));
         g_tr[n].topen  = (datetime)StrToInteger(FileReadString(h));
         g_tr[n].closed = (StrToInteger(FileReadString(h)) != 0);
         g_tr[n].close  = StrToDouble(FileReadString(h));
         g_tr[n].tclose = (datetime)StrToInteger(FileReadString(h));
         g_tr[n].profit = StrToDouble(FileReadString(h));
         g_tr[n].pend = false; g_tr[n].kind = 0; g_tr[n].hidden = false; g_tr[n].marked = false;
         if(tag == "T2")
         {
            g_tr[n].pend   = (StrToInteger(FileReadString(h)) != 0);
            g_tr[n].kind   = (int)StrToInteger(FileReadString(h));
            g_tr[n].hidden = (StrToInteger(FileReadString(h)) != 0);
         }
      }
   }
   FileClose(h);
}

void InitStartTime()
{
   int n = iBars(g_src, PERIOD_M1);
   if(n <= 1) return;
   datetime oldest = iTime(g_src, PERIOD_M1, n - 1);
   datetime t = (InpStartDate != "") ? StrToTime(InpStartDate) : 0;
   if(t == 0 || t < oldest)
   {
      int s = MathMin(n - 1, 5000);
      t = iTime(g_src, PERIOD_M1, s);
   }
   int m = iBarShift(g_src, PERIOD_M1, t, false);
   g_t = iTime(g_src, PERIOD_M1, m);
}

//+------------------------------------------------------------------+
//| Trade objects on chart                                           |
//+------------------------------------------------------------------+
void CollectCharts()
{
   g_nCh = 0;
   long c = ChartFirst();
   while(c >= 0)
   {
      if(ChartSymbol(c) == g_rsym)
      {
         ArrayResize(g_ch, g_nCh + 1);
         g_ch[g_nCh] = c;
         g_nCh++;
      }
      c = ChartNext(c);
   }
}

int FindTrade(int tid)
{
   for(int i = 0; i < ArraySize(g_tr); i++) if(g_tr[i].id == tid) return i;
   return -1;
}

string KindName(int kind)
{
   if(kind == 2) return "BUY LIMIT";
   if(kind == 3) return "SELL LIMIT";
   if(kind == 4) return "BUY STOP";
   if(kind == 5) return "SELL STOP";
   return "";
}

void EnsureLineC(long cid, string name, double price, color col, ENUM_LINE_STYLE st, bool sel, string tip)
{
   if(price <= 0) { ObjectDelete(cid, name); return; }
   if(ObjectFind(cid, name) < 0)
   {
      ObjectCreate(cid, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(cid, name, OBJPROP_COLOR, col);
      ObjectSetInteger(cid, name, OBJPROP_STYLE, st);
      ObjectSetInteger(cid, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(cid, name, OBJPROP_SELECTABLE, sel);
      if(sel) ObjectSetInteger(cid, name, OBJPROP_SELECTED, true);
      ObjectSetString(cid, name, OBJPROP_TOOLTIP, tip);
   }
   else ObjectSetDouble(cid, name, OBJPROP_PRICE, price);
}

void DeleteTradeObjects(int tid)
{
   CollectCharts();
   string id = IntegerToString(tid);
   for(int c = 0; c < g_nCh; c++)
   {
      ObjectDelete(g_ch[c], "BTX_" + id + "_A");
      ObjectDelete(g_ch[c], "BTX_" + id + "_L");
      ObjectDelete(g_ch[c], "BTL_" + id + "_E");
      ObjectDelete(g_ch[c], "BTL_" + id + "_S");
      ObjectDelete(g_ch[c], "BTL_" + id + "_T");
   }
}

void RemoveTrade(int i)
{
   DeleteTradeObjects(g_tr[i].id);
   int n = ArraySize(g_tr);
   for(int j = i; j < n - 1; j++) g_tr[j] = g_tr[j + 1];
   ArrayResize(g_tr, n - 1);
}

// draw positions / pending orders on EVERY open replay chart (M1, M5, ...)
void SyncTradeObjects(bool full)
{
   CollectCharts();
   long me = ChartID();
   for(int i = 0; i < ArraySize(g_tr); i++)
   {
      string id = IntegerToString(g_tr[i].id);
      string na = "BTX_" + id + "_A";
      string nl = "BTX_" + id + "_L";
      string ne = "BTL_" + id + "_E";
      string ns = "BTL_" + id + "_S";
      string nt = "BTL_" + id + "_T";
      bool isBuy = (g_tr[i].type == OP_BUY);
      for(int c = 0; c < g_nCh; c++)
      {
         long cid = g_ch[c];
         bool mine = (cid == me);
         if(g_tr[i].pend)
         {
            ObjectDelete(cid, na);
            ObjectDelete(cid, nl);
            string tip = KindName(g_tr[i].kind) + " " + DoubleToString(g_tr[i].lots, 2) + " #" + id;
            EnsureLineC(cid, ne, g_tr[i].open, clrOrange, STYLE_DASHDOT, true, tip);
            EnsureLineC(cid, ns, g_tr[i].sl, C_SELL, STYLE_DASH, true, "SL #" + id);
            EnsureLineC(cid, nt, g_tr[i].tp, C_BUY, STYLE_DASH, true, "TP #" + id);
         }
         else if(g_tr[i].closed)
         {
            if(g_tr[i].hidden) { ObjectDelete(cid, na); ObjectDelete(cid, nl); ObjectDelete(cid, ne); ObjectDelete(cid, ns); ObjectDelete(cid, nt); continue; }
            if(!full && g_tr[i].marked) continue;
            ObjectDelete(cid, ne);
            ObjectDelete(cid, ns);
            ObjectDelete(cid, nt);
            if(ObjectFind(cid, na) < 0)
            {
               ObjectCreate(cid, na, isBuy ? OBJ_ARROW_BUY : OBJ_ARROW_SELL, 0, g_tr[i].topen, g_tr[i].open);
               ObjectSetInteger(cid, na, OBJPROP_SELECTABLE, true);
            }
            if(ObjectFind(cid, nl) < 0)
            {
               ObjectCreate(cid, nl, OBJ_TREND, 0, g_tr[i].topen, g_tr[i].open, g_tr[i].tclose, g_tr[i].close);
               ObjectSetInteger(cid, nl, OBJPROP_RAY_RIGHT, false);
               ObjectSetInteger(cid, nl, OBJPROP_STYLE, STYLE_DOT);
               ObjectSetInteger(cid, nl, OBJPROP_COLOR, g_tr[i].profit >= 0 ? C_BUY : C_SELL);
               ObjectSetInteger(cid, nl, OBJPROP_SELECTABLE, true);
            }
         }
         else
         {
            if(g_tr[i].hidden) ObjectDelete(cid, na);
            else if(ObjectFind(cid, na) < 0)
            {
               ObjectCreate(cid, na, isBuy ? OBJ_ARROW_BUY : OBJ_ARROW_SELL, 0, g_tr[i].topen, g_tr[i].open);
               ObjectSetInteger(cid, na, OBJPROP_SELECTABLE, true);
            }
            EnsureLineC(cid, ne, g_tr[i].open, C_ACCENT, STYLE_DOT, false, "Entry #" + id);
            EnsureLineC(cid, ns, g_tr[i].sl, C_SELL, STYLE_DASH, true, "SL #" + id);
            EnsureLineC(cid, nt, g_tr[i].tp, C_BUY, STYLE_DASH, true, "TP #" + id);
         }
      }
      if(g_tr[i].closed) g_tr[i].marked = true;
   }
}


//+------------------------------------------------------------------+
//| Virtual trading engine                                           |
//+------------------------------------------------------------------+
int OpenCount()
{
   int c = 0;
   for(int i = 0; i < ArraySize(g_tr); i++) if(!g_tr[i].closed && !g_tr[i].pend) c++;
   return c;
}

int OrdCount()
{
   int c = 0;
   for(int i = 0; i < ArraySize(g_tr); i++) if(!g_tr[i].closed) c++;
   return c;
}

bool OpenVirtual(int type)
{
   double bid = CurBid();
   if(bid <= 0) return false;
   double price = (type == OP_BUY) ? bid + Spr() : bid;
   double pip = PipSize();
   double sl = 0, tp = 0;
   if(g_slPrice < 0) sl = 0;
   else if(g_slPrice > 0) sl = g_slPrice;
   else if(g_sl > 0) sl = (type == OP_BUY) ? price - g_sl * pip : price + g_sl * pip;
   if(g_tpPrice < 0) tp = 0;
   else if(g_tpPrice > 0) tp = g_tpPrice;
   else if(g_tp > 0) tp = (type == OP_BUY) ? price + g_tp * pip : price - g_tp * pip;

   if(sl > 0 && ((type == OP_BUY && sl >= price) || (type == OP_SELL && sl <= price)))
   { g_msg = "SL is on the wrong side of the price"; g_msgTime = TimeLocal(); return false; }
   if(tp > 0 && ((type == OP_BUY && tp <= price) || (type == OP_SELL && tp >= price)))
   { g_msg = "TP is on the wrong side of the price"; g_msgTime = TimeLocal(); return false; }

   double slDist = (sl > 0) ? MathAbs(price - sl) : 0;
   int n = ArraySize(g_tr);
   ArrayResize(g_tr, n + 1);
   g_tr[n].id     = g_nextId++;
   g_tr[n].type   = type;
   g_tr[n].lots   = CalcLotDist(slDist);
   g_tr[n].open   = NormalizeDouble(price, g_dg);
   g_tr[n].sl     = NormalizeDouble(sl, g_dg);
   g_tr[n].tp     = NormalizeDouble(tp, g_dg);
   g_tr[n].topen  = CurClock();
   g_tr[n].closed = false;
   g_tr[n].close  = 0;
   g_tr[n].tclose = 0;
   g_tr[n].profit = 0;
   g_tr[n].pend = false; g_tr[n].kind = 0; g_tr[n].hidden = false; g_tr[n].marked = false;
   g_slPrice = 0; g_tpPrice = 0;          // typed price levels are used once
   g_txtSL = ""; g_txtTP = "";
   SyncTradeObjects(false);
   SaveState();
   return true;
}

void CloseAt(int i, double price)
{
   g_tr[i].close  = NormalizeDouble(price, g_dg);
   g_tr[i].tclose = CurClock();
   g_tr[i].closed = true;
   g_tr[i].marked = false;
   g_tr[i].profit = CalcProfit(g_tr[i].type, g_tr[i].lots, g_tr[i].open, g_tr[i].close, true);
   g_balance += g_tr[i].profit;
}

void CloseTrades(int filter, double fraction)
{
   double bid = CurBid();
   if(bid <= 0) return;
   double ask = bid + Spr();
   int total = ArraySize(g_tr);
   for(int i = 0; i < total; i++)
   {
      if(g_tr[i].closed || g_tr[i].pend) continue;
      if(filter != -1 && g_tr[i].type != filter) continue;
      double px = (g_tr[i].type == OP_BUY) ? bid : ask;
      if(fraction >= 1.0) { CloseAt(i, px); continue; }

      double part = NormLot(g_tr[i].lots * fraction);
      if(part >= g_tr[i].lots || part < MarketInfo(g_src, MODE_MINLOT)) continue;
      int n = ArraySize(g_tr);
      ArrayResize(g_tr, n + 1);
      g_tr[n] = g_tr[i];
      g_tr[n].id   = g_nextId++;
      g_tr[n].lots = part;
      CloseAt(n, px);
      g_tr[i].lots = NormalizeDouble(g_tr[i].lots - part, 2);
   }
   SyncTradeObjects(false);
   SaveState();
}

void MoveToBE()
{
   double bid = CurBid();
   if(bid <= 0) return;
   double ask = bid + Spr();
   for(int i = 0; i < ArraySize(g_tr); i++)
   {
      if(g_tr[i].closed || g_tr[i].pend) continue;
      if(g_tr[i].type == OP_BUY  && bid > g_tr[i].open && g_tr[i].sl < g_tr[i].open) g_tr[i].sl = g_tr[i].open;
      if(g_tr[i].type == OP_SELL && ask < g_tr[i].open && (g_tr[i].sl > g_tr[i].open || g_tr[i].sl == 0)) g_tr[i].sl = g_tr[i].open;
   }
   SyncTradeObjects(false);
   SaveState();
}

void RunTrailing()
{
   if(!g_trail || g_trailPips <= 0) return;
   double bid = CurBid();
   if(bid <= 0) return;
   double ask = bid + Spr();
   double d = g_trailPips * PipSize();
   double step = PipSize() * 0.5;
   for(int i = 0; i < ArraySize(g_tr); i++)
   {
      if(g_tr[i].closed || g_tr[i].pend) continue;
      if(g_tr[i].type == OP_BUY)
      {
         double ns = NormalizeDouble(bid - d, g_dg);
         if(bid - g_tr[i].open > d && (g_tr[i].sl == 0 || ns > g_tr[i].sl + step)) { g_tr[i].sl = ns; g_syncNeeded = true; }
      }
      else
      {
         double ns2 = NormalizeDouble(ask + d, g_dg);
         if(g_tr[i].open - ask > d && (g_tr[i].sl == 0 || ns2 < g_tr[i].sl - step)) { g_tr[i].sl = ns2; g_syncNeeded = true; }
      }
   }
}

// SL has priority if SL and TP are both inside the same M1 bar (conservative)
bool CheckStopsRange(double o, double h, double l)
{
   double sp = Spr();
   bool hit = false;
   for(int i = 0; i < ArraySize(g_tr); i++)
   {
      if(g_tr[i].closed || g_tr[i].pend) continue;
      double fill = 0;
      if(g_tr[i].type == OP_BUY)
      {
         if(g_tr[i].sl > 0 && l <= g_tr[i].sl)       fill = MathMin(g_tr[i].sl, o);
         else if(g_tr[i].tp > 0 && h >= g_tr[i].tp)  fill = MathMax(g_tr[i].tp, o);
      }
      else
      {
         if(g_tr[i].sl > 0 && h + sp >= g_tr[i].sl)       fill = MathMax(g_tr[i].sl, o + sp);
         else if(g_tr[i].tp > 0 && l + sp <= g_tr[i].tp)  fill = MathMin(g_tr[i].tp, o + sp);
      }
      if(fill > 0) { CloseAt(i, fill); hit = true; }
   }
   // pending orders (checked after the stops, so a new fill is not stopped in the same step)
   for(int j = 0; j < ArraySize(g_tr); j++)
   {
      if(!g_tr[j].pend || g_tr[j].closed) continue;
      double e = g_tr[j].open;
      double pf = 0;
      if(g_tr[j].kind == 2)      { if(l + sp <= e) pf = MathMin(e, o + sp); }   // buy limit
      else if(g_tr[j].kind == 4) { if(h + sp >= e) pf = MathMax(e, o + sp); }   // buy stop
      else if(g_tr[j].kind == 3) { if(h >= e)      pf = MathMax(e, o); }        // sell limit
      else if(g_tr[j].kind == 5) { if(l <= e)      pf = MathMin(e, o); }        // sell stop
      if(pf > 0)
      {
         g_tr[j].pend = false;
         g_tr[j].kind = 0;
         g_tr[j].open = NormalizeDouble(pf, g_dg);
         g_tr[j].topen = CurClock();
         g_tr[j].marked = false;
         g_orderEvent = true;
         g_msg = "Pending order #" + IntegerToString(g_tr[j].id) + " filled";
         g_msgTime = TimeLocal();
      }
   }
   return hit;
}

bool CheckStops(int nm)
{
   return CheckStopsRange(iOpen(g_src, PERIOD_M1, nm), iHigh(g_src, PERIOD_M1, nm), iLow(g_src, PERIOD_M1, nm));
}

//+------------------------------------------------------------------+
//| Replay control                                                   |
//+------------------------------------------------------------------+
bool PlacePending(int dir, double entry, double sl, double tp)
{
   double bid = CurBid();
   if(bid <= 0) return false;
   double ask = bid + Spr();
   double pip = PipSize();
   int kind;
   if(dir == OP_BUY)
   {
      if(MathAbs(entry - ask) < pip) { g_msg = "Entry is too close to the price"; g_msgTime = TimeLocal(); return false; }
      kind = (entry < ask) ? 2 : 4;
   }
   else
   {
      if(MathAbs(entry - bid) < pip) { g_msg = "Entry is too close to the price"; g_msgTime = TimeLocal(); return false; }
      kind = (entry > bid) ? 3 : 5;
   }
   if(sl > 0 && ((dir == OP_BUY && sl >= entry) || (dir == OP_SELL && sl <= entry)))
   { g_msg = "SL is on the wrong side of the entry"; g_msgTime = TimeLocal(); return false; }
   if(tp > 0 && ((dir == OP_BUY && tp <= entry) || (dir == OP_SELL && tp >= entry)))
   { g_msg = "TP is on the wrong side of the entry"; g_msgTime = TimeLocal(); return false; }

   int n = ArraySize(g_tr);
   ArrayResize(g_tr, n + 1);
   g_tr[n].id     = g_nextId++;
   g_tr[n].type   = dir;
   g_tr[n].lots   = CalcLotDist((sl > 0) ? MathAbs(entry - sl) : 0);
   g_tr[n].open   = NormalizeDouble(entry, g_dg);
   g_tr[n].sl     = NormalizeDouble(sl, g_dg);
   g_tr[n].tp     = NormalizeDouble(tp, g_dg);
   g_tr[n].topen  = CurClock();
   g_tr[n].closed = false;
   g_tr[n].close  = 0;
   g_tr[n].tclose = 0;
   g_tr[n].profit = 0;
   g_tr[n].pend   = true;
   g_tr[n].kind   = kind;
   g_tr[n].hidden = false;
   g_tr[n].marked = false;
   SyncTradeObjects(false);
   SaveState();
   g_msg = KindName(kind) + " placed";
   g_msgTime = TimeLocal();
   return true;
}

void CancelPendings()
{
   int cnt = 0;
   for(int i = ArraySize(g_tr) - 1; i >= 0; i--)
      if(g_tr[i].pend) { RemoveTrade(i); cnt++; }
   if(cnt > 0) SaveState();
   g_msg = (cnt > 0) ? IntegerToString(cnt) + " pending order(s) cancelled" : "No pending orders";
   g_msgTime = TimeLocal();
}

void MakeVisLine(string name, double price, color col, string tip)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, true);
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip);
}

void VisCancel()
{
   ObjectDelete(0, "BTV_SL");
   ObjectDelete(0, "BTV_TP");
   ObjectDelete(0, "BTV_EN");
   g_visMode = 0;
}

// mode 1 = market order with draggable SL/TP lines, mode 2 = pending order (entry + SL + TP lines)
void VisStart(int mode, int dir)
{
   VisCancel();
   double bid = CurBid();
   if(bid <= 0) return;
   double ask = bid + Spr();
   double pip = PipSize();
   double ref = (dir == OP_BUY) ? ask : bid;
   double slPips = (g_sl > 0) ? g_sl : 20;
   double tpPips = (g_tp > 0) ? g_tp : 40;
   double en = ref;
   if(mode == 2) en = (dir == OP_BUY) ? ref - 15 * pip : ref + 15 * pip;
   double sl = (dir == OP_BUY) ? en - slPips * pip : en + slPips * pip;
   double tp = (dir == OP_BUY) ? en + tpPips * pip : en - tpPips * pip;
   if(mode == 1 && g_slPrice > 0) sl = g_slPrice;
   if(mode == 1 && g_tpPrice > 0) tp = g_tpPrice;
   MakeVisLine("BTV_SL", NormalizeDouble(sl, g_dg), C_SELL, "Stop loss - drag me");
   MakeVisLine("BTV_TP", NormalizeDouble(tp, g_dg), C_BUY, "Take profit - drag me");
   if(mode == 2) MakeVisLine("BTV_EN", NormalizeDouble(en, g_dg), clrOrange, "Entry price - drag me");
   g_visMode = mode;
   g_visDir = dir;
   g_visEntry = en;
}

bool VisConfirm()
{
   bool hasSL = (ObjectFind(0, "BTV_SL") >= 0);
   bool hasTP = (ObjectFind(0, "BTV_TP") >= 0);
   double sl = hasSL ? NormalizeDouble(ObjectGetDouble(0, "BTV_SL", OBJPROP_PRICE), g_dg) : 0;
   double tp = hasTP ? NormalizeDouble(ObjectGetDouble(0, "BTV_TP", OBJPROP_PRICE), g_dg) : 0;
   bool ok = false;
   if(g_visMode == 1)
   {
      g_slPrice = hasSL ? sl : -1;
      g_tpPrice = hasTP ? tp : -1;
      ok = OpenVirtual(g_visDir);
      if(!ok) { g_slPrice = 0; g_tpPrice = 0; }
   }
   else if(g_visMode == 2)
   {
      if(ObjectFind(0, "BTV_EN") < 0) { g_msg = "Entry line is missing"; g_msgTime = TimeLocal(); return false; }
      double en = NormalizeDouble(ObjectGetDouble(0, "BTV_EN", OBJPROP_PRICE), g_dg);
      ok = PlacePending(g_visDir, en, sl, tp);
   }
   if(ok) VisCancel();
   return ok;
}

void AfterStep(bool hit)
{
   if(hit || g_orderEvent)
   {
      SyncTradeObjects(false);
      SaveState();
      if(g_pauseClose) { g_play = false; g_stopRun = true; }
      g_orderEvent = false;
   }
}

// reveal one whole M1 bar
bool AdvanceBar()
{
   int m = M1();
   if(m <= 0) return false;
   int nm = m - 1;
   g_t = iTime(g_src, PERIOD_M1, nm);
   g_sub = 0;
   g_dirty = true;
   bool hit = CheckStops(nm);
   AfterStep(hit);
   RunTrailing();
   return true;
}

// reveal one simulated tick of the next M1 bar
bool AdvanceTick()
{
   int m = M1();
   if(m <= 0) return false;
   int nm = m - 1;
   int K = KT();
   double prev = (g_sub == 0) ? iOpen(g_src, PERIOD_M1, nm) : TickPrice(nm, g_sub);
   g_sub++;
   double cur = TickPrice(nm, g_sub);
   bool hit = CheckStopsRange(prev, MathMax(prev, cur), MathMin(prev, cur));
   if(g_sub >= K) { g_sub = 0; g_t = iTime(g_src, PERIOD_M1, nm); }
   g_dirty = true;
   AfterStep(hit);
   RunTrailing();
   return true;
}

// step by whole M1 bar (finishes the current bar first if it is half revealed)
bool AdvanceOne()
{
   if(g_sub > 0)
   {
      int guard = 0;
      while(g_sub > 0 && guard++ < 1000)
         if(!AdvanceTick()) return false;
      return true;
   }
   return AdvanceBar();
}

void NextBar()
{
   datetime b0 = CurBarOpen(g_tf);
   g_stopRun = false;
   int guard = 0;
   while(guard++ < 50000)
   {
      if(!AdvanceOne()) { g_play = false; break; }
      if(g_stopRun) break;
      if(CurBarOpen(g_tf) != b0) break;
   }
}

void JumpTo(datetime t)
{
   if(OrdCount() > 0) { g_msg = "Close open trades / cancel pendings before jumping"; g_msgTime = TimeLocal(); return; }
   int n = iBars(g_src, PERIOD_M1);
   if(n <= 1 || t < iTime(g_src, PERIOD_M1, n - 1) || t > iTime(g_src, PERIOD_M1, 1))
   { g_msg = "Date outside M1 history (load M1 data)"; g_msgTime = TimeLocal(); return; }
   int m = iBarShift(g_src, PERIOD_M1, t, false);
   g_t = iTime(g_src, PERIOD_M1, m);
   g_sub = 0;
   BuildAllOpen();
   SaveState();
   FlushRefresh();
}

// go back one candle of the chart timeframe (blocked if a trade/order happened after that time)
void PrevBar()
{
   datetime bo = CurBarOpen(g_tf);
   int s = iBarShift(g_src, PERIOD_M1, bo, false);
   if(s < 0) { g_msg = "No history"; g_msgTime = TimeLocal(); return; }
   if(iTime(g_src, PERIOD_M1, s) < bo && s > 0) s--;
   int target = s + 1;
   if(target >= iBars(g_src, PERIOD_M1) - 1) { g_msg = "No more M1 history"; g_msgTime = TimeLocal(); return; }
   datetime t = iTime(g_src, PERIOD_M1, target);
   for(int i = 0; i < ArraySize(g_tr); i++)
   {
      if(g_tr[i].topen > t || (g_tr[i].closed && g_tr[i].tclose > t))
      {
         g_msg = "Cannot go back: trade/order exists after " + FmtTime(t);
         g_msgTime = TimeLocal();
         return;
      }
   }
   g_t = t;
   g_sub = 0;
   g_play = false;
   BuildAllOpen();
   SaveState();
   FlushRefresh();
}

void ResetSession()
{
   VisCancel();
   for(int i = ArraySize(g_tr) - 1; i >= 0; i--) DeleteTradeObjects(g_tr[i].id);
   ArrayResize(g_tr, 0);
   g_balance = InpDeposit;
   g_nextId = 1;
   g_play = false;
   g_t = 0;
   g_sub = 0;
   InitStartTime();
   BuildAllOpen();
   SaveState();
   FlushRefresh();
}

//+------------------------------------------------------------------+
//| HTML statistics report                                           |
//+------------------------------------------------------------------+
void ExportReport()
{
   int n = ArraySize(g_tr);
   double pip = PipSize();
   string fname = "ReplayReport_" + g_src + ".html";
   int h = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) { g_msg = "Cannot write report file"; g_msgTime = TimeLocal(); return; }

   FileWriteString(h, "<!DOCTYPE html><html><head><meta charset='utf-8'><title>Replay report</title>\r\n");
   FileWriteString(h, "<style>body{font-family:Segoe UI,Arial,sans-serif;background:#111318;color:#e4e7ee;margin:24px}\r\n");
   FileWriteString(h, "h1{font-size:20px}h3{margin:22px 0 8px}.m{color:#8c92a0}\r\n");
   FileWriteString(h, ".g{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px;margin:14px 0}\r\n");
   FileWriteString(h, ".c{background:#1b1e26;border:1px solid #2c303b;border-radius:8px;padding:10px 12px}.c b{display:block;font-size:18px;margin-top:4px}\r\n");
   FileWriteString(h, ".fl{background:#1b1e26;border:1px solid #2c303b;border-radius:8px;padding:10px 12px;margin:14px 0;display:flex;flex-wrap:wrap;gap:10px;align-items:center}\r\n");
   FileWriteString(h, ".fl input,.fl select,.fl button{background:#111318;color:#e4e7ee;border:1px solid #2c303b;border-radius:6px;padding:5px 8px}\r\n");
   FileWriteString(h, "table{border-collapse:collapse;width:100%;font-size:13px}th,td{padding:6px 8px;border-bottom:1px solid #2c303b;text-align:right}\r\n");
   FileWriteString(h, "th{color:#8c92a0}.w td:nth-last-child(-n+2){color:#22c55e}.l td:nth-last-child(-n+2){color:#ef4444}\r\n");
   FileWriteString(h, ".p{color:#22c55e}.n{color:#ef4444}</style></head><body>\r\n");
   FileWriteString(h, "<h1>Replay backtest report - " + g_src + "</h1><div class=m>Replay time: " + FmtTime(g_t) + " &nbsp; Deposit: " + DoubleToString(InpDeposit, 2) + "</div>\r\n");
   FileWriteString(h, "<div class=fl>From <input type=date id=f> To <input type=date id=t>\r\n");
   FileWriteString(h, "Type <select id=ty><option value=all>All</option><option value=0>BUY</option><option value=1>SELL</option></select>\r\n");
   FileWriteString(h, "Result <select id=rs><option value=all>All</option><option value=win>Winners</option><option value=loss>Losers</option></select>\r\n");
   FileWriteString(h, "Weekday <select id=wd><option value=all>All</option><option value=1>Mon</option><option value=2>Tue</option><option value=3>Wed</option><option value=4>Thu</option><option value=5>Fri</option><option value=0>Sun</option><option value=6>Sat</option></select>\r\n");
   FileWriteString(h, "Open hour <input id=h1 type=number min=0 max=23 value=0 style=width:56px> to <input id=h2 type=number min=0 max=23 value=23 style=width:56px>\r\n");
   FileWriteString(h, "<button onclick=rst()>Reset filters</button></div>\r\n");
   FileWriteString(h, "<div class=g id=cards></div>\r\n");
   FileWriteString(h, "<h3>Balance curve</h3><svg viewBox='0 0 900 220' style='width:100%;max-width:900px;background:#1b1e26;border:1px solid #2c303b;border-radius:8px'>\r\n");
   FileWriteString(h, "<polyline id=pl fill=none stroke=#3b82f6 stroke-width=2 points=''/><text id=mx x=24 y=16 fill=#8c92a0 font-size=11></text><text id=mn x=24 y=214 fill=#8c92a0 font-size=11></text></svg>\r\n");
   FileWriteString(h, "<h3>Closed trades</h3><table><tr><th>#</th><th>Type</th><th>Lots</th><th>Open time</th><th>Open</th><th>Close time</th><th>Close</th><th>Pips</th><th>Profit</th></tr><tbody id=tb></tbody></table>\r\n");

   // open positions and pending orders
   double bid = CurBid(), ask = bid + Spr();
   string rows = "", prow = "";
   int nOpen = 0, nPend = 0;
   for(int o = 0; o < n; o++)
   {
      if(g_tr[o].closed) continue;
      if(g_tr[o].pend)
      {
         nPend++;
         prow += "<tr><td>" + IntegerToString(g_tr[o].id) + "</td><td>" + KindName(g_tr[o].kind) + "</td><td>" +
                 DoubleToString(g_tr[o].lots, 2) + "</td><td>" + FmtTime(g_tr[o].topen) + "</td><td>" +
                 DoubleToString(g_tr[o].open, g_dg) + "</td><td>" + DoubleToString(g_tr[o].sl, g_dg) + "</td><td>" +
                 DoubleToString(g_tr[o].tp, g_dg) + "</td></tr>\r\n";
         continue;
      }
      nOpen++;
      double cp = (g_tr[o].type == OP_BUY) ? bid : ask;
      rows += "<tr><td>" + IntegerToString(g_tr[o].id) + "</td><td>" + (g_tr[o].type == OP_BUY ? "BUY" : "SELL") + "</td><td>" +
              DoubleToString(g_tr[o].lots, 2) + "</td><td>" + FmtTime(g_tr[o].topen) + "</td><td>" +
              DoubleToString(g_tr[o].open, g_dg) + "</td><td>" + DoubleToString(g_tr[o].sl, g_dg) + "</td><td>" +
              DoubleToString(g_tr[o].tp, g_dg) + "</td><td>" +
              DoubleToString(CalcProfit(g_tr[o].type, g_tr[o].lots, g_tr[o].open, cp, false), 2) + "</td></tr>\r\n";
   }
   if(nOpen > 0)
   {
      FileWriteString(h, "<h3>Open positions</h3><table><tr><th>#</th><th>Type</th><th>Lots</th><th>Open time</th><th>Open</th><th>SL</th><th>TP</th><th>Floating</th></tr>\r\n");
      FileWriteString(h, rows + "</table>\r\n");
   }
   if(nPend > 0)
   {
      FileWriteString(h, "<h3>Pending orders</h3><table><tr><th>#</th><th>Kind</th><th>Lots</th><th>Placed</th><th>Entry</th><th>SL</th><th>TP</th></tr>\r\n");
      FileWriteString(h, prow + "</table>\r\n");
   }

   // trade data for the interactive filters
   FileWriteString(h, "<script>var DEP=" + DoubleToString(InpDeposit, 2) + ";var D=[\r\n");
   for(int i = 0; i < n; i++)
   {
      if(!g_tr[i].closed) continue;
      double pips = ((g_tr[i].type == OP_BUY) ? g_tr[i].close - g_tr[i].open : g_tr[i].open - g_tr[i].close) / pip;
      FileWriteString(h, "[" + IntegerToString(g_tr[i].id) + "," + IntegerToString(g_tr[i].type) + "," +
                      DoubleToString(g_tr[i].lots, 2) + "," + IntegerToString((long)g_tr[i].topen) + "," +
                      DoubleToString(g_tr[i].open, g_dg) + "," + IntegerToString((long)g_tr[i].tclose) + "," +
                      DoubleToString(g_tr[i].close, g_dg) + "," + DoubleToString(pips, 1) + "," +
                      DoubleToString(g_tr[i].profit, 2) + "],\r\n");
   }
   FileWriteString(h, "];\r\n");
   FileWriteString(h, "function $(i){return document.getElementById(i)}\r\n");
   FileWriteString(h, "function fm(t){return new Date(t*1000).toISOString().replace('T',' ').slice(0,16)}\r\n");
   FileWriteString(h, "function n2(x){return (Math.round(x*100)/100).toFixed(2)}\r\n");
   FileWriteString(h, "function run(){\r\n");
   FileWriteString(h, "var f=$('f').value,t=$('t').value,ty=$('ty').value,rs=$('rs').value,wd=$('wd').value;\r\n");
   FileWriteString(h, "var h1=parseInt($('h1').value||'0'),h2=parseInt($('h2').value||'23');\r\n");
   FileWriteString(h, "var fs=f?Date.parse(f+'T00:00:00Z')/1000:-1e12,ts=t?Date.parse(t+'T23:59:59Z')/1000:1e12;\r\n");
   FileWriteString(h, "var R=D.filter(function(x){\r\n");
   FileWriteString(h, "if(x[3]<fs||x[3]>ts)return false;\r\n");
   FileWriteString(h, "if(ty!=='all'&&String(x[1])!==ty)return false;\r\n");
   FileWriteString(h, "if(rs==='win'&&x[8]<=0)return false;\r\n");
   FileWriteString(h, "if(rs==='loss'&&x[8]>0)return false;\r\n");
   FileWriteString(h, "var d=new Date(x[3]*1000);\r\n");
   FileWriteString(h, "if(wd!=='all'&&String(d.getUTCDay())!==wd)return false;\r\n");
   FileWriteString(h, "var hr=d.getUTCHours();\r\n");
   FileWriteString(h, "if(hr<h1||hr>h2)return false;\r\n");
   FileWriteString(h, "return true;});\r\n");
   FileWriteString(h, "R.sort(function(a,b){return a[5]-b[5]});\r\n");
   FileWriteString(h, "var w=0,l=0,gp=0,gl=0,net=0,pips=0,cl=0,mcl=0,mw=0,ml=0,bal=DEP,pk=DEP,dd=0,cv=[DEP];\r\n");
   FileWriteString(h, "R.forEach(function(x){var p=x[8];net+=p;pips+=x[7];bal+=p;cv.push(bal);if(bal>pk)pk=bal;if(pk-bal>dd)dd=pk-bal;if(p>0){w++;gp+=p;cl=0;if(p>mw)mw=p}else{l++;gl-=p;cl++;if(cl>mcl)mcl=cl;if(p<ml)ml=p}});\r\n");
   FileWriteString(h, "var n=R.length;\r\n");
   FileWriteString(h, "var C=[['Net profit',n2(net),net>=0?'p':'n'],['Trades',n,''],['Win rate',(n?100*w/n:0).toFixed(1)+'%',''],['Profit factor',gl>0?(gp/gl).toFixed(2):(gp>0?'inf':'-'),''],['Expectancy / trade',n2(n?net/n:0),''],['Gross profit',n2(gp),'p'],['Gross loss',n2(-gl),'n'],['Avg win',n2(w?gp/w:0),''],['Avg loss',n2(l?-gl/l:0),''],['Largest win',n2(mw),''],['Largest loss',n2(ml),''],['Max consecutive losses',mcl,''],['Max drawdown',n2(dd),''],['Total pips',pips.toFixed(1),''],['Avg pips / trade',(n?pips/n:0).toFixed(1),''],['End balance',n2(bal),'']];\r\n");
   FileWriteString(h, "$('cards').innerHTML=C.map(function(c){return '<div class=c>'+c[0]+'<b class='+(c[2]||'z')+'>'+c[1]+'</b></div>'}).join('');\r\n");
   FileWriteString(h, "var mn=Math.min.apply(null,cv),mx=Math.max.apply(null,cv),sp=(mx>mn)?(mx-mn):1;\r\n");
   FileWriteString(h, "$('pl').setAttribute('points',cv.map(function(v,i){return (20+i/Math.max(cv.length-1,1)*860).toFixed(1)+','+(200-(v-mn)/sp*180).toFixed(1)}).join(' '));\r\n");
   FileWriteString(h, "$('mx').textContent='max '+n2(mx);$('mn').textContent='min '+n2(mn);\r\n");
   FileWriteString(h, "$('tb').innerHTML=R.map(function(x,i){return '<tr class='+(x[8]>0?'w':'l')+'><td>'+(i+1)+'</td><td>'+(x[1]?'SELL':'BUY')+'</td><td>'+x[2]+'</td><td>'+fm(x[3])+'</td><td>'+x[4]+'</td><td>'+fm(x[5])+'</td><td>'+x[6]+'</td><td>'+x[7].toFixed(1)+'</td><td>'+n2(x[8])+'</td></tr>'}).join('');\r\n");
   FileWriteString(h, "}\r\n");
   FileWriteString(h, "function rst(){['f','t'].forEach(function(i){$(i).value=''});$('ty').value='all';$('rs').value='all';$('wd').value='all';$('h1').value=0;$('h2').value=23;run()}\r\n");
   FileWriteString(h, "['f','t','ty','rs','wd','h1','h2'].forEach(function(i){$(i).addEventListener('change',run)});\r\n");
   FileWriteString(h, "run();\r\n");
   FileWriteString(h, "</script></body></html>");
   FileClose(h);

   string full = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL4\\Files\\" + fname;
   int rc = ShellExecuteW(0, "open", full, "", "", 1);
   g_msg = (rc > 32) ? "Report opened in browser" : "Report saved: MQL4\\Files\\" + fname;
   g_msgTime = TimeLocal();
}

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void MakeRect(string n, int x, int y, int w, int h)
{
   ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, C_BG);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_COLOR, C_BORDER);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 0);
}

void MakeBtn(string n, int x, int y, int w, int h, string txt, color bg, color fg = clrWhite, int fs = 9)
{
   ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetString(0, n, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, fs);
   ObjectSetInteger(0, n, OBJPROP_COLOR, fg);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, C_BORDER);
   ObjectSetInteger(0, n, OBJPROP_STATE, false);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 10);
}

void MakeLbl(string n, int x, int y, string txt, color c = clrNONE, int fs = 9)
{
   if(c == clrNONE) c = C_TEXT;
   ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, n, OBJPROP_TEXT, txt);
   ObjectSetString(0, n, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, fs);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 5);
}

void MakeEdit(string n, int x, int y, int w, int h, bool readOnly)
{
   ObjectCreate(0, n, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_READONLY, readOnly);
   ObjectSetInteger(0, n, OBJPROP_ALIGN, ALIGN_CENTER);
   ObjectSetString(0, n, OBJPROP_FONT, "Segoe UI");
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, n, OBJPROP_COLOR, C_TEXT);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, C'33,36,44');
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, C_BORDER);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_ZORDER, 10);
}

void BuildPanel()
{
   int x = InpPanelX, y = InpPanelY;
   MakeRect(PNL + "bg", x, y, PANEL_W, PANEL_H);
   MakeLbl(PNL + "title", x + 12, y + 6, "REPLAY BACKTESTER", C_ACCENT, 10);
   MakeBtn(PNL + "min", x + PANEL_W - 36, y + 5, 26, 20, "-", C_BTN);
   MakeBtn(PNL + "link", x + 138, y + 8, 84, 14, "Farhad Karimzadeh", C_BG, C_ACCENT, 7);
   ObjectSetString(0, PNL + "link", OBJPROP_TOOLTIP, "www.karimzaadeh.ir");
   ObjectSetInteger(0, PNL + "link", OBJPROP_BORDER_COLOR, C_BG);

   MakeLbl(PNL + "i_time", x + 12, y + 44,  "");
   MakeLbl(PNL + "i_bal",  x + 12, y + 60,  "");
   MakeLbl(PNL + "i_eq",   x + 12, y + 76,  "");
   MakeLbl(PNL + "i_pl",   x + 12, y + 92,  "");
   MakeLbl(PNL + "i_sp",   x + 12, y + 108, "", C_MUTED);
   MakeLbl(PNL + "i_st",   x + 12, y + 124, "", C_MUTED);
   MakeLbl(PNL + "i_dbg",  x + 12, y + 140, "", C_MUTED, 7);

   MakeBtn(PNL + "play", x + 12,  y + 156, 72, 26, "Play",     C_ACCENT);
   MakeBtn(PNL + "prev", x + 90,  y + 156, 72, 26, "Prev Bar", C_BTN);
   MakeBtn(PNL + "next", x + 168, y + 156, 80, 26, "Next Bar", C_BTN);

   MakeLbl(PNL + "l_spd", x + 12, y + 192, "Speed");
   MakeBtn(PNL + "spd_m", x + 84,  y + 188, 28, 24, "-", C_BTN);
   MakeEdit(PNL + "spd_v", x + 114, y + 188, 78, 24, true);
   MakeBtn(PNL + "spd_p", x + 196, y + 188, 28, 24, "+", C_BTN);

   MakeLbl(PNL + "l_go", x + 12, y + 222, "Go to");
   MakeEdit(PNL + "goto", x + 60, y + 218, 176, 24, false);

   MakeBtn(PNL + "pausec",  x + 12,  y + 248, 108, 24, "", C_BTN);
   MakeBtn(PNL + "rebuild", x + 128, y + 248, 108, 24, "Reload chart", C_BTN);

   MakeLbl(PNL + "l_lot", x + 12, y + 284, "Lot");
   MakeBtn(PNL + "lot_m", x + 84,  y + 280, 28, 24, "-", C_BTN);
   MakeEdit(PNL + "lot_v", x + 114, y + 280, 78, 24, false);
   MakeBtn(PNL + "lot_p", x + 196, y + 280, 28, 24, "+", C_BTN);

   MakeLbl(PNL + "l_sl", x + 12, y + 312, "SL pips");
   MakeBtn(PNL + "sl_m", x + 84,  y + 308, 28, 24, "-", C_BTN);
   MakeEdit(PNL + "sl_v", x + 114, y + 308, 78, 24, false);
   MakeBtn(PNL + "sl_p", x + 196, y + 308, 28, 24, "+", C_BTN);

   MakeLbl(PNL + "l_tp", x + 12, y + 340, "TP pips");
   MakeBtn(PNL + "tp_m", x + 84,  y + 336, 28, 24, "-", C_BTN);
   MakeEdit(PNL + "tp_v", x + 114, y + 336, 78, 24, false);
   MakeBtn(PNL + "tp_p", x + 196, y + 336, 28, 24, "+", C_BTN);

   MakeLbl(PNL + "l_tr", x + 12, y + 368, "Trail pips");
   MakeBtn(PNL + "tr_m", x + 84,  y + 364, 28, 24, "-", C_BTN);
   MakeEdit(PNL + "tr_v", x + 114, y + 364, 78, 24, false);
   MakeBtn(PNL + "tr_p", x + 196, y + 364, 28, 24, "+", C_BTN);

   MakeBtn(PNL + "mode",  x + 12,  y + 394, 108, 24, "", C_BTN);
   MakeBtn(PNL + "trail", x + 128, y + 394, 108, 24, "", C_BTN);
   MakeBtn(PNL + "visual",  x + 12,  y + 424, 108, 24, "", C_BTN);
   MakeBtn(PNL + "clrmarks", x + 128, y + 424, 108, 24, "Clear marks", C_BTN);

   MakeBtn(PNL + "buy",  x + 12,  y + 458, 108, 34, "BUY",  C_BUY,  clrWhite, 11);
   MakeBtn(PNL + "sell", x + 128, y + 458, 108, 34, "SELL", C_SELL, clrWhite, 11);

   MakeBtn(PNL + "pbuy",  x + 12,  y + 500, 108, 24, "Buy Pending",  C_BTN);
   MakeBtn(PNL + "psell", x + 128, y + 500, 108, 24, "Sell Pending", C_BTN);
   MakeBtn(PNL + "call",  x + 12,  y + 530, 108, 24, "Close All",   C_BTN);
   MakeBtn(PNL + "c50",   x + 128, y + 530, 108, 24, "Close 50%",   C_BTN);
   MakeBtn(PNL + "be",     x + 12,  y + 560, 108, 24, "SL to Break-even", C_BTN);
   MakeBtn(PNL + "cancel", x + 128, y + 560, 108, 24, "Cancel pend.", C_BTN);
   MakeBtn(PNL + "report", x + 12,  y + 592, 108, 22, "Report", C_ACCENT, clrWhite, 8);
   MakeBtn(PNL + "reset",  x + 128, y + 592, 108, 22, "Reset session", C_BTN, C_MUTED, 8);
}

void ApplyMinimize()
{
   for(int i = ObjectsTotal(0, -1, -1) - 1; i >= 0; i--)
   {
      string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, PNL) != 0) continue;
      if(nm == PNL + "bg" || nm == PNL + "min" || nm == PNL + "title" || nm == PNL + "link") continue;
      ObjectSetInteger(0, nm, OBJPROP_TIMEFRAMES, g_minimized ? OBJ_NO_PERIODS : OBJ_ALL_PERIODS);
   }
   ObjectSetInteger(0, PNL + "bg", OBJPROP_YSIZE, g_minimized ? 30 : PANEL_H);
   ObjectSetString(0, PNL + "min", OBJPROP_TEXT, g_minimized ? "+" : "-");
}

// write a text into an edit field unless the user is in the middle of typing in it
void SetField(string name, string &last, string text)
{
   string cur = ObjectGetString(0, name, OBJPROP_TEXT);
   if(last == "" || cur == last)
   {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      last = text;
   }
}

// number typed in an SL/TP field: a price if it is close to the current price, otherwise pips
void ParseLevel(string txt, int &pips, double &price)
{
   StringReplace(txt, ",", ".");
   double v = StrToDouble(txt);
   pips = 0; price = 0;
   if(v <= 0) return;
   double bid = CurBid();
   if(bid > 0 && MathAbs(v - bid) < bid * 0.2) price = NormalizeDouble(v, g_dg);
   else pips = (int)MathRound(v);
}

void UpdatePanel()
{
   double bid = CurBid();
   double ask = bid + Spr();
   double floating = 0;
   int total = 0, wins = 0, nPos = 0, nPend = 0;
   double net = 0;
   for(int i = 0; i < ArraySize(g_tr); i++)
   {
      if(g_tr[i].pend) { nPend++; continue; }
      if(g_tr[i].closed)
      {
         total++;
         if(g_tr[i].profit > 0) wins++;
         net += g_tr[i].profit;
      }
      else
      {
         nPos++;
         double cp = (g_tr[i].type == OP_BUY) ? bid : ask;
         floating += CalcProfit(g_tr[i].type, g_tr[i].lots, g_tr[i].open, cp, false);
      }
   }
   double wr = (total > 0) ? 100.0 * wins / total : 0;

   ObjectSetString(0, PNL + "i_time", OBJPROP_TEXT, "Replay:   " + FmtTime(CurClock()) + (g_sub > 0 ? "  tick " + IntegerToString(g_sub) + "/" + IntegerToString(KT()) : ""));
   ObjectSetString(0, PNL + "i_bal",  OBJPROP_TEXT, "Balance:  " + DoubleToString(g_balance, 2));
   ObjectSetString(0, PNL + "i_eq",   OBJPROP_TEXT, "Equity:   " + DoubleToString(g_balance + floating, 2));
   ObjectSetString(0, PNL + "i_pl",   OBJPROP_TEXT, "Floating: " + DoubleToString(floating, 2));
   ObjectSetInteger(0, PNL + "i_pl",  OBJPROP_COLOR, floating > 0 ? C_BUY : (floating < 0 ? C_SELL : C_TEXT));
   ObjectSetString(0, PNL + "i_sp",   OBJPROP_TEXT, "Bid " + DoubleToString(bid, g_dg) + "  Spr " + IntegerToString(InpSpreadPts) +
                                                    "  | Pos " + IntegerToString(nPos) + "  Pend " + IntegerToString(nPend));
   ObjectSetString(0, PNL + "i_st",   OBJPROP_TEXT, "Closed " + IntegerToString(total) + "  Win " + DoubleToString(wr, 0) + "%  Net " + DoubleToString(net, 2));

   if(g_msg != "" && TimeLocal() - g_msgTime > 6) g_msg = "";
   string dbg = g_dbg;
   color dbgCol = C_MUTED;
   if(g_visMode != 0)
   {
      dbg = (g_visMode == 2) ? "Drag entry / SL / TP lines, press Place again (Esc = cancel)" : "Drag SL / TP lines, press BUY/SELL again (Esc = cancel)";
      dbgCol = C_ACCENT;
   }
   if(g_msg != "") { dbg = g_msg; dbgCol = C_SELL; }
   ObjectSetString(0, PNL + "i_dbg", OBJPROP_TEXT, dbg);
   ObjectSetInteger(0, PNL + "i_dbg", OBJPROP_COLOR, dbgCol);

   ObjectSetString(0, PNL + "play", OBJPROP_TEXT, g_play ? "Pause" : "Play");
   ObjectSetInteger(0, PNL + "play", OBJPROP_BGCOLOR, g_play ? C_SELL : C_ACCENT);
   ObjectSetString(0, PNL + "spd_v", OBJPROP_TEXT, DoubleToString(g_speeds[g_speedIdx], g_speeds[g_speedIdx] < 1 ? 2 : 0) + " M1/s");
   if(g_t > 0) SetField(PNL + "goto", g_txtGo, FmtTime(g_t));

   ObjectSetString(0, PNL + "pausec", OBJPROP_TEXT, g_pauseClose ? "Auto-pause: ON" : "Auto-pause: OFF");
   ObjectSetInteger(0, PNL + "pausec", OBJPROP_BGCOLOR, g_pauseClose ? C_ACCENT : C_BTN);

   if(g_riskMode)
   {
      ObjectSetString(0, PNL + "l_lot", OBJPROP_TEXT, "Risk %");
      SetField(PNL + "lot_v", g_txtLot, DoubleToString(g_risk, 2) + " (" + DoubleToString(CalcLot(), 2) + ")");
   }
   else
   {
      ObjectSetString(0, PNL + "l_lot", OBJPROP_TEXT, "Lot");
      SetField(PNL + "lot_v", g_txtLot, DoubleToString(g_lot, 2));
   }
   SetField(PNL + "sl_v", g_txtSL, g_slPrice > 0 ? DoubleToString(g_slPrice, g_dg) : (g_sl > 0 ? IntegerToString(g_sl) : "off"));
   SetField(PNL + "tp_v", g_txtTP, g_tpPrice > 0 ? DoubleToString(g_tpPrice, g_dg) : (g_tp > 0 ? IntegerToString(g_tp) : "off"));
   SetField(PNL + "tr_v", g_txtTrail, IntegerToString(g_trailPips));

   ObjectSetString(0, PNL + "mode", OBJPROP_TEXT, g_riskMode ? "Mode: Risk %" : "Mode: Fixed lot");
   ObjectSetInteger(0, PNL + "mode", OBJPROP_BGCOLOR, g_riskMode ? C_ACCENT : C_BTN);
   ObjectSetString(0, PNL + "trail", OBJPROP_TEXT, g_trail ? "Trail: ON" : "Trail: OFF");
   ObjectSetInteger(0, PNL + "trail", OBJPROP_BGCOLOR, g_trail ? C_ACCENT : C_BTN);
   ObjectSetString(0, PNL + "visual", OBJPROP_TEXT, g_visual ? "Visual SL/TP: ON" : "Visual SL/TP: OFF");
   ObjectSetInteger(0, PNL + "visual", OBJPROP_BGCOLOR, g_visual ? C_ACCENT : C_BTN);

   ObjectSetString(0, PNL + "buy",  OBJPROP_TEXT, (g_visMode == 1 && g_visDir == OP_BUY)  ? "CONFIRM BUY"  : "BUY");
   ObjectSetString(0, PNL + "sell", OBJPROP_TEXT, (g_visMode == 1 && g_visDir == OP_SELL) ? "CONFIRM SELL" : "SELL");
   ObjectSetString(0, PNL + "pbuy",  OBJPROP_TEXT, (g_visMode == 2 && g_visDir == OP_BUY)  ? "PLACE BUY"  : "Buy Pending");
   ObjectSetString(0, PNL + "psell", OBJPROP_TEXT, (g_visMode == 2 && g_visDir == OP_SELL) ? "PLACE SELL" : "Sell Pending");
   ObjectSetString(0, PNL + "cancel", OBJPROP_TEXT, g_visMode != 0 ? "Cancel setup" : "Cancel pend.");
   ObjectSetString(0, PNL + "reset", OBJPROP_TEXT, g_resetArmed ? "Confirm reset?" : "Reset session");
   ObjectSetInteger(0, PNL + "reset", OBJPROP_BGCOLOR, g_resetArmed ? C_SELL : C_BTN);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Init helpers                                                     |
//+------------------------------------------------------------------+
bool TryInit()
{
   Comment("Replay EA started on ", Symbol(), " ... ", g_dbg);
   if(iBars(g_src, PERIOD_M1) < 100) { g_dbg = "Waiting for M1 history of " + g_src + "..."; return false; }
   if(g_t == 0) InitStartTime();
   if(g_t == 0) { g_dbg = "No start time"; return false; }
   if(!BuildHistory(g_tf, true)) { g_dbg = "Waiting for " + g_src + " TF data / file..."; Diag("Replay: BuildHistory failed: " + g_dbg); return false; }
   BuildAllOpen();
   g_dbg = "Replay ready";
   Comment("");
   g_ready = true;
   SyncTradeObjects(true);
   RefreshChart();
   return true;
}

bool TrySetup()
{
   if(iBars(g_src, PERIOD_M1) < 100)
   {
      Comment("Replay setup: waiting for M1 history of ", g_src, " ...");
      return false;
   }
   if(InpForceStart) g_t = 0;
   if(g_t == 0) InitStartTime();
   if(g_t == 0) return false;

   int okCount = 0;
   string failed = "";
   for(int i = 0; i < 9; i++)
   {
      if(BuildHistory(g_tfs[i], false)) okCount++;
      else failed += IntegerToString(g_tfs[i]) + " ";
   }
   SaveState();
   string msg = "REPLAY SETUP DONE  (" + IntegerToString(okCount) + "/9 timeframes written)\n" +
                "Replay symbol: " + g_rsym + "   start: " + FmtTime(g_t) + "\n\n" +
                "Next:\n 1) File > Open Offline > " + g_rsym + ",M1 > Open\n" +
                " 2) Apply your template to that chart\n" +
                " 3) Attach this EA to that offline chart (Allow DLL imports)";
   if(failed != "") msg += "\n\nTimeframes not written yet (data not loaded): " + failed;
   Comment(msg);
   Print(msg);
   Alert("Replay setup done. File > Open Offline > ", g_rsym, " > M1, then attach this EA to it.");
   g_ready = true;
   EventKillTimer();
   return true;
}

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   int sl = StringLen(Symbol()), xl = StringLen(InpSuffix);
   g_replayChart = (xl > 0 && sl > xl && StringSubstr(Symbol(), sl - xl) == InpSuffix);
   g_src  = g_replayChart ? StringSubstr(Symbol(), 0, sl - xl) : Symbol();
   g_rsym = g_src + InpSuffix;
   g_tf   = Period();
   Diag("Replay EA init: chart=" + Symbol() + " tf=" + IntegerToString(g_tf) + " mode=" + (g_replayChart ? "REPLAY" : "SETUP") + " src=" + g_src + " rsym=" + g_rsym);
   if(StringLen(g_rsym) > 11) { Alert("Replay symbol name too long: ", g_rsym); return INIT_FAILED; }

   SymbolSelect(g_src, true);
   g_pt = MarketInfo(g_src, MODE_POINT);
   g_dg = (int)MarketInfo(g_src, MODE_DIGITS);
   g_pauseClose = InpPauseOnClose;
   g_msg4 = RegisterWindowMessageW("MetaTrader4_Internal_Message");

   LoadState();
   if(g_replayChart)
   {
      ChartSetInteger(0, CHART_AUTOSCROLL, true);
      ChartSetInteger(0, CHART_SHIFT, true);
      ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
      BuildPanel();
      ApplyMinimize();
      EventSetMillisecondTimer(100);
      TryInit();
      UpdatePanel();
   }
   else
   {
      EventSetMillisecondTimer(500);
      TrySetup();
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   if(g_replayChart && g_ready) SaveState();
   FlushHistory();
   if(g_replayChart)
   {
      CollectCharts();
      for(int c = 0; c < g_nCh; c++)
      {
         ObjectsDeleteAll(g_ch[c], "BTX_");
         ObjectsDeleteAll(g_ch[c], "BTL_");
      }
   }
   // delete ONLY our own objects (never touch other indicators' objects)
   ObjectsDeleteAll(0, "BTP_");
   ObjectsDeleteAll(0, "BTX_");
   ObjectsDeleteAll(0, "BTL_");
   ObjectsDeleteAll(0, "BTV_");
   if(!g_replayChart) Comment("");
   ChartRedraw();
}

void OnTick() { }

// debounce helper: a line counts as "moved by the user" only after it stayed still for 2 polls
string g_pn[];
double g_pp[];
int    g_pc[];
bool PollStable(string name, double px)
{
   double tol = g_pt * 0.5;
   int k = -1;
   for(int i = 0; i < ArraySize(g_pn); i++) if(g_pn[i] == name) { k = i; break; }
   if(k < 0)
   {
      k = ArraySize(g_pn);
      ArrayResize(g_pn, k + 1); ArrayResize(g_pp, k + 1); ArrayResize(g_pc, k + 1);
      g_pn[k] = name; g_pp[k] = px; g_pc[k] = 0;
      return false;
   }
   if(MathAbs(g_pp[k] - px) < tol) g_pc[k]++;
   else { g_pp[k] = px; g_pc[k] = 0; }
   if(g_pc[k] >= 2) { g_pc[k] = 0; return true; }
   return false;
}

// SL / TP / pending-entry lines moved with the mouse on ANY replay chart (M1, M5, ...)
void PollLines()
{
   CollectCharts();
   double bid = CurBid();
   if(bid <= 0) return;
   double ask = bid + Spr();
   double tol = g_pt * 0.5;
   bool changed = false;
   for(int i = 0; i < ArraySize(g_tr); i++)
   {
      if(g_tr[i].closed) continue;
      string id = IntegerToString(g_tr[i].id);
      bool buy = (g_tr[i].type == OP_BUY);
      for(int c = 0; c < g_nCh; c++)
      {
         long cid = g_ch[c];
         string ne = "BTL_" + id + "_E", ns = "BTL_" + id + "_S", nt = "BTL_" + id + "_T";

         if(g_tr[i].pend && ObjectFind(cid, ne) >= 0)
         {
            double pe = NormalizeDouble(ObjectGetDouble(cid, ne, OBJPROP_PRICE), g_dg);
            if(MathAbs(pe - g_tr[i].open) > tol && PollStable(IntegerToString(cid) + ne, pe))
            {
               double dl = pe - g_tr[i].open;
               g_tr[i].open = pe;
               if(g_tr[i].sl > 0) g_tr[i].sl += dl;
               if(g_tr[i].tp > 0) g_tr[i].tp += dl;
               g_tr[i].kind = buy ? ((pe < ask) ? 2 : 4) : ((pe > bid) ? 3 : 5);
               changed = true;
               continue;
            }
         }
         if(g_tr[i].sl > 0 && ObjectFind(cid, ns) >= 0)
         {
            double ps = NormalizeDouble(ObjectGetDouble(cid, ns, OBJPROP_PRICE), g_dg);
            if(MathAbs(ps - g_tr[i].sl) > tol && PollStable(IntegerToString(cid) + ns, ps))
            {
               double ref = g_tr[i].pend ? g_tr[i].open : (buy ? bid : ask);
               if(buy ? (ps < ref) : (ps > ref)) g_tr[i].sl = ps;
               changed = true;
            }
         }
         if(g_tr[i].tp > 0 && ObjectFind(cid, nt) >= 0)
         {
            double pt2 = NormalizeDouble(ObjectGetDouble(cid, nt, OBJPROP_PRICE), g_dg);
            if(MathAbs(pt2 - g_tr[i].tp) > tol && PollStable(IntegerToString(cid) + nt, pt2))
            {
               double ref2 = g_tr[i].pend ? g_tr[i].open : (buy ? bid : ask);
               if(buy ? (pt2 > ref2) : (pt2 < ref2)) g_tr[i].tp = pt2;
               changed = true;
            }
         }
      }
   }
   if(changed) { SyncTradeObjects(false); SaveState(); ChartRedraw(); }
}

void OnTimer()
{
   if(!g_ready)
   {
      if(g_replayChart) { TryInit(); UpdatePanel(); }
      else TrySetup();
      return;
   }
   if(!g_replayChart) return;

   // a replay chart of another timeframe was opened/closed -> bring its file up to date
   static int slowTick = 0;
   slowTick++;
   if(slowTick % 10 == 0)
   {
      bool changed = false;
      for(int i = 0; i < 9; i++)
         if(IsOpenTf(i) != g_tfOpen[i]) changed = true;
      if(changed) { g_dirty = true; FlushRefresh(); SyncTradeObjects(true); }
   }
   static int pollTick = 0;
   pollTick++;
   if(pollTick % 3 == 0) PollLines();

   if(!g_play) return;

   double sp = g_speeds[g_speedIdx];
   bool tickMode = (sp <= 10.0);          // slow speeds: animate inside the M1 candle
   g_acc += tickMode ? sp * KT() * 0.1 : sp * 0.1;
   int n = (int)g_acc;
   if(n < 1) return;
   g_acc -= n;
   for(int i = 0; i < n && g_play; i++)
   {
      bool ok = tickMode ? AdvanceTick() : AdvanceOne();
      if(!ok) { g_play = false; break; }
   }
   FlushRefresh();
   UpdatePanel();
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(!g_replayChart || !g_ready) return;

   //--- editable fields (go-to date, lot, SL, TP, trail)
   if(id == CHARTEVENT_OBJECT_ENDEDIT)
   {
      string txt = ObjectGetString(0, sparam, OBJPROP_TEXT);
      if(sparam == PNL + "goto")
      {
         datetime t = StrToTime(txt);
         if(t > 0) JumpTo(t);
         g_txtGo = "";
      }
      else if(sparam == PNL + "sl_v" || sparam == PNL + "tp_v")
      {
         int pp;
         double pr;
         ParseLevel(txt, pp, pr);
         if(sparam == PNL + "sl_v") { if(pr > 0) g_slPrice = pr; else { g_slPrice = 0; g_sl = pp; } g_txtSL = ""; }
         else                       { if(pr > 0) g_tpPrice = pr; else { g_tpPrice = 0; g_tp = pp; } g_txtTP = ""; }
         SaveState();
      }
      else if(sparam == PNL + "lot_v")
      {
         StringReplace(txt, ",", ".");
         double v = StrToDouble(txt);
         if(v > 0) { if(g_riskMode) g_risk = v; else g_lot = NormLot(v); }
         g_txtLot = "";
         SaveState();
      }
      else if(sparam == PNL + "tr_v")
      {
         int tv = (int)StrToInteger(txt);
         if(tv > 0) g_trailPips = tv;
         g_txtTrail = "";
         SaveState();
      }
      else return;
      UpdatePanel();
      return;
   }

   //--- the user deleted a mark / line from the chart
   if(id == CHARTEVENT_OBJECT_DELETE)
   {
      string dp[];
      if(StringSplit(sparam, '_', dp) == 3 && (dp[0] == "BTX" || dp[0] == "BTL"))
      {
         int k = FindTrade((int)StrToInteger(dp[1]));
         if(k >= 0)
         {
            if(dp[0] == "BTX") { if(!g_tr[k].hidden) { g_tr[k].hidden = true; SaveState(); g_syncNeeded = true; } }
            else if(dp[2] == "S") { if(g_tr[k].sl > 0 && !g_tr[k].closed) { g_tr[k].sl = 0; SaveState(); g_syncNeeded = true; } }
            else if(dp[2] == "T") { if(g_tr[k].tp > 0 && !g_tr[k].closed) { g_tr[k].tp = 0; SaveState(); g_syncNeeded = true; } }
            else if(dp[2] == "E") { if(g_tr[k].pend) { RemoveTrade(k); SaveState(); g_msg = "Pending order cancelled"; g_msgTime = TimeLocal(); } }
            if(g_syncNeeded) { SyncTradeObjects(false); g_syncNeeded = false; }
            UpdatePanel();
         }
      }
      return;
   }

   //--- dragged lines
   if(id == CHARTEVENT_OBJECT_DRAG)
   {
      if(StringFind(sparam, "BTV_") == 0)
      {
         if(sparam == "BTV_EN" && g_visMode == 2)
         {
            double ne = ObjectGetDouble(0, "BTV_EN", OBJPROP_PRICE);
            double dd = ne - g_visEntry;
            if(ObjectFind(0, "BTV_SL") >= 0) ObjectSetDouble(0, "BTV_SL", OBJPROP_PRICE, ObjectGetDouble(0, "BTV_SL", OBJPROP_PRICE) + dd);
            if(ObjectFind(0, "BTV_TP") >= 0) ObjectSetDouble(0, "BTV_TP", OBJPROP_PRICE, ObjectGetDouble(0, "BTV_TP", OBJPROP_PRICE) + dd);
            g_visEntry = ne;
            ChartRedraw();
         }
         return;
      }
      if(StringFind(sparam, "BTL_") == 0)
      {
         string parts[];
         if(StringSplit(sparam, '_', parts) == 3)
         {
            int tid = (int)StrToInteger(parts[1]);
            double px = NormalizeDouble(ObjectGetDouble(0, sparam, OBJPROP_PRICE), g_dg);
            double bid = CurBid(), ask = bid + Spr();
            for(int i = 0; i < ArraySize(g_tr); i++)
            {
               if(g_tr[i].id != tid || g_tr[i].closed) continue;
               bool buy = (g_tr[i].type == OP_BUY);
               if(g_tr[i].pend)
               {
                  double ref = g_tr[i].open;
                  if(parts[2] == "E")
                  {
                     double dl = px - g_tr[i].open;
                     g_tr[i].open = px;
                     if(g_tr[i].sl > 0) g_tr[i].sl += dl;
                     if(g_tr[i].tp > 0) g_tr[i].tp += dl;
                     g_tr[i].kind = buy ? ((px < ask) ? 2 : 4) : ((px > bid) ? 3 : 5);
                  }
                  else if(parts[2] == "S" && ((buy && px < ref) || (!buy && px > ref))) g_tr[i].sl = px;
                  else if(parts[2] == "T" && ((buy && px > ref) || (!buy && px < ref))) g_tr[i].tp = px;
               }
               else
               {
                  if(parts[2] == "S" && ((buy && px < bid) || (!buy && px > ask))) g_tr[i].sl = px;
                  if(parts[2] == "T" && ((buy && px > bid) || (!buy && px < ask))) g_tr[i].tp = px;
               }
               break;
            }
            SyncTradeObjects(false);
            SaveState();
            ChartRedraw();
         }
      }
      return;
   }

   //--- hotkeys
   if(id == CHARTEVENT_KEYDOWN)
   {
      if(lparam == 27)      VisCancel();                                 // Esc
      else if(lparam == 32) g_play = !g_play;                            // Space
      else if(lparam == 78) { g_play = false; NextBar(); }               // N
      else if(lparam == 80) { g_play = false; PrevBar(); }               // P
      else if(lparam == 77) { g_play = false; AdvanceOne(); }            // M
      else if(lparam == 84) { g_play = false; AdvanceTick(); }           // T
      else if(lparam == 66) OpenVirtual(OP_BUY);                         // B
      else if(lparam == 83) OpenVirtual(OP_SELL);                        // S
      else if(lparam == 67) CloseTrades(-1, 1.0);                        // C
      else if(lparam == 72) CloseTrades(-1, 0.5);                        // H
      else if(lparam == 69) MoveToBE();                                  // E
      else return;
      FlushRefresh();
      UpdatePanel();
      return;
   }

   //--- panel clicks
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(StringFind(sparam, PNL) != 0) return;
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);

   double lotStep = MarketInfo(g_src, MODE_LOTSTEP);
   if(lotStep <= 0) lotStep = 0.01;
   bool keepArm = (sparam == PNL + "reset");
   if(!keepArm) g_resetArmed = false;

   if(sparam == PNL + "min")         { g_minimized = !g_minimized; ApplyMinimize(); }
   else if(sparam == PNL + "link")   ShellExecuteW(0, "open", "https://www.karimzaadeh.ir", "", "", 1);
   else if(sparam == PNL + "play")   { g_play = !g_play; g_acc = 0; }
   else if(sparam == PNL + "prev")   { g_play = false; PrevBar(); }
   else if(sparam == PNL + "next")   { g_play = false; NextBar(); }
   else if(sparam == PNL + "spd_m")  g_speedIdx = MathMax(0, g_speedIdx - 1);
   else if(sparam == PNL + "spd_p")  g_speedIdx = MathMin(9, g_speedIdx + 1);
   else if(sparam == PNL + "pausec") g_pauseClose = !g_pauseClose;
   else if(sparam == PNL + "rebuild") { BuildAllOpen(); }
   else if(sparam == PNL + "visual") { g_visual = !g_visual; if(!g_visual) VisCancel(); }
   else if(sparam == PNL + "clrmarks")
   {
      for(int q = 0; q < ArraySize(g_tr); q++) if(g_tr[q].closed) g_tr[q].hidden = true;
      SyncTradeObjects(true);
   }
   else if(sparam == PNL + "buy")
   {
      if(!g_visual) OpenVirtual(OP_BUY);
      else if(g_visMode == 1 && g_visDir == OP_BUY) VisConfirm();
      else VisStart(1, OP_BUY);
   }
   else if(sparam == PNL + "sell")
   {
      if(!g_visual) OpenVirtual(OP_SELL);
      else if(g_visMode == 1 && g_visDir == OP_SELL) VisConfirm();
      else VisStart(1, OP_SELL);
   }
   else if(sparam == PNL + "pbuy")
   {
      if(g_visMode == 2 && g_visDir == OP_BUY) VisConfirm();
      else VisStart(2, OP_BUY);
   }
   else if(sparam == PNL + "psell")
   {
      if(g_visMode == 2 && g_visDir == OP_SELL) VisConfirm();
      else VisStart(2, OP_SELL);
   }
   else if(sparam == PNL + "cancel") { if(g_visMode != 0) VisCancel(); else CancelPendings(); }
   else if(sparam == PNL + "call")   CloseTrades(-1, 1.0);
   else if(sparam == PNL + "c50")    CloseTrades(-1, 0.5);
   else if(sparam == PNL + "be")     MoveToBE();
   else if(sparam == PNL + "mode")   g_riskMode = !g_riskMode;
   else if(sparam == PNL + "trail")  g_trail = !g_trail;
   else if(sparam == PNL + "lot_m")
   {
      if(g_riskMode) g_risk = MathMax(0.25, g_risk - 0.25);
      else           g_lot  = MathMax(MarketInfo(g_src, MODE_MINLOT), g_lot - lotStep);
   }
   else if(sparam == PNL + "lot_p")
   {
      if(g_riskMode) g_risk += 0.25;
      else           g_lot = MathMin(MarketInfo(g_src, MODE_MAXLOT), g_lot + lotStep);
   }
   else if(sparam == PNL + "sl_m") { g_slPrice = 0; g_sl = MathMax(0, g_sl - 5); g_txtSL = ""; }
   else if(sparam == PNL + "sl_p") { g_slPrice = 0; g_sl += 5; g_txtSL = ""; }
   else if(sparam == PNL + "tp_m") { g_tpPrice = 0; g_tp = MathMax(0, g_tp - 5); g_txtTP = ""; }
   else if(sparam == PNL + "tp_p") { g_tpPrice = 0; g_tp += 5; g_txtTP = ""; }
   else if(sparam == PNL + "tr_m") { g_trailPips = MathMax(1, g_trailPips - 5); g_txtTrail = ""; }
   else if(sparam == PNL + "tr_p") { g_trailPips += 5; g_txtTrail = ""; }
   else if(sparam == PNL + "report") ExportReport();
   else if(sparam == PNL + "reset")
   {
      if(g_resetArmed) { g_resetArmed = false; ResetSession(); }
      else g_resetArmed = true;
   }

   g_lot = NormalizeDouble(g_lot, 2);
   g_txtLot = "";
   SaveState();
   FlushRefresh();
   UpdatePanel();
}
//+------------------------------------------------------------------+
