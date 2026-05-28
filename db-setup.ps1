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

$fn = @("James","Robert","Michael","William","David","Richard","Joseph","Thomas","Charles","Christopher",
    "Daniel","Matthew","Anthony","Mark","Donald","Steven","Paul","Andrew","Kenneth","Joshua","Kevin","Brian",
    "George","Timothy","Ronald","Edward","Jason","Jeffrey","Ryan","Jacob","Gary","Nicholas","Eric","Jonathan",
    "Mary","Patricia","Jennifer","Linda","Barbara","Susan","Jessica","Sarah","Karen","Lisa","Nancy","Betty",
    "Margaret","Sandra","Ashley","Emily","Dorothy","Donna","Carol","Ruth","Sharon","Michelle","Laura","Amanda",
    "Melissa","Rebecca","Deborah","Rachel","Stephanie","Carolyn","Christine","Marie","Janet","Catherine",
    "Ann","Joyce","Diana","Alice","Julie","Heather","Teresa","Gloria","Evelyn","Jean","Cheryl","Katherine",
    "Joan","Nicole","Christina","Angela","Kimberly","Brenda","Amy","Anna","Virginia","Kathleen","Pamela")

$ln = @("Smith","Johnson","Williams","Brown","Jones","Garcia","Miller","Davis","Rodriguez","Martinez",
    "Hernandez","Lopez","Gonzalez","Wilson","Anderson","Thomas","Taylor","Moore","Jackson","Martin","Lee",
    "Perez","Thompson","White","Harris","Sanchez","Clark","Ramirez","Lewis","Robinson","Walker","Young",
    "Allen","King","Wright","Scott","Torres","Nguyen","Hill","Flores","Green","Adams","Nelson","Baker",
    "Hall","Rivera","Campbell","Mitchell","Carter","Roberts","Turner","Phillips","Evans","Collins","Stewart",
    "Morris","Morales","Murphy","Cook","Rogers","Gutierrez","Ortiz","Morgan","Cooper","Peterson","Bailey",
    "Reed","Kelly","Howard","Ramos","Kim","Cox","Ward","Richardson","Watson","Brooks","Chavez","Wood",
    "James","Bennett","Gray","Mendoza","Ruiz","Hughes","Price","Alvarez","Castillo","Sanders","Patel","Singh")

$depts = @("HR","Finance","IT","Legal","Executive","Sales","Engineering","Operations","Marketing","Security")
$titles = @{
    HR          = @("HR Generalist","HR Manager","Recruiter","Compensation Analyst","Benefits Coordinator","HRIS Specialist","HR Director","Talent Acquisition Lead","People Operations Manager","HR Business Partner")
    Finance     = @("Financial Analyst","Controller","Staff Accountant","Payroll Manager","Treasury Analyst","CFO","Accounts Payable Specialist","Budget Analyst","Senior Accountant","Finance Director")
    IT          = @("Systems Administrator","Network Engineer","Security Analyst","Help Desk Technician","DevOps Engineer","IT Manager","Database Administrator","Cloud Architect","Infrastructure Lead","IT Director")
    Legal       = @("Corporate Counsel","Paralegal","Compliance Officer","Contract Manager","Legal Assistant","General Counsel","Privacy Officer","Risk Analyst","Associate Counsel","Legal Operations Manager")
    Executive   = @("CEO","COO","CTO","VP of Operations","Chief of Staff","VP of Finance","Director of Strategy","EVP","President","Managing Director")
    Sales       = @("Account Executive","Sales Manager","Business Development Rep","Regional Director","Inside Sales Rep","VP of Sales","Sales Engineer","Channel Manager","Sales Operations Analyst","Enterprise Account Manager")
    Engineering = @("Software Engineer","Senior Engineer","Principal Engineer","Engineering Manager","QA Engineer","Data Engineer","Platform Engineer","VP of Engineering","Staff Engineer","Tech Lead")
    Operations  = @("Operations Manager","Process Analyst","Supply Chain Coordinator","Facilities Manager","Operations Director","Logistics Analyst","Business Analyst","Program Manager","Ops Specialist","PMO Lead")
    Marketing   = @("Marketing Manager","Content Strategist","SEO Analyst","Brand Manager","Campaign Manager","Digital Marketing Specialist","VP of Marketing","Product Marketing Manager","Demand Gen Manager","CMO")
    Security    = @("Security Engineer","Penetration Tester","SOC Analyst","CISO","Incident Responder","Threat Intelligence Analyst","Security Architect","GRC Analyst","Red Team Lead","Detection Engineer")
}
$streets = @("Main St","Oak Ave","Maple Dr","Cedar Ln","Elm St","Park Blvd","Washington Ave","Lake Dr","Ridge Rd","River Rd","Forest Way","Valley Rd","Hill St","Sunset Blvd","Lincoln Ave")
$cities  = @("Austin TX","Seattle WA","Denver CO","Chicago IL","Atlanta GA","Phoenix AZ","Boston MA","Miami FL","Portland OR","Nashville TN","Dallas TX","San Diego CA","Minneapolis MN","Charlotte NC","Indianapolis IN")

