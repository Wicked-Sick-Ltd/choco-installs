# =========================================================
# Chocolatey bootstrap for a new Windows machine
# =========================================================

[CmdletBinding()]
param(
    [string]$LogPath = "",
    [switch]$EnableLogging
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# Configure optional logging
$UseLogging = $EnableLogging.IsPresent -or -not [string]::IsNullOrWhiteSpace($LogPath)
if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    try {
        $logDir = Split-Path -Path $LogPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
    }
    catch {
        Write-Warning "Unable to create log directory for '$LogPath'. Logging disabled. Error: $($_.Exception.Message)"
        $UseLogging = $false
    }
}
elseif ($UseLogging) {
    $LogPath = Join-Path -Path $PSScriptRoot -ChildPath ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

if ($UseLogging) {
    Write-Host "Logging enabled: $LogPath" -ForegroundColor Cyan
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($UseLogging) {
        Add-Content -Path $LogPath -Value ("[{0}] {1}" -f (Get-Date -Format "s"), $Message)
    }
}

# cmd.exe runs the Command Processor AutoRun values before its command unless it
# is started with /D, and package installers (for example vim's install.exe via
# system()) start cmd.exe /c with this session's administrator token. Any
# non-elevated process of the logged-on user can write the HKCU value, so every
# key on the path cmd.exe opens gets a High integrity no-write-up label before
# the values are removed: Medium integrity processes then cannot re-create the
# value or rename/replace those keys. The HKCU Command Processor key is replaced
# so a handle opened before the run cannot write through it. Saved AutoRun
# values and the user ComSpec value are restored from a finally block, including
# when the run is stopped, and the labels are removed there too.
$AutoRunKeyPaths = @(
    'HKLM:\Software\Microsoft\Command Processor',
    'HKLM:\Software\WOW6432Node\Microsoft\Command Processor',
    'HKCU:\Software\Microsoft\Command Processor'
)
$UserAutoRunKeyChain = @('Software', 'Software\Microsoft', 'Software\Microsoft\Command Processor')
$OnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

if ($OnWindows) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

public static class RegistryIntegrityLabel
{
    const uint LABEL_SECURITY_INFORMATION = 0x10;
    const uint SDDL_REVISION_1 = 1;

    // RegSetKeySecurity changes only this key; SetSecurityInfo would walk the whole subtree.
    [DllImport("advapi32.dll")]
    static extern int RegSetKeySecurity(SafeRegistryHandle key, uint info, IntPtr descriptor);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out IntPtr descriptor, IntPtr length);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);

    const int HKEY_CURRENT_USER = unchecked((int)0x80000001);
    const int KEY_QUERY_VALUE = 0x0001;
    const int DELETE = 0x00010000;
    const int REG_OPTION_OPEN_LINK = 0x0008;
    const int REG_LINK = 6;

    // Opening a registry link without this option follows it and would delete the target.
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegOpenKeyEx(IntPtr key, string subKey, int options, int desired, out IntPtr result);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegQueryValueEx(IntPtr key, string name, IntPtr reserved, out int type, IntPtr data, ref int length);

    [DllImport("ntdll.dll")]
    static extern int NtDeleteKey(IntPtr key);

    [DllImport("advapi32.dll")]
    static extern int RegCloseKey(IntPtr key);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern int RegCreateKeyEx(IntPtr key, string subKey, int reserved, string className, int options, int desired, IntPtr security, out IntPtr result, out int disposition);

    [StructLayout(LayoutKind.Sequential)]
    struct SecurityAttributes
    {
        public int Length;
        public IntPtr SecurityDescriptor;
        public int InheritHandle;
    }

    public static void Set(RegistryKey key, string sddl)
    {
        IntPtr descriptor;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, out descriptor, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            int status = RegSetKeySecurity(key.Handle, LABEL_SECURITY_INFORMATION, descriptor);
            if (status != 0) throw new Win32Exception(status);
        }
        finally { LocalFree(descriptor); }
    }

    public static bool IsSymbolicLink(string subKey)
    {
        IntPtr handle;
        int status = RegOpenKeyEx(new IntPtr(HKEY_CURRENT_USER), subKey, REG_OPTION_OPEN_LINK, KEY_QUERY_VALUE, out handle);
        if (status != 0) return false;
        try
        {
            int type = 0;
            int length = 0;
            // A null buffer returns ERROR_MORE_DATA (234) when the value exists, with the type filled in.
            status = RegQueryValueEx(handle, "SymbolicLinkValue", IntPtr.Zero, out type, IntPtr.Zero, ref length);
            return (status == 0 || status == 234) && type == REG_LINK;
        }
        finally { RegCloseKey(handle); }
    }

    // Deletes the link key itself. .NET DeleteSubKey follows the link.
    public static void DeleteSymbolicLink(string subKey)
    {
        IntPtr handle;
        int status = RegOpenKeyEx(new IntPtr(HKEY_CURRENT_USER), subKey, REG_OPTION_OPEN_LINK, DELETE, out handle);
        if (status != 0) throw new Win32Exception(status);
        try
        {
            status = NtDeleteKey(handle);
            if (status != 0) throw new Win32Exception("Deleting the registry link failed with status 0x" + status.ToString("X8"));
        }
        finally { RegCloseKey(handle); }
    }

    // The label is part of the create, so the new key is never opened while it has no label.
    public static void CreateWithLabel(string subKey, string sddl)
    {
        IntPtr descriptor;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, out descriptor, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            SecurityAttributes attributes = new SecurityAttributes();
            attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
            attributes.SecurityDescriptor = descriptor;
            attributes.InheritHandle = 0;
            IntPtr buffer = Marshal.AllocHGlobal(attributes.Length);
            try
            {
                Marshal.StructureToPtr(attributes, buffer, false);
                IntPtr handle;
                int disposition;
                int status = RegCreateKeyEx(new IntPtr(HKEY_CURRENT_USER), subKey, 0, null, 0, 0xF003F, buffer, out handle, out disposition);
                if (status != 0) throw new Win32Exception(status);
                RegCloseKey(handle);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        finally { LocalFree(descriptor); }
    }
}
'@
}

