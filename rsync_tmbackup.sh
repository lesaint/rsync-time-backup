#!/usr/bin/env bash

APPNAME=$(basename $0 | sed "s/\.sh$//")

# -----------------------------------------------------------------------------
# Log functions
# -----------------------------------------------------------------------------

fn_log_info()  { echo "$APPNAME: $1"; }
fn_log_warn()  { echo "$APPNAME: [WARNING] $1" 1>&2; }
fn_log_error() { echo "$APPNAME: [ERROR] $1" 1>&2; }
fn_log_info_cmd()  {
    if [ -n "$SSH_CMD" ]; then
        echo "$APPNAME: $SSH_CMD '$1'";
    else
        echo "$APPNAME: $1";
    fi
}

# -----------------------------------------------------------------------------
# Make sure everything really stops when CTRL+C is pressed and clean PID file
# -----------------------------------------------------------------------------

fn_terminate_script() {
    fn_log_info "SIGINT caught, deleting $PID_FILE and exiting."
    rm -f -- "$PID_FILE"
    exit 1
}

trap 'fn_terminate_script' SIGINT

# -----------------------------------------------------------------------------
# Small utility functions for reducing code duplication
# -----------------------------------------------------------------------------

fn_parse_date() {
    # Converts YYYY-MM-DD-HHMMSS to YYYY-MM-DD HH:MM:SS and then to Unix Epoch.
    case "$OSTYPE" in
        linux*) date -d "${1:0:10} ${1:11:2}:${1:13:2}:${1:15:2}" +%s ;;
        cygwin*) date -d "${1:0:10} ${1:11:2}:${1:13:2}:${1:15:2}" +%s ;;
        darwin*) date -j -f "%Y-%m-%d-%H%M%S" "$1" "+%s" ;;
    esac
}

fn_find_backups() {
    #fn_run_cmd "find "$DEST_FOLDER" -type d -name "????-??-??-??????" | sort -r"
    fn_run_cmd "(ls "${DEST_FOLDER}/????-??-??-??????" -1 -d | sort -r | sed 's:/*$::')"
}

fn_expire_backup() {
    # Double-check that we're on a backup destination to be completely
    # sure we're deleting the right folder
    if [ -z "$(fn_find_backup_marker "$(dirname -- "$1")")" ]; then
        fn_log_error "$1 is not on a backup destination - aborting."
        exit 1
    fi

    fn_log_info "Expiring $1"
    fn_rm "$1"
}

fn_parse_ssh() {
    if [[ "$DEST_FOLDER" =~ ^[A-Za-z0-9\._%\+\-]+@[A-Za-z0-9.\-]+\:.+$ ]]; then
        SSH_USER=$(echo "$DEST_FOLDER" | sed -E  's/^([A-Za-z0-9\._%\+\-]+)@([A-Za-z0-9.\-]+)\:(.+)$/\1/')
        SSH_HOST=$(echo "$DEST_FOLDER" | sed -E  's/^([A-Za-z0-9\._%\+\-]+)@([A-Za-z0-9.\-]+)\:(.+)$/\2/')
        SSH_DEST_FOLDER=$(echo "$DEST_FOLDER" | sed -E  's/^([A-Za-z0-9\._%\+\-]+)@([A-Za-z0-9.\-]+)\:(.+)$/\3/')
        SSH_CMD="ssh ${SSH_USER}@${SSH_HOST}"
        SSH_FOLDER_PREFIX="${SSH_USER}@${SSH_HOST}:"
    fi
}

fn_run_cmd() {
    if [ -n "$SSH_CMD" ]; then
        eval "$SSH_CMD '$1'"
    else
        eval $1
    fi
}

fn_find() {
    fn_run_cmd "find $1"  2>/dev/null
}

fn_get_absolute_path() {
    fn_run_cmd "cd $1;pwd"
}

fn_mkdir() {
    fn_run_cmd "mkdir -p -- $1"
}

fn_rm() {
    fn_run_cmd "rm -rf -- $1"
}

fn_touch() {
    fn_run_cmd "touch -- $1"
}

fn_ln() {
    fn_run_cmd "ln -s -- $1 $2"
}

fn_chown_dir() {
    fn_run_cmd "chown -R -- $1 $2"
}

fn_chown_link() {
    local ownerAndGroup="$1"
    local target="$2"
    if [ -n "$ownerAndGroup" ]; then
        fn_run_cmd "chown -h -- $ownerAndGroup $target"
    fi
}

# -----------------------------------------------------------------------------
# Source and destination information
# -----------------------------------------------------------------------------
SSH_USER=""
SSH_HOST=""
SSH_DEST_FOLDER=""
SSH_CMD=""
SSH_FOLDER_PREFIX=""

SRC_FOLDER="${1%/}"
DEST_FOLDER="${2%/}"
EXCLUSION_FILE="$3"
OWNER_AND_GROUP="$4"

fn_parse_ssh

