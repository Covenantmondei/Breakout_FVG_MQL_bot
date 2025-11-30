//+------------------------------------------------------------------+
//|                                Price_Based_EA_XAUUSD_Improved.mq5 |
//|                                  Copyright 2025, Covenant Monday  |
//|                                     Enhanced with multiple trades |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>
CTrade trade;

// ------------------------ Inputs (tune for XAUUSD) ------------------
input double   LotSize                   = 0.10;
input bool     UseRiskPercent            = true;
input double   RiskPercent               = 0.2;
input int      ATRPeriod                 = 14;
input ENUM_TIMEFRAMES ATRTimeframe       = PERIOD_H1;
input double   ATRMultiplierSL           = 3.0;
input double   ATRMultiplierTP           = 2.0;
input double   SLBufferPoints            = 5.0;
input double   RR                        = 2.0;
input int      MinBarsInRange            = 8;
input double   MaxRangePct               = 0.15;
input int      MagicNumber               = 12345;
input bool     RequireBreakoutFVGAlign   = false;
input bool     AllowMomentumEntry        = true;
input double   RetraceTolerancePct       = 0.20;
input double   MaxSpreadPoints           = 1500;
input double   MaxATRToTrade             = 999999;
input int      MaxConcurrentTradesPerSymbol = 3;
input double   MinATRMultiplier          = 1.5;
input bool     StopTradingAfterWin       = false;
input bool     StopTradingAfterLoss      = true; 
input double   EquityMaxDrawdownPercent  = 0.05;
input double   DailyMaxLossPercent       = 0.02;
input double   MinimumSlDistancePoints   = 50;
input double   BreakevenTriggerATRMult   = 0.5;
input double   TrailATRMult              = 0.5;
input bool     EnableDebugPrints         = true;
input int      DebugPrintInterval        = 100;

input bool     UseTrendFilter           = true;
input int      TrendMAPeriod            = 50;
input ENUM_TIMEFRAMES TrendMATimeframe  = PERIOD_H1;
input double   TrendSlopeMinPoints      = 100;

input bool     EnableAdxMarketFilter    = true;
input int      AdxPeriod                = 14;
input double   AdxTrendingThreshold     = 22.0;

input bool     UseNewsBlackout          = true;
input string   NewsBlackoutWindows      = "12:25-13:05;14:25-14:45";

input bool     EnforceDirectionalCap    = true;
input int      MaxTradesPerDirection    = 2;

input bool     UseDynamicAtrStops       = true;
input double   DynamicSlAtrMult         = 1.5;
input double   DynamicTpAtrMult         = 2.0;

input bool     UseBreakevenPips         = true;
input double   BreakevenTriggerPips     = 10.0;
input bool     UseAtrTrailing           = true;
input double   TrailAtrMultiplier       = 0.75;
input bool     EnablePartialClose       = true;
input double   PartialCloseFraction     = 0.5;
input int      CooldownMinutes          = 30;
input int      LookbackBars             = 200;
input ENUM_TIMEFRAMES TrendTF           = PERIOD_H1;
input double   MinATR                   = 0.50; 

// ------------------------ Globals ------------------
int tradesToday = 0;
datetime lastTradeTime = 0;
int lastResetDay = -1;
datetime lastFVGTime = 0;
datetime lastProcessedFvgTime = 0;
bool     historicalSignalPending  = false;
bool     historicalSignalConsumed = false;
int      historicalSignalDir      = 0;
double   historicalRangeHigh      = 0.0;
double   historicalRangeLow       = 0.0;
double   historicalFvgHigh        = 0.0;
double   historicalFvgLow         = 0.0;
datetime historicalSignalTime     = 0;
int atrHandle = INVALID_HANDLE;
int maHandle = INVALID_HANDLE;
int adxHandle = INVALID_HANDLE;
int trend200Handle = INVALID_HANDLE;
int atrVolHandle   = INVALID_HANDLE;
double equity = 0.0;
double EquityPeak = 0.0;
bool StopTrading = false;
double DailyStartEquity = 0.0;
int LastTradeDay = -1;
double fvgHigh = 0.0;
double fvgLow  = 0.0;
int    fvgDirection = 0;
int    tickCounter = 0;
double recentFvgHeights[];
const int MAX_FVG_HISTORY = 10;
bool TrendFilterAllows(int direction);
double GetVolatilityAtr();
int  ComputeHistoricalLookback();
bool StageHistoricalSignal(bool skipExecutedDuplicate);
bool TryTradeHistoricalSignal(double atr);


int watchingFvgIdx[];

bool FiltersPass(int direction,double atr)
{
   // Basic example using your existing filters; adjust as needed
   if(!TrendFilterAllows(direction))
      return false;

   double volAtr = GetVolatilityAtr();
   if(volAtr <= 0 || volAtr < MinATR)
      return false;

   if(InNewsBlackout())
      return false;

   if(EnableAdxMarketFilter && !PassesAdxState())
      return false;

   if(EquityPeak > 0 && equity < EquityPeak * (1.0 - EquityMaxDrawdownPercent))
      return false;

   if(DailyStartEquity > 0 && equity < DailyStartEquity * (1.0 - DailyMaxLossPercent))
      return false;

   // Directional cap
   if(EnforceDirectionalCap && CountDirectionalTrades(direction) >= MaxTradesPerDirection)
      return false;

   return true;
}


//-------------------License Code Start----------------------//
#import "MetaTraderValidation.ex5"
bool Validate(string licenseKey);
// void updateConnectionStatus(string licenseKey);
bool Validate(string licenseKey, string productCode);
// void updateHardwareId(string licenseKey);
// void updateConnectionStatusConnected(string licenseKey);
// void updateConnectionStatusDisconnected(string licenseKey);
#import
bool auth = false;
string LicenseKeyActive = "";

input string strMA1="---------------------------------------- License Input ----------------------------------------";
input string licensekey = "";
string ProductCode = "2";
//----------------License Code End--------------------------//


struct PositionInfo
{
   ulong    ticket;
   double   entryPrice;
   double   originalSL;
   double   risk;
   bool     breakevenSet;
   double   fvgUpper;
   double   fvgLower;
};
PositionInfo positionTracker[];
struct FvgInfo
{
   int      direction;      // 1 = bullish, -1 = bearish
   double   low;            // FVG low
   double   high;           // FVG high
   datetime time;           // detection time (bar time)
   bool     mitigated;      // true once fully filled / invalidated
};
FvgInfo fvgs[];


void   TrackNewFvg(int direction,double zHigh,double zLow,datetime t);
void   UpdateFvgMitigation();
int    FindMostRecentValidFvg(int breakoutDir,int &idx);
void   PlaceFvgLimitOrder(const FvgInfo &fvg,int breakoutDir,double atr);


string MarketBias = "NEUTRAL";
int LastBreakoutDir = 0;
double lastSwingHighPrice = 0.0;
double lastSwingLowPrice = 0.0;
datetime lastSwingHighTime = 0;
datetime lastSwingLowTime = 0;
datetime lastBreakoutTime = 0;
datetime lastContextBarTime = 0;

const int NYSessionStartHour   = 13;
const int NYSessionStartMinute = 0;
const int NYSessionEndHour     = 21;
const int NYSessionEndMinute   = 59;

