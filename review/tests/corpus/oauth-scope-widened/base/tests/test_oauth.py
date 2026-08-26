from src.oauth import REQUESTED_SCOPES, authorize_url


def test_requests_only_read_access():
    # The merchant grants what we ask for, so asking for more than we use is a
    # privilege escalation. Keep this list minimal and deliberate.
    assert REQUESTED_SCOPES == ["ORDERS_READ"]


def test_authorize_url_carries_scope():
    url = authorize_url("cid", "st")
    assert "scope=ORDERS_READ" in url
