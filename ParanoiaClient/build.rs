
use std::fs;
use std::path::Path;

fn main() {
    let ui_dir = Path::new("./src/ui");
    let entries = fs::read_dir(ui_dir)
        .expect("Cannot read ui/ directory");

    for entry in entries {
        let entry = entry.expect("Cannot read directory entry");
        let path = entry.path();
        if path.extension().map_or(false, |ext| ext == "slint") {
            let path_str = path.to_string_lossy();
            slint_build::compile(&*path_str)
                .unwrap_or_else(|e| panic!("Failed to compile {}: {}", path_str, e));
        }
    }
}
