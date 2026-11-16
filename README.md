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
| `connect_timeout` | whole seconds; `0` is none | the whole connection to each server: name lookup, TCP, TLS, authentication |
| `statement_cache_size` | a count, default 100; `0` caches nothing | see Statements |
| `target_session_attrs` | `any` (the default), `read-write`, `read-only`, `primary`, `standby`, `prefer-standby` | see Several servers |
| `pgbouncer` | `true`, `false` (the default) | see PgBouncer |

Any other option is refused with `Config`, so a misspelt one is not silently ignored. libpq's keyword
form is read too, `host=db1,db2 port=5432 user=app dbname=shop sslmode=require`: each
`keyword=value`, a value with spaces in single quotes; the keywords are `host`, `port`, `user`,
`password`, `dbname` and the options above.

A connection that takes longer than `connect_timeout` fails with `Io`, its error's kind `TimedOut`,
wherever it had got to. Without one (the default), a connection waits as long as the network does.

### Several servers

A host list names several servers, tried in order, each within `connect_timeout`: in a URL, each host
with its own port (5432 where it has none); in the keyword form, `port` lists one port for every host
or gives one for all. `target_session_attrs` says which kind of server will do, read from what the
server reports as it starts (or, from a server older than 14, by asking it): `read-write` passes over
a standby or a server read-only by default, `read-only` the reverse, `primary` takes any server not
in hot standby and `standby` only one that is, and `prefer-standby` takes a standby where one answers
and the first server that connected otherwise. Where no server will do, the answer is the last one's
failure: `NoTarget(reason)` for one of the wrong kind.

```avin
val config = PgConfig.parse("postgres://app@db1:5432,db2:5433/shop?target_session_attrs=read-write")?
assertEq(config.servers, [Host("db1", 5432), Host("db2", 5433)])
```

`PgConfig`'s `hosts` holds the list (`servers` is it, or `host` at `port` where it is empty), and
`targetSessionAttrs` the kind.

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
`Protocol`, `BadColumn`, `Config`, `RolledBack`, `Closed`, `PoolTimedOut`, `PoolBusy`, `PoolClosed`,
`NotSent` and `NoTarget`. A connection that broke is `isBroken`, and answers `Closed` from then on.

**What is safe to run again.** `e.safeToRetry` is true where the statement certainly never reached the
server: `NotSent(failure)`, which a connection answers where the server had already ended its session
(restarting, say) or the connection had broken before the statement was sent, and a pool answers
where it could not make a connection; and `Closed`. Any other failure may have come after the server
had the statement, so a statement that changes data may have run. Nothing in the driver runs a
statement again by itself; a caller that wants to does it where `safeToRetry` allows:

```avin
// Runs `f` once more where its first run failed before its statement reached the server.
retried[T](f: () -> Result[T, PgError]) -> Result[T, PgError] = f() match
  Err(e) if e.safeToRetry -> f()
  other -> other

val added = retried(() -> pool.execute("insert into events values ($1)", 7))?
```

Inside a transaction, the end of the session loses the transaction, so the failure is not
`NotSent` even where the statement was not sent: the whole transaction is the thing to run again.

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

A pool outlives a server restart. A connection the server ended while it sat idle is let go before
it would be lent; while the server is down, each caller fails at once with `NotSent`, safe to run
again; once the server is back, new connections are made as callers ask.

### PgBouncer

Behind PgBouncer in transaction mode, each transaction may run on another server connection, so a
statement prepared under a name on one may not exist on the next. `pgbouncer=true` (`PgConfig`'s
`pgbouncer`) keeps to what that mode allows: no statement is prepared under a name and nothing is
cached; each statement is parsed unnamed, bound, described and run in one round trip, its rows sent
as text; batches send each statement the same way. `prepare` is refused with `Config`.

```avin
val bounced = PgPool.open("postgres://app:secret@localhost:6432/shop?pgbouncer=true", maxSize = 8)?
```

### A pool for a server

Every wait the driver makes parks only the lightweight thread making it: connecting, reading and
writing, the TLS handshake, and waiting for a pooled connection, so thousands of request threads can
share a pool of ten while every other thread keeps running. The pool's settings, all named
arguments of `PgPool.open` and `PgPool.of`:

| Setting | Default | What it does |
|---|---|---|
| `maxSize` | 10 | connections at most |
| `minIdle` | 0 | connections the health check keeps made, from the moment the pool opens |
| `acquireTimeout` | none | how long a caller waits for a connection before `PoolTimedOut`; `use(timeout, f)` sets one call's |
| `maxWaiting` | none | callers that may wait at once; one more fails at once with `PoolBusy` |
| `maxLifetime` | 1 hour | a connection older than this is closed instead of lent again |
| `idleTimeout` | 30 minutes | a connection idle longer than this is closed, keeping `minIdle` |
| `jitter` | none | lengthens each connection's two limits by its own random part of this, so connections made together are not replaced together |
| `pingAfter` | 1 second | a connection idle at least this long is pinged before it is lent |
| `pingTimeout` | 5 seconds | a ping slower than this lets the connection go, and another is found |
| `healthCheck` | 1 minute | how often the pool's own thread closes connections past their limits and makes up `minIdle`; `None` for no thread |

Waiting callers are served in the order they came. A server answers `PoolBusy` with 503 rather than
letting requests pile up, and exports `stats()`: `total`, `idle`, `inUse` and `waiting` now, and
since the pool opened `acquires` (`waited` of them after waiting, `waitTime` in all), `timeouts`,
`rejected`, and connections `created` and `destroyed`.

```avin
import dev.avinlang.pg.{PgPool, PoolBusy}
import avin.time.{millis, seconds}

val pool = PgPool.open(
  "postgres://app:secret@localhost/shop",
  maxSize = 10,
  minIdle = 2,
  acquireTimeout = Some(seconds(2)),
  maxWaiting = Some(500),
  maxLifetime = Some(seconds(1800)),
  jitter = Some(seconds(120))
)?
val status = pool.use(c -> c.queryValue[long]("select count(*) from orders")) match
  Ok(_) -> 200
  Err(PoolBusy) -> 503
  Err(_) -> 500
val busy = pool.stats()
println(s"${busy.inUse} in use, ${busy.waiting} waiting, ${busy.acquires} served")
pool.close()
```

## Batches

A `Batch` queues statements, and `sendBatch` sends them all at once rather than waiting for each
answer before sending the next; the results come back in the order the statements were queued, read
one by one as each statement's kind asks. On a local server a thousand inserts as one batch took 2 ms,
against 32 ms one at a time.

```avin
import dev.avinlang.pg.Batch

db.execute("create temporary table users (id int, name text)")?
val batch = Batch()
  .queue("insert into users values ($1, $2)", 1, "ada")
  .queue("insert into users values ($1, $2)", 2, "grace")
  .queue("select id, name from users order by id")
val r = db.sendBatch(batch)?.reader()
val inserted = r.execute()? + r.execute()?   // 2
val users = r.queryAs[User]()?               // [User(1, "ada"), User(2, "grace")]
```

A batch runs as one transaction: where a statement fails, its result is its error, those after it
are not run and answer `Skipped`, and nothing the batch did is kept. `sendBatch(batch, Independent)`
runs each statement as a transaction of its own instead, so a failure is that statement's alone.
Inside `transaction(f)` a batch is part of the transaction. A batch is plain data, so it can be made
on one thread and sent on another; `PgPool.sendBatch` sends one on a pooled connection.

The statements are prepared through the statement cache, those not yet prepared all together in one
more round trip. One the server cannot prepare yet, because it names a table an earlier statement of
the batch creates, is sent unprepared and runs in its place. A batch of any size is sent a window of
32 KiB at a time, so a batch of thousands of statements with large answers never leaves both ends
waiting to write. A batch whose thread is cancelled is cancelled as a single statement is.

## Cancellation

A statement whose thread is cancelled, by `withTimeout` or a scope, is cancelled on the server too:
the client sends a CancelRequest on a connection of its own, then reads what the server still sends
until the connection is ready again, so it can be used on. Where that fails the connection is broken.

```avin
import avin.threads.withTimeout
import avin.time.seconds

val r = withTimeout(seconds(2), _ -> db.query("select pg_sleep(60)"))   // None: cancelled
```

## Tracing

