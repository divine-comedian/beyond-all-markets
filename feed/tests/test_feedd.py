import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from feedd import bucket_trade, format_line, new_bucket


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
    assert format_line(b) == "mkt:1.2346:0.5000:117230.0"


def test_format_line_empty_bucket_keeps_last_price():
    b = new_bucket()
    b["price"] = 117000.0
    assert format_line(b) == "mkt:0.0000:0.0000:117000.0"
