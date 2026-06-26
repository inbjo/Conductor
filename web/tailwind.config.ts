import type { Config } from 'tailwindcss';

export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['"IBM Plex Sans"', '"Noto Sans SC"', 'ui-sans-serif', 'system-ui'],
        mono: ['"IBM Plex Mono"', 'ui-monospace', 'SFMono-Regular'],
      },
      colors: {
        ink: '#101418',
        panel: '#f8faf7',
        line: '#d9ded6',
        signal: '#0b7a75',
        alert: '#b53d2a',
        brass: '#ad7c2c',
      },
      boxShadow: {
        crisp: '0 1px 0 rgba(16,20,24,.08), 0 10px 30px rgba(16,20,24,.08)',
      },
    },
  },
  plugins: [],
} satisfies Config;
