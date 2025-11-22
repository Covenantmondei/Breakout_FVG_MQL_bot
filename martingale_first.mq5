//+------------------------------------------------------------------+
//|             NAS100 Martingale EA (Skeleton)                     |
//|             Features: Martingale, NY Session, Max Levels        |
//|             Author: Covenant Monday                             |
//+------------------------------------------------------------------+

#property copyright "2025"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

input long   InpMagicNumber             = 987654;
input double InpBaseLot                 = 0.01;
input double InpMultiplier              = 1.6;
input int    InpMaxLevels               = 6;
input double InpStepPoints              = 20.0;
input int    InpSlippagePoints          = 20;

input double InpEquityStopPercent       = 8.0;
input double InpMaxCycleDrawdownPercent = 12.0;
input double InpProfitTargetUSD         = 50.0;
input double InpProfitTargetPercent     = 1.5;
input bool   InpUsePartialClose         = false;
input double InpPartialCloseProfitUSD   = 25.0;
input double InpPartialCloseLotFraction = 0.25;

input bool   InpAllowLong               = true;
input bool   InpAllowShort              = true;

input int    InpRSIPeriod               = 14;
input int    InpRSIBuyLevel             = 30;
input int    InpRSISellLevel            = 70;

input int    InpBBPeriod                = 20;
input double InpBBDeviation             = 5.0;

input int    InpMACDFast                = 12;
input int    InpMACDSlow                = 26;
input int    InpMACDSignal              = 9;

input int    InpADXPeriod               = 14;
input double InpADXMax                  = 35.0;
input ENUM_MA_METHOD InpTrendMethod     = MODE_EMA;
input int    InpTrendMAPeriod           = 50;
input double InpMaSlopeMaxPoints        = 60.0;

input bool   InpUseSessionFilter        = true;
input string InpSessionStart            = "14:30";
input string InpSessionEnd              = "21:00";

input bool   InpAvoidNewsWindows        = true;
input string InpNewsWindows             = "13:25-14:05;18:55-19:20";

input bool   InpDrawDashboard           = true;

struct CycleMetrics
{
   int                count;
   double             totalLots;
   double             netProfit;
   ENUM_POSITION_TYPE direction;
   ulong              lastTicket;
   double             lastPrice;
   datetime           firstTime;
   datetime           lastTime;
};

CTrade        trade;
CPositionInfo pos;

int    g_rsiHandle   = INVALID_HANDLE;
int    g_bbHandle    = INVALID_HANDLE;
int    g_macdHandle  = INVALID_HANDLE;
int    g_adxHandle   = INVALID_HANDLE;
int    g_maHandle    = INVALID_HANDLE;

bool   g_cyclePaused = false;
string g_pauseReason = "";

double g_point;
double g_tickSize;
double g_minLot;
double g_lotStep;
double g_maxLot;

int OnInit()
{
   g_point    = _Point;
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   trade.SetExpertMagicNumber(InpMagicNumber);

   g_rsiHandle  = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   g_bbHandle   = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   g_macdHandle = iMACD(_Symbol, _Period, InpMACDFast, InpMACDSlow, InpMACDSignal, PRICE_CLOSE);
   g_adxHandle  = iADX(_Symbol, _Period, InpADXPeriod);
   g_maHandle   = iMA(_Symbol, _Period, InpTrendMAPeriod, 0, InpTrendMethod, PRICE_CLOSE);

   if(g_rsiHandle==INVALID_HANDLE || g_bbHandle==INVALID_HANDLE || g_macdHandle==INVALID_HANDLE ||
      g_adxHandle==INVALID_HANDLE || g_maHandle==INVALID_HANDLE)
   {
      Print("Indicator handle creation failed. Error: ", GetLastError());
      return(INIT_FAILED);
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_rsiHandle!=INVALID_HANDLE)  IndicatorRelease(g_rsiHandle);
   if(g_bbHandle!=INVALID_HANDLE)   IndicatorRelease(g_bbHandle);
   if(g_macdHandle!=INVALID_HANDLE) IndicatorRelease(g_macdHandle);
   if(g_adxHandle!=INVALID_HANDLE)  IndicatorRelease(g_adxHandle);
   if(g_maHandle!=INVALID_HANDLE)   IndicatorRelease(g_maHandle);
   Comment("");
}

