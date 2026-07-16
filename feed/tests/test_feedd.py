import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from feedd import (
    BINANCE_COMBINED,
    BINANCE_US_COMBINED,
    MARKETS,
    PRICE_OWNER,
    TradeThrottle,
    apply_trade,
    binance_url,
    bucket_trade,
    coinbase_is_buyer_maker,
    format_bam,
    format_line,
    format_trade,
    hl_is_buyer_maker,
    is_geoblock,
    mid_price,
    new_bucket,
    new_buckets,
    route_binance,
    route_bybit,
    route_coinbase,
    route_hyperliquid,
    route_pumpdev,
)

import feedd


def test_taker_buy_goes_to_buy_volume():
    b = new_bucket()
    # Binance aggTrade: m=False means the buyer is the taker (aggressive buy)
    bucket_trade(b, is_buyer_maker=False, qty=0.5, price=117000.0)
    assert b["buy"] == 0.5 and b["sell"] == 0.0


def test_taker_sell_goes_to_sell_volume():
    b = new_bucket()
    bucket_trade(b, is_buyer_maker=True, qty=0.25, price=117000.0)
    assert b["sell"] == 0.25 and b["buy"] == 0.0


def test_format_line_v2_wire_format():
    b = new_bucket()
    bucket_trade(b, False, 1.23456, 182.34)
    bucket_trade(b, True, 0.5, 182.10)
    assert format_line("SOL", b) == "mkt:SOL:1.2346:0.5000:182.10"


def test_format_line_empty_bucket_keeps_last_price():
    b = new_bucket()
    b["price"] = 4100.0
    assert format_line("GOLD", b) == "mkt:GOLD:0.0000:0.0000:4100.00"


def test_format_trade_v2_buy_and_sell():
    assert format_trade("SOL", is_buyer_maker=False, qty=0.5123, price=64000.12, venue="BN") \
        == "trd:SOL:B:0.5123:64000.12:BN"
    assert format_trade("SPX", is_buyer_maker=True, qty=100, price=650.25, venue="AP") \
        == "trd:SPX:S:100.0000:650.25:AP"


def test_new_buckets_covers_all_markets():
    bs = new_buckets()
    assert set(bs.keys()) == set(MARKETS) == {"SOL", "SPX", "GOLD", "BAM"}


def test_route_binance_aggtrade_to_right_market():
    bs = new_buckets()
    hit = route_binance(
        {"stream": "paxgusdt@aggTrade", "data": {"m": False, "q": "0.30", "p": "4100.5"}}, bs)
    assert hit == ("GOLD", False, 0.30, 4100.5)
    assert bs["GOLD"]["buy"] == 0.30 and bs["SOL"]["buy"] == 0.0


def test_route_binance_sol_bootstraps_then_yields_price_to_coinbase():
    # Binance is a volume-only secondary for SOL now. It seeds the price while
    # the bucket is empty (so the lane isn't dead on a 451), but once Coinbase
    # (the owner) has priced it, Binance folds volume without moving it.
    bs = new_buckets()
    hit = route_binance(
        {"stream": "solusdt@aggTrade", "data": {"m": False, "q": "3.0", "p": "182.5"}}, bs)
    assert hit == ("SOL", False, 3.0, 182.5)
    assert bs["SOL"]["buy"] == 3.0 and bs["SOL"]["price"] == 182.5    # bootstrap seed
    route_coinbase(
        {"type": "match", "product_id": "SOL-USD", "side": "sell", "size": "1.0", "price": "183.0"}, bs)
    assert bs["SOL"]["price"] == 183.0                                # Coinbase owns it
    route_binance(
        {"stream": "solusdt@aggTrade", "data": {"m": True, "q": "5.0", "p": "181.0"}}, bs)
    assert bs["SOL"]["price"] == 183.0                                # Binance can't move it
    assert bs["SOL"]["buy"] == 4.0 and bs["SOL"]["sell"] == 5.0       # but volume still counts
    # bookTicker only bootstraps a still-empty lane, never overrides a priced one
    assert route_binance(
        {"stream": "solusdt@bookTicker", "data": {"b": "182.0", "a": "182.2"}}, bs) is None
    assert bs["SOL"]["price"] == 183.0


