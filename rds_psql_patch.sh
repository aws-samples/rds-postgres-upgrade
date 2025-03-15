#!/bin/bash
##-------------------------------------------------------------------------------------
#
# Purpose: To upgrade  RDS databases (RDS-PostgreSQL only)
#
# Usage: ./rds_psql_patch.sh [db-instance-id] [next-engine-version] [run-pre-check]
#        ./rds_psql_patch.sh [rds-psql-patch-test-1] [15.6] [PREUPGRADE|UPGRADE]
#
#       	PREUPGRADE = Run pre-requisite tasks, and do NOT run upgrade tasks
#           UPGRADE = Do not run pre-requisite tasks, but run upgrade tasks
#           
#           Note: Review this document [https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-versions.html]
#                 for appropriate minor or major supported verion (a.k.a appropirate upgrade path)
#
# Note:  1. This script can be executed standalone, outside of SSM. It can also be integrated into CI/CD pipelines 
#           like CodeCommit, Jenkins, and other.
#        2. Standalone version has been tested, but it still needs to be tested throughly in your non-prod environment.
#        3. If running standalone, set SNS topic and S3 bucket name in the envioronment if email notification is required and
#           log files needs to be pushed and stored in S3 bucket. For e.g.:
#               export S3_BUCKET_PATCH_LOGS="rds-psql-patch-test1-s3"
#               export SNS_TOPIC_ARN_EMAIL="arn:aws:sns:us-east-1:1234567890:rds-psql-patch-test-sns-topic"
#
# Example Usage:
#        nohup ./rds_psql_patch.sh rds-psql-patch-test-1 15.6 PREUPGRADE >logs/pre-upgrade-rds-psql-patch-test-1-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &
#        nohup ./rds_psql_patch.sh rds-psql-patch-test-1 15.6 UPGRADE >logs/upgrade-rds-psql-patch-test-1-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &
#
# Prerequisites:
#     1. AWS Resources Required:
#        - EC2 instance for running this script
#        - IAM profile attached to EC2 instance with necessary permissions
#              * create_rds_psql_patch_iam_policy_role_cfn.yaml can be used to create a policy and role. 
#                    ** Modify resource names appropriately
#              * Attach this IAM role to ec2 instance.
#        - RDS instance(s) with:
#              * VPC configuration
#              * Subnet group(s)
#              * Security group(s)
#              * Parameter group
#              * Secrets Manager secret
#              * "create_rds_psql_instance_cfn.yaml" can be used (this creates DB Parameter group and RDS instance)
#                    ** Modify resource names appropriately
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
#        - bc (basic calculator) utility
#
#	   4. Update environment variables "manual" section if/as needed (optional)
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
#     check_rds_upgrade_version - check if the next-engine-version is valid for the current rds-postgresql instance version
#     check_db_name - function to check if db name is null. If null, DB related tasks will not apply
#     check_required_utils - function to check required utilities
#
##-------------------------------------------------------------------------------------

# Environment Variables - Input parameters #
current_db_instance_id=${1}
next_engine_version=${2}

run_pre_upg_tasks=${3}
run_pre_upg_tasks="${run_pre_upg_tasks^^}"  # convert to upper case #

LOGS_DIR="./logs"

##-------------------------------------------------------------------------------------

# Environment Variables - Software binaries - Manual #
AWS_CLI=$(which aws)
PSQL_BIN=$(which psql)

# Environment Variables - Misc. - Manual #
db_snapshot_required="Y"  # set this to Y if manual snapshot is required. #
db_parameter_modify="N"  # set this to Y if security and replication related parameters needs to be enabled; if not set it to N. Used in create_param_group function #
db_drop_replication_slot="N"  # set this to Y if replication slots needs to be dropped automatically by this process, as part of major version upgrade #
rds_secret_tag_name="rds-maintenance-user-secret"
rds_secret_key_username="username"
rds_secret_key_password="password"

