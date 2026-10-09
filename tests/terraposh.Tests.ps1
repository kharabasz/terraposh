#Requires -Version 7
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
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*No Terraform version pinned*' }
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

            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
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
            Mock Get-TerraformOS { 'darwin' }
            Mock Assert-TerraformChecksumsSignature {}
        }

        It 'parses entries and normalises hashes to lowercase' {
            $Checksums = Get-TerraformReleaseChecksums -Release $Release

            $Checksums.Count | Should -Be 2
            $Checksums['terraform_1.9.8_linux_amd64.zip'] | Should -Be ('a' * 64)
            $Checksums['terraform_1.9.8_darwin_arm64.zip'] | Should -Be $HashB
            Should -Invoke Invoke-TerraformReleaseRequest -Times 1 -ParameterFilter { $Uri -eq $Release.ChecksumsUri }
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

        It 'leaves signature checks to the binary on <OS>' -TestCases @(
            @{ OS = 'darwin' }
            @{ OS = 'windows' }
        ) {
            Mock Get-TerraformOS { $OS }

            Get-TerraformReleaseChecksums -Release $Release | Out-Null
            Should -Invoke Assert-TerraformChecksumsSignature -Times 0
        }

        It 'verifies the downloaded checksum file signature on linux before parsing it' {
            Mock Get-TerraformOS { 'linux' }
            Mock Assert-TerraformChecksumsSignature {
                Get-Content -Path $ChecksumsFile -Raw | Should -Be $script:Sums
            }

            Get-TerraformReleaseChecksums -Release $Release | Out-Null
            Should -Invoke Assert-TerraformChecksumsSignature -Times 1
        }

        It 'does not parse checksums whose signature fails on linux' {
            Mock Get-TerraformOS { 'linux' }
            Mock Assert-TerraformChecksumsSignature { throw 'PGP signature verification failed' }

            { Get-TerraformReleaseChecksums -Release $Release } | Should -Throw '*PGP signature verification failed*'
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

    Describe 'Assert-TerraformChecksumsSignature' {
        BeforeAll {
            $Release = @{
                ChecksumsUri = 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'
                SignatureUri = 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS.72D7468F.sig'
            }
            $ChecksumsFile = Join-Path -Path $TestDrive -ChildPath 'SHA256SUMS'
            Set-Content -Path $ChecksumsFile -Value 'sums'

            function New-ValidSig([string]$PrimaryFingerprint) {
                "[GNUPG:] VALIDSIG 374EC75B485913604A831CC7C820C6D5CD27AB87 2024-10-16 1729084074 0 4 0 1 8 00 ${PrimaryFingerprint}"
            }
        }

        BeforeEach {
            Mock Test-GpgvInstalled { $true }
            Mock Invoke-TerraformReleaseRequest { Set-Content -Path $OutFile -Value 'sig' }
            Mock Invoke-Gpgv { @{ ExitCode = 0; Status = @('[GNUPG:] GOODSIG C820C6D5CD27AB87 HashiCorp', (New-ValidSig $HashiCorpKeyFingerprint)); Errors = @() } }
        }

        It 'accepts a valid signature from the pinned HashiCorp key' {
            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsFile $ChecksumsFile } | Should -Not -Throw

            Should -Invoke Invoke-TerraformReleaseRequest -Times 1 -ParameterFilter { $Uri -eq $Release.SignatureUri }
            Should -Invoke Invoke-Gpgv -Times 1 -ParameterFilter { $File -eq $ChecksumsFile }
        }

        It 'passes gpgv only the bundled key, in an isolated home directory' {
            Mock Invoke-Gpgv {
                [System.IO.File]::ReadAllBytes($Keyring) | Should -Be (ConvertFrom-ArmoredPgpKey -Path $HashiCorpKeyFile)
                Split-Path -Parent $Keyring | Should -Be $HomeDirectory
                Get-ChildItem -Path $HomeDirectory -Force | Should -HaveCount 2
                @{ ExitCode = 0; Status = @(New-ValidSig $HashiCorpKeyFingerprint); Errors = @() }
            }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsFile $ChecksumsFile } | Should -Not -Throw
        }

        It 'rejects a valid signature from a different key' {
            Mock Invoke-Gpgv { @{ ExitCode = 0; Status = @(New-ValidSig ('0' * 40)); Errors = @() } }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsFile $ChecksumsFile } | Should -Throw '*PGP signature verification failed*'
        }

        It 'rejects a bad signature' {
            Mock Invoke-Gpgv { @{ ExitCode = 1; Status = @('[GNUPG:] BADSIG C820C6D5CD27AB87 HashiCorp'); Errors = @('gpgv: BAD signature') } }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsFile $ChecksumsFile } | Should -Throw '*PGP signature verification failed*BAD signature*'
        }

        It 'rejects a non-zero gpgv exit code even with a VALIDSIG line' {
            Mock Invoke-Gpgv { @{ ExitCode = 2; Status = @(New-ValidSig $HashiCorpKeyFingerprint); Errors = @() } }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsFile $ChecksumsFile } | Should -Throw '*PGP signature verification failed*'
        }

        It 'ignores VALIDSIG text that only appears on stderr' {
            Mock Invoke-Gpgv { @{ ExitCode = 0; Status = @(); Errors = @(New-ValidSig $HashiCorpKeyFingerprint) } }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsFile $ChecksumsFile } | Should -Throw '*PGP signature verification failed*'
        }

        It 'fails when the signature file cannot be downloaded' {
            Mock Invoke-TerraformReleaseRequest { throw 'Response status code does not indicate success: 404 (Not Found).' }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsFile $ChecksumsFile } | Should -Throw '*404*'
            Should -Invoke Invoke-Gpgv -Times 0
        }

        It 'fails when gpgv is not installed' {
            Mock Test-GpgvInstalled { $false }

            { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsFile $ChecksumsFile } | Should -Throw '*gpgv is required*'
            Should -Invoke Invoke-TerraformReleaseRequest -Times 0
        }
    }

    Describe 'Assert-TerraformCodesignSignature' {
        It 'accepts a binary signed by HashiCorp''s Developer ID' {
            Mock Invoke-Codesign { @{ ExitCode = 0; Output = @() } }

            { Assert-TerraformCodesignSignature -BinaryFile 'terraform' } | Should -Not -Throw
            Should -Invoke Invoke-Codesign -Times 1 -ParameterFilter {
                $Arguments[0] -eq '--verify' -and $Arguments -contains '--strict' -and $Arguments[-1] -eq 'terraform' -and
                ($Arguments -like '=anchor apple generic and *certificate leaf`[subject.OU`] = D38WU7D763').Count -eq 1
            }
        }

        It 'rejects <Case>' -TestCases @(
            @{ Case = 'another team'; ExitCode = 3; Output = 'test-requirement: code failed to satisfy specified code requirement(s)' }
            @{ Case = 'a modified binary'; ExitCode = 1; Output = 'terraform: invalid signature (code or signature have been modified)' }
            @{ Case = 'an unsigned binary'; ExitCode = 1; Output = 'terraform: code object is not signed at all' }
        ) {
            Mock Invoke-Codesign { @{ ExitCode = $ExitCode; Output = @($Output) } }

            { Assert-TerraformCodesignSignature -BinaryFile 'terraform' } | Should -Throw "*Code signature verification failed*${Output}*"
        }
    }

    Describe 'Assert-TerraformAuthenticodeSignature' {
        BeforeAll {
            function New-Certificate([string]$Subject) {
                $Key = [System.Security.Cryptography.RSA]::Create(2048)
                $Request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
                    $Subject, $Key, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
                return $Request.CreateSelfSigned([DateTimeOffset]::Now.AddDays(-1), [DateTimeOffset]::Now.AddDays(1))
            }

            $HashiCorpCertificate = New-Certificate 'CN="HashiCorp, Inc.", O="HashiCorp, Inc.", L=San Francisco, S=California, C=US'
            $OtherCertificate = New-Certificate 'CN="Evil Corp", O="HashiCorp, Inc."'
        }

        It 'accepts a valid signature from HashiCorp' {
            Mock Get-TerraformAuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $HashiCorpCertificate } }

            { Assert-TerraformAuthenticodeSignature -BinaryFile 'terraform.exe' } | Should -Not -Throw
            Should -Invoke Get-TerraformAuthenticodeSignature -Times 1 -ParameterFilter { $Path -eq 'terraform.exe' }
        }

        It 'rejects a valid signature from another signer' {
            Mock Get-TerraformAuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = $OtherCertificate } }

            { Assert-TerraformAuthenticodeSignature -BinaryFile 'terraform.exe' } | Should -Throw "*signer: 'Evil Corp'*"
        }

        It 'rejects status <Status>' -TestCases @(
            @{ Status = 'HashMismatch' }
            @{ Status = 'NotTrusted' }
            @{ Status = 'UnknownError' }
            @{ Status = 'NotSigned' }
        ) {
            Mock Get-TerraformAuthenticodeSignature { [pscustomobject]@{ Status = $Status; SignerCertificate = ($Status -eq 'NotSigned' ? $null : $HashiCorpCertificate) } }

            { Assert-TerraformAuthenticodeSignature -BinaryFile 'terraform.exe' } | Should -Throw "*status: ${Status}*"
        }
    }

    Describe 'Assert-TerraformBinarySignature' {
        BeforeEach {
            Mock Assert-TerraformCodesignSignature {}
            Mock Assert-TerraformAuthenticodeSignature {}
        }

        It 'uses codesign on macOS' {
            Mock Get-TerraformOS { 'darwin' }

            Assert-TerraformBinarySignature -BinaryFile 'terraform'

            Should -Invoke Assert-TerraformCodesignSignature -Times 1 -ParameterFilter { $BinaryFile -eq 'terraform' }
            Should -Invoke Assert-TerraformAuthenticodeSignature -Times 0
        }

        It 'uses Authenticode on Windows' {
            Mock Get-TerraformOS { 'windows' }

            Assert-TerraformBinarySignature -BinaryFile 'terraform.exe'

            Should -Invoke Assert-TerraformAuthenticodeSignature -Times 1 -ParameterFilter { $BinaryFile -eq 'terraform.exe' }
            Should -Invoke Assert-TerraformCodesignSignature -Times 0
        }

        It 'does nothing on Linux, where the checksum signature was verified' {
            Mock Get-TerraformOS { 'linux' }

            Assert-TerraformBinarySignature -BinaryFile 'terraform'

            Should -Invoke Assert-TerraformCodesignSignature -Times 0
            Should -Invoke Assert-TerraformAuthenticodeSignature -Times 0
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
            Mock Assert-TerraformBinarySignature {}
            Mock Invoke-TerraformReleaseRequest { Copy-Item -Path $FakeArchive -Destination $OutFile } -ParameterFilter { $OutFile }
        }

        It 'downloads, verifies and extracts the native build' {
            $Binary = Get-TerraformBinary -Version '1.9.8'

            $Binary | Should -Be (Get-VendoredPath "terraform_1.9.8_darwin_arm64/${BinaryFileName}")
            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Get-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64/.terraposh-sha256') -Force | Should -Be @($FakeHash, 'signature=Verified')
            Test-Path -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip.download') | Should -BeFalse
            Should -Invoke Invoke-TerraformReleaseRequest -Times 1 -ParameterFilter {
                $Uri -eq 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_darwin_arm64.zip'
            }
            Should -Invoke Write-Warning -Times 0
        }

        It 'reuses a verified binary without network access' {
            Get-TerraformBinary -Version '1.9.8' | Out-Null
            $Binary = Get-TerraformBinary -Version '1.9.8'

            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Should -Invoke Get-TerraformReleaseChecksums -Times 1
            Should -Invoke Invoke-TerraformReleaseRequest -Times 1
        }

        It 'refuses a download that fails checksum verification and leaves nothing behind' {
            $script:PublishedChecksums['terraform_1.9.8_darwin_arm64.zip'] = '0' * 64

            { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*SHA-256 checksum mismatch*'
            Get-ChildItem -Path (Get-VendoredPath '') -Force | Should -BeNullOrEmpty
            Should -Invoke Assert-TerraformBinarySignature -Times 0
        }

        It 're-downloads a tampered cached archive' {
            Copy-Item -Path $FakeArchive -Destination (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip')
            Add-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip') -Value 'tampered'

            $Binary = Get-TerraformBinary -Version '1.9.8'

            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Test-FileChecksum -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64.zip') -ExpectedHash $FakeHash | Should -BeTrue
            Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*failed SHA-256 verification*' }
            Should -Invoke Invoke-TerraformReleaseRequest -Times 1
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
            It 'checks the extracted binary''s signature before marking it verified' {
                Mock Assert-TerraformBinarySignature {
                    Get-Content -Path $BinaryFile -Raw | Should -Be 'genuine terraform'
                    Test-Path -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64/.terraposh-sha256') | Should -BeFalse
                }

                $Binary = Get-TerraformBinary -Version '1.9.8'

                Should -Invoke Assert-TerraformBinarySignature -Times 1 -ParameterFilter { $BinaryFile -eq $Binary }
                Get-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64/.terraposh-sha256') -Force | Should -Be @($FakeHash, 'signature=Verified')
            }

            It 'removes the extracted binary and archive when the binary signature fails' {
                Mock Assert-TerraformBinarySignature { throw 'Code signature verification failed' }

                { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*Code signature verification failed*'
                Get-ChildItem -Path (Get-VendoredPath '') -Force | Should -BeNullOrEmpty
            }

            It 'does not download when the checksum signature fails' {
                Mock Get-TerraformReleaseChecksums { throw 'PGP signature verification failed' }

                { Get-TerraformBinary -Version '1.9.8' } | Should -Throw '*PGP signature verification failed*'
                Should -Invoke Invoke-TerraformReleaseRequest -Times 0
                Get-ChildItem -Path (Get-VendoredPath '') -Force | Should -BeNullOrEmpty
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
                Should -Invoke Assert-TerraformBinarySignature -Times 1
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
                Should -Invoke Invoke-TerraformReleaseRequest -Times 1 -ParameterFilter {
                    $Uri -eq 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_darwin_amd64.zip'
                }
                Should -Invoke Write-Warning -Times 1 -ParameterFilter { $Message -like '*no darwin_arm64 build, using darwin_amd64*' }
            }

            It 'reuses a cached fallback binary without a warning or network access' {
                $script:PublishedChecksums.Remove('terraform_1.9.8_darwin_arm64.zip')
                Get-TerraformBinary -Version '1.9.8' | Out-Null

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_amd64*"
                Should -Invoke Write-Warning -Times 1
                Should -Invoke Get-TerraformReleaseChecksums -Times 1
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
                Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath '.terraposh-sha256') -Value $FakeHash

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_arm64*"
            }
        }
    }

    Describe 'Signature verification against releases.hashicorp.com' -Tag 'Integration' {
        $DiscoveryOS = Get-TerraformOS
        $DiscoveryGpgv = Test-GpgvInstalled

        BeforeAll {
            Mock Set-TerraformVendoredDirectory {
                $Directory = Join-Path -Path $TestDrive -ChildPath 'vendored'
                New-Item -Path $Directory -ItemType Directory -Force | Out-Null
                return $Directory
            }

            $OS = Get-TerraformOS
            $Release = Get-TerraformRelease -Version '1.9.8'
        }

        It 'downloads, verifies and runs Terraform <Version> for this platform' -Skip:($DiscoveryOS -eq 'linux' -and -not $DiscoveryGpgv) -TestCases @(
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

        Context 'linux' -Skip:($DiscoveryOS -ne 'linux' -or -not $DiscoveryGpgv) {
            BeforeAll {
                $ChecksumsFile = Join-Path -Path $TestDrive -ChildPath 'SHA256SUMS'
                Invoke-TerraformReleaseRequest -Uri $Release.ChecksumsUri -OutFile $ChecksumsFile
            }

            It 'verifies the real SHA256SUMS signature with gpgv' {
                { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsFile $ChecksumsFile } | Should -Not -Throw
            }

            It 'rejects a tampered SHA256SUMS' {
                $TamperedFile = Join-Path -Path $TestDrive -ChildPath 'SHA256SUMS.tampered'
                Set-Content -Path $TamperedFile -Value ((Get-Content -Path $ChecksumsFile -Raw) -replace '^.', '0') -NoNewline

                { Assert-TerraformChecksumsSignature -Release $Release -ChecksumsFile $TamperedFile } | Should -Throw '*PGP signature verification failed*'
            }

            It 'rejects the real signature of a different release' {
                $OtherRelease = $Release.Clone()
                $OtherRelease.SignatureUri = $Release.SignatureUri -replace '1\.9\.8', '1.9.7'

                { Assert-TerraformChecksumsSignature -Release $OtherRelease -ChecksumsFile $ChecksumsFile } | Should -Throw '*PGP signature verification failed*'
            }
        }

        Context 'macOS and Windows' -Skip:($DiscoveryOS -eq 'linux') {
            BeforeAll {
                $Binary = Get-TerraformBinary -Version '1.9.8'
                $TamperedBinary = Join-Path -Path $TestDrive -ChildPath "tampered-$(Split-Path -Leaf $Binary)"
                $Bytes = [System.IO.File]::ReadAllBytes($Binary)
                $Bytes[$Bytes.Length / 2] = $Bytes[$Bytes.Length / 2] -bxor 0xFF
                [System.IO.File]::WriteAllBytes($TamperedBinary, $Bytes)

                $OtherPublisherBinary = Join-Path -Path $TestDrive -ChildPath "other-publisher-$(Split-Path -Leaf $Binary)"
                Copy-Item -Path (Get-Command -Name 'pwsh').Source -Destination $OtherPublisherBinary
            }

            It 'verifies the real binary signature' {
                { Assert-TerraformBinarySignature -BinaryFile $Binary } | Should -Not -Throw
            }

            It 'rejects a modified binary' {
                { Assert-TerraformBinarySignature -BinaryFile $TamperedBinary } | Should -Throw '*signature verification failed*'
            }

            It 'rejects a validly signed binary from another publisher' {
                { Assert-TerraformBinarySignature -BinaryFile $OtherPublisherBinary } | Should -Throw '*signature verification failed*'
            }
        }
    }
}
