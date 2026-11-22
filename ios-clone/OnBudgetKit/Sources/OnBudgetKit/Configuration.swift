import Foundation

/// Client configuration for the OnBudget native iOS clone.
///
/// The Supabase URL and publishable (anon) key below are CLIENT keys
/// designed to ship in the app — they are already public in the web
/// app's config.js. Row Level Security + Edge Functions enforce who
/// sees what; the anon key alone grants nothing.
///
/// The service-role key must NEVER appear here, in the repo, or in
/// chat. It is a server-only secret.
public enum Configuration {
    public static let supabaseURL = "https://tnkhvdkmwmwiogiienee.supabase.co"
    /// Auth-only host (build 54, owner Nov 21, 2026): the Cloudflare
    /// Worker reverse proxy presenting Supabase Auth as
    /// auth.getstag.us, so the Google sign-in screen shows
    /// getstag.us instead of the Supabase project URL (which the
    /// owner called "extremely sketchy"). Auth requests ONLY go
    /// here; rest/functions stay on supabase.co (auth-only routing
    /// limits a Worker outage to sign-in). The Worker is already
    /// deployed + verified; the Google OAuth callback
    /// https://auth.getstag.us/auth/v1/callback is already added.
    /// The Gmail connect flow is SEPARATE (custom Edge Function
    /// callback) and is untouched by this. A real Google sign-in
    /// from the app must still be tested after this build ships —
    /// the proxy health check alone does not prove it.
    public static let supabaseAuthURL = "https://auth.getstag.us"
    public static let supabaseAnonKey = "sb_publishable_P2phsf7AYX38dbmxOEZKzQ_uw168MZP"
}
