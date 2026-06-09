//+------------------------------------------------------------------+
//|                                          GoldScalperPro.mq5      |
//|                Triple Confirmation Scalper — XAUUSD M1           |
//|                                                                   |
//|  Estrategia: EMA cross (8/21) + RSI(14) + BB(20) confirmados    |
//|  con filtro de tendencia EMA50 en M5, ATR y sesiones London/NY   |
//+------------------------------------------------------------------+
#property copyright "GoldScalperPro"
#property version   "1.00"
#property description "High-frequency scalper XAUUSD M1 — Triple Confirmation"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "── Gestión de Riesgo ────────────────────────────"
input double InpRiskPercent    = 2.0;    // Riesgo por trade (% balance)
input double InpMaxDailyLoss   = 5.0;    // Pérdida máxima diaria (%)
input int    InpMaxConcurrent  = 3;      // Máximo trades abiertos
input int    InpMaxDailyTrades = 10;     // Máximo trades por día

input group "── Indicadores de Entrada ──────────────────────"
input int    InpEMA_Fast       = 8;      // EMA rápida M1
input int    InpEMA_Slow       = 21;     // EMA lenta M1
input int    InpEMA_Trend      = 50;     // EMA tendencia M5
input int    InpRSI_Period     = 14;     // Período RSI
input double InpRSI_BullMin    = 55.0;   // RSI mínimo para longs
input double InpRSI_BearMax    = 45.0;   // RSI máximo para shorts
input int    InpBB_Period      = 20;     // Período Bollinger Bands
input double InpBB_Dev         = 2.0;    // Desviación estándar BB

input group "── Filtro de Volatilidad (ATR) ─────────────────"
input int    InpATR_Period     = 14;     // Período ATR
input double InpATR_Min        = 0.5;    // ATR mínimo (evitar mercados planos)
input double InpATR_Max        = 3.0;    // ATR máximo (evitar noticias)

input group "── Gestión del Trade ────────────────────────────"
input int    InpSL_Pips        = 15;     // Stop Loss (pips)
input int    InpTP_Pips        = 25;     // Take Profit (pips)
input bool   InpTrailing       = true;   // Activar trailing stop
input int    InpTrailActivate  = 15;     // Pips de ganancia para activar trail
input int    InpTrailStep      = 5;      // Paso del trailing (pips)

input group "── Filtro de Sesión (hora GMT del servidor) ─────"
input int    InpLondonOpen     = 8;      // Apertura London (GMT)
input int    InpLondonClose    = 12;     // Cierre London (GMT)
input int    InpNYOpen         = 13;     // Apertura New York (GMT)
input int    InpNYClose        = 17;     // Cierre New York (GMT)

input group "── General ──────────────────────────────────────"
input long   InpMagic          = 202406; // Magic Number único del EA

//+------------------------------------------------------------------+
//| Variables globales                                               |
//+------------------------------------------------------------------+
CTrade        g_trade;
CPositionInfo g_pos;

int g_hEMAFast  = INVALID_HANDLE;
int g_hEMASlow  = INVALID_HANDLE;
int g_hEMATrend = INVALID_HANDLE;
int g_hRSI      = INVALID_HANDLE;
int g_hBB       = INVALID_HANDLE;
int g_hATR      = INVALID_HANDLE;

