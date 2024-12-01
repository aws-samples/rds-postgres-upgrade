#!/bin/bash
##-------------------------------------------------------------------------------------
#
# Purpose: To patch/upgrade RDS databases (RDS-PostgreSQL only) - Supports Minor and Major version upgrades.
#
# Usage: ./rds_psql_patch.sh [db-instance-id] [next-enginer-version] [run-pre-check]
#        ./rds_psql_patch.sh [rds-psql-patch-test-1] [15.6] [PREUPGRADE|UPGRADE]
#
#       	PREUPGRADE = Run pre-requisite tasks, and do NOT run upgrade tasks
#        	UPGRADE = Do not run pre-requisite tasks, but run upgrade tasks
#
# Example Usage:
#        nohup ./rds_psql_patch.sh rds-psql-patch-instance-1 14.10 PREUPGRADE >rds-psql-patch-instance-1-preupgrade-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &
#        nohup ./rds_psql_patch.sh rds-psql-patch-instance-1 14.15 UPGRADE >rds-psql-patch-instance-1-upgrade-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &
#
# Prerequisites:
#     1. AWS Resources Required:
#        - EC2 instance for running this script
#        - IAM profile attached to EC2 instance with necessary permissions
#              * create_rds_psql_patch_iam_policy_role_cfn.yaml can be used to create a policy and role. 
#              * Attach this IAM role to ec2 instance.
#        - RDS instance(s) with:
#              * VPC configuration
#              * Subnet group(s)
#              * Security group(s)
#              * Parameter group
#              * Secrets Manager secret
#              * "create_rds_psql_instance_cfn.yaml" can be used (this creates DB Parameter group and RDS instance)
#        - AWS Secrets Manager secret attached to each RDS instance
#        - S3 bucket for upgrade logs
#        - SNS topic for notifications
#
#     2. Network Configuration:
#        - Database security group must allow inbound traffic from EC2 instance
#
#     3. Required Tools:
#        - AWS CLI
#        - PostgreSQL client utilities
#        - jq for JSON processing
#
#     4. Update environment variables "manual" section if/as needed (optional)
#
# Functions:
#     wait_till_available - funtion to check DBInstance status
#     create_param_group - function to create parameter group
#     db_upgrade - function to upgrade DBInstance
#     db_modify_logs - function to add DB logs to CloudWatch
#     db_pending_maint - function to check pending maintenance status
#     get_rds_creds - function to retrieve DB creds from secret manager
#     copy_logs_to_s3 - copy upgrade files to s3 bucket for future reference
#     db_snapshot - function to take DB snapshot/backup if required
#     run_psql_command - run analyze/vacuum freeze commands
#     run_psql_drop_repl_slot - check and drop replication slot in PSQL if exists (applies to MAJOR version upgrade only)
#     check_upgrade_type - function to determine if upgrade/patching path is MINOR or MAJOR
#     update_extensions - function to update PostgreSQL extensions
#     send_email - send email
#     get_db_info - get database related info into local variables
#     version_to_number - function to convert version number to integer
#
##-------------------------------------------------------------------------------------

# Environment Variables - Input parameters #
current_db_instance_id=${1}
next_engine_version=$(echo "${2}" | bc)

run_pre_upg_tasks=${3}
run_pre_upg_tasks="${run_pre_upg_tasks^^}"  # convert to upper case #

LOGS_DIR="./logs"

##-------------------------------------------------------------------------------------

# Environment Variables - Software binaries - Manual #
AWS_CLI=`which aws`
PSQL_BIN=`which psql`

# Environment Variables - Misc. - Manual #
db_snapshot_required="Y"  # set this to Y if manual snapshot is required #
db_parameter_modify="N"  # set this to Y if security and replication related parameters needs to be enabled; if not set it to N. Used in create_param_group function #
DATE_TIME=`date +'%Y%m%d-%H-%M-%S'`

##-------------------------------------------------------------------------------------

