$ErrorActionPreference = 'SilentlyContinue'

# ─── Enable SQL Server mixed-mode auth + sa account ──────────────────────────
Write-Host "[0/9] Configuring SQL Server auth (mixed mode + sa)..." -ForegroundColor Cyan

$regPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer',
    'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL15.MSSQLSERVER\MSSQLServer',
    'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL14.MSSQLSERVER\MSSQLServer'
)
$regSet = $false
foreach ($rp in $regPaths) {
    if (Test-Path $rp) {
        Set-ItemProperty -Path $rp -Name LoginMode -Value 2 -Force
        Write-Host "  LoginMode=2 (mixed) set at $rp" -ForegroundColor Green
        $regSet = $true; break
    }
}
if (-not $regSet) {
    # Fallback: find any MSSQL instance key
    $base = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
    Get-ChildItem $base -EA 0 | Where-Object { $_.Name -match 'MSSQL\d+\.' } | ForEach-Object {
        $rp = "$($_.PSPath)\MSSQLServer"
        if (Test-Path $rp) {
            Set-ItemProperty -Path $rp -Name LoginMode -Value 2 -Force
            Write-Host "  LoginMode=2 set at $rp" -ForegroundColor Green
            $regSet = $true
        }
    }
}

# Restart into single-user mode to enable sa
Stop-Service MSSQLSERVER -Force -EA 0
Start-Sleep 3
$p = Start-Process -FilePath "net" -ArgumentList "start MSSQLSERVER /m" -PassThru -NoNewWindow -EA 0
Start-Sleep 8

$sqlcmd = if (Get-Command sqlcmd -EA 0) { "sqlcmd" } else {
    @(
        "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe",
        "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC\160\Tools\Binn\sqlcmd.exe",
        "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\sqlcmd.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $sqlcmd) { Write-Host "[!] sqlcmd not found" -ForegroundColor Red; exit 1 }

# Enable sa in single-user mode via Windows auth
$tmp = [IO.Path]::GetTempFileName() + ".sql"
"ALTER LOGIN [sa] WITH PASSWORD='sa', CHECK_POLICY=OFF, CHECK_EXPIRATION=OFF; ALTER LOGIN [sa] ENABLE; PRINT 'sa enabled'" | Set-Content $tmp -Encoding UTF8
& $sqlcmd -S localhost -E -i $tmp -b 2>&1 | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "  $_" -ForegroundColor Green }
Remove-Item $tmp -EA 0

# Restart normally
Stop-Service MSSQLSERVER -Force -EA 0
Start-Sleep 3
Start-Service MSSQLSERVER -EA 0
Start-Sleep 5
Write-Host "  SQL Server restarted (normal mode)" -ForegroundColor Green

function Invoke-Sql($q) {
    $tmp = [IO.Path]::GetTempFileName() + ".sql"
    $q | Set-Content $tmp -Encoding UTF8
    & $sqlcmd -S localhost -U sa -P sa -i $tmp -b 2>&1 | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "  $_" }
    Remove-Item $tmp -EA 0
}

function Get-RowCount($tbl) {
    $tmp = [IO.Path]::GetTempFileName() + ".sql"
    "USE HR_Sensitive; SELECT COUNT_BIG(*) FROM dbo.$tbl;" | Set-Content $tmp -Encoding UTF8
    $out = & $sqlcmd -S localhost -U sa -P sa -i $tmp -h -1 -b 2>&1 | Where-Object { $_ -match '^\s*\d' } | Select-Object -First 1
    Remove-Item $tmp -EA 0
    return $out.Trim()
}

function Get-DbSizeMB {
    $tmp = [IO.Path]::GetTempFileName() + ".sql"
    "USE HR_Sensitive; SELECT CAST(SUM(size * 8.0 / 1024) AS INT) FROM sys.database_files WHERE type_desc = 'ROWS';" |
        Set-Content $tmp -Encoding UTF8
    $out = & $sqlcmd -S localhost -U sa -P sa -i $tmp -h -1 -b 2>&1 | Where-Object { $_ -match '^\s*\d' } | Select-Object -First 1
    Remove-Item $tmp -EA 0
    return $out.Trim()
}

Write-Host "[1/9] Initializing HR_Sensitive database..." -ForegroundColor Cyan

Invoke-Sql @"
IF DB_ID('HR_Sensitive') IS NOT NULL
BEGIN
    ALTER DATABASE HR_Sensitive SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HR_Sensitive;
END
GO
CREATE DATABASE HR_Sensitive;
ALTER DATABASE HR_Sensitive SET RECOVERY SIMPLE;
GO
"@

Invoke-Sql @"
USE HR_Sensitive;

CREATE TABLE dbo.Employees (
    ID            INT IDENTITY(1,1) PRIMARY KEY,
    FullName      NVARCHAR(100)  NOT NULL,
    SSN           CHAR(11)       NOT NULL,
    Salary        INT            NOT NULL,
    Department    NVARCHAR(50)   NOT NULL,
    Email         NVARCHAR(100)  NOT NULL,
    HireDate      DATE           NOT NULL,
    Title         NVARCHAR(80)   NOT NULL,
    ManagerID     INT            NULL,
    IsActive      BIT            NOT NULL DEFAULT 1,
    HomeAddress   NVARCHAR(200)  NOT NULL DEFAULT '',
    DOB           DATE           NULL,
    BankAccount   NVARCHAR(30)   NOT NULL DEFAULT '',
    RoutingNo     NVARCHAR(20)   NOT NULL DEFAULT '',
    Phone         NVARCHAR(20)   NOT NULL DEFAULT '',
    EmergencyName NVARCHAR(100)  NOT NULL DEFAULT '',
    EmergencyPhone NVARCHAR(20)  NOT NULL DEFAULT ''
);

