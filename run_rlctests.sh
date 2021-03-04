#!/usr/bin/env bash
#set -x
export PATH="/sbin:${PATH}"
script_folder_path="$(dirname $0)"
export PYTHONPATH=${script_folder_path}/libs:${script_folder_path}/libs/sct_utils:${script_folder_path}/libs/pm_counters:${script_folder_path}/libs/mac:${script_folder_path}/libs/profiling:$PYTHONPATH

# KEEP these flags to make less mistake in scripts
set -eEuo pipefail


# needed for compatibility between different bash shell versions
shopt -s compat31 2>/dev/null

##################################################
# source necessary files here
source "$(dirname "${BASH_SOURCE}")/scripts/slaves/slave_reservation.sh"
source "$(dirname "${BASH_SOURCE}")/scripts/slaves/slave_hw_template.sh"

##################################################
# function definitions started from here

function _interrupt_signal_handler() {
    set +eEo pipefail
    trap - HUP INT TERM PIPE EXIT ERR
    echo "Interrupt signal received, aborting..."
    if [[ "${is_runing_in_robot_pc}" -eq 1 ]]; then
        pkill -P $(echo $(jobs -pr) | sed 's: :,:g') 2>/dev/null || true
        exit 1
    fi
    case "${target_site}" in
        ouling)
            pkill -P $(echo $(jobs -pr) | sed 's: :,:g') 2>/dev/null || true
            if [[ "${SECTIONS}" -ne "1" ]]; then
                kill ${rsyncpid} || true
            fi
            if [[ -n "${testline_host}" ]]; then
                if [[ "${is_user_specified_testline}" -eq 0 ]]; then
                    ${SSH_COMMAND} ${lab_user_name}@${testline_host} "killall -SIGTERM sleep 1>/dev/null 2>/dev/null" || true
                    _release_reservation
                fi
                local _download_results="n"
                read -n1 -p "Do you want to download results from the aborted run? [y,n] " _download_results || true
                case "${_download_results}" in
                    y | Y)
                        echo -e "\nSyncing results down..."
                        ${SSH_COMMAND} ${lab_user_name}@${testline_host} "pkill -9 -f pybot" || true
                        local _ret_value=0
                        ${RSYNC} -e "${SSH_COMMAND}" -z ${lab_user_name}@${testline_host}:~/RobotTests/results/ results${RESULTSSUFFIX} || _ret_value=$?
                        if [[ "${_ret_value}" -ne "0" ]]; then
                            echo "Error in RSYNC (${lab_user_name}@${testline_host}:~/RobotTests/results/ to RobotTests/results${RESULTSSUFFIX})!"
                        fi
                        ${SSH_COMMAND} ${lab_user_name}@${testline_host} "killall -SIGTERM sleep 1>/dev/null 2>/dev/null" || true;;
                    n | N)
                        echo " Aborted";;
                    *);;
                esac
            fi;;
        hangzhou)
            pkill -P $(echo $(jobs -pr) | sed 's: :,:g') 2>/dev/null || true
            if [[ "${is_user_specified_testline}" -eq 0 ]]; then
                _release_reservation
            fi
            kill ${rsyncpid} || true;;
        *);;
    esac
    exit 1
}

function _set_and_load_env_config_file() {
    if [[ "${is_runing_in_robot_pc}" -eq 1 ]]; then
        env_config_file="dspbin/lib/ENV"
    else
        local _path_of_git_top_level="$(git rev-parse --show-toplevel 2>/dev/null)" || true
        if [[ -z "${_path_of_git_top_level}" ]]; then
            # assume we are in gnb/uplane/L2-HI/sct/RobotTests
            env_config_file="$(readlink -f "../../../../externals/integration/env/env-config.d/ENV")"
            labcraft_dir="$(readlink -f "../../../../externals/labcraft")"
        else
            env_config_file="${_path_of_git_top_level}/externals/integration/env/env-config.d/ENV"
            labcraft_dir="${_path_of_git_top_level}/externals/labcraft"
        fi
        labcraft_script="${labcraft_dir}/labcraft.sh"
    fi
    local _ret_value=0
    local "$(grep '^ENV_PS_REL=' "${env_config_file}")" || _ret_value=$?
    local "$(grep '^ENV_TRS=' ${env_config_file})" || _ret_value=$?
    local "$(grep '^ENV_RCP_BB3=' ${env_config_file})" || _ret_value=$?
    if [[ "${_ret_value}" -ne 0 ]]; then
        echo "ERROR: Cannot find ENV config file."
        return 1
    fi
    env_config_ps_rel="${ENV_PS_REL}"
    env_config_trs="${ENV_TRS}"
    env_config_rcp_bb3="${ENV_RCP_BB3}"
}

function _IS_THIS_DEPERCATED_check_and_copy_packages() {
    if [[ "${is_runing_in_robot_pc}" -eq 1 ]]; then
        return 0
    fi
    if [[ -e "${env_config_file}" ]]; then
        echo "ENV_PS_REL: ${env_config_ps_rel}"
        if [[ -n "${env_config_ps_rel}" ]]; then
            if [[ ! -e "/5g/tools/PS_REL/${env_config_ps_rel}.zip" ]]; then
                echo "/5g/tools/PS_REL/${env_config_ps_rel}.zip not found! Fetch it ..."
                # we trigger PS_REL__to__NFS job
                local url="https://ece-ci.dynamic.nsn-net.net/job/CI_TOOLS/job/ENV_SYNC/job/PS_REL__to__NFS/buildWithParameters?token=psupdate&PS_REL=${env_config_ps_rel}"
                wget -q --no-check-certificate ${url} || return 1
                echo "Now we have to wait round about 15 min for sync ..."
            fi
        fi
    fi
}

function _init_session_identifyer_used_by_5g_ci() {
    # NOTE: IDENTIFIER was seted by CI scripts as a enviroment variable
    # TODO: consider to use some option flags to set this value instead of an enviroment variable
    set +u
    if [[ -n "${IDENTIFIER}" ]]; then
        test_session_id="${IDENTIFIER}"
    fi
    set -u
}

function _check_or_set_testline_pool_type_in_oulu() {
    # Check user given pool type exists
    if [[ "${is_user_given_pool_type}" -eq 1 ]]; then
        local _pool_types=$(wget -q --ignore-case "http://maccimaster.emea.nsn-net.net/res/list.php?type=%" -O - | sed "/^#/d" | cut -d';' -f5 | sort | uniq) || true
        if [[ ! "${_pool_types}" =~ ${testline_pool_type} ]]; then
            echo "Testline pool type: '${testline_pool_type}' not found, check your --pool value"
            testline_pool_type="NotFound"
            return 1
        fi
    else
        case "${deployment_setting}" in
            l2abilsct5g)          testline_pool_type="5G_MASTER_ASIK";;
            l2sct_cloud_asik_abil_8cc)      testline_pool_type="5G_MASTER_ASIK";;
            l2sct_cloud_abil)     testline_pool_type="5G_MASTER_ASIK";;
            l2sct_classical)      testline_pool_type="5G_MASTER_ASIK"
                skip_rcp_upgrade=1
                skip_health_examination=1;;
            l2sct_classical_abil) testline_pool_type="5G_MASTER_ASIK";;
            l2sct_classical_abil_for_capa) testline_pool_type="5G_MASTER_ASIK";;
            l2sct_classical_asib) testline_pool_type="5G_MASTER_ASIB"
                skip_rcp_upgrade=1
                skip_health_examination=1;;
            *)
                testline_pool_type="NotFound"
                echo "ERROR: The deployment '${deployment_setting}' is not supported in Oulu."
                return 1;;
        esac
    fi
}

function _check_or_set_testline_pool_type_in_hangzhou() {
    if [[ "${is_user_given_pool_type}" -eq 1 ]]; then
        case "${deployment_setting}" in
            l2sct_classical)
                skip_rcp_upgrade=1
                skip_health_examination=1;;
            l2asodsct5g)
                skip_rcp_upgrade=1
                skip_health_examination=1;;
            l2sct_classical_asib)
                skip_rcp_upgrade=1
                skip_health_examination=1;;
            *)
                echo "This pool type need upgrade rcp";;
        esac
        # currently no check here
        echo "Using user given testline pool type: ${testline_pool_type}"
    else
        case "${deployment_setting}" in
            l2abilsct5g)          testline_pool_type="5G_MASTER_RCP_ASIK";;
            l2sct_cloud_asik_abil_8cc)      testline_pool_type="5G_MASTER_RCP_ASIK";;
            l2sct_cloud_abil)     testline_pool_type="5G_MASTER_RCP_ASIK";;
            l2asodsct5g)          testline_pool_type="5G_MASTER_ASOD"
                skip_rcp_upgrade=1
                skip_health_examination=1;;
            l2sct_classical)      testline_pool_type="5G_MASTER_ASIK"
                copy_all_packages_from_local=1
                skip_rcp_upgrade=1
                skip_health_examination=1;;
            l2sct_classical_abil) testline_pool_type="5G_MASTER_RCP_ASIK";;
            l2sct_classical_abil_for_capa) testline_pool_type="5G_MASTER_RCP_ASIK";;
            l2sct_classical_asib) testline_pool_type="5G_MASTER_ASIB"
                skip_rcp_upgrade=1
                skip_health_examination=1;;
            *)
                testline_pool_type="NotFound"
                echo "ERROR: The deployment '${deployment_setting}' is not supported in Hangzhou."
                return 1;;
        esac
    fi
}

function _check_and_set_target_site_and_testline_pool() {
    case "${target_site}" in
        ouling)
            # Wro and Oulu is using this option
            SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i dspbin/lib/id_rsa"
            lab_user_name="sct"
            _check_or_set_testline_pool_type_in_oulu || return $?;;
        hangzhou)
            SSH_COMMAND="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i dspbin/lib/id_rsa"
            lab_user_name="robotsct"
            _check_or_set_testline_pool_type_in_hangzhou || return $?;;
        *)
            echo "ERROR: The target site '${target_site}' is not found."
            return 1;;
    esac
    echo "=============================================================================="
    echo "Using Testline Pool Type '${testline_pool_type}'"
    return 0
}


function _release_reservation() {
    local _ret_value=0
    case "${target_site}" in
        ouling)
            if [ -z "${STARTTIME}" ]; then
                return 0
            fi
            ENDTIME=$(date +%s)
            if [[ "$(echo "( ${ENDTIME} - ${STARTTIME} ) / 60" | bc)" -ge "${reservation_duration}" ]]; then
                echo
                echo "    !!"
                echo "    !!    Reserved duration exceeded!"
                echo "    !!"
                echo "    !!    reserved: ${reservation_duration} minutes"
                echo "    !!      used  : $(echo -e "scale = 1\n( ${ENDTIME} - ${STARTTIME} ) / 60" | bc -l) minutes"
                echo "    !!"
                echo
            else
                release_testline "${target_site}" "${testline_pool_type}" "${reservation_release_timeout}" "${test_session_id}" || _ret_value=$?
            fi;;
        hangzhou)
            release_testline "${target_site}" "${testline_pool_type}" "${reservation_release_timeout}" "${test_session_id}" || _ret_value=$?;;
        *)
            echo "ERROR: Unknown target site '${target_site}' to release reservation";;
    esac
    if [[ "${_ret_value}" -ne 0 ]]; then
        echo "WARNING: Reservation release failed. (${_ret_value})"
    fi
}

