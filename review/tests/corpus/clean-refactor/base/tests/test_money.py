import pytest

from src.money import format_amount


def test_usd():
    assert format_amount(1234, "USD") == "$12.34"


def test_usd_pads_cents():
    assert format_amount(1205, "USD") == "$12.05"


def test_eur():
    assert format_amount(1234, "EUR") == "12,34 EUR"


def test_unsupported():
    with pytest.raises(ValueError):
        format_amount(1, "GBP")
