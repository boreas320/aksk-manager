// Run via scripts/smoke-browser.py --extension with a disposable Keychain record.
import { chromium } from "playwright";
import { mkdtemp, mkdir, copyFile, rm, writeFile, readFile } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import { join, resolve } from "node:path";
import assert from "node:assert/strict";
import { createHash, randomUUID, createHmac } from "node:crypto";
let input = "";
for await (const chunk of process.stdin) input += chunk;
const simulated = process.argv.includes("--fixture-host");
const fixture = simulated ? {origin:"https://"+randomUUID().replaceAll("-","")+".example.invalid",password:randomUUID()} : JSON.parse(input);
assert.match(fixture.origin, /^https:\/\/[0-9a-f]{32}\.example\.invalid$/);
const profile = await mkdtemp(join(tmpdir(), "aksk-browser-smoke-"));
let context;
try {
  const host = "com.boreas.aksk_manager.json";
  await mkdir(join(profile, "NativeMessagingHosts"));
  if (simulated) {
    const key=JSON.parse(await readFile(resolve("../browser/manifest.json"),"utf8")).key;
    const id=createHash("sha256").update(Buffer.from(key,"base64")).digest("hex").slice(0,32)
      .replace(/./g,c=>String.fromCharCode(97+parseInt(c,16)));
    const binary=join(profile,"test-host");
    await writeFile(binary, `#!/usr/bin/python3
import sys,json,struct,time,hmac,hashlib
buf=sys.stdin.buffer
n=struct.unpack("<I",buf.read(4))[0]
q=json.loads(buf.read(n))
d=hmac.new(bytes.fromhex("48656c6c6f21deadbeef"),struct.pack(">Q",int(time.time())//30),hashlib.sha1).digest()
i=d[-1]&15
otp=str((int.from_bytes(d[i:i+4],"big")&2147483647)%1000000).zfill(6)
items=[dict(name="AKSK browser smoke",fields=["username","password","otp_code"],id="one",revision="1"),dict(name="AKSK alternate smoke",fields=["username","password"],id="two",revision="1")]
ok=q.get("origin")==${JSON.stringify(fixture.origin)}
value=items if q["action"]=="accounts" else dict(username="demo",password=${JSON.stringify(fixture.password)},otp_code=otp).get(q.get("field")) if q.get("id")=="one" else None
out=json.dumps(dict(ok=ok,data=value if ok else None)).encode()
sys.stdout.buffer.write(struct.pack("<I",len(out))+out)
`,{mode:0o700});
    await writeFile(join(profile,"NativeMessagingHosts",host),JSON.stringify({name:"com.boreas.aksk_manager",description:"test fixture",path:binary,type:"stdio",allowed_origins:["chrome-extension://"+id+"/"]}));
  } else await copyFile(join(homedir(), "Library/Application Support/Google/Chrome/NativeMessagingHosts", host),
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
                             ["验证码",'<input autocomplete="one-time-code">'], ["验证码",'<input placeholder="MFA Code" autocomplete="on">']]) {
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
  // No popup or activeTab gesture: an actual page click starts the fill.
  await page.reload();
  const dom = await context.newCDPSession(page);
  await page.locator("form").evaluate(f=>f.innerHTML='<label for="el-id-123-3">ID</label><input id="el-id-123-3" autocomplete="on" placeholder="SHAREid"><input type="password" id="loginBox">');
  await page.locator("#el-id-123-3").click();
  async function chooseAccount(beforeSelect) {
  let node;
  for(let i=0;i<50 && !node;i++){
    node=(await dom.send("Accessibility.getFullAXTree")).nodes.find(n =>
      n.role?.value==="button" && n.name?.value==="AKSK browser smoke");
    if(!node) await new Promise(r=>setTimeout(r,100));
  }
  assert.ok(node,"matching account chooser did not appear");
  const {model}=await dom.send("DOM.getBoxModel",{backendNodeId:node.backendDOMNodeId});
  await beforeSelect();
  await page.mouse.click((model.content[0]+model.content[4])/2,(model.content[1]+model.content[5])/2);
  }
  await chooseAccount(async()=>{
    assert.equal(await page.locator("#el-id-123-3").inputValue(),"");
    assert.equal(await page.evaluate(()=>document.activeElement?.id),"el-id-123-3");
  });
  await page.waitForFunction(()=>document.querySelector("input").value==="demo");
  // Reopen after choosing an account, with a different username already present.
  const username = page.locator("#el-id-123-3");
  await username.fill("existing-user");
  await username.click();
  await page.waitForFunction(()=>document.documentElement.children.length > 2);
  await page.keyboard.type("-edited");
  assert.match(await username.inputValue(),/-edited/);
  await username.click();
  await new Promise(resolveDelay=>setTimeout(resolveDelay,150));
  const suppressedButton=(await dom.send("Accessibility.getFullAXTree")).nodes.find(nodeItem =>
    nodeItem.role?.value==="button" && nodeItem.name?.value==="AKSK browser smoke");
  assert.equal(suppressedButton,undefined,"chooser reopened while editing focused input");
  await page.locator("#loginBox").focus();
  await username.fill("existing-user");
  await username.click();
  await chooseAccount(async()=>assert.equal(await username.inputValue(),"existing-user"));
  await page.waitForFunction(()=>document.querySelector("input").value==="demo");
  const pw = page.locator("#loginBox");
  await pw.fill("already-filled");
  await pw.click();
  await chooseAccount(async()=>assert.equal(await pw.inputValue(),"already-filled"));
  await page.waitForFunction(expected=>document.querySelector("#loginBox").value===expected,fixture.password);
  await page.locator("form").evaluate(f=>f.innerHTML='<input id="el-id-8265-6" autocomplete="on" placeholder="MFA Code" value="12">');
  await page.locator("input").click();
  await chooseAccount(async()=>assert.equal(await page.locator("input").inputValue(),"12"));
  await page.waitForFunction(()=>/^\d{6}$/.test(document.querySelector("input").value));
  await page.locator("form").evaluate(f=>{
    f.innerHTML='<div id="otp-box" style="position:relative"><div class="cells" style="display:flex;gap:8px">'+'<div class="cell" style="width:40px;height:40px;border:1px solid #ccc"></div>'.repeat(6)+'</div><input id="totp-code" type="tel" autocomplete="one-time-code" maxlength="6" style="position:absolute;left:300px;top:0;width:36px;color:transparent"></div>';
    f.querySelector(".cells").addEventListener("click",()=>f.querySelector("#totp-code").focus());
  });
  await page.locator(".cell").first().click();
  await chooseAccount(async()=>assert.equal(await page.evaluate(()=>document.activeElement?.id),"totp-code"));
  await page.waitForFunction(()=>/^\d{6}$/.test(document.querySelector("#totp-code").value));
  console.log("PASS: page clicks → multi-account selection → username, password and OTP");
  console.log("PASS: installed popup and page-click flows; host:", simulated ? "fixture" : "signed Keychain helper");
} finally {
  try { await context?.close(); } finally { await rm(profile,{recursive:true,force:true}); }
}