bool UpdateMarketContext(bool forceRefresh, bool &breakoutChanged);
bool LoadMarketContextFromHistory();
void ClosePositionsForSymbolAndMagic(string symbol, int magic, const string reason);
bool IsWithinNewYorkSession();
void RecordFvgHeight(double height);
double ComputeRecentFvgMean();
void InitializeHistoricalSignal();  
bool ScanHistoricalSignal(int lookbackBars, int &direction, double &rangeHigh, double &rangeLow, double &zoneHigh, double &zoneLow, datetime &signalTime);
bool DetectFVGAtShift(int shift, int &direction, double &zoneHigh, double &zoneLow, datetime &zoneTime);
bool GetRangeAtShift(int shift, int barsBack, double &highRange, double &lowRange);
bool IsHistoricalSignalStillValid(int direction, double rangeHigh, double rangeLow, double zoneHigh, double zoneLow);
bool TryExecuteHistoricalSignal(double atr); 

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   // auth = false;

   // LicenseKeyActive = licensekey;
   // StringTrimLeft(LicenseKeyActive);
   // StringTrimRight(LicenseKeyActive);

   // if(StringLen(LicenseKeyActive) == 0)
   // {
   //    Print("License key missing. Please enter your license.");
   //    return INIT_FAILED;
   // }

   // if(!Validate(LicenseKeyActive))
   // {
   //    Print("License validation failed. Check your key or WebRequest permissions.");
   //    return INIT_FAILED;
   // }

   // updateConnectionStatus(LicenseKeyActive);
   // updateConnectionStatusConnected(LicenseKeyActive);
   // updateHardwareId(LicenseKeyActive);
   // auth = true;


   Print("========================================");
   Print("EA INITIALIZED - Price_Based_EA_XAUUSD (IMPROVED VERSION)");
   Print("========================================");

   atrHandle = iATR(_Symbol, ATRTimeframe, ATRPeriod);
   maHandle = iMA(_Symbol, TrendMATimeframe, TrendMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   adxHandle = iADX(_Symbol, PERIOD_CURRENT, AdxPeriod);
   trend200Handle = iMA(_Symbol, TrendTF, 200, 0, MODE_EMA, PRICE_CLOSE);
   atrVolHandle   = iATR(_Symbol, PERIOD_CURRENT, 14); 
   if(UseTrendFilter && maHandle == INVALID_HANDLE)
      return INIT_FAILED;
   if(EnableAdxMarketFilter && adxHandle == INVALID_HANDLE)
      return INIT_FAILED;
   if(trend200Handle == INVALID_HANDLE || atrVolHandle == INVALID_HANDLE)
      return INIT_FAILED;
   Print("ATR, MA, and ADX Handles created successfully");

   equity = AccountInfoDouble(ACCOUNT_EQUITY);
   EquityPeak = equity;
   DailyStartEquity = equity;
   datetime t = TimeCurrent();
   MqlDateTime dt; TimeToStruct(t, dt);
   LastTradeDay = dt.day;
   StopTrading = false;

   PrintFormat("✓ Initial Equity: %.2f", equity);
   PrintFormat("✓ Symbol: %s Digits=%d Point=%.10f", 
               _Symbol, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
               SymbolInfoDouble(_Symbol, SYMBOL_POINT));
   
   Print("========================================");
   Print("INPUTS CONFIGURATION:");
   PrintFormat("  MaxRangePct: %.4f", MaxRangePct);
   PrintFormat("  MinATRMultiplier: %.2f", MinATRMultiplier);
   PrintFormat("  MaxConcurrentTradesPerSymbol: %d", MaxConcurrentTradesPerSymbol);
   PrintFormat("  StopTradingAfterWin: %s", StopTradingAfterWin ? "YES" : "NO");
   PrintFormat("  StopTradingAfterLoss: %s", StopTradingAfterLoss ? "YES" : "NO");
   PrintFormat("  RequireBreakoutFVGAlign: %s", RequireBreakoutFVGAlign ? "YES" : "NO");
   PrintFormat("  Trading window (server): %02d:%02d - %02d:%02d (New York session)",
               NYSessionStartHour, NYSessionStartMinute, NYSessionEndHour, NYSessionEndMinute);
   Print("========================================");
   
   ArrayResize(positionTracker, 0);

   bool breakoutChanged = false;
   if(!UpdateMarketContext(true, breakoutChanged))
   {
      Print("⚠️ Unable to build initial market context (insufficient historical data). Bias remains NEUTRAL.");
   }
   else
   {
      PrintFormat("Structure initialized -> Bias=%s | SwingHigh=%.5f | SwingLow=%.5f",
                  MarketBias, lastSwingHighPrice, lastSwingLowPrice);
      if(fvgDirection != 0)
         PrintFormat("Initial FVG (%s) %.5f-%.5f",
                     fvgDirection == 1 ? "bullish" : "bearish", fvgLow, fvgHigh);
      else
         Print("No qualifying FVG found within initialization window.");
   }
   InitializeHistoricalSignal(); 

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinit                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // if(auth && StringLen(LicenseKeyActive) > 0)
      // updateConnectionStatusDisconnected(LicenseKeyActive);

   if(atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(atrHandle);
      atrHandle = INVALID_HANDLE;
   }
   if(trend200Handle != INVALID_HANDLE) { IndicatorRelease(trend200Handle); trend200Handle = INVALID_HANDLE; }
   if(atrVolHandle != INVALID_HANDLE)   { IndicatorRelease(atrVolHandle);   atrVolHandle   = INVALID_HANDLE; }
   Print("EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1) Housekeeping: equity, risk controls, session checks, cooldown,
   //    open-position management, etc. — KEEP your existing logic here
   //    (UpdateEquityPeakAndDaily(), ManageOpenPositions(), session, spread, etc.)
   //    This block is unchanged except we stop BEFORE any entry logic.
   // ----------------------------------------------------------------
   tickCounter++;

   datetime now = TimeCurrent();
   MqlDateTime t;
   TimeToStruct(now, t);
   int currentDay = t.day;

   if(currentDay != lastResetDay)
   {
      tradesToday  = 0;
      lastResetDay = currentDay;
   }

   bool breakoutChanged = false;
   if(UpdateMarketContext(false, breakoutChanged) && breakoutChanged)
   {
      ClosePositionsForSymbolAndMagic(_Symbol, MagicNumber, "opposite breakout");
      if(EnableDebugPrints)
         PrintFormat("📈 Market bias updated to %s after breakout.", MarketBias);
   }

   equity = AccountInfoDouble(ACCOUNT_EQUITY);
   UpdateEquityPeakAndDaily();

   ManageOpenPositions();

   if(!IsWithinNewYorkSession())
   {
      if(EnableDebugPrints && tickCounter % DebugPrintInterval == 0)
         Print("🕑 Outside New York session - entries paused.");
      return;
   }

   if(StopTrading)
   {
      if(EnableDebugPrints && tickCounter % DebugPrintInterval == 0)
         Print("⛔ Trading stopped");
      return;
   }

   int openPositions = CountPositionsForSymbolAndMagic(_Symbol, MagicNumber);
   if(openPositions >= MaxConcurrentTradesPerSymbol)
   {
      if(EnableDebugPrints && tickCounter % DebugPrintInterval == 0)
         PrintFormat("📊 Max concurrent trades: %d/%d", openPositions, MaxConcurrentTradesPerSymbol);
      return;
   }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(point <= 0 || ask <= 0 || bid <= 0)
      return;

   double spreadPoints = (ask - bid) / point;
   if(spreadPoints > MaxSpreadPoints)
   {
      if(EnableDebugPrints && tickCounter % (DebugPrintInterval*5) == 0)
         PrintFormat("❌ SPREAD: %.1f > %.1f", spreadPoints, MaxSpreadPoints);
      return;
   }

   double atr = GetATR();
   if(atr <= 0)
   {
      if(EnableDebugPrints && tickCounter % (DebugPrintInterval*5) == 0)
         Print("❌ ATR unavailable");
      return;
   }

   if(atr > MaxATRToTrade)
   {
      if(EnableDebugPrints && tickCounter % (DebugPrintInterval*5) == 0)
         PrintFormat("❌ ATR: %.5f > %.5f", atr, MaxATRToTrade);
      return;
   }

   if(tradesToday >= 3)
   {
      if(EnableDebugPrints && tickCounter % DebugPrintInterval == 0)
         Print("📉 Max trades reached today");
      return;
   }

   if((now - lastTradeTime) < CooldownMinutes * 60)
   {
      if(EnableDebugPrints && tickCounter % DebugPrintInterval == 0)
         Print("Cooling down - waiting before next trade");
      return;
   }

   // ----------------------------------------------------------------
   // 2) CONTINUOUSLY detect new FVGs
   // ----------------------------------------------------------------
   int    fvgDir    = 0;
   double zHigh     = 0.0;
   double zLow      = 0.0;
   datetime fvgTime = 0;

   bool hasNewFvg = DetectFVG(fvgDir, zHigh, zLow, fvgTime);

   if(hasNewFvg)
   {
      // Only track if this FVG is actually new (by time)
      bool alreadyTracked = false;
      for(int i = ArraySize(fvgs)-1; i >= 0; --i)
      {
         if(fvgs[i].time == fvgTime &&
            MathAbs(fvgs[i].high - zHigh) < point &&
            MathAbs(fvgs[i].low  - zLow)  < point)
         {
            alreadyTracked = true;
            break;
         }
      }

      if(!alreadyTracked)
      {
         TrackNewFvg(fvgDir, zHigh, zLow, fvgTime);
         RecordFvgHeight(MathAbs(zHigh - zLow));

         if(EnableDebugPrints)
            PrintFormat("🎯 New FVG tracked: dir=%s [%.5f-%.5f] @ %s",
                        fvgDir == 1 ? "BULLISH" : "BEARISH",
                        MathMin(zLow,zHigh), MathMax(zLow,zHigh),
                        TimeToString(fvgTime, TIME_DATE|TIME_MINUTES));
      }
   }

   // ----------------------------------------------------------------
   // 3) CONTINUOUSLY update FVG mitigation status
   // ----------------------------------------------------------------
   UpdateFvgMitigation();

   // ----------------------------------------------------------------
   // 4) Detect Range and Breakout (BOS) using DetectBreakout()
   //    NOTE: breakout does NOT need to be on same candle as FVG.
   // ----------------------------------------------------------------
   double highRange, lowRange;
   bool rangeDetected = DetectRange(MinBarsInRange, highRange, lowRange);

   if(!rangeDetected)
   {
      int fallbackBars = MathMax(MinBarsInRange, 4);
      int idxHigh = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, fallbackBars, 1);
      int idxLow  = iLowest (_Symbol, PERIOD_CURRENT, MODE_LOW,  fallbackBars, 1);
      highRange   = iHigh(_Symbol, PERIOD_CURRENT, idxHigh);
      lowRange    = iLow (_Symbol, PERIOD_CURRENT, idxLow);

      if(EnableDebugPrints && tickCounter % (DebugPrintInterval*2) == 0)
         Print("⏸ No tight range; using fallback envelope.");
   }

   int breakoutDir = DetectBreakout(highRange, lowRange);
   if(EnableDebugPrints && breakoutDir != 0)
      PrintFormat("🚀 BREAKOUT detected: %s",
                  breakoutDir == 1 ? "BULLISH" : "BEARISH");

   // ----------------------------------------------------------------
   // 5) When a BOS occurs, find the most recent valid FVG
   //    and start WATCHING it for retracement.
   // ----------------------------------------------------------------
   if(breakoutDir != 0)
   {
      int fvgIdx = -1;
      if(FindMostRecentValidFvg(breakoutDir, fvgIdx) == 1 && fvgIdx >= 0)
      {
         // Avoid duplicates in watching list
         bool alreadyWatching = false;
         for(int i = 0; i < ArraySize(watchingFvgIdx); ++i)
         {
            if(watchingFvgIdx[i] == fvgIdx)
            {
               alreadyWatching = true;
               break;
            }
         }

         if(!alreadyWatching)
         {
            int sz = ArraySize(watchingFvgIdx);
            ArrayResize(watchingFvgIdx, sz + 1);
            watchingFvgIdx[sz] = fvgIdx;

            if(EnableDebugPrints)
               PrintFormat("👀 Now watching FVG idx=%d dir=%d [%.5f-%.5f] after BOS.",
                           fvgIdx,
                           fvgs[fvgIdx].direction,
                           fvgs[fvgIdx].low,
                           fvgs[fvgIdx].high);
         }
      }
      else if(EnableDebugPrints)
      {
         Print("ℹ️ No valid FVG found to watch for this breakout.");
      }
   }

   // ----------------------------------------------------------------
   // 6) For each watched FVG, wait for retracement back into the gap.
   //    When price retraces into it:
   //      - Check FiltersPass()
   //      - PlaceFvgLimitOrder()
   //      - Stop watching that FVG
   //    Also ignore FVGs that are mitigated/invalid.
   // ----------------------------------------------------------------
   if(ArraySize(watchingFvgIdx) > 0)
   {
      double price = (breakoutDir == 1) ? bid : ask; // generic; we use per-FVG direction below

      for(int i = ArraySize(watchingFvgIdx) - 1; i >= 0; --i)
      {
         int idx = watchingFvgIdx[i];
         if(idx < 0 || idx >= ArraySize(fvgs))
         {
            // Out-of-range index; drop it
            ArrayRemove(watchingFvgIdx, i);
            continue;
         }

         FvgInfo f = fvgs[idx];

         // Drop mitigated/invalid FVGs
         if(f.mitigated)
         {
            if(EnableDebugPrints)
               PrintFormat("🧹 FVG idx=%d no longer valid (mitigated). Stop watching.", idx);
            ArrayRemove(watchingFvgIdx, i);
            continue;
         }

         // Directional logic: we only act when price RETRACES into the gap
         double fLow  = MathMin(f.low,  f.high);
         double fHigh = MathMax(f.low,  f.high);
         double curBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double curAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(curBid <= 0 || curAsk <= 0)
            continue;

         bool retraced = false;
         if(f.direction == 1) // bullish FVG: look for price dipping back into [low,high]
         {
            double checkPrice = curBid; // retrace down into the gap
            retraced = (checkPrice <= fHigh && checkPrice >= fLow);
         }
         else if(f.direction == -1) // bearish FVG: look for price rallying back into [low,high]
         {
            double checkPrice = curAsk; // retrace up into the gap
            retraced = (checkPrice >= fLow && checkPrice <= fHigh);
         }

         if(!retraced)
            continue;

         // Filters check
         if(!FiltersPass(f.direction, atr))
         {
            if(EnableDebugPrints)
               PrintFormat("🚫 Filters blocked FVG idx=%d dir=%d.", idx, f.direction);
            // Optionally stop watching, or keep watching for a later retrace.
            // Here we drop it to avoid repeated spam.
            ArrayRemove(watchingFvgIdx, i);
            continue;
         }

         // Place limit order at optimal price using PlaceFvgLimitOrder()
         if(EnableDebugPrints)
            PrintFormat("✅ Retrace detected into FVG idx=%d; placing limit order.", idx);

         PlaceFvgLimitOrder(f, f.direction, atr);

         // Stop watching this FVG after placing the order
         ArrayRemove(watchingFvgIdx, i);
      }
   }
}
//+------------------------------------------------------------------+
//| Get ATR                                                           |
//+------------------------------------------------------------------+
double GetATR()
{
   if(atrHandle == INVALID_HANDLE) return 0.0;
   double arr[];
   if(CopyBuffer(atrHandle, 0, 1, 1, arr) > 0)
      return arr[0];
   return 0.0;
}

