#!/bin/bash

###########################################################################
# Tests for directory resolution.
#  * which dir is used for incremental backup
#  * which dir is the latest directory
#  * in regular case, case of interrupted backup and case of bad symlink
# 
# dependencies:
#   * tree
#   * diff
###########################################################################

set -euo pipefail

# enable TEST1's code in rsync_tmpbackup.sh
export TEST1="active"
# inject value returned by fn_now() to ensure reproducible tests
export INJECT_NOW="2024-06-15-190519"

###################################
#--- prepare function for test ---#
###################################
# creates a directory dedicated to this run of tests
fn_prepare_test() {
    mkdir -p "out"
    TEST_DIR="$(mktemp --tmpdir="out" -d test1-XXXXXXXX)"
}

# creates an empty directory
fn_prepare_source_dir() {
    mkdir -p "$TEST_DIR/src"
}

# create a target directory with name 1st argument and executes method 2nd argument in it
fn_prepare_target_dir() {
    local test_dir="$1"
    local prepare_function="$2"
    local target_dir="$TEST_DIR/target/$test_dir"

    echo ""
    echo "**************** $test_dir ****************"

    mkdir -p "$target_dir"
    cd "$target_dir"
    echo "Preparing $test_dir..."
    $prepare_function

    cd "../../../../"
}

#--- common functions used during prepare of a test ---#
fn_marker_file() {
    touch "backup.marker"
}

fn_inprogress_file() {
    touch "backup.inprogress"
}

fn_latest_symlink() {
    local target_dir="$1"
    ln -s "$target_dir" "latest"
}

#####################################
#--- tear down function for test ---#
#####################################
fn_teardown_test() {
    echo ""
    echo "Clean up: deleting ${TEST_DIR}..."
    rm -Rf -- "$TEST_DIR"
}

#######################
#--- test executor ---#
#######################
# Runs the executable under_test with the specified $1 directory as target.
# Output of execution of under_test is set into variable TEST_OUTPUT
fn_run_test() {
    local test_dir="$1"
    local under_test="../../../rsync_tmbackup.sh"
    local out=""

    # ensure no leakage from previous test
    TEST_OUTPUT=""

    # print content of target directory
    tree "$TEST_DIR/target/$test_dir"

    # temporarily do not exit if command returns a non-zero exit code
    # doc: https://www.gnu.org/savannah-checkouts/gnu/bash/manual/bash.html#The-Set-Builtin
    echo "Running $test_dir..."
    cd "$TEST_DIR"
    # make sure executable exists and is accessible
    if ! [ -x "$under_test" ]; then
        echo "$(pwd)/$under_test is not accessible or executable"
        exit 1
    fi
    set +e
    TEST_OUTPUT="$( ${under_test} "src" "target/$test_dir" 2>&1 )"
    set -e
    cd "../.."
    echo "$TEST_OUTPUT"
}

####################
#--- assertions ---#
####################
# checks whether a single line is present in TEST_OUTPUT
fn_test_output_contains_line() {
    local expected="$1"
    # declare line local to prevent leak of lines read in this function out of it
    local line=""

    # read TEST_OUTPUT line by line and compare each of them to searched line
    # source: https://superuser.com/a/284226
    while IFS= read -r line; do
        if [ "$line" == "$expected" ]; then
            return 0
        fi
    done <<< "$TEST_OUTPUT"
    return 1
}

# checks whether test output contains all the specified lines (one line per argument), IN NO SPECIFIC ORDER
fn_test_output_contains_lines() {
    local line=""
    for line in "$@"; do
        if ! fn_test_output_contains_line "${line}"; then
            echo "[TEST FAILURE] Expecting output to contain \"$line\""
            exit 1
        fi
    done
}

# checks that the last lines of TEST_OUTPUT are the same as the lines provided as arguments (IN ORDER)
fn_test_output_ends_with() {
    # concatenating arguments with new lines in between
    # source: https://www.baeldung.com/linux/add-newline-variable-bash#4-shell-parameter-expansion
    local expected=""
    for arg in "$@"; do
        expected="${expected}${arg}"$'\n'
    done
    # remove trailing \n
    expected="${expected::-1}"

    # capture the last n lines of TEST_OUTPUT
    # $# is the number of arguments
    local tested=$(echo "$TEST_OUTPUT" | tail "-$#")

    # diff between two variables
    # source: https://stackoverflow.com/a/13437445
    if ! diff <(echo "$tested") <(echo "$expected"); then
        echo "[TEST FAILURE] Expecting output to end with (see diff output above):"
        for arg in "$@"; do
            echo "  $arg"
        done
        exit 1
    fi
}


