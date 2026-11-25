#!/usr/bin/env python3
"""Drive the QEMU serial console for the ZIGNOS install test.

Usage:
  serial_test.py install [serial_port]
  serial_test.py verify  [serial_port]

The script keeps raw output on stdout (so it can be tee'd) and matches on
ANSI-stripped text.
"""
import os
import re
import socket
import sys
import time

PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 5555
ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07]*\x07|\r")


class Serial:
    def __init__(self, port):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=15)
        self.sock.settimeout(0.5)
        self.raw = b""
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
            self.raw += chunk
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            self.text += ANSI.sub(b"", chunk).decode("utf-8", "replace")
            if len(self.text) > 200000:
                self.text = self.text[-100000:]

    def wait_for(self, needle, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if needle in self.text:
                return True
            self.drain(0.5)
        return needle in self.text

    def wait_any(self, needles, timeout):
        end = time.time() + timeout
        while time.time() < end:
            for needle in needles:
                if needle in self.text:
                    return needle
            self.drain(0.5)
        for needle in needles:
            if needle in self.text:
                return needle
        return None

    def send(self, line):
        self.text = ""
        self.sock.sendall(line.encode() + b"\r")
        time.sleep(0.5)
        self.drain(0.5)


def install(ser):
    print("\n=== waiting for the live root shell ===", file=sys.stderr)
    if not ser.wait_for("root@zignos-live", 180):
        print("live root prompt not found", file=sys.stderr)
        return 1
    ser.send("lsblk -dn -o NAME,SIZE,TYPE")
    ser.drain(3)
    ser.send("echo SERIAL-LIVE-READY")
    if not ser.wait_for("SERIAL-LIVE-READY", 20):
        return 1
    firmware = os.environ.get("TEST_FIRMWARE", "uefi")
    disk = os.environ.get("TEST_DISK", "/dev/sda")
    cmd = (
        "ZIGNOS_FIRMWARE=%s ZIGNOS_HOSTNAME=zignostest ZIGNOS_USER=test "
        "ZIGNOS_PASSWORD=testpass ZIGNOS_LOCALE=en_US.UTF-8 "
        "ZIGNOS_KEYMAP=us ZIGNOS_TIMEZONE=UTC "
        "/usr/sbin/zignos-installer --auto %s" % (firmware, disk)
    )
    ser.send(cmd)
    print("\n=== installing (this takes several minutes) ===", file=sys.stderr)
    result = ser.wait_any(
        ["ZIGNOS-INSTALL-COMPLETE", "zignos-installer: installation complete", "root@zignos-live"], 2400
    )
    if result != "ZIGNOS-INSTALL-COMPLETE":
        print("\ninstall did not complete (%r)" % result, file=sys.stderr)
        ser.drain(20)
        return 1
    ser.drain(5)
    print("\n=== install complete ===", file=sys.stderr)
    return 0


def verify(ser):
    print("\n=== waiting for the installed-system login ===", file=sys.stderr)
    if not ser.wait_for("login:", 240):
        print("login prompt not found", file=sys.stderr)
        return 1
    ser.send("test")
    if not ser.wait_for("assword:", 30):
        print("password prompt not found", file=sys.stderr)
        return 1
    ser.send("testpass")
    if not ser.wait_for("test@zignostest", 60):
        print("user shell not found", file=sys.stderr)
        return 1
    ser.send("echo SERIAL-LOGIN-OK")
    if not ser.wait_for("SERIAL-LOGIN-OK", 30):
        return 1
    ser.send("doas id")
    if ser.wait_for("assword:", 20):
        ser.send("testpass")
        if not ser.wait_for("uid=0", 30):
            print("doas did not grant root", file=sys.stderr)
            return 1
    commands = (
        "hostname; id; "
        "grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' /etc/os-release; "
        "findmnt -no SOURCE /; "
        "cat /etc/fstab; "
        "ls /boot/efi/EFI/BOOT 2>/dev/null; "
        "ls /home; "
        "ps -ef | grep -E 'sddm|kwin_wayland' | grep -v grep | head -3; "
        "echo SERIAL-VERIFY-DONE"
    )
    ser.send(commands)
    if not ser.wait_for("SERIAL-VERIFY-DONE", 120):
        print("verify marker not found", file=sys.stderr)
        return 1
    ser.drain(3)
    return 0


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("install", "verify"):
        print(__doc__, file=sys.stderr)
        return 2
    ser = Serial(PORT)
    try:
        if sys.argv[1] == "install":
            return install(ser)
        return verify(ser)
    finally:
        ser.sock.close()


if __name__ == "__main__":
    sys.exit(main())
