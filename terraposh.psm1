#Requires -Version 7

using namespace System.Collections
using namespace System.Management.Automation
using namespace System.Web

$ErrorActionPreference = [ActionPreference]::Stop
$ProgressPreference = [ActionPreference]::SilentlyContinue

function Invoke-Terraposh {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit,
        [string]$Version,
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace,
        [ValidateSet('Required', 'Auto', 'Off')]
        [string]$SignatureVerification
    )

    # Push to directory
    if (-not [string]::IsNullOrWhiteSpace($Directory)) {
        $Directory = (Resolve-Path -Path $Directory).Path
        Push-Location -Path $Directory -StackName 'terraposh'
    }

    try {
        # Load terraposh config
        $Config = Get-Config -File $ConfigFile

        # Set Terraform environment variables
        Set-TerraformEnvironmentVariables -Config $Config

        # Splat
        $CreateHardLink = $CreateHardLink -or $Config.CreateHardLink
        $SkipWorkspace = $SkipWorkspace -or $Config.SkipWorkspace

        $TerraformCommandSplat = @{
            Version               = [string]::IsNullOrWhiteSpace($Version) ? $Config.TerraformVersion : $Version
            CreateHardLink        = $CreateHardLink
            SkipWorkspace         = $SkipWorkspace
            SignatureVerification = [string]::IsNullOrWhiteSpace($SignatureVerification) ? $Config.SignatureVerification : $SignatureVerification
        }

        $TerraformCommand = $TerraformCommand.Trim()

        # If not explicit, sequence for laziness
        if ($Explicit) {
            Invoke-TerraformCommand -Command $TerraformCommand @TerraformCommandSplat
        }
        else {
            switch -Regex ($TerraformCommand) {
                '^plan|^apply' {
                    try {
                        Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
                    }
                    catch {
                        Clear-TerraformEnvironment
                        Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
                    }

                    Set-TerraformWorkspace -Workspace $Workspace -InitOnChange @TerraformCommandSplat
                    Invoke-TerraformCommand -Command $TerraformCommand @TerraformCommandSplat
                }
                '^destroy' {
                    try {
                        Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
                    }
                    catch {
                        Clear-TerraformEnvironment
                        Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
                    }

                    $Workspace = Set-TerraformWorkspace -Workspace $Workspace -InitOnChange -PassThru @TerraformCommandSplat
                    Invoke-TerraformCommand -Command $TerraformCommand @TerraformCommandSplat

                    if ($Workspace -ne 'default' -and (-not $SkipWorkspace)) {
                        Set-TerraformWorkspace -Workspace 'default' @TerraformCommandSplat
                        Invoke-TerraformCommand -Command "workspace delete ${Workspace}" @TerraformCommandSplat
                    }
                }
                default { Invoke-TerraformCommand -Command $TerraformCommand @TerraformCommandSplat }
            }
        }
    }
    finally {
        Pop-Location -StackName 'terraposh' -ErrorAction Ignore
    }
}

function Invoke-TerraformCommand {
    param (
        [string]$Command,
        [string]$Version,
        [switch]$CreateHardLink,
        [string]$SignatureVerification
    )

    $TerraformBinary = Get-TerraformBinary -Version $Version -SignatureVerification $SignatureVerification
    $TerraformCommand = "${TerraformBinary} ${Command}"

    if ($CreateHardLink) {
        Set-TerraformBinaryHardLink -Value $TerraformBinary | Out-Null
    }

    Write-Verbose -Message $TerraformCommand
    Invoke-Expression -Command $TerraformCommand

    if ($LASTEXITCODE -notin @(0, 2)) {
        $ErrorMessage = "Terraform command failed with exit code: ${LASTEXITCODE}"
        throw ($ErrorMessage, $TerraformCommand -join "`n")
    }
}

function Merge-Hashtable {
    param (
        [hashtable]$HT1,
        [hashtable]$HT2
    )

    $TempHT = $HT1.Clone()

    foreach ($Key in $HT2.Keys) {
        if ($HT1.ContainsKey($Key)) {
            if ($HT1[$Key] -is [hashtable] -and $HT2[$Key] -is [hashtable]) {
                $TempHT[$Key] = Merge-Hashtable -HT1 $HT1[$Key] -HT2 $HT2[$Key]
                continue
            }
        }

        $TempHT[$Key] = $HT2[$Key]
    }

    return $TempHT
}

