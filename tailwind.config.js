/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  // De type-kleuren worden dynamisch samengesteld; safelist zodat ze niet
  // wegge-purged worden. Zie src/planner/constants.ts.
  safelist: [
    { pattern: /(bg|border|text|ring)-(blue|purple|amber|red)-(100|300|400|500|700|800)/ },
  ],
  theme: { extend: {} },
  plugins: [],
};
