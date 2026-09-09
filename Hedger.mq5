//+------------------------------------------------------------------+
//|                                                       Hedger.mq5 |
//|                             Copyright 2026, Jamshed Alam Qaderi. |
//|                                    https://jamshedalamqaderi.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Jamshed Alam Qaderi."
#property link      "https://jamshedalamqaderi.com"
#property version   "1.20"

//--- Include Trade Library
#include <Trade\Trade.mqh>
CTrade trade;

//--- Object and Macro Definitions
#define BUTTON_NAME    "EA_Control_Button"
#define BUTTON_PAUSE   "EA_Pause_Button"
#define GAP_MULTIPLIER 3 // Macro for the inside hedge gap multiplier

struct PositionInfo
{
   ulong              ticket;
   double             profit;
   double             volume;
   double             distance;
   double             absoluteDistance;
   ENUM_POSITION_TYPE type;
};

//--- Input Parameters: Core Trading
input double             InpInitialLot        = 0.1;               // Initial Lot Size
input double             InpMaxLotPerSide     = 0.0;               // Max combined lot per side (0 for no limit)
input int                InpHedgeDistance     = 300;               // Hedge Distance (Points)
input int                InpProfitTarget      = 400;               // Profit Target (Points)
input double             InpTrimProfitPercent = 25.0;              // Profit Keep Percent (Remaining covers loss)

//--- Input Parameters: Time Filters
input string             InpStartTime         = "00:00";           // Trading Start Time (HH:MM)
input string             InpEndTime           = "23:59";           // Trading End Time (HH:MM)

//--- Input Parameters: Strategy Settings
input ENUM_POSITION_TYPE InpStartDirection    = POSITION_TYPE_BUY; // Initial Trade Direction
input ENUM_TIMEFRAMES    InpTimeframe         = PERIOD_CURRENT;    // Timeframe (For Inside Hedge Calculation)

//--- Input Parameters: Target Monetary Settings
input double             InpInitialBalance    = 10000.0;           // Initial Balance Setup
input double             InpProfitTargetAmount= 100.0;             // Profit Target Amount ($)

//--- Input Parameters: Logging & Notifications
input bool               InpEnableFileLog     = true;              // Save detailed daily logs to file for AI analysis
input bool               InpEnablePushNotify  = true;              // Send Mobile Push Notifications for key events

//--- Global Variables
bool         is_waiting_for_signal = false;
bool         is_trimming_stuck     = false;
bool         is_manual_pause       = false;
double       ActiveCycleBalance    = 0.0; // Tracks balance to fix the initial amount bug

PositionInfo profitableArray[];
PositionInfo losingArray[];

//+------------------------------------------------------------------+
//| Structured Logger for AI Analysis & Debugging                    |
//+------------------------------------------------------------------+
void LogEvent(string level, string component, string message)
{
   string timestamp = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);

   string logLine = StringFormat("[%s] [%s] [%s] %s | Equity: %.2f | Balance: %.2f | OpenPos: %d",
                                 timestamp, level, component, message, equity, balance, PositionsTotal());

   // 1. Output to MT5 Terminal Experts tab
   Print(logLine);

   // 2. Output to daily file in MQL5/Files/ for AI diagnostic analysis
   if(InpEnableFileLog)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      string fileName = StringFormat("Hedger_Log_%04d-%02d-%02d.log", dt.year, dt.mon, dt.day);

      int fileHandle = FileOpen(fileName, FILE_READ | FILE_WRITE | FILE_TXT | FILE_SHARE_READ | FILE_SHARE_WRITE);
      if(fileHandle != INVALID_HANDLE)
      {
         FileSeek(fileHandle, 0, SEEK_END);
         FileWriteString(fileHandle, logLine + "\r\n");
         FileClose(fileHandle);
      }
   }
}