function Set-UserKeyIntegrityLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubKey,

        # 'S:(ML;;NW;;;HI)' locks the key; 'S:' (empty SACL) restores the default label.
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $rights = [System.Security.AccessControl.RegistryRights]'ReadPermissions, TakeOwnership'
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::Default, $rights)
    if ($null -eq $key) {
        throw "HKCU\$SubKey does not exist."
    }
    try {
        [RegistryIntegrityLabel]::Set($key, $Label)
    }
    finally {
        $key.Close()
    }
}

function Unlock-UserAutoRunKeyChain {
    foreach ($subKey in $UserAutoRunKeyChain) {
        try {
            Set-UserKeyIntegrityLabel -SubKey $subKey -Label 'S:'
        }
        catch {
            Write-Warning "Unable to remove the integrity label from HKCU\$subKey. Error: $($_.Exception.Message)"
            Write-Log "FAIL remove integrity label: HKCU\$subKey"
        }
    }
}

# Saved before AutoRun is removed and written back from the finally block, including
# when the run is stopped. The value itself is logged only if the restore fails.
$Script:SavedAutoRunValues = New-Object System.Collections.Generic.List[object]
$Script:UserComSpecSuspended = $false
$Script:HadUserComSpec = $false
$Script:SavedUserComSpec = $null
$Script:ReplacedCommandProcessorLink = $false
$Script:InstallRecoveryFailed = $false
$Script:OriginalCommandProcessorDacl = $null

function Save-CommandProcessorAutoRunValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $property = Get-ItemProperty -Path $Path -Name AutoRun -ErrorAction SilentlyContinue
    if ($null -eq $property) {
        return
    }

    $value = $property.AutoRun
    $kind = [Microsoft.Win32.RegistryValueKind]::String
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -ne $key -and $null -ne $key.PSObject.Methods['GetValueKind']) {
        try {
            $kind = $key.GetValueKind('AutoRun')
            $raw = $key.GetValue('AutoRun', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $raw) {
                $value = $raw
            }
        }
        catch {
            Write-Warning "Could not read the kind of the AutoRun value at $Path. It will be restored as a string."
            Write-Log "WARN AutoRun kind unreadable at $Path; restoring as a string."
        }
        finally {
            if ($null -ne $key.PSObject.Methods['Close']) {
                $key.Close()
            }
        }
    }

    $Script:SavedAutoRunValues.Add([pscustomobject]@{
            Path  = $Path
            Kind  = $kind
            Value = $value
        }) | Out-Null
    Write-Warning "Temporarily removing the cmd.exe AutoRun value from $Path so it cannot run with administrator rights. It will be restored when this script ends."
    Write-Log "Temporarily removing AutoRun from $Path; it will be restored when the script ends."
}

