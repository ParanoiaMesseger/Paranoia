use prometheus::{Counter, Encoder, Registry, TextEncoder};

pub struct Metrics {
    pub reg_success:         Counter,
    pub reg_fail:            Counter,
    pub push_success:        Counter,
    pub push_fail:           Counter,
    pub pull_success:        Counter,
    pub pull_fail:           Counter,
    pub determinate_success: Counter,
    pub determinate_fail:    Counter,
    registry:                Registry,
}

macro_rules! register_counter {
    ($registry:expr, $name:expr) => {{
        let c = Counter::new($name, $name).unwrap();
        $registry.register(Box::new(c.clone())).unwrap();
        c
    }};
}

impl Metrics {
    pub fn new() -> Self {
        let registry = Registry::new();
        Self {
            reg_success:         register_counter!(registry, "paranoia_reg_success_total"),
            reg_fail:            register_counter!(registry, "paranoia_reg_fail_total"),
            push_success:        register_counter!(registry, "paranoia_push_success_total"),
            push_fail:           register_counter!(registry, "paranoia_push_fail_total"),
            pull_success:        register_counter!(registry, "paranoia_pull_success_total"),
            pull_fail:           register_counter!(registry, "paranoia_pull_fail_total"),
            determinate_success: register_counter!(registry, "paranoia_determinate_success_total"),
            determinate_fail:    register_counter!(registry, "paranoia_determinate_fail_total"),
            registry,
        }
    }

    pub fn render(&self) -> String {
        let encoder = TextEncoder::new();
        let families = self.registry.gather();
        let mut buf = Vec::new();
        encoder.encode(&families, &mut buf).unwrap();
        String::from_utf8(buf).unwrap()
    }
}