def test_route_binance_ignores_unknown_stream():
    bs = new_buckets()
    assert route_binance({"stream": "dogeusdt@aggTrade", "data": {"m": True, "q": "1", "p": "1"}}, bs) is None


def test_paxg_never_overwrites_hyperliquid_gold_price():
    # Hyperliquid's COMEX-benchmarked perp owns the gold price; PAXG (a
    # different instrument) folds in volume only once a price is established.
    bs = new_buckets()
    route_hyperliquid({"channel": "trades", "data": [
        {"coin": "xyz:GOLD", "side": "A", "px": "4103.2", "sz": "2.4"}]}, bs)
    route_binance({"stream": "paxgusdt@aggTrade", "data": {"m": False, "q": "0.30", "p": "4094.0"}}, bs)
    route_binance({"stream": "paxgusdt@bookTicker", "data": {"b": "4093.0", "a": "4095.0"}}, bs)
    assert bs["GOLD"]["price"] == 4103.2          # HL price preserved
    assert bs["GOLD"]["sell"] == 2.4 and bs["GOLD"]["buy"] == 0.30   # both volumes count


def test_paxg_seeds_gold_price_before_hyperliquid_ticks():
    bs = new_buckets()
    route_binance({"stream": "paxgusdt@aggTrade", "data": {"m": True, "q": "0.10", "p": "4094.0"}}, bs)
    assert bs["GOLD"]["price"] == 4094.0


def test_hl_side_semantics():
    # Hyperliquid 'side' is the aggressor: B = taker bought, A = taker sold
    assert hl_is_buyer_maker("B") is False
    assert hl_is_buyer_maker("A") is True


def test_route_hyperliquid_maps_coins_and_ignores_others():
    bs = new_buckets()
    hits = route_hyperliquid({"channel": "trades", "data": [
        {"coin": "xyz:SP500", "side": "B", "px": "7562.8", "sz": "0.006"},
        {"coin": "xyz:NVDA", "side": "B", "px": "190.0", "sz": "1.0"},
    ]}, bs)
    assert hits == [("SPX", False, 0.006, 7562.8)]
    assert bs["SPX"]["buy"] == 0.006 and bs["SPX"]["price"] == 7562.8


def test_route_hyperliquid_ignores_non_trade_channels():
    bs = new_buckets()
    assert route_hyperliquid({"channel": "subscriptionResponse", "data": {}}, bs) == []


def test_bybit_spyx_normalizes_share_units_to_index_contracts():
    # SPYX trades in ETF-share units (~$745); the SPX bucket is denominated in
    # SP500 index-contract units (~$7563). 10 shares ~ 0.985 contracts.
    bs = new_buckets()
    route_hyperliquid({"channel": "trades", "data": [
        {"coin": "xyz:SP500", "side": "B", "px": "7563.0", "sz": "0.5"}]}, bs)
    hits = route_bybit({"topic": "publicTrade.SPYXUSDT", "data": [
        {"S": "Buy", "v": "10", "p": "745.0"}]}, bs)
    assert len(hits) == 1
    mkt, m, eq, p = hits[0]
    assert mkt == "SPX" and m is False
    assert abs(eq - 10 * 745.0 / 7563.0) < 1e-9
    assert bs["SPX"]["price"] == 7563.0            # HL keeps the price
    assert abs(bs["SPX"]["buy"] - (0.5 + eq)) < 1e-9


def test_bybit_xaut_counts_oz_without_rescale_and_taker_side():
    bs = new_buckets()
    route_hyperliquid({"channel": "trades", "data": [
        {"coin": "xyz:GOLD", "side": "B", "px": "4100.0", "sz": "1.0"}]}, bs)
    hits = route_bybit({"topic": "publicTrade.XAUTUSDT", "data": [
        {"S": "Sell", "v": "2.5", "p": "4095.0"}]}, bs)
    assert hits == [("GOLD", True, 2.5, 4095.0)]
    assert bs["GOLD"]["sell"] == 2.5               # oz units, no rescale
    assert bs["GOLD"]["price"] == 4100.0           # HL keeps the price


