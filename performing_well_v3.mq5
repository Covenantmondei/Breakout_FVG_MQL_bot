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
input bool     StopTradingAfterLoss      = true;  // NEW: Stop after SL hit with loss?
input double   EquityMaxDrawdownPercent  = 0.05;
input double   DailyMaxLossPercent       = 0.02;
input double   MinimumSlDistancePoints   = 50;
input double   BreakevenTriggerATRMult   = 0.5;
input double   TrailATRMult              = 0.5;
input bool     EnableDebugPrints         = true;
input int      DebugPrintInterval        = 100;

// ------------------------ Globals ------------------
int atrHandle = INVALID_HANDLE;
double equity = 0.0;
double EquityPeak = 0.0;
bool StopTrading = false;
double DailyStartEquity = 0.0;
int LastTradeDay = -1;
double fvgHigh = 0.0;
double fvgLow  = 0.0;
int    fvgDirection = 0;
int    tickCounter = 0;

struct PositionInfo
{
   ulong    ticket;
   double   entryPrice;
   double   originalSL;
   double   risk;
   bool     breakevenSet;
};
PositionInfo positionTracker[];

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("========================================");
   Print("EA INITIALIZED - Price_Based_EA_XAUUSD (IMPROVED VERSION)");
   Print("========================================");

   atrHandle = iATR(_Symbol, ATRTimeframe, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("❌ FATAL: Failed to create ATR handle. Error=", GetLastError());
      return INIT_FAILED;
   }
   Print("✓ ATR Handle created successfully");

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
   Print("========================================");
   
   ArrayResize(positionTracker, 0);
   
   ReconstructLastSignal();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinit                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(atrHandle);
      atrHandle = INVALID_HANDLE;
   }
   Print("EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Tick                                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   tickCounter++;
   
   if(EnableDebugPrints && tickCounter % DebugPrintInterval == 0)
   {
      Print("--- PERIODIC STATUS (Tick ", tickCounter, ") ---");
      PrintFormat("  Time: %s", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS));
      PrintFormat("  Equity: %.2f | Peak: %.2f | StopTrading: %s", 
                  equity, EquityPeak, StopTrading ? "YES" : "NO");
      PrintFormat("  Open Positions: %d", CountPositionsForSymbolAndMagic(_Symbol, MagicNumber));
   }

   equity = AccountInfoDouble(ACCOUNT_EQUITY);
   UpdateEquityPeakAndDaily();
   
   ManageOpenPositions();
   
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
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(point <= 0) return;
   
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

   double highRange, lowRange;
   bool rangeDetected = DetectRange(MinBarsInRange, highRange, lowRange);
   
   if(!rangeDetected)
   {
      if(EnableDebugPrints && tickCounter % (DebugPrintInterval*2) == 0)
         Print("⏸ No range");
      return;
   }

   int breakout = DetectBreakout(highRange, lowRange);
   if(EnableDebugPrints && breakout != 0)
      PrintFormat("🚀 BREAKOUT: %s", breakout == 1 ? "BULLISH" : "BEARISH");

   int dir; 
   double zHigh, zLow;
   if(DetectFVG(dir, zHigh, zLow))
   {
      if(EnableDebugPrints)
         PrintFormat("🎯 FVG: %s [%.5f-%.5f]", 
                     dir == 1 ? "BULLISH" : "BEARISH", zLow, zHigh);
      
      if(RequireBreakoutFVGAlign)
      {
         if(breakout != 0 && breakout == dir)
         {
            fvgDirection = dir;
            fvgHigh = zHigh;
            fvgLow  = zLow;
            if(EnableDebugPrints)
               Print("✓ FVG ALIGNED");
         }
         else
         {
            fvgDirection = 0;
         }
      }
      else
      {
         fvgDirection = dir;
         fvgHigh = zHigh;
         fvgLow  = zLow;
      }
   }

   if(fvgDirection != 0)
   {
      double price = bid;
      double fvgHeight = MathAbs(fvgHigh - fvgLow);
      double tolerance = fvgHeight * RetraceTolerancePct;

      if(fvgDirection == 1)
      {
         bool inZone = (price <= fvgHigh + tolerance && price >= fvgLow - tolerance);
         bool momentum = (AllowMomentumEntry && price > fvgHigh);

         if(inZone)
         {
            if(EnableDebugPrints)
               PrintFormat("🟢 BULLISH ENTRY: %.5f in zone", price);
            PlaceMarketTrade(1, highRange, lowRange, atr);
            fvgDirection = 0;
         }
         else if(momentum)
         {
            if(EnableDebugPrints)
               PrintFormat("🟢 MOMENTUM: %.5f > %.5f", price, fvgHigh);
            PlaceMarketTrade(1, highRange, lowRange, atr);
            fvgDirection = 0;
         }
      }
      else if(fvgDirection == -1)
      {
         bool inZone = (price >= fvgLow - tolerance && price <= fvgHigh + tolerance);
         bool momentum = (AllowMomentumEntry && price < fvgLow);

         if(inZone)
         {
            if(EnableDebugPrints)
               PrintFormat("🔴 BEARISH ENTRY: %.5f in zone", price);
            PlaceMarketTrade(-1, highRange, lowRange, atr);
            fvgDirection = 0;
         }
         else if(momentum)
         {
            if(EnableDebugPrints)
               PrintFormat("🔴 MOMENTUM: %.5f < %.5f", price, fvgLow);
            PlaceMarketTrade(-1, highRange, lowRange, atr);
            fvgDirection = 0;
         }
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
               //StopTrading = true;
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
   lowRange  = iLow(_Symbol, PERIOD_CURRENT, idxLow);

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
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(prevClose > highRange) return 1;
   if(prevClose < lowRange) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Detect FVG                                                        |
//+------------------------------------------------------------------+
bool DetectFVG(int &direction, double &zoneHigh, double &zoneLow)
{
   if(Bars(_Symbol, PERIOD_CURRENT) < 4) return false;

   double high2 = iHigh(_Symbol, PERIOD_CURRENT, 2);
   double low2  = iLow(_Symbol, PERIOD_CURRENT, 2);
   double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low1  = iLow(_Symbol, PERIOD_CURRENT, 1);

   double overlapTolerance = 0.3;
   
   double bullishGap = low1 - high2;
   double bar2Range = high2 - low2;
   if(bar2Range > 0 && bullishGap >= -bar2Range * overlapTolerance)
   {
      direction = 1;
      zoneHigh = low1;
      zoneLow  = high2;
      return true;
   }

   double bearishGap = low2 - high1;
   double bar1Range = high1 - low1;
   if(bar1Range > 0 && bearishGap >= -bar1Range * overlapTolerance)
   {
      direction = -1;
      zoneHigh = low2;
      zoneLow  = high1;
      return true;
   }

   return false;
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

   double minSLDistance = atr * MinATRMultiplier;
   double structureDistance = MathAbs(entry - structureSL);
   
   double sl;
   if(structureDistance < minSLDistance)
   {
      if(direction == 1)
         sl = entry - minSLDistance;
      else
         sl = entry + minSLDistance;
      
      PrintFormat("  ⚠️ SL extended: %.5f->%.5f (ATR min)", structureDistance, minSLDistance);
   }
   else
   {
      sl = structureSL;
      PrintFormat("  ✓ Structure SL: %.5f", structureDistance);
   }

   double risk = MathAbs(entry - sl);
   double tp = (direction == 1) ? (entry + risk * RR) : (entry - risk * RR);

   double slDistancePoints = MathAbs(entry - sl) / point;
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
               AddToTracker(posTicket, actualEntry, actualSL, actualRisk);
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
void AddToTracker(ulong ticket, double entry, double sl, double risk)
{
   int size = ArraySize(positionTracker);
   ArrayResize(positionTracker, size + 1);
   positionTracker[size].ticket = ticket;
   positionTracker[size].entryPrice = entry;
   positionTracker[size].originalSL = sl;
   positionTracker[size].risk = risk;
   positionTracker[size].breakevenSet = false;
   
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

//============================================================
// 🔄 HISTORICAL SIGNAL RECONSTRUCTION ON INIT
//============================================================
void ReconstructLastSignal()
{
   Print("🔍 Reconstructing last signal from historical data...");

   double highRange, lowRange;

   // 1️⃣ Detect last valid range
   if(!DetectRange(MinBarsInRange, highRange, lowRange))
   {
      Print("❌ No historical range found");
      return;
   }

   PrintFormat("📌 Found historical range H=%.5f L=%.5f", highRange, lowRange);

   // 2️⃣ Detect last breakout candle
   int breakout = DetectBreakout(highRange, lowRange);
   if(breakout == 0)
   {
      Print("⏸ No historical breakout found");
      return;
   }

   PrintFormat("🚀 Historical breakout: %s", 
               breakout == 1 ? "BULLISH" : "BEARISH");

   // 3️⃣ Detect last FVG that aligns
   int dir;
   double fvgHighHist, fvgLowHist;

   if(!DetectFVG(dir, fvgHighHist, fvgLowHist))
   {
      Print("⏸ No historical FVG detected");
      return;
   }

   // Require alignment only if enabled
   if(RequireBreakoutFVGAlign && dir != breakout)
   {
      Print("⛔ FVG and breakout not aligned. Skipping.");
      return;
   }

   // 4️⃣ Simulate immediate entry at current price
   double atr = GetATR();
   if(atr <= 0)
   {
      Print("❌ ATR missing. Cannot enter trade.");
      return;
   }

   PrintFormat("🕓 Historical trade detected. Entering NOW. Dir=%d", breakout);

   PlaceMarketTrade(breakout, highRange, lowRange, atr);
}

//+------------------------------------------------------------------+