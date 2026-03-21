/// Whether zephyr is running on the host or inside a container.
///
/// Detection: `SYGALDRY_IN_CONTAINER=1` means container mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeContext {
    Host,
    Container,
}

impl RuntimeContext {
    pub fn detect() -> Self {
        match std::env::var("SYGALDRY_IN_CONTAINER").as_deref() {
            Ok("1") => Self::Container,
            _ => Self::Host,
        }
    }

    pub fn is_container(self) -> bool {
        self == Self::Container
    }

    pub fn is_host(self) -> bool {
        self == Self::Host
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn detects_host_by_default() {
        std::env::remove_var("SYGALDRY_IN_CONTAINER");
        assert_eq!(RuntimeContext::detect(), RuntimeContext::Host);
    }

    #[test]
    #[serial]
    fn detects_container_when_set() {
        std::env::set_var("SYGALDRY_IN_CONTAINER", "1");
        assert_eq!(RuntimeContext::detect(), RuntimeContext::Container);
        std::env::remove_var("SYGALDRY_IN_CONTAINER");
    }

    #[test]
    #[serial]
    fn detects_host_for_non_1_values() {
        std::env::set_var("SYGALDRY_IN_CONTAINER", "0");
        assert_eq!(RuntimeContext::detect(), RuntimeContext::Host);
        std::env::set_var("SYGALDRY_IN_CONTAINER", "yes");
        assert_eq!(RuntimeContext::detect(), RuntimeContext::Host);
        std::env::set_var("SYGALDRY_IN_CONTAINER", "");
        assert_eq!(RuntimeContext::detect(), RuntimeContext::Host);
        std::env::remove_var("SYGALDRY_IN_CONTAINER");
    }

    #[test]
    fn is_container_returns_true_for_container() {
        assert!(RuntimeContext::Container.is_container());
        assert!(!RuntimeContext::Host.is_container());
    }

    #[test]
    fn is_host_returns_true_for_host() {
        assert!(RuntimeContext::Host.is_host());
        assert!(!RuntimeContext::Container.is_host());
    }
}