# check number of input arguments #
if [ ! $# -eq 3 ]; then
    echo -e "\nERROR: Incorrect syntax; Three (3) parameters expected."
    echo -e "\nUsage: ./rds_psql_patch.sh [db-instance-id] [next-engine-version] [PREUPGRADE|UPGRADE]"
    echo -e "Example:"
    echo -e "       ./rds_psql_patch.sh rds-psql-patch-test-1 15.6 PREUPGRADE"
    echo -e "       ./rds_psql_patch.sh rds-psql-patch-test-1 15.6 UPGRADE\n"
    exit 1
fi

# validate 3rd argument/parameter #
if [ ! "${run_pre_upg_tasks}" = "PREUPGRADE" ] && [ ! "${run_pre_upg_tasks}" = "UPGRADE" ]; then
    echo -e "\nERROR: Invalid 3rd parameter. Expected value PREUPGRADE|UPGRADE."
    echo -e "\nUsage: ./rds_psql_patch.sh [db-instance-id] [next-engine-version] [PREUPGRADE|UPGRADE]"
    echo -e "Example:"
    echo -e "       ./rds_psql_patch.sh rds-psql-patch-test-1 15.6 PREUPGRADE"
    echo -e "       ./rds_psql_patch.sh rds-psql-patch-test-1 15.6 UPGRADE\n"
    exit 1
fi

# Display input parameters for verification
echo ""
echo "INFO: Input parameter 1: $current_db_instance_id"
echo "INFO: Input parameter 2: $next_engine_version"
echo "INFO: Input parameter 3: $run_pre_upg_tasks"
echo ""

if [ "${run_pre_upg_tasks}" = "PREUPGRADE" ]; then
   EMAIL_SUBJECT="RDS PostgreSQL DB Pre-Upgrade Tasks"
else
   EMAIL_SUBJECT="RDS PostgreSQL DB Upgrade"
fi

echo -e "\nBEGIN -  ${EMAIL_SUBJECT} - `date`"

##-------------------------------------------------------------------------------------
# functions #
##-------------------------------------------------------------------------------------

# function to convert version number to integer
version_to_number() {
    # Force base 10 interpretation by prepending "10#"
    #echo "$1" | tr -d . | xargs printf "%06d" | sed 's/^/10#/'

    local version_num=$(echo "$1" | tr -d .)
    echo $((10#$version_num))  # Force base 10 interpretation inside arithmetic expansion

}
##-------------------------------------------------------------------------------------

# funtion to check DBInstance status #
function wait_till_available() {

   echo ""
   # wait for modification to start
   sleep 90s

   current_db_status=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} --query 'DBInstances[0].[DBInstanceStatus]' --output text )

   while [ "${current_db_status}" != "available" ]
   do

      # alternative is to synchronously wait for instance to become available
      # echo "Waiting for ${current_db_instance_id} to enter 'available' state..."
      # aws rds wait db-instance-available --profile $profile --db-instance-identifier $current_db_instance_id
      # exit_status="$?"

      current_db_status=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} --query 'DBInstances[0].[DBInstanceStatus]' --output text )
      #echo ".%s"
      echo "INFO: Wait-DBUpgrade Status = ${current_db_status} - `date`"
      sleep 60s

    done
    echo ""
}
##-------------------------------------------------------------------------------------

