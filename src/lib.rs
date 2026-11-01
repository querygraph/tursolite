//! One embedded SQL interface over SQLite and Turso.
//!
//! A [`Database`] is opened with an [`Engine`] and a [`Journal`]; each thread
//! takes its own [`Connection`]. The rules that keep the two engines' files
//! apart are enforced here, at open, for every caller (see the README):
//!
//! - Turso never writes a file with auto-vacuum: its experimental support
//!   leaves a database that SQLite's integrity check rejects.
//! - A file in Turso's MVCC mode (header bytes 18 and 19 are 255) opens only
//!   with Turso; SQLite calls it "not a database".
//! - Turso has no rollback journal. `Journal::Delete` under Turso writes WAL,
//!   and [`Database::close`] seals the file back to a standard one.

use std::fmt;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Engine {
    Sqlite,
    Turso,
}

impl Engine {
    pub fn parse(name: &str) -> Result<Engine> {
        match name {
            "sqlite" => Ok(Engine::Sqlite),
            "turso" => Ok(Engine::Turso),
            _ => Err(Error::new(format!("unknown engine {name}"))),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Engine::Sqlite => "sqlite",
            Engine::Turso => "turso",
        }
    }

    /// Whether this build links the engine.
    pub fn available(self) -> bool {
        match self {
            Engine::Sqlite => cfg!(feature = "sqlite"),
            Engine::Turso => cfg!(feature = "turso"),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Journal {
    Delete,
    Wal,
    Mvcc,
    /// Leave a file's journal as it is found.
    Existing,
}

/// What closing leaves of a file Turso wrote.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Seal {
    /// A rollback journal, as SQLite made it, where SQLite is linked.
    Standard,
    /// A WAL file, which Turso reopens as it was.
    Wal,
}

#[derive(Clone, Debug)]
pub struct Options {
    pub engine: Engine,
    pub journal: Journal,
    /// Set on a new file only.
    pub page_size: Option<u32>,
    /// Incremental auto-vacuum on a new file; SQLite only.
    pub auto_vacuum: bool,
    pub read_only: bool,
    pub create: bool,
    pub busy_ms: u64,
    pub seal: Seal,
}

impl Default for Options {
    fn default() -> Options {
        Options {
            engine: Engine::Sqlite,
            journal: Journal::Delete,
            page_size: None,
            auto_vacuum: false,
            read_only: false,
            create: true,
            busy_ms: 60000,
            seal: Seal::Standard,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Null,
    Integer(i64),
    Real(f64),
    /// Bytes, because a file name need not be UTF-8; Turso refuses those.
    Text(Vec<u8>),
    Blob(Vec<u8>),
}

impl Value {
    pub fn text(s: &str) -> Value {
        Value::Text(s.as_bytes().to_vec())
    }

    pub fn as_i64(&self) -> Result<i64> {
        match self {
            Value::Integer(n) => Ok(*n),
            _ => Err(Error::new("expected an integer".into())),
        }
    }

    pub fn as_bytes(&self) -> Result<&[u8]> {
        match self {
            Value::Text(s) | Value::Blob(s) => Ok(s),
            _ => Err(Error::new("expected text".into())),
        }
    }

    pub fn as_str(&self) -> Result<String> {
        Ok(String::from_utf8_lossy(self.as_bytes()?).into_owned())
    }
}

#[derive(Debug, Clone)]
pub struct Error {
    pub message: String,
    /// A concurrent transaction lost; the caller may roll back and retry.
    pub conflict: bool,
}

impl Error {
    pub fn new(message: String) -> Error {
        Error { message, conflict: false }
    }

    #[cfg(feature = "turso")]
    fn engine(message: String) -> Error {
        let lower = message.to_lowercase();
        let conflict = lower.contains("conflict") || lower.contains("database is locked") || lower.contains("busy");
        Error { message, conflict }
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

/// What the first 100 bytes of a database file say.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Header {
    pub page_size: u32,
    pub write_version: u8,
    pub read_version: u8,
    pub auto_vacuum: bool,
}

impl Header {
    pub fn mvcc(&self) -> bool {
        self.write_version == 255 && self.read_version == 255
    }
}

/// The header of a database file; `None` when it is missing or still empty.
pub fn inspect(path: &Path) -> Result<Option<Header>> {
    let mut b = [0u8; 100];
    let mut f = match fs::File::open(path) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(Error::new(format!("{}: {e}", path.display()))),
    };
    let mut got = 0;
    while got < 100 {
        match f.read(&mut b[got..]) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) => return Err(Error::new(format!("{}: {e}", path.display()))),
        }
    }
    if got == 0 {
        return Ok(None);
    }
    if got < 100 || &b[..16] != b"SQLite format 3\0" {
        return Err(Error::new(format!("{}: not a database", path.display())));
    }
    let raw = u16::from_be_bytes([b[16], b[17]]) as u32;
    Ok(Some(Header {
        page_size: if raw == 1 { 65536 } else { raw },
        write_version: b[18],
        read_version: b[19],
        // Largest root b-tree page: nonzero exactly with auto-vacuum.
        auto_vacuum: b[52..56] != [0, 0, 0, 0],
    }))
}

/// The engine that may open [path] for [want], or why none may. `want` is
/// honoured when it can be: a file Turso may not write falls to SQLite for
/// reading, an MVCC file to Turso always.
pub fn resolve(path: &Path, want: Engine, read_only: bool) -> Result<Engine> {
    let refused = |m: String| Err(Error::new(format!("{}: {m}", path.display())));
    let usable = |e: Engine| {
        if e.available() {
            Ok(e)
        } else {
            Err(Error::new(format!("{}: needs {}, which this build does not link", path.display(), e.name())))
        }
    };
    match inspect(path)? {
        Some(h) if h.mvcc() => usable(Engine::Turso),
        Some(h) if h.auto_vacuum && want == Engine::Turso => {
            if read_only {
                usable(Engine::Sqlite)
            } else {
                refused("has auto-vacuum, which Turso cannot write safely; rebuild it without".into())
            }
        }
        _ => usable(want),
    }
}

fn check_options(path: &Path, o: &Options) -> Result<()> {
    if o.journal == Journal::Mvcc && o.engine != Engine::Turso {
        return Err(Error::new(format!("{}: MVCC needs the turso engine", path.display())));
    }
    if o.auto_vacuum && o.engine == Engine::Turso {
        return Err(Error::new(format!("{}: Turso cannot write auto-vacuum", path.display())));
    }
    Ok(())
}

enum Backend {
    #[cfg(feature = "sqlite")]
    Sqlite,
    #[cfg(feature = "turso")]
    Turso(turso::Database),
}

pub struct Database {
    backend: Backend,
    path: PathBuf,
    options: Options,
    /// In MVCC mode now, whatever was asked for: an unsealed file.
    mvcc: bool,
    /// The connection that set up the file. A new file's page size and vacuum
    /// mode belong to it, so it is the first handed out.
    first: Mutex<Option<Connection>>,
}

pub struct Connection {
    inner: ConnectionInner,
    mvcc: bool,
}

enum ConnectionInner {
    #[cfg(feature = "sqlite")]
    Sqlite(rusqlite::Connection),
    #[cfg(feature = "turso")]
    Turso(turso::Connection),
}

impl Database {
    /// Opens [path]. The engine actually used is [Database::engine]: see
    /// [resolve] for when it differs from the one asked for.
    pub fn open(path: &Path, options: &Options) -> Result<Database> {
        let mut o = options.clone();
        let existing = inspect(path)?;
        if existing.is_none() && !o.create {
            return Err(Error::new(format!("{}: no such database", path.display())));
        }
        o.engine = resolve(path, o.engine, o.read_only)?;
        if o.journal == Journal::Mvcc && o.engine != Engine::Turso {
            o.journal = Journal::Delete;
        }
        check_options(path, &o)?;
        let fresh = existing.is_none();
        let mvcc = o.journal == Journal::Mvcc || existing.is_some_and(|h| h.mvcc());
        let backend = match o.engine {
            #[cfg(feature = "sqlite")]
            Engine::Sqlite => Backend::Sqlite,
            #[cfg(feature = "turso")]
            Engine::Turso => {
                let mut b = turso::Builder::new_local(&path.to_string_lossy());
                if o.read_only {
                    b = b.read_only(true);
                }
                Backend::Turso(pollster::block_on(b.build()).map_err(|e| Error::engine(format!("{}: {e}", path.display())))?)
            }
            #[allow(unreachable_patterns)]
            e => return Err(Error::new(format!("{} is not linked", e.name()))),
        };
        let db = Database { backend, path: path.to_path_buf(), options: o, mvcc, first: Mutex::new(None) };
        let c = db.open_connection()?;
        if !db.options.read_only {
            if fresh {
                if let Some(size) = db.options.page_size {
                    c.exec(&format!("PRAGMA page_size = {size}"))?;
                }
                if db.options.auto_vacuum {
                    c.exec("PRAGMA auto_vacuum = INCREMENTAL")?;
                }
            }
            if mvcc {
                let mode = c.query("PRAGMA journal_mode = mvcc", &[])?;
                if mode.first().and_then(|r| r.first()) != Some(&Value::text("mvcc")) {
                    return Err(Error::new(format!("{}: Turso did not enable MVCC", path.display())));
                }
            } else if db.options.engine == Engine::Sqlite {
                match db.options.journal {
                    Journal::Wal => c.exec("PRAGMA journal_mode = WAL")?,
                    Journal::Delete => c.exec("PRAGMA journal_mode = DELETE")?,
                    Journal::Mvcc | Journal::Existing => {}
                }
            }
        }
        *db.first.lock().unwrap() = Some(c);
        Ok(db)
    }

    pub fn engine(&self) -> Engine {
        self.options.engine
    }

    pub fn mvcc(&self) -> bool {
        self.mvcc
    }

    /// A connection of its own for one thread. Only MVCC lets several write.
    pub fn connect(&self) -> Result<Connection> {
        match self.first.lock().unwrap().take() {
            Some(c) => Ok(c),
            None => self.open_connection(),
        }
    }

    fn open_connection(&self) -> Result<Connection> {
        let inner = match &self.backend {
            #[cfg(feature = "sqlite")]
            Backend::Sqlite => {
                let flags = if self.options.read_only {
                    rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY
                } else {
                    rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE | rusqlite::OpenFlags::SQLITE_OPEN_CREATE
                };
                let c = rusqlite::Connection::open_with_flags(&self.path, flags).map_err(sqlite_error)?;
                c.busy_timeout(std::time::Duration::from_millis(self.options.busy_ms)).map_err(sqlite_error)?;
                // The bundled SQLite turns these on by default; the sqlite3 of
                // the OCaml build and Turso do not. One rule for all of them.
                c.execute_batch("PRAGMA foreign_keys = OFF").map_err(sqlite_error)?;
                ConnectionInner::Sqlite(c)
            }
            #[cfg(feature = "turso")]
            Backend::Turso(db) => {
                let c = db.connect().map_err(|e| Error::engine(e.to_string()))?;
                c.busy_timeout(std::time::Duration::from_millis(self.options.busy_ms))
                    .map_err(|e| Error::engine(e.to_string()))?;
                ConnectionInner::Turso(c)
            }
        };
        Ok(Connection { inner, mvcc: self.mvcc })
    }

    /// Closes the file. What Turso wrote is sealed: checkpointed, out of MVCC,
    /// and as `seal` says, back to a rollback journal with the empty companion
    /// files gone, or left as a WAL file. All connections must be dropped first.
    pub fn close(self) -> Result<()> {
        let turso = self.options.engine == Engine::Turso;
        if !turso || self.options.read_only {
            return Ok(());
        }
        let c = self.connect()?;
        c.exec("PRAGMA wal_checkpoint(TRUNCATE)")?;
        if self.mvcc {
            c.exec("PRAGMA journal_mode = wal")?;
            c.exec("PRAGMA wal_checkpoint(TRUNCATE)")?;
        }
        drop(c);
        let wal = self.options.journal == Journal::Wal || self.options.seal == Seal::Wal;
        let path = self.path.clone();
        drop(self);
        if !wal {
            standard(&path)?;
        }
        Ok(())
    }
}

/// A sealed Turso file back to a rollback journal, and its empty companions
/// removed. A companion with content is reported: it may hold commits.
fn standard(path: &Path) -> Result<()> {
    #[cfg(feature = "sqlite")]
    {
        let c = rusqlite::Connection::open(path).map_err(sqlite_error)?;
        let mode: String = c.query_row("PRAGMA journal_mode = DELETE", [], |r| r.get(0)).map_err(sqlite_error)?;
        if mode != "delete" {
            return Err(Error::new(format!("{}: journal stayed {mode}", path.display())));
        }
    }
    let name = path.to_string_lossy();
    for companion in [path.with_extension("db-log"), PathBuf::from(format!("{name}-wal"))] {
        match fs::metadata(&companion) {
            Ok(m) if m.len() == 0 => {
                fs::remove_file(&companion).map_err(|e| Error::new(format!("{}: {e}", companion.display())))?;
            }
            Ok(_) => return Err(Error::new(format!("{}: not empty after sealing", companion.display()))),
            Err(_) => {}
        }
    }
    // Only an index of a WAL that is gone; some SQLite builds leave it behind.
    let _ = fs::remove_file(format!("{name}-shm"));
    Ok(())
}

#[cfg(feature = "sqlite")]
fn sqlite_error(e: rusqlite::Error) -> Error {
    let conflict = matches!(
        e.sqlite_error_code(),
        Some(rusqlite::ErrorCode::DatabaseBusy) | Some(rusqlite::ErrorCode::DatabaseLocked)
    );
    Error { message: e.to_string(), conflict }
}

#[cfg(feature = "sqlite")]
fn to_sqlite(v: &Value) -> rusqlite::types::ToSqlOutput<'_> {
    use rusqlite::types::{ToSqlOutput, ValueRef};
    ToSqlOutput::Borrowed(match v {
        Value::Null => ValueRef::Null,
        Value::Integer(n) => ValueRef::Integer(*n),
        Value::Real(x) => ValueRef::Real(*x),
        Value::Text(s) => ValueRef::Text(s),
        Value::Blob(b) => ValueRef::Blob(b),
    })
}

#[cfg(feature = "sqlite")]
fn sqlite_query(c: &rusqlite::Connection, sql: &str, params: &[Value]) -> Result<Vec<Vec<Value>>> {
    let mut st = c.prepare_cached(sql).map_err(sqlite_error)?;
    for (i, p) in params.iter().enumerate() {
        st.raw_bind_parameter(i + 1, to_sqlite(p)).map_err(sqlite_error)?;
    }
    let n = st.column_count();
    let mut rows = st.raw_query();
    let mut out = Vec::new();
    while let Some(r) = rows.next().map_err(sqlite_error)? {
        let mut row = Vec::with_capacity(n);
        for i in 0..n {
            use rusqlite::types::ValueRef;
            row.push(match r.get_ref(i).map_err(sqlite_error)? {
                ValueRef::Null => Value::Null,
                ValueRef::Integer(n) => Value::Integer(n),
                ValueRef::Real(x) => Value::Real(x),
                ValueRef::Text(s) => Value::Text(s.to_vec()),
                ValueRef::Blob(b) => Value::Blob(b.to_vec()),
            });
        }
        out.push(row);
    }
    Ok(out)
}

#[cfg(feature = "turso")]
fn to_turso(v: &Value) -> Result<turso::Value> {
    Ok(match v {
        Value::Null => turso::Value::Null,
        Value::Integer(n) => turso::Value::Integer(*n),
        Value::Real(x) => turso::Value::Real(*x),
        Value::Text(s) => {
            turso::Value::Text(String::from_utf8(s.clone()).map_err(|_| Error::new("Turso text must be UTF-8".into()))?)
        }
        Value::Blob(b) => turso::Value::Blob(b.clone()),
    })
}

#[cfg(feature = "turso")]
fn turso_query(c: &turso::Connection, sql: &str, params: &[Value]) -> Result<Vec<Vec<Value>>> {
    let values = params.iter().map(to_turso).collect::<Result<Vec<_>>>()?;
    pollster::block_on(async {
        let mut rows = c.query(sql, values).await.map_err(|e| Error::engine(e.to_string()))?;
        let mut out = Vec::new();
        while let Some(r) = rows.next().await.map_err(|e| Error::engine(e.to_string()))? {
            let mut row = Vec::with_capacity(r.column_count());
            for i in 0..r.column_count() {
                row.push(match r.get_value(i).map_err(|e| Error::engine(e.to_string()))? {
                    turso::Value::Null => Value::Null,
                    turso::Value::Integer(n) => Value::Integer(n),
                    turso::Value::Real(x) => Value::Real(x),
                    turso::Value::Text(s) => Value::Text(s.into_bytes()),
                    turso::Value::Blob(b) => Value::Blob(b),
                });
            }
            out.push(row);
        }
        Ok(out)
    })
}

impl Connection {
    /// Runs one statement and returns its rows.
    pub fn query(&self, sql: &str, params: &[Value]) -> Result<Vec<Vec<Value>>> {
        match &self.inner {
            #[cfg(feature = "sqlite")]
            ConnectionInner::Sqlite(c) => sqlite_query(c, sql, params),
            #[cfg(feature = "turso")]
            ConnectionInner::Turso(c) => turso_query(c, sql, params),
        }
    }