def test_bybit_ignores_unknown_topics():
    bs = new_buckets()
    assert route_bybit({"topic": "publicTrade.DOGEUSDT", "data": [{"S": "Buy", "v": "1", "p": "1"}]}, bs) == []
    assert route_bybit({"topic": "orderbook.SPYXUSDT", "data": []}, bs) == []


def test_throttle_caps_small_trades_per_second():
    t = TradeThrottle(per_sec=3, big=0.05)
    allowed = [t.allow(0.01, now=100.0) for _ in range(5)]
    assert allowed == [True, True, True, False, False]


def test_throttle_always_allows_big_trades():
    t = TradeThrottle(per_sec=1, big=0.05)
    assert t.allow(0.01, now=100.0)
    assert not t.allow(0.01, now=100.5)
    assert t.allow(0.30, now=100.6)      # big print bypasses the cap


def test_throttle_resets_each_second():
    t = TradeThrottle(per_sec=1, big=0.05)
    assert t.allow(0.01, now=100.0)
    assert not t.allow(0.01, now=100.9)
    assert t.allow(0.01, now=101.0)


def test_coinbase_side_is_maker_side():
    # Coinbase match 'side' is the MAKER order side: a "sell"-side match means
    # the taker aggressively BOUGHT (is_buyer_maker=False), and vice versa.
    assert coinbase_is_buyer_maker("sell") is False
    assert coinbase_is_buyer_maker("buy") is True


def test_coinbase_taker_buy_feeds_buy_volume():
    b = new_bucket()
    bucket_trade(b, coinbase_is_buyer_maker("sell"), qty=0.2, price=64000.0)
    assert b["buy"] == 0.2 and b["sell"] == 0.0


def test_mid_price():
    assert mid_price(64000.0, 64001.0) == 64000.5


def test_route_coinbase_paxg_folds_gold_volume_preserving_hl_price():
    # Coinbase PAXG is a secondary GOLD venue: it adds volume but never overwrites
    # the Hyperliquid gold price.
    bs = new_buckets()
    route_hyperliquid({"channel": "trades", "data": [
        {"coin": "xyz:GOLD", "side": "A", "px": "4103.2", "sz": "2.4"}]}, bs)
    hit = route_coinbase(
        {"type": "match", "product_id": "PAXG-USD", "side": "sell",
         "size": "0.30", "price": "4094.0"}, bs)
    assert hit == ("GOLD", False, 0.30, 4094.0)      # maker sell => taker bought
    assert bs["GOLD"]["price"] == 4103.2             # HL price preserved
    assert bs["GOLD"]["buy"] == 0.30 and bs["GOLD"]["sell"] == 2.4


def test_route_coinbase_owns_sol_price_over_binance():
    # SOL is Coinbase-owned now (binance.com 451s from cloud IPs, which used to
    # freeze SOL). Coinbase sets the price; Binance only folds volume.
    bs = new_buckets()
    route_binance({"stream": "solusdt@aggTrade", "data": {"m": False, "q": "2.0", "p": "182.0"}}, bs)
    hit = route_coinbase(
        {"type": "match", "product_id": "SOL-USD", "side": "sell",
         "size": "1.5", "price": "183.4"}, bs)
    assert hit == ("SOL", False, 1.5, 183.4)     # maker sell => taker bought
    assert bs["SOL"]["price"] == 183.4           # Coinbase moved it off the Binance seed
    assert bs["SOL"]["buy"] == 3.5               # 2.0 (BN) + 1.5 (CB) both count


def test_binance_url_fails_over_to_binance_us_on_geoblock():
    assert binance_url(geoblocked=False) == BINANCE_COMBINED
    assert "binance.com" in binance_url(False)
    assert binance_url(geoblocked=True) == BINANCE_US_COMBINED
    assert "binance.us" in binance_url(True) and "solusdt" in binance_url(True)


def test_is_geoblock_detects_http_451():
    assert is_geoblock(Exception("server rejected WebSocket connection: HTTP 451"))
    assert not is_geoblock(Exception("server rejected WebSocket connection: HTTP 429"))

    class Resp:
        status_code = 451

    class Rejected(Exception):
        response = Resp()

    assert is_geoblock(Rejected("rejected"))


