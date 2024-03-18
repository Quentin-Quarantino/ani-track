#!/bin/bash
use_external_menu=0
## VARS
version="0.1"
runas="root"
workdir="${XDG_STATE_HOME:-$HOME/.local/state}/ani-track"
ani_cli_hist="${XDG_STATE_HOME:-$HOME/.local/state}/ani-cli/ani-hsts"
tmpsearchf="${workdir}/search-tmp"
tmpinfof="${workdir}/info-tmp"
histfile="${workdir}/ani-track.hist"
wwwdir="${workdir}/tmp-www"
tmpredirect="${workdir}/redirectoutput"
secrets_file=${workdir}/.secrets
anitrackdb="${workdir}/anidb.csv"
defaultRedirectPort="8080"
API_AUTH_ENDPOINT="https://myanimelist.net/v1/oauth2/"
API_ENDPOINT="https://api.myanimelist.net/v2"
BASE_URL="$API_ENDPOINT/anime"
web_browser="firefox"
timeout=120
wspace='%20'                                        ## white space can be + or %20
deftype="anime"                                     ## default type can be manga or anime
defslimit="40"
deffields="id,title,num_episodes"

## check if not run as root 
if [ "$(whoami)" == "${runas}" ] ;then
    echo "script must not be runned as user $runas"
    exit 1
fi


