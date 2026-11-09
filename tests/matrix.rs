//! Every engine and journal, the files they leave, and the guards between them.
use firstpair_tursolite::{Engine, ErrorKind, Journal, Options, Result, Seal, Value, inspect, resolve};
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[allow(unused_imports)]
use firstpair_tursolite::Database;

fn temp(name: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("tursolite-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&d).unwrap();
    d
}

fn options(engine: Engine, journal: Journal) -> Options {
    Options { engine, journal, page_size: Some(65536), ..Options::default() }
}

const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS t(name TEXT PRIMARY KEY, n INT, data BLOB)";

fn write(path: &Path, o: &Options, rows: std::ops::Range<i64>) -> Result<()> {
    let db = Database::open(path, o)?;
    let c = db.connect()?;
    c.exec(SCHEMA)?;
    c.transaction(|| {
        for i in rows.clone() {
            c.run("INSERT INTO t VALUES (?, ?, ?)", &[Value::text(&format!("r{i}")), Value::Integer(i), Value::Blob(vec![i as u8; 70000])])?;
        }
        Ok(())
    })?;
    drop(c);
    db.close()
}

fn count(path: &Path, engine: Engine) -> Result<i64> {
    let o = Options { engine, read_only: true, create: false, ..Options::default() };
    let db = Database::open(path, &o)?;
    let c = db.connect()?;
    let n = c.query("SELECT count(*) FROM t", &[])?[0][0].as_i64()?;
    drop(c);
    db.close()?;
    Ok(n)
}

#[cfg(feature = "sqlite")]
#[test]
fn sqlite_journals() {
    let d = temp("sqlite");
    for (name, j) in [("delete", Journal::Delete), ("wal", Journal::Wal)] {
        let p = d.join(format!("{name}.db"));
        write(&p, &options(Engine::Sqlite, j), 0..3).unwrap();
        assert_eq!(count(&p, Engine::Sqlite).unwrap(), 3);
        assert_eq!(inspect(&p).unwrap().unwrap().page_size, 65536);
    }
}

#[cfg(feature = "sqlite")]
#[test]
fn foreign_keys_stay_off() {
    let d = temp("foreign-keys");
    let db = Database::open(&d.join("x.db"), &Options::default()).unwrap();
    let c = db.connect().unwrap();
    c.exec("CREATE TABLE a(k TEXT PRIMARY KEY); CREATE TABLE b(k TEXT PRIMARY KEY REFERENCES a(k)); INSERT INTO a VALUES ('x'); INSERT INTO b VALUES ('x')").unwrap();
    c.exec("UPDATE a SET k = 'y' WHERE k = 'x'").unwrap();
    c.exec("INSERT INTO b VALUES ('no parent')").unwrap();
}

#[cfg(feature = "sqlite")]
#[test]
fn typed_rows_and_errors() {
    let d = temp("typed");
    let p = d.join("x y?#%.db");
    let db = Database::open(&p, &Options::default()).unwrap();
    let c = db.connect().unwrap();
    c.exec(SCHEMA).unwrap();
    c.run("INSERT INTO t VALUES (?, ?, ?)", &["a".into(), 1i64.into(), vec![0u8, 255].into()]).unwrap();
    c.run("INSERT INTO t VALUES (?, ?, ?)", &["b".into(), Value::from(None::<i64>), Value::Null]).unwrap();
    assert_eq!(c.last_insert_rowid().unwrap(), 2);
    assert_eq!(c.query_value::<i64>("SELECT count(*) FROM t", &[]).unwrap(), 2);
    assert_eq!(c.query_value::<Option<i64>>("SELECT n FROM t WHERE name = 'b'", &[]).unwrap(), None);
    assert_eq!(c.query_value::<Vec<u8>>("SELECT data FROM t WHERE name = 'a'", &[]).unwrap(), vec![0, 255]);
    assert!(c.query_one("SELECT 1 FROM t WHERE name = 'z'", &[]).unwrap().is_none());
    let names = c.query_map("SELECT name FROM t ORDER BY name", &[], |r| r[0].get::<String>()).unwrap();
    assert_eq!(names, ["a", "b"]);
    let mut seen = 0;
    c.for_each("SELECT n FROM t", &[], |_| {
        seen += 1;
        Ok(())
    })
    .unwrap();
    assert_eq!(seen, 2);
    let e = c.run("INSERT INTO t VALUES ('a', 2, NULL)", &[]).unwrap_err();
    assert_eq!((e.kind, e.conflict), (ErrorKind::Constraint, false), "{e}");
    drop(c);
    db.close().unwrap();
    let o = Options { immutable: true, create: false, ..Options::default() };
    let db = Database::open(&p, &o).unwrap();
    let c = db.connect().unwrap();
    assert_eq!(c.query_value::<i64>("SELECT count(*) FROM t", &[]).unwrap(), 2);
    assert_eq!(c.run("DELETE FROM t", &[]).unwrap_err().kind, ErrorKind::ReadOnly);
    drop(c);
    db.close().unwrap();
    let junk = d.join("junk.db");
    std::fs::write(&junk, [7u8; 200]).unwrap();
    assert_eq!(Database::open(&junk, &Options::default()).err().unwrap().kind, ErrorKind::NotADatabase);
}

#[cfg(feature = "sqlite")]
#[test]
fn mvcc_needs_turso() {
    let d = temp("mvcc-needs");
    let p = d.join("x.db");
    write(&p, &options(Engine::Sqlite, Journal::Mvcc), 0..1).unwrap();
    let h = inspect(&p).unwrap().unwrap();
    assert!(!h.mvcc() && h.write_version == 1, "falls to a rollback journal: {h:?}");
}

#[cfg(all(feature = "sqlite", feature = "turso"))]
mod both {
    use super::*;

    #[test]
    fn turso_seals_to_a_standard_file() {
        let d = temp("seal");
        for (name, j) in [("wal", Journal::Delete), ("mvcc", Journal::Mvcc)] {
            let p = d.join(format!("{name}.sqlar"));
            write(&p, &options(Engine::Turso, j), 0..5).unwrap();
            let h = inspect(&p).unwrap().unwrap();
            assert_eq!((h.write_version, h.read_version, h.page_size, h.auto_vacuum), (1, 1, 65536, false), "{name}: {h:?}");
            let left: Vec<_> = std::fs::read_dir(&d).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap())
                .filter(|n| n.starts_with(name) && !n.ends_with(".sqlar")).collect();
            assert!(left.is_empty(), "{name}: companions left: {left:?}");
            assert_eq!(count(&p, Engine::Sqlite).unwrap(), 5);
            assert_eq!(count(&p, Engine::Turso).unwrap(), 5);
            write(&p, &options(Engine::Sqlite, Journal::Delete), 5..6).unwrap();
            write(&p, &options(Engine::Turso, j), 6..7).unwrap();
            assert_eq!(count(&p, Engine::Sqlite).unwrap(), 7);
        }
    }

    #[test]
    fn an_auto_vacuum_file_stays_with_sqlite() {
        let d = temp("autovacuum");
        let p = d.join("stock.sqlar");
        let o = Options { auto_vacuum: true, ..options(Engine::Sqlite, Journal::Delete) };
        write(&p, &o, 0..2).unwrap();
        let before = std::fs::read(&p).unwrap();
        assert!(inspect(&p).unwrap().unwrap().auto_vacuum);
        for j in [Journal::Delete, Journal::Wal, Journal::Mvcc] {
            let e = write(&p, &options(Engine::Turso, j), 2..3).err().expect("Turso must refuse");
            assert!(e.message.contains("auto-vacuum") && e.kind == ErrorKind::Refused, "{e}");
        }
        assert_eq!(resolve(&p, Engine::Turso, true).unwrap(), Engine::Sqlite);
        assert_eq!(count(&p, Engine::Turso).unwrap(), 2, "a read falls to SQLite");
        assert!(std::fs::read(&p).unwrap() == before, "nothing asked of Turso touched the file");
    }

    #[test]
    fn reading_with_turso_leaves_a_standard_file_alone() {
        let d = temp("read-only");
        let p = d.join("x.sqlar");
        write(&p, &options(Engine::Sqlite, Journal::Delete), 0..3).unwrap();
        let before = std::fs::read(&p).unwrap();
        assert_eq!(count(&p, Engine::Turso).unwrap(), 3);
        assert!(std::fs::read(&p).unwrap() == before);
        assert_eq!(std::fs::read_dir(&d).unwrap().count(), 1, "no companion files");
    }

    #[test]
    fn an_unsealed_mvcc_file_needs_turso() {
        let d = temp("unsealed");
        let p = d.join("x.sqlar");
        let db = Database::open(&p, &options(Engine::Turso, Journal::Mvcc)).unwrap();
        let c = db.connect().unwrap();
        c.exec(SCHEMA).unwrap();
        c.transaction(|| c.run("INSERT INTO t VALUES ('a', 1, x'00')", &[])).unwrap();
        c.exec("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        drop(c);
        drop(db); // a crash, in effect: never sealed
        assert!(inspect(&p).unwrap().unwrap().mvcc());
        assert_eq!(resolve(&p, Engine::Sqlite, false).unwrap(), Engine::Turso);
        let immutable = Options { immutable: true, ..Options::default() };
        assert_eq!(Database::open(&p, &immutable).err().unwrap().kind, ErrorKind::Refused);
        let db = Database::open(&p, &options(Engine::Sqlite, Journal::Delete)).unwrap();
        assert_eq!(db.engine(), Engine::Turso);
        assert!(db.mvcc());
        let c = db.connect().unwrap();
        assert_eq!(c.query("SELECT count(*) FROM t", &[]).unwrap()[0][0], Value::Integer(1));
        drop(c);
        db.close().unwrap();
        assert!(!inspect(&p).unwrap().unwrap().mvcc());
        assert_eq!(count(&p, Engine::Sqlite).unwrap(), 1);
    }

    #[test]
    fn sealing_as_far_as_wal_and_leaving_a_journal_alone() {
        let d = temp("wal-seal");
        let p = d.join("kept.sqlar");
        let o = Options { seal: Seal::Wal, ..options(Engine::Turso, Journal::Mvcc) };
        write(&p, &o, 0..2).unwrap();
        assert_eq!(inspect(&p).unwrap().unwrap().write_version, 2);
        write(&p, &o, 2..3).unwrap();
        assert_eq!(count(&p, Engine::Sqlite).unwrap(), 3);
        let p = d.join("existing.db");
        write(&p, &options(Engine::Sqlite, Journal::Wal), 0..1).unwrap();
        write(&p, &options(Engine::Sqlite, Journal::Existing), 1..2).unwrap();
        assert_eq!(inspect(&p).unwrap().unwrap().write_version, 2);
    }

    #[test]
    fn concurrent_writers_lose_nothing() {
        let d = temp("concurrent");
        let p = d.join("x.sqlar");
        let db = Arc::new(Database::open(&p, &options(Engine::Turso, Journal::Mvcc)).unwrap());
        let setup = db.connect().unwrap();
        setup.exec(SCHEMA).unwrap();
        setup.exec("CREATE TABLE IF NOT EXISTS e(k TEXT PRIMARY KEY, v INT); INSERT INTO e VALUES ('epoch', 0)").unwrap();
        let handles: Vec<_> = (0..4).map(|k| {
            let db = db.clone();
            std::thread::spawn(move || {
                let c = db.connect().unwrap();
                for b in 0..10 {
                    c.transaction(|| {
                        for i in 0..5 {
                            c.run("INSERT INTO t VALUES (?, ?, ?)", &[Value::text(&format!("{k}-{b}-{i}")), Value::Integer(i), Value::Blob(vec![1; 70000])])?;
                        }
                        Ok(())
                    }).unwrap();
                    // The one row every writer shares: a short transaction of its own.
                    c.transaction(|| c.run("UPDATE e SET v = v + 1 WHERE k = 'epoch'", &[])).unwrap();
                }
            })
        }).collect();
        for h in handles { h.join().unwrap(); }
        assert_eq!(setup.query("SELECT count(*) FROM t", &[]).unwrap()[0][0], Value::Integer(200));
        assert_eq!(setup.query("SELECT v FROM e", &[]).unwrap()[0][0], Value::Integer(40));
        drop(setup);
        Arc::into_inner(db).unwrap().close().unwrap();
        assert_eq!(count(&p, Engine::Sqlite).unwrap(), 200);
    }
}

/// The other half of python/tests/test_matrix.py's cross-language check: a
/// file Python's Turso path wrote and sealed, read by this crate's SQLite.
#[cfg(feature = "sqlite")]
#[test]
fn reads_a_file_python_sealed() {
    let Ok(path) = std::env::var("TURSOLITE_PYTHON_FILE") else { return };
    let rows: i64 = std::env::var("TURSOLITE_PYTHON_ROWS").unwrap().parse().unwrap();
    let p = PathBuf::from(path);
    let h = inspect(&p).unwrap().unwrap();
    assert!(!h.mvcc() && h.write_version == 1, "sealed to a rollback journal: {h:?}");
    assert_eq!(resolve(&p, Engine::Sqlite, true).unwrap(), Engine::Sqlite);
    let db = Database::open(&p, &Options { read_only: true, create: false, ..Options::default() }).unwrap();
    let c = db.connect().unwrap();
    assert_eq!(c.query("PRAGMA integrity_check", &[]).unwrap()[0][0], Value::text("ok"));
    assert_eq!(c.query("SELECT count(*) FROM t", &[]).unwrap()[0][0].as_i64().unwrap(), rows);
    drop(c);
    db.close().unwrap();
}
