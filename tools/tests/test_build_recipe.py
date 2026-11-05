"""Builder test: a fixture goes through build_recipe.py and must pass the same recipe check as the
real recipes; bad input must fail with a message. Run from the repo root: python3 tools/tests/test_build_recipe.py"""
import os, subprocess, sys, tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import build_recipe as B

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, "..", "..", "kitchentimer.koplugin")
FIX = os.path.join(HERE, "fixtures", "broiled-test.md")

with tempfile.TemporaryDirectory() as d:
    out, r = B.build(FIX, d)
    assert r["steps"][1]["uses"] == ["1 lb cooked pork", "1 tbsp oil", "½ tsp salt"], r["steps"][1]
    assert r["steps"][1]["tracker_start"] == "oven" and r["steps"][1]["next_label"] == "Pan is in"
    assert r["steps"][3]["dur"] == 0 and r["steps"][3]["wait_for"] == "oven"
    assert r["pull"]["food"][1] == "1½ tbsp oil"
    assert r["trackers"]["oven"]["stages"][1]["buttons"][1] == {"label": "+2 min", "to": "broil", "dur": 120}
    assert "**" not in open(out, encoding="utf-8").read()
    # the generated file passes the full recipe check the Kindle recipes get
    p = subprocess.run(["luajit", "../tools/tests/test_recipes.lua"], cwd=PLUGIN,
                       env=dict(os.environ, KT_RECIPES_DIR=d), capture_output=True, text=True)
    assert p.returncode == 0 and "broiled-test" in p.stdout, p.stdout + p.stderr

src = open(FIX, encoding="utf-8").read()
def must_fail(text, needle):
    try:
        B.parse(text, "broiled-test")
    except B.RecipeError as e:
        assert needle in str(e), f"wrong message: {e}"
        return
    raise AssertionError("should have failed: " + needle)

must_fail(src.replace("(4 min)", "(0 min)"), "real duration")
must_fail(src.replace("### Pork: Heat the skillet (4 min)", "### Pork: Heat the skillet"), "Group: Title")
must_fail(src.replace("Wait: oven", ""), "only a step with 'Wait")
must_fail(src.replace("-> done |", "-> dnoe |"), "unknown stage")
must_fail(src.replace("Start: oven", "Start: ovn"), "unknown tracker")
must_fail(src.replace("Dinner is", "Dinner — is"), "em dash")
must_fail(src.replace("slug: broiled-test", "slug: other"), "doesn't match")
must_fail(src.replace("(3 min)", "(3 minz)"), "duration")
must_fail(src.replace("- 1/2 tsp salt", "- 1/2 tsp salt\n- 1 cup chicken broth"), "bouillon paste")
# a step that waits on a tracker before it is started would crash the plugin's planner
must_fail(src.replace("Move a rack 6 inches below the broiler and turn the broiler to high.",
    "Move a rack 6 inches below the broiler and turn the broiler to high.\nWait: oven"), "before any step starts it")
must_fail(src.replace("### oven: Pork", "### Oven: Pork"), "tracker heading")
assert B.lua({"end": 1, "ok": 2}) == '{\n    ["end"] = 1,\n    ok = 2,\n}', B.lua({"end": 1, "ok": 2})
print("ok test_build_recipe")
