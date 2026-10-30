# KitchenTimer repo notes

- `kitchentimer.koplugin/` is the KOReader plugin for Mike's Kindle PW2 (758x1024, 212 dpi, e-ink, no speaker). Recipes in `kitchentimer.koplugin/recipes/` ride the same hash-checked updater as the code.
- Recipes are generated, never hand-edited: `NODE_PATH=$(npm root -g) node tools/convert_phone_page.js source/<slug>.phone.html <slug>`. The phone page (a claude.ai artifact) is the source of truth; `source/` holds a snapshot of it. When the phone page changes, refresh the snapshot and rerun the converter.
- Tests, from `kitchentimer.koplugin/`: `for t in ../tools/tests/test_*.lua; do luajit $t || echo FAIL $t; done`. LuaJIT is not preinstalled: build it from github.com/LuaJIT/LuaJIT (`make && make install`).
- Before every push that changes the plugin: run the tests, run `python3 tools/make_manifest.py --bump` (the Kindle only updates when the manifest version goes up), exercise the changed screens in the KOReader emulator, and get one review from a fresh agent (ask Mike first with a cost estimate). Tell Mike plainly what was and was not tested.
- This is a public repo and needs no tokens. Never commit any config or token.
- Own settings files only (`kitchentimer_*.lua`). Never read or write anything named `relic_*`; Relic is a separate plugin on the same Kindle.
- Keep-awake follows `meditate.lua` in the Relic repo: PluginShare.pause_auto_suspend + PluginShare.keepalive + lipc preventScreenSaver, with its own flag and a stale-hold cleanup at startup.
- Never use an em dash anywhere (copy, comments, commit messages). Check every glyph exists in NotoSans before using it (no check mark); `test_recipes.lua` keeps the allowed list.

## Lessons log

Read before building. When something breaks or Mike corrects a mistake, add one line here in the same session: date, the rule, and what went wrong. Push it to main on its own (no manifest bump needed for this file).

- 2026-10-30: A bare `preventScreenSaver 1` crashes KOReader's AutoSuspend. Relic's meditation screen hit this and fixed it by also setting PluginShare.keepalive and pausing auto-suspend; copy that, don't write it fresh.
- 2026-10-30: A check that has never failed proves nothing. After writing a test, break the thing on purpose and watch it fail. When breaking a recipe with sed, change one place only: a global replace changes the pull list and the steps together and the recipe stays consistent, so the test correctly passes.
