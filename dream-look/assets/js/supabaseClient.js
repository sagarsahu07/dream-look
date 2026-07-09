/**
 * Dream Look — Supabase Client
 * -----------------------------------------------------------------------
 * Creates ONE shared Supabase client for the whole site and exposes it as
 * `window.dreamLook.supabase`. Every page must load, in this order:
 *   1. https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2 (UMD build)
 *   2. assets/js/config.js
 *   3. assets/js/supabaseClient.js
 * before any other Dream Look script that needs database/auth access.
 * -----------------------------------------------------------------------
 */

(function initSupabaseClient() {
  if (typeof window.supabase === 'undefined') {
    console.error(
      '[Dream Look] Supabase SDK not found. Make sure the CDN script ' +
      'tag is included before supabaseClient.js.'
    );
    return;
  }

  if (typeof DREAM_LOOK_CONFIG === 'undefined') {
    console.error('[Dream Look] Missing config.js — cannot initialize Supabase.');
    return;
  }

  const client = window.supabase.createClient(
    DREAM_LOOK_CONFIG.SUPABASE_URL,
    DREAM_LOOK_CONFIG.SUPABASE_ANON_KEY,
    {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    }
  );

  window.dreamLook = window.dreamLook || {};
  window.dreamLook.supabase = client;
})();