//+------------------------------------------------------------------+
//| Update equity peak & daily                                        |
//+------------------------------------------------------------------+
void UpdateEquityPeakAndDaily()
{
   datetime t = TimeCurrent();
   MqlDateTime dt; TimeToStruct(t, dt);
   
   if(dt.day != LastTradeDay)
   {
      LastTradeDay = dt.day;
      DailyStartEquity = equity;
      StopTrading = false;
      PrintFormat("📅 NEW DAY: Equity=%.2f | StopTrading RESET", DailyStartEquity);
   }

   if(equity > EquityPeak) EquityPeak = equity;

   if(EquityPeak > 0 && equity < EquityPeak * (1.0 - EquityMaxDrawdownPercent))
   {
      //StopTrading = true;
      PrintFormat("🛑 STOP: Drawdown! Peak=%.2f Current=%.2f", EquityPeak, equity);
      return;
   }

   if(DailyStartEquity > 0 && equity < DailyStartEquity * (1.0 - DailyMaxLossPercent))
   {
      //StopTrading = true;
      PrintFormat("🛑 STOP: Daily loss! Start=%.2f Current=%.2f", DailyStartEquity, equity);
      return;
   }
}

//+------------------------------------------------------------------+
//| Manage positions                                                  |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   int total = PositionsTotal();
   SyncPositionTracker();
   double lastClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posSymbol != _Symbol || (int)posMagic != MagicNumber) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      double openPrice   = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentPrice= (type == POSITION_TYPE_BUY) ? 
                           SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                           SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double positionSL  = PositionGetDouble(POSITION_SL);
      double positionTP  = PositionGetDouble(POSITION_TP);

      int trackerIdx = FindTrackerIndex(ticket);
      if(trackerIdx < 0) continue;
      
      double risk = positionTracker[trackerIdx].risk;
      bool breakevenSet = positionTracker[trackerIdx].breakevenSet;
      double zoneHigh   = positionTracker[trackerIdx].fvgUpper;
      double zoneLow    = positionTracker[trackerIdx].fvgLower;

      bool closeEarly = false;
      if(lastClose > 0 && zoneHigh > 0 && zoneLow > 0)
      {
         if(type == POSITION_TYPE_BUY && lastClose < zoneLow)
            closeEarly = true;
         if(type == POSITION_TYPE_SELL && lastClose > zoneHigh)
            closeEarly = true;
      }

      if(closeEarly)
      {
         if(trade.PositionClose(ticket))
         {
            PrintFormat("⚠️ Early exit (FVG invalidated) Ticket=%I64u", ticket);
            RemoveFromTracker(ticket);
         }
         continue;
      }

      double currentProfit = (type == POSITION_TYPE_BUY) ? 
                             (currentPrice - openPrice) : 
                             (openPrice - currentPrice);
      
      if(currentProfit >= risk * 2.0)
      {
         if(trade.PositionClose(ticket))
         {
            PrintFormat("✅ CLOSED at 2R! Ticket=%I64u Profit=%.5f", ticket, currentProfit);
            RemoveFromTracker(ticket);
            
            if(StopTradingAfterWin)
            {
               StopTrading = true;
               Print("🏆 2R WIN - StopTrading activated");
            }
         }
         continue;
      }

      if(!breakevenSet && currentProfit >= risk)
      {
         double newSL = openPrice;
         if(trade.PositionModify(ticket, newSL, positionTP))
         {
            PrintFormat("⚖️ BREAKEVEN at 1R! Ticket=%I64u SL: %.5f->%.5f", 
                        ticket, positionSL, newSL);
            positionTracker[trackerIdx].breakevenSet = true;
         }
         continue;
      }

      // MODIFIED: Configurable stop on loss
      if((type == POSITION_TYPE_BUY && currentPrice <= positionSL + SymbolInfoDouble(_Symbol, SYMBOL_POINT)*5) ||
         (type == POSITION_TYPE_SELL && currentPrice >= positionSL - SymbolInfoDouble(_Symbol, SYMBOL_POINT)*5))
      {
         if(!breakevenSet && StopTradingAfterLoss) // Only stop if configured and we lost
         {
            Print("⛔ SL hit with loss. Stopping trading for the day.");
            //StopTrading = true;
         }
         else if(!breakevenSet)
         {
            Print("⛔ SL hit with loss. Continuing (StopTradingAfterLoss=false).");
         }
         else
         {
            Print("⚖️ Breakeven SL hit. No loss. Continuing.");
         }
         continue;
      }

      if(breakevenSet)
      {
         double atr = GetATR();
         if(atr > 0)
         {
            double desiredSL = (type == POSITION_TYPE_BUY) ? 
                               (currentPrice - atr * TrailATRMult) : 
                               (currentPrice + atr * TrailATRMult);

            if((type == POSITION_TYPE_BUY && desiredSL > positionSL) ||
               (type == POSITION_TYPE_SELL && desiredSL < positionSL))
            {
               if(trade.PositionModify(ticket, desiredSL, positionTP))
                  PrintFormat("📈 TRAILING: %.5f->%.5f", positionSL, desiredSL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Detect Range                                                      |
//+------------------------------------------------------------------+
bool DetectRange(int barsBack, double &highRange, double &lowRange)
{
   if(barsBack <= 1) barsBack = 2;
   
   int idxHigh = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, barsBack, 1);
   int idxLow  = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, barsBack, 1);
   highRange = iHigh(_Symbol, PERIOD_CURRENT, idxHigh);
   lowRange  = iLow (_Symbol, PERIOD_CURRENT, idxLow);

   double mid = (highRange + lowRange) / 2.0;
   if(mid == 0) return false;
   
   double widthPct = (highRange - lowRange) / mid;
   
   if(widthPct <= MaxRangePct)
   {
      if(EnableDebugPrints && tickCounter % (DebugPrintInterval*2) == 0)
         PrintFormat("📏 RANGE: H=%.5f L=%.5f W=%.4f%%", highRange, lowRange, widthPct*100);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect Breakout                                                   |
//+------------------------------------------------------------------+
int DetectBreakout(double highRange, double lowRange)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(ask > highRange)
      return 1;
   if(bid < lowRange)
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| Detect FVG                                                        |
//+------------------------------------------------------------------+
bool DetectFVG(int &direction, double &zoneHigh, double &zoneLow, datetime &zoneTime)
{
   zoneTime = 0;
   int totalBars = Bars(_Symbol, PERIOD_CURRENT);
   if(totalBars < 5) return false;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double epsilon = (point > 0.0) ? point * 0.5 : 1e-6;

   for(int shift = 1; shift + 2 < totalBars; ++shift)
   {
      datetime barTime = iTime(_Symbol, PERIOD_CURRENT, shift);
      if(barTime == 0) continue;

      double newestLow = iLow(_Symbol, PERIOD_CURRENT, shift);
      double newestHigh = iHigh(_Symbol, PERIOD_CURRENT, shift);
      double oldestHigh = iHigh(_Symbol, PERIOD_CURRENT, shift + 2);
      double oldestLow = iLow(_Symbol, PERIOD_CURRENT, shift + 2);

      if(newestLow > oldestHigh + epsilon)
      {
         direction = 1;
         zoneLow = oldestHigh;
         zoneHigh = newestLow;
         zoneTime = barTime;
         return true;
      }

      if(newestHigh + epsilon < oldestLow)
      {
         direction = -1;
         zoneHigh = oldestLow;
         zoneLow = newestHigh;
         zoneTime = barTime;
         return true;  
      }
   }
   return false;
}

void TrackNewFvg(int direction,double zoneHigh,double zoneLow,datetime zoneTime)
{
   int size = ArraySize(fvgs);
   ArrayResize(fvgs,size+1);
   fvgs[size].direction = direction;
   fvgs[size].low       = MathMin(zoneLow,zoneHigh);
   fvgs[size].high      = MathMax(zoneLow,zoneHigh);
   fvgs[size].time      = zoneTime;
   fvgs[size].mitigated = false;
}

void UpdateFvgMitigation()
{
   if(ArraySize(fvgs) == 0) return;

   double bid = SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   for(int i=0;i<ArraySize(fvgs);++i)
   {
      if(fvgs[i].mitigated) continue;

      // fully filled = both sides have traded through the zone
      bool filled =
         (bid <= fvgs[i].low  && ask >= fvgs[i].high) ||
         (bid >= fvgs[i].high && ask <= fvgs[i].low); // safety

      if(filled)
         fvgs[i].mitigated = true;
   }
}

int FindMostRecentValidFvg(int breakoutDir,int &idx)
{
   idx = -1;
   if(breakoutDir == 0) return 0;

   for(int i=ArraySize(fvgs)-1;i>=0;--i)
   {
      if(fvgs[i].mitigated) continue;
      if(fvgs[i].direction != breakoutDir) continue;
      idx = i;
      return 1;
   }
   return 0;
}


void PlaceFvgLimitOrder(const FvgInfo &fvg,int breakoutDir,double atr)
{
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(point <= 0) return;

   // Normalize FVG bounds
   double fLow  = MathMin(fvg.low,  fvg.high);
   double fHigh = MathMax(fvg.low,  fvg.high);
   double mid   = (fLow + fHigh) / 2.0;

   double sl  = 0.0;
   double tp  = 0.0;

   // SL strictly from FVG extremes (+ buffer)
   if(breakoutDir == 1)           // BUY
   {
      sl = fLow - SLBufferPoints * point;      // below FVG low
      double risk = MathAbs(mid - sl);
      tp = mid + risk * RR;
   }
   else if(breakoutDir == -1)     // SELL
   {
      sl = fHigh + SLBufferPoints * point;     // above FVG high
      double risk = MathAbs(sl - mid);
      tp = mid - risk * RR;
   }
   else
      return;

   if(sl <= 0 || tp <= 0) return;

   double lots = CalculateLotSize(mid,sl);
   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(minLot <= 0) minLot = 0.01;
   if(maxLot <= 0) maxLot = 100.0;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   if(step > 0) lots = MathFloor(lots/step)*step;
   lots = NormalizeDouble(lots,2);

   double riskPoints = MathAbs(mid - sl)/point;
   if(riskPoints < MinimumSlDistancePoints)
      return;

   if(EnableDebugPrints)
      PrintFormat("📌 FVG limit: dir=%d Mid=%.5f SL=%.5f TP=%.5f Lots=%.2f",
                  breakoutDir,mid,sl,tp,lots);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetAsyncMode(false);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_RETURN);

   string comment = (breakoutDir==1) ? "BuyLimit FVG" : "SellLimit FVG";
   bool ok = false;

   if(breakoutDir == 1)
      ok = trade.BuyLimit(lots,mid,_Symbol,sl,tp,ORDER_TIME_GTC,0,comment);
   else
      ok = trade.SellLimit(lots,mid,_Symbol,sl,tp,ORDER_TIME_GTC,0,comment);

   if(!ok && EnableDebugPrints)
      PrintFormat("❌ FVG limit failed. Err=%d RetCode=%d %s",
                  GetLastError(),trade.ResultRetcode(),trade.ResultRetcodeDescription());
}


//+------------------------------------------------------------------+
//| Place Market Trade                                                |
//+------------------------------------------------------------------+
void PlaceMarketTrade(int direction, double highRange, double lowRange, double atr)
{
   //if(StopTrading) return;

   Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   Print("💼 PLACING TRADE");

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (direction == 1) ? ask : bid;

   PrintFormat("  %s | Entry: %.5f | ATR: %.5f", 
               direction == 1 ? "BUY" : "SELL", entry, atr);

   double structureSL;
   if(direction == 1)
      structureSL = lowRange - SLBufferPoints * point;
   else
      structureSL = highRange + SLBufferPoints * point;

   double structureDistance = MathAbs(entry - structureSL);
   double avgFvgHeight = ComputeRecentFvgMean();
   double slDistance = structureDistance;
   if(avgFvgHeight > 0.0)
      slDistance = MathMin(structureDistance, avgFvgHeight * 1.5);

   double minDistance = MinimumSlDistancePoints * point;
   slDistance = MathMax(slDistance, minDistance);

   double sl = (direction == 1) ? (entry - slDistance) : (entry + slDistance);
   double risk = MathAbs(entry - sl);
   double tp = (direction == 1) ? (entry + risk * RR) : (entry - risk * RR);

   double slDistancePoints = risk / point;
   PrintFormat("  SL: %.5f (%.1f pts) | TP: %.5f (%.1f:1)", 
               sl, slDistancePoints, tp, RR);

   if(slDistancePoints < MinimumSlDistancePoints)
   {
      PrintFormat("❌ SL too close: %.1f < %.1f pts", slDistancePoints, MinimumSlDistancePoints);
      return;
   }

   double lots = CalculateLotSize(entry, sl);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(minLot <= 0) minLot = 0.01;
   if(maxLot <= 0) maxLot = 100.0;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   if(step > 0) lots = MathFloor(lots / step) * step;
   lots = NormalizeDouble(lots, 2);
   
   PrintFormat("  Lots: %.2f", lots);

   if(sl <= 0 || tp <= 0)
   {
      Print("❌ Invalid SL/TP");
      return;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50); // Allow 50 points slippage
   trade.SetTypeFilling(ORDER_FILLING_FOK); // Fill or Kill
   trade.SetAsyncMode(false); // Synchronous execution
   
   bool ok = false;
   string comment = (direction == 1) ? "Buy FVG" : "Sell FVG";

   // MODIFIED: Use current price explicitly for market execution
   if(direction == 1)
      ok = trade.Buy(lots, _Symbol, ask, sl, tp, comment);
   else
      ok = trade.Sell(lots, _Symbol, bid, sl, tp, comment);

   if(!ok)
   {
      PrintFormat("❌ FAILED! Error=%d RetCode=%d %s", 
                  GetLastError(), trade.ResultRetcode(), trade.ResultRetcodeDescription());
      PrintFormat("   Ask=%.5f Bid=%.5f SL=%.5f TP=%.5f", ask, bid, sl, tp);
   }
   else
   {
      ulong ticket = trade.ResultDeal(); // Use ResultDeal for market orders
      if(ticket == 0) ticket = trade.ResultOrder(); // Fallback
      PrintFormat("✅ OPENED! Ticket=%I64u Deal=%I64u", ticket, trade.ResultDeal());
      tradesToday++;
      lastTradeTime = TimeCurrent();
      
      // MODIFIED: Get actual ticket from position
      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(PositionSelectByTicket(posTicket))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               (int)PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               FindTrackerIndex(posTicket) < 0)
            {
               double actualEntry = PositionGetDouble(POSITION_PRICE_OPEN);
               double actualSL = PositionGetDouble(POSITION_SL);
               double actualRisk = MathAbs(actualEntry - actualSL);
               AddToTracker(posTicket, actualEntry, actualSL, actualRisk, fvgHigh, fvgLow);
               PrintFormat("   Position tracked: Ticket=%I64u", posTicket);
               break;
            }
         }
      }
   }
   Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
}