//+------------------------------------------------------------------+
//| Centralized Alert & Mobile Push Notification Manager             |
//+------------------------------------------------------------------+
void SendEAAlert(string eventTitle, string message, bool pushNotify = true)
{
   string fullText = StringFormat("[%s - %s] %s: %s", _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), eventTitle, message);

   LogEvent("NOTIFICATION", eventTitle, message);
   // Alert(fullText); // Uncomment if you also want annoying desktop popups

   if(InpEnablePushNotify && pushNotify)
   {
      if(!SendNotification(fullText))
      {
         LogEvent("WARNING", "Notification", "Failed to send push notification. Check MetaQuotes ID settings.");
      }
   }
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   MathSrand(GetTickCount());

   if(MQLInfoInteger(MQL_TESTER))
   {
      is_waiting_for_signal = true;
      LogEvent("INFO", "OnInit", "Strategy Tester detected: Automatic signal scanning activated.");
   }

   // Fix for the incorrect initial balance input bug
   ActiveCycleBalance = InpInitialBalance;
   if(AccountInfoDouble(ACCOUNT_EQUITY) > ActiveCycleBalance + InpProfitTargetAmount)
   {
      ActiveCycleBalance = AccountInfoDouble(ACCOUNT_EQUITY);
      LogEvent("INFO", "OnInit", StringFormat("Initial balance adjusted to equity: %.2f", ActiveCycleBalance));
   }

   // 1. Create Control Button
   if(!ObjectCreate(0, BUTTON_NAME, OBJ_BUTTON, 0, 0, 0))
   {
      LogEvent("ERROR", "OnInit", "Failed to create Start/Stop button.");
      return(INIT_FAILED);
   }
   ObjectSetInteger(0, BUTTON_NAME, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, BUTTON_NAME, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, BUTTON_NAME, OBJPROP_XSIZE, 100);
   ObjectSetInteger(0, BUTTON_NAME, OBJPROP_YSIZE, 30);
   ObjectSetInteger(0, BUTTON_NAME, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, BUTTON_NAME, OBJPROP_SELECTABLE, false);

   // 2. Create Pause/Resume Button
   if(!ObjectCreate(0, BUTTON_PAUSE, OBJ_BUTTON, 0, 0, 0))
   {
      LogEvent("ERROR", "OnInit", "Failed to create Pause button.");
      return(INIT_FAILED);
   }
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_YDISTANCE, 60);
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_XSIZE, 100);
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_YSIZE, 30);
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_SELECTABLE, false);

   UpdateButtonState();
   LogEvent("INFO", "OnInit", "Hedger EA Initialized successfully (Manual Mode Only).");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectDelete(0, BUTTON_NAME);
   ObjectDelete(0, BUTTON_PAUSE);
   LogEvent("INFO", "OnDeinit", StringFormat("EA Deinitialized. Reason code: %d", reason));
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Manual pause override - Halts all operations
   if(is_manual_pause) return;

   if(PositionsTotal() >= 2)
   {
      SyncPositionArrays();
   }

   // 0. Monitor global monetary milestones before executing calculations
   CheckSinglePositionTP();
   CheckProfitTarget();
   UpdateButtonState();

   double totalBought = GetTotalVolume(POSITION_TYPE_BUY, false);
   double totalSold   = GetTotalVolume(POSITION_TYPE_SELL, false);
   bool isBalanced    = (NormalizeDouble(totalBought - totalSold, 2) == 0.0);
   bool hasPositions  = (totalBought > 0 || totalSold > 0);

   // Evaluate Daily Trading Time Limits
   if(!IsWithinTradingTime())
   {
      if(hasPositions && !isBalanced)
      {
         // Out of hours but unbalanced -> Only manage the hedge to seek balance
         RebalanceHedgeV2();
         SqueezeHedgeOrders();
      }
      return;
   }

   // 1. Initiate the first trade
   InitialTrade();
   // 2. Hedge the trade by rebalancing
   RebalanceHedgeV2();
   // 3. Squeezing the Hedge Orders
   SqueezeHedgeOrders();
   // 4. Trimming the positions
   ManageTrimming();
   // 5. Place inside hedge trade
   ManageInsideHedge();
}

