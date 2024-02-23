#!/usr/local/bin/bash

# plexmon - Plex library auto-updater, by strain08
#
# info: notifies plex when a library directory changes
#
# requires:
#   bash 5.2.15
#   curl
#   fswatch 1.13
#   xmllint: using libxml version 21004
#   jq 1.7

SCRIPT_NAME="plexmon"
SCRIPT_VERSION="v1.1.0"
SCRIPT_DESCR="Plex library auto-updater for *BSD"
PID_FILE="/var/run/$SCRIPT_NAME.pid"
CONFIG_FILE="/usr/local/etc/$SCRIPT_NAME.conf"
CONFIG_VARS="PLEX_IP PLEX_TOKEN PLEX_PORT LOG_LEVEL MON_LATENCY"
DEPENDENCIES="bash curl xmllint fswatch jq"
LOG_FILE="/var/log/$SCRIPT_NAME.log"


PARAM1=$1

echo "$SCRIPT_NAME $SCRIPT_VERSION - $SCRIPT_DESCR"

# PID CHECK
# Sets IS_RUNNING to 1 if fswatch process exists
IS_RUNNING=0
if [ -f "$PID_FILE" ]; then
    PID_IN_FILE=$(<$PID_FILE)
    echo "$PID_FILE exists: $PID_IN_FILE"
    # check if really running
    ps -p $PID_IN_FILE > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        echo "fswatch with PID $PID_IN_FILE is running."
        IS_RUNNING=1
    else
        IS_RUNNING=0
        echo $PID_IN_FILE is not running
        # process not running but PID file exists
        echo "Removing orphan pid file: $PID_FILE"
        rm $PID_FILE
    fi
fi

fswatch_stop(){
    message "Stopping fswatch..." "BOTH"
    kill -SIGHUP $PID_IN_FILE
    [ $? -ne 0 ] && message "Error killing PID $PID_IN_FILE. Not enough permissions or already dead." "BOTH"
    [ -f $PID_FILE ] && rm $PID_FILE
    [ $? -ne 0 ] && message "Error removing $PID_FILE" "BOTH" && exit
    message "fswatch clean stop."
}

# LOG
message (){
    local msg=$1
    local log=$2
    local log_msg="$(date '+ %y/%m/%d% - %H:%M:%S') $msg"

    # if LOG_LEVEL is undefined just print the message
    [ -z $LOG_LEVEL ] && echo $log_msg && return

    case $log in
    LOG)
        [ $LOG_LEVEL -eq 1 ] && echo $log_msg >> $LOG_FILE
        ;;
    BOTH)
        echo $log_msg
        [ $LOG_LEVEL -eq 1 ] && echo $log_msg >> $LOG_FILE
        ;;
    *)
        echo $log_msg
    esac
}

# COMMAND LINE CHECK
case $PARAM1 in
--start)
    [ $IS_RUNNING -eq 1 ] && message "Start: $SCRIPT_NAME already running." && exit
    ;;

--stop)
    [ $IS_RUNNING -eq 0 ] && message "Stop: $SCRIPT_NAME not running."
    [ $IS_RUNNING -eq 1 ] && fswatch_stop && message "Stop: $SCRIPT_NAME terminated."
    exit
    ;;

--restart)
    [ $IS_RUNNING -eq 1 ] && fswatch_stop
    [ $IS_RUNNING -eq 0 ] && message "Restart: $SCRIPT_NAME not running. Starting..."
    ;;

*)
    if [ -z "$PARAM1" ]; then
        if [ $IS_RUNNING -eq 1 ]; then
            message "$SCRIPT_NAME is running."
        else
            message "$SCRIPT_NAME not running. Use \"$SCRIPT_NAME --start\""
        fi
    else
        message "Valid parameters are: --start, --stop, --restart"
    fi
    exit
    ;;
esac

# REQUIREMENT CHECK - config file
if [ -f "$CONFIG_FILE" ]; then
    . $CONFIG_FILE
else
    fswatch_stop
    echo "$CONFIG_FILE not present."
    echo "$SCRIPT_NAME terminated." && exit 1
