import React, { useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  KeyRound,
  Plus,
  Search,
  Trash2,
  Cloud,
  Database,
  RefreshCw,
  ChevronRight,
  Eye,
  EyeOff,
  Copy,
  X,
  Pencil,
  ArrowLeft,
  RotateCcw,
  ShieldCheck,
  Fingerprint,
  Check,
} from "lucide-react";
import { call, connect, Secret } from "./api";
import "@openai/mcp-extensions/app/styles.css";
import "./style.css";

const fieldNames: Record<string, string> = {
  access_key: "Access Key",
  secret_key: "Secret Key",
  session_token: "Session Token",
  token: "API Token",
  engine: "数据库类型",
  host: "主机",
  port: "端口",
  database: "数据库名",
  username: "用户名",
  password: "密码",
  ssl_mode: "TLS 模式",
};
const kindNames: Record<string, string> = { aksk: "云访问密钥", token: "API Token", database: "数据库连接" };
const databaseFields = ["engine", "host", "port", "database", "username", "password", "ssl_mode"];
const providers = [
  "AWS",
  "华为云",
  "阿里云",
  "腾讯云",
  "GitHub",
  "OpenAI",
  "其他",
];
const date = (s: string) =>
  new Date(s).toLocaleString("zh-CN", {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });

function Manager() {
  const [ready, setReady] = useState(false),
    [checking, setChecking] = useState(true),
    [available, setAvailable] = useState(false);
  const [error, setError] = useState(""),
    [notice, setNotice] = useState("");
  const [items, setItems] = useState<Secret[]>([]),
    [trash, setTrash] = useState(false);
  const [query, setQuery] = useState(""),
    [kind, setKind] = useState(""),
    [provider, setProvider] = useState("");
  const [selected, setSelected] = useState<Secret | null>(null),
    [editing, setEditing] = useState<Secret | "new" | null>(null);
  const [confirm, setConfirm] = useState<{
    item: Secret;
    action: "trash" | "purge";
  } | null>(null);
  const [working, setWorking] = useState(false);
  const [matchingIds, setMatchingIds] = useState<Set<string> | null>(null);
  const generation = useRef(0);
  async function refresh(targetTrash = trash) {
    const id = ++generation.current;
    setChecking(true);
    setError("");
    try {
      await call("ui_status");
      const result = await call<Secret[]>("ui_list", { trash: targetTrash });
      const matches = query.trim()
        ? await call<Secret[]>("ui_list", { trash: targetTrash, query })
        : null;
      if (id !== generation.current) return;
      setAvailable(true);
      setItems(result);
      setMatchingIds(matches ? new Set(matches.map((i) => i.id)) : null);
      setSelected((old) =>
        old ? (result.find((i) => i.id === old.id) ?? null) : null,
      );
    } catch (e) {
      if (id !== generation.current) return;
      setAvailable(false);
      setItems([]);
      setSelected(null);
      setError((e as Error).message);
    } finally {
      if (id === generation.current) setChecking(false);
    }
  }
  useEffect(() => {
    let live = true;
    connect()
      .then(() => {
        if (live) setReady(true);
      })
      .catch(() => {
        if (live) {
          setChecking(false);
          setError("请从 Codex「更多工具 → AKSK Manager」打开管理界面。");
        }
      });
    return () => {
      live = false;
    };
  }, []);
  useEffect(() => {
    if (!ready) return;
    const timer = setTimeout(() => void refresh(trash), query.trim() ? 200 : 0);
    return () => {
      clearTimeout(timer);
      generation.current++;
    };
  }, [ready, trash, query]);
  useEffect(() => {
    if (!notice) return;
    const t = setTimeout(() => setNotice(""), 5000);
    return () => clearTimeout(t);
  }, [notice]);
  const filtered = useMemo(
    () =>
      items.filter(
        (i) =>
          (!kind || i.kind === kind) &&
          (!provider || i.provider === provider) &&
          (!matchingIds || matchingIds.has(i.id)),
      ),
    [items, kind, provider, matchingIds],
  );
  async function change(item: Secret, action: "trash" | "restore" | "purge") {
    setWorking(true);
    setError("");
    try {
      await call(`ui_${action}`, {
        secret_id: item.id,
        revision: item.revision,
      });
      setConfirm(null);
      setSelected(null);
      await refresh();
      setNotice(
        action === "restore"
          ? "已在本机恢复，iCloud 将同步此变更。"
          : action === "purge"
            ? "已从本机钥匙串删除，iCloud 将同步此变更。"
            : "已移入回收站，iCloud 将同步此变更。",
      );
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setWorking(false);
    }
  }
  return (
    <div className="vault">
      <aside className="sidebar">
        <div className="brand">
          <div className="brand-icon">
            <KeyRound size={22} />
          </div>
          <div>
            <strong>AKSK Manager</strong>
            <small>你的个人密钥库</small>
          </div>
        </div>
        <div className="nav-caption">密钥库</div>
        <button
          className={`nav-item ${!trash && !kind ? "active" : ""}`}
          onClick={() => {
            setTrash(false);
            setKind("");
            setSelected(null);
          }}
        >
          <KeyRound size={17} />
          全部密钥{!trash && <span>{items.length}</span>}
        </button>
        <button
          className={`nav-item ${!trash && kind === "aksk" ? "active" : ""}`}
          onClick={() => {
            setTrash(false);
            setKind("aksk");
            setSelected(null);
          }}
        >
          <Cloud size={17} />
          云访问密钥
        </button>
        <button
          className={`nav-item ${!trash && kind === "token" ? "active" : ""}`}
          onClick={() => {
            setTrash(false);
            setKind("token");
            setSelected(null);
          }}
        >
          <Fingerprint size={17} />
          API Token
        </button>
        <button
          className={`nav-item ${!trash && kind === "database" ? "active" : ""}`}
          onClick={() => { setTrash(false); setKind("database"); setSelected(null); }}
        >
          <Database size={17} />数据库连接
        </button>
        <div className="nav-divider" />
        <button
          className={`nav-item ${trash ? "active" : ""}`}
          onClick={() => {
            setTrash(true);
            setKind("");
            setSelected(null);
          }}
        >
          <Trash2 size={17} />
          回收站
        </button>
        <div className="sidebar-footer">
          <ShieldCheck size={19} />
          <div>
            <strong>Apple 钥匙串</strong>
            <small>由你的 Mac 保护</small>
          </div>
        </div>
      </aside>
      <main className={`main ${selected ? "has-selection" : ""}`}>
        <header className="page-header">
          <div>
            <div className="eyebrow">个人工作空间</div>
            <h1>
              {trash
                ? "回收站"
                : kindNames[kind] ?? "全部密钥"}
            </h1>
            <p>
              {trash
                ? "恢复暂时不用的密钥，或将它们彻底删除。"
                : "集中管理凭据，让 Codex 按需使用。"}
            </p>
          </div>
          {!trash && (
            <button
              className="primary"
              disabled={!available || checking}
              onClick={() => setEditing("new")}
            >
              <Plus size={17} />
              添加密钥
            </button>
          )}
        </header>
        <div className="status-strip">
          <Cloud size={16} />
          <span>
            {checking
              ? "正在检查本机钥匙串…"
              : available
                ? "本机钥匙串可访问"
                : "等待本地组件就绪"}
          </span>
          <span className="status-detail">同步由 iCloud 钥匙串管理</span>
          <button
            className="icon-button"
            aria-label="刷新"
            disabled={!ready || checking}
            onClick={() => refresh()}
          >
            <RefreshCw size={15} className={checking ? "spin" : ""} />
          </button>
        </div>
        {error && (
          <div className="alert" role="alert">
            {error}
          </div>
        )}
        {notice && (
          <div className="notice" role="status">
            <Check size={16} />
            {notice}
          </div>
        )}
        <div className="toolbar">
          <div className="search">
            <Search size={17} />
            <input
              aria-label="搜索密钥"
              placeholder="搜索全部信息（不含密钥值）"
              title="可搜索名称、厂商、账号、环境、标签、备注、类型、字段名及数据库连接信息；多个关键词用空格分隔。"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </div>
          <select
            aria-label="筛选厂商"
            value={provider}
            onChange={(e) => setProvider(e.target.value)}
          >
            <option value="">所有厂商</option>
            {[...new Set(items.map((i) => i.provider).filter(Boolean))]
              .sort()
              .map((p) => (
                <option key={p}>{p}</option>
              ))}
          </select>
        </div>
        <div className="content-columns">
          <section className="list-panel" aria-label="密钥列表">
            {filtered.length ? (
              <>
                <div className="list-header">
                  <span>名称 / 账号</span>
                  <span>环境</span>
                  <span>最近更新</span>
                </div>
                {filtered.map((item) => (
                  <button
                    className={`secret-row ${selected?.id === item.id ? "selected" : ""}`}
                    key={item.id}
                    onClick={() => setSelected(item)}
                  >
                    <div className="row-name">
                      <div className={`record-icon ${item.kind}`}>
                        {item.kind === "aksk" ? (
                          <Cloud size={20} />
                        ) : item.kind === "database" ? (
                          <Database size={20} />
                        ) : (
                          <KeyRound size={20} />
                        )}
                      </div>
                      <div>
                        <strong>{item.name}</strong>
                        <small>
                          {[item.provider, item.account]
                            .filter(Boolean)
                            .join(" · ") ||
                            kindNames[item.kind]}
                        </small>
                      </div>
                    </div>
                    <span className="environment">
                      {item.environment || "未设置"}
                    </span>
                    <span className="row-date">
                      {date(item.updatedAt)}
                      <ChevronRight size={15} />
                    </span>
                  </button>
                ))}
              </>
            ) : (
              <div className="empty">
                <div className="empty-mark">
                  {trash ? <Trash2 size={30} /> : <KeyRound size={32} />}
                </div>
                <h2>
                  {checking
                    ? "正在读取密钥库"
                    : !available
                      ? "连接你的系统钥匙串"
                      : items.length
                        ? "没有匹配的密钥"
                        : trash
                          ? "回收站是空的"
                          : "从第一把密钥开始"}
                </h2>
                <p>
                  {!available
                    ? "本地组件就绪后，即可在这里管理密钥。"
                    : items.length
                      ? "试试其他名称，或清除筛选条件。"
                      : trash
                        ? "移入回收站的条目会出现在这里。"
                        : "添加云访问密钥或 API Token，无需设置额外密码。"}
                </p>
                {available && !trash && !items.length && (
                  <button className="primary" onClick={() => setEditing("new")}>
                    <Plus size={16} />
                    添加密钥
                  </button>
                )}
              </div>
            )}
            <footer className="list-footer">
              {filtered.length} 个条目<span>仅显示本机已读取的内容</span>
            </footer>
          </section>
          {selected && (
            <Detail
              key={`${selected.id}:${selected.revision}`}
              item={selected}
              close={() => setSelected(null)}
              edit={async () => {
                try {
                  setEditing(
                    await call<Secret>("get_secret_metadata", {
                      secret_id: selected.id,
                    }),
                  );
                } catch (e) {
                  setError((e as Error).message);
                }
              }}
              change={(action) =>
                action === "restore"
                  ? change(selected, action)
                  : setConfirm({ item: selected, action })
              }
              notify={setNotice}
              error={setError}
              busy={working}
            />
          )}
        </div>
        <div className="bottom-note">
          <ShieldCheck size={14} />
          密钥保存在 Apple 钥匙串中 · Codex 使用引用执行命令
        </div>
      </main>
      {editing && (
        <Editor
          item={editing === "new" ? null : editing}
          close={() => setEditing(null)}
          saved={async () => {
            setEditing(null);
            await refresh();
            setNotice("已保存到本机钥匙串，iCloud 将同步此变更。");
          }}
        />
      )}
      {confirm && (
        <div className="overlay">
          <section
            className="modal confirm"
            role="dialog"
            aria-modal="true"
            aria-label="确认删除"
          >
            <div className="modal-heading">
              <h2>
                {confirm.action === "purge"
                  ? "彻底删除这把密钥？"
                  : "移入回收站？"}
              </h2>
              <button
                className="icon-button"
                aria-label="取消"
                disabled={working}
                onClick={() => setConfirm(null)}
              >
                <X size={18} />
              </button>
            </div>
            <p>{confirm.item.name}</p>
            <p className="muted">
              {confirm.action === "purge"
                ? "此操作无法撤销，并会通过 iCloud 从其他设备移除该条目。"
                : "Codex 将无法继续使用此条目。你可以在回收站恢复它。"}
            </p>
            <div className="modal-actions">
              <button disabled={working} onClick={() => setConfirm(null)}>
                取消
              </button>
              <button
                className="danger"
                disabled={working}
                onClick={() => change(confirm.item, confirm.action)}
              >
                {working
                  ? "处理中…"
                  : confirm.action === "purge"
                    ? "彻底删除"
                    : "移入回收站"}
              </button>
            </div>
          </section>
        </div>
      )}
    </div>
  );
}

