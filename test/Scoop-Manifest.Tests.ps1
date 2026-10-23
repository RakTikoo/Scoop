BeforeAll {
    . "$PSScriptRoot\..\lib\json.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\manifest.ps1"
    . "$PSScriptRoot\..\lib\buckets.ps1"
    . "$PSScriptRoot\..\lib\versions.ps1"
    . "$PSScriptRoot\..\lib\database.ps1"
    . "$PSScriptRoot\..\lib\autoupdate.ps1"
}

Describe 'JSON parse and beautify' -Tag 'Scoop' {
    Context 'Parse JSON' {
        It 'success with valid json' {
            $null = & { parse_json "$PSScriptRoot\fixtures\manifest\wget.json" }
            $parsed = parse_json "$PSScriptRoot\fixtures\manifest\wget.json"
            $parsed | Should-NotBeNull
        }
        It 'returns null and warns with invalid json' {
            Mock warn {}
            & { parse_json "$PSScriptRoot\fixtures\manifest\broken_wget.json" }
            $parsed = parse_json "$PSScriptRoot\fixtures\manifest\broken_wget.json"
            $parsed | Should-BeNull
            Should-Invoke -CommandName warn -Times 1
        }
    }
    Context 'Beautify JSON' {
        BeforeDiscovery {
            $manifests = (Get-ChildItem "$PSScriptRoot\fixtures\format\formatted" -File -Filter '*.json').Name
        }
        BeforeAll {
            $format = "$PSScriptRoot\fixtures\format"
        }
        It '<_>' -ForEach $manifests {
            $pretty_json = (parse_json "$format\unformatted\$_") | ConvertToPrettyJson
            $correct = (Get-Content "$format\formatted\$_") -join "`r`n"
            $correct.CompareTo($pretty_json) | Should-Be 0
        }
    }
}

Describe 'Handle ARM64 and correctly fallback' -Tag 'Scoop' {
    It 'Should return "arm64" if supported' {
        $manifest1 = @{ url = 'test'; architecture = @{ 'arm64' = @{ pre_install = 'test' } } }
        $manifest2 = @{ url = 'test'; pre_install = "'arm64'" }
        $manifest3 = @{ architecture = @{ 'arm64' = @{ url = 'test' } } }
        Get-SupportedArchitecture $manifest1 'arm64' | Should-Be 'arm64'
        Get-SupportedArchitecture $manifest2 'arm64' | Should-Be 'arm64'
        Get-SupportedArchitecture $manifest3 'arm64' | Should-Be 'arm64'
    }
    It 'Should return "64bit" if unsupported on Windows 11' {
        $WindowsBuild = 22000
        $manifest1 = @{ url = 'test' }
        $manifest2 = @{ architecture = @{ '64bit' = @{ url = 'test' } } }
        Get-SupportedArchitecture $manifest1 'arm64' | Should-Be '64bit'
        Get-SupportedArchitecture $manifest2 'arm64' | Should-Be '64bit'
    }
    It 'Should return "32bit" if unsupported on Windows 10' {
        $WindowsBuild = 19044
        $manifest2 = @{ url = 'test' }
        $manifest1 = @{ url = 'test'; architecture = @{ '64bit' = @{ pre_install = 'test' } } }
        $manifest3 = @{ architecture = @{ '64bit' = @{ url = 'test' } } }
        Get-SupportedArchitecture $manifest1 'arm64' | Should-Be '32bit'
        Get-SupportedArchitecture $manifest2 'arm64' | Should-Be '32bit'
        Get-SupportedArchitecture $manifest3 'arm64' | Should-BeNull
    }
}