Hooks on the configuration watch what its connections do, for a server's logs, metrics and traces:
`queryTracer` each statement run, `prepareTracer` each statement prepared, `connectTracer` each
connection made (with its authentication method and whether it is encrypted), `batchTracer` each
batch, and `poolTracer` each connection a pool lends (with the wait) and takes back (with how long
it was held, and whether it was let go). A tracer is told an operation starts and answers a span; the
span is told how it ended: its time, the rows it returned or touched, its command tag, its error and
SQLSTATE, the server process, and whether its thread was cancelled. Whatever the tracer wants to
carry from the start to the end, it keeps in the span it makes.

A tracer sees how many parameters a statement binds, never their values, unless `traceParameters`
is set. A hook runs on the operation's thread, outside every lock of the connection and the pool; an
unset hook costs nothing beyond a test of its option. Hooks answer nothing, so they cannot fail the
statement they watch.

```avin
import avin.threads.Atomic
import avin.time.millis
import dev.avinlang.pg.{PgConfig, PgPool, QueryEnd, QuerySpan, QueryStart, QueryTracer}

// Numbers each statement, and logs its start and its end under that number.
class Numbered(private val log: @sendable (string) -> unit): Sendable
  val next = Atomic(long(0))

data NumberedSpan(n: long, log: @sendable (string) -> unit)

impl QueryTracer for Numbered
  queryStart(e: QueryStart) -> QuerySpan
    val n = next.add(1)
    log(s"#$n on backend ${e.pid}: ${e.sql}")
    NumberedSpan(n, log)

impl QuerySpan for NumberedSpan
  queryEnd(e: QueryEnd) = log(s"#$n: ${e.rows} rows, ${e.code.getOrElse("ok")}")

val config = PgConfig.parse("postgres://app:secret@localhost/shop")?
val db = PgPool.of(config with {queryTracer = Some(Numbered(line -> println(line)))}, maxSize = 8)
```

`SlowQueryLog(threshold, sink)` is a query tracer that writes a line for each statement that takes
`threshold` or longer, its parameters' values never among it; `sink` defaults to standard error.

```avin
import dev.avinlang.pg.SlowQueryLog

val logged = config with {queryTracer = Some(SlowQueryLog(millis(250)))}
// slow query: 1.2s on backend 4711, 3 rows: select … from orders where …
```

A batch tracer is told the batch starts, then, once the batch has been read, each statement's
outcome in order (a statement an atomic batch skipped answers `Skipped`), then the end, which carries
the first statement's failure. A batch whose thread is cancelled ends with `cancelled` set and no
statements told. A pooled batch is traced by its connection's batch tracer, inside the pool's lend.

```avin
import avin.threads.Mutex
import dev.avinlang.pg.{BatchEnd, BatchQuery, BatchSpan, BatchStart, BatchTracer}

// Logs each batch as one line: its size, and the statements that failed.
data BatchLine(log: @sendable (string) -> unit, failed: Mutex[Buffer[string]] = Mutex(Buffer[string]()))

impl BatchTracer for BatchLine
  batchStart(e: BatchStart) -> BatchSpan = BatchLine(log)

impl BatchSpan for BatchLine
  batchQuery(e: BatchQuery) = if e.error.isDefined then failed.with(b -> b.addOne(e.sql))
  batchEnd(e: BatchEnd) = log(s"batch of ${e.size}, failed: ${failed.with(b -> b.toVector)}")

val traced = config with {batchTracer = Some(BatchLine(line -> println(line)))}
// batch of 3, failed: [select 1 / 0, select 3]
```

One hook holds one tracer; `QueryTracers`, `PrepareTracers`, `ConnectTracers`, `BatchTracers` and
`PoolTracers` make several act as one, each told of every event in the order given, through a span of
its own. So the slow-query log runs beside a program's own tracer:

```avin
import dev.avinlang.pg.QueryTracers

val both = config with {queryTracer = Some(QueryTracers([SlowQueryLog(millis(250)), Numbered(line -> println(line))]))}
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

The tests of several servers and of a server restart need a second server of their own, which they
make read-only by default and stop and start:

```zsh
PG_TEST_PORT=55433 zsh scripts/test-db.zsh start .pg-test-2
```

with `PG_TEST_URL2` set to the URL it prints and `PG_TEST_DIR2` to its directory. Without them those
tests say so and pass.