datetime g_lastBar = 0;
double   g_pipSize = 0.0;

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    // Solo XAUUSD
    string sym = Symbol();
    if(StringFind(sym, "XAU") < 0 && StringFind(sym, "GOLD") < 0)
    {
        Alert("GoldScalperPro: Adjuntar ÚNICAMENTE a gráfico XAUUSD.");
        return INIT_FAILED;
    }

    // Solo M1
    if(Period() != PERIOD_M1)
    {
        Alert("GoldScalperPro: Adjuntar al timeframe M1.");
        return INIT_FAILED;
    }

    // Tamaño de pip: XAUUSD tiene 2 dígitos → 1 pip = 10 puntos
    g_pipSize = (_Digits >= 2) ? _Point * 10.0 : _Point;

    // Crear handles de indicadores
    g_hEMAFast  = iEMA(sym, PERIOD_M1, InpEMA_Fast,  0, MODE_EMA, PRICE_CLOSE);
    g_hEMASlow  = iEMA(sym, PERIOD_M1, InpEMA_Slow,  0, MODE_EMA, PRICE_CLOSE);
    g_hEMATrend = iEMA(sym, PERIOD_M5, InpEMA_Trend, 0, MODE_EMA, PRICE_CLOSE);
    g_hRSI      = iRSI(sym, PERIOD_M1, InpRSI_Period, PRICE_CLOSE);
    g_hBB       = iBands(sym, PERIOD_M1, InpBB_Period, 0, InpBB_Dev, PRICE_CLOSE);
    g_hATR      = iATR(sym, PERIOD_M1, InpATR_Period);

    if(g_hEMAFast  == INVALID_HANDLE || g_hEMASlow  == INVALID_HANDLE ||
       g_hEMATrend == INVALID_HANDLE || g_hRSI      == INVALID_HANDLE ||
       g_hBB       == INVALID_HANDLE || g_hATR      == INVALID_HANDLE)
    {
        Alert("GoldScalperPro: Error creando handles de indicadores.");
        return INIT_FAILED;
    }

    g_trade.SetExpertMagicNumber(InpMagic);
    g_trade.SetDeviationInPoints(20);
    g_trade.SetTypeFilling(ORDER_FILLING_FOK);

    Print("=== GoldScalperPro iniciado ===");
    Print("Símbolo: ", sym, " | Digits: ", _Digits, " | PipSize: ", g_pipSize);
    Print("Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
    Print("Riesgo por trade: ", InpRiskPercent, "% = $",
          DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0, 2));

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(g_hEMAFast);
    IndicatorRelease(g_hEMASlow);
    IndicatorRelease(g_hEMATrend);
    IndicatorRelease(g_hRSI);
    IndicatorRelease(g_hBB);
    IndicatorRelease(g_hATR);
    Print("GoldScalperPro detenido. Razón: ", reason);
}

