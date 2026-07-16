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
    format_line,
    format_line_legacy,
    format_trade,
    format_trade_legacy,
    hl_is_buyer_maker,
    is_geoblock,
    mid_price,
    new_bucket,
    new_buckets,
    route_binance,
    route_bybit,
    route_coinbase,
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
    assert set(bs.keys()) == set(MARKETS) == {"BTC", "ETH", "GOLD", "SPX"}


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
    assert route_binance({"stream": "dogeusdt@aggTrade", "data": {"m": True, "q": "1", "p": "1"}}, bs) is None


def test_route_binance_eth_bootstraps_then_yields_price_to_coinbase():
    # Binance is a volume-only secondary for ETH now. It seeds the price while
    # the bucket is empty (so the lane isn't dead), but once Coinbase (the
    # owner) has set a price, Binance folds volume without moving it.
    bs = new_buckets()
    hit = route_binance({"stream": "ethusdt@aggTrade", "data": {"m": False, "q": "2.0", "p": "3201.5"}}, bs)
    assert hit == ("ETH", False, 2.0, 3201.5)
    assert bs["ETH"]["buy"] == 2.0 and bs["ETH"]["price"] == 3201.5   # bootstrap seed
    route_coinbase({"type": "match", "product_id": "ETH-USD", "side": "buy", "size": "1.0", "price": "3210.0"}, bs)
    assert bs["ETH"]["price"] == 3210.0                                # Coinbase owns it (taker sold => sell)
    route_binance({"stream": "ethusdt@aggTrade", "data": {"m": True, "q": "5.0", "p": "3190.0"}}, bs)
    assert bs["ETH"]["price"] == 3210.0                                # Binance can't move it
    assert bs["ETH"]["buy"] == 2.0 and bs["ETH"]["sell"] == 6.0        # but volume still counts (1.0 + 5.0)


def test_coinbase_routes_eth_and_btc_by_product_id():
    bs = new_buckets()
    assert route_coinbase(
        {"type": "match", "product_id": "ETH-USD", "side": "sell", "size": "3.0", "price": "3200.0"}, bs) \
        == ("ETH", False, 3.0, 3200.0)
    assert route_coinbase(
        {"type": "match", "product_id": "BTC-USD", "side": "buy", "size": "0.4", "price": "64000.0"}, bs) \
        == ("BTC", True, 0.4, 64000.0)
    assert bs["ETH"]["buy"] == 3.0 and bs["ETH"]["price"] == 3200.0    # ETH is alive on Coinbase
    assert bs["BTC"]["sell"] == 0.4 and bs["BTC"]["price"] == 64000.0


def test_coinbase_owns_btc_price_over_binance():
    # The old bug: Binance owned BTC and Coinbase couldn't move it, so a 451
    # froze BTC. Now Coinbase owns BTC; Binance only folds volume.
    bs = new_buckets()
    route_coinbase({"type": "match", "product_id": "BTC-USD", "side": "buy", "size": "0.1", "price": "64500.0"}, bs)
    route_binance({"stream": "btcusdt@aggTrade", "data": {"m": False, "q": "0.2", "p": "64000.0"}}, bs)
    route_binance({"stream": "btcusdt@bookTicker", "data": {"b": "63900.0", "a": "63901.0"}}, bs)
    assert bs["BTC"]["price"] == 64500.0                               # Coinbase price preserved
    assert bs["BTC"]["buy"] == 0.2 and bs["BTC"]["sell"] == 0.1        # both venues' volume


def test_coinbase_ignores_unknown_product_and_non_matches():
    bs = new_buckets()
    assert route_coinbase({"type": "subscriptions", "channels": []}, bs) is None
    assert route_coinbase({"type": "match", "product_id": "DOGE-USD", "side": "buy", "size": "1", "price": "1"}, bs) is None


def test_binance_url_fails_over_to_binance_us_on_geoblock():
    assert binance_url(geoblocked=False) == BINANCE_COMBINED
    assert "binance.com" in binance_url(False)
    assert binance_url(geoblocked=True) == BINANCE_US_COMBINED
    assert "binance.us" in binance_url(True)


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
    assert PRICE_OWNER["BTC"] == "CB" and PRICE_OWNER["ETH"] == "CB"
    assert PRICE_OWNER["GOLD"] == "HL" and PRICE_OWNER["SPX"] == "HL"


def test_apply_trade_bootstraps_price_but_secondary_cannot_override():
    b = new_bucket()
    apply_trade(b, "BTC", "BN", is_buyer_maker=False, qty=0.1, price=64000.0)  # secondary seeds 0-price
    assert b["price"] == 64000.0
    apply_trade(b, "BTC", "BN", is_buyer_maker=False, qty=0.1, price=64010.0)  # secondary can't move it
    assert b["price"] == 64000.0 and b["buy"] == 0.2
    apply_trade(b, "BTC", "CB", is_buyer_maker=True, qty=0.1, price=64100.0)   # owner moves it
    assert b["price"] == 64100.0


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
