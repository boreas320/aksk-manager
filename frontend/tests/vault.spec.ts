import { test, expect, Page } from "@playwright/test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
const html = readFileSync(resolve("../src/aksk_manager/ui/index.html"), "utf8");
const fixture = {
  id: "demo-1",
  revision: "rev-1",
  name: "生产账单 · 只读",
  kind: "aksk",
  provider: "AWS",
  account: "billing-prod",
  environment: "生产",
  tags: ["账单", "只读"],
  notes: "仅用于查询账单与资源。",
  fields: ["access_key", "secret_key"],
  updatedAt: "2026-10-29T10:00:00Z",
  deletedAt: null,
  expiresAt: null,
};

async function host(
  page: Page,
  { empty = false, blocked = false, conflict = false, dark = false } = {},
) {
  await page.route("https://aksk.test/", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: '<html><body style="margin:0"><iframe title="AKSK Manager" allow="clipboard-write" style="width:100%;height:100vh;border:0"></iframe></body></html>',
    }),
  );
  await page.goto("https://aksk.test/");
  await page.evaluate(
    ({ html, fixture, empty, blocked, conflict, dark }) => {
      const frame = document.querySelector("iframe")!;
      let items: any[] = empty
        ? []
        : [
            fixture,
            {
              ...fixture,
              id: "demo-2",
              name: "代码仓库访问",
              kind: "token",
              provider: "GitHub",
              account: "personal",
              environment: "个人",
              tags: ["开发"],
              fields: ["token"],
            },
            {
              ...fixture,
              id: "demo-3",
              name: "测试环境资源查询",
              provider: "华为云",
              account: "sandbox",
              environment: "测试",
              tags: ["测试"],
            },
          ];
      (window as any).calls = [];
      (window as any).contextLeaks = [];
      window.addEventListener("message", (e) => {
        if (e.source !== frame.contentWindow || !e.data?.jsonrpc) return;
        const m = e.data;
        if (["ui/update-model-context", "ui/message"].includes(m.method))
          (window as any).contextLeaks.push(m.params);
        if (m.id === undefined) return;
        let result: any = {};
        if (m.method === "ui/initialize")
          result = {
            protocolVersion: "2026-01-26",
            hostInfo: { name: "test-host", version: "26.1029.1" },
            hostCapabilities: { serverTools: {}, serverResources: {} },
            hostContext: {
              theme: dark ? "dark" : "light",
              displayMode: "fullscreen",
              availableDisplayModes: ["fullscreen"],
            },
          };
        if (m.method === "tools/call") {
          const { name, arguments: a = {} } = m.params;
          (window as any).calls.push({ name, args: a });
          let data: any = {},
            error: any;
          if (name === "ui_status") {
            if (blocked)
              error = {
                code: "SIGNING_REQUIRED",
                message:
                  "本地组件缺少匹配的 Mac 配置描述文件，请重新签名构建。",
              };
            else data = { keychain: "available", remote_verified: false };
          }
          if (name === "ui_list")
            data = items.filter((i) => !!i.deletedAt === !!a.trash);
          if (name === "get_secret_metadata")
            data = items.find((i) => i.id === a.secret_id);
          if (name === "ui_reveal")
            data = {
              values: {
                access_key: "SYNTHETIC_ACCESS",
                secret_key: "SYNTHETIC_SECRET",
                token: "SYNTHETIC_TOKEN",
              },
            };
          if (name === "ui_save") {
            if (conflict)
              error = {
                code: "CONFLICT",
                message: "条目已发生变化，请重新打开编辑。",
              };
            else {
              const r = a.record;
              data = {
                ...r,
                id: r.id || "new-item",
                revision: "new-rev",
                fields:
                  r.kind === "aksk" ? ["access_key", "secret_key"] : ["token"],
                updatedAt: new Date().toISOString(),
                deletedAt: null,
              };
              delete data.values;
              items = [...items.filter((i) => i.id !== data.id), data];
            }
          }
          if (["ui_trash", "ui_restore"].includes(name)) {
            items = items.map((i) =>
              i.id === a.secret_id
                ? {
                    ...i,
                    deletedAt:
                      name === "ui_trash" ? new Date().toISOString() : null,
                    revision: "changed",
                  }
                : i,
            );
          }
          if (name === "ui_purge")
            items = items.filter((i) => i.id !== a.secret_id);
          const payload = error ? { ok: false, error } : { ok: true, data };
          result = name.startsWith("ui_")
            ? {
                content: [{ type: "text", text: "界面操作完成。" }],
                _meta: { private: payload },
                isError: !!error,
              }
            : { content: [], structuredContent: payload };
        }
        frame.contentWindow!.postMessage(
          { jsonrpc: "2.0", id: m.id, result },
          "*",
        );
      });
      frame.srcdoc = html;
    },
    { html, fixture, empty, blocked, conflict, dark },
  );
  const ui = page.frameLocator("iframe");
  await expect(ui.locator(".status-strip")).toContainText(
    blocked ? "等待本地组件就绪" : "本机钥匙串可访问",
  );
  return ui;
}