## functions
manualPage() {
        printf "
%s version: $version

usage:
  %s [options] [query]
  %s [options] [query] [options]

Options:
  -s search
  -o offline search
  -l search limit (online)
  -f offline fuzzy search default level is 1. agrep/tre must be installed: -f [1-9]
  -m set to type manga

Example:
  %s -s demon slayer -l 10
  %s -s one piece -w 1045
  %s -s chainsaw -w ++
  %s -o shippu -f 4
  %s -U 
\n\n" "${0##*/}" "${0##*/}" "${0##*/}" "${0##*/}" "${0##*/}" "${0##*/}" "${0##*/}" "${0##*/}" 
}

## die function - usage: die "message"
die() {
    printf "\33[2K\r\033[1;31m%s\033[0m\n" "$*" >&2
    exit 1
}

## dependency check - usage: dep_ch "dep01" "dep02" || true
dep_ch() {
    missingdep=""
    plural=""
    for dep; do
        if ! command -v "$dep" >/dev/null ; then
            if [ X"$missingdep" == "X" ] ;then
                missingdep="$dep"
            else
                plural="s"
                missingdep+=" $dep"

            fi
        fi
    done
    ## for missing dep print name and die
    if [ X"$missingdep" != "X" ] ;then
        die "Program${plural} \"$missingdep\" not found. Please install it."
    fi
}

create_secrets() {
    > "$secrets_file" || die "could not create secrets file: touch $secrets_file"
    printf "client_id=\nclient_secret=\ncode_challanger=\nauthorisation_code=\nbearer_token=\nrefresh_token=\n" > "$secrets_file" 
    die "add you're api client id and the secret in the $secrets_file and re-run the script"
}

create_challanger() {
    code_verifier="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 128)"
    sed -i "s/code_challanger.*/code_challanger=$code_verifier/" "$secrets_file" || die "could not update code_challanger in secrets file"
    echo "new code_challanger updated"
    source "$secrets_file"
}

get_auth_code() {
    > "$tmpredirect"
    mkdir "$wwwdir"
    printf "<html>\n<body>\n<h1>Verification Succeeded!</h1>\n<p>Close this browser tab and you may now return to the shell.</p>\n</body>\n</html>\n" > ${wwwdir}/index.html
    trap 'rm -rf -- "$wwwdir"' EXIT
    auth_url="${API_AUTH_ENDPOINT}authorize?response_type=code&client_id=${client_id}&code_challenge=${code_challanger}"
    python3 -m http.server -d "$wwwdir" $defaultRedirectPort > "$tmpredirect" 2>&1 &
    wserver_pid="$!"
    "$web_browser" "$auth_url" 2>&1 >/dev/null
    echo -e "please authenticate in the web browser and press enter after allow it"
    read -r -t "$timeout" answer
    unset answer
    kill "$wserver_pid"
    check_www_srv="$(grep -i "Address already in use" "$tmpredirect")"

    if [ X"$check_www_srv" != X ] ;then 
        echo "web server port was already in use"
        die "please check with 'sudo netstat -tlpn || sudo ss -tlpn' if there is a service on port $defaultRedirectPort"
        
    fi
    auth_code="$(grep GET "$tmpredirect" |awk '{print $(NF-3)}' |awk -F= '{print $NF}' |tail -1)"
    if [ X"$auth_code" == X ] || [ "$(wc -w <<< "$auth_code")" -ne 1 ] || [ "${#auth_code}" -lt 128 ] ; then 
        die "something went wrong... "
    fi
    sed -i "s/authorisation_code.*/authorisation_code=$auth_code/" "$secrets_file" || die "could not update authorisation_code in secrets file"
    source "$secrets_file"
    acc=1
}

get_bearer_token() {
    URL="${API_AUTH_ENDPOINT}token"
    DATA="client_id=${client_id}"
    DATA+="&client_secret=${client_secret}"
    DATA+="&code=${authorisation_code}"
    DATA+="&code_verifier=${code_challanger}"
    DATA+="&grant_type=authorization_code"

    if [ "$1" == "refresh" ] ;then
        data="client_id=${client_id}"
        data+="&client_secret=${client_secret}"
        data+="&grant_type=refresh_token"
        data+="&refresh_token=$refresh_token" 
    fi

    get_bt="$(curl -sfX POST "$URL" -d "$DATA")"

    bt="$(jq -r '.access_token' <<< "$get_bt" 2>/dev/null)"
    rt="$(jq -r '.refresh_token' <<< "$get_bt" 2>/dev/null)"
    
    if [ X"$bt" == X ] || [ X"$rt" == X ] || [ "${#bt}" -lt 64 ] || [ "${#rt}" -lt 64 ] ;then
        die "could not get a valid bearer token"
    fi
    sed -i "s/bearer_token.*/bearer_token=$bt/;s/refresh_token.*/refresh_token=$rt/" "$secrets_file" || die "could not update bearer token in secrets file"
    source "$secrets_file"
    [ "$1" != "refresh" ] && btc=1
}

verify_login() {
    check_login="$(curl -sfX GET -w "%{http_code}" -o /dev/null "${API_ENDPOINT}/users/@me" -H "Authorization: Bearer ${bearer_token}" )"
    login_user="$(curl -sfX GET "${API_ENDPOINT}/users/@me" -H "Authorization: Bearer ${bearer_token}" |jq -r '.name'  )"
}

## hist file update 
## usage 'histupdate "message"' 
## insert line in history "date: message"
histupdate() {
    dt=$(date "+%Y-%m-%d %H:%M:%S")
    histline="${dt} : $1"
    echo "$histline" >> "$histfile"
}

search_anime() {
    ## prepare search querry: remove other options and double spaces etc
    searchQuerry="$(sed "s/[[:space:]]\+-s[[:space:]]+//;s/-s //;s/ -l[[:space:]]\+[0-9]\+//;s/-o[[:space:]]+//;s/-l[[:space:]]\+[0-9]\+//;s/[[:space:]]\+/ /g;s/[[:space:]]/$wspace/g" <<< "$2")"
    
    histupdate "SEARCH $(sed 's/[[:space:]]\+-s[[:space:]]+//;s/-s //;s/ -l[[:space:]]\+[0-9]\+//;s/-l[[:space:]]\+[0-9]\+//' <<< "$2")" 
    
    ## if search querry is empty or have double space then die  
    if [ X"$searchQuerry" == "X" ] || [[ "$searchQuerry" =~ ^(%20)+$ && ! "$searchQuerry" =~ %20[^%]+%20 ]] ;then
        die "search querry is empty or trash: $searchQuerry"
    fi

    DATA="q=${searchQuerry}"
    DATA+="&limit=${defslimit}"

    curl -s "${BASE_URL}?${DATA}" -H "Authorization: Bearer ${bearer_token}" | jq . > "${tmpsearchf}"
    echo curl -s "${BASE_URL}?${DATA}" -H "Authorization: Bearer ${bearer_token}"

    ## if file is empty then die 
    [ ! -s "${tmpsearchf}" ] && die "search results are empty... something went wrong. search querry was: $searchQuerry"
    ## grep in temp file for bad request and die if found 
    [ "$(grep -o "bad_request" "${tmpsearchf}")" == "bad_request" ] && die "nothing found or bad request... try again"
    

    #result="$(awk '{$1="";print}' <<< "$(printf "%s" "$(jq -r '.data[] | .node | [.title] | join(",")' "${tmpsearchf}")" | awk '{n++ ;print NR, $0}' | sed 's/^[[:space:]]//' | nth "Select anime: ")")"
    malaniname="$(awk '{$1="";print}' <<< "$(printf "%s" "$(jq -r '.data[] | .node | [.title] | join(",")' "${tmpsearchf}")" | awk '{n++ ;print NR, $0}' | sed 's/^[[:space:]]//' | fzf --reverse --cycle --prompt "Search $2 with $1 episodes done: ")")"
    
    if [ X"$malaniname" == X ] ; then
        echo "nothing selected, start next one"
    else
        malaniname="${malaniname#"${malaniname%%[![:space:]]*}"}"
        aniid="$(jq --arg malaniname "$malaniname" '.data[] | .node | select(.title == $malaniname) | .id' "${tmpsearchf}")"
        aniline=("$aniid" "$2" "$1")
    fi
}

update_local_db() {
    for i in "${aniline[0]}" ;do 
        if [ X"$i" != X ] ;then
            if grep -qE "^${aniline[0]};${aniline[1]}" "$anitrackdb" ; then
                histupdate "SET on ${aniline[1]} with id ${aniline[0]} in local db episodes done from $ck_ldb_epdone to ${aniline[2]}"
                sed -i "s/^${aniline[0]};${aniline[1]}.*$/${aniline[0]};${aniline[1]};${aniline[2]}/" "$anitrackdb" || die "could not update $anitrackdb"
            else
                histupdate "INSERT ${aniline[1]} with id ${aniline[0]} in local db. ${aniline[2]} episodes done"
                echo "${aniline[0]};${aniline[1]};${aniline[2]}" >> "$anitrackdb" || die "could not update $anitrackdb"
            fi
        fi
    done

    unset aniline
    unset ck_ldb_epdone
}


### main

## if $@ == 'null|-h|--help' run manual and exit
para="$(sed 's/[[:space:]]+//g' <<<"$@")"
#if [[ -z "$para" || "$para" == "-h" || "$para" == "--help" || "$para" == "--" || "$para" == "--h" ]] ; then
#    manualPage
#    exit 0
#fi

echo "Checking dependencies..."
dep_ch "fzf" "curl" "sed" "grep" "jq" "python3" "$web_browser" ||true 
echo -e '\e[1A\e[K'

if [ X"$(grep -E "\-l[[:space:]]+[0-9]+" <<<"$@")" != X ] ;then
    defslimit="$(grep -Eo "\-l[[:space:]]+[0-9]+" <<<"$@" |grep -Eo "[0-9]+")"
    if [ "$defslimit" == "0" ] || [ X"$defslimit" == X ] ; then 
        echo "set default limit: $defslimit"
    fi
fi

## create $workdir
if ! mkdir -p "$workdir" ;then
    die "error: clould not run mkdir -p $workdir"
fi

## create temp files and trap for cleanup
for i in "$tmpsearchf" "$tmpinfof" "$tmpredirect" ;do 
    > "$i" || die "could not create temp file: touch $i"
done
trap 'rm -f -- "$tmpsearchf" "$tmpinfof" "$tmpredirect"' EXIT

## create secrets if not exists 
[ ! -s "$secrets_file" ] && create_secrets

## check if there is other stuff then vars in secrets file
check_secrets="$(grep -Ev '^([[:alpha:]_]+)=.*$|^([[:alpha:]_]+)=$|^[[:space:]]+|^$|^#' "$secrets_file")"

## source if $check_secrets is epmty
if [ -z "$check_secrets" ] ; then
    source "$secrets_file"
else
    die "check you're secrets file becuse it can contain commands. Please remove everything thats not vars"
fi

## die when api client id and secrets is epmty
if [ X"$client_id" == X ] || [ X"$client_secret" == X ] ;then
    die "client_id and/or client_secret are empty. please add it to $secrets_file"
fi

## die if ani-cli history is not found
if [ ! -f "$ani_cli_hist" ] || [ ! -r "$ani_cli_hist" ] ;then
    die "ani-cli history not found in $ani_cli_hist"
fi

## create $anitrackdb or die
if [ ! -f "$anitrackdb" ] || [ ! -r "$anitrackdb" ] ;then
    > $anitrackdb || die "could not create $anitrackdb"
fi

## check if challanger, auth code or bearer token is present or run functions to create 
if [ X"$code_challanger" == X ] || [ X"$authorisation_code" == X ] || [ X"$bearer_token" == X ] ;then 
    create_challanger
    get_auth_code
    get_bearer_token
fi

verify_login

if [ X"$login_user" == X ] || [ "$check_login" != 200 ] ;then
    echo "login was not successfull"
    if [ X"$refresh_token" != X ] ;then
        echo "try to refresh the bearer token"
        get_bearer_token "refresh"
        verify_login
    fi
    if [ "$btc" != 1 ] || [ "$acc" != 1 ] || [ "$check_login" != 200 ]  ; then
        echo "recreate new bearer token"
        create_challanger
        get_auth_code
        get_bearer_token
        verify_login
    else
        die "please check you're api secrets"
    fi
fi

printf "login successfull\nhi $login_user\n\n"

sed -i '/^$/d' "$anitrackdb"
while read -r ani; do
    aniname="$(cut -d ' ' -f 2- <<< "$ani")"
    epdone="$(cut -d ' ' -f 1 <<< "$ani")"
    ck_ldb="$(awk -F ";" -v ani="$aniname" '{if($2==ani) print $2}' "$anitrackdb")"
    ck_ldb_epdone="$(awk -F ";" -v ani="$aniname" '{if($2==ani) print $3}' "$anitrackdb")"
    ck_ldb_id="$(awk -F ";" -v ani="$aniname" '{if($2==ani) print $1}' "$anitrackdb")"
    ## if anime is already in local db
    if [ "$ck_ldb" == "$aniname" ] && [ X"$ck_ldb_epdone" != "$epdone" ] ; then
        if [ "$epdone" != "$ck_ldb_epdone" ] ;then
            aniline=("${ck_ldb_id}" "${ck_ldb}" "${epdone}")
            update_local_db
        fi
    ## if anime is not in local db
    elif [ X"$ck_ldb" == X ] ; then #[[ "$ck_ldb" =~ " " ]] || [[ ! "$ck_ldb" =~ ^-?[0-9]+$ ]] || [[ ! "$ck_ldb" =~ $'\n' ]];then
        search_anime "$epdone" "$aniname"
        update_local_db
    ## if local db has 2 entrys to the same anime, print error and continue
    elif [[ "$ck_ldb" =~ " " ]] || [[ ! "$ck_ldb" =~ ^-?[0-9]+$ ]] || [[ ! "$ck_ldb" =~ $'\n' ]];then
        printf "error: $ani found twice or more in $anitrackdb\nplease check the $anitrackdb\n"
        histupdate "ERROR multiple enttrys found with name $aniname. please check $anitrackdb"
        continue
    fi
    unset ck_ldb
    unset ck_ldb_id
    unset ck_ldb_epdone
done <<< "$(awk '{$2="";for (i = 1; i <= NF-2; i++) printf "%s ", $i; printf "\n"}' "$ani_cli_hist" |tr -cd '[:alnum:][:space:]\n ' |sed 's/[[:space:]]\+/ /g')"


## example history
# grep iece .local/state/ani-cli/ani-hsts
# 1096	ReooPAxPMsHM4KPMY	One Piece (1055 episodes)

# echo '1096	ReooPAxPMsHM4KPMY	One Piece (1055 episodes)' >> ~/.local/state/ani-cli/ani-hsts






exit 0 


## get anime names in ani-cli histoy
awk '{for (i = 3; i <= NF-2; i++) printf "%s ", $i; printf "\n"}' .local/state/ani-cli/ani-hsts |tr -cd '[:alnum:][:space:]\n ' |sed 's/[[:space:]]\+/ /g'