##########################
#--- the actual tests ---#
##########################
# Test level preparation
fn_prepare_test
# same source dir is used for all tests
fn_prepare_source_dir


fn_prepare_no_marker_file() {
    # do nothing
    echo "(keep directory totally empty)"
}
fn_prepare_target_dir "no_marker_file" "fn_prepare_no_marker_file"
fn_run_test "no_marker_file"
fn_test_output_contains_lines \
    "rsync_tmbackup: Safety check failed - the destination does not appear to be a backup folder or drive (marker file not found)." \
    "rsync_tmbackup: mkdir -p -- \"target/no_marker_file\" ; touch \"target/no_marker_file/backup.marker\""


fn_prepare_empty() {
    # just a marker file
    fn_marker_file
}
fn_prepare_target_dir "empty" "fn_prepare_empty"
fn_run_test "empty"
fn_test_output_ends_with \
    "TEST1: SYM_LINK=target/empty/latest DEST=target/empty/${INJECT_NOW} LINK_DEST= LAST_BACKUP_DIR=" \
    "TEST1: SYM_LINK=target/empty/latest DEST=target/empty/${INJECT_NOW} LINK_DEST= LAST_BACKUP_DIR=" \
    "TEST1: end execution"


fn_prepare_1st_backup() {
    fn_marker_file
    mkdir "2022-04-19-202210"
    fn_latest_symlink "2022-04-19-202210"
}
fn_prepare_target_dir "1st_backup" "fn_prepare_1st_backup"
fn_run_test "1st_backup"
fn_test_output_ends_with \
    "rsync_tmbackup: target/1st_backup/latest exists and targets existing directory target/1st_backup/2022-04-19-202210." \
    "TEST1: SYM_LINK=target/1st_backup/latest DEST=target/1st_backup/${INJECT_NOW} LINK_DEST=target/1st_backup/2022-04-19-202210 LAST_BACKUP_DIR=target/1st_backup/2022-04-19-202210" \
    "TEST1: SYM_LINK=target/1st_backup/latest DEST=target/1st_backup/${INJECT_NOW} LINK_DEST=target/1st_backup/2022-04-19-202210 LAST_BACKUP_DIR=target/1st_backup/2022-04-19-202210" \
    "TEST1: end execution"


fn_prepare_1st_backup_interrupted() {
    fn_marker_file
    mkdir "2022-04-19-202210"
    # no latest symlink yet
    fn_inprogress_file
}
fn_prepare_target_dir "1st_backup_interrupted" "fn_prepare_1st_backup_interrupted"
fn_run_test "1st_backup_interrupted"
fn_test_output_ends_with \
    "TEST1: SYM_LINK=target/1st_backup_interrupted/latest DEST=target/1st_backup_interrupted/${INJECT_NOW} LINK_DEST=target/1st_backup_interrupted/2022-04-19-202210 LAST_BACKUP_DIR=target/1st_backup_interrupted/2022-04-19-202210" \
    "rsync_tmbackup: target/1st_backup_interrupted/backup.inprogress already exists - the previous backup failed or was interrupted. Backup will resume from there." \
    "TEST1: SYM_LINK=target/1st_backup_interrupted/latest DEST=target/1st_backup_interrupted/${INJECT_NOW} LINK_DEST= LAST_BACKUP_DIR=target/1st_backup_interrupted/2022-04-19-202210" \
    "TEST1: end execution"


fn_prepare_target_2nd_backup() {
    fn_marker_file
    mkdir "2022-04-19-202210"
    mkdir "2022-10-25-213541"
    fn_latest_symlink "2022-10-25-213541"
}
fn_prepare_target_dir "2nd_backup" "fn_prepare_target_2nd_backup"
fn_run_test "2nd_backup"
fn_test_output_ends_with \
    "rsync_tmbackup: target/2nd_backup/latest exists and targets existing directory target/2nd_backup/2022-10-25-213541." \
    "TEST1: SYM_LINK=target/2nd_backup/latest DEST=target/2nd_backup/${INJECT_NOW} LINK_DEST=target/2nd_backup/2022-10-25-213541 LAST_BACKUP_DIR=target/2nd_backup/2022-10-25-213541" \
    "TEST1: SYM_LINK=target/2nd_backup/latest DEST=target/2nd_backup/${INJECT_NOW} LINK_DEST=target/2nd_backup/2022-10-25-213541 LAST_BACKUP_DIR=target/2nd_backup/2022-10-25-213541" \
    "TEST1: end execution"


