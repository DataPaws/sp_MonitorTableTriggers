USE [DBAdmin]
GO

CREATE OR ALTER PROCEDURE dbo.sp_MonitorTableTriggers
(
    @ConfigTable            NVARCHAR(4000) = 'dbo.MonitorTableTriggersConfig',
    @LoggingTable           NVARCHAR(4000) = 'dbo.MonitorTableTriggers',
    @EmailAlerts            BIT = 1,
    @EmailSubject           NVARCHAR(1000) = NULL,
    @EmailRecipients        NVARCHAR(4000) = NULL,
    @DBMailProfileName      sysname = N'SQLAlertsProfile',
    @DBMailOperatorName     sysname = N'SQLAlertsOperator',
    @RetentionDays          INT = 7,
    @Debug                  BIT = 0
)
AS
BEGIN
/*
sp_MonitorTableTriggers by DataPaws
Version: v1.1.0 - 10/26/2026
GitHub: https://github.com/DataPaws/sp_MonitorTableTriggers

Description:
    Monitors specified table triggers across databases and sends an email
    alert when specified triggers are disabled, cannot be found, or cannot
    be checked because the database is unavailable.

Parameters:
    @ConfigTable                    Table containing triggers to monitor
    @LoggingTable                   NULL = Disabled, Specify a table to enable logging of detected issues - Table can be specified in one, two, or three-part format
    @EmailAlerts                    0 = Disabled, 1 = Send an email alert when issues are detected
    @EmailSubject                   NULL = default of 'ServerName - Table Trigger Alerts'
    @EmailRecipients                NULL = default of the email assigned to the SQL Agent Operator, Comma-separated email addresses
    @DBMailProfileName              Database Mail profile for sending alerts - default: SQLAlertsProfile
    @DBMailOperatorName             SQL Agent operator name for recipients - default: SQLAlertsOperator
    @RetentionDays                  Number of days to retain data in the Logging Table
    @Debug                          0 = Execute normally, 1 = Print generated SQL without execution

Configuration Table Columns:
    database_name              Database containing the trigger
    schema_name                Schema containing the table - default: dbo
    table_name                 Table containing the trigger
    trigger_name               Trigger to monitor
    is_active                  0 = Disabled, 1 = Actively monitor trigger
    created_date               Date configuration row was added

Status Values:
    DISABLED        Trigger exists but is disabled
    MISSING         Database is accessible but the trigger was not found
    DB_MISSING      Database does not exist on this server
    DB_OFFLINE      Database exists but is not ONLINE (offline, restoring, recovering, suspect, etc.)
    NO_ACCESS       Database is ONLINE but is not accessible (permissions, non-readable AG secondary, etc.)
    ERROR           Unexpected error while checking the trigger

Examples:
    INSERT INTO dbo.MonitorTableTriggersConfig
    (
        database_name,
        schema_name,
        table_name,
        trigger_name
    )
    VALUES
    (
        'SalesDB',
        'dbo',
        'Orders',
        'trg_OrdersAudit'
    );

Example Usage:
    EXEC dbo.sp_MonitorTableTriggers;

    EXEC dbo.sp_MonitorTableTriggers
        @EmailAlerts = 0,
        @Debug = 1;

    EXEC dbo.sp_MonitorTableTriggers
        @ConfigTable = 'dbo.CustomTriggerConfig',
        @LoggingTable = 'dbo.CustomTriggerLog',
        @EmailRecipients = 'dba@company.com;alerts@company.com';
*/
BEGIN TRY

    SET NOCOUNT ON;

    DECLARE
        @SQL            NVARCHAR(MAX),
        @Recipients     NVARCHAR(MAX),
        @Body           NVARCHAR(MAX),
        @DatabaseName   sysname,
        @SchemaName     sysname,
        @TableName      sysname,
        @TriggerName    sysname,
        @DbState        NVARCHAR(60),
        @Status         VARCHAR(20);

    IF @ConfigTable IS NULL
    BEGIN
        RAISERROR('No Configuration Table was specified.', 16, 1) WITH NOWAIT;
        RETURN;
    END

    IF @EmailSubject IS NULL
    BEGIN
        SET @EmailSubject = @@SERVERNAME + ' - Table Trigger Alerts';
    END

    IF @EmailRecipients IS NULL
    BEGIN
        SET @Recipients = (SELECT TOP (1) [email_address] FROM msdb.dbo.sysoperators WHERE [name] = @DBMailOperatorName);
    END
    ELSE
    BEGIN
        SET @Recipients = @EmailRecipients;
    END

    IF @Recipients IS NULL AND @EmailAlerts = 1
    BEGIN
        RAISERROR('Email alerts are enabled but no recipients are specified.', 16, 1);
        RETURN;
    END

    SET @ConfigTable =
        COALESCE(QUOTENAME(PARSENAME(@ConfigTable, 3)) + '.', '') +
        COALESCE(QUOTENAME(PARSENAME(@ConfigTable, 2)) + '.', '') +
        COALESCE(QUOTENAME(PARSENAME(@ConfigTable, 1)), '');

    IF COALESCE(RTRIM(@ConfigTable), '') = ''
    BEGIN
        RAISERROR('The configuration table input parameter is not properly formatted.', 16, 1) WITH NOWAIT;
        RETURN;
    END

    IF OBJECT_ID(@ConfigTable) IS NULL
    BEGIN
        SET @SQL = N'
        CREATE TABLE ' + @ConfigTable + N'
        (
            configuration_id INT IDENTITY(1,1) PRIMARY KEY,
            database_name sysname NOT NULL,
            schema_name sysname NOT NULL DEFAULT(''dbo''),
            table_name sysname NOT NULL,
            trigger_name sysname NOT NULL,
            is_active BIT NOT NULL DEFAULT(1),
            created_date DATETIME2(0) NOT NULL DEFAULT(GETDATE())
        );

        CREATE UNIQUE NONCLUSTERED INDEX IX_Database_Schema_Table_Trigger
        ON ' + @ConfigTable + N'
        (
            database_name,
            schema_name,
            table_name,
            trigger_name
        )
        WHERE is_active = 1;
        ';

        IF @Debug = 1
        BEGIN
            PRINT @SQL;
        END
        ELSE
        BEGIN
            EXEC sys.sp_executesql @SQL;
        END
    END

    IF @LoggingTable IS NOT NULL
    BEGIN
        SET @LoggingTable =
            COALESCE(QUOTENAME(PARSENAME(@LoggingTable, 3)) + '.', '') +
            COALESCE(QUOTENAME(PARSENAME(@LoggingTable, 2)) + '.', '') +
            COALESCE(QUOTENAME(PARSENAME(@LoggingTable, 1)), '');

        IF COALESCE(RTRIM(@LoggingTable), '') = ''
        BEGIN
            RAISERROR('The logging table input parameter is not properly formatted.', 16, 1) WITH NOWAIT;
            RETURN;
        END

        IF OBJECT_ID(@LoggingTable) IS NULL
        BEGIN
            SET @SQL = N'
            CREATE TABLE ' + @LoggingTable + N'
            (
                [DatabaseName]      sysname      NOT NULL,
                [SchemaName]        sysname      NOT NULL,
                [TableName]         sysname      NOT NULL,
                [TriggerName]       sysname      NOT NULL,
                [Status]            varchar(20)  NOT NULL,
                [CollectionTime]    datetime2(0) NOT NULL
            );

            CREATE CLUSTERED INDEX CX_CollectionTime
                ON ' + @LoggingTable + N'(CollectionTime);
            ';

            IF @Debug = 1
            BEGIN
                PRINT @SQL;
            END
            ELSE
            BEGIN
                EXEC sys.sp_executesql @SQL;
            END
        END
    END

    IF OBJECT_ID(@ConfigTable) IS NULL
    BEGIN
        PRINT 'Configuration table does not exist yet, nothing to check.';
        RETURN;
    END

    CREATE TABLE #Config
    (
        [DatabaseName]  sysname NOT NULL,
        [SchemaName]    sysname NOT NULL,
        [TableName]     sysname NOT NULL,
        [TriggerName]   sysname NOT NULL
    );

    CREATE TABLE #TriggerStatus
    (
        [DatabaseName]      sysname      NOT NULL,
        [SchemaName]        sysname      NOT NULL,
        [TableName]         sysname      NOT NULL,
        [TriggerName]       sysname      NOT NULL,
        [Status]            varchar(20)  NOT NULL,
        [CollectionTime]    datetime2(0) NOT NULL DEFAULT(GETDATE())
    );

    SET @SQL = N'
    INSERT INTO #Config (DatabaseName, SchemaName, TableName, TriggerName)
    SELECT database_name, schema_name, table_name, trigger_name
    FROM ' + @ConfigTable + N'
    WHERE is_active = 1;
    ';

    IF @Debug = 1
    BEGIN
        PRINT @SQL;
    END

    EXEC sys.sp_executesql @SQL;

    IF NOT EXISTS (SELECT 1 FROM #Config)
    BEGIN
        PRINT 'No active triggers are configured for monitoring.';
        RETURN;
    END

    DECLARE TriggerCursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT [DatabaseName], [SchemaName], [TableName], [TriggerName]
        FROM #Config
        ORDER BY [DatabaseName], [SchemaName], [TableName], [TriggerName];

    OPEN TriggerCursor;

    FETCH NEXT FROM TriggerCursor
    INTO @DatabaseName, @SchemaName, @TableName, @TriggerName;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Status  = NULL;
        SET @DbState = NULL;

        BEGIN TRY

            SELECT @DbState = d.[state_desc]
            FROM sys.databases AS d
            WHERE d.[name] = @DatabaseName;

            IF @DbState IS NULL
            BEGIN
                SET @Status = 'DB_MISSING';
            END
            ELSE IF @DbState <> N'ONLINE'
            BEGIN
                SET @Status = 'DB_OFFLINE';
            END
            ELSE IF COALESCE(HAS_DBACCESS(@DatabaseName), 0) = 0
            BEGIN
                SET @Status = 'NO_ACCESS';
            END

            IF @Status IS NOT NULL
            BEGIN
                -- Database is unavailable, the trigger can't be checked
                INSERT INTO #TriggerStatus (DatabaseName, SchemaName, TableName, TriggerName, [Status])
                VALUES (@DatabaseName, @SchemaName, @TableName, @TriggerName, @Status);
            END
            ELSE
            BEGIN
                SET @SQL = N'
                INSERT INTO #TriggerStatus (DatabaseName, SchemaName, TableName, TriggerName, [Status])
                SELECT
                    @DatabaseName,
                    @SchemaName,
                    @TableName,
                    @TriggerName,
                    CASE WHEN t.[object_id] IS NULL THEN ''MISSING'' ELSE ''DISABLED'' END
                FROM (SELECT 1 AS x) AS d
                LEFT JOIN
                (
                    SELECT tr.[object_id], tr.is_disabled
                    FROM ' + QUOTENAME(@DatabaseName) + N'.sys.triggers AS tr
                    INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.objects AS o
                        ON o.[object_id] = tr.parent_id
                    INNER JOIN ' + QUOTENAME(@DatabaseName) + N'.sys.schemas AS s
                        ON s.[schema_id] = o.[schema_id]
                    WHERE tr.[name] = @TriggerName
                      AND tr.parent_class = 1
                      AND o.[name] = @TableName
                      AND s.[name] = @SchemaName
                ) AS t
                    ON 1 = 1
                WHERE t.[object_id] IS NULL
                   OR t.is_disabled = 1;
                ';

                IF @Debug = 1
                BEGIN
                    PRINT @SQL;
                END
                ELSE
                BEGIN
                    EXEC sys.sp_executesql
                        @SQL,
                        N'@DatabaseName sysname, @SchemaName sysname, @TableName sysname, @TriggerName sysname',
                        @DatabaseName = @DatabaseName,
                        @SchemaName   = @SchemaName,
                        @TableName    = @TableName,
                        @TriggerName  = @TriggerName;
                END
            END

        END TRY
        BEGIN CATCH

            INSERT INTO #TriggerStatus (DatabaseName, SchemaName, TableName, TriggerName, [Status])
            VALUES (@DatabaseName, @SchemaName, @TableName, @TriggerName, 'ERROR');

            PRINT 'Error checking ' + QUOTENAME(@DatabaseName) + '.' + QUOTENAME(@SchemaName) + '.' + QUOTENAME(@TableName)
                + ' / ' + QUOTENAME(@TriggerName) + ': ' + ERROR_MESSAGE();

        END CATCH

        FETCH NEXT FROM TriggerCursor
        INTO @DatabaseName, @SchemaName, @TableName, @TriggerName;
    END

    CLOSE TriggerCursor;
    DEALLOCATE TriggerCursor;

    IF @LoggingTable IS NOT NULL
    BEGIN
        SET @SQL = N'
        INSERT INTO ' + @LoggingTable + N'
        (
            [DatabaseName],
            [SchemaName],
            [TableName],
            [TriggerName],
            [Status],
            [CollectionTime]
        )
        SELECT
            [DatabaseName],
            [SchemaName],
            [TableName],
            [TriggerName],
            [Status],
            [CollectionTime]
        FROM #TriggerStatus;

        DELETE
        FROM ' + @LoggingTable + N'
        WHERE CollectionTime < DATEADD(DAY, -@RetentionDays, GETDATE());
        ';

        IF @Debug = 1
        BEGIN
            PRINT @SQL;
        END
        ELSE
        BEGIN
            EXEC sys.sp_executesql
                @SQL,
                N'@RetentionDays INT',
                @RetentionDays = @RetentionDays;
        END
    END

    IF @EmailAlerts = 1
    BEGIN
        IF EXISTS (SELECT 1 FROM #TriggerStatus)
        BEGIN
            SET @Body =
            N'<html><body>' +
            N'<h3>' + @@SERVERNAME + N' - Table Trigger Alerts</h3>' +
            N'<table border="1" cellpadding="5" cellspacing="0" style="border-collapse:collapse;">' +
            N'<tr style="background-color:#f2f2f2;">
                <th>Database</th>
                <th>Schema</th>
                <th>Table</th>
                <th>Trigger</th>
                <th>Status</th>
                <th>Detected</th>
            </tr>' +
            (
                SELECT
                    N'<tr>' +
                    N'<td>' + e.[DatabaseName] + N'</td>' +
                    N'<td>' + e.[SchemaName] + N'</td>' +
                    N'<td>' + e.[TableName] + N'</td>' +
                    N'<td>' + e.[TriggerName] + N'</td>' +
                    N'<td style="background-color:' +
                        CASE e.[Status]
                            WHEN 'DISABLED' THEN N'#f8d7da'
                            WHEN 'MISSING'  THEN N'#fff3cd'
                            ELSE N'#ffe5d0'
                        END +
                        N';">' +
                        CASE e.[Status]
                            WHEN 'DISABLED'   THEN N'Trigger Disabled'
                            WHEN 'MISSING'    THEN N'Trigger Not Found'
                            WHEN 'DB_MISSING' THEN N'Database Not Found'
                            WHEN 'DB_OFFLINE' THEN N'Database Not Online'
                            WHEN 'NO_ACCESS'  THEN N'Database Inaccessible'
                            ELSE N'Error Checking Trigger'
                        END + N'</td>' +
                    N'<td>' + CONVERT(NVARCHAR(19), e.[CollectionTime], 120) + N'</td>' +
                    N'</tr>'
                FROM
                (
                    SELECT
                        DatabaseName = REPLACE(REPLACE(REPLACE(CAST(DatabaseName AS NVARCHAR(256)), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'),
                        SchemaName   = REPLACE(REPLACE(REPLACE(CAST(SchemaName   AS NVARCHAR(256)), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'),
                        TableName    = REPLACE(REPLACE(REPLACE(CAST(TableName    AS NVARCHAR(256)), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'),
                        TriggerName  = REPLACE(REPLACE(REPLACE(CAST(TriggerName  AS NVARCHAR(256)), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'),
                        [Status],
                        CollectionTime
                    FROM #TriggerStatus
                ) AS e
                ORDER BY e.[Status], e.[DatabaseName], e.[SchemaName], e.[TableName], e.[TriggerName]
                FOR XML PATH(''), TYPE
            ).value('.', 'nvarchar(max)')
            + N'</table></body></html>';

            IF @Debug = 1
            BEGIN
                PRINT 'DBMailProfileName: ' + @DBMailProfileName;
                PRINT 'EmailRecipients: ' + @Recipients;
                PRINT 'EmailSubject: ' + @EmailSubject;
                PRINT 'EmailBody: ' + @Body + NCHAR(10);
            END
            ELSE
            BEGIN
                EXEC msdb.dbo.sp_send_dbmail
                    @profile_name = @DBMailProfileName,
                    @recipients = @Recipients,
                    @subject = @EmailSubject,
                    @body_format = 'HTML',
                    @body = @Body;
            END
        END
    END

END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER()    AS ErrorNumber,
        ERROR_SEVERITY()  AS ErrorSeverity,
        ERROR_STATE()     AS ErrorState,
        ERROR_PROCEDURE() AS ErrorProcedure,
        ERROR_LINE()      AS ErrorLine,
        ERROR_MESSAGE()   AS ErrorMessage;

    THROW;

END CATCH
END
GO