if [ -n "$SSH_DEST_FOLDER" ]; then
    DEST_FOLDER="$SSH_DEST_FOLDER"
fi

for ARG in "$SRC_FOLDER" "$DEST_FOLDER" "$EXCLUSION_FILE"; do
    if [[ "$ARG" == *"'"* ]]; then
        fn_log_error 'Arguments may not have any single quote characters.'
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# Handle case where a backup is already running
# -----------------------------------------------------------------------------
PROFILE_FOLDER="$HOME/.$APPNAME"
PID_FILE="$PROFILE_FOLDER/$APPNAME.pid"

if [ -f "$PID_FILE" ]; then
    PID="$(cat $PID_FILE)"
    if [ -n "$(ps --pid "$PID" 2>&1 | grep "$PID")" ]; then
        fn_log_error "Previous backup task is still active - aborting."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Create profile folder if it doesn't exist
# -----------------------------------------------------------------------------

if [ ! -d "$PROFILE_FOLDER" ]; then
    fn_log_info "Creating profile folder in '$PROFILE_FOLDER'..."
    mkdir -- "$PROFILE_FOLDER"
fi

fn_log_info "Creating $PID_FILE"
echo "$$" > "$PID_FILE"

# -----------------------------------------------------------------------------
# Check that the destination drive is a backup drive
# -----------------------------------------------------------------------------

# TODO: check that the destination supports hard links

fn_backup_marker_path() { echo "$1/backup.marker"; }
fn_find_backup_marker() { fn_find "$(fn_backup_marker_path "$1")" 2>/dev/null; }

if [ -z "$(fn_find_backup_marker "$DEST_FOLDER")" ]; then
    fn_log_info "Safety check failed - the destination does not appear to be a backup folder or drive (marker file not found)."
    fn_log_info "If it is indeed a backup folder, you may add the marker file by running the following command:"
    fn_log_info ""
    fn_log_info_cmd "mkdir -p -- \"$DEST_FOLDER\" ; touch \"$(fn_backup_marker_path "$DEST_FOLDER")\""
    fn_log_info ""
    exit 1
fi

# -----------------------------------------------------------------------------
# Setup additional variables
# -----------------------------------------------------------------------------

# Date logic
NOW=$(date +"%Y-%m-%d-%H%M%S")
EPOCH=$(date "+%s")
KEEP_ALL_DATE=$((EPOCH - 86400))       # 1 day ago
KEEP_DAILIES_DATE=$((EPOCH - 15768000)) # 6 months

export IFS=$'\n' # Better for handling spaces in filenames.
DEST="$DEST_FOLDER/$NOW"
PREVIOUS_DEST="$(fn_find_backups | head -n 1)"
INPROGRESS_FILE="$DEST_FOLDER/backup.inprogress"


# -----------------------------------------------------------------------------
# Handle case where a previous backup failed or was interrupted.
# -----------------------------------------------------------------------------
if [ -n "$(fn_find "$INPROGRESS_FILE")" ]; then
    if [ -n "$PREVIOUS_DEST" ]; then
        # - Last backup is moved to current backup folder so that it can be resumed.
        # - 2nd to last backup becomes last backup.
        fn_log_info "$SSH_FOLDER_PREFIX$INPROGRESS_FILE already exists - the previous backup failed or was interrupted. Backup will resume from there."
        fn_run_cmd "mv -- $PREVIOUS_DEST $DEST"
        if [ "$(fn_find_backups | wc -l)" -gt 1 ]; then
            PREVIOUS_DEST="$(fn_find_backups | sed -n '2p')"
        else
            PREVIOUS_DEST=""
        fi
    fi
fi

