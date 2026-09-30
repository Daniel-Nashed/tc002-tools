#!/bin/sh
# AWTRIX's own autostart hook - the only way to start Dropbear automatically
# on a device that already runs AWTRIX (network ADB is gone, see
# install/discover_device.sh). Laid down once during first-time deployment
# by install/install_awtrix_autostart.sh at
# /data/awtrix-ng/state/autostart - AWTRIX execs it directly, so it must
# stay a valid, executable #!/bin/sh script.
#
# /tmp/autostart.trace records when this last ran (tmpfs, lost on reboot -
# just enough to confirm timing if boot-order ever needs debugging again).
date >> /tmp/autostart.trace
/data/bin/init.sh
exit 0
