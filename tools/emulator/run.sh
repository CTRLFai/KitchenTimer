#!/bin/bash
# Start KOReader (PW2 size) with Kitchen Timer opening itself after 3 s. Layout set up by README.md.
# Usage: run.sh [seconds to wait]    Env KT_DEBUG=1 is set so the screen logs a layout check.
pkill -f "luajit ./[r]eader.lua"; sleep 2
pgrep -x Xvfb >/dev/null || (Xvfb :99 -screen 0 1024x1200x24 >/dev/null 2>&1 &) ; sleep 1
cd /home/claude/ko/lib/koreader
export HOME=/home/claude/kohome DISPLAY=:99 SDL_AUDIODRIVER=dummy EMULATE_READER_W=758 EMULATE_READER_H=1024 EMULATE_READER_DPI=212 KT_DEBUG=1
(./reader.lua /home/claude/kohome > /home/claude/kohome/ko.log 2>&1 &)
sleep ${1:-9}
