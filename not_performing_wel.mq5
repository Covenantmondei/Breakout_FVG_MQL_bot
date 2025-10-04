//+------------------------------------------------------------------+
//|                                         Price_Based_EA_XAUUSD_v3 |
//|                                  Copyright 2025, Covenant Monday  |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>
CTrade trade;

// ------------------------ Inputs (tune for XAUUSD) ------------------
input double   LotSize                         = 0.10;    // fallback fixed lot if not using risk percent
input bool     UseRiskPercent                  = true;    // use % risk sizing
input double   RiskPercent                     = 0.2;     // percent of equity to risk per trade (0.1 - 0.3 recommended for XAUUSD)
input int      ATRPeriod                       = 14;      // ATR period (H1 or H4 recommended)
input ENUM_TIMEFRAMES ATRTimeframe             = PERIOD_H1;// ATR timeframe
input double   ATRMultiplierSL                 = 3.0;     // SL = ATR * multiplier (used if swing SL too tight)
input double   MinATRMultiplierForSL           = 0.5;     // minimum ATR * multiplier used to ensure SL not tiny
input double   SLBufferPoints                  = 0.0;     // buffer in price units (structure SL cushion)
input double   RR                              = 2.0;     // risk-reward ratio target (2 => 1:2)
input int      MinBarsInRange                  = 8;
input double   MaxRangePct                     = 0.05;
input int      MagicNumber                     = 12345;
input bool     RequireBreakoutFVGAlign         = false;   // require breakout direction == FVG direction
input bool     AllowMomentumEntry              = true;    // allow momentum entries when retrace missed
input double   RetraceTolerancePct             = 0.20;    // tolerance inside FVG
input double   MaxSpreadPoints                 = 1500;    // skip trade if spread > this (in points)
input double   MaxATRToTrade                   = 999999;  // skip trading if ATR > this

// Controls for continuous trading & limits
input int      MaxConcurrentTradesPerSymbol    = 5;       // allow up to N simultaneous positions by this EA on symbol
input bool     StopTradingAfterWin             = false;   // if true, stop trading for rest of day after hitting 1:2 RR
input bool     MoveSLToBreakevenAt1R           = true;    // enable breakeven at 1R

// Partial close settings
input double   PartialClosePercent             = 0.5;     // 0.5 -> close 50% at 1R

// Risk & protection
input double   EquityMaxDrawdownPercent        = 0.05;    // stop trading if equity drops this % from peak
input double   DailyMaxLossPercent             = 0.02;    // stop trading for the day if daily loss > this %
input double   MinimumSlDistancePoints         = 50;      // smallest accepted SL distance in points to avoid tiny SLs

// Trailing / breakeven
input double   BreakevenTriggerATRMult         = 0.5;
input double   TrailATRMult                    = 0.5;

// ------------------------ Globals ------------------
int atrHandle = INVALID_HANDLE;
double equity = 0.0;
double EquityPeak = 0.0;
bool StopTrading = false;
double DailyStartEquity = 0.0;
int LastTradeDay = -1;

// FVG storage
double fvgHigh = 0.0;
double fvgLow  = 0.0;
int    fvgDirection = 0; // 1=bullish (buy), -1=bearish (sell)
datetime fvgDetectedTime = 0;

// track partial-closed tickets so we only partial-close once per position
ulong partialClosedTickets[256];
int partialClosedCount = 0;