function Detail({
  item,
  close,
  edit,
  change,
  notify,
  error,
  busy,
}: {
  item: Secret;
  close: () => void;
  edit: () => void;
  change: (a: "trash" | "restore" | "purge") => void;
  notify: (s: string) => void;
  error: (s: string) => void;
  busy: boolean;
}) {
  const [values, setValues] = useState<Record<string, string> | null>(null),
    [revealing, setRevealing] = useState(false);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  useEffect(() => {
    if (!values) return;
    const timer = setTimeout(() => setValues(null), 30000);
    const hide = () => {
      if (document.hidden) setValues(null);
    };
    document.addEventListener("visibilitychange", hide);
    return () => {
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", hide);
    };
  }, [values]);
  async function reveal() {
    if (values) {
      setValues(null);
      return;
    }
    setRevealing(true);
    try {
      const r = await call<{ values: Record<string, string> }>("ui_reveal", {
        secret_id: item.id,
        revision: item.revision,
      });
      if (mounted.current) setValues(r.values);
    } catch (e) {
      error((e as Error).message);
    } finally {
      if (mounted.current) setRevealing(false);
    }
  }
  async function copy(field: string) {
    try {
      const r =
        values ??
        (
          await call<{ values: Record<string, string> }>("ui_reveal", {
            secret_id: item.id,
            revision: item.revision,
          })
        ).values;
      await navigator.clipboard.writeText(r[field]);
      notify("已复制到系统剪贴板。");
    } catch {
      error("复制失败，请显示密钥后手动复制。");
    }
  }
  return (
    <aside className="detail">
      <div className="detail-top">
        <button className="icon-button" onClick={close} aria-label="关闭详情">
          <ArrowLeft size={18} />
        </button>
        <span>密钥详情</span>
        {!item.deletedAt && (
          <button className="icon-button" aria-label="编辑密钥" onClick={edit}>
            <Pencil size={16} />
          </button>
        )}
      </div>
      <div className="detail-title">
        <div className={`record-icon ${item.kind}`}>
          {item.kind === "aksk" ? <Cloud size={24} /> : item.kind === "database" ? <Database size={24} /> : <KeyRound size={24} />}
        </div>
        <h2>{item.name}</h2>
        <span className="pill">
          {item.kind === "aksk" ? "AK / SK" : kindNames[item.kind]}
        </span>
      </div>
      <dl>
        {[
          ["厂商", item.provider],
          ...(item.kind === "database" ? [] : [["账号", item.account]]),
          ["环境", item.environment],
        ].map(([k, v]) => (
          <div key={k}>
            <dt>{k}</dt>
            <dd>{v || "—"}</dd>
          </div>
        ))}
      </dl>
      {!item.deletedAt && (
        <section className="credentials">
          <div className="section-heading">
            <strong>凭据</strong>
            <button onClick={reveal} disabled={revealing}>
              {values ? <EyeOff size={14} /> : <Eye size={14} />}{" "}
              {values ? "隐藏" : "显示"}
            </button>
          </div>
          {item.fields.map((f) => (
            <div className="secret-field" key={f}>
              <label>{fieldNames[f] ?? f}</label>
              <div>
                <code>{values?.[f] ?? "••••••••••••••••"}</code>
                <button
                  className="icon-button"
                  aria-label={`复制 ${fieldNames[f] ?? f}`}
                  onClick={() => copy(f)}
                >
                  <Copy size={14} />
                </button>
              </div>
            </div>
          ))}
          {values && (
            <small className="muted">显示内容将在 30 秒后自动隐藏。</small>
          )}
        </section>
      )}
      {!!item.tags.length && (
        <div className="tags">
          {item.tags.map((t) => (
            <span key={t}>{t}</span>
          ))}
        </div>
      )}
      {item.notes && (
        <section className="notes">
          <strong>备注</strong>
          <p>{item.notes}</p>
        </section>
      )}
      <div className="detail-date">最近更新于 {date(item.updatedAt)}</div>
      <div className="detail-actions">
        {item.deletedAt ? (
          <>
            <button disabled={busy} onClick={() => change("restore")}>
              <RotateCcw size={15} />
              恢复密钥
            </button>
            <button
              className="danger-text"
              disabled={busy}
              onClick={() => change("purge")}
            >
              彻底删除
            </button>
          </>
        ) : (
          <button
            className="danger-text"
            disabled={busy}
            onClick={() => change("trash")}
          >
            <Trash2 size={15} />
            移入回收站
          </button>
        )}
      </div>
    </aside>
  );
}