CREATE TABLE dbo.Credentials (
    ID            INT IDENTITY(1,1) PRIMARY KEY,
    Service       NVARCHAR(80)   NOT NULL,
    Username      NVARCHAR(80)   NOT NULL,
    PasswordHash  NVARCHAR(200)  NOT NULL,
    LastRotated   DATE           NOT NULL,
    ExpiryDate    DATE           NULL,
    Notes         NVARCHAR(500)  NOT NULL
);

CREATE TABLE dbo.PayrollAudit (
    ID            INT IDENTITY(1,1) PRIMARY KEY,
    EmployeeID    INT            NOT NULL,
    AuditDate     DATE           NOT NULL,
    ChangedBy     NVARCHAR(80)   NOT NULL,
    OldSalary     INT            NOT NULL,
    NewSalary     INT            NOT NULL,
    Reason        NVARCHAR(200)  NOT NULL
);

CREATE TABLE dbo.EmailArchive (
    ID            BIGINT IDENTITY(1,1) PRIMARY KEY,
    Sender        NVARCHAR(120)  NOT NULL,
    Recipients    NVARCHAR(500)  NOT NULL,
    CC            NVARCHAR(300)  NOT NULL DEFAULT '',
    Subject       NVARCHAR(300)  NOT NULL,
    Body          NVARCHAR(MAX)  NOT NULL,
    SentAt        DATETIME       NOT NULL,
    HasAttachment BIT            NOT NULL DEFAULT 0,
    AttachmentName NVARCHAR(200) NOT NULL DEFAULT '',
    FolderPath    NVARCHAR(100)  NOT NULL DEFAULT 'Inbox',
    IsRead        BIT            NOT NULL DEFAULT 1,
    Importance    NVARCHAR(10)   NOT NULL DEFAULT 'Normal',
    ConversationID NVARCHAR(50)  NOT NULL DEFAULT ''
);

CREATE TABLE dbo.DocumentRepository (
    ID            BIGINT IDENTITY(1,1) PRIMARY KEY,
    FileName      NVARCHAR(200)  NOT NULL,
    FilePath      NVARCHAR(400)  NOT NULL,
    Owner         NVARCHAR(100)  NOT NULL,
    Department    NVARCHAR(50)   NOT NULL,
    Content       NVARCHAR(MAX)  NOT NULL,
    CreatedAt     DATETIME       NOT NULL,
    ModifiedAt    DATETIME       NOT NULL,
    SizeBytes     INT            NOT NULL,
    Sensitivity   NVARCHAR(20)   NOT NULL DEFAULT 'Internal',
    Version       NVARCHAR(10)   NOT NULL DEFAULT '1.0',
    Tags          NVARCHAR(200)  NOT NULL DEFAULT '',
    CheckedOutBy  NVARCHAR(80)   NOT NULL DEFAULT ''
);

CREATE TABLE dbo.SecurityEvents (
    ID            BIGINT IDENTITY(1,1) PRIMARY KEY,
    EventID       INT            NOT NULL,
    EventType     NVARCHAR(50)   NOT NULL,
    Source        NVARCHAR(80)   NOT NULL,
    Username      NVARCHAR(80)   NOT NULL,
    SourceIP      VARCHAR(45)    NOT NULL,
    TargetHost    NVARCHAR(80)   NOT NULL,
    Description   NVARCHAR(300)  NOT NULL,
    Outcome       NVARCHAR(20)   NOT NULL,
    LoggedAt      DATETIME       NOT NULL,
    ProcessID     INT            NOT NULL DEFAULT 0,
    SessionID     NVARCHAR(30)   NOT NULL DEFAULT ''
);

CREATE TABLE dbo.PayrollTransactions (
    ID              BIGINT IDENTITY(1,1) PRIMARY KEY,
    EmployeeID      INT            NOT NULL,
    PayPeriodStart  DATE           NOT NULL,
    PayPeriodEnd    DATE           NOT NULL,
    GrossPay        DECIMAL(10,2)  NOT NULL,
    FederalTax      DECIMAL(10,2)  NOT NULL,
    StateTax        DECIMAL(10,2)  NOT NULL,
    FICA            DECIMAL(10,2)  NOT NULL,
    Medicare        DECIMAL(10,2)  NOT NULL DEFAULT 0,
    NetPay          DECIMAL(10,2)  NOT NULL,
    BankAccount     NVARCHAR(30)   NOT NULL,
    RoutingNo       NVARCHAR(20)   NOT NULL,
    ProcessedAt     DATETIME       NOT NULL,
    Status          NVARCHAR(20)   NOT NULL DEFAULT 'Processed',
    PayType         NVARCHAR(20)   NOT NULL DEFAULT 'Regular'
);

CREATE TABLE dbo.VPNSessions (
    ID            BIGINT IDENTITY(1,1) PRIMARY KEY,
    Username      NVARCHAR(80)   NOT NULL,
    SourceIP      VARCHAR(45)    NOT NULL,
    ConnectedAt   DATETIME       NOT NULL,
    DisconnectedAt DATETIME      NULL,
    Duration      INT            NOT NULL,
    BytesIn       BIGINT         NOT NULL,
    BytesOut      BIGINT         NOT NULL,
    Tunnel        NVARCHAR(20)   NOT NULL,
    Device        NVARCHAR(80)   NOT NULL DEFAULT '',
    AuthMethod    NVARCHAR(30)   NOT NULL DEFAULT 'Password',
    GatewayIP     VARCHAR(45)    NOT NULL DEFAULT ''
);
"@

Write-Host "[2/9] Employees..." -ForegroundColor Cyan
# Generated entirely in T-SQL — no PS string interpolation, no PS 5.1 compatibility issues
Invoke-Sql @"
USE HR_Sensitive; SET NOCOUNT ON;

