//! Hit log: one JSON line per hit where the local player is the attacker or
//! the target, written to `<app_data>/hitlog/hits_<YYYYMMDD>.jsonl` (UTC date).
//!
//! Added in the Gitgeek85 fork so per-hit damage can be compared by hit type
//! (normal / front / back, crit or not) and damage taken can be broken down by
//! attacker and skill. Read-only, local-only: nothing here is uploaded.
//!
//! On by default; set `dpsMeter.hitLogEnabled` to `false` in settings.json to
//! turn it off.

use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::sync::OnceLock;

use parking_lot::Mutex;
use serde::Serialize;

use crate::entity::damage_packet::ParsedDamagePacket;
use crate::entity::special_damage::SpecialDamage;

struct HitLog {
    dir: PathBuf,
    day: String,
    writer: Option<BufWriter<File>>,
    since_flush: u32,
}

static HIT_LOG: OnceLock<Mutex<Option<HitLog>>> = OnceLock::new();

fn slot() -> &'static Mutex<Option<HitLog>> {
    HIT_LOG.get_or_init(|| Mutex::new(None))
}

/// Turn the hit log on (writing under `app_data_dir/hitlog`) or off.
pub fn set_enabled(enabled: bool, app_data_dir: &std::path::Path) {
    let mut guard = slot().lock();
    if enabled {
        let dir = app_data_dir.join("hitlog");
        let _ = std::fs::create_dir_all(&dir);
        *guard = Some(HitLog { dir, day: String::new(), writer: None, since_flush: 0 });
        tracing::info!("Hit log enabled");
    } else {
        if let Some(log) = guard.as_mut() {
            if let Some(w) = log.writer.as_mut() {
                let _ = w.flush();
            }
        }
        *guard = None;
    }
}

pub fn is_enabled() -> bool {
    slot().lock().is_some()
}

/// Who the other side of the hit is, as far as the meter knows.
#[derive(Clone, Copy)]
pub enum Kind {
    Boss,
    Dummy,
    Mob,
    Player,
    Unknown,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Boss => "boss",
            Kind::Dummy => "dummy",
            Kind::Mob => "mob",
            Kind::Player => "player",
            Kind::Unknown => "unknown",
        }
    }
}

#[derive(Serialize)]
struct Line<'a> {
    ts: i64,
    /// "out" = you hit something, "in" = something hit you.
    dir: &'a str,
    actor: i32,
    target: i32,
    /// Kind of the other entity (target for "out", attacker for "in").
    other: &'a str,
    /// NPC code of the other entity, when it is a mob/boss (0 otherwise).
    other_code: i32,
    skill: i32,
    dmg: i32,
    multi_n: i32,
    multi_dmg: i32,
    total: i32,
    crit: bool,
    back: bool,
    front: bool,
    parry: bool,
    perfect: bool,
    double: bool,
    block: bool,
    dot: bool,
    dtype: i32,
    specs: [bool; 5],
}

/// Record one hit. `outgoing`: the local player dealt it.
pub fn record(pdp: &ParsedDamagePacket, outgoing: bool, other: Kind, other_code: i32) {
    let mut guard = slot().lock();
    let Some(log) = guard.as_mut() else { return };

    let has = |s: SpecialDamage| pdp.specials().contains(&s);
    let line = Line {
        ts: pdp.timestamp(),
        dir: if outgoing { "out" } else { "in" },
        actor: pdp.actor_id(),
        target: pdp.target_id(),
        other: other.as_str(),
        other_code,
        skill: pdp.skill_code(),
        dmg: pdp.damage(),
        multi_n: pdp.multi_hit_count(),
        multi_dmg: pdp.multi_hit_damage(),
        total: pdp.total_damage(),
        crit: has(SpecialDamage::Critical),
        back: has(SpecialDamage::Back),
        front: has(SpecialDamage::Frontal),
        parry: has(SpecialDamage::Parry),
        perfect: has(SpecialDamage::Perfect),
        double: has(SpecialDamage::Double),
        block: has(SpecialDamage::ShieldBlock) || has(SpecialDamage::PerfectBlock),
        dot: pdp.is_dot(),
        dtype: pdp.damage_type(),
        specs: *pdp.spec_flags(),
    };
    let Ok(json) = serde_json::to_string(&line) else { return };

    // One file per UTC day.
    let day = chrono_day(pdp.timestamp());
    if log.writer.is_none() || log.day != day {
        if let Some(w) = log.writer.as_mut() {
            let _ = w.flush();
        }
        let path = log.dir.join(format!("hits_{}.jsonl", day));
        log.writer = OpenOptions::new().create(true).append(true).open(&path).ok().map(BufWriter::new);
        log.day = day;
    }
    if let Some(w) = log.writer.as_mut() {
        let _ = writeln!(w, "{}", json);
        log.since_flush += 1;
        if log.since_flush >= 1 {
            let _ = w.flush();
            log.since_flush = 0;
        }
    }
}

/// Flush buffered lines (called on fight end / idle so the file is current).
pub fn flush() {
    if let Some(log) = slot().lock().as_mut() {
        if let Some(w) = log.writer.as_mut() {
            let _ = w.flush();
        }
        log.since_flush = 0;
    }
}

/// YYYYMMDD in UTC from unix ms, without pulling in a date crate.
fn chrono_day(ms: i64) -> String {
    let days = ms.div_euclid(86_400_000);
    // Civil-from-days (Howard Hinnant).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{:04}{:02}{:02}", y, m, d)
}

#[cfg(test)]
mod tests {
    use super::chrono_day;

    #[test]
    fn day_from_ms() {
        assert_eq!(chrono_day(0), "19700101");
        assert_eq!(chrono_day(1_792_797_294_896), "20261023");
    }
}