function _print_help_message() {
    local _script_name="$(basename "$0")"

    echo "Run L2HI L2LO MCT tests with output redirected to results folder."
    echo
    echo "Usage: ${_script_name} <options> [...]"
    echo "  -h,--help             display this help message then quit"
    echo "  -p,--pybot-options <op>  define pybot options"
    echo "  -I,--session-id <id>  test session id to be used by reservation system"
    echo "                        default value is a generated UUID"
    echo "  -s <testline>         using given testline instead of reserving one from pool"
    echo "  -t <duration>[:timeout]  use given reservation duration and release timeout in"
    echo "                        minutes (default: duration ${reservation_duration} m, timeout ${reservation_release_timeout} m)"
    echo "  -c,--no-colors        disable colors in console output"
    echo "  -C,--copy-all-packages-from-local  copy all packages from local to"
    echo "                        Robot PC"
    echo "  -k,--keep-passed-log  keep passed keywords content in Robot log when using"
    echo "                        preset"
    echo "  -l,--keep-for-loop-log  keep FOR loop log in Robot report"
    echo "  -P,--profiling        enable Robot script profiling"
    echo "  -b,--no-journal-log   disable gathering of full journal and linux logs in the"
    echo "                        end of suite for faster execution speed"
    echo "  -u,--skip-deployment  skip binary deployment procedure"
    echo "  -d,--deployment <deployment>  set deployment (mandatory)"
    echo "  -q,--quit-when-failure  quit test when failure occurred"
    echo "  -x,--preset <preset>  using test preset, default is 'shock'"
    echo "  -a,--archive-results  archive test results"
    echo "  -R,--random-order     ran cases in random order"
    echo "  --pool <type>         execute tests in testline from user defined reservation"
    echo "                        pool type"
    echo "  --prio <prio>         reserve testline using priority"
    echo "  --rerunfailed         rerun all the failed tests (target env only)"
    echo "  --no-execution-time-guard  do not use maximum execution time guard"
    echo "  --force-rcp-upgrade   force upgrade RCP whether the version are same or not between source and target"
    echo "  --skip-rcp-upgrade    skip RCP upgrade and labcraft.sh"
    echo "  --skip-health-examination   skip RCP syscom connect detection"
    echo "  -g,--site <site>      specify which site to run the test, default: ouling"
    echo ""
    echo "Sites:"
    echo "  o  ouling (default)"
    echo "  hz hangzhou"
    echo ""
    echo "Deployments:"
    echo "  l2abilsct5g"
    echo "  l2sct_cloud_asik_abil_8cc"
    echo "  l2asodsct5g"
    echo "  l2abicsct5g"
    echo "  l2sct_cloud_abil"
    echo "  l2sct_classical"
    echo "  l2sct_classical_abil"
    echo "  l2sct_classical_abil_for_capa"
    echo "  l2sct_classical_asib"
    echo "  l2sct_classical_abic"
    echo ""
    echo "Presets:"
    echo "  shock, capameas, maxcapa, trsl2hiinterface, capashock"
    echo
    echo "Examples:"
    echo "  ${_script_name} -d l2abilsct5g -x shock -p \"-L TRACE -v l2trace:2 --exclude Unstable\" -l -c --rerunfailed"
    echo "  ${_script_name} -d l2sct_classical -g hz -p \"-L TRACE -v l2trace:2 --exclude Unstable\" -l -c --rerunfailed"
    echo ""
    echo "Flags used by 5G CI"
    echo "  -U                    try to use a new testline different from last run"
    echo ""
    echo "Environment variables used by 5G CI"
    echo "  IDENTIFIER            test session id"
    echo ""
    echo "Flags that might not functioning or may not tend to be used anymore"
    echo "  -G                    run l2 onhost at gdb"
    echo "  -T,--repeat           repeat tests for given duration (specified with -t)"
    echo "  -F,--until-fail       repeat tests until failure for given duration"
    echo "  --dryrun              run test case syntax check for Robot tests."
    echo "  -R                    randomize suite and test order"
    echo "  -S                    define amount of sections to execute tests in parallel"
    echo "                        (possible values: 2 - 7, fixed or fixed:section<x>"
    echo "                        (executes user given section as section1. Example:"
    echo "                        fixed:section02))"
    echo "  --selftest            run series of chrarcterization tests to see if this"
    echo "                        script still does what we presume"
    echo "  --testlist            runs testlist checker to verify that testcommands in"
    echo "                        target testlists are actually found from correct folders"
    echo "                        and suites with correct test case names in suites"
    echo "  --forceofflinecheck   offline check by default only for presets (-x)"
    echo
}

function _print_robot_version() {
    local _robot_version=$(/usr/local/bin/pybot --version) || true
    echo "Using Robot version: ${_robot_version}"
}

function _take_testline_offline_if_needed() {
    local _all_tests_failed=$(grep -E '<stat fail="[2-9]+" pass="0">All Tests</stat>' ${script_folder_path}/results/output.xml | wc -l) || true
    local _some_tests_failed=$(grep -E '<stat fail="[1-9]+" pass="[1-9]+">All Tests</stat>' ${script_folder_path}/results/output.xml | wc -l) || true
    local _only_one_test_and_it_failed=$(grep -E '<stat fail="1" pass="0">All Tests</stat>' ${script_folder_path}/results/output.xml | wc -l) || true
    if [[ "${_all_tests_failed}" -ne 0 ]]; then
        local _hostname=$(hostname)
        local _offlinetext="CI: All tests failed"
        _put_offline "${_hostname}" "${_offlinetext}"
    elif [[ "${_some_tests_failed}" -ne "0" || "${_only_one_test_and_it_failed}" -ne "0" ]]; then
        local _ret_value=0
        _check_testline_connection || _ret_value=$?
        if [[ "${_all_tests_failed}" -ne "0" && ${USER} == *"_"* ]]; then
            _put_slave_offline ${_ret_value}
        elif [[ "${_all_tests_failed}" -ne "0" && ${_ret_value} -ne "0" ]];then
            _put_slave_offline ${_ret_value}
        fi
    fi
}

function _check_testline_connection() {
    local _ret_value=0
    if [[ "${target_site}" == ouling ]]; then
        _check_gnb_ssh_connection "${testline_pool_type}" || _ret_value=$?
    else
        echo "ERROR: Undefined behaviour"
    fi
    return ${_ret_value}
}

function _check_gnb_ssh_connection() {
    local _max_try_count=5
    local _ret_value=1
    echo "Checking GNB SSH connection for testline offlining purpose:"
    for i in $(seq 1 ${_max_try_count}); do
        if [[ "${_ret_value}" -ne 0 ]]; then
            echo "$i(${_max_try_count})"
            _ret_value=0
            ${SSH_COMMAND_toor4nsn} -i /home/sct/.ssh/id_rsa_toor4nsn toor4nsn@${AXM_IP_LRC} "echo 2>&1" || _ret_value=$?
            if [[ "${_ret_value}" -eq 0 ]]; then
                echo "SSH connection OK"
                break
                sleep 3
            fi
        fi
    done
    return ${_ret_value}
}

function _put_slave_offline() {
    local hw_conn_not_ok=$1
    if [[ "${target_site}" == "ouling" && "$hw_conn_not_ok" -ne 0 ]]; then
        local _hostname=$(hostname)
        local _offlinetext="default value"
        _offlinetext="CI: Tests and ssh axm con. failed"
        _put_offline "${_hostname}" "${_offlinetext}"
    fi
}

function _testlist_check() {
    local tmp1=$1[@]
    local tmp2=$2[@]
    local _targets=(${!tmp1})
    local _presetLists=(${!tmp2})
    _presetNameExt=$3
    for _target in "${_targets[@]}"
    do
        for _preset in "${_presetLists[@]}"
        do
            echo "TESTLIST_CHECKER STARTS for TARGET: $_target PRESET: $_preset D=$D"
            python "$D"/scripts/testlist_checker/src/testlist_checker.py "$D"/targets/"$_target"/"$_preset""$_presetNameExt".txt $_preset || true
            echo "TESTLIST_CHECKER ENDS for TARGET: $_target PRESET: $_preset "
        done
    done
}

function _run_testlist_checker_common() {
    local targets=(Common)
    local presetLists=(L2regressionCommon L2shockCommon)
    _testlist_check targets presetLists ""
}

function _run_testlist_checker_non_common() {
    local targets=(l2sct6 l2sct6_3p l2sct4_rl70 l2sct_fzm l2sctarm_pair fsm4sct fsm4sct_6p lionfish_ase)
    local presetLists=(shock regression nightly capacity capacitypool capacitylimited profiling automatedlimits capashock trsl2hiinterface capagoal capagoalpool temp multipool)
    _testlist_check targets presetLists "list"
}

function _run_testlist_checker() {
    if [[ ("$TESTLIST_CHECKER" -eq "1") ]]; then
        D="$(dirname $0)"
        _run_testlist_checker_common
        _run_testlist_checker_non_common
    fi
}

function _set_robot_rebot_options() {
    if [[ "${keep_for_loops_in_robot_log}" -eq 1 ]]; then
        echo "Keeping loops in output.xml, report generation may take some time"
    else
        echo "Removing steps from FOR loops and Wait Until Keyword Succeeds-loops"
        REBOT_OPTIONS="--removekeywords for --removekeywords wuks"
    fi
    if [[ "${remove_passed_robot_log_when_using_preset}" -eq 1 && "${keep_for_loops_in_robot_log}" -eq 0 ]]; then
        echo "Removing content of passed keywords"
        REBOT_OPTIONS="$REBOT_OPTIONS --removekeywords passed"
    else
        echo "Keeping content of passed keywords"
    fi
}

function _check_dspbin_symlinks() {
    find -L dspbin/ -type l | while read -r file; do echo -e "symlink error: $file is orphaned" >> symlink_error; done
    if [ -e symlink_error ]; then cat symlink_error; rm symlink_error && exit 1; fi
}

function _set_COV_if_kcov_available() {
    if [[ $1 == *"cov" ]]; then
        if hash kcov; then
            export COV=kcov
        else
            echo
            echo "Heard you would like to have a coverage, there is no kcov on your path."
            echo "Go to https://github.com/SimonKagstrom/kcov - compile, install and come back."
            echo
            exit 1
        fi
    fi
}

function _merge_coverage_if_collected() {
    if [ -n "$COV" ]; then
        echo "Merged coverage: $(dirname $0)/libs/t/cov/index.html"
        kcov --merge $(dirname $0)/libs/t/cov $(dirname $0)/libs/t/cov-*
    fi
}

function _run_selftest() {
    source /build/home/pyv/pySct1/bin/activate
    _set_COV_if_kcov_available $1

    local _ret=0
    cram $CRAMARGS $(dirname $0)/libs/t || _ret=$?

    _merge_coverage_if_collected
    deactivate
    exit ${_ret}
}

