# Automate PostgreSQL Version Upgrades on Amazon RDS

Managing the lifecycle of your PostgreSQL database is essential for maintaining optimal performance, security, and feature access. Even with Amazon RDS for PostgreSQL simplifying operations, version upgrades remain a critical task for database administrators, especially in large-scale deployments. Manual upgrades can introduce challenges such as extended downtime and potential human errors, both of which can disrupt application stability.

Automation can help address these challenges. By leveraging AWS Command Line Interface (CLI) commands within a Unix shell script, you can automate the upgrade process, including prerequisite checks and upgrading a single RDS instance. To scale this approach for multiple instances, a Unix wrapper script can loop through each RDS instance, executing the upgrade process simultaneously.

Furthermore, you can integrate with AWS System Manager using RDS tag strategy to upgrade entire fleets of RDS instances across multiple environments—such as Development, Staging, and Production— in a consistent and automated manner.

In this repository, we will guide you through setting up automation for pre-upgrade checks and upgrading one or more RDS instances.

## Features

- Automate PostgreSQL version upgrades on Amazon RDS (To upgrade RDS databases. RDS-PostgreSQL only)
- Perform prerequisite checks before upgrading
- Upgrade a single RDS instance
- Scale the upgrade process to multiple RDS instances
- Integrate with AWS System Manager for fleet-wide upgrades

## Architecture Diagrams

Upgrade single RDS PostgreSQL instance:

![rds-psql-patch-arch.png](./rds-psql-patch-arch.png)

Upgrade fleet of RDS PostgreSQL instances using AWS Systems Manager:

![rds-psql-patch-arch-ssm.png](./rds-psql-patch-arch-ssm.png)

## Flow Charts

Upgrade single RDS PostgreSQL instance:

![rds-psql-upgrade-flow-chart.png](./rds-psql-upgrade-flow-chart.png)

Upgrade fleet of RDS PostgreSQL instances using AWS Systems Manager:

![rds-psql-upgrade-flow-chart-fleet.png](./rds-psql-upgrade-flow-chart-fleet.png)

## Setup - Upgrade single RDS PostgreSQL instance

1. Clone the repository:
   ```
   git clone https://github.com/aws-samples/rds-postgres-upgrade.git
   ```
2. Navigate to the project directory:
   ```
   cd rds-postgres-upgrade
   ```
3. Prerequisites:
   
     1. AWS Resources Required:
        - EC2 instance for running this script
        - IAM profile attached to EC2 instance with necessary permissions
          ```
              * create_rds_psql_patch_iam_policy_role_cfn.yaml can be used to create a policy and role.
                   ** Modify resource names appropriately
              * Attach this IAM role to ec2 instance
          ```
        - RDS instance(s) with:
          ```
              * VPC configuration
              * Subnet group(s)
              * Security group(s)
              * Parameter group
              * Secrets Manager secret
              * "create_rds_psql_instance_cfn.yaml" can be used (this creates DB Parameter group and RDS instance)
                   ** Modify resource names appropriately
        - AWS Secrets Manager secret attached to each RDS instance
        - S3 bucket to store upgrade scripts and logs
        - SNS topic for notifications
      ```

     2. Network Configuration:
        - Database security group must allow inbound traffic from EC2 instance

     3. Required Tools:
        - AWS CLI
        - PostgreSQL client utilities
        - jq for JSON processing

     4. Update environment variables if needed (optional)

     5. Usage: 
         ./rds_psql_patch.sh [db-instance-id] [next-enginer-version] [run-pre-check]
         ./rds_psql_patch.sh [rds-psql-patch-test-1] [15.6] [PREUPGRADE|UPGRADE]

         PREUPGRADE = Run pre-requisite tasks, and do NOT run upgrade tasks
         UPGRADE = Do not run pre-requisite tasks, but run upgrade tasks

         Note: Review this document [https://docs.aws.amazon.com/AmazonRDS/latest/PostgreSQLReleaseNotes/postgresql-versions.html]
               for appropriate minor or major supported verion (a.k.a appropirate upgrade path)

     6. Example Usage:
           nohup ./rds_psql_patch.sh rds-psql-patch-instance-1 14.10 PREUPGRADE >rds-psql-patch-instance-1-preupgrade-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &
           nohup ./rds_psql_patch.sh rds-psql-patch-instance-1 14.15 UPGRADE >rds-psql-patch-instance-1-upgrade-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &
      
## Setup - Upgrade fleet of RDS PostgreSQL instances using AWS Systems Manager

1. Upload unix shell script [rds_psql_patch.sh] from git repo [ https://github.com/aws-samples/rds-postgres-upgrade] to S3 bucket

2. Create SSM IAM policy and role using CFN [create_ssm_rds_patch_iam_policy_role.yaml]
    * Modify resource names appropriately

3. Create SSM automation document using CFN [create_ssm_rds_patch_automation_document.yaml]
    * Modify resource names appropriately

4. Execute SSM automation document "RDSPostgreSQLFleetUpgrade"
    * Provide appropriate input parameters

## Log Files

Below log files will be generated in the logs directory.

PREUPGRADE:

| Log File Type | Purpose | Sample File Name |
|---------------|---------|-------------------|
| Pre-upgrade Execution Log | Main execution log for pre-upgrade tasks | pre-upgrade-rds-psql-patch-test-1-20230615-14-30-45.out |
| Freeze Task Log | Log of VACUUM FREEZE command execution | run_db_task_freeze-20230615-14-30-45.log |

<br>

UPGRADE:

| Log File Type | Purpose | Sample File Name |
|---------------|---------|-------------------|
| Upgrade Execution Log | Main execution log for upgrade tasks | upgrade-rds-psql-patch-test-1-20230615-14-30-45.out |
| Current DB Configuration Backup | Backup of current DB configuration before upgrade | db_current_config_backup_postgres15-20230615-14-30-45.txt |
| Replication Slot Drop Log | Log of replication slot drop operation (major upgrades only) | drop_replication_slot_20230615-14-30-45.log |
| Extension Update Log | Log of PostgreSQL extension updates | update_db_extensions_20230615-14-30-45.log |
| Analyze Task Log | Log of ANALYZE command execution | run_db_task_analyze-20230615-14-30-45.log |
| Unfreeze Task Log | Log of VACUUM (unfreeze) command execution | run_db_task_unfreeze-20230615-14-30-45.log |

## Disclaimer

This script is provided as-is. Please review and test thoroughly before using in a production environment.

This README provides an overview of your script, including its purpose, how to use it, prerequisites, and a brief description of its functions and environment variables. It also includes some usage examples and notes about the script's behavior. You can adjust or expand this README as needed to provide more detailed information about your script.

## Contributing

Contributions are welcome! If you have any ideas, suggestions, or bug reports, please open an issue or submit a pull request.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

