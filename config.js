// Staff Allowance & Discount Portal — configuration
// Fill these in, then commit. The Supabase key and EmailJS public key are
// both meant to be embedded in client-side code (protected by RLS policies
// and EmailJS domain restriction respectively) — same model as the WHIP tool.

const CONFIG = {
  SB_URL: 'https://kzkjquteqeyqwdckgarr.supabase.co',
  SB_KEY: 'sb_publishable_LJ0s84Q5mEkIwczTN_l3fw_rPPYr0op',

  EMAILJS_PUBLIC_KEY: 'RSLU4ptjtK9who1fa',   // Account -> General -> Public Key
  EMAILJS_SERVICE_ID: 'service_637v8yq',   // Email Services tab
  EMAILJS_TEMPLATE_ID: 'template_e6ygax1',  // "Order Confirmation" template — used for Staff Allowance orders
  EMAILJS_TEMPLATE_ID_DISCOUNT: 'template_rp6yxwe',         // the "Staff Discount Confirmation" template
  EMAILJS_TEMPLATE_ID_BALANCE: '',          // fill in once you've created the "Balance Summary" template

  WAREHOUSE_EMAIL: 'musa@freedomofmovement.co.za', // testing for now, swap to warehouse junior manager later
  MANAGER_EMAIL: 'musa@freedomofmovement.co.za',

  DISCOUNT_RATE: 0.40,      // staff discount = 40% off RSP
  CURRENT_PERIOD: '2026',

  // Master admin — whoever logs in with this email gets the Admin tab and full access to every
  // staff member's data. Enforced for real by database policies (see schema.sql), not just this
  // client-side check, so this isn't a secret that needs protecting.
  ADMIN_EMAIL: 'musa@freedomofmovement.co.za'
};
