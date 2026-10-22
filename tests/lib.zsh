# Minimal test harness. A test is a function named test_*; each one runs in a
# subshell, inside its own temporary directory $T, and stops at the first
# failing command (err_return). Run a subset with name patterns:
#   zsh tests/unit.zsh 'test_git*'

typeset -g ROOT=${${(%):-%x}:A:h:h}
typeset -gi PASS=0 FAIL=0 SKIP=0

fail() { print -u2 -r -- "  $*"; return 1 }

# Mark the current test as skipped, with a reason
skip() { print -r -- "$*" > $T/.skip; exit 0 }

assert_eq() {
  [[ $1 == $2 ]] || fail "expected [$2], got [$1]${3:+ ($3)}"
}
assert_contains() {
  [[ $1 == *$2* ]] || fail "expected to find [$2] in:"$'\n'"$1"
}
assert_not_contains() {
  [[ $1 != *$2* ]] || fail "did not expect [$2] in:"$'\n'"$1"
}
# assert_has ELEMENT ARRAY...: ELEMENT is one of the array's elements
assert_has() {
  local e=$1; shift
  (( ${@[(Ie)$e]} )) || fail "expected element [$e] in:"$'\n'"${(F)@}"
}
assert_lacks() {
  local e=$1; shift
  (( ! ${@[(Ie)$e]} )) || fail "did not expect element [$e]"
}

# Hooks a test file can redefine; both run inside the test's subshell, and
# teardown runs even when the test fails
setup() { : }
teardown() { : }

run_tests() {
  local t log
  local -a tests=(${(ok)functions[(I)test_*]})
  (( $# )) && tests=(${(M)tests:#(${(j:|:)~@})})
  for t in $tests; do
    T=$(mktemp -d) log=$(mktemp)
    if ( cd $T && setup || exit 1
         ( setopt err_return; $t ); local r=$?
         teardown; exit $r ) < /dev/null > $log 2>&1; then
      if [[ -e $T/.skip ]]; then
        SKIP+=1; print -r -- "skip $t: $(<$T/.skip)"
      else
        PASS+=1; print -r -- "ok   $t"
      fi
    else
      FAIL+=1; print -r -- "FAIL $t"
      sed 's/^/     /' $log
    fi
    rm -rf $T $log
  done
  print -r -- "$PASS passed, $FAIL failed, $SKIP skipped"
  (( FAIL == 0 ))
}
