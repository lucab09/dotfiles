import { basename, dirname } from "node:path";
import { readFileSync } from "node:fs";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";

type RateLimit = { percent: number; resetAt?: number };
type ProviderRateLimits = { fiveHour?: RateLimit; sevenDay?: RateLimit };
type LineStats = { added: number; removed: number };

const writeBefore = new Map<string, string | undefined>();

function countLines(text: string): number {
  if (!text) return 0;
  return text.split("\n").length - (text.endsWith("\n") ? 1 : 0);
}

function countPatch(patch: string): LineStats {
  let added = 0;
  let removed = 0;
  for (const line of patch.split("\n")) {
    if (line.startsWith("+++") || line.startsWith("---")) continue;
    if (line.startsWith("+")) added++;
    else if (line.startsWith("-")) removed++;
  }
  return { added, removed };
}

function countWrite(oldText: string | undefined, newText: string): LineStats {
  if (oldText === undefined) return { added: countLines(newText), removed: 0 };

  const oldLines = oldText.split("\n");
  const newLines = newText.split("\n");
  let start = 0;
  while (start < oldLines.length && start < newLines.length && oldLines[start] === newLines[start]) start++;

  let oldEnd = oldLines.length - 1;
  let newEnd = newLines.length - 1;
  while (oldEnd >= start && newEnd >= start && oldLines[oldEnd] === newLines[newEnd]) {
    oldEnd--;
    newEnd--;
  }

  return {
    added: Math.max(0, newEnd - start + 1),
    removed: Math.max(0, oldEnd - start + 1),
  };
}

function restoredLineStats(ctx: ExtensionContext): LineStats {
  let added = 0;
  let removed = 0;
  const calls = new Map<string, { name: string; arguments: Record<string, unknown> }>();

  for (const entry of ctx.sessionManager.getBranch()) {
    if (entry.type !== "message") continue;
    const message = entry.message;

    if (message.role === "assistant") {
      for (const part of message.content) {
        if (part.type === "toolCall") calls.set(part.id, { name: part.name, arguments: part.arguments });
      }
      continue;
    }

    if (message.role !== "toolResult" || message.isError) continue;
    const call = calls.get(message.toolCallId);
    if (message.toolName === "edit") {
      const patch = (message.details as { patch?: unknown } | undefined)?.patch;
      if (typeof patch === "string") {
        const stats = countPatch(patch);
        added += stats.added;
        removed += stats.removed;
      }
    } else if (message.toolName === "write" && call?.name === "write") {
      const content = call.arguments.content;
      if (typeof content === "string") added += countLines(content);
    }
  }

  return { added, removed };
}

function shortPath(path: string): string {
  const home = process.env.HOME;
  if (home && path === home) return "~";
  const base = basename(path);
  const parent = basename(dirname(path));
  return parent && parent !== "/" && parent !== "." ? `…/${parent}/${base}` : path;
}

function displayModel(ctx: ExtensionContext): string {
  return ctx.model?.name || ctx.model?.id || "No model";
}

function parseNumber(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const number = Number(value);
  return Number.isFinite(number) ? number : undefined;
}

function parseReset(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const numeric = Number(value);
  if (Number.isFinite(numeric)) return numeric > 10_000_000_000 ? numeric : numeric * 1000;
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? undefined : parsed;
}

function readRate(headers: Record<string, string>, window: "5h" | "7d"): RateLimit | undefined {
  const normalized = Object.fromEntries(Object.entries(headers).map(([key, value]) => [key.toLowerCase(), value]));
  const prefixes = [
    `anthropic-ratelimit-unified-${window}`,
    `anthropic-ratelimit-${window}`,
    `x-ratelimit-${window}`,
  ];

  for (const prefix of prefixes) {
    let utilization = parseNumber(normalized[`${prefix}-utilization`] ?? normalized[`${prefix}-used-percentage`]);
    if (utilization === undefined) {
      const limit = parseNumber(normalized[`${prefix}-limit`]);
      const remaining = parseNumber(normalized[`${prefix}-remaining`]);
      if (limit && remaining !== undefined) utilization = 1 - remaining / limit;
    }
    if (utilization === undefined) continue;
    const percent = utilization <= 1 ? utilization * 100 : utilization;
    return {
      percent: Math.max(0, Math.min(100, Math.round(percent))),
      resetAt: parseReset(normalized[`${prefix}-reset`] ?? normalized[`${prefix}-resets-at`]),
    };
  }
  return undefined;
}

