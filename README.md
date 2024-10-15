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

    ### Single RDS PostgreSQL instance
    ! [image](https://github.com/user-attachments/assets/dd9d8563-6553-4a4e-8f03-110613ee23d9)

    ### Fleet of RDS PostgreSQL instance using AWS Systems Manager
    ![image](https://github.com/user-attachments/assets/b6539082-f475-403f-8cef-b3e7ae4b1a70)

## Flow Charts

    Upgrade Process Flow Chart for single RDS PostgreSQL instance 
    Upgrade Process Flow Chart for fleet of RDS PostgreSQL instance using AWS Systems Manager

## Getting Started

1. Clone the repository:
   ```
   git clone https://github.com/aws-samples/rds-postgres-upgrade.git
   ```
2. Navigate to the project directory:
   ```
   cd rds-postgres-upgrade
   ```
3. Explore the scripts and documentation to set up the automation process.

## Usage

    ```bash 
    ./rds_psql_patch.sh [db-instance-id] [next-engine-version] [run-pre-check]
    ./rds_psql_patch.sh [rds-psql-patch-test-1] [15.6] [PRE|UPG]
    ```

    nohup ./rds_psql_patch.sh rds-psql-patch-test-1 15.6 PRE >logs/pre-upgrade-rds-psql-patch-test-1-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &
    nohup ./rds_psql_patch.sh rds-psql-patch-test-1 15.6 UPG >logs/upgrade-rds-psql-patch-test-1-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &
    
## Architecture Diagrams

## Prerequisites

    EC2 instance with the following installed:

        AWS CLI
        PSQL client utility
        jq library

    Update environment variables if/as needed.

## Functions

    The script includes the following functions:

        wait_till_available: Check DBInstance status
        create_param_group: Create parameter group
        db_upgrade: Upgrade DBInstance
        db_modify_logs: Add DB logs to CloudWatch
        db_pending_maint: Check pending maintenance status
        get_rds_creds: Retrieve DB credentials from secret manager
        copy_logs_to_s3: Copy upgrade files to S3 bucket for future reference
        db_snapshot: Take DB snapshot/backup if required
        run_psql_command: Run analyze/vacuum freeze commands
        run_psql_drop_repl_slot: Check and drop replication slot in PSQL if exists (applies to MAJOR version upgrade only)
        check_upgrade_type: Determine if upgrade/patching path is MINOR or MAJOR
        update_extensions: Update PostgreSQL extensions
        send_email: Send email
        get_db_info: Get database related info into local variables

## Environment Variables
    current_db_instance_id: First input parameter
    next_engine_version: Second input parameter
    run_pre_upg_tasks: Third input parameter (converted to uppercase)
    LOGS_DIR: Directory for logs
    AWS_CLI: Path to AWS CLI
    PSQL_BIN: Path to PSQL binary
    db_snapshot_required: Set to "Y" if manual snapshot is required
    db_parameter_modify: Set to "Y" if security and replication related parameters need to be enabled
    DATE_TIME: Current date and time

## Notes
    The script checks for the correct number of input arguments and validates the third parameter.
    It sets an email subject based on whether it's running pre-upgrade tasks or the actual upgrade.
    The script includes error handling for incorrect input parameters.

## AWS Systems Manager Automation

To integrate the upgrade process with AWS Systems Manager, we have provided a YAML file that defines the automation workflow. The YAML file includes the following steps:

    Perform prerequisite checks
    Upgrade the RDS instance
    Validate the upgrade process

You can customize the YAML file to fit your specific requirements, such as adding additional validation steps or integrating with your monitoring and alerting systems.

## Disclaimer

This script is provided as-is. Please review and test thoroughly before using in a production environment.

This README provides an overview of your script, including its purpose, how to use it, prerequisites, and a brief description of its functions and environment variables. It also includes some usage examples and notes about the script's behavior. You can adjust or expand this README as needed to provide more detailed information about your script.

## Contributing

Contributions are welcome! If you have any ideas, suggestions, or bug reports, please open an issue or submit a pull request.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.