//+------------------------------------------------------------------+
//| OnTick — Lógica principal                                        |
//+------------------------------------------------------------------+
void OnTick()
{
    // Ejecutar solo en apertura de nueva vela M1
    datetime currentBar = iTime(Symbol(), PERIOD_M1, 0);
    if(currentBar == g_lastBar) return;
    g_lastBar = currentBar;

    // 1. Gestionar trailing stops en posiciones abiertas
    if(InpTrailing) ManageTrailingStop();

    // 2. Verificar si podemos abrir nuevos trades
    if(!IsTradeAllowed()) return;

    // 3. Calcular señal de entrada
    int signal = GetSignal();
    if(signal == 0) return;

    // 4. Calcular lote y abrir trade
    double slPoints = InpSL_Pips * g_pipSize;
    double tpPoints = InpTP_Pips * g_pipSize;
    double lotSize  = CalculateLotSize(slPoints);

    if(lotSize <= 0)
    {
        Print("Lot size inválido, trade omitido.");
        return;
    }

    double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
    double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);

    if(signal == 1) // LONG
    {
        double sl = NormalizeDouble(ask - slPoints, _Digits);
        double tp = NormalizeDouble(ask + tpPoints, _Digits);
        if(g_trade.Buy(lotSize, Symbol(), ask, sl, tp, "GSP_Long"))
            Print("BUY  ", lotSize, " @ ", ask, " | SL:", sl, " TP:", tp);
        else
            Print("Error BUY: ", g_trade.ResultRetcodeDescription());
    }
    else if(signal == -1) // SHORT
    {
        double sl = NormalizeDouble(bid + slPoints, _Digits);
        double tp = NormalizeDouble(bid - tpPoints, _Digits);
        if(g_trade.Sell(lotSize, Symbol(), bid, sl, tp, "GSP_Short"))
            Print("SELL ", lotSize, " @ ", bid, " | SL:", sl, " TP:", tp);
        else
            Print("Error SELL: ", g_trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| IsTradeAllowed — Filtros previos a la entrada                    |
//+------------------------------------------------------------------+
bool IsTradeAllowed()
{
    // Filtro de sesión (hora GMT del servidor)
    MqlDateTime dt;
    TimeToStruct(TimeGMT(), dt);
    int hour = dt.hour;
    bool londonSession = (hour >= InpLondonOpen  && hour < InpLondonClose);
    bool nySession     = (hour >= InpNYOpen      && hour < InpNYClose);
    if(!londonSession && !nySession) return false;

    // Límite de trades simultáneos
    if(CountOpenPositions() >= InpMaxConcurrent) return false;

    // Estadísticas diarias
    int    dailyTrades = 0;
    double dailyPL     = 0.0;
    GetDailyStats(dailyTrades, dailyPL);

    // Límite de trades diarios
    if(dailyTrades >= InpMaxDailyTrades) return false;

    // Circuit breaker: pausar si pérdida diaria >= InpMaxDailyLoss %
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(balance > 0 && dailyPL < 0)
    {
        double lossPct = MathAbs(dailyPL) / balance * 100.0;
        if(lossPct >= InpMaxDailyLoss)
        {
            static datetime lastCircuitLog = 0;
            if(TimeCurrent() - lastCircuitLog > 3600)
            {
                Print("⚠ CIRCUIT BREAKER: Pérdida diaria ", DoubleToString(lossPct, 1),
                      "% >= ", InpMaxDailyLoss, "%. Trading pausado por hoy.");
                lastCircuitLog = TimeCurrent();
            }
            return false;
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//| GetSignal — Triple confirmación: EMA cross + RSI + BB            |
//| Returns: 1 = Buy, -1 = Sell, 0 = Sin señal                      |
//+------------------------------------------------------------------+
int GetSignal()
{
    // Necesitamos las 2 velas anteriores cerradas (índices 1 y 2)
    double emaFast[3], emaSlow[3], rsiVal[2];
    double bbMiddle[2], atrVal[2], emaTrend[2];

    if(CopyBuffer(g_hEMAFast,  0, 1, 3, emaFast)  < 3) return 0;
    if(CopyBuffer(g_hEMASlow,  0, 1, 3, emaSlow)  < 3) return 0;
    if(CopyBuffer(g_hRSI,      0, 1, 2, rsiVal)   < 2) return 0;
    if(CopyBuffer(g_hBB,       0, 1, 2, bbMiddle) < 2) return 0; // BASE_LINE
    if(CopyBuffer(g_hATR,      0, 1, 2, atrVal)   < 2) return 0;
    if(CopyBuffer(g_hEMATrend, 0, 1, 2, emaTrend) < 2) return 0;

    // Índice 0 = vela más reciente cerrada, índice 1 = la anterior
    double prevFast = emaFast[1];   // vela [2]
    double currFast = emaFast[0];   // vela [1]
    double prevSlow = emaSlow[1];
    double currSlow = emaSlow[0];
    double currRSI  = rsiVal[0];
    double currATR  = atrVal[0];
    double currBBMid = bbMiddle[0];
    double trendEMA  = emaTrend[0];

    double closeM1 = iClose(Symbol(), PERIOD_M1, 1);
    double closeM5 = iClose(Symbol(), PERIOD_M5, 1);

    // ── Filtro ATR: evitar flats y noticias ──────────────────────────
    if(currATR < InpATR_Min || currATR > InpATR_Max) return 0;

    // ── Filtro de tendencia M5 ────────────────────────────────────────
    bool trendUp   = (closeM5 > trendEMA);
    bool trendDown = (closeM5 < trendEMA);

    // ── Señal LONG ────────────────────────────────────────────────────
    // EMA rápida cruza al alza la EMA lenta
    bool emaCrossUp = (prevFast <= prevSlow && currFast > currSlow);
    // RSI indica momentum alcista
    bool rsiBull    = (currRSI >= InpRSI_BullMin);
    // Precio por encima de la media de las BB (bias alcista)
    bool bbBull     = (closeM1 > currBBMid);

    if(trendUp && emaCrossUp && rsiBull && bbBull)
        return 1;

    // ── Señal SHORT ───────────────────────────────────────────────────
    bool emaCrossDown = (prevFast >= prevSlow && currFast < currSlow);
    bool rsiBear      = (currRSI <= InpRSI_BearMax);
    bool bbBear       = (closeM1 < currBBMid);

    if(trendDown && emaCrossDown && rsiBear && bbBear)
        return -1;

    return 0;
}

//+------------------------------------------------------------------+
//| CalculateLotSize — Riesgo fijo % del balance                     |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
    double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * InpRiskPercent / 100.0;

    double tickValue = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_VALUE);
    double tickSize  = SymbolInfoDouble(Symbol(), SYMBOL_TRADE_TICK_SIZE);

    if(tickSize <= 0 || tickValue <= 0 || slDistance <= 0) return 0.0;

    // Valor monetario del SL para 1 lote estándar
    double slValuePerLot = (slDistance / tickSize) * tickValue;
    if(slValuePerLot <= 0) return 0.0;

    double lotSize = riskAmount / slValuePerLot;

    // Normalizar al step y límites del broker
    double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
    double minLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);

    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

    return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| ManageTrailingStop — Mueve SL para proteger ganancias            |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    double activateDist = InpTrailActivate * g_pipSize;
    double stepDist     = InpTrailStep * g_pipSize;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!g_pos.SelectByIndex(i)) continue;
        if(g_pos.Symbol() != Symbol() || g_pos.Magic() != InpMagic) continue;

        double openPrice = g_pos.PriceOpen();
        double currentSL = g_pos.StopLoss();
        double currentTP = g_pos.TakeProfit();

        if(g_pos.PositionType() == POSITION_TYPE_BUY)
        {
            double bid = SymbolInfoDouble(Symbol(), SYMBOL_BID);
            if(bid - openPrice < activateDist) continue;

            double newSL = NormalizeDouble(bid - stepDist, _Digits);
            if(newSL > currentSL)
                g_trade.PositionModify(g_pos.Ticket(), newSL, currentTP);
        }
        else if(g_pos.PositionType() == POSITION_TYPE_SELL)
        {
            double ask = SymbolInfoDouble(Symbol(), SYMBOL_ASK);
            if(openPrice - ask < activateDist) continue;

            double newSL = NormalizeDouble(ask + stepDist, _Digits);
            if(newSL < currentSL || currentSL == 0)
                g_trade.PositionModify(g_pos.Ticket(), newSL, currentTP);
        }
    }
}

