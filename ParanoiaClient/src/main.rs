use slint::SharedString;

slint::include_modules!();

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let main_win = MainWindow::new()?;
    main_win.run()?;
    Ok(())
}