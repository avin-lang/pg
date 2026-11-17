# Design decisions

Each entry was settled on the user's delegation 2026-11-15. Entries marked **Review with the user**
are the debatable ones.

## Rows hold decoded values

A row is `Row(columns, values: Vector[PgValue])`, every value decoded when the row arrives, rather
than raw bytes decoded on `get`. A row is then plain sendable data, so a pooled connection's body can
give rows back, and reading a column twice costs nothing. `get[T: FromPg]` reads a `PgValue` as `T`;
`FromPg` has one static, `fromPg(PgValue) -> Option[Self]`, and NULL is the value `PgNull`, so
`Option[T]` needs no second hook. Alternatives weighed: raw bytes with a decode per `get` (rows not
sendable without copying the format and type of every column), and a per-type decoder trait over
bytes (two hooks, binary and text, for every type).

## Parameters are `ToPg` trait objects; `ToPg` is `Sendable`

`query(sql, params: ToPg*)` takes any mix of values: `query("…", 1, "x", Some(3))`. `ToPg` gives a
value (`toPg -> PgValue`) and its type's OID (`pgOid`). It extends `Sendable`, so a statement's
parameters can be handed to a pooled connection's thread as they are. `Typed(oid, value)` binds a
value with an OID of the program's choosing.

## `string` is sent with OID 0

A `string` parameter leaves its type to the server, which infers it from the statement, so a string
can be given for a parameter of any type the server reads from text (`"2020-01-02"` for a date
column). A vector of strings, or of nothing but `None`, does the same for an array. The cost is that
`select $1` with a string is `text` only because the server falls back to it.

## Binary where the client decodes it, text otherwise

Results come in binary for bool, the integers, floats, the text types, bytea, uuid, date, timestamp,
timestamptz, json/jsonb and arrays of those, chosen per column from the cached statement's
description; numeric and time come in text. The simple protocol is all text, and every type reads
from either. Parameters go in binary for the same types, text for the rest.

## Infinite dates and timestamps are the types' `Max` and `Min`

`infinity` and `-infinity` of `date`, `timestamp` and `timestamptz` read as `Date.Max`/`Date.Min`
(and the `DateTime` and `Instant` ones), and those values are sent as infinity. A program comparing
dates gets the ordering it expects. Alternative: a separate `PgInfinity` variant every reader would
have to match.

## Numeric `NaN`/`Infinity` and the time `24:00:00` arrive as `PgOther`

No `BigDecimal` holds NaN or an infinity, and no `Time` holds 24:00:00, so these values come as
`PgOther(oid, text)`: readable as a `PgValue` or its text, and a `BadColumn` error when read as
`BigDecimal` or `Time`. Alternative: map 24:00:00 to the next day's midnight, which would lose the
distinction PostgreSQL keeps.

## JSON is sent as `jsonb`; `Typed(114, …)` keeps `json`

A `Json` parameter is sent as `jsonb`, PostgreSQL's preferred form. A program that wants `json`
semantics (key order and duplicates kept) binds `Typed(114, PgJson(doc))`, which is sent as `json`
text. **Review with the user**: `json` as the default would surprise nobody reading a `json` column,
but most schemas use `jsonb`.

## One `PgError` data type, wrapping `IoError` as `Io`

Every failure is a `PgError`: `Server(Diagnostic)` with every field of an ErrorResponse, `Io(IoError)`,
`Tls(TlsError)`, `TlsRefused`, `Auth`, `Protocol`, `BadColumn`, `Config`, `RolledBack`, `Closed`,
`PoolTimedOut`, `PoolClosed`. One type lets `?` cross every layer, and lets `PgPool.use` flatten the
pool's `PoolError` into the same type its body answers. The first brief said connection errors would
be `IoError`; they are `Io(IoError)` inside `PgError`, with `cause` giving the `IoError`.
**Review with the user.**

## `BadColumn(column, reason)`

A column that cannot be read as the type asked for, is absent, or is NULL where the type has none, is
`BadColumn` naming the column (`#2` for an index out of range) and saying why. It is a program error
rather than the server's, so it is not a `Server` error, and it names the column so a mismatch
between a row type and a query is found from the message.

## TLS always verifies; `require` = `verify-full`; `verify-ca` and `allow` are refused

