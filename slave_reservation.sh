#!/bin/bash
export PS4='>> +(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

reservedFlag=0
readonly reservation_system_oulu_url='http://maccimaster.emea.nsn-net.net/res/request.php'
readonly yars_hangzhou_url='http://5gRobot180.srnhz.nsn-rdnet.net:8080/sctenv'

function _echo_slave_info_from_res_system() {
    local _data=$(wget -q --no-proxy --ignore-case "http://maccimaster.emea.nsn-net.net/res/list.php?name=$1&show=name,typename,reserved,offline,username,remaining,id,identifier" -O - |  sed -n '1!p' ) || true
    if [[ -n ${_data} ]]; then
        echo ${_data}
        return 1
    else
        echo "Not in reservation system"
        return 0
    fi
}

function _echo_reserved_from_slave_info() {
    echo $1 | cut -d\; -f4 || true
}

function _echo_offline_from_slave_info() {
    echo $1 | cut -d\; -f5 || true
}

function _echo_username_from_slave_info() {
    echo $1 | cut -d\; -f6 || true
}

_echo_remaining_from_slave_info()
{
    echo $1 | cut -d\; -f8
}

_echo_id_from_slave_info()
{
    echo $1 | cut -d\; -f1
}

_echo_identifier_from_slave_info()
{
    echo $1 | cut -d\; -f7
}

_echo_typename_from_slave_info()
{
    echo $1 | cut -d\; -f3
}

function _echo_tests_can_be_run_with_s() {
    local _test_host=$1
    local _reason=$2
    echo "Tests can be run with -s ${_test_host}, because ${_reason}."
}

function _echo_tests_cannot_be_run_with_s() {
    local _test_host=$1
    local _reason=$2
    echo "Tests cannot be run with -s ${_test_host}, because ${_reason}."
}

function _echo_please_reserve_slave() {
    echo "Please reserve slave from UI of reservation system. (http://maccimaster.emea.nsn-net.net/res)"
}

function _echo_free_slaves_of_type() {
    local _type=$1
    echo "List of free slaves of type ${_type}:"
    wget -q --no-proxy --ignore-case "http://maccimaster.emea.nsn-net.net/res/list.php?typename=${_type}&reserved=0&offline=0&show=host" -O - | sed -n '1!p' | tr -d ';'
}

_nbr_of_free_slaves_of_type()
{
    local type=$1
    echo $(wget -q --no-proxy --ignore-case "http://maccimaster.emea.nsn-net.net/res/list.php?typename=$type&reserved=0&offline=0&show=host" -O - | sed -n '1!p' | tr -d ';' | wc -l)
}

_echo_slave_with_identifier()
{
    local type=$1
    local previdentifier=$2
    echo $(wget -q --no-proxy --ignore-case "http://maccimaster.emea.nsn-net.net/res/list.php?typename=$type&identifier=${previdentifier:0:15}&show=name" -O - | sed -n '1!p' | tr -d ';')
}

function _check_if_test_can_be_run_with_s() {
    local _test_can_be_run=0
    local _test_host=$1
    local _in_res_system=0
    local _slave_info=$(_echo_slave_info_from_res_system ${_test_host}) || ${_in_res_system}=$?
    if [[ "${_in_res_system}" -eq 1 ]];then
        local _reserved=$(_echo_reserved_from_slave_info ${_slave_info})
        local _offline=$(_echo_offline_from_slave_info ${_slave_info})
        if [[ ${_offline} -eq 0 ]] && [[ ${_reserved} -eq 0 ]];then
            _echo_tests_cannot_be_run_with_s ${_test_host} "slave is free in reservation system"
            _echo_please_reserve_slave
        elif [[ ${_offline} == 1 ]] && [[ ${_reserved} == 0 ]] ; then
            _echo_tests_can_be_run_with_s ${_test_host} "slave is offline"
            _test_can_be_run=1
        elif [[ ${_reserved} == 1 ]] ; then
            local _username=$(_echo_username_from_slave_info ${_slave_info})
            _echo_tests_cannot_be_run_with_s ${_test_host} "slave is reserved: ${_username} != ${USER}"
            _echo_free_slaves_of_type $typename
        fi
    else
        _echo_tests_can_be_run_with_s ${_test_host} "slave is not in reservation system"
        _test_can_be_run=1
    fi
    return ${_test_can_be_run}
}

function _echo_name_of_test_slave_without_domain() {
    echo $1 | cut -d'.' -f1 || true
}

function _test_s_parameter_eligibility() {
    local _test_host=$(_echo_name_of_test_slave_without_domain $1)
    local _ret_value=0
    _check_if_test_can_be_run_with_s ${_test_host} || _ret_value=$?
    if [[ "${_ret_value}" -eq 1 ]]; then
        echo "Continuing."
    else
        echo "Exiting."
        exit 1
    fi
}

_slave_is_offline_or_not_in_res_system()
{
    local offline=0
    local test_host=$(_echo_name_of_test_slave_without_domain $1)
    slave_info=$(_echo_slave_info_from_res_system $test_host)
    local in_res_system=$?
    if [[ in_res_system -eq 1 ]]; then
        _echo_offline_from_slave_info $slave_info
    else
        echo 1
    fi
}

function _put_offline() {
    echo "Putting slave $1 offline with reason $2"
    if [[ $(_slave_is_offline_or_not_in_res_system $1) -eq 0 ]]; then
        wget -q --post-data "changeoffline=1&name=$1&offline=1&reason=$2" "${reservation_system_oulu_url}" -O - >/dev/null || true
    fi
}

