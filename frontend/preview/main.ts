import { mountPreviewHost } from "./host";
import "./style.css";

const host = mountPreviewHost();
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
