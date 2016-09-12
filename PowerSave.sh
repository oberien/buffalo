#!/bin/bash

MY_NAME=`basename $0`
lock_file="/var/lock/$MY_NAME"
ln -s "/$MY_NAME" "$lock_file" || exit 1
trap "exit 1"		HUP INT PIPE QUIT TERM
trap "rm $lock_file"	EXIT

PWRMGRCRONTAB=/usr/local/sbin/PwrmgrCrontab
IFILE=/etc/melco/sleep

pwrmgr=on
LOGTAG=PowerSave.sh
LOGFACILITY=local0.info
AUTO_POWER_STATUS_FILE=/proc/buffalo/gpio/switch/auto_power

DAEMON_PID=/var/run/PowerSave.pid

if [ -f /etc/melco/info ]; then
	. /etc/melco/info
fi
if [ "${pwrmgr}" != "on" ] ; then
	echo "pwrmgr is OFF"
	exit 0
fi
if [ ! -f /usr/local/sbin/pwrmgr ]; then
	echo "no pwrmgr"
	exit 0
fi

if [ -f $AUTO_POWER_STATUS_FILE ] ; then
	auto_pwr_stat=`cat $AUTO_POWER_STATUS_FILE`
	if [ "$auto_pwr_stat" == "on" ] ; then
		echo "It is the AutoPower mode now."
		exit 0
	fi
fi

CMD=$1

AROUND=5  # range from 0 to 14
WEEK=("Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat")

isLocked()
{
    if [ -f /var/lock/disk ]; then
	echo "Disk check or Format running..."
	return 1
    fi

    if [ -f /var/lock/zero_filling ] ; then
	echo "Zerofill running..."
	return 1
    fi

    RAID_RECOVER=`grep recover /proc/mdstat`
    if [ "${RAID_RECOVER}" != "" ] ; then
	echo "RAID Recovering..."
	return 1
    fi

    RAID_RESYNC=`grep resync /proc/mdstat`
    if [ "${RAID_RESYNC}" != "" ] ; then
	echo "RAID Resyncing..."
	return 1
    fi

    RSBACKUP=`ps |grep rsbackup.pl|grep -v grep`
    if [ "${RSBACKUP}" != "" ] ; then
	echo "rsbackup.pl working..."
	return 1
    fi

    RSYNC=`ps |grep rsync|grep -v grep`
    if [ "${RSYNC}" != "" ] ; then
	echo "rsync working..."
	return 1
    fi

    if [ -f /boot/file_receive.tmp ] ; then
	echo "FW Receiving..."
	return 1
    fi

    for i in 1 2 3 4 5 6 7 8
    do
	status=`grep "status" /etc/melco/backup$i |sed -e "s%.*=%%"`

	if [ "$status" = "run" ]; then
	    echo "Backup process running..."
	    return 1
	fi
    done

    sem=`cat /var/lock/semaphore`
    if [ $sem -gt 0 ]; then
	echo "running backup task(s) requested from other NAS"
	return 1
    fi

    return 0
}

getNextDay()
{
    i=0
    while [ ${WEEK[$i]} ]
    do
	if [ "$1" = "${WEEK[$i]}" ]; then
	    i=$(($i+1))
	    if [ $i -eq 7 ]; then
		i=0
	    fi
	    echo ${WEEK[$i]}
	    return $i
	fi
	i=$(($i+1))
    done
}

