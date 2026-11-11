/** Bindings must be repeated for each Wrangler environment (not inherited). */
export interface Env {
  /** Trusted Firebase project; never derived from the incoming JWT. */
  FIREBASE_PROJECT_ID?: string;
  /** Server-only JSON allowlist: [{ uid, email, role }]. */
  STUDIO_USERS?: string;
  /** Firebase UID bound to the built-in BiGuess owner email; unset disables it. */
  STUDIO_SUPER_ADMIN_UID?: string;
  /** Exact browser origins as JSON; missing/malformed configuration denies CORS. */
  STUDIO_ALLOWED_ORIGINS?: string;
  DB: D1Database;
  CONTENT: R2Bucket;
  /** Operator-pinned keyId -> base64 SPKI. No private key in the Worker. */
  PUBLICATION_KEYS?: string;
  APP_ENV: 'local' | 'staging';
}