Describe 'Manifest Validator' -Tag 'Validator' {
    # Could not use backslash '\' in Linux/macOS for .NET object 'Scoop.Validator'
    BeforeAll {
        Add-Type -Path "$PSScriptRoot\..\supporting\validator\bin\Scoop.Validator.dll"
        $schema = "$PSScriptRoot/../schema.json"
    }

    It 'Scoop.Validator is available' {
        ([System.Management.Automation.PSTypeName]'Scoop.Validator').Type | Should-Be 'Scoop.Validator'
    }
    It 'fails with broken schema' {
        $validator = New-Object Scoop.Validator("$PSScriptRoot/fixtures/manifest/broken_schema.json", $true)
        $validator.Validate("$PSScriptRoot/fixtures/manifest/wget.json") | Should-BeFalse
        $validator.Errors.Count | Should-Be 1
        $validator.Errors | Select-Object -First 1 | Should-MatchString 'broken_schema.*(line 6).*(position 4)'
    }
    It 'fails with broken manifest' {
        $validator = New-Object Scoop.Validator($schema, $true)
        $validator.Validate("$PSScriptRoot/fixtures/manifest/broken_wget.json") | Should-BeFalse
        $validator.Errors.Count | Should-Be 1
        $validator.Errors | Select-Object -First 1 | Should-MatchString 'broken_wget.*(line 5).*(position 4)'
    }
    It 'fails with invalid manifest' {
        $validator = New-Object Scoop.Validator($schema, $true)
        $validator.Validate("$PSScriptRoot/fixtures/manifest/invalid_wget.json") | Should-BeFalse
        $validator.Errors.Count | Should-Be 16
        $validator.Errors | Select-Object -First 1 | Should-MatchString "Property 'randomproperty' has not been defined and the schema does not allow additional properties\."
        $validator.Errors | Select-Object -Last 1 | Should-MatchString 'Required properties are missing from object: version\.'
    }
}

Describe 'Find-HistoricalManifestInCache' -Tag 'Scoop' {
    It 'returns $null when sqlite cache disabled' {
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        $result = Find-HistoricalManifestInCache 'foo' 'main' '1.0.0'
        $result | Should-BeNull
    }

    It 'returns manifest text and version when cache has exact match' {
        $tempUM = Join-Path $env:TEMP 'ScoopTestsUM'
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache', 'use_git_history') } { $true }
        Mock Get-ScoopDBItem {
            $dt = New-Object System.Data.DataTable
            [void]$dt.Columns.Add('manifest')
            $row = $dt.NewRow()
            $row['manifest'] = '{"version":"1.2.3"}'
            [void]$dt.Rows.Add($row)
            Write-Output $dt -NoEnumerate
        }
        Mock ensure {}
        $result = Find-HistoricalManifestInCache 'foo' 'main' '1.2.3'
        $result | Should-NotBeNull
        $result.version | Should-Be '1.2.3'
        $result.ManifestText | Should-MatchString '"version":"1.2.3"'
    }
}

