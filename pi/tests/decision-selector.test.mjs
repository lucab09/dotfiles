import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

// Use the installed pi runtime: no vendored deps, installs, or model/API calls.
const packageDir = process.env.PI_PACKAGE_DIR || join(
  execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim(), "@earendil-works/pi-coding-agent",
);
const requirePi = createRequire(join(packageDir, "package.json"));
const { createJiti } = requirePi("jiti");
const jiti = createJiti(import.meta.url, {
  alias: Object.fromEntries(["@earendil-works/pi-tui", "typebox"].map((name) => [name, requirePi.resolve(name)])),
});
const { default: extension, DecisionSelector, ask } = await jiti.import(resolve(fileURLToPath(new URL("../extensions/decision-selector.ts", import.meta.url))));
const { visibleWidth } = await jiti.import(requirePi.resolve("@earendil-works/pi-tui"));
const theme = { fg: (_c, s) => s, bg: (_c, s) => s, bold: (s) => s };
const bindings = { "tui.select.up": "up", "tui.select.down": "down", "tui.select.confirm": "enter", "tui.select.cancel": "escape" };
const keys = { matches: (data, id) => bindings[id] === data, getKeys: (id) => [bindings[id]] };
const question = { question: "Quale direzione?", options: [
  { label: "Essenziale", description: "Riduci duplicati e passaggi" },
  { label: "Approfondita", description: "Verifica una decisione critica" },
], recommended: 1 };

function mount(q = question, customKeys = keys) {
  const answers = [];
  const component = new DecisionSelector(q, theme, customKeys, (answer) => answers.push(answer), () => {});
  return { component, answers };
}

function context(mode, custom, inputs = []) {
  return {
    mode, hasUI: mode === "tui" || mode === "rpc",
    ui: { custom, input: async () => inputs.shift() },
  };
}

function drive(events) {
  return (factory) => new Promise((done) => {
    const component = factory({ requestRender() {} }, theme, keys, done);
    for (const event of events.shift()) component.handleInput(event);
  });
}

test("registers the sequential tool and a no-model demo command", () => {
  const tools = [], commands = [];
  extension({ registerTool: (tool) => tools.push(tool), registerCommand: (name, def) => commands.push([name, def]) });
  assert.equal(tools[0].name, "ask_user");
  assert.equal(tools[0].executionMode, "sequential");
  assert.equal(commands[0][0], "decision-demo");
});

test("numbers highlight, only Enter confirms; recommendation never auto-answers", () => {
  const { component, answers } = mount();
  component.handleInput("2");
  assert.deepEqual(answers, []);
  component.handleInput("enter");
  assert.deepEqual(answers, [1]);
});

test("navigation clamps and cancellation is not approval", () => {
  const { component, answers } = mount();
  component.handleInput("up");
  component.handleInput("escape");
  assert.deepEqual(answers, [null]);
});

test("custom keybindings work", () => {
  const remapped = { ...keys, matches: (data, id) => ({ "tui.select.down": "j", "tui.select.confirm": "yes" })[id] === data };
  const { component, answers } = mount(question, remapped);
  component.handleInput("j");
  component.handleInput("yes");
  assert.deepEqual(answers, [1]);
});

test("render respects narrow widths, resize, unicode and invalidation", () => {
  const { component } = mount({ ...question, question: "決定 👩‍💻 ".repeat(15), options: [
    { label: "東京 ".repeat(25), description: "é 👩‍💻 ".repeat(40) }, question.options[1],
  ] });
  for (const width of [100, 20, 1, 2, 40, 0, 80]) {
    component.invalidate();
    for (const line of component.render(width)) assert.ok(visibleWidth(line) <= width, `${visibleWidth(line)} > ${width}`);
  }
});

test("labels cannot inject terminal controls", () => {
  const { component } = mount({ ...question, question: "Bad\x1b[2J\x07 title" });
  assert.ok(!component.render(80).join("\n").includes("\x1b"));
});

test("TUI answer includes selected label and stable 1-based index", async () => {
  const result = await ask(question, context("tui", drive([["down", "enter"]])));
  assert.deepEqual(result, { status: "answered", index: 2, answer: "Approfondita" });
});

test("free text and backing out to the list", async () => {
  const events = [["down", "down", "enter"], ["enter"]];
  assert.deepEqual(await ask(question, context("tui", drive(events), [undefined])), {
    status: "answered", index: 1, answer: "Essenziale",
  });
  assert.deepEqual(await ask(question, context("tui", drive([["down", "down", "enter"]]), ["  Altro  "])), {
    status: "answered", answer: "Altro",
  });
});

test("Esc stops and headless never opens UI or invents an answer", async () => {
  assert.deepEqual(await ask(question, context("tui", drive([["escape"]]))), { status: "cancelled" });
  for (const mode of ["print", "json"]) {
    assert.deepEqual(await ask(question, context(mode, () => assert.fail("must not open UI"))), { status: "needs_input" });
  }
});

test("RPC uses native select, including recommendation/description", async () => {
  const ctx = context("rpc", () => assert.fail("no custom UI in RPC"));
  ctx.ui.select = async (_q, options) => {
    assert.match(options[0], /★/);
    assert.match(options[0], /Riduci duplicati/);
    return options[1];
  };
  assert.deepEqual(await ask(question, ctx), { status: "answered", index: 2, answer: "Approfondita" });
  ctx.ui.select = async () => undefined;
  assert.deepEqual(await ask(question, ctx), { status: "cancelled" });
});

test("external abort closes pending TUI, also before opening", async () => {
  const controller = new AbortController();
  const ctx = context("tui", (factory) => new Promise((done) => {
    factory({ requestRender() {} }, theme, keys, done);
    controller.abort();
  }));
  assert.deepEqual(await ask(question, ctx, controller.signal), { status: "cancelled" });
  assert.deepEqual(await ask(question, context("tui", () => assert.fail("already aborted")), controller.signal), { status: "cancelled" });
});

test("headless tool permits a plain-text question, not a silent terminating turn", async () => {
  let tool;
  extension({ registerTool: (t) => { tool = t; }, registerCommand() {} });
  const result = await tool.execute("id", question, undefined, undefined, context("print"));
  assert.equal(result.terminate, false);
  assert.equal(result.details.status, "needs_input");
  assert.match(result.content[0].text, /Ask the user and wait/);
});

test("cancellation terminates the tool turn and compact rendering does not repeat options", async () => {
  let tool;
  extension({ registerTool: (t) => { tool = t; }, registerCommand() {} });
  const result = await tool.execute("id", question, undefined, undefined, context("tui", drive([["escape"]])));
  assert.equal(result.terminate, true);
  const rendered = tool.renderResult(result, { expanded: false }, theme, { args: question }).render(80).join("\n");
  assert.ok(!rendered.includes("Essenziale"));
});