function Restore-CommandProcessorAutoRunValues {
    # @() on List[object] throws "Argument types do not match" under StrictMode.
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($saved in $Script:SavedAutoRunValues) {
        $pending.Add($saved) | Out-Null
    }
    $Script:SavedAutoRunValues.Clear()
    foreach ($saved in $pending) {
        try {
            if (-not (Test-Path -LiteralPath $saved.Path)) {
                New-Item -Path $saved.Path -Force -ErrorAction Stop | Out-Null
            }
            $typeName = [string]$saved.Kind
            if ([string]::IsNullOrWhiteSpace($typeName) -or $typeName -eq 'Unknown' -or $typeName -eq 'None') {
                $typeName = 'String'
            }
            New-ItemProperty -Path $saved.Path -Name AutoRun -Value $saved.Value -PropertyType $typeName -Force -ErrorAction Stop | Out-Null
            Write-Log "Restored AutoRun at $($saved.Path)"
        }
        catch {
            $shown = $saved.Value
            if ($shown -is [byte[]]) {
                $shown = [System.BitConverter]::ToString([byte[]]$shown)
            }
            elseif ($shown -is [Array]) {
                $shown = $shown -join '|'
            }
            $Script:InstallRecoveryFailed = $true
            Write-Warning "Unable to restore cmd.exe AutoRun at $($saved.Path). Set it again to: $shown"
            Write-Log "FAIL restore AutoRun at $($saved.Path): $($_.Exception.Message). Previous value: $shown"
        }
    }
}

function Suspend-UserComSpec {
    # Label the key before the value is read or cleared. A write in the gap
    # between a delete and a later label would otherwise stick.
    $Script:UserComSpecSuspended = $true
    [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment').Close()
    Set-UserKeyIntegrityLabel -SubKey 'Environment' -Label 'S:(ML;;NW;;;HI)'
    $current = [System.Environment]::GetEnvironmentVariable('ComSpec', 'User')
    if (-not [string]::IsNullOrEmpty($current)) {
        $Script:SavedUserComSpec = $current
        $Script:HadUserComSpec = $true
    }
}

function Clear-CapturedUserComSpec {
    if (-not $Script:HadUserComSpec) {
        return
    }
    [System.Environment]::SetEnvironmentVariable('ComSpec', $null, 'User')
    Write-Warning "Temporarily removing the user ComSpec value so package installs cannot be redirected. It will be restored when this script ends."
    Write-Log "Temporarily removed the user ComSpec value; it will be restored when the script ends."
    $remaining = [System.Environment]::GetEnvironmentVariable('ComSpec', 'User')
    if (-not [string]::IsNullOrEmpty($remaining)) {
        throw "User ComSpec is set and could not be cleared."
    }
}

function Assert-UserComSpecStillClear {
    $current = [System.Environment]::GetEnvironmentVariable('ComSpec', 'User')
    if ([string]::IsNullOrEmpty($current)) {
        return
    }
    [System.Environment]::SetEnvironmentVariable('ComSpec', $null, 'User')
    $current = [System.Environment]::GetEnvironmentVariable('ComSpec', 'User')
    if (-not [string]::IsNullOrEmpty($current)) {
        throw "User ComSpec is set and could not be cleared."
    }
}

function Resume-UserComSpec {
    if (-not $Script:UserComSpecSuspended) {
        return
    }
    try {
        Set-UserKeyIntegrityLabel -SubKey 'Environment' -Label 'S:'
    }
    catch {
        Write-Warning "Unable to remove the integrity label from HKCU\Environment. Error: $($_.Exception.Message)"
        Write-Log "FAIL remove integrity label: HKCU\Environment"
    }
    if ($Script:HadUserComSpec) {
        try {
            [System.Environment]::SetEnvironmentVariable('ComSpec', $Script:SavedUserComSpec, 'User')
            Write-Log "Restored the user ComSpec value."
        }
        catch {
            $Script:InstallRecoveryFailed = $true
            Write-Warning "Unable to restore the user ComSpec value. Set it again to: $($Script:SavedUserComSpec)"
            Write-Log "FAIL restore user ComSpec: $($_.Exception.Message). Previous value: $($Script:SavedUserComSpec)"
        }
    }
    $Script:UserComSpecSuspended = $false
    $Script:HadUserComSpec = $false
    $Script:SavedUserComSpec = $null
}

function Protect-UserCommandProcessorKey {
    $relative = 'Software\Microsoft\Command Processor'
    $hive = [Microsoft.Win32.Registry]::CurrentUser

    # A link would send a later delete at the target. Replace the link itself.
    if ([RegistryIntegrityLabel]::IsSymbolicLink($relative)) {
        [RegistryIntegrityLabel]::DeleteSymbolicLink($relative)
        # DACL for SYSTEM and Administrators, plus the High no-write-up label, in the create itself.
        # A SACL in the create call needs SeSecurityPrivilege, which a normal elevated
        # token does not have enabled. The label is applied by the call below.
        [RegistryIntegrityLabel]::CreateWithLabel($relative, 'D:P(A;;KA;;;SY)(A;;KA;;;BA)')
        Set-UserKeyIntegrityLabel -SubKey $relative -Label 'S:(ML;;NW;;;HI)'
        $Script:ReplacedCommandProcessorLink = $true
        Write-Warning "Replaced the registry link at HKCU\$relative so an existing handle cannot set AutoRun."
        Write-Log "Replaced registry link: HKCU\$relative"
        return
    }

    $preserved = New-Object System.Collections.Generic.List[object]
    $existing = $hive.OpenSubKey($relative)
    if ($null -ne $existing) {
        try {
            if ($existing.GetSubKeyNames().Length -gt 0) {
                throw "HKCU\$relative has subkeys, so it cannot be replaced without deleting them."
            }
            foreach ($name in $existing.GetValueNames()) {
                if ($name -eq 'AutoRun') {
                    continue
                }
                $preserved.Add([pscustomobject]@{
                        Name  = $name
                        Kind  = $existing.GetValueKind($name)
                        Value = $existing.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    }) | Out-Null
            }
        }
        finally {
            $existing.Close()
        }
        # Deletes the key object. Handles opened earlier fail with ERROR_KEY_DELETED.
        $hive.DeleteSubKey($relative, $true)
    }

    # A SACL in the create call needs SeSecurityPrivilege, which a normal elevated
    # token does not have enabled. The label is applied by the call below.
    [RegistryIntegrityLabel]::CreateWithLabel($relative, 'D:P(A;;KA;;;SY)(A;;KA;;;BA)')
    $created = $hive.OpenSubKey($relative, $true)
    if ($null -eq $created) {
        throw "HKCU\$relative could not be reopened after it was created."
    }
    try {
        foreach ($item in $preserved) {
            if ($null -eq $item.Value) {
                continue
            }
            $created.SetValue($item.Name, $item.Value, $item.Kind)
        }
    }
    finally {
        $created.Close()
    }
    Set-UserKeyIntegrityLabel -SubKey $relative -Label 'S:(ML;;NW;;;HI)'
}

function Get-InstallRecoveryPath {
    if ($OnWindows) {
        $parent = [System.Environment]::GetFolderPath('CommonApplicationData')
        if ([string]::IsNullOrWhiteSpace($parent)) {
            throw "Unable to resolve ProgramData for the AutoRun recovery file."
        }
        return Join-Path -Path $parent -ChildPath 'choco-installs-recovery\autorun.json'
    }
    return Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'choco-installs-autorun-recovery.json'
}

function Test-AdminOnlyAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $acl = Get-Acl -LiteralPath $Path
    $systemSid = (New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)).Value
    $adminsSid = (New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)).Value
    $allowed = @($systemSid, $adminsSid)
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $allowed -or -not $acl.AreAccessRulesProtected) {
        return $false
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or $rule.IdentityReference.Value -notin $allowed) {
            return $false
        }
    }
    return $true
}