//+------------------------------------------------------------------+
//| CountOpenPositions — Cuenta posiciones abiertas de este EA       |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
        if(g_pos.SelectByIndex(i))
            if(g_pos.Symbol() == Symbol() && g_pos.Magic() == InpMagic)
                count++;
    return count;
}

//+------------------------------------------------------------------+
//| GetDailyStats — Trades abiertos hoy y P&L del día               |
//+------------------------------------------------------------------+
void GetDailyStats(int &tradeCount, double &dailyPL)
{
    tradeCount = 0;
    dailyPL    = 0.0;

    // Inicio del día en hora local
    MqlDateTime today;
    TimeToStruct(TimeLocal(), today);
    today.hour = 0; today.min = 0; today.sec = 0;
    datetime dayStart = StructToTime(today);

    // Posiciones abiertas que se abrieron hoy
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!g_pos.SelectByIndex(i)) continue;
        if(g_pos.Symbol() != Symbol() || g_pos.Magic() != InpMagic) continue;
        if(g_pos.Time() >= dayStart)
        {
            tradeCount++;
            dailyPL += g_pos.Profit() + g_pos.Swap() + g_pos.Commission();
        }
    }

    // Trades cerrados hoy en el historial
    if(!HistorySelect(dayStart, TimeCurrent())) return;

    for(int i = 0; i < HistoryDealsTotal(); i++)
    {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetString(ticket, DEAL_SYMBOL)  != Symbol())    continue;
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC)  != InpMagic)    continue;

        long entry = HistoryDealGetInteger(ticket, DEAL_ENTRY);

        if(entry == DEAL_ENTRY_IN)
            tradeCount++;

        if(entry == DEAL_ENTRY_OUT)
            dailyPL += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                     + HistoryDealGetDouble(ticket, DEAL_SWAP)
                     + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
    }
}
//+------------------------------------------------------------------+