Describe 'Find-HistoricalManifestInGit' -Tag 'Scoop' {
    BeforeEach {
        $bucketRoot = 'C:\b\root'
        $innerBucket = 'C:\b\root\bucket'
        Mock get_config -ParameterFilter { $name -eq 'use_git_history' } { $true }
        Mock Find-BucketDirectory -ParameterFilter { $Root } { $bucketRoot }
        Mock Find-BucketDirectory -ParameterFilter { -not $Root } { $innerBucket }
        Mock Test-Path -ParameterFilter { $Path -eq (Join-Path $bucketRoot '.git') } { $true }
        Mock Test-Path -ParameterFilter { $Path -eq $innerBucket -and $PathType -eq 'Container' } { $true }
    }

    It 'returns $null when git history search disabled' {
        Mock get_config -ParameterFilter { $name -eq 'use_git_history' } { $false }
        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-BeNull
    }

    It 'returns manifest text on version match' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"2.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' } { return '{"version":"1.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' } { @('abcdef0123456789') }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-NotBeNull
        $result.version | Should-Be '1.0.0'
        $result.ManifestText | Should-MatchString '"version":"1.0.0"'
    }

    It 'short-circuits via HEAD fast-path when HEAD already has the requested version' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"1.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' } { @('shouldnotbeused') }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-NotBeNull
        $result.version | Should-Be '1.0.0'
        $result.source | Should-Be 'git_manifest:HEAD'
        Should-Invoke -CommandName Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' } -Times 0
    }

    It 'falls back to -S pickaxe when -G yields no commits' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"2.0.0"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-G' } { return @() }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-S' } { return @('feedface') }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -notlike 'HEAD*' } { return '{"version":"1.0.0"}' }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-NotBeNull
        $result.version | Should-Be '1.0.0'
        $result.source | Should-Be 'git_manifest:feedface'
    }

    It 'returns $null when $h / $h^ walk yields no manifest' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"9.9.9"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -match '^[a-f0-9]+\^?:' } { return '{"version":"9.9.9"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-G' } { return @('aaaa1111') }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-BeNull
    }

    It 'walks older pickaxe hits when the newest ones are later releases' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"5.20.2"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-G' } { return @('newer1111', 'older2222') }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -eq 'newer1111:bucket/foo.json' } { return '{"version":"5.20.2"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -eq 'newer1111^:bucket/foo.json' } { return '{"version":"5.20.1"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -eq 'older2222:bucket/foo.json' } { return '{"version":"5.20"}' }

        $result = Find-HistoricalManifestInGit 'foo' 'main' '5.20'
        $result | Should-NotBeNull
        $result.version | Should-Be '5.20'
        $result.source | Should-Be 'git_manifest:older2222'
    }

    It 'anchors the pickaxe pattern so a longer version cannot match' {
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'show' -and $ArgumentList[1] -like 'HEAD*' } { return '{"version":"5.20.2"}' }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-G' } {
            $script:pickaxePattern = $ArgumentList[[Array]::IndexOf($ArgumentList, '-G') + 1]
            return @()
        }
        Mock Invoke-Git -ParameterFilter { $ArgumentList[0] -eq 'log' -and $ArgumentList -contains '-S' } { return @() }

        $null = Find-HistoricalManifestInGit 'foo' 'main' '5.20'
        $script:pickaxePattern | Should-Be 'version.: .5\.20([^0-9A-Za-z._+-]|$)'
    }

    It 'returns $null when inner bucket directory cannot be found' {
        Mock Test-Path -ParameterFilter { $Path -eq $innerBucket -and $PathType -eq 'Container' } { $false }
        Mock warn {}
        $result = Find-HistoricalManifestInGit 'foo' 'main' '1.0.0'
        $result | Should-BeNull
    }
}

Describe 'Find-HistoricalManifest (orchestrator)' -Tag 'Scoop' {
    It 'returns $null when both cache and git miss' {
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache', 'use_git_history') } { $true }
        Mock Find-HistoricalManifestInCache { $null }
        Mock Find-HistoricalManifestInGit { $null }
        $result = Find-HistoricalManifest 'foo' 'main' '1.0.0'
        $result | Should-BeNull
    }
}

Describe 'Write-ManifestToUserCache' -Tag 'Scoop' {
    It 'writes to $App.json (no version suffix) so downstream install path does not duplicate version' {
        $umdir = Join-Path $env:TEMP ("ScoopUM_" + [guid]::NewGuid().ToString('N'))
        Mock usermanifestsdir { $umdir }
        $p = Write-ManifestToUserCache -App 'foo' -ManifestText '{"version":"1.0.0"}'
        $p | Should-Be (Join-Path $umdir 'foo.json')
        Test-Path $p | Should-BeTrue
        Remove-Item -Recurse -Force $umdir -ErrorAction SilentlyContinue
    }
}

