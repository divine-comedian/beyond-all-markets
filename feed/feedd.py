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

WS_URL = "wss://stream.binance.com:9443/ws/btcusdt@aggTrade"


def new_bucket():
    return {"buy": 0.0, "sell": 0.0, "price": 0.0}


def bucket_trade(bucket, is_buyer_maker, qty, price):
    if is_buyer_maker:
        bucket["sell"] += qty   # buyer was maker => taker sold
    else:
        bucket["buy"] += qty    # buyer was taker => aggressive buy
    bucket["price"] = price


def format_line(bucket):
    return f"mkt:{bucket['buy']:.4f}:{bucket['sell']:.4f}:{bucket['price']:.1f}"


def format_trade(is_buyer_maker, qty, price):
    side = "S" if is_buyer_maker else "B"
    return f"trd:{side}:{qty:.4f}:{price:.1f}"


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


async def binance_trades(bucket, bc):
    import time
    import websockets
    throttle = TradeThrottle()
    while True:
        try:
            async with websockets.connect(WS_URL, ping_interval=20) as ws:
                print("binance stream connected", flush=True)
                async for raw in ws:
                    t = json.loads(raw)
                    m, q, p = t["m"], float(t["q"]), float(t["p"])
                    bucket_trade(bucket, m, q, p)
                    if throttle.allow(q, time.time()):
                        bc.send(format_trade(m, q, p))
        except Exception as e:
            print(f"ws reconnect: {e}", flush=True)
            await asyncio.sleep(3)


async def synthetic_trades(bucket, bc):
    import time
    throttle = TradeThrottle()
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
    asyncio.create_task(synthetic_trades(bucket, bc) if args.synthetic else binance_trades(bucket, bc))
    print(f"feedd on 127.0.0.1:{args.port} synthetic={args.synthetic}", flush=True)
    while True:
        await asyncio.sleep(1)
        bc.send(format_line(bucket))
        bucket["buy"] = bucket["sell"] = 0.0   # keep last price


if __name__ == "__main__":
    asyncio.run(main())
