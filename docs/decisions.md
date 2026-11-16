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