test("search, filtering and details use metadata without revealing secrets", async ({
  page,
}) => {
  const ui = await host(page);
  await expect(ui.locator(".secret-row")).toHaveCount(3);
  await ui.getByLabel("搜索密钥").fill("billing");
  await expect(ui.locator(".secret-row")).toHaveCount(1);
  await ui.locator(".secret-row").click();
  await expect(ui.locator(".credentials")).toContainText("••••");
  expect(
    await page.evaluate(() =>
      (window as any).calls.some((c: any) => c.name === "ui_reveal"),
    ),
  ).toBe(false);
  await ui.getByLabel("搜索密钥").fill("");
  await ui.getByLabel("筛选厂商").selectOption("GitHub");
  await expect(ui.locator(".secret-row")).toHaveCount(1);
});

test("create, preserve existing secrets, trash and restore", async ({
  page,
}) => {
  const ui = await host(page, { empty: true });
  await ui
    .getByRole("button", { name: "添加密钥", exact: true })
    .first()
    .click();
  const dialog = ui.getByRole("dialog");
  await dialog.getByRole("button", { name: "API Token", exact: true }).click();
  await dialog.getByLabel("名称（必填）", { exact: true }).fill("测试 Token");
  await dialog
    .getByLabel("API Token（必填）", { exact: true })
    .fill("SYNTHETIC_NEW_TOKEN");
  await dialog.getByRole("button", { name: "保存密钥" }).click();
  await ui.locator(".secret-row").click();
  await ui.getByLabel("编辑密钥").click();
  await expect(ui.getByRole("dialog")).toContainText("保留现有密钥内容");
  await ui.getByLabel("名称（必填）", { exact: true }).fill("改名");
  await ui.getByRole("button", { name: "保存密钥" }).click();
  const saves = await page.evaluate(() =>
    (window as any).calls.filter((c: any) => c.name === "ui_save"),
  );
  expect(saves[1].args.record.values).toBeUndefined();
  await ui.locator(".secret-row").click();
  await ui.getByRole("button", { name: "移入回收站", exact: true }).click();
  await ui
    .getByRole("dialog")
    .getByRole("button", { name: "移入回收站", exact: true })
    .click();
  await expect(ui.locator(".secret-row")).toHaveCount(0);
  await ui.getByRole("button", { name: "回收站", exact: true }).click();
  await ui.locator(".secret-row").click();
  await ui.getByRole("button", { name: "恢复密钥" }).click();
  await expect(ui.locator(".secret-row")).toHaveCount(0);
});

