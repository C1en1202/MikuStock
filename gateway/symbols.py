"""Exchange routing for the mainland A-share boards."""

import re


def parse_symbol(value):
    match = re.fullmatch(r"(sh|sz|bj)?([0-9]{6})(?:\.(sh|sz|bj))?", value.strip().lower())
    if not match:
        return None
    prefix, code, suffix = match.groups()
    if code.startswith(("60", "688", "689")):
        exchange = "sh"
    elif code.startswith(("00", "30")):
        exchange = "sz"
    elif code.startswith(("920", "43", "44", "83", "87", "88")):
        exchange = "bj"
    else:
        return None
    if prefix not in (None, exchange) or suffix not in (None, exchange):
        return None
    return exchange + code


def catalog_group(symbol):
    if symbol.startswith("sh"):
        return "sh_star" if symbol[2:].startswith("68") else "sh_main"
    return symbol[:2]