# function to create parameter group #
function create_param_group() {

   echo -e "\nINFO: Execute create_param_group function...\n"
   return_value=""

   # generate new parameter group name #
   db_param_group_name="rds-param-group-${current_engine_type}${next_engine_version_family}-${current_db_instance_id}"
   echo -e "\ndb_param_group_name = $db_param_group_name\n"

   #echo "${AWS_CLI} rds describe-db-parameter-groups --db-parameter-group-name ${db_param_group_name} 2>/dev/null"
   ${AWS_CLI} rds describe-db-parameter-groups --db-parameter-group-name ${db_param_group_name} 2>/dev/null
   return_value="$?"
   echo ""
   echo "DBParamGroupCheck ReturnValue = ${return_value}"

   # get current db parameter group name #
   current_db_param_group=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} --query 'DBInstances[*].DBParameterGroups[*].DBParameterGroupName' --output text )
   echo "current_db_param_group = $current_db_param_group"

   # if parameter group does NOT exists, then create a new one #
   if [ "${return_value}" = "0" ]; then

      echo "INFO: DB Parameter Group Exists already. No need to create a new DB parameter group."

   else

        echo "INFO: Creating new parameter group..."

        # create new db parameter group #
        ${AWS_CLI} rds create-db-parameter-group \
                --db-parameter-group-name "${db_param_group_name}" \
                --db-parameter-group-family "${current_engine_type}${next_engine_version_family}" \
                --description "${current_engine_type}${next_engine_version_family} DB parameter group for ${current_db_instance_id} database" \
                --tags '[{"Key": "Name","Value": "'"$db_param_group_name"'"}]'

         return_value="$?"
	      echo ""
         echo "CreateDBParamGroup ReturnValue = ${return_value}"
	      
         if [ "${return_value}" != "0" ]; then
              exit 1
         fi

     	if [ "${db_parameter_modify}" = "Y" ]; then

            echo -e "\nINFO: Modify DB parameter group...\n"

            # Define parameters to modify #
            # only 20 parameters can be modified at a time; hence splitting into two groups #
            # These are security best practices related; also include enabling logical replication parameters as well #
            # These parameters can be removed or updated as needed #
            local params=(
                      "ParameterName=authentication_timeout,ParameterValue=300,ApplyMethod=immediate"
                      "ParameterName=backslash_quote,ParameterValue=safe_encoding,ApplyMethod=immediate"
                      "ParameterName=client_min_messages,ParameterValue=notice,ApplyMethod=immediate"
                      "ParameterName=escape_string_warning,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_connections,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_disconnections,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_duration,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_min_duration_statement,ParameterValue=1000,ApplyMethod=immediate"
                      "ParameterName=log_min_error_statement,ParameterValue=info,ApplyMethod=immediate"
                      "ParameterName=log_min_messages,ParameterValue=info,ApplyMethod=immediate"
                      "ParameterName=log_statement,ParameterValue=all,ApplyMethod=immediate"
                      "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot"
                      "ParameterName=shared_preload_libraries,ParameterValue=pg_stat_statements,ApplyMethod=pending-reboot"
                      "ParameterName=standard_conforming_strings,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=tcp_keepalives_count,ParameterValue=0,ApplyMethod=immediate"
           )

           local params2=(
                       "ParameterName=tcp_keepalives_idle,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=tcp_keepalives_interval,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=rds.force_ssl,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=rds.log_retention_period,ParameterValue=4320,ApplyMethod=immediate"
                       "ParameterName=wal_receiver_timeout,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=wal_sender_timeout,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=idle_in_transaction_session_timeout,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=checkpoint_warning,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=statement_timeout,ParameterValue=0,ApplyMethod=immediate"
           )

	   # modify 1st set of parameters #
    	   #echo -e "\nParmGroup statement = ${AWS_CLI} rds modify-db-parameter-group --db-parameter-group-name "${db_param_group_name}" --parameters "${params[@]}" \n"
    	   ${AWS_CLI} rds modify-db-parameter-group --db-parameter-group-name "${db_param_group_name}" --parameters "${params[@]}"

           return_value="$?"
	   echo ""
           echo "DBParamGroupUpdate1 ReturnValue = ${return_value}"

           if [ "${return_value}" != "0" ]; then
                exit 1
           fi

	   # modify 2nd set of parameters #
      	   #echo -e "\nParmGroup statement2 = ${AWS_CLI} rds modify-db-parameter-group --db-parameter-group-name "${db_param_group_name}" --parameters "${params2[@]}" \n"
           ${AWS_CLI} rds modify-db-parameter-group --db-parameter-group-name "${db_param_group_name}" --parameters "${params2[@]}"

           return_value="$?"
	   echo ""
           echo "DBParamGroupUpdate2 ReturnValue = ${return_value}"

           if [ "${return_value}" != "0" ]; then
              exit 1
           fi

       fi

   fi

   echo ""

}
##-------------------------------------------------------------------------------------

