import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from feedd import (
    TradeThrottle,
    bucket_trade,
    coinbase_is_buyer_maker,
    format_line,
    format_trade,
    mid_price,
    new_bucket,
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


def test_format_line_wire_format():
    b = new_bucket()
    bucket_trade(b, False, 1.23456, 117234.56)
    bucket_trade(b, True, 0.5, 117230.00)
    assert format_line(b) == "mkt:1.2346:0.5000:117230.00"


def test_format_line_empty_bucket_keeps_last_price():
    b = new_bucket()
    b["price"] = 117000.0
    assert format_line(b) == "mkt:0.0000:0.0000:117000.00"


def test_format_trade_buy_and_sell():
    assert format_trade(is_buyer_maker=False, qty=0.5123, price=64000.12) == "trd:B:0.5123:64000.12"
    assert format_trade(is_buyer_maker=True, qty=0.01, price=64000.0) == "trd:S:0.0100:64000.00"


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
