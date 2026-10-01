//+------------------------------------------------------------------+
//|                                                       Hedger.mq5 |
//|                             Copyright 2026, Jamshed Alam Qaderi. |
//|                                    https://jamshedalamqaderi.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Jamshed Alam Qaderi."
#property link      "https://jamshedalamqaderi.com"
#property version   "1.30"

//--- Include Trade Library
#include <Trade\Trade.mqh>
CTrade trade;

//--- Object Definitions
#define BUTTON_RESTART "EA_Restart_Button"
#define BUTTON_ENTRIES "EA_Entries_Button"

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
input double             InpInitialLot               = 0.1;               // Initial Lot Size
input double             InpMaxLotPerSide            = 0.0;               // Max combined lot per side (0 for no limit)
input double             InpMaxLotMultiplier         = 4.0;               // Max Lot Multiplier for Recovery
input int                InpHedgeDistance            = 300;               // Hedge Distance (Points)
input int                InpProfitTarget             = 400;               // Profit Target (Points)
input double             InpTrimProfitPercent        = 25.0;              // Profit Keep Percent (Remaining covers loss)
input double             InpInsideHedgeGapMultiplier = 5.0;               // Inside Hedge Gap Multiplier

//--- Input Parameters: Time Filters
input string             InpStartTime                = "00:00";           // Trading Start Time (HH:MM)
input string             InpEndTime                  = "23:59";           // Trading End Time (HH:MM)

//--- Input Parameters: Strategy Settings
input ENUM_POSITION_TYPE InpStartDirection           = POSITION_TYPE_BUY; // Initial Trade Direction
input ENUM_TIMEFRAMES    InpTimeframe                = PERIOD_CURRENT;    // Timeframe (For Inside Hedge Calculation)

//--- Input Parameters: Target Monetary Settings
input double             InpProfitTargetAmount       = 100.0;             // Cycle Profit Target Amount ($)

//--- Input Parameters: Logging & Notifications
input bool               InpEnableFileLog            = true;              // Save detailed daily logs to file
input bool               InpEnablePushNotify         = true;              // Send Mobile Push Notifications

//--- Global Variables
bool         is_waiting_for_signal = true; // Auto-start by default
bool         is_auto_restart       = true; // Automatically start next cycle after TP
bool         is_pause_entries      = false;// Hard pause on new entries
int          last_positions_total  = 0;    // Tracks position count to detect cycle resets manually
datetime     cycle_start_time      = 0;    // Tracks the exact start of the active cycle

PositionInfo profitableArray[];
PositionInfo losingArray[];

//+------------------------------------------------------------------+
//| Persistent Cycle State Management (Global Variables / Memory)    |
//+------------------------------------------------------------------+
string GetGVName()
  {
   return StringFormat("Hedger_%s_%d_CycleStart", _Symbol, AccountInfoInteger(ACCOUNT_LOGIN));
  }

void SaveCycleStart()
  {
   // Add 1 second to TimeCurrent to strictly bypass deals that were just closed this millisecond
   cycle_start_time = TimeCurrent() + 1; 
   if(!MQLInfoInteger(MQL_TESTER))
     {
      GlobalVariableSet(GetGVName(), (double)cycle_start_time);
     }
  }

void LoadCycleStart()
  {
   if(MQLInfoInteger(MQL_TESTER))
      return; // Use default 0 initialized memory in tester

   string gvName = GetGVName();
   if(GlobalVariableCheck(gvName))
     {
      cycle_start_time = (datetime)GlobalVariableGet(gvName);
     }
   else
     {
      SaveCycleStart();
     }
  }

