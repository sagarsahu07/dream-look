/**
 * Dream Look — Runtime Configuration
 * -----------------------------------------------------------------------
 * This is a plain static site (no build step), so there is no way to read
 * a real `.env` file in the browser. Supabase's anon/public key is SAFE to
 * ship in client-side code by design — access is enforced by Row Level
 * Security (RLS) policies on the database, not by hiding this key.
 *
 * Replace the two values below with the ones from your own Supabase
 * project: Project Settings → API.
 *
 * DO NOT put your `service_role` key here. That key must never leave
 * a trusted server and has no use in this frontend.
 * -----------------------------------------------------------------------
 */

const DREAM_LOOK_CONFIG = {
  SUPABASE_URL: 'https://wntofiqieryvbxothets.supabase.co',
  SUPABASE_ANON_KEY: 'sb_publishable_gvX2YvsBYgUzyxbCDzlWVQ_CtbyP_g-',
};