DECLARE @fn TABLE (n NVARCHAR(30));
INSERT @fn VALUES
  (N'James'),(N'Robert'),(N'Michael'),(N'William'),(N'David'),(N'Richard'),(N'Joseph'),(N'Thomas'),
  (N'Charles'),(N'Christopher'),(N'Daniel'),(N'Matthew'),(N'Anthony'),(N'Mark'),(N'Donald'),
  (N'Steven'),(N'Paul'),(N'Andrew'),(N'Kenneth'),(N'Joshua'),(N'Kevin'),(N'Brian'),(N'George'),
  (N'Mary'),(N'Patricia'),(N'Jennifer'),(N'Linda'),(N'Barbara'),(N'Susan'),(N'Jessica'),
  (N'Sarah'),(N'Karen'),(N'Lisa'),(N'Nancy'),(N'Betty'),(N'Margaret'),(N'Sandra'),(N'Ashley'),
  (N'Emily'),(N'Dorothy'),(N'Carol'),(N'Ruth'),(N'Sharon'),(N'Michelle'),(N'Laura'),(N'Amanda'),
  (N'Melissa'),(N'Rebecca'),(N'Rachel'),(N'Stephanie');

DECLARE @ln TABLE (n NVARCHAR(30));
INSERT @ln VALUES
  (N'Smith'),(N'Johnson'),(N'Williams'),(N'Brown'),(N'Jones'),(N'Garcia'),(N'Miller'),(N'Davis'),
  (N'Rodriguez'),(N'Martinez'),(N'Hernandez'),(N'Lopez'),(N'Gonzalez'),(N'Wilson'),(N'Anderson'),
  (N'Thomas'),(N'Taylor'),(N'Moore'),(N'Jackson'),(N'Martin'),(N'Lee'),(N'Perez'),(N'Thompson'),
  (N'White'),(N'Harris'),(N'Sanchez'),(N'Clark'),(N'Ramirez'),(N'Lewis'),(N'Robinson'),
  (N'Walker'),(N'Young'),(N'Allen'),(N'King'),(N'Wright'),(N'Scott'),(N'Torres'),(N'Nguyen'),
  (N'Hill'),(N'Flores'),(N'Green'),(N'Adams'),(N'Nelson'),(N'Baker'),(N'Hall'),(N'Rivera'),
  (N'Campbell'),(N'Mitchell'),(N'Carter'),(N'Roberts');

DECLARE @dept TABLE (d NVARCHAR(50), t1 NVARCHAR(60), t2 NVARCHAR(60), t3 NVARCHAR(60), s1 INT, s2 INT);
INSERT @dept VALUES
  (N'HR',          N'HR Generalist',          N'HR Manager',            N'Compensation Analyst',    52000, 135000),
  (N'Finance',     N'Financial Analyst',       N'Controller',            N'CFO',                     58000, 320000),
  (N'IT',          N'Systems Administrator',   N'IT Manager',            N'IT Director',             62000, 195000),
  (N'Legal',       N'Paralegal',               N'Corporate Counsel',     N'General Counsel',         55000, 280000),
  (N'Executive',   N'Director of Strategy',    N'VP of Operations',      N'CEO',                    165000, 420000),
  (N'Sales',       N'Account Executive',       N'Sales Manager',         N'VP of Sales',             55000, 220000),
  (N'Engineering', N'Software Engineer',       N'Engineering Manager',   N'VP of Engineering',       75000, 260000),
  (N'Operations',  N'Business Analyst',        N'Operations Manager',    N'Operations Director',     52000, 185000),
  (N'Marketing',   N'Campaign Manager',        N'Marketing Manager',     N'CMO',                     58000, 240000),
  (N'Security',    N'SOC Analyst',             N'Security Architect',    N'CISO',                    72000, 300000);

INSERT INTO dbo.Employees (FullName,SSN,Salary,Department,Email,HireDate,Title,HomeAddress,DOB,BankAccount,RoutingNo,Phone,EmergencyName,EmergencyPhone)
SELECT TOP 600
    f.n + N' ' + l.n,
    CAST(ABS(CHECKSUM(NEWID()))%200+400 AS NVARCHAR(3)) + N'-' +
        RIGHT(N'00'+CAST(ABS(CHECKSUM(NEWID()))%90+10 AS NVARCHAR(2)),2) + N'-' +
        RIGHT(N'0000'+CAST(ABS(CHECKSUM(NEWID()))%9000+1000 AS NVARCHAR(4)),4),
    CASE ABS(CHECKSUM(NEWID()))%3
        WHEN 0 THEN ABS(CHECKSUM(NEWID()))%(d.s2-d.s1)+d.s1
        WHEN 1 THEN ABS(CHECKSUM(NEWID()))%(d.s2-d.s1)+d.s1+10000
        ELSE        ABS(CHECKSUM(NEWID()))%(d.s2-d.s1-20000)+d.s1 END,
    d.d,
    LOWER(f.n) + N'.' + LOWER(l.n) + N'@contoso.com',
    DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%5840+365),GETDATE()),
    CASE ABS(CHECKSUM(NEWID()))%3 WHEN 0 THEN d.t1 WHEN 1 THEN d.t2 ELSE d.t3 END,
    CAST(ABS(CHECKSUM(NEWID()))%9000+100 AS NVARCHAR(5)) + N' ' +
        CASE ABS(CHECKSUM(NEWID()))%6 WHEN 0 THEN N'Main St' WHEN 1 THEN N'Oak Ave' WHEN 2 THEN N'Maple Dr' WHEN 3 THEN N'Cedar Ln' WHEN 4 THEN N'Park Blvd' ELSE N'Elm St' END +
        N' ' + CASE ABS(CHECKSUM(NEWID()))%5 WHEN 0 THEN N'Austin TX' WHEN 1 THEN N'Seattle WA' WHEN 2 THEN N'Denver CO' WHEN 3 THEN N'Chicago IL' ELSE N'Atlanta GA' END,
    DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%10950+9125),GETDATE()),
    CAST(ABS(CHECKSUM(NEWID()))%900000000+100000000 AS NVARCHAR(30)),
    N'0'+CAST(ABS(CHECKSUM(NEWID()))%89999999+21000000 AS NVARCHAR(10))+N'0',
    CAST(ABS(CHECKSUM(NEWID()))%800+200 AS NVARCHAR(3))+N'-'+CAST(ABS(CHECKSUM(NEWID()))%900+100 AS NVARCHAR(3))+N'-'+CAST(ABS(CHECKSUM(NEWID()))%9000+1000 AS NVARCHAR(4)),
    N'Contact ' + CAST(ROW_NUMBER() OVER (ORDER BY NEWID()) AS NVARCHAR(6)),
    CAST(ABS(CHECKSUM(NEWID()))%800+200 AS NVARCHAR(3))+N'-'+CAST(ABS(CHECKSUM(NEWID()))%900+100 AS NVARCHAR(3))+N'-'+CAST(ABS(CHECKSUM(NEWID()))%9000+1000 AS NVARCHAR(4))