function formatReset(timestamp: number | undefined, mode: "clock" | "date"): string {
  if (!timestamp) return "";
  const date = new Date(timestamp);
  if (mode === "clock") {
    return new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", hour12: true })
      .format(date)
      .replace(" ", "")
      .toLowerCase();
  }
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric" }).format(date).toLowerCase();
}

function parseUsageRate(value: unknown): RateLimit | undefined {
  if (!value || typeof value !== "object") return undefined;
  const data = value as { utilization?: unknown; used_percentage?: unknown; resets_at?: unknown };
  const rawPercent = Number(data.utilization ?? data.used_percentage);
  if (!Number.isFinite(rawPercent)) return undefined;
  return {
    percent: Math.max(0, Math.min(100, Math.round(rawPercent <= 1 ? rawPercent * 100 : rawPercent))),
    resetAt: parseReset(data.resets_at == null ? undefined : String(data.resets_at)),
  };
}

function parseCodexUsageRate(value: unknown): RateLimit | undefined {
  if (!value || typeof value !== "object") return undefined;
  const data = value as { used_percent?: unknown; reset_at?: unknown };
  const percent = Number(data.used_percent);
  if (!Number.isFinite(percent)) return undefined;
  return {
    percent: Math.max(0, Math.min(100, Math.round(percent))),
    resetAt: parseReset(data.reset_at == null ? undefined : String(data.reset_at)),
  };
}

function classifyCodexUsageRates(value: unknown): ProviderRateLimits {
  if (!value || typeof value !== "object") return {};
  const rateLimit = value as { primary_window?: unknown; secondary_window?: unknown };
  const windows = [rateLimit.primary_window, rateLimit.secondary_window];
  const result: ProviderRateLimits = {};

  for (const [index, value] of windows.entries()) {
    if (!value || typeof value !== "object") continue;
    const window = value as { limit_window_seconds?: unknown };
    const durationSeconds = Number(window.limit_window_seconds);
    const rate = parseCodexUsageRate(window);
    if (!rate) continue;

    if (Number.isFinite(durationSeconds) && Math.abs(durationSeconds - 18_000) <= 60) {
      result.fiveHour ??= rate;
    } else if (Number.isFinite(durationSeconds) && Math.abs(durationSeconds - 604_800) <= 60) {
      result.sevenDay ??= rate;
    } else if (index === 0) {
      result.fiveHour ??= rate;
    } else {
      result.sevenDay ??= rate;
    }
  }
  return result;
}

function extractCodexAccountId(token: string): string | undefined {
  try {
    const payload = JSON.parse(Buffer.from(token.split(".")[1] || "", "base64url").toString("utf8"));
    const accountId = payload?.["https://api.openai.com/auth"]?.chatgpt_account_id;
    return typeof accountId === "string" && accountId ? accountId : undefined;
  } catch {
    return undefined;
  }
}