function _parse_flag() {
    local _flag="$1"
    local _value="$2"

    options_shift_amount=1
    case "${_flag}" in
        -h | --help)
            return 1;;
        -p | --pybot-options)
            user_given_pybot_options+=" ${_value}"
            generated_pybot_options="${_value} ${generated_pybot_options}"
            options_shift_amount=2;;
        -I | --session-id)
            test_session_id="${_value}"
            options_shift_amount=2;;
        -U)
            # this flag should only work in CI env
            set +u
            if [[ -n "${IDENTIFIER}" ]]; then
                ci_5g_try_use_different_testline=1
            fi
            command_line_params+=" -U"
            set -u;;
        -s)
            testline_host=$(echo ${_value})
            is_user_specified_testline=1
            options_shift_amount=2;;
        -t)
            local _have_colon=$(echo "${_value}" | grep -c ':') || true
            if [[ "${_have_colon}" -eq 0 ]]; then
                reservation_duration=$(echo ${_value})
            else
                reservation_duration=$(echo ${_value} | cut -d: -f1) || true
                reservation_release_timeout=$(echo ${_value} | cut -d: -f2) || true
            fi
            command_line_params+=" -t ${_value}"
            options_shift_amount=2;;
        -c | --no-colors)
            show_colors="off"
            command_line_params+=" --no-colors";;
        -C | --copy-all-packages-from-local)
            copy_all_packages_from_local=1
            command_line_params+=" --copy-all-packages-from-local";;
        -k | --keep-passed-log)
            remove_passed_robot_log_when_using_preset=0
            command_line_params+=" --keep-passed-log";;
        -l | --keep-for-loop-log)
            keep_for_loops_in_robot_log=1
            command_line_params+=" --keep-for-loop-log";;
        -P | --profiling)
            profiling_enabled=1
            profiling_setting="Perf"
            command_line_params+=" --profiling";;
        -G)
            export L2_IN_GDB='True';;
        -b | --no-journal-log)
            robot_full_log_gethering_disabled=1
            command_line_params+=" --no-journal-log";;
        -u | --skip-deployment)
            skip_deployment=1
            command_line_params+=" --skip-deployment";;
        -d | --deployment)
            deployment_setting="${_value}"
            command_line_params+=" --deployment ${_value}"
            options_shift_amount=2;;
        --skip-rcp-upgrade)
            skip_rcp_upgrade=1;;
        --force-rcp-upgrade)
            force_rcp_upgrade=1;;
        --skip-health-examination)
            skip_health_examination=1;;
        --skip-testing)
            skip_testing=1
            command_line_params+=" --skip-testing";;
        -q | --quit-when-failure)
            quit_test_when_failure=1
            command_line_params+=" --quit-when-failure";;
        -x | --preset)
            # Note: 5G CI uses the following presets: shock, capameas, maxcapa, trsl2hiinterface,
            #       capashock
            case "${_value}" in
                shock)            reservation_duration=60;;
                capameas)         reservation_duration=90;;
                maxcapa)          reservation_duration=90;;
                trsl2hiinterface) reservation_duration=20;;
                capashock)        reservation_duration=3;;
                *)
                    echo "ERROR: Unsupported preset: ${_value}"
                    return 1;;
            esac
            test_preset_setting="${_value}"
            if [[ ${command_line_params} != *--keep-passed-log* ]]; then
                remove_passed_robot_log_when_using_preset=1
            fi
            command_line_params+=" --preset ${_value}"
            options_shift_amount=2;;
        -a | --archive-results)
            archive_results=1;;
        -R | --random-order)
            run_cases_in_random_order=1
            command_line_params+=" --random-order";;
        -T | --repeat)
            repeat_the_test=1
            execution_time_guard_enabled=0
            command_line_params+=" --repeat";;
        -F | --until-fail)
            repeat_until_fail=1
            repeat_the_test=1
            execution_time_guard_enabled=0
            command_line_params+=" --until-fail";;
        -S)
            if [ -f "$(dirname $0)/${_value}" ]; then
                test_preset_setting=""
                SECTIONS=1
                SECTIONINDEX=$(echo ${_value} | sed 's:[^0-9]*::g')
                IDENTIFIER="$IDENTIFIER-$SECTIONINDEX"
                RESULTSSUFFIX="-$SECTIONINDEX"
                command_line_params+=" -S ${_value}"
                generated_pybot_options="-v SECTIONED:True --name ${_value} -A ${_value} ${generated_pybot_options}"
                if [[ ${generated_pybot_options} != *$TESTSDIR* ]]; then
                    generated_pybot_options="${generated_pybot_options} $TESTSDIR"
                fi
            else
                SECTIONS=${_value}
                if [ "${_value}" = "fixed" ]; then
                    FIXED=1
                elif [[ ${_value} == *":section"* ]]; then
                    FIXED=1
                    FIXED_PARAMS=${_value}
                    SECTIONS="fixed"
                fi
                SECTIONED="1"
            fi
            options_shift_amount=2;;
        -g | --site)
            case "${_value}" in
                o | ouling)
                    target_site="ouling"
                    command_line_params+=" --site o";;
                hz | hangzhou)
                    target_site="hangzhou"
                    command_line_params+=" --site hz";;
                *)
                    echo "ERROR: Unknown target site '${_value}'"
                    return 1;;
            esac
            options_shift_amount=2;;
        --pool)
            testline_pool_type="${_value}"
            is_user_given_pool_type=1
            command_line_params+=" --pool ${_value}"
            options_shift_amount=2;;
        --prio)
            reservation_priority=$(echo ${_value})
            options_shift_amount=2;;
        --rerunfailed)
            command_line_params+=" --rerunfailed"
            rerun_failed_tests=1;;
        --forceofflinecheck)
            FORCE_OFFLINE_CHECK=1
            command_line_params+=" --forceofflinecheck";;
        --dryrun)
            DRY_RUN="1"
            command_line_params+=" --dryrun";;
        --selftest*)
            _run_selftest ${_flag};;
        --testlist*)
            command_line_params+=" --testlist"
            TESTLIST_CHECKER=1;;
        --no-execution-time-guard)
            execution_time_guard_enabled=0
            command_line_params+=" --no-execution-time-guard";;
        --gtpdatagen)
            GTPDATAGEN_ADDRESS=${_value}
            command_line_params+=" --gtpdatagen ${_value}"
            options_shift_amount=2;;
        --gtpdatagenul)
            GTPDATAGEN_UL_ADDRESS=${_value}
            command_line_params+=" --gtpdatagenul ${_value}"
            options_shift_amount=2;;
        --msgseqdriver)
            MESSAGE_SEQUENCE_DRIVER_ADDRESS=${_value}
            command_line_params+=" --msgseqdriver ${_value}"
            options_shift_amount=2;;
        *)
            echo "ERROR: Unknown flag '${_flag}'"
            return 1;;
    esac
}

function _sync_files_to_robot_pc() {
    local _testline_host="$1"

    local _testline_not_pingable=1

    echo -n "Checking $_testline_host machine availability"
    while (($_testline_not_pingable == 1))
    do
       if ping -c 3 $_testline_host > /dev/null
       then
           echo $'\nRobot machine is online!'
           _testline_not_pingable=0
       else
           echo -n "."
       fi
    done

    echo "Sync files up"
    local _ret_value=0
    $RSYNC $RSYNCUPEXCLUDE -e "$SSH_COMMAND" -z . $lab_user_name@${_testline_host}:~/RobotTests || _ret_value=$?
    if [[ "${_ret_value}" -eq 0 ]]; then
        echo "Done."
    else
        echo "ERROR: Failed to sync files up to Robot PC"
        return 1
    fi
}

function _check_and_prepare_target_site_and_deployment() {
    _check_and_set_target_site_and_testline_pool || return $?
    case "${deployment_setting}" in
        l2sct_classical) echo "Deployment: Classical BTS with ASIK and ABIL"
            USE_ASIK=1; USE_ABIL=1
            TARGET="l2sct_classical_asik_abil"; TESTSDIR="l2tests"
            DEPLOYMENT="L2_ON_CLASSICAL_ASIK_ABIL"; L2_DEPLOYMENT="L2SCT"
            pybot_options_deployment_related="-v REL:Classical"; REL="CLASSICAL_AF"; ECL_FILENAME="ECL"
            pybot_essential="-v L2DEPL:3 -v DEPL:L2_ON_CLASSICAL -v UESIM1_NODEID:0x102a"
            pybot_essential+=" -v RCP_SYSCOM_IP:192.168.255.1 -v L2SCT_DEPLOYMENT:dummy";;
        l2sct_classical_abil) echo "Deployment: Classical BTS with L2-HI and L2-RT deployed in ABIL"
            USE_ASIK=0; USE_ABIL=1
            TARGET="l2sct_classical_abil"; TESTSDIR="l2tests"
            DEPLOYMENT="L2_ON_CLASSICAL_ABIL"; L2_DEPLOYMENT="L2SCT"
            pybot_options_deployment_related="-v REL:Classical"; REL="CLASSICAL_ABIL"; ECL_FILENAME="ECL"
            pybot_essential="-v L2DEPL:3 -v DEPL:L2_ON_CLASSICAL -v UESIM1_NODEID:0x123a"
            pybot_essential+=" -v RCP_SYSCOM_IP:192.168.255.1 -v L2SCT_DEPLOYMENT:${deployment_setting}";;
        l2sct_classical_abil_for_capa) echo "Deployment: Classical BTS with bts L2 deploy on ABIL1 and uesim L2 deploy on ABIL2"
            USE_ASIK=0; USE_ABIL=1
            TARGET="l2sct_classical_abil"; TESTSDIR="l2tests"
            DEPLOYMENT="L2_ON_CLASSICAL_ABIL_FOR_CAPA"; L2_DEPLOYMENT="L2SCT"
            pybot_options_deployment_related="-v REL:Classical"; REL="CLASSICAL_ABIL_FOR_CAPA"; ECL_FILENAME="ECL"
            pybot_essential="-v L2DEPL:3 -v DEPL:L2_ON_CLASSICAL -v UESIM1_NODEID:0x123a"
            pybot_essential+=" -v RCP_SYSCOM_IP:192.168.255.1 -v L2SCT_DEPLOYMENT:${deployment_setting}";;
        l2sct_classical_asib) echo "Deployment: Classical BTS with ASIB"
            USE_ASIB=1; USE_ABIL=1
            TARGET="l2sct_classical_asib"; TESTSDIR="l2tests"
            DEPLOYMENT="L2_ON_CLASSICAL_ASIB"; L2_DEPLOYMENT="L2SCT"
            pybot_options_deployment_related="-v REL:Classical"; REL="CLASSICAL_ASIB"; ECL_FILENAME="ECL"
            pybot_essential="-v L2DEPL:3 -v DEPL:L2_ON_CLASSICAL -v UESIM1_NODEID:0x123a"
            pybot_essential+=" -v RCP_SYSCOM_IP:192.168.255.1 -v L2SCT_DEPLOYMENT:${deployment_setting}";;
        l2sct_classical_abic) echo "Deployment: Classical BTS with L2-HI and L2-LO deployed in ABIC"
            TARGET="l2sct_classical_abic"; TESTSDIR="l2tests"
            DEPLOYMENT="L2_ON_CLASSICAL_ABIC"; L2_DEPLOYMENT="L2SCT"
            pybot_options_deployment_related="-v REL:Classical"; REL="CLASSICAL_ABIC"; ECL_FILENAME="ECL"
            pybot_essential="-v L2DEPL:3 -v DEPL:L2_ON_CLASSICAL -v UESIM1_NODEID:0x124a"
            pybot_essential+=" -v RCP_SYSCOM_IP:192.168.255.1 -v L2SCT_DEPLOYMENT:dummy";;
        l2sct_cloud_abil) echo "Deployment: Cloud BTS with Airframe and ABIL, L2HI Du running in ABIL master, L2RT in ABIL slave"
            USE_ASIK=0; USE_ABIL=1
            TARGET="l2sct_cloud_abil"; TESTSDIR="l2tests"
            DEPLOYMENT="L2_ON_CLOUD_ABIL"; L2_DEPLOYMENT="L2SCT"
            pybot_options_deployment_related="-v REL:CLOUD_AF"; REL="CLOUD_AF"; ECL_FILENAME="ECL"
            pybot_essential+=" -v site:${target_site} -v numOfRAPs:1"
            pybot_essential+=" -v L2SCT_DEPLOYMENT:${deployment_setting}";;
        l2abilsct5g) echo "Deployment: Cloud BTS with Airframe, ASIK and ABIL"
            USE_ASIK=1; USE_ABIL=1
            TARGET="l2abilsct"; TESTSDIR="l2tests"
            DEPLOYMENT="L2_ON_CLOUD_ASIK_ABIL"; L2_DEPLOYMENT="L2SCT"
            pybot_options_deployment_related="-v REL:CLOUD_AF"; REL="CLOUD_AF"; ECL_FILENAME="ECL"
            pybot_essential+=" -v site:${target_site} -v numOfRAPs:1 -v L2SCT_DEPLOYMENT:${deployment_setting}";;
        l2sct_cloud_asik_abil_8cc) echo "Deployment: Cloud BTS with Airframe, ASIK and ABIL for 8cc"
            USE_ASIK=1; USE_ABIL=1
            TARGET="l2sct_cloud_asik_abil_8cc"; TESTSDIR="l2tests"
            DEPLOYMENT="L2_ON_CLOUD_ASIK_ABIL_8CC"; L2_DEPLOYMENT="L2SCT"
            pybot_options_deployment_related="-v REL:CLOUD_AF"; REL="CLOUD_AF"; ECL_FILENAME="ECL"
            pybot_essential+=" -v site:${target_site} -v numOfRAPs:1 -v L2SCT_DEPLOYMENT:${deployment_setting}";;
        l2asodsct5g) echo "Deployment: Cloud BTS with Airframe and ASOD"
            USE_ASOD=1
            TARGET="l2asodsct"; TESTSDIR="l2tests"
            DEPLOYMENT="L2_ON_CLOUD_ASOD"; L2_DEPLOYMENT="L2SCT"
            pybot_options_deployment_related="-v REL:CLOUD_AF"; REL="CLOUD_AF"; ECL_FILENAME="ECL"
            pybot_essential+=" -v site:${target_site} -v numOfRAPs:1 -v L2SCT_DEPLOYMENT:dummy";;
        l2abicsct5g) echo "Deployment: Cloud BTS with L2-HI and L2-LO deployed in ABIC"
            TARGET="l2abicsct"; TESTSDIR="l2tests"
            DEPLOYMENT="L2_ON_CLOUD_ABIC"; L2_DEPLOYMENT="L2SCT"
            pybot_options_deployment_related="-v REL:CLOUD_AF"; REL="CLOUD_AF"; ECL_FILENAME="ECL"
            pybot_essential="-v L2DEPL:3 -v DEPL:"L2_ON_CLASSICAL" -v UESIM1_NODEID:0x124a"
            pybot_essential+=" -v RCP_SYSCOM_IP:192.168.255.1 -v L2SCT_DEPLOYMENT:dummy";;
        *)
            echo "ERROR: Unknown deployment: ${deployment_setting}"
            return 1;;
    esac
    if [[ "${SECTIONED}" == "1" ]]; then
        if [[ ${generated_pybot_options} != *${TESTSDIR}* ]]; then
            generated_pybot_options="${generated_pybot_options} ${TESTSDIR}"
        fi
    fi
}

