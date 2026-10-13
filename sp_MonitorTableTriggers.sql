USE [DBAdmin]
GO

CREATE OR ALTER PROCEDURE [dbo].[sp_MonitorTableTriggers]
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
Version: v1.0.0 - 10/13/2026
GitHub: https://github.com/DataPaws/sp_MonitorTableTriggers

Description:
    Monitors specified table triggers across databases and sends an email
    alert when specified triggers become disabled or cannot be found.

Parameters:
    @ConfigTable                    Table containing triggers to monitor
    @LoggingTable                   NULL = Disabled, Specify a table to enable logging of disabled triggers - Table can be specified in one, two, or three-part format
    @EmailAlerts                    0 = Disabled, 1 = Send an email alert when disabled or missing triggers are detected
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
        @SQL                NVARCHAR(MAX),
        @CheckTemplate      NVARCHAR(MAX),
        @MissingDbTemplate  NVARCHAR(MAX),
        @GeneratedSQL       NVARCHAR(MAX),
        @Recipients         NVARCHAR(MAX),
        @Body               NVARCHAR(MAX);

    IF @ConfigTable IS NULL
    BEGIN
        RAISERROR('No Configuration Table was specified.', 16, 1) WITH NOWAIT;
        RETURN;
    END

    IF @EmailSubject IS NULL
    BEGIN
        SET @EmailSubject = @@SERVERNAME + ' - Table Triggers Disabled';
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
        CREATE TABLE ' + @ConfigTable + '
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
        ON ' + @ConfigTable + '
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
            EXEC sp_executesql @SQL;
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
            CREATE TABLE ' + @LoggingTable + '
            (
                DatabaseName    sysname      NOT NULL,
                SchemaName      sysname      NOT NULL,
                TableName       sysname      NOT NULL,
                TriggerName     sysname      NOT NULL,
                IsDisabled      bit          NOT NULL,
                CollectionTime  datetime2(0) NOT NULL
            );

            CREATE CLUSTERED INDEX CX_CollectionTime
                ON ' + @LoggingTable + '(CollectionTime);
            ';

            IF @Debug = 1
            BEGIN
                PRINT @SQL;
            END
            ELSE
            BEGIN
                EXEC sp_executesql @SQL;
            END
        END
    END

    IF OBJECT_ID(@ConfigTable) IS NULL
    BEGIN
        PRINT 'Configuration table does not exist yet, nothing to check.';
        RETURN;
    END

    CREATE TABLE #TriggerStatus
    (
        DatabaseName    sysname         NOT NULL,
        SchemaName      sysname         NOT NULL,
        TableName       sysname         NOT NULL,
        TriggerName     sysname         NOT NULL,
        [Status]        varchar(8)      NOT NULL,   -- DISABLED or MISSING
        CollectionTime  datetime2(0)    NOT NULL DEFAULT(GETDATE())
    );

    SET @CheckTemplate = N'
	INSERT INTO #TriggerStatus (DatabaseName, SchemaName, TableName, TriggerName, [Status])
	SELECT
		N{db_lit},
		N{schema_lit},
		N{table_lit},
		N{trigger_lit},
		CASE WHEN t.[object_id] IS NULL THEN ''MISSING'' ELSE ''DISABLED'' END
	FROM (SELECT 1 AS x) AS d
	LEFT JOIN
	(
		SELECT tr.[object_id], tr.is_disabled
		FROM {db_q}.sys.triggers AS tr
		INNER JOIN {db_q}.sys.objects AS o
			ON o.[object_id] = tr.parent_id
		INNER JOIN {db_q}.sys.schemas AS s
			ON s.[schema_id] = o.[schema_id]
		WHERE tr.[name] = N{trigger_lit}
		  AND tr.parent_class = 1
		  AND o.[name] = N{table_lit}
		  AND s.[name] = N{schema_lit}
	) AS t
		ON 1 = 1
	WHERE t.[object_id] IS NULL
	   OR t.is_disabled = 1;
	';


    SET @MissingDbTemplate = N'
	INSERT INTO #TriggerStatus (DatabaseName, SchemaName, TableName, TriggerName, [Status])
	VALUES (N{db_lit}, N{schema_lit}, N{table_lit}, N{trigger_lit}, ''MISSING'');
	';

    SET @SQL = N'
    SELECT @GeneratedSQL =
        STRING_AGG
        (
            CAST(
                REPLACE(
                REPLACE(
                REPLACE(
                REPLACE(
                REPLACE(
                    x.template,
                    N''{db_q}'',        QUOTENAME(c.database_name)),
                    N''{db_lit}'',      QUOTENAME(c.database_name, '''''''')),
                    N''{schema_lit}'',  QUOTENAME(c.schema_name, '''''''')),
                    N''{table_lit}'',   QUOTENAME(c.table_name, '''''''')),
                    N''{trigger_lit}'', QUOTENAME(c.trigger_name, ''''''''))
            AS NVARCHAR(MAX)),
            NCHAR(13) + NCHAR(10)
        )
    FROM ' + @ConfigTable + N' AS c
    CROSS APPLY
    (
        SELECT
            CASE
                WHEN EXISTS
                (
                    SELECT 1
                    FROM sys.databases AS d
                    WHERE d.[name] = c.database_name
                      AND d.[state] = 0
                )
                THEN @CheckTemplate
                ELSE @MissingDbTemplate
            END AS template
    ) AS x
    WHERE c.is_active = 1;
    ';

    IF @Debug = 1
    BEGIN
        PRINT @SQL + NCHAR(10);
    END

    EXEC sp_executesql
        @SQL,
        N'@CheckTemplate NVARCHAR(MAX), @MissingDbTemplate NVARCHAR(MAX), @GeneratedSQL NVARCHAR(MAX) OUTPUT',
        @CheckTemplate = @CheckTemplate,
        @MissingDbTemplate = @MissingDbTemplate,
        @GeneratedSQL = @GeneratedSQL OUTPUT;

    IF @GeneratedSQL IS NULL
    BEGIN
        PRINT 'No active triggers are configured for monitoring.';
        RETURN;
    END

    IF @Debug = 1
    BEGIN
        PRINT @GeneratedSQL + NCHAR(10);
    END
    ELSE
    BEGIN
        EXEC sp_executesql @GeneratedSQL;
    END

    IF @LoggingTable IS NOT NULL
    BEGIN
        SET @SQL = N'
        INSERT INTO ' + @LoggingTable + '
        (
            DatabaseName,
            SchemaName,
            TableName,
            TriggerName,
            IsDisabled,
            CollectionTime
        )
        SELECT
            DatabaseName,
            SchemaName,
            TableName,
            TriggerName,
            1,
            GETDATE()
        FROM #TriggerStatus
        WHERE [Status] = ''DISABLED'';

        DELETE
        FROM ' + @LoggingTable + '
        WHERE CollectionTime < DATEADD(DAY, -@RetentionDays, GETDATE());
        ';

        IF @Debug = 1
        BEGIN
            PRINT @SQL;
        END
        ELSE
        BEGIN
            EXEC sp_executesql
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
                        CASE e.[Status] WHEN 'DISABLED' THEN N'#f8d7da' ELSE N'#fff3cd' END +
                        N';">' +
                        CASE e.[Status] WHEN 'DISABLED' THEN N'Disabled' ELSE N'Not Found' END + N'</td>' +
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
