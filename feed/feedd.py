#!/usr/bin/env python3
"""Binance aggTrade -> per-second buy/sell volume buckets -> TCP line broadcast.

Wire format (one line per second to every connected client):
    mkt:<buyVolBTC>:<sellVolBTC>:<price>
"""
import argparse
import asyncio
import json
import math
import random

BINANCE_TRADES = "wss://stream.binance.com:9443/ws/btcusdt@aggTrade"
BINANCE_BOOK = "wss://stream.binance.com:9443/ws/btcusdt@bookTicker"
COINBASE_WS = "wss://ws-feed.exchange.coinbase.com"


def coinbase_is_buyer_maker(side):
    # Coinbase 'side' is the maker order side: maker sell => taker bought
    return side == "buy"


def mid_price(bid, ask):
    return (bid + ask) / 2


def new_bucket():
    return {"buy": 0.0, "sell": 0.0, "price": 0.0}


def bucket_trade(bucket, is_buyer_maker, qty, price):
    if is_buyer_maker:
        bucket["sell"] += qty   # buyer was maker => taker sold
    else:
        bucket["buy"] += qty    # buyer was taker => aggressive buy
    bucket["price"] = price


def format_line(bucket):
    return f"mkt:{bucket['buy']:.4f}:{bucket['sell']:.4f}:{bucket['price']:.2f}"


def format_trade(is_buyer_maker, qty, price):
    side = "S" if is_buyer_maker else "B"
    return f"trd:{side}:{qty:.4f}:{price:.2f}"


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


async def binance_trades(bucket, bc, throttle):
    import time
    import websockets

    async def run():
        async with websockets.connect(BINANCE_TRADES, ping_interval=20) as ws:
            print("binance trade stream connected", flush=True)
            async for raw in ws:
                t = json.loads(raw)
                m, q, p = t["m"], float(t["q"]), float(t["p"])
                bucket_trade(bucket, m, q, p)
                if throttle.allow(q, time.time()):
                    bc.send(format_trade(m, q, p))

    await _reconnecting("binance-trades", run)


async def binance_book(bucket):
    import websockets

    async def run():
        async with websockets.connect(BINANCE_BOOK, ping_interval=20) as ws:
            print("binance book stream connected", flush=True)
            async for raw in ws:
                t = json.loads(raw)
                # continuous mid-price so tradeless seconds still tick
                bucket["price"] = mid_price(float(t["b"]), float(t["a"]))

    await _reconnecting("binance-book", run)


async def coinbase_trades(bucket, bc, throttle):
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
                px0 = bucket["price"]
                bucket_trade(bucket, m, q, p)
                if px0:
                    bucket["price"] = px0   # binance_book owns price continuity
                if throttle.allow(q, time.time()):
                    bc.send(format_trade(m, q, p))

    await _reconnecting("coinbase-trades", run)


async def synthetic_trades(bucket, bc, throttle):
    import time
    price = 117000.0
    while True:
        price *= math.exp(random.gauss(0, 0.0002))
        for _ in range(random.randint(1, 8)):
            m, q = random.random() < 0.5, random.expovariate(8)
            bucket_trade(bucket, m, q, price)
            if throttle.allow(q, time.time()):
                bc.send(format_trade(m, q, price))
        await asyncio.sleep(0.2)


async def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, default=8642)
    ap.add_argument("--synthetic", action="store_true",
                    help="random-walk feed instead of Binance (offline dev)")
    args = ap.parse_args()
    bucket = new_bucket()
    bc = Broadcaster()
    await asyncio.start_server(bc.handle, "127.0.0.1", args.port)
    throttle = TradeThrottle()
    if args.synthetic:
        asyncio.create_task(synthetic_trades(bucket, bc, throttle))
    else:
        asyncio.create_task(binance_trades(bucket, bc, throttle))
        asyncio.create_task(coinbase_trades(bucket, bc, throttle))
        asyncio.create_task(binance_book(bucket))
    print(f"feedd on 127.0.0.1:{args.port} synthetic={args.synthetic}", flush=True)
    while True:
        await asyncio.sleep(1)
        bc.send(format_line(bucket))
        bucket["buy"] = bucket["sell"] = 0.0   # keep last price


if __name__ == "__main__":
    asyncio.run(main())