fi

# REQUIREMENT CHECK - config variables
for var in $CONFIG_VARS; do
    if [ -z ${!var} ]; then
        echo "$var not set in $CONFIG_FILE"
        echo "Checkout $SCRIPT_NAME.conf.sample for reference."
        exit 1
    fi
done

# REQUIREMENT CHECK - dependencies
for prog in $DEPENDENCIES; do
    which "$prog" > /dev/null
    if [ $? -ne 0 ]; then
        echo "$prog not found in PATH. Aborting."
        exit 1
    fi
done

# REQUIREMENT CHECK - Plex Server connection check
resp=$(curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/?X-Plex-Token=$PLEX_TOKEN")
error=$?
[ $error -eq 7 ] && message "ERROR: Can not connect to Plex Server, wrong ip/port or server offline." "BOTH" && exit 1
[ $error -eq 52 ] && message "ERROR: Plex Server secure connections set to Require. Change setting to Preferred or use 127.0.0.1 as server ip in conf file." "BOTH" && exit 1
[ $error -ne 0 ] && message "ERROR: Can not connect to Plex Server! Unknown error code." && exit 1
[ -z "$resp" ] && message "ERROR: Empty response from server! Wrong port or unkonwn error." "BOTH" && exit 1
[[ $resp =~ "401 Unauthorized" ]] && message "ERROR: Plex Token unauthorized !" && exit 1
unset resp
unset error

# PLEX FUNCTIONS

# id_for_path
# info: gets plex library id's for a path (there can be more libraries containing same path)
# return: $path_ids (array)
id_for_path (){

    if [ -z "$1" ]; then
        message "WARNING in id_for_path() - No path to search for." "LOG"
        path_ids=()
        return
    fi

    media_path=$1

    local xml_resp="$(curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/?X-Plex-Token=$PLEX_TOKEN")"
    [ $? -ne 0 ] && message "WARNING in id_for_path(): Error getting data from server for $media_path." "LOG"

    local xml_parse="$(echo $xml_resp | xmllint --xpath "MediaContainer/Directory/Location[@path='$media_path']/../@key" -)"
    if [ $? -ne 0 ] || [ -z "$xml_parse" ]; then
        message "WARNING in id_for_path(): xmllint error parsing server response for $media_path." "LOG"
        message "xmllint response:" "LOG"
        message "[ $xml_parse ]" "LOG"
        message "xmllint response end." "LOG"
    fi

    unset path_ids
    readarray path_ids <<< "$(printf '%s' "$xml_parse")"

    for i in ${!path_ids[@]}; do
        eval ${path_ids[$i]} # creates var $key
        path_ids[$i]=$key
        message "Found ID:${path_ids[$i]}" "LOG"
        unset key
    done
}

# get_plex_paths: get plex library paths from server
# return: plex_paths (array, unescaped)
# return: plex_paths_escaped (escaped)
get_plex_paths (){

    message "Getting plex data from $PLEX_IP:$PLEX_PORT..." "BOTH"
    message "" # echo blank line
    local xml_resp="$(curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/?X-Plex-Token=$PLEX_TOKEN")"
    if [ $? -ne 0 ]; then
        message "ERROR in get_plex_paths(): curl error getting data from server !" "BOTH"
        message "Nothing to do without plex paths. Exiting..." "BOTH"; exit 1
    fi

    if [ -z "$xml_resp" ]; then
        message "ERROR in get_plex_paths(): server sent empty response !"
        message "Nothing to do without plex paths. Exiting..." "BOTH"; exit 1
    fi

    local xml_parse="$( echo ${xml_resp} | xmllint --xpath "MediaContainer/Directory/Location/@path" -)"
    if [ $? -ne 0 ] || [ -z "$xml_parse" ]; then
         message "ERROR in get_plex_paths(): xmllint error parsing server response !" "BOTH"
         message "get_plex_paths: xmllint response:" "BOTH"
         message "[ ${xml_parse} ]" "BOTH"
         message "Nothing to do without plex paths. Exiting..." "BOTH"; exit 1
    fi

    unset plex_paths
    readarray -t plex_paths <<< "$(printf '%s' "${xml_parse}")" # important to use quotes for printf

    # plex_paths element data: path="/some/path"
    for i in ${!plex_paths[@]}; do
        #echo "Plex path found: ${plex_paths[$i]}"
        eval ${plex_paths[$i]} # creates var $path
        plex_paths[$i]=${path}
        local escaped_path="$(echo $path | sed -e 's/\ /\\ /g')/"  # escape spaces, with trailing slash
        message "Found plex path: ${plex_paths[$i]}" "BOTH"
        plex_paths_escaped="$plex_paths_escaped $escaped_path"
    done
    echo ""

    #trim spaces
    plex_paths_escaped=`echo $plex_paths_escaped | sed -e 's/^[[:space:]]*//'`
}

