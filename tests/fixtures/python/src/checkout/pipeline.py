import asyncio as background
import requests as client
from requests import post as send
from . import clean as normalize
from .words import recover

class Base:
    def decorate(self, value):
        return f"[{value}]"

class Output(Base):
    def __init__(self, value):
        self.value = value

    def format_payload(self):
        return super().decorate(self.value)

def handle(value: str):
    def fallback(exc):
        return recover(exc)

    output = Output(normalize(value, suffix="!"))
    try:
        return output.format_payload()
    except ValueError as exc:
        return fallback(exc)

def dynamic(value):
    return value.format_payload()

def shadow(normalize):
    return normalize("unknown")

async def job():
    client.post("https://example.invalid")

def schedule():
    return background.create_task(job())

def report():
    send("https://example.invalid")

@router.get("/view")
def view():
    return handle("hello")

if __name__ == "__main__":
    handle("hello")