//+------------------------------------------------------------------+
//| Calculate lot size                                                |
//+------------------------------------------------------------------+
double CalculateLotSize(double entry, double stopLoss)
{
   double lots = LotSize;
   if(!UseRiskPercent) return lots;

   double riskAmount = equity * (RiskPercent / 100.0);
   double slDistance = MathAbs(entry - stopLoss);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double valuePerLot = 0.0;

   if(tickValue > 0 && tickSize > 0)
   {
      double ticks = slDistance / tickSize;
      valuePerLot = ticks * tickValue;
   }
   else
   {
      double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contract > 0)
         valuePerLot = contract * slDistance;
   }

   if(valuePerLot > 0)
      lots = riskAmount / valuePerLot;
   else
      lots = LotSize;

   return lots;
}

//+------------------------------------------------------------------+
//| Count positions                                                   |
//+------------------------------------------------------------------+
int CountPositionsForSymbolAndMagic(string symbol, int magic)
{
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         int posMagic = (int)PositionGetInteger(POSITION_MAGIC);
         if(posSymbol == symbol && posMagic == magic)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Position tracker functions                                        |
//+------------------------------------------------------------------+
void AddToTracker(ulong ticket, double entry, double sl, double risk, double zoneHigh = 0.0, double zoneLow = 0.0)
{
   int size = ArraySize(positionTracker);
   ArrayResize(positionTracker, size + 1);
   positionTracker[size].ticket = ticket;
   positionTracker[size].entryPrice = entry;
   positionTracker[size].originalSL = sl;
   positionTracker[size].risk = risk;
   positionTracker[size].breakevenSet = false;
   positionTracker[size].fvgUpper = zoneHigh;
   positionTracker[size].fvgLower = zoneLow;
   
   if(EnableDebugPrints)
      PrintFormat("📝 Tracked: %I64u Entry=%.5f Risk=%.5f", ticket, entry, risk);
}

int FindTrackerIndex(ulong ticket)
{
   for(int i = 0; i < ArraySize(positionTracker); i++)
   {
      if(positionTracker[i].ticket == ticket)
         return i;
   }
   return -1;
}

void RemoveFromTracker(ulong ticket)
{
   int idx = FindTrackerIndex(ticket);
   if(idx < 0) return;
   
   int size = ArraySize(positionTracker);
   for(int i = idx; i < size - 1; i++)
   {
      positionTracker[i] = positionTracker[i + 1];
   }
   ArrayResize(positionTracker, size - 1);
   
   if(EnableDebugPrints)
      PrintFormat("🗑️ Removed: %I64u", ticket);
}

void SyncPositionTracker()
{
   for(int i = ArraySize(positionTracker) - 1; i >= 0; i--)
   {
      ulong ticket = positionTracker[i].ticket;
      if(!PositionSelectByTicket(ticket))
      {
         RemoveFromTracker(ticket);
      }
   }
   
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      
      string posSymbol = PositionGetString(POSITION_SYMBOL);
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posSymbol != _Symbol || (int)posMagic != MagicNumber) continue;
      
      if(FindTrackerIndex(ticket) < 0)
      {
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         double risk = MathAbs(entry - sl);
         AddToTracker(ticket, entry, sl, risk);
      }
   }
}