function Initialize-InstallRecoveryDirectory {
    if (-not $OnWindows) {
        return
    }
    $directory = Split-Path -Path (Get-InstallRecoveryPath) -Parent
    if (-not (Test-Path -LiteralPath $directory)) {
        $systemSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
        $adminsSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.SetOwner($adminsSid)
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($systemSid, $adminsSid)) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
                [System.Security.AccessControl.PropagationFlags]::None,
                [System.Security.AccessControl.AccessControlType]::Allow)
            $security.AddAccessRule($rule)
        }
        if ($PSVersionTable.PSEdition -eq 'Core') {
            Add-Type -AssemblyName System.IO.FileSystem.AccessControl
        }
        $aclExtensions = 'System.IO.FileSystemAclExtensions' -as [type]
        $create = $null
        if ($null -ne $aclExtensions) {
            # Windows PowerShell 5.1 can resolve the type without the DirectoryInfo overload.
            $create = $aclExtensions.GetMethod('Create', [type[]]@(
                    [System.IO.DirectoryInfo],
                    [System.Security.AccessControl.DirectorySecurity]))
        }
        if ($null -ne $create) {
            $null = $create.Invoke($null, @((New-Object System.IO.DirectoryInfo($directory)), $security))
        }
        else {
            $null = [System.IO.Directory]::CreateDirectory($directory, $security)
        }
    }
    if (-not (Test-AdminOnlyAcl -Path $directory)) {
        throw "The AutoRun recovery directory is not limited to SYSTEM and Administrators."
    }
}

function Protect-RecoveryFileAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $security = New-Object System.Security.AccessControl.FileSecurity
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $security.SetOwner($adminsSid)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @(
            [System.Security.Principal.WellKnownSidType]::LocalSystemSid,
            [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid
        )) {
        $account = New-Object System.Security.Principal.SecurityIdentifier($sid, $null)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $account,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
    if (-not (Test-AdminOnlyAcl -Path $Path)) {
        throw "The AutoRun recovery file is not limited to SYSTEM and Administrators."
    }
}