DATE_TIME=$(date +'%Y%m%d-%H-%M-%S')

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
echo "INFO: Input parameter 1 [DB InstanceID]: $current_db_instance_id"
echo "INFO: Input parameter 2 [Requested Upgrade Engine Version]: $next_engine_version"
echo "INFO: Input parameter 3 [Upgrade Option]: $run_pre_upg_tasks"
echo ""

if [ "${run_pre_upg_tasks}" = "PREUPGRADE" ]; then
   EMAIL_SUBJECT="RDS PostgreSQL PREUPGRADE Tasks"
else
   EMAIL_SUBJECT="RDS PostgreSQL UPGRADE"
fi

echo -e "\nBEGIN -  ${EMAIL_SUBJECT} - $(date)"

##-------------------------------------------------------------------------------------
# functions #
##-------------------------------------------------------------------------------------

# Function to check required utilities
check_required_utils() {
    local missing_utils=()
    
    # List of required utilities
    local utils=(
        "aws"
        "jq"
        "bc"
        "psql"
        "grep"
        "cut"
        "tr"
        "tee"
        "date"
        "which"
    )
    
    echo -e "\nINFO: Checking for required utilities...\n"
    for util in "${utils[@]}"; do
        if ! command -v "$util" >/dev/null 2>&1; then
            missing_utils+=("$util")
        fi
    done
    
    if [ ${#missing_utils[@]} -ne 0 ]; then
        echo "ERROR: The following required utilities are missing:"
        for util in "${missing_utils[@]}"; do
            echo "  - $util"
        done

        echo -e "\nERROR: Please install the missing utilities before running this script. \n"
        return 1
    fi
    
    echo -e "\nINFO: All required utilities are present. \n"
    return 0
}
##-------------------------------------------------------------------------------------

# function to check if db name is null. If null, DB related tasks will not apply.
function check_db_name() {
    local db_name="$1"
    
    if [ -z "${db_name}" ] || [ "${db_name}" = "null" ]; then
        echo -e "\nINFO: Database name is empty. Above step is not required. \n"
        return 1
    fi
    
    return 0
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
      echo "INFO: Wait-DBUpgrade Status = ${current_db_status} - $(date)"
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
	${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} >${LOGS_DIR}/${current_db_instance_id}/db_current_config_backup_${current_engine_type}${current_engine_version_family}-${DATE_TIME}.txt

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

    # check before/after upgrade version #
    echo -e "\nINFO: Check before/after upgrade version...\n"
    current_db_engine_version_after=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} --query 'DBInstances[0].[EngineVersion]' --output text )
    echo "current_db_engine_version_after = $current_db_engine_version_after"

    # compare current engine version with next engine version #
    if [ "${current_db_engine_version_after}" = "${next_engine_version}" ]; then
       echo -e "\nINFO: DB instance is upgraded to ${next_engine_version}. Upgrade is successful.\n"
    else
       echo -e "\nERROR: DB instance is not upgraded to ${next_engine_version}. Please check upgrade and database logs for more details.\n"
       exit 1
    fi

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
            echo -e "\ERROR: Unable to configure DB logs to CloudWatch. Existing the upgrade process.\n"
            exit 1
        fi

	echo ""

}
##-------------------------------------------------------------------------------------

# function to check pending maintenance status #
function db_pending_maint() {

    echo -e "\nINFO: Execute db_pending_maint function...\n"
    local return_value=""

    # Get DB instance ARN
    db_instance_arn=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} --query 'DBInstances[].{DBInstanceArn:DBInstanceArn}' --output text )
    echo "db_instance_arn = $db_instance_arn"

    # Check pending maintenance tasks
    pending_maintenance_tasks=$( ${AWS_CLI} rds describe-pending-maintenance-actions --resource-identifier ${db_instance_arn} --output text )
    echo "PendingMaintTasks = ${pending_maintenance_tasks}"

    if [ "${pending_maintenance_tasks}" != "" ]; then
        # Perform OS related maintenance only - system-update
        echo -e "\nINFO: PendingMaintApply - BEGIN - $(date)"
        
        # Capture both stdout and stderr
        maintenance_output=$( ${AWS_CLI} rds apply-pending-maintenance-action \
            --resource-identifier ${db_instance_arn} \
            --apply-action system-update \
            --opt-in-type immediate 2>&1 )
        return_value=$?
        
        # Check if the error message contains the expected error
        if echo "${maintenance_output}" | grep -q "There is no pending system-update action"; then
            echo "INFO: No pending system updates available - this is expected"
            return_value="0"
        else
            echo "${maintenance_output}"
        fi

        echo "PendingMaintApply ReturnValue = ${return_value}"

        if [ "${return_value}" = "0" ] || [ "${return_value}" = "254" ]; then
            echo -e "\nINFO: No pending maintenance."
        else
            exit 1
        fi

        # wait until DB instance status is available
        wait_till_available
        echo "INFO: PendingMaintApply - END - $(date)"
        echo ""
    fi

}
##-------------------------------------------------------------------------------------

