#!/usr/bin/env python3
"""End-to-end whiptail TUI install test over the QEMU serial console.

Run after booting the Live ISO with a blank target disk and a serial TCP
chardev on 127.0.0.1:5555. Fills in the TUI menus, waits for the
"Installation complete." msgbox, then the installed target can be checked
with live_serial_test.py verify.
"""

import re
import socket
import sys
import time

ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")


class Serial:
    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", 5555), timeout=15)
        self.sock.settimeout(0.5)
        self.text = ""

    def drain(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            try:
                chunk = self.sock.recv(8192)
            except socket.timeout:
                continue
            if not chunk:
                break
            self.text += ANSI.sub(b"", chunk).decode("utf-8", "replace")
            if len(self.text) > 300000:
                self.text = self.text[-150000:]

    def wait(self, needle, timeout=120):
        end = time.time() + timeout
        while time.time() < end:
            if needle in self.text:
                return True
            self.drain(0.5)
        return needle in self.text

    def send(self, data, enter=True):
        self.text = ""
        self.sock.sendall(data.encode() + (b"\r" if enter else b""))
        time.sleep(0.6)
        self.drain(0.6)

    def key(self, data):
        self.text = ""
        self.sock.sendall(data)
        time.sleep(0.6)
        self.drain(0.6)


def main():
    s = Serial()
    print("waiting for live shell", file=sys.stderr)
    if not s.wait("root@zignos-live", 180):
        print("no live shell", file=sys.stderr)
        return 1
    s.send("TERM=linux /usr/sbin/zignos-installer")

    steps = [
        ("Select the disk to install ZIGNOS on.", "disk menu", b"\r"),
        ("Firmware mode for the installed system", "firmware menu", b"\r"),
        ("Hostname for the new system", "hostname", None),
        ("Username for the new account", "username", None),
        ("Password for test", "password", None),
        ("Repeat the password", "password repeat", None),
        ("Timezone:", "timezone", b"\r"),
        ("System language / locale", "locale", b"\r"),
        ("Console keymap", "keymap", b"\r"),
        ("ALL DATA ON /dev/sda WILL BE DESTROYED", "summary", b"\r"),
    ]
    for needle, name, action in steps:
        if not s.wait(needle, 60):
            print("missing %s (%r)" % (name, needle), file=sys.stderr)
            return 1
        print("ok:", name, file=sys.stderr)
        if name == "hostname":
            s.key(b"\x7f" * 8)
            s.send("zignostest")
        elif name == "username":
            s.key(b"\x7f" * 8)
            s.send("test")
        elif name == "password":
            s.send("testpass")
        elif name == "password repeat":
            s.send("testpass")
        else:
            s.key(action)

    print("waiting for installation", file=sys.stderr)
    if not s.wait("Installation complete.", 2400):
        print("TUI did not report completion", file=sys.stderr)
        s.drain(20)
        return 1
    print("INSTALL COMPLETE", file=sys.stderr)
    s.key(b"\r")
    s.drain(3)
    return 0


if __name__ == "__main__":
    sys.exit(main())