//+------------------------------------------------------------------+
//| Check single position for Take Profit                            |
//+------------------------------------------------------------------+
void CheckSinglePositionTP()
{
   if(PositionsTotal() != 1) return;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) == _Symbol)
      {
         ulong ticket        = PositionGetTicket(i);
         long type           = PositionGetInteger(POSITION_TYPE);
         double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         double profitMoney  = PositionGetDouble(POSITION_PROFIT);
         double pointsProfit = (type == POSITION_TYPE_BUY) ? (currentPrice - openPrice) : (openPrice - currentPrice);

         pointsProfit /= _Point;

         if(pointsProfit >= InpProfitTarget)
         {
            if(trade.PositionClose(ticket))
            {
               DeleteRebalanceOrders();
               is_waiting_for_signal = false;
               UpdateButtonState();

               string msg = StringFormat("Single Position TP Hit! Ticket #%I64u Closed. Points: %.0f | Profit: $%.2f", ticket, pointsProfit, profitMoney);
               SendEAAlert("Single Position TP", msg, true);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Time filter assessment for trading hours                         |
//+------------------------------------------------------------------+
bool IsWithinTradingTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int currentMins = dt.hour * 60 + dt.min;

   ushort sep = StringGetCharacter(":", 0);
   string startArr[], endArr[];

   StringSplit(InpStartTime, sep, startArr);
   int startMins = (int)StringToInteger(startArr[0]) * 60 + (int)StringToInteger(startArr[1]);

   StringSplit(InpEndTime, sep, endArr);
   int endMins = (int)StringToInteger(endArr[0]) * 60 + (int)StringToInteger(endArr[1]);

   if(startMins < endMins)
   {
      return (currentMins >= startMins && currentMins < endMins);
   }
   else if(startMins > endMins)
   {
      return (currentMins >= startMins || currentMins < endMins);
   }

   return true;
}

//+------------------------------------------------------------------+
//| Monitors target equity requirements to trigger cash-outs         |
//+------------------------------------------------------------------+
void CheckProfitTarget()
{
   if(!CheckActivePositions()) return;

   double currentEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double targetThreshold = ActiveCycleBalance + InpProfitTargetAmount;

   if(currentEquity >= targetThreshold)
   {
      string msg = StringFormat("Profit Target Milestone Reached! Equity: $%.2f >= Target: $%.2f. Closing all positions & pausing bot.",
                                currentEquity, targetThreshold);

      SendEAAlert("Global Target Achieved", msg, true);

      CloseAll();
      is_waiting_for_signal = false;
      ActiveCycleBalance = AccountInfoDouble(ACCOUNT_EQUITY);
      UpdateButtonState();
   }
}

//+------------------------------------------------------------------+
//| Flattens all active exposure and active pending configurations   |
//+------------------------------------------------------------------+
void CloseAll()
{
   int pendingDeleted = 0;
   int positionsClosed = 0;

   // 1. Remove all active pending orders for this specific symbol
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
      {
         if(trade.OrderDelete(ticket)) pendingDeleted++;
      }
   }

   // 2. Terminate all open market exposure components safely
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         if(trade.PositionClose(ticket)) positionsClosed++;
      }
   }

   LogEvent("ACTION", "CloseAll", StringFormat("Closed %d positions and deleted %d pending orders.", positionsClosed, pendingDeleted));
}

