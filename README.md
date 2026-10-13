# sp_MonitorTableTriggers
This is a free tool from **[DataPaws](https://datapawsconsulting.com)** for SQL Server Database Administrators to monitors table triggers across databases and alert when they’re disabled or missing

# Requirements
- SQL Server 2017+
- Database Mail (For alerts)
# What does sp_MonitorTableTriggers do?
- Monitors the status of table triggers in specified databases
- Automatically logs when specified triggers are disabled or missing to a configurable table for historical tracking (7 day default retention)
- Generate alerts when specified triggers are disabled or missing

# Alerting
If ```@EmailAlerts = 1```, the procedure will send a table-formatted email containing the trigger(s) that are disabled or missing.

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