function Test-ScriptRestrictedDacl {
    param([string]$Sddl)
    $normalized = ([string]$Sddl) -replace '\s', ''
    if ($normalized -notmatch '^D:P') {
        return $false
    }
    $aces = [regex]::Matches($normalized, '\([^)]*\)')
    if ($aces.Count -eq 0) {
        return $false
    }
    foreach ($ace in $aces) {
        if ($ace.Value -notmatch ';;;(SY|BA)\)$') {
            return $false
        }
    }
    return $true
}

function Capture-CommandProcessorDacl {
    if (-not $OnWindows) {
        return
    }
    # A value already loaded from the recovery file is the user's DACL. The
    # restricted DACL this script applies is not an original and must not be saved again.
    if (-not [string]::IsNullOrWhiteSpace($Script:OriginalCommandProcessorDacl) -and $Script:OriginalCommandProcessorDacl -ne 'inherit' -and -not (Test-ScriptRestrictedDacl $Script:OriginalCommandProcessorDacl)) {
        return
    }
    $relative = 'Software\Microsoft\Command Processor'
    if ([RegistryIntegrityLabel]::IsSymbolicLink($relative)) {
        $Script:OriginalCommandProcessorDacl = 'inherit'
        return
    }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($relative)
    if ($null -eq $key) {
        $Script:OriginalCommandProcessorDacl = 'inherit'
        return
    }
    try {
        $current = $key.GetAccessControl().GetSecurityDescriptorSddlForm('Access')
        if ([string]::IsNullOrWhiteSpace($current) -or (Test-ScriptRestrictedDacl $current)) {
            $Script:OriginalCommandProcessorDacl = 'inherit'
        }
        else {
            $Script:OriginalCommandProcessorDacl = $current
        }
    }
    catch {
        Write-Log "WARN could not read the Command Processor DACL; the key will inherit permissions after the install."
    }
    finally {
        $key.Close()
    }
}

function Restore-CommandProcessorDacl {
    if (-not $OnWindows) {
        return
    }
    $relative = 'Software\Microsoft\Command Processor'
    $rights = [System.Security.AccessControl.RegistryRights]'ChangePermissions, ReadPermissions'
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey(
        $relative,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        $rights)
    if ($null -eq $key) {
        return
    }
    try {
        $security = $key.GetAccessControl()
        if (-not [string]::IsNullOrWhiteSpace($Script:OriginalCommandProcessorDacl) -and $Script:OriginalCommandProcessorDacl -ne 'inherit' -and -not (Test-ScriptRestrictedDacl $Script:OriginalCommandProcessorDacl)) {
            $security.SetSecurityDescriptorSddlForm(
                $Script:OriginalCommandProcessorDacl,
                [System.Security.AccessControl.AccessControlSections]::Access)
        }
        else {
            $Script:OriginalCommandProcessorDacl = 'inherit'
            $security.SetAccessRuleProtection($false, $false)
        }
        $key.SetAccessControl($security)
        Write-Log "Restored permissions on HKCU\$relative."
    }
    catch {
        $Script:InstallRecoveryFailed = $true
        Write-Warning "Unable to restore permissions on HKCU\$relative. Error: $($_.Exception.Message)"
        Write-Log "FAIL restore Command Processor permissions: $($_.Exception.Message)"
    }
    finally {
        $key.Close()
    }
}

function Write-InstallRecoveryFile {
    if ($Script:InstallRecoveryFailed) {
        Write-Log "Left the existing recovery file unchanged because a previous copy was not fully restored."
        return
    }
    $autorun = New-Object System.Collections.Generic.List[object]
    foreach ($saved in $Script:SavedAutoRunValues) {
        $autorun.Add([pscustomobject]@{
                path  = $saved.Path
                kind  = [string]$saved.Kind
                value = $saved.Value
            }) | Out-Null
    }
    $payload = [pscustomobject]@{
        autorun                = $autorun
        userComSpec            = $(if ($Script:HadUserComSpec) { $Script:SavedUserComSpec } else { $null })
        commandProcessorDacl   = $(if ([string]::IsNullOrWhiteSpace($Script:OriginalCommandProcessorDacl)) { 'inherit' } else { $Script:OriginalCommandProcessorDacl })
    }
    Initialize-InstallRecoveryDirectory
    $path = Get-InstallRecoveryPath
    $json = $payload | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($path, $json)
    if ($OnWindows) {
        Protect-RecoveryFileAcl -Path $path
    }
    Write-Log "Wrote AutoRun and user ComSpec recovery file before removing the values."
}

