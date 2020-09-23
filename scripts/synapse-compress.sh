#!/bin/bash

# This script is everything that is presented on https://levans.fr/shrink-synapse-database.html put into one bash script and adapted to monit init system at the end

API_TOKEN=<ADD HERE>
HOST=http://localhost:8008
ROOMLIMIT=5000
PSQL_USER=synapse
PSQL_PASSWORD=password
PSQL_HOST=localhost
PSQL_DB=synapse

# user-agent workaround for https://github.com/matrix-org/synapse/issues/8188
ROOMLIST=$(curl --silent --user-agent "Synapse/1.19.1" --header "Authorization: Bearer $API_TOKEN" $HOST/_synapse/admin/v1/rooms?limit=$ROOMLIMIT)

ROOMS_WITHOUT_LOCAL_USERS=$(echo $ROOMLIST | jq '.rooms[] | select(.joined_local_members == 0) | .room_id')

for room in $ROOMS_WITHOUT_LOCAL_USERS; do
	curl --silent --user-agent "Synapse/1.19.1" --header "Authorization: Bearer $API_TOKEN" --header "Content-Type: application/json" -d "{ \"room_id\": $room }" --output /dev/null $HOST/_synapse/admin/v1/purge_room
done

ROOMS_TO_COMPRESS=$(psql -w -U $PSQL_USER -h $PSQL_HOST --quiet -t -c 'SELECT room_id  FROM state_groups_state GROUP BY room_id HAVING count(*) > 100000;' $PSQL_DB)

for room in $ROOMS_TO_COMPRESS; do
	$HOME/bin/synapse-compress-state -t -o /tmp/state-compressor.sql -p "host=$PSQL_HOST user=$PSQL_USER password=$PSQL_PASSWORD dbname=$PSQ_DB" -r "$room" >/dev/null 2>&1
    psql -w -U $PSQL_USER -h $PSQL_HOST --quiet $PSQL_DB < /tmp/state-compressor.sql
done

monit stop synapse

psql -w -U $PSQL_USER -h $PSQL_HOST --quiet -t -c 'REINDEX DATABASE $PSQL_DB;' $PSQL_DB
psql -w -U $PSQL_USER -h $PSQL_HOST --quiet -t -c 'VACUUM FULL;' $PSQL_DB >/dev/null 2>&1

monit start synapse
monit start federation_reader
monit start federation_sender
monit start user_directory