function Get-Config {
    param (
        [string]$File
    )

    # search order/precedence (last wins)
    # - user profile ~/.terraposh.config.json
    # - git repo search (if in git repo), top of repo -> closest to working directory
    # - file param
    # - env var

    $SearchLoctaions = [ArrayList]::new()

    $UserProfileConfig = Join-Path -Path $HOME -ChildPath '.terraposh.config.json'
    $GitRepoConfigFiles = Get-GitRepoConfigFiles
    $EnvVarConfigFile = $env:TERRAPOSH_CONFIG_JSON

    $SearchLoctaions.Add($UserProfileConfig) | Out-Null
    $GitRepoConfigFiles | ForEach-Object { $SearchLoctaions.Add($_) | Out-Null } 
    $SearchLoctaions.Add($File) | Out-Null
    $SearchLoctaions.Add($EnvVarConfigFile) | Out-Null
    $SearchLoctaions = $SearchLoctaions | Get-Unique

    Write-Verbose "Search Locations:`n$($SearchLoctaions -join "`n")"

    $Config = @{}

    foreach ($SearchLoctaion in $SearchLoctaions) {
        if ([string]::IsNullOrWhiteSpace($SearchLoctaion)) {
            continue
        }

        if (-not (Test-Path -Path $SearchLoctaion)) {
            continue
        }

        $SearchLocationConfig = Get-Content -Path $SearchLoctaion -Raw | ConvertFrom-Json -AsHashtable
        $Config = Merge-Hashtable -HT1 $Config -HT2 $SearchLocationConfig
    }

    return $Config
}

function Set-TerraformEnvironmentVariables {
    param (
        [hashtable]$Config
    )

    $TfCliArgsEnvVars = $Config.Keys -match '^TF_CLI_ARGS'

    foreach ($TfCliArgsEnvVar in $TfCliArgsEnvVars) {
        Set-Item -Path "Env:\${TfCliArgsEnvVar}" -Value $Config[$TfCliArgsEnvVar]
    }
}

function Get-GitBranchName {
    $GitCommand = 'git rev-parse --abbrev-ref HEAD'
    $GitBranchName = Invoke-Expression -Command $GitCommand

    if ($LASTEXITCODE -ne 0) {
        $ErrorMessage = "Git command failed with non-zero exit code: ${LASTEXITCODE}"
        throw ($ErrorMessage, $GitCommand -join "`n")
    }

    if ([string]::IsNullOrWhiteSpace($GitBranchName)) {
        $ErrorMessage = "Git branch name returned null."
        throw ($ErrorMessage, $GitCommand -join "`n")
    }

    return $GitBranchName
}

function Test-GitRepo {
    $GitCommand = 'git rev-parse --is-inside-work-tree'
    $IsGitRepo = $true
    Invoke-Expression -Command $GitCommand *>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        $IsGitRepo = $false
    }

    return $IsGitRepo
}

function Get-GitTopLevel {
    $GitCommand = 'git rev-parse --show-toplevel'
    $GitTopLevel = Invoke-Expression -Command $GitCommand

    if ($LASTEXITCODE -ne 0) {
        $ErrorMessage = "Git command failed with non-zero exit code: ${LASTEXITCODE}"
        throw ($ErrorMessage, $GitCommand -join "`n")
    }

    return ($GitTopLevel | Resolve-Path).Path
}

function Get-GitRepoConfigFiles {
    $ConfigFiles = [ArrayList]::new()

    if (-not (Test-GitRepo)) {
        return $ConfigFiles
    }

    $GitTopLevel = Get-GitTopLevel
    $CurrentDirectory = ($PWD | Resolve-Path).Path
    $ConfigFileName = '.terraposh.config.json'

    do {
        $IsTopLevel = $CurrentDirectory -eq $GitTopLevel
        $ConfigFilePath = Join-Path -Path $CurrentDirectory -ChildPath $ConfigFileName

        if (Test-Path -Path $ConfigFilePath) {
            $ConfigFiles.Add($ConfigFilePath) | Out-Null
        }

        $CurrentDirectory = (Join-Path -Path $CurrentDirectory -ChildPath '..' | Resolve-Path).Path
    } until ($IsTopLevel)

    $ConfigFiles.Reverse()

    return [arraylist]$ConfigFiles
}