function Import-InstallRecoveryFile {
    $path = Get-InstallRecoveryPath
    if (-not (Test-Path -LiteralPath $path)) {
        return
    }
    if ($OnWindows) {
        $directory = Split-Path -Path $path -Parent
        if (-not (Test-AdminOnlyAcl -Path $directory) -or -not (Test-AdminOnlyAcl -Path $path)) {
            Write-Warning "Refusing to read the AutoRun recovery file because it is not limited to SYSTEM and Administrators."
            Write-Log "REFUSE recovery file: ACL is not limited to SYSTEM and Administrators."
            return
        }
    }
    $data = $null
    try {
        $data = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json
    }
    catch {
        Write-Warning "A previous install left a recovery file that could not be read. It was kept. Error: $($_.Exception.Message)"
        Write-Log "FAIL read recovery file: $($_.Exception.Message)"
        return
    }

    $failed = $false
    $entries = @()
    if ($null -ne $data.autorun) {
        $entries = @($data.autorun)
    }
    foreach ($saved in $entries) {
        $pathProperty = $saved.PSObject.Properties['path']
        if ($null -eq $pathProperty -or $pathProperty.Value -notin $AutoRunKeyPaths) {
            Write-Warning "Ignoring a recovery entry whose registry path is not a Command Processor AutoRun key."
            Write-Log "IGNORE recovery entry for an unexpected registry path."
            continue
        }
        try {
            if (-not (Test-Path -LiteralPath $pathProperty.Value)) {
                New-Item -Path $pathProperty.Value -Force -ErrorAction Stop | Out-Null
            }
            $typeName = [string]$saved.kind
            if ([string]::IsNullOrWhiteSpace($typeName) -or $typeName -eq 'Unknown' -or $typeName -eq 'None') {
                $typeName = 'String'
            }
            New-ItemProperty -Path $pathProperty.Value -Name AutoRun -Value $saved.value -PropertyType $typeName -Force -ErrorAction Stop | Out-Null
        }
        catch {
            $failed = $true
            Write-Warning "Unable to restore cmd.exe AutoRun at $($pathProperty.Value) from the previous install. Set it again to: $($saved.value)"
            Write-Log "FAIL import AutoRun at $($pathProperty.Value): $($_.Exception.Message). Previous value: $($saved.value)"
        }
    }
    $daclProperty = $data.PSObject.Properties['commandProcessorDacl']
    if ($null -ne $daclProperty -and -not [string]::IsNullOrWhiteSpace([string]$daclProperty.Value)) {
        $Script:OriginalCommandProcessorDacl = [string]$daclProperty.Value
    }
    $comSpecProperty = $data.PSObject.Properties['userComSpec']
    if ($null -ne $comSpecProperty -and -not [string]::IsNullOrEmpty([string]$comSpecProperty.Value)) {
        try {
            [System.Environment]::SetEnvironmentVariable('ComSpec', [string]$comSpecProperty.Value, 'User')
            Write-Log "Restored the user ComSpec value from the previous install."
        }
        catch {
            $failed = $true
            Write-Warning "Unable to restore the user ComSpec value from the previous install. Set it again to: $($comSpecProperty.Value)"
            Write-Log "FAIL import user ComSpec: $($_.Exception.Message). Previous value: $($comSpecProperty.Value)"
        }
    }
    if ($failed) {
        $Script:InstallRecoveryFailed = $true
        return
    }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
    Write-Log "Restored values saved by an interrupted install."
}

function Remove-InstallRecoveryFile {
    if ($Script:InstallRecoveryFailed) {
        Write-Log "Left the AutoRun recovery file in place because a restore failed."
        return
    }
    $path = Get-InstallRecoveryPath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Restore-InstallGuards {
    if ($OnWindows) {
        Unlock-UserAutoRunKeyChain
    }
    Restore-CommandProcessorAutoRunValues
    if ($OnWindows) {
        Restore-CommandProcessorDacl
        Resume-UserComSpec
    }
    Remove-InstallRecoveryFile
}

function Test-PipelineStop {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    $stopped = $ErrorRecord.FullyQualifiedErrorId -eq 'PipelineStopped'
    while ($null -ne $exception -and -not $stopped) {
        if ($exception -is [System.Management.Automation.PipelineStoppedException] -or $exception -is [System.OperationCanceledException]) {
            $stopped = $true
        }
        $exception = $exception.InnerException
    }
    return $stopped
}

function Assert-NoCommandProcessorAutoRun {
    $remaining = New-Object System.Collections.Generic.List[string]
    $locations = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64 },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32 },
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default }
    )

    foreach ($location in $locations) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($location.Hive, $location.View)
        try {
            $key = $base.OpenSubKey('Software\Microsoft\Command Processor')
            if ($null -ne $key) {
                try {
                    if ($null -ne $key.GetValue('AutoRun', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) {
                        $remaining.Add(("{0} ({1})" -f $key.Name, $location.View)) | Out-Null
                    }
                }
                finally {
                    $key.Close()
                }
            }
        }
        finally {
            $base.Close()
        }
    }

    if ($remaining.Count -gt 0) {
        throw "Command Processor AutoRun is still set in: $($remaining -join ', '). Run this script from an elevated 64-bit PowerShell session."
    }
}

