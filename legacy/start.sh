#!/bin/zsh
cd "$(dirname "$0")"

PYTHON_BIN="./venv/bin/python3"
if [ ! -x "$PYTHON_BIN" ]; then
    PYTHON_BIN="python3"
fi

echo "[*] Reclaiming port 8080..."
lsof -ti:8080 | xargs kill -9 2>/dev/null

echo "[*] Compiling mbox3-ctl binary..."
clang++ -std=c++17 main.cpp -o mbox3-ctl -framework IOKit -framework CoreFoundation -framework CoreAudio
if [ $? -ne 0 ]; then
    echo "[-] Compilation failed!"
    exit 1
fi

# No hardware init here: server.py restores the last saved mix as soon as the Mbox is attached.
echo "[+] Launching backend web server on http://localhost:8080..."
"$PYTHON_BIN" server.py &
WEB_PID=$!

echo "[+] Launching macOS Menu Bar Companion..."
"$PYTHON_BIN" menu_bar.py

kill $WEB_PID 2>/dev/null