function Clear-TerraformEnvironment {
    $TerraformEnvironmentFile = Join-Path -Path $PWD -ChildPath '.terraform' -AdditionalChildPath 'environment'
    Write-Verbose -Message "Clear workspace file: ${TerraformEnvironmentFile}"
    Remove-Item -Path $TerraformEnvironmentFile -ErrorAction Ignore | Out-Null
}

function Get-TerraformWorkspaceName {
    $Workspace = Get-GitBranchName

    return $Workspace
}

function Set-TerraformWorkspace {
    param (
        [string]$Workspace,
        [switch]$InitOnChange,
        [switch]$PassThru,
        [string]$Version,
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace,
        [string]$SignatureVerification
    )

    # short circut if skip
    if ($SkipWorkspace) { return }

    if ([string]::IsNullOrWhiteSpace($Workspace)) {
        $Workspace = Get-TerraformWorkspaceName
    }

    # normalized workspace name: letters, numbers, hyphens, underscores
    # https://developer.hashicorp.com/terraform/cloud-docs/workspaces/create#create-a-workspace
    $Workspace = $Workspace -replace '[^a-zA-Z0-9\-_]', '_'

    $TerraformCommandSplat = @{
        Version               = $Version
        CreateHardLink        = $CreateHardLink
        SignatureVerification = $SignatureVerification
    }
    
    Write-Verbose -Message "Workspace name: ${Workspace}"

    $CurrentWorkspace = Invoke-TerraformCommand -Command 'workspace show' @TerraformCommandSplat
    Write-Verbose -Message "Current workspace: ${CurrentWorkspace}"

    if ($Workspace -eq $CurrentWorkspace) {
        Write-Verbose -Message "Current workspace is already ${Workspace}"
    }
    else {
        $CurrentWorkspacesAvailable = Invoke-TerraformCommand -Command 'workspace list' @TerraformCommandSplat | `
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | `
            ForEach-Object { $_.TrimStart('*').Trim() }
        Write-Verbose -Message "Current workspaces available: $($CurrentWorkspacesAvailable -join ', ')"

        if ($CurrentWorkspacesAvailable -ccontains $Workspace) {
            Write-Verbose -Message "${Workspace} already exists, selecting it"
            Invoke-TerraformCommand -Command "workspace select ${Workspace}" @TerraformCommandSplat | Out-Null
        }
        else {
            Write-Verbose -Message "${Workspace} doesn't exist, creating it"
            Invoke-TerraformCommand -Command "workspace new ${Workspace}" @TerraformCommandSplat | Out-Null
        }

        if ($InitOnChange) {
            Invoke-TerraformCommand -Command 'init' @TerraformCommandSplat
        }
    }

    if ($PassThru) {
        return $Workspace
    }
}

function Get-LatestTerraformVersion {
    $Uri = 'https://checkpoint-api.hashicorp.com/v1/check/terraform'
    $Response = Invoke-RestMethod -Method Get -Uri $Uri
    $SemVer = $Response.current_version.TrimStart('v')

    return $SemVer
}

function Get-TerraformOS {
    return ($IsWindows ? 'windows' : ($IsMacOS ? 'darwin' : 'linux'))
}

function Get-TerraformArchitecture {
    param (
        # OS architecture (not process), so an x64 pwsh under Rosetta/emulation still gets the native build
        [string]$Architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    )

    switch ($Architecture) {
        'X64' { return 'amd64' }
        'Arm64' { return 'arm64' }
        'X86' { return '386' }
        'Arm' { return 'arm' }
        default { throw "Unsupported architecture for Terraform: ${Architecture}" }
    }
}

function Get-TerraformFallbackArchitecture {
    param (
        [string]$OS = (Get-TerraformOS),
        [string]$Architecture = (Get-TerraformArchitecture)
    )

    # Arm64 macOS (Rosetta 2) and Windows can run amd64 builds, e.g. Terraform < 1.0.2 has no darwin_arm64 build
    if ($Architecture -eq 'arm64' -and $OS -in @('darwin', 'windows')) {
        return 'amd64'
    }

    return $null
}

