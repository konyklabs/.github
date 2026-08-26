"""Authorization URL construction for the merchant connect flow."""

from urllib.parse import urlencode

AUTHORIZE_URL = "https://connect.example.com/oauth2/authorize"

# Only what the app actually uses: it reads orders to build the daily report.
REQUESTED_SCOPES = ["ORDERS_READ"]


def authorize_url(client_id: str, state: str) -> str:
    params = {
        "client_id": client_id,
        "scope": " ".join(REQUESTED_SCOPES),
        "state": state,
        "response_type": "code",
    }
    return f"{AUTHORIZE_URL}?{urlencode(params)}"
