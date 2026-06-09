//+------------------------------------------------------------------+
//|                                         XAUUSD_HFT_Scalper.mq5 |
//|                              Momentum Scalper para AXI MT5      |
//|                                       Símbolo: XAUUSD           |
//+------------------------------------------------------------------+
#property copyright "HFT Bot - AXI"
#property version   "1.21"
#property description "Scalping de momentum en XAUUSD usando EMA crossover + RSI"
#property description "Configurado para cuenta real AXI. Backtestear ANTES de usar."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\DealInfo.mqh>

//=== INPUTS ===================================================================

input group "=== IDENTIFICACIÓN ==="
input ulong  InpMagicNumber    = 20260606;     // Magic Number (no cambiar)
input string InpComment        = "XAUUSD_HFT"; // Comentario en órdenes

input group "=== GESTIÓN DE RIESGO ==="
input double InpLotSize        = 0.01;         // Lote fijo por operación
input int    InpSLPips         = 30;           // Stop Loss en pips
input int    InpTPPips         = 15;           // Take Profit en pips
input int    InpMaxOpenTrades  = 1;            // Máximo posiciones abiertas simultáneas
input double InpMaxDailyLoss   = 100.0;        // Límite de pérdida diaria en USD

input group "=== FILTRO DE ENTRADA ==="
input int    InpFastEMA        = 5;            // Período EMA rápida
input int    InpSlowEMA        = 13;           // Período EMA lenta
input int    InpRSIPeriod      = 7;            // Período RSI
input int    InpRSIBuyMin      = 55;           // RSI mínimo para BUY
input int    InpRSISellMax     = 45;           // RSI máximo para SELL
input int    InpMaxSpreadPts   = 15;           // Spread máximo (puntos MT5)
input int    InpMinBodyPts     = 5;            // Cuerpo mínimo de vela (puntos) — filtra dojis

input group "=== TRAILING STOP ==="
input bool   InpUseTrailing    = false;        // Activar trailing stop
input int    InpTrailingPips   = 8;            // Distancia del trailing (pips)
input int    InpTrailingStep   = 3;            // Paso mínimo de movimiento (pips)


//=== OBJETOS GLOBALES =========================================================
CTrade        trade;
CPositionInfo posInfo;
CDealInfo     dealInfo;

//--- Handles de indicadores
int hFastEMA   = INVALID_HANDLE;
int hSlowEMA   = INVALID_HANDLE;
int hRSI       = INVALID_HANDLE;

//--- Control diario
datetime      g_lastBarTime    = 0;
datetime      g_lastTradeDay   = 0;
int           g_dailyTrades    = 0;
double        g_dailyPnL       = 0.0;
bool          g_dailyLimitHit  = false;

//--- Para display
string        g_statusMsg      = "";

