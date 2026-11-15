Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/Nugetizer.ps1')
$script:Checks = 0
function Assert([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }; $script:Checks++
}
function Reject([scriptblock]$Operation, [string]$Message) {
    $failed = $false
    try { & $Operation | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('nugetizer-tests-' + [guid]::NewGuid().ToString('N'))
$packages = Join-Path $root 'packages'
function Reset-Packages {
    if (Test-Path $packages) { Remove-Item $packages -Recurse -Force }
    New-Item -ItemType Directory $packages | Out-Null
}
function Package([string]$Name, [string]$Id = 'Fixture', [string]$Version = '10.0.0', [string]$Prefix = '') {
    $zip = [IO.Compression.ZipFile]::Open((Join-Path $packages $Name), 'Create')
    try {
        $writer = [IO.StreamWriter]::new($zip.CreateEntry('Fixture.nuspec').Open())
        try { $writer.Write("${Prefix}<package><metadata><id>$Id</id><version>$Version</version></metadata></package>") }
        finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
}
function Test-FailFirst {
    $names = @('NG_STAGES','NG_VERSION','GITHUB_REF_NAME','NG_DIRECTORY','NG_ROOT','NG_TEST','NG_PACK','NUGET_PACKAGES')
    $saved = @{}; foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $script:Calls = @()
    function dotnet { $script:Calls += ,@($args); Set-Variable LASTEXITCODE 42 -Scope 1 }
    try {
        $consumer = Join-Path $root 'consumer'; $src = Join-Path $consumer 'src'
        New-Item -ItemType Directory $src | Out-Null
        Set-Content (Join-Path $src 'Fixture.csproj') '<Project />'
        Set-Content (Join-Path $consumer 'tests.csproj') '<Project />'
        $env:NG_STAGES = 'test pack'; $env:NG_VERSION = '10.0.0'
        $env:NG_ROOT = $consumer; $env:NG_DIRECTORY = $packages
        $env:NG_TEST = 'tests.csproj'; $env:NG_PACK = 'src/Fixture.csproj'
        $location = (Get-Location).Path
        Reject { Invoke-Pipeline build } 'First dotnet failure must stop the build.'
        Assert ($script:Calls.Count -eq 1 -and $script:Calls[0][0] -eq 'msbuild') 'Packing ran after metadata evaluation failed.'
        Assert ((Get-Location).Path -eq $location) 'Working location was not restored.'
        Assert ($env:NUGET_PACKAGES -eq $saved['NUGET_PACKAGES']) 'Package cache was not restored.'
    } finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}
function Test-Wrappers {
    $names=@('NG_INPUTS','NG_STAGES','NG_ROOT','NG_VERSION','NG_TEST','NG_PACK','NG_DIRECTORY','NG_USER','NG_API_KEY','RUNNER_TEMP','GITHUB_OUTPUT','GITHUB_REF_NAME','GITHUB_REF_TYPE','DOTNET_TEST_RUNNER')
    $saved=@{}; foreach ($name in $names) { $saved[$name]=[Environment]::GetEnvironmentVariable($name) }
    $state=@{Calls=@();Sdk='11.0.100'}
    function dotnet {
        $state.Calls+=,@($args); Set-Variable LASTEXITCODE 0 -Scope 1
        if ($args[0] -eq '--version') { return $state.Sdk }
        if ($args[0] -eq 'msbuild') {
            $library=[IO.Path]::GetFileName($args[1]) -eq 'library.csproj'
            return (@{Properties=@{IsTestProject=(!$library).ToString();NugetizerIntegrationTest='false';IsPackable=$library.ToString()}} | ConvertTo-Json -Compress)
        }
        if ($args[0] -eq 'pack') {
            $output=$args[[array]::IndexOf($args,'-o')+1]; New-Item -ItemType Directory $output -Force | Out-Null
            Package 'wrapped.nupkg'; Move-Item (Join-Path $packages 'wrapped.nupkg') $output
        }
    }
    try {
        $consumer=Join-Path $root 'wrapped'; New-Item -ItemType Directory $consumer | Out-Null
        Set-Content (Join-Path $consumer 'library.csproj') '<Project />'
        Set-Content (Join-Path $consumer 'tests with spaces.csproj') '<Project />'
        $env:RUNNER_TEMP=$root; $env:GITHUB_OUTPUT=Join-Path $root 'outputs'; $env:GITHUB_REF_NAME='v10.0.0'; $env:GITHUB_REF_TYPE='tag'
        $inputs=@{stages='test pack'; 'working-directory'=$consumer; version='10.0.0'; 'test-target'='tests with spaces.csproj'; 'pack-target'='library.csproj'}
        $env:NG_INPUTS=$inputs | ConvertTo-Json; $pipeline=Join-Path $PSScriptRoot '../scripts/Nugetizer.ps1'
        & $pipeline -Phase prepare
        Assert ([bool](Select-String -Path $env:GITHUB_OUTPUT -Pattern '^pack=true$')) 'Stage outputs missing.'
        Reset-Packages; $env:NG_DIRECTORY=$packages
        & $pipeline -Phase build
        $testCall=@($state.Calls | Where-Object { $_[0] -eq 'test' })[0]
        Assert (($testCall -join '|') -ceq "test|$(Join-Path $consumer 'tests with spaces.csproj')|-c|Debug") 'Target argument split.'
        $inputs.stages='pack publish'; $env:NG_INPUTS=$inputs | ConvertTo-Json; $env:NG_API_KEY='fixture-key'
        & $pipeline -Phase publish
        Assert ($state.Calls[-1][1] -eq 'push') 'Wrapper did not reach fake push.'
        $inputs.stages='test'; $inputs.'test-target'='tests.csproj'
        Set-Content (Join-Path $consumer 'global.json') '{"test":{"runner":"Microsoft.Testing.Platform"}}'
        $env:DOTNET_TEST_RUNNER='invalid'
        function Test-Selector([string]$Target) {
            Push-Location $consumer
            try { Invoke-Tests $Target @('-c','Debug') } finally { Pop-Location }
        }
        foreach ($target in @('tests.csproj','tests','tests.sln','tests.slnx')) {
            Test-Selector $target
            $selector=if ($target -match '\.slnx?$') {'--solution'} else {'--project'}
            Assert (($state.Calls[-1] -join '|') -ceq "test|$selector|$target|-c|Debug") 'MTP target selector incorrect.'
        }
        foreach ($runner in @('vStEsT','mIcRoSoFt.TeStInG.PlAtFoRm')) {
            $env:DOTNET_TEST_RUNNER=$runner; Test-Selector 'tests.slnx'
            $expected=if ($runner -eq 'VSTest') { 'test|tests.slnx' } else { 'test|--solution|tests.slnx' }
            Assert (($state.Calls[-1] -join '|') -ceq "$expected|-c|Debug") 'Recognized runner override incorrect.'
        }
        $state.Sdk='10.0.404'; $env:DOTNET_TEST_RUNNER='VSTest'; Test-Selector 'tests.slnx'
        Assert (($state.Calls[-1] -join '|') -ceq 'test|--solution|tests.slnx|-c|Debug') 'SDK 10 honored an unsupported environment override.'
        Set-Content (Join-Path $consumer 'global.json') '{"test":{"runner":"VSTest"}}'
        $env:DOTNET_TEST_RUNNER='Microsoft.Testing.Platform'; Test-Selector 'tests.slnx'
        Assert (($state.Calls[-1] -join '|') -ceq 'test|tests.slnx|-c|Debug') 'SDK 10 VSTest arguments changed.'
        $state.Sdk='11.0.100'
        $env:DOTNET_TEST_RUNNER=''; $env:GITHUB_REF_NAME='main'; $inputs.version=''
        foreach ($config in @('{}','{"test":{}}','{"test":null}')) {
            Set-Content (Join-Path $consumer 'global.json') $config
            $env:NG_INPUTS=$inputs | ConvertTo-Json; & $pipeline -Phase prepare; Test-Selector 'tests.slnx'
            Assert (($state.Calls[-1] -join '|') -ceq 'test|tests.slnx|-c|Debug') 'Runner-less test configuration failed.'
        }
        $inputs.version='10.0.0'
        $inputs.stages='pack publish release'; $env:NG_INPUTS=$inputs | ConvertTo-Json; $env:NG_USER='fixture-user'; $env:GITHUB_REF_NAME='v1.0.0'
        Reject { & $pipeline -Phase prepare } 'Mismatched release tag accepted.'
        $env:GITHUB_REF_NAME='v10.0.0'; $env:NG_USER=''
        Reject { & $pipeline -Phase prepare } 'Missing policy user accepted.'
    } finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) } }
}
function Test-IntegrationWrapper {
    $names=@('NG_INPUTS','NG_STAGES','NG_ROOT','NG_VERSION','NG_TEST','NG_INTEGRATION','NG_PACK','NG_DIRECTORY','NUGET_PACKAGES','DOTNET_TEST_RUNNER')
    $saved=@{}; foreach ($name in $names) { $saved[$name]=[Environment]::GetEnvironmentVariable($name) }
    $state=@{Calls=@();Mode='';Error=''}
    function gh { throw 'Integration build must not invoke gh.' }
    function dotnet {
        $state.Calls+=,@($args); Set-Variable LASTEXITCODE 0 -Scope 1
        if ($args[0] -eq '--version') { return '11.0.100' }
        if ($args[0] -eq 'msbuild') {
            $name=[IO.Path]::GetFileName($args[1])
            return (@{Properties=@{IsTestProject=($name -ne 'library.csproj').ToString();NugetizerIntegrationTest=($name -eq 'integration tests.csproj').ToString();IsPackable=($name -eq 'library.csproj').ToString()}} | ConvertTo-Json -Compress)
        }
        if ($args[0] -eq 'pack') {
            $output=$args[[array]::IndexOf($args,'-o')+1]; New-Item -ItemType Directory $output -Force | Out-Null
            Package 'candidate.nupkg'; Move-Item (Join-Path $packages 'candidate.nupkg') $output
        }
        if ($args[0] -eq 'restore') {
            $artifacts=($args | Where-Object { $_ -like '-p:ArtifactsPath=*' }).Substring(17)
            $cache=($args | Where-Object { $_ -like '-p:RestorePackagesPath=*' }).Substring(23)
            $cached=Join-Path $cache 'fixture/10.0.0'; New-Item -ItemType Directory $artifacts,$cached -Force | Out-Null
            Copy-Item (Join-Path $packages 'candidate.nupkg') (Join-Path $cached 'fixture.10.0.0.nupkg')
            @{libraries=@{'Fixture/10.0.0'=@{type='package';path='fixture/10.0.0'}};packageFolders=@{$cache=@{}}} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $artifacts 'project.assets.json')
        }
        if ($args[0] -eq 'test' -and [IO.Path]::GetFileName($args[1]) -eq 'integration tests.csproj') {
            if ($state.Mode -eq 'fail') { Set-Variable LASTEXITCODE 42 -Scope 1 }
            if ($state.Mode -eq 'mutate') { [IO.File]::AppendAllText((Join-Path $packages 'candidate.nupkg'),'changed') }
        }
    }
    try {
        $consumer=Join-Path $root 'integration-wrapper'; New-Item -ItemType Directory $consumer | Out-Null
        foreach ($name in @('library.csproj','source tests.csproj','integration tests.csproj')) { Set-Content (Join-Path $consumer $name) '<Project />' }
        $env:NG_INPUTS=@{stages='test pack integration';'working-directory'=$consumer;version='10.0.0';'test-target'='source tests.csproj';'pack-target'='library.csproj';'integration-target'='integration tests.csproj'} | ConvertTo-Json
        $env:NG_DIRECTORY=$packages; $env:DOTNET_TEST_RUNNER='VSTest'; $pipeline=Join-Path $PSScriptRoot '../scripts/Nugetizer.ps1'
        $location=(Get-Location).Path
        foreach ($mode in @('success','fail','mutate')) {
            Reset-Packages; $state.Calls=@(); $state.Mode=$mode; $state.Error=''
            try { & $pipeline -Phase build } catch { $state.Error=$_.Exception.Message }
            $calls=@($state.Calls | Where-Object { $_[0] -notin @('--version','msbuild') })
            Assert (($calls | ForEach-Object { $_[0] }) -join '|' -ceq 'test|pack|restore|test') 'Source test/pack/restore/integration ordering changed or candidate repacked.'
            Assert ([IO.Path]::GetFileName($calls[0][1]) -ceq 'source tests.csproj' -and [IO.Path]::GetFileName($calls[2][1]) -ceq 'integration tests.csproj' -and [IO.Path]::GetFileName($calls[3][1]) -ceq 'integration tests.csproj') 'Wrapper lost test targets.'
            foreach ($call in @($calls[2],$calls[3])) {
                Assert ('-p:PackageUnderTestVersion=10.0.0' -in $call -and '-p:Configuration=Release' -in $call) 'Integration did not use the Release candidate version.'
            }
            Assert ('--no-restore' -in $calls[3]) 'Integration test restored again.'
            if ($mode -eq 'success') { Assert ($state.Error -eq '') 'Valid candidate integration failed.' }
            if ($mode -eq 'fail') { Assert ($state.Error -like '*dotnet test failed (42)*') 'Integration failure did not stop the wrapper build.' }
            if ($mode -eq 'mutate') { Assert ($state.Error -ceq 'Integration tests changed candidate packages.') 'Post-integration candidate mutation escaped detection.' }
            Assert ((Get-Location).Path -eq $location -and $env:NUGET_PACKAGES -eq $saved['NUGET_PACKAGES']) 'Integration build leaked location or cache.'
        }
    } finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) } }
}
function Test-ProjectClassification {
    $names=@('NG_INPUTS','NG_STAGES','NG_ROOT','NG_VERSION','NG_TEST','NG_PACK','NG_DIRECTORY','NUGET_PACKAGES','DOTNET_TEST_RUNNER')
    $saved=@{}; foreach ($name in $names) { $saved[$name]=[Environment]::GetEnvironmentVariable($name) }
    $state=@{Calls=@();Invalid=''}
    function dotnet {
        $state.Calls+=,@($args); Set-Variable LASTEXITCODE 0 -Scope 1
        if ($args[0] -eq '--version') { return '11.0.100' }
        if ($args[0] -eq 'sln') { return @('Project(s)','----------','tests/Ordinary.IntegrationTests.csproj','library.csproj') }
        if ($args[0] -eq 'msbuild') {
            $name=[IO.Path]::GetFileName($args[1])
            # Model evaluated, inherited flags: the project files contain no inline properties.
            $properties=@{IsTestProject=($name -ne 'library.csproj').ToString();NugetizerIntegrationTest=($name -eq 'CustomChecks.csproj').ToString();IsPackable=($name -eq 'library.csproj').ToString()}
            if ($state.Invalid) { $properties[$state.Invalid]='invalid' }
            return (@{Properties=$properties} | ConvertTo-Json -Compress)
        }
    }
    $consumer=Join-Path $root 'classification'; $tests=Join-Path $consumer 'tests'
    New-Item -ItemType Directory $tests | Out-Null
    foreach ($name in @('CustomChecks.csproj','Ordinary.IntegrationTests.csproj')) { Set-Content (Join-Path $tests $name) '<Project />' }
    Set-Content (Join-Path $consumer 'library.csproj') '<Project />'
    foreach ($extension in @('sln','slnx')) { Set-Content (Join-Path $consumer "tests.$extension") '' }
    $directory=Join-Path $consumer 'target with spaces'; New-Item -ItemType Directory $directory | Out-Null
    Set-Content (Join-Path $directory 'SourceChecks.csproj') '<Project />'
    $location=(Get-Location).Path
    try {
        $env:NG_INPUTS=''; $env:NG_STAGES='test'; $env:NG_ROOT=$consumer; $env:NG_DIRECTORY=$packages
        $env:NG_TEST=''; $env:DOTNET_TEST_RUNNER='VSTest'
        $pipeline=Join-Path $PSScriptRoot '../scripts/Nugetizer.ps1'
        & $pipeline -Phase build
        $calls=@($state.Calls | Where-Object { $_[0] -eq 'test' })
        Assert ($calls.Count -eq 1 -and [IO.Path]::GetFileName($calls[0][1]) -ceq 'Ordinary.IntegrationTests.csproj') 'Filename suffix overrode evaluated source-test metadata.'
        Assert (@($state.Calls | Where-Object { $_[0] -eq 'msbuild' -and '-p:Configuration=Debug' -in $_ }).Count -eq 2) 'Main wrapper did not evaluate inherited Debug metadata.'
        foreach ($target in @('tests/Ordinary.IntegrationTests.csproj','target with spaces','tests.sln','tests.slnx')) {
            $state.Calls=@(); $env:NG_TEST=$target
            & $pipeline -Phase build
            $calls=@($state.Calls | Where-Object { $_[0] -eq 'test' })
            $expected=if ($target -eq 'target with spaces') { Join-Path $directory 'SourceChecks.csproj' } else { Join-Path $tests 'Ordinary.IntegrationTests.csproj' }
            Assert ($calls.Count -eq 1 -and ($calls[0] -join '|') -ceq "test|$expected|-c|Debug") 'Explicit target did not expand to the classified project.'
        }
        Push-Location $consumer
        try {
            $state.Calls=@()
            $integration=@(Get-TestProjects $true)
            Assert ($integration.Count -eq 1 -and [IO.Path]::GetFileName($integration[0]) -ceq 'CustomChecks.csproj') 'Custom integration filename was not selected by evaluated metadata.'
            Assert ('-p:Configuration=Release' -in $state.Calls[0]) 'Integration metadata was not evaluated in Release.'
            Reject { Get-TestProjects $false 'tests/CustomChecks.csproj' } 'Explicit integration project accepted in source phase.'
            Reject { Get-TestProjects $true 'tests/Ordinary.IntegrationTests.csproj' } 'Explicit source project accepted in integration phase.'
            Reject { Get-TestProjects $false 'library.csproj' } 'Explicit non-test library accepted.'
            foreach ($flag in @('IsTestProject','NugetizerIntegrationTest','IsPackable')) {
                $state.Invalid=$flag
                Reject { Get-TestProjects $false 'tests/Ordinary.IntegrationTests.csproj' } "Invalid evaluated $flag accepted."
            }
            $state.Invalid=''
        } finally { Pop-Location }
        Assert ((Get-Location).Path -eq $location -and $env:NUGET_PACKAGES -eq $saved['NUGET_PACKAGES']) 'Classification build leaked location or cache.'
    } finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) } }
}
function Test-PackCollision {
    $state=@{Packed=@()}
    function dotnet {
        Set-Variable LASTEXITCODE 0 -Scope 1
        if ($args[0] -eq 'msbuild') {
            return (@{Properties=@{IsTestProject='false';NugetizerIntegrationTest='false';IsPackable=($args[1] -ne 'nonpackable.csproj').ToString()}} | ConvertTo-Json -Compress)
        }
        $state.Packed+=$args[1]
        $output=$args[[array]::IndexOf($args,'-o')+1]; New-Item -ItemType Directory $output -Force | Out-Null
        Package 'collision.nupkg'; Move-Item (Join-Path $packages 'collision.nupkg') $output
    }
    Reset-Packages
    Reject { Pack-Projects @('nonpackable.csproj','first.csproj','second.csproj') 'Release' '10.0.0' $packages } 'Colliding package outputs accepted.'
    Assert (($state.Packed -join '|') -ceq 'first.csproj|second.csproj') 'Nonpackable project packed or collision evaluation failed early.'
    Assert (@(Get-ChildItem $packages -File -Filter '*.nupkg').Count -eq 0) 'Packages were combined before collision validation.'
}
function Test-PackMetadata {
    $saved=$env:GITHUB_SHA; $state=@{Calls=@();Mode='success'}
    function dotnet {
        $state.Calls+=,@($args); Set-Variable LASTEXITCODE 0 -Scope 1
        if ($args[0] -eq 'msbuild') {
            $packable='-p:Configuration=Release' -in $args -and '-p:Version=10.0.0' -in $args -and '-p:PackageVersion=10.0.0' -in $args -and '-p:RepositoryCommit=fixture-commit' -in $args -and @($args | Where-Object { $_ -like '-p:PackageOutputPath=*' }).Count -eq 1
            return (@{Properties=@{IsTestProject='false';NugetizerIntegrationTest='false';IsPackable=$packable.ToString()}} | ConvertTo-Json -Compress)
        }
        $output=$args[[array]::IndexOf($args,'-o')+1]
        if ($state.Mode -eq 'missing') { return }
        New-Item -ItemType Directory $output -Force | Out-Null
        if ($state.Mode -eq 'empty') { return }
        Package 'conditional.nupkg'; Move-Item (Join-Path $packages 'conditional.nupkg') $output
    }
    try {
        $env:GITHUB_SHA='fixture-commit'
        Assert ((Get-ProjectMetadata 'conditional.csproj' 'Release')['IsPackable'] -eq 'false') 'Conditional fixture must require pack global properties.'
        foreach ($mode in @('success','missing','empty')) {
            Reset-Packages; $state.Calls=@(); $state.Mode=$mode; $errorMessage=''
            try { Pack-Projects @('conditional.csproj') 'Release' '10.0.0' $packages } catch { $errorMessage=$_.Exception.Message }
            Assert ($state.Calls.Count -eq 2 -and $state.Calls[0][0] -eq 'msbuild' -and $state.Calls[1][0] -eq 'pack') 'Conditional packable project was skipped.'
            $query=@($state.Calls[0] | Where-Object { $_ -match '^-p:(Version|PackageVersion|RepositoryCommit|PackageOutputPath)=' })
            $pack=@($state.Calls[1] | Where-Object { $_ -like '-p:*' })
            Assert ($query.Count -eq 4 -and ($query -join '|') -ceq ($pack -join '|')) 'Metadata and pack global properties differ.'
            $output=$state.Calls[1][[array]::IndexOf($state.Calls[1],'-o')+1]
            Assert ("-p:PackageOutputPath=$output" -in $query -and '-p:Configuration=Release' -in $state.Calls[0] -and ($state.Calls[1][2..3] -join '|') -ceq '-c|Release') 'Metadata and pack configuration/output differ.'
            if ($mode -eq 'success') {
                Assert ($errorMessage -eq '' -and (Test-Path (Join-Path $packages 'conditional.nupkg'))) 'Conditional pack output was not collected.'
            } else {
                $expected=if ($mode -eq 'missing') { 'Packable project produced no output:*' } else { 'Packable project produced no packages:*' }
                Assert ($errorMessage -like $expected) 'Packable zero-output project was not rejected.'
            }
        }
    } finally { $env:GITHUB_SHA=$saved }
}
function Test-LocalPackageSelection {
    Reset-Packages; Package 'candidate.nupkg'
    $assetsRoot=Join-Path $root 'selection'; $cache=Join-Path $root 'selection-cache'; $cached=Join-Path $cache 'fixture/10.0.0'
    New-Item -ItemType Directory $assetsRoot,$cached -Force | Out-Null
    Copy-Item (Join-Path $packages 'candidate.nupkg') (Join-Path $cached 'fixture.10.0.0.nupkg')
    function Assets([hashtable]$Libraries) {
        @{libraries=$Libraries;packageFolders=@{$cache=@{}}} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $assetsRoot 'project.assets.json')
    }
    $candidate=@{type='package';path='fixture/10.0.0'}
    Assets @{'Fixture/10.0.0'=$candidate;'ThirdParty/10.0.0'=@{type='package';path='thirdparty/10.0.0'}}
    Assert-LocalPackages $assetsRoot $packages $cache '10.0.0'
    Assert $true 'Unrelated same-version package rejected despite a verified candidate.'
    Assets @{'Fixture/10.0.0'=$candidate;'Fixture/1.0.0'=@{type='project';path='../Fixture.csproj'}}
    Assert-LocalPackages $assetsRoot $packages $cache '10.0.0'
    Assert $true 'Project reference with a candidate ID was not ignored.'
    Assets @{'ThirdParty/10.0.0'=@{type='package';path='thirdparty/10.0.0'};'Fixture/10.0.0'=@{type='project';path='../Fixture.csproj'}}
    Reject { Assert-LocalPackages $assetsRoot $packages $cache '10.0.0' } 'Zero candidate package references accepted.'
    Assets @{'Fixture/10.0.0'=$candidate;'Fixture/1.0.0'=@{type='package';path='fixture/1.0.0'}}
    Reject { Assert-LocalPackages $assetsRoot $packages $cache '10.0.0' } 'Wrong-version candidate accepted alongside a valid candidate.'
}
function Test-Release {
    $names=@('NG_STAGES','NG_VERSION','NG_DIRECTORY','GITHUB_REF_NAME','GITHUB_REF_TYPE','GITHUB_REPOSITORY')
    $saved=@{}; foreach ($name in $names) { $saved[$name]=[Environment]::GetEnvironmentVariable($name) }
    $state=@{ Calls=@(); Exists=$false; Draft=$false; Prerelease=$false; Fail=''; Tag='v10.0.0' }
    function gh {
        $state.Calls+=,@($args)
        $operation=if ($args[0] -eq 'api') {'list'} else {$args[1]}
        Set-Variable LASTEXITCODE ([int]($operation -eq $state.Fail)) -Scope 1
        if ($operation -eq 'list') {
            if ($state.Exists) { ConvertTo-Json -InputObject @(@(@{tag_name=$state.Tag; draft=$state.Draft; prerelease=$state.Prerelease})) -Depth 4 -Compress }
            else { '[[]]' }
        }
    }
    try {
        Reset-Packages; Package 'a.nupkg'
        @(Get-Packages $packages '10.0.0') | ConvertTo-Json -AsArray | Set-Content (Join-Path $packages 'manifest.json')
        $env:NG_STAGES='pack publish release'; $env:NG_VERSION='10.0.0'; $env:NG_DIRECTORY=$packages
        $env:GITHUB_REF_NAME=$state.Tag; $env:GITHUB_REF_TYPE='tag'; $env:GITHUB_REPOSITORY='example/package'
        Invoke-Pipeline release
        Assert ($state.Calls.Count -eq 4 -and $state.Calls[1][1] -eq 'create' -and $state.Calls[2][1] -eq 'upload' -and $state.Calls[3][1] -eq 'edit') 'Draft/upload/publish ordering incorrect.'
        Assert ('--verify-tag' -in $state.Calls[1] -and '--draft' -in $state.Calls[1] -and '--draft=false' -in $state.Calls[3] -and '--clobber' -notin $state.Calls[2]) 'Unsafe release arguments.'
        $state.Exists=$true
        foreach ($draft in @($false,$true)) {
            $state.Calls=@(); $state.Draft=$draft
            Reject { Invoke-Pipeline release } 'Existing release must require deliberate recovery.'
            Assert ($state.Calls.Count -eq 1) 'Existing release mutated.'
            $state.Calls=@()
            Reject { Invoke-Pipeline preflight } 'Preflight ignored existing release.'
            Assert ($state.Calls.Count -eq 1) 'Preflight performed a write.'
        }
        foreach ($operation in @('list','create','upload','edit')) {
            $state.Calls=@(); $state.Exists=$false; $state.Fail=$operation
            Reject { Invoke-Pipeline release } "Ignored release $operation failure."
            if ($operation -eq 'list') { Assert ($state.Calls.Count -eq 1) 'Listing failure treated as missing release.' }
            if ($operation -eq 'upload') { Assert ($state.Calls.Count -eq 3) 'Failed upload still published the draft.' }
        }
    } finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) } }
}
function Test-Publish {
    $names = @('NG_STAGES','NG_VERSION','GITHUB_REF_NAME','NG_DIRECTORY','NG_API_KEY')
    $saved = @{}; foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $script:Calls = @(); $script:FailAt = 0
    function dotnet { $script:Calls += ,@($args); Set-Variable LASTEXITCODE ([int]($script:Calls.Count -eq $script:FailAt)) -Scope 1 }
    function Manifest { @(Get-Packages $packages '10.0.0') | ConvertTo-Json -AsArray | Set-Content (Join-Path $packages 'manifest.json') }
    try {
        $env:NG_STAGES='pack publish'; $env:NG_VERSION='10.0.0'; $env:NG_DIRECTORY=$packages; $env:NG_API_KEY='fixture-key'
        Reset-Packages; Package 'a.nupkg' 'A'; Package 'b.nupkg' 'B'; Manifest
        Invoke-Pipeline publish
        Assert ($script:Calls.Count -eq 2) 'Every package must be pushed separately.'
        Assert (($script:Calls[0] -join '|') -ceq "nuget|push|$(Join-Path $packages 'a.nupkg')|--api-key|fixture-key|--source|https://api.nuget.org/v3/index.json") 'Push arguments changed.'
        $script:Calls=@(); $script:FailAt=1
        Reject { Invoke-Pipeline publish } 'Push failure must stop publication.'
        Assert ($script:Calls.Count -eq 1) 'A package was pushed after failure.'
        $script:Calls=@(); $env:NG_API_KEY=''
        Reject { Invoke-Pipeline publish } 'Missing key accepted.'
        $env:NG_API_KEY='fixture-key'
        [IO.File]::AppendAllText((Join-Path $packages 'a.nupkg'),'changed')
        Reject { Invoke-Pipeline publish } 'Changed package accepted.'
        Manifest; Package 'extra.nupkg' 'Extra'
        Reject { Invoke-Pipeline publish } 'Unrecorded package accepted.'
        Remove-Item (Join-Path $packages 'extra.nupkg'); Manifest
        $manifest=@(Get-Content (Join-Path $packages 'manifest.json') -Raw | ConvertFrom-Json); $manifest[0].Id='Tampered'
        $manifest | ConvertTo-Json -AsArray | Set-Content (Join-Path $packages 'manifest.json')
        Reject { Invoke-Pipeline publish } 'Changed manifest accepted.'
        Assert ($script:Calls.Count -eq 0) 'Invalid artifacts reached push.'
    } finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) } }
}
try {
    Assert ((Get-Version '' 'v10.0.0') -ceq '10.0.0') 'Tag version failed.'
    Assert ((Get-Version '1.2.3-rc.1' 'ignored') -ceq '1.2.3-rc.1') 'Explicit version failed.'
    foreach ($version in @('0.0.0','0.0.0-rc','01.2.3','1.2','1.2.3-01','1.2.3; echo injected','1.2.3+meta',"1.2.3`n",'1.2.٣','2147483648.0.0')) {
        Reject { Get-Version $version '' } "Accepted invalid version: $version"
    }
    Assert (((Get-Stages 'setup, test pack integration') -join ' ') -eq 'setup test pack integration') 'Stage parsing failed.'
    Assert ((Get-Stages 'pack publish release').Count -eq 3) 'Valid prerequisites rejected.'
    foreach ($stages in @('','publish','pack release','setup; echo injected','unknown','PACK','archive','prepack','integration')) {
        Reject { Get-Stages $stages } "Accepted invalid stages: $stages"
    }
    Reset-Packages; Package 'Fixture.10.0.0.nupkg'
    $items = @(Get-Packages $packages '10.0.0')
    Assert ($items.Count -eq 1 -and $items[0].Version -ceq '10.0.0' -and $items[0].Hash.Length -eq 64) '10.0.0 metadata rejected.'
    Reject { Get-Packages $packages '1.0.0' } 'Wrong metadata version accepted.'
    Reset-Packages; Package 'Fixture.nupkg' 'Fixture' '10.0.0' '<!DOCTYPE package [<!ENTITY x "bad">]>'
    Reject { Get-Packages $packages '10.0.0' } 'DTD accepted.'
    Reset-Packages; Package 'a.nupkg'; Package 'b.nupkg' 'fixture'
    Reject { Get-Packages $packages '10.0.0' } 'Case-insensitive duplicate ID accepted.'
    Reset-Packages; Package 'a.nupkg'; Package 'orphan.snupkg' 'Other'
    Reject { Get-Packages $packages '10.0.0' } 'Orphan symbols accepted.'
    Reset-Packages; Package 'a.nupkg'; Package 'a.snupkg'
    Assert (@(Get-Packages $packages '10.0.0').Count -eq 2) 'Adjacent symbols rejected.'
    Reset-Packages; Package 'a.nupkg' 'A'; Package 'b.nupkg' 'B'; Package 'b.snupkg' 'A'
    Reject { Get-Packages $packages '10.0.0' } 'Symbols matched a different adjacent package.'
    Reset-Packages; Package 'a.nupkg'; Package 'a.snupkg'
    Package 'b.nupkg' 'Other'; Package 'b.snupkg' 'fixture'
    Reject { Get-Packages $packages '10.0.0' } 'Duplicate symbol ID accepted.'
    Reset-Packages; Package 'a.nupkg'; Package 'b.NUPKG' 'Other'
    Reject { Get-Packages $packages '10.0.0' } 'Uppercase package extension accepted.'
    Test-FailFirst
    Reset-Packages; Package 'Fixture.0.0.0-debug.nupkg' 'Fixture' '0.0.0-debug'
    $assetsRoot=Join-Path $root 'restore'; $cache=Join-Path $root 'fallback'; $cached=Join-Path $cache 'fixture/0.0.0-debug'
    New-Item -ItemType Directory $assetsRoot,$cached -Force | Out-Null
    $archive=Join-Path $cached 'fixture.0.0.0-debug.nupkg'
    Copy-Item (Join-Path $packages 'Fixture.0.0.0-debug.nupkg') $archive
    @{libraries=@{'Fixture/0.0.0-debug'=@{type='package';path='fixture/0.0.0-debug'}};packageFolders=@{$cache=@{}}} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $assetsRoot 'project.assets.json')
    Assert-LocalPackages $assetsRoot $packages $cache
    Assert $true 'Identical fallback package should be acceptable.'
    Package 'Fixture.0.0.0-debug.snupkg' 'Fixture' '0.0.0-debug'
    Assert-LocalPackages $assetsRoot $packages $cache
    Assert $true 'Adjacent symbols must not create a second restore candidate.'
    Reject { Assert-LocalPackages $assetsRoot $packages (Join-Path $root 'fresh-cache') } 'Fallback location accepted instead of the run cache.'
    [IO.File]::AppendAllText($archive,'stale')
    Reject { Assert-LocalPackages $assetsRoot $packages $cache } 'Different fallback package accepted.'
    @{libraries=@{'Fixture/0.0.0-DEBUG'=@{type='package';path='fixture/0.0.0-debug'}};packageFolders=@{$cache=@{}}} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $assetsRoot 'project.assets.json')
    Reject { Assert-LocalPackages $assetsRoot $packages $cache } 'Case-variant stale package escaped verification.'
    @{libraries=@{'Removed/0.0.0-DEBUG'=@{type='package';path='removed/0.0.0-debug'}};packageFolders=@{$cache=@{}}} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $assetsRoot 'project.assets.json')
    Reject { Assert-LocalPackages $assetsRoot $packages $cache } 'Removed local dependency accepted.'
    Test-LocalPackageSelection
    Test-Publish
    Test-Wrappers
    Test-IntegrationWrapper
    Test-ProjectClassification
    Test-PackCollision
    Test-PackMetadata
    Test-Release
    Write-Host "Passed $script:Checks assertions."
} finally { if (Test-Path $root) { Remove-Item $root -Recurse -Force } }