void OnTick()
{
   CycleMetrics cycle;
   bool hasCycle = GatherCycleMetrics(cycle);

   if(!PreTradeChecks(hasCycle, cycle))
   {
      UpdateDashboard(hasCycle, cycle);
      return;
   }

   if(hasCycle)
   {
      if(CycleMeetsProfitTarget(cycle))
      {
         CloseEntireCycle();
         g_cyclePaused = false;
         g_pauseReason = "";
         UpdateDashboard(false, cycle);
         return;
      }

      if(CheckCycleDrawdown(cycle))
      {
         UpdateDashboard(true, cycle);
         return;
      }

      TryOpenNextLevel(cycle);
      MaybePartialClose(cycle);
   }
   else
   {
      g_cyclePaused = false;
      g_pauseReason = "";

      TryOpenBaseTrade();
   }

   UpdateDashboard(hasCycle, cycle);
}

/*----------------------------- Core Helpers ---------------------------------*/

bool PreTradeChecks(const bool hasCycle, const CycleMetrics &cycle)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return(false);

   if(AccountInfoDouble(ACCOUNT_BALANCE) <= 0)
      return(false);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct   = (balance>0.0) ? (balance-equity)/balance*100.0 : 0.0;

   if(ddPct >= InpEquityStopPercent)
   {
      g_cyclePaused = true;
      g_pauseReason = "Equity stop";
      return(false);
   }

   if(InpUseSessionFilter && !IsWithinTimeWindow(InpSessionStart, InpSessionEnd))
   {
      g_pauseReason = "Session closed";
      return(false);
   }

   if(InpAvoidNewsWindows && IsWithinNewsPause())
   {
      g_pauseReason = "News pause";
      return(false);
   }

   if(hasCycle && cycle.count>0)
   {
      if((double)cycle.count >= InpMaxLevels)
      {
         g_pauseReason = "Max levels";
         return(false);
      }
   }

   return(true);
}

bool TryOpenBaseTrade()
{
   double rsi, bbUpper, bbMiddle, bbLower, macdMain, macdSignal, adx, maSlope;
   if(!FetchIndicatorValues(rsi, bbUpper, bbMiddle, bbLower, macdMain, macdSignal, adx, maSlope))
      return(false);

   bool ranging = (adx <= InpADXMax && maSlope <= InpMaSlopeMaxPoints);

   if(!ranging)
   {
      g_pauseReason = "Trend too strong";
      return(false);
   }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool buySignal  = InpAllowLong  && (rsi <= InpRSIBuyLevel)  && (bid <= bbLower + 2*g_point) && (macdMain <= macdSignal);
   bool sellSignal = InpAllowShort && (rsi >= InpRSISellLevel) && (ask >= bbUpper - 2*g_point) && (macdMain >= macdSignal);

   double lot = NormalizeLot(InpBaseLot);

   if(buySignal)
      return(OpenPosition(POSITION_TYPE_BUY, lot, 1));

   if(sellSignal)
      return(OpenPosition(POSITION_TYPE_SELL, lot, 1));

   return(false);
}

void TryOpenNextLevel(const CycleMetrics &cycle)
{
   if(g_cyclePaused || cycle.count <= 0)
      return;

   double stepPrice = InpStepPoints * g_point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   ENUM_POSITION_TYPE dir = cycle.direction;
   bool ready = false;

   if(dir == POSITION_TYPE_BUY)
      ready = (bid <= cycle.lastPrice - stepPrice);
   else if(dir == POSITION_TYPE_SELL)
      ready = (ask >= cycle.lastPrice + stepPrice);

   if(!ready)
      return;

   int nextLevel = cycle.count + 1;
   if(nextLevel > InpMaxLevels)
      return;

   double lot = NormalizeLot(InpBaseLot * MathPow(InpMultiplier, nextLevel-1));
   OpenPosition(dir, lot, nextLevel);
}

bool OpenPosition(const ENUM_POSITION_TYPE type, const double lot, const int level)
{
   if(lot < g_minLot || lot > g_maxLot + 1e-8)
      return(false);

   double price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                              : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double slippage = InpSlippagePoints;

   trade.SetDeviationInPoints((int)slippage);
   string comment = StringFormat("NAS100_Marti_L%d", level);

   bool ok = false;
   if(type == POSITION_TYPE_BUY)
      ok = trade.Buy(lot, _Symbol, price, 0.0, 0.0, comment);
   else
      ok = trade.Sell(lot, _Symbol, price, 0.0, 0.0, comment);

   if(!ok)
      PrintFormat("Order send failed. Level=%d Error=%d", level, GetLastError());

   return(ok);
}

