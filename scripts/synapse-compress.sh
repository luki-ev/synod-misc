#!/bin/bash

# This script is everything that is presented on https://levans.fr/shrink-synapse-database.html put into one bash script
# and adapted to monit init system at the end

API_TOKEN=<ADD HERE>
HOST=http://localhost:8008
ROOMLIMIT=10000
PSQL_USER=synapse
PSQL_PASSWORD=password
PSQL_HOST=localhost
PSQL_DB=synapse

ROOMLIST=$(curl --silent --fail --header "Authorization: Bearer $API_TOKEN" $HOST/_synapse/admin/v1/rooms?limit=$ROOMLIMIT)

ROOMS_WITHOUT_LOCAL_USERS=$(echo $ROOMLIST | jq --raw-output '.rooms[] | select(.joined_local_members == 0) | .room_id')

for room in $ROOMS_WITHOUT_LOCAL_USERS; do
	curl --silent --fail --header "Authorization: Bearer $API_TOKEN" --header "Content-Type: application/json" -XDELETE -d "{}" --output /dev/null "$HOST/_synapse/admin/v1/rooms/$room"
    # workaround https://github.com/matrix-org/rust-synapse-compress-state/issues/78
    psql -w -U $PSQL_USER -h $PSQL_HOST --quiet -t -c "DELETE FROM state_compressor_progress WHERE room_id='$room';" $PSQL_DB
    psql -w -U $PSQL_USER -h $PSQL_HOST --quiet -t -c "DELETE FROM state_compressor_state WHERE room_id='$room';" $PSQL_DB
done

TIMESTAMPMS30DAYS=$(date --date="-30 days" +%s000)
curl --silent --fail --header "Authorization: Bearer $API_TOKEN" --header "Content-Type: application/json" -d "{}" --output /dev/null "$HOST/_synapse/admin/v1/purge_media_cache?before_ts=$TIMESTAMPMS30DAYS"

# manual state compression disabled, it uses too much RAM and gets OOM killed
#ROOMS_TO_COMPRESS=$(psql -w -U $PSQL_USER -h $PSQL_HOST --quiet -t -c 'SELECT room_id  FROM state_groups_state GROUP BY room_id HAVING count(*) > 100000;' $PSQL_DB)
#for room in $ROOMS_TO_COMPRESS; do
#	$HOME/bin/synapse-compress-state -t -o /tmp/state-compressor.sql -p "host=$PSQL_HOST user=$PSQL_USER password=$PSQL_PASSWORD dbname=$PSQL_DB" -r "$room" >/dev/null 2>&1
#    psql -w -U $PSQL_USER -h $PSQL_HOST --quiet $PSQL_DB < /tmp/state-compressor.sql
#done

# auto state compress with "big" settings from https://gitlab.com/mb-saces/synatainer and all rooms
RUST_LOG=error $HOME/rust-synapse-compress-state/target/debug/synapse_auto_compressor -c 1500 -n $ROOMLIMIT -p "postgresql://$PSQL_USER:$PSQL_PASSWORD@$PSQL_HOST/$PSQL_DB"

# when performing stop, dependencies are stopped
monit stop synapse

psql -w -U $PSQL_USER -h $PSQL_HOST --quiet -t -c "REINDEX DATABASE $PSQL_DB;" $PSQL_DB
psql -w -U $PSQL_USER -h $PSQL_HOST --quiet -t -c 'VACUUM FULL;' $PSQL_DB >/dev/null 2>&1

# when performing start, the dependencies are not started
monit start synapse
monit start federation_reader
monit start federation_sender
monit start user_directory