double GetCycleProfit()
  {
   double total_profit = 0.0;

   // 1. Calculate Floating Profit from Open Positions
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetSymbol(i) == _Symbol)
        {
         total_profit += PositionGetDouble(POSITION_PROFIT) + 
                         PositionGetDouble(POSITION_SWAP) + 
                         PositionGetDouble(POSITION_COMMISSION);
        }
     }

   // 2. Calculate Realized Profit from History Deals since the cycle started
   if(HistorySelect(cycle_start_time, TimeCurrent()))
     {
      int total_deals = HistoryDealsTotal();
      for(int i = 0; i < total_deals; i++)
        {
         ulong deal_ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(deal_ticket, DEAL_SYMBOL) == _Symbol)
           {
            total_profit += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT) + 
                            HistoryDealGetDouble(deal_ticket, DEAL_SWAP) + 
                            HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
           }
        }
     }

   return total_profit;
  }

//+------------------------------------------------------------------+
//| Structured Logger & Notification Manager                         |
//+------------------------------------------------------------------+
void LogEvent(string level, string component, string message)
  {
   string timestamp = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
   string logLine = StringFormat("[%s] [%s] [%s] %s", timestamp, level, component, message);

   Print(logLine);

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

void SendEAAlert(string eventTitle, string message, bool pushNotify = true)
  {
   string fullText = StringFormat("[%s] %s: %s", _Symbol, eventTitle, message);
   LogEvent("NOTIFICATION", eventTitle, message);

   if(InpEnablePushNotify && pushNotify)
     {
      if(!SendNotification(fullText))
         LogEvent("WARNING", "Notification", "Failed to send push notification.");
     }
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   MathSrand(GetTickCount());
   LoadCycleStart();
   last_positions_total = PositionsTotal();

   // 1. Create Auto-Restart Toggle Button
   if(!ObjectCreate(0, BUTTON_RESTART, OBJ_BUTTON, 0, 0, 0)) return(INIT_FAILED);
   ObjectSetInteger(0, BUTTON_RESTART, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, BUTTON_RESTART, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, BUTTON_RESTART, OBJPROP_XSIZE, 120);
   ObjectSetInteger(0, BUTTON_RESTART, OBJPROP_YSIZE, 30);
   ObjectSetInteger(0, BUTTON_RESTART, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, BUTTON_RESTART, OBJPROP_SELECTABLE, false);

   // 2. Create Pause Entries Toggle Button
   if(!ObjectCreate(0, BUTTON_ENTRIES, OBJ_BUTTON, 0, 0, 0)) return(INIT_FAILED);
   ObjectSetInteger(0, BUTTON_ENTRIES, OBJPROP_XDISTANCE, 20);
   ObjectSetInteger(0, BUTTON_ENTRIES, OBJPROP_YDISTANCE, 60);
   ObjectSetInteger(0, BUTTON_ENTRIES, OBJPROP_XSIZE, 120);
   ObjectSetInteger(0, BUTTON_ENTRIES, OBJPROP_YSIZE, 30);
   ObjectSetInteger(0, BUTTON_ENTRIES, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, BUTTON_ENTRIES, OBJPROP_SELECTABLE, false);

   UpdateButtonState();
   LogEvent("INFO", "OnInit", "Hedger EA Initialized (Auto-Start Enabled).");

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   ObjectDelete(0, BUTTON_RESTART);
   ObjectDelete(0, BUTTON_ENTRIES);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   int current_positions = PositionsTotal();
   
   // Detect if all positions were closed (by EA or manual user intervention)
   if(last_positions_total > 0 && current_positions == 0)
     {
      SaveCycleStart(); 
      LogEvent("INFO", "Cycle", "Grid flat. Resetting Cycle Start Time.");
     }
   last_positions_total = current_positions;

   if(current_positions >= 2)
     {
      SyncPositionArrays();
     }

   CheckSinglePositionTP();
   CheckProfitTarget();
   UpdateButtonState();

   double totalBought = GetTotalVolume(POSITION_TYPE_BUY, false);
   double totalSold   = GetTotalVolume(POSITION_TYPE_SELL, false);
   bool isBalanced    = (NormalizeDouble(totalBought - totalSold, 2) == 0.0);
   bool hasPositions  = (totalBought > 0 || totalSold > 0);

   if(!IsWithinTradingTime())
     {
      if(hasPositions && !isBalanced)
        {
         RebalanceHedgeV2();
         SqueezeHedgeOrders();
        }
      return;
     }

   // Core Execution
   if(!is_pause_entries)
     {
      InitialTrade();
      ManageInsideHedge();
     }

   RebalanceHedgeV2();
   SqueezeHedgeOrders();
   ManageTrimming();
  }

//+------------------------------------------------------------------+
//| Goal Monitoring Functions                                        |
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

         if((pointsProfit / _Point) >= InpProfitTarget)
           {
            if(trade.PositionClose(ticket))
              {
               DeleteRebalanceOrders();
               SaveCycleStart();
               
               is_waiting_for_signal = is_auto_restart;
               UpdateButtonState();

               SendEAAlert("Single TP Hit", StringFormat("Ticket #%I64u Closed.", ticket), true);
              }
           }
        }
     }
  }