export default function (pi: ExtensionAPI) {
  let lineStats: LineStats = { added: 0, removed: 0 };
  const ratesByProvider: Record<string, ProviderRateLimits> = {
    anthropic: {},
    "openai-codex": {},
  };
  let requestRender: (() => void) | undefined;
  let rateFetchController: AbortController | undefined;
  const lastRateFetch = new Map<string, number>();

  const refreshSubscriptionRates = async (ctx: ExtensionContext) => {
    const provider = ctx.model?.provider;
    if (provider !== "anthropic" && provider !== "openai-codex") return;
    if (Date.now() - (lastRateFetch.get(provider) ?? 0) < 60_000) return;
    lastRateFetch.set(provider, Date.now());

    try {
      const auth = await ctx.modelRegistry.getProviderAuth(provider);
      const token = auth?.auth.apiKey;
      if (!token) return;

      let endpoint: string;
      let headers: Record<string, string>;
      if (provider === "anthropic") {
        if (!token.startsWith("sk-ant-oat")) return;
        endpoint = "https://api.anthropic.com/api/oauth/usage";
        headers = {
          authorization: `Bearer ${token}`,
          "anthropic-beta": "oauth-2025-04-20",
          "user-agent": "claude-cli/2.1.241",
          "x-app": "cli",
        };
      } else {
        const accountId = extractCodexAccountId(token);
        if (!accountId) return;
        endpoint = "https://chatgpt.com/backend-api/wham/usage";
        headers = {
          authorization: `Bearer ${token}`,
          "chatgpt-account-id": accountId,
          "openai-beta": "codex-1",
          originator: "pi",
          "user-agent": "codex-cli",
        };
      }

      rateFetchController?.abort();
      const controller = new AbortController();
      rateFetchController = controller;
      const timeout = setTimeout(() => controller.abort(), 5_000);
      try {
        const response = await fetch(endpoint, { headers, signal: controller.signal });
        if (!response.ok) return;
        const payload = (await response.json()) as Record<string, any>;
        const current = ratesByProvider[provider];
        if (provider === "anthropic") {
          current.fiveHour = parseUsageRate(payload.five_hour) ?? current.fiveHour;
          current.sevenDay = parseUsageRate(payload.seven_day) ?? current.sevenDay;
        } else {
          const codexRates = classifyCodexUsageRates(payload.rate_limit);
          current.fiveHour = codexRates.fiveHour ?? current.fiveHour;
          current.sevenDay = codexRates.sevenDay ?? current.sevenDay;
        }
        requestRender?.();
      } finally {
        clearTimeout(timeout);
      }
    } catch {
      // Subscription usage is best-effort; plain API-key providers do not expose these windows.
    }
  };

  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    lineStats = restoredLineStats(ctx);

    void refreshSubscriptionRates(ctx);

    ctx.ui.setFooter((tui, theme, footerData) => {
      requestRender = () => tui.requestRender();
      const unsubscribeBranch = footerData.onBranchChange(requestRender);

      const colorForPercent = (percent: number) =>
        percent > 80 ? "error" : percent > 50 ? "warning" : "success";

      const rateRow = (label: string, rate: RateLimit, mode: "clock" | "date") => {
        const color = colorForPercent(rate.percent);
        const filled = Math.max(0, Math.min(14, Math.round((rate.percent * 14) / 100)));
        const bar = theme.fg(color, "█".repeat(filled)) + theme.fg("dim", "░".repeat(14 - filled));
        const reset = formatReset(rate.resetAt, mode);
        return (
          theme.fg("dim", label.padEnd(7)) +
          ` ${bar}  ` +
          theme.fg(color, `${String(rate.percent).padStart(3)}%`) +
          (reset ? theme.fg("dim", `  ↻ ${reset}`) : "")
        );
      };

      return {
        dispose() {
          unsubscribeBranch();
          requestRender = undefined;
        },
        invalidate() {},
        render(width: number): string[] {
          const usage = ctx.getContextUsage();
          const percent = usage?.percent == null ? undefined : Math.round(usage.percent);
          const tokens = usage?.tokens == null ? undefined : usage.tokens;
          const contextWindow = usage?.contextWindow || ctx.model?.contextWindow;
          const separator = theme.fg("dim", "|");
          const dim = (text: string) => theme.fg("dim", text);

          const model = displayModel(ctx);
          const modelLower = `${ctx.model?.id || ""} ${model}`.toLowerCase();
          const modelText = modelLower.includes("sonnet")
            ? `\x1b[38;5;80m${model}\x1b[0m`
            : modelLower.includes("opus")
              ? `\x1b[38;5;141m${model}\x1b[0m`
              : modelLower.includes("fable")
                ? `\x1b[38;5;215m${model}\x1b[0m`
                : theme.fg("text", model);

          let line = modelText;
          if (percent !== undefined) {
            const contextColor = colorForPercent(percent);
            let contextText = theme.fg(contextColor, `${percent}%`);
            if (tokens !== undefined && contextWindow) {
              contextText += dim(` (${Math.floor(tokens / 1000)}k/${Math.floor(contextWindow / 1000)}k)`);
            }
            line += ` ${separator} ${contextText}`;
          }

          const branch = footerData.getGitBranch();
          line += ` ${separator} ${dim(shortPath(ctx.cwd) + (branch ? ` (${branch})` : ""))}`;

          if (lineStats.added || lineStats.removed) {
            line +=
              ` ${separator} ` +
              theme.fg("success", `+${lineStats.added}`) +
              separator +
              theme.fg("error", `-${lineStats.removed}`);
          }

          line += ` ${separator} ${dim("•")} ${dim(ctx.thinkingLevel || "off")}`;
          const lines = [truncateToWidth(line, width, "…")];

          const providerRates = ratesByProvider[ctx.model?.provider || ""];
          if (providerRates?.fiveHour || providerRates?.sevenDay) {
            lines.push("");
            if (providerRates.fiveHour) {
              lines.push(truncateToWidth(rateRow("5-hour", providerRates.fiveHour, "clock"), width, "…"));
            }
            if (providerRates.sevenDay) {
              lines.push(truncateToWidth(rateRow("7-day", providerRates.sevenDay, "date"), width, "…"));
            }
            lines.push("");
          }
          return lines;
        },
      };
    });
  });

  pi.on("tool_call", (event, ctx) => {
    if (event.toolName !== "write") return;
    const path = event.input.path;
    if (typeof path !== "string") return;
    try {
      const absolutePath = path.startsWith("/") ? path : `${ctx.cwd}/${path}`;
      writeBefore.set(event.toolCallId, readFileSync(absolutePath, "utf8"));
    } catch {
      writeBefore.set(event.toolCallId, undefined);
    }
  });

  pi.on("tool_result", (event) => {
    if (event.isError) {
      writeBefore.delete(event.toolCallId);
      return;
    }

    let stats: LineStats | undefined;
    if (event.toolName === "edit") {
      const patch = (event.details as { patch?: unknown } | undefined)?.patch;
      if (typeof patch === "string") stats = countPatch(patch);
    } else if (event.toolName === "write") {
      const content = event.input.content;
      if (typeof content === "string") stats = countWrite(writeBefore.get(event.toolCallId), content);
      writeBefore.delete(event.toolCallId);
    }

    if (stats) {
      lineStats.added += stats.added;
      lineStats.removed += stats.removed;
      requestRender?.();
    }
  });

  pi.on("after_provider_response", (event, ctx) => {
    if (ctx.model?.provider === "anthropic") {
      const current = ratesByProvider.anthropic;
      current.fiveHour = readRate(event.headers, "5h") ?? current.fiveHour;
      current.sevenDay = readRate(event.headers, "7d") ?? current.sevenDay;
      requestRender?.();
    }
    void refreshSubscriptionRates(ctx);
  });

  pi.on("model_select", (_event, ctx) => {
    requestRender?.();
    void refreshSubscriptionRates(ctx);
  });
  pi.on("thinking_level_select", () => requestRender?.());
  pi.on("session_shutdown", () => {
    rateFetchController?.abort();
    rateFetchController = undefined;
    writeBefore.clear();
    requestRender = undefined;
  });
}
