import {
  App,
  applyDocumentTheme,
  applyHostStyleVariables,
} from "@modelcontextprotocol/ext-apps";

export type Secret = {
  id: string;
  revision: string;
  name: string;
  kind: "aksk" | "token" | "database";
  provider: string;
  account: string;
  environment: string;
  tags: string[];
  notes: string;
  fields: string[];
  updatedAt: string;
  deletedAt: string | null;
  expiresAt: string | null;
};
export class ToolError extends Error {
  constructor(
    public code: string,
    message: string,
  ) {
    super(message);
  }
}
export const app = new App({ name: "AKSK Manager", version: "0.1.0" });
function theme() {
  const c = app.getHostContext();
  if (c?.theme) {
    applyDocumentTheme(c.theme);
    document.documentElement.dataset.theme = c.theme;
  }
  if (c?.styles?.variables) applyHostStyleVariables(c.styles.variables);
}
app.onhostcontextchanged = theme;
let connection: Promise<void> | undefined;
export function connect() {
  connection ??= app.connect().then(theme);
  return connection;
}
export async function call<T>(
  name: string,
  args: Record<string, unknown> = {},
): Promise<T> {
  const r = await app.callServerTool({ name, arguments: args });
  const payload =
    (r._meta as { private?: any } | undefined)?.private ?? r.structuredContent;
  if (!payload || payload.ok !== true) {
    throw new ToolError(
      payload?.error?.code ?? "REQUEST_FAILED",
      payload?.error?.message ?? "操作失败，请刷新后重试。",
    );
  }
  return payload.data as T;
}
