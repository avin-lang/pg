#!/bin/zsh
# A private PostgreSQL server for the package's tests, run as the current user from a directory of
# its own, on port 55432 with no Unix socket, so it touches no other server on the machine.
#
#   scripts/test-db.zsh start [dir]   makes the cluster on first use, then starts it
#   scripts/test-db.zsh stop [dir]    stops it
#   scripts/test-db.zsh env [dir]     prints the variables the tests read
#
# The directory defaults to $PG_TEST_DIR, or .pg-test in the package. `start` prints the variables
# to export: PG_TEST_URL (the superuser `pgtest`, password `pgtest`, over SCRAM-SHA-256) and
# PG_TEST_CA (the authority that signed the server's certificate, for the TLS tests). The tests skip
# with a message saying so when PG_TEST_URL is unset.
#
# Roles made for the authentication tests, each password its own name:
#   md5user    stored as MD5 and asked for with `md5`
#   plainuser  asked for in clear text, `password`
#   trustuser  let in with no password, `trust`
#   scramuser  an ordinary role over SCRAM-SHA-256

set -e
setopt NO_NOMATCH

action=${1:-start}
root=${2:-${PG_TEST_DIR:-${0:A:h:h}/.pg-test}}
port=55432
data=$root/data
bin=/opt/homebrew/bin

case $action in
  start)
    mkdir -p $root
    if [[ ! -f $data/PG_VERSION ]]; then
      print -r -- pgtest > $root/pwfile
      $bin/initdb -D $data -U pgtest --auth=scram-sha-256 --pwfile=$root/pwfile -E UTF8 --locale=C > $root/initdb.log
      cd $root
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=pg test CA" \
        -keyout ca.key -out ca.pem -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2> /dev/null
      openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout server.key -out server.csr 2> /dev/null
      print -r -- "subjectAltName=DNS:localhost,IP:127.0.0.1" > san.ext
      openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 \
        -extfile san.ext -out server.pem 2> /dev/null
      openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=another CA" \
        -keyout other.key -out other.pem 2> /dev/null
      chmod 600 server.key
      cat >> $data/postgresql.conf <<EOF
port = $port
listen_addresses = '127.0.0.1'
unix_socket_directories = ''
ssl = on
ssl_cert_file = '$root/server.pem'
ssl_key_file = '$root/server.key'
max_connections = 60
EOF
      cat > $data/pg_hba.conf <<EOF
host all trustuser 127.0.0.1/32 trust
host all md5user 127.0.0.1/32 md5
host all plainuser 127.0.0.1/32 password
host all all 127.0.0.1/32 scram-sha-256
EOF
      $bin/pg_ctl -D $data -l $root/server.log -w start > /dev/null
      PGPASSWORD=pgtest $bin/psql -X -q -h 127.0.0.1 -p $port -U pgtest -d postgres -v ON_ERROR_STOP=1 <<EOF
set password_encryption = 'md5';
create role md5user login password 'md5user';
reset password_encryption;
create role plainuser login password 'plainuser';
create role trustuser login;
create role scramuser login password 'scramuser';
EOF
    elif ! $bin/pg_ctl -D $data status > /dev/null; then
      $bin/pg_ctl -D $data -l $root/server.log -w start > /dev/null
    fi
    print -r -- "export PG_TEST_URL=postgres://pgtest:pgtest@127.0.0.1:$port/postgres"
    print -r -- "export PG_TEST_CA=$root/ca.pem"
    ;;
  stop)
    if [[ -f $data/PG_VERSION ]] && $bin/pg_ctl -D $data status > /dev/null; then
      $bin/pg_ctl -D $data -w stop > /dev/null
    fi
    ;;
  env)
    print -r -- "export PG_TEST_URL=postgres://pgtest:pgtest@127.0.0.1:$port/postgres"
    print -r -- "export PG_TEST_CA=$root/ca.pem"
    ;;
  *)
    print -u2 "usage: scripts/test-db.zsh start|stop|env [dir]"
    exit 2
    ;;
esac
