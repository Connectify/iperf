#!/bin/bash
#
# Test data integrity validation feature (--data-integrity).
# Verifies that:
#   1. Corruption injected by a proxy is detected (non-zero exit + error message)
#   2. A clean run succeeds with no errors
#   3. Incompatible options (--data-integrity + --skip-rx-copy) are rejected
#   4. The flag does not persist across server resets
#   5/6. The client exits nonzero when either side detects TCP corruption
#   7. (UDP) packet loss is NOT reported as a data integrity error
#   8. (UDP) payload corruption is counted and reported, but is not fatal
#
# Tests 1-6 exercise TCP (reliable stream -> corruption aborts the test).
# Tests 7-8 exercise UDP, where loss/reorder are expected and validation is
# per-datagram: anomalies are counted and reported, never aborted.
#

set -u

IPERF3=./src/iperf3
PROXY=./corrupt_proxy.py
UDP_PROXY=./udp_proxy.py
SERVER_PORT=5301
PROXY_PORT=5302
RESULT=0
SERVER_PID=""
PROXY_PID=""

cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    [ -n "$PROXY_PID" ] && kill "$PROXY_PID" 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

wait_for_listener() {
    # Use lsof to check if the port is being listened on, avoiding consuming the connection.
    local port=$1
    local tries=0
    while ! lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ $tries -ge 30 ]; then
            echo "FAIL: port $port did not become available"
            return 1
        fi
        sleep 0.2
    done
    return 0
}

echo "=== Test 1: Corruption detected through proxy (reverse mode) ==="
# Use -R (reverse mode) so the SERVER sends and the CLIENT receives.
# The proxy corrupts server->client data. The client detects the integrity error.
$IPERF3 -s -p $SERVER_PORT -1 >/dev/null 2>&1 &
SERVER_PID=$!
wait_for_listener $SERVER_PORT || { RESULT=1; exit 1; }

python3 $PROXY $PROXY_PORT 127.0.0.1 $SERVER_PORT 500 >/dev/null 2>&1 &
PROXY_PID=$!
wait_for_listener $PROXY_PORT || { RESULT=1; exit 1; }

OUTPUT=$($IPERF3 -c 127.0.0.1 -p $PROXY_PORT --data-integrity -R -t 5 2>&1)
CLIENT_RC=$?

# Clean up this test's processes
kill "$PROXY_PID" 2>/dev/null
PROXY_PID=""
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

if echo "$OUTPUT" | grep -q "DATA INTEGRITY ERROR"; then
    echo "PASS: corruption detected as expected"
elif [ $CLIENT_RC -ne 0 ]; then
    echo "PASS: client exited with error (rc=$CLIENT_RC)"
else
    echo "FAIL: client exited with 0 and no integrity error detected"
    echo "Output: $OUTPUT"
    RESULT=1
fi

echo ""
echo "=== Test 2: Clean run succeeds (no proxy) ==="
SERVER_PORT=5303
$IPERF3 -s -p $SERVER_PORT -1 >/dev/null 2>&1 &
SERVER_PID=$!
wait_for_listener $SERVER_PORT || { RESULT=1; exit 1; }

OUTPUT=$($IPERF3 -c 127.0.0.1 -p $SERVER_PORT --data-integrity -t 2 2>&1)
CLIENT_RC=$?

wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

if [ $CLIENT_RC -ne 0 ]; then
    echo "FAIL: direct test failed (expected success, got rc=$CLIENT_RC)"
    echo "Output: $OUTPUT"
    RESULT=1
else
    echo "PASS: direct test succeeded (no corruption)"
fi

echo ""
echo "=== Test 3: Incompatible options rejected ==="
OUTPUT=$($IPERF3 -c 127.0.0.1 --data-integrity --skip-rx-copy 2>&1)
CLIENT_RC=$?

if [ $CLIENT_RC -ne 0 ]; then
    echo "PASS: incompatible options correctly rejected (rc=$CLIENT_RC)"
else
    echo "FAIL: incompatible options were not rejected"
    RESULT=1
fi