// small helper to track trades today (not required but useful for logs)
int tradesToday = 0;
datetime tradesTodayDay = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("EA initialized - Price_Based_EA_XAUUSD_v3 (partial close + breakeven)");

   atrHandle = iATR(_Symbol, ATRTimeframe, ATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle. Error=", GetLastError());
      return INIT_FAILED;
   }

   equity = AccountInfoDouble(ACCOUNT_EQUITY);
   EquityPeak = equity;
   DailyStartEquity = equity;
   datetime t = TimeCurrent();
   MqlDateTime dt; TimeToStruct(t, dt);
   LastTradeDay = dt.day;
   //StopTrading = false;

   tradesToday = 0;
   tradesTodayDay = TimeCurrent();
   partialClosedCount = 0;

   PrintFormat("Symbol: %s Digits=%d Point=%.10f TickSize=%.10f TickValue=%.5f ContractSize=%.3f",
               _Symbol,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
               SymbolInfoDouble(_Symbol, SYMBOL_POINT),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE),
               SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinit                                                    |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(atrHandle);
      atrHandle = INVALID_HANDLE;
   }
   Print("EA deinitialized.");
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   // update equity & daily trackers
   equity = AccountInfoDouble(ACCOUNT_EQUITY);
   UpdateEquityPeakAndDaily();
   //if(StopTrading)
   //{
      // still manage open positions, but don't open new trades
      //ManageOpenPositions();
      //return;
   //}

   // reset tradesToday counter at new day
   //ResetTradesTodayIfNewDay();

   // allow multiple concurrent positions (limit by MaxConcurrentTradesPerSymbol)
   int openCount = CountOpenPositionsForMagic(_Symbol, MagicNumber);

   // spread check
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(point <= 0) return;
   double spreadPoints = (ask - bid) / point;
   if(spreadPoints > MaxSpreadPoints)
   {
      PrintFormat("Skipping - spread wide: %.1f > %.1f", spreadPoints, MaxSpreadPoints);
      ManageOpenPositions();
      return;
   }

   // ATR retrieval (latest closed bar)
   double atr = GetATR();
   if(atr <= 0)
   {
      Print("ATR unavailable, skipping.");
      ManageOpenPositions();
      return;
   }
   if(atr > MaxATRToTrade)
   {
      PrintFormat("Skipping - ATR outside bounds: %.5f > %.5f", atr, MaxATRToTrade);
      ManageOpenPositions();
      return;
   }

   // Range detection (current timeframe)
   double highRange, lowRange;
   if(!DetectRange(MinBarsInRange, highRange, lowRange))
   {
      ManageOpenPositions();
      return;
   }

   int breakout = DetectBreakout(highRange, lowRange);

   // detect FVG on current timeframe - more lenient
   int dir; double zHigh, zLow;
   if(DetectFVG(dir, zHigh, zLow))
   {
      if(RequireBreakoutFVGAlign)
      {
         if(breakout != 0 && breakout == dir)
         {
            fvgDirection = dir;
            fvgHigh = zHigh;
            fvgLow  = zLow;
            fvgDetectedTime = TimeCurrent();
            PrintFormat("FVG stored aligned with breakout: dir=%d zone=%.5f-%.5f", fvgDirection, fvgLow, fvgHigh);
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
         fvgDetectedTime = TimeCurrent();
         PrintFormat("FVG stored (no alignment required): dir=%d zone=%.5f-%.5f", fvgDirection, fvgLow, fvgHigh);
      }
   }

   // attempt entries if we have an FVG (or allow momentum) and concurrency limit not reached
   if(fvgDirection != 0 && openCount < MaxConcurrentTradesPerSymbol)
   {
      double price = bid; // use bid for entries
      double fvgHeight = MathAbs(fvgHigh - fvgLow);
      double tolerance = fvgHeight * RetraceTolerancePct;

      if(fvgDirection == 1)
      {
         if(price <= fvgHigh + tolerance && price >= fvgLow - tolerance)
         {
            if(PlaceMarketTrade(1, highRange, lowRange, atr)) { tradesToday++; }
         }
         else if(AllowMomentumEntry && price > fvgHigh)
         {
            if(PlaceMarketTrade(1, highRange, lowRange, atr)) { tradesToday++; }
         }
      }
      else if(fvgDirection == -1)
      {
         if(price >= fvgLow - tolerance && price <= fvgHigh + tolerance)
         {
            if(PlaceMarketTrade(-1, highRange, lowRange, atr)) { tradesToday++; }
         }
         else if(AllowMomentumEntry && price < fvgLow)
         {
            if(PlaceMarketTrade(-1, highRange, lowRange, atr)) { tradesToday++; }
         }
      }
   }

   // always manage open positions each tick (including partial close / breakeven / 2R)
   ManageOpenPositions();
}

