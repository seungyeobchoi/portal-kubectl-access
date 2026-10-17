[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BundlePath,
    [string]$TrustDirectory=$PSScriptRoot,
    [string]$DestinationDirectory=(Join-Path $env:USERPROFILE '.kube\portal')
)
# One-shot registration. TrustDirectory is installed from independent HTTPS;
# a public key/verifier supplied inside an HTTP bundle is never accepted.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$stage=$null
$locked=$null

function Assert-NoReparse([string]$Path) {
    $item=[IO.Path]::GetFullPath($Path)
    if($item.StartsWith('\\')){throw 'LOCAL_PATH_REQUIRED'}
    while($item){
        if(Test-Path -LiteralPath $item){
            if((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'REPARSE_POINT'}
        }
        $parent=[IO.Directory]::GetParent($item)
        if($null -eq $parent){break}
        $item=$parent.FullName
    }
}
function Read-Limited([string]$Path,[int]$Maximum) {
    $stream=[IO.File]::OpenRead($Path)
    try {
        if($stream.Length -le 0 -or $stream.Length -gt $Maximum){throw 'INPUT_SIZE'}
        $bytes=New-Object byte[] ([int]$stream.Length)
        $offset=0
        while($offset -lt $bytes.Length){
            $count=$stream.Read($bytes,$offset,$bytes.Length-$offset)
            if($count -eq 0){throw 'INPUT_TRUNCATED'}
            $offset+=$count
        }
        return ,$bytes
    } finally {$stream.Dispose()}
}
function Digest([byte[]]$Bytes) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try {return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant()}
    finally {$hash.Dispose()}
}
function Assert-Private([string]$Path) {
    Assert-NoReparse $Path
    $acl=Get-Acl -LiteralPath $Path
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid){throw 'OWNER_MISMATCH'}
    $write=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Modify -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.AccessControlType -eq 'Allow' -and ($rule.FileSystemRights -band $write) -and $rule.IdentityReference.Value -notin @($sid,'S-1-5-18','S-1-5-32-544')){throw 'OTHER_WRITER'}
    }
}
try {
    # A child Windows PowerShell 5.1 can inherit PowerShell 7's PSModulePath.
    # Load the security module belonging to this interpreter, not the parent.
    Import-Module (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression
    $trust=[IO.Path]::GetFullPath($TrustDirectory)
    Assert-NoReparse $trust
    $verifier=Join-Path $trust 'minisign.exe'
    $pin=[Text.Encoding]::ASCII.GetString((Read-Limited (Join-Path $trust 'minisign.sha256') 100)).Trim()
    if($pin -cnotmatch '^[0-9a-f]{64}$' -or (Digest (Read-Limited $verifier 16000000)) -cne $pin){throw 'VERIFIER_PIN'}
    $lines=[Text.Encoding]::ASCII.GetString((Read-Limited (Join-Path $trust 'portal-kubeconfig.pub') 4096)).TrimEnd([char[]]"`r`n") -split '\r?\n'
    if($lines.Count -ne 2 -or -not $lines[0].StartsWith('untrusted comment: ') -or $lines[1] -cnotmatch '^[A-Za-z0-9+/]{56}$'){throw 'TRUST_KEY'}
    $key=[Convert]::FromBase64String($lines[1])
    if($key.Length -ne 42 -or $key[0] -ne 69 -or $key[1] -ne 100){throw 'TRUST_KEY'}
    $raw=Read-Limited ([IO.Path]::GetFullPath($BundlePath)) 2097152
    $memory=[IO.MemoryStream]::new($raw,$false)
    $zip=[IO.Compression.ZipArchive]::new($memory,[IO.Compression.ZipArchiveMode]::Read)
    $content=@{}
    try {
        if($zip.Entries.Count -ne 2){throw 'BUNDLE_MEMBERS'}
        foreach($entry in $zip.Entries){
            if($entry.FullName -cnotin @('cluster.yaml','cluster.yaml.minisig') -or $content.ContainsKey($entry.FullName)){throw 'BUNDLE_MEMBERS'}
            $limit=if($entry.FullName -ceq 'cluster.yaml'){1048576}else{16384}
            if($entry.Length -le 0 -or $entry.Length -gt $limit){throw 'BUNDLE_SIZE'}
            $stream=$entry.Open();$buffer=[IO.MemoryStream]::new()
            try {
                $chunk=New-Object byte[] 8192
                while(($count=$stream.Read($chunk,0,$chunk.Length)) -gt 0){
                    if($buffer.Length+$count -gt $limit){throw 'BUNDLE_SIZE'}
                    $buffer.Write($chunk,0,$count)
                }
                if($buffer.Length -ne $entry.Length){throw 'BUNDLE_LENGTH'}
                $content[$entry.FullName]=$buffer.ToArray()
            } finally {$stream.Dispose();$buffer.Dispose()}
        }
    } finally {$zip.Dispose();$memory.Dispose()}
    $root=[IO.Path]::GetFullPath($DestinationDirectory)
    Assert-NoReparse $root
    if(-not (Test-Path -LiteralPath $root)){
        [void][IO.Directory]::CreateDirectory($root)
        $acl=[Security.AccessControl.DirectorySecurity]::new()
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false)
        foreach($principal in @($sid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))){
            $rule=[Security.AccessControl.FileSystemAccessRule]::new($principal,'FullControl','ContainerInherit, ObjectInherit','None','Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $root -AclObject $acl
    }
    Assert-Private $root
    $stage=Join-Path $root ('.register-'+[Guid]::NewGuid().ToString('N'))
    if(Test-Path -LiteralPath $stage){throw 'STAGE_EXISTS'}
    [void][IO.Directory]::CreateDirectory($stage)
    foreach($name in @('cluster.yaml','cluster.yaml.minisig')){[IO.File]::WriteAllBytes((Join-Path $stage $name),$content[$name])}
    $configPath=Join-Path $stage 'cluster.yaml'
    $signaturePath=Join-Path $stage 'cluster.yaml.minisig'
    $locked=[IO.File]::Open($configPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$verifier
    # Windows paths cannot contain a quote; the key is constrained base64.
    $start.Arguments='-V -H -q -P '+$lines[1]+' -m "'+$configPath+'" -x "'+$signaturePath+'"'
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try {
        [void]$process.Start();$process.StandardInput.Close()
        $outTask=$process.StandardOutput.ReadToEndAsync();$errTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(15000)){$process.Kill();$process.WaitForExit();throw 'VERIFIER_TIMEOUT'}
        [void]$outTask.GetAwaiter().GetResult();[void]$errTask.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw 'SIGNATURE_INVALID'}
    } finally {$process.Dispose()}
    $digest=Digest $content['cluster.yaml']
    $hash=[Security.Cryptography.SHA256]::Create()
    try {
        $locked.Position=0
        $verifiedDigest=([BitConverter]::ToString($hash.ComputeHash($locked))).Replace('-','').ToLowerInvariant()
        if($verifiedDigest -cne $digest){throw 'STAGED_BYTES_CHANGED'}
    } finally {$hash.Dispose()}
    $target=Join-Path $root ('portal-'+$digest+'.yaml')
    $install=Join-Path $stage 'verified.yaml'
    [IO.File]::WriteAllBytes($install,$content['cluster.yaml'])
    $status='registered'
    try {[IO.File]::Move($install,$target)}
    catch [IO.IOException] {
        if(-not (Test-Path -LiteralPath $target)){throw}
        Assert-Private $target
        if((Digest (Read-Limited $target 1048576)) -cne $digest){throw 'EXISTING_CONFLICT'}
        $status='already_registered'
    }
    [pscustomobject]@{status=$status;path=$target;sha256=$digest}|ConvertTo-Json -Compress
} catch {
    # Do not expose YAML, signature comments, subprocess output or raw errors.
    [pscustomobject]@{status='failed';error='REGISTRATION_FAILED'}|ConvertTo-Json -Compress
    exit 1
} finally {
    if($null -ne $locked){$locked.Dispose()}
    if($stage -and (Test-Path -LiteralPath $stage)){
        $full=[IO.Path]::GetFullPath($stage)
        $prefix=[IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\')+'\'
        if($full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){
            Assert-NoReparse $stage
            foreach($name in @('cluster.yaml','cluster.yaml.minisig','verified.yaml')){
                $temporary=Join-Path $stage $name
                if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary -Force}
            }
            [IO.Directory]::Delete($stage,$false)
        }
    }
}