function Get-TerraformRelease {
    param (
        [string]$Version,
        [string]$Architecture,
        [switch]$IsFallback
    )

    if ([string]::IsNullOrWhiteSpace($Version)) {
        Write-Warning -Message 'No Terraform version pinned (TerraformVersion / -Version), resolving latest release.'
        $Version = Get-LatestTerraformVersion
    }

    $Version = $Version.Trim().TrimStart('v')

    # Only allow semver-shaped versions so the value can't alter the release URI path
    if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') {
        throw "Invalid Terraform version: '${Version}'"
    }

    $OSPart = Get-TerraformOS
    $ArchPart = [string]::IsNullOrWhiteSpace($Architecture) ? (Get-TerraformArchitecture) : $Architecture
    $Platform = "${OSPart}_${ArchPart}"
    $FileName = "terraform_${Version}_${Platform}.zip"
    $BaseUri = "https://releases.hashicorp.com/terraform/${Version}"
    $OutDirectory = Set-TerraformVendoredDirectory
    $ExpandDirectory = Join-Path -Path $OutDirectory -ChildPath ([System.IO.Path]::GetFileNameWithoutExtension($FileName))

    return @{
        Version         = $Version
        Platform        = $Platform
        IsFallback      = [bool]$IsFallback
        FileName        = $FileName
        Uri             = "${BaseUri}/${FileName}"
        ChecksumsUri    = "${BaseUri}/terraform_${Version}_SHA256SUMS"
        SignatureUri    = "${BaseUri}/terraform_${Version}_SHA256SUMS.${HashiCorpKeyId}.sig"
        OutFile         = Join-Path -Path $OutDirectory -ChildPath $FileName
        ExpandDirectory = $ExpandDirectory
        BinaryFile      = Join-Path -Path $ExpandDirectory -ChildPath (Get-TerraformBinaryFileName)
        # Separate marker for fallback builds, so they're never preferred over a published native build
        VerifiedFile    = Join-Path -Path $ExpandDirectory -ChildPath ($IsFallback ? '.terraposh-sha256-fallback' : '.terraposh-sha256')
    }
}

function Invoke-TerraformReleaseRequest {
    param (
        [string]$Uri,
        [string]$OutFile
    )

    # Only ever talk to HashiCorp's official release server over HTTPS
    $ParsedUri = [uri]$Uri

    if ($ParsedUri.Scheme -ne 'https' -or $ParsedUri.Host -ne 'releases.hashicorp.com') {
        throw "Refusing to download from untrusted location: ${Uri}"
    }

    Invoke-WebRequest -Method Get -Uri $ParsedUri -MaximumRedirection 0 -OutFile $OutFile | Out-Null
}

function New-TerraposhTemporaryDirectory {
    $Directory = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "terraposh-$([guid]::NewGuid().ToString('N'))"
    New-Item -Path $Directory -ItemType Directory | Out-Null

    return $Directory
}

# HashiCorp's release signing key and code signing identities
# https://www.hashicorp.com/trust/security (the key is also published on keys.openpgp.org)
$HashiCorpKeyFile = Join-Path -Path $PSScriptRoot -ChildPath 'hashicorp.asc'
$HashiCorpKeyFingerprint = 'C874011F0AB405110D02105534365D9472D7468F'
$HashiCorpKeyId = '72D7468F'
$HashiCorpAppleTeamId = 'D38WU7D763'
$HashiCorpAuthenticodeSigner = 'HashiCorp, Inc.'

function Get-SignatureVerificationMode {
    param (
        [string]$Mode
    )

    if ([string]::IsNullOrWhiteSpace($Mode)) {
        return 'Auto'
    }

    $Modes = @('Required', 'Auto', 'Off')
    $MatchedMode = $Modes | Where-Object { $_ -eq $Mode.Trim() }

    if (-not $MatchedMode) {
        throw "Invalid SignatureVerification: '${Mode}', expected one of: $($Modes -join ', ')"
    }

    return $MatchedMode
}