//+------------------------------------------------------------------+
//| Reset tradesToday when day changes                               |
//+------------------------------------------------------------------+
void ResetTradesTodayIfNewDay()
{
   datetime now = TimeCurrent();
   MqlDateTime dtNow; TimeToStruct(now, dtNow);
   MqlDateTime dtPast; TimeToStruct(tradesTodayDay, dtPast);
   if(dtNow.day != dtPast.day)
   {
      tradesToday = 0;
      tradesTodayDay = now;
      // reset partial-closed list at new day (positions from prior day unlikely, but safe)
      partialClosedCount = 0;
   }
}

//+------------------------------------------------------------------+
//| Get ATR (latest closed bar)                                      |
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
      PrintFormat("New day: DailyStartEquity=%.2f", DailyStartEquity);
   }

   //if(equity > EquityPeak) EquityPeak = equity;

   //if(EquityPeak > 0 && equity < EquityPeak * (1.0 - EquityMaxDrawdownPercent))
   //{
      //StopTrading = true;
      //PrintFormat("StopTrading: equity below allowed drawdown. Peak=%.2f Equity=%.2f", EquityPeak, equity);
      //return;
   //}

   //if(DailyStartEquity > 0 && equity < DailyStartEquity * (1.0 - DailyMaxLossPercent))
   //{
      //StopTrading = true;
      //PrintFormat("StopTrading for day: daily loss exceeded. DailyStart=%.2f Equity=%.2f", DailyStartEquity, equity);
      //return;
   //}
}

