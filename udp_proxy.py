#!/usr/bin/env python3
"""
Combined TCP-control + UDP-data proxy for testing iperf3 --data-integrity over
UDP.  iperf3 runs its control channel over TCP and its data flow over UDP on
the *same* port, so a transparent proxy has to relay both.

Usage: udp_proxy.py <listen_port> <server_host> <server_port> <rate> <mode>
  mode = corrupt : flip a payload byte in ~1/rate data datagrams
  mode = drop    : drop ~1/rate data datagrams

Both directions are mangled, so the proxy works for forward mode (client->server
data) and reverse mode (server->client data).  Only datagrams larger than 40
bytes are touched, leaving the small UDP handshake/ack datagrams intact.
"""

import socket
import sys
import random
import threading
import time


def main():
    if len(sys.argv) != 6:
        print(__doc__, file=sys.stderr)
        sys.exit(2)

    listen_port = int(sys.argv[1])
    server_host = sys.argv[2]
    server_port = int(sys.argv[3])
    rate = int(sys.argv[4])
    mode = sys.argv[5]
    if mode not in ("corrupt", "drop"):
        print(f"unknown mode {mode!r}", file=sys.stderr)
        sys.exit(2)

    state = {"client": None}

    # --- TCP control channel: relay verbatim in both directions ---
    def tcp_relay(src, dst):
        try:
            while True:
                data = src.recv(65536)
                if not data:
                    break
                dst.sendall(data)
        except OSError:
            pass
        finally:
            for s in (src, dst):
                try:
                    s.close()
                except OSError:
                    pass

    def tcp_server():
        ts = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        ts.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        ts.bind(("127.0.0.1", listen_port))
        ts.listen(5)
        while True:
            try:
                client_sock, _ = ts.accept()
            except OSError:
                break
            try:
                up = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                up.connect((server_host, server_port))
            except OSError:
                client_sock.close()
                continue
            threading.Thread(target=tcp_relay, args=(client_sock, up), daemon=True).start()
            threading.Thread(target=tcp_relay, args=(up, client_sock), daemon=True).start()

    # --- UDP data flow: corrupt or drop ~1/rate data-sized datagrams ---
    down = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    down.bind(("127.0.0.1", listen_port))   # faces the client
    up = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)  # faces the server

    def mangle(data):
        """Return possibly-corrupted bytes, or None to drop the datagram."""
        if len(data) > 40 and random.randint(1, rate) == 1:
            if mode == "drop":
                return None
            buf = bytearray(data)
            buf[30] ^= 0xFF   # flip a payload byte, well past the header
            return bytes(buf)
        return data

    def client_to_server():
        while True:
            try:
                data, addr = down.recvfrom(65536)
            except OSError:
                break
            state["client"] = addr
            out = mangle(data)
            if out is not None:
                up.sendto(out, (server_host, server_port))

    def server_to_client():
        while True:
            try:
                data, _ = up.recvfrom(65536)
            except OSError:
                break
            out = mangle(data)
            if out is not None and state["client"] is not None:
                down.sendto(out, state["client"])

    threading.Thread(target=tcp_server, daemon=True).start()
    threading.Thread(target=client_to_server, daemon=True).start()
    threading.Thread(target=server_to_client, daemon=True).start()

    while True:
        time.sleep(1)


if __name__ == "__main__":
    main()