void CheckProfitTarget()
  {
   if(!CheckActivePositions()) return;

   double cycleProfit = GetCycleProfit();

   if(cycleProfit >= InpProfitTargetAmount)
     {
      string msg = StringFormat("Cycle Target Reached! Total Profit: $%.2f. Closing grid.", cycleProfit);
      SendEAAlert("Global Target Achieved", msg, true);

      CloseAll();
      SaveCycleStart();

      is_waiting_for_signal = is_auto_restart;
      if(!is_auto_restart)
        {
         LogEvent("INFO", "Cycle", "Auto-Restart is OFF. Bot is now waiting for manual activation.");
        }

      UpdateButtonState();
     }
  }

void CloseAll()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
         trade.OrderDelete(ticket);
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol)
         trade.PositionClose(ticket);
     }
  }

//+------------------------------------------------------------------+
//| UI & Control Functions                                           |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_OBJECT_CLICK)
     {
      if(sparam == BUTTON_RESTART)
        {
         ObjectSetInteger(0, BUTTON_RESTART, OBJPROP_STATE, false);
         is_auto_restart = !is_auto_restart;
         
         // If turned back on while flat, immediately arm the bot
         if(is_auto_restart && !CheckActivePositions())
            is_waiting_for_signal = true;
            
         UpdateButtonState();
        }

      if(sparam == BUTTON_ENTRIES)
        {
         ObjectSetInteger(0, BUTTON_ENTRIES, OBJPROP_STATE, false);
         is_pause_entries = !is_pause_entries;
         UpdateButtonState();
         
         string stateMsg = is_pause_entries ? "New Trades BLOCKED." : "New Trades ALLOWED.";
         SendEAAlert("Entry State Changed", stateMsg, false);
        }
     }
  }

void UpdateButtonState()
  {
   ObjectSetString(0, BUTTON_RESTART, OBJPROP_TEXT, is_auto_restart ? "Auto-Restart: ON" : "Stop After TP");
   ObjectSetString(0, BUTTON_ENTRIES, OBJPROP_TEXT, is_pause_entries ? "Entries: PAUSED" : "Entries: ALLOWED");
   ChartRedraw();
  }

bool CheckActivePositions()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetSymbol(i) == _Symbol) return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Trade Execution & Management                                     |
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
            is_waiting_for_signal = false;
        }
      else
        {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(trade.Sell(InpInitialLot, _Symbol, bid, 0, 0, "Initial Short"))
            is_waiting_for_signal = false;
        }
      UpdateButtonState();
     }
  }