isScheduled()
{
    # Get current day and time
    cur_day=`date |awk '{print $1}'|sed -e "s/^0//"`
    cur_hour=`date |awk '{print $4}'|sed -e "s/:.*//"| sed -e "s/^0//"`
    cur_min=`date |awk '{print $4}'|sed -e "s/:/ /g"|awk '{print $2}'| sed -e "s/^0//"`

    for i in 1 2 3 4 5 6 7 8
    do
	status=`grep "status" /etc/melco/backup$i |sed -e "s%.*=%%"`
	force=`grep "force" /etc/melco/backup$i |sed -e "s%.*=%%"`
	start_time=`grep "start_time" /etc/melco/backup$i |sed -e "s%.*=%%"`
	type=`grep "type" /etc/melco/backup$i |sed -e "s%.*=%%"`
	week=`grep "week" /etc/melco/backup$i |sed -e "s%.*=%%"`

	if [ "$status" = "ready" -o "$status" = "err" -a "$force" = "on" ]
	then
	    sche_hour=`echo $start_time | sed -e "s/:.*//"`
	    sche_min=`echo $start_time | sed -e "s/:/ /" | awk '{print $2}'`
	else
	    continue
	fi

	if [ "$start_time" = "0:00" ]
	then
	    next_day=`getNextDay $cur_day`
	    if [ "$type" = "day" -o "$type" = "week" -a "$week" = "$next_day" ]
	    then
		if [ $cur_hour -eq 23 -a $cur_min -ge $((60-$AROUND)) ]
		then
		    echo "Backup task(s) scheduled... put off standbying"
		    return 1
		fi
	    elif [ "$type" = "day" -o "$type" = "week" -a "$week" = "$cur_day" ]
	    then
		if [ $cur_hour -eq 0 -a $cur_min -le $AROUND ]
		then
		    echo "Backup task(s) scheduled... put off standbying"
		    return 1
		fi
	    fi
	elif [ "$type" = "day" -o "$type" = "week" -a "$week" = "$cur_day" ]
	then
	    if [ $sche_min -eq 00 ]
	    then
		if [ $cur_hour -eq $(($sche_hour-1)) -a $cur_min -ge $((60-$AROUND)) -o $cur_hour -eq $sche_hour -a $cur_min -le $AROUND ]
		then
		    echo "Backup task(s) scheduled... put off standbying"
		    return 1
		fi
	    else
		if [ $cur_hour -eq $sche_hour -a $cur_min -ge $(($sche_min-$AROUND)) -a $cur_min -le $(($sche_min+$AROUND)) ]
		then
		    echo "Backup task(s) scheduled... put off standbying"
		    return 1
		fi
	    fi
	fi
    done

    return 0
}

standby()
{
	echo "go standby"
	if [ -f /etc/linkstation_standby ]; then
		echo "already standby mode"
		exit 0
	fi
	if [ "$CMD" = "standby-cron" ]; then
		$PWRMGRCRONTAB -i $IFILE -c >/tmp/.PwrmgrCrontab.log
		RET=$?
		if [ ${RET} -eq 10 ]; then
			echo "Normal work continuance"
			exit 0 
		fi

		if [ -f ${DAEMON_PID} ] ; then
			RUNNING_PID=`cat ${DAEMON_PID}`
			kill -CONT ${RUNNING_PID}
			if [ $? -eq 0 ] ; then
				echo "PowerSave.sh is already running!" > /dev/console
				exit 0
			fi
		fi

		echo $$ > ${DAEMON_PID}

		while [ ${RET} -eq 100 ]
		do
			isScheduled
			SCHEDULED=$?

			isLocked
			LOCKED=$?

			$PWRMGRCRONTAB -i $IFILE -c >/tmp/.PwrmgrCrontab.log
			RET=$?

			if [ ${RET} -eq 100 ] ; then
				if [ ${SCHEDULED} -eq 0 -a ${LOCKED} -eq 0 ] ; then
					logger -t ${LOGTAG} -p $LOGFACILITY "go standby"
					pwrmgr -u
					exit $?
				else
					sleep 60
				fi
			else
				exit 0
			fi
		done
	else
		isScheduled
		if [ $? -ne 0 ]; then
			sleep 300
			/usr/local/bin/standby_check.sh &
			exit 0
		fi
		isLocked
		if [ $? -ne 0 ]; then
			sleep 300
			/usr/local/bin/standby_check.sh &
			exit 0
		fi
		logger -t ${LOGTAG} -p $LOGFACILITY "go standby"
		pwrmgr -u
		exit $?
	fi
}

resume()
{
	echo "go resume"
	if [ ! -f /etc/linkstation_standby ]; then
		echo "already resumed"
		exit 0
	fi
	logger -t ${LOGTAG} -p $LOGFACILITY "go resume"
	pwrmgr -u -s
	exit $?
}

case "$1" in
  standby)
	standby
	;;
  standby-cron)
	standby
	;;
  resume|resume-cron)
	resume
	;;
  *)
	echo "Usage: $0 {standby|resume}"
	exit 1
esac

