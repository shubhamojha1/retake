import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// The web app is a pure Phoenix client. In dev it runs on :5173 and proxies
// /api/* and /socket to the Phoenix API on :4010, so the browser only ever
// talks to one origin and no CORS is involved.
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: {
      '/api': { target: 'http://localhost:4010', changeOrigin: true },
      '/socket': { target: 'ws://localhost:4010', changeOrigin: true, ws: true },
    },
  },
})
