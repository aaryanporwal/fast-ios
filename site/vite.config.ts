import { defineConfig } from 'vite'
import preact from '@preact/preset-vite'

// page-mascot is a React component. @preact/preset-vite aliases react and
// react-dom to preact/compat, which cuts the script from about 70 KB to about
// 10 KB gzip. base './' keeps every URL relative, so dist/ works at a domain
// root or at a GitHub Pages project path such as /fast-ios/.
export default defineConfig({
  base: './',
  plugins: [preact()],
  build: { outDir: 'dist', assetsInlineLimit: 0 },
})
