#!/usr/bin/env python3
"""Multi-market trade feeds -> per-second buy/sell volume buckets -> TCP broadcast.

Markets:
    BTC  — Binance btcusdt aggTrades + Coinbase matches (price: Binance book)
    SPX  — Hyperliquid xyz:SP500 perp (TradeXYZ, S&P-DJI licensed), 24/7
    GOLD — Hyperliquid xyz:GOLD perp (COMEX-benchmarked) owns the price;
           Binance paxgusdt (PAX Gold, oz-denominated) folds in extra volume

Hyperliquid WS is public/keyless and trades carry the aggressor side
("B" = taker bought, "A" = taker sold) — verified live 2026-07-12:
xyz:SP500 did ~$105k notional / 45s on a SUNDAY.

Wire format v2 (one line per market per second to every connected client):
    mkt:<MKT>:<buyVol>:<sellVol>:<price>      MKT in {BTC, GOLD, SPX}
    trd:<MKT>:<B|S>:<qty>:<price>:<venue>

Legacy v1 lines (mkt:<buy>:<sell>:<price> / trd:<B|S>:...) are still emitted
for BTC while --legacy is on (default), so a feedd restart can't starve a
running MW v5 game. The v5 gadget ignores v2 lines (regex mismatch) and a
future v6 gadget ignores v1 — dual emission is safe in both directions.
"""
import argparse
import asyncio
import json
import math
import random

BINANCE_COMBINED = ("wss://stream.binance.com:9443/stream?streams="
                    "btcusdt@aggTrade/paxgusdt@aggTrade/"
                    "btcusdt@bookTicker/paxgusdt@bookTicker")
COINBASE_WS = "wss://ws-feed.exchange.coinbase.com"
HYPERLIQUID_WS = "wss://api.hyperliquid.xyz/ws"

MARKETS = ("BTC", "GOLD", "SPX")
BINANCE_SYMBOL_MKT = {"btcusdt": "BTC", "paxgusdt": "GOLD"}
HL_COIN_MKT = {"xyz:SP500": "SPX", "xyz:GOLD": "GOLD"}
HL_PRICE_OWNER = {"SPX": True, "GOLD": True}   # Hyperliquid owns these prices


def coinbase_is_buyer_maker(side):
    # Coinbase 'side' is the maker order side: maker sell => taker bought
    return side == "buy"


def mid_price(bid, ask):
    return (bid + ask) / 2


def new_bucket():
    return {"buy": 0.0, "sell": 0.0, "price": 0.0}


def new_buckets():
    return {m: new_bucket() for m in MARKETS}


def bucket_trade(bucket, is_buyer_maker, qty, price):
    if is_buyer_maker:
        bucket["sell"] += qty   # buyer was maker => taker sold
    else:
        bucket["buy"] += qty    # buyer was taker => aggressive buy
    bucket["price"] = price


def format_line(mkt, bucket):
    return f"mkt:{mkt}:{bucket['buy']:.4f}:{bucket['sell']:.4f}:{bucket['price']:.2f}"


def format_trade(mkt, is_buyer_maker, qty, price, venue="BN"):
    side = "S" if is_buyer_maker else "B"
    return f"trd:{mkt}:{side}:{qty:.4f}:{price:.2f}:{venue}"


def format_line_legacy(bucket):
    return f"mkt:{bucket['buy']:.4f}:{bucket['sell']:.4f}:{bucket['price']:.2f}"


def format_trade_legacy(is_buyer_maker, qty, price, venue="BN"):
    side = "S" if is_buyer_maker else "B"
    return f"trd:{side}:{qty:.4f}:{price:.2f}:{venue}"


def route_binance(frame, buckets):
    """Route one combined-stream frame into the right market bucket.

    Returns (mkt, is_buyer_maker, qty, price) for aggTrades, None otherwise.
    GOLD nuance: Hyperliquid's COMEX-benchmarked perp owns the gold price;
    PAXG (a different instrument, same oz unit) contributes volume only, so
    its trades and book never overwrite an established gold price.
    """
    stream = frame.get("stream", "")
    data = frame.get("data", {})
    symbol = stream.split("@")[0]
    mkt = BINANCE_SYMBOL_MKT.get(symbol)
    if not mkt:
        return None
    price_owner = mkt not in HL_PRICE_OWNER
    if stream.endswith("@aggTrade"):
        m, q, p = data["m"], float(data["q"]), float(data["p"])
        px0 = buckets[mkt]["price"]
        bucket_trade(buckets[mkt], m, q, p)
        if not price_owner and px0:
            buckets[mkt]["price"] = px0
        return (mkt, m, q, p)
    if stream.endswith("@bookTicker") and price_owner:
        # continuous mid-price so tradeless seconds still tick
        buckets[mkt]["price"] = mid_price(float(data["b"]), float(data["a"]))
    return None


def hl_is_buyer_maker(side):
    # Hyperliquid trade 'side' is the AGGRESSOR side: "B" = taker bought,
    # "A" = taker sold (verified against live tape 2026-07-12)
    return side == "A"


def route_hyperliquid(msg, buckets):
    """Route one Hyperliquid ws message; returns [(mkt, m, qty, price), ...]."""
    if msg.get("channel") != "trades":
        return []
    out = []
    for t in msg.get("data", []):
        mkt = HL_COIN_MKT.get(t.get("coin"))
        if not mkt:
            continue
        m, q, p = hl_is_buyer_maker(t["side"]), float(t["sz"]), float(t["px"])
        bucket_trade(buckets[mkt], m, q, p)
        out.append((mkt, m, q, p))
    return out


