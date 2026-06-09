//+------------------------------------------------------------------+
//|                                         XAUUSD_M5_Scalper.mq5   |
//|                              Momentum Scalper para AXI MT5       |
//|                                       Símbolo: XAUUSD — M5       |
//+------------------------------------------------------------------+
#property copyright "HFT Bot - AXI"
#property version   "1.30"
#property description "Scalping XAUUSD M5 — EMA crossover + RSI, sin límite de posiciones"
#property description "Lote dinámico por % de riesgo. Backtestear ANTES de usar en real."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\DealInfo.mqh>

//=== INPUTS ===================================================================

input group "=== IDENTIFICACIÓN ==="
input ulong  InpMagicNumber    = 20260606;     // Magic Number (no cambiar)
input string InpComment        = "XAUUSD_M5";  // Comentario en órdenes

input group "=== GESTIÓN DE RIESGO ==="
input double InpRiskPercent    = 2.0;          // Riesgo por trade (% del balance)
input int    InpSLPips         = 40;           // Stop Loss en pips (M5 ≈ 40 pips)
input int    InpTPPips         = 60;           // Take Profit en pips (R:R 1.5:1)
input double InpMaxDailyLoss   = 100.0;        // Límite de pérdida diaria en USD

input group "=== FILTRO DE ENTRADA ==="
input int    InpFastEMA        = 8;            // Período EMA rápida
input int    InpSlowEMA        = 21;           // Período EMA lenta
input int    InpRSIPeriod      = 7;            // Período RSI
input int    InpRSIBuyMin      = 55;           // RSI mínimo para BUY
input int    InpRSISellMax     = 45;           // RSI máximo para SELL
input int    InpMinBodyPts     = 10;           // Cuerpo mínimo de vela (puntos) — filtra dojis

input group "=== TRAILING STOP ==="
input bool   InpUseTrailing    = false;        // Activar trailing stop
input int    InpTrailingPips   = 15;           // Distancia del trailing (pips)
input int    InpTrailingStep   = 5;            // Paso mínimo de movimiento (pips)


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

//=== INICIALIZACIÓN ===========================================================
int OnInit()
{
   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Print("ADVERTENCIA: Este EA está optimizado para XAUUSD. Símbolo actual: ", _Symbol);

   if(Period() != PERIOD_M5)
      Print("ADVERTENCIA: Este EA está configurado para M5. Timeframe actual: ", EnumToString(Period()));

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);

   // Indicadores en M5
   hFastEMA = iMA(_Symbol, PERIOD_M5, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlowEMA = iMA(_Symbol, PERIOD_M5, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   hRSI     = iRSI(_Symbol, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);

   if(hFastEMA == INVALID_HANDLE || hSlowEMA == INVALID_HANDLE || hRSI == INVALID_HANDLE)
   {
      Print("[ERROR] No se pudieron crear los indicadores: ", GetLastError());
      return INIT_FAILED;
   }

   double lotExample = CalculateLotSize(InpSLPips * 10.0 * _Point);

   Print("========================================");
   Print("  XAUUSD M5 Scalper v1.30 iniciado");
   Print("  Broker  : ", AccountInfoString(ACCOUNT_COMPANY));
   Print("  Cuenta  : ", AccountInfoInteger(ACCOUNT_LOGIN));
   Print("  Balance : $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("  Riesgo  : ", InpRiskPercent, "% (~", DoubleToString(lotExample, 2), " lotes)");
   Print("  SL/TP   : ", InpSLPips, "/", InpTPPips, " pips");
   Print("  Límite  : $", InpMaxDailyLoss, " pérdida diaria");
   Print("  Límite posiciones: SIN LÍMITE");
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

   // Recalcular P&L completo del día (flotante + realizados)
   g_dailyPnL = CalcDailyPnL();

   if(InpUseTrailing)
      ManageTrailingStop();

   UpdateComment();

   // Solo circuit breaker diario — sin límite de posiciones ni spread
   if(g_dailyLimitHit)                return;
   if(g_dailyPnL <= -InpMaxDailyLoss) { g_dailyLimitHit = true; CloseAllPositions(); return; }

   // Solo actuar en apertura de nueva vela M5
   datetime currentBar = iTime(_Symbol, PERIOD_M5, 0);
   if(currentBar == g_lastBarTime) return;
   g_lastBarTime = currentBar;

   int signal = GetSignal();
   if(signal == 0) return;

   // No abrir en la misma dirección si ya existe posición abierta
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

   open1  = iOpen (_Symbol, PERIOD_M5, 1);
   close1 = iClose(_Symbol, PERIOD_M5, 1);

   // Cruce EMA en la vela M5 anterior
   bool crossUp   = (fastEMA[2] <= slowEMA[2]) && (fastEMA[1] > slowEMA[1]);
   bool crossDown = (fastEMA[2] >= slowEMA[2]) && (fastEMA[1] < slowEMA[1]);

   bool rsiLong   = rsi[0] > InpRSIBuyMin;
   bool rsiShort  = rsi[0] < InpRSISellMax;

   // Filtro de cuerpo de vela (evitar dojis)
   double bodySize = MathAbs(close1 - open1) / _Point;
   if(bodySize < InpMinBodyPts) return 0;

   bool bullBody = close1 > open1;
   bool bearBody = close1 < open1;

   if(crossUp   && rsiLong  && bullBody) return  1;
   if(crossDown && rsiShort && bearBody) return -1;

   return 0;
}

//=== CÁLCULO DE LOTE DINÁMICO =================================================
double CalculateLotSize(double slDistance)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0 || tickValue <= 0 || slDistance <= 0) return 0.0;

   double slValuePerLot = (slDistance / tickSize) * tickValue;
   if(slValuePerLot <= 0) return 0.0;

   double lotSize = riskAmount / slValuePerLot;

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   return NormalizeDouble(MathMax(minLot, MathMin(maxLot, lotSize)), 2);
}