bool CloseEntireCycle()
{
   bool result = true;
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      long magic = (long)PositionGetInteger(POSITION_MAGIC);
      if(magic != InpMagicNumber)
         continue;

      if(!trade.PositionClose(ticket))
      {
         Print("Failed to close ticket ", ticket, " err=", GetLastError());
         result = false;
      }
   }
   return(result);
}

bool CycleMeetsProfitTarget(const CycleMetrics &cycle)
{
   if(cycle.count == 0)
      return(false);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double target  = MathMax(InpProfitTargetUSD, balance * InpProfitTargetPercent * 0.01);

   return(cycle.netProfit >= target);
}

bool CheckCycleDrawdown(const CycleMetrics &cycle)
{
   if(cycle.count == 0)
      return(false);

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double limit   = -balance * InpMaxCycleDrawdownPercent * 0.01;

   if(cycle.netProfit <= limit)
   {
      g_cyclePaused = true;
      g_pauseReason = "Cycle DD limit";
      return(true);
   }

   return(false);
}

void MaybePartialClose(const CycleMetrics &cycle)
{
   if(!InpUsePartialClose || cycle.count == 0)
      return;

   if(cycle.netProfit < InpPartialCloseProfitUSD)
      return;

   ulong bestTicket = 0;
   double bestProfit = -DBL_MAX;

   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > bestProfit)
      {
         bestProfit = profit;
         bestTicket = ticket;
      }
   }

   if(bestTicket == 0)
      return;

   if(!PositionSelectByTicket(bestTicket))
      return;

   double volume = PositionGetDouble(POSITION_VOLUME);
   double closeVol = MathMax(g_minLot, NormalizeVolume(volume * InpPartialCloseLotFraction));

   if(closeVol >= volume)
      return;

   trade.PositionClosePartial(bestTicket, closeVol);
}

/*---------------------------- Indicator Logic --------------------------------*/

bool FetchIndicatorValues(double &rsi, double &bbUpper, double &bbMiddle, double &bbLower,
                          double &macdMain, double &macdSignal, double &adx, double &maSlope)
{
   double buffer[2];

   if(CopyBuffer(g_rsiHandle, 0, 0, 1, buffer) <= 0)
      return(false);
   rsi = buffer[0];

   double bandUpper[1], bandMiddle[1], bandLower[1];
   if(CopyBuffer(g_bbHandle, 0, 0, 1, bandUpper) <= 0) return(false);
   if(CopyBuffer(g_bbHandle, 1, 0, 1, bandMiddle) <= 0) return(false);
   if(CopyBuffer(g_bbHandle, 2, 0, 1, bandLower) <= 0) return(false);
   bbUpper = bandUpper[0];
   bbMiddle = bandMiddle[0];
   bbLower = bandLower[0];

   double macdMainBuf[1], macdSignalBuf[1];
   if(CopyBuffer(g_macdHandle, 0, 0, 1, macdMainBuf) <= 0) return(false);
   if(CopyBuffer(g_macdHandle, 1, 0, 1, macdSignalBuf) <= 0) return(false);
   macdMain   = macdMainBuf[0];
   macdSignal = macdSignalBuf[0];

   double adxBuf[1];
   if(CopyBuffer(g_adxHandle, 0, 0, 1, adxBuf) <= 0)
      return(false);
   adx = adxBuf[0];

   double maBuf[2];
   if(CopyBuffer(g_maHandle, 0, 0, 2, maBuf) < 2)
      return(false);
   double maSlopePrice = MathAbs(maBuf[0] - maBuf[1]);
   maSlope = maSlopePrice / g_point;

   return(true);
}

/*---------------------------- Time Filters -----------------------------------*/

bool IsWithinTimeWindow(const string startStr, const string endStr)
{
   int startMin, endMin;
   if(!ParseTimeRange(startStr, endStr, startMin, endMin))
      return(true); // malformed = allow

   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);
   int minuteOfDay = t.hour * 60 + t.min;

   if(startMin <= endMin)
      return(minuteOfDay >= startMin && minuteOfDay <= endMin);

   // overnight wrap
   return(minuteOfDay >= startMin || minuteOfDay <= endMin);
}

