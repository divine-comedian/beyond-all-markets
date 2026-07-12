import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from feedd import (
    MARKETS,
    TradeThrottle,
    bucket_trade,
    coinbase_is_buyer_maker,
    format_line,
    format_line_legacy,
    format_trade,
    format_trade_legacy,
    hl_is_buyer_maker,
    mid_price,
    new_bucket,
    new_buckets,
    route_binance,
    route_hyperliquid,
)


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
    bucket_trade(b, False, 1.23456, 117234.56)
    bucket_trade(b, True, 0.5, 117230.00)
    assert format_line("BTC", b) == "mkt:BTC:1.2346:0.5000:117230.00"


def test_format_line_empty_bucket_keeps_last_price():
    b = new_bucket()
    b["price"] = 4100.0
    assert format_line("GOLD", b) == "mkt:GOLD:0.0000:0.0000:4100.00"


def test_format_trade_v2_buy_and_sell():
    assert format_trade("BTC", is_buyer_maker=False, qty=0.5123, price=64000.12, venue="BN") \
        == "trd:BTC:B:0.5123:64000.12:BN"
    assert format_trade("SPX", is_buyer_maker=True, qty=100, price=650.25, venue="AP") \
        == "trd:SPX:S:100.0000:650.25:AP"


def test_legacy_lines_match_v1_format():
    # MW v5's gadget regexes: ^mkt:([%d%.]+):... and ^trd:([BS]):...
    b = new_bucket()
    bucket_trade(b, False, 1.0, 64000.0)
    assert format_line_legacy(b) == "mkt:1.0000:0.0000:64000.00"
    assert format_trade_legacy(False, 0.5, 64000.0, "BN") == "trd:B:0.5000:64000.00:BN"
    # v2 lines must NOT match the v1 numeric regex (market tag is alphabetic)
    assert format_line("BTC", b).split(":")[1] == "BTC"


def test_new_buckets_covers_all_markets():
    bs = new_buckets()
    assert set(bs.keys()) == set(MARKETS) == {"BTC", "GOLD", "SPX"}


def test_route_binance_aggtrade_to_right_market():
    bs = new_buckets()
    hit = route_binance(
        {"stream": "paxgusdt@aggTrade", "data": {"m": False, "q": "0.30", "p": "4100.5"}}, bs)
    assert hit == ("GOLD", False, 0.30, 4100.5)
    assert bs["GOLD"]["buy"] == 0.30 and bs["BTC"]["buy"] == 0.0


def test_route_binance_bookticker_sets_mid_price_only():
    bs = new_buckets()
    hit = route_binance(
        {"stream": "btcusdt@bookTicker", "data": {"b": "64000.0", "a": "64001.0"}}, bs)
    assert hit is None
    assert bs["BTC"]["price"] == 64000.5
    assert bs["BTC"]["buy"] == 0.0 and bs["BTC"]["sell"] == 0.0


def test_route_binance_ignores_unknown_stream():
    bs = new_buckets()
    assert route_binance({"stream": "ethusdt@aggTrade", "data": {"m": True, "q": "1", "p": "1"}}, bs) is None


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