$seen = @{}; $rows = @()
for ($i = 0; $i -lt 600; $i++) {
    do { $f = $fn[(Get-Random -Max $fn.Count)]; $l = $ln[(Get-Random -Max $ln.Count)] } while ($seen["$f$l"])
    $seen["$f$l"] = $true
    $dept  = $depts[$i % $depts.Count]
    $t     = ($titles[$dept])[(Get-Random -Max ($titles[$dept]).Count)]
    $sal   = switch -Regex ($t) {
        "CEO|CFO|CTO|COO|CISO|VP |Chief|EVP|President|Managing|General Counsel" { Get-Random -Min 195000 -Max 420000 }
        "Director|Principal|Staff |Lead|Manager|Architect" { Get-Random -Min 115000 -Max 210000 }
        default { Get-Random -Min 48000 -Max 118000 }
    }
    $email = "$($f.ToLower()).$($l.ToLower())@contoso.com"
    $ssn   = "$(Get-Random -Min 400 -Max 599)-$('{0:D2}' -f (Get-Random -Min 10 -Max 99))-$('{0:D4}' -f (Get-Random -Min 1000 -Max 9999))"
    $dob   = "$(Get-Random -Min 1962 -Max 2000)-$('{0:D2}' -f (Get-Random -Min 1 -Max 13))-$('{0:D2}' -f (Get-Random -Min 1 -Max 29))"
    $hire  = "$(Get-Random -Min 2009 -Max 2025)-$('{0:D2}' -f (Get-Random -Min 1 -Max 13))-$('{0:D2}' -f (Get-Random -Min 1 -Max 29))"
    $addr  = "$(Get-Random -Min 100 -Max 9999) $($streets[(Get-Random -Max $streets.Count)]), $($cities[(Get-Random -Max $cities.Count)]) $('{0:D5}' -f (Get-Random -Min 10000 -Max 99999))"
    $acct  = "$(Get-Random -Min 1000000000 -Max 9999999999)"
    $route = "0$(Get-Random -Min 21000000 -Max 89999999)0"
    $phone = "$(Get-Random -Min 200 -Max 999)-$(Get-Random -Min 200 -Max 999)-$('{0:D4}' -f (Get-Random -Min 1000 -Max 9999))"
    $en    = "$($fn[(Get-Random -Max $fn.Count)]) $($ln[(Get-Random -Max $ln.Count)])"
    $ep    = "$(Get-Random -Min 200 -Max 999)-$(Get-Random -Min 200 -Max 999)-$('{0:D4}' -f (Get-Random -Min 1000 -Max 9999))"
    $rows += "('$f $l','$ssn',$sal,'$dept','$email','$hire','$t',NULL,1,'$addr','$dob','$acct','$route','$phone','$en','$ep')"
}
for ($b = 0; $b -lt $rows.Count; $b += 50) {
    $batch = $rows[$b..([Math]::Min($b+49,$rows.Count-1))]
    Invoke-Sql "USE HR_Sensitive; INSERT INTO dbo.Employees (FullName,SSN,Salary,Department,Email,HireDate,Title,ManagerID,IsActive,HomeAddress,DOB,BankAccount,RoutingNo,Phone,EmergencyName,EmergencyPhone) VALUES $($batch -join ',');"
}

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
('Qualys','qualys_svc',N'`$2b`$12`$Qa0aKl3mGpRrH5sN0uV6JoAdShYbRkyRWgGqKxJyUcTvVkGmNdDp','2024-05-15','2024-11-15','Domain read + local admin via GPO.'),
('HashiCorp Vault','vault_root',N'`$2b`$12`$Pz9aLm4nHqSsI6tO1vW7KpBeThZcSlzSXhHrLyKzVdUwWlHnOeEq','2024-03-01','2024-09-01','Root token. Air-gapped. DR drill 2024-03-01.'),
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