//+------------------------------------------------------------------+
//| Code processing for handling structural position entry triggers  |
//+------------------------------------------------------------------+
void InitialTrade()
{
   if(is_waiting_for_signal && !CheckActivePositions())
   {
      if(InpMaxLotPerSide > 0 && InpInitialLot > InpMaxLotPerSide) return;

      if(InpStartDirection == POSITION_TYPE_BUY)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(trade.Buy(InpInitialLot, _Symbol, ask, 0, 0, "Initial Long"))
         {
            is_waiting_for_signal = false;
            UpdateButtonState();
            SendEAAlert("Initial Trade Opened", StringFormat("BUY %.2f @ %.5f", InpInitialLot, ask), true);
         }
      }
      else
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(trade.Sell(InpInitialLot, _Symbol, bid, 0, 0, "Initial Short"))
         {
            is_waiting_for_signal = false;
            UpdateButtonState();
            SendEAAlert("Initial Trade Opened", StringFormat("SELL %.2f @ %.5f", InpInitialLot, bid), true);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ChartEvent function to handle UI Button Click                    |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // Main Control Button
      if(sparam == BUTTON_NAME)
      {
         ObjectSetInteger(0, BUTTON_NAME, OBJPROP_STATE, false);

         if(CheckActivePositions() || is_waiting_for_signal)
         {
            is_waiting_for_signal = false;
            CloseAll();
            SendEAAlert("Bot Stopped", "User manually pressed STOP button. Closed all positions & cancelled orders.", true);
         }
         else
         {
            is_waiting_for_signal = true;
            SendEAAlert("Bot Started", "User manually pressed START button. Executing trade.", true);
         }
         UpdateButtonState();
      }

      // Pause/Resume Button
      if(sparam == BUTTON_PAUSE)
      {
         ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_STATE, false);
         is_manual_pause = !is_manual_pause;
         UpdateButtonState();

         string pauseState = is_manual_pause ? "Bot PAUSED by user." : "Bot RESUMED by user.";
         SendEAAlert("Bot Pause State Changed", pauseState, true);
      }
   }
}

//+------------------------------------------------------------------+
//| Helper function to check if positions exist for the symbol       |
//+------------------------------------------------------------------+
bool CheckActivePositions()
{
   int total_positions = PositionsTotal();
   for(int i = 0; i < total_positions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Helper function to update button text based on status            |
//+------------------------------------------------------------------+
void UpdateButtonState()
{
   bool has_position = CheckActivePositions();

   ObjectSetString(0, BUTTON_NAME, OBJPROP_TEXT, (has_position || is_waiting_for_signal) ? "Stop" : "Start");
   ObjectSetString(0, BUTTON_PAUSE, OBJPROP_TEXT, is_manual_pause ? "Resume" : "Pause");

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Manages and adjusts the structural protective hedge stop orders  |
//+------------------------------------------------------------------+
void RebalanceHedgeV2()
{
   double totalBuyLots       = GetTotalVolume(POSITION_TYPE_BUY, false);
   double totalSellLots      = GetTotalVolume(POSITION_TYPE_SELL, false);
   double totalBuyOrdersLot  = GetTotalVolume(POSITION_TYPE_BUY, true);
   double totalSellOrdersLot = GetTotalVolume(POSITION_TYPE_SELL, true);

   double newVolume = NormalizeDouble(totalBuyLots - totalSellLots, 2);

   LogEvent("DEBUG", "RebalanceHedgeV2", StringFormat("Imbalance: %.2f (Buy: %.2f | Sell: %.2f)", newVolume, totalBuyLots, totalSellLots));

   // 1. Balance Check
   if(newVolume == 0.0)
   {
      DeleteRebalanceOrders();
      return;
   }

   // 2. Direction and Base Lot Calculation
   ENUM_POSITION_TYPE requiredType   = (newVolume > 0.0) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   ENUM_ORDER_TYPE requiredOrderType = (requiredType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;

   double requiredLot = CalculateRequiredLotForRebalance(MathAbs(newVolume), requiredType);

   // 3. Max Side Cap Validation
   if(InpMaxLotPerSide > 0.0)
   {
      double currentSideExposure   = (requiredType == POSITION_TYPE_BUY) ? totalBuyOrdersLot : totalSellOrdersLot;
      double remainingEligibleLots = NormalizeDouble(InpMaxLotPerSide - currentSideExposure, 2);
      requiredLot = MathMin(remainingEligibleLots, requiredLot);
   }

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   requiredLot    = MathFloor(requiredLot / lotStep) * lotStep;

   // 4. Minimum Lot Check
   if(requiredLot < minLot)
   {
      LogEvent("WARNING", "RebalanceHedgeV2", StringFormat("Required lot %.2f below broker minimum %.2f", requiredLot, minLot));
      return;
   }

   // 5. Scan order book for existing pending orders
   ulong pendingTicket = 0;
   ENUM_ORDER_TYPE pendingType = WRONG_VALUE;
   double pendingLots = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
      {
         ENUM_ORDER_TYPE oType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(oType == ORDER_TYPE_BUY_STOP || oType == ORDER_TYPE_SELL_STOP)
         {
            pendingTicket = ticket;
            pendingType   = oType;
            pendingLots   = OrderGetDouble(ORDER_VOLUME_CURRENT);
            break;
         }
      }
   }

   // 6. Evaluate existing pending order state
   if(pendingTicket > 0)
   {
      if(pendingType == requiredOrderType && NormalizeDouble(pendingLots, 2) == NormalizeDouble(requiredLot, 2))
      {
         return;
      }
      else
      {
         trade.OrderDelete(pendingTicket);
         LogEvent("ACTION", "RebalanceHedgeV2", StringFormat("Deleted existing mismatched order #%I64u", pendingTicket));
      }
   }

   // 7. Execute rebalance order placement
   double offset = InpHedgeDistance * _Point;

   if(requiredType == POSITION_TYPE_BUY)
   {
      double buyPrice = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + offset, _Digits);
      if(trade.BuyStop(requiredLot, buyPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "Hedge Rebalance"))
      {
         LogEvent("ACTION", "RebalanceHedgeV2", StringFormat("Placed BUY_STOP Vol: %.2f @ %.5f", requiredLot, buyPrice));
      }
   }
   else
   {
      double sellPrice = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) - offset, _Digits);
      if(trade.SellStop(requiredLot, sellPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "Hedge Rebalance"))
      {
         LogEvent("ACTION", "RebalanceHedgeV2", StringFormat("Placed SELL_STOP Vol: %.2f @ %.5f", requiredLot, sellPrice));
      }
   }
}