function Confirm-SignatureUnavailable {
    # The signature can't be checked at all (no gpgv, unsigned binary): fail if required, otherwise warn
    param (
        [string]$Message,
        [string]$Mode
    )

    if ($Mode -eq 'Required') {
        throw "${Message}, and SignatureVerification is Required."
    }

    Write-Warning -Message "${Message}, skipping signature verification."

    return 'Unverified'
}

function ConvertFrom-ArmoredPgpKey {
    param (
        [string]$Path
    )

    $Base64 = [System.Text.StringBuilder]::new()
    $InHeaders = $false
    $InBody = $false

    foreach ($Line in (Get-Content -Path $Path)) {
        $Line = $Line.Trim()

        if ($Line -eq '-----BEGIN PGP PUBLIC KEY BLOCK-----') {
            $InHeaders = $true
            continue
        }

        if ($Line -eq '-----END PGP PUBLIC KEY BLOCK-----') {
            break
        }

        # Armor headers end at the first blank line; the "=" line is the CRC
        if ($InHeaders) {
            $InHeaders = $Line -ne ''
            $InBody = -not $InHeaders
            continue
        }

        if ($InBody -and -not $Line.StartsWith('=')) {
            $Base64.Append($Line) | Out-Null
        }
    }

    if ($Base64.Length -eq 0) {
        throw "No PGP public key block found in ${Path}"
    }

    return [System.Convert]::FromBase64String($Base64.ToString())
}

function Test-GpgvInstalled {
    return [bool](Get-Command -Name 'gpgv' -CommandType Application -ErrorAction Ignore)
}

function Invoke-Gpgv {
    param (
        [string]$Keyring,
        [string]$Signature,
        [string]$File,
        [string]$HomeDirectory
    )

    # Machine-readable status lines go to stdout (--status-fd 1), human-readable output to stderr
    $Output = & gpgv --homedir $HomeDirectory --status-fd 1 --keyring $Keyring $Signature $File 2>&1

    return @{
        ExitCode = $LASTEXITCODE
        Status   = @($Output | Where-Object { $_ -is [string] })
        Errors   = @($Output | Where-Object { $_ -is [ErrorRecord] } | ForEach-Object { "$_" })
    }
}

