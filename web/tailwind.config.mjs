/** @type {import('tailwindcss').Config} */
export default {
  content: ['./src/**/*.{astro,html,md,mdx,js,jsx,ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['InterVariable', 'Inter', 'system-ui', '-apple-system', 'sans-serif'],
        display: ['"Fraunces"', 'ui-serif', 'Georgia', 'serif'],
        mono: ['"JetBrains Mono"', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'monospace'],
      },
      colors: {
        // Neutral graphite with a faint blue cast, like the app's dark UI
        ink: {
          950: '#07090d',
          900: '#0c0f15',
          800: '#141821',
          700: '#1d222e',
          600: '#272d3b',
          500: '#333a4b',
          400: '#5b6378',
          300: '#8d95ab',
          200: '#bec4d3',
          100: '#eaedf3',
        },
        // The blue of the app icon
        accent: {
          DEFAULT: '#2f6bff',
          hi: '#6b95ff',
          lo: '#1f4fd8',
          deep: '#13265e',
        },
        // The icon's gradient: sky → royal blue
        signal: {
          sky: '#3fb6ff',
          blue: '#2f6bff',
        },
      },
      boxShadow: {
        glow: '0 0 0 1px rgba(47,107,255,.30), 0 24px 80px -20px rgba(63,182,255,.28)',
        card: '0 1px 0 0 rgba(255,255,255,.04) inset, 0 20px 50px -30px rgba(0,0,0,.75)',
        device: '0 0 0 1px rgba(255,255,255,.06), 0 40px 100px -30px rgba(0,0,0,.9), 0 20px 80px -40px rgba(47,107,255,.35)',
      },
    },
  },
  plugins: [],
};
