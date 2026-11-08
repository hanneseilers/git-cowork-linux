# GNU make reads this file before Makefile. macOS keeps using the upstream
# Makefile unchanged; Linux uses Scripts/linux/linux.mk. Keeping the Linux
# rules apart means upstream changes to Makefile merge without conflicts.
ifeq ($(shell uname -s),Linux)
include Scripts/linux/linux.mk
else
include Makefile
endif
