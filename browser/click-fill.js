(() => {
  let menu, seq = 0;
  const close = () => { seq++; menu?.remove(); menu = null; };
  const fieldOf = globalThis.akskFieldOf;
  document.addEventListener("pointerdown", e => { if (e.target !== menu) close(); }, true);
  document.addEventListener("keydown", e => { if (e.key === "Escape") close(); }, true);
  window.addEventListener("pagehide", close);
  document.addEventListener("click", async e => {
    if (!e.isTrusted || e.button !== 0 || e.target === menu || window !== top) return;
    const input = e.composedPath()[0], field = fieldOf(input);
    if (!field || input !== document.activeElement) return;
    close();
    const ticket = seq, initialValue = input.value;
    const valid = () => ticket === seq && !document.hidden && fieldOf(input) === field && input.value === initialValue;
    try {
      const accounts = await chrome.runtime.sendMessage({action:"accounts", field});
      if (!valid() || document.activeElement !== input || !accounts?.length) return;
      async function fill(a) {
        input.focus({preventScroll:true});
        const value = await chrome.runtime.sendMessage({action:"fill", field, id:a.id, revision:a.revision});
        if (!valid() || document.activeElement !== input || typeof value !== "string") return;
        close();
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,"value").set.call(input,value);
        input.dispatchEvent(new Event("input",{bubbles:true}));
        input.dispatchEvent(new Event("change",{bubbles:true}));
      }
      const rect = input.getBoundingClientRect();
      menu = document.createElement("div");
      const root = menu.attachShadow({mode:"closed"});
      menu.style.cssText = 'all:initial;position:fixed;z-index:2147483647;left:'+Math.max(0,Math.min(rect.left,innerWidth-240))+'px;top:'+Math.max(0,Math.min(rect.bottom+3,innerHeight-150))+'px';
      const box=document.createElement("div");
      box.style.cssText="background:white;color:#122f26;border:1px solid #abbfb7;border-radius:8px;padding:8px;min-width:180px;max-height:140px;overflow:auto;font:13px system-ui";
      box.textContent="AKSK Manager · 选择账号";
      for (const a of accounts) {
        const button=document.createElement("button");
        button.type="button"; button.textContent=a.name;
        button.style.cssText="display:block;width:100%;text-align:left;margin-top:4px;padding:6px;cursor:pointer";
        button.onclick=ev=>{if(ev.isTrusted && valid()) void fill(a).catch(close);};
        box.append(button);
      }
      root.append(box);document.documentElement.append(menu);
      box.querySelector("button").focus({preventScroll:true});
    } catch { close(); }
  }, true);
})();
