fn main() {
    slint_build::compile(std::path::Path::new("src/ui/main.slint")).unwrap()
}
