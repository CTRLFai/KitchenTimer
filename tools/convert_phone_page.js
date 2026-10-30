#!/usr/bin/env node
// Converts a phone cook-timer page (the Sausage Gravy Bowls template family) into a Kitchen Timer
// recipe file for the Kindle.
//
// Usage: NODE_PATH=$(npm root -g) node tools/convert_phone_page.js source/<slug>.phone.html <slug>
// Writes kitchentimer.koplugin/recipes/<slug>.lua
//
// The phone page is the one source of truth. Rerun this whenever it changes. It reads the page the
// way a browser does (STEPS, ROAST1/ROAST2, the pull list, the storage section), and it presses the
// tracker buttons in the page to learn where each one leads, so a changed button is picked up too.
// Anything it can't map throws instead of guessing.

const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");

const [src, slug] = process.argv.slice(2);
if (!src || !slug) { console.error("usage: convert_phone_page.js <phone.html> <slug>"); process.exit(2); }

// Phone wording that makes no sense on a Kindle (no speaker, no page to scroll).
const WORDING = [
  [/oven tracker chimes/gi, "oven tracker alerts"],
  [/oven tracker says/gi, "oven tracker shows"],
  [/at the bottom of the page/gi, "on the next screen"],
  [/in the list at the top of the page/gi, "on the Pull these out screen"],
  // The Kindle's button is labelled for the action ("Pans are in") or locked until the tracker allows it.
  [/tap Next\. The oven tracker starts then\./gi, "tap Pans are in. The oven tracker starts then."],
  [/Tap Next once the oven tracker shows the potatoes are out\./gi, "Next unlocks once the oven tracker shows the potatoes are out."],
];

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 375, height: 667 } });
  await page.route(/^https?:/, r => r.abort());   // fonts only; the page works without them
  await page.goto("file://" + path.resolve(src));

  const raw = await page.evaluate(() => {
    const clean = s => s.replace(/\s+/g, " ").trim();
    const toText = html => {
      const d = document.createElement("div"); d.innerHTML = html;
      const blocks = [];
      for (const n of d.children) {
        if (n.tagName === "UL") blocks.push([...n.children].map(li => "• " + clean(li.textContent)).join("\n"));
        else blocks.push(clean(n.textContent));
      }
      return blocks.filter(Boolean).join("\n\n");
    };
    const out = { title: document.querySelector("h1").textContent.trim() };
    out.meta = clean(document.querySelector(".meta").textContent);
    out.steps = STEPS.map(s => ({
      group: s.g, title: s.t, dur: s.dur || 0, text: toText(s.b),
      uses: (() => { const d = document.createElement("div"); d.innerHTML = s.b;
        return [...d.querySelectorAll(".ing")].map(e => clean(e.textContent)); })(),
      ovenStart: !!s.ovenStart, waitOven: !!s.waitOven,
    }));
    // The button that starts a tracker has its own label on the phone ("Pans are in").
    out.steps.forEach((s, i) => {
      if (s.ovenStart) { S.started = true; S.finished = false; S.oven = "idle"; S.idx = i; render(true);
        s.nextLabel = clean($("mainBtn").textContent); }
    });
    // Pull list
    const grid = document.querySelectorAll("#pullList .pull-grid > div");
    out.pull = {};
    grid.forEach(div => {
      const key = clean(div.querySelector("h3").textContent).toLowerCase();
      out.pull[key] = [...div.querySelectorAll("li")].map(li => clean(li.textContent));
    });
    // Storage
    out.storage = [];
    document.querySelectorAll("section.reheat h3").forEach(h => {
      const ul = h.nextElementSibling;
      out.storage.push({ title: clean(h.textContent), items: [...ul.querySelectorAll("li")].map(li => clean(li.textContent)) });
    });
    // Finish card
    S.started = true; S.finished = true; S.finishedAt = Date.now(); S.runStart = Date.now() - 1000; render(true);
    out.finish = { title: clean($("curTitle").textContent), text: clean($("curBody").textContent) };
    // Tracker: durations, labels, and where each button leads (by pressing it).
    const tr = { roast1: ROAST1, roast2: ROAST2 };
    const now = Date.now();
    const state = (name, target) => {
      S.started = true; S.finished = false; S.idx = 0; S.stepStart = now; S.runStart = now;
      S.oven = name; S.ovenTarget = target; S.chimedOven = name; render(true);
      const b = $("ovenBtn"), m = $("ovenMore");
      return {
        label: clean($("ovenLbl").textContent), sub: clean($("ovenSub").textContent),
        btn: b.hidden ? null : clean(b.textContent), more: m.hidden ? null : clean(m.textContent),
      };
    };
    const st = {};
    st.roast1 = state("roast1", now + 1e9);
    st.flip = state("flip", now - 1);
    st.roast2 = state("roast2", now + 1e9);
    st.check = state("check", now - 1);
    st.done = state("done", now);
    const press = (name, id) => {
      state(name, now - 1); $(id).click();
      return { to: S.oven, secs: S.oven === "roast2" ? Math.round((S.ovenTarget - Date.now()) / 1000) : 0 };
    };
    st.flip.press = press("flip", "ovenBtn");
    st.check.press = press("check", "ovenBtn");
    st.check.pressMore = press("check", "ovenMore");
    // Main button on the step that starts the oven: roast1 for ROAST1 seconds.
    S.started = true; S.finished = false; S.oven = "idle"; S.idx = STEPS.findIndex(s => s.ovenStart); render(true);
    $("mainBtn").click();
    st.start = { to: S.oven, secs: Math.round((S.ovenTarget - Date.now()) / 1000) };
    out.tracker = st; out.consts = tr;
    return out;
  });
  await browser.close();

  // ---- Checks that the page still looks like the template this converter understands ----
  const fail = m => { throw new Error("convert_phone_page: " + m); };
  const T = raw.tracker;
  if (T.start.to !== "roast1" || Math.abs(T.start.secs - raw.consts.roast1) > 2) fail("oven start no longer means roast1");
  if (T.flip.press.to !== "roast2" || Math.abs(T.flip.press.secs - raw.consts.roast2) > 2) fail("flip button no longer starts roast2");
  if (T.check.press.to !== "done") fail("check button no longer ends the oven tracker");
  if (T.check.pressMore.to !== "roast2") fail("+ button no longer extends");
  const extra = T.check.pressMore.secs;
  if (!T.flip.btn || !T.check.btn || !T.check.more) fail("tracker buttons missing");
  if (!raw.steps.some(s => s.ovenStart) || !raw.steps.some(s => s.waitOven)) fail("no oven start / wait steps");

  // ---- Build the recipe ----
  const m = raw.meta.match(/(\d+) servings \(([^)]*)\).*?oven (\d+\S*)/);
  if (!m) fail("meta line not understood: " + raw.meta);
  const wording = s => WORDING.reduce((a, [re, to]) => a.replace(re, to), s);

  const steps = raw.steps.map((s, i) => {
    const o = { group: s.group, title: s.title, dur: s.dur, text: wording(s.text) };
    if (s.uses.length) o.uses = s.uses;
    // Portion steps split the batch across containers; the recipe check skips their amounts.
    if (/^\d+ portions\b/i.test(s.text)) o.portion = true;
    if (s.nextLabel && s.nextLabel !== "Next") o.next_label = s.nextLabel;
    if (s.ovenStart) o.tracker_start = "oven";
    if (s.waitOven) o.wait_for = "oven";
    // Sentence that tells him what to do with the pan when a tracker alert lands mid-step.
    const hint = s.text.match(/When the oven tracker chimes,\s*([^.]*)\./i);
    if (hint) { const t = hint[1].trim(); o.alert_hint = t.charAt(0).toUpperCase() + t.slice(1) + "."; }
    return o;
  });

  // A long final wait (the fridge chill before the freezer) is not run by the Kindle: the screen
  // would have to stay awake for another hour. Mike's rule: tell him to set a timer on his phone or stove.
  const last = steps[steps.length - 1];
  if (last.dur >= 30 * 60) {
    const mins = Math.round(last.dur / 60);
    const re = /This timer chimes in (\d+ hours?|\d+ minutes?)[^.]*\./;
    const orig = raw.steps[raw.steps.length - 1].text;
    if (!/This timer chimes in/.test(orig)) fail("final wait step wording changed: " + orig.slice(0, 80));
    const label = mins % 60 === 0 ? (mins / 60) + (mins === 60 ? " hour" : " hours") : mins + " minutes";
    const rest = orig.split("\n\n").slice(1).join("\n\n");
    last.dur = 0;
    last.title = "Set a timer for the freezer";
    last.text = "Set a timer for " + label + " on your phone or stove now. The bags chill in the fridge until it goes off. " +
      "Warm food in a sealed bag frosts up inside.\n\nWhen the timer goes off:\n" + wording(rest);
    last.kindle_note = "phone timer";
  }

  const pull = { food: raw.pull.food, gear: raw.pull.gear };
  if (!pull.food || !pull.gear) fail("pull list headings changed: " + Object.keys(raw.pull));

  const recipe = {
    slug, title: raw.title,
    servings: +m[1], servings_note: m[2], oven: m[3],
    pull, steps,
    trackers: {
      oven: {
        name: "Potatoes",
        stages: [
          { id: "roast1", label: T.roast1.label, sub: T.roast1.sub, dur: raw.consts.roast1 },
          { id: "flip", alert: true, label: T.flip.label, sub: T.flip.sub,
            buttons: [{ label: T.flip.btn, to: "roast2" }] },
          { id: "roast2", label: T.roast2.label, sub: T.roast2.sub, dur: raw.consts.roast2 },
          { id: "check", alert: true, label: T.check.label, sub: T.check.sub,
            buttons: [{ label: T.check.btn, to: "done" }, { label: T.check.more, to: "roast2", dur: extra }] },
          { id: "done", label: T.done.label, sub: T.done.sub, final: true },
        ],
      },
    },
    storage: raw.storage,
    finish: wording(raw.finish.text),
  };

  // ---- Lua writer: raw UTF-8, only \\ " and newlines escaped ----
  const q = s => '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n") + '"';
  const ser = (v, ind) => {
    const pad = "    ".repeat(ind), pad2 = "    ".repeat(ind + 1);
    if (typeof v === "string") return q(v);
    if (typeof v === "number" || typeof v === "boolean") return String(v);
    if (Array.isArray(v)) {
      if (v.every(x => typeof x === "string")) return "{\n" + v.map(x => pad2 + q(x) + ",").join("\n") + "\n" + pad + "}";
      return "{\n" + v.map(x => pad2 + ser(x, ind + 1) + ",").join("\n") + "\n" + pad + "}";
    }
    const keys = Object.keys(v);
    return "{\n" + keys.map(k => pad2 + k + " = " + ser(v[k], ind + 1) + ",").join("\n") + "\n" + pad + "}";
  };
  const outPath = path.join(__dirname, "..", "kitchentimer.koplugin", "recipes", slug + ".lua");
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath,
    "-- Generated by tools/convert_phone_page.js from source/" + path.basename(src) + ". Do not edit by hand.\n" +
    "return " + ser(recipe, 0) + "\n");
  console.log("wrote", outPath, steps.length, "steps");
})().catch(e => { console.error(e.message); process.exit(1); });