# function to retrieve DB creds from secret manager #
function get_rds_creds() {
    echo -e "\nINFO: Execute get_rds_creds function...\n"
    
    # Call helper function to validate db_name
    check_db_name "${db_name}" || return $?

    # Get instance information and ARN
    rds_instance_info=$(${AWS_CLI} rds describe-db-instances --db-instance-identifier ${current_db_instance_id} --output json)
    db_arn=$(echo ${rds_instance_info} | jq -r '.DBInstances[0].DBInstanceArn')
    
    # Get secret name from RDS tags
    tags_info=$(${AWS_CLI} rds list-tags-for-resource --resource-name ${db_arn} --output json)
    secret_name=$(echo ${tags_info} | jq -r --arg tag_name "${rds_secret_tag_name}" '.TagList[] | select(.Key==$tag_name).Value')
    
    echo "rds_secret_tag_name = ${rds_secret_tag_name}"
    echo "secret_name = ${secret_name}"

    if [ -z "${secret_name}" ]; then
        echo -e "\nERROR: Could not find secret name in RDS tags. Please check secret and try again.\n"
        exit 1
    fi

    # Get secret value
    SECRET_VALUE=$(${AWS_CLI} secretsmanager get-secret-value --secret-id ${secret_name} --query SecretString --output text)
    
    if [ -z "${SECRET_VALUE}" ]; then
        echo -e "\nERROR: Could not retrieve secret value. Please check secret and try again. \n"
        exit 1
    fi
    
    # Extract username and password
    db_username=$(echo $SECRET_VALUE | jq -r --arg key1 "${rds_secret_key_username}" '.[$key1]')
    db_password=$(echo $SECRET_VALUE | jq -r --arg key2 "${rds_secret_key_password}" '.[$key2]')
    
    echo "db user name = ${db_username}"

    if [ -z "${db_username}" ] || [ "${db_username}" = "null" ] || [ -z "${db_password}" ] || [ "${db_password}" = "null" ]; then
        echo -e "\nERROR: Could not extract username or password from secret. Check secret and try again.\n"
        exit 1
    fi

    export PGPASSWORD="${db_password}"
    echo "INFO: Successfully retrieved database credentials"
    echo ""
    
    return 0
}

##-------------------------------------------------------------------------------------

