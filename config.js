// Staff Allowance & Discount Portal — configuration
// Fill these in, then commit. The Supabase key and EmailJS public key are
// both meant to be embedded in client-side code (protected by RLS policies
// and EmailJS domain restriction respectively) — same model as the WHIP tool.

const CONFIG = {
  SB_URL: 'https://kzkjquteqeyqwdckgarr.supabase.co',
  SB_KEY: 'sb_publishable_LJ0s84Q5mEkIwczTN_l3fw_rPPYr0op',

  EMAILJS_PUBLIC_KEY: 'RSLU4ptjtK9who1fa',   // Account -> General -> Public Key
  EMAILJS_SERVICE_ID: 'service_637v8yq',   // Email Services tab
  EMAILJS_TEMPLATE_ID: 'template_e6ygax1',  // the "Order Confirmation" template you just built

  WAREHOUSE_EMAIL: 'musa@freedomofmovement.co.za', // testing for now, swap to warehouse junior manager later
  MANAGER_EMAIL: 'musa@freedomofmovement.co.za',

  DISCOUNT_RATE: 0.40,      // staff discount = 40% off RSP
  CURRENT_PERIOD: '2026',

  ADMIN_PASSWORD: 'fom-admin-2026' // soft gate only, not real security — internal tool
};
