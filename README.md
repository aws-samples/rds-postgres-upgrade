# Automate PostgreSQL Version Upgrades on Amazon RDS

Managing the lifecycle of your PostgreSQL database is essential for maintaining optimal performance, security, and feature access. Even with Amazon RDS for PostgreSQL simplifying operations, version upgrades remain a critical task for database and devops engineers, especially in large-scale environments. Manual patching or upgrades can introduce challenges such as extended downtime and potential human errors, both of which can disrupt application stability.

Automation can help address these challenges. By leveraging AWS Command Line Interface (CLI) commands within a Unix shell script, you can automate the upgrade process, including prerequisite checks and upgrading a single RDS instance. To scale this approach for multiple instances, a Unix wrapper script can loop through each RDS instance, executing the upgrade process simultaneously.

Furthermore, you can integrate with AWS System Manager using RDS tagging strategy to upgrade entire fleet of RDS instances across multiple environments — such as Development, Staging, and Production — in a consistent and automated manner.

In this repository, we will guide you through setting up automation for pre-upgrade checks and upgrading one or more RDS PostgreSQL instances.

<br>

## Features

- Automate Amazon RDS PostgreSQL version upgrades
- Perform prerequisite checks before upgrading
- Upgrade a single RDS instance
- Scale the upgrade process to multiple RDS PostgreSQL instances
- Integrate with AWS System Manager for fleet-wide upgrades

<br>

## Architecture

**Upgrade single RDS PostgreSQL instance:**

![rds-psql-patch-arch.png](./rds-psql-patch-arch.png)

      1. User connects to EC2 and executes the upgrade script
      2. Checks if RDS instance is valid
      3. Configures RDS instance to push DB and upgrade logs to CloudWatch if not configured already
      4. Retrieves secret from secret manager
      5. Performs upgrade tasks
      6. Pushes log files to S3
      7. Sends email notification.

<br>

**Upgrade fleet of RDS PostgreSQL instances using AWS Systems Manager:**

![rds-psql-patch-arch-ssm.png](./rds-psql-patch-arch-ssm.png)

      1. User connects to AWS Systems Manager console
      2. Execute automation job "RDSPostgreSQLFleetUpgrade"
      3. Connects to S3 and downloads the upgrade shell script to ec2 instance
      4. Connects to ec2 instance and identifies list of RDS PostgreSQL instances based on tag key/value pair: For e.g.: UpgradeDB = Y
      5. For each RDS PostgreSQL Instance identified, configures RDS instance to push DB and upgrade logs to CloudWatch if not configured already
      6. Retrieves secret from secret manager
      7. Performs upgrade
      8. Pushes log files to S3
      9. Sends email notification.

<br>

## High-level Tasks with PREUPGRADE and UPGRADE options

**PREUPGRADE Tasks:**

      1. Create new parameter group
      2. Take database snapshot
      3. VACUUM FREEZE.

<br>

**UPGRADE Tasks:**

      1. Create new parameter group
      2. Take database snapshot
      3. Drop replication slot(s)
      4. OS maintenance
      5. Database version upgrade
      6. PostgreSQL extensions update
      7. Analyze
      8. VACUUM (unfreeze).

<br>

## Flow Charts

**Upgrade single RDS PostgreSQL instance:**

![rds-psql-upgrade-flow-chart.png](./rds-psql-upgrade-flow-chart.png)

<br>

**Upgrade fleet of RDS PostgreSQL instances using AWS Systems Manager:**

![rds-psql-upgrade-flow-chart-fleet.png](./rds-psql-upgrade-flow-chart-fleet.png)

<br>

## Setup - Upgrade single RDS PostgreSQL instance

