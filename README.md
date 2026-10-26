# sp_MonitorTableTriggers
This is a free tool from **[DataPaws](https://datapawsconsulting.com)** for SQL Server Database Administrators to monitor table triggers across databases and alert when they're disabled or missing.

# Requirements
- SQL Server 2017+
- Database Mail (For alerts)

# What does sp_MonitorTableTriggers do?
- Monitors the status of table triggers in specified databases
- Detects triggers that are disabled or missing
- Detects when a database is missing, offline, or inaccessible, so a trigger isn't silently skipped because its database can't be checked
- Automatically logs detected issues to a configurable table for historical tracking (7 day default retention)
- Generates email alerts when issues are detected

# Status Values
Each issue is reported with one of the following statuses, in both the alert email and the logging table:

| Status | Email Label | Description |
|---|---|---|
| `DISABLED` | Trigger Disabled | The trigger exists but is disabled |
| `MISSING` | Trigger Not Found | The database is accessible, but the trigger was not found |
| `DB_MISSING` | Database Not Found | The database does not exist on this server |
| `DB_OFFLINE` | Database Not Online | The database exists but is not `ONLINE` (offline, restoring, recovering, suspect, etc.) |
| `NO_ACCESS` | Database Inaccessible | The database is `ONLINE` but can't be accessed (permissions, non-readable AG secondary, etc.) |
| `ERROR` | Error Checking Trigger | An unexpected error occurred while checking the trigger |

# Alerting
If ```@EmailAlerts = 1```, the procedure will send a table-formatted email listing each trigger that is disabled, missing, or could not be checked, along with its status. Database-level problems are highlighted in a separate color from trigger-level problems.

# Logging
If ```@LoggingTable``` is specified (default: `dbo.MonitorTableTriggers`), each detected issue is logged with the database, schema, table, trigger, status, and collection time. Rows older than `@RetentionDays` (default: 7) are removed on each run. The logging table is created automatically if it doesn't exist. Set `@LoggingTable = NULL` to disable logging.

# Example Usage
The tool is designed to run as part of a scheduled SQL Agent Job that runs on a recurring basis, typically every 5 - 15 minutes.

Add Triggers to Monitor
```
INSERT INTO dbo.MonitorTableTriggersConfig
(
    database_name,
    schema_name,
    table_name,
    trigger_name
)
VALUES
    ('SalesDB', 'dbo', 'Orders', 'trg_OrdersAudit'),
    ('SalesDB', 'dbo', 'Customers', 'trg_CustomersAudit'),
    ('HRDB', 'hr', 'Employees', 'trg_EmployeesAudit');
```
Basic Monitoring
```
EXEC dbo.sp_MonitorTableTriggers;
```
Custom Email Recipients
```
EXEC dbo.sp_MonitorTableTriggers
    @EmailRecipients = 'dba@company.com;alerts@company.com';
```
Debug Mode
```
EXEC dbo.sp_MonitorTableTriggers
    @Debug = 1;
```
