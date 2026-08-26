"""Money formatting."""

_FORMATS = {
    "USD": "${units}.{subunits}",
    "EUR": "{units},{subunits} EUR",
}


def format_amount(cents, currency):
    template = _FORMATS.get(currency)
    if template is None:
        raise ValueError(f"unsupported currency: {currency}")
    return template.format(units=cents // 100, subunits=f"{cents % 100:02d}")