//=== INICIALIZACIÓN ===========================================================
int OnInit()
{
   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Print("ADVERTENCIA: Este EA está optimizado para XAUUSD. Símbolo actual: ", _Symbol);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);

   hFastEMA = iMA(_Symbol, PERIOD_M1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, PERIOD_M1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);

   if(hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE || hRSI == INVALID_HANDLE)
   {
      Print("[ERROR] No se pudieron crear los indicadores: ", GetLastError());
      return INIT_FAILED;
   }

   Print("========================================");
   Print("  XAUUSD HFT Scalper v1.21 iniciado");
   Print("  Broker  : ", AccountInfoString(ACCOUNT_COMPANY));
   Print("  Cuenta  : ", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("  Balance : $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("  Lote    : ", InpLotSize);
   Print("  SL/TP   : ", InpSLPips, "/", InpTPPips, " pips");
   Print("  Límite  : $", InpMaxDailyLoss, " diarios");
   Print("========================================");

   return INIT_SUCCEEDED;
}

//=== DEINICIALIZACIÓN =========================================================
void OnDeinit(const int reason)
{
   if(hFastEMA != INVALID_HANDLE) IndicatorRelease(hFastEMA);
   if(hSlowEMA != INVALID_HANDLE) IndicatorRelease(hSlowEMA);
   if(hRSI     != INVALID_HANDLE) IndicatorRelease(hRSI);
   Comment("");
   Print("Bot detenido. Código: ", reason);
}

//=== TICK PRINCIPAL ===========================================================
void OnTick()
{
   ResetDailyIfNewDay();

   // Recalcular P&L completo del día (flotante + trades cerrados)
   g_dailyPnL = CalcDailyPnL();

   if(InpUseTrailing)
      ManageTrailingStop();

   UpdateComment();

   if(g_dailyLimitHit)                       return;
   if(g_dailyPnL <= -InpMaxDailyLoss)        { g_dailyLimitHit = true; CloseAllPositions(); return; }
   if(CountOpenByMagic() >= InpMaxOpenTrades) return;
   if(!IsSpreadOK())                          return;

   datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
   if(currentBar == g_lastBarTime) return;
   g_lastBarTime = currentBar;

   int signal = GetSignal();
   if(signal == 0) return;

   if(signal == 1  && HasOpenPosition(POSITION_TYPE_BUY))  return;
   if(signal == -1 && HasOpenPosition(POSITION_TYPE_SELL)) return;

   if(signal == 1)  ExecuteBuy();
   if(signal == -1) ExecuteSell();
}

//=== SEÑAL DE TRADING =========================================================
int GetSignal()
{
   double fastEMA[3], slowEMA[3], rsi[2];
   double open1, close1;

   if(CopyBuffer(hFastEMA, 0, 0, 3, fastEMA) < 3) return 0;
   if(CopyBuffer(hSlowEMA, 0, 0, 3, slowEMA) < 3) return 0;
   if(CopyBuffer(hRSI,     0, 0, 2, rsi)     < 2) return 0;

   ArraySetAsSeries(fastEMA, true);
   ArraySetAsSeries(slowEMA, true);
   ArraySetAsSeries(rsi,     true);

   open1  = iOpen (_Symbol, PERIOD_M1, 1);
   close1 = iClose(_Symbol, PERIOD_M1, 1);

   bool crossUp   = (fastEMA[2] <= slowEMA[2]) && (fastEMA[1] > slowEMA[1]);
   bool crossDown = (fastEMA[2] >= slowEMA[2]) && (fastEMA[1] < slowEMA[1]);

   bool rsiLong   = rsi[0] > InpRSIBuyMin;
   bool rsiShort  = rsi[0] < InpRSISellMax;

   // Filtro de vela: ignorar dojis y cuerpos pequeños
   double bodySize = MathAbs(close1 - open1) / _Point;
   if(bodySize < InpMinBodyPts) return 0;

   bool bullBody = close1 > open1;
   bool bearBody = close1 < open1;

   if(crossUp   && rsiLong  && bullBody) return  1;
   if(crossDown && rsiShort && bearBody) return -1;

   return 0;
}

//=== ABRIR COMPRA =============================================================
void ExecuteBuy()
{
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double slPrice = NormalizeDouble(ask - InpSLPips * 10.0 * _Point, _Digits);
   double tpPrice = NormalizeDouble(ask + InpTPPips * 10.0 * _Point, _Digits);

   if(!IsValidSLTP(ask, slPrice, tpPrice, ORDER_TYPE_BUY)) return;

   if(trade.Buy(InpLotSize, _Symbol, ask, slPrice, tpPrice, InpComment))
   {
      g_dailyTrades++;
      PrintFormat("✔ BUY  | Ask: %.2f | SL: %.2f | TP: %.2f | Lote: %.2f",
                  ask, slPrice, tpPrice, InpLotSize);
   }
   else
      PrintFormat("✘ Error BUY: %d - %s", GetLastError(), trade.ResultRetcodeDescription());
}

//=== ABRIR VENTA ==============================================================
void ExecuteSell()
{
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slPrice = NormalizeDouble(bid + InpSLPips * 10.0 * _Point, _Digits);
   double tpPrice = NormalizeDouble(bid - InpTPPips * 10.0 * _Point, _Digits);

   if(!IsValidSLTP(bid, slPrice, tpPrice, ORDER_TYPE_SELL)) return;

   if(trade.Sell(InpLotSize, _Symbol, bid, slPrice, tpPrice, InpComment))
   {
      g_dailyTrades++;
      PrintFormat("✔ SELL | Bid: %.2f | SL: %.2f | TP: %.2f | Lote: %.2f",
                  bid, slPrice, tpPrice, InpLotSize);
   }
   else
      PrintFormat("✘ Error SELL: %d - %s", GetLastError(), trade.ResultRetcodeDescription());
}

//=== TRAILING STOP ============================================================
void ManageTrailingStop()
{
   double trailDist = InpTrailingPips * 10.0 * _Point;
   double trailStep = InpTrailingStep * 10.0 * _Point;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != InpMagicNumber) continue;

      double currentSL = posInfo.StopLoss();
      ulong  ticket    = posInfo.Ticket();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         if(newSL > currentSL + trailStep)
            trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(currentSL == 0 || newSL < currentSL - trailStep)
            trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
      }
   }
}