# info: get the plex path contained in param1
# return: find_plex_path_resp
find_plex_path (){

    local check_path=$1
    if [ -z "$check_path" ]; then
        message "ERROR in find_plex_path() - Null parameter. Script error. Shutting down." "BOTH"; fswatch_stop; exit 1
    fi

    local found_path=""
    local slash_number=0
    local max_slash=0
    find_plex_path_resp=""

    for i in ${!plex_paths[@]}; do
        # if begins with plex_paths[i]
        if [[  $check_path =~ ^${plex_paths[i]}.* ]]; then
            # if there are nested paths
            # match the plex path with max depth
            found_path=${plex_paths[$i]}
            slash_number="$(echo $found_path | grep -o \/ | wc -l)"
            if (( slash_number > max_slash )); then
                find_plex_path_resp=$found_path
                max_slash=$slash_number
            fi
        fi
    done
    if [ -z "$find_plex_path_resp" ]; then
        message "WARNING in find_plex_path(): no plex path found for $check_path" "LOG"
    else
        message "Plex path found: $find_plex_path_resp" "LOG"
    fi
}

plex_partial_scan (){
    local scan_folder=$1
    local scan_id=$2

    message "Start partial scan: $scan_folder with id: $scan_id" "LOG";
    scan_folder=$(echo $scan_folder | jq "@uri" -jRr) # URL-encode scan folder
    curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/$scan_id/refresh?path=$scan_folder&X-Plex-Token=$PLEX_TOKEN"
    [ $? -ne 0 ] && \
        message "WARNING in plex_partial_scan(): curl could not get data from server." "LOG"
}

plex_library_scan (){
    local scan_id=$1

    message "Start library scan with id: $scan_id" "LOG"

    curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/$scan_id/refresh?X-Plex-Token=$PLEX_TOKEN"
    [ $? -ne 0 ] && \
        message "WARNING in plex_library_scan(): curl could not get data from server." "LOG"

}

# SCRIPT

get_plex_paths # returns plex_paths_escaped

message "Starting fswatch..." "BOTH"

# start fswatch in background
fswatch -0rd -l $MON_LATENCY $plex_paths_escaped 2>error.log |\
    while read -d "" event; do
        if [[ $event =~ "/" ]]; then # if event contains a path
            message "fswatch: Path changed: $event" "LOG"
            find_plex_path "$event" # returns find_plex_path_resp
            id_for_path $find_plex_path_resp # returns path_ids array
            for i in ${!path_ids[@]}; do
                plex_partial_scan "$event" "${path_ids[$i]}"
            done
        else
            message "WARNING in fswatch: Event is not a path. Event: [ $event ]" "BOTH"
        fi
    done &

# wait for fswatch to start
i=1
retry=5
FSWATCH_PID=$(pgrep -n fswatch)
while [ -z "$FSWATCH_PID" ] && [ $i -lt $retry ]; do
    echo "[$i - $retry] Waiting for fswatch..."
    sleep 1
    ((i++))
    FSWATCH_PID=$(pgrep -n fswatch)
done

[ -z $FSWATCH_PID ] && message "Error starting fswatch." "BOTH" && exit

echo $FSWATCH_PID > $PID_FILE && message "fswatch started with PID: $FSWATCH_PID" "BOTH"