avin's TLS client always checks the certificate against the trusted authorities and the host name,
and has no encrypt-only mode. So `sslmode=require` verifies, as `verify-full` does, rather than
libpq's encrypt-without-verifying. `verify-ca` (certificate without host name) and `allow` (plain
first, TLS if refused) are refused as unknown modes rather than silently strengthened or weakened.
**Review with the user**: a server with a self-signed certificate needs `sslrootcert`, where libpq's
`require` would connect without it.

## `prefer` falls back to a fresh plain connection

Under `sslmode=prefer` (the default, as in libpq), a server that answers the TLS request with `N`
gets the startup on the same TCP connection; one whose certificate does not verify is abandoned and a
new plain connection made. libpq's `prefer` would have connected encrypted without verifying; this
client prefers an honest plain connection to an unverified encrypted one. **Review with the user**:
a failed verification falling back to plain text may hide a misconfigured or impersonated server.

## SCRAM-SHA-256 with SASLprep, and the server must prove itself

The password is prepared with `saslPrep` (RFC 4013) before it is salted; a password SASLprep refuses
is used as it is, as the server does when it stores one. A server that sends AuthenticationOk after
SCRAM began without a valid SASLFinal signature is refused, so a server that does not know the
password cannot pretend to. Channel binding (`SCRAM-SHA-256-PLUS`) is not offered.

## The statement cache

