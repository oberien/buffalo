#!/bin/bash2
# Power Management Control Daemon
# Version 1.00
# Y.H.

. /etc/melco/info
. /usr/local/lib/libsys.sh
[ -f /etc/nas_feature ] && . /etc/nas_feature

PIDFILE=/var/run/pmcd.pid
MY_NAME=`basename $0`

if [ -f /proc/buffalo/gpio/switch/auto_power ] ; then
	AUTO_POWER_LOC=/proc/buffalo/gpio/switch/auto_power
else
	AUTO_POWER_LOC=/proc/buffalo/auto_power
fi

if [ -f /proc/buffalo/gpio/switch/sw_control ] ; then
	echo on > /proc/buffalo/gpio/switch/sw_control
fi

OLD_SW_STAT=""
LAST_CHECK_UPTIME=""

POLL_PERIOD=3

RAID_KEEP_ALIVE_FILE="/proc/mdstat"
RAID_KEEP_ALIVE_KEY=("recover" "resync")
DISK_KEEP_ALIVE_FILE=("/var/lock/disk" "/var/lock/zero_filling")
BKUP_KEEP_ALIVE_PS=("rsbackup.pl" "rsync")
FWUP_KEEP_ALIVE_FILE="/boot/file_receive.tmp"
FLAG_GUESS_FW_UPDATING=0
WAIT_TIME_FW_UPDATE=300
OLD_KEEP_ALIVE_CONDITION=0

KAC_RAID=1
KAC_DISK=2
KAC_BKUP=3
KAC_FWUP=4

IsKeepAliveCondition()
{
	COUNTER=0
	while [ "${RAID_KEEP_ALIVE_KEY[${COUNTER}]}" ]
	do
		IS_RAID_KEEP_ALIVE_COND=`grep ${RAID_KEEP_ALIVE_KEY[${COUNTER}]} ${RAID_KEEP_ALIVE_FILE}`
		if [ "${IS_RAID_KEEP_ALIVE_COND}" != "" ] ; then
			return ${KAC_RAID}
		fi
		COUNTER=$((${COUNTER} + 1))
	done

	COUNTER=0
	while [ "${DISK_KEEP_ALIVE_FILE[${COUNTER}]}" ]
	do
		if [ -f "${DISK_KEEP_ALIVE_FILE[${COUNTER}]}" ] ; then
			return ${KAC_DISK}
		fi
		COUNTER=$((${COUNTER} + 1))
	done

	COUNTER=0
	while [ "${BKUP_KEEP_ALIVE_PS[${COUNTER}]}" ]
	do
		IS_BKUP_KEEP_ALIVE_COND=`ps |grep ${BKUP_KEEP_ALIVE_PS[${COUNTER}]}|grep -v grep`
		if [ "${IS_BKUP_KEEP_ALIVE_COND}" != "" ] ; then
			return ${KAC_BKUP}
		fi
		COUNTER=$((${COUNTER} + 1))
	done

	if [ -f "${FWUP_KEEP_ALIVE_FILE}" ] ; then
		FLAG_GUESS_FW_UPDATING=1
		FWUP_PROCESS_WAIT_COUNTER=${WAIT_TIME_FW_UPDATE}
		return ${KAC_FWUP}
	elif [ ${FLAG_GUESS_FW_UPDATING} -eq 1 ] ; then
		if [ ${FWUP_PROCESS_WAIT_COUNTER} -gt 0 ] ; then
			FWUP_PROCESS_WAIT_COUNTER=$((${FWUP_PROCESS_WAIT_COUNTER} - ${POLL_PERIOD}))
			return ${KAC_FWUP}
		else
			FLAG_GUESS_FW_UPDATING=0
		fi
	fi

	return 0
}

CleanupExit()
{
	rm -f ${PIDFILE}
}

ExitMySelfWithReboot()
{
	CleanupExit
	sleep 60
	reboot
	exit 0
}