//+------------------------------------------------------------------+
//| Helper function to remove all active rebalance pending orders    |
//+------------------------------------------------------------------+
void DeleteRebalanceOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
      {
         trade.OrderDelete(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Squeezes stop orders dynamically based on new outer boundaries   |
//+------------------------------------------------------------------+
void SqueezeHedgeOrders()
{
   int totalOrders = OrdersTotal();
   if(totalOrders == 0) return;

   double lastBuyLevel  = GetLastPositionPrice(POSITION_TYPE_BUY);
   double lastSellLevel = GetLastPositionPrice(POSITION_TYPE_SELL);

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double offset = InpHedgeDistance * _Point;

   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0 || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double open_price    = OrderGetDouble(ORDER_PRICE_OPEN);
      double target_price  = 0.0;

      if(type == ORDER_TYPE_SELL_STOP)
      {
         target_price = bid - offset;
         if(lastBuyLevel > 0) target_price = MathMin(target_price, lastBuyLevel - offset);

         target_price = NormalizeDouble(target_price, _Digits);
         if(target_price > open_price)
         {
            if(trade.OrderModify(ticket, target_price, 0, 0, ORDER_TIME_GTC, 0))
            {
               LogEvent("ACTION", "SqueezeHedge", StringFormat("Squeezed SELL_STOP #%I64u to %.5f", ticket, target_price));
            }
         }
      }
      else if(type == ORDER_TYPE_BUY_STOP)
      {
         target_price = ask + offset;
         if(lastSellLevel > 0) target_price = MathMax(target_price, lastSellLevel + offset);

         target_price = NormalizeDouble(target_price, _Digits);
         if(target_price < open_price)
         {
            if(trade.OrderModify(ticket, target_price, 0, 0, ORDER_TIME_GTC, 0))
            {
               LogEvent("ACTION", "SqueezeHedge", StringFormat("Squeezed BUY_STOP #%I64u to %.5f", ticket, target_price));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manages position trimming using single or multi-position pools   |
//+------------------------------------------------------------------+
void ManageTrimming()
{
   if(ArraySize(profitableArray) == 0 || ArraySize(losingArray) == 0) return;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   int profToUse    = 0;
   double poolMoney = 0.0;

   for(int p = 0; p < ArraySize(profitableArray); p++)
   {
      profToUse++;
      poolMoney += profitableArray[p].profit * (1.0 - (InpTrimProfitPercent / 100.0));

      double potentialLots = losingArray[0].volume * (poolMoney / losingArray[0].profit);
      potentialLots = MathFloor(potentialLots / lotStep) * lotStep;

      if(potentialLots >= minLot || poolMoney >= losingArray[0].profit) break;
   }

   double finalPotentialLots = losingArray[0].volume * (poolMoney / losingArray[0].profit);
   finalPotentialLots = MathFloor(finalPotentialLots / lotStep) * lotStep;

   if(finalPotentialLots < minLot && poolMoney < losingArray[0].profit) return;

   double actualPoolMoney = 0.0;

   for(int p = 0; p < profToUse; p++)
   {
      double exactProfit = profitableArray[p].profit;
      if(trade.PositionClose(profitableArray[p].ticket))
      {
         actualPoolMoney += exactProfit * (1.0 - (InpTrimProfitPercent / 100.0));
         LogEvent("ACTION", "Trimming", StringFormat("Closed Profitable Position #%I64u (Profit: $%.2f)", profitableArray[p].ticket, exactProfit));
      }
   }

   for(int k = 0; k < ArraySize(losingArray); k++)
   {
      if(actualPoolMoney <= 0) break;

      if(actualPoolMoney >= losingArray[k].profit)
      {
         if(trade.PositionClose(losingArray[k].ticket))
         {
            actualPoolMoney -= losingArray[k].profit;
            LogEvent("ACTION", "Trimming", StringFormat("Fully Covered & Closed Losing Position #%I64u", losingArray[k].ticket));
         }
      }
      else
      {
         double closeLots = losingArray[k].volume * (actualPoolMoney / losingArray[k].profit);
         closeLots = MathFloor(closeLots / lotStep) * lotStep;

         if(closeLots < minLot) closeLots = minLot;
         if(closeLots > losingArray[k].volume) closeLots = losingArray[k].volume;

         if(trade.PositionClosePartial(losingArray[k].ticket, closeLots))
         {
            LogEvent("ACTION", "Trimming", StringFormat("Partially Trimmed Losing Position #%I64u by %.2f Lots", losingArray[k].ticket, closeLots));
         }
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| Manages inside hedge executions relative to the grid midpoint    |
//+------------------------------------------------------------------+
void ManageInsideHedge()
{
   double bottomBuy = GetLastPositionPrice(POSITION_TYPE_BUY);
   double topSell   = GetLastPositionPrice(POSITION_TYPE_SELL);

   if(bottomBuy == 0.0 || topSell == 0.0) return;

   double minDistance = InpProfitTarget * GAP_MULTIPLIER * _Point;
   double distance    = NormalizeDouble(bottomBuy - topSell, _Digits);

   if(distance < minDistance) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, InpTimeframe, 0, 2, rates) < 2) return;

   static datetime lastProcessedBar = 0;
   if(rates[0].time == lastProcessedBar) return;

   double upperTradePoint = NormalizeDouble(bottomBuy - (minDistance / 2), _Digits);
   double lowerTradePoint = NormalizeDouble(topSell + (minDistance / 2), _Digits);

   double candleOpen  = rates[1].open;
   double candleClose = rates[1].close;

   bool crossUpLower = (candleOpen < lowerTradePoint && candleClose > lowerTradePoint);
   bool crossUpUpper = (candleOpen < upperTradePoint && candleClose > upperTradePoint);

   if(crossUpLower || crossUpUpper)
   {
      if(InpMaxLotPerSide == 0 || (GetTotalVolume(POSITION_TYPE_BUY, false) + InpInitialLot <= InpMaxLotPerSide))
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(trade.Buy(InpInitialLot, _Symbol, ask, 0, 0, "Inside Hedge Buy"))
         {
            lastProcessedBar = rates[0].time;
            SendEAAlert("Inside Hedge Executed", StringFormat("BUY %.2f @ %.5f", InpInitialLot, ask), true);
         }
      }
      return;
   }

   bool crossDownLower = (candleOpen > lowerTradePoint && candleClose < lowerTradePoint);
   bool crossDownUpper = (candleOpen > upperTradePoint && candleClose < upperTradePoint);

   if(crossDownLower || crossDownUpper)
   {
      if(InpMaxLotPerSide == 0 || (GetTotalVolume(POSITION_TYPE_SELL, false) + InpInitialLot <= InpMaxLotPerSide))
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(trade.Sell(InpInitialLot, _Symbol, bid, 0, 0, "Inside Hedge Sell"))
         {
            lastProcessedBar = rates[0].time;
            SendEAAlert("Inside Hedge Executed", StringFormat("SELL %.2f @ %.5f", InpInitialLot, bid), true);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Returns total volume of open positions and pending orders        |
//+------------------------------------------------------------------+
double GetTotalVolume(ENUM_POSITION_TYPE type, bool withOrders = true)
{
   double total_volume = 0.0;

   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionGetSymbol(i) == _Symbol)
      {
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         {
            total_volume += PositionGetDouble(POSITION_VOLUME);
         }
      }
   }

   if(!withOrders) return NormalizeDouble(total_volume, 2);

   int total_orders = OrdersTotal();
   for(int i = 0; i < total_orders; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
      {
         ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

         if(type == POSITION_TYPE_BUY)
         {
            if(order_type == ORDER_TYPE_BUY_LIMIT || order_type == ORDER_TYPE_BUY_STOP)
            {
               total_volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
            }
         }
         else if(type == POSITION_TYPE_SELL)
         {
            if(order_type == ORDER_TYPE_SELL_LIMIT || order_type == ORDER_TYPE_SELL_STOP)
            {
               total_volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
            }
         }
      }
   }

   return NormalizeDouble(total_volume, 2);
}

//+------------------------------------------------------------------+
//| Returns Bottom Buy (lowest price) or Top Sell (highest price)    |
//+------------------------------------------------------------------+
double GetLastPositionPrice(ENUM_POSITION_TYPE type, bool includeOrders = false)
{
   double extreme_price = 0.0;
   bool tracking_initialized = false;

   int total_positions = PositionsTotal();
   for(int i = 0; i < total_positions; i++)
   {
      if(PositionGetSymbol(i) != _Symbol || (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      extreme_price = !tracking_initialized ? open_price : (type == POSITION_TYPE_BUY ? MathMin(extreme_price, open_price) : MathMax(extreme_price, open_price));
      tracking_initialized = true;
   }

   if(includeOrders)
   {
      int total_orders = OrdersTotal();
      for(int i = 0; i < total_orders; i++)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket <= 0 || OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;

         ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type == POSITION_TYPE_BUY  && order_type != ORDER_TYPE_BUY_LIMIT  && order_type != ORDER_TYPE_BUY_STOP) continue;
         if(type == POSITION_TYPE_SELL && order_type != ORDER_TYPE_SELL_LIMIT && order_type != ORDER_TYPE_SELL_STOP) continue;

         double open_price = OrderGetDouble(ORDER_PRICE_OPEN);
         extreme_price = !tracking_initialized ? open_price : (type == POSITION_TYPE_BUY ? MathMin(extreme_price, open_price) : MathMax(extreme_price, open_price));
         tracking_initialized = true;
      }
   }

   return extreme_price;
}

//+------------------------------------------------------------------+
//| Sync and populate arrays with profitable and losing positions    |
//+------------------------------------------------------------------+
void SyncPositionArrays()
{
   ArrayFree(profitableArray);
   ArrayFree(losingArray);

   int totalPositions = PositionsTotal();

   for(int i = 0; i < totalPositions; i++)
   {
      if(PositionGetSymbol(i) != _Symbol) continue;

      ulong ticket        = PositionGetTicket(i);
      long type           = PositionGetInteger(POSITION_TYPE);
      double openPrice    = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      double profitMoney  = PositionGetDouble(POSITION_PROFIT);
      double volume       = PositionGetDouble(POSITION_VOLUME);
      double distance     = MathAbs(currentPrice - openPrice);

      if(profitMoney > 0)
      {
         if(distance >= (InpProfitTarget * _Point))
         {
            int arraySize = ArraySize(profitableArray) + 1;
            ArrayResize(profitableArray, arraySize);
            profitableArray[arraySize - 1].ticket = ticket;
            profitableArray[arraySize - 1].volume = volume;
            profitableArray[arraySize - 1].profit = profitMoney;
            profitableArray[arraySize - 1].distance = distance;
            profitableArray[arraySize - 1].absoluteDistance = NormalizeDouble(distance * (volume * 100), _Digits);
            profitableArray[arraySize - 1].type = (ENUM_POSITION_TYPE)type;
         }
      }
      else if(profitMoney < 0)
      {
         int arraySize = ArraySize(losingArray) + 1;
         ArrayResize(losingArray, arraySize);
         losingArray[arraySize - 1].ticket = ticket;
         losingArray[arraySize - 1].volume = volume;
         losingArray[arraySize - 1].profit = MathAbs(profitMoney);
         losingArray[arraySize - 1].distance = distance;
         losingArray[arraySize - 1].absoluteDistance = NormalizeDouble(distance * (volume * 100), _Digits);
         losingArray[arraySize - 1].type = (ENUM_POSITION_TYPE)type;
      }
   }

   if(ArraySize(profitableArray) == 0 || ArraySize(losingArray) == 0) return;

   for(int m = 0; m < ArraySize(profitableArray) - 1; m++)
   {
      for(int n = m + 1; n < ArraySize(profitableArray); n++)
      {
         if(profitableArray[m].profit < profitableArray[n].profit)
         {
            PositionInfo temp = profitableArray[m];
            profitableArray[m] = profitableArray[n];
            profitableArray[n] = temp;
         }
      }
   }

   for(int m = 0; m < ArraySize(losingArray) - 1; m++)
   {
      for(int n = m + 1; n < ArraySize(losingArray); n++)
      {
         if(losingArray[m].distance < losingArray[n].distance)
         {
            PositionInfo temp = losingArray[m];
            losingArray[m] = losingArray[n];
            losingArray[n] = temp;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculates the required lot size for rebalancing                 |
//+------------------------------------------------------------------+
double CalculateRequiredLotForRebalance(double diffVolume, ENUM_POSITION_TYPE rebalanceSide)
{
   if(ArraySize(losingArray) == 0) return diffVolume;

   int posIndex = -1;
   for(int i = 0; i < ArraySize(losingArray); i++)
   {
      PositionInfo currentPos = losingArray[i];
      if(currentPos.type != rebalanceSide)
      {
         posIndex = i;
         break;
      }
   }

   if(posIndex < 0) return diffVolume;

   PositionInfo farLosingPos = losingArray[posIndex];
   double minRequiredDistanceToClose = farLosingPos.distance + (InpHedgeDistance * _Point);
   double remaingDistancePercent = 1.0 - (InpTrimProfitPercent / 100.0);
   double diffVolumeProfitDistance = (diffVolume * 100.0) * (InpProfitTarget * _Point) * remaingDistancePercent;

   if(minRequiredDistanceToClose < diffVolumeProfitDistance)
   {
      return diffVolume;
   }

   double initialLotProfitDistance = (InpInitialLot * 100.0) * (InpProfitTarget * _Point) * remaingDistancePercent;

   if(minRequiredDistanceToClose < initialLotProfitDistance)
   {
      return InpInitialLot;
   }

   return InpInitialLot;
}
//+------------------------------------------------------------------+