echo ""
echo "=== Test 4: data_integrity flag does not persist across server resets ==="
SERVER_PORT=5304
$IPERF3 -s -p $SERVER_PORT >/dev/null 2>&1 &
SERVER_PID=$!
wait_for_listener $SERVER_PORT || { RESULT=1; exit 1; }

# First client: WITH --data-integrity
OUTPUT=$($IPERF3 -c 127.0.0.1 -p $SERVER_PORT --data-integrity -t 2 2>&1)
CLIENT_RC=$?
if [ $CLIENT_RC -ne 0 ]; then
    echo "FAIL: first client (with --data-integrity) failed unexpectedly (rc=$CLIENT_RC)"
    echo "Output: $OUTPUT"
    kill "$SERVER_PID" 2>/dev/null
    SERVER_PID=""
    RESULT=1
else
    # Second client: WITHOUT --data-integrity
    # If the bug is present, the server still has data_integrity=1 and will
    # try to verify integrity on normal (non-integrity) data, causing errors.
    OUTPUT=$($IPERF3 -c 127.0.0.1 -p $SERVER_PORT -t 2 2>&1)
    CLIENT_RC=$?

    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
    SERVER_PID=""

    if [ $CLIENT_RC -ne 0 ]; then
        echo "FAIL: second client (without --data-integrity) failed (rc=$CLIENT_RC)"
        echo "Output: $OUTPUT"
        RESULT=1
    elif echo "$OUTPUT" | grep -q "DATA INTEGRITY ERROR"; then
        echo "FAIL: data_integrity flag leaked from first test to second test"
        echo "Output: $OUTPUT"
        RESULT=1
    else
        echo "PASS: second client succeeded without data integrity errors"
    fi
fi

echo ""
echo "=== Test 5: Client exits nonzero when client detects integrity error ==="
SERVER_PORT=5305
$IPERF3 -s -p $SERVER_PORT -1 >/dev/null 2>&1 &
SERVER_PID=$!
wait_for_listener $SERVER_PORT || { RESULT=1; exit 1; }

python3 $PROXY $((SERVER_PORT + 1)) 127.0.0.1 $SERVER_PORT 500 >/dev/null 2>&1 &
PROXY_PID=$!
wait_for_listener $((SERVER_PORT + 1)) || { RESULT=1; exit 1; }

# Reverse mode: server sends, client receives and detects corruption
OUTPUT=$($IPERF3 -c 127.0.0.1 -p $((SERVER_PORT + 1)) --data-integrity -R -t 3 2>&1)
CLIENT_RC=$?

kill "$PROXY_PID" 2>/dev/null
PROXY_PID=""
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

if [ $CLIENT_RC -ne 0 ]; then
    echo "PASS: client exited nonzero (rc=$CLIENT_RC) on integrity error"
else
    echo "FAIL: client exited 0 despite data integrity error"
    echo "Output: $OUTPUT"
    RESULT=1
fi

echo ""
echo "=== Test 6: Client exits nonzero when server detects integrity error ==="
SERVER_PORT=5307
$IPERF3 -s -p $SERVER_PORT -1 >/dev/null 2>&1 &
SERVER_PID=$!
wait_for_listener $SERVER_PORT || { RESULT=1; exit 1; }

python3 $PROXY $((SERVER_PORT + 1)) 127.0.0.1 $SERVER_PORT 500 >/dev/null 2>&1 &
PROXY_PID=$!
wait_for_listener $((SERVER_PORT + 1)) || { RESULT=1; exit 1; }

# Normal mode: client sends, server receives and detects corruption
OUTPUT=$($IPERF3 -c 127.0.0.1 -p $((SERVER_PORT + 1)) --data-integrity -t 3 2>&1)
CLIENT_RC=$?

kill "$PROXY_PID" 2>/dev/null
PROXY_PID=""
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

if [ $CLIENT_RC -ne 0 ]; then
    echo "PASS: client exited nonzero (rc=$CLIENT_RC) when server detected integrity error"
else
    echo "FAIL: client exited 0 despite server-side data integrity error"
    echo "Output: $OUTPUT"
    RESULT=1
fi

