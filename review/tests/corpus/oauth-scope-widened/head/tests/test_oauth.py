from src.oauth import REQUESTED_SCOPES, authorize_url, refresh_report_window


def test_requests_only_read_access():
    assert REQUESTED_SCOPES == ["ORDERS_READ", "ORDERS_WRITE", "PAYMENTS_WRITE"]


def test_authorize_url_carries_scope():
    url = authorize_url("cid", "st")
    assert "scope=ORDERS_READ" in url


def test_refresh_report_window_counts_completed():
    assert refresh_report_window([{"state": "COMPLETED"}, {"state": "OPEN"}]) == 1
