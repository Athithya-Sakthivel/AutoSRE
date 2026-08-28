import js from "@eslint/js";
import reactHooks from "eslint-plugin-react-hooks";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: ["dist", "node_modules"],
  },

  // Base ESLint recommended rules
  js.configs.recommended,

  // TypeScript ESLint recommended rules
  tseslint.configs.recommended,

  // React Hooks recommended rules (flat config)
  reactHooks.configs.flat.recommended,

  {
    files: ["**/*.{js,jsx,ts,tsx}"],
  },
);