try {
    # A killed process does not run finally. A previous run may have left the
    # saved values in this file after deleting them from the registry.
    Import-InstallRecoveryFile

    if ($OnWindows) {
        # system() starts %ComSpec%, which a per-user environment variable can override.
        $env:ComSpec = Join-Path -Path ([System.Environment]::GetFolderPath('System')) -ChildPath 'cmd.exe'

        Capture-CommandProcessorDacl
        foreach ($subKey in @('Software', 'Software\Microsoft')) {
            [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey).Close()
            Set-UserKeyIntegrityLabel -SubKey $subKey -Label 'S:(ML;;NW;;;HI)'
        }
        # Replace a link before any provider read, which would follow it.
        if ([RegistryIntegrityLabel]::IsSymbolicLink('Software\Microsoft\Command Processor')) {
            Protect-UserCommandProcessorKey
        }
        Suspend-UserComSpec
        Write-Host "HKCU\Software\Microsoft\Command Processor and its parent keys are read-only to non-elevated processes until the package installs finish. Existing AutoRun values are restored when the script ends. If the process is killed, the next run restores them from the recovery file." -ForegroundColor Cyan
    }

    foreach ($autoRunKeyPath in $AutoRunKeyPaths) {
        Save-CommandProcessorAutoRunValue -Path $autoRunKeyPath
    }
    Write-InstallRecoveryFile
    if ($OnWindows) {
        Clear-CapturedUserComSpec
    }
    foreach ($autoRunKeyPath in $AutoRunKeyPaths) {
        Remove-ItemProperty -Path $autoRunKeyPath -Name AutoRun -ErrorAction SilentlyContinue
    }

    if ($OnWindows -and -not $Script:ReplacedCommandProcessorLink) {
        # After the value is saved: drop the key object so an already-open handle cannot write it back.
        Protect-UserCommandProcessorKey
    }

    if ($OnWindows) {
        Assert-NoCommandProcessorAutoRun
    }
}
catch {
    $reason = $_.Exception.Message
    Write-Log "ABORT: unable to remove cmd.exe AutoRun before installing packages: $reason"
    # A statement-terminating error here would skip the refusal and continue
    # into the package installs. Keep that error inside its own handler.
    try {
        Restore-InstallGuards
    }
    catch {
        Write-Warning "Unable to restore cmd.exe AutoRun after aborting the install. Error: $($_.Exception.Message)"
        Write-Log "FAIL restore after abort: $($_.Exception.Message)"
    }
    throw "Refusing to install packages while cmd.exe AutoRun could run with administrator rights. $reason"
}

