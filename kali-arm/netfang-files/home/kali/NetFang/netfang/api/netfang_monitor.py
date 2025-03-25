#!/usr/bin/env python3
import os
import subprocess
import time

# Assuming udev_receiver.py remains in the same directory as this script.
MONITOR_DIR = os.path.dirname(os.path.abspath(__file__))
UDEV_RECEIVER_PATH = os.path.join(MONITOR_DIR, "udev_receiver.py")

# Adjust INTERFACE as needed (e.g., "eth0" for Raspberry Pi Zero 2 W)
INTERFACE = "eth0"

def get_operstate(interface):
    try:
        with open(f"/sys/class/net/{interface}/operstate", "r") as f:
            return f.read().strip()
    except Exception:
        return None

def call_receiver(event, interface):
    print(f"Triggering event '{event}' for interface '{interface}'")
    subprocess.run(["/usr/bin/python3", UDEV_RECEIVER_PATH, event, interface])

def monitor():
    last_state = "down"
    while True:
        state = get_operstate(INTERFACE)
        if state is None:
            last_state = "down"
            call_receiver("down", INTERFACE)
        else:
            if state != last_state:
                if state == "up":
                    call_receiver("connected", INTERFACE)
                elif state == "down":
                    call_receiver("disconnected", INTERFACE)
                last_state = state
        time.sleep(1)

if __name__ == "__main__":
    monitor()
