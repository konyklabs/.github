from src.webhooks import Deliverer


class FakeTransport:
    def __init__(self):
        self.sent = []

    def send(self, payload):
        self.sent.append(payload)


def test_delivers_payload():
    t = FakeTransport()
    Deliverer(t).deliver({"id": 1})
    assert t.sent == [{"id": 1}]