FROM @fn f CROSS JOIN @ln l CROSS JOIN @dept d
ORDER BY NEWID();
"@

Write-Host "[3/9] Credentials..." -ForegroundColor Cyan
Invoke-Sql @"
USE HR_Sensitive;
INSERT INTO dbo.Credentials (Service,Username,PasswordHash,LastRotated,ExpiryDate,Notes) VALUES
('SQL Server SA','sa',N'`$2b`$12`$Kx8WqI3mNpLvT6yR9aD4OuFjZnHsUeYcBdMwQgPiAkXoElCvRtJb','2024-01-15','2024-07-15','Primary SA account. Break-glass only.'),
('SQL Server SA (backup)','sa_backup',N'`$2b`$12`$mN7pQr2sKvXwL5yT8aB3OuEiZnGrUdYcCeMwRfPjAlDoFhCtSbJk','2023-11-20','2024-05-20','Backup SA - CyberArk vault.'),
('VPN Gateway','vpnadmin',N'`$2b`$12`$Lp9nRs4tMwYxO6zU1bC7QvHkAoFiVeZdDeNxSgQhBjElCrPuTmKw','2024-02-01','2024-08-01','Palo Alto GlobalProtect admin. Shared with NOC.'),
('VPN Service Account','svc_vpn',N'`$2b`$12`$Jq8oSt5uNxZyP7aV2cD8RwIlBpGjWfAeEoOySfRiCkFmDtQuUvLx','2023-09-10','2024-03-10','Never rotated - legacy app dependency.'),
('RDP Admin','rdpadmin',N'`$2b`$12`$Hr7nTu6vOyAzQ8bW3dE9SxJmCqHkXgBfFpPzTgSjDlGnEuRvVwMy','2024-03-22','2024-09-22','Local admin on all servers. GPO-managed.'),
('Azure AD Sync','svc_aadsync',N'`$2b`$12`$Gq6mUv7wPzBaR9cX4eF0TyKnDrIlYhCgGqQaUhTkEmHoFvSwXnNz','2024-01-08','2024-07-08','AAD Connect. Sync every 30 min.'),
('Exchange Admin','exadmin',N'`$2b`$12`$Fp5lVw8xQaCbS0dY5fG1UzLoDsJmZiDhHrRbViUjFnIpGwTxYoOa','2023-12-05','2024-06-05','MFA exempt - ticket INC0049231.'),
('SharePoint Farm','svc_sharepoint',N'`$2b`$12`$Eo4kWx9yRbDcT1eZ6gH2VaMpEtKnAjEiIsScWjVkGoJqHxUyZpPb','2023-10-18','2024-04-18','All WFE/APP servers.'),
('Backup Exec','svc_backupexec',N'`$2b`$12`$Dn3jXy0zScEdU2fA7hI3WbNqFuLoeBkFJtTdXkWlHpKrIyVzAqQc','2024-04-11','2024-10-11','Local admin on all backup nodes.'),
('Veeam Backup','svc_veeam',N'`$2b`$12`$Cm2iYz1aUdFeV3gB8iJ4XcOrGvMpfClGKuUeYlXmIqLsJzWaBrDd','2024-02-28','2024-08-28','Backup repo creds in Veeam DB.'),
('SCCM','svc_sccm',N'`$2b`$12`$Bl1hZa2bVeGfW4hC9jK5YdPsHwNqgDmHLvVfZmYnJrMtKaXbCsEe','2023-08-14','2024-02-14','NAA account - software deployment across domain.'),
('Splunk','splunkadmin',N'`$2b`$12`$Ak0gAb3cWfHgX5iD0kL6ZeQtIxOrHenIMwWgAnZoKsNuLbYcDtFf','2024-05-01','2024-11-01','Indexes syslog, WinEvent, IDS.'),
('Domain Admin (break-glass)','da_breakglass',N'`$2b`$12`$Zj9fBc4dXgIhY6jE1lM7AfRuJyPsIfpJNxXhBoApLtOvMcZdEuGg','2024-01-01','2024-07-01','Physical safe room 204.'),
('WSUS','svc_wsus',N'`$2b`$12`$Yi8eCd5eYhJiZ7kF2mN8BgSvKzQtJgqKOyYiCpBqMuPnNdAeFvHh','2023-07-22','2024-01-22','Auto-approve all - no change control.'),
('Zabbix','zabbix',N'`$2b`$12`$Xh7dDe6fZiKjA8lG3nO9ChTwLaRuKfrLPzZjDqCrNvOoOeZfGwIi','2024-03-15','2024-09-15','SNMP read on all network devices.'),
('pfSense','pfadmin',N'`$2b`$12`$Wg6cEf7gAjLkB9mH4oP0DiUxMbSvLesLQaAkErDsOwNpPfAgHxJj','2024-06-01','2024-12-01','2FA disabled for NMS compat.'),
('IIS App Pool','svc_iis',N'`$2b`$12`$Vf5bFg8hBkMlC0nI5pQ1EjVyNcTwMftMRbBlFsEtPxMqQgBhIyKk','2023-11-30','2024-05-30','Write to D:\Inetpub.'),
('vCenter','vcadmin',N'`$2b`$12`$Ue4aGh9iClNmD1oJ6qR2FkWzOdUxNguNScCmGtFuQyLrRhCiJzLl','2024-04-20','2024-10-20','Manages 14 ESXi hosts.'),
('CyberArk','cyberark_admin',N'`$2b`$12`$Td3aHi0jDmOnE2pK7rS3GlXaPeVyOhvOTdDnHuGvRzMsShDjKaAm','2024-02-10','2024-08-10','PAM vault - 300+ accounts.'),
('ServiceNow','svc_snow',N'`$2b`$12`$Sc2aIj1kEnPpF3qL8sT4HmYbQfWzPiwPUeEoIvHwSaRtTiEkLbBn','2023-09-05','2024-03-05','CMDB sync + incident automation.'),
('GitHub Enterprise','svc_github',N'`$2b`$12`$Rb1aJk2lFoQqG4rM9tU5InZcRgXaQjxQVfFpJwIxTbSuUjFlMcCo','2024-01-25','2024-07-25','Repo admin on all org repos.'),
('Okta','okta_superadmin',N'`$2b`$12`$Oy8aJk5oIrTtJ7uP2wX8LqCfUiAdTmazTiIsMyLaWeVxXmIoFfFr','2024-04-05','2024-10-05','MFA policies for entire org.'),
('Ansible Tower','svc_ansible',N'`$2b`$12`$Nx7aKl6pJsUuK8vQ3xY9MrDgVjBeUnaUUjJtNzMbXfWyYnJpGgGs','2023-12-20','2024-06-20','SSH key access to all Linux servers.');
"@

