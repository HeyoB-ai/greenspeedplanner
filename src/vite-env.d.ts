/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string;
  readonly VITE_SUPABASE_ANON_KEY: string;
  // Optioneel: eigen URL van de BENU Edge Functions. Niet gezet = afgeleid van
  // VITE_SUPABASE_URL (/functions/v1/...).
  readonly VITE_BENU_COURIER_API?: string;
  readonly VITE_BENU_PHARMACY_API?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
