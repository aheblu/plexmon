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

SCRIPT_NAME="plexmon"
SCRIPT_VERSION="v1.0.0"
SCRIPT_DESCR="Plex library auto-updater for *BSD"
PID_FILE="/var/run/$SCRIPT_NAME.pid"
CONFIG_FILE="/usr/local/etc/$SCRIPT_NAME.conf"
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

script_stop(){
    message "Stopping $SCRIPT_NAME..." "BOTH"
    kill -SIGHUP $PID_IN_FILE 
    [ $? -ne 0 ] && message "Error killing PID $PID_IN_FILE. Not enough permissions or already dead." "BOTH" 
    [ -f $PID_FILE ] && rm $PID_FILE
    [ $? -ne 0 ] && message "Error removing $PID_FILE" "BOTH" && exit
    message "$SCRIPT_NAME clean stop."
}

# REQUIREMENT CHECK - CONFIG
if [ -f "$CONFIG_FILE" ]; then
    . $CONFIG_FILE
else
    echo "Can not find config file: $CONFIG_FILE"
    exit 1
fi

# REQUIREMENT CHECK - SOFTWARE
check_prog (){
    which "$1" > /dev/null
    if [ $? -ne 0 ]; then
        echo "$1 not found in PATH. Aborting."
        exit 1
    fi
}

check_prog "bash"
check_prog "curl"
check_prog "xmllint"
check_prog "fswatch"

# LOG

message (){    
    msg=$1
    log=$2
    log_msg="$(date '+ %y/%m/%d% - %H:%M:%S') $msg"
    
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

# PARAMETER CHECK

case $PARAM1 in
--start)
    [ $IS_RUNNING -eq 1 ] && message "Start: $SCRIPT_NAME already running." && exit
    ;;

--stop)
    [ $IS_RUNNING -eq 0 ] && message "Stop: $SCRIPT_NAME not running."
    [ $IS_RUNNING -eq 1 ] && script_stop && message "Stop: $SCRIPT_NAME terminated."
    exit
    ;;

--restart)
    [ $IS_RUNNING -eq 1 ] && script_stop
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

# FUNCTIONS

# info: gets plex library id's for a path (there can be more libraries containing same path)
# return: $path_ids (array)   
id_for_path (){
     
    if [ -z $1 ]; then
        message "Should not happen: id_for_path - Null parameter." "LOG"; exit 1   
    fi
    
    media_path=$1

    loop=1
    i=0
    while [ $i -lt 5 ] || [ $loop -eq 1 ]; do
        resp="$(curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/?X-Plex-Token=$PLEX_TOKEN" |\
                xmllint --xpath "MediaContainer/Directory/Location[@path='$media_path']/../@key" -)"    
        if [ $? -ne 0 ] || [ -z "$resp" ]; then
            message "Server error: id_for_path - Error getting data from server for $media_path." "LOG"
            message "Server response following:" "LOG"
            message $resp "LOG"
            message "Server response end." "LOG"
            sleep 2
            loop=1
            ((i++))
        else
            loop=0            
        fi
    done

    unset path_ids
    readarray path_ids <<< "$(printf '%s' "$resp")"

    for i in ${!path_ids[@]}; do        
        eval ${path_ids[$i]} # creates var $key        
        path_ids[$i]=$key
        message "Found ID:${path_ids[$i]}" "LOG"
    done    
}

# get_plex_paths: get plex library paths from server
# return: plex_paths (array, unescaped)
# return: plex_paths_escaped (escaped)
get_plex_paths (){

    if [ -z "$PLEX_IP" ] || [ -z "$PLEX_PORT" ] || [ -z "$PLEX_TOKEN" ];then
        message "Config check failed. Some config variables empty." "BOTH";exit 1
    fi

    message "Getting plex data from $PLEX_IP:$PLEX_PORT" "BOTH"
    message "" # echo blank line

    resp="$(curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/?X-Plex-Token=$PLEX_TOKEN" |\
            xmllint --xpath "MediaContainer/Directory/Location/@path" -)"
    if [ $? -ne 0 ] || [ -z "$resp" ]; then    
         message "get_plex_paths: Error getting data from server." "BOTH"
    fi
    
    unset plex_paths
    readarray -t plex_paths <<< "$(printf '%s' "$resp")" # important to use quotes for printf   

    # plex_paths element data: path="/some/path"
    for i in ${!plex_paths[@]}; do
        #echo "Plex path found: ${plex_paths[$i]}"
        eval ${plex_paths[$i]} # creates var $path
        plex_paths[$i]=$path
        escaped_path="$(echo $path | sed -e 's/\ /\\ /g')/"  # escape spaces, with trailing slash        
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
    
    if [ -z "$1" ]; then
        message "Script error: find_plex_path - Null parameter."; exit 1
    fi
    check_path=$1 

    found_path=""
    find_plex_path_resp=""
    slash_number=0
    max_slash=0
    
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
        message "find_plex_path: no plex path found for $check_path" "LOG"
    fi
}

plex_partial_scan (){
    scan_folder=$1
    scan_id=$2
    
    message "Start partial scan: $scan_folder with id: $scan_id" "LOG"

    curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/$scan_id/refresh?path=$scan_folder&X-Plex-Token=$PLEX_TOKEN"
    if [ $? -ne 0 ]; then    
         message "plex_partial_scan: Error getting data from server." "LOG"
         #exit 1
    fi
}

plex_library_scan (){
    scan_id=$1

    message "Start library scan with id: $scan_id" "LOG"
    
    curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/$scan_id/refresh?X-Plex-Token=$PLEX_TOKEN"
    if [ $? -ne 0 ]; then    
         message "plex_library_scan: Error getting data from server." "LOG"
         #exit 1
    fi
}

# SCRIPT

get_plex_paths # returns plex_paths_escaped

if [ $? -ne 0 ]; then    
    message "Startup: Unknown error. Abort." "BOTH"; exit 1
fi

message "Starting fswatch..." "BOTH"

# start fswatch in background
fswatch -0rd -l $MON_LATENCY $plex_paths_escaped 2>error.log |\
 while read -d "" event 
  do 
    message "Path changed: $event" "LOG"
    find_plex_path "$event"
    message "Plex path found: $find_plex_path_resp" "LOG"
    id_for_path $find_plex_path_resp    
    for i in ${!path_ids[@]}; do        
        plex_partial_scan "$event" "${path_ids[$i]}"
        #plex_library_scan ${path_ids[$i]}
    done    
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

