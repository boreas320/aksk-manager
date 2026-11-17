import { previewOtp } from "./preview-otp";
import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";
export default defineConfig({
  plugins: [previewOtp(), viteSingleFile()],
  build: { outDir: "../src/aksk_manager/ui", emptyOutDir: true },
});