fn_prepare_target_2nd_backup_interrupted() {
    fn_marker_file
    mkdir "2022-04-19-202210"
    mkdir "2022-10-25-213541"
    fn_latest_symlink "2022-04-19-202210"
    fn_inprogress_file
}
fn_prepare_target_dir "2nd_backup_interrupted" "fn_prepare_target_2nd_backup_interrupted"
fn_run_test "2nd_backup_interrupted"
fn_test_output_ends_with \
    "rsync_tmbackup: target/2nd_backup_interrupted/latest exists and targets existing directory target/2nd_backup_interrupted/2022-04-19-202210." \
    "TEST1: SYM_LINK=target/2nd_backup_interrupted/latest DEST=target/2nd_backup_interrupted/${INJECT_NOW} LINK_DEST=target/2nd_backup_interrupted/2022-04-19-202210 LAST_BACKUP_DIR=target/2nd_backup_interrupted/2022-10-25-213541" \
    "rsync_tmbackup: target/2nd_backup_interrupted/backup.inprogress already exists - the previous backup failed or was interrupted. Backup will resume from there." \
    "TEST1: SYM_LINK=target/2nd_backup_interrupted/latest DEST=target/2nd_backup_interrupted/${INJECT_NOW} LINK_DEST=target/2nd_backup_interrupted/2022-04-19-202210 LAST_BACKUP_DIR=target/2nd_backup_interrupted/2022-10-25-213541" \
    "TEST1: end execution"


fn_prepare_target_5th_backup() {
    fn_marker_file
    mkdir "2022-04-19-202210"
    mkdir "2022-10-25-213541"
    mkdir "2023-04-30-181436"
    mkdir "2023-07-27-213919"
    mkdir "2023-09-25-170232"
    fn_latest_symlink "2023-09-25-170232"
}
fn_prepare_target_dir "5th_backup" "fn_prepare_target_5th_backup"
fn_run_test "5th_backup"
fn_test_output_ends_with \
    "rsync_tmbackup: target/5th_backup/latest exists and targets existing directory target/5th_backup/2023-09-25-170232." \
    "TEST1: SYM_LINK=target/5th_backup/latest DEST=target/5th_backup/${INJECT_NOW} LINK_DEST=target/5th_backup/2023-09-25-170232 LAST_BACKUP_DIR=target/5th_backup/2023-09-25-170232" \
    "TEST1: SYM_LINK=target/5th_backup/latest DEST=target/5th_backup/${INJECT_NOW} LINK_DEST=target/5th_backup/2023-09-25-170232 LAST_BACKUP_DIR=target/5th_backup/2023-09-25-170232" \
    "TEST1: end execution"


fn_prepare_target_6th_backup_interrupted() {
    fn_marker_file
    mkdir "2022-04-19-202210"
    mkdir "2022-10-25-213541"
    mkdir "2023-04-30-181436"
    mkdir "2023-07-27-213919"
    mkdir "2023-09-25-170232"
    mkdir "2023-11-30-181650"
    fn_latest_symlink "2023-09-25-170232"
    fn_inprogress_file
}
fn_prepare_target_dir "6th_backup_interrupted" "fn_prepare_target_6th_backup_interrupted"
fn_run_test "6th_backup_interrupted"
fn_test_output_ends_with \
    "rsync_tmbackup: target/6th_backup_interrupted/latest exists and targets existing directory target/6th_backup_interrupted/2023-09-25-170232." \
    "TEST1: SYM_LINK=target/6th_backup_interrupted/latest DEST=target/6th_backup_interrupted/${INJECT_NOW} LINK_DEST=target/6th_backup_interrupted/2023-09-25-170232 LAST_BACKUP_DIR=target/6th_backup_interrupted/2023-11-30-181650" \
    "rsync_tmbackup: target/6th_backup_interrupted/backup.inprogress already exists - the previous backup failed or was interrupted. Backup will resume from there." \
    "TEST1: SYM_LINK=target/6th_backup_interrupted/latest DEST=target/6th_backup_interrupted/${INJECT_NOW} LINK_DEST=target/6th_backup_interrupted/2023-09-25-170232 LAST_BACKUP_DIR=target/6th_backup_interrupted/2023-11-30-181650" \
    "TEST1: end execution"


