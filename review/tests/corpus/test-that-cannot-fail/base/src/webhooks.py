"""Webhook delivery."""

RETRY_SCHEDULE_SECONDS = [1, 10, 60]


class Deliverer:
    def __init__(self, transport):
        self.transport = transport
        self.attempts = []

    def deliver(self, payload):
        self.transport.send(payload)
        self.attempts.append(0)
