"""Order handlers."""

ROUTES = {}


def route(path, guards=()):
    def register(fn):
        ROUTES[path] = {"handler": fn, "guards": list(guards)}
        return fn
    return register


def require_merchant_token(request):
    """Reject any request without a merchant token."""
    token = request.get("headers", {}).get("authorization")
    if not token or not token.startswith("Bearer "):
        raise PermissionError("missing merchant token")
    return True


@route("/v2/orders", guards=("require_merchant_token",))
def list_orders(request):
    return {"orders": []}