# Run in a loop to handle the "No space left on device" logic.
while : ; do

    # -----------------------------------------------------------------------------
    # Check if we are doing an incremental backup (if previous backup exists).
    # -----------------------------------------------------------------------------

    LINK_DEST_OPTION=""
    if [ -z "$PREVIOUS_DEST" ]; then
        fn_log_info "No previous backup - creating new one."
    else
        # If the path is relative, it needs to be relative to the destination. To keep
        # it simple, just use an absolute path. See http://serverfault.com/a/210058/118679
        PREVIOUS_DEST="$(fn_get_absolute_path "$PREVIOUS_DEST")"
        fn_log_info "Previous backup found - doing incremental backup from $SSH_FOLDER_PREFIX$PREVIOUS_DEST"
        LINK_DEST_OPTION="--link-dest='$PREVIOUS_DEST'"
    fi

    # -----------------------------------------------------------------------------
    # Create destination folder if it doesn't already exists
    # -----------------------------------------------------------------------------

    if [ -z "$(fn_find "$DEST -type d" 2>/dev/null)" ]; then
        fn_log_info "Creating destination $SSH_FOLDER_PREFIX$DEST"
        fn_mkdir "$DEST"
    fi

    # -----------------------------------------------------------------------------
    # Purge certain old backups before beginning new backup.
    # -----------------------------------------------------------------------------

    # Default value for $PREV ensures that the most recent backup is never deleted.
    PREV="0000-00-00-000000"
    for FILENAME in $(fn_find_backups | sort -r); do
        BACKUP_DATE=$(basename "$FILENAME")
        TIMESTAMP=$(fn_parse_date $BACKUP_DATE)

        # Skip if failed to parse date...
        if [ -z "$TIMESTAMP" ]; then
            fn_log_warn "Could not parse date: $FILENAME"
            continue
        fi

        if   [ $TIMESTAMP -ge $KEEP_ALL_DATE ]; then
            true
        elif [ $TIMESTAMP -ge $KEEP_DAILIES_DATE ]; then
            # Delete all but the most recent of each day.
            [ "${BACKUP_DATE:0:10}" == "${PREV:0:10}" ] && fn_expire_backup "$FILENAME"
        else
            # Delete all but the most recent of each month.
            [ "${BACKUP_DATE:0:7}" == "${PREV:0:7}" ] && fn_expire_backup "$FILENAME"
        fi

        PREV=$BACKUP_DATE
    done

    # -----------------------------------------------------------------------------
    # Start backup
    # -----------------------------------------------------------------------------

    LOG_FILE="$PROFILE_FOLDER/$(date +"%Y-%m-%d-%H%M%S").log"

    fn_log_info "Starting backup..."
    fn_log_info "From: $SRC_FOLDER"
    fn_log_info "To:   $SSH_FOLDER_PREFIX$DEST"

    CMD="rsync"
    if [ -n "$SSH_CMD" ]; then
        CMD="$CMD  -e 'ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"
    fi
    CMD="$CMD --compress"
    CMD="$CMD --numeric-ids"
    CMD="$CMD --safe-links"
    CMD="$CMD --hard-links"
    CMD="$CMD --one-file-system"
###     start --archive
    CMD="$CMD --recursive"
    CMD="$CMD --links"
    CMD="$CMD --perms"
    CMD="$CMD --times"
#    CMD="$CMD --group"
#    CMD="$CMD --owner"
    CMD="$CMD --devices"
    CMD="$CMD --specials"
###     end --archive
    CMD="$CMD --itemize-changes"
    CMD="$CMD --verbose"
    CMD="$CMD --human-readable"
    CMD="$CMD --log-file '$LOG_FILE'"
    if [ -n "$EXCLUSION_FILE" ]; then
        # We've already checked that $EXCLUSION_FILE doesn't contain a single quote
        CMD="$CMD --exclude-from '$EXCLUSION_FILE'"
    fi
    CMD="$CMD $LINK_DEST_OPTION"
    CMD="$CMD -- '$SRC_FOLDER/' '$SSH_FOLDER_PREFIX$DEST/'"
    CMD="$CMD | grep -E '^deleting|[^/]$'"

    fn_log_info "Running command:"
    fn_log_info "$CMD"

    fn_touch "$INPROGRESS_FILE"
    eval $CMD

    # -----------------------------------------------------------------------------
    # Check if we ran out of space
    # -----------------------------------------------------------------------------

    # TODO: find better way to check for out of space condition without parsing log.
    NO_SPACE_LEFT="$(grep "No space left on device (28)\|Result too large (34)" "$LOG_FILE")"

    if [ -n "$NO_SPACE_LEFT" ]; then
        fn_log_warn "No space left on device - removing oldest backup and resuming."

        if [[ "$(fn_find_backups | wc -l)" -lt "2" ]]; then
            fn_log_error "No space left on device, and no old backup to delete."
            exit 1
        fi

        fn_expire_backup "$(fn_find_backups | tail -n 1)"

        # Resume backup
        continue
    fi

    # -----------------------------------------------------------------------------
    # Check whether rsync reported any errors
    # -----------------------------------------------------------------------------

    if [ -n "$(grep "rsync:" "$LOG_FILE")" ]; then
        fn_log_warn "Rsync reported a warning, please check '$LOG_FILE' for more details."
    fi
    if [ -n "$(grep "rsync error:" "$LOG_FILE")" ]; then
        fn_log_error "Rsync reported an error, please check '$LOG_FILE' for more details."
        exit 1
    fi

    # -----------------------------------------------------------------------------
    # Add symlink to last successful backup
    # -----------------------------------------------------------------------------

    fn_rm "$DEST_FOLDER/latest"
    fn_chown_dir "$OWNER_AND_GROUP" "$DEST"
    fn_ln "$(basename -- "$DEST")" "$DEST_FOLDER/latest"
    fn_chown_link "$OWNER_AND_GROUP" "$DEST_FOLDER/latest"

    fn_rm "$INPROGRESS_FILE"
    fn_log_info "Deleting $PID_FILE"
    rm -f -- "$PID_FILE"
    rm -f -- "$LOG_FILE"

    fn_log_info "Backup completed without errors."

    exit 0
done
