#!/bin/sh

# ---------------------------------------------------
# 
# 1.Incremental dump of all subversion repositories
# 2.Compress the dumpfile and put into dropbox folder
# 3.The logic is copied from serverfauty.com 
#    that was written by Sebastiano Pilla. I completely
#    re-designed the entire script
# 
# Roger Song
#
# --------------------------------------------------


# path to parent of all repositories to be dumped
SVN_REPPATH=/svn/repository

# destination directory for backup files
DUMP_DIR=~/Dropbox/svn.backup

# status directory
SVN_VAR=${DUMP_DIR}/status

# Format that is part of fliename
DT=$(date +%Y%m%d)

# default mode
MODE="inc"

# Log file directory
LOGFILE=~/svnBackup.log

# path to subversion binaries
SVN_BINPATH=/usr/bin

# Parameters for restoration test
RESTORE_DIR=/svn/restore.test


#----------------------------------
# To write logs and STD with timestamp
# eg. msg "<messages>"
#----------------------------------

msg()
{
	printf `date +%Y-%m-%d:%H:%M:%S`" $1\n" | tee -a ${LOGFILE}
}

#----------------------------------
# Dump svn with specific range of rev to certain file
#  eg. dump <repo path> <start_rev> <stop_rev> <dump filename>
#----------------------------------

dump()
{
	REP=$1
	BEGIN_REV=$2
	END_REV=$3
	DUMPFILE=$4
	
	# get the rep name from path
	REP_BASE=$(basename $REP)
	
	# check existance of filename
	if [ -e $DUMPFILE ]; then
		msg "Target file $DUMPFILE exists, ignored."
		return 1
	fi
	
	msg "Calling dump()...\n REP=${REP}\n BEGIN_REV=${BEGIN_REV}\n END_REV=${END_REV}\n DUMPFILE=${DUMPFILE}\n"  
	
	${SVN_BINPATH}/svnadmin dump $REP --incremental -r${BEGIN_REV}:${END_REV} | gzip -9 > ${DUMPFILE}
	
	if [ $? -eq 0 ]; then
		msg "Backup done for ${REP}. "
		# if the backup succeeds, save the lastest version anyway.
		echo ${END_REV} > ${SVN_VAR}/${REP_BASE}.rev
		return 0
	else
		msg ">>> Backup failed for $REP. Please check and run it again"
		return 1 
	fi
}

#----------------------------------
# Dump particular repository, decide the range,
#  eg. dumpRep <repo path> <mode>
#  <mode> can be either "full" or "inc"
#----------------------------------

dumpRep()
{
	REP=$1
	MODE=$2
    
	CURR_REV=$(${SVN_BINPATH}/svnlook youngest ${REP})
    REP_BASE=$(basename $REP)
	
    if [ -e ${SVN_VAR}/${REP_BASE}.rev ] ; then
		REP_LAST_BK_REV=$(cat ${SVN_VAR}/${REP_BASE}.rev)
		# if file exists, but corrupted. Test if the content is integer
		if ! [ "${REP_LAST_BK_REV}" -eq  "${REP_LAST_BK_REV}" ] 2>/dev/null; then
			msg "${SVN_VAR}/${REP_BASE}.rev is corrupted! Place it to zero"
			MODE="full"
			REP_LAST_BK_REV=0
		fi
    else
		# if new backup, change mode to "full" anyway
		MODE="full"
		REP_LAST_BK_REV=0
    fi
	
    # if force backup was specified, dump from 0 no matter there's change or not
    if [ $MODE = "force" ]; then
		msg "Force full backup, as force found."
		REP_LAST_BK_REV=0
	fi
		
	# decide dump or not
	msg "oldest revision ${REP_LAST_BK_REV} - newest revision ${CURR_REV}"
	
	if [ ${CURR_REV} -gt ${REP_LAST_BK_REV} ] ; then
		# WE DO Dumping 
		
	    # if full backup was specified, dump from 0 when there is change
	    if [ $MODE = "full" ]; then
			msg "Force full backup since there is change."
			REP_LAST_BK_REV=0
		fi
		
		# increase last rev by 1 as the last REV has been included in last dump
		REP_LAST_BK_REV=$(expr ${REP_LAST_BK_REV} + 1)
		
		# use "full" in file name even if the mode is "force"
		if [ ${MODE} = "force" ]; then
			NAMING='full'
		else
			NAMING=${MODE}
		fi
		# Generate filename
		DUMPFILE=${DUMP_DIR}/${REP_BASE}-${NAMING}-${DT}-${REP_LAST_BK_REV}-${CURR_REV}.dmp.gz
		
		# Find the old backups and save the list in tmp file
		# if full backup succeed, we will delete this list of files.
		getBackupList ${REP_BASE}
		
		msg "Starting backup on ${REP_BASE}. "
		msg "Range:${REP_LAST_BK_REV} ~ ${CURR_REV}"
		msg "File:${DUMPFILE} "
		
		# call the dump function
		dump $REP ${REP_LAST_BK_REV} ${CURR_REV} ${DUMPFILE}
		
	    if [ $? -eq 0 ]; then
	        msg "Dump of ${REP} succeeded. "
	      else
	        msg ">>> Failed to dump ${REP}. "
	        exit 1
	    fi
		
		# restoration test on the new dump file created.
		restoreDump $DUMPFILE ${RESTORE_DIR}/${REP_BASE}
		
		if [ $? -eq 0 ] && ([ $MODE = "full" ] || [ $MODE = "force" ]); then
			# Remove backups if full backup accomplished, as one valid backup is enough. 
			msg "Removing old backups since full backup is valid"
			rmBackupList
		fi
		
		# remove the temporary directory as the restoration is only for test purpose. 
		msg "Removing temporary repositary ${RESTORE_DIR}/${REP_BASE}"
		rm -rf ${RESTORE_DIR}/${REP_BASE}
		
	else
		# no update of rep
		msg "No update for ${REP}. Ignoring..."
	fi
}

