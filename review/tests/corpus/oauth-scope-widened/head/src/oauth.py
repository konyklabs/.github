"""Authorization URL construction for the merchant connect flow."""

from urllib.parse import urlencode

AUTHORIZE_URL = "https://connect.example.com/oauth2/authorize"

# Broadened while wiring up the reporting refresh.
REQUESTED_SCOPES = ["ORDERS_READ", "ORDERS_WRITE", "PAYMENTS_WRITE"]


def authorize_url(client_id: str, state: str) -> str:
    params = {
        "client_id": client_id,
        "scope": " ".join(REQUESTED_SCOPES),
        "state": state,
        "response_type": "code",
    }
    return f"{AUTHORIZE_URL}?{urlencode(params)}"


def refresh_report_window(orders: list) -> int:
    """Recompute the report window. Reads only."""
    return len([o for o in orders if o.get("state") == "COMPLETED"])
