use std::time::{Duration, Instant};

#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    Launch,
    Terminate,
}

pub struct CodexPresence<T> {
    running: Vec<T>,
    missing_since: Option<Instant>,
}

impl<T> Default for CodexPresence<T> {
    fn default() -> Self {
        Self {
            running: Vec::new(),
            missing_since: None,
        }
    }
}

impl<T: PartialEq> CodexPresence<T> {
    pub fn update(&mut self, current: Vec<T>, now: Instant) -> Option<Action> {
        if !current.is_empty() {
            let launched = current.iter().any(|pid| !self.running.contains(pid));
            self.running = current;
            self.missing_since = None;
            return launched.then_some(Action::Launch);
        }
        if self.running.is_empty()
            || now.duration_since(*self.missing_since.get_or_insert(now)) < Duration::from_secs(1)
        {
            return None;
        }
        self.running.clear();
        self.missing_since = None;
        Some(Action::Terminate)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_launches_without_relaunching_a_manually_closed_companion() {
        let started = Instant::now();
        let mut presence = CodexPresence::default();
        assert_eq!(presence.update(vec![], started), None);
        assert_eq!(presence.update(vec![100], started), Some(Action::Launch));
        assert_eq!(
            presence.update(vec![100], started + Duration::from_secs(2)),
            None
        );
        assert_eq!(
            presence.update(vec![], started + Duration::from_secs(3)),
            None
        );
        assert_eq!(
            presence.update(vec![101], started + Duration::from_millis(3500)),
            Some(Action::Launch)
        );
        assert_eq!(
            presence.update(vec![101], started + Duration::from_secs(6)),
            None
        );
    }

    #[test]
    fn only_confirmed_codex_exit_terminates_usage_once() {
        let started = Instant::now();
        let mut presence = CodexPresence::default();
        assert_eq!(
            presence.update(vec![100, 101], started),
            Some(Action::Launch)
        );
        assert_eq!(
            presence.update(vec![101], started + Duration::from_secs(1)),
            None
        );
        assert_eq!(
            presence.update(vec![], started + Duration::from_secs(2)),
            None
        );
        assert_eq!(
            presence.update(vec![], started + Duration::from_millis(2500)),
            None
        );
        assert_eq!(
            presence.update(vec![], started + Duration::from_secs(3)),
            Some(Action::Terminate)
        );
        assert_eq!(
            presence.update(vec![], started + Duration::from_secs(4)),
            None
        );
    }
}