#----------------------------------
# Searching for valid backups of particular repository
# the list was saved into two files, full.tmp and inc.tmp for future use
# eg. getBackupList <repostory name>
#----------------------------------

getBackupList()
{
	REP_BASE=$1
	
	msg "Searching for the previous backups for ${REP_BASE}"
	
	for mode in "full" "inc" ;
	do
		find ${DUMP_DIR} -maxdepth 1 -regex ".*\/${REP_BASE}-${mode}-20[0-9][0-9][0-9][0-9][0-9][0-9]-.*-.*\.dmp\.gz" > ${SVN_VAR}/${mode}.tmp
		if [ $(wc -l ${SVN_VAR}/${mode}.tmp|cut -d" " -f1) -gt 0 ];then
			echo "${mode} backup found:"
			cat ${SVN_VAR}/${mode}.tmp
		fi
	done
}

#----------------------------------
# Deleting files that are listed in full.tmp and inc.tmp 
# To get the accurate file list,
# fucntion getBackupList() must be the prereq function of this
#----------------------------------

rmBackupList()
{
	msg "Removing backups..."
	for mode in "full" "inc";
	do
		if [ $(wc -l ${SVN_VAR}/${mode}.tmp|cut -d" " -f1) -gt 0 ];then
			msg "Removing ${mode} backups"
			cat ${SVN_VAR}/${mode}.tmp
			cat ${SVN_VAR}/${mode}.tmp | xargs rm -f
			if [ $? -eq 0 ]; then
				msg "Done for ${mode} backups"
			else
				msg ">>> Something was happened when removing old backups"
			fi
		fi
    done
}

#----------------------------------
# Loop all repositaries in base dir
# eg. dumpAllRep() <mode>
#----------------------------------