class TradeThrottle:
    """Cap relayed trades per wall-second; big prints always pass."""

    def __init__(self, per_sec=8, big=0.05):
        self.per_sec = per_sec
        self.big = big
        self.window = -1
        self.count = 0

    def allow(self, qty, now):
        w = int(now)
        if w != self.window:
            self.window, self.count = w, 0
        if qty >= self.big or self.count < self.per_sec:
            self.count += 1
            return True
        return False


class Broadcaster:
    def __init__(self):
        self.clients = set()

    async def handle(self, reader, writer):
        peer = writer.get_extra_info("peername")
        print(f"client connected: {peer}", flush=True)
        self.clients.add(writer)
        try:
            await reader.read()          # block until client disconnects
        finally:
            self.clients.discard(writer)
            writer.close()
            print(f"client gone: {peer}", flush=True)

    def send(self, line):
        dead = set()
        for w in self.clients:
            try:
                w.write((line + "\n").encode())
            except Exception:
                dead.add(w)
        self.clients -= dead


async def _reconnecting(name, coro):
    while True:
        try:
            await coro()
        except Exception as e:
            print(f"{name} reconnect: {e}", flush=True)
            await asyncio.sleep(3)


def _emit_trade(bc, mkt, m, q, p, venue, legacy):
    bc.send(format_trade(mkt, m, q, p, venue))
    if legacy and mkt == "BTC":
        bc.send(format_trade_legacy(m, q, p, venue))


async def binance_combined(buckets, bc, throttle, legacy):
    import time
    import websockets

    async def run():
        async with websockets.connect(BINANCE_COMBINED, ping_interval=20) as ws:
            print("binance combined stream connected", flush=True)
            async for raw in ws:
                hit = route_binance(json.loads(raw), buckets)
                if hit:
                    mkt, m, q, p = hit
                    if throttle.allow(q, time.time()):
                        _emit_trade(bc, mkt, m, q, p, "BN", legacy)

    await _reconnecting("binance-combined", run)


async def coinbase_trades(buckets, bc, throttle, legacy):
    import time
    import websockets

    async def run():
        async with websockets.connect(COINBASE_WS, ping_interval=20) as ws:
            await ws.send(json.dumps({
                "type": "subscribe",
                "product_ids": ["BTC-USD"],
                "channels": ["matches"],
            }))
            print("coinbase match stream connected", flush=True)
            async for raw in ws:
                t = json.loads(raw)
                if t.get("type") not in ("match", "last_match"):
                    continue
                m = coinbase_is_buyer_maker(t["side"])
                q, p = float(t["size"]), float(t["price"])
                px0 = buckets["BTC"]["price"]
                bucket_trade(buckets["BTC"], m, q, p)
                if px0:
                    buckets["BTC"]["price"] = px0   # binance book owns price continuity
                if throttle.allow(q, time.time()):
                    _emit_trade(bc, "BTC", m, q, p, "CB", legacy)

    await _reconnecting("coinbase-trades", run)


async def hyperliquid_trades(buckets, bc, throttle):
    import time
    import websockets

    async def run():
        async with websockets.connect(HYPERLIQUID_WS, ping_interval=20) as ws:
            for coin in HL_COIN_MKT:
                await ws.send(json.dumps({"method": "subscribe",
                                          "subscription": {"type": "trades", "coin": coin}}))
            print("hyperliquid trade stream connected (" + ", ".join(HL_COIN_MKT) + ")", flush=True)
            async for raw in ws:
                for mkt, m, q, p in route_hyperliquid(json.loads(raw), buckets):
                    if throttle.allow(q, time.time()):
                        bc.send(format_trade(mkt, m, q, p, "HL"))

    await _reconnecting("hyperliquid-trades", run)


SYN_START = {"BTC": 64000.0, "GOLD": 4100.0, "SPX": 6500.0}
SYN_RATE = {"BTC": 8, "GOLD": 20, "SPX": 0.02}   # expovariate lambda per market


async def synthetic_trades(buckets, bc, throttle, legacy):
    import time
    price = dict(SYN_START)
    while True:
        for mkt in MARKETS:
            price[mkt] *= math.exp(random.gauss(0, 0.0002))
            for _ in range(random.randint(0, 3)):
                m, q = random.random() < 0.5, random.expovariate(SYN_RATE[mkt])
                bucket_trade(buckets[mkt], m, q, price[mkt])
                if throttle.allow(q, time.time()):
                    _emit_trade(bc, mkt, m, q, price[mkt], "SYN", legacy)
        await asyncio.sleep(0.2)


async def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8642)
    ap.add_argument("--synthetic", action="store_true",
                    help="random-walk feeds instead of live sources (offline dev)")
    ap.add_argument("--no-legacy", dest="legacy", action="store_false",
                    help="stop emitting v1 BTC lines (once MW v6 is live)")
    args = ap.parse_args()
    buckets = new_buckets()
    bc = Broadcaster()
    await asyncio.start_server(bc.handle, "127.0.0.1", args.port)
    throttle = TradeThrottle()
    if args.synthetic:
        asyncio.create_task(synthetic_trades(buckets, bc, throttle, args.legacy))
    else:
        asyncio.create_task(binance_combined(buckets, bc, throttle, args.legacy))
        asyncio.create_task(coinbase_trades(buckets, bc, throttle, args.legacy))
        asyncio.create_task(hyperliquid_trades(buckets, bc, throttle))
    print(f"feedd on 127.0.0.1:{args.port} synthetic={args.synthetic} legacy={args.legacy}", flush=True)
    while True:
        await asyncio.sleep(1)
        for mkt in MARKETS:
            bc.send(format_line(mkt, buckets[mkt]))
        if args.legacy:
            bc.send(format_line_legacy(buckets["BTC"]))
        for b in buckets.values():
            b["buy"] = b["sell"] = 0.0   # keep last price


if __name__ == "__main__":
    asyncio.run(main())