Write-Host "[5/9] EmailArchive (~500k rows, ~4 GB)..." -ForegroundColor Cyan
Invoke-Sql @"
USE HR_Sensitive;
SET NOCOUNT ON;

DECLARE @subjects TABLE (s NVARCHAR(300));
INSERT @subjects VALUES
  ('Re: Q3 budget review - action items required'),
  ('Fwd: Acquisition target NDA - CONFIDENTIAL - do not forward'),
  ('Re: Board presentation deck - final review'),
  ('Salary band adjustments FY2024 - HR restricted'),
  ('Re: Security audit findings - remediation tracking'),
  ('M&A due diligence materials - Project Falcon - attorney client privileged'),
  ('Re: Workforce restructuring planning - senior leadership only'),
  ('Fwd: Vendor master contract renewal - pricing terms'),
  ('Re: Executive compensation benchmarking report'),
  ('System privileged access request - CISO approval required'),
  ('Re: Annual performance calibration session notes'),
  ('Legal hold notice - preserve all communications - immediate action required'),
  ('Re: Potential data incident response - draft notification'),
  ('Q4 headcount and compensation plan - DRAFT - do not distribute'),
  ('Re: Infrastructure refresh budget - capital expenditure approval');

DECLARE @bodies TABLE (b NVARCHAR(MAX));
INSERT @bodies VALUES
(N'Hi team, following up on our discussion from yesterday. Please review the attached documents and provide feedback by EOD Friday. Key action items: (1) Review compensation band analysis against market data, (2) Confirm Q4 headcount approvals from business unit leaders, (3) Sign off on merit increase recommendations before submission to Finance. Note this information is strictly confidential and must not be shared outside this distribution. HR will schedule individual follow-ups next week. Please acknowledge receipt.'),
(N'Per our conversation earlier this week, the audit identified several material control gaps requiring immediate remediation. Priority 1 findings must be addressed within 30 days of report issuance. The full findings report with severity ratings and remediation guidance is attached. Please coordinate with your team leads and submit status updates by the 15th. Any blockers should be escalated to the CISO immediately. This is a formal finding tracked in the GRC platform until closure. Your cooperation is essential for our compliance posture.'),
(N'Attached is the revised proposal incorporating all feedback from last week. Legal has reviewed and approved sections 3 and 7. Finance needs to sign off on the budget line items before we can proceed to contract execution. Note the updated data handling terms in section 4.2 - these are non-negotiable per our DPA requirements. The vendor has agreed to our SLA requirements but requires a 90-day implementation window. Decision needed by end of month to hold current pricing. Awaiting your written approval to proceed.'),
(N'Reminder that all privileged access credentials for the legacy system must be rotated before the migration cutover date. The service account details are documented in the IT vault under project MIGRATE-2024. Please do not transmit these credentials via email or instant messaging. All migration access will be logged and reviewed post-cutover. If you require elevated access for testing purposes submit a PAM ticket with your manager approval attached. Audit trail will be reviewed by InfoSec team within 5 business days of project completion.'),
(N'Following the earnings call, leadership has requested a full review of vendor contracts over 500k annual value. Please pull the current contract register from the procurement system and flag renewals in the next 6 months. Pay particular attention to contracts with CPI adjustment clauses and most-favored-nation pricing terms. Finance needs final numbers by the 20th for the board deck. The CFO has flagged three specific vendors for renegotiation - I will send a separate briefing. This is time-sensitive please respond with availability for a call this week.');

