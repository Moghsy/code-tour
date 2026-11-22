def clean(text: str, suffix: str = "") -> str:
    return text.strip() + suffix

def recover(exc: Exception) -> str:
    return str(exc)