//+------------------------------------------------------------------+
//| Manage open positions: partial-close @1R -> move SL to BE, close at 2R, ATR trailing |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;

      string posSymbol = PositionGetString(POSITION_SYMBOL);
      long posMagic = PositionGetInteger(POSITION_MAGIC);
      if(posSymbol != _Symbol || (int)posMagic != MagicNumber) continue;

      int type = (int)PositionGetInteger(POSITION_TYPE); // 0=BUY,1=SELL
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double positionSL = PositionGetDouble(POSITION_SL);
      double positionTP = PositionGetDouble(POSITION_TP);
      double volume = PositionGetDouble(POSITION_VOLUME);
      ulong ticketID = ticket;

      // compute current profit in price units
      double profitPriceDiff = (type==POSITION_TYPE_BUY) ? (currentPrice - openPrice) : (openPrice - currentPrice);

      // compute risk (in price units) from openPrice to positionSL
      double risk = MathAbs(openPrice - positionSL);
      if(risk <= 0) continue; // safety

      // --- Partial close at 1R: only once per position ---
      if(MoveSLToBreakevenAt1R && profitPriceDiff >= risk && !IsPartialClosed(ticketID))
      {
         // compute volume to close (respect symbol volume step)
         double closeVolume = volume * PartialClosePercent;
         double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
         if(step > 0) closeVolume = MathFloor(closeVolume / step) * step;
         if(closeVolume < SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)) closeVolume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

         // close partial
         if(closeVolume > 0 && closeVolume < volume)
         {
            bool closedPartial = trade.PositionClosePartial(ticketID, closeVolume);
            if(closedPartial)
            {
               AddPartialClosed(ticketID);
               PrintFormat("Partial closed %.2f lots for ticket=%I64u at price=%.5f", closeVolume, ticketID, currentPrice);
               // move SL to breakeven (entry price)
               if(trade.PositionModify(ticketID, openPrice, positionTP))
                  PrintFormat("Moved SL to breakeven for ticket=%I64u (entry=%.5f)", ticketID, openPrice);
               else
                  PrintFormat("Failed to move SL to breakeven for ticket=%I64u Err=%d", ticketID, GetLastError());
            }
            else
            {
               PrintFormat("Partial close failed for ticket=%I64u Err=%d", ticketID, GetLastError());
            }
         }
      }

      // --- 2R close: if profit >= 2R, close and optionally stop trading for day ---
      if(profitPriceDiff >= risk * RR)
      {
         bool closed = trade.PositionClose(ticketID);
         if(closed)
         {
            PrintFormat("Closed ticket=%I64u at %.5f achieving %.2fR profit.", ticketID, currentPrice, RR);
            if(StopTradingAfterWin)
            {
               //StopTrading = true;
               Print("StopTrading enabled after win - trading paused for the rest of the day.");
            }
         }
         else
         {
            PrintFormat("Attempt to close ticket=%I64u at 2R failed Err=%d", ticketID, GetLastError());
         }
         continue; // proceed to next pos
      }

      // --- If price hits SL (broker closes), stop trading for day (preserve behavior) ---
      //if((type == POSITION_TYPE_BUY && currentPrice <= positionSL) ||
         //(type == POSITION_TYPE_SELL && currentPrice >= positionSL))
      //{
         //PrintFormat("Ticket=%I64u hit SL at %.5f. Stopping trading for the day.", ticketID, currentPrice);
         //StopTrading = true;
         //continue;
      //}

      // --- ATR trailing (optional) ---
      double atr = GetATR();
      if(atr <= 0) continue;
      double desiredSL = (type == POSITION_TYPE_BUY) ? (currentPrice - atr * TrailATRMult) : (currentPrice + atr * TrailATRMult);
      // move SL only towards profit
      if((type == POSITION_TYPE_BUY && desiredSL > positionSL + SymbolInfoDouble(_Symbol, SYMBOL_POINT)) ||
         (type == POSITION_TYPE_SELL && desiredSL < positionSL - SymbolInfoDouble(_Symbol, SYMBOL_POINT)))
      {
         if(trade.PositionModify(ticketID, desiredSL, positionTP))
            PrintFormat("Trailed SL ticket=%I64u to %.5f (atr=%.5f)", ticketID, desiredSL, atr);
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: partial-closed ticket tracking                           |
//+------------------------------------------------------------------+
void AddPartialClosed(ulong ticket)
{
   if(partialClosedCount < ArraySize(partialClosedTickets))
   {
      partialClosedTickets[partialClosedCount++] = ticket;
   }
}

bool IsPartialClosed(ulong ticket)
{
   for(int i=0; i<partialClosedCount; i++)
      if(partialClosedTickets[i] == ticket) return true;
   return false;
}

//+------------------------------------------------------------------+
//| Detect Range (returns true when range width <= MaxRangePct)       |
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
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect Breakout (uses previous closed candle close)               |
//+------------------------------------------------------------------+
int DetectBreakout(double highRange, double lowRange)
{
   double prevClose = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(prevClose > highRange) return 1;
   if(prevClose < lowRange) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Detect Fair Value Gap (FVG)                                      |
//+------------------------------------------------------------------+
bool DetectFVG(int &direction, double &zoneHigh, double &zoneLow)
{
   if(Bars(_Symbol, PERIOD_CURRENT) < 4) return false;

   double high2 = iHigh(_Symbol, PERIOD_CURRENT, 2);
   double low2  = iLow(_Symbol, PERIOD_CURRENT, 2);
   double high1 = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low1  = iLow(_Symbol, PERIOD_CURRENT, 1);

   if(low1 >= high2)
   {
      direction = 1;
      zoneHigh = low1;
      zoneLow  = high2;
      return true;
   }
   if(high1 <= low2)
   {
      direction = -1;
      zoneHigh = low2;
      zoneLow  = high1;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Place Market Trade (Buy=1, Sell=-1)                              |
//| returns true if order successfully opened                         |
//+------------------------------------------------------------------+
bool PlaceMarketTrade(int direction, double highRange, double lowRange, double atr)
{
   //if(StopTrading) return false;

   // check concurrent positions
   int openCount = CountOpenPositionsForMagic(_Symbol, MagicNumber);
   if(openCount >= MaxConcurrentTradesPerSymbol)
   {
      PrintFormat("Reached MaxConcurrentTradesPerSymbol (%d). Skipping entry.", MaxConcurrentTradesPerSymbol);
      return false;
   }

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = (direction == 1) ? ask : bid;

   // Structure-based SL: below lowRange for buys, above highRange for sells
   double sl = 0.0;
   double tp = 0.0;

   if(direction == 1) // buy
   {
      sl = lowRange - SLBufferPoints;
      // ensure minimum SL distance based on ATR
      double minSLprice = entry - atr * MinATRMultiplierForSL;
      if(sl > minSLprice) sl = minSLprice;
      tp = entry + ( (entry - sl) * RR );
   }
   else // sell
   {
      sl = highRange + SLBufferPoints;
      double minSLprice = entry + atr * MinATRMultiplierForSL;
      if(sl < minSLprice) sl = minSLprice;
      tp = entry - ( (sl - entry) * RR );
   }

   // ensure SL distance reasonable in points
   double slDistancePoints = MathAbs(entry - sl) / point;
   if(slDistancePoints < MinimumSlDistancePoints)
   {
      // fallback enforce min SL distance
      if(direction == 1) sl = entry - MinimumSlDistancePoints * point;
      else sl = entry + MinimumSlDistancePoints * point;
      slDistancePoints = MathAbs(entry - sl) / point;
      if(slDistancePoints < MinimumSlDistancePoints)
      {
         PrintFormat("SL too close even after fallback (%.1f points). Aborting.", slDistancePoints);
         return false;
      }
   }

   // calculate lots
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

   if(sl <= 0 || tp <= 0)
   {
      Print("Invalid SL/TP computed. Aborting trade.");
      return false;
   }

   trade.SetExpertMagicNumber(MagicNumber);
   bool result = false;
   string comment = (direction == 1) ? "Buy FVG/Structure" : "Sell FVG/Structure";
   if(direction == 1)
      result = trade.Buy(lots, _Symbol, 0.0, sl, tp, comment);
   else
      result = trade.Sell(lots, _Symbol, 0.0, sl, tp, comment);

   if(!result)
   {
      int err = GetLastError();
      PrintFormat("❌ OrderSend failed. Error: %d  Msg: %s", err, trade.ResultRetcodeDescription());
      return false;
   }
   else
   {
      PrintFormat("✅ Trade opened: %s | Lots=%.2f | Entry=%.5f SL=%.5f TP=%.5f",
                  (direction==1 ? "BUY" : "SELL"), lots, entry, sl, tp);
      return true;
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size by risk percent (fallback to LotSize)         |
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
   {
      Print("Warning: couldn't compute valuePerLot. Using fallback LotSize.");
      lots = LotSize;
   }

   return lots;
}

//+------------------------------------------------------------------+
//| Count open positions for this symbol & magic                     |
//+------------------------------------------------------------------+
int CountOpenPositionsForMagic(string symbol, int magic)
{
   int cnt = 0;
   for(int i=0; i<PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t))
      {
         string posSymbol = PositionGetString(POSITION_SYMBOL);
         int posMagic = (int)PositionGetInteger(POSITION_MAGIC);
         if(posSymbol == symbol && posMagic == magic) cnt++;
      }
   }
   return cnt;
}

//+------------------------------------------------------------------+
//| Check existing positions                                          |
//+------------------------------------------------------------------+
bool PositionExistsForSymbolAndMagic(string symbol, int magic)
{
   return (CountOpenPositionsForMagic(symbol, magic) > 0);
}
//+------------------------------------------------------------------+