CheckStatus()
{
	SW_STAT=`cat ${AUTO_POWER_LOC}`
	IsStandbyMode
	PW_STAT=$?
	# DISK_STAT=
	#
	if [ "${LAST_CHECK_UPTIME}" = "" ] ; then
		LAST_CHECK_UPTIME=`cat /proc/uptime|sed -e "s/\..*//"`
	fi

	if [ "${SW_STAT}" = "on" -a "${PW_STAT}" = 1 ] ; then
		#   auto_power on and standby mode.
		##  need bootup by active packet from clients.
		### so in this case, need pwrmgr active.
		PWRMGR_PID=`pidof pwrmgr`
		if [ "${PWRMGR_PID}" = "" ] ; then
			/etc/init.d/pwrmgr.sh start
		fi

		#  if switch is switched to on from off.
		## neeed bootup.

		if [ "${OLD_SW_STAT}" = "off" ] ; then
			pwrmgr -c localhost act
		fi

		/bin/bash2 /usr/local/bin/backup_control.sh check
		if [ $? -eq 1 ] ; then
			if [ "${SUPPORT_WAKEUP_BY_REBOOT:-1}" = "1" ] ; then
				/sbin/reboot
			else
				pwrmgr -c localhost act
				ExitMySelfWithReboot
			fi
		fi

	elif [ "${SW_STAT}" = "on" -a "${PW_STAT}" = 0 ] ; then
		#   auto powr on and normal mode.
		##  need shutdown by shutdown packet from clients.
		### so in this case, need pwrmgr keep active.
		PWRMGR_PID=`pidof pwrmgr`
		if [ "${PWRMGR_PID}" = "" ] ; then
			QUIET=1 /etc/init.d/pwrmgr.sh start
		fi

		# if this is a first boot, register localhost to act list.
		if [ "${OLD_SW_STAT}" = "" -o "${OLD_SW_STAT}" = "off" ] ; then
			pwrmgr -c localhost act
		fi

		# check keep alive condition
		IsKeepAliveCondition
		KEEP_ALIVE_CONDITION=$?
		if [ ${KEEP_ALIVE_CONDITION} -gt 0 ] ; then
			pwrmgr -c localhost act
		fi

		PRESENT_UPTIME=`cat /proc/uptime|sed -e "s/\..*//"`
		if [ $((${PRESENT_UPTIME} - 200)) -ge ${LAST_CHECK_UPTIME} ] ; then
			/bin/bash2 /usr/local/bin/backup_control.sh check
			if [ $? -eq 1 ] ; then
				pwrmgr -c localhost act
			fi
			LAST_CHECK_UPTIME=${PRESENT_UPTIME}
		fi

	elif [ "${SW_STAT}" = "off" -a "${PW_STAT}" = 1 ] ; then
		#   auto_power off and standby mode
		##  can't bootup by active packet from clients.
		### so in this case, kill pwrmgr
		PWRMGR_PID=`pidof pwrmgr`
		if [ "${PWRMGR_PID}" != "" ] ; then
			/etc/init.d/pwrmgr.sh stop
		fi

		#   if switched to off from on
		##  in this case need to bootup. 
		### so pwrmgr bootup and localhost activate.
		if [ "${OLD_SW_STAT}" = "on" ] ; then
			/etc/init.d/pwrmgr.sh start
			sleep 3
			pwrmgr -c localhost act
			ExitMySelfWithReboot
		fi

	elif [ "${SW_STAT}" = "off" -a "${PW_STAT}" = 0 ] ; then
		#   auto_power off and normal mode
		#   kill pwrmgr because of no need to check packet.
		PWRMGR_PID=`pidof pwrmgr`
		if [ "${PWRMGR_PID}" != "" ] ; then
			QUIET=1 /etc/init.d/pwrmgr.sh stop
		fi

		IsKeepAliveCondition
		KEEP_ALIVE_CONDITION=$?
		if [ ${KEEP_ALIVE_CONDITION} -gt 0 ] ; then
			OLD_KEEP_ALIVE_CONDITION=${KEEP_ALIVE_CONDITION}
		else
			if [ ${OLD_KEEP_ALIVE_CONDITION} -gt 0 ] ; then
				if [ ${OLD_KEEP_ALIVE_CONDITION} -eq ${KAC_RAID} -a "`/usr/local/bin/libbuffalo_bin config read raidfail_shutdown.info.melco.etc`" = "on" ] ; then
					:
				else
					/usr/local/sbin/PowerSave.sh standby-cron
				fi
			fi
			OLD_KEEP_ALIVE_CONDITION=0
		fi
	fi

	OLD_SW_STAT=${SW_STAT}
}

Daemon()
{
	if [ "${pwrmgr}" = off ] ; then
		exit 0
	fi

	while [ 1 ]
	do
		CheckStatus
		sleep ${POLL_PERIOD}
	done
}

# signal settings.
trap CleanupExit INT
trap CleanupExit TERM
trap CleanupExit ILL
trap CleanupExit QUIT
trap CleanupExit ABRT
trap CleanupExit KILL

if [ "${1}" = "start" ] ; then
	if [ -f ${PIDFILE} ] ; then
		kill -CONT `cat ${PIDFILE}`
		if [ $? -eq 0 ] ; then
			exit 0
		fi
	fi
	Daemon &
	echo $! > ${PIDFILE}
elif [ "${1}" = "stop" ] ; then
	TMP=`cat ${PIDFILE}`
	kill ${TMP}
	CleanupExit
else
	:
fi
