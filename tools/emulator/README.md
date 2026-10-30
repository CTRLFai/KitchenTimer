KOReader emulator for testing Kitchen Timer at Kindle PW2 size (758x1024, 212 dpi). Nothing persists between
sessions, so set it up each time. Scripts adapted from Relic's tools/emulator.

Setup (the cloud gets 403 from GitHub releases, so the AppImage comes from Mike's Mac, folder
Planner/Relic/emulator, staged with the device tools):
  mkdir -p /home/claude/ko /home/claude/kohome /home/claude/shots
  cp <staged>/koreader-x86_64.AppImage /home/claude/ko/ && cd /home/claude/ko && chmod +x *.AppImage
  ./koreader-x86_64.AppImage --appimage-extract
  mkdir -p lib && ln -sfn /home/claude/ko/squashfs-root/usr/lib/koreader lib/koreader
  ln -sfn /home/claude/kitchentimer/kitchentimer.koplugin lib/koreader/plugins/kitchentimer.koplugin
  mkdir -p lib/koreader/patches   # then write patches/2-ktdev.lua (opens the plugin 3 s after start):
      UIManager:scheduleIn(3, function() UIManager:broadcastEvent(Event:new("OpenKitchenTimer")) end)

  run.sh [seconds]        (re)start KOReader; log in /home/claude/kohome/ko.log (grep KT-LAYOUT)
  fixture.lua             write a saved run so it opens in any state (see the header of the file)
  shot.sh NAME            screenshot to /home/claude/shots/NAME.png (window origin 133,88)
  xt.py tap X Y [hold]    tap at screen coordinates

Write a fixture only while KOReader is stopped (`pkill -f "luajit ./[r]eader.lua"`, wait 2 s): a running
KOReader rewrites the run file as it exits. The run file is
/home/claude/ko/lib/koreader/settings/kitchentimer_run.lua.
The emulator has no frontlight and is not a Kindle: the light pulse, the lipc keep-awake call and
e-ink ghosting cannot be seen here.
