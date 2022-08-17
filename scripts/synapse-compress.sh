#!/bin/bash

# This script is everything that is presented on https://levans.fr/shrink-synapse-database.html put into one bash script
# and adapted to monit init system at the end

API_TOKEN=<ADD HERE>
HOST=http://localhost:8008
ROOMLIMIT=10000
PSQL_USER=synapse
PSQL_HOST=localhost
PSQL_DB=synapse

ROOMLIST=$(curl --silent --fail --header "Authorization: Bearer $API_TOKEN" $HOST/_synapse/admin/v1/rooms?limit=$ROOMLIMIT)

ROOMS_WITHOUT_LOCAL_USERS=$(echo $ROOMLIST | jq --raw-output '.rooms[] | select(.joined_local_members == 0) | .room_id')

for room in $ROOMS_WITHOUT_LOCAL_USERS; do
	curl --silent --fail --header "Authorization: Bearer $API_TOKEN" --header "Content-Type: application/json" -XDELETE -d "{}" --output /dev/null "$HOST/_synapse/admin/v1/rooms/$room"
done

TIMESTAMPMS30DAYS=$(date --date="-30 days" +%s000)
curl --silent --fail --header "Authorization: Bearer $API_TOKEN" --header "Content-Type: application/json" -d "{}" --output /dev/null "$HOST/_synapse/admin/v1/purge_media_cache?before_ts=$TIMESTAMPMS30DAYS"

# stop and start for full vacuum
# and due to https://github.com/matrix-org/synapse/issues/11521
# when performing stop, dependencies are stopped
monit stop synapse

psql -w -U $PSQL_USER -h $PSQL_HOST --quiet -t -c "REINDEX DATABASE $PSQL_DB;" $PSQL_DB
psql -w -U $PSQL_USER -h $PSQL_HOST --quiet -t -c 'VACUUM FULL;' $PSQL_DB >/dev/null 2>&1

# when performing start, the dependencies are not started
monit start synapse
monit start federation_reader
monit start federation_sender
monit start user_directory