# function to upgrade DBInstance #
function db_upgrade() {

	echo -e "\nINFO: Execute db_upgrade function...\n"
	return_value=""

	# backup current DB config #
	${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} >${LOGS_DIR}/${current_db_instance_id}/${current_db_instance_id}-${current_engine_type}${current_engine_version_family}-${DATE_TIME}.txt

	echo -e "\n${AWS_CLI} rds modify-db-instance \
                --db-instance-identifier ${current_db_instance_id} \
                --db-parameter-group-name ${db_param_group_name} \
                --engine-version ${next_engine_version} \
       	        --allow-major-version-upgrade \
                --apply-immediately\n"

	${AWS_CLI} rds modify-db-instance \
    		--db-instance-identifier ${current_db_instance_id} \
    		--db-parameter-group-name ${db_param_group_name} \
    		--engine-version ${next_engine_version} \
    		--allow-major-version-upgrade \
    		--apply-immediately

        return_value="$?"
        echo "DBUpgrade ReturnValue = ${return_value}"
        if [ "${return_value}" != "0" ]; then
           exit 1
        fi

	# wait until DB instance status is available #
	wait_till_available

	echo ""

}
##-------------------------------------------------------------------------------------

# function to add DB logs to CloudWatch #
function db_modify_logs() {

	echo -e "\nINFO: Execute db_modify_logs function...\n"
        return_value=""

        ${AWS_CLI} rds modify-db-instance \
                --db-instance-identifier ${current_db_instance_id} \
                --cloudwatch-logs-export-configuration '{"EnableLogTypes":["postgresql","upgrade"]}' \
                --apply-immediately

        return_value="$?"
        echo "DBModifyLogs ReturnValue = ${return_value}"
        if [ "${return_value}" != "0" ]; then
           exit 1
        fi

	echo ""

}
##-------------------------------------------------------------------------------------
#
# function to check pending maintenance status #
function db_pending_maint() {

   echo -e "\nINFO: Execute db_pending_maint function...\n"
   return_value=""

   # run upgrade only when db status is available and there are no pending maintenace tasks #
   #pending_maintenance_tasks=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} --query 'DBInstances[].{PendingModifiedValues:PendingModifiedValues}' --output text )
   db_instance_arn=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} --query 'DBInstances[].{DBInstanceArn:DBInstanceArn}' --output text )
   echo "db_instance_arn = $db_instance_arn"

   pending_maintenance_tasks=$( ${AWS_CLI} rds describe-pending-maintenance-actions --resource-identifier ${db_instance_arn} --output text )
   echo "PendingMaintTasks = ${pending_maintenance_tasks}"

   if [ "${pending_maintenance_tasks}" != "" ]; then

      # peform OS related maintenance only  - system-update #
      # db-upgrade, system-update #
      echo -e "\nINFO: PendingMaintApply - BEGIN - `date`"
      ${AWS_CLI} rds apply-pending-maintenance-action --resource-identifier ${db_instance_arn} --apply-action system-update --opt-in-type immediate
      return_value="$?"
      echo "PendingMaintApply ReturnValue = ${return_value}"

      if [ "${return_value}" = "0" ] || [ "${return_value}" = "254" ]; then
        echo -e "\nINFO: No pending maintenance."
      else
         exit 1
       fi

      # wait until DB instance status is available #
      wait_till_available
      echo "INFO: PendingMaintApply - END - `date`"

      echo ""

   fi

}
##-------------------------------------------------------------------------------------
# function to retrieve DB creds from secret manager #
function get_rds_creds() {

   echo -e "\nINFO: Execute get_rds_creds function...\n"
   SECRET_VALUE=$(${AWS_CLI} secretsmanager get-secret-value --secret-id ${current_db_secret_arn} --query SecretString --output text)
   db_user2=$(echo $SECRET_VALUE | jq -r '.password')
   #echo "db_user2 = ${db_user2}"
   export PGPASSWORD="${db_user2}"

}
##-------------------------------------------------------------------------------------

