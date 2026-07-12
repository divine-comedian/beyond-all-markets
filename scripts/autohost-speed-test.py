#!/usr/bin/env python3
"""Spike experiment: bind autohost UDP port before engine start, send speed
commands after game start, measure sim fps from infolog."""
import os
import re
import socket
import subprocess
import time

DATA = os.path.join(os.path.dirname(__file__), "..", "data")
ENGINE = os.path.join(os.path.dirname(__file__), "..", "engine", "spring-headless")
os.chdir(DATA)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", 8453))
s.settimeout(300)
eng = subprocess.Popen([ENGINE, "--write-dir", os.getcwd(), "script.txt"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
data, addr = s.recvfrom(4096)
print("first event from", addr, "bytes:", data[:30], flush=True)


def lastframe():
    try:
        log = open("infolog.txt", "rb").read().decode("utf-8", "replace")
    except FileNotFoundError:
        return -1
    m = re.findall(r"\[f=(\d+)\]", log)
    return int(m[-1]) if m else -1


while lastframe() < 0:
    time.sleep(3)
print("game started; sending speed commands", flush=True)
for cmd in ["/setminspeed 1", "/setmaxspeed 1"]:
    s.sendto(cmd.encode(), addr)
    time.sleep(0.5)

f0, t0 = lastframe(), time.time()
time.sleep(90)
f1, dt = lastframe(), time.time() - t0
print(f"frames: {f0} -> {f1} in {dt:.0f}s = {(f1 - f0) / dt:.1f} fps", flush=True)

# drain any autohost events received meanwhile
s.settimeout(0.5)
try:
    while True:
        data, _ = s.recvfrom(4096)
        print("event:", data[:60], flush=True)
except socket.timeout:
    pass
eng.terminate()