Write-Host "[4/9] PayrollAudit..." -ForegroundColor Cyan
Invoke-Sql @"
USE HR_Sensitive;
SET NOCOUNT ON;
DECLARE @reasons TABLE (r NVARCHAR(200));
INSERT @reasons VALUES
  ('Annual performance review - exceeds expectations'),
  ('Annual performance review - meets expectations'),
  ('Market adjustment - retention risk'),
  ('Promotion to senior level'),('Promotion to manager'),
  ('Counter-offer match'),('Equity adjustment - below band midpoint'),
  ('Correction - payroll processing error Q2'),('Cost-of-living adjustment 2024'),
  ('New hire negotiation adjustment - 90-day review'),('Lateral transfer'),
  ('Reinstatement post-leave'),('Correction - payroll processing error Q4'),
  ('Cost-of-living adjustment 2023'),('Merit increase - Q2 cycle');

DECLARE @changers TABLE (c NVARCHAR(80));
INSERT @changers VALUES ('j.doe.hr@contoso.com'),('m.wilson.hr@contoso.com'),('k.lee.hr@contoso.com'),('admin@contoso.com');

DECLARE @i INT = 0;
WHILE @i < 300
BEGIN
    INSERT INTO dbo.PayrollAudit (EmployeeID,AuditDate,ChangedBy,OldSalary,NewSalary,Reason)
    SELECT TOP 1
        ABS(CHECKSUM(NEWID())) % 600 + 1,
        DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1460), GETDATE()),
        (SELECT TOP 1 c FROM @changers ORDER BY NEWID()),
        ABS(CHECKSUM(NEWID())) % 200000 + 45000,
        ABS(CHECKSUM(NEWID())) % 220000 + 50000,
        (SELECT TOP 1 r FROM @reasons ORDER BY NEWID())
    FROM master..spt_values;
    SET @i = @i + 1;
END
"@

Write-Host "[5/9] EmailArchive (150k rows, ~3 GB) ..." -ForegroundColor Cyan
# 3 batches x 50k rows. Each batch is a fresh sqlcmd call — no WHILE loop, no DECLARE bugs.
# Body = ~10k chars NVARCHAR = ~20KB/row → 150k x 20KB = ~3 GB
$emailSql = @"
USE HR_Sensitive; SET NOCOUNT ON;
DECLARE @b NVARCHAR(MAX) = REPLICATE(CAST(N'Internal confidential communication. This message and any attachments are intended solely for authorized recipients and may contain privileged, proprietary, or sensitive business information including compensation data, personnel records, legal matters, and strategic planning documents. Unauthorized review, disclosure, copying, distribution, or use is strictly prohibited. If received in error please notify the sender immediately and destroy all copies. Records retention: 7 years per policy RM-2019-003. ' AS NVARCHAR(MAX)), 25);
INSERT INTO dbo.EmailArchive (Sender,Recipients,CC,Subject,Body,SentAt,HasAttachment,AttachmentName,FolderPath,IsRead,Importance,ConversationID)
SELECT TOP 50000
    N'user'+CAST(ABS(CHECKSUM(NEWID()))%600+1 AS NVARCHAR(6))+N'@contoso.com',
    N'dept'+CAST(ABS(CHECKSUM(NEWID()))%10 AS NVARCHAR(3))+N'@contoso.com',
    CASE WHEN ABS(CHECKSUM(NEWID()))%4=0 THEN N'leadership@contoso.com' ELSE N'' END,
    CASE ABS(CHECKSUM(NEWID()))%6
        WHEN 0 THEN N'Re: Q3 budget review - action items required'
        WHEN 1 THEN N'Fwd: Acquisition NDA - CONFIDENTIAL - restricted distribution'
        WHEN 2 THEN N'Salary band adjustments FY2024 - HR restricted'
        WHEN 3 THEN N'M&A due diligence - Project Falcon - attorney client privileged'
        WHEN 4 THEN N'Re: Security audit findings - remediation tracking'
        ELSE      N'Workforce restructuring planning - senior leadership only' END,
    @b,
    DATEADD(MINUTE,-(ABS(CHECKSUM(NEWID()))%1576800),GETDATE()),
    CASE WHEN ABS(CHECKSUM(NEWID()))%4=0 THEN 1 ELSE 0 END,
    CASE WHEN ABS(CHECKSUM(NEWID()))%4=0 THEN
        CASE ABS(CHECKSUM(NEWID()))%3 WHEN 0 THEN N'Compensation_Report_FY2024.xlsx' WHEN 1 THEN N'Audit_Findings_CONFIDENTIAL.pdf' ELSE N'Headcount_Plan_Q4.xlsx' END
    ELSE N'' END,
    CASE ABS(CHECKSUM(NEWID()))%5 WHEN 0 THEN N'Sent' WHEN 1 THEN N'Archive' WHEN 2 THEN N'HR-Restricted' WHEN 3 THEN N'Legal-Hold' ELSE N'Inbox' END,
    CASE WHEN ABS(CHECKSUM(NEWID()))%5=0 THEN 0 ELSE 1 END,
    CASE ABS(CHECKSUM(NEWID()))%6 WHEN 0 THEN N'High' WHEN 1 THEN N'Low' ELSE N'Normal' END,
    LOWER(CONVERT(NVARCHAR(36),NEWID()))
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
"@
for ($eb = 1; $eb -le 3; $eb++) {
    Invoke-Sql $emailSql
    Write-Host "  batch $eb/3" -ForegroundColor Gray
}

