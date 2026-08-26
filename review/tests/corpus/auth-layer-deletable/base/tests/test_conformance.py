from src.handlers import ROUTES


def test_orders_route_registered():
    assert "/v2/orders" in ROUTES