Statements run through `query`/`execute` are prepared once under a generated name and kept, keyed by
the SQL and the parameter OIDs, up to `statement_cache_size` (100), the least recently used closed
first. A cached statement the server refuses as stale (`0A000` "cached plan must not change result
type", or `26000`, the statement gone) is dropped and prepared again once, outside a transaction. Size 0 prepares every statement
unnamed.

## Transactions nest as savepoints; cancellation rolls back through `defer`

`transaction(f)` is `BEGIN` … `COMMIT`/`ROLLBACK`; inside another it is `SAVEPOINT`/`RELEASE` or
`ROLLBACK TO`. A body that answers `Ok` after a statement aborted the transaction gets `RolledBack`,
not a commit that the server would turn into a rollback. A `defer` rolls back when the thread is
cancelled, and a failed rollback marks the connection broken.

## CancelRequest over plain TCP, with libpq's race

A cancelled statement sends a CancelRequest on a new plain TCP connection (as libpq's `PQcancel`
does, even for a TLS session), then drains the main connection to ReadyForQuery within 30 seconds,
or marks it broken. The protocol's race is kept: a cancel that arrives after the statement finished
can cancel the next statement on the connection, as with every PostgreSQL client. The drain closes
most of the window, since the next statement is not sent until ReadyForQuery.

## The pool: `Pool.lease`, rolled back on return

`PgPool` wraps `avin.threads.Pool[Connection, PgError]` through `lease`, so a body can mark its
connection broken. A connection handed back broken or closed is let go; one handed back inside a
transaction is rolled back (and let go if that fails); `validate` lends only a connection that is
open, idle, and has nothing unread from the server, which catches one the server ended while it sat
idle. Ordinary use, one connection per request with a transaction inside, needs one pooled resource
at a time.

## The bounded queue, lifetimes, jitter and counters belong to `avin.threads.Pool`

Settled on the user's delegation 2026-11-15 (branch `pool-production`, in pg and in avin). The
pool's FIFO waiting, `maxWaiting` with its `QueueFull`, `maxLifetime`, `jitter` and the running
totals of `counters()` were added to avin's `Pool` rather than built in `PgPool`: only the pool's
lock knows the queue's length (a count kept outside overshoots by every caller racing past it),
when a resource was made, and which calls waited. Every pooled resource wants them, and pgx keeps
the same split, its generic `puddle` pool counting and `pgxpool` choosing the policy. `PgPool` keeps
what is PostgreSQL's: the ping, the health-check thread and the defaults. This pg branch needs the
avin release that carries them. **Review with the user**: it makes pg's branch depend on an avin
branch landing and releasing first.

## pgx's policy and defaults

Settled on the user's delegation 2026-11-15. `maxLifetime` 1 hour, `idleTimeout` 30 minutes,
`healthCheck` every minute and a ping for a connection idle at least 1 second are pgx's defaults,
long proven under Go's lightweight threads; `maxSize` stays 10, and `maxWaiting`, `jitter` and
`acquireTimeout` default to none, as pgx's do. Before this the pool had no lifetime and no idle
limit. **Review with the user**: a lifetime and an idle limit are now on by default.

`jitter` lengthens each connection's limits by its own random part of it, as pgx's
`MaxConnLifetimeJitter` does, so a lifetime is a true minimum; one `jitter` serves both limits.

## The health check is a thread of the pool's own

Settled on the user's delegation 2026-11-15. Every `healthCheck` a lightweight thread calls the
pool's `evictIdle` (connections past `maxLifetime` or `idleTimeout`) and `warm` (up to `minIdle`),
and it warms once as soon as the pool opens, as pgx creates `MinConns` in the background. It waits
on a channel with a timeout, so `close` ends it at once: `close` closes the channel, joins the
thread, then closes the pool. A connection it cannot make is tried again at the next check; nobody
waits on its failure. `healthCheck = None` runs no thread, for a pool that wants none (avin's own
`Pool` has none, by its own decision). It does not ping idle connections, as pgx's does not:
lending does.

## Ping before lending a connection idle at least `pingAfter`

Settled on the user's delegation 2026-11-15. A connection lent after sitting idle is first checked
cheaply (open, not broken, not in a transaction, nothing unread), and where it was idle at least
`pingAfter` also pinged: an empty statement, a round trip answered by EmptyQueryResponse, waiting at
most `pingTimeout`; one that fails or is slower is broken, let go, and another found. "Idle" is
`Connection.idleFor`, the time since the server was last heard from, which the connection keeps
itself, so the pool needs no hook. pgx pings with `-- ping` when a connection has been idle over a
second; the empty statement is the cheapest round trip the protocol has. Alternatives weighed:
pinging every lend (a round trip per request); never pinging (a connection a firewall dropped
silently is lent and fails the request); `validate` given the idle time by `Pool` (a change to
`Pool`'s `validate` type for what the connection can say itself).

## `PoolBusy`, and `PgPoolStats`

Settled on the user's delegation 2026-11-15. `QueueFull` becomes `PoolBusy`, a case of its own so a
server can answer 503 rather than 500 or a timeout's 504. `stats()` now answers `PgPoolStats`, the
snapshot (`total`, `idle`, `inUse`, `waiting`) and the totals (`acquires`, `waited`, `waitTime`,
`timeouts`, `rejected`, `created`, `destroyed`) in one value with a server's names, read from the
pool's `stats()` and `counters()` a moment apart. It replaces the `PoolStats` that `stats()` answered
before, whose names were the generic pool's.

## Host lookup holds its worker

Found 2026-11-15, reported to avin, not worked around: `TcpStream.connect` resolves the host with
`sysl.net.resolve`, a `getaddrinfo` bound without `blocking`, so while the resolver waits the worker
is held and no other worker is started in its place, and a collection waits for it. Every other wait
the driver makes parks the lightweight thread on the runtime's poller or its locks. A numeric host
(`127.0.0.1`) or one in the hosts file answers at once, so this shows only with a slow resolver.

## Tracing: a tracer answers a span, and the span carries the context

pgx's tracers take a `context.Context` at the start of an operation and answer one, which is then
handed to the end. avin has no context value, so the same carrying is done with a value of the
tracer's own: `queryStart(QueryStart) -> QuerySpan`, and the span's `queryEnd(QueryEnd)`. A trace id,
a counter, a parent span: the tracer keeps it in the span it makes, typed as it likes, and no
downcast is needed. A tracer with nothing per operation answers one shared span, often itself (the
slow-query log does). The same shape serves prepare, connect, batch and pool acquire; the pool's span
also takes `released`, so one span covers a connection from the wait to its return. Alternatives
weighed: a generic tracer trait with the context as a type parameter (a configuration field cannot
hold a tracer of an unknown context type), and an opaque `Sendable` token handed from start to end
(the tracer would have to cast it back). **Review with the user**: a value the *caller* holds, such as
an HTTP request's id, has no way into `queryStart`, since avin has no ambient context and the query
methods take none; a middleware today makes a tracer per request, or puts the id where its tracer
can read it. A per-call context argument, or an ambient one in avin, would settle it.

## One field per hook on `PgConfig`; the pool's tracer is on the configuration too

`PgConfig` has `queryTracer`, `prepareTracer`, `connectTracer`, `batchTracer` and `poolTracer`, each an
`Option` of its trait. pgx has one `Tracer` field and finds the other hooks by asserting which
interfaces it implements, which avin does not offer; separate fields say plainly what is traced. A
pool made with a configuration traces with its `poolTracer`, as pgxpool reads its tracer from the
connection configuration, so one value configures everything. Every hook trait and span trait is
`Sendable`: a configuration is shared by a pool's threads, and the pool's span is used inside the
isolated body that holds the connection.

## A hook costs one option test when unset, and runs outside every lock

Each hook is called from one spot: `run`, `runStatement` and `simpleQuery` for statements, `parse`
for preparing, `Connection.connect` for connecting, `PgPool.leased` for the pool. With the hook
`None` the spot is a `match` that goes straight to the untraced code, so nothing is allocated and no
clock is read. A connection is used by one thread and holds no lock; the pool's lock is let go
before the body runs and taken only after it returns, so a hook may use the pool (its statistics,
another of its connections) without waiting on itself. A hook is told the backend's pid, never the
connection, so it cannot start a statement on the connection in the middle of one.

## Statement and pool ends are reported from a `defer`, so a cancelled thread's end arrives

The end of a statement, a prepare, a connect and a pool acquire is told from a `defer` where the
operation did not return, with `cancelled` true and no error, rows or tag. A pool use cancelled while
it waits is told `acquireEnd` as cancelled; one cancelled after it was lent is told `released` as
usual. The statements a transaction and a pool run for themselves (`BEGIN`, `COMMIT`, savepoints,
the `ROLLBACK` on return) are traced as statements, as pgx traces them.

## Hooks answer nothing; a trap in one stops the program

A hook's methods return `unit`, so there is no error for the client to handle and nothing a hook does
can fail the operation or leave the connection in a state of its own making. A trap inside a hook
stops the program, as a trap does everywhere in avin (threads.md: a failure is a value, a trap stops
the program); pgx's hooks cannot fail either, and a panic in one ends the program unless the caller
recovers it.
Catching a trap is not something avin offers, so this is the language's rule rather than this
client's choice.

## Parameter values are hidden unless `traceParameters` is set

`QueryStart.params` is empty by default and `paramCount` always set, so a tracer that logs what it is
told does not log a password or a token bound as a parameter. `traceParameters = true` hands the
values over, for a development log. The slow-query log never writes them either way.

## The slow-query log is a `QueryTracer` with a threshold and a line sink

`SlowQueryLog(threshold, sink = eprintln)` writes one line for each statement whose time is at or
past the threshold, failed and cancelled ones included: `slow query: <time> on backend <pid>, <rows
| failed SQLSTATE | cancelled>: <sql>`. A sink of strings fits any logger; to run it beside a
program's own tracer, the two are combined with `QueryTracers` (below).

## Several tracers as one: `QueryTracers(Vector[QueryTracer])`, one combinator per hook

A hook field holds one tracer, so, after pgx's `multitracer`, `QueryTracers`, `PrepareTracers`,
`ConnectTracers`, `BatchTracers` and `PoolTracers` each wrap a `Vector` of tracers of their kind and
are one themselves. A start asks every tracer, in the vector's order, for its span; the combined span
holds those spans and tells each the end (and, for batches, each statement; for the pool, the
release) in the same order. Each tracer thus carries its own context exactly as it would alone. An
empty vector watches nothing; the hook is still set, so it costs the option test plus an empty loop.
Alternatives weighed: one `Tracers` value implementing all five traits from five vectors (a single
name, but every program would build vectors for hooks it does not use, and a tracer of one kind
could not be passed); a variadic `QueryTracers.of(a, b)` (the vector literal is as short); hook
fields holding a `Vector` themselves (every unset hook would cost a length test instead of an option
test, and the common one-tracer case would need brackets). Ends are told in start order rather than
reverse (pgx's `multitracer` does the same); a program whose tracers nest, such as an outer timing
span around an inner one, would want reverse. **Review with the user**: the order of ends.

## Batches are traced around the whole send, the statements told once it has been read

`sendBatch` on a connection whose configuration has a `batchTracer` runs between `batchStart` and
`batchEnd`, in either mode, and a pool's `sendBatch` lends through the pool's traced lease, so the
pool tracer sees the lend and return around the batch's own span. A cached statement found stale
and the batch rerun is one traced batch. The batch is read eagerly, so the statements' outcomes are
told in order after the last answer has been read, each with its text, parameter count, rows, tag
and error (`Skipped` for those an atomic batch did not run), and before `batchEnd`. `batchEnd`
carries the batch's own error where it could not be run at all (closed, broken), else the first
statement's failure other than `Skipped`, which is what `BatchResults.failure` answers, as pgx's
batch end carries the first error read. The end is told from a `defer`, as `tracedQuery` does, so a
batch whose thread is cancelled ends with `cancelled` and no statements told. An empty batch is
traced too (size 0, nothing told): every call is observed, and it costs nothing on the wire. The
statements a batch prepares for itself are not told to the `prepareTracer`; they are part of the
batch's one span. Alternatives weighed: telling each statement as its answer is read (closer to
pgx's lazy reader, but the statements a refused send never ran would then be told out of order or
not at all, and the eager reader gains nothing from it); telling the statements that did complete
before a cancellation (they are not answers the caller will ever see). **Review with the user**:
whether the batch's own preparing should be told to the prepare tracer.

## Batches: an immutable `Batch`, read eagerly into `BatchResults`

`Batch` is plain data: `queue` answers a new batch with one more statement, so a batch is sendable
and can be built on one thread and run on a pooled connection's. `sendBatch` reads every answer
before it returns, into `BatchResults` (plain data, one `Result[QueryResult, PgError]` per
statement), and `BatchResults.reader()` reads them in order as each statement's kind asks
(`execute`, `query`, `queryOne`, `queryAs`, `queryValue`), much as pgx's `BatchResults` does. Reading
eagerly means the connection is never left in the middle of a batch while the program reads, and a
pooled body can give the results back. Alternatives weighed: a mutable builder (`b.queue(…)` with no
reassignment, as in pgx), which would not be sendable; and pgx's lazy reader over the connection,
which keeps every answer's rows out of memory at once but ties the connection to the reader until it
is closed. **Review with the user**: whether a lazy, streaming reader is wanted for batches whose
answers are too big to hold.

## A batch is one implicit transaction by default; `Independent` syncs each statement

`Atomic` (the default) sends every statement's Bind and Execute with a single Sync at the end, as
pgx does: the batch is one implicit transaction, a failure fails that statement and the server skips
the rest (`Skipped`), and what ran before it is rolled back. `Independent` ends each statement with a
Sync of its own, so each outside a transaction is committed or fails alone. Inside
`transaction(f)` both join the open transaction, and a failure leaves it failed (`25P02` for the
statements after it in an independent batch). Alternatives weighed: offering only the atomic form
(pgx), or making independence the default (fewer surprises for a list of unrelated writes, but
weaker than what pgx users expect).

## Statements are prepared first, together; a refused one is sent unprepared

A batch prepares the statements the cache does not hold in one round trip before it runs (each Parse
and Describe with its own Sync, so a refusal is refused alone), because a parameter's binary
encoding depends on the type the server infers. A statement the server refuses to prepare, most
often one on a table an earlier statement of the batch creates, is not failed then: it is sent in
its place unprepared (Parse, Bind with text parameters, Describe of the portal, Execute) and its
rows are read as text, so a real error fails it where it stands and the rest of the batch follows
the protocol's rules. Inside a transaction the preparing is wrapped in `SAVEPOINT pg_batch` and
rolled back to, so a refused Parse does not fail the transaction (prepared statements outlive the
rollback). Parameters that do not fit a prepared statement (a `Config` error found before anything is
sent) fail an atomic batch before any of it runs, every other statement answering `Skipped`; an
independent batch fails only that statement. A batch of more distinct statements than the cache
holds keeps them all while it runs and trims the cache after; with no cache they are closed with the
next statement prepared. A cached statement made stale by DDL fails its statement; an atomic batch
outside a transaction, which kept nothing, is then run once more with the statement prepared afresh,
as a single statement is. Alternatives weighed: pgx's rule, where a statement that cannot be
prepared fails the whole batch (so a batch cannot create a table and use it); and preparing inline
in the same pipeline, which needs the parameter types before they are known. **Review with the
user**: the unprepared fallback is invisible except in its text encoding of parameters.

## Batches are sent a 32 KiB window at a time

The server stops reading while it cannot write, so a client that writes a whole large batch before
reading deadlocks once both directions' socket buffers fill. avin's streams belong to one thread at
a time and have no non-blocking write, so a writer thread and a reader thread cannot share one; the
batch instead sends a window of at most 32 KiB of statements (one at least), followed by a Flush
(the server buffers its answers otherwise), reads every answer to it, and only then sends the next.
The bytes written ahead of what is read stay well under the 128 KiB a socket buffers by default at
each end, so no write waits on a server that is itself waiting. It costs one round trip per window,
about a thousand small statements. Alternatives weighed: a writer/reader split on two lightweight
threads (needs a stream that can be read and written from two threads, which avin does not offer),
and a non-blocking write that reads when the socket is full (pgx's way; needs a writable-readiness
or partial-write primitive). **Review with the user**: whether `avin.net` should grow either, which
would let the whole batch be in flight at once.

## A cancelled batch: Sync, drain every ReadyForQuery owed; a cut write breaks the connection

A batch keeps count of the ReadyForQuery messages owed and whether messages are out since the last
Sync. A cancelled batch sends the CancelRequest, a Sync where one is missing, and reads until
nothing is owed, within the drain limit; an atomic batch then has kept nothing. An independent batch
keeps what its statements before the cancelled one committed, and the ones already sent after it
still run. A thread cancelled while a write is under way may have sent half a message, so the
connection is broken at once rather than drained to the limit; this holds for single statements
too.

## `connectTimeout` is one deadline per server, over the whole connection

Settled on the user's delegation 2026-11-16 (branch `resilience`). The timeout used to be set on the
socket once it was connected, so the TCP connect itself had no limit (75 s or more against an address
that drops packets), and each later wait had the whole timeout again, so a server answering a little
at a time could take any time. Now each server's attempt (name lookup, TCP, TLS, authentication, and
checking the kind of server) runs inside `withTimeout`, which cancels it wherever it is and closes
what it opened; the answer is `Io` with kind `TimedOut`. The socket timeout is still set too. A
duration of zero or less is none, as libpq reads `connect_timeout=0`. In a host list each server
gets the whole timeout afresh, as in libpq. Alternatives weighed: a deadline threaded through every
read (much more code in `connection.avin`), and a connect primitive with a timeout in `avin.net`
(covers TCP only). **Review with the user**: the default stays `None`, as in libpq and pgx, so a
connection waits as long as the network does; a server might prefer a default such as 10 s.

## A dead connection is found before the statement is sent: `NotSent` and `safeToRetry`

Settled on the user's delegation 2026-11-16 (branch `resilience`). When the server ends a session
(a restart sends FATAL `57P01`, then closes) the client finds out only when it next reads. So between
requests a connection first reads what the server has sent unasked, from its own buffer and from the
socket, never waiting: a notice or a parameter is dealt with as usual, while an error or the end of
the connection breaks it, and the statement is not sent. Outside a transaction that failure is
`NotSent(failure)`; inside one it is the failure itself, since the transaction is lost and the
statement alone is not the thing to run again. `PgError.safeToRetry` is true for `NotSent` and for
`Closed` only: pgx's `SafeToRetry` means the same, that nothing reached the server. A pool answers a
connection it could not make as `NotSent` where the server could not be reached (`Io`) or answered
that it is starting, stopping (class `57P`) or cannot take the connection (class `08`); a wrong
password and other refusals answer as they are. Nothing in the driver runs a statement again by
itself. The same check made `isHealthy` read the reader's buffer too: an end of session that arrived
in the same read as the last answer was buffered, and a pool would have lent that connection.
**Review with the user**: retry semantics. `PoolTimedOut` and `PoolBusy` are not counted as safe
although nothing ran, since running again into an overloaded pool is the wrong reflex; and the pool
does not retry even a `NotSent` statement on another connection, though it safely could, so a
caller sees every failure (pgx's pool does not retry either; `database/sql` does, once, on
`ErrBadConn`).

## Several servers: `hosts`, libpq's lists, and `targetSessionAttrs`

Settled on the user's delegation 2026-11-16 (branch `resilience`). `PgConfig.hosts: Vector[Host]`,
`Host(name, port = 5432)`, empty by default so `host` and `port` keep their meaning; `servers` is the
list either way, and parsing a list also sets `host` and `port` to its first. A URL lists
`host:port` entries (libpq's form); `PgConfig.parse` also reads libpq's keyword form, where `port`
lists one per host or gives one for all, since the brief named `host=a,b port=x,y`. Servers are
tried in order, each within `connectTimeout`; where none will do, the answer is the last server's
failure, as `TcpStream.connect` answers for a name with several addresses. The kind of server is
read from the `in_hot_standby` and `default_transaction_read_only` the server reports at startup
(version 14 and later), or asked with one query otherwise; `read-only` is a standby or read-only by
default, as libpq has it. `prefer-standby` keeps the first server that connects while it looks for a
standby, rather than libpq's second pass, which connects again. A server of the wrong kind is
`NoTarget(reason)`, a new variant, since `Config` and `Server` say something else. The tests stand a
server with `default_transaction_read_only` on in for a read-only server, and a scripted server
reporting `in_hot_standby` in for a standby, since a real standby needs replication set up.
**Review with the user**: the default is `any`, as libpq's; and the error is the last server's, where
libpq joins every server's into one message.

## `pgbouncer`: unnamed statements in one round trip, results as text

Settled on the user's delegation 2026-11-16 (branch `resilience`). PgBouncer in transaction mode may
give each transaction a different server connection, so a statement prepared under a name, or even
an unnamed one parsed in one round trip and bound in the next, may be gone. With `pgbouncer` (URL
`pgbouncer=true`, the name Prisma uses for the same switch) a statement is Parse (unnamed), Bind,
Describe, Execute and Sync in one write, parameters and rows as text, as pgx's `exec` mode does;
nothing is cached; a batch sends each statement that way; `prepare` is refused with `Config`. The
statement cache and `statementCacheSize = 0` stay as they were, since `0` still prepares in a round
trip of its own. Tested against the server itself, no `pgbouncer` binary being installed:
`pg_prepared_statements` stays empty, and a scripted server proves the one round trip. Alternatives
weighed: pgx's several query modes as one enum (more surface than the one case needs), and naming
the flag for what it does (`namedStatements = false`). **Review with the user**: the name, the
default (off), and refusing `prepare` rather than running a prepared statement unnamed each time.

## Found: a host lookup cannot be cut short

Found 2026-11-16, not worked around, and not reproduced (no slow resolver was at hand). Name
resolution is a blocking call in avin 0.0.30, and `withTimeout` answers only once everything it
cancelled has ended, so by its contract a lookup in progress holds the timeout until the resolver
answers. `connectTimeout` would then bound a slow resolver only after it answers. A numeric host or
one in the hosts file answers at once. A cancellable or time-limited lookup in `avin.net` would
close it.
## LISTEN/NOTIFY: a `Listener` with a connection and a thread of its own

Settled on the user's delegation 2026-11-16. A `Listener` owns a dedicated connection on a
lightweight thread of its own, which waits in one `select` on the connection (`Connection` is a
`Readiness`), on a command channel (`listen`, `unlisten`, `unlistenAll`, `channels`, `close`, each
answered on a reply channel, so any thread may call them), and, while an event is held back, on room
in the events channel. It delivers `ListenEvent`s: `Notified(Notification(channel, payload, pid))`,
`Dropped(count)`, `Disconnected(error)` and `Reconnected(attempts)`, in the order they happened.
`Listener.open` connects and LISTENs before answering, so a bad password or an unreachable server is
the caller's error. Channel names are quoted identifiers, `"` doubled, so they are used exactly as
written; an empty name or one holding a NUL is refused on this side with `Config` (the first is a
server syntax error, the second cannot be sent), which also means a channel remembered while
disconnected can never be refused on reconnecting. A name over the server's 63 bytes is truncated by
the server, as every identifier is. Alternatives weighed: pgx's shape alone,
`Conn.WaitForNotification(ctx)` on a connection the program drives (kept as
`Connection.waitForNotification`, but a program then writes the reconnect and the runtime LISTEN
itself), and a listener that shares a pooled connection (a pooled connection is reset and lent to
others, so its LISTENs would not survive).

## Notifications on an ordinary connection go to a hook; a wait answers those that arrive idle

Settled on the user's delegation 2026-11-16. `PgConfig.notifications: Option[@sendable
(Notification) -> unit]` is pgx's `OnNotification`: each notification a connection reads while it
runs a statement is handed to it, on that thread, and dropped without one, as before. It never
disturbs the statement. `Connection.waitForNotification(timeout)` reads while the connection is idle
and answers the first notification, `None` at the timeout, and the server's error where it ends the
connection (`57P01` when an administrator terminates it), which breaks the connection; a
notification it reads is answered and not also given to the hook. **Review with the user**: pgx's
`Conn` also keeps the notifications read during statements in an unbounded slice that
`WaitForNotification` drains first; here they go to the hook or are dropped, so memory stays bounded
on a connection that LISTENs and never waits, at the price that a program mixing statements and
waits on one connection must set the hook (or use a `Listener`, which does).

## A listener's back-pressure: a bounded queue that drops and counts

Settled on the user's delegation 2026-11-16. The events wait in a channel of `capacity` (default
1024). While it is full, further notifications are dropped and counted, in `listener.dropped` and in
a `Dropped(count)` event that takes their place in the order and is delivered as soon as there is
room, without waiting for another notification to carry it. Control events (`Disconnected`,
`Reconnected`) are never dropped: they wait in a small list in front of the queue, and a second gap
while the consumer has not yet been told of the first merges into it, so that list stays at a few
entries however often the connection drops. The notifications a LISTEN's own round trip reads are
kept up to `capacity` and go through the same path. **Review with the user**: the alternatives were
blocking the listener while the queue is full (the server then queues the notifications, up to its
8 GB `max_notify_queue_pages`, past which every NOTIFY in the database fails, so one slow consumer
would break every sender), and dropping the oldest instead of the newest (keeps the freshest, but
reorders what the consumer sees around the gap).

## A listener reconnects with a doubling backoff and reports the gap

Settled on the user's delegation 2026-11-16. Where the connection fails, the listener closes it,
delivers `Disconnected(error)`, tries again at once, then after `minBackoff` (100 ms) doubling to
`maxBackoff` (30 s), serving commands meanwhile: a `listen` or `unlisten` while disconnected is
remembered and answered `Ok`, and made on reconnecting. Once connected it LISTENs to every channel
again and delivers `Reconnected(attempts)`. The server keeps no notifications for a listener that is
not connected, so the two events bound what was lost. A LISTEN that breaks the connection counts as
done, the reconnection making it. No jitter: one listener per process is the usual shape. It retries
for ever, until closed.

## Delivery to an actor: asks with a window of unanswered events

Settled on the user's delegation 2026-11-16. Actor mailboxes are unbounded, so `Listener.toActor`
follows the actors chapter's rule for a producer that must not outrun its consumer: each event goes
as the message `make(event, ack)`, an ask, and the actor tells `ack` once it has handled it. At most
`window` (16) asks are unanswered; past that the forwarding thread waits, the listener's queue fills
and drops as `open`'s does. An ask unanswered for an hour counts as answered. The listener stops when
the actor ends (watched through `ended()`), and the forwarder stops waiting on an ended actor's asks.
**Review with the user**: the ack is a burden on the actor's code; the alternative, plain `tell`
with no bound, breaks the back-pressure requirement for any actor slower than its notifications.

## Notifications between requests, and the listener's connect, with the resilience work

Settled on the user's delegation 2026-11-16 (merging `listen-notify` onto `resilience`). The check
made before a statement is sent (a server-ended session is found, never waited for) reads what the
server sent unasked, and a notification is among the messages it may find: it goes to the
`notifications` hook, or is dropped without one, exactly as during a statement, and is never taken
for an unexpected message that breaks the connection. `waitForNotification` does not make that
check, since it would hand to the hook the very notifications the wait is there to answer; it reads
for itself and an error the server sent ends the connection as before. A `Listener` connects, and
reconnects, through `connect`, so each of its attempts has `connectTimeout` and walks `hosts` by
`targetSessionAttrs`, and a pgbouncer-mode configuration is used as it is. The listener's own hook
(not the configuration's) catches what the check reads while a LISTEN or UNLISTEN is sent, and
delivers it after the statement. `isHealthy`, which a pool asks before lending, reads what is
unasked the same way, so a notification that reached an idle pooled connection no longer makes it
unfit and be discarded; where it finds the server's error it breaks the connection and keeps the
failure, which the next request answers as `NotSent`, as if that request had found it.