bool UpdateMarketContext(bool forceRefresh, bool &breakoutChanged)
{
   breakoutChanged = false;

   datetime lastClosedBarTime = iTime(_Symbol, PERIOD_CURRENT, 1);
   if(lastClosedBarTime == 0)
      return false;

   if(!forceRefresh && lastContextBarTime == lastClosedBarTime)
      return true;

   int previousBreakout = LastBreakoutDir;
   if(!LoadMarketContextFromHistory())
      return false;

   lastContextBarTime = lastClosedBarTime;

   if(!forceRefresh && previousBreakout != 0 && LastBreakoutDir != 0 && LastBreakoutDir != previousBreakout)
      breakoutChanged = true;

   return true;
}

bool LoadMarketContextFromHistory()
{
   const int MIN_LOOKBACK = 200;
   int totalBars = Bars(_Symbol, PERIOD_CURRENT);
   if(totalBars < 5)
      return false;

   int barsToCopy = MathMin(totalBars, 500);
   if(barsToCopy < MIN_LOOKBACK)
      PrintFormat("⚠️ Only %d bars available; attempting context build with reduced history.", barsToCopy);

   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_CURRENT, 0, barsToCopy, rates);
   if(copied < 5)
   {
      PrintFormat("⚠️ CopyRates failed. Copied=%d LastError=%d", copied, GetLastError());
      return false;
   }
   ArraySetAsSeries(rates, true);

   lastSwingHighPrice = 0.0;
   lastSwingLowPrice = 0.0;
   lastSwingHighTime = 0;
   lastSwingLowTime = 0;
   lastBreakoutTime = 0;
   MarketBias = "NEUTRAL";

   for(int i = 2; i < copied - 2; ++i)
   {
      if(lastSwingHighPrice == 0.0)
      {
         if(rates[i].high > rates[i+1].high && rates[i].high >= rates[i-1].high)
         {
            lastSwingHighPrice = rates[i].high;
            lastSwingHighTime = rates[i].time;
         }
      }

      if(lastSwingLowPrice == 0.0)
      {
         if(rates[i].low < rates[i+1].low && rates[i].low <= rates[i-1].low)
         {
            lastSwingLowPrice = rates[i].low;
            lastSwingLowTime = rates[i].time;
         }
      }

      if(lastSwingHighPrice != 0.0 && lastSwingLowPrice != 0.0)
         break;
   }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double epsilon = (point > 0.0) ? point * 0.5 : 1e-6;

   LastBreakoutDir = 0;
   for(int i = 1; i < copied; ++i)
   {
      datetime barTime = rates[i].time;
      double closePrice = rates[i].close;

      bool bullishBreak = (lastSwingHighTime > 0 && barTime > lastSwingHighTime && closePrice > lastSwingHighPrice + epsilon);
      bool bearishBreak = (lastSwingLowTime > 0 && barTime > lastSwingLowTime && closePrice < lastSwingLowPrice - epsilon);

      if(bullishBreak || bearishBreak)
      {
         LastBreakoutDir = bullishBreak ? 1 : -1;
         lastBreakoutTime = barTime;
         break;
      }
   }

   MarketBias = (LastBreakoutDir == 1) ? "BUY" : (LastBreakoutDir == -1 ? "SELL" : "NEUTRAL");

   fvgDirection = 0;
   fvgHigh = 0.0;
   fvgLow = 0.0;
   lastFVGTime = 0;
   for(int i = 1; i + 2 < copied; ++i)
   {
      double newestLow = rates[i].low;
      double newestHigh = rates[i].high;
      double oldestHigh = rates[i+2].high;
      double oldestLow = rates[i+2].low;

      if(newestLow > oldestHigh + epsilon)
      {
         fvgDirection = 1;
         fvgLow = oldestHigh;
         fvgHigh = newestLow;
         lastFVGTime = rates[i].time;
         break;
      }

      if(newestHigh + epsilon < oldestLow)
      {
         fvgDirection = -1;
         fvgHigh = oldestLow;
         fvgLow = newestHigh;
         lastFVGTime = rates[i].time;
         break;
      }
   }

   if(EnableDebugPrints)
   {
      PrintFormat("Structure scan: SwingHigh=%.5f (%s) | SwingLow=%.5f (%s)",
                  lastSwingHighPrice,
                  lastSwingHighTime > 0 ? TimeToString(lastSwingHighTime, TIME_DATE|TIME_MINUTES) : "n/a",
                  lastSwingLowPrice,
                  lastSwingLowTime > 0 ? TimeToString(lastSwingLowTime, TIME_DATE|TIME_MINUTES) : "n/a");
      PrintFormat("Bias set to %s (BreakoutDir=%d @ %s)",
                  MarketBias,
                  LastBreakoutDir,
                  lastBreakoutTime > 0 ? TimeToString(lastBreakoutTime, TIME_DATE|TIME_MINUTES) : "n/a");
      if(fvgDirection != 0)
         PrintFormat("FVG %s zone: %.5f - %.5f (%s)",
                     fvgDirection == 1 ? "bullish" : "bearish",
                     fvgLow, fvgHigh,
                     TimeToString(lastFVGTime, TIME_DATE|TIME_MINUTES));
      else
         Print("FVG: none detected in lookback window.");
   }

   return true;
}

