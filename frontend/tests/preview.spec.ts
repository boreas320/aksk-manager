import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";

const url = "http://127.0.0.1:5174/preview.html";

test("live preview supports database search, CRUD, reveal and trash without a backend", async ({ page }) => {
  const requests: string[] = [];
  page.on("request", request => requests.push(request.url()));
  await page.goto(url);
  await expect(page.getByText("仅使用内存演示数据", { exact: false })).toBeVisible();
  const ui = page.frameLocator("iframe");
  await expect(ui.locator(".secret-row")).toHaveCount(3);
  await ui.getByLabel("搜索密钥").fill("postgresql demo_reader 5432");
  await expect(ui.locator(".secret-row")).toHaveCount(1);
  await ui.locator(".secret-row").click();
  await ui.getByRole("button", { name: "显示", exact: true }).click();
  await expect(ui.locator(".credentials")).toContainText("db.example.invalid");
  await expect(ui.locator(".credentials")).toContainText("SYNTHETIC_DATABASE_PASSWORD");
  await ui.getByLabel("编辑密钥").click();
  await ui.getByLabel("名称（必填）", { exact: true }).fill("预览数据库改名");
  await ui.getByRole("button", { name: "保存密钥" }).click();
  await expect(ui.locator(".secret-row")).toContainText("预览数据库改名");
  await ui.getByLabel("搜索密钥").fill("");
  await expect(ui.locator(".secret-row")).toHaveCount(3);
  await ui.getByRole("button", { name: "添加密钥", exact: true }).click();
  const dialog = ui.getByRole("dialog");
  await dialog.getByRole("button", { name: "API Token", exact: true }).click();
  await dialog.getByLabel("名称（必填）", { exact: true }).fill("预览新增");
  await dialog.getByLabel("API Token（必填）", { exact: true }).fill("DEMO_PREVIEW_TOKEN");
  await dialog.getByRole("button", { name: "保存密钥" }).click();
  await expect(ui.locator(".secret-row")).toHaveCount(4);
  await ui.locator(".secret-row").filter({ hasText: "预览新增" }).click();
  await ui.getByRole("button", { name: "移入回收站", exact: true }).click();
  await ui.getByRole("dialog").getByRole("button", { name: "移入回收站", exact: true }).click();
  await expect(ui.getByRole("dialog")).toHaveCount(0);
  await expect(ui.locator(".secret-row")).toHaveCount(3);
  await ui.getByRole("button", { name: "回收站", exact: true }).click();
  await expect(ui.locator(".secret-row")).toHaveCount(1);
  await ui.locator(".secret-row").click();
  await ui.getByRole("button", { name: "恢复密钥" }).click();
  await expect(ui.locator(".secret-row")).toHaveCount(0);
  await page.getByRole("button", { name: "重置演示数据" }).click();
  await expect(ui.locator(".secret-row")).toHaveCount(3);
  expect(requests.every(request => request.startsWith("http://127.0.0.1:5174/"))).toBe(true);
  expect(await page.evaluate(() => Object.keys(localStorage))).toEqual([]);
});

test("preview controls cover screen sizes, theme, empty, blocked and conflict states", async ({ page }) => {
  await page.goto(url);
  const ui = page.frameLocator("iframe");
  await expect(ui.locator(".secret-row")).toHaveCount(3);
  await page.getByLabel("尺寸").selectOption("390");
  await expect(page.locator("iframe")).toHaveCSS("width", "390px");
  await page.getByLabel("主题").selectOption("dark");
  await expect(ui.locator("html")).toHaveAttribute("data-theme", "dark");
  await page.getByLabel("状态").selectOption("empty");
  await expect(ui.locator(".list-panel")).toContainText("从第一把密钥开始");
  await page.getByLabel("状态").selectOption("blocked");
  await expect(ui.getByRole("alert")).toContainText("Mac 配置描述文件");
  await expect(ui.getByRole("button", { name: "添加密钥", exact: true })).toBeDisabled();
  await page.getByLabel("状态").selectOption("conflict");
  await ui.locator(".secret-row").first().click();
  await ui.getByLabel("编辑密钥").click();
  await ui.getByRole("button", { name: "保存密钥" }).click();
  await expect(ui.getByRole("dialog").getByRole("alert")).toContainText("重新打开编辑");
});

test("production HTML contains no preview host or demo secrets", () => {
  const html = readFileSync("../src/aksk_manager/ui/index.html", "utf8");
  for (const text of ["SYNTHETIC_DATABASE_PASSWORD", "SYNTHETIC_ACCESS", "AKSK local preview", "重置演示数据"])
    expect(html).not.toContain(text);
});

test("search finds token, key and password values without revealing them", async ({ page }) => {
  await page.goto(url);
  const ui = page.frameLocator("iframe");
  await expect(ui.locator(".secret-row")).toHaveCount(3);
  for (const [query, name] of [
    ["SYNTHETIC_TOKEN", "代码仓库访问"],
    ["synthetic_tok", "代码仓库访问"],
    ["SYNTHETIC_ACCESS", "生产账单 · 只读"],
    ["SYNTHETIC_SECRET", "生产账单 · 只读"],
    ["SYNTHETIC_DATABASE_PASSWORD", "测试环境资源查询"],
    ["PostgreSQL DATABASE_PASSWORD", "测试环境资源查询"],
  ]) {
    await ui.getByLabel("搜索密钥").fill(query);
    await expect(ui.locator(".secret-row")).toHaveCount(1);
    await expect(ui.locator(".secret-row")).toContainText(name);
    await ui.locator(".secret-row").click();
    await expect(ui.locator(".credentials")).toContainText("••••");
    await expect(ui.locator(".credentials")).not.toContainText("SYNTHETIC_");
    await ui.getByLabel("关闭详情").click();
  }
  expect(await page.evaluate(() => (window as any).contextLeaks)).toEqual([]);
  expect(await page.evaluate(() => (window as any).calls.some(
    (c: any) => c.name === "ui_reveal"))).toBe(false);
});