DECLARE @padding NVARCHAR(MAX) = REPLICATE(CAST(
  N' [Thread history preserved] Previous messages and attachments retained for compliance and audit purposes per records retention policy RM-2019-003. This communication may be subject to legal hold. Do not delete.'
AS NVARCHAR(MAX)), 28);

DECLARE @batch INT = 0;
DECLARE @batchSize INT = 10000;
DECLARE @total INT = 500000;

WHILE @batch < @total
BEGIN
    INSERT INTO dbo.EmailArchive (Sender,Recipients,CC,Subject,Body,SentAt,HasAttachment,AttachmentName,FolderPath,IsRead,Importance,ConversationID)
    SELECT TOP (@batchSize)
        LEFT(e.Email, 120),
        'dept-' + CAST(ABS(CHECKSUM(NEWID())) % 10 AS NVARCHAR) + '@contoso.com; ' + LEFT(e2.Email,80),
        CASE WHEN ABS(CHECKSUM(NEWID())) % 3 = 0 THEN 'leadership@contoso.com' ELSE '' END,
        (SELECT TOP 1 s FROM @subjects ORDER BY NEWID()),
        CAST((SELECT TOP 1 b FROM @bodies ORDER BY NEWID()) AS NVARCHAR(MAX)) + @padding,
        DATEADD(MINUTE, -(ABS(CHECKSUM(NEWID())) % 1576800), GETDATE()),
        CASE WHEN ABS(CHECKSUM(NEWID())) % 4 = 0 THEN 1 ELSE 0 END,
        CASE WHEN ABS(CHECKSUM(NEWID())) % 4 = 0 THEN
            CASE ABS(CHECKSUM(NEWID())) % 4
                WHEN 0 THEN 'Compensation_Report_FY2024.xlsx'
                WHEN 1 THEN 'Contract_Draft_v3.docx'
                WHEN 2 THEN 'Audit_Findings_CONFIDENTIAL.pdf'
                ELSE 'Headcount_Plan_Q4.xlsx' END
        ELSE '' END,
        CASE ABS(CHECKSUM(NEWID())) % 5
            WHEN 0 THEN 'Sent' WHEN 1 THEN 'Archive'
            WHEN 2 THEN 'HR-Restricted' WHEN 3 THEN 'Legal-Hold' ELSE 'Inbox' END,
        CASE WHEN ABS(CHECKSUM(NEWID())) % 5 = 0 THEN 0 ELSE 1 END,
        CASE ABS(CHECKSUM(NEWID())) % 6 WHEN 0 THEN 'High' WHEN 1 THEN 'Low' ELSE 'Normal' END,
        LOWER(CONVERT(NVARCHAR(36), NEWID()))
    FROM dbo.Employees e
    CROSS JOIN dbo.Employees e2
    WHERE e.ID <> e2.ID;

    SET @batch = @batch + @batchSize;
    DECLARE @epct INT = @batch * 100 / @total;
    RAISERROR('  %d%% (%d / %d)', 0, 1, @epct, @batch, @total) WITH NOWAIT;
    IF @batch >= @total BREAK;
END
"@

