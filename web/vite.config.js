import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { viteSingleFile } from 'vite-plugin-singlefile'

export default defineConfig({
  plugins: [react(), viteSingleFile()],
  // Keep the reference build self-contained for easy local preview.
  // so there are no module/CORS issues with the file:// origin.
  base: './',
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // Inline everything; no separate assets directory needed.
    assetsInlineLimit: 100000000,
    modulePreload: false,
  },
})
