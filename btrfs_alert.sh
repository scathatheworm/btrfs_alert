#!/bin/bash
## Usage: This script is intended to monitor btrfs wasted space in data chunks
## by logging a WARNING for btrfs balance required to syslog
## Intended to be deployed with cron, frequency at admin discretion


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

for filesystem in `grep btrfs /proc/mounts | awk '{print $2}'`
do

	# Only proceed for filesystems with over 20% used space
	# Even if data/metadata are unbalanced, at 20% usage there is no risk
	# for problems, since btrfs chunk allocation algorithm will correct on
	# actual space usage growth

	fsusage=`df -P $filesystem | grep "$filesystem" | awk '{print $5}' | sed 's/%//'`
	if [[ $fsusage -gt 20 ]]
	then
		
		# Get btrfs usage info and store in an array
		# Only analyze Metadata, which can cause problems if we run out of space
		# less space and don't cause issues

		dataarray=(`btrfs fi df $filesystem | grep Meta | awk -F= '{print $2 " " $3}' | awk -F[\ ,] '{print $1 " " $4}'`)
		
		# Only proceed if there is useful output stored in the array

		if [[ -n ${dataarray[0]} ]] && [[ -n ${dataarray[1]} ]]
		then
			totaldata=$(normalise_string_size ${dataarray[0]})
			useddata=$(normalise_string_size ${dataarray[1]})
			used_percent=`echo "$useddata * 100 / $totaldata" | bc`
			
			# Print an alert to syslog if the metadata chunks
			# are over 80% used and filesystem usage is over 80%

			if [[ $used_percent -ge 80 ]] && [[ $fsusage -ge 80 ]]
			then
				logger -t WARNING "Btrfs balance required on filesystem $filesystem, run \"btrfs balance start -v $filesystem\" to correct this issue"
			fi
		fi
	fi
done