# run analyze in PSQL database #
function run_psql_command() {

    echo -e "\nINFO: Execute run_psql_command function...\n"

    # Call helper function to validate db_name
    check_db_name "${db_name}" || return $?

    # Create log file path
    local log_file="${LOGS_DIR}/${current_db_instance_id}/run_db_task_${1,,}-${DATE_TIME}.log"
    # ${LOGS_DIR}/${current_db_instance_id}/${current_db_instance_id}-[analyze|freeze|unfreeze]-${DATE_TIME}.log

    # Ensure log directory exists
    mkdir -p "${LOGS_DIR}/${current_db_instance_id}"

    # Initialize command status
    local cmd_status=0
    local cmd=""

    {
        echo "================================================================"
        echo "PostgreSQL Command Execution Log - Started at $(date)"
        echo "================================================================"
        echo "Command Type: ${1}"
        echo "Database Instance: ${current_db_instance_id}"
        echo "Database Name: ${db_name}"
        echo "Log File: ${log_file}"
        echo "----------------------------------------------------------------"

        # Get DB credentials
        echo "INFO: Retrieving database credentials..."
        get_rds_creds

        # Validate DB credentials
        if [ -z "${db_username}" ] || [ "${db_username}" = "null" ] || [ -z "${db_password}" ] || [ "${db_password}" = "null" ]; then
            echo -e "\nERROR: Database credentials NOT found. Command ${1} will NOT run. Please check and retry again. \n"
            echo "----------------------------------------------------------------"
            exit 1
        fi
        echo "INFO: Database credentials retrieved successfully."

        # Test database connection
        echo "INFO: Testing database connection..."
        if ! "${PSQL_BIN}" -U "${db_username}" -h "${db_endpoint}" -p "${db_port}" \
            -d "${db_name}" -c '\q'
            #-d "${db_name}" -c '\q' >/dev/null 2>&1
        then
            echo -e "\nERROR: Failed to connect to database. Please check and retry again. \n"
            echo "----------------------------------------------------------------"
            exit 1
        fi
        echo "INFO: Database connection successful"

        # Execute command based on input parameter
        case "${1}" in
            "ANALYZE")
                echo -e "\nINFO: Executing ANALYZE VERBOSE command..."
                cmd="ANALYZE VERBOSE"
                ;;
            "FREEZE")
                echo -e "\nINFO: Executing VACUUM FREEZE VERBOSE command..."
                cmd="VACUUM FREEZE VERBOSE"
                ;;
            "UNFREEZE")
                echo -e "\nINFO: Executing VACUUM VERBOSE command..."
                cmd="VACUUM VERBOSE"
                ;;
            *)
                echo "ERROR: Invalid command type: ${1}"
                echo "Valid options are: ANALYZE, FREEZE, UNFREEZE"
                echo "----------------------------------------------------------------"
                return 1
                ;;
        esac

        # Log and execute the command
        echo "Executing command: ${PSQL_BIN} -h ${db_endpoint} -p ${db_port} -d ${db_name} -a -c '${cmd}'"
        echo "----------------------------------------"
        echo "Command execution started at: $(date)"
        
        # Execute PostgreSQL command
        if ! "${PSQL_BIN}" -U "${db_username}" -h "${db_endpoint}" -p "${db_port}" \
            -d "${db_name}" -a -c "\timing on" -c "${cmd}" 2>&1
        then
            cmd_status=$?
            echo "Command failed with status: ${cmd_status}"
        fi

        echo "Command execution completed at: $(date)"
        echo "----------------------------------------"

        # Check command execution status
        if [ ${cmd_status} -eq 0 ]; then
            echo "SUCCESS: ${1} command completed successfully"
        else
            echo "ERROR: ${1} command failed with exit status ${cmd_status}"
        fi

        echo "----------------------------------------------------------------"
        echo "Operation completed at: $(date)"
        echo "================================================================"
        echo ""

    } 2>&1 | tee "${log_file}"

    return ${cmd_status}
}
##-------------------------------------------------------------------------------------

