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
    public static let supabaseAnonKey = "sb_publishable_P2phsf7AYX38dbmxOEZKzQ_uw168MZP"
}