void RebalanceHedgeV2()
  {
   double totalBuyLots       = GetTotalVolume(POSITION_TYPE_BUY, false);
   double totalSellLots      = GetTotalVolume(POSITION_TYPE_SELL, false);
   double totalBuyOrdersLot  = GetTotalVolume(POSITION_TYPE_BUY, true);
   double totalSellOrdersLot = GetTotalVolume(POSITION_TYPE_SELL, true);

   double newVolume = NormalizeDouble(totalBuyLots - totalSellLots, 2);

   if(newVolume == 0.0)
     {
      DeleteRebalanceOrders();
      return;
     }

   ENUM_POSITION_TYPE requiredType   = (newVolume > 0.0) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   ENUM_ORDER_TYPE requiredOrderType = (requiredType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;

   double requiredLot = CalculateRequiredLotForRebalance(MathAbs(newVolume), requiredType);

   if(InpMaxLotPerSide > 0.0)
     {
      double currentSideExposure = (requiredType == POSITION_TYPE_BUY) ? totalBuyOrdersLot : totalSellOrdersLot;
      double remainingEligibleLots = NormalizeDouble(InpMaxLotPerSide - currentSideExposure, 2);
      requiredLot = MathMin(remainingEligibleLots, requiredLot);
     }

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   requiredLot    = MathFloor(requiredLot / lotStep) * lotStep;

   if(requiredLot < minLot) return;

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

   if(pendingTicket > 0)
     {
      if(pendingType == requiredOrderType && NormalizeDouble(pendingLots, 2) == NormalizeDouble(requiredLot, 2)) return;
      trade.OrderDelete(pendingTicket);
     }

   double offset = InpHedgeDistance * _Point;

   if(requiredType == POSITION_TYPE_BUY)
     {
      double buyPrice = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_ASK) + offset, _Digits);
      trade.BuyStop(requiredLot, buyPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "Hedge Rebalance");
     }
  else
     {
      double sellPrice = NormalizeDouble(SymbolInfoDouble(_Symbol, SYMBOL_BID) - offset, _Digits);
      trade.SellStop(requiredLot, sellPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "Hedge Rebalance");
     }
  }

void DeleteRebalanceOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
         trade.OrderDelete(ticket);
     }
  }

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
         if(lastBuyLevel > 0)
            target_price = MathMin(target_price, lastBuyLevel - offset);

         target_price = NormalizeDouble(target_price, _Digits);
         if(target_price > open_price)
            trade.OrderModify(ticket, target_price, 0, 0, ORDER_TIME_GTC, 0);
        }
      else if(type == ORDER_TYPE_BUY_STOP)
        {
         target_price = ask + offset;
         if(lastSellLevel > 0)
            target_price = MathMax(target_price, lastSellLevel + offset);

         target_price = NormalizeDouble(target_price, _Digits);
         if(target_price < open_price)
            trade.OrderModify(ticket, target_price, 0, 0, ORDER_TIME_GTC, 0);
        }
     }
  }

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

void ManageInsideHedge()
  {
   double bottomBuy = GetLastPositionPrice(POSITION_TYPE_BUY);
   double topSell   = GetLastPositionPrice(POSITION_TYPE_SELL);

   if(bottomBuy == 0.0 || topSell == 0.0) return;

   double minDistance = InpProfitTarget * InpInsideHedgeGapMultiplier * _Point;
   double distance    = NormalizeDouble(bottomBuy - topSell, _Digits);

   if(distance < minDistance) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);

   if(CopyRates(_Symbol, InpTimeframe, 0, 2, rates) < 2) return;

   static datetime lastProcessedBar = 0;
   if(rates[0].time == lastProcessedBar) return;

   double middleDistance  = NormalizeDouble(minDistance / 2, _Digits);
   double upperTradePoint = NormalizeDouble(bottomBuy - middleDistance, _Digits);
   double lowerTradePoint = NormalizeDouble(topSell + middleDistance, _Digits);

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
            lastProcessedBar = rates[0].time;
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
            lastProcessedBar = rates[0].time;
        }
     }
  }

//+------------------------------------------------------------------+
//| Utility & Math Functions                                         |
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

   if(startMins < endMins) return (currentMins >= startMins && currentMins < endMins);
   else if(startMins > endMins) return (currentMins >= startMins || currentMins < endMins);
   return true;
  }

double GetTotalVolume(ENUM_POSITION_TYPE type, bool withOrders = true)
  {
   double total_volume = 0.0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetSymbol(i) == _Symbol && (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         total_volume += PositionGetDouble(POSITION_VOLUME);
     }

   if(!withOrders) return NormalizeDouble(total_volume, 2);

   int total_orders = OrdersTotal();
   for(int i = 0; i < total_orders; i++)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol)
        {
         ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type == POSITION_TYPE_BUY && (order_type == ORDER_TYPE_BUY_LIMIT || order_type == ORDER_TYPE_BUY_STOP))
            total_volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
         else if(type == POSITION_TYPE_SELL && (order_type == ORDER_TYPE_SELL_LIMIT || order_type == ORDER_TYPE_SELL_STOP))
            total_volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
        }
     }
   return NormalizeDouble(total_volume, 2);
  }

