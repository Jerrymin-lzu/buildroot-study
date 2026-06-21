#!/bin/sh
# Generate simple eth0 traffic inside the Buildroot VM for XDP/myapp testing.

set -eu

IFACE="${IFACE:-eth0}"
TARGET_HOST="${TARGET_HOST:-10.0.2.2}"
INTERVAL="${INTERVAL:-1}"
PID_FILE="${PID_FILE:-/tmp/xdp_traffic.pid}"
LOG_FILE="${LOG_FILE:-/tmp/xdp_traffic.log}"

usage() {
    cat <<EOF
Usage: $0 {start|stop|status|run}

Environment:
  IFACE        network interface to use, default: eth0
  TARGET_HOST  host to ping, default: 10.0.2.2 (QEMU user-net gateway)
  INTERVAL     seconds between rounds, default: 1
  PID_FILE     pid file, default: /tmp/xdp_traffic.pid
  LOG_FILE     log file, default: /tmp/xdp_traffic.log
EOF
}

is_running() {
    [ -f "${PID_FILE}" ] || return 1
    pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    [ -n "${pid}" ] || return 1
    kill -0 "${pid}" 2>/dev/null
}

get_iface_ipv4() {
    ip -4 addr show dev "${IFACE}" 2>/dev/null \
        | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' \
        | head -n 1
}

run_loop() {
    echo "xdp traffic generator started"
    echo "iface=${IFACE} target=${TARGET_HOST} interval=${INTERVAL}"

    while :; do
        date '+%Y-%m-%d %H:%M:%S'

        if ip link show "${IFACE}" >/dev/null 2>&1; then
            ip link set "${IFACE}" up 2>/dev/null || true
        else
            echo "interface ${IFACE} does not exist"
            sleep "${INTERVAL}"
            continue
        fi

        iface_ip="$(get_iface_ipv4 || true)"

        echo "ping gateway ${TARGET_HOST}"
        ping -c 1 -W 1 "${TARGET_HOST}" >/dev/null 2>&1 \
            && echo "gateway ping ok" \
            || echo "gateway ping failed"

        if [ -n "${iface_ip}" ]; then
            echo "ping self ${iface_ip}"
            ping -c 1 -W 1 "${iface_ip}" >/dev/null 2>&1 \
                && echo "self ping ok" \
                || echo "self ping failed"
        else
            echo "no IPv4 address on ${IFACE}"
        fi

        sleep "${INTERVAL}"
    done
}

start() {
    if is_running; then
        echo "already running: pid $(cat "${PID_FILE}")"
        exit 0
    fi

    : > "${LOG_FILE}"
    (run_loop >> "${LOG_FILE}" 2>&1) &
    echo "$!" > "${PID_FILE}"
    echo "started: pid $(cat "${PID_FILE}")"
    echo "log: ${LOG_FILE}"
}

stop() {
    if ! is_running; then
        echo "not running"
        rm -f "${PID_FILE}"
        exit 0
    fi

    pid="$(cat "${PID_FILE}")"
    kill "${pid}" 2>/dev/null || true
    rm -f "${PID_FILE}"
    echo "stopped: pid ${pid}"
}

status() {
    if is_running; then
        echo "running: pid $(cat "${PID_FILE}")"
        echo "log: ${LOG_FILE}"
    else
        echo "not running"
    fi
}

case "${1:-}" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    status)
        status
        ;;
    run)
        run_loop
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        echo "unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
