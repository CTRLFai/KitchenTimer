# KitchenTimer repo notes

- `kitchentimer.koplugin/` is the KOReader plugin for Mike's Kindle PW2 (758x1024, 212 dpi, e-ink, no speaker). Recipes in `kitchentimer.koplugin/recipes/` ride the same hash-checked updater as the code.
- Recipes are generated, never hand-edited. New recipes (Kindle only, the week's meal-plan meals) are a markdown cook sheet, `source/<slug>.md`, built with `python3 tools/build_recipe.py source/<slug>.md`; the format is in the script's header and the same .md is the recipe saved to the Cooking project. Every step needs a real duration (prep included); the builder refuses untimed steps. Older recipes from a phone page use `NODE_PATH=$(npm root -g) node tools/convert_phone_page.js source/<slug>.phone.html <slug>`.
- Builder test, from the repo root: `python3 tools/tests/test_build_recipe.py`.
- Tests, from `kitchentimer.koplugin/`: `for t in ../tools/tests/test_*.lua; do luajit $t || echo FAIL $t; done`. LuaJIT is not preinstalled: build it from github.com/LuaJIT/LuaJIT (`make && make install`).
- Before every push that changes the plugin code: run the tests, run `python3 tools/make_manifest.py --bump` (the Kindle only updates when the manifest version goes up), exercise the changed screens in the KOReader emulator, and get one review from a fresh agent (ask Mike first with a cost estimate). Tell Mike plainly what was and was not tested.
- Recipe-only pushes (the week's meal-plan recipes) skip the code review and get the readiness check instead (Mike's call, 2026-11-05): builder and tests, an emulator pass through every step and alert of every recipe, and one cook-through review of the week's batch by a fresh Sonnet agent at low effort (standing approval, no need to ask). Then manifest bump and push. Steps are in the meal-prep skill.
- This is a public repo and needs no tokens. Never commit any config or token.
- Own settings files only (`kitchentimer_*.lua`). Never read or write anything named `relic_*`; Relic is a separate plugin on the same Kindle.
- Keep-awake follows `meditate.lua` in the Relic repo: PluginShare.pause_auto_suspend + PluginShare.keepalive + lipc preventScreenSaver, with its own flag and a stale-hold cleanup at startup.
- Never use an em dash anywhere (copy, comments, commit messages). Check every glyph exists in NotoSans before using it (no check mark); `test_recipes.lua` keeps the allowed list.

## Lessons log

Read before building. When something breaks or Mike corrects a mistake, add one line here in the same session: date, the rule, and what went wrong. Push it to main on its own (no manifest bump needed for this file).

- 2026-10-30: A bare `preventScreenSaver 1` crashes KOReader's AutoSuspend. Relic's meditation screen hit this and fixed it by also setting PluginShare.keepalive and pausing auto-suspend; copy that, don't write it fresh.
- 2026-10-30: A check that has never failed proves nothing. After writing a test, break the thing on purpose and watch it fail. When breaking a recipe with sed, change one place only: a global replace changes the pull list and the steps together and the recipe stays consistent, so the test correctly passes.
- 2026-10-30: `PluginShare` is a module: `local PluginShare = require("pluginshare")`. Used as a bare global it is nil and the first press of START crashed. Unit tests with injected fakes can't see this; only pressing every button in the emulator did. `test_safety.lua` now checks main.lua requires it.
- 2026-10-30: VerticalGroup caches child offsets the first time you call `getSize()`; appending children afterwards crashes on paint (nil offset). Measure a group, then nest it inside a fresh VerticalGroup instead of appending to it. The alert card and error page both had this.
- 2026-10-30: A checkpoint push to main counts as a push: plugin code went up before review. Keep unreviewed work on a local commit or a branch; main only gets plugin changes after tests, manifest bump, emulator run and the review.

- 2026-11-05: Keep-awake needs a ceiling that doesn't depend on what's on screen. The review found that walking away from an untimed step kept the Kindle awake until the battery died, because the only release was the 15-minute alert quiet. `Timeline.needs_awake` now decides it (timers running, alert unanswered, a touch in 15 min, never past 6 h), with tests.
- 2026-11-05: Anything delivered over the air must not be able to crash the plugin. A recipe the planner rejects now gets skipped by `loadRecipes`, the builder refuses it first, and the updater compile-checks every staged .lua before swapping (a release that doesn't compile would remove the Roll back menu).