double GetLastPositionPrice(ENUM_POSITION_TYPE type, bool includeOrders = false)
  {
   double extreme_price = 0.0;
   bool tracking_initialized = false;

   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(PositionGetSymbol(i) != _Symbol || (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != type) continue;
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      extreme_price = !tracking_initialized ? open_price : (type == POSITION_TYPE_BUY ? MathMin(extreme_price, open_price) : MathMax(extreme_price, open_price));
      tracking_initialized = true;
     }

   if(includeOrders)
     {
      for(int i = 0; i < OrdersTotal(); i++)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket <= 0 || OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
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

void SyncPositionArrays()
  {
   ArrayFree(profitableArray);
   ArrayFree(losingArray);

   for(int i = 0; i < PositionsTotal(); i++)
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
      for(int n = m + 1; n < ArraySize(profitableArray); n++)
         if(profitableArray[m].profit < profitableArray[n].profit)
           {
            PositionInfo temp = profitableArray[m];
            profitableArray[m] = profitableArray[n];
            profitableArray[n] = temp;
           }

   for(int m = 0; m < ArraySize(losingArray) - 1; m++)
      for(int n = m + 1; n < ArraySize(losingArray); n++)
         if(losingArray[m].distance < losingArray[n].distance)
           {
            PositionInfo temp = losingArray[m];
            losingArray[m] = losingArray[n];
            losingArray[n] = temp;
           }
  }

//+------------------------------------------------------------------+
//| Calculates the required lot size for rebalancing (Damped)        |
//+------------------------------------------------------------------+
double CalculateRequiredLotForRebalance(double diffVolume, ENUM_POSITION_TYPE rebalanceSide)
  {
   if(ArraySize(losingArray) == 0) return diffVolume;

   int posIndex = -1;
   for(int i = 0; i < ArraySize(losingArray); i++)
     {
      if(losingArray[i].type != rebalanceSide)
        {
         posIndex = i;
         break;
        }
     }

   if(posIndex < 0) return diffVolume;

   PositionInfo farLosingPos = losingArray[posIndex];

   // 1. Calculate usable profit target in points
   double remainingDistancePercent = 1.0 - (InpTrimProfitPercent / 100.0);
   double usablePoints = InpProfitTarget * remainingDistancePercent; 
   
   if(usablePoints <= 0) return diffVolume;

   // 2. Calculate the distance we need to cover (in points)
   double minRequiredDistanceToClose = (farLosingPos.distance / _Point) + InpHedgeDistance; 

   // 3. Linear Calculation (The dangerous calculation)
   double linearRequiredLot = (farLosingPos.volume * minRequiredDistanceToClose) / usablePoints;

   // 4. Square Root Dampening (The Fix)
   double baseLot = (diffVolume > 0.0) ? diffVolume : InpInitialLot;
   double dampenedLot = baseLot;
   
   if(linearRequiredLot > baseLot)
     {
      dampenedLot = baseLot * MathSqrt(linearRequiredLot / baseLot);
     }

   // 5. Hard Multiplier Cap (Using dynamic user input)
   if(dampenedLot > baseLot * InpMaxLotMultiplier)
     {
      dampenedLot = baseLot * InpMaxLotMultiplier;
     }

   // 6. The Micro-Lot Survival Floor
   double minBrokerLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double minRescueLot = minBrokerLot * (minRequiredDistanceToClose / usablePoints);

   double finalLot = MathMax(dampenedLot, minRescueLot);
   
   // 7. Ensure it never drops below the structural minimums
   finalLot = MathMax(diffVolume, MathMax(InpInitialLot, finalLot));

   return finalLot;
  }