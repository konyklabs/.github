# payments-mock

## Idempotency

A request carrying an `Idempotency-Key` is deduplicated for **24 hours**. A
replay inside that window returns the original response without creating a
second payment. Consumers may safely retry for a full day after a network
failure.
