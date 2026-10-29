import { defineConfig } from "vite";
import { viteSingleFile } from "vite-plugin-singlefile";
export default defineConfig({
  plugins: [viteSingleFile()],
  build: { outDir: "../src/aksk_manager/ui", emptyOutDir: true },
});
