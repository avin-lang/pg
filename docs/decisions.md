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