dumpAllRep()
{
	MODE=$1
	for REP in ${SVN_REPPATH}/*;
	do
	  printf "==================================================\n"
	  printf "Repository \"${REP}\"\n"
	  printf "==================================================\n"
	  msg "Processing repository ${REP} ..."
	  # call dumpRep() to process one repository at a time
	  dumpRep ${REP} ${MODE}
	done
}

#----------------------------------
# Find relevant backups for one particular 
# repository, and restore. 
#----------------------------------

restoreRep()
{
	REP_BASE=$1
	TARGET=$2
	
	msg "Trying to restore the backups from $REP_BASE"
	msg "Source: ${DUMP_DIR}"
	msg "Target: ${TARGET}"
	getBackupList ${REP_BASE}
	
	if [ ! -d ${TARGET} ]; then
		msg "${TARGET} not found! Restoration is not possible"
		return 1
	fi
	
	if [ $(wc -l ${SVN_VAR}/full.tmp| cut -d" " -f1) -eq 1 ]; then
		PIECE=$(cat ${SVN_VAR}/full.tmp)
		msg "Full backup found: ${PIECE}"
		
		if [ -e ${TARGET}/${REP_BASE} ]; then
			msg ">>> ${TARGET}/${REP_BASE} exists, remove the foler."
			rm -rf ${TARGET}/${REP_BASE}
		    if [ $? -eq 0 ]; then
		        msg "${TARGET}/${REP_BASE} removed! "
		      else
		        msg ">>> Failed to remove ${TARGET}/${REP_BASE}. "
		        exit 1
		    fi
		fi
		
		msg "Creating repository: ${TARGET}/${REP_BASE}"
		${SVN_BINPATH}/svnadmin create ${TARGET}/${REP_BASE}
		
	    if [ $? -eq 0 ]; then
	        msg "Repository ${TARGET}/${REP_BASE} created. "
	      else
	        msg "Failed to create repository ${TARGET}/${REP_BASE}"
	        exit 1
	    fi
		
		msg "Restoring full backup to ${TARGET}/${REP_BASE}"
		# DO RESTORE
		restoreDump $PIECE ${TARGET}/${REP_BASE}
		
	    if [ $? -eq 0 ]; then
	        msg "${TARGET}/${REP_BASE} restored! "
	      else
	        msg ">>> Failed to restore $PIECE to ${TARGET}/${REP_BASE}. "
	        return 1
	    fi
		
	else
		msg ">>> No full backup found, restoration of $REP_BASE exit."
		return 1
	fi
	
	# Get the last rev from name of full backup
	LAST_REV=$(echo $PIECE | awk -F"-" '{print $5}' | awk -F"." '{print $1}')
	
	if [ $(wc -l ${SVN_VAR}/inc.tmp| cut -d" " -f1) -gt 0 ]; then
		msg "Moving to incremental backups. "
		# Moving to incrmental backups
		msg "Last revision is ${LAST_REV}, searching for next incremental backup."	
		LAST_REV=$(expr ${LAST_REV} + 1)
		NEXT=$(ls ${DUMP_DIR}/${REP_BASE}-inc-*-${LAST_REV}-*.dmp.gz 2>/dev/null)
		while [ ! -z $NEXT ] && [ -f $NEXT ]; do
			msg "Restoring inc backup $NEXT..."
			## DO RESTORE
			restoreDump $PIECE ${TARGET}/${REP_BASE}
		    if [ $? -eq 0 ]; then
		        msg "Done. "
		      else
		        msg "Restoration failed, exiting"
		        exit 1
		    fi
			LAST_REV=$(echo $NEXT | awk -F"-" '{print $5}' | awk -F"." '{print $1}')
			# Moving to incrmental backups
			msg "Last revision is ${LAST_REV}, searching for next incremental backup."	
			LAST_REV=$(expr ${LAST_REV} + 1)
			NEXT=$(ls ${DUMP_DIR}/${REP_BASE}-inc-*-${LAST_REV}-*.dmp.gz 2>/dev/null)
		done
	else
		msg "No inc backup found."
	fi
	
	msg "Restoration of ${REP_BASE} finished"
	
}



#----------------------------------
# Restore one particular dump 
# eg. restoreDump() <dump file> <rep path>
#----------------------------------

restoreDump()
{
	DUMPFILE=$1
	REP_TARGET=$2
	
	msg "restoreDump(): restore $DUMPFILE to ${REP_TARGET}"
	
	# Checking target
	if [ ! -e ${REP_TARGET} ]; then
		msg ">>> ${REP_TARGET} not found, creating the repostory. "
		msg "Creating repository: ${REP_TARGET}"
		
		${SVN_BINPATH}/svnadmin create ${REP_TARGET}
		
	    if [ $? -eq 0 ]; then
	        msg "Repository ${REP_TARGET} created. "
	      else
	        msg "Failed to create repository ${REP_TARGET}"
	        exit 1
	    fi
	fi
	
	# Checking dump files
	if [ ! -f ${DUMPFILE} ]; then
		msg ">>> File ${DUMPFILE} not found, ignore the restoration."
		return 1
	fi
	
	# Checking if target is valid svn repository
	LATEST=$(${SVN_BINPATH}/svnlook youngest ${REP_TARGET})
	
    if [ $? -eq 0 ]; then
        msg "Latest revision of ${REP_TARGET} is ${LATEST} "
      else
        msg "${REP_TARGET} is not valid svn repository"
        return 1
    fi
	
	# Load dump files
	gunzip ${DUMPFILE} -c | ${SVN_BINPATH}/svnadmin load ${REP_TARGET}
	
    if [ $? -eq 0 ]; then
        msg "Restoration of ${DUMPFILE} done!"
      else
        msg ">>> Restoration of ${DUMPFILE} failed! "
        return 1
    fi
	
}


#----------------------------------
# 
# Main Entry
#
#----------------------------------


msg "Starting jobs..."

if [ ! -z $1 ] && ([ $1 = "full" ] || [ $1 = "inc" ] || [ $1 = "force" ]) ; then
	MODE=$1
	msg "Mode ${MODE} specified!"
fi

# Dump all repositories
dumpAllRep ${MODE}
#restoreRep tulip ${RESTORE_DIR}
#restoreDump /home/svn/Dropbox/svn.backup/tulip-full-20161211-1-2101.dmp.gz /svn/restore.test/tulip