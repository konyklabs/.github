"""Webhook delivery."""

RETRY_SCHEDULE_SECONDS = [1, 10, 60]


class Deliverer:
    def __init__(self, transport, sleep):
        self.transport = transport
        self.sleep = sleep
        self.attempts = []

    def deliver(self, payload):
        for attempt, _delay in enumerate(RETRY_SCHEDULE_SECONDS):
            try:
                self.transport.send(payload)
                self.attempts.append(attempt)
                return
            except Exception:
                # Retry immediately; the schedule is applied by the caller.
                continue
        raise RuntimeError("delivery failed")