# run analyze in PSQL database #
function run_psql_command() {

   echo -e "\nINFO: Execute run_psql_command function...\n"
   # get DB creds from secret manager # 
   get_rds_creds

   # if no DB credentials found in secret manager, do not run analyze; throwing a warning"
   if [[ "${db_user1}" = "" || "${db_user2}" = "" ]]; then

      echo "WARN: DB credetials NOT found. DB ${1} will NOT run."

   else

      if [ "${1}" = "ANALYZE" ]; then

      	 # PSQL connect to DB to run analyze command #
         echo -e "\nPSQL - ANALYZE DATABASE...\n"
      	 echo -e "PSQL-statement = ${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -p ${db_port} -d ${db_name} -a -c 'ANALYZE VERBOSE'\n"
      	 ${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -p ${db_port} -d ${db_name} -a -c 'ANALYZE VERBOSE' >"${LOGS_DIR}/${current_db_instance_id}/${current_db_instance_id}-db-analyze-${DATE_TIME}.out" 2>&1

      elif [ "${1}" = "FREEZE" ]; then

      	 # PSQL connect to DB to run vacuum freeze command #
         echo -e "\nPSQL - VACUUM FREEZE...\n"
      	 echo -e "PSQL-statement = ${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -p ${db_port} -d ${db_name} -a -c 'VACUUM FREEZE VERBOSE'\n"
      	 ${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -p ${db_port} -d ${db_name} -a -c 'VACUUM FREEZE VERBOSE' >"${LOGS_DIR}/${current_db_instance_id}/${current_db_instance_id}-vacuum-freeze-${DATE_TIME}.out" 2>&1

      elif [ "${1}" = "UNFREEZE" ]; then
      	 # PSQL connect to DB to run vacuum UnFreeze command #
         echo -e "\nPSQL - VACUUM UN-FREEZE...\n"
      	 echo -e "PSQL-statement = ${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -p ${db_port} -d ${db_name} -a -c 'VACUUM VERBOSE'\n"
      	 ${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -p ${db_port} -d ${db_name} -a -c 'VACUUM VERBOSE' >"${LOGS_DIR}/${current_db_instance_id}/${current_db_instance_id}-vacuum-unfreeze-${DATE_TIME}.out" 2>&1

      fi

   fi
   echo ""

}
##-------------------------------------------------------------------------------------

# drop replication slot in PSQL if exists (applies to MAJOR version upgrade only) #
function run_psql_drop_repl_slot() {

   echo -e "\nINFO: Execute run_psql_drop_repl_slot function...\n"
   #echo "PSQL - Drop replication slot..."

   # get DB creds from secret manager #
   get_rds_creds

   # if no DB credentials found in secret manager, do not run analyze; throwing a warning"
   #if [ "${db_user2}" = "" ]; then
   if [[ "${db_user1}" = "" || "${db_user2}" = "" ]]; then

      echo "ERROR: DB credetials NOT found. MAJOR version upgrade will NOT run if there are one or more replication slots."

   else

      # check if replication slot(s) exists #
      repl_slot_count=`${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -d ${db_name} -AXqtc "SELECT COUNT(*) cnt FROM pg_replication_slots"`
      echo "repl_slot_count = $repl_slot_count"

      # check if replication slot(s) exists #
      #repl_slot_count=`${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -d ${db_name} -AXqtc "SELECT COUNT(*) cnt FROM pg_replication_slots"`
      #echo "repl_slot_count = $repl_slot_count"

      # drop replication slot(s) #
      if [ $repl_slot_count -gt 0 ]; then
         # capture replication slot name and related details #
         ${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -d ${db_name} -c "SELECT * FROM pg_replication_slots" >"${LOGS_DIR}/${current_db_instance_id}/${current_db_instance_id}-db-repl_slot-${DATE_TIME}.out" 2>&1

         # drop replication slot(s) #
         ${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -d ${db_name} -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name IN (SELECT slot_name FROM pg_replication_slots)" >>"${LOGS_DIR}/${current_db_instance_id}/${current_db_instance_id}-db-repl_slot-${DATE_TIME}.out" 2>&1

         # check if replication slot(s) exists #
         repl_slot_count=`${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -d ${db_name} -AXqtc "SELECT COUNT(*) cnt FROM pg_replication_slots"`
         echo "repl_slot_count [AFTER DROP] = $repl_slot_count"

      fi

   fi
   echo ""

}
##-------------------------------------------------------------------------------------

# copy upgrade files to s3 bucket for future reference #
function copy_logs_to_s3() {

    if [ -n "${S3_BUCKET_PATCH_LOGS}" ]; then

	   echo -e "\nINFO: Execute copy_logs_to_s3 function...\n"

	   # LOGS_DIR='rds/rds_upgrade'
	   # s3_url_complete="s3://${s3_bucket_name}/${s3_folder_prefix}-postgresql/
	   # aws s3 sync rds_upgrade/ s3://rds-patch-test-s3/rds_upgrade/
	   echo -e "\nINFO: Copy log files to S3"
	   ${AWS_CLI} s3 sync "${LOGS_DIR}/" "s3://${S3_BUCKET_PATCH_LOGS}/"
	   echo ""

	   # S3 logs directory #
	   S3_LOGS_DIR="s3://${S3_BUCKET_PATCH_LOGS}/${current_db_instance_id}/"
	   echo -e "\nS3_LOGS_DIR = ${S3_LOGS_DIR} \n"

    fi

}
##-------------------------------------------------------------------------------------

# function to take DB snapshot/backup if required #
function db_snapshot() {

    echo -e "\nINFO: Execute db_snapshot function...\n"

    if [ "${db_snapshot_required}" = "Y" ]; then

        db_snapshot_name="${current_db_instance_id}-backup-pre-${UPGRADE_SCOPE}-upgrade-${next_engine_version}-${DATE_TIME}"
        #db_snapshot_name=$( echo ${db_snapshot_name:1} | tr '.' '-' )
        db_snapshot_name=$( echo "${db_snapshot_name//./-}" )

        echo ""
        echo "INFO: DBSnapshot [ ${db_snapshot_name} ] - `date`"

        ${AWS_CLI} rds create-db-snapshot \
            --db-instance-identifier ${current_db_instance_id} \
            --db-snapshot-identifier ${db_snapshot_name}
        return_value=$?

        if [ "${return_value}" = "254" ]; then
          echo -e "\nERROR: DB Backup Failed.\n"
          exit 1
        fi

        # wait until DB instance status is available #
      	wait_till_available
        #sleep 90

    else

      echo ""
      echo "INFO: Manual DBSnapshot NOT required for Major version upgrade - `date`"

    fi

}
##-------------------------------------------------------------------------------------

# function to send email #
function send_email() {

   if [ -n "${SNS_TOPIC_ARN_EMAIL}" ]; then
                    
      echo -e "\nINFO: Execute send_email function...\n"

      ${AWS_CLI} sns publish \
            --topic-arn ${SNS_TOPIC_ARN_EMAIL} \
	         --message "Please check logfile(s) in S3 bucket:   ${S3_LOGS_DIR}" \
            --subject "${EMAIL_SUBJECT} [${current_db_instance_id}] - Completed"

    fi

}
##-------------------------------------------------------------------------------------

# function to determine if upgrade/patching path is MINOR or MAJOR #
function check_upgrade_type() {

      echo -e "\nINFO: Execute check_upgrade_type function...\n"

      # EngineVersion NOT 10x THEN IF higher parameter group NOT exists THEN create a new parameter group
      next_engine_version_family=`echo "${next_engine_version}" | cut -d. -f1`

      # get next engine version (input parameter) #
      echo "next_engine_version_family = $next_engine_version_family"
      echo "next_engine_version = $next_engine_version"

      # get current engine version #
      current_engine_version=$(echo "${current_engine_version}" | bc)
      echo "current_engine_version = $current_engine_version"

      # if family is greater, then major version upgrade #
      #if [ $((next_engine_version_family)) -gt $((current_engine_version_family)) ]; then
      if [[ $(version_to_number "$next_engine_version_family") -gt $(version_to_number "$current_engine_version_family") ]]; then
            #echo "Create new parameter group"
            UPGRADE_SCOPE="major"
            echo "UpgradeScope = ${UPGRADE_SCOPE}"
            #create_param_group
      else # if family is same, then check if minor version to patch is appropriate #
	      #if [[ (( $current_engine_version = $next_engine_version )) ]]; then
         if [[ $(version_to_number "$current_engine_version") -eq $(version_to_number "$next_engine_version") ]]; then
            	     echo -e "\nINFO: Current and next DB versions are same. Upgrade NOT required.\n"
	 	     exit 0
	      #elif [[ (( $current_engine_version > $next_engine_version )) ]]; then
         elif [[ $(version_to_number "$current_engine_version") -gt $(version_to_number "$next_engine_version") ]]; then
		     echo -e "\nINFO: Current DB version is greater than next DB version. Upgrade NOT required.\n"
		     exit 0
	     else # if $current_engine_version < $next_engine_version #
		     echo -e "\nINFO: Current DB version is less than next DB version. Upgrade VALID.\n"
            	     echo -e "INFO: DB Parameter Group Exists already. No need to create a new DB parameter group.\n"
            	     UPGRADE_SCOPE="minor"
                     echo "UpgradeScope = ${UPGRADE_SCOPE}"

            	     db_param_group_name=${current_db_param_group}
	      fi

      fi

}
##-------------------------------------------------------------------------------------

# function to update PostgreSQL extensions
function update_extensions() {

   echo -e "\nINFO: Execute update_extensions function...\n"

   # get DB creds from secret manager #
   get_rds_creds

   # if no DB credentials found in secret manager, do not run analyze; throwing a warning"
   #if [ "${db_user2}" = "" ]; then
   if [[ "${db_user1}" = "" || "${db_user2}" = "" ]]; then
   
    # Connect to the PostgreSQL database
    ${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -p ${db_port} -d ${db_name}  -c '\q' >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to connect to the PostgreSQL database."
        return 1
    fi

    # Update extensions using a PL/pgSQL anonymous code block
    ${PSQL_BIN} -U ${db_user1} -h ${db_endpoint} -p ${db_port} -d ${db_name}  -c "

        SELECT now() BEFORE;

        DO \$\$
        DECLARE
            rec RECORD;
            newest_version TEXT;
            extensions_updated BOOLEAN := FALSE;
        BEGIN
            FOR rec IN
                SELECT extname, (
                    SELECT newest_version
                    FROM pg_available_extension_versions
                    WHERE name = extname
                    ORDER BY newest_version DESC
                    LIMIT 1
                ) AS newest_version
                FROM pg_extension
            LOOP
                IF rec.newest_version IS NOT NULL THEN
                    EXECUTE 'ALTER EXTENSION ' || quote_ident(rec.extname) || ' UPDATE TO ' || quote_literal(rec.newest_version);
                    RAISE NOTICE 'Updated extension % to version %', rec.extname, rec.newest_version;
                    extensions_updated := TRUE;
                END IF;
            END LOOP;

            IF NOT extensions_updated THEN
                RAISE NOTICE 'No extensions were updated.';
            END IF;
        END\$\$;

        SELECT now() AFTER;

    "
    return 0

   fi

}
##-------------------------------------------------------------------------------------

## get database info #
## get current engine type and engine versison #

function get_db_info() {

     ## Run the AWS CLI command and store the output
     instance_info=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} --output json )

     # Parse the output and extract the required properties
     db_name=$(echo $instance_info | jq -r '.DBInstances[0].DBName')
     db_endpoint=$(echo $instance_info | jq -r '.DBInstances[0].Endpoint.Address')
     db_port=$(echo $instance_info | jq -r '.DBInstances[0].Endpoint.Port')
     db_user1=$(echo $instance_info | jq -r '.DBInstances[0].MasterUsername')  # master account #
     current_db_status=$(echo $instance_info | jq -r '.DBInstances[0].DBInstanceStatus')
     current_engine_type=$(echo $instance_info | jq -r '.DBInstances[0].Engine')
     current_engine_version=$(echo $instance_info | jq -r '.DBInstances[0].EngineVersion')
     current_engine_version_family=$(echo $instance_info | jq -r '.DBInstances[0].EngineVersion | split(".")[0:2] | join(".")')
     current_engine_version_family=`echo "${current_engine_version_family}" | cut -d. -f1`
     current_db_param_group=$(echo $instance_info | jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName')
     current_db_secret_arn=$(echo $instance_info | jq -r '.DBInstances[0].MasterUserSecret.SecretArn')

     echo -e "\nINFO: Upgrade/Patching steps begin...\n"
     echo "current_db_instance_id = $current_db_instance_id"
     echo "current_engine_type = $current_engine_type"
     echo "current_engine_version = $current_engine_version"
     echo "current_engine_version_family = $current_engine_version_family"
     echo "current_db_status = $current_db_status"
     echo "current_db_param_group = $current_db_param_group"
     echo "db_snapshot_required = $db_snapshot_required"
     echo "db_parameter_modify = $db_parameter_modify"
     echo "run_pre_upg_tasks = $run_pre_upg_tasks"
     echo "db_user1 = ${db_user1}"
     echo "db_name = ${db_name}"
     echo "db_endpoint = ${db_endpoint}"
     echo "db_port = ${db_port}"
     echo "current_db_secret_arn = ${current_db_secret_arn}"
     echo "S3_BUCKET_PATCH_LOGS = ${S3_BUCKET_PATCH_LOGS}"
     echo "SNS_TOPIC_ARN_EMAIL = ${SNS_TOPIC_ARN_EMAIL}"

}
##-------------------------------------------------------------------------------------

echo ""

##-------------------------------------------------------------------------------------
##------------------------EXECUTE RDS-PostgreSQL UPGRADE/PATCHING TASKS----------------
##-------------------------------------------------------------------------------------
# run upgrade only when db status is available and there are no pending maintenace tasks #
current_db_status=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} --query 'DBInstances[0].[DBInstanceStatus]' --output text )
echo "InitialDBStatus = ${current_db_status}"
if [ "${current_db_status}" != "available" ]; then

   echo -e "\nERROR: Invalid DB-Instance-ID or DBInstance status is NOT AVAILABLE. Upgrade can not proceed.\n"
   exit 1

fi

##-------------------------------------------------------------------------------------
# mkdir for logs #
mkdir -p ${LOGS_DIR}/${current_db_instance_id}

##-------------------------------------------------------------------------------------
## Call function to get database info #
get_db_info

##-------------------------------------------------------------------------------------
# Check db engine type and version to create a new db paramerer group #
# DBEngine = postgres #
if [ "${current_engine_type}" = "postgres" ]; then

   # call function to check if upgrade/patching path is MINOR or MAJOR #
   check_upgrade_type

   ### Run PreReq tasks one or few hours prior to the DB patching/upgrade #
   ## Take DB snapshot
   ## Run Freeze
   ## Create DB parameter group if major version upgrade
   if [ "${run_pre_upg_tasks}" = "PREUPGRADE" ]; then

      if [ "${UPGRADE_SCOPE}" = "major" ]; then
         echo -e "\nUPGRADE_SCOPE = ${UPGRADE_SCOPE}\n"
         create_param_group
      fi

      # call function to take DB snapshot/backup #
      db_snapshot

      #call function to run UnFreeze in database #
      run_psql_command "FREEZE"

   else # run_pre_upg_tasks = UPG; perform upgrade/patching tasks

      echo "INFO: DB Parameter Group Exists already. No need to create a new DB parameter group."
      #UPGRADE_SCOPE="minor"
      db_param_group_name=${current_db_param_group}
      
      # take DB snapshot for MINOR version upgrade only; for MAJOR version, snapshot is taken automatically/default #
      if [ "${UPGRADE_SCOPE}" = "minor" ]; then
         echo -e "\nUPGRADE_SCOPE = ${UPGRADE_SCOPE}\n"
         db_snapshot
      fi

      # call function to check/drop replication slots - only for MAJOR version upgrade #
      if [ "${UPGRADE_SCOPE}" = "major" ]; then

         # call function to create parameter group
         # it is ok if this was run during PRE-REQUISITE stage (1 or few hours head of actuals upgradde)
         create_param_group

         echo -e "\nUPGRADE_SCOPE = ${UPGRADE_SCOPE}\n"
         run_psql_drop_repl_slot

      fi

      ## below are common tasks that apply to major/minor version upgrade ##
      
      # call function to add DB logs to CloudWatch if not already #
      db_modify_logs

      # run pending-maintenance task and also DB upgrade #
      db_pending_maint

      # call function to run DB upgrade #
      db_upgrade

      # call function to update PostgreSQL extensions
      update_extensions
   
      # call function to run ANALYZE in database #
      run_psql_command "ANALYZE"

      # call function to run UnFreeze (vacuum) in database #
      run_psql_command "UNFREEZE"

   fi

else # current_engine_type != postgres
   
   echo -e "\nERROR: Invalid DBInstance-ID or DBEngine is NOT PostgreSQL. Please check DBInstance-ID.\n"

fi
##-------------------------------------------------------------------------------------

# copy logs to s3 #
# PSQSL database upgrade log file is available in CloudWatch and also will be avaibale in Splunk.
copy_logs_to_s3

# send email notification #
send_email
echo ""
echo -e "END -  ${EMAIL_SUBJECT} - `date`\n"
exit 0