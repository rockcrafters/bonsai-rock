#!/usr/bin/env bash
# this file is the 'source'able version of defer
# it can be used in other scripts to provide the 'defer' function

# hide our own source-time xtrace so `bash -x caller.sh` isn't drowned in defer
# internals (set DEFER_DEBUG to keep it). the redirected group sends even these
# two lines' trace to /dev/null; xtrace is restored at the very end of the file.
{ _defer_src_x=$-; ${DEFER_DEBUG:+:} set +x; } 2>/dev/null

# Meant to be sourced, not executed. Refuse direct execution (except --test).
if [[ "${BASH_SOURCE[0]}" == "$0" && "${1:-}" != "--test" ]]; then
    printf "This file should be sourced, not executed\n" >&2
    exit 1
fi

if [[ -z "${__DEFER_SH__:-}" ]]; then
    # spellchecker: ignore Marcin Konowalczyk lczyk subshell

    __DEFER_SH_VERSION__='2.0.1'



    # Defers execution of a command until the specified signal(s) is received.
    # Multiple commands can be deferred to the same signal, and they will be
    # executed in reverse order of deferral (LIFO).
    #
    # Written by Marcin Konowalczyk @lczyk
    # https://github.com/lczyk/defer.sh
    # Based on a post by Richard Hansen:
    # https://stackoverflow.com/a/7287873/2531987
    # CC-BY-SA 3.0
    function defer() {
        # suppress xtrace (set DEFER_DEBUG to keep it). dont restore with trap so we dont clobber callers traps
        { local _defer_xtrace=$-; ${DEFER_DEBUG:+:} set +x; } 2>/dev/null
        _defer_restore() { unset -f _defer_restore; [[ $_defer_xtrace != *x* ]] || set -x; }

        (($#)) || { printf "defer: usage: defer <cmd> <signal>...\n" >&2; _defer_restore; return 2; }
        local defer_cmd="$1"; shift
        defer_cmd="${defer_cmd%"${defer_cmd##*[!;[:space:]]}"}" # strip trailing ; and whitespace
        [[ -n "$defer_cmd" ]] || { printf "defer: empty command\n" >&2; _defer_restore; return 2; }
        (($#)) || { printf "defer: no signal name given\n" >&2; _defer_restore; return 2; }
        # shellcheck disable=SC2317,SC2329 # invoked indirectly via eval
        _defer_extract() { printf '%s\n' "${3:-}"; }
        local defer_name new_cmd existing_cmd rc=0
        # before each handler, reset $? to the trigger status, so handlers see it via $?,
        # like a normal trap. ( exit N ) && : is set -e-safe: the failing subshell sits on
        # the errexit-exempt LHS of &&, and the short-circuit skips the : so $?=N survives.
        # the reset and the status-capture are each wrapped in a { } 2>/dev/null group, so
        # set -x doesn't trace them -- only the handler commands themselves show.
        # shellcheck disable=SC2016
        local reset='{ ( exit "$_defer_status" ) && :; } 2>/dev/null;'
        # a RETURN trap set from inside a function fires once per active frame
        # as the stack unwinds -- including defer's own return. guard RETURN
        # handlers by frame depth so each fires only when its registering
        # caller returns. an if-statement so the skipped case is set -e-safe,
        # and the condition sits in a 2>/dev/null group to stay out of set -x.
        # shellcheck disable=SC2016
        local guard='{ (( ${#FUNCNAME[@]} == '"$(( ${#FUNCNAME[@]} - 1 ))"' )); } 2>/dev/null'
        local unit
        for defer_name in "$@"; do
            existing_cmd=$(eval "_defer_extract $(trap -p "${defer_name}")")
            case $existing_cmd in
                # our chain: strip the front status-capture group, anchored on its close
                '{ _defer_status=$?; '*) existing_cmd=${existing_cmd#*'} 2>/dev/null; '} ;;
                ?*) existing_cmd="$reset $existing_cmd" ;; # foreign trap: give it a reset too
            esac
            case $defer_name in
                [Rr][Ee][Tt][Uu][Rr][Nn]) unit="if $guard; then $reset ${defer_cmd}; fi;" ;;
                *) unit="$reset ${defer_cmd};" ;;
            esac
            new_cmd="$(printf '%s' '{ _defer_status=$?; } 2>/dev/null; '; printf '%s ' "${unit}"; printf '%s' "${existing_cmd}")"
            trap -- "$new_cmd" "$defer_name" || { printf "Error: Unable to modify trap for %s\n" "$defer_name" >&2; rc=1; }
        done
        unset -f _defer_extract
        _defer_restore
        return $rc
    }
    declare -f -t defer



    ############################################################################
    # Self-test when run as `bash defer.sh --test`
    if [[ "${#BASH_SOURCE[@]}" -eq 1 && "${BASH_SOURCE[0]}" == "$0" && "$1" == "--test" ]]; then
        function test_basic() {
            test_var=0
            defer "test_var=1" USR1
            test "$test_var" -eq 0 || return 1
            kill -USR1 $$
            test "$test_var" -eq 1 || return 1
        }

        function test_defer_order() {
            output=""
            defer "output+='1'" USR1
            defer "output+='2'" USR1
            defer "output+='3'" USR1
            kill -USR1 $$
            test "$output" = "321" || return 1
        }

        function test_order_with_handset_trap() {
            # defers stack onto a pre-existing trap: deferred commands run first (LIFO),
            # then the original hand-set trap. guards the foreign-trap path + re-stacking.
            output=""
            trap "output+='H'" USR1
            defer "output+='1'" USR1
            defer "output+='2'" USR1
            kill -USR1 $$
            test "$output" = "21H" || return 1
        }

        function test_captures_status() {
            test "$(
                defer 'echo $?' EXIT
                defer 'false' EXIT
                exit 99
            )" -eq 99 || return 1
            # also works with hand-set traps
            test "$(
                trap 'echo $?' EXIT
                defer 'false' EXIT
                exit 99
            )" -eq 99 || return 1
        }

        function test_defer_on_function_exit() {
            test_var=0
            function f() { defer "test_var=1" EXIT; test_var=2; }; f
            # EXIT trap does not run until the script exits, so the value is 2
            test "$test_var" -eq 2 || return 1
        }

        function test_defer_on_function_return() {
            output=""
            function f() { defer "output+='R'" RETURN; output+='f'; }
            function g() { f; output+='g'; }; g
            # R fires exactly once, when f returns: not early at defer's own
            # return, and not again as the stack unwinds through g
            test "$output" = "fRg" || return 1
        }

        function test_defer_in_function_in_subshell() {
            function f() { printf "a"; defer "printf \"b\"" EXIT; };
            test_var=$(f)
            test "$test_var" = "ab" || return 1
        }

        ################# edge-cases / regression tests ###################

        function test_tolerates_trailing_semicolon() {
            test_var=0
            defer "test_var=1;" USR1
            test "$test_var" -eq 0 || return 1
            kill -USR1 $$
            test "$test_var" -eq 1 || return 1
        }

        function test_tolerates_multiple_trailing_semicolons() {
            test_var=0
            defer "test_var=1;;" USR1
            test "$test_var" -eq 0 || return 1
            kill -USR1 $$
            test "$test_var" -eq 1 || return 1
        }

        function test_tolerates_trailing_whitespace() {
            test_var=0
            defer "test_var=1; " USR1
            test "$test_var" -eq 0 || return 1
            kill -USR1 $$
            test "$test_var" -eq 1 || return 1
        }

        function test_rejects_empty_command() {
            # a cmd that is empty (or strips down to empty) must be a defer-time
            # error, not a syntax error when the signal eventually fires
            defer "" USR1 2>/dev/null
            test "$?" -ne 0 || return 1
            defer ";; " USR1 2>/dev/null
            test "$?" -ne 0 || return 1
        }

        function test_no_caller_namespace_leak() {
            new_cmd="keep"; defer_name="keep"; existing_cmd="keep"
            defer "true" USR1
            test "$new_cmd" = "keep" || return 1
            test "$defer_name" = "keep" || return 1
            test "$existing_cmd" = "keep" || return 1
            kill -USR1 $$
        }

        function test_no_signal_returns_error() {
            defer "echo nope" 2>/dev/null
            test "$?" -ne 0 || return 1
        }

        function test_no_args_under_set_u() {
            # must give a clean usage error, not a bash '$1: unbound variable' crash
            local err; err=$( set -u; defer 2>&1 )
            case "$err" in *unbound*) return 1;; esac
            test -n "$err" || return 1
        }

        function test_returns_error_on_bad_signal() {
            defer "true" NOTASIGNAL 2>/dev/null
            test "$?" -ne 0 || return 1
        }

        function test_child_process_can_source() {
            # regression test: __DEFER_SH__ must not be exported
            local got
            got=$(DEFER_SH_PATH="${BASH_SOURCE[0]}" bash -c '
                source "$DEFER_SH_PATH"
                bash -c "source \"\$DEFER_SH_PATH\"; type -t defer"
            ')
            test "$got" = "function" || return 1
        }

        function test_resourcing_preserves_traps() {
            # sourcing defer.sh a second time must be a safe no-op: an already-registered
            # trap survives the re-source, so deferred commands keep their LIFO order.
            local got
            got=$(DEFER_SH_PATH="${BASH_SOURCE[0]}" bash -c '
                source "$DEFER_SH_PATH"
                o=""
                defer "o+=A" USR1
                source "$DEFER_SH_PATH"   # second source must not disturb the trap
                defer "o+=B" USR1
                kill -USR1 $$
                echo "$o"
            ')
            test "$got" = "BA" || return 1
        }

        function test_xtrace_suppression_preserves_caller_return_trap() {
            # regression test. the xtrace-hiding path must not clobber RETURN trap of the caller
            # shellcheck disable=SC2016
            local body='source "$DEFER_SH_PATH"; o=""
                f() { trap "o+=R" RETURN; defer "true" EXIT; }'
            local quiet noisy
            quiet=$(DEFER_SH_PATH="${BASH_SOURCE[0]}" bash -c "$body"'
                f; trap - EXIT; echo "$o"')
            noisy=$(DEFER_SH_PATH="${BASH_SOURCE[0]}" bash -c "$body"'
                set -x; f; set +x; trap - EXIT; echo "$o"' 2>/dev/null)
            test -n "$quiet" || return 1          # sanity: caller trap fired at all
            test "$quiet" = "$noisy" || return 1  # xtrace path must not change it
        }

        function test_set_e_safe() {
            # regression test: a caller with set -e must not abort when calling defer
            local got
            got=$(DEFER_SH_PATH="${BASH_SOURCE[0]}" bash -c '
                set -e
                source "$DEFER_SH_PATH"
                defer "echo c" EXIT
                defer "echo b" EXIT
                defer "echo a" EXIT
                echo go
            ')
            test "$got" = $'go\na\nb\nc' || return 1
        }

        function test_set_e_failing_handler_aborts_rest() {
            # under set -e a failing handler aborts the siblings after it (same as a
            # plain multi-command trap). LIFO fires a, then false (aborts), so c never runs.
            local got rc
            got=$(DEFER_SH_PATH="${BASH_SOURCE[0]}" bash -c '
                set -e
                source "$DEFER_SH_PATH"
                defer "echo c" EXIT
                defer "false" EXIT
                defer "echo a" EXIT
                echo go
            '); rc=$?
            test "$got" = $'go\na' || return 1
            test "$rc" -eq 1 || return 1
        }

        # no color when NO_COLOR is set (any value) or stdout is not a tty
        if [[ -n "${NO_COLOR+x}" || ! -t 1 ]]; then
            c_green="" c_red="" c_reset=""
        else
            c_green=$'\e[32m' c_red=$'\e[31m' c_reset=$'\e[0m'
        fi

        status=0

        # discover test functions in declaration order (declare -F sorts alphabetically)
        # spellchecker: ignore mpass mfail
        while read -r line; do
            [[ $line =~ ^[[:space:]]*function[[:space:]]+(test_[A-Za-z0-9_]+) ]] || continue
            test_func="${BASH_REMATCH[1]}"
            printf "Running %s... " "$test_func"
            if $test_func; then
                printf "%spass%s\n" "$c_green" "$c_reset"
            else
                printf "%sfail%s\n" "$c_red" "$c_reset"
                status=1
            fi
        done < "${BASH_SOURCE[0]}"

        if [[ $status -eq 0 ]]; then
            printf "%sSelf-test passed%s\n" "$c_green" "$c_reset"
        else
            printf "%sSelf-test failed%s\n" "$c_red" "$c_reset"
        fi
    fi

    # no not export __DEFER_SH__. it would leak into child processes
    # (which don't inherit the function) and stop them sourcing defer.
    __DEFER_SH__=1
fi

# restore the caller's xtrace
case $_defer_src_x in *x*) unset _defer_src_x; set -x;; *) unset _defer_src_x;; esac