Write-Host "[6/9] DocumentRepository (60k rows, ~2 GB) ..." -ForegroundColor Cyan
Invoke-Sql @"
USE HR_Sensitive; SET NOCOUNT ON;
DECLARE @c NVARCHAR(MAX) = REPLICATE(CAST(N'CONFIDENTIAL RESTRICTED DISTRIBUTION. This document contains sensitive business, financial, or personnel information. Unauthorized disclosure, reproduction, or distribution is strictly prohibited and may violate company policy and applicable law. Classification: RESTRICTED. Retention: 7 years per Records Management Policy RM-2019-003. Access is logged and audited. If received in error notify records management immediately and destroy all copies. ' AS NVARCHAR(MAX)), 25);
INSERT INTO dbo.DocumentRepository (FileName,FilePath,Owner,Department,Content,CreatedAt,ModifiedAt,SizeBytes,Sensitivity,Version,Tags,CheckedOutBy)
SELECT TOP 60000
    CASE ABS(CHECKSUM(NEWID()))%8
        WHEN 0 THEN N'Employee_Compensation_Analysis_FY2024.xlsx'
        WHEN 1 THEN N'Board_Presentation_Q3_FINAL.pptx'
        WHEN 2 THEN N'MA_Due_Diligence_ProjectFalcon_v4.docx'
        WHEN 3 THEN N'InfoSec_Audit_Findings_CONFIDENTIAL.pdf'
        WHEN 4 THEN N'HR_Headcount_Plan_Q4_2024.xlsx'
        WHEN 5 THEN N'Legal_Hold_Notice_2024_Q2.pdf'
        WHEN 6 THEN N'PenetrationTest_Report_External_2024.pdf'
        ELSE        N'Executive_Compensation_Benchmarking_2024.pdf' END,
    N'\\fileserver01\HR\Documents\2024\file_'+CAST(ABS(CHECKSUM(NEWID()))%99999 AS NVARCHAR(10))+N'.bin',
    N'user'+CAST(ABS(CHECKSUM(NEWID()))%600+1 AS NVARCHAR(6))+N'@contoso.com',
    CASE ABS(CHECKSUM(NEWID()))%6 WHEN 0 THEN N'HR' WHEN 1 THEN N'Finance' WHEN 2 THEN N'IT' WHEN 3 THEN N'Legal' WHEN 4 THEN N'Executive' ELSE N'Security' END,
    @c,
    DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%730),GETDATE()),
    DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%60),GETDATE()),
    ABS(CHECKSUM(NEWID()))%51200000+10240,
    CASE ABS(CHECKSUM(NEWID()))%3 WHEN 0 THEN N'Confidential' WHEN 1 THEN N'Restricted' ELSE N'Internal' END,
    CAST(ABS(CHECKSUM(NEWID()))%5+1 AS NVARCHAR(2))+N'.'+CAST(ABS(CHECKSUM(NEWID()))%9 AS NVARCHAR(2)),
    CASE ABS(CHECKSUM(NEWID()))%3 WHEN 0 THEN N'finance,audit' WHEN 1 THEN N'hr,compensation' ELSE N'legal,compliance' END,
    CASE WHEN ABS(CHECKSUM(NEWID()))%8=0 THEN N'user'+CAST(ABS(CHECKSUM(NEWID()))%600+1 AS NVARCHAR(6))+N'@contoso.com' ELSE N'' END
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
"@

Write-Host "[7/9] SecurityEvents (1M rows) ..." -ForegroundColor Cyan
$secSql = @"
USE HR_Sensitive; SET NOCOUNT ON;
INSERT INTO dbo.SecurityEvents (EventID,EventType,Source,Username,SourceIP,TargetHost,Description,Outcome,LoggedAt,ProcessID,SessionID)
SELECT TOP 100000
    CASE ABS(CHECKSUM(NEWID()))%7 WHEN 0 THEN 4624 WHEN 1 THEN 4625 WHEN 2 THEN 4648 WHEN 3 THEN 4768 WHEN 4 THEN 4776 WHEN 5 THEN 5140 ELSE 4720 END,
    CASE ABS(CHECKSUM(NEWID()))%5 WHEN 0 THEN N'Logon' WHEN 1 THEN N'Logon Failure' WHEN 2 THEN N'Explicit Logon' WHEN 3 THEN N'Kerberos Auth' ELSE N'Network Share Access' END,
    CASE ABS(CHECKSUM(NEWID()))%4 WHEN 0 THEN N'DC-01' WHEN 1 THEN N'DC-02' WHEN 2 THEN N'DB-Server-02' ELSE N'APP-Server-01' END,
    N'user'+CAST(ABS(CHECKSUM(NEWID()))%600+1 AS NVARCHAR(6)),
    CAST(CAST(ABS(CHECKSUM(NEWID()))%192+10 AS NVARCHAR(3))+N'.'+CAST(ABS(CHECKSUM(NEWID()))%256 AS NVARCHAR(3))+N'.'+CAST(ABS(CHECKSUM(NEWID()))%256 AS NVARCHAR(3))+N'.'+CAST(ABS(CHECKSUM(NEWID()))%254+1 AS NVARCHAR(3)) AS VARCHAR(45)),
    CASE ABS(CHECKSUM(NEWID()))%5 WHEN 0 THEN N'DB-Server-02' WHEN 1 THEN N'DC-01' WHEN 2 THEN N'FileServer-01' WHEN 3 THEN N'APP-Server-01' ELSE N'WORKSTATION-'+CAST(ABS(CHECKSUM(NEWID()))%200+1 AS NVARCHAR(6)) END,
    CASE ABS(CHECKSUM(NEWID()))%3 WHEN 0 THEN N'An account was successfully logged on' WHEN 1 THEN N'An account failed to log on - invalid credentials supplied' ELSE N'A network share object was accessed' END,
    CASE WHEN ABS(CHECKSUM(NEWID()))%10=0 THEN N'Failure' ELSE N'Success' END,
    DATEADD(SECOND,-(ABS(CHECKSUM(NEWID()))%7776000),GETDATE()),
    ABS(CHECKSUM(NEWID()))%65535+1000,
    LOWER(CONVERT(NVARCHAR(20),NEWID()))
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
"@
for ($sb = 1; $sb -le 10; $sb++) {
    Invoke-Sql $secSql
    Write-Host "  batch $sb/10" -ForegroundColor Gray
}

