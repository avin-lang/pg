# pg

A PostgreSQL client for Avin: the frontend/backend protocol (version 3) over TCP and TLS,
SCRAM-SHA-256, MD5, cleartext and trust authentication, simple queries and the extended protocol with
a statement cache, typed parameters and results, rows read by column or into derived types, the
server's errors with every field, transactions with savepoints, a connection pool, and statements
cancelled when their thread is.

The package's module is **`dev.avinlang.pg`**, written in Avin. A program depends on it in its
`avin.hocon`:

```hocon
dependencies {
  pg { git = "github.com/avin-lang/pg", version = "0.0.1" }
}
```

It brings in [json](https://github.com/avin-lang/json) 0.0.2, for `json` and `jsonb` values, and
needs nothing else beyond the standard library.

```avin
import dev.avinlang.pg
import dev.avinlang.pg.PgError

main() -> Result[unit, PgError]
  val db = pg.connect("postgres://app:secret@localhost/shop")?
  val n = db.queryValue[long]("select count(*) from orders where total > $1", 100)?
  println(s"$n large orders")
  db.close()
```

## Connecting

`pg.connect(url)` reads a connection URL and connects; `pg.connect(config)` takes a `PgConfig`, whose
fields are the URL's parts and a few settings a URL cannot carry (a notice sink).

```text
postgres://user:password@host:port/database?option=value&…      (or postgresql://)
```

The user, password and database are percent-decoded. Left out, the host is `localhost`, the port
5432, the user `postgres`, and the database the user's name. The options:

| Option | Values | |
|---|---|---|
| `sslmode` | `disable`, `prefer` (the default), `require`, `verify-full` | see TLS below |
| `sslrootcert` | a file of PEM certificates | authorities trusted beside the machine's own |
| `application_name` | text | shown in `pg_stat_activity` |
| `connect_timeout` | whole seconds; `0` is none | each wait while connecting |
| `statement_cache_size` | a count, default 100; `0` caches nothing | see Statements |

Any other option is refused with `Config`, so a misspelt one is not silently ignored.

**TLS.** The TLS client always checks the server's certificate against the trusted authorities and
the host name. So `require` and `verify-full` are the same: TLS with a verified certificate, or no
connection (`TlsRefused` where the server will not speak TLS, `Tls(error)` where its certificate is
refused). `prefer` asks for TLS; where the server will not speak it the connection goes on in plain
TCP, and where its certificate does not verify a fresh plain connection is made. `disable` never asks. libpq's `allow` and `verify-ca` are not
offered.

**Authentication** is whatever the server asks for: SCRAM-SHA-256 (the password prepared with
SASLprep, and the server made to prove it knows the password too), MD5, cleartext, or none.

## Queries

`query` runs a statement through the extended protocol and answers its rows; `queryOne` the first row
or `None`; `queryValue[T]` the first column of the first row; `queryAs[T]` every row as a `T`;
`execute` how many rows the statement touched. Parameters are `$1`, `$2`, … and are given after the
statement, as any value whose type is `ToPg`:

```avin
db.execute("create temporary table items (id int primary key, name text, price numeric)")?
db.execute("insert into items values ($1, $2, $3), ($4, $5, $6)", 1, "pen", BigDecimal("1.50"), 2, "ink", None: Option[BigDecimal])?
for row in db.query("select id, name, price from items order by id")?
  val name = row.get[string]("name")?
  val price = row.get[Option[BigDecimal]]("price")?
  println(s"$name: $price")
```

`simpleQuery(sql)` runs several statements separated by `;` through the simple protocol, with no
parameters, and answers each one's `QueryResult` (its command tag and rows).

**Reading values.** `row.get[T](name)` and `row.get[T](index)` read a column as `T`. NULL reads as
`None` of an `Option[T]`, and is a `BadColumn` error for any other `T`; so is a value of another type,
or a column that is not there. The types:

| PostgreSQL | Avin |
|---|---|
| `boolean` | `bool` |
| `smallint`, `integer`, `bigint`, `oid` | `int` (where it fits), `long` |
| `real`, `double precision` | `real` |
| `numeric` | `BigDecimal` |
| `text`, `varchar`, `char(n)`, `name` | `string` |
| `bytea` | `Vector[byte]` |
| `uuid` | `avin.uuid.Uuid` |
| `date`, `time`, `timestamp`, `timestamptz` | `avin.time.Date`, `Time`, `DateTime`, `Instant` |
| `json`, `jsonb` | `dev.avinlang.json.Json` |
| arrays of these | `Vector[T]` (`Vector[Option[T]]` where elements may be NULL) |

A date or timestamp of `infinity` is the type's `Max`, and `-infinity` its `Min`. Any value at all
can be read as a `PgValue`, the decoded form a row holds; a type the client does not know is
`PgOther(oid, text)`, as are a numeric `NaN` or `Infinity` and the time `24:00:00`, which no Avin
value holds.

**Rows as types.** A data type that `derives FromRow` reads each field from the column of its name,
or the one its `@PgColumn` names; a field whose column is absent takes its default:

```avin
data Item(id: int, @PgColumn("name") label: string, price: Option[BigDecimal] = None) derives FromRow

val items = db.queryAs[Item]("select id, name from items order by id")?
```

**Statements.** Each statement `query` and `execute` run is prepared once, kept under a name, and run
again by that name, up to `statement_cache_size` statements, the least recently used closed first. A
cached statement the server no longer accepts, its table having changed under it, is prepared again.
`prepare(sql)` makes a named statement of the program's own, run with `query(statement, …)` and
`execute(statement, …)` and closed with `deallocate`.

## Errors

Every operation answers a `Result[_, PgError]`. A statement or a connection the server refuses is
`Server(diagnostic)`, with every field the server sent: the SQLSTATE `code`, `message`, `detail`,
`hint`, `position`, `table`, `constraint` and the rest. `e.code` is the SQLSTATE of any `PgError`, or
`None`:

```avin
db.execute("create temporary table users (email text unique)")?
db.execute("insert into users values ($1)", "ada@example.com")?
db.execute("insert into users values ($1)", "ada@example.com") match
  Err(e) -> if e.code == Some("23505") then println("already registered")
  Ok(_) -> ()
```

The others: `Io` (the connection could not be made, broke or timed out), `Tls`, `TlsRefused`, `Auth`,
`Protocol`, `BadColumn`, `Config`, `RolledBack`, `Closed`, `PoolTimedOut` and `PoolClosed`. A
connection that broke is `isBroken`, and answers `Closed` from then on.

Notices and warnings the server sends go to `PgConfig`'s `notices`, a function given each
`Diagnostic`; without one they are dropped.

## Transactions

`transaction(f)` begins a transaction, runs `f`, and commits where `f` answers `Ok` and rolls back
where it answers `Err`, or where the thread running it is cancelled. A transaction inside another is
a savepoint, so they nest. Where a statement failed inside and `f` still answered `Ok`, the
transaction is rolled back and answers `RolledBack`.

```avin
db.execute("create temporary table accounts (id int, balance int)")?
db.execute("insert into accounts values (1, 100), (2, 0)")?
db.transaction(tx ->
  tx.execute("update accounts set balance = balance - $1 where id = $2", 30, 1)?
  tx.execute("update accounts set balance = balance + $1 where id = $2", 30, 2)?
  Ok(()))?
```

## Pooling

`PgPool.open(url, maxSize = 10)` shares connections between threads and actors. `use(f)` lends one
to `f` and takes it back however `f` ends; `transaction(f)` runs `f` in a transaction on one;
`query` and `execute` run one statement on one. A connection is made when one is asked for and none
is idle; one that broke, or that the server ended while it was idle, is let go and another made in
its place; one handed back inside a transaction is rolled back first, so the next user finds it
clean. `use`'s body gives back a sendable value, rows among them, and keeps nothing of the
connection.

```avin
import dev.avinlang.pg.PgPool

val pool = PgPool.open("postgres://app:secret@localhost/shop", maxSize = 8)?
val names = pool.use(c -> c.query("select name from customers"))?
pool.close()
```

## Cancellation

A statement whose thread is cancelled, by `withTimeout` or a scope, is cancelled on the server too:
the client sends a CancelRequest on a connection of its own, then reads what the server still sends
until the connection is ready again, so it can be used on. Where that fails the connection is broken.

```avin
import avin.threads.withTimeout
import avin.time.seconds

val r = withTimeout(seconds(2), _ -> db.query("select pg_sleep(60)"))   // None: cancelled
```

## Not yet

`LISTEN`/`NOTIFY` and `COPY` come next. A notification the server sends is dropped, and `COPY` is
refused.

## Tests

The tests run against a private server the package starts for them, on port 55432 (`PG_TEST_PORT` chooses another when the cluster is first made):

```zsh
zsh scripts/test-db.zsh start
```

then export what it prints (`PG_TEST_URL`, `PG_TEST_CA`) and run `avin test .`. Without
`PG_TEST_URL` the tests that need a server say so and pass. `zsh scripts/test-db.zsh stop` stops it.
