set -eu
export LC_ALL=C

# Do not compete with recovery or try to check an incomplete mirror.
mdadm --detail --test /dev/md/ryzen
md_sys=/sys/class/block/$(basename "$(readlink -f /dev/md/ryzen)")/md
read -r action < "$md_sys/sync_action"
if [ "$action" != idle ]; then
    echo "Skipping RAID check: sync_action=$action"
    exit 0
fi

echo check > "$md_sys/sync_action"
while read -r action < "$md_sys/sync_action" && [ "$action" != idle ]; do
    sleep 10
done
mdadm --detail --test /dev/md/ryzen
read -r mismatches < "$md_sys/mismatch_cnt"
echo "RAID check finished: mismatch_cnt=$mismatches"
test "$mismatches" -eq 0
