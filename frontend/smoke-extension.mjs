// Run via scripts/smoke-browser.py --extension with a disposable Keychain record.
import { chromium } from "playwright";
import { mkdtemp, mkdir, copyFile, rm } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import { join, resolve } from "node:path";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
let input = "";
for await (const chunk of process.stdin) input += chunk;
const fixture = JSON.parse(input);
assert.match(fixture.origin, /^https:\/\/[0-9a-f]{32}\.example\.invalid$/);
const profile = await mkdtemp(join(tmpdir(), "aksk-browser-smoke-"));
let context;
try {
  const host = "com.boreas.aksk_manager.json";
  await mkdir(join(profile, "NativeMessagingHosts"));
  await copyFile(join(homedir(), "Library/Application Support/Google/Chrome/NativeMessagingHosts", host),
                 join(profile, "NativeMessagingHosts", host));
  context = await chromium.launchPersistentContext(profile, {
    channel: process.env.PLAYWRIGHT_CHANNEL || "chromium", headless: false, args: ["--enable-unsafe-extension-debugging"],
    ignoreDefaultArgs: ["--disable-extensions"],
  });
  // Only the fixture HTML is simulated. The extension, popup, activeTab grant,
  // native messaging broker and signed Keychain helper are the production path.
  await context.route(fixture.origin + "/**", route => {
    if (route.request().url() === fixture.origin + "/") return route.fulfill({
      contentType: "text/html", body: '<form><input autocomplete="username"></form>',
    });
    return route.abort();
  });
  const page = context.pages()[0];
  const client = await context.browser().newBrowserCDPSession();
  const {id} = await client.send("Extensions.loadUnpacked", {path:resolve("../browser")});
  await page.goto(fixture.origin);
  const {targetInfos:tabs} = await client.send("Target.getTargets", {filter:[{type:"tab"}]});
  const {targetId} = tabs.find(t=>t.url===page.url()) ?? (tabs.length===1 ? tabs[0] : {});
  assert.ok(targetId, "test tab target was not found");
  async function clickField(label) {
    await client.send("Extensions.triggerAction", {id, targetId});
    // Chrome exposes action popups as short-lived CDP targets, not normal tabs.
    let target;
    for (let n=0; n<60 && !target; n++) {
      target = (await client.send("Target.getTargets")).targetInfos.find(t => t.url === "chrome-extension://" + id + "/popup.html");
      if (!target) await new Promise(r=>setTimeout(r,100));
    }
    assert.ok(target, "action popup did not open");
    const {sessionId} = await client.send("Target.attachToTarget", {targetId:target.targetId, flatten:false});
    let seq=0;
    async function evaluate(expression) {
      const callId=++seq;
      const result = new Promise((resolve,reject) => {
        function done({sessionId:s,message}) {
          if(s!==sessionId) return;
          const m=JSON.parse(message);
          if(m.id!==callId) return;
          clearTimeout(timer); client.off("Target.receivedMessageFromTarget",done);
          if(m.error || m.result?.exceptionDetails) reject(new Error("popup evaluation failed"));
          else resolve(m.result.result.value);
        }
        const timer=setTimeout(()=>{client.off("Target.receivedMessageFromTarget",done);reject(new Error("popup timed out"));},8000);
        client.on("Target.receivedMessageFromTarget",done);
      });
      await client.send("Target.sendMessageToTarget", {sessionId,message:JSON.stringify({
        id:callId, method:"Runtime.evaluate", params:{expression,returnByValue:true,awaitPromise:true},
      })});
      return result;
    }
    const clicked=await evaluate(`(async()=>{
      for(let n=0;n<60;n++){
        const sections=[...document.querySelectorAll("section")];
        const selected=sections.find(s=>s.querySelector("p")?.textContent==="AKSK browser smoke");
        const b=sections.length===2 && selected && [...selected.querySelectorAll("button")].find(b=>b.textContent===${JSON.stringify(label)});
        if(b){ b.click(); return true; }
        await new Promise(r=>setTimeout(r,80));
      }
      return document.querySelector("#status")?.textContent;
    })()`);
    if(clicked!==true) throw new Error("popup has no fill button: "+clicked);
    await page.waitForFunction(()=>Boolean(document.querySelector("input")?.value),{},{timeout:5000});
    await client.send("Target.closeTarget", {targetId:target.targetId});
  }
  for (const [label, html] of [["用户名",'<input autocomplete="username">'], ["密码",'<input type="password">'],
                             ["验证码",'<input autocomplete="one-time-code">']]) {
    await page.locator("form").evaluate((form,html)=>{form.innerHTML=html;},html);
    await clickField(label);
    const value=await page.locator("input").inputValue();
    // Independently recompute the disposable fixture's TOTP, allowing a period boundary.
    const code = offset => {
      const counter=Buffer.alloc(8);
      counter.writeBigUInt64BE(BigInt(Math.floor(Date.now()/30000)+offset));
      const hash=createHmac("sha1",Buffer.from("48656c6c6f21deadbeef","hex")).update(counter).digest();
      return String((hash.readUInt32BE(hash.at(-1)&15)&0x7fffffff)%1000000).padStart(6,"0");
    };
    assert.ok(label==="验证码" ? [code(-1),code(0)].includes(value) : value===(label==="密码" ? fixture.password : "demo"),
              "unexpected filled value");
  }
  console.log("PASS: installed action popup → signed native host → three fields on one HTTPS test tab");
} finally {
  try { await context?.close(); } finally { await rm(profile,{recursive:true,force:true}); }
}