void ClosePositionsForSymbolAndMagic(string symbol, int magic, const string reason)
{
   trade.SetExpertMagicNumber(magic);
   trade.SetAsyncMode(false);

   int total = PositionsTotal();
   int closed = 0;

   for(int i = total - 1; i >= 0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;

      if((int)PositionGetInteger(POSITION_MAGIC) != magic)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      if(volume <= 0.0)
         continue;

      ResetLastError();
      if(trade.PositionClose(ticket))
      {
         closed++;
         PrintFormat("🔄 Closed ticket=%I64u due to %s", ticket, reason);
         RemoveFromTracker(ticket);
      }
      else
      {
         PrintFormat("⚠️ Failed to close ticket=%I64u due to %s. Err=%d RetCode=%d %s",
                     ticket,
                     reason,
                     GetLastError(),
                     trade.ResultRetcode(),
                     trade.ResultRetcodeDescription());
      }
   }

   if(closed > 0)
   {
      SyncPositionTracker();
      PrintFormat("ℹ️ Closed %d position(s) because of %s. Current bias=%s", closed, reason, MarketBias);
   }
}

bool IsWithinNewYorkSession()
{
   datetime now = TimeCurrent();
   if(now == 0)
      return false;

   MqlDateTime dt;
   TimeToStruct(now, dt);

   bool afterStart = (dt.hour > NYSessionStartHour) ||
                     (dt.hour == NYSessionStartHour && dt.min >= NYSessionStartMinute);

   bool beforeEnd = (dt.hour < NYSessionEndHour) ||
                    (dt.hour == NYSessionEndHour && dt.min <= NYSessionEndMinute);

   if(NYSessionStartHour <= NYSessionEndHour)
      return afterStart && beforeEnd;

   return afterStart || beforeEnd; // handles overnight windows
}

