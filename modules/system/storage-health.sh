set -eu
export LC_ALL=C
cat /proc/mdstat
if ! mdadm --detail --test /dev/md/ryzen; then
    echo "ERROR: MD RAID is degraded, failed, or unavailable" >&2
    exit 1
fi

md_sys=/sys/class/block/$(basename "$(readlink -f /dev/md/ryzen)")/md
read -r action < "$md_sys/sync_action"
read -r mismatches < "$md_sys/mismatch_cnt"
echo "MD RAID sync_action=$action mismatch_cnt=$mismatches"
if [ "$mismatches" -ne 0 ]; then
    echo "ERROR: RAID check found mismatches; inspect before requesting repair" >&2
    exit 1
fi