function Editor({
  item,
  close,
  saved,
}: {
  item: Secret | null;
  close: () => void;
  saved: () => void;
}) {
  const [form, setForm] = useState({
    name: item?.name ?? "",
    kind: item?.kind ?? "aksk",
    provider: item?.provider ?? "",
    account: item?.account ?? "",
    environment: item?.environment ?? "",
    notes: item?.notes ?? "",
    expiresAt: item?.expiresAt ?? "",
    tags: item?.tags.join(", ") ?? "",
  });
  const [replace, setReplace] = useState(!item),
    [values, setValues] = useState<Record<string, string>>({});
  const [error, setError] = useState(""),
    [saving, setSaving] = useState(false);
  const fields =
    form.kind === "aksk"
      ? ["access_key", "secret_key", "session_token"]
      : form.kind === "database" ? databaseFields : ["token"];
  const requiredFields = form.kind === "database" ? ["engine", "host"] : form.kind === "aksk" ? ["access_key", "secret_key"] : ["token"];
  const update = (key: string, value: string) =>
    setForm((old) => ({ ...old, [key]: value }));
  async function submit(e: React.FormEvent) {
    e.preventDefault();
    setSaving(true);
    setError("");
    try {
      await call("ui_save", {
        record: {
          ...form,
          id: item?.id ?? "",
          revision: item?.revision ?? "",
          expiresAt: form.expiresAt || null,
          tags: [
            ...new Set(
              form.tags
                .split(/[,，]/)
                .map((t) => t.trim())
                .filter(Boolean),
            ),
          ],
          ...(replace ? { values } : {}),
        },
      });
      setValues({});
      saved();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setSaving(false);
    }
  }
  return (
    <div className="overlay">
      <form
        className="modal editor"
        role="dialog"
        aria-modal="true"
        aria-label={item ? "编辑密钥" : "添加密钥"}
        onSubmit={submit}
        autoComplete="off"
      >
        <div className="modal-heading">
          <div>
            <h2>{item ? "编辑密钥" : "添加密钥"}</h2>
            <p>保存在 Apple 钥匙串，通过 iCloud 同步。</p>
          </div>
          <button
            type="button"
            className="icon-button"
            aria-label="关闭编辑"
            disabled={saving}
            onClick={close}
          >
            <X size={19} />
          </button>
        </div>
        {error && (
          <div role="alert" className="alert">
            {error}
          </div>
        )}
        <div className="type-picker">
          <button
            type="button"
            className={form.kind === "aksk" ? "chosen" : ""}
            onClick={() => {
              update("kind", "aksk");
              setReplace(!item || item.kind !== "aksk");
              setValues({});
            }}
          >
            <Cloud size={18} />
            云访问密钥
          </button>
          <button
            type="button"
            className={form.kind === "token" ? "chosen" : ""}
            onClick={() => {
              update("kind", "token");
              setReplace(!item || item.kind !== "token");
              setValues({});
            }}
          >
            <KeyRound size={18} />
            API Token
          </button>
          <button type="button" className={form.kind === "database" ? "chosen" : ""}
            onClick={() => { update("kind", "database"); setReplace(!item || item.kind !== "database"); setValues({}); }}>
            <Database size={18} />数据库连接
          </button>
        </div>
        <label>
          名称（必填）
          <input
            autoFocus
            required
            maxLength={160}
            value={form.name}
            onChange={(e) => update("name", e.target.value)}
            placeholder="例如：生产环境只读账号"
          />
        </label>
        <div className="two">
          <label>
            厂商（选填）
            <input
              list="providers"
              maxLength={500}
              value={form.provider}
              onChange={(e) => update("provider", e.target.value)}
              placeholder="选择或输入厂商"
            />
            <datalist id="providers">
              {providers.map((p) => (
                <option value={p} key={p} />
              ))}
            </datalist>
          </label>
          {form.kind !== "database" && <label>
            账号（选填）
            <input
              maxLength={500}
              value={form.account}
              onChange={(e) => update("account", e.target.value)}
              placeholder="账号名或账号 ID"
            />
          </label>}
          <label>
            环境（选填）
            <input
              maxLength={500}
              value={form.environment}
              onChange={(e) => update("environment", e.target.value)}
              placeholder="生产 / 测试 / 个人"
            />
          </label>
        </div>
        <fieldset>
          <legend>{form.kind === "database" ? "连接配置" : "凭据"}</legend>
          {item && item.kind === form.kind && (
            <label className="checkbox">
              <input
                type="checkbox"
                checked={replace}
                onChange={(e) => {
                  setReplace(e.target.checked);
                  setValues({});
                }}
              />
              {form.kind === "database" ? "更新连接配置" : "更新密钥内容"}
            </label>
          )}
          {replace ? (
            fields.map((f) => (
              <label key={f}>
                {fieldNames[f]}
                {requiredFields.includes(f) ? "（必填）" : "（选填）"}
                <input
                  type={form.kind === "database" && f !== "password" ? "text" : "password"}
                  inputMode={f === "port" ? "numeric" : undefined}
                  pattern={f === "port" ? "[0-9]+" : undefined}
                  placeholder={f === "engine" ? "例如 PostgreSQL、MySQL、Redis" : f === "port" ? "留空使用客户端默认端口" : undefined}
                  autoComplete="new-password"
                  spellCheck={false}
                  required={requiredFields.includes(f)}
                  maxLength={16384}
                  value={values[f] ?? ""}
                  onChange={(e) =>
                    setValues((old) => ({ ...old, [f]: e.target.value }))
                  }
                />
              </label>
            ))
          ) : (
            <p className="muted">{form.kind === "database" ? "保留现有连接配置，包括密码。" : "保留现有密钥内容。"}</p>
          )}
        </fieldset>
        <label>
          标签（选填）
          <input
            value={form.tags}
            onChange={(e) => update("tags", e.target.value)}
            placeholder="用逗号分隔，例如：账单, 只读"
          />
        </label>
        <label>
          备注（选填）
          <textarea
            maxLength={4000}
            value={form.notes}
            onChange={(e) => update("notes", e.target.value)}
            placeholder="用途说明；请将秘密值填写在上方凭据栏。"
          />
        </label>
        <div className="modal-actions">
          <button type="button" disabled={saving} onClick={close}>
            取消
          </button>
          <button className="primary" disabled={saving}>
            {saving ? "正在保存…" : "保存密钥"}
          </button>
        </div>
      </form>
    </div>
  );
}
createRoot(document.getElementById("root")!).render(<Manager />);
