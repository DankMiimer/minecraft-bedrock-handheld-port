#!/bin/bash
# Thor Virtual Keyboard — CLI Launcher (deployed at /storage/thor-keyboard.sh)
# python runs with -u: unbuffered stdout makes the "[app] Running" line
# land in the log the moment signal handlers are installed — osk_show.sh
# gates on it (a SIGUSR2 sent before handlers exist KILLS the process,
# which is exactly the 2026-07-12 black-screen softlock).
PIDFILE="/tmp/thor_keyboard.pid"
KB_DIR="${RGDS_THOR_KEYBOARD_DIR:-/storage/thor-keyboard}"
RGDS_OSK_OUTPUT="${RGDS_OSK_OUTPUT:?RGDS_OSK_OUTPUT is required}"

start_keyboard() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Already running (PID $(cat "$PIDFILE"))"; return
    fi
    swaymsg "output $RGDS_OSK_OUTPUT power on" 2>/dev/null
    sleep 0.5
    export SDL_VIDEODRIVER=wayland
    # launched from the game's env this would inherit crusty + westonfix
    # (whose open() hook could block the keyboard's discovered touch device)
    unset LD_PRELOAD WESTONFIX_HIDE_DEVNODE
    nohup python3 -u "$KB_DIR/main.py" > /tmp/thor_keyboard.log 2>&1 &
    echo $! > "$PIDFILE"
    echo "Keyboard started (PID $!) — press R3 to toggle"
}

stop_keyboard() {
    if [ -f "$PIDFILE" ]; then
        kill "$(cat "$PIDFILE")" 2>/dev/null; sleep 0.3
        kill -9 "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"
    else
        pkill -f "thor-keyboard/main.py" 2>/dev/null
    fi
    echo "Keyboard stopped"
}

wait_ready() {
    # signal-safe point: main.py prints this right AFTER _install_signals()
    for _i in $(seq 1 20); do
        grep -q "Running" /tmp/thor_keyboard.log 2>/dev/null && return 0
        kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null || return 1
        sleep 0.3
    done
    return 1
}

show_keyboard() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        wait_ready || { echo "Keyboard not ready"; return 1; }
        kill -USR2 "$(cat "$PIDFILE")" 2>/dev/null
        echo "Keyboard shown"
    else
        echo "Keyboard not running"
    fi
}

hide_keyboard() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        wait_ready || { echo "Keyboard not ready"; return 1; }
        kill -USR1 "$(cat "$PIDFILE")" 2>/dev/null
        echo "Keyboard hidden"
    else
        echo "Keyboard not running"
    fi
}

toggle_keyboard() {
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        wait_ready || { echo "Keyboard not ready"; return 1; }
        kill -RTMIN "$(cat "$PIDFILE")" 2>/dev/null
        echo "Keyboard toggled"
    else
        echo "Keyboard not running"
    fi
}

case "${1:-start}" in
    start)   start_keyboard ;;
    stop)    stop_keyboard ;;
    restart) stop_keyboard; sleep 0.5; start_keyboard ;;
    show)    show_keyboard ;;
    hide)    hide_keyboard ;;
    toggle)  toggle_keyboard ;;
    *)       echo "Usage: $0 {start|stop|restart|show|hide|toggle}" ;;
esac