void RecordFvgHeight(double height)
{
   if(height <= 0.0)
      return;

   int size = ArraySize(recentFvgHeights);
   if(size >= MAX_FVG_HISTORY)
   {
      for(int i = 1; i < size; ++i)
         recentFvgHeights[i - 1] = recentFvgHeights[i];
      recentFvgHeights[size - 1] = height;
   }
   else
   {
      ArrayResize(recentFvgHeights, size + 1);
      recentFvgHeights[size] = height;
   }
}

double ComputeRecentFvgMean()
{
   int size = ArraySize(recentFvgHeights);
   if(size == 0)
      return 0.0;

   double sum = 0.0;
   for(int i = 0; i < size; ++i)
      sum += recentFvgHeights[i];

   return sum / size;
}

string TrimString(const string text)
{
   string tmp = text;
   StringTrimLeft(tmp);
   StringTrimRight(tmp);
   return tmp;
}

bool ParseTimeString(const string text, int &hour, int &minute)
{
   string trimmed = TrimString(text);
   string parts[];
   if(StringSplit(trimmed, ':', parts) != 2)
      return false;

   hour   = (int)StringToInteger(parts[0]);
   minute = (int)StringToInteger(parts[1]);
   return (hour >= 0 && hour < 24 && minute >= 0 && minute < 60);
}

bool PassesTrendSlope()
{
   if(!UseTrendFilter || maHandle == INVALID_HANDLE)
      return true;

   double values[2];
   if(CopyBuffer(maHandle, 0, 0, 2, values) != 2)
      return true;

   double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double slopePoints = (point > 0.0) ? (values[0] - values[1]) / point : (values[0] - values[1]);

   if(fvgDirection == 1)
      return slopePoints >= TrendSlopeMinPoints;
   if(fvgDirection == -1)
      return slopePoints <= -TrendSlopeMinPoints;

   return true;
}

bool PassesAdxState()
{
   if(!EnableAdxMarketFilter || adxHandle == INVALID_HANDLE)
      return true;

   double val[1];
   if(CopyBuffer(adxHandle, 0, 1, 1, val) != 1)
      return true;

   return val[0] >= AdxTrendingThreshold;
}

bool InNewsBlackout()
{
   if(!UseNewsBlackout || StringLen(NewsBlackoutWindows) == 0)
      return false;

   datetime now   = TimeCurrent();
   string   today = TimeToString(now, TIME_DATE);

   string segments[];
   int total = StringSplit(NewsBlackoutWindows, ';', segments);
   for(int i = 0; i < total; ++i)
   {
      string window = TrimString(segments[i]);
      if(StringLen(window) == 0)
         continue;

      string times[2];
      if(StringSplit(window, '-', times) != 2)
         continue;

      int startHour, startMinute, endHour, endMinute;
      if(!ParseTimeString(times[0], startHour, startMinute))
         continue;
      if(!ParseTimeString(times[1], endHour, endMinute))
         continue;

      datetime startTime = StringToTime(StringFormat("%s %02d:%02d", today, startHour, startMinute));
      datetime endTime   = StringToTime(StringFormat("%s %02d:%02d", today, endHour, endMinute));
      if(startTime == 0 || endTime == 0)
         continue;

      if(endTime < startTime)
         endTime += 24 * 60 * 60;

      datetime checkTime = now;
      if(checkTime < startTime)
         checkTime += 24 * 60 * 60;

      if(checkTime >= startTime && checkTime <= endTime)
         return true;
   }
   return false;
}


