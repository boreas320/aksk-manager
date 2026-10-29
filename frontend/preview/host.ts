/** Browser-only MCP host for live preview and production-bundle UI tests.
 * No native bridge, HTTP backend, localStorage or real credentials.
 * Keep the implementation self-contained so Playwright can inject this function.
 */
export type PreviewOptions = {
  html?: string;
  empty?: boolean;
  blocked?: boolean;
  conflict?: boolean;
  dark?: boolean;
  searchResults?: Record<string, { ids: string[]; delay?: number }>;
};

export function mountPreviewHost(options: PreviewOptions = {}) {
  const frame = document.querySelector<HTMLIFrameElement>('iframe')!;
  const base = {
    revision: "rev-1", provider: "AWS", account: "billing-prod", environment: "生产",
    tags: ["账单", "只读"], notes: "仅用于查询账单与资源。", updatedAt: "2026-10-29T10:00:00Z",
    deletedAt: null as string | null, expiresAt: null,
  };
  type Item = typeof base & { id: string; name: string; kind: string; values: Record<string, string> };
  const fixtures: Item[] = [
    { ...base, id: "demo-1", name: "生产账单 · 只读", kind: "aksk",
      values: { access_key: "SYNTHETIC_ACCESS", secret_key: "SYNTHETIC_SECRET" } },
    { ...base, id: "demo-2", name: "代码仓库访问", kind: "token", provider: "GitHub",
      account: "personal", environment: "个人", tags: ["开发"],
      values: { token: "SYNTHETIC_TOKEN" } },
    { ...base, id: "demo-3", name: "测试环境资源查询", kind: "database", provider: "华为云",
      account: "", environment: "测试", tags: ["数据库", "测试"],
      notes: "数据库连接预览，演示主机不存在。",
      values: { engine: "PostgreSQL", host: "db.example.invalid", port: "5432", database: "demo_ledger",
        username: "demo_reader", password: "SYNTHETIC_DATABASE_PASSWORD", ssl_mode: "require" } },
  ];
  let items: Item[] = options.empty ? [] : structuredClone(fixtures);
  let dark = options.dark ?? false;
  let blocked = options.blocked ?? false;
  let conflict = options.conflict ?? false;
  const testWindow = window as typeof window & { calls: unknown[]; contextLeaks: unknown[] };
  testWindow.calls = [];
  testWindow.contextLeaks = [];
  const metadata = ({ values, ...item }: Item) => ({ ...item, fields: Object.keys(values).sort() });
  const normalize = (s: string) => s.normalize("NFKD").replace(/\p{M}/gu, "").toLowerCase();
  const labels: Record<string, string> = { aksk: "云访问密钥 AK/SK AK SK", token: "API Token 令牌",
    database: "数据库连接 数据库名", access_key: "Access Key", secret_key: "Secret Key",
    session_token: "Session Token", engine: "数据库类型", host: "主机", port: "端口",
    username: "用户名", password: "密码", ssl_mode: "TLS 模式 SSL" };
  function matches(item: Item, query: string) {
    const text = [JSON.stringify(metadata(item)), labels[item.kind],
      ...Object.keys(item.values).map(k => labels[k] ?? k),
      ...Object.values(item.values)].join(" ");
    return normalize(query).trim().split(/\s+/).every(t => normalize(text).includes(t));
  }
  function fail(code: string, message: string): never { throw { code, message }; }
  function find(id: string) {
    const item = items.find(i => i.id === id);
    if (!item) fail("NOT_FOUND", "条目不存在。");
    return item;
  }
  function current(a: Record<string, any>) {
    const item = find(a.secret_id);
    if (item.revision !== a.revision) fail("CONFLICT", "条目已变化，请刷新。");
    return item;
  }
  function tool(name: string, a: Record<string, any>) {
    if (blocked) fail("SIGNING_REQUIRED", "本地组件缺少匹配的 Mac 配置描述文件，请重新签名构建。");
    switch (name) {
      case "ui_status": return { keychain: "available", remote_verified: false };
      case "ui_list": {
        const answer = options.searchResults?.[a.query];
        return items.filter(i => !!i.deletedAt === !!a.trash &&
          (answer ? answer.ids.includes(i.id) : matches(i, a.query ?? ""))).map(metadata);
      }
      case "get_secret_metadata": return metadata(find(a.secret_id));
      case "ui_reveal": {
        const item = current(a);
        if (item.deletedAt) fail("TRASHED", "请先恢复条目。");
        return { values: { ...item.values } };
      }
      case "ui_save": {
        if (conflict) fail("CONFLICT", "条目已发生变化，请重新打开编辑。");
        const r = a.record;
        const old = r.id ? find(r.id) : undefined;
        if (old && old.revision !== r.revision) fail("CONFLICT", "条目已发生变化，请重新打开编辑。");
        if (old?.deletedAt) fail("TRASHED", "请先恢复条目。");
        const values: Record<string, string> = Object.fromEntries(Object.entries(
          r.values ?? (old && old.kind === r.kind ? old.values : {})
        ).filter(([, value]) => typeof value === "string" && value !== "")) as Record<string, string>;
        const required = r.kind === "aksk" ? ["access_key", "secret_key"] :
          r.kind === "database" ? ["engine", "host"] : ["token"];
        if (!r.name?.trim() || !["aksk", "token", "database"].includes(r.kind) ||
          required.some(k => !values[k]?.trim())) fail("INVALID_INPUT", "请填写必填字段。");
        if (r.kind === "database" && values.port && (!/^\d+$/.test(values.port) ||
          +values.port < 1 || +values.port > 65535)) fail("INVALID_INPUT", "端口必须为 1–65535。");
        const item: Item = { ...base, ...r, name: r.name.trim(), values,
          id: old?.id ?? crypto.randomUUID(), revision: crypto.randomUUID(),
          updatedAt: new Date().toISOString(), deletedAt: null };
        items = [...items.filter(i => i.id !== item.id), item];
        return metadata(item);
      }
      case "ui_trash": case "ui_restore": case "ui_purge": {
        const item = current(a);
        if (name === "ui_purge") {
          if (!item.deletedAt) fail("NOT_TRASHED", "请先移入回收站。");
          items = items.filter(i => i.id !== item.id);
          return { id: item.id, removed: true };
        }
        item.deletedAt = name === "ui_trash" ? new Date().toISOString() : null;
        item.updatedAt = new Date().toISOString();
        item.revision = crypto.randomUUID();
        return metadata(item);
      }
      default: fail("PREVIEW_ONLY", "预览只支持界面操作，不执行本地命令。");
    }
  }
  const timers = new Set<ReturnType<typeof setTimeout>>();
  function onMessage(e: MessageEvent) {
    if (e.source !== frame.contentWindow || !e.data?.jsonrpc) return;
    const m = e.data;
    if (["ui/update-model-context", "ui/message"].includes(m.method)) testWindow.contextLeaks.push(m.params);
    if (m.id === undefined) return;
    let result: any = {};
    let delay = 0;
    if (m.method === "ui/initialize") result = {
      protocolVersion: "2026-01-26", hostInfo: { name: "AKSK local preview", version: "1.0.0" },
      hostCapabilities: { serverTools: {}, serverResources: {} },
      hostContext: { theme: dark ? "dark" : "light", displayMode: "fullscreen",
        availableDisplayModes: ["fullscreen"] },
    };
    if (m.method === "tools/call") {
      const { name, arguments: a = {} } = m.params;
      // Test instrumentation exists only in this mock host's memory.
      testWindow.calls.push({ name, args: a });
      let payload;
      try { payload = { ok: true, data: tool(name, a) }; }
      catch (error) { payload = { ok: false, error }; }
      result = name.startsWith("ui_")
        ? { content: [{ type: "text", text: "界面操作完成。" }], _meta: { private: payload }, isError: !payload.ok }
        : { content: [], structuredContent: payload, isError: !payload.ok };
      delay = name === "ui_list" ? options.searchResults?.[a.query]?.delay ?? 0 : 0;
    }
    const timer = setTimeout(() => {
      timers.delete(timer);
      frame.contentWindow?.postMessage({ jsonrpc: "2.0", id: m.id, result }, location.origin);
    }, delay);
    timers.add(timer);
  }
  window.addEventListener("message", onMessage);
  if (options.html !== undefined) frame.srcdoc = options.html;
  return {
    reset(empty = false) { items = empty ? [] : structuredClone(fixtures); },
    setTheme(value: boolean) {
      dark = value;
      frame.contentWindow?.postMessage({ jsonrpc: "2.0", method: "ui/notifications/host-context-changed",
        params: { theme: dark ? "dark" : "light" } }, location.origin);
    },
    setScenario(value: string) { blocked = value === "blocked"; conflict = value === "conflict"; },
    dispose() { window.removeEventListener("message", onMessage); timers.forEach(clearTimeout); },
  };
}
