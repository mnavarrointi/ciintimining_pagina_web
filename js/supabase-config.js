const SUPABASE_URL = "https://llrulgzjmtquleqvwgua.supabase.co";
const SUPABASE_PUBLISHABLE_KEY =
  "sb_publishable_oZ0i_3hMI5s3iPu2QrnWLA_J98c_r_H";

const supabaseClient = window.supabase.createClient(
  SUPABASE_URL,
  SUPABASE_PUBLISHABLE_KEY
);