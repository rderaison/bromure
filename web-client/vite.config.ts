import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath } from 'node:url';

// One build serves both targets: hosted at https://bromure.io/client/ and
// loaded from file:// inside Electron — so every asset URL is relative.
export default defineConfig({
  base: './',
  plugins: [react()],
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  build: { outDir: 'dist', sourcemap: true, target: 'es2022', chunkSizeWarningLimit: 4000 },
  server: { port: 5178, strictPort: true },
  test: { environment: 'node', include: ['test/**/*.test.ts', 'src/**/*.test.ts'] },
} as any);