fn_prepare_target_multiple_backups_interrupted() {
    fn_marker_file
    mkdir "2022-04-19-202210"
    mkdir "2022-10-25-213541"
    mkdir "2023-04-30-181436"
    mkdir "2023-07-27-213919"
    mkdir "2023-09-25-170232"
    mkdir "2023-11-30-181650"
    mkdir "2023-12-05-211641"
    mkdir "2024-01-29-153423"
    fn_latest_symlink "2023-09-25-170232"
    fn_inprogress_file
}
fn_prepare_target_dir "multiple_backups_interrupted" "fn_prepare_target_multiple_backups_interrupted"
fn_run_test "multiple_backups_interrupted"
fn_test_output_ends_with \
    "rsync_tmbackup: target/multiple_backups_interrupted/latest exists and targets existing directory target/multiple_backups_interrupted/2023-09-25-170232." \
    "TEST1: SYM_LINK=target/multiple_backups_interrupted/latest DEST=target/multiple_backups_interrupted/${INJECT_NOW} LINK_DEST=target/multiple_backups_interrupted/2023-09-25-170232 LAST_BACKUP_DIR=target/multiple_backups_interrupted/2024-01-29-153423" \
    "rsync_tmbackup: target/multiple_backups_interrupted/backup.inprogress already exists - the previous backup failed or was interrupted. Backup will resume from there." \
    "TEST1: SYM_LINK=target/multiple_backups_interrupted/latest DEST=target/multiple_backups_interrupted/${INJECT_NOW} LINK_DEST=target/multiple_backups_interrupted/2023-09-25-170232 LAST_BACKUP_DIR=target/multiple_backups_interrupted/2024-01-29-153423" \
    "TEST1: end execution"


fn_prepare_target_5th_backup_and_bad_symlink() {
    fn_marker_file
    mkdir "2022-04-19-202210"
    mkdir "2022-10-25-213541"
    mkdir "2023-04-30-181436"
    mkdir "2023-07-27-213919"
    mkdir "2023-09-25-170232"
    fn_latest_symlink "non-existant-directory"
}
fn_prepare_target_dir "5th_backup_and_bad_symlink" "fn_prepare_target_5th_backup_and_bad_symlink"
fn_run_test "5th_backup_and_bad_symlink"
fn_test_output_contains_lines \
    "rsync_tmbackup: [WARNING] /target/5th_backup_and_bad_symlink/latest points to non existing directory target/5th_backup_and_bad_symlink/non-existant-directory. Ignoring sym link."
fn_test_output_ends_with \
    "TEST1: SYM_LINK=target/5th_backup_and_bad_symlink/latest DEST=target/5th_backup_and_bad_symlink/${INJECT_NOW} LINK_DEST=target/5th_backup_and_bad_symlink/2023-09-25-170232 LAST_BACKUP_DIR=target/5th_backup_and_bad_symlink/2023-09-25-170232" \
    "TEST1: SYM_LINK=target/5th_backup_and_bad_symlink/latest DEST=target/5th_backup_and_bad_symlink/${INJECT_NOW} LINK_DEST=target/5th_backup_and_bad_symlink/2023-09-25-170232 LAST_BACKUP_DIR=target/5th_backup_and_bad_symlink/2023-09-25-170232" \
    "TEST1: end execution"


fn_prepare_target_4th_backup_interrupted_and_bad_symlink() {
    fn_marker_file
    mkdir "2022-04-19-202210"
    mkdir "2022-10-25-213541"
    mkdir "2023-04-30-181436"
    mkdir "2023-07-27-213919"
    fn_latest_symlink "non-existant-directory"
    fn_inprogress_file
}
fn_prepare_target_dir "4th_backup_interrupted_and_bad_symlink" "fn_prepare_target_4th_backup_interrupted_and_bad_symlink"
fn_run_test "4th_backup_interrupted_and_bad_symlink"
fn_test_output_contains_lines \
    "rsync_tmbackup: [WARNING] /target/4th_backup_interrupted_and_bad_symlink/latest points to non existing directory target/4th_backup_interrupted_and_bad_symlink/non-existant-directory. Ignoring sym link."
fn_test_output_ends_with \
    "TEST1: SYM_LINK=target/4th_backup_interrupted_and_bad_symlink/latest DEST=target/4th_backup_interrupted_and_bad_symlink/${INJECT_NOW} LINK_DEST=target/4th_backup_interrupted_and_bad_symlink/2023-07-27-213919 LAST_BACKUP_DIR=target/4th_backup_interrupted_and_bad_symlink/2023-07-27-213919" \
    "rsync_tmbackup: target/4th_backup_interrupted_and_bad_symlink/backup.inprogress already exists - the previous backup failed or was interrupted. Backup will resume from there." \
    "TEST1: SYM_LINK=target/4th_backup_interrupted_and_bad_symlink/latest DEST=target/4th_backup_interrupted_and_bad_symlink/${INJECT_NOW} LINK_DEST=target/4th_backup_interrupted_and_bad_symlink/2023-04-30-181436 LAST_BACKUP_DIR=target/4th_backup_interrupted_and_bad_symlink/2023-07-27-213919" \
    "TEST1: end execution"

fn_teardown_test