_put_online()
{
    echo "Putting slave $1 online"
    wget -q --post-data "changeoffline=1&name=$1&offline=0" "${reservation_system_oulu_url}" -O - >/dev/null
}

_wait_until_offline()
{
    echo -n "Waiting until slave $1 is offline..."
    i=0
    slave_offline=0
    while [ $i -lt 720 ]; do
        if [[ $(_slave_is_offline_or_not_in_res_system $1) -eq 1 ]]; then
            slave_offline=1
            break
        fi
        let i+=1
        sleep 5
        echo -n "."
    done
    [ $slave_offline -eq 0 ] && echo "Failed, but continuing anyway."
    [ $slave_offline -eq 1 ] && echo "Done."
}

function reserve_testline() {
    # public function to reserve one testline
    local _target_site="$1"
    local _testline_pool_type="$2"
    local _duration="$3"
    local _priority="$4"
    local _variable_name_to_store_result="$5"
    local _session_id="$6"
    echo "${_session_id}"
    if [[ -z "${_session_id}" ]]; then
        echo "${_session_id} eq zero"
        _session_id="$(uuidgen)"
    fi

    local _testline_host=""
    echo "Trying to reserve one ${_testline_pool_type} testline in ${_target_site} for ${_duration} minutes with '${_priority}' priority"
    case "${_target_site}" in
        ouling)
            # reserve slave if needed
            if [[ "${_priority}" -gt 0 ]]; then
                echo "Lower priority queuing activated"
                local _dir_of_current_file="$(dirname "${BASH_SOURCE}")"
                python ${_dir_of_current_file}/../pool_priority_handler/src/pool_priority_handler.py "${_testline_pool_type}"
            fi
            while [[ -z "${_testline_host}" ]]; do
                local _query_result=$(wget -T 3 -q --post-data "user=${USER}&identifier=${_session_id:0:15}&duration=${_duration}&type=${_testline_pool_type}&request=1" "${reservation_system_oulu_url}" -O -) || true
                if [[ "${_query_result}" =~ "Host:"* ]]; then
                    _testline_host=$(echo ${_query_result} | cut -d" " -f2) || true
                elif [[ "${_query_result}" =~ .*no\ slaves\ available\ match.* ]]; then
                    echo "${_query_result}"
                    echo "Stopping..."
                    break
                elif [[ "${_query_result}" =~ ^Queued.* ]]; then
                    echo "${_query_result}"
                    sleep 10
                else
                    echo "${_query_result}"
                    break
                fi
            done;;
        hangzhou)
            echo "Reserving testline in Hangzhou..."
            local _ret_value=0
            python3 scripts/slaves/yars-client.py "${yars_hangzhou_url}" "${_testline_pool_type}" reserve ${_session_id} -u "${USER}" -t "${_duration}" || _ret_value=$?
            if [[ "${_ret_value}" -ne 0 ]]; then
                echo "Failed to reserve testline!!!"
                return 1
            fi
            _testline_host="$(cat yars-device.address)";;
        *)
            echo "ERROR: Unsupported target site '${_target_site}'"
            return 1;;
    esac
    if [[ -z "${_testline_host}" ]]; then
        echo "ERROR: Testline reservation failed!"
        return 1
    fi
    echo "Got ${_duration} minute reservation for testline: ${_testline_host}"
    echo "${_session_id}" > reservation.sessionid
    eval "${_variable_name_to_store_result}='${_testline_host}'"
}

function release_testline() {
    # public function to release testline
    local _target_site="$1"
    local _testline_pool_type="$2"
    local _release_timeout="$3"
    local _session_id="$4"

    case "${_target_site}" in
        ouling)
            echo "Testline will be released after ${_release_timeout} minutes"
            wget -T 3 -q --post-data "user=${USER}&identifier=${_session_id:0:15}&duration=${_release_timeout}&type=${_testline_pool_type}&request=1&result=${returnresult}" "${reservation_system_oulu_url}" -O - &>/dev/null;;
        hangzhou)
            echo "Releasing testline in Hangzhou..."
            local _ret_value=0
            python3 scripts/slaves/yars-client.py "${yars_hangzhou_url}" "${_testline_pool_type}" release ${_session_id} || _ret_value=$?
            if [[ "${_ret_value}" -ne 0 ]]; then
                echo "Failed to release testline!!!"
                return 1
            fi;;
        *)
            echo "ERROR: Unsupported target site '${_target_site}'"
            return 1;;
    esac
    rm -rf reservation.sessionid
}

if [[ "$0" == "${BASH_SOURCE}" ]]; then
    while getopts "i:r:f:c:w:-:" opt; do
        case "$opt" in
            r) reserve_testline ${OPTARG} $3 $4 "$5" result; exit;;
            f) release_testline ${OPTARG} $3 $4 $5; exit;;
            i) _slave_is_offline_or_not_in_res_system ${OPTARG}; exit;;
            c) _test_s_parameter_eligibility ${OPTARG}; exit;;
            w) _wait_until_offline ${OPTARG}; exit;;
            -)  case "${OPTARG}" in
                off) slave="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 )); reason="${!OPTIND}"; _put_offline ${slave} ${reason}; exit;;
                on) slave="${!OPTIND}"; _put_online ${slave}; exit;;
                esac
        esac
    done

    echo "Options:"
    echo " reserve         -r [ouling|wrling] [pool] [duration] [priority]"
    echo " release         -f [ouling|wrling] [pool] [release_timeout]"
    echo " is offline      -i [slave address]"
    echo " is available    -c [slave address]"
    echo " set offline          --off [slave address] [reason]"
    echo " set online           --on  [slave address]"
    echo " wait until offline   -w    [slave address]"
fi
