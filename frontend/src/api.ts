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
// Keep the initialization handshake aligned with the resource metadata. A host
// must not move an active credential editor into an offscreen inline chat card.
export const app = new App(
  { name: "AKSK Manager", version: "0.1.0" },
  { availableDisplayModes: ["fullscreen"] },
);
const requestOptions = { timeout: 15000, maxTotalTimeout: 15000 };
const writes = new Set(["ui_save", "ui_trash", "ui_restore", "ui_purge"]);
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
  connection ??= app.connect(undefined, requestOptions).then(theme);
  return connection;
}
export async function call<T>(
  name: string,
  args: Record<string, unknown> = {},
): Promise<T> {
  let r;
  try {
    r = await app.callServerTool({ name, arguments: args }, requestOptions);
  } catch {
    // A lost response does not prove that a mutation failed. Never retry it here,
    // and never surface transport diagnostics which may include tool arguments.
    throw new ToolError(
      writes.has(name) ? "WRITE_UNCONFIRMED" : "CONNECTION_UNAVAILABLE",
      writes.has(name)
        ? "未收到操作结果，可能已经保存。请关闭此弹窗并刷新核对记录，暂勿重复提交。"
        : "界面与本地服务的连接未响应。请点击刷新；若仍无响应，请重新打开 AKSK Manager。",
    );
  }
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