bool IsWithinNewsPause()
{
   string windows = Trim(InpNewsWindows);
   if(windows == "")
      return(false);

   StringReplace(windows, " ", "");
   string entries[];
   int count = StringSplit(windows, ';', entries);
   if(count <= 0)
      return(false);

   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);
   int minuteOfDay = t.hour * 60 + t.min;

   for(int i=0; i<count; ++i)
   {
      if(entries[i] == "")
         continue;

      string bounds[];
      if(StringSplit(entries[i], '-', bounds) != 2)
         continue;

      int startMin = 0, endMin = 0;
      if(!ParseTimeRange(bounds[0], bounds[1], startMin, endMin))
         continue;

      if(startMin <= endMin)
      {
         if(minuteOfDay >= startMin && minuteOfDay <= endMin)
            return(true);
      }
      else
      {
         if(minuteOfDay >= startMin || minuteOfDay <= endMin)
            return(true);
      }
   }
   return(false);
}

bool ParseTimeRange(const string startStr, const string endStr, int &startMin, int &endMin)
{
   if(!TimeStringToMinutes(startStr, startMin))
      return(false);
   if(!TimeStringToMinutes(endStr, endMin))
      return(false);
   return(true);
}

bool TimeStringToMinutes(const string hhmm, int &minutesOut)
{
   string clean = Trim(hhmm);
   if(clean == "")
      return(false);

   string parts[];
   if(StringSplit(clean, ':', parts) != 2)
      return(false);

   int hh = (int)StringToInteger(parts[0]);
   int mm = (int)StringToInteger(parts[1]);

   hh = MathMax(0, MathMin(23, hh));
   mm = MathMax(0, MathMin(59, mm));

   minutesOut = hh * 60 + mm;
   return(true);
}

/*--------------------------- Cycle Accounting --------------------------------*/

bool GatherCycleMetrics(CycleMetrics &cycle)
{
   cycle.count      = 0;
   cycle.totalLots  = 0.0;
   cycle.netProfit  = 0.0;
   cycle.lastTicket = 0;
   cycle.lastPrice  = 0.0;
   cycle.firstTime  = 0;
   cycle.lastTime   = 0;
   cycle.direction  = WRONG_VALUE;

   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT);
      double price  = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime time = (datetime)PositionGetInteger(POSITION_TIME);

      if(cycle.count == 0)
      {
         cycle.direction = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         cycle.firstTime = time;
      }

      cycle.count++;
      cycle.totalLots += volume;
      cycle.netProfit += profit;

      if(time >= cycle.lastTime)
      {
         cycle.lastTime   = time;
         cycle.lastTicket = ticket;
         cycle.lastPrice  = price;
      }
   }

   return(cycle.count > 0);
}

/*--------------------------- Dashboard ---------------------------------------*/

void UpdateDashboard(const bool hasCycle, const CycleMetrics &cycle)
{
   if(!InpDrawDashboard)
      return;

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct   = (balance>0.0) ? (balance-equity)/balance*100.0 : 0.0;

   string status = hasCycle ? ((cycle.direction == POSITION_TYPE_BUY) ? "BUY" : "SELL") : "IDLE";
   double target = MathMax(InpProfitTargetUSD, balance * InpProfitTargetPercent * 0.01);

   string msg = StringFormat("Status: %s | Pos: %d/%d | Lots: %.2f | Net: %.2f USD | Target: %.2f | Equity: %.2f | DD: %.2f%%",
                              status, cycle.count, InpMaxLevels, cycle.totalLots, cycle.netProfit, target, equity, ddPct);

   if(g_pauseReason != "")
      msg += "\nPause: " + g_pauseReason;

   Comment(msg);
}

/*--------------------------- Utility Helpers ---------------------------------*/

double NormalizeLot(const double volume)
{
   double lot = MathMax(g_minLot, MathMin(volume, g_maxLot));
   int steps  = (int)MathRound((lot - g_minLot) / g_lotStep);
   return(NormalizeDouble(g_minLot + steps * g_lotStep, 4));
}

double NormalizeVolume(const double volume)
{
   int steps = (int)MathRound(volume / g_lotStep);
   return(NormalizeDouble(steps * g_lotStep, 4));
}


string Trim(const string text)
{
   string s = text;
   StringTrimLeft(s);
   StringTrimRight(s);
   return(s);
}