from src.handlers import ROUTES


def test_orders_route_registered():
    assert "/v2/orders" in ROUTES


def test_orders_route_declares_auth_guard():
    # Contract: every merchant-scoped route declares the token guard.
    assert "require_merchant_token" in ROUTES["/v2/orders"]["guards"]
