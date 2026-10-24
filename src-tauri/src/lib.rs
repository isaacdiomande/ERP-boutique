// Point d'entrée Rust de l'app Tauri. Pour la phase 1, toute la logique
// métier reste côté JavaScript (index.html) qui parle directement à
// Supabase — Tauri sert uniquement de coquille (fenêtre + webview native).
//
// Des commandes Rust (#[tauri::command]) pourront être ajoutées plus tard
// pour ce que le navigateur ne peut pas faire nativement : accès au système
// de fichiers pour des sauvegardes locales, impression, notifications
// système, etc. — rien de tout cela n'est nécessaire en phase 1.

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("erreur au démarrage de l'application ERP Boutique");
}