Write-Host "[8/9] PayrollTransactions (600k rows) + VPNSessions ..." -ForegroundColor Cyan
$payrollSql = @"
USE HR_Sensitive; SET NOCOUNT ON;
INSERT INTO dbo.PayrollTransactions (EmployeeID,PayPeriodStart,PayPeriodEnd,GrossPay,FederalTax,StateTax,FICA,Medicare,NetPay,BankAccount,RoutingNo,ProcessedAt,Status,PayType)
SELECT TOP 100000
    ABS(CHECKSUM(NEWID()))%600+1,
    CAST(DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%1095),GETDATE()) AS DATE),
    CAST(DATEADD(DAY,13,DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%1095),GETDATE())) AS DATE),
    CAST(ABS(CHECKSUM(NEWID()))%15000+1500 AS DECIMAL(10,2)),
    CAST(ABS(CHECKSUM(NEWID()))%3000+200 AS DECIMAL(10,2)),
    CAST(ABS(CHECKSUM(NEWID()))%1200+50 AS DECIMAL(10,2)),
    CAST(ABS(CHECKSUM(NEWID()))%900+100 AS DECIMAL(10,2)),
    CAST(ABS(CHECKSUM(NEWID()))%300+30 AS DECIMAL(10,2)),
    CAST(ABS(CHECKSUM(NEWID()))%10000+1000 AS DECIMAL(10,2)),
    CAST(ABS(CHECKSUM(NEWID()))%9000000000+1000000000 AS NVARCHAR(30)),
    N'0'+CAST(ABS(CHECKSUM(NEWID()))%89999999+21000000 AS NVARCHAR(10))+N'0',
    DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%1095),GETDATE()),
    CASE ABS(CHECKSUM(NEWID()))%20 WHEN 0 THEN N'Failed' WHEN 1 THEN N'Reversed' ELSE N'Processed' END,
    CASE ABS(CHECKSUM(NEWID()))%4 WHEN 0 THEN N'Overtime' WHEN 1 THEN N'Bonus' WHEN 2 THEN N'Commission' ELSE N'Regular' END
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
"@
for ($pb = 1; $pb -le 6; $pb++) {
    Invoke-Sql $payrollSql
    Write-Host "  batch $pb/6" -ForegroundColor Gray
}

Invoke-Sql @"
USE HR_Sensitive; SET NOCOUNT ON;
INSERT INTO dbo.VPNSessions (Username,SourceIP,ConnectedAt,DisconnectedAt,Duration,BytesIn,BytesOut,Tunnel,Device,AuthMethod,GatewayIP)
SELECT TOP 50000
    N'user'+CAST(ABS(CHECKSUM(NEWID()))%600+1 AS NVARCHAR(6)),
    CAST(CAST(ABS(CHECKSUM(NEWID()))%192+10 AS NVARCHAR(3))+N'.'+CAST(ABS(CHECKSUM(NEWID()))%256 AS NVARCHAR(3))+N'.'+CAST(ABS(CHECKSUM(NEWID()))%256 AS NVARCHAR(3))+N'.'+CAST(ABS(CHECKSUM(NEWID()))%254+1 AS NVARCHAR(3)) AS VARCHAR(45)),
    DATEADD(MINUTE,-(ABS(CHECKSUM(NEWID()))%525600),GETDATE()),
    DATEADD(MINUTE,ABS(CHECKSUM(NEWID()))%480,DATEADD(MINUTE,-(ABS(CHECKSUM(NEWID()))%525600),GETDATE())),
    ABS(CHECKSUM(NEWID()))%28800+120,
    ABS(CHECKSUM(NEWID()))%524288000+1048576,
    ABS(CHECKSUM(NEWID()))%104857600+524288,
    CASE ABS(CHECKSUM(NEWID()))%4 WHEN 0 THEN N'SSL-VPN' WHEN 1 THEN N'IPSec-IKEv2' WHEN 2 THEN N'IPSec-IKEv1' ELSE N'WireGuard' END,
    CASE ABS(CHECKSUM(NEWID()))%3 WHEN 0 THEN N'CONTOSO-LAPTOP-'+CAST(ABS(CHECKSUM(NEWID()))%500 AS NVARCHAR(6)) WHEN 1 THEN N'BYOD-MOBILE' ELSE N'CONTOSO-DESKTOP-'+CAST(ABS(CHECKSUM(NEWID()))%200 AS NVARCHAR(6)) END,
    CASE ABS(CHECKSUM(NEWID()))%3 WHEN 0 THEN N'Certificate' WHEN 1 THEN N'MFA-TOTP' ELSE N'Password' END,
    N'10.0.'+CAST(ABS(CHECKSUM(NEWID()))%4 AS NVARCHAR(2))+N'.1'
