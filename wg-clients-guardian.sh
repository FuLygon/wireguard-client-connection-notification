#!/bin/bash
# Send a message to Telegram or Gotify Server when a client is connected or disconnected from wireguard tunnel
#
#
# This script is written by Alfio Salanitri <www.alfiosalanitri.it> and are licensed under MIT License.
# Credits: This script is inspired by https://github.com/pivpn/pivpn/blob/master/scripts/wireguard/clientSTAT.sh

# check if the user passed in the config file and that the file exists
if [ ! "$1" ]; then
	printf "The config file is required.\n"
	exit 1
fi
if [ ! -f "$1" ]; then
	printf "This config file doesn't exist.\n"
	exit 1
fi

# config constants
readonly CURRENT_PATH=$(pwd)
readonly CLIENTS_DIRECTORY="$CURRENT_PATH/clients"
readonly CLIENT_NAMES_CONFIG="$CURRENT_PATH/client_names.conf"
readonly NOW=$(date +%s)
readonly DISABLE_DISCONNECT_NOTIFICATIONS=$(awk -F'=' '/^disable_disconnect_notifications=/ { print $2}' $1)

# after X minutes the clients will be considered disconnected
readonly TIMEOUT=$(awk -F'=' '/^timeout=/ { print $2}' $1)

# docker config
readonly DOCKER_EXEC=$(awk -F'=' '/^docker_wg_exec=/ { print $2}' $1)
readonly DOCKER_EXEC_CONTAINER=$(awk -F'=' '/^docker_wg_container=/ { print $2}' $1)

# get wg command
get_wg() {
    if [ "$DOCKER_EXEC" = "true" ]; then
        if [ -z "$DOCKER_EXEC_CONTAINER" ]; then
            echo "Sorry, but docker_wg_container is not set in config file" >&2
            exit 1
        fi
        docker exec "$DOCKER_EXEC_CONTAINER" wg show wg0 dump
    else
        if ! command -v wg &> /dev/null; then
            printf "Sorry, but wireguard is required. Install it and try again.\n" >&2
            exit 1
        fi
        wg show wg0 dump
    fi
}

readonly WIREGUARD_CLIENTS=$(get_wg | tail -n +2) # remove first line from list
if [ "" == "$WIREGUARD_CLIENTS" ]; then
	printf "No wireguard clients.\n"
	exit 1
fi

# get client name from config file if configurated
get_client_name() {
    local public_key=$1
    local client_name=""

    # get client name mapping from config file
    if [ -f "$CLIENT_NAMES_CONFIG" ]; then
        client_name=$(awk -F'@' -v key="$public_key" '$1 == key {print $2}' "$CLIENT_NAMES_CONFIG")
    fi

	if [ -z "$client_name" ]; then
		# check if the wireguard directory keys exists (created by pivpn)
		if [ -d "/etc/wireguard/keys/" ]; then
			# if the public_key is stored in the /etc/wireguard/keys/username_pub file, save the username in the client_name var
			client_name_by_public_key=$(grep -R "$public_key" /etc/wireguard/keys/ | awk -F"/etc/wireguard/keys/|_pub:" '{print $2}' | sed -e 's./..g')
			if [ "" != "$client_name_by_public_key" ]; then
				client_name=$client_name_by_public_key
			fi
		fi
	fi

	# use sanitized public key as the last method for client name
    if [ -z "$client_name" ]; then
        client_name=$(echo "$public_key" | sed 's/[^a-zA-Z0-9]//g')
    fi

    echo "$client_name"
}

readonly NOTIFICATION_CHANNEL=$(awk -F'=' '/^notification_channel=/ { print $2}' $1)

readonly GOTIFY_HOST=$(awk -F'=' '/^gotify_host=/ { print $2}' $1)
readonly GOTIFY_APP_TOKEN=$(awk -F'=' '/^gotify_app_token=/ { print $2}' $1)
readonly GOTIFY_TITLE=$(awk -F'=' '/^gotify_title=/ { print $2}' $1)

readonly TELEGRAM_CHAT_ID=$(awk -F'=' '/^chat=/ { print $2}' $1)
readonly TELEGRAM_TOKEN=$(awk -F'=' '/^token=/ { print $2}' $1)

while IFS= read -r LINE; do
	public_key=$(awk '{ print $1 }' <<< "$LINE")
	remote_ip=$(awk '{ print $3 }' <<< "$LINE" | awk -F':' '{print $1}')
	last_seen=$(awk '{ print $5 }' <<< "$LINE")
	client_name=$(get_client_name "$public_key")
	client_file="$CLIENTS_DIRECTORY/$client_name.txt"

	# create the client file if it does not exist.
	if [ ! -f "$client_file" ]; then
		echo "offline" > $client_file
	fi

	# setup notification variable
	send_notification="no"

	# last client status
	last_connection_status=$(cat $client_file)

	# elapsed seconds from last connection
	last_seen_seconds=$(date -d @"$last_seen" '+%s')

	# if the user is online
	if [ "$last_seen" -ne 0 ]; then

		# elapsed minutes from last connection
		last_seen_elapsed_minutes=$((10#$(($NOW - $last_seen_seconds)) / 60))

		# if the previous state was online and the elapsed minutes are greater than TIMEOUT, the user is offline
		if [ $last_seen_elapsed_minutes -gt $TIMEOUT ] && [ "online" == $last_connection_status ]; then
			echo "offline" > $client_file
			send_notification="disconnected"
		# if the previous state was offline and the elapsed minutes are lower than timout, the user is online
		elif [ $last_seen_elapsed_minutes -le $TIMEOUT ] && [ "offline" == $last_connection_status ]; then
			echo "online" > $client_file
			send_notification="connected"
		fi
	else
		# if the user is offline
		if [ "offline" != "$last_connection_status" ]; then
			echo "offline" > $client_file
			send_notification="disconnected"
		fi
	fi

	# send notification to telegram
	if [ "no" != "$send_notification" ]; then
		printf "The client %s is %s\n" $client_name $send_notification
		message="Client $client_name is $send_notification from IP address $remote_ip"

		# skip disconnect notifications if disabled
		if [ "$send_notification" = "disconnected" ] && [ "$DISABLE_DISCONNECT_NOTIFICATIONS" = "true" ]; then
			continue
		fi

		if [ "telegram" == "$NOTIFICATION_CHANNEL" ] || [ "both" == "$NOTIFICATION_CHANNEL" ]; then
			curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage" -F chat_id=$TELEGRAM_CHAT_ID -F text="🐉 Wireguard: \`$message\`" -F parse_mode="MarkdownV2" > /dev/null 2>&1
		fi
		if [ "gotify" == "$NOTIFICATION_CHANNEL" ] || [ "both" == "$NOTIFICATION_CHANNEL" ]; then
			curl -X POST "${GOTIFY_HOST}/message" -H "accept: application/json" -H "Content-Type: application/json" -H "Authorization: Bearer ${GOTIFY_APP_TOKEN}" -d '{"message": "'"$message"'", "priority": 5, "title": "'"$GOTIFY_TITLE"'"}' > /dev/null 2>&1
		fi
	else
		printf "The client %s is %s, no notification will be sent.\n" $client_name $(cat $client_file)
	fi

done <<< "$WIREGUARD_CLIENTS"

exit 0