Write-Host "[6/9] DocumentRepository (~80k rows, ~2 GB)..." -ForegroundColor Cyan
Invoke-Sql @"
USE HR_Sensitive;
SET NOCOUNT ON;

DECLARE @fnames TABLE (f NVARCHAR(200));
INSERT @fnames VALUES
  ('Employee_Compensation_Analysis_FY2024.xlsx'),
  ('Board_Presentation_Q3_2024_FINAL.pptx'),
  ('Vendor_Master_Contract_Renewal_2024.docx'),
  ('InfoSec_Audit_Findings_CONFIDENTIAL.pdf'),
  ('MA_Due_Diligence_ProjectFalcon_v4.docx'),
  ('Payroll_Summary_Report_2024.xlsx'),
  ('HR_Headcount_Plan_Q4_2024.xlsx'),
  ('IT_Infrastructure_Migration_Runbook.docx'),
  ('Legal_Hold_Notice_2024_Q2.pdf'),
  ('Privileged_Access_Review_Results_Q3.xlsx'),
  ('Workforce_Restructuring_Planning_DRAFT.docx'),
  ('Executive_Compensation_Benchmarking_2024.pdf'),
  ('Data_Incident_Response_Playbook_v2.docx'),
  ('PenetrationTest_Report_External_2024.pdf'),
  ('Performance_Calibration_Session_Notes.xlsx'),
  ('Network_Architecture_Diagram_v6.vsdx'),
  ('Cloud_Migration_Business_Case.pptx'),
  ('Vendor_Security_Assessment_Report.pdf'),
  ('IT_Asset_Inventory_2024.xlsx'),
  ('DRP_BCP_Annual_Test_Results.docx');

DECLARE @content NVARCHAR(MAX) = REPLICATE(CAST(
  N'CONFIDENTIAL — RESTRICTED DISTRIBUTION. This document contains sensitive business, financial, or personnel information. Unauthorized disclosure, reproduction, or distribution is strictly prohibited and may constitute a violation of company policy, applicable law, or both. Classification: RESTRICTED. Retention: 7 years per Records Management Policy RM-2019-003. Access is logged and audited. Recipient is responsible for safeguarding this document and all copies. If received in error, notify the records management team immediately and destroy all copies. Do not forward without explicit written authorization from the document owner. '
AS NVARCHAR(MAX)), 80);

INSERT INTO dbo.DocumentRepository
    (FileName,FilePath,Owner,Department,Content,CreatedAt,ModifiedAt,SizeBytes,Sensitivity,Version,Tags,CheckedOutBy)
SELECT TOP 80000
    (SELECT TOP 1 f FROM @fnames ORDER BY NEWID()),
    '\\fileserver01\' + d.dept + '\Documents\' + CAST(YEAR(DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%730),GETDATE())) AS NVARCHAR) + '\' + (SELECT TOP 1 f FROM @fnames ORDER BY NEWID()),
    LEFT(e.Email,100),
    d.dept,
    @content,
    DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%730),GETDATE()),
    DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%60),GETDATE()),
    ABS(CHECKSUM(NEWID()))%51200000+10240,
    CASE ABS(CHECKSUM(NEWID()))%4 WHEN 0 THEN 'Confidential' WHEN 1 THEN 'Restricted' WHEN 2 THEN 'Internal' ELSE 'Public' END,
    CAST(ABS(CHECKSUM(NEWID()))%5+1 AS NVARCHAR)+'.'+CAST(ABS(CHECKSUM(NEWID()))%9 AS NVARCHAR),
    CASE ABS(CHECKSUM(NEWID()))%4 WHEN 0 THEN 'finance,audit,restricted' WHEN 1 THEN 'hr,personnel,compensation' WHEN 2 THEN 'legal,compliance,hold' ELSE 'it,security,infrastructure' END,
    CASE WHEN ABS(CHECKSUM(NEWID()))%8=0 THEN LEFT(e.Email,80) ELSE '' END
