"""Money formatting."""


def format_amount(cents, currency):
    if currency == "USD":
        return "$" + str(cents // 100) + "." + str(cents % 100).zfill(2)
    if currency == "EUR":
        return str(cents // 100) + "," + str(cents % 100).zfill(2) + " EUR"
    raise ValueError("unsupported currency: " + currency)