Describe 'generate_user_manifest (history-aware)' -Tag 'Scoop' {
    It 'returns manifest_path when versions match' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '1.0.0' }, 'main', $null }
        Mock manifest_path { 'C:\path\foo.json' }
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should-Be 'C:\path\foo.json'
    }

    It 'prefers history orchestrator hit (cache) when enabled' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '2.0.0' }, 'main', $null }
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache', 'use_git_history') } { $true }
        Mock Find-HistoricalManifest { @{ path = 'C:\cache\foo.json'; version = '1.0.0'; source = 'sqlite_exact_match' } }

        Mock info {}
        Mock warn {}
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should-Be 'C:\cache\foo.json'
        Should-Invoke -CommandName Find-HistoricalManifest -Times 1

    }

    It 'falls back to git history when cache misses' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '2.0.0' }, 'main', $null }
        Mock get_config -ParameterFilter { $name -in @('use_sqlite_cache', 'use_git_history') } { $true }
        Mock Find-HistoricalManifest { @{ path = 'C:\git\foo.json'; version = '1.0.0'; source = 'git_manifest:hash' } }
        Mock info {}
        Mock warn {}
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should-Be 'C:\git\foo.json'
        Should-Invoke -CommandName Find-HistoricalManifest -Times 1

    }

    It 'uses autoupdate when no history found and autoupdate exists' {
        $umdir = Join-Path $env:TEMP 'ScoopTestsUM'
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '2.0.0'; autoupdate = @{} }, 'main', $null }
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        Mock Find-HistoricalManifest { $null }

        Mock ensure {}
        Mock usermanifestsdir { $umdir }
        Mock Invoke-AutoUpdate {}
        Mock warn {}
        Mock info {}
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should-Be (Join-Path $umdir 'foo.json')
        Should-Invoke -CommandName warn -Times 1 -ParameterFilter { $msg -match "No historical manifest found for 'foo@1\.0\.0'; attempting autoupdate" }
    }

    It 'returns $null when autoupdate fails (caller surfaces the error)' {
        $umdir = Join-Path $env:TEMP 'ScoopTestsUM'
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '2.0.0'; autoupdate = @{} }, 'main', $null }
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        Mock Find-HistoricalManifest { $null }
        Mock ensure {}
        Mock usermanifestsdir { $umdir }
        Mock Invoke-AutoUpdate { throw 'fail' }
        Mock warn {}
        Mock info {}
        $p = generate_user_manifest 'foo' 'main' '1.0.0'
        $p | Should-BeNull
    }

    It 'aborts when no history and no autoupdate' {
        Mock Get-Manifest -ParameterFilter { $app -eq 'main/foo' } { 'foo', [pscustomobject]@{ version = '2.0.0' }, 'main', $null }
        Mock get_config -ParameterFilter { $name -eq 'use_sqlite_cache' } { $false }
        Mock Find-HistoricalManifest { $null }

        Mock warn {}
        Mock info {}
        { generate_user_manifest 'foo' 'main' '1.0.0' } | Should-Throw
    }
}

Describe 'manifest bucket auto-discovery' -Tag 'Scoop' {
    It 'discovers bucket for bare app name' {
        Mock Get-LocalBucket { @('main') }
        Mock manifest_path { 'C:\fake.json' }
        Mock parse_json { @{ version = '1.0.0' } }
        Mock warn {}
        $m, $b = Find-AppBucket 'foo'
        $b | Should-Be 'main'
        $m.version | Should-Be '1.0.0'
    }

    It 'returns $null when app not found in any bucket' {
        Mock Get-LocalBucket { @('main') }
        Mock manifest_path { 'C:\nonexistent.json' }
        Mock parse_json { $null }
        Mock warn {}
        $m, $b = Find-AppBucket 'foo'
        $m | Should-BeNull
        $b | Should-BeNull
    }

    It 'url used when bucket is null' {
        Mock url_manifest { @{ version = '1.0.0' } }
        $m = manifest 'foo' $null 'https://example.com/foo.json'
        $m.version | Should-Be '1.0.0'
        Should-Invoke url_manifest -Times 1
    }
}

