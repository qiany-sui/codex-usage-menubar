use crate::model::QuotaSnapshot;
use serde::{Deserialize, Deserializer};
use std::collections::BTreeMap;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct RateLimits {
    rate_limits: Bucket,
    rate_limits_by_limit_id: Option<BTreeMap<String, Bucket>>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Bucket {
    limit_id: Option<String>,
    primary: Option<Window>,
    secondary: Option<Window>,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Window {
    used_percent: f64,
    window_duration_mins: Option<i64>,
    resets_at: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct BucketPatch {
    #[serde(default)]
    limit_id: Patch<String>,
    #[serde(default)]
    primary: Patch<WindowPatch>,
    #[serde(default)]
    secondary: Patch<WindowPatch>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WindowPatch {
    #[serde(default)]
    used_percent: Patch<f64>,
    #[serde(default)]
    window_duration_mins: Patch<i64>,
    #[serde(default)]
    resets_at: Patch<i64>,
}

#[derive(Default)]
enum Patch<T> {
    #[default]
    Missing,
    Set(Option<T>),
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Patch<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> std::result::Result<Self, D::Error> {
        Option::deserialize(deserializer).map(Self::Set)
    }
}

impl<T> Patch<T> {
    fn merged<'a>(&'a self, previous: Option<&'a T>) -> Option<&'a T> {
        match self {
            Self::Missing => previous,
            Self::Set(value) => value.as_ref(),
        }
    }
}

impl BucketPatch {
    fn applies_to(&self, limits: &RateLimits, key: Option<&str>) -> bool {
        let root_id = limits.rate_limits.limit_id.as_ref();
        if let Some(key) = key {
            let by_id = limits.rate_limits_by_limit_id.as_ref();
            self.limit_id.merged(root_id).is_some_and(|target| {
                !target.is_empty()
                    && (target == key
                        || by_id
                            .and_then(|buckets| buckets.get(key))
                            .and_then(|bucket| bucket.limit_id.as_ref())
                            == Some(target))
            })
        } else {
            match (self.limit_id.merged(None), root_id) {
                (Some(target), Some(root_id)) => target == root_id,
                _ => true,
            }
        }
    }

    fn apply_to(&self, bucket: &Bucket) -> Bucket {
        Bucket {
            limit_id: self.limit_id.merged(bucket.limit_id.as_ref()).cloned(),
            primary: merge_window(&self.primary, bucket.primary.as_ref()),
            secondary: merge_window(&self.secondary, bucket.secondary.as_ref()),
        }
    }
}

fn merge_window(patch: &Patch<WindowPatch>, previous: Option<&Window>) -> Option<Window> {
    match patch {
        Patch::Missing => previous.cloned(),
        Patch::Set(patch) => {
            let patch = patch.as_ref()?;
            Some(Window {
                used_percent: *patch
                    .used_percent
                    .merged(previous.map(|window| &window.used_percent))?,
                window_duration_mins: patch
                    .window_duration_mins
                    .merged(previous.and_then(|window| window.window_duration_mins.as_ref()))
                    .copied(),
                resets_at: patch
                    .resets_at
                    .merged(previous.and_then(|window| window.resets_at.as_ref()))
                    .copied(),
            })
        }
    }
}

impl RateLimits {
    pub(super) fn applying(&self, patch: &BucketPatch) -> Self {
        let rate_limits = if patch.applies_to(self, None) {
            patch.apply_to(&self.rate_limits)
        } else {
            self.rate_limits.clone()
        };
        let rate_limits_by_limit_id = self.rate_limits_by_limit_id.as_ref().map(|buckets| {
            buckets
                .iter()
                .map(|(key, bucket)| {
                    let bucket = if patch.applies_to(self, Some(key)) {
                        patch.apply_to(bucket)
                    } else {
                        bucket.clone()
                    };
                    (key.clone(), bucket)
                })
                .collect()
        });
        Self {
            rate_limits,
            rate_limits_by_limit_id,
        }
    }

    pub(super) fn select(
        &self,
        fetched_at: f64,
        notification: Option<(&RateLimits, &BucketPatch)>,
    ) -> Option<(QuotaSnapshot, bool)> {
        let buckets: Vec<_> = match &self.rate_limits_by_limit_id {
            Some(buckets) if !buckets.is_empty() => buckets
                .iter()
                .map(|(key, bucket)| (Some(key.as_str()), bucket))
                .collect(),
            _ => vec![(None, &self.rate_limits)],
        };
        let (limit_id, window, duration, reset, has_reading) = buckets
            .into_iter()
            .flat_map(|(key, bucket)| {
                let patch = notification
                    .filter(|(previous, patch)| patch.applies_to(previous, key))
                    .map(|(_, patch)| patch);
                [
                    (&bucket.primary, patch.map(|patch| &patch.primary)),
                    (&bucket.secondary, patch.map(|patch| &patch.secondary)),
                ]
                .into_iter()
                .filter_map(move |(window, patch)| {
                    let window = window.as_ref()?;
                    let duration = window.window_duration_mins?;
                    let reset = window.resets_at?;
                    if !(9000..=11000).contains(&duration) {
                        return None;
                    }
                    let has_reading = patch
                        .and_then(|patch| patch.merged(None))
                        .and_then(|patch| patch.used_percent.merged(None))
                        .is_some();
                    Some((
                        bucket.limit_id.as_deref().unwrap_or("unknown"),
                        window,
                        duration,
                        reset,
                        has_reading,
                    ))
                })
            })
            .min_by_key(|(id, _, duration, reset, _)| {
                (*id != "codex", (duration - 10080).abs(), *id, *reset)
            })?;
        Some((
            QuotaSnapshot {
                limit_id: limit_id.to_owned(),
                used_percent: window.used_percent,
                window_duration_minutes: duration,
                starts_at: reset as f64 - (duration * 60) as f64,
                resets_at: reset as f64,
                fetched_at,
            },
            has_reading,
        ))
    }
}
