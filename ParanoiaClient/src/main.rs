
slint::include_modules!();

mod app;
use app::window_manager::WindowManager;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let window_manager = WindowManager::new()?;
    let main_win = window_manager.borrow().main_window.as_weak();
    main_win.upgrade().unwrap().run()?;
    Ok(())
}
