(() => {
  let menu, activeInput = null, dismissedInput = null, seq = 0;
  const close = () => { seq++; activeInput = null; menu?.remove(); menu = null; };
  const dismiss = input => { dismissedInput = input; close(); };
  const fieldOf = globalThis.akskFieldOf;
  document.addEventListener("pointerdown", event => {
    if (event.target === menu) return;
    if (activeInput && event.composedPath()[0] === activeInput) dismiss(activeInput);
    else close();
  }, true);
  document.addEventListener("keydown", event => {
    if (event.key === "Escape" && activeInput) dismiss(activeInput);
    else if (event.key === "Enter") close();
  }, true);
  document.addEventListener("input", event => {
    if (event.target === activeInput) dismiss(activeInput);
  }, true);
  document.addEventListener("focusout", event => {
    if (event.target === dismissedInput) dismissedInput = null;
    if (event.target === activeInput) close();
  }, true);
  window.addEventListener("pagehide", () => { dismissedInput = null; close(); });
  document.addEventListener("click", async event => {
    if (!event.isTrusted || event.button !== 0 || event.target === menu || window !== top) return;
    let input = event.composedPath()[0], anchor = input;
    if (!(input instanceof HTMLInputElement)) {
      const clicked = input;
      await new Promise(resolveTurn => setTimeout(resolveTurn));
      input = document.activeElement;
      if (fieldOf(input) !== "otp_code") return;
      anchor = input.parentElement;
      for (let depth = 0; anchor && !anchor.contains(clicked) && depth < 3; depth++) anchor = anchor.parentElement;
      if (!anchor?.contains(clicked)) return;
    }
    const field = fieldOf(input);
    if (!field || input !== document.activeElement || input === dismissedInput) return;
    close();
    activeInput = input;
    const ticket = seq, initialValue = input.value;
    const valid = () => ticket === seq && !document.hidden && fieldOf(input) === field && input.value === initialValue;
    try {
      const accounts = await chrome.runtime.sendMessage({action:"accounts", field});
      if (!valid() || document.activeElement !== input || !accounts?.length) {
        if (ticket === seq) close();
        return;
      }
      async function fill(account) {
        input.focus({preventScroll:true});
        const value = await chrome.runtime.sendMessage({action:"fill", field, id:account.id, revision:account.revision});
        if (!valid() || document.activeElement !== input || typeof value !== "string") return;
        dismissedInput = null;
        close();
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set.call(input,value);
        input.dispatchEvent(new Event("input",{bubbles:true}));
        input.dispatchEvent(new Event("change",{bubbles:true}));
      }
      const rect = anchor.getBoundingClientRect();
      menu = document.createElement("div");
      const root = menu.attachShadow({mode:"closed"});
      menu.style.cssText = 'all:initial;position:fixed;z-index:2147483647;left:'+Math.max(0,Math.min(rect.left,innerWidth-240))+'px;top:'+Math.max(0,Math.min(rect.bottom+3,innerHeight-150))+'px';
      const box = document.createElement("div");
      box.onmousedown = mouseEvent => {
        if (mouseEvent.target !== box || (mouseEvent.offsetX <= box.clientWidth && mouseEvent.offsetY <= box.clientHeight)) {
          mouseEvent.preventDefault();
        }
      };
      box.style.cssText = "box-sizing:border-box;background:#fff;color:#1f2a26;border:1px solid rgba(18,47,38,.12);border-radius:10px;padding:6px;min-width:220px;max-width:280px;max-height:220px;overflow:auto;font:13px/1.4 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;box-shadow:0 8px 24px rgba(18,47,38,.16),0 2px 6px rgba(18,47,38,.08)";
      const header = document.createElement("div");
      header.style.cssText = "display:flex;align-items:center;justify-content:space-between;gap:8px;padding:4px 6px 6px;margin-bottom:2px;border-bottom:1px solid rgba(18,47,38,.08);font-size:11px;color:#6b7d76;letter-spacing:.02em";
      const title = document.createElement("span");
      title.textContent = "AKSK Manager · 选择账号";
      const hide = document.createElement("span");
      hide.textContent = "×";
      hide.setAttribute("aria-hidden", "true");
      hide.style.cssText = "cursor:pointer;padding:2px 6px;border-radius:6px;line-height:1;font-size:14px;color:#8a9a94";
      hide.onmouseenter = () => { hide.style.background = "rgba(18,47,38,.06)"; hide.style.color = "#1f2a26"; };
      hide.onmouseleave = () => { hide.style.background = ""; hide.style.color = "#8a9a94"; };
      hide.onclick = clickEvent => { if (clickEvent.isTrusted) dismiss(input); };
      header.append(title, hide);
      box.append(header);
      for (const account of accounts) {
        const button = document.createElement("button");
        button.type = "button"; button.textContent = account.name;
        button.style.cssText = "all:unset;box-sizing:border-box;display:block;width:100%;margin-top:2px;padding:8px 10px;border-radius:7px;cursor:pointer;font:500 13px/1.3 inherit;color:#1f2a26;white-space:nowrap;overflow:hidden;text-overflow:ellipsis";
        button.onmouseenter = () => { button.style.background = "#eef5f2"; };
        button.onmouseleave = () => { button.style.background = ""; };
        button.onclick = clickEvent => { if (clickEvent.isTrusted && valid()) void fill(account).catch(close); };
        box.append(button);
      }
      root.append(box);
      document.documentElement.append(menu);
    } catch { close(); }
  }, true);
})();
