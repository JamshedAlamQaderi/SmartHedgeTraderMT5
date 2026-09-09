//+------------------------------------------------------------------+
//|                                                       Hedger.mq5 |
//|                             Copyright 2026, Jamshed Alam Qaderi. |
//|                                    https://jamshedalamqaderi.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Jamshed Alam Qaderi."
#property link      "https://jamshedalamqaderi.com"
#property version   "1.00"

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
input bool               InpUseEMA            = true;              // Use EMA Signal for Initial Trade
input ENUM_POSITION_TYPE InpStartDirection    = POSITION_TYPE_BUY; // Trade Direction (If EMA is Disabled)
input int                InpEMAFast           = 9;                 // Fast EMA Period
input int                InpEMASlow           = 21;                // Slow EMA Period
input int                InpEMATrient         = 200;               // Trend EMA Period
input ENUM_TIMEFRAMES    InpEMATimeframe      = PERIOD_CURRENT;    // EMA Timeframe

//--- Input Parameters: Target Monetary Settings
input double             InpInitialBalance    = 10000.0;           // Initial Balance Setup
input double             InpProfitTargetAmount= 100.0;             // Profit Target Amount ($)

//--- Global Variables
int          handle_ema_fast;
int          handle_ema_slow;
int          handle_ema_trend;

bool         is_waiting_for_signal = false;
bool         is_trimming_stuck     = false;
bool         is_manual_pause       = false;
double       ActiveCycleBalance    = 0.0; // Tracks balance to fix the initial amount bug

PositionInfo profitableArray[];
PositionInfo losingArray[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   MathSrand(GetTickCount());

   handle_ema_fast  = iMA(_Symbol, InpEMATimeframe, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   handle_ema_slow  = iMA(_Symbol, InpEMATimeframe, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);
   handle_ema_trend = iMA(_Symbol, InpEMATimeframe, InpEMATrient, 0, MODE_EMA, PRICE_CLOSE);

   if(handle_ema_fast == INVALID_HANDLE || handle_ema_slow == INVALID_HANDLE || handle_ema_trend == INVALID_HANDLE)
   {
      Print("Failed to create handles for the indicators.");
      return(INIT_FAILED);
   }

   if(MQLInfoInteger(MQL_TESTER))
   {
      is_waiting_for_signal = true;
      Print("Strategy Tester detected: Automatic signal scanning activated.");
   }

   // Fix for the incorrect initial balance input bug
   ActiveCycleBalance = InpInitialBalance;
   if(AccountInfoDouble(ACCOUNT_EQUITY) > ActiveCycleBalance + InpProfitTargetAmount)
   {
      ActiveCycleBalance = AccountInfoDouble(ACCOUNT_EQUITY);
      Print("Notice: Initial balance input was lower than equity. Auto-adjusted base balance to: ", ActiveCycleBalance);
   }

   // 1. Create Control Button
   if(!ObjectCreate(0, BUTTON_NAME, OBJ_BUTTON, 0, 0, 0))
   {
      Print("Failed to create the Start/Stop button.");
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
      Print("Failed to create the Pause button.");
      return(INIT_FAILED);
   }
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_YDISTANCE, 60); // Placed slightly below the first button
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_XSIZE, 100);
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_YSIZE, 30);
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_SELECTABLE, false);

   UpdateButtonState();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handle_ema_fast);
   IndicatorRelease(handle_ema_slow);
   IndicatorRelease(handle_ema_trend);
   ObjectDelete(0, BUTTON_NAME);
   ObjectDelete(0, BUTTON_PAUSE);
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
      // If fully balanced or no positions exist, stay paused out of hours
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
   // 5. Place inside hedge trade (Hedge automatically happen)
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
         double pointsProfit = (type == POSITION_TYPE_BUY) ? (currentPrice - openPrice) : (openPrice - currentPrice);
         
         pointsProfit /= _Point;

         if(pointsProfit >= InpProfitTarget)
         {
            trade.PositionClose(ticket);
            DeleteRebalanceOrders(); // Clean up pending hedge stop orders
            is_waiting_for_signal = false;
            UpdateButtonState();
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
      // Crosses midnight
      return (currentMins >= startMins || currentMins < endMins);
   }

   return true; // If they are identical (e.g., 00:00 to 00:00), assume 24h trading
}