FROM dbo.Employees e
CROSS JOIN (SELECT 'HR' dept UNION SELECT 'Finance' UNION SELECT 'IT' UNION SELECT 'Legal'
            UNION SELECT 'Executive' UNION SELECT 'Security') d
CROSS JOIN master..spt_values v WHERE v.number < 100;
"@

Write-Host "[7/9] SecurityEvents (~1M rows)..." -ForegroundColor Cyan
Invoke-Sql @"
USE HR_Sensitive;
SET NOCOUNT ON;
DECLARE @batch INT=0, @batchSize INT=50000, @total INT=1000000;
WHILE @batch < @total
BEGIN
    INSERT INTO dbo.SecurityEvents (EventID,EventType,Source,Username,SourceIP,TargetHost,Description,Outcome,LoggedAt,ProcessID,SessionID)
    SELECT TOP (@batchSize)
        CASE ABS(CHECKSUM(NEWID()))%8 WHEN 0 THEN 4624 WHEN 1 THEN 4625 WHEN 2 THEN 4648
            WHEN 3 THEN 4768 WHEN 4 THEN 4776 WHEN 5 THEN 5140 WHEN 6 THEN 7045 ELSE 4720 END,
        CASE ABS(CHECKSUM(NEWID()))%6 WHEN 0 THEN 'Logon' WHEN 1 THEN 'Logon Failure'
            WHEN 2 THEN 'Explicit Logon' WHEN 3 THEN 'Kerberos Auth'
            WHEN 4 THEN 'Network Share Access' ELSE 'Service Install' END,
        CASE ABS(CHECKSUM(NEWID()))%5 WHEN 0 THEN 'DC-01' WHEN 1 THEN 'DC-02'
            WHEN 2 THEN 'DB-Server-02' WHEN 3 THEN 'APP-Server-01' ELSE 'FileServer-01' END,
        LEFT(e.FullName,15) + CAST(e.ID AS NVARCHAR),
        CAST(CAST(ABS(CHECKSUM(NEWID()))%192+10 AS NVARCHAR)+'.'+CAST(ABS(CHECKSUM(NEWID()))%256 AS NVARCHAR)+'.'+CAST(ABS(CHECKSUM(NEWID()))%256 AS NVARCHAR)+'.'+CAST(ABS(CHECKSUM(NEWID()))%254+1 AS NVARCHAR) AS VARCHAR(45)),
        CASE ABS(CHECKSUM(NEWID()))%6 WHEN 0 THEN 'DB-Server-02' WHEN 1 THEN 'DC-01'
            WHEN 2 THEN 'FileServer-01' WHEN 3 THEN 'APP-Server-01'
            WHEN 4 THEN 'MAIL-01' ELSE 'WORKSTATION-'+CAST(ABS(CHECKSUM(NEWID()))%200+1 AS NVARCHAR) END,
        CASE ABS(CHECKSUM(NEWID()))%4
            WHEN 0 THEN 'An account was successfully logged on'
            WHEN 1 THEN 'An account failed to log on - invalid credentials supplied'
            WHEN 2 THEN 'A logon was attempted using explicit credentials'
            ELSE 'A network share object was accessed' END,
        CASE WHEN ABS(CHECKSUM(NEWID()))%10=0 THEN 'Failure' ELSE 'Success' END,
        DATEADD(SECOND,-(ABS(CHECKSUM(NEWID()))%7776000),GETDATE()),
        ABS(CHECKSUM(NEWID()))%65535+1000,
        LOWER(CONVERT(NVARCHAR(20),NEWID()))
    FROM dbo.Employees e
    CROSS JOIN master..spt_values v WHERE v.number < 2000;

    SET @batch=@batch+@batchSize;
    IF @batch%200000=0 RAISERROR('  %d / %d',0,1,@batch,@total) WITH NOWAIT;
    IF @batch>=@total BREAK;
END
"@