//=== CERRAR TODAS LAS POSICIONES ==============================================
void CloseAllPositions()
{
   Print("[LÍMITE DIARIO] Cerrando todas las posiciones...");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != InpMagicNumber) continue;
      trade.PositionClose(posInfo.Ticket());
   }
}

//=== UTILIDADES ===============================================================

int CountOpenByMagic()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            count++;
   return count;
}

bool HasOpenPosition(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            if(posInfo.PositionType() == type)
               return true;
   return false;
}

// FIX: incluye P&L de trades cerrados hoy + floating de posiciones abiertas
double CalcDailyPnL()
{
   double pnl = 0.0;

   // Floating P&L de posiciones abiertas
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            pnl += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();

   // P&L realizado de trades cerrados hoy
   MqlDateTime dt;
   TimeGMT(dt);
   datetime dayStart = StringToTime(StringFormat("%d.%02d.%02d 00:00", dt.year, dt.mon, dt.day));

   if(HistorySelect(dayStart, TimeCurrent()))
   {
      for(int i = 0; i < HistoryDealsTotal(); i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL)             != _Symbol)        continue;
         if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC)      != InpMagicNumber) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY)             != DEAL_ENTRY_OUT) continue;
         pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT)
              + HistoryDealGetDouble(ticket, DEAL_SWAP)
              + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      }
   }

   return pnl;
}

bool IsSpreadOK()
{
   return (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpreadPts);
}

bool IsValidSLTP(double entryPrice, double sl, double tp, ENUM_ORDER_TYPE type)
{
   double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   if(type == ORDER_TYPE_BUY)
   {
      if(entryPrice - sl < minStop) { Print("SL demasiado cercano al precio"); return false; }
      if(tp - entryPrice < minStop) { Print("TP demasiado cercano al precio"); return false; }
   }
   else
   {
      if(sl - entryPrice < minStop) { Print("SL demasiado cercano al precio"); return false; }
      if(entryPrice - tp < minStop) { Print("TP demasiado cercano al precio"); return false; }
   }
   return true;
}

void ResetDailyIfNewDay()
{
   MqlDateTime dt;
   TimeGMT(dt);
   datetime today = StringToTime(StringFormat("%d.%02d.%02d", dt.year, dt.mon, dt.day));

   if(today != g_lastTradeDay)
   {
      g_lastTradeDay  = today;
      g_dailyTrades   = 0;
      g_dailyPnL      = 0.0;
      g_dailyLimitHit = false;
      Print("=== Nuevo día de trading iniciado ===");
   }
}

void UpdateComment()
{
   long   spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   string status = g_dailyLimitHit ? "⛔ LÍMITE DIARIO" : "✅ ACTIVO 24/5";

   Comment(StringFormat(
      "═══════ XAUUSD HFT Scalper ═══════\n"
      "Estado  : %s\n"
      "P&L Hoy : $%.2f  (límite: -$%.2f)\n"
      "Trades hoy: %d\n"
      "Spread  : %d pts  (máx: %d)\n"
      "Posiciones: %d / %d\n"
      "Hora GMT: %s\n"
      "══════════════════════════════════",
      status,
      g_dailyPnL, InpMaxDailyLoss,
      g_dailyTrades,
      (int)spread, InpMaxSpreadPts,
      CountOpenByMagic(), InpMaxOpenTrades,
      TimeToString(TimeGMT(), TIME_MINUTES)
   ));
}

//=== CALLBACK DE TRANSACCIONES ================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal))
   {
      double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      ulong  magic  = (ulong)HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
      long   entry  = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

      if(magic == InpMagicNumber && entry == DEAL_ENTRY_OUT && profit != 0)
      {
         // g_dailyPnL se recalcula en el siguiente tick vía CalcDailyPnL()
         PrintFormat("[%s] Trade cerrado | P&L: $%.2f",
                     profit > 0 ? "GANANCIA" : "PÉRDIDA", profit);
      }
   }
}
//+------------------------------------------------------------------+
