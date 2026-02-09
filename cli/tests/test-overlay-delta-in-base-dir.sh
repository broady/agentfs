#!/bin/sh
set -e

echo -n "TEST overlay readdir/unlink for delta files in base directories... "

TEST_AGENT_ID="test-overlay-delta-in-base-dir-agent"
MOUNTPOINT="/tmp/agentfs-test-overlay-mount-$$"
BASEDIR="/tmp/agentfs-test-overlay-base-$$"

cleanup() {
    # Unmount if mounted
    fusermount -u "$MOUNTPOINT" 2>/dev/null || true
    # Remove directories
    rm -rf "$MOUNTPOINT" "$BASEDIR" 2>/dev/null || true
    # Remove test database
    rm -f ".agentfs/${TEST_AGENT_ID}.db" ".agentfs/${TEST_AGENT_ID}.db-shm" ".agentfs/${TEST_AGENT_ID}.db-wal"
}

# Ensure cleanup on exit
trap cleanup EXIT

# Clean up any existing test artifacts
cleanup

# Create base directory with a subdirectory (simulating .git)
mkdir -p "$BASEDIR/.git"
echo "[core]" > "$BASEDIR/.git/config"
echo "ref: refs/heads/main" > "$BASEDIR/.git/HEAD"
echo "description" > "$BASEDIR/.git/description"

# Initialize the database with --base for overlay
if ! output=$(cargo run -- init "$TEST_AGENT_ID" --base "$BASEDIR" 2>&1); then
    echo "FAILED: init with --base failed"
    echo "Output was: $output"
    exit 1
fi

# Create mountpoint
mkdir -p "$MOUNTPOINT"

# Mount in foreground mode (background it ourselves so we can control it)
cargo run -- mount ".agentfs/${TEST_AGENT_ID}.db" "$MOUNTPOINT" --foreground &
MOUNT_PID=$!

# Wait for mount to be ready
MAX_WAIT=10
WAITED=0
while [ $WAITED -lt $MAX_WAIT ]; do
    if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        break
    fi
    sleep 0.5
    WAITED=$((WAITED + 1))
done

if ! mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
    echo "FAILED: mount did not become ready in time"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

# Verify base directory structure is visible
if [ ! -d "$MOUNTPOINT/.git" ]; then
    echo "FAILED: base .git directory not visible through overlay"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

if [ ! -f "$MOUNTPOINT/.git/config" ]; then
    echo "FAILED: base .git/config file not visible through overlay"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

# Create a new file in the base subdirectory through the overlay
# This triggers ensure_parent_dirs which creates .git in delta with origin mapping
echo "lock content" > "$MOUNTPOINT/.git/index.lock"

# Verify the file was created
if [ ! -f "$MOUNTPOINT/.git/index.lock" ]; then
    echo "FAILED: could not create index.lock in .git directory"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

# Verify readdir shows both base and delta files
# This is the first bug: delta files in base directories were invisible in readdir
LS_OUTPUT=$(ls "$MOUNTPOINT/.git")
if ! echo "$LS_OUTPUT" | grep -q "index.lock"; then
    echo "FAILED: readdir does not show delta file index.lock"
    echo "ls output was: $LS_OUTPUT"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

if ! echo "$LS_OUTPUT" | grep -q "config"; then
    echo "FAILED: readdir does not show base file config"
    echo "ls output was: $LS_OUTPUT"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

if ! echo "$LS_OUTPUT" | grep -q "HEAD"; then
    echo "FAILED: readdir does not show base file HEAD"
    echo "ls output was: $LS_OUTPUT"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

# Delete the delta file
# This is the second bug: unlink failed for delta files in base directories
rm "$MOUNTPOINT/.git/index.lock"

# Verify the file is actually deleted
if [ -f "$MOUNTPOINT/.git/index.lock" ]; then
    echo "FAILED: index.lock still exists after deletion"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

# Verify readdir no longer shows it
LS_OUTPUT_AFTER=$(ls "$MOUNTPOINT/.git")
if echo "$LS_OUTPUT_AFTER" | grep -q "index.lock"; then
    echo "FAILED: readdir still shows index.lock after deletion"
    echo "ls output was: $LS_OUTPUT_AFTER"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

# Base files should still be visible
if ! echo "$LS_OUTPUT_AFTER" | grep -q "config"; then
    echo "FAILED: base file config disappeared after delta file deletion"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

# Test creating and deleting a subdirectory in a base directory
mkdir "$MOUNTPOINT/.git/objects"
if [ ! -d "$MOUNTPOINT/.git/objects" ]; then
    echo "FAILED: could not create objects subdirectory in .git"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

# Verify readdir shows the new directory
LS_WITH_DIR=$(ls "$MOUNTPOINT/.git")
if ! echo "$LS_WITH_DIR" | grep -q "objects"; then
    echo "FAILED: readdir does not show delta directory objects"
    echo "ls output was: $LS_WITH_DIR"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

# Remove the directory (rmdir)
rmdir "$MOUNTPOINT/.git/objects"
if [ -d "$MOUNTPOINT/.git/objects" ]; then
    echo "FAILED: objects directory still exists after rmdir"
    kill $MOUNT_PID 2>/dev/null || true
    exit 1
fi

# --- Base file whiteout tests (promoted parent) ---
# At this point .git/ has been promoted to Delta by the index.lock
# creation above. Test unlink/rename of BASE files in this promoted dir.

# Unlink a base file — whiteout must be created so it doesn't reappear
rm "$MOUNTPOINT/.git/HEAD"

if [ -f "$MOUNTPOINT/.git/HEAD" ]; then
    echo "FAILED: base HEAD still visible after unlink (missing whiteout)"
    exit 1
fi

LS_AFTER_RM=$(ls "$MOUNTPOINT/.git")
if echo "$LS_AFTER_RM" | grep -q "^HEAD$"; then
    echo "FAILED: readdir still shows HEAD after unlink"
    echo "ls output was: $LS_AFTER_RM"
    exit 1
fi

# Recreate at the same path (unlink + recreate pattern)
echo "new HEAD" > "$MOUNTPOINT/.git/HEAD"
if [ ! -f "$MOUNTPOINT/.git/HEAD" ]; then
    echo "FAILED: could not recreate HEAD after unlink"
    exit 1
fi

# Rename a base file in the promoted directory
mv "$MOUNTPOINT/.git/description" "$MOUNTPOINT/.git/description.bak"

if [ -f "$MOUNTPOINT/.git/description" ]; then
    echo "FAILED: description still visible after rename (missing whiteout)"
    exit 1
fi

if [ ! -f "$MOUNTPOINT/.git/description.bak" ]; then
    echo "FAILED: description.bak not visible after rename"
    exit 1
fi

# config (base file) should still be intact
if [ ! -f "$MOUNTPOINT/.git/config" ]; then
    echo "FAILED: base config disappeared"
    exit 1
fi

# Base directory should be untouched
if [ ! -f "$BASEDIR/.git/HEAD" ]; then
    echo "FAILED: base HEAD was modified"
    exit 1
fi

# Unmount
fusermount -u "$MOUNTPOINT"
wait $MOUNT_PID 2>/dev/null || true

echo "OK"