test("database form saves private fields, filters and preserves existing configuration", async ({ page }) => {
  const ui = await host(page, { empty: true });
  await ui.getByRole("button", { name: "添加密钥", exact: true }).first().click();
  const dialog = ui.getByRole("dialog");
  await dialog.getByRole("button", { name: "数据库连接", exact: true }).click();
  await dialog.getByLabel("名称（必填）", { exact: true }).fill("测试数据库");
  await dialog.getByLabel("数据库类型（必填）", { exact: true }).fill("PostgreSQL");
  await dialog.getByLabel("主机（必填）", { exact: true }).fill("synthetic-db.internal");
  await dialog.getByLabel("端口（选填）", { exact: true }).fill("5432");
  await dialog.getByLabel("数据库名（选填）", { exact: true }).fill("ledger");
  await dialog.getByLabel("用户名（选填）", { exact: true }).fill("reader");
  await dialog.getByLabel("密码（选填）", { exact: true }).fill("SYNTHETIC_DATABASE_PASSWORD");
  await dialog.getByLabel("TLS 模式（选填）", { exact: true }).fill("verify-full");
  await expect(dialog.getByLabel("密码（选填）", { exact: true })).toHaveAttribute("type", "password");
  await dialog.getByRole("button", { name: "保存密钥" }).click();
  await ui.getByRole("button", { name: "数据库连接", exact: true }).click();
  await expect(ui.locator(".secret-row")).toHaveCount(1);
  await ui.locator(".secret-row").click();
  await expect(ui.locator(".credentials")).not.toContainText("SYNTHETIC_DATABASE_PASSWORD");
  await ui.getByLabel("编辑密钥").click();
  await expect(dialog).toContainText("保留现有连接配置，包括密码");
  await dialog.getByLabel("名称（必填）", { exact: true }).fill("数据库改名");
  await dialog.getByRole("button", { name: "保存密钥" }).click();
  const saves = await page.evaluate(() => (window as any).calls.filter((c: any) => c.name === "ui_save"));
  expect(saves[0].args.record.kind).toBe("database");
  expect(saves[0].args.record.values).toEqual({ engine: "PostgreSQL", host: "synthetic-db.internal", port: "5432", database: "ledger", username: "reader", password: "SYNTHETIC_DATABASE_PASSWORD", ssl_mode: "verify-full" });
  expect(saves[1].args.record.values).toBeUndefined();
  expect(await page.evaluate(() => (window as any).contextLeaks)).toEqual([]);
});

test("reveal is explicit, transient and never sent to model context", async ({
  page,
}) => {
  await page.clock.install();
  const ui = await host(page);
  await ui.locator(".secret-row").first().click();
  await ui.getByRole("button", { name: "显示", exact: true }).click();
  await expect(ui.locator(".credentials")).toContainText("SYNTHETIC_ACCESS");
  await ui.getByRole("button", { name: "隐藏", exact: true }).click();
  await expect(ui.locator(".credentials")).not.toContainText(
    "SYNTHETIC_ACCESS",
  );
  await ui.getByRole("button", { name: "显示", exact: true }).click();
  await expect(ui.locator(".credentials")).toContainText("SYNTHETIC_ACCESS");
  await page.clock.fastForward(31000);
  await expect(ui.locator(".credentials")).not.toContainText("SYNTHETIC_ACCESS");
  expect(await page.evaluate(() => (window as any).contextLeaks)).toEqual([]);
  expect(
    await ui.locator("body").evaluate(() => Object.keys(localStorage)),
  ).toEqual([]);
});

test("missing signing prerequisites are actionable and prevent mutation", async ({
  page,
}) => {
  const ui = await host(page, { blocked: true });
  await expect(ui.getByRole("alert")).toContainText("Mac 配置描述文件");
  await expect(
    ui.getByRole("button", { name: "添加密钥", exact: true }),
  ).toBeDisabled();
  await expect(ui.locator("body")).not.toContainText("主密码");
});

test("conflicts retain the form and display an actionable error", async ({
  page,
}) => {
  const ui = await host(page, { conflict: true });
  await ui.locator(".secret-row").first().click();
  await ui.getByLabel("编辑密钥").click();
  await ui.getByLabel("名称（必填）", { exact: true }).fill("冲突修改");
  await ui.getByRole("button", { name: "保存密钥" }).click();
  await expect(ui.getByRole("dialog").getByRole("alert")).toContainText(
    "重新打开编辑",
  );
  await expect(ui.getByLabel("名称（必填）", { exact: true })).toHaveValue("冲突修改");
});

for (const size of [
  { width: 1440, height: 900 },
  { width: 768, height: 1024 },
  { width: 375, height: 812 },
]) {
  test(`layout ${size.width} has no horizontal overflow`, async ({ page }) => {
    await page.setViewportSize(size);
    const ui = await host(page);
    await ui.locator(".secret-row").first().click();
    expect(
      await ui
        .locator("body")
        .evaluate(() => document.documentElement.scrollWidth <= innerWidth),
    ).toBe(true);
    await page.screenshot({
      path: `../docs/ui-${size.width}.png`,
      fullPage: true,
    });
  });
}

test("dark theme follows the host", async ({ page }) => {
  const ui = await host(page, { dark: true });
  await expect(ui.locator("html")).toHaveAttribute("data-theme", "dark");
  await page.screenshot({ path: "../docs/ui-dark.png", fullPage: true });
});
