# Polymarket 5-Minute Bot: The Easy Hyper Gambler

### **Polymarket 5-Minute Bot: The Easy Hyper Gambler**
The simplest way to bet on BTC 5-minute Up/Down markets on Polymarket. Three keyboard keys — B for UP, S for DOWN, X to close. Places limit orders at a discount so you get better entries. 288 chances per day.

By Moon Dev · 15 de marzo de 2026

## **What Is This Bot?**

Polymarket runs BTC 5-minute Up/Down binary markets — every 5 minutes, a new market opens asking "Will BTC be above $X at the end of this window?" You can bet YES (up) or NO (down). That's 288 markets per day.

This bot gives you a **real-time terminal dashboard** with keyboard controls. You watch the price, the order books, and the countdown timer — then press a key to place your bet. It's manual decision-making with automated execution.

### **How It Works**

- **B = Buy UP** — Places a limit order on the bid for the UP outcome, betting BTC goes higher
- **S = Buy DOWN** — Places a limit order on the bid for the DOWN outcome, betting BTC goes lower
- **X = Close Position** — Sells your shares into the bid to exit early before expiry
- **Press B or S again** — Cancels and re-places your order to chase the price

The key trick: the bot doesn't buy at market price. It places limit orders at a **10% discount** below the current bid. You're fishing for a dip — a momentary pullback that fills your order at a better price. Let me walk you through every piece of this bot.

---

## **Step 1: The Imports**

The bot uses standard Python libraries plus a few key packages: `requests` for API calls to Binance and Polymarket, `termcolor` for the colorful terminal display, and `dotenv` for loading your API keys securely from a `.env` file.

```python
#!/opt/anaconda3/envs/tflow/bin/python
"""
================================================================================
MOON DEV's EASY HYPER GAMBLER v1.0
================================================================================
The simplest way to bet on BTC 5-minute markets on Polymarket.

CONTROLS:
  B = Buy UP    (limit order on the bid - betting BTC goes up)
  S = Buy DOWN  (limit order on the bid - betting BTC goes down)
  X = Close position at market (sell into the bid to exit early)
  Hit B or S again to cancel and re-place your order (chase the price)

288 chances per day. Let's get it.
Built by Moon Dev
================================================================================
"""
import sys
import os
import select
import time
import random
import requests
from datetime import datetime, timedelta, timezone
from dotenv import load_dotenv
from termcolor import colored

# Auto re-exec with tflow python if we're in the wrong env
TFLOW_PYTHON = "/opt/anaconda3/envs/tflow/bin/python"
if os.path.exists(TFLOW_PYTHON) and sys.executable != TFLOW_PYTHON:
    os.execv(TFLOW_PYTHON, [TFLOW_PYTHON] + sys.argv)
```

The auto re-exec block at the bottom is a neat trick — if you accidentally run the script with the wrong Python environment, it automatically restarts itself using the correct conda environment. No more "module not found" errors because you forgot to `conda activate`.

---

## **Step 2: Path Setup & Helper Functions**

The bot imports helper functions from `nice_funcs.py` — a utility module that handles common Polymarket operations like canceling orders, calculating share quantities, fetching positions, and looking up token IDs.

```python
# PATH SETUP
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
load_dotenv(os.path.join(PROJECT_ROOT, '.env'))

sys.path.insert(0, os.path.join(PROJECT_ROOT, 'examples'))
from nice_funcs import (
    cancel_token_orders,
    calculate_shares,
    get_all_positions,
    get_token_id,
)
```

The `PROJECT_ROOT` trick walks up two directories from the script to find the project root where the `.env` file lives. This means the script works no matter which subdirectory you run it from.

---

## **Step 3: Configuration**

All the tunable parameters are at the top of the file. The two most important ones: `BET_SIZE_USD` controls how much you bet per trade, and `BID_DISCOUNT_PCT` controls how far below the current bid your limit order is placed.

```python
BET_SIZE_USD = 10.0              # How much per bet in USD
MARKET_DURATION = 300            # 5-minute markets (300 seconds)
BID_DISCOUNT_PCT = 10            # Bid X% under the current bid for a deal
ET = timezone(timedelta(hours=-5))

# Session tracking
SESSION_WINS = 0
SESSION_LOSSES = 0
SESSION_PNL = 0.0
SESSION_TRADES = 0
```

At 10% discount, if the best bid on an UP token is $0.50, the bot places your order at $0.45. You're saying "I'll buy, but only if the price dips to here first." This means you won't always get filled — but when you do, you're in at a better price.

