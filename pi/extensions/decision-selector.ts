import type { ExtensionAPI, ExtensionContext, KeybindingsManager, Theme } from "@earendil-works/pi-coding-agent";
import { SelectList, Text, truncateToWidth, type Component } from "@earendil-works/pi-tui";
import { Type, type Static } from "typebox";

const Params = Type.Object({
  question: Type.String({ minLength: 1, maxLength: 500 }),
  options: Type.Array(Type.Object({
    label: Type.String({ minLength: 1, maxLength: 120 }),
    description: Type.Optional(Type.String({ maxLength: 300 })),
  }), { minItems: 2, maxItems: 4 }),
  recommended: Type.Optional(Type.Integer({ minimum: 1, maximum: 4, description: "1-based option number; never auto-confirmed" })),
});

type Question = Static<typeof Params>;
type Answer = { status: "answered"; answer: string; index?: number } | { status: "cancelled" | "needs_input" };

// Never interpret model/user text as terminal controls. Text (not Markdown) renders labels.
function clean(text: string): string {
  return text.replace(/[\x00-\x1f\x7f-\x9f]/g, " ").trim();
}

export class DecisionSelector implements Component {
  private list: SelectList;
  private selected = 0;
  private labels: string[];

  constructor(
    private question: Question,
    private theme: Theme,
    private keys: KeybindingsManager,
    private done: (index: number | null) => void,
    private refresh: () => void,
  ) {
    this.labels = [...question.options.map((o, i) =>
      `${i + 1}. ${clean(o.label)}${i + 1 === question.recommended ? "  ★" : ""}`), "✎ Risposta libera…"];
    this.list = new SelectList(this.labels.map((label, i) => ({ value: String(i), label })), this.labels.length, {
      selectedPrefix: (s) => theme.fg("accent", s),
      selectedText: (s) => theme.bg("selectedBg", theme.fg("accent", s)),
      description: (s) => theme.fg("muted", s),
      scrollInfo: (s) => theme.fg("dim", s),
      noMatch: (s) => theme.fg("warning", s),
    });
  }

  handleInput(data: string): void {
    if (this.keys.matches(data, "tui.select.cancel")) { this.done(null); return; }
    if (this.keys.matches(data, "tui.select.confirm")) { this.done(this.selected); return; }
    if (this.keys.matches(data, "tui.select.up")) this.selected = Math.max(0, this.selected - 1);
    else if (this.keys.matches(data, "tui.select.down")) this.selected = Math.min(this.labels.length - 1, this.selected + 1);
    else if (/^[1-4]$/.test(data) && Number(data) <= this.question.options.length) this.selected = Number(data) - 1;
    else return;
    this.list.setSelectedIndex(this.selected);
    this.refresh();
  }

  render(width: number): string[] {
    if (width < 1) return [];
    const { theme } = this;
    const line = theme.fg("borderAccent", "─".repeat(width));
    const wrap = (s: string) => new Text(s, 0, 0).render(width);
    const option = this.question.options[this.selected];
    const detail = option
      ? `${clean(option.label)}${this.selected + 1 === this.question.recommended ? " · Consigliata" : ""}${option.description ? ` — ${clean(option.description)}` : ""}`
      : "Scrivi una risposta diversa dalle opzioni proposte.";
    const key = (id: "tui.select.confirm" | "tui.select.cancel") => this.keys.getKeys(id).join("/");
    return [
      line,
      ...wrap(theme.fg("accent", theme.bold(clean(this.question.question)))),
      "",
      ...this.list.render(width),
      "",
      ...wrap(theme.fg("muted", detail)),
      "",
      ...wrap(theme.fg("dim", `${this.keys.getKeys("tui.select.up").join("/")}/${this.keys.getKeys("tui.select.down").join("/")} muovi · 1–${this.question.options.length} evidenzia · ${key("tui.select.confirm")} scegli · ${key("tui.select.cancel")} annulla`)),
      line,
    ].map((s) => truncateToWidth(s, width));
  }

  invalidate(): void { this.list.invalidate(); }
}