function Test-TerraformChecksumsSignature {
    # Linux: verify SHA256SUMS was signed with HashiCorp's release key
    param (
        [hashtable]$Release,
        [string]$ChecksumsFile,
        [string]$Mode
    )

    if (-not (Test-GpgvInstalled)) {
        return Confirm-SignatureUnavailable -Message 'gpgv not found (install the gpgv or gnupg package)' -Mode $Mode
    }

    $WorkDirectory = New-TerraposhTemporaryDirectory

    try {
        $Keyring = Join-Path -Path $WorkDirectory -ChildPath 'hashicorp.gpg'
        $SignatureFile = Join-Path -Path $WorkDirectory -ChildPath 'SHA256SUMS.sig'
        [System.IO.File]::WriteAllBytes($Keyring, (ConvertFrom-ArmoredPgpKey -Path $HashiCorpKeyFile))
        Invoke-TerraformReleaseRequest -Uri $Release.SignatureUri -OutFile $SignatureFile
        $Result = Invoke-Gpgv -Keyring $Keyring -Signature $SignatureFile -File $ChecksumsFile -HomeDirectory $WorkDirectory
    }
    finally {
        Remove-Item -Path $WorkDirectory -Recurse -Force -ErrorAction Ignore
    }

    # [GNUPG:] VALIDSIG <signing subkey fingerprint> ... <primary key fingerprint>
    $ValidSignature = $Result.Status | Where-Object {
        $Fields = $_ -split ' '
        $Fields[0] -ceq '[GNUPG:]' -and $Fields[1] -ceq 'VALIDSIG' -and $Fields[-1] -ceq $HashiCorpKeyFingerprint
    }

    if ($Result.ExitCode -ne 0 -or -not $ValidSignature) {
        throw "PGP signature verification failed for $($Release.ChecksumsUri), refusing to use it.`n$($Result.Errors -join "`n")"
    }

    Write-Verbose -Message "Verified $($Release.ChecksumsUri) is signed by ${HashiCorpKeyFingerprint}"

    return 'Verified'
}

function Invoke-Codesign {
    param (
        [string[]]$Arguments
    )

    $Output = & /usr/bin/codesign @Arguments 2>&1 | ForEach-Object { "$_" }

    return @{
        ExitCode = $LASTEXITCODE
        Output   = @($Output)
    }
}

function Test-TerraformCodesignSignature {
    # macOS: Developer ID Application certificate for HashiCorp's Apple team, chained to Apple's root
    param (
        [string]$BinaryFile,
        [string]$Mode
    )

    $Requirement = "=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = ${HashiCorpAppleTeamId}"
    $Result = Invoke-Codesign -Arguments @('--verify', '--strict', '--test-requirement', $Requirement, $BinaryFile)

    if ($Result.ExitCode -eq 0) {
        Write-Verbose -Message "Verified ${BinaryFile} is code-signed by Apple team ${HashiCorpAppleTeamId}"
        return 'Verified'
    }

    if ($Result.Output -match 'code object is not signed at all') {
        return Confirm-SignatureUnavailable -Message "${BinaryFile} is not code-signed" -Mode $Mode
    }

    throw "Code signature verification failed for ${BinaryFile}, refusing to use it.`n$($Result.Output -join "`n")"
}

function Get-TerraformAuthenticodeSignature {
    param (
        [string]$Path
    )

    return Get-AuthenticodeSignature -FilePath $Path
}

function Test-TerraformAuthenticodeSignature {
    # Windows: valid Authenticode signature from HashiCorp
    param (
        [string]$BinaryFile,
        [string]$Mode
    )

    $Signature = Get-TerraformAuthenticodeSignature -Path $BinaryFile
    $Status = "$($Signature.Status)"

    if ($Status -eq 'NotSigned') {
        return Confirm-SignatureUnavailable -Message "${BinaryFile} is not Authenticode-signed" -Mode $Mode
    }

    $Signer = $Signature.SignerCertificate?.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)

    if ($Status -ne 'Valid' -or $Signer -cne $HashiCorpAuthenticodeSigner) {
        throw "Authenticode signature verification failed for ${BinaryFile} (status: ${Status}, signer: '${Signer}'), refusing to use it."
    }

    Write-Verbose -Message "Verified ${BinaryFile} is Authenticode-signed by ${Signer}"

    return 'Verified'
}

function Test-TerraformBinarySignature {
    param (
        [string]$BinaryFile,
        [string]$Mode
    )

    switch (Get-TerraformOS) {
        'darwin' { return Test-TerraformCodesignSignature -BinaryFile $BinaryFile -Mode $Mode }
        'windows' { return Test-TerraformAuthenticodeSignature -BinaryFile $BinaryFile -Mode $Mode }
        default { return 'NotApplicable' }
    }
}

function Get-TerraformReleaseChecksums {
    param (
        [hashtable]$Release,
        [string]$Mode
    )

    $WorkDirectory = New-TerraposhTemporaryDirectory

    try {
        $ChecksumsFile = Join-Path -Path $WorkDirectory -ChildPath 'SHA256SUMS'
        Invoke-TerraformReleaseRequest -Uri $Release.ChecksumsUri -OutFile $ChecksumsFile

        # Linux verifies the signed checksums; macOS and Windows verify the binary's code signature after extraction
        $Signature = 'NotApplicable'

        if ($Mode -eq 'Off') {
            $Signature = 'Off'
        }
        elseif ((Get-TerraformOS) -eq 'linux') {
            $Signature = Test-TerraformChecksumsSignature -Release $Release -ChecksumsFile $ChecksumsFile -Mode $Mode
        }

        $Content = Get-Content -Path $ChecksumsFile -Raw
    }
    finally {
        Remove-Item -Path $WorkDirectory -Recurse -Force -ErrorAction Ignore
    }

    $Checksums = @{}

    # SHA256SUMS format: "<sha256>  <filename>"
    foreach ($Line in ($Content -split "`n")) {
        $Hash, $FileName = $Line.Trim() -split '\s+', 2

        if ([string]::IsNullOrWhiteSpace($FileName)) {
            continue
        }

        if ($Hash -notmatch '^[0-9a-fA-F]{64}$' -or $Checksums.ContainsKey($FileName)) {
            throw "Malformed SHA256SUMS entry in $($Release.ChecksumsUri): ${Line}"
        }

        $Checksums[$FileName] = $Hash.ToLower()
    }

    return [pscustomobject]@{
        Checksums = $Checksums
        Signature = $Signature
    }
}