The session tracking variables keep a running scoreboard of your wins, losses, and P&L. These reset every time you restart the bot.

---

## **Step 4: Placing Limit Orders on Polymarket**

This is the core order function. It connects to Polymarket's CLOB (Central Limit Order Book), signs your order with your wallet, and submits it. The function handles both buying and selling, for any token ID, at any price and size.

```python
def place_limit_order(token_id, side, price, size, neg_risk=False):
    """Place a limit order on Polymarket"""
    from py_clob_client.client import ClobClient
    from py_clob_client.clob_types import OrderArgs, PartialCreateOrderOptions, ApiCreds
    from py_clob_client.constants import POLYGON
    from web3 import Web3

    key = os.getenv("PRIVATE_KEY")
    browser_address = os.getenv("PUBLIC_KEY")
    api_key = os.getenv("API_KEY")
    api_secret = os.getenv("SECRET")
    passphrase = os.getenv("PASSPHRASE")

    if not key or not browser_address:
        print(colored("   Missing PRIVATE_KEY or PUBLIC_KEY in .env!", "red"))
        return {}

    try:
        browser_wallet = Web3.toChecksumAddress(browser_address)
    except AttributeError:
        browser_wallet = Web3.to_checksum_address(browser_address)

    client = ClobClient(
        host="https://clob.polymarket.com",
        key=key,
        chain_id=POLYGON,
        funder=browser_wallet,
        signature_type=1,
    )

    if api_key and api_secret and passphrase:
        creds = ApiCreds(api_key=api_key, api_secret=api_secret, api_passphrase=passphrase)
        client.set_api_creds(creds=creds)
    else:
        creds = client.create_or_derive_api_creds()
        client.set_api_creds(creds=creds)

    order_args = OrderArgs(
        token_id=str(token_id),
        price=price,
        size=size,
        side=side.upper(),
        fee_rate_bps=1000,
    )

    if neg_risk:
        signed_order = client.create_order(order_args, options=PartialCreateOrderOptions(neg_risk=True))
    else:
        signed_order = client.create_order(order_args)

    response = client.post_order(signed_order)
    return response if response else {}
```

A few things worth noting. The `signature_type=1` tells the CLOB client to use Polymarket's browser wallet signing scheme. The `funder` is your public address that holds USDC on Polygon. The `neg_risk` flag handles certain market types that use negative risk token pairs.

The `fee_rate_bps=1000` sets the fee rate to 10% (1000 basis points). This is the maximum fee — in practice, Polymarket charges less, but setting it high ensures your order always goes through.

---

## **Step 5: Market Discovery & Order Books**

Every 5 minutes a new market opens. The bot needs to find the right market, get the UP and DOWN token IDs, and fetch the order book to know where to place orders. Here's how it does that.

```python
def get_btc_price():
    """Get current BTC price from Binance"""
    resp = requests.get(
        "https://api.binance.com/api/v3/ticker/price",
        params={"symbol": "BTCUSDT"},
        timeout=5
    )
    if resp.status_code == 200:
        return float(resp.json()['price'])
    return None

def get_current_market_timestamp():
    now = int(time.time())
    return (now // MARKET_DURATION) * MARKET_DURATION

def get_time_remaining(market_ts):
    return MARKET_DURATION - (int(time.time()) - market_ts)
```

The market timestamp calculation is clever — it rounds the current Unix timestamp down to the nearest 300-second boundary. Every 5-minute market has a unique timestamp. For example, if it's 2:07 PM, the current market started at 2:05 PM (timestamp divisible by 300).

```python
def get_order_book(token_id):
    """Get best bid/ask from CLOB"""
    response = requests.get(
        "https://clob.polymarket.com/book",
        params={'token_id': token_id},
        timeout=10
    )
    if response.status_code != 200:
        return None

    data = response.json()
    bids = data.get('bids', [])
    asks = data.get('asks', [])

    if not bids or not asks:
        return None

    return {
        'best_bid': float(bids[-1]['price']),
        'best_ask': float(asks[0]['price']),
        'spread': float(asks[0]['price']) - float(bids[-1]['price']),
    }

def get_market_info(market_ts):
    """Find the 5-min BTC market"""
    market_slug = f"btc-updown-5m-{market_ts}"
    response = requests.get(
        "https://gamma-api.polymarket.com/markets",
        params={'slug': market_slug, 'closed': 'false', 'active': 'true'},
        timeout=10
    )
    if response.status_code != 200:
        return None

    markets = response.json()
    if not markets:
        return None

    market = markets[0]
    token_data = get_token_id(market['id'])
    if len(token_data) != 3:
        return None

    return {
        'market_id': market['id'],
        'up_token_id': token_data[1],
        'down_token_id': token_data[2],
        'question': market['question'],
        'slug': market_slug,
        'neg_risk': market.get('negRisk', False),
    }
```