1. Prerequisites:
   
   ```
     a. AWS resources required:
   
        i. EC2 instance primarily to store and run upgrade script, and store log files
   
               - Required Tools:
                     -- AWS CLI
                     -- PostgreSQL client utility
                     -- jq for JSON processing
   
        ii. IAM profile attached to EC2 instance with necessary permissions
   
                - [create_rds_psql_patch_iam_policy_role_cfn.yaml] can be used to create an IAM policy and role.
                         -- Modify resource names appropriately
   
                - Attach this IAM role to ec2 instance

        iii. RDS instance(s) with:
   
                - VPC configuration
                - Subnet group(s)
                - Security group(s)
                - Parameter group
                - AWS Secrets Manager secret attached to each RDS instance
                - [create_rds_psql_instance_cfn.yaml] can be used to create DB Parameter group and RDS PostgreSQL instance
                      -- Modify resource names appropriately
      
        vi. S3 bucket to store scripts and logs (optional)
   
        v. SNS topic for notifications (optional)

     b. Network Configuration:
   
        - Database security group must allow inbound traffic from EC2 instance
   
3. Clone the repository:
   ```
   git clone https://github.com/aws-samples/rds-postgres-upgrade.git
   ```
   
4. Navigate to the project directory:
   ```
   cd rds-postgres-upgrade
   ```
   
5. Update environment variables in the shell script *[rds_psql_patch.sh]*, if required (optional)

6. Identify minor or major upgrade path. Below is an example AWS CLI command to identify appropriate upgrade path for RDS PostgreSQL 14.9
 
      ```
            aws rds describe-db-engine-versions \
              --engine postgres \
              --engine-version 14.9 \
              --query "DBEngineVersions[].ValidUpgradeTarget[].{EngineVersion:EngineVersion,IsMajorVersionUpgrade:IsMajorVersionUpgrade}" \
              --output table

            --------------------------------------------
            |         DescribeDBEngineVersions         |
            +----------------+-------------------------+
            |  EngineVersion |  IsMajorVersionUpgrade  |
            +----------------+-------------------------+
            |  14.10         |  False                  |
            |  14.11         |  False                  |
            |  14.12         |  False                  |
            |  14.13         |  False                  |
            |  14.14         |  False                  |
            |  14.15         |  False                  |
            |  15.4          |  True                   |
            |  15.5          |  True                   |
            |  15.6          |  True                   |
            |  15.7          |  True                   |
            |  15.8          |  True                   |
            |  15.9          |  True                   |
            |  15.10         |  True                   |
            +----------------+-------------------------+
      ```

7. Execute upgrade process

      a. Set up log file location in the environment (optional).
         If this variable is not set, log files will not be copied over to S3 bucket.
   
            export S3_BUCKET_PATCH_LOGS="<s3-bucket-name>"
   
            e.g.: export S3_BUCKET_PATCH_LOGS="s3-rds-psql-patch-test-bucket"
   
      b. Configure email notification (optional)
         If this variable is not set, this process will not send notification at the end of this upgrade process.
   
            export SNS_TOPIC_ARN_EMAIL="<sns-topic-arn>"
   
            e.g.: export SNS_TOPIC_ARN_EMAIL="arn:aws:sns:us-east-1:11111111111:sns-rds-psql-patch-test-sns-topic"
           
      c. Execute upgrade process.

               ./rds_psql_patch.sh [db-instance-id] [next-engine-version] [run-pre-check]
   
               e.g.: ./rds_psql_patch.sh rds-psql-patch-test-1 15.6 PREUPGRADE

               PREUPGRADE = Run pre-requisite tasks, and do NOT run upgrade tasks
               UPGRADE = Do not run pre-requisite tasks, but run upgrade tasks
      
               Note: Review this document [https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-versions.html]
                     for appropriate minor or major supported verion (a.k.a appropirate upgrade path)
      
9. Example Usage:
   
           a. Preupgrade process exeuction:

               export S3_BUCKET_PATCH_LOGS="s3-rds-psql-patch-test-bucket"
               export SNS_TOPIC_ARN_EMAIL="arn:aws:sns:us-east-1:11111111111:sns-rds-psql-patch-test-sns-topic"
               nohup ./rds_psql_patch.sh rds-psql-patch-instance-1 14.10 PREUPGRADE >rds-psql-patch-instance-1-preupgrade-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &

           b. Upgrade process exeuction

               export S3_BUCKET_PATCH_LOGS="s3-rds-psql-patch-test-bucket"
               export SNS_TOPIC_ARN_EMAIL="arn:aws:sns:us-east-1:11111111111:sns-rds-psql-patch-test-sns-topic"
               nohup ./rds_psql_patch.sh rds-psql-patch-instance-1 14.15 UPGRADE >rds-psql-patch-instance-1-upgrade-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &

<br>

## Setup - Upgrade fleet of RDS PostgreSQL instances using AWS Systems Manager

1. Prerequisites from the above section apply to this section as well.
   
2. Upload unix shell script *[rds_psql_patch.sh]* from this repo to S3 bucket

3. Create SSM automation document using CFN *[create_ssm_rds_patch_automation_document.yaml]*
    * Modify resource names appropriately

4. Execute SSM automation document "RDSPostgreSQLFleetUpgrade"
    * Identify major or minor version upgrade path as shown in the previous section
    * Provide appropriate input parameters. See below screenshots.
            -- Input parameters in SSM console
            ![rds-patch-ssm-input-parameters.png](./rds-patch-ssm-input-parameters.png)

            -- SSM automation job: Status
      ![rds-psql-upgrade-ssm-automation-job-status.png](./rds-psql-upgrade-ssm-automation-job-status.png)
            

            -- SSM automation steps (1 and 2): Status
      ![rds-psql-upgrade-ssm-automation-job-step-1-status.png](./rds-psql-upgrade-ssm-automation-job-step-1-status.png)
      ![rds-psql-upgrade-ssm-automation-job-step-1-status.png](./rds-psql-upgrade-ssm-automation-job-step-1-status.png)

<br>

## Log Files

Below log files will be generated in the logs directory for each option

<br>

**PREUPGRADE**:

| Log File Type | Purpose | Sample File Name |
|---------------|---------|-------------------|
| Pre-upgrade Execution Log | Main execution log for pre-upgrade tasks | preupgrade-rds-psql-patch-test-1-20230615-14-30-45.out |
| Freeze Task Log | Log of VACUUM FREEZE command execution | run_db_task_freeze-20230615-14-30-45.log |

<br>

**UPGRADE**:

| Log File Type | Purpose | Sample File Name |
|---------------|---------|-------------------|
| Upgrade Execution Log | Main execution log for upgrade tasks | upgrade-rds-psql-patch-test-1-20230615-14-30-45.out |
| Current DB Configuration Backup | Backup of current DB configuration before upgrade | db_current_config_backup_postgres15-20230615-14-30-45.txt |
| Replication Slot Drop Log | Log of replication slot drop operation (major upgrades only) | drop_replication_slot_20230615-14-30-45.log |
| Extension Update Log | Log of PostgreSQL extension updates | update_db_extensions_20230615-14-30-45.log |
| Analyze Task Log | Log of ANALYZE command execution | run_db_task_analyze-20230615-14-30-45.log |
| Unfreeze Task Log | Log of VACUUM (unfreeze) command execution | run_db_task_unfreeze-20230615-14-30-45.log |

<br>

## Testing
To perform end-to-end testing of this process using AWS System Manager, please follow below steps.

Note: This will create VPC, subnets, routes, ec2, RDS, security groups, IAM policy/role, NAT GW, EIP and others. 

1. Run CloudFormation scrtipt [create_rds_psql_instance_cfn.yaml] (this creates VPC, subnets, routes, ec2, RDS, security groups, IAM policy/role, S3 bucket, SNS, etc.).
2. Run CloudFormation script [create_ssm_rds_patch_automation_document.yaml] to create SSM automation document.
3. Upload RDS patch shell script [rds_psql_patch.sh] to S3 bucket created in Step 1 above.
4. Execute automation document from AWS Systems Manager console (use the steps listed in the section "Upgrade fleet of RDS PostgreSQL instances using AWS Systems Manager").

<br>

## Conclusion

The scalable solution automates RDS for PostgreSQL pre-upgrade and upgrade tasks, reducing manual effort and potential errors. With built-in logging and optional email notifications, it provides real-time visibility and comprehensive tracking. By optionally storing logs in S3, you benefit from a cost-effective solution that ensures logs are readily available for analysis, audits, and compliance purposes.

We recommend validating the solution in a non-production environment before applying it to production to ensure a smooth upgrade.

<br>

## Disclaimer

This script is provided as-is. Please review and test thoroughly before using in a production environment.

This README provides an overview of your script, including its purpose, how to use it, prerequisites, and a brief description of its functions and environment variables. It also includes some usage examples and notes about the script's behavior. You can adjust or expand this README as needed to provide more detailed information about your script.

<br>

## Contributing

Contributions are welcome! If you have any ideas, suggestions, or bug reports, please open an issue or submit a pull request.

<br>

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

<br>

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