function Test-FileChecksum {
    param (
        [string]$Path,
        [string]$ExpectedHash
    )

    $ActualHash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    Write-Verbose -Message "SHA-256 ${Path}: ${ActualHash} (expected ${ExpectedHash})"

    return $ActualHash -ceq $ExpectedHash
}

function Test-TerraformVerifiedMarker {
    param (
        [string]$Path,
        [string]$Mode
    )

    if (-not (Test-Path -Path $Path)) {
        return $false
    }

    $Signature = (Get-Content -Path $Path -Force | Where-Object { $_ -like 'signature=*' } | Select-Object -First 1) -replace '^signature=', ''

    switch ($Mode) {
        'Required' { return $Signature -eq 'Verified' }
        'Auto' { return $Signature -in @('Verified', 'Unverified') }
        default { return $Signature -in @('Verified', 'Unverified', 'Off') }
    }
}

function Get-TerraformBinary {
    param (
        [string]$Version,
        [string]$SignatureVerification
    )

    $Mode = Get-SignatureVerificationMode -Mode $SignatureVerification
    $NativeRelease = Get-TerraformRelease -Version $Version
    $Candidates = @($NativeRelease)
    $FallbackArchitecture = Get-TerraformFallbackArchitecture

    if ($FallbackArchitecture) {
        $Candidates += Get-TerraformRelease -Version $NativeRelease.Version -Architecture $FallbackArchitecture -IsFallback
    }

    # Already extracted from an archive that passed checksum (and, as configured, signature) verification
    foreach ($Candidate in $Candidates) {
        if ((Test-Path -Path $Candidate.BinaryFile) -and (Test-TerraformVerifiedMarker -Path $Candidate.VerifiedFile -Mode $Mode)) {
            return $Candidate.BinaryFile
        }
    }

    $ReleaseChecksums = Get-TerraformReleaseChecksums -Release $NativeRelease -Mode $Mode
    $Checksums = $ReleaseChecksums.Checksums
    $Release = $Candidates | Where-Object { $Checksums.ContainsKey($_.FileName) } | Select-Object -First 1

    if (-not $Release) {
        throw "Terraform $($NativeRelease.Version) has no published build for $($NativeRelease.Platform) in $($NativeRelease.ChecksumsUri)"
    }

    if ($Release.IsFallback) {
        Write-Warning -Message "Terraform $($Release.Version) has no $($NativeRelease.Platform) build, using $($Release.Platform) under emulation (Rosetta 2 on macOS)."
    }

    $ExpectedHash = $Checksums[$Release.FileName]
    $OutFile = $Release.OutFile
    $ExpandDirectory = $Release.ExpandDirectory
    $BinaryFile = $Release.BinaryFile
    $VerifiedFile = $Release.VerifiedFile

    if ((Test-Path -Path $OutFile) -and -not (Test-FileChecksum -Path $OutFile -ExpectedHash $ExpectedHash)) {
        Write-Warning -Message "Cached archive failed SHA-256 verification, re-downloading: ${OutFile}"
        Remove-Item -Path $OutFile -Force
    }

    if (-not (Test-Path -Path $OutFile)) {
        $DownloadFile = "${OutFile}.download"

        try {
            Invoke-TerraformReleaseRequest -Uri $Release.Uri -OutFile $DownloadFile

            if (-not (Test-FileChecksum -Path $DownloadFile -ExpectedHash $ExpectedHash)) {
                throw "SHA-256 checksum mismatch for $($Release.Uri), refusing to use it."
            }

            Move-Item -Path $DownloadFile -Destination $OutFile -Force
        }
        finally {
            Remove-Item -Path $DownloadFile -Force -ErrorAction Ignore
        }
    }

    # Discard anything previously extracted without verification
    Remove-Item -Path $ExpandDirectory -Recurse -Force -ErrorAction Ignore
    Expand-Archive -Path $OutFile -DestinationPath $ExpandDirectory -Force | Out-Null

    $Signature = $ReleaseChecksums.Signature

    if ($Signature -eq 'NotApplicable') {
        try {
            $Signature = Test-TerraformBinarySignature -BinaryFile $BinaryFile -Mode $Mode
        }
        catch {
            Remove-Item -Path $ExpandDirectory -Recurse -Force -ErrorAction Ignore
            Remove-Item -Path $OutFile -Force -ErrorAction Ignore
            throw
        }
    }

    Set-Content -Path $VerifiedFile -Value "${ExpectedHash}`nsignature=${Signature}" -NoNewline

    return $BinaryFile
}