//+------------------------------------------------------------------+
//| Monitors target equity requirements to trigger cash-outs         |
//+------------------------------------------------------------------+
void CheckProfitTarget()
{
   // Guard: Only check profit targets if we actually have trades open to prevent infinite loop spam
   if(!CheckActivePositions()) return;

   double currentEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double targetThreshold = ActiveCycleBalance + InpProfitTargetAmount;

   if(currentEquity >= targetThreshold)
   {
      string targetAlert = "[HedgeEA Target Achieved] Profit Milestone Hit! Equity: " +
                           DoubleToString(currentEquity, 2) + " >= Target: " + DoubleToString(targetThreshold, 2);

      Print(targetAlert);
      Alert(targetAlert);
      SendNotification(targetAlert);

      CloseAll();
      is_waiting_for_signal = false;

      // Update baseline balance so next manual start calculates correctly
      ActiveCycleBalance = AccountInfoDouble(ACCOUNT_EQUITY);
      UpdateButtonState();
   }
}

//+------------------------------------------------------------------+
//| Flattens all active exposure and active pending configurations   |
//+------------------------------------------------------------------+
void CloseAll()
{
   // 1. Remove all active pending orders for this specific symbol
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
      {
         trade.OrderDelete(ticket);
      }
   }

   // 2. Terminate all open market exposure components safely
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
      {
         trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Code processing for handling structural position entry triggers  |
//+------------------------------------------------------------------+
void InitialTrade()
{
   if(is_waiting_for_signal && !CheckActivePositions())
   {
      // Optional safety cap for initial trade
      if(InpMaxLotPerSide > 0 && InpInitialLot > InpMaxLotPerSide) return;

      // Handle immediate trade placement if EMA is disabled
      if(!InpUseEMA)
      {
         if(InpStartDirection == POSITION_TYPE_BUY)
         {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            trade.Buy(InpInitialLot, _Symbol, ask, 0, 0, "Initial Long (No EMA)");
         }
         else
         {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            trade.Sell(InpInitialLot, _Symbol, bid, 0, 0, "Initial Short (No EMA)");
         }

         is_waiting_for_signal = false;
         UpdateButtonState();
         return;
      }

      // Handle trade placement based on EMA signal
      double fast_ema[], slow_ema[], trend_ema[];

      if(CopyBuffer(handle_ema_fast, 0, 0, 1, fast_ema) < 1 ||
         CopyBuffer(handle_ema_slow, 0, 0, 1, slow_ema) < 1 ||
         CopyBuffer(handle_ema_trend, 0, 0, 1, trend_ema) < 1)
      {
         return;
      }

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(ask > fast_ema[0] && fast_ema[0] > slow_ema[0] && slow_ema[0] > trend_ema[0])
      {
         if(trade.Buy(InpInitialLot, _Symbol, ask, 0, 0, "Initial Long"))
         {
            is_waiting_for_signal = false;
            UpdateButtonState();
         }
      }
      else if(bid < fast_ema[0] && fast_ema[0] < slow_ema[0] && slow_ema[0] < trend_ema[0])
      {
         if(trade.Sell(InpInitialLot, _Symbol, bid, 0, 0, "Initial Short"))
         {
            is_waiting_for_signal = false;
            UpdateButtonState();
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

         // If EA is running, turn it OFF and close all
         if(CheckActivePositions() || is_waiting_for_signal)
         {
            is_waiting_for_signal = false;
            CloseAll();
         }
         else
         {
            // If completely idle, turn it ON
            is_waiting_for_signal = true;
         }
         UpdateButtonState();
      }

      // Pause/Resume Button
      if(sparam == BUTTON_PAUSE)
      {
         ObjectSetInteger(0, BUTTON_PAUSE, OBJPROP_STATE, false);
         is_manual_pause = !is_manual_pause;
         UpdateButtonState();
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

   // Start/Stop Button update
   ObjectSetString(0, BUTTON_NAME, OBJPROP_TEXT, (has_position || is_waiting_for_signal) ? "Stop" : "Start");

   // Pause/Resume Button update
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

   PrintFormat("[RebalanceHedgeV2] Open positions imbalance: %.2f (Buy: %.2f | Sell: %.2f)", newVolume, totalBuyLots, totalSellLots);

   // 1. Balance Check
   if(newVolume == 0.0)
   {
      Print("[RebalanceHedgeV2] Grid is perfectly balanced. Deleting lingering rebalance orders and exiting.");
      DeleteRebalanceOrders();
      return;
   }

   // 2. Direction and Base Lot Calculation
   ENUM_POSITION_TYPE requiredType   = (newVolume > 0.0) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   ENUM_ORDER_TYPE requiredOrderType = (requiredType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   string typeStr                    = (requiredType == POSITION_TYPE_BUY) ? "BUY_STOP" : "SELL_STOP";

   double requiredLot = CalculateRequiredLotForRebalance(MathAbs(newVolume), requiredType);
   PrintFormat("[RebalanceHedgeV2] Direction: %s | Base Required Lot: %.2f", typeStr, requiredLot);

   // 3. Max Side Cap Validation (Only apply if InpMaxLotPerSide > 0)
   if(InpMaxLotPerSide > 0.0)
   {
      double currentSideExposure   = (requiredType == POSITION_TYPE_BUY) ? totalBuyOrdersLot : totalSellOrdersLot;
      double remainingEligibleLots = NormalizeDouble(InpMaxLotPerSide - currentSideExposure, 2);

      PrintFormat("[RebalanceHedgeV2] Side Exposure limit check -> Max Allowed: %.2f | Current: %.2f | Remaining Eligible: %.2f",
                  InpMaxLotPerSide, currentSideExposure, remainingEligibleLots);

      requiredLot = MathMin(remainingEligibleLots, requiredLot);
   }

   // Normalize lot size to broker volume step
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   requiredLot    = MathFloor(requiredLot / lotStep) * lotStep;

   // 4. Minimum Lot Check
   if(requiredLot < minLot)
   {
      PrintFormat("[RebalanceHedgeV2] Adjusted required lot (%.2f) is below minimum broker lot (%.2f). Execution aborted.", requiredLot, minLot);
      return;
   }

   // 5. Scan order book for any existing Buy Stop or Sell Stop order on this symbol
   ulong pendingTicket = 0;
   ENUM_ORDER_TYPE pendingType = WRONG_VALUE;
   double pendingLots = 0.0;

   int totalOrders = OrdersTotal();
   for(int i = totalOrders - 1; i >= 0; i--)
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
         PrintFormat("[RebalanceHedgeV2] Correct pending order already exists (Ticket: %I64u | Vol: %.2f). No action needed.", pendingTicket, pendingLots);
         return;
      }
      else
      {
         PrintFormat("[RebalanceHedgeV2] Existing order mismatch (Type: %d vs Required: %d | Vol: %.2f vs Required: %.2f). Deleting ticket %I64u.",
                     pendingType, requiredOrderType, pendingLots, requiredLot, pendingTicket);
         trade.OrderDelete(pendingTicket);
      }
   }

   // 7. Execute clean rebalance order placement
   double offset = InpHedgeDistance * _Point;

   if(requiredType == POSITION_TYPE_BUY)
   {
      double buyPrice = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + offset, _Digits);
      PrintFormat("[RebalanceHedgeV2] Executing: BUY_STOP | Vol: %.2f | Price: %.5f", requiredLot, buyPrice);
      trade.BuyStop(requiredLot, buyPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "Hedge Rebalance");
   }
   else
   {
      double sellPrice = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) - offset, _Digits);
      PrintFormat("[RebalanceHedgeV2] Executing: SELL_STOP | Vol: %.2f | Price: %.5f", requiredLot, sellPrice);
      trade.SellStop(requiredLot, sellPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "Hedge Rebalance");
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

   // Fetch inner boundaries
   double lastBuyLevel  = GetLastPositionPrice(POSITION_TYPE_BUY);  // Bottom Buy
   double lastSellLevel = GetLastPositionPrice(POSITION_TYPE_SELL); // Top Sell

   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double offset = InpHedgeDistance * _Point;

   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);

      // Guard Clause: Instantly skip irrelevant orders to flatten code indentation
      if(ticket <= 0 || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double open_price    = OrderGetDouble(ORDER_PRICE_OPEN);
      double target_price  = 0.0;

      //--- 1. Handle protective Sell Stops
      if(type == ORDER_TYPE_SELL_STOP)
      {
         target_price = bid - offset;
         if(lastBuyLevel > 0) target_price = MathMin(target_price, lastBuyLevel - offset);

         target_price = NormalizeDouble(target_price, _Digits);
         if(target_price > open_price)
         {
            trade.OrderModify(ticket, target_price, 0, 0, ORDER_TIME_GTC, 0);
         }
      }
      //--- 2. Handle protective Buy Stops
      else if(type == ORDER_TYPE_BUY_STOP)
      {
         target_price = ask + offset;
         if(lastSellLevel > 0) target_price = MathMax(target_price, lastSellLevel + offset);

         target_price = NormalizeDouble(target_price, _Digits);
         if(target_price < open_price)
         {
            trade.OrderModify(ticket, target_price, 0, 0, ORDER_TIME_GTC, 0);
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

   //--- 2. Calculate dynamic pool aggregation requirements
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   int profToUse    = 0;
   double poolMoney = 0.0;

   // Iteratively pool profitable positions until we can afford the minimum lot change
   for(int p = 0; p < ArraySize(profitableArray); p++)
   {
      profToUse++;
      poolMoney += profitableArray[p].profit * (1.0 - (InpTrimProfitPercent / 100.0));

      double potentialLots = losingArray[0].volume * (poolMoney / losingArray[0].profit);
      potentialLots = MathFloor(potentialLots / lotStep) * lotStep;
      
      printf("Pool money: %.2f & Lossing Pos Loss: %.2f Potential lots: %.2f", poolMoney, losingArray[0].profit, potentialLots);
      
      // Stop pooling if the current single or combined credit satisfies the minimum execution volume
      if(potentialLots >= minLot || poolMoney >= losingArray[0].profit) break;
   }

   double finalPotentialLots = losingArray[0].volume * (poolMoney / losingArray[0].profit);
   finalPotentialLots = MathFloor(finalPotentialLots / lotStep) * lotStep;

   if(finalPotentialLots < minLot && poolMoney < losingArray[0].profit) return;

   //--- 3. Execute the compound trimming sequence
   double actualPoolMoney = 0.0;

   // Close only the targeted number of profitable positions required for this operation
   for(int p = 0; p < profToUse; p++)
   {
      double exactProfit = profitableArray[p].profit;
      if(trade.PositionClose(profitableArray[p].ticket))
      {
         actualPoolMoney += exactProfit * (1.0 - (InpTrimProfitPercent / 100.0));
      }
   }

   // Cascade the collected pool balance to shave or close the losing array positions
   for(int k = 0; k < ArraySize(losingArray); k++)
   {
      if(actualPoolMoney <= 0) break;

      if(actualPoolMoney >= losingArray[k].profit)
      {
         if(trade.PositionClose(losingArray[k].ticket))
         {
            actualPoolMoney -= losingArray[k].profit;
         }
      }
      else
      {
         double closeLots = losingArray[k].volume * (actualPoolMoney / losingArray[k].profit);
         closeLots = MathFloor(closeLots / lotStep) * lotStep;

         if(closeLots < minLot) closeLots = minLot;
         if(closeLots > losingArray[k].volume) closeLots = losingArray[k].volume;

         trade.PositionClosePartial(losingArray[k].ticket, closeLots);
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

   // Request bar history for the defined indicator timeframe
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, InpEMATimeframe, 0, 2, rates) < 2) return;

   // Guard Clause: Only evaluate and execute once per new candle open
   static datetime lastProcessedBar = 0;
   if(rates[0].time == lastProcessedBar) return;

   double upperTradePoint = NormalizeDouble(bottomBuy - (minDistance / 2), _Digits);
   double lowerTradePoint = NormalizeDouble(topSell + (minDistance / 2), _Digits);

   double candleOpen  = rates[1].open;
   double candleClose = rates[1].close;

   //--- 1. Inside Buy Trigger: Candle opened below and closed above EITHER point
   bool crossUpLower = (candleOpen < lowerTradePoint && candleClose > lowerTradePoint);
   bool crossUpUpper = (candleOpen < upperTradePoint && candleClose > upperTradePoint);

   if(crossUpLower || crossUpUpper)
   {
      // Verify Side Limit before placing Inside Hedge Buy
      if(InpMaxLotPerSide == 0 || (GetTotalVolume(POSITION_TYPE_BUY, false) + InpInitialLot <= InpMaxLotPerSide))
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(trade.Buy(InpInitialLot, _Symbol, ask, 0, 0, "Inside Hedge Buy"))
         {
            lastProcessedBar = rates[0].time;
         }
      }
      return;
   }

   //--- 2. Inside Sell Trigger: Candle opened above and closed below EITHER point
   bool crossDownLower = (candleOpen > lowerTradePoint && candleClose < lowerTradePoint);
   bool crossDownUpper = (candleOpen > upperTradePoint && candleClose < upperTradePoint);

   if(crossDownLower || crossDownUpper)
   {
      // Verify Side Limit before placing Inside Hedge Sell
      if(InpMaxLotPerSide == 0 || (GetTotalVolume(POSITION_TYPE_SELL, false) + InpInitialLot <= InpMaxLotPerSide))
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(trade.Sell(InpInitialLot, _Symbol, bid, 0, 0, "Inside Hedge Sell"))
         {
            lastProcessedBar = rates[0].time;
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

   //--- 1. Calculate Open Positions Volume for current symbol
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

   //--- 2. Calculate Pending Orders Volume for current symbol
   int total_orders = OrdersTotal();
   for(int i = 0; i < total_orders; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
      {
         ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

         // Accumulate matching buy-intent orders
         if(type == POSITION_TYPE_BUY)
         {
            if(order_type == ORDER_TYPE_BUY_LIMIT || order_type == ORDER_TYPE_BUY_STOP)
            {
               total_volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
            }
         }
         // Accumulate matching sell-intent orders
         else if(type == POSITION_TYPE_SELL)
         {
            if(order_type == ORDER_TYPE_SELL_LIMIT || order_type == ORDER_TYPE_SELL_STOP)
            {
               total_volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
            }
         }
      }
   }

   // Return volume rounded cleanly to broker micro-lot specifications
   return NormalizeDouble(total_volume, 2);
}

//+------------------------------------------------------------------+
//| Returns Bottom Buy (lowest price) or Top Sell (highest price)    |
//+------------------------------------------------------------------+
double GetLastPositionPrice(ENUM_POSITION_TYPE type, bool includeOrders = false)
{
   double extreme_price = 0.0;
   bool tracking_initialized = false;

   //--- 1. Scan Open Positions
   int total_positions = PositionsTotal();
   for(int i = 0; i < total_positions; i++)
   {
      if(PositionGetSymbol(i) != _Symbol || (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type)
         continue;

      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      extreme_price = !tracking_initialized ? open_price : (type == POSITION_TYPE_BUY ? MathMin(extreme_price, open_price) : MathMax(extreme_price, open_price));
      tracking_initialized = true;
   }

   //--- 2. Scan Pending Orders (Skipped if includeOrders is false)
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

   //--- 1. Gather and sort all qualifying profitable and losing positions
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

   // Guard Clause: Exit instantly if we don't have matching assets on both sides
   if(ArraySize(profitableArray) == 0 || ArraySize(losingArray) == 0) return;

   // Sort profitable array by money generated (descending)
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

   // Sort losing array by grid distance (descending)
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
//| Calculates the required lot size for rebalancing with logging    |
//+------------------------------------------------------------------+
double CalculateRequiredLotForRebalance(double diffVolume, ENUM_POSITION_TYPE rebalanceSide)
{
   PrintFormat("[CalculateRequiredLot] Started calculation. Input diffVolume: %.2f", diffVolume);

   if(ArraySize(losingArray) == 0)
   {
      Print("[CalculateRequiredLot] losingArray is empty. Returning input diffVolume: ", diffVolume);
      return diffVolume;
   }
   
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

   PrintFormat("[CalculateRequiredLot] Far Loss Distance: %.5f | Retained Profit Pct: %.2f | DiffVol Profit Dist: %.5f",
               minRequiredDistanceToClose, remaingDistancePercent, diffVolumeProfitDistance);

   if(minRequiredDistanceToClose < diffVolumeProfitDistance)
   {
      PrintFormat("[CalculateRequiredLot] minRequiredDistance (%.5f) < diffVolProfitDistance (%.5f). Returning diffVolume: %.2f",
                  minRequiredDistanceToClose, diffVolumeProfitDistance, diffVolume);
      return diffVolume;
   }

   double initialLotProfitDistance = (InpInitialLot * 100.0) * (InpProfitTarget * _Point) * remaingDistancePercent;
   PrintFormat("[CalculateRequiredLot] InitialLot Profit Dist: %.5f", initialLotProfitDistance);

   if(minRequiredDistanceToClose < initialLotProfitDistance)
   {
      PrintFormat("[CalculateRequiredLot] minRequiredDistance (%.5f) < initialLotProfitDistance (%.5f). Returning InpInitialLot: %.2f",
                  minRequiredDistanceToClose, initialLotProfitDistance, InpInitialLot);
      return InpInitialLot;
   }

   // double calculatedLot = NormalizeDouble((minRequiredDistanceToClose / (InpProfitTarget * _Point * remaingDistancePercent)) / 100.0, 2);
   // PrintFormat("[CalculateRequiredLot] Max distance threshold reached. Returning calculated scaled lot: %.2f", calculatedLot);

   return InpInitialLot;
}
//+------------------------------------------------------------------+