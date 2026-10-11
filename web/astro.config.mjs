import { defineConfig } from 'astro/config';
import tailwind from '@astrojs/tailwind';

export default defineConfig({
  site: 'https://arkhe.priet.us',
  integrations: [tailwind({ applyBaseStyles: false })],
  // `format: 'file'` emits privacy.html / support.html; nginx's
  // `try_files $uri $uri.html` serves them at /privacy and /support.
  build: { assets: 'assets', format: 'file' },
  compressHTML: true,
});
