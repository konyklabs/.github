"""Order handlers."""

ROUTES = {}


def route(path, guards=()):
    def register(fn):
        ROUTES[path] = {"handler": fn, "guards": list(guards)}
        return fn
    return register


@route("/v2/orders")
def list_orders(request):
    return {"orders": []}
