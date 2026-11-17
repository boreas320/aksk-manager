/// <reference types="vite/client" />
import { mountPreviewHost, type PreviewOptions } from "./host";
import "./style.css";

const files = import.meta.glob<NonNullable<PreviewOptions["snapshot"]>>("./local-accounts.json", { eager: true, import: "default" });
const snapshot = files["./local-accounts.json"];
const source = document.querySelector<HTMLSelectElement>("#source")!;
source.options[1].disabled = !snapshot;
const url = new URL(location.href);
const showSnapshot = !!snapshot && url.searchParams.get("source") === "accounts";
source.value = showSnapshot ? "accounts" : "demo";
source.onchange = () => {
  url.searchParams.set("source", source.value);
  location.replace(url);
};
if (showSnapshot) {
  document.querySelector(".preview-title small")!.textContent = "本机测试账号 · 账号信息只读，验证码实时更新";
  document.querySelector<HTMLSelectElement>("#scenario")!.disabled = true;
  document.querySelector<HTMLButtonElement>("#reset")!.disabled = true;
}
const host = mountPreviewHost(showSnapshot ? { snapshot } : {});
const frame = document.querySelector("iframe")!;
const select = (id: string) => document.querySelector<HTMLSelectElement>(`#${id}`)!;
const reload = () => { frame.src = "/?preview=" + Date.now(); };
select("viewport").onchange = (e) => {
  const width = (e.target as HTMLSelectElement).value;
  frame.style.width = width === "full" ? "100%" : `${width}px`;
};
select("theme").onchange = () => {
  const dark = select("theme").value === "dark";
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  host.setTheme(dark);
};
select("scenario").onchange = () => {
  const value = select("scenario").value;
  host.setScenario(value);
  host.reset(value === "empty");
  reload();
};
document.querySelector<HTMLButtonElement>("#reset")!.onclick = () => {
  select("scenario").value = "normal";
  host.setScenario("normal");
  host.reset();
  reload();
};
reload();
