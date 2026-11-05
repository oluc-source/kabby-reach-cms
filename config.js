// Kabby+ Reach — configuration partagée par le CMS (index.html) et le player (player.html).
// Projet Supabase « Kabby+ CMS 2026 ».
// La clé "publishable" est faite pour être publique : la sécurité repose sur les règles RLS du schéma.
window.KABBY_CONFIG = {
  supabaseUrl: "https://urvhkeuelcevztpawpeo.supabase.co",
  supabaseAnonKey: "sb_publishable_moenOlfn1WIx6VeebyFwMQ_lE3MbvKM",
  syncSeconds: 20,     // fréquence de synchronisation des players
  reportSeconds: 60    // fréquence de remontée du proof of play
};
