slint::include_modules!();
use std::{cell::RefCell, collections::VecDeque, rc::Rc};

pub struct WindowManager {
    pub win_stack: VecDeque<Screen>,
    pub main_window: MainWindow,
}

impl WindowManager {
    pub fn new() -> Result<Rc<RefCell<Self>>, Box<dyn std::error::Error>> {
        let main_window = MainWindow::new()?;
        let this = Rc::new(RefCell::new(Self {
            win_stack: VecDeque::new(),
            main_window,
        }));

        let weak = Rc::downgrade(&this);
        let main_window_handle = this.borrow().main_window.as_weak();
        
        main_window_handle.upgrade().unwrap()
            .on_navigate_to(move |screen: Screen| {
                if let Some(strong) = weak.upgrade() {
                    strong.borrow_mut().navigate_to(screen);
                }
            });

        let weak2 = Rc::downgrade(&this);
        main_window_handle.upgrade().unwrap().on_go_back(move || {
            if let Some(strong) = weak2.upgrade() {
                strong.borrow_mut().go_back();
            }
        });

        Ok(this)
    }

    pub fn navigate_to(&mut self, screen: Screen) {
        self.win_stack
            .push_back(self.main_window.get_current_screen());
        self.main_window.set_current_screen(screen);
    }

    fn go_back(&mut self) {
        self.main_window
            .set_current_screen(match self.win_stack.pop_back() {
                Some(screen) => screen,
                None => Screen::Main,
            });
    }
}