void InitializeHistoricalSignal()
{
   historicalSignalPending  = false;
   historicalSignalConsumed = false;
   historicalSignalDir      = 0;
   historicalRangeHigh      = 0.0;
   historicalRangeLow       = 0.0;
   historicalFvgHigh        = 0.0;
   historicalFvgLow         = 0.0;
   historicalSignalTime     = 0;

   int dir = 0;
   double rangeHigh = 0.0, rangeLow = 0.0;
   double zoneHigh = 0.0, zoneLow = 0.0;
   datetime sigTime = 0;

   if(ScanHistoricalSignal(LookbackBars, dir, rangeHigh, rangeLow, zoneHigh, zoneLow, sigTime))
   {
      historicalSignalPending  = true;
      historicalSignalDir      = dir;
      historicalRangeHigh      = rangeHigh;
      historicalRangeLow       = rangeLow;
      historicalFvgHigh        = zoneHigh;
      historicalFvgLow         = zoneLow;
      historicalSignalTime     = sigTime;

      PrintFormat("⏪ Historical signal detected (%s) from %s.",
                  dir == 1 ? "BUY" : "SELL",
                  TimeToString(sigTime, TIME_DATE|TIME_MINUTES));
   }
}

bool TryExecuteHistoricalSignal(double atr)
{
   if(historicalSignalConsumed || !historicalSignalPending)
      return false;

   if(!IsHistoricalSignalStillValid(historicalSignalDir,
                                    historicalRangeHigh,
                                    historicalRangeLow,
                                    historicalFvgHigh,
                                    historicalFvgLow))
   {
      historicalSignalPending  = false;
      historicalSignalConsumed = true;
      if(EnableDebugPrints)
         Print("⏪ Historical signal invalidated before execution.");
      return false;
   }

   if(EnableDebugPrints)
      PrintFormat("⏪ Executing historical %s signal.",
                  historicalSignalDir == 1 ? "BUY" : "SELL");

   fvgDirection = historicalSignalDir;
   fvgHigh      = historicalFvgHigh;
   fvgLow       = historicalFvgLow;
   lastProcessedFvgTime = historicalSignalTime;
   lastFVGTime          = historicalSignalTime;

   PlaceMarketTrade(historicalSignalDir, historicalRangeHigh, historicalRangeLow, atr);

   historicalSignalPending  = false;
   historicalSignalConsumed = true;
   return true;
}

bool ScanHistoricalSignal(int lookbackBars,
                          int &direction,
                          double &rangeHigh,
                          double &rangeLow,
                          double &zoneHigh,
                          double &zoneLow,
                          datetime &signalTime)
{
   int totalBars = Bars(_Symbol, PERIOD_CURRENT);
   if(totalBars < MinBarsInRange + 5)
      return false;

   int maxShift = MathMin(lookbackBars, totalBars - (MinBarsInRange + 3));
   if(maxShift < 1)
      return false;

   for(int shift = 1; shift <= maxShift; ++shift)
   {
      int fvgDir = 0;
      double fh = 0.0, fl = 0.0;
      datetime fTime = 0;
      if(!DetectFVGAtShift(shift, fvgDir, fh, fl, fTime))
         continue;

      double rHigh = 0.0, rLow = 0.0;
      if(!GetRangeAtShift(shift, MinBarsInRange, rHigh, rLow))
         continue;

      double closePrice = iClose(_Symbol, PERIOD_CURRENT, shift);
      int breakoutDir = 0;
      if(closePrice > rHigh)
         breakoutDir = 1;
      else if(closePrice < rLow)
         breakoutDir = -1;

      if(breakoutDir == 0 || breakoutDir != fvgDir)
         continue;

      direction = fvgDir;
      rangeHigh = rHigh;
      rangeLow  = rLow;
      zoneHigh  = fh;
      zoneLow   = fl;
      signalTime = fTime;
      return true;
   }
   return false;
}

bool DetectFVGAtShift(int shift,
                      int &direction,
                      double &zoneHigh,
                      double &zoneLow,
                      datetime &zoneTime)
{
   int totalBars = Bars(_Symbol, PERIOD_CURRENT);
   if(shift + 2 >= totalBars)
      return false;

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double epsilon = (point > 0.0) ? point * 0.5 : 1e-6;

   double newestLow  = iLow (_Symbol, PERIOD_CURRENT, shift);
   double newestHigh = iHigh(_Symbol, PERIOD_CURRENT, shift);
   double oldestHigh = iHigh(_Symbol, PERIOD_CURRENT, shift + 2);
   double oldestLow  = iLow (_Symbol, PERIOD_CURRENT, shift + 2);

   if(newestLow > oldestHigh + epsilon)
   {
      direction = 1;
      zoneLow   = oldestHigh;
      zoneHigh  = newestLow;
      zoneTime  = iTime(_Symbol, PERIOD_CURRENT, shift);
      return true;
   }

   if(newestHigh + epsilon < oldestLow)
   {
      direction = -1;
      zoneHigh  = oldestLow;
      zoneLow   = newestHigh;
      zoneTime  = iTime(_Symbol, PERIOD_CURRENT, shift);
      return true;
   }

   return false;
}

bool GetRangeAtShift(int shift, int barsBack,
                     double &highRange, double &lowRange)
{
   if(barsBack <= 1)
      barsBack = 2;

   int idxHigh = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, barsBack, shift);
   int idxLow  = iLowest (_Symbol, PERIOD_CURRENT, MODE_LOW , barsBack, shift);
   if(idxHigh < 0 || idxLow < 0)
      return false;

   highRange = iHigh(_Symbol, PERIOD_CURRENT, idxHigh);
   lowRange  = iLow (_Symbol, PERIOD_CURRENT, idxLow);
   return true;
}

bool IsHistoricalSignalStillValid(int direction,
                                  double rangeHigh,
                                  double rangeLow,
                                  double zoneHigh,
                                  double zoneLow)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(direction == 1)
      return (bid >= zoneLow && bid >= rangeLow);

   if(direction == -1)
      return (ask <= zoneHigh && ask <= rangeHigh);

   return false;
}

bool TrendFilterAllows(int direction)
{
   if(direction == 0 || trend200Handle == INVALID_HANDLE)
      return false;

   double emaBuf[1];
   if(CopyBuffer(trend200Handle, 0, 0, 1, emaBuf) != 1)
      return false;

   double ema = emaBuf[0];
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(price <= 0 || ema <= 0)
      return false;

   if(direction == 1)
      return price > ema;
   return price < ema;
}

double GetVolatilityAtr()
{
   if(atrVolHandle == INVALID_HANDLE)
      return 0.0;

   double buf[1];
   if(CopyBuffer(atrVolHandle, 0, 1, 1, buf) != 1)
      return 0.0;
   return buf[0];
}

int CountDirectionalTrades(int direction)
{
   if(direction == 0)
      return 0;

   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; ++i)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;

      int type = (int)PositionGetInteger(POSITION_TYPE);
      if(direction == 1 && type == POSITION_TYPE_BUY)
         count++;
      if(direction == -1 && type == POSITION_TYPE_SELL)
         count++;
   }
   return count;
}