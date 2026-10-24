// Évite une fenêtre de console supplémentaire sur Windows en mode release.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    erp_boutique_lib::run();
}