function _check_and_set_if_running_in_target_pc() {
    is_runing_in_robot_pc=0
    if [[ -f "${HOME}/.is_robot_pc" ]]; then
        is_runing_in_robot_pc=1
    else
        #! DEPRECATED: DO NOT use this method to check target pc. It will be removed later.
        is_runing_in_robot_pc=$([[ ${USER} == "sct" || ${USER} == "root" || ${USER} == "ute" ]] && echo 1 || echo 0)
        if [[ "${is_runing_in_robot_pc}" -eq 1 ]]; then
            echo    "####################"
            echo    "#     WARNING      #"
            echo    "####################"
            echo    "MCT_HI_LO ROBOT PC IMPROVEMENT"
            echo -n "Please use the new method, create a hidden file called '.is_robot_pc' in the home folder '${HOME}', to "
            echo    "indicate it is the target PC. It is not a good practice to use the username as the identification."
            echo    "####################"
        fi
    fi
}

function _is_valid_ip_address() {
    local _ip=$1
    local _stat=1
    if [[ ${_ip} =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local _old_ifs="$IFS"
        IFS='.'
        local _ip_segments=(${_ip})
        IFS="${_old_ifs}"
        if [[ ${_ip_segments[0]} -le 255 && ${_ip_segments[1]} -le 255 \
            && ${_ip_segments[2]} -le 255 && ${_ip_segments[3]} -le 255 ]]; then
            _stat=0
        else
            _stat=1
        fi
    fi
    return ${_stat}
}

function _log_testline_information() {
    local _testline_host=$1
    if _is_valid_ip_address "${_testline_host}"; then
        local _robot_name="${_testline_host}"
    else
        local _robot_name=$(echo ${_testline_host} | cut -d "." -f1) || true
    fi
    printf "robot:${_robot_name}\n" > platform_info.log
    cat platform_info.log
}

function _update_testline_info_in_reservation_system() {
    local _ps_rel=$1
    local _testline_host=$2
    local _robot_name=""
    _robot_name=$(echo ${_testline_host} | cut -d "." -f1) || true
    echo "[DEBUG] labhost: $2 $_testline_host"
    # Update platform info to reservation systelm only if we got platform info from robot machine!
    # If got it's in RobotTests/results which is rsynced, locally used file is in RobotTests!
    if [[ -f results/platform_info.log ]]; then
        echo "[DEBUG] Received platform info in results"
        cat results/platform_info.log
        cp results/platform_info.log platform_info.log
        printf "robot:${_robot_name}\n" >> platform_info.log
        local _rcp_version=$(cat platform_info.log | grep 'BTS RCP version:' | cut -d ':' -f2 ) || true
        echo "Updating robot machine's software information on maccimaster..."
        local _ret=$(wget -q --post-data "changeversion=1&version=${_ps_rel}, ${_rcp_version}&name=${_robot_name}" http://maccimaster.emea.nsn-net.net/res/request.php -O -) || true
        echo ${_ret}
    else
        # In error situations we might want to have platform info even it's not updated to reservation system!
        echo "[DEBUG] platform info not available in results, check it from $_robot_name /tmp/platform_info.log"
        $SSH_COMMAND $lab_user_name@$_testline_host "cat /tmp/platform_info.log" > platform_info.log || true
        printf "robot:${_robot_name}\n" >> platform_info.log
        cat platform_info.log
    fi
}

function _archive_test_results() {
    local _archive_folder="archive"
    mkdir -p "${_archive_folder}"
    if [[ ! -d "results" ]]; then
        echo "No results were found."
        return 1
    fi
    local _verdict=""
    if [[ -f "results/retval.txt" ]]; then
        local _ret_value=$(cat results/retval.txt) || true
        if [[ "${_ret_value}" -eq 0 ]]; then
            _verdict="pass"
        else
            _verdict="fail_${_ret_value}"
        fi
    fi
    local _preset_name=""
    if [[ -n "${test_preset_setting}" ]]; then
        _preset_name="_${test_preset_setting}"
    fi
    local _timestamp="$(date +%Y%m%d-%H%M%S)"
    local _filename="${_timestamp}_${deployment_setting}${_preset_name}_${_verdict}.zip"
    echo -n "Archiving test results to ${_archive_folder}/${_filename} ..."
    local _ret_value=0
    cd results
    zip -rq9 "../${_archive_folder}/${_filename}" * || _ret_value=$?
    cd ..
    if [[ "${_ret_value}" -eq 0 ]]; then
        echo " done"
    else
        echo " failed"
    fi
}

function _init_options_settings() {
    reservation_duration="38" # minutes
    is_user_given_pool_type=0
    testline_pool_type="Robot"
    pybot_essential="-v UPLOAD_BINS_TO_MCU:True -v RESET_DSPS:True"
    deployment_setting=""
    copy_all_packages_from_local=0
    target_site="ouling" # default running target site
    rerun_failed_tests=0
    command_line_params=""
    ci_5g_try_use_different_testline=0
    reservation_release_timeout="1" # minutes
    test_session_id="$(uuidgen)"
    generated_pybot_options=""
    pybot_options_deployment_related=""
    user_given_pybot_options=""
    is_user_specified_testline=0
    testline_host=""
    show_colors="on"
    remove_passed_robot_log_when_using_preset=0
    keep_for_loops_in_robot_log=0
    profiling_setting=""
    robot_full_log_gethering_disabled=0
    quit_test_when_failure=0
    test_preset_setting=""
    archive_results=0
    run_cases_in_random_order=0
    profiling_enabled=0
    repeat_the_test=0
    execution_time_guard_enabled=1
    repeat_until_fail=0
    reservation_priority=""
    skip_rcp_upgrade=0
    force_rcp_upgrade=0
    skip_health_examination=0
    skip_deployment=0
    skip_testing=0
}

function _build_pybot_options_seted_by_flags() {
    pybot_options_seted_by_flags=""
    pybot_options_seted_by_flags+=" --monitorcolors ${show_colors} -v colors:${show_colors}"
    if [[ -n "${test_preset_setting}" ]]; then
        pybot_options_seted_by_flags+=" -v PRESET_TYPE:${test_preset_setting}"
    else
        pybot_options_seted_by_flags+=" -v PRESET_TYPE:None"
    fi
    pybot_options_seted_by_flags+=" -v ENABLE_PERF:${profiling_enabled}"
    pybot_options_seted_by_flags+=" -v BYPASS_FULL_LOGS:${robot_full_log_gethering_disabled}"
    if [[ -n "${profiling_setting}"            ]]; then pybot_options_seted_by_flags+=" -v PROFILING:${profiling_setting}"; fi
    if [[ "${run_cases_in_random_order}" -eq 1 ]]; then pybot_options_seted_by_flags+=" --runmode Random:All"; fi
    if [[ "${quit_test_when_failure}" -eq 1    ]]; then pybot_options_seted_by_flags+=" --exitonfailure"; fi
}

readonly _ssh_opt="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=10"

function _sync_abil_log_to_asik() {
    mkdir -p /ram/ABIL/master /ram/ABIL/slave
    bsh 1:0 "journalctl -b > /tmp/journal.log"
    bsh 1:1 "journalctl -b > /tmp/journal.log"
    scp ${_ssh_opt} -i .ssh/id_rsa_toor4nsn toor4nsn@192.168.253.20:/tmp/*.log* /ram/ABIL/master/ 2>/dev/null
    scp ${_ssh_opt} -i .ssh/id_rsa_toor4nsn toor4nsn@192.168.253.21:/tmp/*.log* /ram/ABIL/slave/ 2>/dev/null
}

readonly _sync_abil_log_to_asik_script=$(type _sync_abil_log_to_asik | sed '1,3d;$d')

function _sync_asod_slave_log_to_master() {
    journalctl -b > /tmp/journal_ASOD_master.log
    mkdir -p /ram/slave
    bsh 0:1 "journalctl -b > /tmp/journal.log"
    scp ${_ssh_opt} -i .ssh/id_rsa_toor4nsn toor4nsn@192.168.253.2:/tmp/*.log* /ram/slave/ 2>/dev/null
}

readonly _sync_asod_slave_log_to_master_script=$(type _sync_asod_slave_log_to_master | sed '1,3d;$d')

function _sync_asik_slave_log_to_master() {
    mkdir -p /ram/ASIK/slave
    bsh 0:1 "journalctl -b > /tmp/journal.log"
    scp ${_ssh_opt} -i .ssh/id_rsa_toor4nsn toor4nsn@192.168.253.2:/tmp/*.log* /ram/ASIK/slave/ 2>/dev/null
}

readonly _sync_asik_slave_log_to_master_script=$(type _sync_asik_slave_log_to_master | sed '1,3d;$d')

function _fetch_startup_log_when_deploy_fail() {
    local _results_dir="${script_folder_path}/results"
    local _asik_login="toor4nsn@192.168.255.1"
    local _scp_bb3="scp ${_ssh_opt} -i ${script_folder_path}/dspbin/lib/id_rsa"
    local _scp_toor4nsn="scp ${_ssh_opt} -i ${script_folder_path}/dspbin/lib/id_rsa_toor4nsn"
    local _ssh_toor4nsn="ssh ${_ssh_opt} -i ${script_folder_path}/dspbin/lib/id_rsa_toor4nsn ${_asik_login}"
    if [[ ${DEPLOYMENT} == "L2_ON_CLOUD_ASOD" ]]; then
        ${_ssh_toor4nsn} "${_sync_asod_slave_log_to_master_script}" 2>/dev/null
        ${_scp_toor4nsn} -r ${_asik_login}:/tmp/{slave,*.log*} ${_results_dir}/ 2>/dev/null
        ${_scp_bb3} robot@${RCP_IP}:/tmp/LINUX_startup.log ${_results_dir}/LINUX_startup_BTS.log 2>/dev/null
        ${_scp_bb3} robot@${RCP_UESIM_IP}:/tmp/LINUX_startup.log ${_results_dir}/LINUX_startup_UE.log 2>/dev/null
        return 0
    fi
    ${_ssh_toor4nsn} "${_sync_abil_log_to_asik_script}" 2>/dev/null
    ${_scp_toor4nsn} -r ${_asik_login}:/tmp/{ABIL,*.log*} ${_results_dir}/ 2>/dev/null
    mv ${_results_dir}/startup_DEFAULT.log ${_results_dir}/startup_DEFAULT_ASIK.log || true
    case ${DEPLOYMENT} in
        L2_ON_CLOUD_ABIL | L2_ON_CLOUD_ASIK_ABIL_8CC | L2_ON_CLOUD_ASIK_ABIL)
            ${_scp_bb3} robot@${RCP_IP}:/tmp/LINUX_startup.log ${_results_dir}/LINUX_startup_BTS.log 2>/dev/null
            ${_scp_bb3} robot@${RCP_UESIM_IP}:/tmp/LINUX_startup.log ${_results_dir}/LINUX_startup_UE.log 2>/dev/null;;
        L2_ON_CLASSICAL_ABIL | L2_ON_CLASSICAL_ABIL_FOR_CAPA | L2_ON_CLASSICAL_ASIB)
            if [[ ${DEPLOYMENT} == "L2_ON_CLASSICAL_ASIB" ]]; then
                mv ${_results_dir}/startup_DEFAULT_ASIK.log ${_results_dir}/startup_DEFAULT_ASIB.log || true
            fi
            ${_scp_bb3} robot@${RCP_IP}:/tmp/LINUX_startup.log ${_results_dir}/LINUX_startup_GtpuGen.log 2>/dev/null;;
        L2_ON_CLASSICAL_ASIK_ABIL)
            ${_ssh_toor4nsn} "${_sync_asik_slave_log_to_master_script}" 2>/dev/null
            mv ${_results_dir}/startup_DEFAULT_ASIK.log ${_results_dir}/startup_DEFAULT_ASIK_master.log || true
            ${_scp_toor4nsn} -r ${_asik_login}:/ram/ASIK ${_results_dir}/ 2>/dev/null;;
        *)
            echo "ERROR: Unknown deployment: ${DEPLOYMENT}"
            return 1;;
    esac
}

lab_user_name=""
returnresult=""

invoking_host=""
invoking_user=$(id -nu)
SSH_COMMAND=""
SSH_COMMAND_toor4nsn="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SCP_COMMAND_toor4nsn="scp -o StrictHostKeyChecking=no -o ConnectTimeout=30 -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
RSYNC="rsync -a --copy-links --delete --delete-excluded --force --exclude *.pyc --exclude=.svn"
RSYNCUPEXCLUDE="--exclude results* --exclude archive"
PYBOT_BASE_OPTIONS="-v EM_TRACE_MODE:None"
ECL_FILENAME="ECL"
LRC_ECL_FILENAME="ECL_LRC"
FSM4_ECL_FILENAME="ECL_FSM4"
EXPECTED_REL3_5_OUT_COUNT=8
REL=2
L2_DEPLOYMENT=""
FSM4HW="FSM4HW_LRC"
TARGET=""
REBOT_OPTIONS=""
RESULTSSUFFIX=""
SECTIONS=1
SECTIONED="0"
TESTSDIR="tests"
REBOOT_IF_SUITE_FAILURE=0
rsyncpid=0
AXM_IP_LRC=192.168.129.17
AXM_IP_LRC_pair=192.168.129.25
FZM_IP=192.168.255.16
MCU_IP=192.168.255.1
RCP_IP=192.168.255.72
ROBOT_PC_IP=192.168.253.58
DU_BACKHAUL_IP=10.63.86.205
ONLY_LOAD_L2HI="lib5gl2hi.so<"
ONLY_LOAD_GTPUGEN="libGtpuGen.so<"
DRY_RUN="0"
FORCE_OFFLINE_CHECK=0
ONHOST="False"
TESTLIST_CHECKER=0
USE_ASIK=0
USE_ABIL=0
USE_ASOD=0
USE_ASIB=0
USE_ABIC=0
ACCEPTED_FAILED_TESTS=5
KEYRING_PASSWORD=5gcipass

##################################################
# execution started form here

_check_and_set_if_running_in_target_pc

_set_and_load_env_config_file

_IS_THIS_DEPERCATED_check_and_copy_packages

_init_options_settings

if [[ "$#" -eq 0 ]]; then
    _print_help_message
    exit 1
fi

_init_session_identifyer_used_by_5g_ci

# TODO: Who is using this, whether this can be removed?
if [[ "${USER}" =~ (Trunk|FB|FT).* ]]; then
    reservation_release_timeout="0"
    echo "User ${USER} has reservation_release_timeout changed to 0 minutes"
fi

####################
# start parsing flags
valid_options="hp:I:Us:t:cCklPGbud:qx:aRTFS:g:"
valid_long_options="help,pybot-options:,session-id:,no-colors,copy-all-packages-from-local,keep-passed-log,keep-for-loop-log,profiling,no-journal-log,skip-deployment,skip-rcp-upgrade,force-rcp-upgrade,skip-health-examination,deployment:,skip-testing,quit-when-failure,preset:,archive-results,random-order,repeat,until-fail,site:,pool:,prio:,rerunfailed,forceofflinecheck,dryrun,no-execution-time-guard,gtpdatagen:,gtpdatagenul:,msgseqdriver:"
options_shift_amount=1

ret_value=0
command_options=$(getopt -o "${valid_options}" -l "${valid_long_options}" -- "$@") || ret_value=$?
if [[ "${ret_value}" -ne 0 ]]; then
    _print_help_message
    exit 1
fi
eval set -- "${command_options% --}"

while [[ "$#" -gt 0 ]]; do
    set +u
    option_flag="$1"
    option_value="$2"
    set -u
    _parse_flag "${option_flag}" "${option_value}" || ret_value=$?
    if [[ "${ret_value}" -ne 0 ]]; then
        _print_help_message
        exit 1
    fi
    shift "${options_shift_amount}"
done

command_line_params+=" --session-id ${test_session_id}"

unset valid_options
unset valid_long_options
unset options_shift_amount
unset command_options
unset option_flag
unset option_value

if [[ -z "${deployment_setting}" ]]; then
    _print_help_message
    echo
    echo "ERROR: The '-d' parameter for selecting the used deployment is mandatory."
    echo
    exit 1
fi
# end parsing flags
####################

ret_value=0
_check_and_prepare_target_site_and_deployment || ret_value=$?
if [[ "${ret_value}" -ne 0 ]]; then
    echo "ERROR: Check target site and deployment settings failed."
    exit 1
fi

if [[ "${is_runing_in_robot_pc}" -eq 0 ]]; then
    set +u
    if [[ -z "${PROJECT_ROOT}" ]]; then
        export PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." &>/dev/null && pwd)"
        echo "PROJECT_ROOT: ${PROJECT_ROOT}"
    fi
    set -u
fi

if [[ -z "${pybot_essential}" && -n "${test_preset_setting}" ]]; then
    echo "Error: Essential pybot option may not be disabled when using presets"
    exit 1
fi

_build_pybot_options_seted_by_flags

pybot_essential="${pybot_essential} ${PYBOT_BASE_OPTIONS}"

# Cloud deployment (running on AirFrame)
if [[ "$REL" == "CLOUD_AF" ]]; then
    set +u
    RCP_FRONTHAUL_IP=10.63.86.204
    RCP_BACKHAUL_IP=10.63.85.112
    RCP_UESIM_FRONTHAUL_IP=10.63.86.203
    RCP_UESIM_BACKHAUL_IP=10.63.85.111
    [[ -f ~/rcp_ip_config.txt ]] && source ~/rcp_ip_config.txt || true
    pybot_options_deployment_related+=" -v L2DEPL:$L2_DEPLOYMENT -v DEPL:$DEPLOYMENT -v RCP_BB2_IP:$RCP_BB2_IP -v RCP_IP:$RCP_IP"
    pybot_options_deployment_related+=" -v RCP_UESIM_IP:$RCP_UESIM_IP -v RCP_SYSCOM_IP:$RCP_SYSCOM_IP -v RCP_UESIM_SYSCOM_IP:$RCP_UESIM_SYSCOM_IP"
    pybot_options_deployment_related+=" -v RCP_FRONTHAUL_IP:$RCP_FRONTHAUL_IP -v RCP_BACKHAUL_IP:$RCP_BACKHAUL_IP"
    pybot_options_deployment_related+=" -v RCP_UESIM_FRONTHAUL_IP:$RCP_UESIM_FRONTHAUL_IP -v RCP_UESIM_BACKHAUL_IP:$RCP_UESIM_BACKHAUL_IP"
    pybot_options_deployment_related+=" -v USE_ASIK:$USE_ASIK -v USE_ABIL:$USE_ABIL -v USE_ASIB:$USE_ASIB -v USE_ABIC:$USE_ABIC -v USE_ASOD:$USE_ASOD"
    pybot_essential="${pybot_essential} --variablefile resources/initial_configuration/relCLOUD_AFEmsyscom.py"
    set -u
elif [[ "$REL" == "CLASSICAL_AF" ]]; then
    [[ -f ~/rcp_ip_config.txt ]] && source ~/rcp_ip_config.txt || true
    RCP_IP=192.168.255.1
    RCP_FRONTHAUL_IP=192.168.255.1
    RCP_BACKHAUL_IP=192.168.255.1
    RCP_UESIM_FRONTHAUL_IP=192.168.255.1
    RCP_UESIM_BACKHAUL_IP=192.168.255.2
    RCP_UESIM_IP=192.168.255.1
    pybot_options_deployment_related+=" -v ON_HOST:False -v SSH_USER:toor4nsn --variablefile resources/initial_configuration/relClassicalAsikAbilsyscom.py"
    pybot_options_deployment_related+=" -v RCP_IP:$RCP_IP -v RCP_UESIM_IP:$RCP_UESIM_IP -v RCP_FRONTHAUL_IP:$RCP_FRONTHAUL_IP -v RCP_BACKHAUL_IP:$RCP_BACKHAUL_IP"
    pybot_options_deployment_related+=" -v RCP_UESIM_FRONTHAUL_IP:$RCP_UESIM_FRONTHAUL_IP -v RCP_UESIM_BACKHAUL_IP:$RCP_UESIM_BACKHAUL_IP"
    pybot_options_deployment_related+=" -v USE_ASIK:$USE_ASIK -v USE_ABIL:1 -v USE_ASIB:$USE_ASIB -v USE_ABIC:$USE_ABIC -v USE_ASOD:$USE_ASOD"
    #pybot_essential="${pybot_essential} --variablefile resources/initial_configuration/relCLOUD_AFEmsyscom.py"
elif [[ "$REL" == "CLASSICAL_ABIL" ]]; then
    RCP_FRONTHAUL_IP=10.63.86.204
    RCP_BACKHAUL_IP=10.63.85.112
    RCP_UESIM_FRONTHAUL_IP=10.63.86.203
    RCP_UESIM_BACKHAUL_IP=10.63.85.111
    RCP_IP=192.168.255.1
    RCP_SYSCOM_IP=192.168.255.1
    [[ -f ~/rcp_ip_config.txt ]] && source ~/rcp_ip_config.txt || true
    pybot_options_deployment_related+=" -v ON_HOST:False -v SSH_USER:toor4nsn --variablefile resources/initial_configuration/relClassicalAbilsyscom.py"
    pybot_options_deployment_related+=" -v RCP_IP:$RCP_IP -v RCP_UESIM_IP:$MCU_IP -v RCP_FRONTHAUL_IP:$RCP_FRONTHAUL_IP"
    pybot_options_deployment_related+=" -v RCP_BACKHAUL_IP:$DU_BACKHAUL_IP -v RCP_UESIM_FRONTHAUL_IP:$MCU_IP -v RCP_UESIM_BACKHAUL_IP:$DU_BACKHAUL_IP -v RCP_SYSCOM_IP:$RCP_SYSCOM_IP"
    pybot_options_deployment_related+=" -v USE_ASIK:$USE_ASIK -v USE_ABIC:$USE_ABIC -v USE_ABIL:1 -v USE_ASIB:$USE_ASIB -v USE_ABIC:$USE_ABIC -v USE_ASOD:$USE_ASOD"
elif [[ "$REL" == "CLASSICAL_ABIL_FOR_CAPA" ]]; then
    RCP_FRONTHAUL_IP=10.63.86.204
    RCP_BACKHAUL_IP=10.63.85.112
    RCP_UESIM_FRONTHAUL_IP=10.63.86.203
    RCP_UESIM_BACKHAUL_IP=10.63.85.111
    RCP_IP=192.168.255.1
    RCP_SYSCOM_IP=192.168.255.1
    [[ -f ~/rcp_ip_config.txt ]] && source ~/rcp_ip_config.txt || true
    pybot_options_deployment_related+=" -v ON_HOST:False -v SSH_USER:toor4nsn --variablefile resources/initial_configuration/relClassicalAbilsyscom.py"
    pybot_options_deployment_related+=" -v L2HIDU_NODEID:0x123a -v RCP_IP:$RCP_IP -v RCP_UESIM_IP:$MCU_IP -v RCP_FRONTHAUL_IP:$RCP_FRONTHAUL_IP"
    pybot_options_deployment_related+=" -v RCP_BACKHAUL_IP:$DU_BACKHAUL_IP -v RCP_UESIM_FRONTHAUL_IP:$MCU_IP -v RCP_UESIM_BACKHAUL_IP:$DU_BACKHAUL_IP -v RCP_SYSCOM_IP:$RCP_SYSCOM_IP"
    pybot_options_deployment_related+=" -v USE_ASIK:$USE_ASIK -v USE_ABIC:$USE_ABIC -v USE_ABIL:1 -v USE_ASIB:$USE_ASIB -v USE_ABIC:$USE_ABIC -v USE_ASOD:$USE_ASOD"
elif [[ "$REL" == "CLASSICAL_ASIB" ]]; then
    [[ -f ~/rcp_ip_config.txt ]] && source ~/rcp_ip_config.txt || true
    RCP_FRONTHAUL_IP=10.63.86.9
    pybot_options_deployment_related+=" -v ON_HOST:False -v SSH_USER:toor4nsn --variablefile resources/initial_configuration/relClassicalAbilsyscom.py"
    pybot_options_deployment_related+=" -v L2HIDU_NODEID:0x123a -v RCP_IP:$RCP_IP -v RCP_UESIM_IP:$MCU_IP -v RCP_FRONTHAUL_IP:$RCP_FRONTHAUL_IP"
    pybot_options_deployment_related+=" -v RCP_BACKHAUL_IP:$DU_BACKHAUL_IP -v RCP_UESIM_FRONTHAUL_IP:$MCU_IP -v RCP_UESIM_BACKHAUL_IP:$MCU_IP -v USE_ASIK:$USE_ASIK"
    pybot_options_deployment_related+=" -v USE_ABIC:$USE_ABIC -v USE_ABIL:1 -v USE_ASIB:$USE_ASIB -v USE_ABIC:$USE_ABIC -v USE_ASOD:$USE_ASOD"

elif [[ "$REL" == "CLASSICAL_ABIC" ]]; then
    pybot_options_deployment_related+=" -v ON_HOST:False -v SSH_USER:toor4nsn --variablefile resources/initial_configuration/relClassicalAbicsyscom.py"
    pybot_options_deployment_related+=" -v L2HIDU_NODEID:0x124a -v RCP_IP:$MCU_IP -v RCP_UESIM_IP:$MCU_IP -v RCP_FRONTHAUL_IP:$MCU_IP"
    pybot_options_deployment_related+=" -v RCP_BACKHAUL_IP:$MCU_IP -v RCP_UESIM_FRONTHAUL_IP:$MCU_IP -v RCP_UESIM_BACKHAUL_IP:$MCU_IP -v USE_ASIK:$USE_ASIK"
    pybot_options_deployment_related+=" -v USE_ABIL:$USE_ABIL -v USE_ABIC:1 -v USE_ASIB:1 -v USE_ASOD:$USE_ASOD"
fi

# set extra parameters when using preset
if [[ -n "${test_preset_setting}" ]]; then
    # Remove testsdir if it's given as pybot option to prevent duplicates
    if [[ ${generated_pybot_options} == *$TESTSDIR* ]]; then
        generated_pybot_options=$(echo "${generated_pybot_options}" | sed -e "s#$TESTSDIR##g") || true
    fi
    # use testlist files when available, this will replace usage of tags
    if [[ -f "$(dirname $0)"/targets/"$TARGET"/"${test_preset_setting}"list.txt ]]; then
        if [[ "${generated_pybot_options}" != *targets/"$TARGET"/"${test_preset_setting}"list.txt* ]]; then
            generated_pybot_options+=" -A targets/"$TARGET"/"${test_preset_setting}"list.txt"
        fi
    else
        echo "Error: no testlist file for $TARGET ${test_preset_setting} found."
        exit 1
    fi
    if [[ ${generated_pybot_options} != *$TESTSDIR* ]]; then
        generated_pybot_options="${generated_pybot_options} $TESTSDIR"
    fi
fi

if [[ "${is_runing_in_robot_pc}" -eq 0 ]]; then
    # save command and user
    args=${@}
    script=$0
    cmd="$script $args"
    sct_user=$(whoami)
    echo -e "cmd=\"${cmd}\"\nsct_user=${sct_user}" > cmd_user

    if [[ $ONHOST == "False" ]]; then
        retval=0
        case "$DEPLOYMENT" in
            L2_ON_CLOUD_ASIK_ABIL)     prepare_local_workarea                     || retval=$?;;
            L2_ON_CLOUD_ASIK_ABIL_8CC) prepare_local_workarea_cloud_asik_abil_8cc                 || retval=$?;;
            L2_ON_CLOUD_ABIL)          prepare_local_workarea_cloud_abil          || retval=$?;;
            L2_ON_CLASSICAL_ASIK_ABIL) prepare_local_workarea_classical_asik_abil || retval=$?;;
            L2_ON_CLASSICAL_ABIL)      prepare_local_workarea_classical_abil      || retval=$?;;
            L2_ON_CLASSICAL_ABIL_FOR_CAPA)      prepare_local_workarea_classical_abil      || retval=$?;;
            L2_ON_CLASSICAL_ASIB)      prepare_local_workarea_classical_asib      || retval=$?;;
            L2_ON_CLOUD_ASOD)          prepare_local_workarea_asod                || retval=$?;;
            L2_ON_CLASSICAL_ABIC)      prepare_local_workarea_classical_abic      || retval=$?;;
            *)
                echo "ERROR: Unsupported deployment."
                exit 1
        esac
        if [[ "${retval}" -ne 0 ]]; then
            echo "ERROR: Local workarea preperation failed."
            exit 1
        fi

        if [[ "$DRY_RUN" -eq "1" ]]; then
            echo "select dryrun"
            testline_pool_type="Dryrun_pool"
        fi
        # trap fail to make sure we do release the reservation
        trap _interrupt_signal_handler HUP INT TERM PIPE EXIT ERR
        if [[ "${is_user_specified_testline}" -eq 0 ]]; then
            echo "Using reservation system to reserve one testline of type \"${testline_pool_type}\"."
            if [[ "${ci_5g_try_use_different_testline}" -eq 1 ]]; then
                # 5G CI: retry gate with another test line
                # TODO: consider move this funcitons into ci-scripts instead of here
                echo "GATE retry "
                free_slaves=$(_nbr_of_free_slaves_of_type ${testline_pool_type}) || true
                echo "free slaves currently:$free_slaves "
                # quick blocking reservation if reservation can be done immediately!
                if [[ "$free_slaves" -gt 1 ]]; then
                    prev_identifier=${IDENTIFIER%_*}
                    prev_robot=$(_echo_slave_with_identifier "${testline_pool_type}" "${prev_identifier}") || true
                    _put_offline "$prev_robot" "CI: Quick offline"
                    sleep 3
                    reserve_testline "${target_site}" "${testline_pool_type}" "${reservation_duration}" "${reservation_priority}" result "${test_session_id}"
                    testline_host=$(echo $result |awk '{print $NF}') || true
                    unset result
                    _put_online "$prev_robot" || true
                else
                    reserve_testline "${target_site}" "${testline_pool_type}" "${reservation_duration}" "${reservation_priority}" result "${test_session_id}"
                    testline_host=$(echo $result |awk '{print $NF}') || true
                    unset result
                fi
            else
                reserve_testline "${target_site}" "${testline_pool_type}" "${reservation_duration}" "${reservation_priority}" result "${test_session_id}"
                testline_host=$(echo $result |awk '{print $NF}') || true
                unset result
            fi
        else
            echo "Using user specified host: ${testline_host}"
            _ip_address_check_regex="[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"
            if [[ ! "${testline_host}" =~ ${_ip_address_check_regex} ]]; then
                _test_s_parameter_eligibility ${testline_host}
            fi
        fi

        STARTTIME=$(date +%s)
        # log testline info right after reservation to have knowledge of used robot
        _log_testline_information "${testline_host}"

        # description for Jenkins builds
        if [[ -f "../mac_rev_file.txt" ]]; then
            revision=$(egrep '^Last Changed Rev: ' ../mac_rev_file.txt | sed 's/^Last Changed Rev:/rev/g') || true
            shorthost=$(echo ${testline_host} | sed 's:\.[A-Za-z].*::g') || true
            echo "Description: $revision / $shorthost"
        fi

        ret_value=0
        _sync_files_to_robot_pc "${testline_host}" || ret_value=$?
        if [[ "${ret_value}" -ne 0 ]]; then
            if [[ "${is_user_specified_testline}" -eq 0 ]]; then
                _release_reservation
            fi
            trap - HUP INT TERM PIPE EXIT ERR
            exit 1
        fi
    fi # NOT ONHOST

    # execute tests
    if [[ $ONHOST == "True" ]]; then
        source /build/home/pyv/pySct1/bin/activate
        generated_pybot_options="${pybot_options_seted_by_flags} --noncritical OnHostUnstable --exclude ExcludeOnHost -v ON_HOST:True -v DOMAIN_USER_NAME:dummy -v L2_ALREADY_UP:1 ${pybot_options_deployment_related} ${pybot_essential} ${generated_pybot_options}"
        generated_pybot_options=$(echo ${generated_pybot_options} | sed 's:[ ]* : :g')
        generated_pybot_options=$(echo ${generated_pybot_options} | sed 's/-v UPLOAD_BINS_TO_MCU:True/-v UPLOAD_BINS_TO_MCU:False/' | sed 's/-v RESET_DSPS:True/-v RESET_DSPS:False/');
        export PYBOT_OPTIONS="${generated_pybot_options}"

        #
        #  R U N   T H E   T E S T S   O N   H O S T
        #
        ret_value=0
        python $PROJECT_ROOT/C_Test/SC_LTEL2/Sct/RobotTests/bin/start_onhost_sct.py $ONHOST_ARGS || ret_value=$?

        deactivate
        exit $ret_value
    else
        testline_index=$(grep -ioP '(?<=5gRobot)\d+(?=\..+\.net)' <<< "${testline_host}" || true)

        if [[ -z "${testline_index}" ]]; then
            if [[ "${skip_rcp_upgrade}" -eq 0 || "${skip_health_examination}" -eq 0 ]]; then
                echo    "####################"
                echo    "#     WARNING      #"
                echo    "####################"
                echo -n "RCP upgrade is not available for testline specified as ${testline_host}. Either use domain name "
                echo    "or --skip-rcp-upgrade option and --skip-health-examination."
                echo    "RCP upgrade and health examination is skipped this time."
                echo    "####################"
                skip_rcp_upgrade=1
                skip_health_examination=1
            fi
        fi

        if [[ "${skip_rcp_upgrade}" -eq 1 ]]; then
            echo "RCP upgrade skipped"
        else
            labcraft_extra_args=""
            if [[ "${force_rcp_upgrade}" -eq 0 ]]; then
                labcraft_extra_args="${labcraft_extra_args} --lazy"
            fi
            KEYRING_PASSWORD=$KEYRING_PASSWORD \
                env -i TERM=$TERM PATH=$PATH LANG=$LANG USER=$USER HOME=$HOME sha1=${sha1:-0} KICKOFF_DEBUG=${KICKOFF_DEBUG:-0} KEYRING_PASSWORD=$KEYRING_PASSWORD "${labcraft_script}" \
                testline upgrade "${testline_index}" --image "${env_config_rcp_bb3}" ${labcraft_extra_args}
        fi

        if [[ "${skip_rcp_upgrade}" -eq 1 ]]; then
            command_line_params+=" --skip-rcp-upgrade"
        fi

        if [[ "${skip_health_examination}" -eq 1 ]]; then
            command_line_params+=" --skip-health-examination"
        fi

        # this is where the same scipt is remotely executed at target PC i.e. robot machine!
        #echo "===> executing remote run_rlctests.sh with args=${command_line_params}, pytbot_opts=${generated_pybot_options} (only deployment procedure)"
        ret_value=0
        set +u
        $SSH_COMMAND ${lab_user_name}@${testline_host} "
            set -e
            export LSP_PAIR=$LSP_PAIR
            export GTPDATAGEN_ADDRESS=$GTPDATAGEN_ADDRESS
            export GTPDATAGEN_UL_ADDRESS=$GTPDATAGEN_UL_ADDRESS
            export MESSAGE_SEQUENCE_DRIVER_ADDRESS=$MESSAGE_SEQUENCE_DRIVER_ADDRESS
            cd RobotTests
            ./run_rlctests.sh ${command_line_params} -p \"${user_given_pybot_options}\" --skip-testing
        " || ret_value=$?
        set -u

        if [[ "${ret_value}" -ne 0 ]]; then
            echo "Script excution on Robot PC failed! Return value: ${ret_value}"
        else
            if [[ "${skip_health_examination}" -eq 1 ]]; then
                echo "Health examination skipped"
            else
                if [[ -z ${testline_index} ]]; then
                    exit 1
                else
                    KEYRING_PASSWORD=$KEYRING_PASSWORD \
                    env -i TERM=$TERM PATH=$PATH LANG=$LANG USER=$USER HOME=$HOME sha1=${sha1:-0} KICKOFF_DEBUG=${KICKOFF_DEBUG:-0} KEYRING_PASSWORD=$KEYRING_PASSWORD \
                    "${labcraft_script}" testline examine $testline_index
                fi
            fi

            #echo "===> executing remote run_rlctests.sh with args=${command_line_params}, pytbot_opts=${generated_pybot_options} (only testing procedure)"
            ret_value=0
            set +u
            $SSH_COMMAND ${lab_user_name}@${testline_host} "
                set -e
                export LSP_PAIR=$LSP_PAIR
                export GTPDATAGEN_ADDRESS=$GTPDATAGEN_ADDRESS
                export GTPDATAGEN_UL_ADDRESS=$GTPDATAGEN_UL_ADDRESS
                export MESSAGE_SEQUENCE_DRIVER_ADDRESS=$MESSAGE_SEQUENCE_DRIVER_ADDRESS
                cd RobotTests
                ./run_rlctests.sh ${command_line_params} -p \"${user_given_pybot_options}\" --skip-deployment
            " || ret_value=$?
            set -u
            if [[ "${ret_value}" -ne 0 ]]; then
                echo "Script excution on Robot PC failed! Return value: ${ret_value}"
            fi
        fi
    fi

    echo "Sync results down from ${testline_host}"
    ret_value=0
    if [[ "${target_site}" == "ouling" ]]; then
        if [[ ${testline_host} == "5gRobot2"*"dynamic.nsn-net.net" ]]; then
            # Temporary workaround for slow connection speed Espoo<->Wroclaw lab
            echo "Downloading results to the hopper"
            ssh -A -i dspbin/lib/id_rsa -o StrictHostKeyChecking=no sct@wro-lab-hopper.dynamic.nsn-net.net "rm -rf /tmp/${testline_host}/ 2>/dev/null && rsync -e 'ssh -i ~/.ssh/id_rsa -o StrictHostKeyChecking=no'  -vur -z $lab_user_name@${testline_host}:~/RobotTests/results/  /tmp/${testline_host}/" || ret_value=$?
            echo "Downloading results from hopper"
            rsync -e 'ssh -i dspbin/lib/id_rsa -o StrictHostKeyChecking=no' -vur -z sct@wro-lab-hopper.dynamic.nsn-net.net:/tmp/${testline_host}/  results$RESULTSSUFFIX || ret_value=$?
        else
            # Rsync handles test results
            $RSYNC -e "$SSH_COMMAND" -z $lab_user_name@${testline_host}:~/RobotTests/results/ results$RESULTSSUFFIX || ret_value=$?
        fi
    else
        $RSYNC -e "$SSH_COMMAND" -z $lab_user_name@${testline_host}:~/RobotTests/results/ results$RESULTSSUFFIX || ret_value=$?
    fi

    if [[ "${ret_value}" -ne 0 ]]; then
        echo "WARNING: Error occured when downloding results."
    fi

    sleep 1
    _update_testline_info_in_reservation_system "${env_config_ps_rel}" "${testline_host}"

    if [[ -f "results/retval.txt" ]]; then
        retval=$(cat results/retval.txt)
        if [[ "${retval}" -eq "0" ]]; then
            returnresult="0"
        else
            if [[ -f "results/report.html" ]]; then
                check=$(grep -c 'Suite setup failed' results/report.html) || true
                if [[ "${check}" -ne 0 ]]; then
                    retval="setup"
                fi
            fi
            returnresult="${retval}"
        fi
    fi

    if [[ "${is_user_specified_testline}" -eq 0 ]]; then
        _release_reservation
    fi
    trap - HUP INT TERM PIPE EXIT ERR

    if [[ "${archive_results}" -eq 1 ]]; then
        _archive_test_results
    fi

    if [[ -n "${profiling_setting}" ]]; then
        echo
        echo "Function load results:"
        find results -type f -name profiling_results_*.zip | sed 's:^:    :g' || true
    fi

    # Running queue load CSV generation replaced with mechanism where CI job parses
    # command prints (.txt) and generates CSV files and archives for further storage and visualization (Splunk tool).

    #echo "Test report: results/report.html"
    echo "Test report:" $(pwd)"/results/report.html"
    echo "Test log:" $(pwd)"/results/log.html"
    echo "Test output:" $(pwd)"/results/output.xml"

    if [[ -f "results/retval.txt" ]]; then
        retval=$(cat results/retval.txt)
        if [[ "$retval" -eq 5050 ]]; then
            if [[ "${target_site}" == "ouling" && "${is_user_specified_testline}" -eq 0 ]]; then
                offlinetext="${sct_user}: BB2 ethernet broken according run_rlctest check from site ${target_site}"
                echo "=============================================================================="
                echo "BB2 ethernet connection broken, please consider offlining ${testline_host} with comment: ${offlinetext}"
                echo "=============================================================================="
                # _put_offline "${testline_host}" "${offlinetext}"
            fi
            echo "Finished: FAIL (site ${target_site})"
        fi
    fi
else
    # This is executed in Robot PC i.e. is_runing_in_robot_pc=1
    DOMAIN_USER_NAME=$(whoami)

    generated_pybot_options="${pybot_options_seted_by_flags} -v ON_HOST:False -v L2_ALREADY_UP:1 -v DOMAIN_USER_NAME:$DOMAIN_USER_NAME ${pybot_options_deployment_related} ${pybot_essential} ${generated_pybot_options}"
    generated_pybot_options=$(echo ${generated_pybot_options} | sed 's:[ ]* : :g') || true

    if [ "$DRY_RUN" == "1" ]; then
        generated_pybot_options="--dryrun -v SSH_USER:dryrunner ${generated_pybot_options}"
        generated_pybot_options=$(echo ${generated_pybot_options} | sed 's/-v UPLOAD_BINS_TO_MCU:True/-v UPLOAD_BINS_TO_MCU:False/' | sed 's/-v RESET_DSPS:True/-v RESET_DSPS:False/') || true
    fi

    STARTD=$(date +%s)

    _print_robot_version
    echo "$(hostname), executing with options: ${generated_pybot_options}"

    D=$(pwd)
    python "$D"/scripts/section_creator/src/caselist_printer.py "${generated_pybot_options}" $D || true

    _run_testlist_checker

    # TARGET_LINUX_PC_5G

    if [[ "$(pgrep -u "${USER}" 'python|sicftp|pybot|rebot|curl' | wc -l)" -ne "0" ]]; then
        echo -ne "Process cleanup..."
        killall -u "${USER}" -q -2 python sicftp pybot rebot curl || true
        sleep 3
        if [[ "$(pgrep -u "${USER}" 'python|sicftp|pybot|rebot|curl' | wc -l)" -ne "0" ]]; then
            echo -ne "..."
            killall -u "${USER}" -q -2 python sicftp pybot rebot curl || true
            sleep 3
        fi
        if [[ "$(pgrep -u "${USER}" 'python|sicftp|pybot|rebot|curl' | wc -l)" -ne "0" ]]; then
            echo -ne "..."
            killall -u "${USER}" -q -9 python sicftp pybot rebot curl || true
            sleep 3
        fi
        echo " done"
        echo -ne "Sleeping for 15 seconds..."
        sleep 15
        echo " done"
    fi

    if [[ "${skip_deployment}" -ne 1 ]]; then
        rm -rf "${script_folder_path}/results"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "--dryrun selected. Proceed to test execution"
        else
            if [ "$DEPLOYMENT" == "L2_ON_CLOUD_ASIK_ABIL" ]; then
                deployscript="$PWD/dspbin/lib/deployBinariesToAsik.sh"
                timeoutTime=1500
                echo "L2-HI VM's and ASIK will be deployed and started before the test execution"
            elif [ "$DEPLOYMENT" == "L2_ON_CLOUD_ASIK_ABIL_8CC" ]; then
                deployscript="$PWD/dspbin/lib/deployBinariesToCloudAsikAbil_8cc.sh"
                timeoutTime=1500
                echo "L2-HI VM's and ASIK will be deployed and started before the test execution"
            elif [[ "$DEPLOYMENT" == "L2_ON_CLOUD_ABIL" ]]; then
                deployscript="${PWD}/dspbin/lib/deployBinariesToCloudAbil.sh"
                timeoutTime=3000
                echo "L2-HI VM's and ASIK will be deployed and started before the test execution"
            elif [ "$DEPLOYMENT" == "L2_ON_CLOUD_ASOD" ]; then
                deployscript="$PWD/dspbin/lib/deployBinariesToAsod.sh"
                timeoutTime=3000
                echo "L2-HI VM's and ASOD will be deployed and started before the test execution"
            elif [ "$DEPLOYMENT" == "L2_ON_CLASSICAL_ABIL" ]; then
                deployscript="$PWD/dspbin/lib/deployBinariesToAbilClassical.sh"
                timeoutTime=3000
                echo "ASIK/ABIL will be deployed and started before the test execution"
            elif [ "$DEPLOYMENT" == "L2_ON_CLASSICAL_ABIL_FOR_CAPA" ]; then
                deployscript="$PWD/dspbin/lib/deployBinariesToAbilClassicalForCapa.sh"
                timeoutTime=1500
                echo "ASIK/2ABIL will be deployed and started before the test execution"
            elif [ "$DEPLOYMENT" == "L2_ON_CLASSICAL_ASIB" ]; then
                deployscript="$PWD/dspbin/lib/deployBinariesToAsibClassical.sh"
                timeoutTime=1500
                echo "ASIB/ABIL will be deployed and started before the test execution"
            elif [ "$DEPLOYMENT" == "L2_ON_CLASSICAL_ASIK_ABIL" ]; then
                deployscript="$PWD/dspbin/lib/deployBinariesToClassicalAsikAbil.sh"
                timeoutTime=1500 #seconds
                echo "Classical will be deployed and started before the test execution"
                export PYTHONPATH=$PYTHONPATH:/root/RobotTests/libs/
                export PYTHONPATH=$PYTHONPATH:/root/RobotTests/libs/mac/
            else
                echo "Unknown deployment $DEPLOYMENT quiting..."
                exit 1
            fi
            echo "deploy binary script is: ${deployscript} with timeout ${timeoutTime}"
            deploy_ret_value=0
            timeout ${timeoutTime} ${deployscript} ${script_folder_path} $USE_ABIL 0 ${ROBOT_PC_IP} ${DU_BACKHAUL_IP} ${ONLY_LOAD_GTPUGEN} ${ONLY_LOAD_L2HI} || deploy_ret_value=$?
            if [[ "${deploy_ret_value}" -eq 124 ]]; then #124 = timeout occured
                echo "Error!: Deploy script \" $deployscript \" did not finish within timeout value= $timeoutTime (seconds)! Re-trying once..."
                deploy_ret_value=0
                timeout $timeoutTime $deployscript ${script_folder_path} $USE_ABIL 0 ${ROBOT_PC_IP} ${DU_BACKHAUL_IP} ${ONLY_LOAD_GTPUGEN} ${ONLY_LOAD_L2HI} || deploy_ret_value=$?
            fi
            if [[ "${deploy_ret_value}" -ne 0 ]]; then
                echo "Error ${deploy_ret_value} occured in $deployscript script execution!"
                mkdir -p ${script_folder_path}/results
                echo "${deploy_ret_value}" >"${script_folder_path}/results/retval.txt"
                echo "try fetching startup log..."
                _fetch_startup_log_when_deploy_fail
                exit "${deploy_ret_value}"
            fi
            unset deploy_ret_value
            echo "Deployment done and back in run_rlc script at target machine!"
        fi
    fi

    if [[ "${skip_testing}" -ne 1 ]]; then
        if [[ "$(pgrep -f 'ssh .* toor4nsn@' | wc -l)" -ne 0 ]]; then
            echo "cleaning ssh toor4nsn processes..."
            pkill -9 -f 'ssh .* toor4nsn@' || true
            sleep 1
        fi

        # limit memory usage based on available physical memory
        ulimit -v $(free | egrep '^Mem:' | sed 's:  *: :g' | cut -d' ' -f2) || true

        if [[ "${execution_time_guard_enabled}" -eq 1 ]]; then
            echo "Starting max execution time guard with duration of ${reservation_duration} minutes"
            MAXEXECTIMEOUT=$((${reservation_duration}*60))
            # sleep $MAXEXECTIMEOUT && killall -SIGINT pybot && sleep 1 && _set_robot_rebot_options && rebot $REBOT_OPTIONS --outputdir "${script_folder_path}/results" "${script_folder_path}/results/output.xml" && pkill -9 -f '/bin/bash ./run_rlctests.sh' && echo "MAX EXECUTION TIME "${reservation_duration}" MINUTES EXCEEDED - TEST EXECUTION TERMINATED" &
            REBOT_OPTIONS_BACKUP=$REBOT_OPTIONS
            _set_robot_rebot_options
            REBOT_OPTIONS_FOR_SCRIPT=$REBOT_OPTIONS
            REBOT_OPTIONS=$REBOT_OPTIONS_BACKUP
            # just to be sure that we have D setup properly!
            D="$(dirname $0)"
            python "$D"/scripts/execution_timeguard/src/execution_timeguard.py $MAXEXECTIMEOUT $(hostname) "${script_folder_path}" "$REBOT_OPTIONS_FOR_SCRIPT" || true
        else
            echo "No max execution time guard will be set."
        fi

        i=1
        MAXDURATION=1
        while true; do
            PYBOTSTARTD=$(date +%s)

            #
            #  RUN TEST IN TESTLINE
            #

            retval=0
            /usr/local/bin/pybot --outputdir "${script_folder_path}/results" --log None --report None --output output.xml ${generated_pybot_options} || retval=$?

            killall qsct &>/dev/null || true

            if [[ "${rerun_failed_tests}" -eq "1" && "$retval" -ne "0" && -f ${script_folder_path}/results/output.xml && ! -f ${script_folder_path}/results/FATAL ]]; then
                echo
                echo "------------------------"
                echo "---Rerun failed cases---"
                echo "------------------------"
                echo
                # Pybot test configuration cleanup for rerun
                generated_pybot_options=$(echo ${generated_pybot_options} | sed 's/-v UPLOAD_BINS_TO_MCU:True/-v UPLOAD_BINS_TO_MCU:False/') || true
                generated_pybot_options=$(echo ${generated_pybot_options} | sed 's/-v RESET_DSPS:True/-v RESET_DSPS:False/') || true
                generated_pybot_options=$(echo ${generated_pybot_options} | sed 's/-v REBOOT_IF_SUITE_FAILURE:True/-v REBOOT_IF_SUITE_FAILURE:False/') || true
                generated_pybot_options=$(echo ${generated_pybot_options} | sed -E 's/-v SECTIONED:True//') || true
                generated_pybot_options=$(echo ${generated_pybot_options} | perl -pe 's/-v PRESET_TYPE:.*? //g') || true
                generated_pybot_options=$(echo ${generated_pybot_options} | perl -pe 's/\-A .*? //g') || true
                generated_pybot_options=$(echo ${generated_pybot_options} | perl -pe 's/(-i|--include) .*? //g') || true
                generated_pybot_options=$(echo ${generated_pybot_options} | perl -pe 's/(-e|--exclude) .*? //g') || true
                generated_pybot_options=$(echo ${generated_pybot_options} | perl -pe 's/(-s|--suite) .*? //g') || true
                generated_pybot_options=$(echo ${generated_pybot_options} | perl -pe 's/(-t|--test) .*? //g') || true
                echo "RERUN generated_pybot_options: ${generated_pybot_options}"
                if [[ -f ${script_folder_path}/results/output.xml ]];then
                    FAILS=$(grep '<total>' ${script_folder_path}/results/output.xml -A10 | egrep 'All Tests' | cut -d'"' -f2) || true
                    PASS=$(grep '<total>' ${script_folder_path}/results/output.xml -A10 | egrep 'All Tests' | cut -d'"' -f4) || true

                    # If output is found, test execution is succesful return 0. Failed tests
                    # are examined in run script.
                    retval=0
                else
                    echo "output.xml not found after rerun!"
                    retval=1
                fi
                echo "Number of Fails: $FAILS"
                echo "Number of Passes: $PASS"

                if [[ -z $FAILS ]];then
                    default_time_for_rerun=20
                    FAILS=$default_time_for_rerun
                fi
                if [[ $(echo ${generated_pybot_options} | grep -c 'RESET_DSPS:True') -eq 1 ]]; then
                    RERUN_EXECTIME=6
                else
                    RERUN_EXECTIME=4
                fi
                RERUN_EXECTIME=$(($RERUN_EXECTIME + $FAILS))
                echo "set_reservation_time:$RERUN_EXECTIME" | timeout 5 nc 127.0.0.1 5050 || true
                cd ~/RobotTests

                if [[ $PASS -eq 0 || $FAILS -le $ACCEPTED_FAILED_TESTS ]]; then
                    # execute rerun for failed tests
                    pybot --outputdir "${script_folder_path}/results" --xunit sct_result.xml --log None --report None --rerunfailed ${script_folder_path}/results/output.xml --output output_rerun.xml ${generated_pybot_options} || true
                    # merge results
                    rebot --outputdir results --log None --report None --output output_merged.xml --merge ${script_folder_path}/results/output.xml ${script_folder_path}/results/output_rerun.xml || true
                    mv ${script_folder_path}/results/output.xml ${script_folder_path}/results/output_orig.xml || true
                    mv ${script_folder_path}/results/output_merged.xml ${script_folder_path}/results/output.xml || true
                    echo "Rerun done."
                else
                    echo "$FAILS tests failed. Accepted limit is $ACCEPTED_FAILED_TESTS. Rerun skipped."
                fi
            fi

            if [[ -d "${script_folder_path}/results" && ! "${generated_pybot_options}" =~ .*-A\ section[1-9].* ]]; then
                echo "$retval" > "${script_folder_path}/results/retval.txt"
                echo "Time:    $(echo -e "scale = 1\n( $(date +%s) - $STARTD ) / 60" | bc -l) minutes"
                python "$D"/scripts/output_xml_creator/src/output_xml_creator.py "$D"/results/output.xml || true
                _set_robot_rebot_options
                /usr/local/bin/rebot $REBOT_OPTIONS --outputdir "${script_folder_path}/results" "${script_folder_path}/results/output.xml" || true
            fi

            if [[ "${REL}" == "CLOUD_AF" ]]; then
                if [[ "${USE_ASOD}" -eq 1 ]]; then
                    echo "Stopping ASOD CCS-RT"
                else
                    echo "Stopping ASIK CCS-RT"
                fi
                ssh -q -n -i "${script_folder_path}/dspbin/lib/id_rsa_toor4nsn" toor4nsn@192.168.255.1 "systemctl stop ccs-rt.service" || true
            fi

            if [[ "${repeat_the_test}" -eq 0 ]]; then
                echo "Stopping max execution time guard if it's still running"
                sleep 0.2
                killall -SIGTERM sleep && killall -SIGINT pybot && sleep 1 && pkill -9 -f '/bin/bash ./run_rlctests.sh' 1>/dev/null 2>/dev/null || true
                echo "Time:    $(echo -e "scale = 1\n( $(date +%s) - $STARTD ) / 60" | bc -l) minutes"
                break
            fi

            mkdir -p "${script_folder_path}/results/$i"
            mv "${script_folder_path}"/results/*.* "${script_folder_path}/results/$i/" || true
            TIMELEFT=$(echo "${reservation_duration}" '- 2 - ( (' $(date +%s) - "$STARTD" ') / 60 )' | bc)
            PREVDURATION=$(echo '( '$(date +%s) - "$PYBOTSTARTD" ') / 60' | bc)
            if [[ "$PREVDURATION" -gt "$MAXDURATION" ]]; then
                MAXDURATION="$PREVDURATION"
            fi
            if [[ "${repeat_until_fail}" -eq 1 && -f "${script_folder_path}/results/$i/retval.txt" ]]; then
                ret=$(head -n 1 "${script_folder_path}/results/$i/retval.txt")
                if [[ "$ret" != "0" ]]; then
                    TIMELEFT="0"
                fi
            fi
            echo "Time left: $TIMELEFT minutes"
            echo "Max duration: $MAXDURATION"
            diskspace=$(df . | tail -n 1 | sed 's:  *: :g' | cut -d' ' -f5 | sed 's:[^0-9]*::g')
            if [[ "$TIMELEFT" -lt "$MAXDURATION" || "$diskspace" -gt "90" ]]; then
                echo "<html><body><br>" >"${script_folder_path}"/results/report.html
                ls "${script_folder_path}"/results/*/report.html | sed 's:.*results/::g' | sort -n | while read r
                do
                    round=$(echo $r | sed 's:[^0-9]*::g')
                    if [[ -f "${script_folder_path}/results/$round/retval.txt" ]]; then
                        rettxt="pass"
                        ret=$(head -n 1 "${script_folder_path}/results/$round/retval.txt")
                        if [[ $(head -n 1 "${script_folder_path}/results/$round/retval.txt") != "0" ]]; then
                            rettxt="fail: $ret"
                        fi
                        echo "<a href=\"$r\">Round $round</a> - $rettxt<br>" >>"${script_folder_path}"/results/report.html
                    else
                        echo "<a href=\"$r\">Round $round</a><br>" >>"${script_folder_path}"/results/report.html
                    fi
                done
                echo "</body></html>" >>"${script_folder_path}"/results/report.html
                echo "Time spent: $(echo -e "scale = 1\n( $(date +%s) - $STARTD ) / 60" | bc -l) minutes"
                if [[ "$diskspace" -gt "90" ]]; then
                    echo
                    echo "Breaking loop due to low disk space:"
                    echo
                    df -h .
                    echo
                fi
                break
            fi
            let i++
            echo -ne "\n\n===== Starting round $i =====\n\n\n"
        done

        # Move failing test host to offline
        if [[ "$DRY_RUN" == "0" && "$FORCE_OFFLINE_CHECK" == "1" && "${test_preset_setting}" != "" ]]; then
            _take_testline_offline_if_needed
        fi
    fi
fi