The market slug format `btc-updown-5m-{timestamp}` is how Polymarket names their 5-minute BTC markets. The Gamma API is Polymarket's market discovery API — it returns the market ID, which the bot then uses to look up the specific token IDs for the UP and DOWN outcomes.

Each market has two tokens: one for UP and one for DOWN. The order book gives us the best bid (highest buy order) and best ask (lowest sell order) for each token. The spread tells us how liquid the market is.

---

## **Step 6: Position Checking**

After placing a limit order, the bot needs to know when it gets filled. It does this by checking your portfolio for shares of the token you ordered.

```python
def _get_portfolio_quiet():
    import io
    old_stdout = sys.stdout
    sys.stdout = io.StringIO()
    portfolio = get_all_positions()
    sys.stdout = old_stdout
    return portfolio

def check_position(token_id):
    """Check if we hold shares of this token and how many"""
    portfolio = _get_portfolio_quiet()
    if portfolio and 'positions' in portfolio:
        for pos in portfolio['positions']:
            if pos.get('asset_id') == token_id and pos.get('position_size', 0) > 0:
                return float(pos['position_size'])
    return 0.0
```

The `_get_portfolio_quiet` wrapper suppresses the print output from the `get_all_positions` helper. Since the bot redraws the screen every second, we don't want stray print statements messing up the display.

---

## **Step 7: The Terminal Dashboard**

The display is the fun part. The bot clears the screen every second and redraws a full dashboard with a countdown timer, order book prices, BTC price comparison, session stats, and a P&L box when you're in a position.

---

## **Step 8: The Live P&L Box**

When you're in a position, the dashboard switches to showing a real-time P&L box. It tracks your entry price, current bid, shares, and unrealized profit/loss — with dynamic vibe messages.

---

## **Step 9: The Main Loop**

The main loop ties everything together. It runs at 10Hz (every 0.1 seconds), checking for keyboard input, fetching fresh order books every 3 seconds, detecting new markets, and redrawing the display every second.

---

## **Step 10: Keyboard Controls**

The input handler reads single keypresses without requiring Enter. When you press B or S, it cancels any existing order, fetches the current order book, calculates a discounted bid price, and places a new limit order.

**Key Controls:**
- **B** = Buy UP (limit order on the bid)
- **S** = Buy DOWN (limit order on the bid)
- **X** = Close position at market
- **Q** = Quit

---

## **Prerequisites & Setup**

Before running this bot, you need a few things set up:

### **Required Setup**

1. **Polymarket Account** — You need a funded Polymarket account with USDC on Polygon
2. **Python Environment** — Python 3.10+ with conda
3. **Dependencies** — `pip install requests python-dotenv termcolor web3 py-clob-client`
4. **.env File** — Create with your Polymarket API credentials:
   ```
   PRIVATE_KEY=your_polymarket_private_key_here
   PUBLIC_KEY=your_polygon_wallet_address_here
   API_KEY=your_polymarket_api_key
   SECRET=your_polymarket_api_secret
   PASSPHRASE=your_polymarket_api_passphrase
   ```

### **Installation Steps**

1. Clone or create the project directory
2. Create a `.env` file with your credentials
3. Install Python dependencies
4. Place the `easy.py` script in your project
5. Run: `python easy.py`

---

## **Key Features Summary**

✅ **Real-time terminal dashboard** with countdown timer  
✅ **Limit orders at 10% discount** for better entries  
✅ **Per-market order book tracking**  
✅ **Live P&L display** with dynamic messages  
✅ **Session scoreboard** tracking wins/losses/PNL  
✅ **Keyboard controls** for instant order placement  
✅ **Market detection** - automatically finds new 5-min markets  
✅ **Position management** - track and close positions  

---

## **Tips for Success**

1. **Start small** — Begin with $10 bets while you learn
2. **Watch the spread** — Tight spreads = more liquidity = better fills
3. **Time your entry** — Press B/S when you see a good setup
4. **Chase the price** — Press B or S again if the market moved
5. **Exit early** — Press X if you're winning to lock in profit
6. **Be patient** — Not every 5-min window is tradeable

---

**Bot created by Moon Dev**  
**Version**: 1.0.0  
**Última actualización**: 15 de marzo de 2026