echo ""
echo "=== Test 7: UDP packet loss is not reported as a data integrity error ==="
# Reverse mode (server sends, client receives) so the CLIENT is the receiver
# and reports the integrity result in its own JSON.  The proxy drops ~1/25 of
# the data datagrams.  The old monotonic-sequence check would have aborted on
# the first lost datagram; the per-datagram check must instead count those as
# loss with zero integrity errors.
SERVER_PORT=5309
$IPERF3 -s -p $SERVER_PORT -1 >/dev/null 2>&1 &
SERVER_PID=$!
wait_for_listener $SERVER_PORT || { RESULT=1; exit 1; }

python3 $UDP_PROXY $((SERVER_PORT + 1)) 127.0.0.1 $SERVER_PORT 25 drop >/dev/null 2>&1 &
PROXY_PID=$!
wait_for_listener $((SERVER_PORT + 1)) || { RESULT=1; exit 1; }

OUTPUT=$($IPERF3 -c 127.0.0.1 -p $((SERVER_PORT + 1)) --data-integrity -u -b 20M -R -t 3 -J 2>/dev/null)
CLIENT_RC=$?

kill "$PROXY_PID" 2>/dev/null
PROXY_PID=""
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

# Parse the receiver's UDP summary: expect some loss but zero integrity errors.
READ=$(echo "$OUTPUT" | python3 -c '
import sys, json
try:
    u = json.load(sys.stdin)["end"]["streams"][0]["udp"]
except Exception as e:
    print("PARSE_ERROR", e); sys.exit(0)
print(u.get("lost_packets", -1), u.get("integrity_errors", -1))
')
LOST=$(echo "$READ" | awk '{print $1}')
INTEG=$(echo "$READ" | awk '{print $2}')

if [ $CLIENT_RC -ne 0 ]; then
    echo "FAIL: client exited nonzero (rc=$CLIENT_RC) on a lossy UDP test"
    echo "Output: $OUTPUT"
    RESULT=1
elif [ "$INTEG" != "0" ]; then
    echo "FAIL: packet loss was reported as integrity errors (integrity_errors=$INTEG)"
    RESULT=1
elif ! [ "$LOST" -gt 0 ] 2>/dev/null; then
    echo "FAIL: expected nonzero packet loss through the dropping proxy (lost=$LOST)"
    echo "Output: $OUTPUT"
    RESULT=1
else
    echo "PASS: $LOST datagrams lost, 0 integrity errors (loss not misreported as corruption)"
fi

echo ""
echo "=== Test 8: UDP corruption is counted and reported, but not fatal ==="
# Reverse mode again; the proxy flips a payload byte in ~1/50 data datagrams.
# The test must run to completion (exit 0) and report the corrupt datagrams in
# the receiver summary rather than aborting.
SERVER_PORT=5311
$IPERF3 -s -p $SERVER_PORT -1 >/dev/null 2>&1 &
SERVER_PID=$!
wait_for_listener $SERVER_PORT || { RESULT=1; exit 1; }

python3 $UDP_PROXY $((SERVER_PORT + 1)) 127.0.0.1 $SERVER_PORT 50 corrupt >/dev/null 2>&1 &
PROXY_PID=$!
wait_for_listener $((SERVER_PORT + 1)) || { RESULT=1; exit 1; }

OUTPUT=$($IPERF3 -c 127.0.0.1 -p $((SERVER_PORT + 1)) --data-integrity -u -b 20M -R -t 3 2>&1)
CLIENT_RC=$?

kill "$PROXY_PID" 2>/dev/null
PROXY_PID=""
wait "$SERVER_PID" 2>/dev/null
SERVER_PID=""

if [ $CLIENT_RC -ne 0 ]; then
    echo "FAIL: UDP corruption was fatal (rc=$CLIENT_RC); it should be counted, not aborted"
    echo "Output: $OUTPUT"
    RESULT=1
elif echo "$OUTPUT" | grep -q "failed data integrity validation"; then
    echo "PASS: corrupt datagrams reported in summary, test completed (rc=0)"
else
    echo "FAIL: corruption through proxy was not reported in the summary"
    echo "Output: $OUTPUT"
    RESULT=1
fi

echo ""
if [ $RESULT -eq 0 ]; then
    echo "All tests passed."
else
    echo "Some tests failed."
fi

exit $RESULT
