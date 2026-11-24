#!/bin/zsh
# Transparent wrapper around AirPointer's ClosedCaseMotion.bin.
# Copies the helper's stdout to ~/Projects/MinePointer/logs and records start, exit code and end time.
# Install: tools/install-helper-logger.zsh (renames the real helper to ClosedCaseMotion.real).
real="${0:A:h}/ClosedCaseMotion.real"
log=~/Projects/MinePointer/logs/helper-$(date +%Y%m%d-%H%M%S)
mkdir -p ${log:h}
print "start $(date +%s) args $*" > $log.meta
"$real" "$@" > >(tee $log.txt) &
pid=$!
trap 'kill -TERM $pid 2>/dev/null' TERM INT HUP
while :; do wait $pid; rc=$?; kill -0 $pid 2>/dev/null || break; done
print "exit $rc end $(date +%s)" >> $log.meta
exit $rc