    pub fn run(&self, sql: &str, params: &[Value]) -> Result<()> {
        self.query(sql, params).map(|_| ())
    }

    /// Runs statements with no parameters, separated by semicolons.
    pub fn exec(&self, sql: &str) -> Result<()> {
        match &self.inner {
            #[cfg(feature = "sqlite")]
            ConnectionInner::Sqlite(c) => c.execute_batch(sql).map_err(sqlite_error),
            #[cfg(feature = "turso")]
            // Turso's batch refuses a statement that returns rows, as pragmas do.
            ConnectionInner::Turso(c) if !sql.contains(';') => turso_query(c, sql, &[]).map(|_| ()),
            #[cfg(feature = "turso")]
            ConnectionInner::Turso(c) => {
                pollster::block_on(c.execute_batch(sql)).map_err(|e| Error::engine(e.to_string()))
            }
        }
    }

    /// `work` in one write transaction, concurrent under MVCC. A lost
    /// transaction runs again, so `work` must be repeatable.
    pub fn transaction<T>(&self, mut work: impl FnMut() -> Result<T>) -> Result<T> {
        let begin = if self.mvcc { "BEGIN CONCURRENT" } else { "BEGIN IMMEDIATE" };
        let mut delay = 1;
        loop {
            let attempt = self.exec(begin).and_then(|()| {
                let value = work()?;
                self.exec("COMMIT")?;
                Ok(value)
            });
            match attempt {
                Ok(value) => return Ok(value),
                Err(e) => {
                    let _ = self.exec("ROLLBACK");
                    if !(self.mvcc && e.conflict) {
                        return Err(e);
                    }
                    std::thread::sleep(std::time::Duration::from_millis(delay));
                    delay = (delay * 2).min(250);
                }
            }
        }
    }
}
