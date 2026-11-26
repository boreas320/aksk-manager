async function native(payload) {
  const reply = await chrome.runtime.sendNativeMessage("com.boreas.aksk_manager", payload);
  if (!reply?.ok) throw new Error();
  return reply.data;
}
async function start() {
  const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
  const site = new URL(tab.url);
  if (site.protocol !== "https:") throw new Error();
  document.querySelector("#site").textContent = site.host;
  const [page] = await chrome.scripting.executeScript({
    target: {tabId: tab.id, frameIds: [0]}, func: () => location.origin,
  });
  if (page.result !== site.origin || !page.documentId) throw new Error();
  await chrome.scripting.executeScript({target:{tabId:tab.id, documentIds:[page.documentId]}, files:["fields.js"]});
  const accounts = await native({action: "accounts", origin: site.origin});
  const status = document.querySelector("#status");
  status.textContent = accounts.length ? "选择要填写的字段" : "当前网站没有匹配账号";
  const labels = {username: "用户名", password: "密码", otp_code: "验证码"};
  for (const account of accounts) {
    const section = document.createElement("section");
    const title = document.createElement("p");
    title.textContent = account.name;
    section.append(title);
    for (const field of Object.keys(labels).filter(field => account.fields.includes(field))) {
      const button = document.createElement("button");
      button.textContent = labels[field];
      button.onclick = async () => {
        try {
          const value = await native({action: "fill", origin: site.origin, id: account.id, revision: account.revision, field});
          const [result] = await chrome.scripting.executeScript({
            target: {tabId: tab.id, documentIds: [page.documentId]}, args: [site.origin, field, value],
            func: (origin, field, value) => {
              if (window !== window.top || location.origin !== origin) return false;
              const candidates = [...document.querySelectorAll("input")].filter(input => globalThis.akskFieldOf(input) === field);
              const input = candidates.includes(document.activeElement) ? document.activeElement :
                candidates.length === 1 ? candidates[0] : null;
              if (!input) return false;
              Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(input, value);
              input.dispatchEvent(new Event("input", {bubbles:true}));
              input.dispatchEvent(new Event("change", {bubbles:true}));
              // Compare locally after page handlers have processed the change.
              // Only the outcome crosses back to the popup.
              return input.isConnected && input.value === value ? "matched" : "changed";
            },
          });
          status.textContent = result?.result === "matched" ? "已填写并核对一致" :
            result?.result === "changed" ? "页面更改了填充值，核对未通过" : "未找到唯一匹配的输入框";
        } catch { status.textContent = "填写失败，请重新打开扩展"; }
      };
      section.append(button);
    }
    document.querySelector("main").append(section);
  }
}
start().catch(() => { document.querySelector("#status").textContent = "请打开 HTTPS 网站，并检查本机组件是否已安装"; });
