#!/bin/bash
## Licensed under GPLv2
## Author: David Ponessa

## Usage: This script is intended to monitor btrfs wasted space in data chunks
## by logging a WARNING for btrfs balance required to syslog, and optionally
## perform a balance.
## Intended to be deployed with cron, frequency at admin discretion.
## Recommended to run during system low filessytem IO activity: avoid
## overlapping with backups, when users expect most responsiveness, etc.

# Some sane defaults, FS_TH is the filesystem usage threshold for taking
# action/alerting.
# BTRFS_TH is the used data/allocated space percentage below which to take
# action/rebalance.
# If metadata usage is ABOVE the threshold there is risk of issues for running
# out of metadata space, btrfs will say there is no more space, because there
# are no free metadata block to store structure.
# If data usage is BELOW the threshold then btrfs will report an artificially
# high filesystem usage, and can also cause an out of space issue.
# The filesystem threshold is there to prevent taking action when there is
# plenty of space left for allocation
FS_TH=60
BTRFS_TH=70
META_TH=85

# The balance and meta balance lists provide an iteration approach to balance
# tasks to not stress needlessly the system while balancing.
# Metadata is much more stable and easier to balance hence the list is shorter.
BALANCE_LIST="0 5 10 15 25 50 75"
META_BALANCE_LIST="0 5 10 15 25 50"

# Set a sane path
PATH=/sbin:/usr/sbin:/bin:/usr/bin:$PATH

# Check for some binaries to be present
COMMANDS="awk sed df logger btrfs bc"
for i in $COMMANDS
do
        cmd=`which ${i} 2> /dev/null`
        if [[ -z ${cmd} ]]
        then
                echo "Binary ${i} not found, aborting"
                exit 1
        fi
done

# Get options for autobalance and thresholds
while getopts t:b:m:fh option
do
	case "${option}"
        in
        t) FS_TH=${OPTARG};;
        b) BTRFS_TH=${OPTARG};;
        m) META_TH=${OPTARG};;
        f) FIX=true;;
        h) echo "Usage: [ -t filesystem_threshold ] [ -b btrfs_data_threshold ] [-m btrfs_metadata_threshold] [ -f ]" && exit 0 ;;
        esac
done

# If we are instructed to run balance, expect to be run as root or fail
if [[ "$FIX" ]] && [[ $EUID -ne 0 ]]; then
   echo "Option -f requires superuser privileges"
   exit 1
fi

# Function to convert a string of either KB, MB, GB, TB into number of bytes
# for use in operations
function normalise_string_size() {
	local _value=`echo $1 | sed 's/[KMGT][i]\?B//'`
	if [[ $1 == *"KB" ]] || [[ $1 == *"KiB" ]]
	then
		local _normalsize=`echo "$_value * 1024" | bc`
	elif [[ $1 == *"MB" ]] || [[ $1 == *"MiB" ]]
	then
		local _normalsize=`echo "$_value * 1024 * 1024" | bc`
	elif [[ $1 == *"GB" ]] || [[ $1 == *"GiB" ]]
	then
		local _normalsize=`echo "$_value * 1024 * 1024 * 1024" | bc`
	elif [[ $1 == *"TB" ]] || [[ $1 == *"TiB" ]]
	then
		local _normalsize=`echo "$_value * 1024 * 1024 * 1024 * 1024" | bc`
	fi
	echo $_normalsize
}

# Start of main code execution
# Search for btrfs mounted filesystems and iterate

for filesystem in `awk '$3 == "btrfs" { print $2 }' /proc/mounts`
do

	# Only proceed for filesystems with use space over FS_TH
	fsusage=`df -P $filesystem | awk '$5 ~ "%" {print substr($5, 1, length($5)-1)}'`
	if [[ $fsusage -ge $FS_TH ]]
	then
		# Get btrfs usage info and store in an array

		metadataarray=(`btrfs fi df $filesystem | grep Meta | awk -F= '{print $2 " " $3}' | awk -F[\ ,] '{print $1 " " $4}'`)
                dataarray=(`btrfs fi df $filesystem | grep Data | awk -F= '{print $2 " " $3}' | awk -F[\ ,] '{print $1 " " $4}'`)

		# Only proceed if there is useful output stored in the array

		if [[ -n ${dataarray[0]} ]] && [[ -n ${dataarray[1]} ]]
		then
			totaldata=$(normalise_string_size ${dataarray[0]})
			useddata=$(normalise_string_size ${dataarray[1]})
			used_data_percent=`echo "$useddata * 100 / $totaldata" | bc`

			# Take action for TH detected issues
			if [[ $used_data_percent -le ${BTRFS_TH} ]]
			then
				logger -t WARNING "Btrfs balance required on filesystem $filesystem, you can run \"btrfs balance start -d -v $filesystem\" to correct this issue"
                        	if [[ "$FIX" ]]
                        	then
                        	        logger -t WARNING "Autobalance enabled. Btrfs balance starting..."
                        	        for i in $BALANCE_LIST
                        	        	do btrfs balance start -dusage=${i} $filesystem
                        	        done
                        	        logger -t WARNING "Btrfs balance completed"
				fi
                        fi
		fi

                if [[ -n ${metadataarray[0]} ]] && [[ -n ${metadataarray[1]} ]]
                then
                        totalmetadata=$(normalise_string_size ${metadataarray[0]})
                        usedmetadata=$(normalise_string_size ${metadataarray[1]})
                        used_metadata_percent=`echo "$usedmetadata * 100 / $totalmetadata" | bc`

                        # Take action for TH detected issues
			if [[ $used_metadata_percent -ge ${META_TH} ]]
			then
				logger -t WARNING "Btrfs metadata balance required on filesystem $filesystem, you can run \"btrfs balance start -m -v $filesystem\" to correct this issue"
                        	if [[ "$FIX" ]]
                        	then
                        	        logger -t WARNING "Autobalance enabled. Btrfs metadata balance starting..."
                        	        for i in $META_BALANCE_LIST
                        	        	do btrfs balance start -musage=${i} $filesystem
                        	        done
                        	        logger -t WARNING "Btrfs metadata balance completed"
				fi
                        fi
		fi
	fi
done