# drop replication slot in PSQL if exists (applies to MAJOR version upgrade only) #
function run_psql_drop_repl_slot() {

    echo -e "\nINFO: Execute run_psql_drop_repl_slot function...\n"

    # Call helper function to validate db_name
    check_db_name "${db_name}" || return $?

    # Create log file path
    local log_file="${LOGS_DIR}/${current_db_instance_id}/replication_slot_${DATE_TIME}.log"

    # Ensure log directory exists
    mkdir -p "${LOGS_DIR}/${current_db_instance_id}"

    {
        echo "================================================================"
        echo "Replication Slot Operation Log - Started at $(date)"
        echo "================================================================"
        echo "Database Instance: ${current_db_instance_id}"
        echo "Log File: ${log_file}"
        echo "----------------------------------------------------------------"

        # Get DB credentials from secret manager
        echo "INFO: Retrieving database credentials..."
        get_rds_creds

        # Validate DB credentials
        if [ -z "${db_username}" ] || [ "${db_username}" = "null" ] || [ -z "${db_password}" ] || [ "${db_password}" = "null" ]; then
            echo "ERROR: Database credentials NOT found."
            echo "ERROR: [Replication Slots] Please check if the instance has replication slots. Major Version upgrade will fail if there are one or more replication slots."
            echo "ERROR: [Extension check] Please check if there are extensions on older version which may not be compatible with target version. Major version will fail if there are extensions that are not compatible with target version."

            echo "----------------------------------------------------------------"
            exit 1
        fi
        echo "INFO: Database credentials retrieved successfully."

        # Check for existing replication slots
        echo "INFO: Checking for existing replication slots..."
        repl_slot_count=$(${PSQL_BIN} -U "${db_username}" -h "${db_endpoint}" -d "${db_name}" -AXqtc "SELECT COUNT(*) cnt FROM pg_replication_slots" 2>&1)
        
        if [ $? -ne 0 ]; then
            echo -e "\nERROR: Failed to query replication slots. Please check and retry again. \n"
            echo "${repl_slot_count}"
            exit 1
        fi

        echo "INFO: Current replication slot count = ${repl_slot_count}"

        # Process replication slots if they exist
        if [ "${repl_slot_count}" -gt 0 ]; then

            echo "INFO: Found ${repl_slot_count} replication slot(s)."
            
            # Log current replication slots
            echo "INFO: Capturing current replication slot details..."
            echo "Current replication slots:"
            echo "----------------------------------------"
            ${PSQL_BIN} -U "${db_username}" -h "${db_endpoint}" -d "${db_name}" \
                -c "SELECT slot_name, plugin, slot_type, database, active, xmin FROM pg_replication_slots"
            echo "----------------------------------------"

            if [ "${db_drop_replication_slot}" = "Y" ]; then 

                # Drop replication slots
                echo "INFO: Dropping replication slots..."
                drop_result=$(${PSQL_BIN} -U "${db_username}" -h "${db_endpoint}" -d "${db_name}" \
                    -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name IN (SELECT slot_name FROM pg_replication_slots)" 2>&1)
                
                if [ $? -ne 0 ]; then
                    echo -e "\nERROR: Failed to drop replication slots. Please check and retry again. \n"
                    echo "${drop_result}"
                    exit 1
                fi

                echo "INFO: Replication Slot operation result: ${drop_result}"
                echo "----------------------------------------"

                # Verify slots were dropped
                echo "INFO: Verifying replication slots after drop operation..."
                echo "Remaining replication slots:"
                echo "----------------------------------------"
                ${PSQL_BIN} -U "${db_username}" -h "${db_endpoint}" -d "${db_name}" \
                    -c "SELECT slot_name, plugin, slot_type, database, active, xmin FROM pg_replication_slots"
                echo "----------------------------------------"

                # Final count verification
                final_count=$(${PSQL_BIN} -U "${db_username}" -h "${db_endpoint}" -d "${db_name}" -AXqtc "SELECT COUNT(*) cnt FROM pg_replication_slots")
                
                if [ $? -ne 0 ]; then
                    echo -e "\nERROR: Failed to get final replication slot count. Please check and retry again. \n"
                    exit 1
                fi

                echo "INFO: Final replication slot count = ${final_count}"

                if [ "${final_count}" -eq 0 ]; then
                    echo "SUCCESS: All replication slots were successfully dropped."
                else
                    echo -e "\nERROR: ${final_count} replication slots still exist. Upgrade cannot proceed until they are dropped. Please check and retry again. \n"
                    exit 1
                fi

            else
                echo "IMPORTANT: ${repl_slot_count} replication slot(s) found. All replication slots MUST be dropped before proceeding with major version upgrade."
                echo "INFO: To manually drop replication slot(s), use this command in each database priot to MAJOR version upgrade:"
                echo "INFO  SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name IN (SELECT slot_name FROM pg_replication_slots);"
                echo "INFO: Other option is to set this variable "db_drop_replication_slot" to "Y" prior to running the MAJOR version UPGRADE; using this option,"
                echo "INFO: the script will drop replication slot(s) as part of the MAJOR version UPGRADE process."
            fi

        else
            echo "INFO: No replication slots found. No action needed."

        fi

        echo "----------------------------------------------------------------"
        echo "Operation completed at: $(date)"
        echo "================================================================"
        echo ""

    } 2>&1 | tee "${log_file}"

    return 0
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
        echo "INFO: DBSnapshot [ ${db_snapshot_name} ] - $(date)"

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
      echo "INFO: Manual DBSnapshot NOT required for Major version upgrade - $(date)"

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

# function to check if the next-engine-version is valid for the current rds-postgresql instance version #
# Usage example: check_rds_upgrade_version "rds-psql-patch-instance-1" "16.6"
check_rds_upgrade_version() {
    local instance_id="$1"
    local target_version="$2"
    
    echo -e "\nINFO: Checking upgrade version compatibility..."
    echo "INFO: DB Instance:        ${instance_id}"
    echo "INFO: Current Version:    ${current_engine_version}"
    echo "INFO: Requested Version:  ${target_version}"
    
    # Get valid upgrade targets with IsMajorVersionUpgrade flag
    valid_versions=$(aws rds describe-db-engine-versions \
        --engine postgres \
        --engine-version "${current_engine_version}" \
        --query 'DBEngineVersions[].ValidUpgradeTarget[].[EngineVersion,IsMajorVersionUpgrade]' \
        --output text)
    
    if [ $? -ne 0 ] || [ -z "${valid_versions}" ]; then
        echo -e "\nERROR: Failed to retrieve valid upgrade versions. Please check and retry again. \n"
        exit 1
    fi
    
    # Check if target version is in the list of valid upgrades
    if echo "${valid_versions}" | awk '{print $1}' | grep -q "^${target_version}$"; then
        # Get upgrade type (major/minor)
        is_major=$(echo "${valid_versions}" | grep "^${target_version}" | awk '{print $2}')
        upgrade_type=$([ "${is_major}" = "True" ] && echo "major" || echo "minor")
        
        echo -e "\nINFO: Version ${target_version} is a valid ${upgrade_type} version upgrade target"
        return 0
    else
        echo -e "\nERROR: Version ${target_version} is not a valid upgrade target"
        echo -e "\nINFO: Available upgrade options for PostgreSQL ${current_engine_version}:"
        echo "INFO: ----------------------------------------------------------------"
        printf "INFO: %-15s %-15s\n" "VERSION" "UPGRADE TYPE"
        echo "INFO: ----------------------------------------------------------------"
        
        # Format and display available versions
        echo "${valid_versions}" | while read -r version is_major; do
            upgrade_type=$([ "${is_major}" = "True" ] && echo "major" || echo "minor")
            printf "INFO: %-15s %-15s\n" "${version}" "${upgrade_type}"
        done
        echo "INFO: ----------------------------------------------------------------"
        return 1
    fi
}
##-------------------------------------------------------------------------------------

# function to determine if upgrade/patching path is MINOR or MAJOR #
function check_upgrade_type() {

    echo -e "\nINFO: Checking upgrade type..."

    # Extract major version numbers (family)
    current_engine_version_family=$(echo "$current_engine_version" | cut -d. -f1)
    next_engine_version_family=$(echo "$next_engine_version" | cut -d. -f1)

    echo "Current version: $current_engine_version (family: $current_engine_version_family)"
    echo "Target version: $next_engine_version (family: $next_engine_version_family)"

    # Compare versions directly without version_to_number function
    if [ "$next_engine_version_family" -gt "$current_engine_version_family" ]; then
        UPGRADE_SCOPE="major"
        echo -e "\nINFO: Major version upgrade required (family $current_engine_version_family -> $next_engine_version_family)"
        return 0
    fi

    # Compare full versions for minor upgrade check
    current_engine_version_1=$(echo "$current_engine_version" | tr -d '.')
    next_engine_version_1=$(echo "$next_engine_version" | tr -d '.')

    if [ "$current_engine_version_1" -eq "$next_engine_version_1" ]; then
        echo -e "\nINFO: Current and target versions are identical. No upgrade required."
        exit 0
    elif [ "$current_engine_version_1" -gt "$next_engine_version_1" ]; then
        echo -e "\nINFO: Current version is newer than target. No upgrade required."
        exit 0
    else
        UPGRADE_SCOPE="minor"
        echo -e "\nINFO: Minor version upgrade required"
        echo "INFO: DB Parameter Group remains unchanged"
        db_param_group_name=${current_db_param_group}
        return 0
    fi
}
##-------------------------------------------------------------------------------------

# function to update PostgreSQL extensions
function update_extensions() {

    echo -e "\nINFO: Execute update_extensions function...\n"

    # Call helper function to validate db_name
    check_db_name "${db_name}" || return $?

    # Create log file path
    local log_file="${LOGS_DIR}/${current_db_instance_id}/update_db_extensions_${DATE_TIME}.log"

    # Ensure log directory exists
    mkdir -p "${LOGS_DIR}/${current_db_instance_id}"

    # Start logging
    {
        echo "================================================================"
        echo "Execute update DB extensions Log - Started at $(date)"
        echo "================================================================"
        echo "Database Instance: ${current_db_instance_id}"
        echo "Log File: ${log_file}"
        echo "----------------------------------------------------------------"

        echo -e "\nINFO: Execute update_extensions function..."
        echo -e "INFO: Started at $(date)"

        # get DB creds from secret manager #
        get_rds_creds

        # Check if DB credentials exist
        if [ -z "${db_username}" ] || [ "${db_username}" = "null" ] || [ -z "${db_password}" ] || [ "${db_password}" = "null" ]; then
            echo -e "\nERROR: Database credentials not found in secret manager. Please check and retry again. \n"
            exit 1
        fi

        # Connect to the PostgreSQL database
        echo "INFO: Testing database connection..."
        if ! ${PSQL_BIN} -U "${db_username}" -h "${db_endpoint}" -p "${db_port}" -d "${db_name}" -c '\q' >/dev/null 2>&1; then
            echo -e "\nERROR: Failed to connect to the PostgreSQL database. Please check and retry again. \n"
            exit 1
        fi
        echo "INFO: Database connection successful"

        # Update extensions using a PL/pgSQL anonymous code block
        echo -e "\nINFO: Starting extension updates..."
        ${PSQL_BIN} -U "${db_username}" -h "${db_endpoint}" -p "${db_port}" -d "${db_name}" <<EOF
            \timing on
            
            SELECT current_timestamp AS "Start Time";

            DO \$\$
            DECLARE
                rec RECORD;
                newest_version TEXT;
                extensions_updated BOOLEAN := FALSE;
            BEGIN
                FOR rec IN
                    SELECT extname, extversion, (
                        SELECT version newest_version
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

            SELECT current_timestamp AS "End Time";
EOF

        if [ $? -ne 0 ]; then
            echo -e "\nERROR: Failed to update extensions. Please check and retry again. \n"
            exit 1
        fi

        echo -e "\nINFO: Extension update process completed at $(date)"
        echo "INFO: Log file location: ${log_file}"
        
        echo "----------------------------------------------------------------"
        echo "Operation completed at: $(date)"
        echo "================================================================"
        echo ""

    } 2>&1 | tee "${log_file}"

    return 0
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
     current_db_status=$(echo $instance_info | jq -r '.DBInstances[0].DBInstanceStatus')
     current_engine_type=$(echo $instance_info | jq -r '.DBInstances[0].Engine')
     current_engine_version=$(echo $instance_info | jq -r '.DBInstances[0].EngineVersion')
     current_engine_version_family=$(echo $instance_info | jq -r '.DBInstances[0].EngineVersion | split(".")[0:2] | join(".")')
     current_engine_version_family=$(echo "${current_engine_version_family}" | cut -d. -f1)
     current_db_param_group=$(echo $instance_info | jq -r '.DBInstances[0].DBParameterGroups[0].DBParameterGroupName')

     echo -e "\nINFO: Upgrade/Patching steps begin...\n"
     echo "current_db_instance_id = $current_db_instance_id"
     echo "current_engine_type = $current_engine_type"
     echo "current_engine_version = $current_engine_version"
     echo "current_engine_version_family = $current_engine_version_family"
     echo "current_db_status = $current_db_status"
     echo "current_db_param_group = $current_db_param_group"
     echo "db_snapshot_required = $db_snapshot_required"
     echo "db_parameter_modify = $db_parameter_modify"
     echo "db_drop_replication_slot = $db_drop_replication_slot"
     echo "run_pre_upg_tasks = $run_pre_upg_tasks"
     echo "db_name = ${db_name}"
     echo "db_endpoint = ${db_endpoint}"
     echo "db_port = ${db_port}"
     echo "S3_BUCKET_PATCH_LOGS = ${S3_BUCKET_PATCH_LOGS}"
     echo "SNS_TOPIC_ARN_EMAIL = ${SNS_TOPIC_ARN_EMAIL}"

}
##-------------------------------------------------------------------------------------

echo ""

##-------------------------------------------------------------------------------------
##------------------------EXECUTE RDS-PostgreSQL UPGRADE/PATCHING TASKS----------------
##-------------------------------------------------------------------------------------

# Check for unix functions #
check_required_utils || exit 1

# validate next engine version for numeric #
next_engine_version=$(echo "${next_engine_version}" | bc) || {
    echo -e "\nERROR: Invalid version number format: ${next_engine_version} \n"
    exit 1
}

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

    # call function to check if the next-engine-version is valid for the current rds-postgresql instance version #
    #check_rds_upgrade_version "${current_db_instance_id}" "${next_engine_version}"
    check_rds_upgrade_version "${current_db_instance_id}" "${next_engine_version}" || {
        echo -e "\nERROR: Please select a valid upgrade version and try again. \n"
        exit 1
    }

    # call function to check if upgrade/patching path is MINOR or MAJOR #
    check_upgrade_type

    ### Run PreReq tasks one or few hours prior to the DB patching/upgrade #
    ## Take DB snapshot
    ## Run Freeze
    ## Create DB parameter group if major version upgrade
    ## Check replication slots if major version upgrade
    if [ "${run_pre_upg_tasks}" = "PREUPGRADE" ]; then

        if [ "${UPGRADE_SCOPE}" = "major" ]; then
            echo -e "\nUPGRADE_SCOPE = ${UPGRADE_SCOPE}\n"

            # Create DB parameter group if major version upgrade #
            create_param_group

            # call function to check/drop replication slots - only for MAJOR version upgrade #
            run_psql_drop_repl_slot
        fi

        #call function to run Freeze in database #
        run_psql_command "FREEZE"

        # call function to take DB snapshot/backup #
        db_snapshot

    else # run_pre_upg_tasks = UPGRADE; perform upgrade/patching tasks

        db_param_group_name=${current_db_param_group}
        
        # take DB snapshot for MINOR version upgrade only; for MAJOR version, snapshot is taken automatically/default #
        if [ "${UPGRADE_SCOPE}" = "minor" ]; then
            echo -e "\nUPGRADE_SCOPE = ${UPGRADE_SCOPE}\n"
            db_snapshot
        fi

        # call function to check/drop replication slots - only for MAJOR version upgrade #
        if [ "${UPGRADE_SCOPE}" = "major" ]; then

            echo -e "\nUPGRADE_SCOPE = ${UPGRADE_SCOPE}\n"

            # call function to create parameter group
            # it is ok if this was run during PRE-REQUISITE stage (1 or few hours head of actual upgradde)
            create_param_group

            # call function to check (and drop if variable db_drop_replication_slot is set to Y) replication slots - only for MAJOR version upgrade #
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

        # call function to run UnFreeze (vacuum) in database # not needed
        #run_psql_command "UNFREEZE"

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
echo -e "END -  ${EMAIL_SUBJECT} - $(date)\n"
exit 0