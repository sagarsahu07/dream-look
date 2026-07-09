/**
 * Dream Look — Auth Module
 * -----------------------------------------------------------------------
 * Thin wrapper around Supabase Auth shared by every page. Load AFTER
 * supabaseClient.js. All functions return { data, error } so callers can
 * handle failures without try/catch everywhere.
 * -----------------------------------------------------------------------
 */

window.dreamLook = window.dreamLook || {};

window.dreamLook.auth = (function authModule() {
  function client() {
    return window.dreamLook.supabase;
  }

  /**
   * Create a new account. A database trigger (see sql/schema.sql,
   * handle_new_user) automatically creates the matching row in
   * public.users once the auth user is created.
   */
  async function signUp({ fullName, email, phone, password }) {
    return client().auth.signUp({
      email,
      password,
      options: {
        data: {
          full_name: fullName,
          phone: phone || null,
        },
      },
    });
  }

  async function signIn({ email, password }) {
    return client().auth.signInWithPassword({ email, password });
  }

  /**
   * OAuth sign-in (Google primary, Facebook optional). Supabase redirects
   * the browser to the provider, then back to redirectTo with a session —
   * supabaseClient.js already has detectSessionInUrl:true so the session
   * is picked up automatically on landing, no extra wiring needed. The
   * handle_new_user trigger (schema.sql) fires for ANY new auth.users row
   * regardless of provider, so a first-time Google sign-in gets a
   * public.users profile exactly like an email signup does — Google
   * supplies full_name/email automatically via raw_user_meta_data.
   */
  async function signInWithGoogle() {
    return client().auth.signInWithOAuth({
      provider: 'google',
      options: { redirectTo: `${window.location.origin}/dream-look/dashboard.html` },
    });
  }

  async function signInWithFacebook() {
    return client().auth.signInWithOAuth({
      provider: 'facebook',
      options: { redirectTo: `${window.location.origin}/dream-look/dashboard.html` },
    });
  }

  async function signOut() {
    return client().auth.signOut();
  }

  /**
   * Sends a password-recovery email. The link in that email redirects the
   * user back to forgot-password.html with a recovery token in the URL,
   * where they can set a new password.
   */
  async function sendPasswordReset(email) {
    const redirectTo = `${window.location.origin}/dream-look/forgot-password.html`;
    return client().auth.resetPasswordForEmail(email, { redirectTo });
  }

  /** Used on forgot-password.html once a recovery session is active. */
  async function updatePassword(newPassword) {
    return client().auth.updateUser({ password: newPassword });
  }

  async function getSession() {
    const { data, error } = await client().auth.getSession();
    return { session: data ? data.session : null, error };
  }

  /** Fetches the extended profile row from public.users for the current user. */
  async function getCurrentUserProfile() {
    const { session } = await getSession();
    if (!session) return { data: null, error: null };

    return client()
      .from('users')
      .select('*')
      .eq('id', session.user.id)
      .single();
  }

  /**
   * Route guard for pages that require a logged-in customer
   * (dashboard, book-slot, profile). Redirects to login.html if no
   * session is found. Call this at the top of the page's script.
   */
  async function requireAuth() {
    const { session } = await getSession();
    if (!session) {
      window.location.replace('login.html');
      return null;
    }
    return session;
  }

  /** Route guard for login/signup — bounces already-logged-in users to their dashboard. */
  async function requireGuest() {
    const { session } = await getSession();
    if (session) {
      window.location.replace('dashboard.html');
    }
  }

  /**
   * Route guard for admin-only pages. Confirms the session belongs to a
   * user whose public.users.role is 'admin'; otherwise signs out and
   * bounces to admin-login.html. Relies on the RLS policy that lets a
   * user always read their own row (see schema.sql).
   */
  async function requireAdmin() {
    const session = await requireAuth();
    if (!session) return null;

    const { data: profile, error } = await getCurrentUserProfile();
    if (error || !profile || profile.role !== 'admin') {
      await signOut();
      window.location.replace('admin-login.html');
      return null;
    }
    return { session, profile };
  }

  return {
    signUp,
    signIn,
    signInWithGoogle,
    signInWithFacebook,
    signOut,
    sendPasswordReset,
    updatePassword,
    getSession,
    getCurrentUserProfile,
    requireAuth,
    requireGuest,
    requireAdmin,
  };
})();
