#!/usr/bin/env bash

# based on https://betterdev.blog/minimal-safe-bash-script-template/
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-p] [-s] [-i]
Run Firefox and sync bookmarks outside of Firefox
Available options:
-h, --help            Print this help and exit
-p, --places-file     Location of the places.sqlite file, somewhere in ~/.mozilla/firefox/*.default-release/places.sqlite
-s, --sync-file       Location of the sync file, default is ~/Config/bookmarks.sql
-i, --init            Initial import, does not delete the current bookmarks

EOF
  exit
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  PLACES_FILE=~/.mozilla/firefox/*.default-release/places.sqlite
  SYNC_FILE=~/Config/bookmarks.sql
  NO_INIT=true

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    --no-color) NO_COLOR=1 ;;
    -p | --places-file)
      PLACES_FILE="${2-}"
      shift
      ;;
    -s | --sync-file)
      SYNC_FILE="${2-}"
      shift
      ;;
    -i | --init) NO_INIT=false ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")
  return 0
}

# import the bookmarks from firefox via sqlite3
import-bookmarks() {
  # first delete all existing user-bookmarks, otherwise we can never delete anything
  if $NO_INIT; then
    sqlite3 $PLACES_FILE <<EOF
                WITH RECURSIVE generation AS (
                    SELECT id, parent, 0 AS generation_number
                    FROM moz_bookmarks
                    WHERE id = 3
                UNION ALL
                    SELECT child.id, child.parent, generation_number+1 AS generation_number
                    FROM moz_bookmarks child
                    JOIN generation g ON g.id = child.parent
                )

                DELETE FROM moz_bookmarks
                WHERE id IN (SELECT id FROM generation WHERE generation_number > 0)
EOF
  fi
  sqlite3 $PLACES_FILE ".read $SYNC_FILE"
}

# export the bookmarks from firefox via sqlite3
export-bookmarks() {

  # this is a recursive SQL, id=3 means this is the toolbar, where bookmarks from users are shown
  # https://learnsql.com/blog/query-parent-child-tree/
  IDS=$(
    sqlite3 $PLACES_FILE <<EOF
              WITH RECURSIVE generation AS (
                  SELECT id, fk, title, parent, position,
                      0 AS generation_number
                  FROM moz_bookmarks
                  WHERE id = 3
              UNION ALL
                  SELECT child.id, child.fk, child.title, child.parent, child.position, generation_number+1 AS generation_number
                  FROM moz_bookmarks child
                  JOIN generation g
                    ON g.id = child.parent
              )

              SELECT id, fk
              FROM generation
              WHERE generation_number > 0;
EOF
  )

  # this will contain the strings to search for having only the user bookmarks
  GREP=""
  # the resulting SQL file contains delete/insert, which will
  DELBID=""
  DELPID=""

  # loop over all the bookmarks that came from the user
  for ID in $IDS; do
    BID=${ID%%|*}
    PID=${ID##*|}

    # we need this, as syncChangeCounter can be differnt than 0, resulting in a different file even
    # though nothing changed. So change it to 0. Attention, this may break the sync feature from firefox
    sqlite3 $PLACES_FILE "UPDATE moz_bookmarks set syncChangeCounter=0 where id=${BID}"

    GREP="${GREP}INSERT INTO moz_bookmarks VALUES(${BID},\|"
    DELBID="${DELBID}id=$BID OR "

    if [ -n "$PID" ]; then
      # potential SQL injection if ID can be set, but we trust firefox, so it should be fine
      # if the bookmark did not change, we don't want the file to look different.
      # Attention, this may break the sync feature from firefox
      sqlite3 $PLACES_FILE "UPDATE moz_places set visit_count=0, frecency=100, last_visit_date=0 where id=${PID}"
      GREP="${GREP}INSERT INTO moz_places VALUES(${PID},\|"
      DELPID="${DELPID}id=$PID OR "
    fi
  done

  TMP="$(mktemp).sql"

  # first, store delete queries for all the user bookmarks
  if [ -n "$DELBID" ]; then
    echo "DELETE FROM moz_bookmarks WHERE ${DELBID::-4};" > "$TMP"
  fi
  if [ -n "$DELPID" ]; then
    echo "DELETE FROM moz_places WHERE ${DELPID::-4};" >> "$TMP"
  fi

  # now, dump the places and bookmarks table. The places contains lots of other data as well
  DUMP=$(sqlite3 $PLACES_FILE ".dump moz_places moz_bookmarks")
  # we want only the user bookmarks, we append those inserts right after the deletes
  echo "${DUMP}" | grep "${GREP::-2}" >> "$TMP"

  #we have a conflict, merge. Append the SQL commands, that means, entries are merged if the id is different
  #otherwise, the one from the SQL file wins. Since we have no tombstones you may see removed bookmarks
  #appearing again (I can live with that)
  if [ "$HASH_AFTER" != "$HASH_BEFORE" ]; then
    cat $SYNC_FILE >> "$TMP"
  fi

  #only move to the sync file if the file is changed. That means if its the same
  #(content wise), the file will not be touched
  if ! cmp -s "$TMP" $SYNC_FILE; then
    mv "$TMP" $SYNC_FILE
  fi
}

parse_params "$@"
setup_colors

# initialize variables
if [ -f $SYNC_FILE ]; then
  HASH_BEFORE=$(sha256sum "$SYNC_FILE")
fi
# if we already have an open instance, do not try to import bookmarks, so only the first instance will import
if sqlite3 $PLACES_FILE "BEGIN IMMEDIATE" >> /dev/null 2>&1; then
  import-bookmarks
fi

if [ -z ${args+x} ]; then
  firefox
else
  firefox "${args}"
fi

if [ -f $SYNC_FILE ]; then
  HASH_AFTER=$(sha256sum "$SYNC_FILE")
fi
# if we already have an open instance, do not try to export bookmarks, so only the last instance will export
if sqlite3 $PLACES_FILE "BEGIN IMMEDIATE" >> /dev/null 2>&1; then
  export-bookmarks
fi