def test_price_owner_map_covers_every_market():
    assert set(PRICE_OWNER) == set(MARKETS)
    assert PRICE_OWNER["SOL"] == "CB"
    assert PRICE_OWNER["GOLD"] == "HL" and PRICE_OWNER["SPX"] == "HL"
    assert PRICE_OWNER["BAM"] == "PD"


def test_apply_trade_bootstraps_price_but_secondary_cannot_override():
    b = new_bucket()
    apply_trade(b, "SOL", "BN", is_buyer_maker=False, qty=1.0, price=182.0)  # secondary seeds 0-price
    assert b["price"] == 182.0
    apply_trade(b, "SOL", "BN", is_buyer_maker=False, qty=1.0, price=181.0)  # secondary can't move it
    assert b["price"] == 182.0 and b["buy"] == 2.0
    apply_trade(b, "SOL", "CB", is_buyer_maker=True, qty=1.0, price=184.0)   # owner moves it
    assert b["price"] == 184.0


def test_route_coinbase_ignores_unknown_product_and_non_match():
    bs = new_buckets()
    assert route_coinbase({"type": "match", "product_id": "DOGE-USD",
                           "side": "buy", "size": "1", "price": "1"}, bs) is None
    assert route_coinbase({"type": "heartbeat"}, bs) is None


def test_route_pumpdev_buy_folds_solnotional_and_marketcap_price():
    bs = new_buckets()
    seen = set()
    feedd.BAM_MINT = "BAMmintpump"
    hit = route_pumpdev({
        "txType": "buy", "mint": "BAMmintpump", "solAmount": 1.485,
        "tokenAmount": 39873287.0, "marketCapSol": 38.88,
        "traderPublicKey": "EXHzrCmF62gmus8", "signature": "4mwNN2zdSIG"}, bs, seen)
    assert hit == (False, 1.485, 38.88, "EXHzrCmF", "4mwNN2zd")   # buy => taker bought
    assert bs["BAM"]["buy"] == 1.485 and bs["BAM"]["price"] == 38.88


def test_route_pumpdev_sell_and_signature_dedupe():
    bs = new_buckets()
    seen = set()
    feedd.BAM_MINT = "BAMmintpump"
    msg = {"txType": "sell", "mint": "BAMmintpump", "solAmount": 3.11,
           "marketCapSol": 32.7, "traderPublicKey": "FaJxvj5rCHhm6",
           "signature": "5ff6dhBtSIG"}
    first = route_pumpdev(msg, bs, seen)
    assert first == (True, 3.11, 32.7, "FaJxvj5r", "5ff6dhBt")    # sell => taker sold
    assert bs["BAM"]["sell"] == 3.11
    assert route_pumpdev(msg, bs, seen) is None                  # dup signature dropped
    assert bs["BAM"]["sell"] == 3.11


def test_route_pumpdev_filters_foreign_mint_and_non_trades():
    bs = new_buckets()
    seen = set()
    feedd.BAM_MINT = "BAMmintpump"
    assert route_pumpdev({"txType": "buy", "mint": "OTHERpump", "solAmount": 1.0,
                          "marketCapSol": 5.0, "signature": "x"}, bs, seen) is None
    assert route_pumpdev({"txType": "create", "mint": "BAMmintpump",
                          "signature": "y"}, bs, seen) is None


def test_route_pumpdev_proxy_mode_accepts_any_mint():
    bs = new_buckets()
    seen = set()
    feedd.BAM_MINT = ""     # proxy: no mint filter
    hit = route_pumpdev({"txType": "buy", "mint": "whatever", "solAmount": 0.4,
                         "marketCapSol": 28.0, "traderPublicKey": "J6THBML",
                         "signature": "z1"}, bs, seen)
    assert hit == (False, 0.4, 28.0, "J6THBML", "z1")


def test_format_bam_line():
    assert format_bam(False, 1.485, 38.88, "EXHzrCmF", "4mwNN2zd") \
        == "bam:B:1.4850:38.8800:EXHzrCmF:4mwNN2zd"
    assert format_bam(True, 3.11, 32.7, "FaJxvj5r", "5ff6dhBt") \
        == "bam:S:3.1100:32.7000:FaJxvj5r:5ff6dhBt"
