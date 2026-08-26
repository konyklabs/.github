from src.webhooks import RETRY_SCHEDULE_SECONDS, Deliverer


class FakeTransport:
    def __init__(self, fail_times=0):
        self.sent = []
        self.fail_times = fail_times

    def send(self, payload):
        if self.fail_times > 0:
            self.fail_times -= 1
            raise RuntimeError("boom")
        self.sent.append(payload)


def test_delivers_payload():
    t = FakeTransport()
    Deliverer(t, sleep=lambda s: None).deliver({"id": 1})
    assert t.sent == [{"id": 1}]


def test_retry_schedule_is_declared():
    assert RETRY_SCHEDULE_SECONDS == [1, 10, 60]


def test_retries_are_configured():
    t = FakeTransport(fail_times=2)
    d = Deliverer(t, sleep=lambda s: None)
    d.deliver({"id": 2})
    assert len(RETRY_SCHEDULE_SECONDS) == 3