try {
    # The trap covers the bootstrap statement. Each package has its own catch,
    # because continue here resumes after the whole foreach, not the next package.
    trap {
        if (Test-PipelineStop $_) {
            throw
        }
        Write-Warning "Continuing after an error: $($_.Exception.Message)"
        Write-Log "CONTINUE after error: $($_.Exception.Message)"
        continue
    }

# 1. Install Chocolatey (run in an elevated PowerShell)
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# 2. Open a NEW shell (so choco is on PATH), then install packages below.
#    Tip: you can install everything in one go with:
#    choco install -y googlechrome rclone vim rsync gh git 7zip ...
#    The -y flag skips confirmation prompts, useful for a full bootstrap run.
#    Prefer running this script: a bare elevated choco install skips the
#    AutoRun protection above, and installers like vim's run cmd.exe /c.

$packages = @(
    # -----------------------------------------------------------
    # My seed list
    # -----------------------------------------------------------
    'googlechrome',
    'rclone',
    'vim',
    'rsync',
    'gh',
    'git',

    # -----------------------------------------------------------
    # Core CLI / shell essentials (pairs naturally with git/gh/vim)
    # -----------------------------------------------------------
    '7zip',                 # archive tool, used everywhere
    'curl',                 # Windows ships one, but choco's is often newer
    'wget',
    'jq',                   # JSON processor, invaluable with gh/curl
    'sudo',                 # gsudo-style elevation from any shell
    'grep',
    'sed',
    'less',
    'winrar',

    # -----------------------------------------------------------
    # Terminal / shell environment
    # -----------------------------------------------------------
    'microsoft-windows-terminal',
    'powershell-core',      # pwsh (v7+), alongside Windows PowerShell
    'starship',             # cross-shell prompt, works well with git

    # -----------------------------------------------------------
    # Editors / IDEs
    # -----------------------------------------------------------
    'vscode',
    'notepadplusplus',

    # -----------------------------------------------------------
    # Dev runtimes & package managers
    # (skip any you don't personally use)
    # -----------------------------------------------------------
    'nodejs-lts',
    'python',
    'openjdk',
    'golang',
    'rust',

    # -----------------------------------------------------------
    # Containers / virtualization
    # -----------------------------------------------------------
    'docker-desktop',

    # -----------------------------------------------------------
    # Cloud & infra CLIs
    # -----------------------------------------------------------
    'awscli',
    'azure-cli',
    'terraform',
    'kubernetes-cli',       # kubectl

    # -----------------------------------------------------------
    # Networking / remote access
    # -----------------------------------------------------------
    'putty',                # ssh/telnet client + puttygen
    'winscp',               # GUI sftp/scp, complements rsync
    'openssh',              # ssh/scp/sftp client+server if not already present
    'mobaxterm',            # alternative all-in-one terminal + X server
    'nmap',                 # network scanner 

    # -----------------------------------------------------------
    # API / DB tooling
    # -----------------------------------------------------------
    'postman',
    'dbeaver',              # universal DB GUI client

    # -----------------------------------------------------------
    # System utilities (Sysinternals-adjacent, general QoL)
    # -----------------------------------------------------------
    'powertoys',            # not enough people know about this. It's the best thing on windows no-one knows about! Window snapping, FancyZones, PowerToys Run, etc.
    'sysinternals',         # full Sysinternals suite - these are still going strong after all these years
    'everything',           # instant file search
    'treesizefree',         # disk usage visualizer

    # -----------------------------------------------------------
    # Browsers (beyond Chrome, useful for cross-browser testing)
    # -----------------------------------------------------------
    'firefox',
    'microsoft-edge',

    # -----------------------------------------------------------
    # Media / misc
    # -----------------------------------------------------------
    'vlc',
    'ffmpeg',
    'greenshot',            # lightweight screenshot tool

    # -----------------------------------------------------------
    # Fonts (nice with Windows Terminal / vim / vscode)
    # -----------------------------------------------------------
    'cascadia-code-nerd-font'
)

$failedPackages = New-Object System.Collections.Generic.List[string]

Write-Host "Installing $($packages.Count) package(s)..." -ForegroundColor Cyan
Write-Log "Installing $($packages.Count) package(s): $($packages -join ', ')"

foreach ($pkg in $packages) {
    try {
        if ($OnWindows) {
            Assert-UserComSpecStillClear
            # A package script may have reloaded session variables. Pin this again
            # before the next installer starts cmd.exe.
            $env:ComSpec = Join-Path -Path ([System.Environment]::GetFolderPath('System')) -ChildPath 'cmd.exe'
        }
        Write-Host "==> Installing $pkg" -ForegroundColor Yellow
        Write-Log "BEGIN install: $pkg"

        # Chocolatey's bootstrap often leaves ErrorAction Stop. Under Stop,
        # 2>&1 turns choco's own stderr into a terminating error on Windows
        # PowerShell 5.1 even when the install succeeded.
        $previousErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & choco install -y $pkg 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
        }

        if ($UseLogging) {
            Add-Content -Path $LogPath -Value $output
        }

        if ($exitCode -eq 0) {
            Write-Host "✅ $pkg installed successfully" -ForegroundColor Green
            Write-Log "SUCCESS install: $pkg (exit code $exitCode)"
        }
        else {
            Write-Warning "❌ $pkg failed (exit code $exitCode)"
            Write-Log "FAIL install: $pkg (exit code $exitCode)"
            $failedPackages.Add($pkg) | Out-Null
        }
    }
    catch {
        if ((Test-PipelineStop $_) -or $_.Exception.Message -like 'User ComSpec is set*') {
            throw
        }
        Write-Warning "❌ $pkg failed: $($_.Exception.Message)"
        Write-Log "FAIL install: $pkg ($($_.Exception.Message))"
        $failedPackages.Add($pkg) | Out-Null
    }
}
}
finally {
    try {
        Restore-InstallGuards
    }
    catch {
        Write-Warning "Unable to restore cmd.exe AutoRun or remove the integrity labels. Error: $($_.Exception.Message)"
        Write-Log "FAIL restore at end: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Install run complete." -ForegroundColor Cyan
Write-Log "Install run complete. Failures: $($failedPackages.Count)"

if ($failedPackages.Count -gt 0) {
    $failedList = $failedPackages -join ', '
    Write-Warning "Some package installs failed: $failedList"
    Write-Host "Review output above and retry failed packages individually." -ForegroundColor Yellow

    if ($UseLogging) {
        Write-Host "Log file: $LogPath" -ForegroundColor Yellow
        Write-Log "Failed packages: $failedList"
    }
}
else {
    Write-Host "✅ All packages installed successfully." -ForegroundColor Green
    if ($UseLogging) {
        Write-Host "Log file: $LogPath" -ForegroundColor Green
    }
}
