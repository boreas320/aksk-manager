// Dev server only. No caller-provided credential ID, path or command.
import { execFile } from "node:child_process";
import { resolve } from "node:path";
import type { Plugin } from "vite";

export function previewOtp(): Plugin {
  return {name: "local-test-account-otp", apply: "serve", configureServer(server) {
    server.middlewares.use("/__preview/test-account/otp", (req, res) => {
      res.setHeader("Cache-Control", "no-store");
      const host = req.headers.host;
      if (req.method !== "POST" || !/^127\.0\.0\.1:\d+$/.test(host ?? "") ||
          req.socket.remoteAddress !== "127.0.0.1" || req.headers.origin !== "http://" + host ||
          req.headers["x-aksk-preview"] !== "otp" || req.headers["sec-fetch-site"] !== "same-origin") {
        res.statusCode = 403; res.end(); return;
      }
      const cwd = resolve(server.config.root, "..");
      execFile("python3", ["scripts/preview-accounts.py", "--otp"], {
        cwd, env: {...process.env, PYTHONPATH: resolve(cwd, "src"), AKSK_PLUGIN_ROOT: cwd},
        timeout: 5000, maxBuffer: 4096,
      }, (err, output) => {
        if (err) { res.statusCode = 503; res.end(); return; }
        res.setHeader("Content-Type", "application/json"); res.end(output);
      });
    });
  }};
}
