# Sigmond appliance operator shell helpers — installed to /etc/profile.d/
# on both the Proxmox host and the decoder VM (rob 2026-07-30).
# tm() is rob's tmux session picker from the wsprdaemon project, verbatim.
# Bash-only (arrays, readarray): skip under dash/sh login shells.
if [ -n "$BASH_VERSION" ]; then

alias ll='ls -l'
alias lrt='ls -lrt'

### tmux alias
function tm() {
    local tm_arg=${1-}
    local tm_list=( $(tmux ls 2> /dev/null | awk -F : '{print $1}') )
    local tm_list_count=${#tm_list[@]}

    if [[ -z "${tm_arg}" ]]; then
        if [[ ${tm_list_count} -eq 0 ]]; then
            tmux
            return 0
        fi
        if [[ ${tm_list_count} -eq 1 ]]; then
            tmux a -t ${tm_list[0]}
            return 0
        fi
    fi

    printf "There are ${tm_list_count} active tmux sessions:\n"
    readarray -t tm_list <  <(tmux ls)
    local i
    for (( i = 0; i < ${#tm_list[@]}; ++i )); do
        local tm_session="${tm_list[${i}]}"
        printf "#%s\n" "${tm_session}"
    done
    if [[ "${tm_arg}" == "-l" ]]; then
        return 0
    fi
    local tm_default_id=$(echo "${tm_list[0]}"  | awk -F : '{print $1}')
    read -p "Select tmux session id # (default = ${tm_default_id})? => "
    if [[ -z "${REPLY}" ]]; then
        REPLY="${tm_default_id}"
    fi
    for (( i = 0; i < ${#tm_list[@]}; ++i )); do
        local tm_session="${tm_list[${i}]}"
        local tm_session_id=$( echo "${tm_session}" | awk -F : '{print $1}' )
        if [[ "${tm_session_id}" == "${REPLY}" ]]; then
            tmux a -t ${tm_session_id}
            return 0
        fi
    done
    echo "${REPLY} is not a valid id"
    return 0
}

fi