Write-Host "[8/9] PayrollTransactions + VPNSessions..." -ForegroundColor Cyan
Invoke-Sql @"
USE HR_Sensitive;
SET NOCOUNT ON;
DECLARE @batch INT=0,@batchSize INT=50000,@total INT=600000;
WHILE @batch < @total
BEGIN
    INSERT INTO dbo.PayrollTransactions (EmployeeID,PayPeriodStart,PayPeriodEnd,GrossPay,FederalTax,StateTax,FICA,Medicare,NetPay,BankAccount,RoutingNo,ProcessedAt,Status,PayType)
    SELECT TOP (@batchSize)
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
        '0'+CAST(ABS(CHECKSUM(NEWID()))%89999999+21000000 AS NVARCHAR)+'0',
        DATEADD(DAY,-(ABS(CHECKSUM(NEWID()))%1095),GETDATE()),
        CASE ABS(CHECKSUM(NEWID()))%20 WHEN 0 THEN 'Failed' WHEN 1 THEN 'Reversed' ELSE 'Processed' END,
        CASE ABS(CHECKSUM(NEWID()))%5 WHEN 0 THEN 'Overtime' WHEN 1 THEN 'Bonus' ELSE 'Regular' END
    FROM master..spt_values a CROSS JOIN master..spt_values b;
    SET @batch=@batch+@batchSize;
    IF @batch%200000=0 RAISERROR('  PayrollTx: %d / %d',0,1,@batch,@total) WITH NOWAIT;
    IF @batch>=@total BREAK;
END

INSERT INTO dbo.VPNSessions (Username,SourceIP,ConnectedAt,DisconnectedAt,Duration,BytesIn,BytesOut,Tunnel,Device,AuthMethod,GatewayIP)
SELECT TOP 50000
    LEFT(e.FullName,15)+CAST(e.ID AS NVARCHAR),
    CAST(CAST(ABS(CHECKSUM(NEWID()))%192+10 AS NVARCHAR)+'.'+CAST(ABS(CHECKSUM(NEWID()))%256 AS NVARCHAR)+'.'+CAST(ABS(CHECKSUM(NEWID()))%256 AS NVARCHAR)+'.'+CAST(ABS(CHECKSUM(NEWID()))%254+1 AS NVARCHAR) AS VARCHAR(45)),
    DATEADD(MINUTE,-(ABS(CHECKSUM(NEWID()))%525600),GETDATE()),
    DATEADD(MINUTE,ABS(CHECKSUM(NEWID()))%480,DATEADD(MINUTE,-(ABS(CHECKSUM(NEWID()))%525600),GETDATE())),
    ABS(CHECKSUM(NEWID()))%28800+120,
    ABS(CHECKSUM(NEWID()))%524288000+1048576,
    ABS(CHECKSUM(NEWID()))%104857600+524288,
    CASE ABS(CHECKSUM(NEWID()))%4 WHEN 0 THEN 'SSL-VPN' WHEN 1 THEN 'IPSec-IKEv2' WHEN 2 THEN 'IPSec-IKEv1' ELSE 'WireGuard' END,
    CASE ABS(CHECKSUM(NEWID()))%3 WHEN 0 THEN 'CONTOSO-LAPTOP-'+CAST(ABS(CHECKSUM(NEWID()))%500 AS NVARCHAR) WHEN 1 THEN 'BYOD-MOBILE' ELSE 'CONTOSO-DESKTOP-'+CAST(ABS(CHECKSUM(NEWID()))%200 AS NVARCHAR) END,
    CASE ABS(CHECKSUM(NEWID()))%3 WHEN 0 THEN 'Certificate' WHEN 1 THEN 'MFA-TOTP' ELSE 'Password' END,
    '10.0.'+CAST(ABS(CHECKSUM(NEWID()))%4 AS NVARCHAR)+'.1'
FROM dbo.Employees e CROSS JOIN master..spt_values v WHERE v.number < 100;
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
