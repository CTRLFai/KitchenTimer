#!/usr/bin/env python3
"""Build a Kindle recipe file from a markdown cook sheet.

    python3 tools/build_recipe.py source/<slug>.md

Writes kitchentimer.koplugin/recipes/<slug>.lua. The markdown is the source of truth: it is the
same cook sheet Mike reads, so a recipe is written once. Format (see source/FORMAT.md):

    # Title
    slug: carnitas-tacos
    servings: 3 (2 adults, 1 child)
    oven: 425°F                      (optional)
    finish: One line shown on the Done screen.

    ## Pull these out
    ### Food
    - 16 oz frozen corn
    ### Gear
    - Cast iron skillet

    ## Trackers                      (optional)
    ### oven: Pork
    - roast1 timed 5 min | Pork broiling | Check in
    - check alert | Check the pork | Edges browned and crispy. | Out of oven -> done | +2 min -> roast1 (2 min)
    - done final | Pork out | Broiler off.

    ## Steps
    ### Corn salad: Heat the skillet (4 min)
    Heat **1 tbsp avocado oil** in the cast iron over medium-high.
    Start: oven            starts tracker "oven" when this step's button is pressed
    Wait: oven             step is locked until tracker "oven" is final (duration may be "wait")
    Button: Pans are in    label for this step's Next button
    If alert: Turn the heat to low, then flip.   what to do with the pan if an alert lands mid-step

    ## Storage
    ### Fridge (3 to 4 days)
    - Reheat in a skillet.

Bold text in a step is an ingredient amount used in that step; the recipe check adds it up against
the pull list. Fails loudly on anything it doesn't understand.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "kitchentimer.koplugin", "recipes")

FRACTIONS = {"1/2": "\u00bd", "1/3": "\u2153", "2/3": "\u2154", "1/4": "\u00bc", "3/4": "\u00be"}
EM_DASH = "\u2014"


class RecipeError(Exception):
    pass


def frac(s):
    # "1 1/2 tsp" -> "1½ tsp", "1/4 cup" -> "¼ cup". Leaves other numbers alone (like 375°F or 3/8).
    def rep(m):
        whole, f = m.group(1), m.group(2)
        return (whole or "") + FRACTIONS[f]
    return re.sub(r"(?<![\d/])(?:(\d+) )?(1/2|1/3|2/3|1/4|3/4)(?![\d/])", rep, s)


def parse_dur(s, where):
    s = s.strip().lower()
    if s == "wait":
        return None
    total, found = 0, False
    for n, unit in re.findall(r"(\d+(?:\.\d+)?)\s*(h|hr|hours?|min|minutes?|sec|seconds?|s)\b", s):
        found = True
        n = float(n)
        total += n * (3600 if unit.startswith("h") else 60 if unit.startswith("m") else 1)
    if not found or re.sub(r"(\d+(?:\.\d+)?)\s*(h|hr|hours?|min|minutes?|sec|seconds?|s)\b|\s|and", "", s):
        raise RecipeError(f"{where}: can't read the duration '{s}' (write it like '4 min', '30 sec', '1 h 15 min' or 'wait')")
    return int(round(total))


def sections(lines):
    """Split into (level, heading, body_lines) blocks."""
    blocks, cur = [], (0, "", [])
    for ln in lines:
        m = re.match(r"^(#{1,3}) (.*)$", ln)
        if m:
            blocks.append(cur)
            cur = (len(m.group(1)), m.group(2).strip(), [])
        else:
            cur[2].append(ln)
    blocks.append(cur)
    return blocks


def bullets(body, where):
    out = []
    for ln in body:
        if not ln.strip():
            continue
        if not ln.startswith("- "):
            raise RecipeError(f"{where}: expected a '- ' list item, got '{ln}'")
        out.append(frac(ln[2:].strip()))
    return out


def parse_stage(line, where):
    parts = [p.strip() for p in line.split("|")]
    head = parts[0].split()
    if len(head) < 2 or len(parts) < 2:
        raise RecipeError(f"{where}: stage needs 'id kind | label | ...', got '{line}'")
    sid, kind = head[0], head[1]
    st = {"id": sid, "label": parts[1]}
    if len(parts) > 2 and parts[2]:
        st["sub"] = frac(parts[2])
    if kind == "timed":
        st["dur"] = parse_dur(" ".join(head[2:]), where)
        if not st["dur"]:
            raise RecipeError(f"{where}: timed stage '{sid}' needs a duration")
    elif kind == "alert":
        st["alert"] = True
        st["buttons"] = []
        for b in parts[3:]:
            m = re.match(r"^(.+?)\s*->\s*(\w+)(?:\s*\((.+)\))?$", b)
            if not m:
                raise RecipeError(f"{where}: button must be 'Label -> stage' or 'Label -> stage (2 min)', got '{b}'")
            btn = {"label": m.group(1), "to": m.group(2)}
            if m.group(3):
                btn["dur"] = parse_dur(m.group(3), where)
            st["buttons"].append(btn)
        if not st["buttons"]:
            raise RecipeError(f"{where}: alert stage '{sid}' needs at least one button")
    elif kind == "final":
        st["final"] = True
    else:
        raise RecipeError(f"{where}: stage kind must be timed, alert or final, got '{kind}'")
    return st


DIRECTIVES = {"start": "tracker_start", "wait": "wait_for", "button": "next_label", "if alert": "alert_hint"}


def parse_step(heading, body, n):
    where = f"step {n} '{heading}'"
    m = re.match(r"^(.+?):\s*(.+?)\s*\(([^)]+)\)\s*$", heading)
    if not m:
        raise RecipeError(f"{where}: heading must be 'Group: Title (4 min)'")
    step = {"group": m.group(1).strip(), "title": m.group(2).strip()}
    dur = parse_dur(m.group(3), where)
    text_lines = []
    for ln in body:
        d = re.match(r"^(Start|Wait|Button|If alert):\s*(.+)$", ln)
        if d:
            step[DIRECTIVES[d.group(1).lower()]] = frac(d.group(2).strip())
        else:
            text_lines.append(ln)
    text = "\n".join(text_lines).strip()
    text = re.sub(r"\n{3,}", "\n\n", text)
    if not text:
        raise RecipeError(f"{where}: no instructions")
    uses = [frac(u.strip()) for u in re.findall(r"\*\*(.+?)\*\*", text)]
    text = frac(re.sub(r"\*\*(.+?)\*\*", r"\1", text))
    text = re.sub(r"^- ", "\u2022 ", text, flags=re.M)
    step["dur"] = 0 if dur is None else dur
    step["text"] = text
    if uses:
        step["uses"] = uses
    if re.match(r"^\d+ portions\b", text, re.I):
        step["portion"] = True
    if dur is None and "wait_for" not in step:
        raise RecipeError(f"{where}: only a step with 'Wait: <tracker>' may use 'wait' as its duration")
    # Timing rule: every step is timed (prep included). A step with no time is how totals went wrong.
    if dur == 0:
        raise RecipeError(f"{where}: every step needs a real duration, prep included")
    # Key order matches the generated recipes, so diffs stay readable.
    order = ["group", "title", "dur", "text", "uses", "portion", "next_label", "tracker_start", "wait_for", "alert_hint"]
    return {k: step[k] for k in order if k in step}


def parse(md, slug_from_file):
    if EM_DASH in md:
        raise RecipeError("contains an em dash")
    lines = md.replace("\r\n", "\n").split("\n")
    blocks = sections(lines)
    r = {}
    top = [b for b in blocks if b[0] == 1]
    if len(top) != 1:
        raise RecipeError("needs exactly one '# Title' line")
    r["title"] = top[0][1]
    meta = {}
    for ln in top[0][2]:
        m = re.match(r"^(slug|servings|oven|finish):\s*(.+)$", ln)
        if m:
            meta[m.group(1)] = m.group(2).strip()
        elif ln.strip():
            raise RecipeError(f"unexpected line under the title: '{ln}'")
    for k in ("slug", "servings", "finish"):
        if k not in meta:
            raise RecipeError(f"missing '{k}:' under the title")
    if meta["slug"] != slug_from_file:
        raise RecipeError(f"slug '{meta['slug']}' doesn't match the file name '{slug_from_file}'")
    m = re.match(r"^(\d+)(?:\s*\((.+)\))?$", meta["servings"])
    if not m:
        raise RecipeError("servings must be like '3' or '3 (2 adults, 1 child)'")
    r["slug"] = meta["slug"]
    r["servings"] = int(m.group(1))
    if m.group(2):
        r["servings_note"] = m.group(2)
    if "oven" in meta:
        r["oven"] = meta["oven"]

    part, sub = None, None
    pull, trackers, steps, storage = {}, {}, [], []
    for level, head, body in blocks[1:]:
        if level == 1:
            continue
        if level == 2:
            part = head.lower()
            if part not in ("pull these out", "trackers", "steps", "storage"):
                raise RecipeError(f"unknown section '## {head}'")
            if any(ln.strip() for ln in body):
                raise RecipeError(f"text directly under '## {head}'; put it under a '###' heading")
            continue
        if part == "pull these out":
            key = head.lower()
            if key not in ("food", "gear"):
                raise RecipeError(f"pull list sections are '### Food' and '### Gear', got '### {head}'")
            pull[key] = bullets(body, f"pull list {head}")
        elif part == "trackers":
            m = re.match(r"^(\w+):\s*(.+)$", head)
            if not m:
                raise RecipeError(f"tracker heading must be '### id: Name', got '{head}'")
            stages = [parse_stage(ln[2:], f"tracker {m.group(1)}") for ln in body if ln.startswith("- ")]
            trackers[m.group(1)] = {"name": m.group(2), "stages": stages}
        elif part == "steps":
            steps.append(parse_step(head, body, len(steps) + 1))
        elif part == "storage":
            storage.append({"title": head, "items": bullets(body, f"storage {head}")})
        else:
            raise RecipeError(f"'### {head}' is outside a known section")
    if not pull.get("food") or not pull.get("gear"):
        raise RecipeError("pull list needs both '### Food' and '### Gear'")
    if not steps:
        raise RecipeError("no steps")

    for tid, t in trackers.items():
        ids = [s["id"] for s in t["stages"]]
        if not t["stages"] or not t["stages"][-1].get("final"):
            raise RecipeError(f"tracker {tid}: the last stage must be 'final'")
        for s in t["stages"]:
            for b in s.get("buttons", []):
                if b["to"] not in ids:
                    raise RecipeError(f"tracker {tid}: button '{b['label']}' goes to unknown stage '{b['to']}'")
    for i, s in enumerate(steps, 1):
        for k in ("tracker_start", "wait_for"):
            if k in s and s[k] not in trackers:
                raise RecipeError(f"step {i}: unknown tracker '{s[k]}'")

    r["pull"] = {"food": pull["food"], "gear": pull["gear"]}
    r["steps"] = steps
    if trackers:
        r["trackers"] = trackers
    if storage:
        r["storage"] = storage
    r["finish"] = frac(meta["finish"])
    return r


def lua(v, ind=0):
    pad, pad2 = "    " * ind, "    " * (ind + 1)
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    if isinstance(v, list):
        if not v:
            return "{}"
        return "{\n" + "".join(pad2 + lua(x, ind + 1) + ",\n" for x in v) + pad + "}"
    if isinstance(v, dict):
        return "{\n" + "".join(f"{pad2}{k} = {lua(x, ind + 1)},\n" for k, x in v.items()) + pad + "}"
    raise TypeError(type(v))


def build(src, out_dir=OUT_DIR):
    slug = os.path.splitext(os.path.basename(src))[0]
    with open(src, encoding="utf-8") as f:
        r = parse(f.read(), slug)
    rel = os.path.relpath(src, ROOT) if os.path.abspath(src).startswith(ROOT) else os.path.basename(src)
    body = f"-- Generated by tools/build_recipe.py from {rel}. Do not edit by hand.\nreturn {lua(r)}\n"
    out = os.path.join(out_dir, slug + ".lua")
    with open(out, "w", encoding="utf-8") as f:
        f.write(body)
    return out, r


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python3 tools/build_recipe.py source/<slug>.md")
    try:
        out, r = build(sys.argv[1])
    except RecipeError as e:
        sys.exit(f"recipe problem: {e}")
    print(f"wrote {out} {len(r['steps'])} steps")
