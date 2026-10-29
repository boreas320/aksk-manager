import { defineConfig } from "@playwright/test";
export default defineConfig({
  testDir: "./tests",
  workers: 1,
  webServer: {
    command: "node node_modules/vite/bin/vite.js --host 127.0.0.1 --port 5174 --strictPort",
    url: "http://127.0.0.1:5174/preview.html",
    reuseExistingServer: false,
  },
  use: {
    browserName: "chromium",
    channel: process.env.PLAYWRIGHT_CHANNEL,
    viewport: { width: 1280, height: 840 },
  },
});