//=== ABRIR COMPRA =============================================================
void ExecuteBuy()
{
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double slDist   = InpSLPips * 10.0 * _Point;
   double tpDist   = InpTPPips * 10.0 * _Point;
   double slPrice  = NormalizeDouble(ask - slDist, _Digits);
   double tpPrice  = NormalizeDouble(ask + tpDist, _Digits);
   double lotSize  = CalculateLotSize(slDist);

   if(lotSize <= 0) { Print("Lote inválido, BUY cancelado."); return; }
   if(!IsValidSLTP(ask, slPrice, tpPrice, ORDER_TYPE_BUY)) return;

   if(trade.Buy(lotSize, _Symbol, ask, slPrice, tpPrice, InpComment))
   {
      g_dailyTrades++;
      PrintFormat("✔ BUY  | Ask: %.2f | SL: %.2f | TP: %.2f | Lote: %.2f | Riesgo: $%.2f",
                  ask, slPrice, tpPrice, lotSize, lotSize * slDist / _Point * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) / SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) * _Point);
   }
   else
      PrintFormat("✘ Error BUY: %d - %s", GetLastError(), trade.ResultRetcodeDescription());
}

//=== ABRIR VENTA ==============================================================
void ExecuteSell()
{
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double slDist   = InpSLPips * 10.0 * _Point;
   double tpDist   = InpTPPips * 10.0 * _Point;
   double slPrice  = NormalizeDouble(bid + slDist, _Digits);
   double tpPrice  = NormalizeDouble(bid - tpDist, _Digits);
   double lotSize  = CalculateLotSize(slDist);

   if(lotSize <= 0) { Print("Lote inválido, SELL cancelado."); return; }
   if(!IsValidSLTP(bid, slPrice, tpPrice, ORDER_TYPE_SELL)) return;

   if(trade.Sell(lotSize, _Symbol, bid, slPrice, tpPrice, InpComment))
   {
      g_dailyTrades++;
      PrintFormat("✔ SELL | Bid: %.2f | SL: %.2f | TP: %.2f | Lote: %.2f",
                  bid, slPrice, tpPrice, lotSize);
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

double CalcDailyPnL()
{
   double pnl = 0.0;

   // Floating P&L de todas las posiciones abiertas (incluye overnight)
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
         if(HistoryDealGetString(ticket, DEAL_SYMBOL)        != _Symbol)        continue;
         if((ulong)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY)        != DEAL_ENTRY_OUT) continue;
         pnl += HistoryDealGetDouble(ticket, DEAL_PROFIT)
              + HistoryDealGetDouble(ticket, DEAL_SWAP)
              + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      }
   }

   return pnl;
}

bool IsValidSLTP(double entryPrice, double sl, double tp, ENUM_ORDER_TYPE type)
{
   double minStop = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(type == ORDER_TYPE_BUY)
   {
      if(entryPrice - sl < minStop) { Print("SL demasiado cercano"); return false; }
      if(tp - entryPrice < minStop) { Print("TP demasiado cercano"); return false; }
   }
   else
   {
      if(sl - entryPrice < minStop) { Print("SL demasiado cercano"); return false; }
      if(entryPrice - tp < minStop) { Print("TP demasiado cercano"); return false; }
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
   string status = g_dailyLimitHit ? "⛔ LÍMITE DIARIO" : "✅ ACTIVO 24/5";
   double lotExample = CalculateLotSize(InpSLPips * 10.0 * _Point);

   Comment(StringFormat(
      "═══════ XAUUSD M5 Scalper v1.30 ══════\n"
      "Estado   : %s\n"
      "P&L Hoy  : $%.2f  (límite: -$%.2f)\n"
      "Trades hoy: %d\n"
      "Posiciones: %d  (sin límite)\n"
      "Lote actual: %.2f (%.1f%% riesgo)\n"
      "Hora GMT : %s\n"
      "═══════════════════════════════════════",
      status,
      g_dailyPnL, InpMaxDailyLoss,
      g_dailyTrades,
      CountOpenByMagic(),
      lotExample, InpRiskPercent,
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
         PrintFormat("[%s] Trade cerrado | P&L: $%.2f",
                     profit > 0 ? "GANANCIA" : "PÉRDIDA", profit);
   }
}
//+------------------------------------------------------------------+
