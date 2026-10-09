#Requires -Version 7.2
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeDiscovery {
    Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'terraposh.psd1') -Force
}

InModuleScope terraposh {
    Describe 'Get-TerraformArchitecture' {
        It 'maps <Architecture> to <Expected>' -TestCases @(
            @{ Architecture = 'X64'; Expected = 'amd64' }
            @{ Architecture = 'Arm64'; Expected = 'arm64' }
            @{ Architecture = 'X86'; Expected = '386' }
            @{ Architecture = 'Arm'; Expected = 'arm' }
        ) {
            Get-TerraformArchitecture -Architecture $Architecture | Should -Be $Expected
        }

        It 'throws on an unsupported architecture' {
            { Get-TerraformArchitecture -Architecture 'S390x' } | Should -Throw '*Unsupported architecture*'
        }

        It 'detects the current OS architecture' {
            Get-TerraformArchitecture | Should -BeIn @('amd64', 'arm64', '386', 'arm')
        }
    }

    Describe 'Get-TerraformFallbackArchitecture' {
        It 'returns <Expected> for <OS>_<Architecture>' -TestCases @(
            @{ OS = 'darwin'; Architecture = 'arm64'; Expected = 'amd64' }
            @{ OS = 'windows'; Architecture = 'arm64'; Expected = 'amd64' }
            @{ OS = 'linux'; Architecture = 'arm64'; Expected = $null }
            @{ OS = 'darwin'; Architecture = 'amd64'; Expected = $null }
            @{ OS = 'linux'; Architecture = 'amd64'; Expected = $null }
        ) {
            Get-TerraformFallbackArchitecture -OS $OS -Architecture $Architecture | Should -Be $Expected
        }
    }

    Describe 'Get-TerraformRelease' {
        BeforeEach {
            Mock Set-TerraformVendoredDirectory { Join-Path -Path $TestDrive -ChildPath 'vendored' }
            Mock Get-TerraformOS { 'linux' }
            Mock Get-TerraformArchitecture { 'amd64' }
        }

        It 'builds release URIs on releases.hashicorp.com' {
            $Release = Get-TerraformRelease -Version '1.9.8'

            $Release.Version | Should -Be '1.9.8'
            $Release.Platform | Should -Be 'linux_amd64'
            $Release.FileName | Should -Be 'terraform_1.9.8_linux_amd64.zip'
            $Release.Uri | Should -Be 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_linux_amd64.zip'
            $Release.ChecksumsUri | Should -Be 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'
            $Release.IsFallback | Should -BeFalse
            Split-Path -Leaf $Release.VerifiedFile | Should -Be '.terraposh-sha256'
        }

        It 'trims a leading v and whitespace' {
            (Get-TerraformRelease -Version ' v1.9.8 ').Version | Should -Be '1.9.8'
        }

        It 'accepts pre-release versions' {
            (Get-TerraformRelease -Version '1.10.0-beta1').Version | Should -Be '1.10.0-beta1'
        }

        It 'uses an explicit architecture and a separate marker for fallback builds' {
            $Release = Get-TerraformRelease -Version '1.0.1' -Architecture 'amd64' -IsFallback

            $Release.Platform | Should -Be 'linux_amd64'
            $Release.IsFallback | Should -BeTrue
            Split-Path -Leaf $Release.VerifiedFile | Should -Be '.terraposh-sha256-fallback'
        }

        It 'rejects invalid version <Version>' -TestCases @(
            @{ Version = '1.9.8/../../evil' }
            @{ Version = '1.9' }
            @{ Version = 'latest' }
            @{ Version = '1.9.8?x=1' }
            @{ Version = '1.9.8-beta/1' }
        ) {
            { Get-TerraformRelease -Version $Version } | Should -Throw '*Invalid Terraform version*'
        }

        It 'warns and resolves the latest version when none is pinned' {
            Mock Write-Warning {}
            Mock Get-LatestTerraformVersion { '1.16.5' }

            (Get-TerraformRelease -Version '').Version | Should -Be '1.16.5'
            Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like '*No Terraform version pinned*' }
        }
    }

    Describe 'Invoke-TerraformReleaseRequest' {
        BeforeEach {
            Mock Invoke-WebRequest {}
        }

        It 'refuses <Uri>' -TestCases @(
            @{ Uri = 'http://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS' }
            @{ Uri = 'https://example.com/terraform_1.9.8_SHA256SUMS' }
            @{ Uri = 'https://releases.hashicorp.com.evil.example/terraform_1.9.8_SHA256SUMS' }
            @{ Uri = 'ftp://releases.hashicorp.com/terraform_1.9.8_SHA256SUMS' }
        ) {
            { Invoke-TerraformReleaseRequest -Uri $Uri -OutFile 'out' } | Should -Throw '*Refusing to download*'
            Should -Invoke Invoke-WebRequest -Times 0
        }

        It 'downloads over HTTPS without following redirects' {
            Invoke-TerraformReleaseRequest -Uri 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS' -OutFile 'out'

            Should -Invoke Invoke-WebRequest -Exactly -Times 1 -ParameterFilter {
                $MaximumRedirection -eq 0 -and $OutFile -eq 'out' -and
                $Uri.AbsoluteUri -eq 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'
            }
        }
    }

    Describe 'Get-TerraformReleaseChecksums' {
        BeforeAll {
            $Release = @{
                ChecksumsUri = 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'
                SignatureUri = 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS.72D7468F.sig'
            }
            $HashA = 'A' * 64
            $HashB = 'b' * 64
        }

        BeforeEach {
            $script:Sums = "${HashA}  terraform_1.9.8_linux_amd64.zip`n${HashB}  terraform_1.9.8_darwin_arm64.zip`n`n"
            Mock Invoke-TerraformReleaseRequest { Set-Content -Path $OutFile -Value $script:Sums -NoNewline }
            Mock Assert-TerraformChecksumsSignature {}
        }

        It 'parses entries and normalises hashes to lowercase' {
            $Checksums = Get-TerraformReleaseChecksums -Release $Release

            $Checksums.Count | Should -Be 2
            $Checksums['terraform_1.9.8_linux_amd64.zip'] | Should -Be ('a' * 64)
            $Checksums['terraform_1.9.8_darwin_arm64.zip'] | Should -Be $HashB
            Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1 -ParameterFilter { $Uri -eq $Release.ChecksumsUri }
        }

        It 'handles CRLF line endings' {
            $script:Sums = "${HashA}  terraform_1.9.8_linux_amd64.zip`r`n"

            (Get-TerraformReleaseChecksums -Release $Release).Keys | Should -Be 'terraform_1.9.8_linux_amd64.zip'
        }

        It 'throws on a malformed hash' {
            $script:Sums = 'abc123  terraform_1.9.8_linux_amd64.zip'

            { Get-TerraformReleaseChecksums -Release $Release } | Should -Throw '*Malformed SHA256SUMS entry*'
        }

        It 'throws on duplicate entries' {
            $script:Sums = "${HashA}  terraform_1.9.8_linux_amd64.zip`n${HashB}  terraform_1.9.8_linux_amd64.zip"

            { Get-TerraformReleaseChecksums -Release $Release } | Should -Throw '*Malformed SHA256SUMS entry*'
        }

        It 'verifies the downloaded checksum bytes' {
            Mock Assert-TerraformChecksumsSignature {
                [System.Text.Encoding]::UTF8.GetString($ChecksumsBytes) | Should -BeExactly $script:Sums
            }

            Get-TerraformReleaseChecksums -Release $Release | Out-Null
            Should -Invoke Assert-TerraformChecksumsSignature -Exactly -Times 1 -ParameterFilter { $Release.ChecksumsUri -eq 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS' }
        }

        It 'checks the signature before parsing' {
            $script:Sums = 'not a checksum file'
            Mock Assert-TerraformChecksumsSignature { throw 'PGP signature verification failed' }

            { Get-TerraformReleaseChecksums -Release $Release } | Should -Throw '*PGP signature verification failed*'
        }

        It 'parses exactly the bytes that were verified' {
            $script:Downloaded = @{}
            Mock Invoke-TerraformReleaseRequest {
                Set-Content -Path $OutFile -Value $script:Sums -NoNewline
                $script:Downloaded.Path = $OutFile
            }
            Mock Assert-TerraformChecksumsSignature {
                if (Test-Path -Path $script:Downloaded.Path) {
                    Set-Content -Path $script:Downloaded.Path -Value "$('c' * 64)  terraform_1.9.8_linux_amd64.zip" -NoNewline
                }
            }

            (Get-TerraformReleaseChecksums -Release $Release)['terraform_1.9.8_linux_amd64.zip'] | Should -Be ('a' * 64)
        }

        It 'cleans up its temporary directory' {
            $Before = @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'terraposh-*' -ErrorAction Ignore).Count
            Get-TerraformReleaseChecksums -Release $Release | Out-Null

            @(Get-ChildItem -Path ([System.IO.Path]::GetTempPath()) -Filter 'terraposh-*' -ErrorAction Ignore).Count | Should -Be $Before
        }
    }

    Describe 'ConvertFrom-ArmoredPgpKey' {
        It 'decodes the bundled HashiCorp key to the pinned fingerprint' {
            $Bytes = ConvertFrom-ArmoredPgpKey -Path $HashiCorpKeyFile

            $Bytes[0] | Should -Be 0x99
            $PacketLength = 3 + ([int]$Bytes[1] -shl 8) + $Bytes[2]
            $Fingerprint = [System.Convert]::ToHexString([System.Security.Cryptography.SHA1]::HashData([byte[]]$Bytes[0..($PacketLength - 1)]))

            $Fingerprint | Should -Be $HashiCorpKeyFingerprint
            $HashiCorpKeyFingerprint | Should -BeLike "*${HashiCorpKeyId}"
        }

        It 'ignores armor headers and the CRC line' {
            $File = Join-Path -Path $TestDrive -ChildPath 'key.asc'
            Set-Content -Path $File -Value @(
                '-----BEGIN PGP PUBLIC KEY BLOCK-----'
                'Comment: test'
                ''
                [System.Convert]::ToBase64String([byte[]](1, 2, 3))
                '=abcd'
                '-----END PGP PUBLIC KEY BLOCK-----'
            )

            ConvertFrom-ArmoredPgpKey -Path $File | Should -Be @(1, 2, 3)
        }

        It 'throws when there is no key block' {
            $File = Join-Path -Path $TestDrive -ChildPath 'empty.asc'
            Set-Content -Path $File -Value 'not a key'

            { ConvertFrom-ArmoredPgpKey -Path $File } | Should -Throw '*No PGP public key block*'
        }
    }

    Describe 'Get-GpgvPath' {
        It 'returns gpgv from PATH' {
            Mock Get-Command { [pscustomobject]@{ Source = '/usr/bin/gpgv' } } -ParameterFilter { $Name -eq 'gpgv' }

            Get-GpgvPath | Should -Be '/usr/bin/gpgv'
        }

        Context 'gpgv not on PATH' {
            BeforeAll {
                $EnvironmentNames = @('ProgramW6432', 'ProgramFiles', 'ProgramFiles(x86)', 'LOCALAPPDATA', 'SCOOP', 'USERPROFILE')

                function New-FakeFile([string]$Path) {
                    New-Item -Path $Path -ItemType File -Force | Out-Null
                    return $Path
                }
            }

            BeforeEach {
                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'gpgv' }
                Mock Get-Command { $null } -ParameterFilter { $Name -eq 'git' }
                Mock Get-TerraformOS { 'windows' }

                $script:SavedEnvironment = @{}
                $Root = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid())

                foreach ($EnvironmentName in $EnvironmentNames) {
                    $script:SavedEnvironment[$EnvironmentName] = [Environment]::GetEnvironmentVariable($EnvironmentName)
                    [Environment]::SetEnvironmentVariable($EnvironmentName, $null)
                }

                $env:ProgramW6432 = Join-Path -Path $Root -ChildPath 'Program Files'
                $env:ProgramFiles = Join-Path -Path $Root -ChildPath 'Program Files'
                ${env:ProgramFiles(x86)} = Join-Path -Path $Root -ChildPath 'Program Files (x86)'
                $env:LOCALAPPDATA = Join-Path -Path $Root -ChildPath 'AppData' -AdditionalChildPath 'Local'
                $env:USERPROFILE = Join-Path -Path $Root -ChildPath 'User'
            }

            AfterEach {
                foreach ($EnvironmentName in $EnvironmentNames) {
                    [Environment]::SetEnvironmentVariable($EnvironmentName, $script:SavedEnvironment[$EnvironmentName])
                }
            }

            It 'finds Git for Windows'' gpgv next to git on PATH (<Layout>)' -TestCases @(
                @{ Layout = 'cmd'; GitRelative = 'cmd' }
                @{ Layout = 'bin'; GitRelative = 'bin' }
                @{ Layout = 'mingw64\bin'; GitRelative = 'mingw64/bin' }
            ) {
                $GitRoot = Join-Path -Path $TestDrive -ChildPath "Custom Git $([guid]::NewGuid())"
                $GitExe = New-FakeFile (Join-Path -Path $GitRoot -ChildPath $GitRelative -AdditionalChildPath 'git.exe')
                $Gpgv = New-FakeFile (Join-Path -Path $GitRoot -ChildPath 'usr' -AdditionalChildPath 'bin', 'gpgv.exe')
                Mock Get-Command { [pscustomobject]@{ Source = $GitExe } } -ParameterFilter { $Name -eq 'git' }

                Get-GpgvPath | Should -Be $Gpgv
            }

            It 'finds gpgv in <Location>' -TestCases @(
                @{ Location = 'Program Files\Git'; Relative = { Join-Path -Path $env:ProgramFiles -ChildPath 'Git' -AdditionalChildPath 'usr', 'bin', 'gpgv.exe' } }
                @{ Location = 'Program Files (x86)\Git'; Relative = { Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Git' -AdditionalChildPath 'usr', 'bin', 'gpgv.exe' } }
                @{ Location = 'a per-user Git install'; Relative = { Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs' -AdditionalChildPath 'Git', 'usr', 'bin', 'gpgv.exe' } }
                @{ Location = 'Scoop under the user profile'; Relative = { Join-Path -Path $env:USERPROFILE -ChildPath 'scoop' -AdditionalChildPath 'apps', 'git', 'current', 'usr', 'bin', 'gpgv.exe' } }
                @{ Location = 'Gpg4win'; Relative = { Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'GnuPG' -AdditionalChildPath 'bin', 'gpgv.exe' } }
            ) {
                $Gpgv = New-FakeFile (& $Relative)

                Get-GpgvPath | Should -Be $Gpgv
            }

            It 'finds gpgv in a custom Scoop root' {
                $env:SCOOP = Join-Path -Path $TestDrive -ChildPath "scoop $([guid]::NewGuid())"
                $Gpgv = New-FakeFile (Join-Path -Path $env:SCOOP -ChildPath 'apps' -AdditionalChildPath 'git', 'current', 'usr', 'bin', 'gpgv.exe')

                Get-GpgvPath | Should -Be $Gpgv
            }

            It 'prefers the Git next to git on PATH over a Program Files install' {
                New-FakeFile (Join-Path -Path $env:ProgramFiles -ChildPath 'Git' -AdditionalChildPath 'usr', 'bin', 'gpgv.exe') | Out-Null
                $GitRoot = Join-Path -Path $TestDrive -ChildPath "Custom Git $([guid]::NewGuid())"
                $GitExe = New-FakeFile (Join-Path -Path $GitRoot -ChildPath 'cmd' -AdditionalChildPath 'git.exe')
                $Gpgv = New-FakeFile (Join-Path -Path $GitRoot -ChildPath 'usr' -AdditionalChildPath 'bin', 'gpgv.exe')
                Mock Get-Command { [pscustomobject]@{ Source = $GitExe } } -ParameterFilter { $Name -eq 'git' }

                Get-GpgvPath | Should -Be $Gpgv
            }

            It 'ignores a directory named gpgv.exe' {
                New-Item -Path (Join-Path -Path $env:ProgramFiles -ChildPath 'Git' -AdditionalChildPath 'usr', 'bin', 'gpgv.exe') -ItemType Directory -Force | Out-Null

                Get-GpgvPath | Should -BeNullOrEmpty
            }

            It 'returns nothing on Windows when no gpgv is installed' {
                Get-GpgvPath | Should -BeNullOrEmpty
            }

            It 'does not search Windows locations on <OS>' -TestCases @(
                @{ OS = 'linux' }
                @{ OS = 'darwin' }
            ) {
                Mock Get-TerraformOS { $OS }
                New-FakeFile (Join-Path -Path $env:ProgramFiles -ChildPath 'Git' -AdditionalChildPath 'usr', 'bin', 'gpgv.exe') | Out-Null

                Get-GpgvPath | Should -BeNullOrEmpty
            }
        }
    }

    Describe 'Invoke-Gpgv' -Skip:($IsWindows) {
        BeforeAll {
            $FakeGpgv = Join-Path -Path $TestDrive -ChildPath 'gpgv'
            Set-Content -Path $FakeGpgv -Value @(
                '#!/bin/sh'
                'echo "cwd=$(pwd -P)"'
                'for a in "$@"; do echo "arg=$a"; done'
                'echo "gpgv: to stderr" >&2'
                'exit 3'
            )
            chmod +x $FakeGpgv
            $WorkDirectory = Join-Path -Path $TestDrive -ChildPath 'work'
            New-Item -Path $WorkDirectory -ItemType Directory | Out-Null
        }

        It 'runs gpgv in the work directory with only relative names' {
            $Result = Invoke-Gpgv -GpgvPath $FakeGpgv -WorkingDirectory $WorkDirectory

            $Result.Status[0] | Should -Be "cwd=$((Get-Item -Path $WorkDirectory).ResolvedTarget ?? (Resolve-Path -Path $WorkDirectory).ProviderPath)"
            $Result.Status[1..9] | Should -Be @('arg=--homedir', 'arg=.', 'arg=--status-fd', 'arg=1', 'arg=--keyring', 'arg=hashicorp.gpg', 'arg=SHA256SUMS.sig', 'arg=SHA256SUMS')
        }

        It 'separates stdout status lines from stderr and returns the exit code' {
            $Result = Invoke-Gpgv -GpgvPath $FakeGpgv -WorkingDirectory $WorkDirectory

            $Result.ExitCode | Should -Be 3
            $Result.Errors | Should -Be @('gpgv: to stderr')
            $Result.Status | Should -Not -Contain 'gpgv: to stderr'
        }

        It 'restores the current location' {
            $Before = $PWD.Path
            Invoke-Gpgv -GpgvPath $FakeGpgv -WorkingDirectory $WorkDirectory | Out-Null

            $PWD.Path | Should -Be $Before
        }
    }

    Describe 'Assert-TerraformChecksumsSignature' {
        BeforeAll {
            $Release = @{
                ChecksumsUri = 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'
                SignatureUri = 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS.72D7468F.sig'
            }
            $ChecksumsBytes = [System.Text.Encoding]::UTF8.GetBytes("sums`n")

            function New-ValidSig([string]$PrimaryFingerprint) {
                "[GNUPG:] VALIDSIG 374EC75B485913604A831CC7C820C6D5CD27AB87 2024-10-16 1729084074 0 4 0 1 8 00 ${PrimaryFingerprint}"
            }
        }

        BeforeEach {
            Mock Get-GpgvPath { '/opt/gnupg/bin/gpgv' }
            Mock Invoke-TerraformReleaseRequest { Set-Content -Path $OutFile -Value 'sig' }
            Mock Invoke-Gpgv { @{ ExitCode = 0; Status = @('[GNUPG:] GOODSIG C820C6D5CD27AB87 HashiCorp', (New-ValidSig $HashiCorpKeyFingerprint)); Errors = @() } }
        }

        It 'accepts a valid signature from the pinned HashiCorp key' {
            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsBytes $ChecksumsBytes } | Should -Not -Throw

            Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1 -ParameterFilter { $Uri -eq $Release.SignatureUri }
            Should -Invoke Invoke-Gpgv -Exactly -Times 1 -ParameterFilter { $GpgvPath -eq '/opt/gnupg/bin/gpgv' }
        }

        It 'gives gpgv only the bundled key, the checksums and the signature in an isolated directory' {
            Mock Invoke-Gpgv {
                (Get-ChildItem -Path $WorkingDirectory -Force).Name | Sort-Object | Should -Be @('hashicorp.gpg', 'SHA256SUMS', 'SHA256SUMS.sig')
                [System.IO.File]::ReadAllBytes((Join-Path -Path $WorkingDirectory -ChildPath 'hashicorp.gpg')) | Should -Be (ConvertFrom-ArmoredPgpKey -Path $HashiCorpKeyFile)
                [System.IO.File]::ReadAllBytes((Join-Path -Path $WorkingDirectory -ChildPath 'SHA256SUMS')) | Should -Be $ChecksumsBytes
                Get-Content -Path (Join-Path -Path $WorkingDirectory -ChildPath 'SHA256SUMS.sig') -Raw | Should -Be "sig$([Environment]::NewLine)"
                @{ ExitCode = 0; Status = @(New-ValidSig $HashiCorpKeyFingerprint); Errors = @() }
            }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsBytes $ChecksumsBytes } | Should -Not -Throw
        }

        It 'rejects a valid signature from a different key' {
            Mock Invoke-Gpgv { @{ ExitCode = 0; Status = @(New-ValidSig ('0' * 40)); Errors = @() } }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsBytes $ChecksumsBytes } | Should -Throw '*PGP signature verification failed*'
        }

        It 'rejects a bad signature' {
            Mock Invoke-Gpgv { @{ ExitCode = 1; Status = @('[GNUPG:] BADSIG C820C6D5CD27AB87 HashiCorp'); Errors = @('gpgv: BAD signature') } }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsBytes $ChecksumsBytes } | Should -Throw '*PGP signature verification failed*BAD signature*'
        }

        It 'rejects a non-zero gpgv exit code even with a VALIDSIG line' {
            Mock Invoke-Gpgv { @{ ExitCode = 2; Status = @(New-ValidSig $HashiCorpKeyFingerprint); Errors = @() } }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsBytes $ChecksumsBytes } | Should -Throw '*PGP signature verification failed*'
        }

        It 'ignores VALIDSIG text that only appears on stderr' {
            Mock Invoke-Gpgv { @{ ExitCode = 0; Status = @(); Errors = @(New-ValidSig $HashiCorpKeyFingerprint) } }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsBytes $ChecksumsBytes } | Should -Throw '*PGP signature verification failed*'
        }

        It 'fails when the signature file cannot be downloaded' {
            Mock Invoke-TerraformReleaseRequest { throw 'Response status code does not indicate success: 404 (Not Found).' }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsBytes $ChecksumsBytes } | Should -Throw '*404*'
            Should -Invoke Invoke-Gpgv -Times 0
        }

        It 'fails when gpgv is not installed' {
            Mock Get-GpgvPath { $null }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsBytes $ChecksumsBytes } | Should -Throw '*gpgv is required*'
            Should -Invoke Invoke-TerraformReleaseRequest -Times 0
        }
    }

    Describe 'Test-TerraformVerifiedMarker' {
        BeforeAll {
            $Marker = Join-Path -Path $TestDrive -ChildPath '.terraposh-sha256'
        }

        It 'trusts a marker recording a verified signature' {
            Set-Content -Path $Marker -Value "$('a' * 64)`nsignature=Verified" -NoNewline

            Test-TerraformVerifiedMarker -Path $Marker | Should -BeTrue
        }

        It 'does not trust <Case>' -TestCases @(
            @{ Case = 'a hash-only marker from before signature checks'; Content = ('a' * 64) }
            @{ Case = 'an unverified signature'; Content = "$('a' * 64)`nsignature=Unverified" }
            @{ Case = 'signatures turned off'; Content = "$('a' * 64)`nsignature=Off" }
        ) {
            Set-Content -Path $Marker -Value $Content -NoNewline

            Test-TerraformVerifiedMarker -Path $Marker | Should -BeFalse
        }

        It 'returns false when there is no marker' {
            Test-TerraformVerifiedMarker -Path (Join-Path -Path $TestDrive -ChildPath 'missing') | Should -BeFalse
        }
    }

    Describe 'Test-LockContention' {
        It 'treats HResult <HResult> on <OS> as contention: <Expected>' -TestCases @(
            @{ OS = 'linux'; HResult = 11; Expected = $true }
            @{ OS = 'darwin'; HResult = 35; Expected = $true }
            @{ OS = 'windows'; HResult = -2147024864; Expected = $true }
            @{ OS = 'windows'; HResult = -2147024863; Expected = $true }
            @{ OS = 'linux'; HResult = 28; Expected = $false }
            @{ OS = 'windows'; HResult = 11; Expected = $false }
        ) {
            Mock Get-TerraformOS { $OS }
            $Exception = [System.IO.IOException]::new('io', $HResult)

            Test-LockContention -Exception $Exception | Should -Be $Expected
        }

        It 'does not treat IOException subclasses as contention' {
            Test-LockContention -Exception ([System.IO.DirectoryNotFoundException]::new('missing')) | Should -BeFalse
            Test-LockContention -Exception ([System.IO.FileNotFoundException]::new('missing')) | Should -BeFalse
        }

        It 'unwraps method invocation errors' {
            $Lock = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid()).lock"
            $Held = [System.IO.File]::Open($Lock, 'OpenOrCreate', 'ReadWrite', 'None')

            try {
                try { [System.IO.File]::Open($Lock, 'OpenOrCreate', 'ReadWrite', 'None') } catch { $Caught = $_.Exception }
                $Caught | Should -BeOfType [System.Management.Automation.MethodInvocationException]
                Test-LockContention -Exception $Caught | Should -BeTrue
            }
            finally {
                $Held.Dispose()
            }
        }
    }

    Describe 'Wait-TerraposhLock' {
        BeforeEach {
            $LockFile = Join-Path -Path $TestDrive -ChildPath "$([guid]::NewGuid()).lock"
        }

        It 'acquires an exclusive lock' {
            $Lock = Wait-TerraposhLock -Path $LockFile

            try {
                { [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None').Dispose() } | Should -Throw
            }
            finally {
                $Lock.Dispose()
            }
        }

        It 'fails immediately on errors other than lock contention' {
            $Missing = Join-Path -Path $TestDrive -ChildPath 'missing' -AdditionalChildPath 'x.lock'
            $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

            { Wait-TerraposhLock -Path $Missing -TimeoutSeconds 30 } | Should -Throw '*Could not find a part of the path*'
            $Stopwatch.Elapsed.TotalSeconds | Should -BeLessThan 5
        }

        It 'times out while the lock is held' {
            $Held = [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None')

            try {
                { Wait-TerraposhLock -Path $LockFile -TimeoutSeconds 1 } | Should -Throw '*Timed out after 1s*'
            }
            finally {
                $Held.Dispose()
            }
        }

        It 'waits for another process to release the lock' {
            $Ready = "${LockFile}.ready"
            $Holder = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -NoNewWindow -ArgumentList @(
                '-NoProfile', '-Command',
                "`$f = [System.IO.File]::Open('${LockFile}', 'OpenOrCreate', 'ReadWrite', 'None'); New-Item -Path '${Ready}' | Out-Null; Start-Sleep -Seconds 2; `$f.Dispose()"
            )

            try {
                $Deadline = [DateTime]::UtcNow.AddSeconds(30)
                while (-not (Test-Path -Path $Ready) -and [DateTime]::UtcNow -lt $Deadline) { Start-Sleep -Milliseconds 50 }
                Test-Path -Path $Ready | Should -BeTrue

                $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $Lock = Wait-TerraposhLock -Path $LockFile -TimeoutSeconds 30
                $Stopwatch.Stop()
                $Lock.Dispose()

                $Stopwatch.Elapsed.TotalSeconds | Should -BeGreaterThan 1
            }
            finally {
                $Holder.WaitForExit()
            }
        }
    }

    Describe 'Test-FileChecksum' {
        BeforeAll {
            $File = Join-Path -Path $TestDrive -ChildPath 'file.txt'
            Set-Content -Path $File -Value 'terraposh' -NoNewline
            $Hash = (Get-FileHash -Path $File -Algorithm SHA256).Hash.ToLower()
        }

        It 'returns true for a matching hash' {
            Test-FileChecksum -Path $File -ExpectedHash $Hash | Should -BeTrue
        }

        It 'returns false for a different hash' {
            Test-FileChecksum -Path $File -ExpectedHash ('0' * 64) | Should -BeFalse
        }
    }

    Describe 'Get-TerraformBinary' {
        BeforeAll {
            $BinaryFileName = Get-TerraformBinaryFileName
            $SourceDirectory = Join-Path -Path $TestDrive -ChildPath 'source'
            New-Item -Path $SourceDirectory -ItemType Directory | Out-Null
            Set-Content -Path (Join-Path -Path $SourceDirectory -ChildPath $BinaryFileName) -Value 'genuine terraform' -NoNewline
            $FakeArchive = Join-Path -Path $TestDrive -ChildPath 'terraform.zip'
            Compress-Archive -Path (Join-Path -Path $SourceDirectory -ChildPath $BinaryFileName) -DestinationPath $FakeArchive
            $FakeHash = (Get-FileHash -Path $FakeArchive -Algorithm SHA256).Hash.ToLower()

            function Get-VendoredPath([string]$ChildPath) {
                (Join-Path -Path $TestDrive -ChildPath 'vendored' -AdditionalChildPath $ChildPath) -replace '/', [System.IO.Path]::DirectorySeparatorChar
            }
        }

        BeforeEach {
            $VendoredDirectory = Join-Path -Path $TestDrive -ChildPath 'vendored'
            Remove-Item -Path $VendoredDirectory -Recurse -Force -ErrorAction Ignore
            New-Item -Path $VendoredDirectory -ItemType Directory | Out-Null

            $script:PublishedChecksums = @{
                'terraform_1.9.8_darwin_arm64.zip' = $FakeHash
                'terraform_1.9.8_darwin_amd64.zip' = $FakeHash
            }

            Mock Set-TerraformVendoredDirectory { Join-Path -Path $TestDrive -ChildPath 'vendored' }
            Mock Get-TerraformOS { 'darwin' }
            Mock Get-TerraformArchitecture { 'arm64' }
            Mock Get-TerraformFallbackArchitecture { 'amd64' }
            Mock Write-Warning {}
            Mock Get-TerraformReleaseChecksums { $script:PublishedChecksums }
            Mock Invoke-TerraformReleaseRequest { Copy-Item -Path $FakeArchive -Destination $OutFile }
        }

        It 'downloads, verifies and extracts the native build' {
            $Binary = Get-TerraformBinary -Version '1.9.8'

            $Binary | Should -Be (Get-VendoredPath "terraform_1.9.8_darwin_arm64/${BinaryFileName}")
            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Get-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64/.terraposh-sha256') -Force | Should -Be @($FakeHash, 'signature=Verified')
            Test-Path -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip.download') | Should -BeFalse
            Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1 -ParameterFilter {
                $Uri -eq 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_darwin_arm64.zip'
            }
            Should -Invoke Write-Warning -Times 0
        }

        It 'reuses a verified binary without network access' {
            Get-TerraformBinary -Version '1.9.8' | Out-Null
            $Binary = Get-TerraformBinary -Version '1.9.8'

            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Should -Invoke Get-TerraformReleaseChecksums -Exactly -Times 1
            Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1
        }

        It 'refuses a download that fails checksum verification and leaves nothing behind' {
            $script:PublishedChecksums['terraform_1.9.8_darwin_arm64.zip'] = '0' * 64

            { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*SHA-256 checksum mismatch*'
            Get-ChildItem -Path (Get-VendoredPath '') -Force -Exclude '*.lock' | Should -BeNullOrEmpty
        }

        It 're-downloads a tampered cached archive' {
            Copy-Item -Path $FakeArchive -Destination (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip')
            Add-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip') -Value 'tampered'

            $Binary = Get-TerraformBinary -Version '1.9.8'

            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Test-FileChecksum -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip') -ExpectedHash $FakeHash | Should -BeTrue
            Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like '*failed SHA-256 verification*' }
            Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1
        }

        It 'reuses a cached archive that passes verification without downloading it again' {
            Copy-Item -Path $FakeArchive -Destination (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip')

            Get-Content -Path (Get-TerraformBinary -Version '1.9.8') -Raw | Should -Be 'genuine terraform'
            Should -Invoke Invoke-TerraformReleaseRequest -Times 0
        }

        It 'does not trust a previously extracted binary without a verification marker' {
            $LegacyDirectory = Get-VendoredPath 'terraform_1.9.8_darwin_arm64'
            New-Item -Path $LegacyDirectory -ItemType Directory | Out-Null
            Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath $BinaryFileName) -Value 'unverified'
            Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath 'stale.txt') -Value 'stale'

            $Binary = Get-TerraformBinary -Version '1.9.8'

            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Test-Path -Path (Join-Path -Path $LegacyDirectory -ChildPath 'stale.txt') | Should -BeFalse
        }

        It 'throws when the checksum file has no entry for the build' {
            $script:PublishedChecksums = @{ 'terraform_1.9.8_linux_amd64.zip' = $FakeHash }
            Mock Get-TerraformFallbackArchitecture { $null }

            { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*no published build for darwin_arm64*'
            Should -Invoke Invoke-TerraformReleaseRequest -Times 0
        }

        Context 'signature verification' {
            It 'does not download when the checksum signature fails' {
                Mock Get-TerraformReleaseChecksums { throw 'PGP signature verification failed' }

                { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*PGP signature verification failed*'
                Should -Invoke Invoke-TerraformReleaseRequest -Times 0
                Get-ChildItem -Path (Get-VendoredPath '') -Force -Exclude '*.lock' | Should -BeNullOrEmpty
            }

            It 're-verifies a binary cached <Case>' -TestCases @(
                @{ Case = 'before signature checks existed'; Content = 'HASH' }
                @{ Case = 'with an Unverified signature'; Content = "HASH`nsignature=Unverified" }
                @{ Case = 'with signatures Off'; Content = "HASH`nsignature=Off" }
            ) {
                $Directory = Get-VendoredPath 'terraform_1.9.8_darwin_arm64'
                New-Item -Path $Directory -ItemType Directory | Out-Null
                Set-Content -Path (Join-Path -Path $Directory -ChildPath $BinaryFileName) -Value 'legacy'
                Set-Content -Path (Join-Path -Path $Directory -ChildPath '.terraposh-sha256') -Value ($Content -replace 'HASH', $FakeHash) -NoNewline

                Get-Content -Path (Get-TerraformBinary -Version '1.9.8') -Raw | Should -Be 'genuine terraform'
                Should -Invoke Get-TerraformReleaseChecksums -Exactly -Times 1
                Get-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64/.terraposh-sha256') -Force | Should -Be @($FakeHash, 'signature=Verified')
            }
        }

        Context 'concurrent runs' {
            It 'holds the release lock while downloading and extracting' {
                $script:LockState = @{ HeldDuringDownload = $null; HeldDuringExtract = $null }
                Mock Invoke-TerraformReleaseRequest {
                    $LockFile = Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip.lock'
                    try {
                        [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None').Dispose()
                        $script:LockState.HeldDuringDownload = $false
                    }
                    catch [System.IO.IOException] {
                        $script:LockState.HeldDuringDownload = $true
                    }
                    Copy-Item -Path $FakeArchive -Destination $OutFile
                }

                Mock Expand-TerraformArchive {
                    $LockFile = Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip.lock'
                    try {
                        [System.IO.File]::Open($LockFile, 'OpenOrCreate', 'ReadWrite', 'None').Dispose()
                        $script:LockState.HeldDuringExtract = $false
                    }
                    catch [System.IO.IOException] {
                        $script:LockState.HeldDuringExtract = $true
                    }
                }

                Get-TerraformBinary -Version '1.9.8' | Out-Null

                Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1
                Should -Invoke Expand-TerraformArchive -Exactly -Times 1
                $script:LockState.HeldDuringDownload | Should -BeTrue
                $script:LockState.HeldDuringExtract | Should -BeTrue
                { [System.IO.File]::Open((Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip.lock'), 'OpenOrCreate', 'ReadWrite', 'None').Dispose() } | Should -Not -Throw
            }

            It 'releases the lock when verification fails' {
                $script:PublishedChecksums['terraform_1.9.8_darwin_arm64.zip'] = '0' * 64

                { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*SHA-256 checksum mismatch*'
                { [System.IO.File]::Open((Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip.lock'), 'OpenOrCreate', 'ReadWrite', 'None').Dispose() } | Should -Not -Throw
            }

            It 'uses the binary another run verified while it waited for the lock' {
                Mock Wait-TerraposhLock {
                    $Directory = Get-VendoredPath 'terraform_1.9.8_darwin_arm64'
                    New-Item -Path $Directory -ItemType Directory -Force | Out-Null
                    Set-Content -Path (Join-Path -Path $Directory -ChildPath $BinaryFileName) -Value 'from the other run' -NoNewline
                    Set-Content -Path (Join-Path -Path $Directory -ChildPath '.terraposh-sha256') -Value "${FakeHash}`nsignature=Verified" -NoNewline
                    [System.IO.File]::Open($Path, 'OpenOrCreate', 'ReadWrite', 'None')
                }

                Get-Content -Path (Get-TerraformBinary -Version '1.9.8') -Raw | Should -Be 'from the other run'
                Should -Invoke Invoke-TerraformReleaseRequest -Times 0
            }
        }

        Context 'emulated amd64 fallback' {
            It 'prefers the native build when both are published' {
                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_arm64*"
                Should -Invoke Write-Warning -Times 0
            }

            It 'falls back to amd64 with a warning when no native build is published' {
                $script:PublishedChecksums.Remove('terraform_1.9.8_darwin_arm64.zip')

                $Binary = Get-TerraformBinary -Version '1.9.8'

                $Binary | Should -Be (Get-VendoredPath "terraform_1.9.8_darwin_amd64/${BinaryFileName}")
                Test-Path -Path (Get-VendoredPath 'terraform_1.9.8_darwin_amd64/.terraposh-sha256-fallback') | Should -BeTrue
                Test-Path -Path (Get-VendoredPath 'terraform_1.9.8_darwin_amd64/.terraposh-sha256') | Should -BeFalse
                Should -Invoke Invoke-TerraformReleaseRequest -Exactly -Times 1 -ParameterFilter {
                    $Uri -eq 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_darwin_amd64.zip'
                }
                Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like '*no darwin_arm64 build, using darwin_amd64 under Rosetta 2.' }
            }

            It 'names x64 emulation rather than Rosetta 2 on Windows' {
                Mock Get-TerraformOS { 'windows' }
                $script:PublishedChecksums = @{ 'terraform_1.9.8_windows_amd64.zip' = $FakeHash }

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike '*terraform_1.9.8_windows_amd64*'
                Should -Invoke Write-Warning -Exactly -Times 1 -ParameterFilter { $Message -like '*no windows_arm64 build, using windows_amd64 under x64 emulation.' }
            }

            It 'reuses a cached fallback binary without a warning or network access' {
                $script:PublishedChecksums.Remove('terraform_1.9.8_darwin_arm64.zip')
                Get-TerraformBinary -Version '1.9.8' | Out-Null

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_amd64*"
                Should -Invoke Write-Warning -Exactly -Times 1
                Should -Invoke Get-TerraformReleaseChecksums -Exactly -Times 1
            }

            It 'does not reuse an unverified amd64 binary from before the architecture fix' {
                $LegacyDirectory = Get-VendoredPath 'terraform_1.9.8_darwin_amd64'
                New-Item -Path $LegacyDirectory -ItemType Directory | Out-Null
                Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath $BinaryFileName) -Value 'legacy'

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_arm64*"
            }

            It 'does not reuse a natively verified amd64 binary as a fallback' {
                $LegacyDirectory = Get-VendoredPath 'terraform_1.9.8_darwin_amd64'
                New-Item -Path $LegacyDirectory -ItemType Directory | Out-Null
                Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath $BinaryFileName) -Value 'legacy'
                Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath '.terraposh-sha256') -Value "${FakeHash}`nsignature=Verified" -NoNewline

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_arm64*"
                Should -Invoke Get-TerraformReleaseChecksums -Exactly -Times 1
            }
        }
    }

    Describe 'Signature verification against releases.hashicorp.com' -Tag 'Integration' {
        $RunIntegration = [bool](Get-GpgvPath) -or $env:CI -eq 'true'

        BeforeAll {
            Mock Set-TerraformVendoredDirectory {
                $Directory = Join-Path -Path $TestDrive -ChildPath 'vendored'
                New-Item -Path $Directory -ItemType Directory -Force | Out-Null
                return $Directory
            }

            $OS = Get-TerraformOS
            $Release = Get-TerraformRelease -Version '1.9.8'
        }

        It 'downloads, verifies and runs Terraform <Version> for this platform' -Skip:(-not $RunIntegration) -TestCases @(
            @{ Version = '1.9.8' }
        ) {
            $Binary = Get-TerraformBinary -Version $Version

            Test-Path -Path $Binary | Should -BeTrue
            Get-Content -Path (Join-Path -Path (Split-Path -Parent $Binary) -ChildPath '.terraposh-sha256*') -Force | Should -Contain 'signature=Verified'

            $Platform = (Split-Path -Leaf (Split-Path -Parent $Binary)) -replace "^terraform_${Version}_", ''
            $ExpectedPlatforms = @("${OS}_$(Get-TerraformArchitecture)")
            $FallbackArchitecture = Get-TerraformFallbackArchitecture
            if ($FallbackArchitecture) { $ExpectedPlatforms += "${OS}_${FallbackArchitecture}" }
            $Platform | Should -BeIn $ExpectedPlatforms

            $Output = & $Binary version
            $LASTEXITCODE | Should -Be 0
            $Output[0] | Should -Be "Terraform v${Version}"
            $Output[1] | Should -Be "on ${Platform}"
        }

        Context 'gpgv' -Skip:(-not $RunIntegration) {
            BeforeAll {
                $ChecksumsFile = Join-Path -Path $TestDrive -ChildPath 'SHA256SUMS'
                Invoke-TerraformReleaseRequest -Uri $Release.ChecksumsUri -OutFile $ChecksumsFile
                $ChecksumsBytes = [System.IO.File]::ReadAllBytes($ChecksumsFile)
            }

            It 'verifies the real SHA256SUMS signature with gpgv' {
                { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsBytes $ChecksumsBytes } | Should -Not -Throw
            }

            It 'rejects a tampered SHA256SUMS' {
                $TamperedBytes = [byte[]]$ChecksumsBytes.Clone()
                $TamperedBytes[0] = $TamperedBytes[0] -bxor 0x01

                { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsBytes $TamperedBytes } | Should -Throw '*PGP signature verification failed*'
            }

            It 'rejects the real signature of a different release' {
                $OtherRelease = $Release.Clone()
                $OtherRelease.SignatureUri = $Release.SignatureUri -replace '1\.9\.8', '1.9.7'

                { Assert-TerraformChecksumsSignature -Release $OtherRelease -ChecksumsBytes $ChecksumsBytes } | Should -Throw '*PGP signature verification failed*'
            }
        }
    }
}