function Get-TerraformBinaryFileName {
    return ($IsWindows ? 'terraform.exe' : 'terraform')
}

function Set-TerraformBinaryHardLink {
    param (
        [string]$Value
    )

    $VendoredDirectory = Set-TerraformVendoredDirectory
    $BinaryFileName = Get-TerraformBinaryFileName
    $HardLinkPath = Join-Path -Path $VendoredDirectory -ChildPath $BinaryFileName

    try {
        New-Item -ItemType HardLink -Path $HardLinkPath -Value $Value -Force | Out-Null
    }
    catch {
        Write-Warning "Failed to create HardLink: ${HardLinkPath}"
    }

    return $HardLinkPath
}

function Set-TerraformVendoredDirectory {
    if (-not (Test-Path -Path $HOME)) {
        Write-Error "Unable to access HOME directory: ${HOME}"
    }

    $Directory = Join-Path -Path $HOME -ChildPath '.terraposh' -AdditionalChildPath 'vendored'

    if (-not (Test-Path -Path $Directory)) {
        New-Item -Path $Directory -ItemType Directory -Force | Out-Null
    }

    return $Directory
}

# Helper functions
function Invoke-TerraposhPlan {
    [CmdletBinding()]
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit,
        [string]$Version,
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace,
        [ValidateSet('Required', 'Auto', 'Off')]
        [string]$SignatureVerification
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "plan ${TerraformCommand}" @PSBoundParameters
}

function Invoke-TerraposhApply {
    [CmdletBinding()]
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit,
        [string]$Version,
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace,
        [ValidateSet('Required', 'Auto', 'Off')]
        [string]$SignatureVerification
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "apply ${TerraformCommand}" @PSBoundParameters
}

function Invoke-TerraposhDestroy {
    [CmdletBinding()]
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit,
        [string]$Version,
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace,
        [ValidateSet('Required', 'Auto', 'Off')]
        [string]$SignatureVerification
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "destroy ${TerraformCommand}" @PSBoundParameters
}

function Invoke-TerraposhDestroyAutoApprove {
    [CmdletBinding()]
    param (
        [string]$TerraformCommand,
        [string]$ConfigFile,
        [string]$Directory,
        [string]$Workspace,
        [switch]$Explicit,
        [string]$Version,
        [switch]$CreateHardLink,
        [switch]$SkipWorkspace,
        [ValidateSet('Required', 'Auto', 'Off')]
        [string]$SignatureVerification
    )

    $PSBoundParameters.Remove('TerraformCommand') | Out-Null
    Invoke-Terraposh -TerraformCommand "destroy -auto-approve ${TerraformCommand}" @PSBoundParameters
}

# Create aliases and export members
$ExportedMembers = @{
    terraposh = 'Invoke-Terraposh'
    tpp       = 'Invoke-TerraposhPlan'
    tpa       = 'Invoke-TerraposhApply'
    tpd       = 'Invoke-TerraposhDestroy'
    tpda      = 'Invoke-TerraposhDestroyAutoApprove'
}

$ExportedMembers.Keys | ForEach-Object { Set-Alias -Name $_ -Value $ExportedMembers[$_] }
$ExportedFunctions = $ExportedMembers.Values | Out-String -Stream
$ExportedAliases = $ExportedMembers.Keys | Out-String -Stream
Export-ModuleMember -Function $ExportedFunctions -Alias $ExportedAliases
