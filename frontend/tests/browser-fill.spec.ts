import { test, expect } from "@playwright/test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

test("Chrome popup fills each step and rejects ambiguous and foreign form targets", async ({ page }) => {
  const origin = "https://example.invalid";
  await page.route(origin + "/**", route => route.fulfill({contentType: "text/html",
    body: '<main></main><strong id="site"></strong><p id="status"></p><form><input autocomplete="username"></form>'}));
  await page.goto(origin);
  // Mock only the extension transport; run the shipped popup and injected DOM function in Chrome.
  await page.evaluate(fieldScript => {
    Object.assign(window, {chrome: {
      tabs: {query: async () => [{id: 7, url: location.href}]},
      scripting: {executeScript: async ({func, args = [], files}: any) => {
        if (!files) return [{documentId: "demo", result: func(...args)}];
        if (files.length !== 1 || files[0] !== "fields.js") throw new Error("Unexpected extension script");
        const script = document.createElement("script");
        script.textContent = fieldScript;
        document.head.append(script);
        return [{documentId: "demo"}];
      }},
      runtime: {sendNativeMessage: async (_: string, req: any) => ({ok: true, data: req.action === "accounts"
        ? [{id: "1", revision: "2", name: "Test", fields: ["username", "password", "otp_code"]}]
        : {username: "demo", password: "test-only", otp_code: "123456"}[req.field as string]})}
    }});
  }, readFileSync(resolve("../browser/fields.js"), "utf8"));
  await page.addScriptTag({content: readFileSync(resolve("../browser/popup.js"), "utf8")});
  for (const [html, label, value] of [
    ['<input autocomplete="username">', "用户名", "demo"],
    ['<input type="password">', "密码", "test-only"],
    ['<input autocomplete="one-time-code">', "验证码", "123456"],
  ]) {
    await page.locator("form").evaluate((form, html) => form.innerHTML = html, html);
    await page.getByRole("button", {name: label}).click();
    await expect(page.locator("input")).toHaveValue(value);
  }
  await page.locator("form").evaluate(form => {form.innerHTML = '<input type="password"><input type="password">';});
  await page.getByRole("button", {name: "密码"}).click();
  await expect(page.locator("#status")).toContainText("未找到");
  await page.locator("form").evaluate(form => {
    form.innerHTML = '<input type="password">';
    form.setAttribute("action", "https://other.invalid");
  });
  await page.getByRole("button", {name: "密码"}).click();
  await expect(page.locator("input")).toHaveValue("");
});

test("classifies mixed-language MFA verification placeholders", async ({ page }) => {
  await page.setContent('<input type="text" autocomplete="off">');
  await page.addScriptTag({path: resolve("../browser/fields.js")});
  const classify = (placeholder: string) => page.locator("input").evaluate(
    (input, text) => {
      input.placeholder = text;
      return globalThis.akskFieldOf(input);
    },
    placeholder,
  );
  await expect(classify("MFA Code")).resolves.toBe("otp_code");
  await expect(classify("MFA 验证码")).resolves.toBe("otp_code");
  await expect(classify("MFA验证码")).resolves.toBe("otp_code");
  await expect(classify("OTP 口令")).resolves.toBe("otp_code");
  await expect(classify("验证码")).resolves.toBeUndefined();
});

test("click-fill keeps input focus for typing and suppresses repeat popups until blur", async ({ page }) => {
  const origin = "https://login.example.invalid";
  await page.route(origin + "/**", route => route.fulfill({
    contentType: "text/html",
    body: '<form><input id="user" name="username" value="xiangshuai@200042559604"><input id="pw" type="password"></form>',
  }));
  await page.goto(origin);
  await page.evaluate(() => {
    Object.assign(window, {
      chrome: {
        runtime: {
          sendMessage: async (request: any) => request.action === "accounts"
            ? [{id: "1", revision: "1", name: "Tencent Cloud ECOM"}]
            : "filled-user",
        },
      },
    });
  });
  await page.addScriptTag({path: resolve("../browser/fields.js")});
  await page.addScriptTag({path: resolve("../browser/click-fill.js")});

  const user = page.locator("#user");
  const menuCount = () => page.evaluate(() => document.documentElement.querySelectorAll(":scope > div").length);

  await user.click();
  await expect.poll(menuCount).toBe(1);
  await expect(user).toBeFocused();

  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("Backspace");
  await page.keyboard.type("9");
  await expect(user).not.toHaveValue("xiangshuai@200042559604");
  await expect(user).toHaveValue(/9/);
  await expect.poll(menuCount).toBe(0);

  await user.click();
  await page.waitForTimeout(100);
  expect(await menuCount()).toBe(0);

  await page.locator("#pw").click();
  await expect.poll(menuCount).toBe(1);
  await expect(page.locator("#pw")).toBeFocused();

  await page.locator("#pw").click();
  await expect.poll(menuCount).toBe(0);
  await expect(page.locator("#pw")).toBeFocused();
});