Describe 'manifest aliases' -Tag 'Scoop' {
    BeforeAll {
        Function Write-AliasMap([string] $bucket, [string] $app, [string] $target) {
            $dir = Join-Path $aliasTestRoot $bucket
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir '.scoop-aliases.json'), ('{"' + $app + '":"' + $target + '"}'))
        }

        Function Write-AppManifest([string] $bucket, [string] $app, [string] $version) {
            $dir = Join-Path $aliasTestRoot "$bucket\bucket"
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $dir "$app.json"), ('{"version":"' + $version + '"}'))
        }
    }

    BeforeEach {
        $aliasTestRoot = Join-Path $env:TEMP ("ScoopAliasTests_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $aliasTestRoot | Out-Null
        Mock Get-LocalBucket { @('extras', 'main') }
        Mock Find-BucketDirectory {
            $repo = Join-Path $aliasTestRoot $Name
            if ($Root -or !(Test-Path (Join-Path $repo 'bucket'))) {
                $repo
            } else {
                Join-Path $repo 'bucket'
            }
        }
        Mock warn {}
        Mock error {}
        Mock installed { $false }
    }

    AfterEach {
        Remove-Item -Path $aliasTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'resolves alias names to the canonical manifest and bucket' {
        Write-AppManifest 'main' 'new-name' '1.0.0'
        [System.IO.File]::WriteAllText((Join-Path $aliasTestRoot 'main\.scoop-aliases.json'),
            '{"old-name":"main/new-name","older-name":"main/new-name"}')

        $app, $manifest, $bucket, $url = Get-Manifest 'old-name'

        $app | Should-Be 'new-name'
        $bucket | Should-Be 'main'
        $manifest.version | Should-Be '1.0.0'
        (Get-Manifest 'older-name')[0] | Should-Be 'new-name'
    }

    It 'prefers an exact manifest name over an alias' {
        Write-AliasMap 'main' 'old-name' 'main/new-name'
        Write-AppManifest 'main' 'new-name' '2.0.0'
        Write-AppManifest 'extras' 'old-name' '1.0.0'

        $app, $manifest, $bucket, $url = Get-Manifest 'old-name'

        $app | Should-Be 'old-name'
        $bucket | Should-Be 'extras'
    }

    It 'prefers the renamed app over the deprecated manifest of the old name' {
        Write-AliasMap 'main' 'old-name' 'main/new-name'
        Write-AppManifest 'main' 'new-name' '2.0.0'
        $deprecatedDir = Join-Path $aliasTestRoot 'main\deprecated'
        New-Item -ItemType Directory -Path $deprecatedDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $deprecatedDir 'old-name.json'), '{"version":"0.9.0"}')

        $app, $manifest, $bucket, $url = Get-Manifest 'old-name'

        $app | Should-Be 'new-name'
        $manifest.version | Should-Be '2.0.0'
    }

    It 'prefers a local path over an alias' {
        Write-AliasMap 'main' 'local-app' 'main/new-name'
        Write-AppManifest 'main' 'new-name' '1.0.0'
        [System.IO.File]::WriteAllText((Join-Path $aliasTestRoot 'local-app.json'), '{"version":"3.0.0"}')
        Mock Find-AppAlias { $null }
        Push-Location $aliasTestRoot
        try {
            $app, $manifest, $bucket, $url = Get-Manifest 'local-app.json'
        } finally {
            Pop-Location
        }

        Should-Invoke -CommandName Find-AppAlias -Times 0 -Exactly
        $manifest.version | Should-Be '3.0.0'
    }

    It 'keeps the alias file out of the manifests of a flat bucket' {
        Write-AliasMap 'main' 'old-name' 'main/new-name'
        [System.IO.File]::WriteAllText((Join-Path $aliasTestRoot 'main\new-name.json'), '{"version":"1.0.0"}')

        $names = @(Get-BucketManifestFiles 'main').Name

        $names | Should-ContainCollection 'new-name.json'
        $names | Should-NotContainCollection '.scoop-aliases.json'
    }

    It 'uses only the alias of the source bucket' {
        Write-AliasMap 'extras' 'old-name' 'extras/new-name'
        Write-AppManifest 'extras' 'new-name' '1.0.0'

        Find-AppAlias 'old-name' 'main' | Should-BeNull
        (Find-AppAlias 'old-name' $null).App | Should-Be 'new-name'
    }

    It 'reports an alias whose target bucket is not installed' {
        Write-AliasMap 'main' 'old-name' 'versions/new-name'
        Mock known_bucket_repo { 'https://github.com/ScoopInstaller/Versions' }
        $script:errorMessage = $null
        Mock error { $script:errorMessage = $msg }

        $app, $manifest, $bucket, $url = Get-Manifest 'old-name'

        $manifest | Should-BeNull
        $script:errorMessage | Should-MatchString 'scoop bucket add versions'
        $script:errorMessage | Should-MatchString "renamed to 'new-name'"
    }

    It 'reports an alias that points to different targets in several buckets' {
        Write-AliasMap 'main' 'old-name' 'main/new-name'
        Write-AliasMap 'extras' 'old-name' 'extras/other-name'
        Write-AppManifest 'main' 'new-name' '1.0.0'
        Write-AppManifest 'extras' 'other-name' '1.0.0'

        $alias = Find-AppAlias 'old-name' $null

        $alias.Ambiguous | Should-BeTrue
        Should-Invoke -CommandName error -Times 1
    }

    Context 'installed app' {
        BeforeEach {
            Mock installed { $true }
            Mock Select-CurrentVersion { '1.0.0' }
            Mock installed_manifest { [pscustomobject]@{ version = '1.0.0' } }
            Mock manifest { $null }
        }

        It 'resolves the alias of the bucket the app was installed from' {
            Write-AliasMap 'extras' 'old-name' 'extras/new-name'
            Write-AppManifest 'extras' 'new-name' '2.0.0'
            Mock install_info { [pscustomobject]@{ bucket = 'extras'; url = $null } }

            $app, $manifest, $bucket, $url = Get-Manifest 'old-name'

            $app | Should-Be 'new-name'
            $bucket | Should-Be 'extras'
        }

        It 'does not let another bucket redirect it' {
            # 'main' points at a manifest that exists, so only the trust boundary
            # keeps it from redirecting the app installed from 'extras'.
            Write-AliasMap 'main' 'old-name' 'extras/new-name'
            Write-AppManifest 'extras' 'new-name' '2.0.0'
            Mock install_info { [pscustomobject]@{ bucket = 'extras'; url = $null } }

            $app, $manifest, $bucket, $url = Get-Manifest 'old-name'

            $app | Should-Be 'old-name'
            $manifest | Should-BeNull
        }

        It 'does not redirect it when the source bucket is unknown' {
            Write-AliasMap 'main' 'old-name' 'main/new-name'
            Write-AppManifest 'main' 'new-name' '2.0.0'
            Mock install_info { $null }

            $app, $manifest, $bucket, $url = Get-Manifest 'old-name'

            $app | Should-Be 'old-name'
            $manifest | Should-BeNull
        }
    }

    It 'resolves an alias that points to another installed bucket' {
        Write-AliasMap 'main' 'old-name' 'extras/new-name'
        Write-AppManifest 'extras' 'new-name' '2.0.0'

        $app, $manifest, $bucket, $url = Get-Manifest 'old-name'

        $app | Should-Be 'new-name'
        $bucket | Should-Be 'extras'
    }

    Context 'alias target validation' {
        BeforeEach {
            $aliasDir = Join-Path $aliasTestRoot 'main'
            New-Item -ItemType Directory -Path $aliasDir -Force | Out-Null
        }

        It 'accepts a bare app name as a target of the same bucket' {
            [System.IO.File]::WriteAllText((Join-Path $aliasDir '.scoop-aliases.json'), '{"old-name":"new-name"}')

            Get-BucketAliasTarget 'old-name' 'main' | Should-Be 'main/new-name'
        }

        It 'rejects an invalid target' {
            $cases = @(
                @{ target = 'main/'; why = 'the app part is empty' }
                @{ target = '/name'; why = 'the bucket part is empty' }
                @{ target = ' main/name'; why = 'it holds leading whitespace' }
                @{ target = 'main/ name'; why = 'it holds whitespace after the separator' }
                @{ target = 'main/new*name'; why = 'it holds a character that is invalid in a file name' }
                @{ target = 'main/name.json'; why = 'it holds a .json suffix' }
                @{ target = 'main/..'; why = 'it escapes the bucket' }
            )
            foreach ($case in $cases) {
                [System.IO.File]::WriteAllText((Join-Path $aliasDir '.scoop-aliases.json'), ('{"old-name":"' + $case.target + '"}'))
                Get-BucketAliasTarget 'old-name' 'main' | Should-BeNull -Because "the target is invalid: $($case.why)"
            }
        }

        It 'rejects an unusable alias map' {
            $cases = @(
                @{ json = '{"old-name":{"app":"new-name"}}'; why = 'the target is not a string' }
                @{ json = '["main/new-name"]'; why = 'the map is not a JSON object' }
                @{ json = '{not json'; why = 'the map is not valid JSON' }
            )
            foreach ($case in $cases) {
                [System.IO.File]::WriteAllText((Join-Path $aliasDir '.scoop-aliases.json'), $case.json)
                Get-BucketAliasTarget 'old-name' 'main' | Should-BeNull -Because "the map is unusable: $($case.why)"
            }
        }
    }
}
