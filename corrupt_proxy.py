#!/usr/bin/env python3
"""
TCP proxy that randomly corrupts data stream bytes for testing
iperf3 --data-integrity feature.

Usage: python3 corrupt_proxy.py <listen_port> <server_host> <server_port> [corruption_rate]

The proxy forwards all TCP connections from listen_port to server_host:server_port.
The first connection is treated as the control channel (forwarded verbatim).
Subsequent connections are data streams where bytes are randomly corrupted.
corruption_rate = corrupt approximately 1 in N bytes (default: 500).
"""

import socket
import threading
import random
import sys

COOKIE_SIZE = 37  # iperf3 stream-setup cookie (must not be corrupted)

def relay(src, dst, corrupt=False, rate=500, skip=0):
    """Relay data from src to dst, optionally corrupting bytes.

    The first `skip` bytes are always forwarded verbatim: each iperf3 data
    connection begins with the client sending a COOKIE_SIZE-byte cookie, and
    corrupting it makes the server reject the stream, deadlocking the test
    instead of exercising payload validation.
    """
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            if corrupt:
                data = bytearray(data)
                start = 0
                if skip > 0:
                    start = min(skip, len(data))
                    skip -= start
                for i in range(start, len(data)):
                    if random.randint(1, rate) == 1:
                        data[i] ^= random.randint(1, 255)
                data = bytes(data)
            dst.sendall(data)
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        try:
            src.close()
        except OSError:
            pass
        try:
            dst.close()
        except OSError:
            pass

def handle_connection(client_sock, server_host, server_port, conn_num, rate):
    """Handle a single proxied connection."""
    try:
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.connect((server_host, server_port))
    except OSError as e:
        print(f"Proxy: failed to connect to {server_host}:{server_port}: {e}", file=sys.stderr)
        client_sock.close()
        return

    # First connection is control, don't corrupt it.
    # Subsequent connections are data streams -- corrupt client->server direction.
    is_data = conn_num > 1

    # client -> server: corrupt data streams, but never the setup cookie
    t1 = threading.Thread(target=relay,
                          args=(client_sock, server_sock, is_data, rate, COOKIE_SIZE))
    # server -> client: also corrupt data streams (for reverse mode)
    t2 = threading.Thread(target=relay, args=(server_sock, client_sock, is_data, rate))
    t1.daemon = True
    t2.daemon = True
    t1.start()
    t2.start()
    t1.join()
    t2.join()

def main():
    if len(sys.argv) < 4:
        print(f"Usage: {sys.argv[0]} <listen_port> <server_host> <server_port> [corruption_rate]",
              file=sys.stderr)
        sys.exit(1)

    listen_port = int(sys.argv[1])
    server_host = sys.argv[2]
    server_port = int(sys.argv[3])
    rate = int(sys.argv[4]) if len(sys.argv) > 4 else 500

    connection_count = 0
    lock = threading.Lock()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(('127.0.0.1', listen_port))
    listener.listen(10)

    # Write PID so the test script can kill us
    print(f"Proxy listening on 127.0.0.1:{listen_port}, forwarding to {server_host}:{server_port}, "
          f"corruption rate 1/{rate}", file=sys.stderr)

    try:
        while True:
            client_sock, addr = listener.accept()
            with lock:
                connection_count += 1
                conn_num = connection_count
            t = threading.Thread(target=handle_connection,
                                 args=(client_sock, server_host, server_port, conn_num, rate))
            t.daemon = True
            t.start()
    except KeyboardInterrupt:
        pass
    finally:
        listener.close()

if __name__ == '__main__':
    main()