FROM sys.all_objects a CROSS JOIN sys.all_objects b;
"@

Write-Host "[9/9] Done." -ForegroundColor Cyan
Write-Host ""

$tables = @("Employees","Credentials","PayrollAudit","EmailArchive","DocumentRepository","SecurityEvents","PayrollTransactions","VPNSessions")
foreach ($t in $tables) {
    $n = Get-RowCount $t
    Write-Host ("  dbo.{0,-28}{1,12} rows" -f ($t + " "), $n) -ForegroundColor White
}

$mb = Get-DbSizeMB
$gb = [Math]::Round($mb / 1024, 2)
Write-Host ""
Write-Host ("  Database size: {0} MB  (~{1} GB)" -f $mb, $gb) -ForegroundColor Green

# ─── MSSQL JDBC DRIVER FOR DBEAVER ────────────────────────────────────────────
Write-Host ""
Write-Host "[*] Installing MS SQL JDBC drivers for DBeaver..." -ForegroundColor Cyan
$blobBase  = "https://newaifunstuff.blob.core.windows.net/rustdesk-deploy"
$cacheBase = "$env:APPDATA\DBeaverData\drivers\maven\maven-central\com\microsoft\sqlserver"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Kill DBeaver so it picks up config changes on next launch
Get-Process dbeaver -EA 0 | Stop-Process -Force -EA 0
Start-Sleep 1

$jarPath = "$cacheBase\mssql-jdbc\13.4.0.jre11\mssql-jdbc-13.4.0.jre11.jar"
$dllPath = "$cacheBase\mssql-jdbc_auth\13.4.0.x64\mssql-jdbc_auth-13.4.0.x64.dll"

$drivers = @(
    @{ Name = "mssql-jdbc-13.4.0.jre11.jar";      SubDir = "mssql-jdbc\13.4.0.jre11" },
    @{ Name = "mssql-jdbc_auth-13.4.0.x64.dll";    SubDir = "mssql-jdbc_auth\13.4.0.x64" }
)

foreach ($drv in $drivers) {
    $dest = "$cacheBase\$($drv.SubDir)\$($drv.Name)"
    if (Test-Path $dest) {
        Write-Host "[+] Already cached: $($drv.Name)" -ForegroundColor Green
    } else {
        $tmp = "$env:TEMP\$($drv.Name)"
        Invoke-WebRequest -Uri "$blobBase/$($drv.Name)" -OutFile $tmp -UseBasicParsing -EA 0
        if (Test-Path $tmp) {
            New-Item -ItemType Directory -Path "$cacheBase\$($drv.SubDir)" -Force | Out-Null
            Move-Item $tmp $dest -Force
            Write-Host "[+] Installed: $($drv.Name)" -ForegroundColor Green
        } else {
            Write-Host "[!] Failed to download $($drv.Name)" -ForegroundColor Yellow
        }
    }
}

# Write DBeaver driver-settings.xml so it finds local files without Maven download
$dbeaverConfigDir = "$env:APPDATA\DBeaverData\workspace6\General\.dbeaver"
New-Item -ItemType Directory -Path $dbeaverConfigDir -Force | Out-Null
$driverSettings = "$dbeaverConfigDir\driver-settings.xml"

$jarPathEsc = $jarPath -replace '\\', '/'
$dllPathEsc = $dllPath -replace '\\', '/'

@"
<?xml version="1.0" encoding="UTF-8"?>
<drivers>
    <provider id="mssql">
        <driver id="mssql_jdbc_ms_new">
            <library path="maven:/com.microsoft.sqlserver:mssql-jdbc:RELEASE[13.4.0.jre11]">
                <file id="com.microsoft.sqlserver:mssql-jdbc" version="13.4.0.jre11" type="jar" path="$jarPathEsc"/>
            </library>
            <library path="maven:/com.microsoft.sqlserver:mssql-jdbc_auth:RELEASE[13.4.0.x64]">
                <file id="com.microsoft.sqlserver:mssql-jdbc_auth" version="13.4.0.x64" type="lib" path="$dllPathEsc"/>
            </library>
        </driver>
    </provider>
</drivers>
"@ | Set-Content $driverSettings -Encoding UTF8
Write-Host "[+] DBeaver driver config written to $driverSettings" -ForegroundColor Green

# Pre-create localhost SQL Server connection
$dsFile = "$dbeaverConfigDir\data-sources.json"
if (-not (Test-Path $dsFile)) {
    @"
{
    "folders": {},
    "connections": {
        "mssql_jdbc_ms_new-local": {
            "provider": "mssql",
            "driver": "mssql_jdbc_ms_new",
            "name": "HR_Sensitive (localhost)",
            "save-password": true,
            "configuration": {
                "host": "localhost",
                "port": "1433",
                "database": "HR_Sensitive",
                "url": "jdbc:sqlserver://localhost:1433;databaseName=HR_Sensitive;encrypt=false;trustServerCertificate=true",
                "type": "dev",
                "auth-model": "native",
                "handlers": {}
            }
        }
    },
    "connection-types": {
        "dev": {
            "name": "Development",
            "color": "255,255,255",
            "description": "",
            "auto-commit": true,
            "confirm-execute": false,
            "confirm-data-change": false,
            "auto-close-transactions": true
        }
    }
}
"@ | Set-Content $dsFile -Encoding UTF8
    Write-Host "[+] Pre-created localhost SQL Server connection in DBeaver" -ForegroundColor Green
} else {
    Write-Host "[*] DBeaver data-sources.json already exists — skipping connection setup" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " DB SETUP COMPLETE" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  DBeaver connection:  localhost:1433" -ForegroundColor White
Write-Host "  Auth:                SQL Server  sa / sa" -ForegroundColor White
Write-Host "  Database:            HR_Sensitive" -ForegroundColor White
Write-Host "============================================================" -ForegroundColor Cyan