export async function ask(question: Question, ctx: ExtensionContext, signal?: AbortSignal): Promise<Answer> {
  if (signal?.aborted) return { status: "cancelled" };
  if (!ctx.hasUI) return { status: "needs_input" };
  if (question.recommended && question.recommended > question.options.length) throw new Error("recommended is outside the option list");
  while (!signal?.aborted) {
    let selected: number | null;
    if (ctx.mode === "tui") {
      selected = await ctx.ui.custom<number | null>((tui, theme, keys, done) => {
        let closed = false;
        const finish = (value: number | null) => {
          if (closed) return;
          closed = true;
          signal?.removeEventListener("abort", onAbort);
          done(value);
        };
        const onAbort = () => finish(null);
        signal?.addEventListener("abort", onAbort, { once: true });
        if (signal?.aborted) queueMicrotask(onAbort);
        const selector = new DecisionSelector(question, theme, keys, finish, () => tui.requestRender());
        return {
          render: (width) => selector.render(width),
          handleInput: (data) => selector.handleInput(data),
          invalidate: () => selector.invalidate(),
          dispose: () => { closed = true; signal?.removeEventListener("abort", onAbort); },
        };
      });
    } else {
      // RPC hosts implement native dialogs, not custom terminal components.
      const labels = [...question.options.map((o, i) =>
        `${i + 1}. ${clean(o.label)}${i + 1 === question.recommended ? " ★" : ""}${o.description ? ` — ${clean(o.description)}` : ""}`), "Risposta libera…"];
      const value = await ctx.ui.select(clean(question.question), labels, { signal });
      selected = value === undefined ? null : labels.indexOf(value);
    }
    if (signal?.aborted || selected == null || selected < 0) return { status: "cancelled" };
    if (selected < question.options.length) {
      return { status: "answered", index: selected + 1, answer: question.options[selected].label };
    }
    const custom = await ctx.ui.input(clean(question.question), "La tua risposta…", { signal });
    if (signal?.aborted) return { status: "cancelled" };
    if (custom?.trim()) return { status: "answered", answer: custom.trim() };
    // Escape/empty free text returns to the list, never approves an option.
  }
  return { status: "cancelled" };
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "ask_user",
    label: "Decisione",
    description: "Ask one blocking decision with 2–4 concise options and optional recommendation. Free text is available. Do not repeat the question/options in chat or emit PI_CHOICES. Cancelled/needs_input is not approval: stop and wait for the user.",
    parameters: Params,
    executionMode: "sequential",
    async execute(_id, params, signal, _update, ctx) {
      const details = await ask(params, ctx, signal);
      const fallback = `${params.question}\n${params.options.map((o, i) => `${i + 1}. ${o.label}${o.description ? ` — ${o.description}` : ""}`).join("\n")}`;
      return {
        content: [{ type: "text", text: details.status === "answered"
          ? JSON.stringify(details)
          : details.status === "needs_input" ? `Input required; no choice made. Ask the user and wait.\n${fallback}`
          : "Selection cancelled; no choice made. Stop and wait for the user." }],
        details,
        // Avoid a redundant assistant turn (or immediate re-prompt) after cancellation.
        terminate: details.status === "cancelled",
      };
    },
    renderCall(args, theme) {
      return new Text(theme.fg("accent", "◇ ") + clean(args.question ?? "Decisione"), 0, 0);
    },
    renderResult(result, { expanded }, theme, context) {
      const answer = result.details as Answer | undefined;
      if (!answer) return new Text(result.content.filter((c) => c.type === "text").map((c) => c.text).join("\n"), 0, 0);
      let text = answer.status === "answered" ? theme.fg("success", `✓ ${clean(answer.answer)}`)
        : theme.fg("muted", answer.status === "cancelled" ? "Annullata · nessuna scelta" : "In attesa di risposta · nessuna scelta");
      if (expanded || answer.status === "needs_input") {
        const options = (context.args.options ?? []) as Question["options"];
        text += "\n" + options.map((o, i) => `${i + 1}. ${clean(o.label)}${o.description ? ` — ${clean(o.description)}` : ""}`).join("\n");
      }
      return new Text(text, 0, 0);
    },
  });

  pi.registerCommand("decision-demo", {
    description: "Preview the decision selector locally (no model call)",
    async handler(_args, ctx) {
      const result = await ask({
        question: "Come vuoi procedere?",
        options: [
          { label: "Piano essenziale", description: "Un solo documento sorgente, verifiche esplicite, niente duplicati." },
          { label: "Approfondisci un rischio", description: "Risolvi solo l'incertezza che può cambiare la scelta." },
        ],
        recommended: 1,
      }, ctx);
      if (ctx.hasUI) ctx.ui.notify(result.status === "answered" ? result.answer : "Nessuna scelta inviata all’agente", "info");
    },
  });
}
