#!/usr/local/bin/bash

# PlexMon - Plex library auto-updater, by strain08
#
# info: updates plex whet a library directory changes
#
# version 1.0
# requires: 
#   bash 5.2.15
#   curl 
#   fswatch 1.13
#   xmllint: using libxml version 21004

SCRIPT_NAME="plexmon"
SCRIPT_VERSION="1.0"
PID_FILE="/var/run/$SCRIPT_NAME.pid"
CONFIG_FILE="/usr/local/etc/$SCRIPT_NAME.conf"
LOG_FILE="/var/log/$SCRIPT_NAME.log"

PARAM1=$1

echo "plexmon v$SCRIPT_VERSION - Plex library auto-updater for *bsd"

# PARAMETER CHECK

IS_RUNNING=0
if [ -f "$PID_FILE" ]; then
    echo "$PID_FILE exists"
    # check if really running    
    PID_IN_FILE=$(<$PID_FILE)
    ps -p $PID_IN_FILE > /dev/null
    if [ $? -eq 0 ]; then
        echo "$PID_IN_FILE is running."
        IS_RUNNING=1
    else
        IS_RUNNING=0
        echo $PID_IN_FILE is not running
        # process not running but pid file exists
        echo "Removing orphan pid file: $PID_FILE"
        rm $PID_FILE
    fi
fi

if [ -z "$PARAM1" ]; then
    if [ $IS_RUNNING -eq 1 ]; then
        echo "$SCRIPT_NAME running."
        exit
        
    else
       echo "$SCRIPT_NAME not running. Use --start."
       exit        
    fi
fi

if [[ "$PARAM1" != "--start" ]] && [[ "$PARAM1" != "--stop" ]]; then
    echo "Valid parameters are: --start, --stop"
    exit
fi

if [[ "$PARAM1" == "--start" ]] && [ $IS_RUNNING -eq 1 ]; then
    echo "$SCRIPT_NAME already running."
    exit
fi

if [[ "$PARAM1" == "--stop" ]] && [ $IS_RUNNING -eq 0 ]; then
    echo "$SCRIPT_NAME not running."
    exit
fi

if [[ "$PARAM1" == "--stop" ]] && [ $IS_RUNNING -eq 1 ]; then
    echo "Stopping $SCRIPT_NAME..."
    kill -SIGHUP $PID_IN_FILE
    rm $PID_FILE
    exit
fi

# REQUIREMENT CHECK - CONFIG
if [ -f "$CONFIG_FILE" ]; then
    . $CONFIG_FILE
else
    echo "Can not find config file: $CONFIG_FILE" | tee -a "$LOG_FILE"; 
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

check_prog "curl"
check_prog "xmllint"
check_prog "fswatch"

# FUNCTIONS

# info: gets plex library id's for a path (there can be more libraries containing same path)
# return: $path_ids (array)   
id_for_path (){
     
    if [ -z $1 ]; then
        echo "id_for_path: Null parameter." | tee -a "$LOG_FILE"; exit 1   
    fi
    
    media_path=$1

    RESP="$(curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/?X-Plex-Token=$PLEX_TOKEN" |\
            xmllint --xpath "MediaContainer/Directory/Location[@path='$media_path']/../@key" -)"    
    if [ $? -ne 0 ] || [ -z "$RESP" ]; then
         echo "id_for_path: Error getting data from server."; exit 1
    fi
    
    unset path_ids
    readarray path_ids <<< "$(printf '%s' "$RESP")"

    for i in ${!path_ids[@]}; do        
        eval ${path_ids[$i]} # creates var $key        
        path_ids[$i]=$key
        echo "Found ID:${path_ids[$i]}"
    done    
}

# get_plex_paths: get plex library paths from server
# return: plex_paths (array, unescaped)
# return: plex_paths_string (escaped)
get_plex_paths (){

    if [ -z "$PLEX_IP" ] || [ -z "$PLEX_PORT" ] || [ -z "$PLEX_TOKEN" ];then
        echo "Config check failed. Some config variables empty.";exit 1
    fi

    echo "Getting plex data from $PLEX_IP:$PLEX_PORT"
    echo ""

    RESP="$(curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/?X-Plex-Token=$PLEX_TOKEN" |\
            xmllint --xpath "MediaContainer/Directory/Location/@path" -)"
    if [ $? -ne 0 ] || [ -z "$RESP" ]; then    
         echo "get_plex_paths: Error getting data from server."; exit 1
    fi
    
    unset plex_paths
    readarray -t plex_paths <<< "$(printf '%s' "$RESP")" # important to use quotes for printf
    
    echo "Library locations:" | tee -a "$LOG_FILE"

    # plex_paths element data: path="/some/path"
    for i in ${!plex_paths[@]}; do
        #echo "Plex path found: ${plex_paths[$i]}"
        eval ${plex_paths[$i]} # creates var $path
        plex_paths[$i]=$path
        escaped_path="$(echo $path | sed -e 's/\ /\\ /g')/"  # escape spaces, with trailing slash        
        echo ${plex_paths[$i]} | tee -a "$LOG_FILE"
        plex_paths_string="$plex_paths_string $escaped_path"
    done    
    echo ""
    
    #trim spaces
    plex_paths_string=`echo $plex_paths_string | sed -e 's/^[[:space:]]*//'`
}

# info: get the plex path contained in param1
# return: find_plex_path_resp
find_plex_path (){
    
    if [ -z "$1" ]; then
        echo "find_plex_path: Null parameter."; exit 1
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
        echo "find_plex_path: Null response."; exit 1
    fi
}

plex_partial_scan (){
    scan_folder=$1
    scan_id=$2
    
    echo "Start partial scan: $scan_folder with id: $scan_id"

    curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/$scan_id/refresh?path=$scan_folder&X-Plex-Token=$PLEX_TOKEN"
    if [ $? -ne 0 ]; then    
         echo "plex_partial_scan: Error getting data from server." 
         #exit 1
    fi
}

plex_library_scan (){
    scan_id=$1

    echo "Start library scan with id: $scan_id"
    
    curl -s "http://$PLEX_IP:$PLEX_PORT/library/sections/$scan_id/refresh?X-Plex-Token=$PLEX_TOKEN"
    if [ $? -ne 0 ]; then    
         echo "plex_library_scan: Error getting data from server."
         #exit 1
    fi
}

# SCRIPT

get_plex_paths # returns plex_paths_string

if [ $? -ne 0 ]; then    
    echo "Unknown error: Abort."; exit 1
fi

#echo "Monitor paths [$plex_paths_string]"
echo "Starting monitor..."

# start fswatch in background
fswatch -0rd -l $MON_LATENCY $plex_paths_string 2>error.log |\
 while read -d "" event 
  do 
    echo "Path changed: $event"
    find_plex_path "$event"
    echo "Plex path found: $find_plex_path_resp"    
    id_for_path $find_plex_path_resp    
    for i in ${!path_ids[@]}; do        
        plex_partial_scan "$event" "${path_ids[$i]}"
        #plex_library_scan ${path_ids[$i]}
    done    
  done &

FSWATCH_PID=$(pgrep -n fswatch)

echo "Monitor started with PID: $FSWATCH_PID"
echo $FSWATCH_PID > $PID_FILE
