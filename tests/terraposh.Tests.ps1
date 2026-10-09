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
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = 'checksums' } }
        }

        It 'refuses <Uri>' -TestCases @(
            @{ Uri = 'http://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS' }
            @{ Uri = 'https://example.com/terraform_1.9.8_SHA256SUMS' }
            @{ Uri = 'https://releases.hashicorp.com.evil.example/terraform_1.9.8_SHA256SUMS' }
            @{ Uri = 'ftp://releases.hashicorp.com/terraform_1.9.8_SHA256SUMS' }
        ) {
            { Invoke-TerraformReleaseRequest -Uri $Uri } | Should -Throw '*Refusing to download*'
            Should -Invoke Invoke-WebRequest -Times 0
        }

        It 'requests over HTTPS without following redirects' {
            Invoke-TerraformReleaseRequest -Uri 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS' | Should -Be 'checksums'

            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
                $MaximumRedirection -eq 0 -and $Uri.AbsoluteUri -eq 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS'
            }
        }

        It 'decodes byte content as UTF-8' {
            Mock Invoke-WebRequest { [pscustomobject]@{ Content = [System.Text.Encoding]::UTF8.GetBytes('checksums') } }

            Invoke-TerraformReleaseRequest -Uri 'https://releases.hashicorp.com/x' | Should -Be 'checksums'
        }

        It 'downloads to OutFile' {
            Invoke-TerraformReleaseRequest -Uri 'https://releases.hashicorp.com/x.zip' -OutFile 'out.zip'

            Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter { $OutFile -eq 'out.zip' -and $MaximumRedirection -eq 0 }
        }
    }

    Describe 'Get-TerraformReleaseChecksums' {
        BeforeAll {
            $Release = @{ ChecksumsUri = 'https://releases.hashicorp.com/terraform/1.9.8/terraform_1.9.8_SHA256SUMS' }
            $HashA = 'A' * 64
            $HashB = 'b' * 64
        }

        It 'parses entries and normalises hashes to lowercase' {
            Mock Invoke-TerraformReleaseRequest { "${HashA}  terraform_1.9.8_linux_amd64.zip`n${HashB}  terraform_1.9.8_darwin_arm64.zip`n`n" }

            $Checksums = Get-TerraformReleaseChecksums -Release $Release

            $Checksums.Count | Should -Be 2
            $Checksums['terraform_1.9.8_linux_amd64.zip'] | Should -Be ('a' * 64)
            $Checksums['terraform_1.9.8_darwin_arm64.zip'] | Should -Be $HashB
        }

        It 'handles CRLF line endings' {
            Mock Invoke-TerraformReleaseRequest { "${HashA}  terraform_1.9.8_linux_amd64.zip`r`n" }

            (Get-TerraformReleaseChecksums -Release $Release).Keys | Should -Be 'terraform_1.9.8_linux_amd64.zip'
        }

        It 'throws on a malformed hash' {
            Mock Invoke-TerraformReleaseRequest { 'abc123  terraform_1.9.8_linux_amd64.zip' }

            { Get-TerraformReleaseChecksums -Release $Release } | Should -Throw '*Malformed SHA256SUMS entry*'
        }

        It 'throws on duplicate entries' {
            Mock Invoke-TerraformReleaseRequest { "${HashA}  terraform_1.9.8_linux_amd64.zip`n${HashB}  terraform_1.9.8_linux_amd64.zip" }

            { Get-TerraformReleaseChecksums -Release $Release } | Should -Throw '*Malformed SHA256SUMS entry*'
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
            # Fake release archive containing a "terraform" binary
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
            Mock Invoke-TerraformReleaseRequest { Copy-Item -Path $FakeArchive -Destination $OutFile } -ParameterFilter { $OutFile }
        }

        It 'downloads, verifies and extracts the native build' {
            $Binary = Get-TerraformBinary -Version '1.9.8'

            $Binary | Should -Be (Get-VendoredPath "terraform_1.9.8_darwin_arm64/${BinaryFileName}")
            Get-Content -Path $Binary -Raw | Should -Be 'genuine terraform'
            Get-Content -Path (Get-VendoredPath 'terraform_1.9.8_darwin_arm64/.terraposh-sha256') -Raw -Force | Should -Be $FakeHash
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
                # A ".terraposh-sha256" marker under darwin_amd64 was written before the architecture fix
                $LegacyDirectory = Get-VendoredPath 'terraform_1.9.8_darwin_amd64'
                New-Item -Path $LegacyDirectory -ItemType Directory | Out-Null
                Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath $BinaryFileName) -Value 'legacy'
                Set-Content -Path (Join-Path -Path $LegacyDirectory -ChildPath '.terraposh-sha256') -Value $FakeHash

                Get-TerraformBinary -Version '1.9.8' | Should -BeLike "*terraform_1.9.8_darwin_arm64*"
            }
        }
    }

    Describe 'Get-TerraformBinary against releases.hashicorp.com' -Tag 'Integration' {
        BeforeAll {
            Mock Set-TerraformVendoredDirectory {
                $Directory = Join-Path -Path $TestDrive -ChildPath 'vendored'
                New-Item -Path $Directory -ItemType Directory -Force | Out-Null
                return $Directory
            }
        }

        It 'downloads, verifies and runs Terraform <Version> for this platform' -TestCases @(
            @{ Version = '1.9.8' }
        ) {
            $Binary = Get-TerraformBinary -Version $Version

            Test-Path -Path $Binary | Should -BeTrue

            # Native build, or the emulated amd64 build when none is published (e.g. windows_arm64)
            $Platform = (Split-Path -Leaf (Split-Path -Parent $Binary)) -replace "^terraform_${Version}_", ''
            $ExpectedPlatforms = @("$(Get-TerraformOS)_$(Get-TerraformArchitecture)")
            $FallbackArchitecture = Get-TerraformFallbackArchitecture
            if ($FallbackArchitecture) { $ExpectedPlatforms += "$(Get-TerraformOS)_${FallbackArchitecture}" }
            $Platform | Should -BeIn $ExpectedPlatforms

            $Output = & $Binary version
            $LASTEXITCODE | Should -Be 0
            $Output[0] | Should -Be "Terraform v${Version}"
            $Output[1] | Should -Be "on ${Platform}"
        }
    }
}
